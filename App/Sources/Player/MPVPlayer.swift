import Foundation
import QuartzCore
import Libmpv
import Core

/// Thin libmpv wrapper. Video URL is the file, audio URL is added via `audio-files`; software
/// decoding for AV1/VP9/Opus (hwdec only for H.264/HEVC), big demuxer cache, no ytdl.
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
    // Callbacks run on the main thread.
    var onFileLoaded: (@MainActor () -> Void)?
    var onEndOfFile: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onTick: (@MainActor (Double, Bool) -> Void)?
    /// Called on the mpv queue; mpv's own levels are mapped (fatal/error → error, warn → warn).
    var logSink: ((LogBuffer.Level, String) -> Void)?

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "tube.mpv", qos: .userInitiated)
    private var pendingSource: Source?
    private var retainedSelf: Unmanaged<MPVPlayer>?
    private var lastErrorLog: String?
    private var stats = Stats()
    private var lastPublish = Date.distantPast
    private var lastStatsPublish = Date.distantPast
    private var position: Double = 0
    private var duration: Double = 0
    private var paused = true  // mpv queue only
    private var loadGeneration = 0
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
            if let source = pendingSource {
                pendingSource = nil
                performLoad(source)
            }
        }
    }

    /// Tears down mpv. The player can't be used afterwards.
    func destroy() {
        let releaseIdleTimer = { [self] in
            destroyedOnMain = true
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

    func load(_ source: Source) {
        queue.async { [self] in
            guard handle != nil else {
                pendingSource = source
                return
            }
            performLoad(source)
        }
    }

    private func performLoad(_ source: Source) {
        loadGeneration += 1
        lastErrorLog = nil
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
        command(["loadfile", source.videoURL.absoluteString, "replace"])
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

    func addSubtitle(url: String, title: String, language: String) {
        queue.async { [self] in command(["sub-add", url, "select", title, language]) }
    }

    func disableSubtitles() {
        queue.async { [self] in setString("sid", "no") }
    }

    func stop() {
        queue.async { [self] in command(["stop"]) }
    }

    // MARK: - mpv helpers (queue only)

    @discardableResult
    private func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil { free(UnsafeMutablePointer(mutating: pointer)) }
        }
        let status = mpv_command(handle, &cargs)
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
            case MPV_EVENT_FILE_LOADED:
                // `paused-for-cache` only reports changes; seed the buffering flag with its
                // current value so a stream that never stalls doesn't look stuck.
                let buffering = stats.pausedForCache
                DispatchQueue.main.async { [self] in
                    state.isFileLoaded = true
                    state.isBuffering = buffering
                    MainActor.assumeIsolated { onFileLoaded?() }
                }
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    handleEndFile(data.assumingMemoryBound(to: mpv_event_end_file.self).pointee)
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = message.prefix.map { String(cString: $0) } ?? ""
                    let level = message.level.map { String(cString: $0) } ?? ""
                    let text = message.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if level == "error" || level == "fatal" { lastErrorLog = "\(prefix): \(text)" }
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
        let at = "at \(Formatters.duration(position)) of \(Formatters.duration(duration))"
        if end.reason == MPV_END_FILE_REASON_ERROR {
            let reason = String(cString: mpv_error_string(end.error))
            let detail = lastErrorLog.map { " (\($0))" } ?? ""
            log(.error, "mpv end-file: error \(at): \(reason)\(detail)")
            report(error: "Playback failed: \(reason)\(detail)")
        } else if end.reason == MPV_END_FILE_REASON_EOF {
            log(.info, "mpv end-file: eof \(at)")
            DispatchQueue.main.async { [self] in
                guard !state.isEOF else { return }
                state.isEOF = true
                MainActor.assumeIsolated { onEndOfFile?() }
            }
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
            guard let value = double() else { return }
            position = value
            let now = Date()
            if now.timeIntervalSince(lastPublish) >= 0.25 {
                lastPublish = now
                let isPlaying = !paused
                DispatchQueue.main.async { [self] in
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
            DispatchQueue.main.async { [self] in
                state.isPaused = value
                guard !destroyedOnMain else { return }
                MainActor.assumeIsolated { IdleTimer.set(self, playing: !value) }
            }
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
            if flag() == true {
                log(.info, "mpv eof-reached at \(Formatters.duration(position)) of \(Formatters.duration(duration))")
                DispatchQueue.main.async { [self] in
                    guard !state.isEOF else { return }
                    state.isEOF = true
                    MainActor.assumeIsolated { onEndOfFile?() }
                }
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

    private func report(error: String) {
        log(.error, error)
        DispatchQueue.main.async { [self] in
            state.errorMessage = error
            state.isBuffering = false
            MainActor.assumeIsolated { onError?(error) }
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
