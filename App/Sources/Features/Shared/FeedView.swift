import SwiftUI
import Core

/// Loads a feed with its continuation. Uses the SwiftData feed cache for instant display and
/// refreshes only when the cached copy is older than the category's TTL (timers, not
/// navigation).
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var page: FeedPage? {
        didSet { rebuildSections() }
    }
    /// The page as FeedView draws it, worked out once per change of `page` instead of in every
    /// body of every section (which also re-ran whenever a loading flag changed).
    private(set) var sections: [FeedSectionModel] = []
    /// Cards in `page`.
    private(set) var itemCount = 0
    /// Every card in the order it's drawn (a grid, then its Shorts shelf, then the next
    /// section), and whether it's drawn in a grid column or at a shelf's own card size.
    private var drawOrder: [(item: FeedItem, inGrid: Bool)] = []
    /// Goes up when `page` is replaced by a different first page (a refresh, "Show the latest"),
    /// so sections whose card count didn't change still redraw.
    private var generation = 0
    /// A newer first page that a background refresh fetched while the list was on screen. It's
    /// shown when the user picks "Show the latest", so a refresh never swaps the cards (and the
    /// focused one) out from under them.
    @Published private(set) var pendingPage: FeedPage?
    @Published private(set) var error: BridgeError?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var moreError: BridgeError?
    /// A refresh the user asked for failed while a list was on screen (shown in the footer).
    @Published private(set) var refreshError: BridgeError?
    /// The page came from the cache (or its key expired with the JS session), so its
    /// continuation can't be used; the next page starts again from the first one.
    @Published private(set) var hasStaleContinuation = false
    /// Goes up after each page that loaded (and when a new first page is shown), so the footer
    /// goes on loading while it stays on screen. The bridge hands back the same continuation key
    /// for every page of a feed, so the key alone can't tell that a page arrived.
    @Published private(set) var listVersion = 0
    /// Pages in a row that added nothing (every card already shown).
    private var pagesWithNothingNew = 0
    /// An automatic next page was asked for while a refresh ran.
    private var resumeAfterRefresh = false
    /// Cards of `page` on screen now, by their position in the page.
    private var cardsOnScreen: Set<Int> = []
    /// The list scrolled since it came on screen: a card left while others stayed. When the last
    /// one leaves, the list itself left (another tab, a pushed page, another channel tab), and it
    /// starts over when it's back.
    private var hasScrolled = false
    private(set) var fetchedAt: Date?
    private var lastMoreFailure: Date?

    let cacheKey: String?
    let category: RefreshPolicy.Category
    private let loader: (YouTubeService) async throws -> FeedPage
    private var loadTask: Task<Void, Never>?

    init(cacheKey: String?, category: RefreshPolicy.Category, loader: @escaping (YouTubeService) async throws -> FeedPage) {
        self.cacheKey = cacheKey
        self.category = category
        self.loader = loader
    }

    /// When the user changed a list's content (a card's "Save to Watch Later"), by cache key.
    private static var changedAt: [String: Date] = [:]

    /// The list behind `cacheKey` changed: its next load fetches it again, even over a fresh
    /// cache, and shows the result directly.
    static func markChanged(cacheKey: String) {
        changedAt[cacheKey] = Date()
    }

    private var wasChanged: Bool {
        guard let cacheKey, let changed = Self.changedAt[cacheKey] else { return false }
        guard let fetchedAt else { return true }
        return fetchedAt < changed
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return wasChanged || !RefreshPolicy.isFresh(fetchedAt: fetchedAt, category: category)
    }

    var canLoadMore: Bool {
        page?.continuation != nil || hasStaleContinuation
    }

    /// The next page loads by itself (when the last cards or the footer come on screen); false
    /// once a load failed or pages stopped bringing anything new, which leaves it to the footer's
    /// button.
    var loadsMoreByItself: Bool {
        canLoadMore && moreError == nil && pagesWithNothingNew < Self.pagesWithNothingNewLimit
    }

    private static let pagesWithNothingNewLimit = 5

    /// How many cards before the end of the list the next page starts loading once the list
    /// scrolls: five grid rows, about two screens. With only the last two rows (as before) a
    /// remote pressed every half second reached the end before the page arrived, and the cards
    /// appeared under the focus.
    static let loadAheadCount = Layout.gridColumns * 5

    /// The same before the list has scrolled: the last two grid rows, as before (the footer
    /// coming on screen loads it too). The longer lead reached back into the first screen of a
    /// page of up to about 30 cards, so just opening a list loaded its next page: a list restored
    /// from a fresh cache fetched its first page again to resume it, and a search or a channel
    /// tab fetched page 2 on every visit, scrolled or not.
    static let loadAtEndCount = Layout.gridColumns * 2

    /// Cards fetched ahead of a card that comes on screen: two grid rows, or the start of the
    /// shelf or section after it.
    static let artworkAheadCount = Layout.gridColumns * 2

    /// A card came on screen. Close enough to the end, the next page starts loading; and the
    /// artwork of the cards drawn after it is fetched now. A lazy grid or shelf only makes a
    /// card as it scrolls into view, so its image used to start downloading when the focus was
    /// already landing on it (a grey card under the focus, then a fade).
    /// `generation` is the one of the section that drew the card; `gridCardWidth` (the width a
    /// grid hands its cards; a shelf's cards keep their own) and `scale` give the size the cards
    /// draw their artwork at.
    func cardAppeared(_ entry: KeyedFeedItem, generation: Int, _ model: AppModel, gridCardWidth: CGFloat, scale: CGFloat) {
        guard generation == self.generation else { return }
        cardsOnScreen.insert(entry.offset)
        let lead = hasScrolled ? Self.loadAheadCount : Self.loadAtEndCount
        if entry.offset >= itemCount - lead, loadsMoreByItself, !isLoadingMore {
            Task { await loadMore(model, automatic: true) }
        }
        let next = drawOrder.dropFirst(entry.slot + 1).prefix(Self.artworkAheadCount)
        for upcoming in next {
            guard let artwork = upcoming.item.artwork(cardWidth: upcoming.inGrid ? gridCardWidth : nil) else { continue }
            ImagePipeline.shared.prefetch(artwork.url, pixels: CGSize(
                width: (artwork.size.width * scale).rounded(.up),
                height: (artwork.size.height * scale).rounded(.up)))
        }
    }

    /// A card left the screen: the list scrolled, unless it was the last one (the list left).
    func cardDisappeared(_ entry: KeyedFeedItem, generation: Int) {
        guard generation == self.generation else { return }
        cardsOnScreen.remove(entry.offset)
        hasScrolled = !cardsOnScreen.isEmpty
    }

    /// A new first page (or none) starts with nothing on screen and nothing scrolled; the cards
    /// of the old one that leave now don't count (their sections have the old generation).
    private func startGeneration() {
        generation += 1
        cardsOnScreen = []
        hasScrolled = false
    }

    /// First appearance: show cache, fetch if missing or stale. With `keepPlace` (FeedView,
    /// which offers "Show the latest"), a fetch for a list already on screen is kept aside.
    func loadIfNeeded(_ model: AppModel, keepPlace: Bool = false) async {
        var restoredOld = false
        if page == nil, let key = cacheKey, let cached = model.store.cachedPage(key, as: FeedPage.self) {
            var restored = cached.value
            hasStaleContinuation = restored.continuation != nil
            restored.continuation = nil
            page = restored
            fetchedAt = cached.fetchedAt
            // A list from an earlier launch that is over an hour old is replaced as soon as the
            // new one arrives instead of waiting for "Show the latest".
            restoredOld = Date().timeIntervalSince(cached.fetchedAt) > 3600
        }
        if page == nil || isStale {
            await refresh(model, keepPlace: keepPlace && !wasChanged && !restoredOld)
        }
    }

    /// Timer tick: refresh only when the TTL expired.
    func refreshIfStale(_ model: AppModel, keepPlace: Bool = false) async {
        guard !isLoading, isStale else { return }
        await refresh(model, keepPlace: keepPlace && !wasChanged)
    }

    /// `userInitiated`: the Retry / Refresh buttons. Their failures are always shown; a timer
    /// refresh that fails while a list is on screen only logs.
    func refresh(_ model: AppModel, userInitiated: Bool = false, keepPlace: Bool = false) async {
        if isLoading { return }
        isLoading = true
        if userInitiated { refreshError = nil }
        defer { isLoading = false }
        do {
            let fresh = try await model.api(loader)
            if keepPlace, !userInitiated, let page, !page.isEmpty {
                let latest = fresh.allItems.map(\.id)
                if !latest.isEmpty, page.allItems.map(\.id).starts(with: latest) {
                    // Nothing new at the top: no "Show the latest" for the same cards. A cached
                    // list goes on from this page's continuation instead of fetching it again.
                    pendingPage = nil
                    if hasStaleContinuation {
                        self.page?.continuation = fresh.continuation
                        hasStaleContinuation = false
                    }
                } else {
                    pendingPage = fresh
                }
            } else {
                show(fresh)
            }
            error = nil
            refreshError = nil
            fetchedAt = Date()
            if let key = cacheKey { model.store.storePage(key, fresh) }
        } catch {
            if page == nil || !(page?.isEmpty == false) {
                self.error = BridgeError.wrap(error)
            } else if userInitiated {
                refreshError = BridgeError.wrap(error)
            } else {
                model.logs.append(.warn, "Background refresh failed: \(BridgeError.wrap(error).message)")
            }
        }
        if resumeAfterRefresh {
            // An automatic next page waited for this refresh: the footer (if it's still on
            // screen) asks again, instead of showing a spinner with nothing loading.
            resumeAfterRefresh = false
            listVersion += 1
        }
    }

    /// "Show the latest": swaps in the page a background refresh kept aside.
    func showPending() {
        guard let pendingPage else { return }
        show(pendingPage)
    }

    private func show(_ fresh: FeedPage) {
        startGeneration()
        page = fresh
        pendingPage = nil
        refreshError = nil
        moreError = nil
        lastMoreFailure = nil
        hasStaleContinuation = false
        pagesWithNothingNew = 0
        listVersion += 1
    }

    /// Next page. `automatic` loads (the footer or the last cards coming on screen) don't retry
    /// a failure by themselves; the footer's Retry does. Otherwise a key that keeps failing (an
    /// expired one while YouTube rejects the session) would request pages in a loop.
    func loadMore(_ model: AppModel, automatic: Bool = false) async {
        if automatic {
            if moreError != nil { return }
            if let lastMoreFailure, Date().timeIntervalSince(lastMoreFailure) < 5 { return }
        }
        if isLoading {
            // A refresh (the first fetch, or a timer's) is running; see the end of `refresh`.
            if automatic { resumeAfterRefresh = true }
            return
        }
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        moreError = nil
        defer { isLoadingMore = false }
        do {
            var added = 0
            if !hasStaleContinuation, let key = page?.continuation {
                do {
                    let next = try await model.api { try await $0.more(key) }
                    added = appendNew(next)
                } catch let error as BridgeError where error.kind == .expired {
                    // The key died with the JS session (recreated after an auth error, or evicted).
                    hasStaleContinuation = true
                    added = try await resumeFromFirstPage(model)
                }
            } else {
                added = try await resumeFromFirstPage(model)
            }
            lastMoreFailure = nil
            // The footer loads on by itself while pages bring new cards (or while a resumed list
            // catches up with what it shows), but a run of pages with nothing new stops at its
            // Load more button instead of requesting page after page.
            pagesWithNothingNew = added > 0 ? 0 : pagesWithNothingNew + 1
            if pagesWithNothingNew < Self.pagesWithNothingNewLimit { listVersion += 1 }
        } catch {
            moreError = BridgeError.wrap(error)
            lastMoreFailure = Date()
        }
    }

    /// Continues a page whose continuation can't be used: fetches the first page again and
    /// appends only what isn't shown yet, so the list grows instead of being replaced under the
    /// user.
    private func resumeFromFirstPage(_ model: AppModel) async throws -> Int {
        let first = try await model.api(loader)
        let added = appendNew(first)
        hasStaleContinuation = false
        return added
    }

    /// Appends a page, skipping items the list already shows (continuation pages repeat videos,
    /// and resuming appends the first page again). Returns how many cards it added.
    private func appendNew(_ next: FeedPage) -> Int {
        guard var current = page else {
            page = next
            return next.allItems.count
        }
        var seen = Set(current.allItems.map(\.id))
        var unseen = next
        unseen.sections = next.sections.map { section in
            var copy = section
            copy.items = section.items.filter { seen.insert($0.id).inserted }
            return copy
        }
        current.append(unseen)
        page = current
        return unseen.allItems.count
    }

    func clear() {
        startGeneration()
        page = nil
        pendingPage = nil
        error = nil
        refreshError = nil
        moreError = nil
        hasStaleContinuation = false
        fetchedAt = nil
    }

    /// Rebuilds `sections` from `page`. A section whose cards didn't change keeps its model (and
    /// so its views skip their bodies); appending a page only rebuilds the sections it touched.
    private func rebuildSections() {
        guard let page else {
            sections = []
            itemCount = 0
            drawOrder = []
            return
        }
        var start = 0
        var rebuilt: [FeedSectionModel] = []
        rebuilt.reserveCapacity(page.sections.count)
        for (position, section) in page.sections.enumerated() {
            if position < sections.count, sections[position].isCurrent(for: section, start: start, generation: generation) {
                rebuilt.append(sections[position])
            } else {
                rebuilt.append(FeedSectionModel(position: position, section: section, start: start, generation: generation))
            }
            start += section.items.count
        }
        sections = rebuilt
        itemCount = start
        var order: [(item: FeedItem, inGrid: Bool)] = []
        order.reserveCapacity(start)
        for section in rebuilt {
            for card in section.cards { order.append((item: card.item, inGrid: section.style == .grid)) }
            for card in section.shelf { order.append((item: card.item, inGrid: false)) }
        }
        drawOrder = order
    }
}

