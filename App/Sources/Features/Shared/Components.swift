import SwiftUI
import Core

/// Card sizes and the grid, from the tvOS grid in Apple's Human Interface Guidelines. tvOS itself
/// keeps content 80 points from the sides of the 1,920-point screen; a list adds no margin of its
/// own inside that, as in Apple's TV apps, so four video columns of 410 points or six Short
/// columns of 260, 40 points apart, fill the 1,760 points between the margins exactly.
enum Layout {
    static let gridColumns = 4
    static let cardWidth: CGFloat = 410
    static let cardSpacing: CGFloat = 40
    static let shortWidth: CGFloat = 260
    static let shortColumns = 6
    static let shortSpacing: CGFloat = 40
    /// A channel in a sideways row (a six-column width); in a grid it takes the column's width.
    static let channelWidth: CGFloat = 260
    /// Between the rows of a grid (the list's video grid, the Shorts tab), from the last line of
    /// text to the next row's artwork. That artwork reaches up into the gap when focused
    /// (`focusOverflow`: 12 points for a video, 24 for a Short), so this leaves a clear gap under
    /// the text either way.
    static let rowSpacing: CGFloat = 60
    /// tvOS's own side safe area. The system insets every screen's content by it; lists don't add
    /// it themselves.
    static let screenMargin: CGFloat = 80
    /// Side margin a list adds inside the safe area: none, so the first card lines up with the
    /// safe area like the grids in Apple's apps.
    static let horizontalPadding: CGFloat = 0
    /// The width between the side margins of a list on the Apple TV's 1920-point screen (80-point
    /// safe area plus `horizontalPadding` on each side). Used until the real width is measured.
    static let defaultContentWidth: CGFloat = 1920 - 2 * (screenMargin + horizontalPadding)

    /// Width of each of `count` equal columns that exactly fill `width`, so a grid has the same
    /// margin on the right as on the left.
    static func columnWidth(in width: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0, width > 0 else { return 0 }
        return floor((width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// How far focused artwork of this width or height reaches past each of its edges: the
    /// system's focus effect enlarges it to about 110 %. Text under a card starts this much lower,
    /// so the lifted card never covers it and nothing has to move when focus arrives.
    static func focusOverflow(_ length: CGFloat) -> CGFloat {
        ceil(length * 0.05)
    }
}

/// Measures the width of the view it is attached to into `width`. Attach it to the list's content
/// (full width, inside the side padding): a scroll view's own frame can reach under tvOS's
/// safe-area margins, so measuring that would be too wide on some screens.
struct ContentWidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { update(geo.size.width) }
                .onChange(of: geo.size.width) { _, newWidth in update(newWidth) }
        }
    }

    private func update(_ measured: CGFloat) {
        if measured > 0, abs(measured - width) > 0.5 { width = measured }
    }
}

/// Plain message + Retry, used for every failure.
struct ErrorStateView: View {
    let title: String
    let message: String
    /// The retry is running: the button shows progress (and stays, keeping focus).
    let isRetrying: Bool
    let retry: (() -> Void)?

    init(error: BridgeError, isRetrying: Bool = false, retry: (() -> Void)?) {
        title = error.title
        message = error.userMessage
        self.isRetrying = isRetrying
        self.retry = retry
    }

    init(title: String, message: String, isRetrying: Bool = false, retry: (() -> Void)?) {
        self.title = title
        self.message = message
        self.isRetrying = isRetrying
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.titleToContent) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Theme.heroSymbolSize))
                .foregroundStyle(.yellow)
            VStack(spacing: Theme.Spacing.textLines * 3) {
                Text(title).font(.title3.bold())
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Theme.messageWidth)
            if let retry {
                Button {
                    if !isRetrying { retry() }
                } label: {
                    if isRetrying {
                        HStack(spacing: Theme.Spacing.row) {
                            ProgressView()
                            Text("Retrying…")
                        }
                    } else {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                .padding(.top, Theme.Spacing.row)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole width is a focus target, so Down from a control at the side of the screen
        // (a list's leading picker) still reaches the centred Retry.
        .focusSection()
    }
}

struct LoadingView: View {
    var message: String = "Loading…"

    var body: some View {
        VStack(spacing: Theme.Spacing.titleToContent) {
            ProgressView()
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: Theme.Spacing.titleToContent) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.heroSymbolSize))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Theme.messageWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.section)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .black.opacity(0.8)
    /// A symbol before the text (a playlist's stack, for example).
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color, in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .foregroundStyle(.white)
    }
}

