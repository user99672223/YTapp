import SwiftUI
import Core

/// Full-screen watch page. Owns one playback session (one mpv instance) for its lifetime.
struct WatchView: View {
    @EnvironmentObject private var model: AppModel
    let request: WatchRequest

    var body: some View {
        WatchScreen(request: request, model: model)
    }
}

private struct WatchScreen: View {
    @StateObject private var vm: WatchViewModel

    init(request: WatchRequest, model: AppModel) {
        _vm = StateObject(wrappedValue: WatchViewModel(videoId: request.videoId, model: model))
    }

    var body: some View {
        WatchContent(vm: vm, player: vm.player.state)
            .onAppear { vm.start() }
            .onDisappear { vm.close() }
    }
}

enum WatchPanel: String, Identifiable {
    case info, chapters, captions, speed, quality, comments, upNext
    var id: String { rawValue }
}

/// A button style with no focus decoration (used for the invisible full-screen remote catcher).
struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct WatchContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State

    enum Focus: Hashable {
        case catcher, playPause, scrubber, panel
    }

    @FocusState private var focus: Focus?
    @State private var controlsVisible = true
    @State private var panel: WatchPanel?
    @State private var scrubTarget: Double?
    @State private var scrubStep: Double = 10
    @State private var lastScrub = Date.distantPast
    @State private var scrubCommit: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: String?
    @State private var seekFlashTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(player: vm.player).ignoresSafeArea()

            if !controlsVisible, panel == nil, vm.countdown == nil, !isFailed {
                Button { showControls() } label: {
                    Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(InvisibleButtonStyle())
                .focused($focus, equals: .catcher)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: jump(-10)
                    case .right: jump(10)
                    default: showControls()
                    }
                }
                .ignoresSafeArea()
            }

            bufferingOverlay

            if let seekFlash {
                Text(seekFlash)
                    .font(.title2.monospacedDigit().bold())
                    .padding(.horizontal, 30).padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            if controlsVisible, panel == nil, !isFailed, vm.countdown == nil {
                ControlsOverlay(vm: vm, player: player, focus: $focus, scrubTarget: scrubTarget,
                                onScrub: scrub, onCommitScrub: commitScrub, onPanel: open, onActivity: bumpHideTimer)
                    .transition(.opacity)
            }

            if let panel {
                HStack {
                    Spacer()
                    PanelView(panel: panel, vm: vm, player: player, close: { closePanel() }, openChannel: openChannel)
                        .frame(width: 760)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .focusSection()
                }
                .ignoresSafeArea()
                .transition(.move(edge: .trailing))
            }

            if let countdown = vm.countdown, let next = vm.nextVideo {
                UpNextCountdown(video: next, seconds: countdown, playNow: { vm.playNext() }, cancel: { vm.cancelCountdown(); showControls() })
            }

            if case .loading(let message) = vm.phase {
                VStack(spacing: 24) {
                    ProgressView()
                    Text(message).font(.headline)
                    if let title = vm.details?.title { Text(title).foregroundStyle(.secondary).lineLimit(2) }
                }
                .padding(50)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
            }

            if case .failed(let error) = vm.phase {
                VStack(spacing: 20) {
                    ErrorStateView(error: error) { vm.retry() }
                    Button("Close") { closeWatch() }
                }
                .background(Color.black.opacity(0.85))
            }

            if let toast = vm.toast {
                VStack {
                    Text(toast)
                        .padding(.horizontal, 30).padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 60)
            }

            if model.settings.showStatsOverlay {
                VStack {
                    HStack {
                        Spacer()
                        StatsOverlay(vm: vm, player: player)
                    }
                    Spacer()
                }
                .padding(40)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: panel)
        .onPlayPauseCommand {
            vm.togglePlay()
            if !controlsVisible { flash(player.isPaused ? "▶︎" : "❚❚") }
        }
        .onExitCommand { handleExit() }
        .onChange(of: focus) { _, _ in bumpHideTimer() }
        .onChange(of: player.isPaused) { _, paused in
            if paused { showControls() } else { bumpHideTimer() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app (TV button) pauses, like the YouTube app.
            if phase == .background { vm.player.setPaused(true) }
        }
        .onAppear {
            focus = .playPause
            bumpHideTimer()
        }
    }

    private var isFailed: Bool {
        if case .failed = vm.phase { return true }
        return false
    }

    @ViewBuilder
    private var bufferingOverlay: some View {
        if vm.phase == .playing, player.isBuffering || !player.isFileLoaded, player.errorMessage == nil {
            VStack(spacing: 16) {
                ProgressView()
                if player.bufferingPercent > 0 {
                    Text("Buffering \(player.bufferingPercent)%").font(.headline.monospacedDigit())
                } else {
                    Text(player.isFileLoaded ? "Buffering…" : "Opening stream…").font(.headline)
                }
                if player.bufferedSeconds > 0 {
                    Text(String(format: "%.0f s buffered", player.bufferedSeconds)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    // MARK: - Controls visibility

    private func showControls() {
        controlsVisible = true
        focus = .playPause
        bumpHideTimer()
    }

    private func hideControls() {
        guard panel == nil, scrubTarget == nil else { return }
        controlsVisible = false
        focus = .catcher
    }

    private func bumpHideTimer() {
        hideTask?.cancel()
        guard controlsVisible, panel == nil else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, !player.isPaused, vm.phase == .playing else { return }
            hideControls()
        }
    }

    private func open(_ newPanel: WatchPanel) {
        hideTask?.cancel()
        panel = newPanel
        focus = .panel
        if newPanel == .comments { vm.comments.load() }
    }

    private func closePanel() {
        panel = nil
        showControls()
    }

    private func handleExit() {
        if panel != nil {
            closePanel()
        } else if vm.countdown != nil {
            vm.cancelCountdown()
            showControls()
        } else if controlsVisible, vm.phase == .playing {
            hideTask?.cancel()
            controlsVisible = false
            focus = .catcher
        } else {
            closeWatch()
        }
    }

    private func closeWatch() {
        vm.close()
        router.watch = nil
    }

    private func openChannel(_ id: String) {
        vm.close()
        router.open(.channel(id))
    }

    // MARK: - Seeking

    private func jump(_ delta: Double) {
        vm.seek(by: delta)
        flash(delta > 0 ? "+\(Int(delta)) s" : "−\(Int(-delta)) s")
    }

    private func flash(_ text: String) {
        seekFlash = text
        seekFlashTask?.cancel()
        seekFlashTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if !Task.isCancelled { seekFlash = nil }
        }
    }

    /// Left/right on the focused scrubber moves a preview target; repeated presses accelerate.
    private func scrub(_ direction: MoveCommandDirection) {
        guard direction == .left || direction == .right, player.duration > 0 else { return }
        let now = Date()
        scrubStep = now.timeIntervalSince(lastScrub) < 0.6 ? min(scrubStep * 1.6, 180) : 10
        lastScrub = now
        let base = scrubTarget ?? player.position
        let delta = direction == .right ? scrubStep : -scrubStep
        scrubTarget = min(max(0, base + delta), max(0, player.duration - 1))
        bumpHideTimer()
        scrubCommit?.cancel()
        scrubCommit = Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if !Task.isCancelled { commitScrub() }
        }
    }

    private func commitScrub() {
        scrubCommit?.cancel()
        if let target = scrubTarget { vm.seek(to: target) }
        scrubTarget = nil
        bumpHideTimer()
    }
}

// MARK: - Controls overlay

private struct ControlsOverlay: View {
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State
    var focus: FocusState<WatchContent.Focus?>.Binding
    let scrubTarget: Double?
    let onScrub: (MoveCommandDirection) -> Void
    let onCommitScrub: () -> Void
    let onPanel: (WatchPanel) -> Void
    let onActivity: () -> Void

    private var chapters: [Chapter] { vm.chapters }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            if let details = vm.details {
                Text(details.title).font(.title2.bold()).lineLimit(2)
                Text([details.channel.name, details.viewCountText, details.publishedText].compactMap { $0 }.joined(separator: " • "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Scrubber(position: player.position, duration: player.duration, buffered: player.bufferedSeconds,
                     chapters: chapters, target: scrubTarget, onMove: onScrub, onCommit: onCommitScrub)
                .focused(focus, equals: .scrubber)
            HStack {
                Text(Formatters.duration(scrubTarget ?? player.position))
                if let index = ChapterParser.index(of: scrubTarget ?? player.position, in: chapters) {
                    Text("• \(chapters[index].title)").lineLimit(1)
                }
                Spacer()
                Text(Formatters.duration(player.duration))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                ControlButton(systemImage: "gobackward.10") { vm.seek(by: -10); onActivity() }
                ControlButton(systemImage: player.isPaused ? "play.fill" : "pause.fill") { vm.togglePlay(); onActivity() }
                    .focused(focus, equals: .playPause)
                ControlButton(systemImage: "goforward.10") { vm.seek(by: 10); onActivity() }
                Spacer().frame(width: 30)
                if !chapters.isEmpty {
                    ControlButton(systemImage: "list.bullet.rectangle", title: "Chapters") { onPanel(.chapters) }
                }
                ControlButton(systemImage: vm.activeCaption == nil ? "captions.bubble" : "captions.bubble.fill", title: "Captions") { onPanel(.captions) }
                ControlButton(systemImage: "speedometer", title: String(format: "%g×", player.speed)) { onPanel(.speed) }
                ControlButton(systemImage: "slider.horizontal.3", title: vm.selection.map { $0.video.qualityLabel ?? "\($0.video.shortSide)p" } ?? "Quality") { onPanel(.quality) }
                ControlButton(systemImage: "info.circle", title: "Info") { onPanel(.info) }
                ControlButton(systemImage: "text.bubble", title: "Comments") { onPanel(.comments) }
            }

            if let upNext = vm.details?.upNext, !upNext.isEmpty {
                Text("Up next").font(.headline).padding(.top, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 30) {
                        ForEach(Array(upNext.prefix(20).enumerated()), id: \.offset) { _, video in
                            Button { vm.play(video) } label: {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteImage(url: video.thumbnailURL)
                                        .frame(width: 320, height: 180)
                                        .clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                                    Text(video.title).font(.caption.weight(.semibold)).lineLimit(2).padding(10)
                                }
                                .frame(width: 320, height: 180)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .frame(height: 230)
                .focusSection()
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 50)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}

private struct ControlButton: View {
    let systemImage: String
    var title: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                if let title { Text(title).font(.caption) }
            }
            .padding(.horizontal, title == nil ? 6 : 10)
        }
    }
}

/// The progress bar. Focus it and press left/right to scrub; click to jump there.
private struct Scrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let chapters: [Chapter]
    let target: Double?
    let onMove: (MoveCommandDirection) -> Void
    let onCommit: () -> Void
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button(action: onCommit) {
            ScrubberBar(position: position, duration: duration, buffered: buffered, chapters: chapters, target: target)
        }
        .buttonStyle(ScrubberButtonStyle())
        .onMoveCommand(perform: onMove)
    }
}

private struct ScrubberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrubberStyleBody(configuration: configuration)
    }

    private struct ScrubberStyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .frame(height: isFocused ? 22 : 12)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    if isFocused {
                        Text("◀︎ ▶︎ to scrub, click to jump").font(.caption2).foregroundStyle(.secondary).offset(y: -30)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

private struct ScrubberBar: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let chapters: [Chapter]
    let target: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white.opacity(0.45))
                    .frame(width: width * min(1, (position + buffered) / total))
                Capsule().fill(Color.red)
                    .frame(width: width * min(1, position / total))
                ForEach(chapters.dropFirst()) { chapter in
                    Rectangle().fill(Color.black.opacity(0.8))
                        .frame(width: 3)
                        .offset(x: width * min(1, chapter.startSeconds / total))
                }
                if let target {
                    Circle().fill(Color.white)
                        .frame(width: 26, height: 26)
                        .offset(x: width * min(1, target / total) - 13)
                    Text(Formatters.duration(target))
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .offset(x: min(max(0, width * min(1, target / total) - 40), width - 90), y: -40)
                }
            }
        }
    }
}