/// A section as FeedView draws it: its cards keyed once, a grid's Shorts split out into the shelf
/// under it, and each card's position in the whole page.
struct FeedSectionModel: Identifiable, Equatable {
    /// Position in the page, not the section's id: the bridge numbers sections anew on every
    /// fetch, so its ids would tear down every section (and the focused card) on each new page.
    let id: Int
    let title: String?
    let style: SectionStyle
    /// Grid sections: the cards of the grid. Rows and Shorts shelves: every card.
    let cards: [KeyedFeedItem]
    /// Grid sections: their Shorts, shown as a shelf under the grid.
    let shelf: [KeyedFeedItem]
    /// Index of the section's first item in the page.
    let start: Int
    /// Items in the section (cards and shelf).
    let count: Int
    let generation: Int

    init(position: Int, section: FeedSection, start: Int, generation: Int) {
        id = position
        title = section.title
        style = section.style
        self.start = start
        count = section.items.count
        self.generation = generation
        // Keys come from the whole section (a video listed twice is numbered as before);
        // `offset` becomes the position in the page and `slot` the position in the order the
        // feed is drawn (the grid, then its shelf), which starts at `start` too.
        let keyed = section.items.keyed.map { entry in
            KeyedFeedItem(id: entry.id, offset: start + entry.offset, item: entry.item)
        }
        switch section.style {
        case .grid:
            let gridCards = keyed.filter { !$0.item.isShortVideo }
            cards = Self.slotted(gridCards, from: start)
            shelf = Self.slotted(keyed.filter { $0.item.isShortVideo }, from: start + gridCards.count)
        case .row, .shorts:
            cards = Self.slotted(keyed, from: start)
            shelf = []
        }
    }