// MARK: - Cards
//
// A card is a tvOS lockup: artwork on the system's `.card` button style (it lifts, tilts with the
// remote and casts a shadow when focused), with continuous corners, and the title and one line
// of details below it in `CardText`.

struct VideoCard: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var model: AppModel
    let video: VideoItem
    var width: CGFloat = Layout.cardWidth
    /// Replaces opening the video on its own watch page (the watch page's Up next row plays it in
    /// the same session). A card with an action of its own has no context menu.
    var action: (() -> Void)? = nil
    @State private var watchLaterError: BridgeError?

    init(video: VideoItem, width: CGFloat = Layout.cardWidth, action: (() -> Void)? = nil) {
        self.video = video
        self.width = width
        self.action = action
    }

    /// The artwork of a card `width` points wide: 16:9, rounded to whole points. Code that fetches
    /// artwork ahead asks for this size, so the image it caches is the one the card draws.
    static func artworkSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * 9 / 16).rounded())
    }

    private var height: CGFloat { Self.artworkSize(width: width).height }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artworkButton
            CardText(title: video.title, detail: video.subtitle, width: width, artworkHeight: height)
        }
        .frame(width: width, alignment: .topLeading)
        .alert("Watch Later failed", isPresented: watchLaterFailed, presenting: watchLaterError) { _ in
            Button("Retry") { saveToWatchLater() }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.userMessage)
        }
    }

    @ViewBuilder
    private var artworkButton: some View {
        let button = Button {
            if let action { action() } else { router.play(video) }
        } label: {
            artwork
        }
        .buttonStyle(.card)
        if action == nil {
            button.contextMenu {
                if model.isSignedIn, !video.isShort {
                    Button("Save to Watch Later") { saveToWatchLater() }
                }
                if let channelId = video.channelId {
                    Button("Go to channel") { router.open(.channel(channelId)) }
                }
            }
        } else {
            button
        }
    }

    private var watchLaterFailed: Binding<Bool> {
        Binding(get: { watchLaterError != nil }, set: { if !$0 { watchLaterError = nil } })
    }

    /// Confirms with a toast or offers Retry, and has Watch Later reload the next time it's shown.
    @MainActor
    private func saveToWatchLater() {
        let id = video.id
        let model = self.model
        let toasts = self.router.toasts
        Task {
            do {
                _ = try await model.api { try await $0.setWatchLater(videoId: id, true) }
                FeedModel.markChanged(cacheKey: "playlist:WL")
                toasts.show("Saved to Watch Later")
            } catch {
                watchLaterError = BridgeError.wrap(error)
            }
        }
    }

    /// Watched share, 0…1; nil when the video wasn't started.
    private var watched: Double? {
        guard let percent = video.watchedPercent, percent > 0 else { return nil }
        return min(1, percent / 100)
    }

    /// The thumbnail with its badges and the watched bar, all inside the rounded shape.
    private var artwork: some View {
        RemoteImage(url: video.thumbnailURL)
            .frame(width: width, height: height)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    if video.isLive { Badge(text: "LIVE", color: .red) }
                    if video.isUpcoming { Badge(text: "UPCOMING") }
                    if video.isShort { Badge(text: "SHORTS", color: .red.opacity(0.85)) }
                    if let duration = video.durationText, !video.isLive { Badge(text: duration) }
                }
                .padding(Theme.Spacing.badgeInset)
                .padding(.bottom, watched == nil ? 0 : WatchedBar.height)
            }
            .overlay(alignment: .bottom) {
                if let watched { WatchedBar(fraction: watched) }
            }
            .continuousCorners(Theme.Radius.card)
    }
}

