import Foundation

/// The user's quality rule. Default: AV1 > VP9 > H.264, highest resolution up to 2160p,
/// Opus audio (highest bitrate, itag 251) else AAC. No adaptive switching.
public struct QualityPreferences: Codable, Hashable, Sendable {
    public var maxHeight: Int
    public var codecOrder: [CodecFamily]
    public var allowSuperResolution: Bool

    public init(maxHeight: Int = 2160, codecOrder: [CodecFamily] = [.av1, .vp9, .avc], allowSuperResolution: Bool = false) {
        self.maxHeight = maxHeight
        self.codecOrder = codecOrder
        self.allowSuperResolution = allowSuperResolution
    }

    public static let `default` = QualityPreferences()
}

public struct StreamSelection: Hashable, Sendable {
    public var video: StreamFormat
    public var audio: StreamFormat?

    public init(video: StreamFormat, audio: StreamFormat?) {
        self.video = video
        self.audio = audio
    }

    public var summary: String {
        [video.displayName, audio?.displayName].compactMap { $0 }.joined(separator: " + ")
    }
}

public enum QualityError: Error, Equatable, LocalizedError {
    case noVideoFormats(String)
    case noPlayableVideo(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoFormats(let why), .noPlayableVideo(let why): return why
        }
    }
}

public extension StreamFormat {
    /// The resolution a video format is labelled with ("1080p"): its shorter side. YouTube
    /// reports vertical videos at their real size, so a 1080p Short is 1080×1920.
    var shortSide: Int {
        let h = height ?? 0
        guard let w = width, w > 0, h > 0 else { return h }
        return min(w, h)
    }
}

public enum QualitySelector {
    /// Formats that can be played as a single progressive file: have a URL (or cipher), are not
    /// DRM protected and not OTF/segmented (live).
    public static func isStreamable(_ f: StreamFormat) -> Bool {
        f.hasUrl && !f.isDrm && !f.isOtf
    }

    /// Video-only adaptive formats the TV can show (SDR only). The maximum quality applies to
    /// the short side, so vertical videos are capped like landscape ones.
    public static func videoCandidates(_ formats: [StreamFormat], preferences: QualityPreferences = .default) -> [StreamFormat] {
        formats.filter { f in
            f.hasVideo && !f.hasAudio && isStreamable(f) && !f.isHdr &&
                preferences.codecOrder.contains(f.codecFamily) &&
                f.shortSide > 0 && f.shortSide <= preferences.maxHeight
        }
    }

    public static func audioCandidates(_ formats: [StreamFormat]) -> [StreamFormat] {
        formats.filter { $0.hasAudio && !$0.hasVideo && isStreamable($0) && ($0.codecFamily == .opus || $0.codecFamily == .aac) }
    }

    /// Highest resolution first; within a resolution the codec order (AV1 > VP9 > H.264),
    /// then higher frame rate, then higher bitrate.
    public static func selectVideo(_ formats: [StreamFormat], preferences: QualityPreferences = .default) -> StreamFormat? {
        var candidates = videoCandidates(formats, preferences: preferences)
        if !preferences.allowSuperResolution {
            let native = candidates.filter { !$0.isSuperResolution }
            if !native.isEmpty { candidates = native }
        }
        func rank(_ family: CodecFamily) -> Int { preferences.codecOrder.firstIndex(of: family) ?? Int.max }
        return candidates.sorted { a, b in
            let ha = a.shortSide, hb = b.shortSide
            if ha != hb { return ha > hb }
            let ra = rank(a.codecFamily), rb = rank(b.codecFamily)
            if ra != rb { return ra < rb }
            let fa = a.fps ?? 0, fb = b.fps ?? 0
            if fa != fb { return fa > fb }
            return (a.bitrate ?? 0) > (b.bitrate ?? 0)
        }.first
    }

    /// Opus with the highest bitrate (itag 251), else AAC. Prefers the default/original audio
    /// track and non-DRC variants.
    public static func selectAudio(_ formats: [StreamFormat]) -> StreamFormat? {
        var candidates = audioCandidates(formats)
        guard !candidates.isEmpty else { return nil }
        let defaults = candidates.filter { $0.isDefaultAudio == true }
        if !defaults.isEmpty {
            candidates = defaults
        } else {
            let originals = candidates.filter { $0.isOriginal == true }
            if !originals.isEmpty { candidates = originals }
        }
        let clean = candidates.filter { $0.isAutoDubbed != true && $0.isDescriptive != true }
        if !clean.isEmpty { candidates = clean }
        let nonDrc = candidates.filter { !$0.isDrc }
        if !nonDrc.isEmpty { candidates = nonDrc }
        let opus = candidates.filter { $0.codecFamily == .opus }
        let pool = opus.isEmpty ? candidates : opus
        return pool.sorted { a, b in
            if (a.itag == 251) != (b.itag == 251) { return a.itag == 251 }
            return (a.bitrate ?? 0) > (b.bitrate ?? 0)
        }.first
    }

    public static func select(_ formats: [StreamFormat], preferences: QualityPreferences = .default) throws -> StreamSelection {
        let videos = formats.filter { $0.hasVideo }
        if videos.isEmpty {
            throw QualityError.noVideoFormats("YouTube didn't return any video streams for this video. Live streams and some premieres are only offered as HLS/DASH manifests, which this app doesn't use.")
        }
        guard let video = selectVideo(formats, preferences: preferences) else {
            if videos.allSatisfy({ $0.isOtf }) {
                throw QualityError.noPlayableVideo("This is a live or segmented stream. It is only available as HLS/DASH, which this app doesn't play.")
            }
            if videos.allSatisfy({ !$0.hasUrl }) {
                throw QualityError.noPlayableVideo("YouTube only offered this video through SABR streaming for the selected client. Pick another stream client in Settings.")
            }
            if videos.allSatisfy({ $0.isDrm }) {
                throw QualityError.noPlayableVideo("This video is DRM protected and can't be played here.")
            }
            throw QualityError.noPlayableVideo("None of the video streams match the quality rule (SDR, AV1/VP9/H.264, up to \(preferences.maxHeight)p).")
        }
        return StreamSelection(video: video, audio: selectAudio(formats))
    }

    /// Every format for the manual override list, best first.
    public static func overrideList(_ formats: [StreamFormat]) -> (video: [StreamFormat], audio: [StreamFormat]) {
        let video = formats.filter { $0.hasVideo && !$0.hasAudio }.sorted {
            if $0.shortSide != $1.shortSide { return $0.shortSide > $1.shortSide }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo }.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }
        return (video, audio)
    }
}
