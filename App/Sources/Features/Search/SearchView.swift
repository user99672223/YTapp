import SwiftUI
import Core

/// Search with live suggestions, filters and paged results.
struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var submitted: String?
    @State private var filters = SearchFilters()
    @State private var results: FeedModel?
    @State private var suggestionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let results, let query = submitted {
                FeedView(feed: results, emptyText: "No results for “\(query)”.", autoRefresh: false) {
                    filterBar
                }
                .id(query + String(describing: filters))
            } else {
                EmptyStateView(systemImage: "magnifyingglass", text: "Search YouTube")
            }
        }
        .searchable(text: $text, prompt: "Videos, channels, playlists")
        .searchSuggestions {
            ForEach(suggestions, id: \.self) { suggestion in
                Text(suggestion).searchCompletion(suggestion)
            }
        }
        .onSubmit(of: .search) { run(text) }
        .onChange(of: text) { _, newValue in
            scheduleSuggestions(for: newValue)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 24) {
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
            Menu {
                Picker("Type", selection: $filters.type) {
                    Text("All").tag(SearchFilters.ResultType.all)
                    Text("Videos").tag(SearchFilters.ResultType.video)
                    Text("Shorts").tag(SearchFilters.ResultType.shorts)
                    Text("Channels").tag(SearchFilters.ResultType.channel)
                    Text("Playlists").tag(SearchFilters.ResultType.playlist)
                }
            } label: {
                Label(filters.type == .all ? "All types" : filters.type.rawValue.capitalized, systemImage: "square.grid.2x2")
            }
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
            Menu {
                Picker("Sort", selection: $filters.prioritize) {
                    Text("Relevance").tag(SearchFilters.Prioritize.relevance)
                    Text("Popularity").tag(SearchFilters.Prioritize.popularity)
                }
            } label: {
                Label(filters.prioritize == .relevance ? "Relevance" : "Popularity", systemImage: "arrow.up.arrow.down")
            }
            if !filters.isDefault {
                Button("Clear filters") { filters = SearchFilters() }
            }
        }
        .onChange(of: filters) { _, _ in
            if let submitted { run(submitted) }
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
        submitted = q
        let currentFilters = filters
        results = FeedModel(cacheKey: nil, category: .search) { try await $0.search(q, filters: currentFilters) }
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