/// How much of a video was watched, along the bottom edge of its artwork. The artwork's rounded
/// corners clip it, so it follows the card's shape.
private struct WatchedBar: View {
    static let height: CGFloat = 6
    let fraction: Double

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.35))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.red)
                    .scaleEffect(x: CGFloat(fraction), y: 1, anchor: .leading)
            }
            .frame(height: Self.height)
    }
}

struct ShortCard: View {
    @EnvironmentObject private var router: Router
    let video: VideoItem
    var width: CGFloat = Layout.shortWidth

    /// The artwork of a card `width` points wide: 9:16, rounded to whole points (see
    /// `VideoCard.artworkSize(width:)`).
    static func artworkSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * 16 / 9).rounded())
    }

    private var height: CGFloat { Self.artworkSize(width: width).height }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                router.play(video)
            } label: {
                RemoteImage(url: video.thumbnailURL)
                    .frame(width: width, height: height)
                    .continuousCorners(Theme.Radius.card)
            }
            .buttonStyle(.card)
            CardText(title: video.title, detail: video.viewCountText, width: width, artworkHeight: height, compact: true)
        }
        .frame(width: width, alignment: .topLeading)
    }
}

/// A channel: a round avatar that lifts on focus like the system's own lockups (the borderless
/// button style with the highlight effect on the avatar, shaped as a circle), with the name and
/// subscriber count centred below.
struct ChannelCard: View {
    let channel: ChannelItem
    var width: CGFloat = Layout.channelWidth

    /// The avatar of a card `width` points wide: as tall as a video card's artwork, so a channel
    /// lines up with the videos next to it in search results; smaller in a narrower column.
    /// Code that fetches artwork ahead asks for this size, so the image it caches is the one the
    /// card draws.
    static func avatarDiameter(forWidth width: CGFloat) -> CGFloat {
        min((width * 0.85).rounded(), (Layout.cardWidth * 9 / 16).rounded())
    }

    private var diameter: CGFloat { Self.avatarDiameter(forWidth: width) }

    var body: some View {
        NavigationLink(value: Route.channel(channel.id)) {
            VStack(spacing: 0) {
                RemoteImage(url: channel.avatar.flatMap(URL.init(string:)))
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .hoverEffect(HoverEffect.highlight)
                VStack(spacing: Theme.Spacing.textLines) {
                    Text(channel.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let detail = channel.subscriberCountText ?? channel.handle {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(width: width)
                // Below the lifted avatar, like the text under the other cards.
                .padding(.top, Theme.Spacing.cardToText + Layout.focusOverflow(diameter))
            }
            .frame(width: width)
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
    }
}

/// A playlist: its first video's artwork on a stack of cards (two edges peek out above it) with
/// the number of videos in a badge, so it doesn't read as a single video.
struct PlaylistCard: View {
    let playlist: PlaylistItem
    var width: CGFloat = Layout.cardWidth

    /// The same 16:9 artwork as a video's.
    private var height: CGFloat { VideoCard.artworkSize(width: width).height }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: Route.playlist(id: playlist.id, title: playlist.title)) {
                RemoteImage(url: playlist.thumbnail.flatMap(URL.init(string:)))
                    .frame(width: width, height: height)
                    .overlay(alignment: .bottomTrailing) {
                        Badge(text: playlist.videoCountText ?? "Playlist", systemImage: "list.and.film")
                            .padding(Theme.Spacing.badgeInset)
                    }
                    .continuousCorners(Theme.Radius.card)
            }
            .buttonStyle(.card)
            .background(alignment: .top) { PlaylistStackEdges(width: width) }
            CardText(title: playlist.title, detail: playlist.channelName, width: width, artworkHeight: height)
        }
        .frame(width: width, alignment: .topLeading)
    }
}

/// The two cards behind a playlist's artwork. They sit in the gap above it without taking layout
/// space (so the artwork lines up with the videos in the same row), and the focused card lifts
/// over them.
private struct PlaylistStackEdges: View {
    let width: CGFloat
    /// How far each edge shows above the one in front of it.
    private var rise: CGFloat { 7 }

