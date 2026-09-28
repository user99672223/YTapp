import Foundation
import Core

/// Last known playback details for the debug screen (updated by the players about once a second).
@MainActor
final class PlaybackDiagnostics: ObservableObject {
    static let shared = PlaybackDiagnostics()

    struct Snapshot: Equatable {
        var videoId = ""
        var title = ""
        var client = ""
        var selection = ""
        var stats = MPVPlayer.Stats()
        var position: Double = 0
        var duration: Double = 0
        var isBuffering = false
        var refreshRate: Double?
        var history = ""
        var error: String?
        var updated = Date.distantPast
    }

    @Published private(set) var snapshot = Snapshot()
    private var lastUpdate = Date.distantPast

    func update(videoId: String, title: String?, client: String?, selection: StreamSelection?, state: MPVPlayer.State,
                refreshRate: Double?, history: String) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = now
        snapshot = Snapshot(videoId: videoId, title: title ?? "", client: client ?? "", selection: selection?.summary ?? "",
                            stats: state.stats, position: state.position, duration: state.duration,
                            isBuffering: state.isBuffering, refreshRate: refreshRate, history: history,
                            error: state.errorMessage, updated: now)
    }
}
