import Foundation
import QuartzCore
import Libmpv
import Core

/// Thin libmpv wrapper. Video URL is the file, audio URL is added via `audio-files`; software
/// decoding for AV1/VP9/Opus (hwdec only for H.264/HEVC), big demuxer cache, no ytdl.
///
/// Every `load` starts a new generation: ticks, file-loaded, end-of-file and playback errors of
/// an earlier file that are still on their way never reach the callbacks of the next one.
final class MPVPlayer: @unchecked Sendable {
    struct Source {
        var videoURL: URL
        var audioURL: URL?
        var userAgent: String
        var headers: [String: String]
        var startTime: Double?
        var hardwareDecode: Bool
        var loop: Bool
        var startPaused: Bool
    }

    struct Stats: Equatable {
        var videoCodec: String = ""
        var audioCodec: String = ""
        var hwdec: String = ""
        var width: Int = 0
        var height: Int = 0
        var containerFps: Double = 0
        var estimatedFps: Double = 0
        var droppedFrames: Int = 0
        var decoderDroppedFrames: Int = 0
        var avsync: Double = 0
        var cacheSpeed: Double = 0
        var bufferedSeconds: Double = 0
        var bufferingPercent: Int = 0
        var pausedForCache: Bool = false
        var demuxerCacheBytes: Int = 0
    }

    /// Where a file ended. mpv also reports a stream that broke off for good (expired links,
    /// HTTP 403, a connection that stayed down) as end of file; the position tells them apart.
    struct EndOfFile {
        /// The exact position (not throttled like `State.position`).
        var position: Double
        /// The file's duration, 0 if unknown.
        var duration: Double
        /// The last mpv warning or error since the file was loaded.
        var problem: String?
    }

    /// Published player state (main thread).
    final class State: ObservableObject {
        @Published var position: Double = 0
        @Published var duration: Double = 0
        @Published var isPaused: Bool = true
        @Published var isBuffering: Bool = true
        @Published var bufferingPercent: Int = 0
        @Published var bufferedSeconds: Double = 0
        @Published var isEOF: Bool = false
        @Published var isFileLoaded: Bool = false
        @Published var errorMessage: String?
        @Published var speed: Double = 1
        @Published var stats = Stats()
    }

    let state = State()
    // Callbacks run on the main thread, only for the file of the latest `load`.
    var onFileLoaded: (@MainActor () -> Void)?
    var onEndOfFile: (@MainActor (EndOfFile) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onTick: (@MainActor (Double, Bool) -> Void)?
    /// Paused or resumed (time-pos doesn't change while paused, so `onTick` never says so).
    var onPauseChanged: (@MainActor (Bool) -> Void)?
    /// A caption track added with `addSubtitle` couldn't be loaded (already logged).
    var onSubtitleFailed: (@MainActor (String) -> Void)?
    /// Called on the mpv queue; mpv's own levels are mapped (fatal/error → error, warn → warn).
    var logSink: ((LogBuffer.Level, String) -> Void)?

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "tube.mpv", qos: .userInitiated)
    private var pendingSource: (source: Source, generation: Int)?
    private var retainedSelf: Unmanaged<MPVPlayer>?
    private var lastErrorLog: String?
    /// ffmpeg logs HTTP failures ('HTTP error 403 Forbidden') as warnings, below `lastErrorLog`.
    private var lastHttpError: String?
    /// A dropped connection shows up as warnings only ('error reading packet', 'Will reconnect').
    private var lastWarnLog: String?
    /// The current file came with a separate audio URL.
    private var expectAudio = false
    private var stats = Stats()
    private var lastPublish = Date.distantPast
    private var lastStatsPublish = Date.distantPast
    private var position: Double = 0
    private var duration: Double = 0
    private var paused = true  // mpv queue only
    private var idleActive = true  // mpv queue only: no file loaded (before the first, after stop or a failure)
    /// mpv queue: the generation of the file mpv is loading or playing.
    private var loadGeneration = 0
    /// mpv queue: FILE_LOADED arrived for that file. Until then time-pos and eof-reached can
    /// still come from the file it replaces.
    private var fileIsLoaded = false
    /// mpv queue: playlist entry id of the latest `loadfile` (nil if unknown), and the one of the
    /// last START_FILE. The FILE_LOADED/END_FILE of a file that a newer `loadfile` replaced can
    /// still be waiting in mpv's event queue (e.g. it finished opening while the next load was
    /// being set up); only the entry ids tell them apart from the new file's.
    private var expectedEntry: Int64?
    private var startedEntry: Int64?
    /// mpv queue: the current file's failure was already shown (its END_FILE error isn't again).
    private var failureReported = false
    /// mpv queue: reply ids of `sub-add` (run asynchronously), the one still downloading, and
    /// whether captions were switched off since.
    private var subtitleRequest: UInt64 = 0
    private var pendingSubtitle: UInt64?
    private var subtitlesOff = false
    /// Main thread only: the generation of the latest `load`; events of older ones are dropped.
    private var generationOnMain = 0
    /// Main thread only: set by `destroy()` so late pause events can't keep the screensaver off.
    private var destroyedOnMain = false

