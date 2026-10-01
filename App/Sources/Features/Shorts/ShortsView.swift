import SwiftUI
import Core

/// Shorts player (full screen, from the Shorts tab or a tapped Short).
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
        ShortsContent(vm: vm)
            .onAppear { vm.start() }
            .onDisappear { vm.close() }
    }
}

/// What can hold focus on the Shorts player.
enum ShortsFocus: Hashable {
    case video
    // The info column.
    case title, channel, subscribe
    case like, comments, more
    case menuDislike, menuChannel
    // The comments column.
    /// The line in place of the comments: loading, or "No comments yet."
    case commentsNote
    case commentsRetry
    case comment(String)
    case moreComments
    /// A piece of the open comment's text (`Comment.textChunks`).
    case threadText(Int)
    case reply(String)
    case repliesRetry
    case moreReplies

    /// In the info column (rows, buttons, the More menu).
    var isInInfoColumn: Bool {
        switch self {
        case .title, .channel, .subscribe, .like, .comments, .more, .menuDislike, .menuChannel:
            return true
        default:
            return false
        }
    }

    var isInMenu: Bool {
        self == .menuDislike || self == .menuChannel
    }
}

/// Measurements of the Shorts player on the Apple TV's 1920 × 1080-point screen, taken from
/// YouTube's own TV app: the video nearly as tall as the screen with its right edge at x 1200, so
/// a wider Short (4:5, square) grows to the left; the column of details from x 1255, 610 wide.
enum ShortsLayout {
    static let screen = CGSize(width: 1920, height: 1080)
    static let frameTop: CGFloat = 8
    static let frameHeight: CGFloat = 1064
    /// x of the video's right edge.
    static let frameTrailing: CGFloat = 1200
    static let frameRadius: CGFloat = 28
    /// The white ring around the focused video, outside its edge.
    static let borderWidth: CGFloat = 6
    /// The video view: as wide as the widest frame (square), so mpv's surface never changes size.
    /// mpv fits the picture into it, centred; the frame clips it to the Short's own shape.
    static let videoSize = CGSize(width: frameHeight, height: frameHeight)
    /// 9:16, until the Short's shape is known.
    static let defaultAspectRatio = 9.0 / 16.0

    static let columnLeading: CGFloat = 1255
    static let columnWidth: CGFloat = 610
    /// From the screen's bottom edge up to the round buttons' captions.
    static let buttonRowBottom: CGFloat = 50
    static let captionHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 12
    static let pillPadding: CGFloat = 24
    static let pillRadius: CGFloat = 18
    static let avatarSize: CGFloat = 52
    static let buttonSize: CGFloat = 72
    static let buttonSpacing: CGFloat = 24

    /// The comments column: its title this far below the screen's top edge, the list running to
    /// the screen's bottom edge.
    static let commentsTop: CGFloat = 52
    static let headerToList: CGFloat = 28
    static let cardSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 24
    static let cardRadius: CGFloat = 16
    static let listBottom: CGFloat = 60

    /// The video's frame for a Short of this shape (width / height).
    static func frame(aspectRatio: Double?) -> CGRect {
        let ratio = min(1, max(0.5, aspectRatio ?? defaultAspectRatio))
        // Rounded down: mpv fits the picture to the height, so a frame half a point wider
        // would show a hairline of black at its edge.
        let width = (frameHeight * CGFloat(ratio)).rounded(.down)
        return CGRect(x: frameTrailing - width, y: frameTop, width: width, height: frameHeight)
    }
}

/// The Shorts player, laid out like YouTube's own TV app: the current Short in a tall rounded
/// frame over a dark colour taken from it, its details and buttons in a column to the right.
///
/// The remote: focus starts on the video. Up/Down page to the previous/next Short (the outgoing
/// one slides out at the top while the next comes in from below, as posters; then the video),
/// Select and Play/Pause pause, Right moves into the column (to the like button). In the column
/// Up/Down move between the rows and the buttons, Left/Right between the buttons, and Left from
/// its left edge goes back to the video. Back steps out one level at a time: replies → comments →
/// the column (focus on the comments button) → the video → closes the player.
private struct ShortsContent: View {
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var vm: ShortsViewModel
    @StateObject private var palette = ShortsPalette()

