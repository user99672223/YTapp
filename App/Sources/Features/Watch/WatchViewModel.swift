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
    /// The refresh rate this session asked the TV for; nil while the TV is at its own rate.
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
    // Periodic playback line in the log (what the Apple TV sustains for the chosen stream).
    private var statsLoggedAt = Date.distantPast
    private var statsDroppedAtLog = 0
    private var lastSavedPosition: Double = 0
    private var waitingForDisplay = false
    /// Bumped for every file handed to mpv, so a `fileLoaded` task of an older one stops.
    private var playbackToken = 0
    private var inBackground = false
    /// Automatic reconnects after the stream broke off, per video (see `streamEndedEarly`).
    private var earlyEnds = 0
    /// Captions were set up for this video (from Settings or by the viewer); later files of the
    /// same video get `activeCaption` back instead of the default.
    private var captionsApplied = false
    private var closed = false
    private var toastTask: Task<Void, Never>?
    /// Settings → Match frame rate for this player session: when the TV changes its refresh
    /// rate, at most once per video, and back when the page closes.
    private var displaySwitcher = FrameRateSwitcher()

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
        player.onSubtitleFailed = { [weak self] message in self?.captionFailed(message) }
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
        // Its `fileLoaded` task (frame-rate switch, captions, unpause) may still be waiting, or
        // its FILE_LOADED still on the way: neither may unpause it or pick captions now.
        playbackToken += 1
        waitingForDisplay = false
        self.videoId = videoId
        countdownTask?.cancel()
        countdown = nil
        comments.reset(videoId: videoId)
        overrideVideo = nil
        overrideAudio = nil
        activeCaption = nil
        captionsApplied = false
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
        let preferences = model.settings.quality
        var chosen = try QualitySelector.select(details.formats, preferences: preferences)
        var unlimited = preferences
        unlimited.decodeBudget = nil
        if let best = QualitySelector.selectVideo(details.formats, preferences: unlimited), best.itag != chosen.video.itag {
            model.logs.append(.info, "quality: \(best.displayName) is more than this Apple TV decodes smoothly; playing \(chosen.video.displayName)")
        }
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
        playbackToken += 1
        startedPlayback = false
        statsLoggedAt = .distantPast
        statsDroppedAtLog = 0
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

    /// File is open (paused): match the display's refresh rate (Settings → Match frame rate), then
    /// start playing.
    private func fileLoaded() {
        guard waitingForDisplay else { return }
        waitingForDisplay = false
        let token = playbackToken
        Task {
            if await matchDisplayRate(token: token) {
                // The TV blanks while it changes modes; start the video once it shows again.
                try? await Task.sleep(nanoseconds: 300_000_000)
                var waited = 0
                while DisplayCriteriaController.isSwitching, waited < 50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
            }
            guard !closed, token == playbackToken else { return }
            applyCaptions()
            // If the TV button was pressed while the video opened, it stays paused (as after
            // leaving during playback) instead of playing on in the background.
            if !inBackground { player.setPaused(false) }
        }
    }

    /// Applies `FrameRateSwitcher`'s decision for the file that just opened. Returns whether the TV
    /// was asked to change modes (the video then waits for the switch). Off never touches the
    /// display; restarts of the same video (quality change, Retry, reconnect) keep the mode.
    private func matchDisplayRate(token: Int) async -> Bool {
        guard !closed, token == playbackToken, let id = playingDetails?.id else { return false }
        let mode = model.settings.frameRateMatching
        let firstFile = !displaySwitcher.hasDecided(id)
        if mode != .off, firstFile, let reason = DisplayCriteriaController.unavailableReason {
            noteDisplay("display: not switching: \(reason)")
            return false
        }
        let listed = selection?.video.fps
        var fps = RefreshRate.videoRate(container: player.state.stats.containerFps, listed: listed)
        if mode != .off, firstFile, fps <= 0 {
            // Without YouTube's frame rate, give mpv a moment to report the container's.
            for _ in 0..<10 where fps <= 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if closed || token != playbackToken { return false }
                fps = RefreshRate.videoRate(container: player.state.stats.containerFps, listed: listed)
            }
        }
        // Closing the page resets the display; a switch requested after that would leave the
        // whole app at the video's refresh rate.
        guard !closed, token == playbackToken else { return false }
        let before = displaySwitcher
        let outcome = displaySwitcher.decide(videoId: id, fps: fps, mode: mode,
                                             homeRate: mode == .off ? nil : DisplayCriteriaController.homeRate)
        noteDisplay(outcome.message)
        var changed = true
        switch outcome.decision {
        case .keep:
            changed = false
        case .switchTo(let rate):
            let width = selection?.video.width ?? 1920
            let height = selection?.video.height ?? 1080
            if !DisplayCriteriaController.request(refreshRate: rate, width: width, height: height) {
                displaySwitcher = before
                noteDisplay("display: couldn't describe the video format → keeping \(RefreshRate.format(before.current)) Hz")
                changed = false
            }
        case .resetToHome:
            DisplayCriteriaController.reset()
        }
        if appliedRefreshRate != displaySwitcher.requested { appliedRefreshRate = displaySwitcher.requested }
        return changed
    }

    /// Frame-rate lines go to the TV log (category "display") and the Debug screen's log.
    private func noteDisplay(_ line: String) {
        DisplayCriteriaController.note(line)
        model.logs.append(.info, line)
    }

    /// A new file starts without captions. The first file of a video gets the default from
    /// Settings; after a restart of the same video (quality change, Retry, reconnect) the
    /// viewer's choice comes back, and nothing if they switched captions off.
    private func applyCaptions() {
        guard let details = playingDetails else { return }
        if captionsApplied {
            // Retry fetched the video again, with fresh caption URLs.
            if let current = activeCaption { setCaption(details.captions.first { $0.id == current.id } ?? current) }
            return
        }
        captionsApplied = true
        guard model.settings.captionsEnabled else { return }
        let language = model.settings.captionsLanguage
        let track = details.captions.first { $0.languageCode == language && !$0.isAuto }
            ?? details.captions.first { $0.languageCode.hasPrefix(language) }
        if let track { setCaption(track) }
    }

    private func captionFailed(_ message: String) {
        guard activeCaption != nil else { return }
        activeCaption = nil
        show(message)
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
        logPlaybackStatsIfDue(playing: playing, videoId: playingDetails.id)
    }

    /// Every 30 s of playback one log line: resolution, codec, decoder, frames dropped since the
    /// last line, A/V sync, CPU and buffer. Shows whether the TV keeps up with the chosen stream.
    private func logPlaybackStatsIfDue(playing: Bool, videoId: String) {
        let now = Date()
        guard playing, now.timeIntervalSince(statsLoggedAt) >= 30 else { return }
        let stats = player.state.stats
        let first = statsLoggedAt == .distantPast
        let dropped = max(0, stats.droppedFrames - statsDroppedAtLog)
        statsLoggedAt = now
        statsDroppedAtLog = stats.droppedFrames
        guard !first else { return }
        let fps = String(format: "%.2f", stats.estimatedFps)
        let avsync = String(format: "%.3f", stats.avsync)
        let cpu = String(format: "%.0f", ProcessStats.cpuPercent())
        model.logs.append(.info, "playback \(videoId): \(stats.width)x\(stats.height) \(stats.videoCodec) \(fps) fps hw:\(stats.hwdec), \(dropped) frames dropped in 30 s, avsync \(avsync) s, cpu \(cpu)%, buffer \(Int(stats.bufferedSeconds)) s")
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
        guard model.settings.autoplay, !inBackground, nextVideo != nil else { return }
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

    /// Leaving the app (TV button) pauses, like the YouTube app, and cancels autoplay; a video
    /// that is still opening stays paused too.
    func setInBackground(_ background: Bool) {
        guard background != inBackground else { return }
        inBackground = background
        guard background else { return }
        player.setPaused(true)
        cancelCountdown()
    }

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
        captionsApplied = true
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
                // The current file is still loaded; don't let it play on behind the error.
                player.setPaused(true)
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
                FeedModel.markChanged(cacheKey: "playlist:WL")
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
        // Back to the TV's own rate, and only if this session changed it: with matching off, or
        // when every video kept the mode, the display isn't touched.
        let outcome = displaySwitcher.leave()
        noteDisplay(outcome.message)
        if outcome.decision == .resetToHome { DisplayCriteriaController.reset() }
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
        if let bridge = error as? BridgeError, bridge.kind == .expired {
            // resolveFormats: the stream links are about to expire, or the video was loaded again
            // since (another client, or as a Short). BridgeError's own text is about lists, and
            // Retry here loads the video's details again.
            return BridgeError(kind: .unknown,
                               message: "The stream links for this video are out of date. Press Retry to load them again.",
                               detail: bridge.message)
        }
        return BridgeError.wrap(error)
    }
}
