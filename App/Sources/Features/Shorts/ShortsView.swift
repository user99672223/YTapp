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
        ShortsContent(vm: vm, isFullScreen: isFullScreen)
            .onAppear { vm.start() }
            .onDisappear { vm.close() }
    }
}

/// What can hold focus on the Shorts player.
private enum ShortsFocus: Hashable {
    case video, subscribe, like, dislike, comments, channel
}

/// The Shorts player: the current Short in a rounded 9:16 frame over a blurred backdrop of its
/// poster, with its actions in a column to the right.
///
/// The remote: the video holds focus. Up/Down (click or swipe) page to the previous/next Short,
/// Select and Play/Pause pause, Right moves into the action column, Left jumps to the Subscribe
/// pill at the video's bottom left. In the column Up/Down move between the buttons and Left goes
/// back to the video, which pages again: the column is short, so paging from there would make
/// every Up/Down a guess between "next button" and "next Short". Back closes the comments panel
/// (focus returns to its button), otherwise the player.
private struct ShortsContent: View {
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var vm: ShortsViewModel
    let isFullScreen: Bool

    @FocusState private var focus: ShortsFocus?
    @State private var showComments = false
    /// The Subscribe pill is a real button only while it has focus (see `subscribeLayer`).
    @State private var subscribeArmed = false
    /// The position the pager shows; it follows `vm.index` with the paging animation.
    @State private var shownIndex = 0
    /// A page change is sliding; the video stays hidden until it settled.
    @State private var isPaging = false
    @State private var pageSerial = 0