    private static func slotted(_ entries: [KeyedFeedItem], from first: Int) -> [KeyedFeedItem] {
        entries.enumerated().map { index, entry in
            KeyedFeedItem(id: entry.id, offset: entry.offset, item: entry.item, slot: first + index)
        }
    }

    /// Still shows `section`: same place in the page, same first page, same number of items
    /// (pages are only ever appended to a section).
    func isCurrent(for section: FeedSection, start: Int, generation: Int) -> Bool {
        self.generation == generation && self.start == start && count == section.items.count
            && title == section.title && style == section.style
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.generation == rhs.generation && lhs.start == rhs.start && lhs.count == rhs.count
            && lhs.title == rhs.title && lhs.style == rhs.style
    }
}

/// Vertical feed: grids for loose items, horizontal shelves for rows and Shorts, infinite
/// scroll at the end.
struct FeedView<Header: View>: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feed: FeedModel
    var emptyText = "Nothing here yet."
    var autoRefresh = true
    var emptySystemImage = "tray"
    let header: Header
    @State private var contentWidth: CGFloat = Layout.defaultContentWidth
    @FocusState private var footerFocused: Bool

    init(feed: FeedModel, emptyText: String = "Nothing here yet.", autoRefresh: Bool = true,
         emptySystemImage: String = "tray", @ViewBuilder header: () -> Header) {
        self.feed = feed
        self.emptyText = emptyText
        self.autoRefresh = autoRefresh
        self.emptySystemImage = emptySystemImage
        self.header = header()
    }

    var body: some View {
        // One scroll view for every state, so the header (a channel's tab picker, for example)
        // keeps its identity and focus while the list below loads, fails or changes.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.section) {
                header
                if let page = feed.page {
                    content(page)
                } else if let error = feed.error {
                    errorView(error)
                } else {
                    LoadingView().frame(minHeight: Layout.stateHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ContentWidthReader(width: $contentWidth))
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, 40)
        }
        .overlay(alignment: .top) { ToastOverlay() }
        // Keyed on the model: when the view is handed a different FeedModel (another channel
        // tab, a new search) it loads that one instead of leaving it on an endless spinner.
        .task(id: ObjectIdentifier(feed)) {
            await feed.loadIfNeeded(model, keepPlace: true)
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await feed.refreshIfStale(model, keepPlace: true)
            }
        }
    }

    @ViewBuilder
    private func content(_ page: FeedPage) -> some View {
        if feed.pendingPage != nil {
            Button {
                feed.showPending()
            } label: {
                Label("Show the latest", systemImage: "arrow.clockwise")
            }
        }
        if page.isEmpty {
            // An empty list whose refresh failed shows the failure, not "nothing here".
            if let error = feed.error {
                errorView(error)
            } else {
                EmptyStateView(systemImage: emptySystemImage, text: emptyText)
                    .frame(minHeight: Layout.stateHeight)
            }
        }
        // Equatable: a loading flag or a new page redraws only the sections that changed, not
        // every grid (whose cards were rebuilt and re-diffed on each change before).
        ForEach(feed.sections) { section in
            FeedSectionView(section: section, contentWidth: contentWidth, feed: feed, model: model)
                .equatable()
        }
        if !page.isEmpty || feed.error == nil {
            footer
        }
    }

    /// In the same band as the loading state it replaces (a scroll view doesn't give its
    /// `maxHeight: .infinity` any height, which left it at the top).
    private func errorView(_ error: BridgeError) -> some View {
        ErrorStateView(error: error, isRetrying: feed.isLoading) {
            Task { await feed.refresh(model, userInitiated: true) }
        }
        .frame(minHeight: Layout.stateHeight)
    }

    /// While pages load by themselves the footer is only a spinner that focus can't land on: a
    /// focused footer button was pushed down by each page that arrived above it, and the list
    /// followed it past the new cards to the bottom, again and again while it stayed on screen.
    /// The button (Load more, Retry, Refresh) shows when loading needs a press, and stays while
    /// it's focused whatever it says, so focus never loses the view it's on and jumps to the top.
    private var footer: some View {
        VStack(spacing: 16) {
            if let error = feed.moreError ?? feed.refreshError {
                Text(error.userMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if feed.loadsMoreByItself, !footerFocused {
                ProgressLabel("Loading…")
                    .padding(.vertical, 10)
            } else {
                Button {
                    if feed.canLoadMore {
                        Task { await feed.loadMore(model) }
                    } else {
                        Task { await feed.refresh(model, userInitiated: true) }
                    }
                } label: {
                    footerLabel
                }
                .focused($footerFocused)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        // Full width: Down from a card in any column of the last row reaches the centred button.
        .focusSection()
        // Infinite scroll: load the next page when the footer comes on screen, and again after
        // each page that brought new cards while it stays there (the continuation key stays the
        // same, so it can't be the trigger). The cards near the end usually start it earlier.
        // Keyed on the model too: Subs and channel tabs hand this view another FeedModel, whose
        // listVersion can happen to equal the old one's.
        .task(id: [AnyHashable(ObjectIdentifier(feed)), AnyHashable(feed.listVersion)]) {
            await feed.loadMore(model, automatic: true)
        }
    }

    @ViewBuilder
    private var footerLabel: some View {
        if feed.isLoadingMore {
            ProgressLabel("Loading…", plain: true)
        } else if feed.canLoadMore {
            if feed.moreError != nil {
                Label("Retry", systemImage: "arrow.clockwise")
            } else {
                Text("Load more")
            }
        } else if feed.isLoading {
            Label("Refreshing…", systemImage: "arrow.clockwise")
        } else {
            Label(feed.refreshError != nil ? "Retry" : "Refresh", systemImage: "arrow.clockwise")
        }
    }
}

extension FeedView where Header == EmptyView {
    init(feed: FeedModel, emptyText: String = "Nothing here yet.", autoRefresh: Bool = true, emptySystemImage: String = "tray") {
        self.init(feed: feed, emptyText: emptyText, autoRefresh: autoRefresh, emptySystemImage: emptySystemImage) { EmptyView() }
    }
}

/// One section of a feed: a grid (with its Shorts in a shelf under it) or a horizontal shelf.
/// Equatable on its model and width, so its body only runs when its own cards change.
struct FeedSectionView: View, Equatable {
    let section: FeedSectionModel
    /// Width between the list's side margins; the grid's columns fill exactly this.
    var contentWidth: CGFloat = Layout.defaultContentWidth
    /// For the cards' "near the end" and prefetch calls; not observed (the parent is).
    let feed: FeedModel
    let model: AppModel
    @Environment(\.displayScale) private var displayScale

    init(section: FeedSectionModel, contentWidth: CGFloat = Layout.defaultContentWidth, feed: FeedModel, model: AppModel) {
        self.section = section
        self.contentWidth = contentWidth
        self.feed = feed
        self.model = model
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section && lhs.contentWidth == rhs.contentWidth && lhs.feed === rhs.feed
    }

    private var cardWidth: CGFloat {
        Layout.columnWidth(in: contentWidth, count: Layout.gridColumns, spacing: Layout.cardSpacing)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: Layout.cardSpacing, alignment: .top), count: Layout.gridColumns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
            if let title = section.title, !title.isEmpty {
                Text(title).font(.title3.bold())
            }
            switch section.style {
            case .grid:
                grid
            case .row, .shorts:
                ShelfRow(entries: section.cards, cardAppeared: cardAppeared, cardDisappeared: cardDisappeared)
            }
        }
    }

    /// The grid, then its Shorts shelf one row spacing under its last row of text, as far as the
    /// grid's rows are from each other.
    private var grid: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing - ShelfRow.liftRoom(for: section.shelf)) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(section.cards) { entry in
                    FeedItemView(item: entry.item, width: cardWidth)
                        .onAppear { cardAppeared(entry) }
                        .onDisappear { cardDisappeared(entry) }
                }
            }
            // Full width: Down from a control above the list (Search filters, a picker at the
            // side) reaches the first row even when that row has a single card.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            if !section.shelf.isEmpty {
                ShelfRow(entries: section.shelf, cardAppeared: cardAppeared, cardDisappeared: cardDisappeared)
            }
        }
    }

    /// Loads the next page when the end is near and fetches the artwork of the next cards.
    private func cardAppeared(_ entry: KeyedFeedItem) {
        feed.cardAppeared(entry, generation: section.generation, model, gridCardWidth: cardWidth, scale: displayScale)
    }

    /// Tells the feed whether the list scrolled (see `FeedModel.cardDisappeared`).
    private func cardDisappeared(_ entry: KeyedFeedItem) {
        feed.cardDisappeared(entry, generation: section.generation)
    }
}

