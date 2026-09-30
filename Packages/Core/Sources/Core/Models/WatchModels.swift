import Foundation

public enum LikeStatus: String, Codable, Sendable, Hashable {
    case like
    case dislike
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LikeStatus(rawValue: raw) ?? .none
    }
}

public struct ChannelSummary: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var avatar: String?
    public var subscriberCountText: String?
    public var isSubscribed: Bool?

    public init(id: String?, name: String, avatar: String? = nil, subscriberCountText: String? = nil, isSubscribed: Bool? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.subscriberCountText = subscriberCountText
        self.isSubscribed = isSubscribed
    }
}

public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    public var startSeconds: Double
    public var thumbnail: String?

    public var id: Double { startSeconds }

    public init(title: String, startSeconds: Double, thumbnail: String? = nil) {
        self.title = title
        self.startSeconds = startSeconds
        self.thumbnail = thumbnail
    }
}

public struct CaptionTrack: Codable, Hashable, Sendable, Identifiable {
    public var languageCode: String
    public var name: String
    /// WebVTT URL (caption base_url + fmt=vtt).
    public var url: String
    @DefaultFalse public var isAuto: Bool = false
    public var vssId: String?

    public var id: String { vssId ?? (languageCode + (isAuto ? ".auto" : "")) }

    public init(languageCode: String, name: String, url: String, isAuto: Bool = false, vssId: String? = nil) {
        self.languageCode = languageCode
        self.name = name
        self.url = url
        self.isAuto = isAuto
        self.vssId = vssId
    }
}

/// One entry of `streaming_data.adaptive_formats` (URL not included — it is deciphered on demand).
public struct StreamFormat: Codable, Hashable, Sendable, Identifiable {
    /// Index into `adaptive_formats`; the key used to resolve the URL.
    public var index: Int
    public var itag: Int
    public var mimeType: String?
    public var codecs: String?
    @DefaultFalse public var hasVideo: Bool = false
    @DefaultFalse public var hasAudio: Bool = false
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var bitrate: Int?
    public var averageBitrate: Int?
    public var contentLength: Int64?
    public var qualityLabel: String?
    public var audioQuality: String?
    public var audioSampleRate: Int?
    public var audioChannels: Int?
    public var loudnessDb: Double?
    @DefaultFalse public var isDrc: Bool = false
    @DefaultFalse public var isHdr: Bool = false
    @DefaultFalse public var isOtf: Bool = false
    @DefaultFalse public var isSuperResolution: Bool = false
    public var audioTrackId: String?
    public var audioTrackName: String?
    public var isDefaultAudio: Bool?
    public var isOriginal: Bool?
    public var isDubbed: Bool?
    public var isAutoDubbed: Bool?
    public var isDescriptive: Bool?
    public var isSecondary: Bool?
    public var language: String?
    @DefaultFalse public var hasUrl: Bool = false
    @DefaultFalse public var isDrm: Bool = false
    public var approxDurationMs: Double?

    public var id: Int { index }

    public init(index: Int, itag: Int, mimeType: String? = nil, codecs: String? = nil, hasVideo: Bool = false,
                hasAudio: Bool = false, width: Int? = nil, height: Int? = nil, fps: Double? = nil,
                bitrate: Int? = nil, averageBitrate: Int? = nil, contentLength: Int64? = nil,
                qualityLabel: String? = nil, audioQuality: String? = nil, audioSampleRate: Int? = nil,
                audioChannels: Int? = nil, isDrc: Bool = false, isHdr: Bool = false, isOtf: Bool = false,
                isSuperResolution: Bool = false, audioTrackId: String? = nil, audioTrackName: String? = nil,
                isDefaultAudio: Bool? = nil, isOriginal: Bool? = nil, isAutoDubbed: Bool? = nil,
                language: String? = nil, hasUrl: Bool = true, isDrm: Bool = false) {
        self.index = index
        self.itag = itag
        self.mimeType = mimeType
        self.codecs = codecs
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.averageBitrate = averageBitrate
        self.contentLength = contentLength
        self.qualityLabel = qualityLabel
        self.audioQuality = audioQuality
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.isDrc = isDrc
        self.isHdr = isHdr
        self.isOtf = isOtf
        self.isSuperResolution = isSuperResolution
        self.audioTrackId = audioTrackId
        self.audioTrackName = audioTrackName
        self.isDefaultAudio = isDefaultAudio
        self.isOriginal = isOriginal
        self.isAutoDubbed = isAutoDubbed
        self.language = language
        self.hasUrl = hasUrl
        self.isDrm = isDrm
    }

    /// Codec family used by the quality rule.
    public var codecFamily: CodecFamily { CodecFamily(codecs: codecs ?? "", mimeType: mimeType ?? "") }

