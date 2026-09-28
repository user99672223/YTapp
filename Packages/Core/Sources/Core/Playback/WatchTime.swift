import Foundation

public struct WatchSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Parameters of one `videostats_watchtime_url` ping, like the web client sends them.
public struct WatchTimeReport: Equatable, Sendable {
    public var segments: [WatchSegment]
    public var currentTime: Double
    public var isPlaying: Bool
    public var isFinal: Bool
    public var length: Double?
    public var lastActivityMs: Double
    public var realTime: Double
    public var volume: Int
    public var muted: Bool
    public var videoItag: Int?
    public var audioItag: Int?

    public init(segments: [WatchSegment], currentTime: Double, isPlaying: Bool, isFinal: Bool, length: Double?,
                lastActivityMs: Double, realTime: Double, volume: Int = 100, muted: Bool = false,
                videoItag: Int? = nil, audioItag: Int? = nil) {
        self.segments = segments
        self.currentTime = currentTime
        self.isPlaying = isPlaying
        self.isFinal = isFinal
        self.length = length
        self.lastActivityMs = lastActivityMs
        self.realTime = realTime
        self.volume = volume
        self.muted = muted
        self.videoItag = videoItag
        self.audioItag = audioItag
    }

    /// Arguments for the bridge's `watchtime` method (st/et/cmt/state/...).
    public var bridgeArguments: [String: Any] {
        var args: [String: Any] = [
            "segments": segments.map { [rounded($0.start), rounded($0.end)] },
            "cmt": rounded(currentTime),
            "playing": isPlaying,
            "final": isFinal,
            "lact": Int(max(0, lastActivityMs)),
            "rt": rounded(realTime),
            "volume": volume,
            "muted": muted
        ]
        if let length { args["len"] = rounded(length) }
        if let videoItag { args["fmt"] = videoItag }
        if let audioItag { args["afmt"] = audioItag }
        return args
    }

    private func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}

/// Collects the ranges of media time actually played between two watch-time pings.
/// A jump (seek) or a pause closes the current range; the next ping reports every range since
/// the previous one (`st`/`et` lists), exactly like the web player.
public final class WatchTimeTracker {
    public let seekThreshold: Double
    private var segments: [WatchSegment] = []
    private var openStart: Double?
    private var lastPosition: Double?

    public init(seekThreshold: Double = 2.5) {
        self.seekThreshold = seekThreshold
    }

    /// Feed the playback position periodically (e.g. every 0.5 s).
    public func record(position: Double, isPlaying: Bool) {
        guard position.isFinite, position >= 0 else { return }
        guard isPlaying else {
            closeOpenSegment()
            lastPosition = position
            return
        }
        guard let start = openStart, let last = lastPosition else {
            openStart = position
            lastPosition = position
            return
        }
        let delta = position - last
        if delta < -0.25 || delta > seekThreshold {
            if last > start { segments.append(WatchSegment(start: start, end: last)) }
            openStart = position
        }
        lastPosition = position
    }

    /// Call when the user seeks.
    public func seeked(to position: Double, isPlaying: Bool) {
        closeOpenSegment()
        lastPosition = position
        if isPlaying { openStart = position }
    }

    /// Returns the ranges played since the last flush. An open range is split at the current
    /// position and continues from there.
    public func flush() -> [WatchSegment] {
        if let start = openStart, let last = lastPosition, last > start {
            segments.append(WatchSegment(start: start, end: last))
            openStart = last
        }
        let out = segments
        segments = []
        return out
    }

    public var currentPosition: Double { lastPosition ?? 0 }

    private func closeOpenSegment() {
        if let start = openStart, let last = lastPosition, last > start {
            segments.append(WatchSegment(start: start, end: last))
        }
        openStart = nil
    }
}

/// Where to start a video given a saved position.
public enum ResumePolicy {
    public static let minimumResume: Double = 15
    public static let endMargin: Double = 20

    public static func startPosition(saved: Double?, duration: Double?) -> Double? {
        guard let saved, saved.isFinite, saved >= minimumResume else { return nil }
        if let duration, duration > 0, saved >= duration - endMargin { return nil }
        return max(0, saved - 2)
    }

    public static func isFinished(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position >= duration - endMargin || position / duration >= 0.95
    }
}

/// Snaps a stream frame rate to a display refresh rate for frame-rate matching.
public enum RefreshRate {
    public static let standard: [Double] = [23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60]

    public static func match(fps: Double) -> Double? {
        guard fps.isFinite, fps >= 10 else { return nil }
        let best = standard.min(by: { abs($0 - fps) < abs($1 - fps) })!
        return abs(best - fps) <= 0.6 ? best : fps
    }
}
