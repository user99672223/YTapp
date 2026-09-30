import SwiftUI
import Core

/// The Shorts tab: a launcher for the full-screen endless feed plus the Shorts from Home.
/// (The player itself is full screen so up/down never fights with the tab bar.)
struct ShortsTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    @StateObject private var home = FeedModel(cacheKey: "home", category: .home) { try await $0.home() }
    @State private var contentWidth: CGFloat = Layout.defaultContentWidth

    /// The columns fill the width between the margins exactly, so both sides match.
    private var shortWidth: CGFloat {
        Layout.columnWidth(in: contentWidth, count: Layout.shortColumns, spacing: Layout.shortSpacing)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(shortWidth), spacing: Layout.shortSpacing, alignment: .top), count: Layout.shortColumns)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                Button {
                    router.shorts = ShortsRequest(seedId: nil)
                } label: {
                    Label("Play Shorts", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ContentWidthReader(width: $contentWidth))
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, 40)
        }
        .task { await home.loadIfNeeded(model) }
    }

    @ViewBuilder
    private var content: some View {
        if let shorts = home.page?.shorts, !shorts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
                Text("From your Home feed").font(.title3.bold())
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.section) {
                    ForEach(shorts, id: \.id) { short in
                        ShortCard(video: short, width: shortWidth)
                    }
                }
            }
        } else if let error = home.error {
            ErrorStateView(error: error, isRetrying: home.isLoading) {
                Task { await home.refresh(model, userInitiated: true) }
            }
            .frame(height: 500)
        } else if home.page == nil || home.isLoading {
            LoadingView().frame(height: 500)
        } else {
            EmptyStateView(systemImage: "bolt.horizontal", text: "Your Home feed has no Shorts right now.")
                .frame(height: 500)
        }
    }
}

/// Shorts player (tab or full screen from a tapped Short).
struct ShortsPlayerView: View {
    @EnvironmentObject private var model: AppModel
    let seedId: String?
    let isFullScreen: Bool

    var body: some View {
        ShortsScreen(seedId: seedId, model: model, isFullScreen: isFullScreen)
    }
}

private struct ShortsScreen: View {
    @StateObject private var vm: ShortsViewModel
    let isFullScreen: Bool

    init(seedId: String?, model: AppModel, isFullScreen: Bool) {
        _vm = StateObject(wrappedValue: ShortsViewModel(seedId: seedId, model: model))
        self.isFullScreen = isFullScreen
    }

    var body: some View {
        ShortsContent(vm: vm, player: vm.player.state, isFullScreen: isFullScreen)
            .onAppear { vm.start() }
            .onDisappear { vm.close() }
    }
}

private struct ShortsContent: View {
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var vm: ShortsViewModel
    @ObservedObject var player: MPVPlayer.State
    let isFullScreen: Bool
    @State private var showComments = false
    @FocusState private var focusedLike: Bool

    private let videoHeight: CGFloat = 1080
    private var videoWidth: CGFloat { videoHeight * 9 / 16 }

    var body: some View {
        ZStack {
            background
            HStack(spacing: 0) {
                Spacer()
                ZStack {
                    Color.black
                    MPVVideoView(player: vm.player)
                    if case .loading(let message) = vm.phase {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text(message).font(.caption)
                        }
                    } else if vm.phase == .playing, player.isBuffering || !player.isFileLoaded {
                        ProgressView()
                    }
                    if player.isPaused, vm.phase == .playing, player.isFileLoaded {
                        Image(systemName: "pause.fill").font(.system(size: 90)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: videoWidth, height: videoHeight)
                .clipped()
                overlay
                    .frame(width: 620)
                    .padding(.leading, 40)
                Spacer()
            }
            .ignoresSafeArea()

            if case .failed(let error) = vm.phase {
                VStack(spacing: 20) {
                    ErrorStateView(error: error) { vm.retry() }
                    HStack(spacing: 30) {
                        Button("Next Short") { vm.next() }
                        Button("Close") { router.shorts = nil }
                    }
                }
                .background(Color.black.opacity(0.85))
            }

            if showComments {
                HStack {
                    Spacer()
                    CommentsPanel(comments: vm.comments, close: { showComments = false })
                    .frame(width: Theme.panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .focusSection()
                }
                .ignoresSafeArea()
                .transition(.move(edge: .trailing))
            }

            if let toast = vm.toast {
                VStack {
                    Text(toast)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 50)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showComments)
        .onPlayPauseCommand { vm.togglePlay() }
        .onExitCommand {
            if showComments {
                showComments = false
            } else {
                vm.close()
                router.shorts = nil
            }
        }
        .onAppear { focusedLike = true }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.pause() }
        }
    }

    private var background: some View {
        ZStack {
            Color.black
            if let thumb = vm.current?.thumbnail, let url = URL(string: thumb) {
                RemoteImage(url: url)
                    .blur(radius: 60)
                    .overlay(Color.black.opacity(0.45))
            }
        }
        .ignoresSafeArea()
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            if let short = vm.current {
                Text(short.title).font(.title3.bold()).lineLimit(4)
                Text([short.channel.name, short.viewCountText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                    .foregroundStyle(.secondary)
            }
            // One horizontal row: up/down never moves focus, so they switch Shorts.
            HStack(spacing: 18) {
                Button {
                    vm.rate(.like)
                } label: {
                    Image(systemName: vm.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .focused($focusedLike)
                .onMoveCommand(perform: move)
                Button {
                    vm.rate(.dislike)
                } label: {
                    Image(systemName: vm.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .onMoveCommand(perform: move)
                Button {
                    showComments = true
                } label: {
                    Image(systemName: "text.bubble")
                }
                .onMoveCommand(perform: move)
                if vm.current?.channel.id != nil {
                    Button {
                        vm.toggleSubscription()
                    } label: {
                        Text(vm.isSubscribed == true ? "Subscribed" : "Subscribe")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .tint(vm.isSubscribed == true ? .gray : .red)
                    .onMoveCommand(perform: move)
                    Button {
                        if let id = vm.current?.channel.id {
                            vm.close()
                            router.open(.channel(id))
                        }
                    } label: {
                        Image(systemName: "person.crop.square")
                    }
                    .onMoveCommand(perform: move)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down")
                Text("Swipe up or down for the next Short")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 80)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .down: vm.next()
        case .up: vm.previous()
        default: break
        }
    }
}