    /// "2160p60 · AV1 · 12.0 Mb/s" / "Opus · 160 kb/s · 48 kHz"
    public var displayName: String {
        var parts: [String] = []
        if hasVideo {
            parts.append(qualityLabel ?? "\(height ?? 0)p")
            parts.append(codecFamily.displayName)
        } else {
            parts.append(codecFamily.displayName)
            if let track = audioTrackName, !track.isEmpty { parts.append(track) }
            if let rate = audioSampleRate { parts.append("\(rate / 1000) kHz") }
            if isDrc { parts.append("DRC") }
        }
        if let bitrate = averageBitrate ?? bitrate {
            parts.append(Formatters.bitrate(bitrate))
        }
        return parts.joined(separator: " · ")
    }
}

public enum CodecFamily: String, Codable, Sendable, CaseIterable {
    case av1
    case vp9
    case avc
    case hevc
    case opus
    case aac
    case other

    public init(codecs: String, mimeType: String) {
        let c = codecs.lowercased()
        if c.hasPrefix("av01") { self = .av1 }
        else if c.hasPrefix("vp9") || c.hasPrefix("vp09") { self = .vp9 }
        else if c.hasPrefix("avc1") || c.hasPrefix("avc3") { self = .avc }
        else if c.hasPrefix("hev1") || c.hasPrefix("hvc1") { self = .hevc }
        else if c.hasPrefix("opus") { self = .opus }
        else if c.hasPrefix("mp4a") { self = .aac }
        else { self = .other }
    }

    public var displayName: String {
        switch self {
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .avc: return "H.264"
        case .hevc: return "HEVC"
        case .opus: return "Opus"
        case .aac: return "AAC"
        case .other: return "Other"
        }
    }
}

public struct Playability: Codable, Hashable, Sendable {
    public var status: String
    public var reason: String?
}

public struct VideoDetails: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var channel: ChannelSummary
    public var viewCountText: String?
    public var publishedText: String?
    public var likeCountText: String?
    public var likeStatus: LikeStatus
    @DefaultFalse public var isLive: Bool = false
    @DefaultFalse public var isUpcoming: Bool = false
    @DefaultFalse public var isPostLiveDvr: Bool = false
    public var durationSeconds: Double?
    public var thumbnail: String?
    @DefaultEmpty public var chapters: [Chapter] = []
    @DefaultEmpty public var captions: [CaptionTrack] = []
    @DefaultEmpty public var formats: [StreamFormat] = []
    @DefaultEmpty public var upNext: [VideoItem] = []
    public var autoplayNextId: String?
    public var commentsCountText: String?
    public var playerClient: String?
    public var userAgent: String?
    @DefaultFalse public var trackingAvailable: Bool = false
    public var playability: Playability?

    public init(id: String, title: String, description: String = "", channel: ChannelSummary,
                likeStatus: LikeStatus = .none, durationSeconds: Double? = nil, formats: [StreamFormat] = [],
                upNext: [VideoItem] = [], chapters: [Chapter] = [], captions: [CaptionTrack] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.channel = channel
        self.likeStatus = likeStatus
        self.durationSeconds = durationSeconds
        self.formats = formats
        self.upNext = upNext
        self.chapters = chapters
        self.captions = captions
    }

    /// Chapters from the player bar, or parsed from the description's timestamps.
    public var effectiveChapters: [Chapter] {
        if !chapters.isEmpty { return chapters }
        return ChapterParser.chapters(fromDescription: description, duration: durationSeconds)
    }
}

public struct ShortDetails: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// `channel.avatar` comes from the reel overlay, when YouTube sends one.
    public var channel: ChannelSummary
    public var viewCountText: String?
    /// Compact like count ("12K"); nil when the reel overlay has none (likes hidden, or an answer
    /// without the overlay).
    public var likeCountText: String?
    /// Compact comment count ("1.2K"); nil when the reel overlay has none.
    public var commentsCountText: String?
    public var likeStatus: LikeStatus
    public var thumbnail: String?
    public var durationSeconds: Double?
    @DefaultEmpty public var formats: [StreamFormat] = []
    @DefaultEmpty public var captions: [CaptionTrack] = []
    public var playerClient: String?
    public var userAgent: String?
    @DefaultFalse public var trackingAvailable: Bool = false
}

public struct ShortsSequence: Codable, Hashable, Sendable {
    @DefaultEmpty public var ids: [String] = []
    public var continuation: String?

    public init(ids: [String] = [], continuation: String? = nil) {
        self.ids = ids
        self.continuation = continuation
    }
}

public struct ResolvedStreams: Codable, Hashable, Sendable {
    /// Format index (as string) -> deciphered googlevideo URL.
    public var urls: [String: String]
    public var userAgent: String?
    public var headers: [String: String]?

    public func url(for format: StreamFormat) -> URL? {
        urls[String(format.index)].flatMap(URL.init(string:))
    }
}

public struct PingResult: Codable, Hashable, Sendable {
    @DefaultFalse public var ok: Bool = false
    public var status: Int?
    public var cpn: String?
}
