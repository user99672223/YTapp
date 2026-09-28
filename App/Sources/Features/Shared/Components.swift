import SwiftUI
import Core

enum Layout {
    static let gridColumns = 4
    static let cardWidth: CGFloat = 400
    static let cardSpacing: CGFloat = 48
    static let shortWidth: CGFloat = 230
    static let channelWidth: CGFloat = 240
    static let horizontalPadding: CGFloat = 80
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

/// Remote image with a neutral placeholder. Uses URLCache (configured in AppModel).
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                Color.white.opacity(0.08).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            default:
                Color.white.opacity(0.08)
            }
        }
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
                    Button("Save to Watch Later") {
                        let id = video.id
                        Task { _ = try? await model.api { try await $0.setWatchLater(videoId: id, true) } }
                    }
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

/// Renders any feed item with the right card.
struct FeedItemView: View {
    let item: FeedItem
    var compact = false

    var body: some View {
        switch item {
        case .video(let video):
            if video.isShort {
                ShortCard(video: video)
            } else {
                VideoCard(video: video)
            }
        case .channel(let channel):
            ChannelCard(channel: channel)
        case .playlist(let playlist):
            PlaylistCard(playlist: playlist)
        }
    }
}