/// A horizontal row of cards. It takes the same spacings as a grid (`Theme.Spacing.titleToContent`
/// under a title, `Layout.rowSpacing` under a grid's text, `Theme.Spacing.section` to the next
/// section) and keeps only `liftRoom(for:)` above its cards.
struct ShelfRow: View {
    let entries: [KeyedFeedItem]
    /// A card came on screen (FeedView loads the next page near the end and fetches the artwork
    /// of the cards after it).
    let cardAppeared: @MainActor (KeyedFeedItem) -> Void
    /// A card left the screen (FeedView tells from it whether the list scrolled).
    let cardDisappeared: @MainActor (KeyedFeedItem) -> Void

    init(entries: [KeyedFeedItem],
         cardAppeared: @escaping @MainActor (KeyedFeedItem) -> Void = { _ in },
         cardDisappeared: @escaping @MainActor (KeyedFeedItem) -> Void = { _ in }) {
        self.entries = entries
        self.cardAppeared = cardAppeared
        self.cardDisappeared = cardDisappeared
    }

    /// Room kept above the cards: the part of their focus lift that goes past a video card's. The
    /// spacings above a row leave room for a focused video card to lift into; a focused Short
    /// reaches twice as far up (`Layout.focusOverflow`), and this keeps it as clear of the title
    /// or text above. The cards' own text already starts below their lift, so nothing is kept
    /// below them.
    static func liftRoom(for entries: [KeyedFeedItem]) -> CGFloat {
        guard entries.contains(where: { $0.item.isShortVideo }) else { return 0 }
        return Layout.focusOverflow(ShortCard.artworkSize(width: Layout.shortWidth).height)
            - Layout.focusOverflow(VideoCard.artworkSize(width: Layout.cardWidth).height)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                ForEach(entries) { entry in
                    FeedItemView(item: entry.item)
                        .onAppear { cardAppeared(entry) }
                        .onDisappear { cardDisappeared(entry) }
                }
            }
            .padding(.top, Self.liftRoom(for: entries))
        }
        // The row lines up with the list on the safe-area margin but isn't clipped there: its
        // cards scroll out to the screen's edges, and a focused card's lift and shadow show
        // above and below the row.
        .scrollClipDisabled()
        .focusSection()
    }
}

