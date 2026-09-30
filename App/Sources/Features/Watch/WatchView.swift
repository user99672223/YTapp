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
    case info, chapters, captions, speed, quality, comments
    var id: String { rawValue }
}

/// What has focus on the watch page. The controls and the side panels share one focus state, so
/// opening a panel can put focus on its current choice and closing it can give focus back to the
/// button that opened it.
enum WatchFocus: Hashable {
    /// The invisible full-screen button that takes the remote while the controls are hidden.
    case catcher
    case playPause
    case scrubber
    /// The button in the controls that opens this panel.
    case opener(WatchPanel)
    /// A row of the open side panel (ids from `PanelView`).
    case panelRow(String)
    /// The open side panel's Done button.
    case panelDone
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

    @FocusState private var focus: WatchFocus?
    @State private var controlsVisible = true
    @State private var panel: WatchPanel?
    /// Where focus went when `panel` opened; also where it goes if it gets lost inside the panel.
    @State private var panelFocus: WatchFocus?
    @State private var scrubTarget: Double?
    @State private var scrubStep: Double = 10
    @State private var lastScrub = Date.distantPast
    @State private var scrubCommit: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: SeekFlash?
    @State private var seekFlashTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(player: vm.player).ignoresSafeArea()

            if !controlsVisible, panel == nil, vm.countdown == nil, !isFailed {
                catcher
            }

            if showsControls {
                ControlsOverlay(vm: vm, player: player, focus: $focus, scrubTarget: scrubTarget,
                                onScrub: scrub, onCommitScrub: commitScrub, onPanel: open, onActivity: bumpHideTimer)
                    .transition(.opacity)
            }

            if let panel {
                // A floating sheet inside the safe area. It slides in only a little, so it is on
                // screen (and can take focus) from the first frame of the animation.
                PanelView(panel: panel, vm: vm, player: player, focus: $focus,
                          close: { closePanel() }, openChannel: openChannel)
                    .frame(width: Theme.panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .continuousCorners(Theme.Radius.panel)
                    .focusSection()
                    .defaultFocus($focus, panelFocus ?? .panelDone)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity.combined(with: .offset(x: 60)))
            }

