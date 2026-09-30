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

            // The toast: at the top, beside an open panel rather than under it. The controls sit at
            // the bottom, so it doesn't meet their title.
            VStack(spacing: Theme.Spacing.row) {
                if let toast = vm.toast {
                    // Plain text: the watch page's messages report failures too.
                    ToastView(text: toast)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, videoInset)

            // Loading and buffering while the controls are hidden (or a panel or the countdown
            // stands in for them): centred on the video, left of an open panel. With the controls
            // up, the box is part of their column, above the title (`ControlsOverlay`).
            if !showsControls {
                VStack(spacing: Theme.Spacing.row) {
                    if let status = WatchStatus(vm: vm, player: player) {
                        StatusBox(status: status)
                    }
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
        // `videoId` isn't published, but `load(videoId:)` publishes in the same step (countdown,
        // phase), so the page is redrawn with the new id.
        .onChange(of: vm.videoId) { _, _ in videoChanged() }
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

    private var catcher: some View {
        Button { showControls() } label: {
            Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(InvisibleButtonStyle())
        .focused($focus, equals: .catcher)
        .onMoveCommand { direction in
            switch direction {
            // ±10 s once there is a video to seek in; while the next one loads (the controls
            // can be hidden then too), left/right bring the controls up like up/down.
            case .left where vm.phase == .playing: jump(-10)
            case .right where vm.phase == .playing: jump(10)
            default: showControls()
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Controls visibility and focus

    /// Shows the controls. Focus goes to Play/Pause when they were hidden, like the system
    /// player; if they are already up (pausing from the remote), it stays where it is.
    private func showControls() {
        if !controlsVisible, panel == nil, vm.countdown == nil { focus = .playPause }
        controlsVisible = true
        bumpHideTimer()
    }

    /// The hide timer: only while nothing else holds the screen or the remote.
    private func hideControls() {
        guard panel == nil, scrubTarget == nil, vm.countdown == nil, !isFailed else { return }
        hideNow()
    }

    /// Hides the controls; the invisible catcher takes the remote.
    private func hideNow() {
        hideTask?.cancel()
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
            // Nil for comments, which place their own focus (the system lands in the panel,
            // the only focusable part of the screen then).
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
            // No Chapters button to go back to (the details changed and have none).
            focus = .playPause
        default:
            focus = .opener(closing)
        }
        bumpHideTimer()
    }

    /// The countdown's Cancel button: the viewer stays on this video, so the controls come up
    /// (Play again, Up next).
    private func cancelCountdown() {
        vm.cancelCountdown()
        if panel == nil { showControls() }
    }

    /// Back on the up-next countdown: autoplay stops and the box goes, and nothing comes up in
    /// its place. The controls stay hidden (the finished video's pause raised them under the
    /// box), so the next Back leaves the page; a panel open under the box gets focus back.
    private func dismissCountdown() {
        if panel == nil {
            hideTask?.cancel()
            controlsVisible = false
        }
        vm.cancelCountdown()
        // `onChange(of: vm.countdown == nil)` puts focus back: on the panel, else the catcher.
    }

    /// Another video started in this session (autoplay, Play now, an Up next card). An open panel
    /// belongs to the previous one (its chapters, captions, streams, comments): it closes back to
    /// the controls, which now show the new title. A scrub preview is dropped rather than
    /// seeking the new video to a time on the old one's bar. Otherwise a panel could stay open
    /// across the change, and Back, meant to leave, would first close it.
    private func videoChanged() {
        scrubCommit?.cancel()
        scrubTarget = nil
        guard panel != nil else { return }
        panel = nil
        panelFocus = nil
        controlsVisible = true
        if vm.countdown == nil { focus = .playPause }
        bumpHideTimer()
    }

    /// Back/Menu takes away one thing, the one on top, in this order: a scrub preview (dropped,
    /// like the system player's), the up-next countdown (it takes focus when it appears, even over
    /// an open panel), a side panel (focus goes back to the button that opened it), the controls,
    /// and, with nothing left on screen, the watch page itself. The same whether the video is
    /// playing, paused or still loading: controls on screen are hidden first, never skipped.
    private func handleExit() {
        if scrubTarget != nil {
            cancelScrub()
        } else if vm.countdown != nil {
            dismissCountdown()
        } else if panel != nil {
            closePanel()
        } else if showsControls {
            hideNow()
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
/// Everything sits at the bottom of the screen: the Spacer on top is the only view in the column
/// that grows (the Up next scroll view is held to its content's height, the progress bar to its
/// own), and loading/buffering takes its place above the title rather than floating over it.
private struct ControlsOverlay: View {
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State
    var focus: FocusState<WatchFocus?>.Binding
    let scrubTarget: Double?
    let onScrub: (MoveCommandDirection) -> Void
    let onCommitScrub: () -> Void
    let onPanel: (WatchPanel) -> Void
    let onActivity: () -> Void

    /// None while the next video loads: the previous one's details, and so its chapters, stay
    /// until the next one's arrive, like the title and Up next (which also wait for them).
    private var chapters: [Chapter] { vm.details?.id == vm.videoId ? vm.chapters : [] }
    /// The scrub preview while there is one, else where the video is.
    private var shownPosition: Double { scrubTarget ?? player.position }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            // In the column, so it can't cover the title or the controls; it grows upwards into
            // the Spacer, and nothing below it moves when it comes and goes.
            if let status = WatchStatus(vm: vm, player: player) {
                StatusBox(status: status, showsTitle: false, alignment: .leading)
                    .padding(.bottom, Theme.Spacing.titleToContent)
            }
            VStack(alignment: .leading, spacing: 0) {
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
    }

    /// How far above the title the scrim starts to darken the video.
    private static let scrimFade: CGFloat = 200

    /// Darkens the video behind the controls: it fades in above the title and reaches the
    /// screen's bottom and side edges, so the title and times read on any picture, however tall
    /// the controls are (with or without Up next).
    private var scrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.scrimFade)
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        }
        .padding(.top, -Self.scrimFade)
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

/// What the loading/buffering box reports; nil (no box) while the video plays normally, and on
/// the failure screen, which says what went wrong itself.
private enum WatchStatus: Equatable {
    /// Fetching the video or unlocking its stream, with its title once the details are in.
    case loading(message: String, title: String?)
    /// The stream is opening, or refilling its buffer.
    case buffering(percent: Int, fileLoaded: Bool, bufferedSeconds: Double)

    @MainActor
    init?(vm: WatchViewModel, player: MPVPlayer.State) {
        if case .loading(let message) = vm.phase {
            // The previous video's details stay until the next one's arrive; not its title.
            let title = vm.details.flatMap { $0.id == vm.videoId ? $0.title : nil }
            self = .loading(message: message, title: title)
        } else if vm.phase == .playing, player.isBuffering || !player.isFileLoaded, player.errorMessage == nil {
            self = .buffering(percent: player.bufferingPercent, fileLoaded: player.isFileLoaded,
                              bufferedSeconds: player.bufferedSeconds)
        } else {
            return nil
        }
    }
}

/// Loading or buffering, in one compact box (a spinner beside the text).
private struct StatusBox: View {
    let status: WatchStatus
    /// The video's title under a loading message; off in the controls, whose title is right below.
    var showsTitle = true
    /// Where the box sits in its (at most `Theme.messageWidth` wide) frame: centred on the video,
    /// or leading, in line with the controls' title.
    var alignment: Alignment = .center

    var body: some View {
        HStack(spacing: Theme.Spacing.titleToContent) {
            ProgressView()
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                switch status {
                case .loading(let message, let title):
                    Text(message).font(.headline)
                    if showsTitle, let title {
                        Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                case .buffering(let percent, let fileLoaded, let bufferedSeconds):
                    if percent > 0 {
                        Text("Buffering \(percent)%").font(.headline.monospacedDigit())
                    } else {
                        Text(fileLoaded ? "Buffering…" : "Opening stream…").font(.headline)
                    }
                    if bufferedSeconds > 0 {
                        Text(String(format: "%.0f s buffered", bufferedSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .floatingBox()
        .frame(maxWidth: Theme.messageWidth, alignment: alignment)
    }
}

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
