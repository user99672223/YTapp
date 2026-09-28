import Foundation
import SwiftUI
import Core

/// Endless Shorts: seeded from the Home feed's Shorts shelf (or a tapped Short), extended with
/// YouTube's reel watch-sequence continuation. One mpv instance, looping the current Short.
@MainActor
final class ShortsViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading(String)
        case playing
        case failed(BridgeError)
    }

    @Published private(set) var phase: Phase = .loading("Loading Shorts…")
    @Published private(set) var ids: [String] = []
    @Published private(set) var index = 0
    @Published private(set) var current: ShortDetails?
    @Published private(set) var likeStatus: LikeStatus = .none
    @Published private(set) var isSubscribed: Bool?
    @Published var toast: String?

    let player = MPVPlayer()
    let comments: CommentsModel
    private let model: AppModel
    private let seedId: String?
    private var continuation: String?
    private var details: [String: ShortDetails] = [:]
    private var reporter: PlaybackReporter?
    private var loadingMore = false
    private var started = false
    private var closed = false
    private var playbackStarted = false
    private var toastTask: Task<Void, Never>?

    init(seedId: String?, model: AppModel) {
        self.seedId = seedId
        self.model = model
        comments = CommentsModel(model: model)
        let logs = model.logs
        player.logSink = { level, line in logs.append(level, line) }
        player.onTick = { [weak self] position, playing in self?.tick(position: position, playing: playing) }
        player.onError = { [weak self] message in
            guard let self, !self.closed else { return }
            self.phase = .failed(BridgeError(kind: .network, message: message))
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await loadSequence() }
    }

    func loadSequence() async {
        phase = .loading("Finding Shorts…")
        do {
            let sequence = try await model.api { [seedId] in try await $0.shortsFeed(seedId: seedId) }
            guard !closed else { return }
            ids = unique(sequence.ids)
            continuation = sequence.continuation
            guard !ids.isEmpty else {
                phase = .failed(BridgeError(kind: .notFound, message: "YouTube didn't return any Shorts."))
                return
            }
            index = 0
            await show(0)
        } catch {
            guard !closed else { return }
            phase = .failed(BridgeError.wrap(error))
        }
    }

    func next() {
        guard !ids.isEmpty else { return }
        if index + 1 < ids.count {
            index += 1
            Task { await show(index) }
        } else {
            Task {
                await loadMore()
                if index + 1 < ids.count {
                    index += 1
                    await show(index)
                } else {
                    notify("That's all the Shorts for now.")
                }
            }
        }
    }

    func previous() {
        guard index > 0 else { return }
        index -= 1
        Task { await show(index) }
    }

    func retry() {
        if ids.isEmpty {
            Task { await loadSequence() }
        } else {
            details[ids[index]] = nil
            Task { await show(index) }
        }
    }

    private func show(_ position: Int) async {
        guard ids.indices.contains(position) else { return }
        reporter?.stop()
        reporter = nil
        // The previous Short would keep looping (with sound) while this one loads.
        player.setPaused(true)
        let id = ids[position]
        comments.reset(videoId: id)
        phase = .loading("Loading Short…")
        do {
            let info = try await detailsFor(id, refresh: false)
            guard index == position, !closed else { return }
            current = info
            likeStatus = info.likeStatus
            isSubscribed = info.channel.isSubscribed
            let resolved: (selection: StreamSelection, streams: ResolvedStreams)
            do {
                resolved = try await selectAndResolve(id, formats: info.formats)
            } catch let error as BridgeError where error.kind == .expired {
                // The bridge dropped this Short's player data; fetch it again.
                let fresh = try await detailsFor(id, refresh: true)
                resolved = try await selectAndResolve(id, formats: fresh.formats)
            }
            let (selection, streams) = resolved
            guard index == position, !closed else { return }
            guard let videoURL = streams.url(for: selection.video) else {
                throw BridgeError(kind: .extraction, message: "YouTube didn't return a URL for this Short.")
            }
            player.load(MPVPlayer.Source(
                videoURL: videoURL,
                audioURL: selection.audio.flatMap { streams.url(for: $0) },
                userAgent: streams.userAgent ?? info.userAgent ?? "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
                headers: streams.headers ?? [:],
                startTime: nil,
                hardwareDecode: selection.video.codecFamily == .avc && model.settings.hardwareDecodeH264,
                loop: true,
                startPaused: false
            ))
            // Only ticks of this file reach the reporter (the player drops the previous file's).
            reporter = PlaybackReporter(videoId: id, model: model)
            reporterSelection = selection
            playbackStarted = false
            phase = .playing
            prefetch(position + 1)
            trimDetails(around: position)
            if position >= ids.count - 3 { Task { await loadMore() } }
        } catch {
            guard index == position, !closed else { return }
            phase = .failed(WatchViewModel.describe(error))
        }
    }

    private var reporterSelection: StreamSelection?

    private func selectAndResolve(_ id: String, formats available: [StreamFormat]) async throws
        -> (selection: StreamSelection, streams: ResolvedStreams) {
        let selection = try QualitySelector.select(available, preferences: model.settings.quality)
        var formats = [selection.video]
        if let audio = selection.audio { formats.append(audio) }
        let streams = try await model.api { try await $0.resolveFormats(videoId: id, formats: formats) }
        return (selection, streams)
    }

    private func detailsFor(_ id: String, refresh: Bool) async throws -> ShortDetails {
        if !refresh, let cached = details[id] { return cached }
        let client = model.settings.streamClient
        let fetched = try await model.api { try await $0.shortInfo(id, client: client) }
        details[id] = fetched
        return fetched
    }

    /// Keeps the details of the Shorts just before and after the current one. An endless feed
    /// would otherwise hold every Short's formats for the whole session, and older entries are
    /// fetched again anyway once the bridge has dropped their player data.
    private func trimDetails(around position: Int) {
        guard ids.indices.contains(position) else { return }
        let keep = Set(ids[max(0, position - 5)...min(ids.count - 1, position + 2)])
        details = details.filter { keep.contains($0.key) }
    }

    private func prefetch(_ position: Int) {
        guard ids.indices.contains(position) else { return }
        let id = ids[position]
        guard details[id] == nil else { return }
        Task { _ = try? await detailsFor(id, refresh: false) }
    }

    private func loadMore() async {
        guard !loadingMore, let key = continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try await model.api { try await $0.shortsMore(key) }
            let fresh = more.ids.filter { !ids.contains($0) }
            ids.append(contentsOf: fresh)
            continuation = more.continuation
        } catch {
            model.logs.append(.warn, "Shorts continuation failed: \(BridgeError.wrap(error).message)")
        }
    }

    private func tick(position: Double, playing: Bool) {
        // No reporter while the next Short loads: a tick then must not use up its start.
        if let reporter {
            reporter.tick(position: position, isPlaying: playing)
            if playing, !playbackStarted, position > 0.3 {
                playbackStarted = true
                reporter.playbackStarted(length: current?.durationSeconds, videoItag: reporterSelection?.video.itag,
                                         audioItag: reporterSelection?.audio?.itag)
            }
        }
        if let current {
            PlaybackDiagnostics.shared.update(videoId: current.id, title: current.title, client: current.playerClient,
                                              selection: reporterSelection, state: player.state, refreshRate: nil,
                                              history: reporter?.lastStatus ?? "")
        }
    }

    // MARK: - Actions

    func togglePlay() {
        reporter?.userActivity()
        player.togglePause()
    }

    func rate(_ target: LikeStatus) {
        guard let id = current?.id else { return }
        let desired: LikeStatus = likeStatus == target ? .none : target
        let previous = likeStatus
        likeStatus = desired
        Task {
            do {
                likeStatus = try await model.api { try await $0.rate(videoId: id, desired) }
            } catch {
                likeStatus = previous
                notify("Couldn't update the rating: \(BridgeError.wrap(error).userMessage)")
            }
        }
    }

    func toggleSubscription() {
        guard let channelId = current?.channel.id else { return }
        let target = !(isSubscribed ?? false)
        Task {
            do {
                isSubscribed = try await model.api { try await $0.setSubscribed(channelId: channelId, target) }
                notify(target ? "Subscribed" : "Unsubscribed")
            } catch {
                notify("Couldn't change the subscription: \(BridgeError.wrap(error).userMessage)")
            }
        }
    }

    func notify(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func pause() {
        player.setPaused(true)
    }

    func close() {
        guard !closed else { return }
        closed = true
        reporter?.stop()
        reporter = nil
        player.destroy()
    }

    private func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
