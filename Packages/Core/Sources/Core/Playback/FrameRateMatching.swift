import Foundation

/// When Tube asks the TV to switch its refresh rate to a video's frame rate (Settings → Match
/// frame rate). Every switch makes some TVs flicker for a while, so it is off by default.
public enum FrameRateMatching: String, CaseIterable, Codable, Sendable {
    /// Never switch; the TV stays at its home-screen rate.
    case off
    /// Only 23.976/24 fps videos switch the TV (to 24 Hz); everything else plays at the
    /// home-screen rate.
    case only24
    /// 24 fps → 24 Hz, 25/50 fps → 50 Hz, 30/60 fps → 60 Hz; other rates don't switch.
    case all

    public var label: String {
        switch self {
        case .off: return "Off"
        case .only24: return "24 fps videos only"
        case .all: return "All videos"
        }
    }
}

/// Video frame rates and the display refresh rates they are shown at.
public enum RefreshRate {
    public static let standard: [Double] = [23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60]

    /// The nearest standard rate (within 0.6 fps), else the rate itself. What Tube asks the TV
    /// for is `target(fps:)`.
    public static func match(fps: Double) -> Double? {
        guard fps.isFinite, fps >= 10 else { return nil }
        let best = standard.min(by: { abs($0 - fps) < abs($1 - fps) })!
        return abs(best - fps) <= 0.6 ? best : fps
    }

    /// The refresh rate Tube asks the TV for when a video plays with frame-rate matching on:
    /// 23.976/24 fps → 24 Hz, 25/50 fps → 50 Hz, 29.97/30/59.94/60 fps → 60 Hz. Any other rate
    /// (15, 48, 120 fps…) has no mode of its own and never switches the TV.
    ///
    /// A whole-number mode stands in for its 1000/1001 sibling, so a 23.976 fps video after a
    /// 24 fps one (or 59.94 after 60) keeps the mode instead of flickering the TV again; the cost
    /// is one repeated frame about every 42 s. 25 and 30 fps are shown at 50 and 60 Hz (every
    /// frame twice), never at 25/30 Hz: tvOS picks those modes for a 25/30 Hz request anyway, and
    /// asking for them directly lets a 50 fps video after a 25 fps one keep the mode.
    public static func target(fps: Double) -> Double? {
        guard fps.isFinite, fps > 0 else { return nil }
        let families: [(rates: [Double], refresh: Double)] = [([24], 24), ([25, 50], 50), ([30, 60], 60)]
        return families.first(where: { family in family.rates.contains { abs(fps - $0) <= 0.5 } })?.refresh
    }

    /// The TV's own refresh rate (the format picked in Apple TV Settings → Video and Audio) from
    /// the frame rate the screen reports while no app asks for another: 50 when it says 50, else
    /// 60. tvOS has no API that names the home format, and a 24 Hz reading can only be a switch
    /// still in effect, so everything but 50 counts as the usual 60.
    public static func home(screenFramesPerSecond fps: Int) -> Double {
        (49...51).contains(fps) ? 50 : 60
    }

    /// The frame rate a video is matched by. mpv's container rate tells 23.976 from 24 (YouTube's
    /// formats only list whole numbers), but it "can easily contain bogus values" (mpv manual), so
    /// it counts only when it agrees with the listed rate within 1 fps. 0 when neither is known.
    public static func videoRate(container: Double, listed: Double?) -> Double {
        let container = container.isFinite && container > 0 ? container : 0
        guard let listed, listed.isFinite, listed > 0 else { return container }
        return abs(container - listed) <= 1 ? container : listed
    }

    /// "23.976", "24", "59.94": a rate for log lines.
    public static func format(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Decides when one watch session (one player) changes the TV's refresh rate; the app applies
/// the decisions to `AVDisplayManager`. Every mode change blanks the picture and makes some TVs
/// flicker for a while afterwards, so the rules aim at as few changes as possible:
/// - Off never touches the display, not even to reset it.
/// - A video decides once, with its first file. Quality changes, Retry and reconnects of the same
///   video keep whatever mode is on.
/// - Only a rate different from the one in effect is requested, so consecutive videos of the same
///   rate (autoplay, Up next) keep the mode.
/// - 24 fps videos only: any other video while the TV is at 24 Hz goes back to the home rate
///   (60 fps at 24 Hz would drop most frames); at the home rate it doesn't switch.
/// - Leaving the player restores the home rate, and only if Tube changed it.
public struct FrameRateSwitcher: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Leave the display as it is.
        case keep
        /// Ask the TV for this refresh rate.
        case switchTo(Double)
        /// Drop Tube's request (`preferredDisplayCriteria = nil`): the TV goes back to its own rate.
        case resetToHome
    }

