import SwiftUI
import Core

/// Loads a feed with its continuation. Uses the SwiftData feed cache for instant display and
/// refreshes only when the cached copy is older than the category's TTL (timers, not
/// navigation).
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var page: FeedPage?
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

    /// First appearance: show cache, fetch if missing or stale. With `keepPlace` (FeedView,
    /// which offers "Show the latest"), a fetch for a list already on screen is kept aside.
    func loadIfNeeded(_ model: AppModel, keepPlace: Bool = false) async {
        if page == nil, let key = cacheKey, let cached = model.store.cachedPage(key, as: FeedPage.self) {
            var restored = cached.value
            hasStaleContinuation = restored.continuation != nil
            restored.continuation = nil
            page = restored
            fetchedAt = cached.fetchedAt
        }
        if page == nil || isStale {
            await refresh(model, keepPlace: keepPlace && !wasChanged)
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
    }

    /// "Show the latest": swaps in the page a background refresh kept aside.
    func showPending() {
        guard let pendingPage else { return }
        show(pendingPage)
    }

    private func show(_ fresh: FeedPage) {
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
        guard !isLoadingMore, !isLoading, canLoadMore else { return }
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
            if pagesWithNothingNew < 5 { listVersion += 1 }
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
        page = nil
        pendingPage = nil
        error = nil
        refreshError = nil
        moreError = nil
        hasStaleContinuation = false
        fetchedAt = nil
    }
}

/// Vertical feed: grids for loose items, horizontal shelves for rows and Shorts, infinite
/// scroll at the end.
struct FeedView<Header: View>: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feed: FeedModel
    var emptyText = "Nothing here yet."
    var autoRefresh = true
    let header: Header

    init(feed: FeedModel, emptyText: String = "Nothing here yet.", autoRefresh: Bool = true, @ViewBuilder header: () -> Header) {
        self.feed = feed
        self.emptyText = emptyText
        self.autoRefresh = autoRefresh
        self.header = header()
    }

    var body: some View {
        // One scroll view for every state, so the header (a channel's tab picker, for example)
        // keeps its identity and focus while the list below loads, fails or changes.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 60) {
                header
                if let page = feed.page {
                    content(page)
                } else if let error = feed.error {
                    errorView(error)
                } else {
                    LoadingView().frame(height: 500)
                }
            }
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
                EmptyStateView(systemImage: "tray", text: emptyText)
            }
        }
        // Keyed by position, not by the section ids (the bridge numbers sections anew on every
        // fetch), so a new page doesn't tear down every section and the focused card with it.
        ForEach(Array(page.sections.enumerated()), id: \.offset) { index, section in
            FeedSectionView(section: section, isLastSection: index == page.sections.count - 1) {
                Task { await feed.loadMore(model, automatic: true) }
            }
        }
        if !page.isEmpty || feed.error == nil {
            footer
        }
    }

    private func errorView(_ error: BridgeError) -> some View {
        ErrorStateView(error: error, isRetrying: feed.isLoading) {
            Task { await feed.refresh(model, userInitiated: true) }
        }
    }

    /// One button whose label follows the state: replacing it with a spinner while loading would
    /// remove the focused view and send focus back to the top.
    private var footer: some View {
        VStack(spacing: 16) {
            if let error = feed.moreError ?? feed.refreshError {
                Text(error.userMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                if feed.canLoadMore {
                    Task { await feed.loadMore(model) }
                } else {
                    Task { await feed.refresh(model, userInitiated: true) }
                }
            } label: {
                footerLabel
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        // Infinite scroll: load the next page when the footer comes on screen, and again after
        // each page that brought new cards (the continuation key stays the same, so it can't be
        // the trigger).
        .task(id: feed.listVersion) {
            await feed.loadMore(model, automatic: true)
        }
    }

    @ViewBuilder
    private var footerLabel: some View {
        if feed.isLoadingMore {
            HStack(spacing: 16) {
                ProgressView()
                Text("Loading…")
            }
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
    init(feed: FeedModel, emptyText: String = "Nothing here yet.", autoRefresh: Bool = true) {
        self.init(feed: feed, emptyText: emptyText, autoRefresh: autoRefresh) { EmptyView() }
    }
}

struct FeedSectionView: View {
    let section: FeedSection
    let isLastSection: Bool
    let onNearEnd: () -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Layout.cardWidth), spacing: Layout.cardSpacing, alignment: .top), count: Layout.gridColumns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let title = section.title, !title.isEmpty {
                Text(title).font(.title3.bold())
            }
            switch section.style {
            case .grid:
                grid
            case .row, .shorts:
                row
            }
        }
    }

    private var grid: some View {
        let items = section.items.keyed
        let loose = items.filter { !isShort($0.item) }
        let shorts = items.filter { isShort($0.item) }.map(\.item)
        return VStack(alignment: .leading, spacing: 40) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(loose) { entry in
                    FeedItemView(item: entry.item)
                        .onAppear {
                            if isLastSection, entry.offset >= section.items.count - Layout.gridColumns * 2 { onNearEnd() }
                        }
                }
            }
            if !shorts.isEmpty {
                ShelfRow(items: shorts)
            }
        }
    }

    private var row: some View {
        ShelfRow(items: section.items)
    }

    private func isShort(_ item: FeedItem) -> Bool {
        if case .video(let v) = item { return v.isShort }
        return false
    }
}

struct ShelfRow: View {
    let items: [FeedItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                ForEach(items.keyed) { entry in
                    FeedItemView(item: entry.item)
                }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 10)
        }
        .focusSection()
    }
}

/// A feed item with a view identity that survives a refresh (so the focused card stays put):
/// the item's id, numbered when it repeats in the same list (a playlist can hold a video twice).
struct KeyedFeedItem: Identifiable {
    let id: String
    /// Position in the list it came from.
    let offset: Int
    let item: FeedItem
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
