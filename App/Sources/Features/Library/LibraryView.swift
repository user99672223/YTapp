import SwiftUI
import Core

/// Library: history, Watch Later, liked videos and the user's playlists.
struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case history = "History"
        case watchLater = "Watch Later"
        case liked = "Liked"
        case playlists = "Playlists"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var section: Section = .history
    @StateObject private var history = FeedModel(cacheKey: "history", category: .library) { try await $0.history() }
    @StateObject private var watchLater = FeedModel(cacheKey: "playlist:WL", category: .library) { try await $0.playlist("WL").page }
    @StateObject private var liked = FeedModel(cacheKey: "playlist:LL", category: .library) { try await $0.playlist("LL").page }
    @StateObject private var playlists = FeedModel(cacheKey: "playlists", category: .library) { try await $0.playlists() }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 1000)
            .padding(.top, 20)
            if !model.isSignedIn {
                EmptyStateView(systemImage: "person.crop.circle.badge.exclamationmark", text: "Sign in (Settings → Re-enter cookies) to see your library.")
            } else {
                switch section {
                case .history: FeedView(feed: history, emptyText: "Your watch history is empty.")
                case .watchLater: FeedView(feed: watchLater, emptyText: "Watch Later is empty.")
                case .liked: FeedView(feed: liked, emptyText: "No liked videos yet.")
                case .playlists: FeedView(feed: playlists, emptyText: "You have no playlists.")
                }
            }
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

/// Its own view observing the feed: FeedView keeps the header value it was built with, so the
/// Play button has to redraw by itself when the videos arrive.
private struct PlaylistHeader: View {
    @EnvironmentObject private var router: Router
    @ObservedObject var playlist: PlaylistModel
    @ObservedObject var feed: FeedModel
    let title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(playlist.info?.title ?? title ?? "Playlist").font(.title.bold())
            Text([playlist.info?.channelName, playlist.info?.videoCountText].compactMap { $0 }.joined(separator: " • "))
                .foregroundStyle(.secondary)
            if let first = feed.page?.allItems.compactMap(\.video).first {
                Button {
                    router.play(first)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
            }
        }
    }
}