// MARK: - Up next countdown

private struct UpNextCountdown: View {
    let video: VideoItem
    let seconds: Int
    let playNow: () -> Void
    let cancel: () -> Void
    @FocusState private var playNowFocused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 30) {
                    RemoteImage(url: video.thumbnailURL)
                        .frame(width: 320, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Up next in \(seconds)").font(.headline).foregroundStyle(.secondary)
                        Text(video.title).font(.title3.bold()).lineLimit(2)
                        if let channel = video.channelName { Text(channel).foregroundStyle(.secondary) }
                        HStack(spacing: 20) {
                            Button("Play now", action: playNow)
                                .focused($playNowFocused)
                            Button("Cancel", action: cancel)
                        }
                    }
                    .frame(width: 560, alignment: .leading)
                }
                .padding(40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            }
        }
        .padding(60)
        .focusSection()
        .onAppear { playNowFocused = true }
    }
}

// MARK: - Stats overlay

struct StatsOverlay: View {
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State
    @State private var cpu: Double = 0
    @State private var memory: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "CPU %.0f%%", cpu) + " of \(ProcessStats.coreCount) cores")
            Text("RAM \(Formatters.bytes(Int64(memory)))")
            Text("\(player.stats.videoCodec) \(player.stats.width)×\(player.stats.height) hw:\(player.stats.hwdec)")
            Text(String(format: "fps %.3f (est %.2f) · display %@", player.stats.containerFps, player.stats.estimatedFps,
                        vm.appliedRefreshRate.map { String(format: "%.3f Hz", $0) } ?? "unchanged"))
            Text("dropped \(player.stats.droppedFrames) vo / \(player.stats.decoderDroppedFrames) dec · avsync \(String(format: "%.3f", player.stats.avsync))")
            Text(String(format: "buffer %.0f s · %@/s · cache %@", player.stats.bufferedSeconds,
                        Formatters.bytes(Int64(player.stats.cacheSpeed)), Formatters.bytes(Int64(player.stats.demuxerCacheBytes))))
            if let selection = vm.selection { Text(selection.summary) }
            if !vm.historyStatus.isEmpty { Text("history: \(vm.historyStatus)") }
        }
        .font(.system(size: 20, design: .monospaced))
        .padding(20)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .task {
            while !Task.isCancelled {
                cpu = ProcessStats.cpuPercent()
                memory = ProcessStats.memoryFootprint()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