/// A feed item with a view identity that survives a refresh (so the focused card stays put):
/// the item's id, numbered when it repeats in the same list (a playlist can hold a video twice).
struct KeyedFeedItem: Identifiable {
    let id: String
    /// Position in the list it came from (for FeedView's sections: in the whole page).
    let offset: Int
    let item: FeedItem
    /// Position in the order the feed draws its cards (FeedView: a grid, then its Shorts shelf).
    var slot = 0
}

extension Array where Element == FeedItem {
    var keyed: [KeyedFeedItem] {
        var counts: [String: Int] = [:]
        return enumerated().map { offset, item in
            let n = counts[item.id, default: 0]
            counts[item.id] = n + 1
            return KeyedFeedItem(id: n == 0 ? item.id : "\(item.id)#\(n)", offset: offset, item: item)
        }
    }
}

extension FeedItem {
    var isShortVideo: Bool {
        if case .video(let v) = self { return v.isShort }
        return false
    }

    /// The artwork `FeedItemView(item:width:)` draws for this item and its size in points, from
    /// the cards' own size functions, so a prefetched image is exactly the one the card asks for
    /// (the image pipeline only shares a load between requests of the same pixel size).
    /// `cardWidth` is the width passed to `FeedItemView`: a grid's column, or nil in a shelf,
    /// where every kind of card keeps its own width. Shorts keep theirs in a grid too.
    func artwork(cardWidth: CGFloat?) -> (url: URL, size: CGSize)? {
        switch self {
        case .video(let video):
            guard let url = video.thumbnailURL else { return nil }
            if video.isShort {
                return (url, ShortCard.artworkSize(width: Layout.shortWidth))
            }
            return (url, VideoCard.artworkSize(width: cardWidth ?? Layout.cardWidth))
        case .playlist(let playlist):
            guard let url = playlist.thumbnail.flatMap(URL.init(string:)) else { return nil }
            return (url, VideoCard.artworkSize(width: cardWidth ?? Layout.cardWidth))
        case .channel(let channel):
            guard let url = channel.avatar.flatMap(URL.init(string:)) else { return nil }
            let side = ChannelCard.avatarDiameter(forWidth: cardWidth ?? Layout.channelWidth)
            return (url, CGSize(width: side, height: side))
        }
    }
}
