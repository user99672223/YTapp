import Foundation

public struct AccountInfo: Codable, Hashable, Sendable {
    public var name: String
    public var handle: String?
    public var photo: String?
    public var byline: String?

    public init(name: String, handle: String? = nil, photo: String? = nil, byline: String? = nil) {
        self.name = name
        self.handle = handle
        self.photo = photo
        self.byline = byline
    }
}

public struct SessionSummary: Codable, Hashable, Sendable {
    @DefaultFalse public var loggedIn: Bool = false
    public var account: AccountInfo?
    public var accountError: String?
    public var visitorData: String?
    public var clientName: String?
    public var playerId: String?
    public var signatureTimestamp: Int?
    @DefaultFalse public var hasDecipher: Bool = false
    public var userAgent: String?
}

public struct SessionOptions: Codable, Hashable, Sendable {
    public var cookie: String
    public var client: String
    public var visitorData: String?
    public var userAgent: String?
    public var lang: String?
    public var location: String?
    public var poTokenMode: String

    public init(cookie: String, client: String, visitorData: String? = nil, userAgent: String? = nil,
                lang: String? = nil, location: String? = nil, poTokenMode: String = "auto") {
        self.cookie = cookie
        self.client = client
        self.visitorData = visitorData
        self.userAgent = userAgent
        self.lang = lang
        self.location = location
        self.poTokenMode = poTokenMode
    }
}

public struct BundleInfo: Codable, Hashable, Sendable {
    public var bundleVersion: String
    public var youtubeiVersion: String
    public var bgutilsVersion: String?
    public var `protocol`: Int?
}

public enum ChannelTab: String, Codable, Sendable, CaseIterable, Identifiable {
    case videos
    case shorts
    case live
    case playlists

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .videos: return "Videos"
        case .shorts: return "Shorts"
        case .live: return "Live"
        case .playlists: return "Playlists"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChannelTab(rawValue: raw) ?? .videos
    }
}

public struct ChannelHeader: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var avatar: String?
    public var description: String?
    public var banner: String?
    public var handle: String?
    public var subscriberCountText: String?
    public var videoCountText: String?
    public var isSubscribed: Bool?
}

public struct ChannelPage: Codable, Hashable, Sendable {
    public var channel: ChannelHeader
    @DefaultEmpty public var tabs: [ChannelTab] = []
    public var key: String?
}

public struct PlaylistInfo: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var channelName: String?
    public var videoCountText: String?
    public var thumbnail: String?
    @DefaultFalse public var isEditable: Bool = false
}

public struct PlaylistPage: Codable, Hashable, Sendable {
    public var info: PlaylistInfo
    public var page: FeedPage
}

public struct Comment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var author: String
    public var authorAvatar: String?
    public var text: String
    public var publishedText: String?
    public var likeCountText: String?
    public var replyCountText: String?
    @DefaultFalse public var isPinned: Bool = false
    @DefaultFalse public var isCreator: Bool = false
    @DefaultFalse public var isHearted: Bool = false
}

public struct CommentsPage: Codable, Hashable, Sendable {
    public var countText: String?
    @DefaultEmpty public var items: [Comment] = []
    public var continuation: String?
}

public enum CommentSort: String, Codable, Sendable, CaseIterable {
    case top
    case newest
}

public struct RateResult: Codable, Hashable, Sendable {
    public var likeStatus: LikeStatus
}

public struct SubscribeResult: Codable, Hashable, Sendable {
    @DefaultFalse public var isSubscribed: Bool = false
}

public struct WatchLaterResult: Codable, Hashable, Sendable {
    public var inWatchLater: Bool?
}

public struct PostCommentResult: Codable, Hashable, Sendable {
    @DefaultFalse public var posted: Bool = false
}

/// Search filters (maps to YouTube.js `SearchFilters`).
public struct SearchFilters: Codable, Hashable, Sendable {
    public enum UploadDate: String, Codable, CaseIterable, Sendable { case all, today, week, month, year }
    public enum ResultType: String, Codable, CaseIterable, Sendable { case all, video, shorts, channel, playlist, movie }
    public enum Duration: String, Codable, CaseIterable, Sendable {
        case all
        case short = "under_three_mins"
        case medium = "three_to_twenty_mins"
        case long = "over_twenty_mins"
    }
    public enum Prioritize: String, Codable, CaseIterable, Sendable { case relevance, popularity }

    public var uploadDate: UploadDate
    public var type: ResultType
    public var duration: Duration
    public var prioritize: Prioritize
    public var features: [String]

    public init(uploadDate: UploadDate = .all, type: ResultType = .all, duration: Duration = .all,
                prioritize: Prioritize = .relevance, features: [String] = []) {
        self.uploadDate = uploadDate
        self.type = type
        self.duration = duration
        self.prioritize = prioritize
        self.features = features
    }

    private enum CodingKeys: String, CodingKey {
        case uploadDate = "upload_date"
        case type
        case duration
        case prioritize
        case features
    }

    public var isDefault: Bool { self == SearchFilters() }
}
