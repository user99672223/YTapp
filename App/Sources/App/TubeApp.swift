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
                ErrorStateView(error: error, secondary: reenterCookies) {
                    Task { await model.start() }
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

    /// Under Retry on a launch failure, when there are cookies to replace.
    private var reenterCookies: ErrorStateView.SecondaryAction? {
        guard model.isSignedIn else { return nil }
        return .init(title: "Re-enter cookies") { model.beginCookieReentry() }
    }
}

struct LaunchView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.section) {
            VStack(spacing: Theme.Spacing.titleToContent) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: Theme.heroSymbolSize * 1.5))
                    .foregroundStyle(.red)
                Text("Tube").font(.largeTitle.bold())
            }
            VStack(spacing: Theme.Spacing.titleToContent) {
                ProgressView()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.messageWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router

    // Six tabs with icon and text don't fit the tvOS tab bar at 1920 points: the last one was cut
    // off, and focusing it cut off the first. Subscriptions is shortened, and Search and Settings
    // show only their icon, as in Apple's own TV apps. The symbols are the plain (outline) ones,
    // so the bar can apply one variant to all of them.
    //
    // Up from a tab's content is the system's move: the focus engine picks a tab item it finds
    // in the direction of the move, which isn't always the selected one (tvOS then switches to
    // it), and the selected tab only when no item is in the way. The tab bar's items aren't
    // views the app can focus or give a default to, and focus sections and default focus in the
    // content only steer focus coming into it, so the app can't change this.
    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: router.path(for: .home)) { HomeView().withRoutes() }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            NavigationStack(path: router.path(for: .subscriptions)) { SubscriptionsView().withRoutes() }
                .tabItem { Label("Subs", systemImage: "rectangle.stack.badge.play") }
                .tag(AppTab.subscriptions)
            ShortsTabView()
                .tabItem { Label("Shorts", systemImage: "bolt.horizontal") }
                .tag(AppTab.shorts)
            NavigationStack(path: router.path(for: .search)) { SearchView().withRoutes() }
                .tabItem { Image(systemName: "magnifyingglass") }
                .tag(AppTab.search)
            NavigationStack(path: router.path(for: .library)) { LibraryView().withRoutes() }
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            NavigationStack(path: router.path(for: .settings)) { SettingsView() }
                .tabItem { Image(systemName: "gearshape") }
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
        HStack(spacing: Theme.Spacing.titleToContent) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.messageWidth, alignment: .leading)
            Button("Re-enter cookies") { model.beginCookieReentry() }
            Button("Dismiss") { model.authProblem = nil }
        }
        .floatingBox()
        .padding(.bottom, Theme.Spacing.floating)
    }
}
