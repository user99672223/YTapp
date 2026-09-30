import Foundation
import SwiftUI
import Core

/// Endless Shorts: seeded from the Home feed's Shorts shelf (or a tapped Short), extended with
/// YouTube's reel watch-sequence continuation. One mpv instance, looping the current Short; the
/// same instance loads the next one.
///
/// While a Short plays, the next one is prepared: its details, its resolved stream links and its
/// poster, so paging to it starts mpv straight away instead of after two bridge round trips.
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
    /// The Short on screen, as soon as its details are known (straight away when it was prepared).
    @Published private(set) var current: ShortDetails?
    @Published private(set) var likeStatus: LikeStatus = .none
    @Published private(set) var isSubscribed: Bool?
    /// mpv shows the current Short's picture. Until then the pager shows its poster, so paging
    /// never flashes black or the previous Short's last frame.
    @Published private(set) var isVideoOnScreen = false
    /// Details of the Shorts around the current one, by id: the pager shows their posters and
    /// titles while they slide in.
    @Published private(set) var details: [String: ShortDetails] = [:]
    @Published var toast: String?

    let player = MPVPlayer()
    let comments: CommentsModel
    private let model: AppModel
    private let seedId: String?
    private var continuation: String?
    /// Stream links resolved ahead of time, for the Shorts next to the current one (and the
    /// current one, so going back is as quick as going forward).
    private var prepared: [String: Prepared] = [:]
    /// Preparations still running, so showing that Short waits for it instead of asking twice.
    private var preparing: [String: Task<Void, Never>] = [:]
    /// The current file plays links resolved earlier (a preparation). If mpv can't open them,
    /// they are resolved again once before the failure is shown.
    private var playingEarlierLinks = false
    private var reporter: PlaybackReporter?
    private var reporterSelection: StreamSelection?
    private var loadingMore = false
    private var started = false
    private var closed = false
    private var playbackStarted = false
    private var toastTask: Task<Void, Never>?

    /// A Short's details and stream links, ready for mpv.
    private struct Prepared {
        let info: ShortDetails
        let selection: StreamSelection
        let streams: ResolvedStreams

        /// googlevideo links carry their expiry (`expire`, Unix time). Links that run out within
        /// the bridge's own margin are resolved again instead of handed to mpv.
        var isFresh: Bool {
            guard let url = streams.url(for: selection.video),
                  let expire = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "expire" })?.value,
                  let seconds = TimeInterval(expire) else { return true }
            return Date(timeIntervalSince1970: seconds).timeIntervalSinceNow > Self.margin
        }

        /// Like the bridge's own check in `resolveFormats`: the links must last a while of looping.
        static let margin: TimeInterval = 30 * 60
    }

    init(seedId: String?, model: AppModel) {
        self.seedId = seedId
        self.model = model
        comments = CommentsModel(model: model)
        let logs = model.logs
        player.logSink = { level, line in logs.append(level, line) }
        player.onTick = { [weak self] position, playing in self?.tick(position: position, playing: playing) }
        player.onPauseChanged = { [weak self] paused in
            guard let self else { return }
            self.reporter?.setPlaying(!paused, position: self.player.state.position)
        }
        player.onError = { [weak self] message in
            guard let self, !self.closed else { return }
            if self.playingEarlierLinks {
                // Links resolved ahead of time can have gone stale (expired, or refused); fetch
                // the Short again once before showing the failure.
                self.playingEarlierLinks = false
                self.model.logs.append(.info, "Shorts: prepared links failed (\(message)); resolving them again")
                let position = self.index
                Task { await self.show(position, freshLinks: true) }
                return
            }
            self.phase = .failed(WatchViewModel.playbackError(message, stream: self.reporterSelection?.summary))
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

    /// The details of the Short at `position`, if they are loaded.
    func short(at position: Int) -> ShortDetails? {
        ids.indices.contains(position) ? details[ids[position]] : nil
    }

    func next() {
        guard !ids.isEmpty else { return }
        if index + 1 < ids.count {
            move(to: index + 1)
        } else {
            Task {
                await loadMore()
                if index + 1 < ids.count {
                    move(to: index + 1)
                } else {
                    notify("That's all the Shorts for now.")
                }
            }
        }
    }

    func previous() {
        guard index > 0 else { return }
        move(to: index - 1)
    }

    func retry() {
        if ids.isEmpty {
            Task { await loadSequence() }
        } else {
            // Fresh details and links; the poster and title stay on screen meanwhile.
            let position = index
            Task { await show(position, freshLinks: true) }
        }
    }

    /// Pages to `position`: the view slides the Shorts at the same moment, over their posters.
    private func move(to position: Int) {
        index = position
        isVideoOnScreen = false
        if let info = short(at: position) {
            apply(info)
        } else {
            current = nil
            likeStatus = .none
            isSubscribed = nil
        }
        Task { await show(position) }
    }

    /// Loads the Short at `position` into the one player. `freshLinks` fetches its details and
    /// links again instead of using prepared or cached ones (Retry, or prepared links that failed).
    private func show(_ position: Int, freshLinks: Bool = false) async {
        guard ids.indices.contains(position) else { return }
        reporter?.stop()
        reporter = nil
        // The previous Short would keep looping (with sound) while this one loads.
        player.setPaused(true)
        isVideoOnScreen = false
        playingEarlierLinks = false
        let id = ids[position]
        if comments.videoId != id { comments.reset(videoId: id) }
        phase = .loading("Loading Short…")
        do {
            if !freshLinks, let running = preparing[id] {
                // Its preparation is on the way: wait for it rather than asking the bridge twice.
                await running.value
            }
            guard index == position, !closed else { return }
            let ready: Prepared
            let earlier: Bool
            if !freshLinks, let saved = prepared[id], saved.isFresh {
                ready = saved
                earlier = true
            } else {
                ready = try await prepare(id, refresh: freshLinks)
                earlier = false
            }
            guard index == position, !closed else { return }
            let (info, selection, streams) = (ready.info, ready.selection, ready.streams)
            // The cached details carry the likes and subscriptions changed since it was prepared.
            apply(details[id] ?? info)
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
            playingEarlierLinks = earlier
            prepared[id] = ready
            // From here on only this file's ticks arrive (the player drops the previous file's):
            // the first one with time moving on shows the video.
            isVideoOnScreen = false
            reporter = PlaybackReporter(videoId: id, model: model)
            reporterSelection = selection
            playbackStarted = false
            phase = .playing
            prefetch(position + 1)
            trim(around: position)
            if position >= ids.count - 3 { Task { await loadMore() } }
        } catch {
            guard index == position, !closed else { return }
            // Don't leave the previous Short loaded behind the error.
            player.stop()
            phase = .failed(WatchViewModel.describe(error))
        }
    }

    /// Shows `info` as the current Short.
    private func apply(_ info: ShortDetails) {
        current = info
        likeStatus = info.likeStatus
        isSubscribed = info.channel.isSubscribed
    }

    private func prepare(_ id: String, refresh: Bool) async throws -> Prepared {
        let info = try await detailsFor(id, refresh: refresh)
        do {
            let (selection, streams) = try await selectAndResolve(id, formats: info.formats)
            return Prepared(info: info, selection: selection, streams: streams)
        } catch let error as BridgeError where error.kind == .expired {
            // The bridge dropped this Short's player data; fetch it again.
            let fresh = try await detailsFor(id, refresh: true)
            let (selection, streams) = try await selectAndResolve(id, formats: fresh.formats)
            return Prepared(info: fresh, selection: selection, streams: streams)
        }
    }

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
        guard !closed else { return fetched }
        details[id] = fetched
        return fetched
    }

    /// Keeps the details of the Shorts just before and after the current one, and prepared links
    /// only for its neighbours. An endless feed would otherwise hold every Short's formats for the
    /// whole session, and older entries are fetched again anyway once the bridge has dropped
    /// their player data.
    private func trim(around position: Int) {
        guard ids.indices.contains(position) else { return }
        let keep = Set(ids[max(0, position - 5)...min(ids.count - 1, position + 2)])
        details = details.filter { keep.contains($0.key) }
        let neighbours = Set(ids[max(0, position - 1)...min(ids.count - 1, position + 1)])
        prepared = prepared.filter { neighbours.contains($0.key) }
    }

    /// Prepares the Short at `position`: details, stream links and poster.
    private func prefetch(_ position: Int) {
        guard ids.indices.contains(position) else { return }
        let id = ids[position]
        guard preparing[id] == nil else { return }
        if let ready = prepared[id], ready.isFresh { return }
        preparing[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.preparing[id] = nil }
            do {
                let ready = try await self.prepare(id, refresh: false)
                guard !self.closed else { return }
                self.prepared[id] = ready
                self.warmPoster(ready.info.thumbnail)
            } catch {
                // Not shown: the Short is loaded (and its failure shown) when it comes up.
                self.model.logs.append(.info, "Shorts: preparing \(id) failed: \(BridgeError.wrap(error).message)")
                if let info = self.details[id] { self.warmPoster(info.thumbnail) }
            }
        }
    }

    /// Loads a poster into URLCache.shared, which the image views read from, so it's there the
    /// moment its Short slides in.
    private func warmPoster(_ thumbnail: String?) {
        guard let thumbnail, let url = URL(string: thumbnail) else { return }
        let request = URLRequest(url: url)
        guard URLCache.shared.cachedResponse(for: request) == nil else { return }
        URLSession.shared.dataTask(with: request).resume()
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
        // Time moving on means the frames are on screen, but only a tick of this Short's file
        // counts: until `show` has loaded it, the previous file's last ticks can still arrive (the
        // player drops them only from `load` on), and there's no reporter until then.
        if !isVideoOnScreen, reporter != nil, position > 0.01 {
            isVideoOnScreen = true
        }
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
                let result = try await model.api { try await $0.rate(videoId: id, desired) }
                // Coming back to this Short shows the rating it has now, not the one it was loaded with.
                details[id]?.likeStatus = result
                if current?.id == id { likeStatus = result }
            } catch {
                if current?.id == id { likeStatus = previous }
                notify("Couldn't update the rating: \(BridgeError.wrap(error).userMessage)")
            }
        }
    }

    func toggleSubscription() {
        guard let channelId = current?.channel.id else { return }
        let target = !(isSubscribed ?? false)
        Task {
            do {
                let subscribed = try await model.api { try await $0.setSubscribed(channelId: channelId, target) }
                // The prepared Shorts of the same channel show it too.
                for (id, info) in details where info.channel.id == channelId {
                    details[id]?.channel.isSubscribed = subscribed
                }
                if current?.channel.id == channelId { isSubscribed = subscribed }
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
        preparing.values.forEach { $0.cancel() }
        preparing = [:]
        prepared = [:]
        reporter?.stop()
        reporter = nil
        player.destroy()
    }

    private func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
