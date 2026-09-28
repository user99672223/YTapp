import SwiftUI
import AVFoundation
import Core

@main
struct TubeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var router = Router()

    init() {
        // Video playback app: play audio even with the silent switch / other apps' audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                LaunchView(message: "Starting…")
            case .connecting(let message):
                LaunchView(message: message)
            case .needsSetup:
                SetupView()
            case .failed(let error):
                VStack(spacing: 40) {
                    ErrorStateView(error: error) {
                        Task { await model.start() }
                    }
                    if model.isSignedIn {
                        Button("Re-enter cookies") { model.beginCookieReentry() }
                    }
                }
            case .ready:
                MainTabView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // tvOS may terminate the app once it's in the background: save rotated cookies now.
            if phase != .active { model.cookies.flush() }
        }
    }
}

struct LaunchView: View {
    let message: String

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 120))
                .foregroundStyle(.red)
            Text("Tube").font(.largeTitle.bold())
            ProgressView()
            Text(message).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: router.path(for: .home)) { HomeView().withRoutes() }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            NavigationStack(path: router.path(for: .subscriptions)) { SubscriptionsView().withRoutes() }
                .tabItem { Label("Subscriptions", systemImage: "rectangle.stack.badge.play") }
                .tag(AppTab.subscriptions)
            ShortsTabView()
                .tabItem { Label("Shorts", systemImage: "bolt.horizontal.fill") }
                .tag(AppTab.shorts)
            NavigationStack(path: router.path(for: .search)) { SearchView().withRoutes() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            NavigationStack(path: router.path(for: .library)) { LibraryView().withRoutes() }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            NavigationStack(path: router.path(for: .settings)) { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .fullScreenCover(item: $router.watch) { request in
            WatchView(request: request)
                .environmentObject(model)
                .environmentObject(router)
        }
        .fullScreenCover(item: $router.shorts) { request in
            ShortsPlayerView(seedId: request.seedId, isFullScreen: true)
                .environmentObject(model)
                .environmentObject(router)
        }
        .overlay(alignment: .bottom) {
            if let problem = model.authProblem {
                AuthBanner(message: problem)
            }
        }
    }
}

struct AuthBanner: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    let message: String

    var body: some View {
        HStack(spacing: 30) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.callout)
            Button("Re-enter cookies") { model.beginCookieReentry() }
            Button("Dismiss") { model.authProblem = nil }
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.bottom, 40)
    }
}