            // The toast, and loading/buffering while the controls cover the lower part of the
            // screen: at the top, beside an open panel rather than under it.
            VStack(spacing: Theme.Spacing.row) {
                if let toast = vm.toast {
                    // Plain text: the watch page's messages report failures too.
                    ToastView(text: toast)
                }
                if showsControls {
                    statusBox
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, videoInset)

            if !showsControls {
                VStack(spacing: Theme.Spacing.row) {
                    statusBox
                    if let seekFlash {
                        SeekFlashView(flash: seekFlash)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, videoInset)
            }

            if let countdown = vm.countdown, let next = vm.nextVideo {
                UpNextCountdown(video: next, seconds: countdown, playNow: { vm.playNext() }, cancel: { cancelCountdown() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, videoInset)
                    .transition(.opacity)
            }

            if case .failed(let error) = vm.phase {
                ZStack {
                    Color.black.opacity(0.85).ignoresSafeArea()
                    ErrorStateView(error: error, secondary: .init(title: "Close") { closeWatch() }) {
                        vm.retry()
                    }
                }
            }

            // Not over a side panel, which it would cover.
            if model.settings.showStatsOverlay, panel == nil {
                StatsOverlay(vm: vm, player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: panel)
        .animation(.easeInOut(duration: 0.25), value: vm.countdown == nil)
        .animation(.easeOut(duration: 0.2), value: vm.toast)
        .animation(.easeOut(duration: 0.15), value: seekFlash)
        .onPlayPauseCommand {
            let resuming = player.isPaused || player.isEOF
            vm.togglePlay()
            // Pausing brings the controls up (below); resuming with them hidden shows a short sign.
            if !controlsVisible, resuming { flash(SeekFlash(systemImage: "play.fill")) }
        }
        .onExitCommand { handleExit() }
        .onChange(of: focus) { _, _ in bumpHideTimer() }
        .onChange(of: player.isPaused) { _, paused in
            if paused { showControls() } else { bumpHideTimer() }
        }
        .onChange(of: isFailed) { _, failed in
            if failed {
                // The failure screen takes the remote. A panel left open under it would keep
                // focus on rows nobody can see.
                hideTask?.cancel()
                scrubCommit?.cancel()
                scrubTarget = nil
                panel = nil
                panelFocus = nil
            } else {
                controlsVisible = true
                restoreFocus()
            }
        }
        .onChange(of: vm.countdown == nil) { _, ended in
            // Play now, Cancel, Back or the countdown running out: the focused box went away.
            if ended { restoreFocus() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app (TV button) pauses, like the YouTube app.
            vm.setInBackground(phase == .background)
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

    /// The controls overlay is on screen (not hidden, and nothing covers its place).
    private var showsControls: Bool {
        controlsVisible && panel == nil && !isFailed && vm.countdown == nil
    }

    /// How much of the right side an open panel covers; status boxes center on the rest.
    private var videoInset: CGFloat {
        panel == nil ? 0 : Theme.panelWidth + Theme.Spacing.row
    }

    private var isBuffering: Bool {
        vm.phase == .playing && (player.isBuffering || !player.isFileLoaded) && player.errorMessage == nil
    }

    private var catcher: some View {
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

    /// Loading or buffering, in one compact box (a spinner beside the text).
    @ViewBuilder
    private var statusBox: some View {
        if case .loading(let message) = vm.phase {
            HStack(spacing: Theme.Spacing.titleToContent) {
                ProgressView()
                VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                    Text(message).font(.headline)
                    // The previous video's details stay until the next one's arrive.
                    if let details = vm.details, details.id == vm.videoId {
                        Text(details.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .floatingBox()
            .frame(maxWidth: Theme.messageWidth)
        } else if isBuffering {
            HStack(spacing: Theme.Spacing.titleToContent) {
                ProgressView()
                VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                    if player.bufferingPercent > 0 {
                        Text("Buffering \(player.bufferingPercent)%").font(.headline.monospacedDigit())
                    } else {
                        Text(player.isFileLoaded ? "Buffering…" : "Opening stream…").font(.headline)
                    }
                    if player.bufferedSeconds > 0 {
                        Text(String(format: "%.0f s buffered", player.bufferedSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .floatingBox()
        }
    }

    // MARK: - Controls visibility and focus

    /// Shows the controls. Focus goes to Play/Pause when they were hidden, like the system
    /// player; if they are already up (pausing from the remote), it stays where it is.
    private func showControls() {
        if !controlsVisible, panel == nil, vm.countdown == nil { focus = .playPause }
        controlsVisible = true
        bumpHideTimer()
    }

    private func hideControls() {
        guard panel == nil, scrubTarget == nil, vm.countdown == nil, !isFailed else { return }
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

    /// Gives focus back to the page after something that held it went away (the up-next
    /// countdown, the failure screen): the open panel, else the controls, else the remote catcher.
    private func restoreFocus() {
        if panel != nil {
            focus = panelFocus
        } else if controlsVisible {
            focus = .playPause
            bumpHideTimer()
        } else {
            focus = .catcher
        }
    }

    private func open(_ newPanel: WatchPanel) {
        hideTask?.cancel()
        // Straight to the current choice (or the first row), not wherever the system lands
        // when the button that had focus disappears.
        let target = PanelView.initialFocus(for: newPanel, vm: vm, player: player)
        panelFocus = target
        panel = newPanel
        focus = target
    }

    /// Closes the panel and gives focus back to the button that opened it.
    private func closePanel() {
        guard let closing = panel else { return }
        panel = nil
        panelFocus = nil
        controlsVisible = true
        switch closing {
        case .chapters where vm.chapters.isEmpty:
            // The video changed under the panel and the new one has no Chapters button.
            focus = .playPause
        default:
            focus = .opener(closing)
        }
        bumpHideTimer()
    }

    private func cancelCountdown() {
        vm.cancelCountdown()
        if panel == nil { showControls() }
    }

    /// Back: a scrub preview is dropped first (like the system player), then the countdown,
    /// the panel, the controls, and last the watch page itself. The countdown goes before the
    /// panel because it takes focus when it appears, even over an open panel.
    private func handleExit() {
        if scrubTarget != nil {
            cancelScrub()
        } else if vm.countdown != nil {
            cancelCountdown()
        } else if panel != nil {
            closePanel()
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
        flash(SeekFlash(systemImage: delta > 0 ? "goforward" : "gobackward",
                        text: delta > 0 ? "+\(Int(delta)) s" : "−\(Int(-delta)) s"))
    }

    private func flash(_ content: SeekFlash) {
        seekFlash = content
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

    /// Back while scrubbing: drop the preview and stay where the video is.
    private func cancelScrub() {
        scrubCommit?.cancel()
        scrubTarget = nil
        bumpHideTimer()
    }
}

// MARK: - Controls overlay

/// The controls over the video, laid out like the system player's: title and channel, the
/// progress bar with elapsed and remaining time, a row of round buttons, and Up next below.
private struct ControlsOverlay: View {
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State
    var focus: FocusState<WatchFocus?>.Binding
    let scrubTarget: Double?
    let onScrub: (MoveCommandDirection) -> Void
    let onCommitScrub: () -> Void
    let onPanel: (WatchPanel) -> Void
    let onActivity: () -> Void

    private var chapters: [Chapter] { vm.chapters }
    /// The scrub preview while there is one, else where the video is.
    private var shownPosition: Double { scrubTarget ?? player.position }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            titleBlock
            Scrubber(position: player.position, duration: player.duration, buffered: player.bufferedSeconds,
                     chapters: chapters, target: scrubTarget, onMove: onScrub, onCommit: onCommitScrub)
                .focused(focus, equals: .scrubber)
            timeRow
                .padding(.top, 4)
            buttonRow
                .padding(.top, Theme.Spacing.titleToContent)
            upNextRow
        }
        .background { scrim }
    }

    /// Darkens the lower part of the video behind the controls, edge to edge.
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0), location: 0),
            .init(color: .black.opacity(0.3), location: 0.3),
            .init(color: .black.opacity(0.75), location: 0.6),
            .init(color: .black.opacity(0.9), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var titleBlock: some View {
        // The previous video's details stay until the next one's arrive; don't label it with them.
        if let details = vm.details, details.id == vm.videoId {
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                Text(details.title)
                    .font(.title3.bold())
                    .lineLimit(2)
                Text([details.channel.name, details.viewCountText, details.publishedText]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.bottom, Theme.Spacing.titleToContent)
        }
    }

    /// Elapsed time (and chapter) on the left, remaining time on the right, as on the system
    /// player; both follow the scrub preview.
    private var timeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Formatters.duration(shownPosition))
                .foregroundStyle(scrubTarget == nil ? .secondary : .primary)
            if let index = ChapterParser.index(of: shownPosition, in: chapters) {
                Text("• \(chapters[index].title)")
                    .lineLimit(1)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer(minLength: Theme.Spacing.row)
            if player.duration > 0 {
                Text("−" + Formatters.duration(max(0, player.duration - shownPosition)))
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .overlay {
            if focus.wrappedValue == .scrubber, scrubTarget == nil {
                Text("◀︎ ▶︎ to scrub, click to jump")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: Theme.Spacing.row) {
            ControlButton(title: "Back 10 seconds", systemImage: "gobackward.10") {
                vm.seek(by: -10)
                onActivity()
            }
            ControlButton(title: playTitle, systemImage: playSymbol) {
                vm.togglePlay()
                onActivity()
            }
            .focused(focus, equals: .playPause)
            ControlButton(title: "Forward 10 seconds", systemImage: "goforward.10") {
                vm.seek(by: 10)
                onActivity()
            }
            Spacer(minLength: Theme.Spacing.section)
            if !chapters.isEmpty {
                panelButton(.chapters, title: "Chapters", systemImage: "list.bullet.rectangle")
            }
            panelButton(.captions, title: "Captions",
                        systemImage: vm.activeCaption == nil ? "captions.bubble" : "captions.bubble.fill")
            panelButton(.speed, title: "Speed", systemImage: "speedometer",
                        value: String(format: "%g×", player.speed))
            panelButton(.quality, title: "Quality", systemImage: "slider.horizontal.3",
                        value: vm.selection.map { $0.video.qualityLabel ?? "\($0.video.shortSide)p" })
            panelButton(.info, title: "Info", systemImage: "info.circle")
            panelButton(.comments, title: "Comments", systemImage: "text.bubble")
        }
    }

    private var playTitle: String {
        if player.isEOF { return "Play again" }
        return player.isPaused ? "Play" : "Pause"
    }

    private var playSymbol: String {
        if player.isEOF { return "arrow.counterclockwise" }
        return player.isPaused ? "play.fill" : "pause.fill"
    }

    /// A button that opens a side panel. Its name shows under it while it has focus, since a
    /// symbol alone doesn't always say what it opens.
    private func panelButton(_ panel: WatchPanel, title: String, systemImage: String, value: String? = nil) -> some View {
        ControlButton(title: title, systemImage: systemImage, value: value,
                      showsTitle: focus.wrappedValue == .opener(panel)) {
            onPanel(panel)
        }
        .focused(focus, equals: .opener(panel))
    }

    /// Width of the cards in the Up next row.
    private static let upNextCardWidth: CGFloat = 288

    @ViewBuilder
    private var upNextRow: some View {
        // The previous video's details stay until the next one's arrive; so would its Up next.
        if let details = vm.details, details.id == vm.videoId, !details.upNext.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
                Text("Up next").font(.headline).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                        ForEach(Array(details.upNext.prefix(20).enumerated()), id: \.offset) { _, video in
                            // The app's video card, playing in this watch session.
                            VideoCard(video: video, width: Self.upNextCardWidth) {
                                vm.play(video)
                                // This row turns into the next video's; keep focus on a control
                                // that stays.
                                focus.wrappedValue = .playPause
                                onActivity()
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // A horizontal scroll view also stretches vertically: without this it took the
                // overlay's free height from the Spacer above and pushed the controls to the top.
                .fixedSize(horizontal: false, vertical: true)
                // The focused card grows and casts a shadow past the row's edges.
                .scrollClipDisabled()
                .focusSection()
            }
            .padding(.top, Theme.Spacing.section)
        }
    }
}

/// A button in the controls row, in the system player's style: a round symbol button, or a
/// capsule when it also shows a value (speed, quality). The focus effect is the system's.
private struct ControlButton: View {
    let title: String
    let systemImage: String
    var value: String? = nil
    /// Shows `title` under the button (the parent sets it while the button has focus).
    var showsTitle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                if let value {
                    Text(value).monospacedDigit()
                }
            }
            .font(.body.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(value == nil ? .circle : .capsule)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .overlay(alignment: .bottom) {
            // Below the button without taking layout space, so the row doesn't move.
            if showsTitle {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0[.top] - 18 }
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The progress bar. Focus it and press left/right to scrub: a preview time that it jumps to a
/// moment after the last press, or on click.
private struct Scrubber: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let chapters: [Chapter]
    let target: Double?
    let onMove: (MoveCommandDirection) -> Void
    let onCommit: () -> Void

    var body: some View {
        Button(action: onCommit) {
            ScrubberBar(position: position, duration: duration, buffered: buffered, chapters: chapters, target: target)
        }
        .buttonStyle(ScrubberButtonStyle())
        .onMoveCommand(perform: onMove)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Formatters.duration(target ?? position)) of \(Formatters.duration(duration))")
    }
}

/// The bar grows and shows its playhead while focused, like the system player's transport bar.
/// Its layout height stays the same, so nothing around it moves.
private struct ScrubberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrubberStyleBody(configuration: configuration)
    }

    private struct ScrubberStyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .frame(height: isFocused ? 16 : 8)
                .frame(height: 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
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
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(isFocused ? 0.35 : 0.25))
                Capsule().fill(Color.white.opacity(0.5))
                    .frame(width: x(position + buffered, width))
                Capsule().fill(Color.red)
                    .frame(width: x(position, width))
                ForEach(chapters.dropFirst()) { chapter in
                    Rectangle().fill(Color.black.opacity(0.8))
                        .frame(width: 3)
                        .offset(x: x(chapter.startSeconds, width) - 1.5)
                }
            }
            // Overlays, so the playhead and the preview time don't change the bar's size.
            .overlay(alignment: .leading) {
                if isFocused || target != nil {
                    Circle().fill(Color.white)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.4), radius: 6)
                        .offset(x: x(target ?? position, width) - 14)
                }
            }
            .overlay(alignment: .topLeading) {
                if let target {
                    Text(Formatters.duration(target))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .fixedSize()
                        .position(x: min(max(x(target, width), 80), max(80, width - 80)), y: -44)
                }
            }
        }
    }

    /// Distance of `seconds` from the bar's leading edge, for a bar `width` points wide.
    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        width * CGFloat(min(1, max(0, seconds / max(duration, 1))))
    }
}

// MARK: - Floating boxes
//
// The watch page's floating boxes (loading, buffering, seek flash, toast, up-next countdown,
// stats) are `floatingBox(compact:)`s, like the app's toast (Components.swift).

/// A short sign over the video while the controls are hidden: a jump (±10 s) or play.
private struct SeekFlash: Equatable {
    let systemImage: String
    var text: String? = nil
}

private struct SeekFlashView: View {
    let flash: SeekFlash

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: flash.systemImage)
            if let text = flash.text {
                Text(text).monospacedDigit()
            }
        }
        .font(.title3.weight(.semibold))
        .floatingBox(compact: true)
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
        HStack(spacing: 32) {
            RemoteImage(url: video.thumbnailURL)
                .frame(width: 320, height: 180)
                .continuousCorners(Theme.Radius.card)
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                Text("Up next in \(seconds)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(video.title).font(.headline).lineLimit(2)
                if let channel = video.channelName {
                    Text(channel).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: Theme.Spacing.row) {
                    Button("Play now", action: playNow)
                        .focused($playNowFocused)
                    Button("Cancel", action: cancel)
                }
                .padding(.top, Theme.Spacing.row)
            }
            .frame(width: 560, alignment: .leading)
        }
        .floatingBox()
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
        .font(.caption2.monospaced())
        .floatingBox()
        .task {
            while !Task.isCancelled {
                cpu = ProcessStats.cpuPercent()
                memory = ProcessStats.memoryFootprint()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
