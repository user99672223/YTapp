import Foundation
import Core

/// Keeps YouTube's watch history in sync for one playback: `addToWatchHistory` when playback
/// starts, a watch-time ping every 30 s with the played ranges (st/et), current time (cmt) and
/// state, and a final ping when playback stops.
@MainActor
final class PlaybackReporter {
    let videoId: String
    private let model: AppModel
    private let tracker = WatchTimeTracker()
    private var timer: Timer?
    private var started = false
    private var finished = false
    private var startDate = Date()
    private var lastActivity = Date()
    private var isPlaying = false
    private var length: Double?
    private var videoItag: Int?
    private var audioItag: Int?
    private(set) var lastStatus: String = "not started"

    init(videoId: String, model: AppModel) {
        self.videoId = videoId
        self.model = model
    }

    var isEnabled: Bool { model.isSignedIn }

    /// Call once the first frames play.
    func playbackStarted(length: Double?, videoItag: Int?, audioItag: Int?) {
        guard !started, isEnabled else { return }
        started = true
        startDate = Date()
        self.length = length
        self.videoItag = videoItag
        self.audioItag = audioItag
        let id = videoId
        let model = self.model
        Task { [weak self] in
            do {
                let result = try await model.api { try await $0.markWatched(videoId: id) }
                self?.lastStatus = result.ok ? "added to history" : "history ping HTTP \(result.status ?? 0)"
            } catch {
                let message = BridgeError.wrap(error).message
                self?.lastStatus = "history failed: \(message)"
                model.logs.append(.warn, "addToWatchHistory failed for \(id): \(message)")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing(final: false) }
        }
    }

    func tick(position: Double, isPlaying: Bool) {
        self.isPlaying = isPlaying
        tracker.record(position: position, isPlaying: isPlaying)
    }

    func seeked(to position: Double) {
        tracker.seeked(to: position, isPlaying: isPlaying)
        userActivity()
    }

    func userActivity() {
        lastActivity = Date()
    }

    /// Final ping; safe to call more than once.
    func stop() {
        timer?.invalidate()
        timer = nil
        guard started, !finished else { return }
        finished = true
        sendPing(final: true)
    }

    private func sendPing(final: Bool) {
        guard started else { return }
        let segments = tracker.flush()
        let report = WatchTimeReport(
            segments: segments,
            currentTime: tracker.currentPosition,
            isPlaying: final ? false : isPlaying,
            isFinal: final,
            length: length,
            lastActivityMs: Date().timeIntervalSince(lastActivity) * 1000,
            realTime: Date().timeIntervalSince(startDate),
            videoItag: videoItag,
            audioItag: audioItag
        )
        let id = videoId
        let model = self.model
        Task { [weak self] in
            do {
                let result = try await model.api { try await $0.watchtime(videoId: id, report: report) }
                self?.lastStatus = "watch-time ping \(result.ok ? "ok" : "HTTP \(result.status ?? 0)")\(final ? " (final)" : "")"
            } catch {
                self?.lastStatus = "watch-time failed: \(BridgeError.wrap(error).message)"
            }
        }
    }
}