    deinit {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: - Lifecycle

    /// Creates the mpv core rendering into `layer`. Called once the video view exists.
    func attach(to layer: CAMetalLayer) {
        queue.async { [self] in
            guard handle == nil else { return }
            guard let mpv = mpv_create() else {
                report(error: "Couldn't start the video player (mpv_create failed).")
                return
            }
            handle = mpv
            mpv_request_log_messages(mpv, "warn")
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
            // MPVKit is built without the ytdl hook and the OSC script, so `ytdl`/`osc` don't exist.
            let options: [(String, String)] = [
                ("vo", "gpu-next"),
                ("gpu-api", "vulkan"),
                ("gpu-context", "moltenvk"),
                ("hwdec", "no"),
                ("hwdec-codecs", "h264,hevc"),
                ("cache", "yes"),
                ("demuxer-max-bytes", "600MiB"),
                ("demuxer-max-back-bytes", "200MiB"),
                ("demuxer-readahead-secs", "600"),
                ("cache-pause-initial", "yes"),
                ("cache-pause-wait", "3"),
                ("network-timeout", "30"),
                ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5"),
                ("keep-open", "yes"),
                ("idle", "yes"),
                // A decoder or video/audio output that fails to start ends the file with an
                // error (shown with Retry) instead of playing on without picture or sound.
                ("stop-playback-on-init-failure", "yes"),
                ("input-default-bindings", "no"),
                ("input-vo-keyboard", "no"),
                ("osd-level", "0"),
                ("vd-lavc-threads", "0"),
                ("framedrop", "vo"),
                ("target-colorspace-hint", "no"),
                ("sub-auto", "no"),
                ("subs-fallback", "yes"),
                ("sub-font-size", "44"),
                ("sub-border-size", "2.5"),
                ("sub-margin-y", "60"),
                ("audio-client-name", "Tube"),
                ("save-position-on-quit", "no"),
                ("video-rotate", "no")
            ]
            for (name, value) in options {
                let status = mpv_set_option_string(mpv, name, value)
                if status < 0 { log(.error, "mpv option \(name)=\(value) failed: \(String(cString: mpv_error_string(status)))") }
            }
            let status = mpv_initialize(mpv)
            guard status >= 0 else {
                report(error: "The video player failed to initialise: \(String(cString: mpv_error_string(status))).")
                return
            }
            observe(mpv)
            let retained = Unmanaged.passRetained(self)
            retainedSelf = retained
            mpv_set_wakeup_callback(mpv, { context in
                guard let context else { return }
                Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().wakeup()
            }, retained.toOpaque())
            if let pending = pendingSource {
                pendingSource = nil
                performLoad(pending.source, generation: pending.generation)
            }
        }
    }

    /// Tears down mpv. The player can't be used afterwards.
    func destroy() {
        let releaseIdleTimer = { [self] in
            destroyedOnMain = true
            generationOnMain += 1
            MainActor.assumeIsolated { IdleTimer.set(self, playing: false) }
        }
        if Thread.isMainThread { releaseIdleTimer() } else { DispatchQueue.main.async(execute: releaseIdleTimer) }
        queue.async { [self] in
            guard let mpv = handle else { return }
            handle = nil
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
            retainedSelf?.release()
            retainedSelf = nil
        }
    }

    // MARK: - Playback control

    /// Replaces the current file. From here on nothing of the previous file reaches the callbacks.
    @MainActor
    func load(_ source: Source) {
        generationOnMain += 1
        let generation = generationOnMain
        queue.async { [self] in
            guard handle != nil else {
                pendingSource = (source, generation)
                return
            }
            performLoad(source, generation: generation)
        }
    }

    private func performLoad(_ source: Source, generation: Int) {
        loadGeneration = generation
        fileIsLoaded = false
        failureReported = false
        startedEntry = nil
        expectAudio = source.audioURL != nil
        lastErrorLog = nil
        lastHttpError = nil
        lastWarnLog = nil
        // mpv aborts a caption download when its file ends; that reply isn't about the new file.
        pendingSubtitle = nil
        position = source.startTime ?? 0
        duration = 0
        DispatchQueue.main.async { [state] in
            state.isEOF = false
            state.isFileLoaded = false
            state.errorMessage = nil
            state.isBuffering = true
            state.position = source.startTime ?? 0
        }
        setString("user-agent", source.userAgent)
        let headerList = source.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ",")
        setString("http-header-fields", headerList)
        setString("hwdec", source.hardwareDecode ? "videotoolbox" : "no")
        setString("loop-file", source.loop ? "inf" : "no")
        setString("start", source.startTime.map { String(format: "%.3f", $0) } ?? "0")
        setString("pause", source.startPaused ? "yes" : "no")
        command(["change-list", "audio-files", "clr", ""])
        if let audio = source.audioURL {
            command(["change-list", "audio-files", "append", audio.absoluteString])
        }
        let status = command(["loadfile", source.videoURL.absoluteString, "replace"])
        guard status >= 0 else {
            expectedEntry = nil
            failureReported = true
            report(error: "Couldn't open the stream: \(String(cString: mpv_error_string(status))).", generation: generation)
            command(["stop"])
            return
        }
        // `replace` leaves this file as the only playlist entry.
        expectedEntry = int64Property("playlist/0/id")
        if expectedEntry == nil { log(.warn, "mpv playlist/0/id unavailable; can't tell a replaced file's events apart") }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in setFlag("pause", paused) }
    }

    /// mpv flips its own state: `paused` is only updated once mpv reports the change, so reading
    /// it here (on main, while the mpv queue writes it) would lose a quick second press.
    func togglePause() {
        queue.async { [self] in command(["cycle", "pause"]) }
    }

    func seek(to seconds: Double) {
        clearEOF()
        queue.async { [self] in command(["seek", String(format: "%.3f", max(0, seconds)), "absolute"]) }
    }

    func seek(by delta: Double) {
        clearEOF()
        queue.async { [self] in command(["seek", String(format: "%.3f", delta), "relative"]) }
    }

    private func clearEOF() {
        DispatchQueue.main.async { [state] in
            if state.isEOF { state.isEOF = false }
        }
    }

    func setSpeed(_ speed: Double) {
        queue.async { [self] in setString("speed", String(format: "%.2f", speed)) }
    }

    /// Downloads and selects a WebVTT track. It runs as an asynchronous mpv command: waiting for
    /// the download here would hold up the player queue (position, buffering, pause, seeks) for
    /// as long as it takes, up to the network timeout. Failures come back via `onSubtitleFailed`.
    func addSubtitle(url: String, title: String, language: String) {
        queue.async { [self] in
            guard handle != nil else { return }
            abortPendingSubtitle()
            subtitlesOff = false
            subtitleRequest += 1
            let status = command(["sub-add", url, "select", title, language], reply: subtitleRequest)
            if status >= 0 { pendingSubtitle = subtitleRequest } else { subtitleFailed(status) }
        }
    }

    func disableSubtitles() {
        queue.async { [self] in
            abortPendingSubtitle()
            subtitlesOff = true
            setString("sid", "no")
        }
    }

    /// A newer caption choice replaces a download that is still running.
    private func abortPendingSubtitle() {
        guard let handle, let request = pendingSubtitle else { return }
        pendingSubtitle = nil
        mpv_abort_async_command(handle, request)
    }

    private func subtitleFailed(_ status: Int32) {
        let reason = String(cString: mpv_error_string(status))
        log(.error, "mpv sub-add failed: \(reason)\(problemDetail().map { " (\($0))" } ?? "")")
        let generation = loadGeneration
        DispatchQueue.main.async { [self] in
            guard generation == generationOnMain else { return }
            MainActor.assumeIsolated { onSubtitleFailed?("Couldn't load the captions (\(reason)).") }
        }
    }

    func stop() {
        queue.async { [self] in command(["stop"]) }
    }

    // MARK: - mpv helpers (queue only)

    /// Runs a command and waits for it, or with `reply` starts it asynchronously; its result then
    /// arrives as MPV_EVENT_COMMAND_REPLY with that id.
    @discardableResult
    private func command(_ args: [String], reply: UInt64? = nil) -> Int32 {
        guard let handle else { return -1 }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil { free(UnsafeMutablePointer(mutating: pointer)) }
        }
        let status: Int32
        if let reply {
            // mpv copies the arguments before this returns.
            status = mpv_command_async(handle, reply, &cargs)
        } else {
            status = mpv_command(handle, &cargs)
        }
        if status < 0 {
            log(.error, "mpv command \(args.first ?? "") failed: \(String(cString: mpv_error_string(status)))")
        }
        return status
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        let status = mpv_set_property_string(handle, name, value)
        if status < 0 { log(.error, "mpv set \(name) failed: \(String(cString: mpv_error_string(status)))") }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        let status = mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
        if status < 0 { log(.error, "mpv set \(name)=\(value) failed: \(String(cString: mpv_error_string(status)))") }
    }

    private func observe(_ mpv: OpaquePointer) {
        let properties: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("idle-active", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("cache-buffering-state", MPV_FORMAT_INT64),
            ("demuxer-cache-duration", MPV_FORMAT_DOUBLE), ("eof-reached", MPV_FORMAT_FLAG),
            ("speed", MPV_FORMAT_DOUBLE), ("container-fps", MPV_FORMAT_DOUBLE),
            ("estimated-vf-fps", MPV_FORMAT_DOUBLE), ("video-codec", MPV_FORMAT_STRING),
            ("audio-codec-name", MPV_FORMAT_STRING), ("hwdec-current", MPV_FORMAT_STRING),
            ("video-params/w", MPV_FORMAT_INT64), ("video-params/h", MPV_FORMAT_INT64),
            ("frame-drop-count", MPV_FORMAT_INT64), ("decoder-frame-drop-count", MPV_FORMAT_INT64),
            ("avsync", MPV_FORMAT_DOUBLE), ("cache-speed", MPV_FORMAT_INT64),
            ("demuxer-cache-state/total-bytes", MPV_FORMAT_INT64)
        ]
        for (name, format) in properties {
            let status = mpv_observe_property(mpv, 0, name, format)
            if status < 0 { log(.error, "mpv observe \(name) failed: \(String(cString: mpv_error_string(status)))") }
        }
    }

    // MARK: - Events

    private func wakeup() {
        queue.async { [self] in drainEvents() }
    }

    private func drainEvents() {
        while let handle, let event = mpv_wait_event(handle, 0) {
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            switch id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.pointee.data {
                    handleProperty(data.assumingMemoryBound(to: mpv_event_property.self).pointee)
                }
            case MPV_EVENT_START_FILE:
                if let data = event.pointee.data {
                    startedEntry = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
                }
            case MPV_EVENT_FILE_LOADED:
                if !isCurrentEntry(startedEntry) {
                    // Opened just before a newer `loadfile` replaced it: not the current file,
                    // and checking its tracks now would look at the next one's (still loading).
                    log(.debug, "mpv file-loaded of a replaced file ignored")
                } else if let problem = missingTrackError() {
                    failureReported = true
                    report(error: problem, generation: loadGeneration)
                    // Don't play on without sound (or with sound over black) behind the error.
                    command(["stop"])
                } else {
                    fileIsLoaded = true
                    // `paused-for-cache` only reports changes; seed the buffering flag with its
                    // current value so a stream that never stalls doesn't look stuck.
                    let buffering = stats.pausedForCache
                    let generation = loadGeneration
                    DispatchQueue.main.async { [self] in
                        guard generation == generationOnMain else { return }
                        state.isFileLoaded = true
                        state.isBuffering = buffering
                        MainActor.assumeIsolated { onFileLoaded?() }
                    }
                }
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    handleEndFile(data.assumingMemoryBound(to: mpv_event_end_file.self).pointee)
                }
            case MPV_EVENT_COMMAND_REPLY:
                // Only `sub-add` runs asynchronously.
                let request = event.pointee.reply_userdata
                let status = event.pointee.error
                if request == pendingSubtitle {
                    pendingSubtitle = nil
                    if status < 0 { subtitleFailed(status) }
                } else if status >= 0, subtitlesOff {
                    // A download the viewer switched off finished before the abort reached it
                    // and selected its track after all.
                    setString("sid", "no")
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = message.prefix.map { String(cString: $0) } ?? ""
                    let level = message.level.map { String(cString: $0) } ?? ""
                    let text = message.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if level == "error" || level == "fatal" { lastErrorLog = "\(prefix): \(text)" }
                    if level == "warn" { lastWarnLog = "\(prefix): \(text)" }
                    if text.contains("HTTP error") { lastHttpError = "\(prefix): \(text)" }
                    log(Self.logLevel(mpv: level), "[mpv \(level)] \(prefix): \(text)")
                }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    /// Every end of a file is logged with its reason and where playback was.
    private func handleEndFile(_ end: mpv_event_end_file) {
        guard isCurrentEntry(end.playlist_entry_id) else {
            // The file a newer `loadfile` replaced: its end says nothing about the current one.
            log(.debug, "mpv end-file of a replaced file: \(String(cString: mpv_error_string(end.error)))")
            return
        }
        let at = "at \(Formatters.duration(position)) of \(Formatters.duration(duration))"
        if end.reason == MPV_END_FILE_REASON_ERROR {
            let reason = String(cString: mpv_error_string(end.error))
            let detail = problemDetail().map { " (\($0))" } ?? ""
            log(.error, "mpv end-file: error \(at): \(reason)\(detail)")
            // Already shown with a better reason (e.g. the missing track at FILE_LOADED).
            if failureReported { return }
            failureReported = true
            report(error: "Playback failed: \(reason)\(detail).", generation: loadGeneration)
        } else if end.reason == MPV_END_FILE_REASON_EOF {
            log(.info, "mpv end-file: eof \(at)")
            reachedEnd()
        } else if end.reason == MPV_END_FILE_REASON_STOP {
            // Every `loadfile replace` and `stop` ends the previous file this way.
            log(.debug, "mpv end-file: stop \(at)")
        } else if end.reason == MPV_END_FILE_REASON_QUIT {
            log(.info, "mpv end-file: quit \(at)")
        } else if end.reason == MPV_END_FILE_REASON_REDIRECT {
            log(.info, "mpv end-file: redirect \(at)")
        } else {
            log(.warn, "mpv end-file: unknown reason \(at)")
        }
    }

    /// The mpv log lines that explain a failure of the current file.
    private func problemDetail() -> String? {
        var lines: [String] = []
        if let http = lastHttpError { lines.append(http) }
        if let error = lastErrorLog, error != lastHttpError { lines.append(error) }
        return lines.isEmpty ? nil : lines.joined(separator: "; ")
    }

    /// At FILE_LOADED (after mpv opened the external audio file and started the decoders and
    /// outputs): the video track and, when one was given, the audio track must be there. mpv only
    /// logs an audio URL it couldn't open (HTTP 403, timeout) and plays on without sound.
    private func missingTrackError() -> String? {
        let detail = problemDetail().map { " (\($0))" } ?? ""
        if !hasTrack("video") { return "The video stream couldn't be opened or shown\(detail)." }
        if expectAudio, !hasTrack("audio") { return "The audio stream couldn't be opened\(detail)." }
        return nil
    }

    /// Only mpv's "property unavailable" means no track is selected. Any other failure of the
    /// query itself is logged and counts as present, so this check can never block playback.
    private func hasTrack(_ type: String) -> Bool {
        guard let handle else { return false }
        var id: Int64 = 0
        let status = mpv_get_property(handle, "current-tracks/\(type)/id", MPV_FORMAT_INT64, &id)
        if status >= 0 { return true }
        if Int(status) == Int(MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue) { return false }
        log(.warn, "mpv current-tracks/\(type)/id failed: \(String(cString: mpv_error_string(status)))")
        return true
    }

    private func int64Property(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    /// Whether an event with this playlist entry id is about the file of the latest `load`.
    private func isCurrentEntry(_ entry: Int64?) -> Bool {
        guard let expectedEntry else { return true }
        return entry == expectedEntry
    }

    /// The file played to its end (END_FILE eof, or eof-reached with keep-open), or its stream
    /// broke off: see `EndOfFile`.
    private func reachedEnd() {
        let end = EndOfFile(position: position, duration: duration, problem: problemDetail() ?? lastWarnLog)
        let generation = loadGeneration
        DispatchQueue.main.async { [self] in
            guard generation == generationOnMain, !state.isEOF else { return }
            state.isEOF = true
            MainActor.assumeIsolated { onEndOfFile?(end) }
        }
    }

    private func handleProperty(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let format = property.format
        func double() -> Double? {
            guard format == MPV_FORMAT_DOUBLE, let p = property.data else { return nil }
            return p.assumingMemoryBound(to: Double.self).pointee
        }
        func int() -> Int? {
            guard format == MPV_FORMAT_INT64, let p = property.data else { return nil }
            return Int(p.assumingMemoryBound(to: Int64.self).pointee)
        }
        func flag() -> Bool? {
            guard format == MPV_FORMAT_FLAG, let p = property.data else { return nil }
            return p.assumingMemoryBound(to: Int32.self).pointee != 0
        }
        func string() -> String? {
            guard format == MPV_FORMAT_STRING, let p = property.data,
                  let cstr = p.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return String(cString: cstr)
        }

        switch name {
        case "time-pos":
            // After a new `loadfile` the replaced file can still report its position.
            guard let value = double(), fileIsLoaded else { return }
            position = value
            let now = Date()
            if now.timeIntervalSince(lastPublish) >= 0.25 {
                lastPublish = now
                let isPlaying = !paused
                let generation = loadGeneration
                DispatchQueue.main.async { [self] in
                    guard generation == generationOnMain else { return }
                    state.position = value
                    MainActor.assumeIsolated { onTick?(value, isPlaying) }
                }
            }
        case "duration":
            let value = double() ?? 0
            duration = value
            DispatchQueue.main.async { [state] in state.duration = value }
        case "pause":
            let value = flag() ?? true
            paused = value
            updateIdleTimer()
            let generation = loadGeneration
            DispatchQueue.main.async { [self] in
                state.isPaused = value
                guard !destroyedOnMain, generation == generationOnMain else { return }
                MainActor.assumeIsolated { onPauseChanged?(value) }
            }
        case "idle-active":
            idleActive = flag() ?? false
            updateIdleTimer()
        case "paused-for-cache":
            let value = flag() ?? false
            stats.pausedForCache = value
            DispatchQueue.main.async { [state] in state.isBuffering = value }
        case "cache-buffering-state":
            let value = int() ?? 0
            stats.bufferingPercent = value
            DispatchQueue.main.async { [state] in state.bufferingPercent = value }
        case "demuxer-cache-duration":
            let value = double() ?? 0
            stats.bufferedSeconds = value
            DispatchQueue.main.async { [state] in state.bufferedSeconds = value }
        case "eof-reached":
            if flag() == true, fileIsLoaded {
                log(.info, "mpv eof-reached at \(Formatters.duration(position)) of \(Formatters.duration(duration))")
                reachedEnd()
            }
        case "speed":
            let value = double() ?? 1
            DispatchQueue.main.async { [state] in state.speed = value }
        case "container-fps": stats.containerFps = double() ?? 0
        case "estimated-vf-fps": stats.estimatedFps = double() ?? 0
        case "video-codec": stats.videoCodec = string() ?? ""
        case "audio-codec-name": stats.audioCodec = string() ?? ""
        case "hwdec-current": stats.hwdec = string() ?? "no"
        case "video-params/w": stats.width = int() ?? 0
        case "video-params/h": stats.height = int() ?? 0
        case "frame-drop-count": stats.droppedFrames = int() ?? 0
        case "decoder-frame-drop-count": stats.decoderDroppedFrames = int() ?? 0
        case "avsync": stats.avsync = double() ?? 0
        case "cache-speed": stats.cacheSpeed = Double(int() ?? 0)
        case "demuxer-cache-state/total-bytes": stats.demuxerCacheBytes = int() ?? 0
        default: break
        }
        publishStats(immediately: Self.immediateStats.contains(name))
    }

    /// Stats that change once per file and are needed right away (frame-rate matching reads
    /// `containerFps`). The rest (avsync, drop counts, cache) change with every frame and are
    /// published at most once a second, so the player views don't redraw at the frame rate.
    private static let immediateStats: Set<String> = [
        "container-fps", "video-codec", "audio-codec-name", "hwdec-current", "video-params/w", "video-params/h"
    ]

    private func publishStats(immediately: Bool) {
        let now = Date()
        guard immediately || now.timeIntervalSince(lastStatsPublish) >= 1 else { return }
        lastStatsPublish = now
        let snapshot = stats
        DispatchQueue.main.async { [state] in
            if state.stats != snapshot { state.stats = snapshot }
        }
    }

    /// Shows `error` on screen. A playback error passes its file's generation, so the error of a
    /// replaced file isn't shown over the next one; setup errors pass nil.
    private func report(error: String, generation: Int? = nil) {
        log(.error, error)
        DispatchQueue.main.async { [self] in
            if let generation, generation != generationOnMain { return }
            state.errorMessage = error
            state.isBuffering = false
            MainActor.assumeIsolated {
                IdleTimer.set(self, playing: false)
                onError?(error)
            }
        }
    }

    /// The screensaver stays off only while a file really plays: not paused, and not idle. A
    /// failed load or `stop` leaves mpv idle with `pause` unchanged.
    private func updateIdleTimer() {
        let playing = !paused && !idleActive
        DispatchQueue.main.async { [self] in
            guard !destroyedOnMain else { return }
            MainActor.assumeIsolated { IdleTimer.set(self, playing: playing) }
        }
    }

    private func log(_ level: LogBuffer.Level, _ text: String) {
        logSink?(level, text)
    }

    private static func logLevel(mpv level: String) -> LogBuffer.Level {
        switch level {
        case "fatal", "error": return .error
        case "warn": return .warn
        case "info": return .info
        default: return .debug
        }
    }
}
