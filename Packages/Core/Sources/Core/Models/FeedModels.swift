import Foundation

/// A video card (regular video, Short, live stream or premiere).
public struct VideoItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channelName: String?
    public var channelId: String?
    public var channelAvatar: String?
    public var thumbnail: String?
    public var durationText: String?
    public var durationSeconds: Double?
    public var viewCountText: String?
    public var publishedText: String?
    @DefaultFalse public var isLive: Bool = false
    @DefaultFalse public var isShort: Bool = false
    @DefaultFalse public var isUpcoming: Bool = false
    public var watchedPercent: Double?
    public var setVideoId: String?

    public init(
        id: String, title: String, channelName: String? = nil, channelId: String? = nil,
        channelAvatar: String? = nil, thumbnail: String? = nil, durationText: String? = nil,
        durationSeconds: Double? = nil, viewCountText: String? = nil, publishedText: String? = nil,
        isLive: Bool = false, isShort: Bool = false, isUpcoming: Bool = false,
        watchedPercent: Double? = nil, setVideoId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.channelName = channelName
        self.channelId = channelId
        self.channelAvatar = channelAvatar
        self.thumbnail = thumbnail
        self.durationText = durationText
        self.durationSeconds = durationSeconds
        self.viewCountText = viewCountText
        self.publishedText = publishedText
        self.isLive = isLive
        self.isShort = isShort
        self.isUpcoming = isUpcoming
        self.watchedPercent = watchedPercent
        self.setVideoId = setVideoId
    }

    /// "Channel • 12K views • 3 days ago"
    public var subtitle: String {
        [channelName, viewCountText, publishedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    public var thumbnailURL: URL? {
        URL(string: thumbnail ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}

public struct ChannelItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var avatar: String?
    public var handle: String?
    public var subscriberCountText: String?
    public var videoCountText: String?
    public var isSubscribed: Bool?

    public init(id: String, name: String, avatar: String? = nil, handle: String? = nil,
                subscriberCountText: String? = nil, videoCountText: String? = nil, isSubscribed: Bool? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.handle = handle
        self.subscriberCountText = subscriberCountText
        self.videoCountText = videoCountText
        self.isSubscribed = isSubscribed
    }
}

public struct PlaylistItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var thumbnail: String?
    public var videoCountText: String?
    public var channelName: String?

    public init(id: String, title: String, thumbnail: String? = nil, videoCountText: String? = nil, channelName: String? = nil) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.videoCountText = videoCountText
        self.channelName = channelName
    }
}

/// One entry of a feed. Decoded from `{ "type": "video" | "channel" | "playlist", ... }`.
public enum FeedItem: Codable, Hashable, Sendable, Identifiable {
    case video(VideoItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "video"
        switch type {
        case "channel": self = .channel(try ChannelItem(from: decoder))
        case "playlist": self = .playlist(try PlaylistItem(from: decoder))
        default: self = .video(try VideoItem(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let v):
            try container.encode("video", forKey: .type)
            try v.encode(to: encoder)
        case .channel(let c):
            try container.encode("channel", forKey: .type)
            try c.encode(to: encoder)
        case .playlist(let p):
            try container.encode("playlist", forKey: .type)
            try p.encode(to: encoder)
        }
    }

    public var id: String {
        switch self {
        case .video(let v): return "v:" + v.id
        case .channel(let c): return "c:" + c.id
        case .playlist(let p): return "p:" + p.id
        }
    }

    public var video: VideoItem? {
        if case .video(let v) = self { return v }
        return nil
    }
}

public enum SectionStyle: String, Codable, Sendable {
    case grid
    case row
    case shorts

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SectionStyle(rawValue: raw) ?? .row
    }
}

public struct FeedSection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var style: SectionStyle
    public var items: [FeedItem]

    public init(id: String, title: String? = nil, style: SectionStyle, items: [FeedItem]) {
        self.id = id
        self.title = title
        self.style = style
        self.items = items
    }

    public var videos: [VideoItem] { items.compactMap(\.video) }
}

public struct FeedPage: Codable, Hashable, Sendable {
    @DefaultEmpty public var sections: [FeedSection] = []
    /// Opaque key to pass to `more(key:)`; nil when there is nothing more.
    public var continuation: String?

    public init(sections: [FeedSection] = [], continuation: String? = nil) {
        self.sections = sections
        self.continuation = continuation
    }

    public var allItems: [FeedItem] { sections.flatMap(\.items) }
    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
}

extension FeedPage {
    /// Appends a continuation page. Consecutive untitled grid sections are merged so infinite
    /// scroll keeps extending the same grid.
    public mutating func append(_ next: FeedPage) {
        for section in next.sections where !section.items.isEmpty {
            if section.style == .grid, section.title == nil,
               let lastIndex = sections.indices.last,
               sections[lastIndex].style == .grid, sections[lastIndex].title == nil {
                sections[lastIndex].items.append(contentsOf: section.items)
            } else {
                sections.append(section)
            }
        }
        continuation = next.continuation
    }

    /// The Shorts found anywhere in the page (shelves first), deduplicated.
    public var shorts: [VideoItem] {
        var seen = Set<String>()
        let ordered = sections.filter { $0.style == .shorts } + sections.filter { $0.style != .shorts }
        return ordered.flatMap(\.videos).filter { $0.isShort && seen.insert($0.id).inserted }
    }
}
