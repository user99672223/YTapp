import Foundation

/// When Tube asks the TV to switch its refresh rate to a video's frame rate (Settings → Match
/// frame rate). Every switch makes some TVs flicker for a while, so it is off by default.
public enum FrameRateMatching: String, CaseIterable, Codable, Sendable {
    /// Never switch; the TV stays at its home-screen rate.
    case off
    /// Only 23.976/24 fps videos switch the TV (to 24 Hz); everything else plays at the
    /// home-screen rate.
    case only24
    /// 24 fps → 24 Hz, 25/50 fps → 50 Hz, 30/60 fps → 60 Hz.
    case all

    public var label: String {
        switch self {
        case .off: return "Off"
        case .only24: return "24 fps videos only"
        case .all: return "All videos"
        }
    }
}
