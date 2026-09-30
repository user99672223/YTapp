import SwiftUI
import Core

/// Library: history, Watch Later, liked videos and the user's playlists, one at a time under a
/// picker. Each is the same list as the other tabs, with the same cards, loading, empty and
/// failure states.
struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case watchLater = "Watch Later"
        case liked = "Liked"
        case playlists = "Playlists"
        var id: String { rawValue }

        var emptyText: String {
            switch self {
            case .history: return "Your watch history is empty."
            case .watchLater: return "Watch Later is empty."
            case .liked: return "No liked videos yet."
            case .playlists: return "You have no playlists."
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var section: Section = .history
    @StateObject private var history = FeedModel(cacheKey: "history", category: .library) { try await $0.history() }
    @StateObject private var watchLater = FeedModel(cacheKey: "playlist:WL", category: .library) { try await $0.playlist("WL").page }
    @StateObject private var liked = FeedModel(cacheKey: "playlist:LL", category: .library) { try await $0.playlist("LL").page }
    @StateObject private var playlists = FeedModel(cacheKey: "playlists", category: .library) { try await $0.playlists() }

    var body: some View {
        Group {
            if model.isSignedIn {
                // One list for every section, with the picker as its header, as in Subs and on a
                // channel's page: it scrolls away with the cards, and it keeps its identity and
                // focus when the section changes, since FeedView just loads the other model.
                FeedView(feed: feed(for: section), emptyText: section.emptyText) {
                    Picker("Library", selection: $section) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 1000)
                    // Leading, above the list's first row, so Down from the picker reaches that
                    // row; the full-width focus section brings Up from any column back to it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }
            } else {
                VStack(spacing: Theme.Spacing.titleToContent) {
                    EmptyStateView(systemImage: "person.crop.circle.badge.exclamationmark",
                                   text: "Sign in to see your history, Watch Later, liked videos and playlists.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Sign in") { model.beginCookieReentry() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func feed(for section: Section) -> FeedModel {
        switch section {
        case .history: return history
        case .watchLater: return watchLater
        case .liked: return liked
        case .playlists: return playlists
        }
    }
}

/// A single playlist (also used for Watch Later / Liked from channel pages).
@MainActor
final class PlaylistModel: ObservableObject {
    @Published var info: PlaylistInfo?
    private(set) var feed: FeedModel!
    /// The feed cache holds only the videos; the title, channel and count are cached under this
    /// key so a cache hit (which skips the loader) still has a header.
    private let infoKey: String
    private weak var store: Store?

    init(playlistId: String) {
        infoKey = "playlist-info:\(playlistId)"
        feed = FeedModel(cacheKey: "playlist:\(playlistId)", category: .library) { [weak self] service in
            let page = try await service.playlist(playlistId)
            await MainActor.run { self?.update(page.info) }
            return page.page
        }
    }

    /// Called when the view appears (the model is created before the environment exists).
    func attach(_ store: Store) {
        guard self.store == nil else { return }
        self.store = store
        if let info {
            store.storePage(infoKey, info)
        } else if let cached = store.cachedPage(infoKey, as: PlaylistInfo.self) {
            info = cached.value
        }
    }

    private func update(_ info: PlaylistInfo) {
        self.info = info
        store?.storePage(infoKey, info)
    }
}

struct PlaylistView: View {
    @EnvironmentObject private var model: AppModel
    let title: String?
    @StateObject private var playlist: PlaylistModel

    init(playlistId: String, title: String?) {
        self.title = title
        _playlist = StateObject(wrappedValue: PlaylistModel(playlistId: playlistId))
    }

    var body: some View {
        FeedView(feed: playlist.feed, emptyText: "This playlist is empty.") {
            PlaylistHeader(playlist: playlist, feed: playlist.feed, title: title)
        }
        .onAppear { playlist.attach(model.store) }
    }
}

/// The playlist's artwork, title, channel and size, and Play for its first video (Tube plays one
/// video at a time; there is no play-all queue or shuffle to offer). Its own view observing the
/// feed: FeedView keeps the header value it was built with, so the header has to redraw by
/// itself when the videos arrive.
private struct PlaylistHeader: View {
    @EnvironmentObject private var router: Router
    @ObservedObject var playlist: PlaylistModel
    @ObservedObject var feed: FeedModel
    let title: String?

    /// Wider than a card in the grid below: it's the artwork of the whole page.
    private static let artworkWidth: CGFloat = 560

    var body: some View {
        let first = feed.page?.allItems.compactMap(\.video).first
        HStack(alignment: .top, spacing: Theme.Spacing.section) {
            // Watch Later and Liked have no artwork of their own: their first video's stands in.
            RemoteImage(url: playlist.info?.thumbnail.flatMap(URL.init(string:)) ?? first?.thumbnailURL)
                .frame(width: Self.artworkWidth, height: (Self.artworkWidth * 9 / 16).rounded())
                .continuousCorners(Theme.Radius.card)
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines * 2) {
                Text(displayTitle)
                    .font(.title2.bold())
                    .lineLimit(2)
                if !details.isEmpty {
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let first {
                    Button {
                        router.play(first)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.top, Theme.Spacing.titleToContent)
                }
            }
            // Every line at its full height: in a stack short of room, Text truncates with "…"
            // instead of wrapping.
            .fixedSize(horizontal: false, vertical: true)
        }
        // Full width, so Up from any column of the grid below comes back to Play.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// The playlist's own title (Watch Later and Liked get theirs once loaded), else the one its
    /// card showed; never blank.
    private var displayTitle: String {
        [playlist.info?.title, title].compactMap { $0 }.first { !$0.isEmpty } ?? "Playlist"
    }

    /// "Channel • 42 videos", leaving out what YouTube didn't send.
    private var details: String {
        [playlist.info?.channelName, playlist.info?.videoCountText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}