    /// 9:16, filling the 960-point safe area height but for room for the focus lift and shadow.
    static let stageSize = CGSize(width: 495, height: 880)
    /// The action column, and the same space on the other side, so the video stays centred.
    private static let actionsWidth: CGFloat = 150
    private static let pageAnimation = Animation.smooth(duration: 0.35)
    private static let panelAnimation = Animation.easeInOut(duration: 0.3)

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: Theme.Spacing.section) {
                    Color.clear.frame(width: Self.actionsWidth, height: 1)
                    stage
                    actions.frame(width: Self.actionsWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(isFailed)
                // The comments panel takes the trailing edge; the video moves over to stay in view.
                if showComments {
                    Color.clear.frame(width: Theme.panelWidth)
                }
            }
            .ignoresSafeArea(edges: .horizontal)

            if showComments {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CommentsPanel(comments: vm.comments, close: { closeComments() })
                        .frame(width: Theme.panelWidth)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .focusSection()
                }
                .ignoresSafeArea()
                .transition(.move(edge: .trailing))
            }

            if case .failed(let error) = vm.phase {
                failure(error)
            }

            if let toast = vm.toast {
                VStack {
                    Text(toast)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 40)
                .transition(.opacity)
            }
        }
        .background {
            ShortsBackdrop(url: vm.poster(at: vm.index),
                           fallback: vm.short(at: vm.index)?.thumbnail.flatMap(URL.init(string:)))
        }
        .animation(Self.panelAnimation, value: showComments)
        .animation(.easeInOut(duration: 0.2), value: vm.toast)
        .defaultFocus($focus, .video)
        .onPlayPauseCommand { vm.togglePlay() }
        .onExitCommand {
            if showComments {
                closeComments()
            } else {
                vm.close()
                router.shorts = nil
            }
        }
        .onChange(of: vm.index) { _, newIndex in page(to: newIndex) }
        .onChange(of: focus) { _, newFocus in
            if let newFocus, newFocus != .subscribe { subscribeArmed = false }
        }
        .onChange(of: isFailed) { _, failed in
            if failed {
                // The failure covers everything; its buttons take focus.
                showComments = false
                subscribeArmed = false
            } else {
                focus = .video
            }
        }
        .onAppear {
            shownIndex = vm.index
            focus = .video
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.pause() }
        }
    }

    private var isFailed: Bool {
        if case .failed = vm.phase { return true }
        return false
    }

    // MARK: - Video

    /// The video frame is one button: Select pauses, and the card style gives it the system's
    /// focus lift. Up/Down page (nothing is above or below it, so focus never moves away).
    private var stage: some View {
        Button {
            vm.togglePlay()
        } label: {
            ShortsPager(vm: vm, shownIndex: shownIndex,
                        showsVideo: vm.isVideoOnScreen && !isPaging && shownIndex == vm.index,
                        hidesPill: subscribeArmed)
        }
        .buttonStyle(.card)
        .focused($focus, equals: .video)
        .onMoveCommand { direction in
            switch direction {
            case .up: vm.previous()
            case .down: vm.next()
            case .left: armSubscribe()
            default: break  // Right: the focus engine moves into the action column.
            }
        }
        .overlay { subscribeLayer }
        // A plain shape's shadow: shadowing the video itself would render it offscreen every frame.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.player, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.6), radius: 40, y: 24)
        }
    }

    /// The Subscribe pill inside the video can't be a button of its own there: the video frame is
    /// one button, and a button inside it can't take focus. So Left from the video puts a real
    /// button exactly over the pill (the rest of this layer keeps its place, invisible) and
    /// focuses it; once focus moves on, the pill is part of the picture again.
    @ViewBuilder
    private var subscribeLayer: some View {
        if subscribeArmed, !isFailed, let short = vm.current, short.channel.id != nil {
            ShortInfoView(short: short, pillOnly: true) {
                Button {
                    vm.toggleSubscription()
                } label: {
                    Text(vm.isSubscribed == true ? "Subscribed" : "Subscribe")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .focused($focus, equals: .subscribe)
                .onMoveCommand { direction in
                    if direction == .up { focus = .video }
                }
                .onAppear {
                    // Once the button is in the focus system.
                    Task { @MainActor in focus = .subscribe }
                }
            }
            .frame(width: Self.stageSize.width, height: Self.stageSize.height)
        }
    }

    private func armSubscribe() {
        guard vm.current?.channel.id != nil else { return }
        subscribeArmed = true
        focus = .subscribe
    }

    /// Slides the pager to `newIndex`: the outgoing Short leaves at the top (or bottom) while the
    /// next comes in, both as posters; the video shows again once the slide settled and mpv has
    /// the new Short's first frame.
    private func page(to newIndex: Int) {
        guard newIndex != shownIndex else { return }
        pageSerial += 1
        let serial = pageSerial
        isPaging = true
        withAnimation(Self.pageAnimation) {
            shownIndex = newIndex
        } completion: {
            if serial == pageSerial { isPaging = false }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: Theme.Spacing.titleToContent) {
            ShortsActionButton(title: "Like", caption: "Like", systemImage: "hand.thumbsup",
                               isActive: vm.likeStatus == .like, focus: $focus, target: .like) {
                vm.rate(.like)
            }
            ShortsActionButton(title: "Dislike", caption: "Dislike", systemImage: "hand.thumbsdown",
                               isActive: vm.likeStatus == .dislike, focus: $focus, target: .dislike) {
                vm.rate(.dislike)
            }
            CommentsActionButton(comments: vm.comments, isOpen: showComments, focus: $focus) {
                showComments.toggle()
            }
            // Always there (does nothing until the Short's channel is known), so the column
            // doesn't jump while a Short loads.
            ShortsActionButton(title: "Go to channel", caption: "Channel", systemImage: "person.crop.circle",
                               imageURL: vm.current?.channel.avatar.flatMap(URL.init(string:)), focus: $focus, target: .channel) {
                if let channelId = vm.current?.channel.id {
                    vm.close()
                    router.open(.channel(channelId))
                }
            }
        }
        .focusSection()
        // Coming over from the video lands on the first button, wherever the video had focus.
        .defaultFocus($focus, .like, priority: .userInitiated)
    }

    private func closeComments() {
        showComments = false
        focus = .comments
    }

    // MARK: - Failure

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85).ignoresSafeArea())
        .focusSection()
    }
}

