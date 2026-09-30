import SwiftUI
import Core

enum Layout {
    static let gridColumns = 4
    static let cardWidth: CGFloat = 400
    static let cardSpacing: CGFloat = 48
    static let shortWidth: CGFloat = 230
    static let shortColumns = 6
    static let shortSpacing: CGFloat = 40
    static let channelWidth: CGFloat = 240
    static let horizontalPadding: CGFloat = 80
    /// The width between the side margins of a list on the Apple TV's 1920-point screen (80-point
    /// safe area plus `horizontalPadding` on each side). Used until the real width is measured.
    static let defaultContentWidth: CGFloat = 1920 - 2 * (80 + horizontalPadding)

    /// Width of each of `count` equal columns that exactly fill `width`, so a grid has the same
    /// margin on the right as on the left.
    static func columnWidth(in width: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0, width > 0 else { return 0 }
        return floor((width - spacing * CGFloat(count - 1)) / CGFloat(count))
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
        VStack(spacing: 28) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.yellow)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1100)
            if let retry {
                Button {
                    if !isRetrying { retry() }
                } label: {
                    if isRetrying {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Retrying…")
                        }
                    } else {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingView: View {
    var message: String = "Loading…"

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage).font(.system(size: 70)).foregroundStyle(.secondary)
            Text(text).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(80)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .black.opacity(0.8)

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
    }
}

// MARK: - Cards

struct VideoCard: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var model: AppModel
    let video: VideoItem
    var width: CGFloat = Layout.cardWidth
    @State private var watchLaterError: BridgeError?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                router.play(video)
            } label: {
                thumbnail
            }
            .buttonStyle(.card)
            .contextMenu {
                if model.isSignedIn, !video.isShort {
                    Button("Save to Watch Later") { saveToWatchLater() }
                }
                if let channelId = video.channelId {
                    Button("Go to channel") { router.open(.channel(channelId)) }
                }
            }
            Text(video.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            if !video.subtitle.isEmpty {
                Text(video.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .alert("Watch Later failed", isPresented: watchLaterFailed, presenting: watchLaterError) { _ in
            Button("Retry") { saveToWatchLater() }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.userMessage)
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

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: video.thumbnailURL)
                .frame(width: width, height: width * 9 / 16)
                .clipped()
            HStack(spacing: 6) {
                if video.isLive { Badge(text: "LIVE", color: .red) }
                if video.isUpcoming { Badge(text: "UPCOMING") }
                if video.isShort { Badge(text: "SHORTS", color: .red.opacity(0.85)) }
                if let duration = video.durationText, !video.isLive { Badge(text: duration) }
            }
            .padding(10)
            if let percent = video.watchedPercent, percent > 0 {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.3))
                            Rectangle().fill(Color.red).frame(width: geo.size.width * min(1, percent / 100))
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
        .frame(width: width, height: width * 9 / 16)
    }
}

struct ShortCard: View {
    @EnvironmentObject private var router: Router
    let video: VideoItem
    var width: CGFloat = Layout.shortWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                router.play(video)
            } label: {
                RemoteImage(url: video.thumbnailURL)
                    .frame(width: width, height: width * 16 / 9)
                    .clipped()
            }
            .buttonStyle(.card)
            Text(video.title).font(.caption.weight(.medium)).lineLimit(2).frame(width: width, alignment: .leading)
            if let views = video.viewCountText {
                Text(views).font(.caption2).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

struct ChannelCard: View {
    let channel: ChannelItem
    var width: CGFloat = Layout.channelWidth

    var body: some View {
        NavigationLink(value: Route.channel(channel.id)) {
            VStack(spacing: 14) {
                RemoteImage(url: channel.avatar.flatMap(URL.init(string:)))
                    .frame(width: width * 0.62, height: width * 0.62)
                    .clipShape(Circle())
                Text(channel.name).font(.callout.weight(.medium)).lineLimit(1)
                if let subs = channel.subscriberCountText ?? channel.handle {
                    Text(subs).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width)
            .padding(.vertical, 20)
        }
        .buttonStyle(.card)
    }
}

struct PlaylistCard: View {
    let playlist: PlaylistItem
    var width: CGFloat = Layout.cardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.playlist(id: playlist.id, title: playlist.title)) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(url: playlist.thumbnail.flatMap(URL.init(string:)))
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                    Badge(text: playlist.videoCountText.map { "▶︎ \($0)" } ?? "Playlist").padding(10)
                }
                .frame(width: width, height: width * 9 / 16)
            }
            .buttonStyle(.card)
            Text(playlist.title).font(.callout.weight(.medium)).lineLimit(2).frame(width: width, alignment: .leading)
            if let channel = playlist.channelName {
                Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .topLeading)
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
        if let message = toasts.message {
            Text(message)
                .padding(.horizontal, 30).padding(.vertical, 16)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 40)
        }
    }
}

/// Renders any feed item with the right card.
struct FeedItemView: View {
    let item: FeedItem
    var compact = false
    /// Card width for video and playlist cards (a grid column); nil keeps the standard size.
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
            ChannelCard(channel: channel)
        case .playlist(let playlist):
            PlaylistCard(playlist: playlist, width: width ?? Layout.cardWidth)
        }
    }
}