    @FocusState private var focus: ShortsFocus?
    @State private var commentsOpen = false
    @State private var menuOpen = false
    @State private var titleExpanded = false
    /// The position whose page is on screen; it follows `vm.index` with the paging slide.
    @State private var shownIndex = 0
    /// Where the next page comes in from: the bottom going forward, the top going back.
    @State private var insertionEdge: Edge = .bottom
    /// A page change is sliding; the video and the column wait until it settled.
    @State private var isPaging = false
    @State private var pageSerial = 0
    /// The background colour; it stays while the next Short's isn't known yet.
    @State private var backdrop = ShortsSwatch.neutral

    private static let pageAnimation = Animation.smooth(duration: 0.33)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(backdrop.color)
                .animation(.easeInOut(duration: 0.45), value: backdrop)
            pages
            video
            playbackStatus
            frameButton
            column
                .disabled(isFailed)
            if case .failed(let error) = vm.phase {
                failure(error)
            }
            toast
        }
        .frame(width: ShortsLayout.screen.width, height: ShortsLayout.screen.height, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: vm.toast)
        .defaultFocus($focus, .video)
        .onPlayPauseCommand { vm.togglePlay() }
        .onExitCommand { back() }
        .onChange(of: vm.index) { _, newIndex in
            page(to: newIndex)
            prepareArtwork()
        }
        .onChange(of: vm.ids.count) { _, _ in prepareArtwork() }
        .onChange(of: vm.current?.id) { _, _ in prepareArtwork() }
        .onChange(of: currentSwatch) { _, swatch in
            if let swatch { backdrop = swatch }
        }
        .onChange(of: focus) { _, newFocus in
            // The More menu closes once focus leaves it (its own button keeps it open).
            if menuOpen, newFocus != .more, newFocus?.isInMenu != true {
                menuOpen = false
            }
        }
        .onChange(of: isFailed) { _, failed in
            if failed {
                // The failure covers everything; its buttons take focus.
                commentsOpen = false
                menuOpen = false
            } else {
                focus = .video
            }
        }
        .onAppear {
            shownIndex = vm.index
            focus = .video
            prepareArtwork()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.pause() }
        }
    }

    private var isFailed: Bool {
        if case .failed = vm.phase { return true }
        return false
    }

    private var currentSwatch: ShortsSwatch? {
        palette.swatch(for: shortId(at: vm.index))
    }

    private func shortId(at position: Int) -> String? {
        vm.ids.indices.contains(position) ? vm.ids[position] : nil
    }

    /// The frame of the Short at `position`: its streams' shape, else its poster's.
    private func videoFrame(at position: Int) -> CGRect {
        ShortsLayout.frame(aspectRatio: vm.aspectRatio(at: position) ?? palette.swatch(for: shortId(at: position))?.aspectRatio)
    }

    // MARK: - Video

    /// The page on screen: the Short's poster in its frame. Paging replaces it, with the outgoing
    /// page sliding out at one edge of the screen while the new one comes in at the other.
    private var pages: some View {
        ZStack(alignment: .topLeading) {
            if let pageId = shortId(at: shownIndex) {
                ShortsPage(poster: vm.poster(at: shownIndex), fallback: vm.posterFallback(at: shownIndex),
                           frame: videoFrame(at: shownIndex), showsBorder: focus == .video)
                    .id(pageId)
                    .transition(.asymmetric(insertion: .move(edge: insertionEdge),
                                            removal: .move(edge: insertionEdge == .bottom ? .top : .bottom)))
            }
        }
        .frame(width: ShortsLayout.screen.width, height: ShortsLayout.screen.height, alignment: .topLeading)
    }

    /// The one video view, over the current page. It never moves with the slide (mpv keeps its
    /// surface) and never changes size: it's centred on the frame and clipped to it. Shown once
    /// mpv has the Short's first frame and the slide settled.
    private var video: some View {
        let rect = videoFrame(at: vm.index)
        let shows = vm.isVideoOnScreen && !isPaging && shownIndex == vm.index
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .overlay {
                MPVVideoView(player: vm.player)
                    .frame(width: ShortsLayout.videoSize.width, height: ShortsLayout.videoSize.height)
            }
            .continuousCorners(ShortsLayout.frameRadius)
            .position(x: rect.midX, y: rect.midY)
            .opacity(shows ? 1 : 0)
            // Fades in over the poster; hides at once when paging, so it never covers the slide.
            .animation(shows ? .easeOut(duration: 0.2) : nil, value: shows)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var playbackStatus: some View {
        let rect = videoFrame(at: vm.index)
        return ZStack {
            if vm.ids.isEmpty, case .loading(let message) = vm.phase {
                LoadingView(message: message)
            } else if !isPaging {
                PlaybackStatus(player: vm.player.state, phase: vm.phase, isVideoOnScreen: vm.isVideoOnScreen)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }

    /// What holds focus for the video: a plain button over its frame (not around the live video:
    /// the card style's lift around mpv's view was what threw the old pager out of place). Its
    /// focus shows as the white ring the page draws. Select pauses; Up/Down page (nothing is
    /// above or below it, so focus never moves away).
    private var frameButton: some View {
        let rect = videoFrame(at: vm.index)
        return Button {
            vm.togglePlay()
        } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(ShortsFrameStyle())
        .focusEffectDisabled()
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .focused($focus, equals: .video)
        .onMoveCommand { direction in
            switch direction {
            case .up: vm.previous()
            case .down: vm.next()
            default: break  // Right: the focus engine moves into the column.
            }
        }
        .accessibilityLabel(vm.current?.title ?? "Short")
        .accessibilityHint("Up and down change the Short")
        .disabled(isFailed)
    }

    /// Slides to `newIndex`. The outgoing page takes its removal transition from its last update,
    /// so a change of direction is set one update before the slide.
    private func page(to newIndex: Int) {
        guard newIndex != shownIndex else { return }
        pageSerial += 1
        isPaging = true
        commentsOpen = false
        menuOpen = false
        titleExpanded = false
        if let swatch = currentSwatch { backdrop = swatch }
        let edge: Edge = newIndex > shownIndex ? .bottom : .top
        if edge != insertionEdge {
            insertionEdge = edge
            DispatchQueue.main.async { slide() }
        } else {
            slide()
        }
    }

    private func slide() {
        let serial = pageSerial
        withAnimation(Self.pageAnimation) {
            shownIndex = vm.index
        } completion: {
            if serial == pageSerial { isPaging = false }
        }
    }

    /// The colours, shapes and posters of the Shorts around the current one, so a page that
    /// slides in has them at once.
    private func prepareArtwork() {
        guard !vm.ids.isEmpty else { return }
        let lower = max(0, vm.index - 1)
        let upper = min(vm.ids.count - 1, vm.index + 2)
        guard lower <= upper else { return }
        for position in lower...upper {
            palette.load(id: vm.ids[position], poster: vm.poster(at: position), fallback: vm.posterFallback(at: position))
            if position != vm.index, let url = vm.poster(at: position) {
                let size = videoFrame(at: position).size
                ImagePipeline.shared.prefetch(url, pixels: CGSize(width: (size.width * displayScale).rounded(.up),
                                                                  height: (size.height * displayScale).rounded(.up)))
            }
        }
    }

    // MARK: - Column

    private var column: some View {
        ZStack(alignment: .topLeading) {
            ShortsInfoColumn(vm: vm, comments: vm.comments, focus: $focus,
                             isActive: focus?.isInInfoColumn == true, menuOpen: menuOpen,
                             titleExpanded: $titleExpanded,
                             openComments: openComments, toggleMenu: toggleMenu, openChannel: openChannel)
                .opacity(commentsOpen || isPaging ? 0 : 1)
                .disabled(commentsOpen)
                .focusSection()
                // Coming over from the video lands on the like button, as in YouTube's app.
                .defaultFocus($focus, .like, priority: .userInitiated)
            if commentsOpen {
                ShortsCommentsColumn(comments: vm.comments, countText: vm.current?.commentsCountText,
                                     focus: $focus, moveFocus: moveFocus)
                    // Gone at once when closed: a focused card that lingers through a fade-out
                    // kept focus from reaching the comments button.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: commentsOpen)
        .animation(.easeOut(duration: 0.2), value: isPaging)
        .frame(width: ShortsLayout.columnWidth, height: ShortsLayout.screen.height, alignment: .topLeading)
        .position(x: ShortsLayout.columnLeading + ShortsLayout.columnWidth / 2, y: ShortsLayout.screen.height / 2)
    }

    private func openComments() {
        menuOpen = false
        commentsOpen = true
        moveFocus(ShortsCommentsColumn.firstFocus(in: vm.comments))
    }

    private func closeComments() {
        let wasInComments = focus != .video
        vm.comments.closeThread()
        commentsOpen = false
        if wasInComments { moveFocus(.comments) }
    }

    private func toggleMenu() {
        if menuOpen {
            menuOpen = false
        } else {
            menuOpen = true
            moveFocus(.menuDislike)
        }
    }

    private func openChannel() {
        guard let channelId = vm.current?.channel.id else { return }
        vm.close()
        router.open(.channel(channelId))
    }

    /// Back: one level at a time (see the type's comment).
    private func back() {
        if commentsOpen {
            if let thread = vm.comments.thread, focus != .video {
                vm.comments.closeThread()
                moveFocus(.comment(thread.comment.id))
            } else {
                closeComments()
            }
        } else if menuOpen {
            menuOpen = false
            moveFocus(.more)
        } else if let focus, focus != .video {
            moveFocus(.video)
        } else {
            vm.close()
            router.shorts = nil
        }
    }

    /// Moves focus to `target`, and again over the next half second while it hasn't arrived: a
    /// view that only just became focusable (its column was hidden or disabled in the same
    /// update) can't take focus at once, and meanwhile the focus engine puts it on the video.
    private func moveFocus(_ target: ShortsFocus) {
        focus = target
        Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard focus != target else { return }
                focus = target
            }
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var toast: some View {
        if let message = vm.toast {
            ToastView(text: message)
                .frame(width: ShortsLayout.columnWidth)
                .position(x: ShortsLayout.columnLeading + ShortsLayout.columnWidth / 2, y: 100)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func failure(_ error: BridgeError) -> some View {
        VStack(spacing: Theme.Spacing.row) {
            ErrorStateView(error: error) { vm.retry() }
            HStack(spacing: Theme.Spacing.row) {
                if !vm.ids.isEmpty {
                    Button("Next Short") { vm.next() }
                }
                Button("Close") {
                    vm.close()
                    router.shorts = nil
                }
            }
            .padding(.bottom, Theme.Spacing.section)
        }
        .frame(width: ShortsLayout.screen.width, height: ShortsLayout.screen.height)
        .background(Color.black.opacity(0.85))
        .focusSection()
    }
}

/// The focus target over the video: draws nothing itself (the page draws the focus ring).
private struct ShortsFrameStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// One Short's page: its poster in its frame, and the white ring while the video has focus. As
/// big as the screen, so the paging slide moves it fully out of view.
private struct ShortsPage: View {
    let poster: URL?
    let fallback: URL?
    let frame: CGRect
    let showsBorder: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShortsPosterImage(url: poster, fallback: fallback, size: frame.size)
                .continuousCorners(ShortsLayout.frameRadius)
                .overlay {
                    RoundedRectangle(cornerRadius: ShortsLayout.frameRadius + ShortsLayout.borderWidth, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: ShortsLayout.borderWidth)
                        .padding(-ShortsLayout.borderWidth)
                        .opacity(showsBorder ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: showsBorder)
                }
                .position(x: frame.midX, y: frame.midY)
                .animation(.easeInOut(duration: 0.25), value: frame)
        }
        .frame(width: ShortsLayout.screen.width, height: ShortsLayout.screen.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Spinner while the current Short loads or stalls, a play symbol while it's paused.
private struct PlaybackStatus: View {
    @ObservedObject var player: MPVPlayer.State
    let phase: ShortsViewModel.Phase
    let isVideoOnScreen: Bool

    var body: some View {
        Group {
            if phase == .playing, isVideoOnScreen, player.isPaused {
                Image(systemName: "play.fill")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(40)
                    .background(.ultraThinMaterial, in: Circle())
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else if isLoading {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: player.isPaused)
    }

    private var isLoading: Bool {
        switch phase {
        case .loading: return true
        case .failed: return false
        case .playing: return !player.isPaused && (!isVideoOnScreen || player.isBuffering)
        }
    }
}