/// The 9:16 frame. The Shorts next to the current one wait above and below it (clipped away), so
/// a page change slides the outgoing Short out and the incoming one in, over their posters; the
/// one video sits over the current Short's poster (never moved, so mpv keeps its surface) and is
/// shown once it has a picture.
private struct ShortsPager: View {
    @ObservedObject var vm: ShortsViewModel
    let shownIndex: Int
    let showsVideo: Bool
    /// The Subscribe button of the focus layer is over the pill.
    let hidesPill: Bool

    private struct Page: Identifiable {
        let position: Int
        let id: String
    }

    /// The current Short and its neighbours.
    private var pages: [Page] {
        guard !vm.ids.isEmpty else { return [] }
        let lower = max(0, shownIndex - 1)
        let upper = min(vm.ids.count - 1, shownIndex + 1)
        guard lower <= upper else { return [] }
        return (lower...upper).map { Page(position: $0, id: vm.ids[$0]) }
    }

    private var size: CGSize { ShortsContent.stageSize }

    private func yOffset(of page: Page) -> CGFloat {
        CGFloat(page.position - shownIndex) * size.height
    }

    var body: some View {
        ZStack {
            Color.black
            ForEach(pages) { page in
                ShortPoster(url: vm.poster(at: page.position),
                            fallback: vm.short(at: page.position)?.thumbnail.flatMap(URL.init(string:)))
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .offset(y: yOffset(of: page))
                    .transition(.identity)
            }
            MPVVideoView(player: vm.player)
                .opacity(showsVideo ? 1 : 0)
                // Fades in over the poster; hides at once when paging, so it never covers the slide.
                .animation(showsVideo ? Animation.easeOut(duration: 0.2) : nil, value: showsVideo)
            ForEach(pages) { page in
                info(for: page)
                    .offset(y: yOffset(of: page))
                    .transition(.identity)
            }
            if vm.ids.isEmpty, case .loading(let message) = vm.phase {
                LoadingView(message: message)
            }
        }
        .frame(width: size.width, height: size.height)
        .continuousCorners(Theme.Radius.player)
        .modifier(HoverShape(radius: Theme.Radius.player))
    }

