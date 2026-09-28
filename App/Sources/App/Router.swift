import SwiftUI
import Core

enum AppTab: String, Hashable, CaseIterable {
    case home, subscriptions, shorts, search, library, settings
}

enum Route: Hashable {
    case channel(String)
    case playlist(id: String, title: String?)
}

struct WatchRequest: Identifiable, Equatable {
    let id = UUID()
    let videoId: String
    let title: String?
}

struct ShortsRequest: Identifiable, Equatable {
    let id = UUID()
    let seedId: String?
}

/// Navigation state: tab selection, per-tab stacks and the full-screen players.
@MainActor
final class Router: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var paths: [AppTab: [Route]] = [:]
    @Published var watch: WatchRequest?
    @Published var shorts: ShortsRequest?

    func path(for tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    func play(_ video: VideoItem) {
        if video.isShort {
            shorts = ShortsRequest(seedId: video.id)
        } else {
            watch = WatchRequest(videoId: video.id, title: video.title)
        }
    }

    func play(videoId: String) {
        watch = WatchRequest(videoId: videoId, title: nil)
    }

    func open(_ route: Route) {
        watch = nil
        shorts = nil
        let tab = selectedTab == .shorts || selectedTab == .settings ? .home : selectedTab
        selectedTab = tab
        paths[tab, default: []].append(route)
    }
}

extension View {
    /// Destinations for channel and playlist pages inside a tab's NavigationStack.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .channel(let id):
                ChannelView(channelId: id)
            case .playlist(let id, let title):
                PlaylistView(playlistId: id, title: title)
            }
        }
    }
}
