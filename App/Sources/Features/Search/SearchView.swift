import SwiftUI
import Core

/// Search with live suggestions, filters and paged results. The filter chips and the results
/// start at the lists' margin (`Layout.horizontalPadding` inside tvOS's safe area), like every
/// other screen; with no margin of its own that is also where the system puts the search field's
/// suggestion chips, so the whole screen shares one leading edge. The filters are the results
/// list's header, like the pickers on Subs and Library: they scroll away with the results, which
/// then get the whole screen once the search field and keyboard have moved off it, and Up from
/// the first row of results brings them back.
struct SearchView: View {
    /// The filter menus, so focus can be put back on one.
    private enum Filter: Hashable { case uploadDate, type, duration, sort }

    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var submitted: String?
    @State private var filters = SearchFilters()
    @State private var results: FeedModel?
    /// The filters `results` was searched with.
    @State private var searchedFilters: SearchFilters?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focusedFilter: Filter?

    var body: some View {
        // A stack that stays put whichever state shows, so the search field and its modifiers
        // below keep their identity (and focus) when the first results arrive.
        VStack(alignment: .leading, spacing: 0) {
            if let results, let query = submitted {
                // The scroll view is the whole screen's content, so it reaches up under the
                // search field and keyboard, and the results scroll up into the room they leave
                // instead of sliding under chips pinned in the middle of the screen. No .id on
                // it: FeedView loads whichever model it's handed, so a new search or a changed
                // filter keeps the header, and the focused filter menu, in place. FeedView shows
                // the loading, no-results and error (with Retry) states under the filters, and
                // lays channels, videos and playlists out in the same grid as every other list.
                FeedView(feed: results, emptyText: noResultsText(for: query), autoRefresh: false, emptySystemImage: "magnifyingglass") {
                    filterBar
                        // Full width and its own focus section, so Up from any column of results
                        // comes back to the filters.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                }
            } else {
                EmptyStateView(systemImage: "magnifyingglass", text: "Search YouTube")
            }
        }
        .searchable(text: $text, prompt: "Videos, channels, playlists")
        // tvOS shows these as its own row of chips under the keyboard; picking one fills in the
        // field and searches at once.
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { suggestion in
                Text(suggestion).searchCompletion(suggestion)
            }
        }
        .onSubmit(of: .search) { run(text) }
        .onChange(of: text) { _, newValue in
            scheduleSuggestions(for: newValue)
            scheduleSearch(for: newValue)
        }
        .onChange(of: filters) { _, _ in
            if let submitted { run(submitted) }
        }
    }

    /// A search that found nothing says whether filters narrowed it (Clear filters is right above).
    private func noResultsText(for query: String) -> String {
        if let searchedFilters, !searchedFilters.isDefault {
            return "No results for “\(query)” with these filters."
        }
        return "No results for “\(query)”."
    }

    /// Every filter is a capsule in the system's button look (it lifts and turns white when
    /// focused) that names its current choice; Select opens the choices, with a checkmark on the
    /// current one.
    private var filterBar: some View {
        HStack(spacing: Theme.Spacing.row) {
            Menu {
                Picker("Upload date", selection: $filters.uploadDate) {
                    Text("Any time").tag(SearchFilters.UploadDate.all)
                    Text("Today").tag(SearchFilters.UploadDate.today)
                    Text("This week").tag(SearchFilters.UploadDate.week)
                    Text("This month").tag(SearchFilters.UploadDate.month)
                    Text("This year").tag(SearchFilters.UploadDate.year)
                }
            } label: {
                Label(label(for: filters.uploadDate), systemImage: "calendar")
            }
            .focused($focusedFilter, equals: .uploadDate)
            Menu {
                Picker("Type", selection: $filters.type) {
                    Text("All types").tag(SearchFilters.ResultType.all)
                    Text("Videos").tag(SearchFilters.ResultType.video)
                    Text("Shorts").tag(SearchFilters.ResultType.shorts)
                    Text("Channels").tag(SearchFilters.ResultType.channel)
                    Text("Playlists").tag(SearchFilters.ResultType.playlist)
                }
            } label: {
                Label(label(for: filters.type), systemImage: "square.grid.2x2")
            }
            .focused($focusedFilter, equals: .type)
            Menu {
                Picker("Duration", selection: $filters.duration) {
                    Text("Any length").tag(SearchFilters.Duration.all)
                    Text("Under 3 minutes").tag(SearchFilters.Duration.short)
                    Text("3–20 minutes").tag(SearchFilters.Duration.medium)
                    Text("Over 20 minutes").tag(SearchFilters.Duration.long)
                }
            } label: {
                Label(label(for: filters.duration), systemImage: "clock")
            }
            .focused($focusedFilter, equals: .duration)
            Menu {
                Picker("Sort by", selection: $filters.prioritize) {
                    Text("Relevance").tag(SearchFilters.Prioritize.relevance)
                    Text("Popularity").tag(SearchFilters.Prioritize.popularity)
                }
            } label: {
                Label(filters.prioritize == .relevance ? "Relevance" : "Popularity", systemImage: "arrow.up.arrow.down")
            }
            .focused($focusedFilter, equals: .sort)
            if !filters.isDefault {
                Button {
                    filters = SearchFilters()
                    // The button goes away with the filters it cleared: hand focus to the menu
                    // next to it rather than letting it jump somewhere else on the screen.
                    focusedFilter = .sort
                } label: {
                    Label("Clear filters", systemImage: "xmark")
                }
            }
        }
        .lineLimit(1)
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func label(for type: SearchFilters.ResultType) -> String {
        switch type {
        case .all: return "All types"
        case .video: return "Videos"
        case .shorts: return "Shorts"
        case .channel: return "Channels"
        case .playlist: return "Playlists"
        case .movie: return "Movies"
        }
    }

    private func label(for date: SearchFilters.UploadDate) -> String {
        switch date {
        case .all: return "Any time"
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        }
    }

    private func label(for duration: SearchFilters.Duration) -> String {
        switch duration {
        case .all: return "Any length"
        case .short: return "Under 3 min"
        case .medium: return "3–20 min"
        case .long: return "Over 20 min"
        }
    }

    private func run(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let currentFilters = filters
        // The same search again (picking a suggestion also changes the text) keeps the results
        // and the user's place instead of starting over.
        if results != nil, q == submitted, currentFilters == searchedFilters { return }
        searchTask?.cancel()
        submitted = q
        searchedFilters = currentFilters
        results = FeedModel(cacheKey: nil, category: .search) { try await $0.search(q, filters: currentFilters) }
    }

    /// The Siri Remote's on-screen keyboard has no Search key, so typing searches by itself once
    /// the text stops changing. (Return on a keyboard and picking a suggestion still search at once.)
    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            submitted = nil
            results = nil
            searchedFilters = nil
            return
        }
        guard query.count >= 2 else { return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            run(query)
        }
    }

    private func scheduleSuggestions(for value: String) {
        suggestionTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            suggestions = []
            return
        }
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if let list = try? await model.api({ try await $0.searchSuggestions(query) }), !Task.isCancelled {
                suggestions = list
            }
        }
    }
}