    var body: some View {
        let inset = (width * 0.04).rounded()
        ZStack(alignment: .top) {
            edge(width: width - 4 * inset, opacity: 0.14).offset(y: -2 * rise)
            edge(width: width - 2 * inset, opacity: 0.28).offset(y: -rise)
        }
    }

    private func edge(width: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(.white.opacity(opacity))
            .frame(width: width, height: 4 * rise)
    }
}

/// The title and one line of details under a card's artwork. It starts below the room the lifted
/// artwork takes when focused, so focus never covers or moves it; the title always takes two
/// lines, so the details of the cards in a row line up.
private struct CardText: View {
    let title: String
    let detail: String?
    let width: CGFloat
    let artworkHeight: CGFloat
    /// Narrow poster cards (Shorts) use the next smaller pair of text styles.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
            Text(title)
                .font(compact ? Font.caption.weight(.medium) : Font.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(compact ? Font.caption2 : Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, Theme.Spacing.cardToText + Layout.focusOverflow(artworkHeight))
    }
}

/// The app-wide toast (`Router.toasts`), pinned to the top of a screen.
struct ToastOverlay: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        ToastText(toasts: router.toasts)
    }
}

private struct ToastText: View {
    @ObservedObject var toasts: ToastCenter

    var body: some View {
        // A container that stays, so the toast slides in and out instead of popping.
        VStack {
            if let message = toasts.message {
                ToastView(text: message, systemImage: "checkmark.circle.fill")
                    .padding(.top, Theme.Spacing.floating)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toasts.message)
    }
}

/// A short message over the screen: a confirmation ("Saved to Watch Later") or a note about an
/// action that didn't work. The same box everywhere (the app's toast, the watch page's and
/// Shorts'): `floatingBox(compact:)`, at most `Theme.messageWidth` wide.
struct ToastView: View {
    let text: String
    /// A symbol before the text (a confirmation's checkmark); nil for plain text, as for messages
    /// that can also report a failure.
    var systemImage: String? = nil

    var body: some View {
        content
            .font(.callout)
            .multilineTextAlignment(.center)
            .floatingBox(compact: true)
            .frame(maxWidth: Theme.messageWidth)
    }

    @ViewBuilder
    private var content: some View {
        if let systemImage {
            Label(text, systemImage: systemImage)
        } else {
            Text(text)
        }
    }
}

extension View {
    /// The look of boxes that float over a screen (toasts, banners, the watch page's loading box,
    /// seek sign, up-next countdown and stats): the regular material with the floating corner
    /// radius.
    func floatingBackground() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous))
    }

    /// A floating box: `Theme.Spacing.floating` padding inside `floatingBackground()`. `compact`
    /// (one-line boxes such as toasts and the seek sign) halves the padding above and below.
    func floatingBox(compact: Bool = false) -> some View {
        padding(.horizontal, Theme.Spacing.floating)
            .padding(.vertical, compact ? Theme.Spacing.floating / 2 : Theme.Spacing.floating)
            .floatingBackground()
    }
}

extension View {
    /// A segmented picker at the head of a list (Subscriptions, Library, a channel's tabs): the
    /// segments as wide as their titles, the same on every screen, at the list's leading edge
    /// right above its first card, so Down from the picker reaches that card ("Show the latest"
    /// included). The full-width focus section brings Up from any column back to the picker.
    func listHeaderPicker() -> some View {
        pickerStyle(.segmented)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
    }
}

/// Renders any feed item with the right card.
struct FeedItemView: View {
    let item: FeedItem
    var compact = false
    /// Card width for video, playlist and channel cards (a grid column); nil keeps the standard
    /// size.
    var width: CGFloat?

    var body: some View {
        switch item {
        case .video(let video):
            if video.isShort {
                ShortCard(video: video)
            } else {
                VideoCard(video: video, width: width ?? Layout.cardWidth)
            }
        case .channel(let channel):
            ChannelCard(channel: channel, width: width ?? Layout.channelWidth)
        case .playlist(let playlist):
            PlaylistCard(playlist: playlist, width: width ?? Layout.cardWidth)
        }
    }
}