    /// A decision and its log line, e.g. "display: 23.976 fps → switching to 24 Hz (was 60 Hz)".
    /// Every requested mode change says "switching to" or "reset to home".
    public struct Outcome: Equatable, Sendable {
        public var decision: Decision
        public var message: String

        public init(decision: Decision, message: String) {
            self.decision = decision
            self.message = message
        }
    }

    /// The rate Tube has asked for; nil while the TV is at its home rate.
    public private(set) var requested: Double?
    /// The TV's own rate, in effect whenever Tube hasn't asked for another.
    public private(set) var homeRate: Double
    private var decidedVideoId: String?

    public init(homeRate: Double = 60) {
        self.homeRate = homeRate
    }

    /// The rate the TV is at, as far as Tube knows.
    public var current: Double { requested ?? homeRate }

    /// Whether this video already decided (a restart of it keeps the mode, see `decide`).
    public func hasDecided(_ videoId: String) -> Bool {
        decidedVideoId == videoId
    }

    /// Decides for a file that is about to play. `homeRate` is the TV's own rate as the screen
    /// reports it now; it is taken only while Tube has no rate requested (otherwise the screen
    /// shows Tube's rate, not the home one).
    public mutating func decide(videoId: String, fps: Double, mode: FrameRateMatching,
                                homeRate reported: Double? = nil) -> Outcome {
        if requested == nil, let reported, reported.isFinite, reported > 0 { homeRate = reported }
        if mode == .off {
            decidedVideoId = videoId
            return keep("display: matching off")
        }
        if decidedVideoId == videoId {
            return keep("display: same video again (quality change, Retry or reconnect) → keeping \(hz(current))")
        }
        decidedVideoId = videoId
        guard fps.isFinite, fps > 0 else {
            return keep("display: frame rate unknown → keeping \(hz(current))")
        }
        let video = "\(RefreshRate.format(fps)) fps"
        let target = RefreshRate.target(fps: fps)
        switch mode {
        case .off:
            return keep("display: matching off")
        case .only24:
            if target == 24 { return move(to: 24, for: video) }
            if requested != nil { return resetToHome(for: video) }
            return keep("display: \(video) → keeping \(hz(current)) (only 24 fps videos switch)")
        case .all:
            guard let target else {
                return keep("display: \(video) → no matching refresh rate, keeping \(hz(current))")
            }
            return move(to: target, for: video)
        }
    }

    /// Leaving the player: the TV goes back to its home rate if Tube changed it. The next session
    /// decides every video afresh.
    public mutating func leave() -> Outcome {
        decidedVideoId = nil
        guard let was = requested else { return keep("display: leaving player → nothing to reset") }
        requested = nil
        return Outcome(decision: .resetToHome, message: "display: leaving player → reset to home \(hz(homeRate)) (was \(hz(was)))")
    }

    private mutating func move(to target: Double, for video: String) -> Outcome {
        if target == current { return keep("display: \(video) → keeping \(hz(target))") }
        if target == homeRate { return resetToHome(for: video) }
        let was = current
        requested = target
        return Outcome(decision: .switchTo(target), message: "display: \(video) → switching to \(hz(target)) (was \(hz(was)))")
    }

    private mutating func resetToHome(for video: String) -> Outcome {
        let was = current
        requested = nil
        return Outcome(decision: .resetToHome, message: "display: \(video) → reset to home \(hz(homeRate)) (was \(hz(was)))")
    }

    private func keep(_ message: String) -> Outcome {
        Outcome(decision: .keep, message: message)
    }

    private func hz(_ rate: Double) -> String {
        "\(RefreshRate.format(rate)) Hz"
    }
}
