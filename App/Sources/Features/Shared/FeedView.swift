import SwiftUI
import Core

/// Loads a feed with its continuation. Uses the SwiftData feed cache for instant display and
/// refreshes only when the cached copy is older than the category's TTL (timers, not
/// navigation).
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var page: FeedPage?
    @Published private(set) var error: BridgeError?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var moreError: BridgeError?
    private(set) var fetchedAt: Date?

    let cacheKey: String?
    let category: RefreshPolicy.Category
    private let loader: (YouTubeService) async throws -> FeedPage
    private var loadTask: Task<Void, Never>?

    init(cacheKey: String?, category: RefreshPolicy.Category, loader: @escaping (YouTubeService) async throws -> FeedPage) {
        self.cacheKey = cacheKey
        self.category = category
        self.loader = loader
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return !RefreshPolicy.isFresh(fetchedAt: fetchedAt, category: category)
    }

    /// First appearance: show cache, fetch if missing or stale.
    func loadIfNeeded(_ model: AppModel) async {
        if page == nil, let key = cacheKey, let cached = model.store.cachedPage(key, as: FeedPage.self) {
            var restored = cached.value
            restored.continuation = nil
            page = restored
            fetchedAt = cached.fetchedAt
            hasStaleContinuation = true
        }
        if page == nil || isStale {
            await refresh(model)
        }
    }

    /// Timer tick: refresh only when the TTL expired.
    func refreshIfStale(_ model: AppModel) async {
        guard !isLoading, isStale else { return }
        await refresh(model)
    }

    private var hasStaleContinuation = false

    func refresh(_ model: AppModel) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await model.api(loader)
            page = fresh
            error = nil
            moreError = nil
            fetchedAt = Date()
            hasStaleContinuation = false
            if let key = cacheKey { model.store.storePage(key, fresh) }
        } catch {
            if page == nil || !(page?.isEmpty == false) {
                self.error = BridgeError.wrap(error)
            } else {
                model.logs.append(.warn, "Background refresh failed: \(BridgeError.wrap(error).message)")
            }
        }
    }

    func loadMore(_ model: AppModel) async {
        if hasStaleContinuation {
            // A cached page from a previous launch can't be continued; refresh it once instead.
            hasStaleContinuation = false
            await refresh(model)
            return
        }
        guard !isLoadingMore, !isLoading, let key = page?.continuation else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await model.api { try await $0.more(key) }
            page?.append(next)
            moreError = nil
        } catch let error as BridgeError where error.kind == .expired {
            await refresh(model)
        } catch {
            moreError = BridgeError.wrap(error)
        }
    }

    func clear() {
        page = nil
        error = nil
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
        Group {
            if let page = feed.page {
                content(page)
            } else if let error = feed.error {
                ScrollView {
                    header
                    ErrorStateView(error: error) { Task { await feed.refresh(model) } }
                }
            } else {
                ScrollView {
                    header
                    LoadingView().frame(height: 500)
                }
            }
        }
        .task {
            await feed.loadIfNeeded(model)
            guard autoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await feed.refreshIfStale(model)
            }
        }
    }

    @ViewBuilder
    private func content(_ page: FeedPage) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 60) {
                header
                if page.isEmpty {
                    EmptyStateView(systemImage: "tray", text: emptyText)
                }
                ForEach(Array(page.sections.enumerated()), id: \.element.id) { index, section in
                    FeedSectionView(section: section, isLastSection: index == page.sections.count - 1) {
                        Task { await feed.loadMore(model) }
                    }
                }
                footer(page)
            }
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private func footer(_ page: FeedPage) -> some View {
        if feed.isLoadingMore {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
        } else if let error = feed.moreError {
            VStack(spacing: 16) {
                Text(error.userMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await feed.loadMore(model) } }
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        } else if page.continuation != nil {
            Button("Load more") { Task { await feed.loadMore(model) } }
                .frame(maxWidth: .infinity)
                .onAppear { Task { await feed.loadMore(model) } }
        } else {
            Button {
                Task { await feed.refresh(model) }
            } label: {
                Label(feed.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .frame(maxWidth: .infinity)
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
        let items = Array(section.items.enumerated())
        let loose = items.filter { !isShort($0.element) }
        let shorts = items.filter { isShort($0.element) }.map(\.element)
        return VStack(alignment: .leading, spacing: 40) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(loose, id: \.offset) { index, item in
                    FeedItemView(item: item)
                        .onAppear {
                            if isLastSection, index >= section.items.count - Layout.gridColumns * 2 { onNearEnd() }
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
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    FeedItemView(item: item)
                }
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 10)
        }
        .focusSection()
    }
}
