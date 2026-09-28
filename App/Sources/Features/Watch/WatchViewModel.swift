import Foundation
import SwiftUI
import Core

/// One watch session: fetches the video, applies the quality rule, deciphers the chosen
/// formats, plays them with mpv (resume position, frame-rate matching) and keeps YouTube's
/// history in sync. Also owns the watch-page actions (like, subscribe, Watch Later, comments)
/// and up-next autoplay.
@MainActor
final class WatchViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading(String)
        case playing
        case failed(BridgeError)
    }

    @Published private(set) var phase: Phase = .loading("Loading video…")
    @Published private(set) var details: VideoDetails? = nil {
        didSet { chapters = details?.effectiveChapters ?? [] }
    }
    /// `details.effectiveChapters`, worked out once per video: parsing them from the description
    /// runs a regex, and the controls read them on every player update.
    private(set) var chapters: [Chapter] = []
    @Published private(set) var selection: StreamSelection?
    @Published private(set) var likeStatus: LikeStatus = .none
    @Published private(set) var isSubscribed: Bool?
    @Published private(set) var inWatchLater: Bool?
    @Published private(set) var activeCaption: CaptionTrack?
    @Published private(set) var countdown: Int?
    @Published var toast: String?
    @Published private(set) var historyStatus = ""
    @Published private(set) var appliedRefreshRate: Double?

    let player = MPVPlayer()
    let comments: CommentsModel
    private(set) var videoId: String
    private let model: AppModel
    private var reporter: PlaybackReporter?
    /// The video whose file was handed to mpv. Ticks, resume points and the end of file belong
    /// to it; `details` already shows the next video while that one is still loading.
    private var playingDetails: VideoDetails?
    private var overrideVideo: StreamFormat?
    private var overrideAudio: StreamFormat?
    private var countdownTask: Task<Void, Never>?
    private var startedPlayback = false
    private var lastSavedPosition: Double = 0
    private var waitingForDisplay = false
    /// Automatic reconnects after the stream broke off, per video (see `streamEndedEarly`).
    private var earlyEnds = 0
    private var closed = false
    private var toastTask: Task<Void, Never>?

    init(videoId: String, model: AppModel) {
        self.videoId = videoId
        self.model = model
        comments = CommentsModel(model: model)
        let logs = model.logs
        player.logSink = { level, line in logs.append(level, line) }
        player.onFileLoaded = { [weak self] in self?.fileLoaded() }
        player.onEndOfFile = { [weak self] end in self?.endOfFile(end) }
        player.onError = { [weak self] message in self?.playerFailed(message) }
        player.onTick = { [weak self] position, playing in self?.tick(position: position, playing: playing) }
        player.onPauseChanged = { [weak self] paused in self?.pauseChanged(paused) }
    }

    var nextVideo: VideoItem? {
        guard let details else { return nil }
        if let id = details.autoplayNextId, let item = details.upNext.first(where: { $0.id == id }) { return item }
        return details.upNext.first
    }

    var formatsForOverride: (video: [StreamFormat], audio: [StreamFormat]) {
        QualitySelector.overrideList(details?.formats ?? [])
    }

    var isOverridden: Bool { overrideVideo != nil || overrideAudio != nil }

    // MARK: - Loading

    func start() {
        Task { await load(videoId: videoId) }
    }

    func load(videoId: String) async {
        finishCurrent()
        // The previous video would keep playing behind the loading screen until the next
        // one's file reaches mpv.
        player.setPaused(true)
        self.videoId = videoId
        countdownTask?.cancel()
        countdown = nil
        comments.reset(videoId: videoId)
        overrideVideo = nil
        overrideAudio = nil
        activeCaption = nil
        earlyEnds = 0
        inWatchLater = nil
        historyStatus = ""
        phase = .loading("Loading video…")
        do {
            let client = model.settings.streamClient
            let cacheKey = "\(videoId)|\(client)"
            let cached = model.videoInfoCache.value(for: cacheKey)
            var fetched: VideoDetails
            if let cached {
                fetched = cached
            } else {
                fetched = try await fetchDetails(videoId, client: client)
            }
            guard !closed, self.videoId == videoId else { return }
            details = fetched
            likeStatus = fetched.likeStatus
            isSubscribed = fetched.channel.isSubscribed
            do {
                try await startPlayback(fetched, at: nil)
            } catch let error as BridgeError where error.kind == .expired && cached != nil {
                // The bridge no longer holds this video's player data; fetch it again.
                fetched = try await fetchDetails(videoId, client: client)
                guard !closed, self.videoId == videoId else { return }
                details = fetched
                try await startPlayback(fetched, at: nil)
            }
            loadWatchLaterStatus()
        } catch {
            guard !closed, self.videoId == videoId else { return }
            // Nothing of this video reached mpv; don't keep the previous one loaded behind the
            // error (it would hold the screensaver off once unpaused).
            player.stop()
            phase = .failed(Self.describe(error))
        }
    }

    private func fetchDetails(_ id: String, client: String) async throws -> VideoDetails {
        let fetched = try await model.api { try await $0.videoInfo(id, client: client) }
        model.videoInfoCache.set(fetched, for: "\(id)|\(client)", ttl: RefreshPolicy.ttl(.videoInfo))
        return fetched
    }

    private func invalidateCachedDetails() {
        guard let id = details?.id else { return }
        model.videoInfoCache.remove("\(id)|\(model.settings.streamClient)")
    }

    /// Re-fetches (stream URLs may have expired) and continues at the current position.
    func retry() {
        earlyEnds = 0
        reload("Retrying…")
    }

    /// Fetches the video again (fresh stream URLs) and continues at `explicit`, else where this
    /// video's file was.
    private func reload(_ message: String, at explicit: Double? = nil) {
        let id = videoId
        // Only this video's own position: if its load failed before the file reached mpv, the
        // player still holds the previous video's position, and the resume rule decides.
        let current = playingDetails?.id == id ? player.state.position : 0
        let position: Double? = explicit ?? (current > 1 ? current : nil)
        Task {
            phase = .loading(message)
            do {
                let fetched = try await fetchDetails(id, client: model.settings.streamClient)
                guard !closed, videoId == id else { return }
                details = fetched
                try await startPlayback(fetched, at: position)
            } catch {
                guard !closed, videoId == id else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    private func startPlayback(_ details: VideoDetails, at position: Double?) async throws {
        var chosen = try QualitySelector.select(details.formats, preferences: model.settings.quality)
        if let overrideVideo { chosen.video = overrideVideo }
        if let overrideAudio { chosen.audio = overrideAudio }
        selection = chosen
        phase = .loading("Unlocking the stream…")
        var formats = [chosen.video]
        if let audio = chosen.audio { formats.append(audio) }
        let streams = try await model.api { try await $0.resolveFormats(videoId: details.id, formats: formats) }
        guard !closed, videoId == details.id else { return }
        guard let videoURL = streams.url(for: chosen.video) else {
            throw BridgeError(kind: .extraction, message: "YouTube didn't return a URL for the chosen video stream.")
        }
        let audioURL = chosen.audio.flatMap { streams.url(for: $0) }
        let saved = model.store.resumePosition(for: details.id)?.position
        let start = position ?? ResumePolicy.startPosition(saved: saved, duration: details.durationSeconds)
        reporter?.stop()
        reporter = PlaybackReporter(videoId: details.id, model: model)
        playingDetails = details
        startedPlayback = false
        lastSavedPosition = start ?? 0
        waitingForDisplay = true
        let settings = model.settings
        player.setSpeed(settings.playbackSpeed)
        player.load(MPVPlayer.Source(
            videoURL: videoURL,
            audioURL: audioURL,
            userAgent: streams.userAgent ?? details.userAgent ?? "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
            headers: streams.headers ?? [:],
            startTime: start,
            hardwareDecode: chosen.video.codecFamily == .avc && settings.hardwareDecodeH264,
            loop: false,
            startPaused: true
        ))
        phase = .playing
    }

    /// File is open (paused): match the display's frame rate, then start playing.
    private func fileLoaded() {
        guard waitingForDisplay else { return }
        waitingForDisplay = false
        Task {
            // Give mpv a moment to report the container frame rate.
            var fps = player.state.stats.containerFps
            for _ in 0..<10 where fps <= 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                fps = player.state.stats.containerFps
            }
            if fps <= 0 { fps = selection?.video.fps ?? 0 }
            let width = selection?.video.width ?? 1920
            let height = selection?.video.height ?? 1080
            appliedRefreshRate = fps > 0 ? DisplayCriteriaController.apply(fps: fps, width: width, height: height) : nil
            if appliedRefreshRate != nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
                var waited = 0
                while DisplayCriteriaController.isSwitching, waited < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }
            guard !closed else { return }
            player.setPaused(false)
            applyDefaultCaptions()
        }
    }

    private func applyDefaultCaptions() {
        guard model.settings.captionsEnabled, let details else { return }
        let language = model.settings.captionsLanguage
        let track = details.captions.first { $0.languageCode == language && !$0.isAuto }
            ?? details.captions.first { $0.languageCode.hasPrefix(language) }
        if let track { setCaption(track) }
    }

    private func tick(position: Double, playing: Bool) {
        // Between switching videos and the next file reaching mpv, nothing is playing for us.
        guard let playingDetails else { return }
        reporter?.tick(position: position, isPlaying: playing)
        if playing, !startedPlayback, position > 0.3 {
            startedPlayback = true
            reporter?.playbackStarted(length: playingDetails.durationSeconds, videoItag: selection?.video.itag, audioItag: selection?.audio?.itag)
        }
        if abs(position - lastSavedPosition) >= 10 {
            lastSavedPosition = position
            saveResume(position)
        }
        if let reporter, historyStatus != reporter.lastStatus { historyStatus = reporter.lastStatus }
        PlaybackDiagnostics.shared.update(videoId: playingDetails.id, title: playingDetails.title, client: playingDetails.playerClient,
                                          selection: selection, state: player.state,
                                          refreshRate: appliedRefreshRate, history: historyStatus)
    }

    private func pauseChanged(_ paused: Bool) {
        guard playingDetails != nil else { return }
        reporter?.setPlaying(!paused, position: player.state.position)
    }

    private func saveResume(_ position: Double) {
        guard let playingDetails else { return }
        model.store.saveResume(videoId: playingDetails.id, position: position,
                               duration: playingDetails.durationSeconds ?? player.state.duration)
    }

    private func endOfFile(_ end: MPVPlayer.EndOfFile) {
        guard !closed, let playingDetails else { return }
        // A natural end is at the duration (mpv's time-pos at keep-open EOF is the last frame).
        let duration = end.duration > 0 ? end.duration : (playingDetails.durationSeconds ?? 0)
        if duration > 0, end.position < duration - max(5, duration * 0.01) {
            streamEndedEarly(end, duration: duration)
            return
        }
        reporter?.stop()
        model.store.saveResume(videoId: playingDetails.id, position: playingDetails.durationSeconds ?? player.state.duration,
                               duration: playingDetails.durationSeconds ?? 0)
        guard model.settings.autoplay, nextVideo != nil else { return }
        startCountdown()
    }

    /// The stream broke off before the end (expired links, HTTP 403, a connection that stayed
    /// down); mpv reports that as an ordinary end of file. Don't mark the video finished or
    /// autoplay the next one: fetch fresh stream links and continue where it stopped, twice per
    /// video, then show the error with Retry.
    private func streamEndedEarly(_ end: MPVPlayer.EndOfFile, duration: Double) {
        let at = "\(Formatters.duration(end.position)) of \(Formatters.duration(duration))"
        let reason = end.problem.map { " (\($0))" } ?? ""
        model.logs.append(.error, "The stream of \(videoId) ended early at \(at)\(reason)")
        saveResume(end.position)
        if earlyEnds < 2 {
            earlyEnds += 1
            reload("Reconnecting…", at: end.position)
        } else {
            phase = .failed(Self.playbackError("The video stream stopped at \(at)\(reason).", stream: selection?.summary))
        }
    }

    private func playerFailed(_ message: String) {
        guard !closed else { return }
        phase = .failed(Self.playbackError(message, stream: selection?.summary))
    }

    // MARK: - Up next

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 8
        countdownTask = Task {
            while let value = countdown, value > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown = value - 1
            }
            if !Task.isCancelled { playNext() }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
    }

    func playNext() {
        countdownTask?.cancel()
        countdown = nil
        guard let next = nextVideo else { return }
        Task { await load(videoId: next.id) }
    }

    func play(_ video: VideoItem) {
        cancelCountdown()
        Task { await load(videoId: video.id) }
    }

    // MARK: - Transport

    func togglePlay() {
        reporter?.userActivity()
        if player.state.isEOF {
            seek(to: 0)
            player.setPaused(false)
            return
        }
        player.togglePause()
    }

    func seek(by delta: Double) {
        let target = max(0, min(player.state.position + delta, max(player.state.duration - 1, 0)))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        cancelCountdown()
        player.seek(to: seconds)
        reporter?.seeked(to: seconds)
    }

    func setSpeed(_ speed: Double) {
        player.setSpeed(speed)
        model.settings.playbackSpeed = speed
    }

    func setCaption(_ track: CaptionTrack?) {
        activeCaption = track
        if let track {
            player.addSubtitle(url: track.url, title: track.name, language: track.languageCode)
        } else {
            player.disableSubtitles()
        }
    }

    /// Manual override from the quality menu; restarts at the current position.
    func choose(video: StreamFormat?, audio: StreamFormat?) {
        if let video { overrideVideo = video }
        if let audio { overrideAudio = audio }
        restartAtCurrentPosition()
    }

    func resetQualityOverride() {
        overrideVideo = nil
        overrideAudio = nil
        restartAtCurrentPosition()
    }

    private func restartAtCurrentPosition() {
        guard let details else { return }
        // While a newly picked video is still loading, the player holds the previous one.
        let position: Double? = playingDetails?.id == details.id ? player.state.position : nil
        Task {
            do {
                try await startPlayback(details, at: position)
            } catch {
                guard !closed, videoId == details.id else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Actions

    func rate(_ target: LikeStatus) {
        guard let id = details?.id else { return }
        let desired: LikeStatus = likeStatus == target ? .none : target
        let previous = likeStatus
        likeStatus = desired
        invalidateCachedDetails()
        Task {
            do {
                likeStatus = try await model.api { try await $0.rate(videoId: id, desired) }
            } catch {
                likeStatus = previous
                show("Couldn't update the rating: \(BridgeError.wrap(error).userMessage)")
            }
        }
    }

    func toggleSubscription() {
        guard let channelId = details?.channel.id else { return }
        let target = !(isSubscribed ?? false)
        invalidateCachedDetails()
        Task {
            do {
                isSubscribed = try await model.api { try await $0.setSubscribed(channelId: channelId, target) }
                show(target ? "Subscribed" : "Unsubscribed")
            } catch {
                show("Couldn't change the subscription: \(BridgeError.wrap(error).userMessage)")
            }
        }
    }

    func toggleWatchLater() {
        guard let id = details?.id else { return }
        let target = !(inWatchLater ?? false)
        Task {
            do {
                inWatchLater = try await model.api { try await $0.setWatchLater(videoId: id, target) }
                show(target ? "Saved to Watch Later" : "Removed from Watch Later")
            } catch {
                show("Watch Later failed: \(BridgeError.wrap(error).userMessage)")
            }
        }
    }

    private func loadWatchLaterStatus() {
        guard model.isSignedIn, let id = details?.id else { return }
        Task {
            if let status = try? await model.api({ try await $0.watchLaterStatus(videoId: id) }) {
                inWatchLater = status
            }
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Teardown

    private func finishCurrent() {
        if player.state.isFileLoaded, player.state.position > 0 { saveResume(player.state.position) }
        reporter?.stop()
        reporter = nil
        playingDetails = nil
    }

    func close() {
        guard !closed else { return }
        finishCurrent()
        closed = true
        countdownTask?.cancel()
        player.destroy()
        DisplayCriteriaController.reset()
    }

    /// A player failure, shown with mpv's actual reason (as a network error the screen would only
    /// say to check the internet connection).
    static func playbackError(_ message: String, stream: String?) -> BridgeError {
        let refused = message.contains("HTTP error 403") || message.contains("403 Forbidden")
        let hint = refused
            ? "YouTube refused the stream. Press Retry for fresh stream links, or pick another stream client in Settings."
            : "Press Retry to try again."
        return BridgeError(kind: .unknown, message: "\(message) \(hint)", detail: "Stream: \(stream ?? "?")")
    }

    static func describe(_ error: Error) -> BridgeError {
        if let quality = error as? QualityError {
            return BridgeError(kind: .unavailable, message: quality.errorDescription ?? "No playable stream.")
        }
        return BridgeError.wrap(error)
    }
}