    /// Title and channel over a soft gradient, and the current Short's loading/paused state.
    private func info(for page: Page) -> some View {
        let isCurrent = page.position == vm.index
        return ZStack {
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
            if let short = vm.short(at: page.position) {
                let subscribed = isCurrent ? vm.isSubscribed : short.channel.isSubscribed
                ShortInfoView(short: short) {
                    if short.channel.id != nil {
                        SubscribePill(isSubscribed: subscribed == true)
                            .opacity(isCurrent && hidesPill ? 0 : 1)
                    }
                }
            }
            if isCurrent {
                PlaybackStatus(player: vm.player.state, phase: vm.phase, isVideoOnScreen: vm.isVideoOnScreen)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The frame's own continuous corners for the card style's focus effect (tvOS 18 and later; on
/// tvOS 17 the effect keeps the style's shape).
private struct HoverShape: ViewModifier {
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 18.0, *) {
            content.contentShape(.hoverEffect, RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

/// Channel row (avatar, name, Subscribe pill), title and views at the bottom left of a Short.
/// With `pillOnly` everything but the pill keeps its place invisibly, so a layer over the video
/// can put a button exactly where the pill is.
private struct ShortInfoView<Pill: View>: View {
    let short: ShortDetails
    var pillOnly = false
    let pill: Pill

    init(short: ShortDetails, pillOnly: Bool = false, @ViewBuilder pill: () -> Pill) {
        self.short = short
        self.pillOnly = pillOnly
        self.pill = pill()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.cardToText) {
            HStack(spacing: Theme.Spacing.cardToText) {
                ChannelAvatar(channel: short.channel)
                    .opacity(pillOnly ? 0 : 1)
                Text(short.channel.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .opacity(pillOnly ? 0 : 1)
                pill
            }
            Group {
                Text(short.title)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                if let views = short.viewCountText, !views.isEmpty {
                    Text(views)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(pillOnly ? 0 : 1)
        }
        .padding(Theme.Spacing.titleToContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// "Subscribe" (white) or "Subscribed" (translucent), as a picture: see `subscribeLayer`.
private struct SubscribePill: View {
    let isSubscribed: Bool

    var body: some View {
        Text(isSubscribed ? "Subscribed" : "Subscribe")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .foregroundStyle(isSubscribed ? Color.white : Color.black)
            .background(isSubscribed ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white), in: Capsule())
    }
}

/// The channel's avatar, or its initial on a plain circle (Shorts' details often have no avatar).
private struct ChannelAvatar: View {
    let channel: ChannelSummary
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let avatar = channel.avatar, let url = URL(string: avatar) {
                RemoteImage(url: url)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .overlay(
                        Text(channel.name.first.map { String($0).uppercased() } ?? "")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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

/// One round button of the action column with its caption under it; the symbol fills when the
/// action is on (liked, disliked, comments open).
private struct ShortsActionButton: View {
    let title: String
    let caption: String
    let systemImage: String
    var isActive = false
    /// Shown instead of the symbol (the channel's avatar).
    var imageURL: URL?
    var focus: FocusState<ShortsFocus?>.Binding
    let target: ShortsFocus
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.cardToText) {
            Button(action: action) {
                Group {
                    if let imageURL {
                        RemoteImage(url: imageURL).clipShape(Circle())
                    } else {
                        Image(systemName: systemImage)
                            .symbolVariant(isActive ? .fill : .none)
                            .font(.title3)
                    }
                }
                .frame(width: 48, height: 48)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .focused(focus, equals: target)
            .accessibilityLabel(title)
            Text(caption)
                .font(.caption)
                .foregroundStyle(focus.wrappedValue == target ? .primary : .secondary)
                .lineLimit(1)
        }
    }
}

/// The comments button, with the count once the comments are loaded.
private struct CommentsActionButton: View {
    @ObservedObject var comments: CommentsModel
    let isOpen: Bool
    var focus: FocusState<ShortsFocus?>.Binding
    let action: () -> Void

    var body: some View {
        ShortsActionButton(title: "Comments", caption: count ?? "Comments", systemImage: "text.bubble",
                           isActive: isOpen, focus: focus, target: .comments, action: action)
    }

    /// "1,234 Comments" → "1,234"; nil until loaded or when the text has no number.
    private var count: String? {
        guard let first = comments.page?.countText?.split(separator: " ").first,
              first.first?.isNumber == true else { return nil }
        return String(first)
    }
}

/// A Short's poster: its vertical thumbnail from the id alone, so it never waits for the details
/// and never switches under the viewer; if that one can't be loaded, the thumbnail from its
/// details (once they're known).
private struct ShortPoster: View {
    let url: URL?
    let fallback: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                RemoteImage(url: fallback)
            default:
                Color.white.opacity(0.08)
            }
        }
    }
}

/// The current Short's poster, blurred and darkened behind everything, crossfading on paging.
private struct ShortsBackdrop: View {
    let url: URL?
    let fallback: URL?
    /// The last poster shown: while the feed is still loading (no Short yet) it stays instead of
    /// dipping to black.
    @State private var shown: URL? = nil

    var body: some View {
        ZStack {
            Color.black
            if let shown {
                ShortPoster(url: shown, fallback: fallback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 70, opaque: true)
                    .overlay(Color.black.opacity(0.5))
                    .id(shown)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: shown)
        .ignoresSafeArea()
        .onAppear { if let url { shown = url } }
        .onChange(of: url) { _, newURL in
            if let newURL { shown = newURL }
        }
    }
}
