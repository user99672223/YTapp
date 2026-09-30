import SwiftUI
import Core

/// Right-hand panel over the playing video: a title with Done, then a scrolling list of rows.
/// Rows are full-width buttons with the system focus effect, and the current choice has a
/// checkmark, like the Settings lists. The watch page places the panel and puts focus on
/// `initialFocus(for:vm:player:)` when it opens. Comments come from `CommentsPanel`, shared
/// with Shorts.
struct PanelView: View {
    let panel: WatchPanel
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State
    var focus: FocusState<WatchFocus?>.Binding
    let close: () -> Void
    let openChannel: (String) -> Void

    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        if panel == .comments {
            // A floating sheet inside the safe area, like the other panels (see WatchContent).
            CommentsPanel(comments: vm.comments, margins: CommentsLayout.floating, close: close)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Spacing.row) {
                    Text(title).font(.title3.bold()).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Done", action: close)
                        .focused(focus, equals: .panelDone)
                }
                .padding([.horizontal, .top], Theme.Spacing.panel)
                ScrollView {
                    // Not lazy: the row that gets focus when the panel opens (the current chapter
                    // or stream) can be far down, and a lazy stack wouldn't have built it yet.
                    VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.panel)
                    // Also room for the focused row to grow without the scroll view cutting it.
                    .padding(.top, Theme.Spacing.titleToContent)
                    .padding(.bottom, Theme.Spacing.panel)
                }
            }
        }
    }

    private var title: String {
        switch panel {
        case .info: return "About this video"
        case .chapters: return "Chapters"
        case .captions: return "Captions"
        case .speed: return "Playback speed"
        case .quality: return "Quality"
        case .comments: return "Comments"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .info: InfoPanel(vm: vm, focus: focus, openChannel: openChannel)
        case .chapters: chaptersList
        case .captions: captionsList
        case .speed: speedList
        case .quality: QualityPanel(vm: vm, focus: focus)
        case .comments: EmptyView() // CommentsPanel, above
        }
    }

    private var chaptersList: some View {
        let chapters = vm.chapters
        let current = ChapterParser.index(of: player.position, in: chapters)
        return ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
            PanelChoice(title: chapter.title,
                        subtitle: Formatters.duration(chapter.startSeconds),
                        thumbnail: chapter.thumbnail.flatMap(URL.init(string:)),
                        selected: index == current) {
                vm.seek(to: chapter.startSeconds)
                close()
            }
            .focused(focus, equals: .panelRow(RowID.chapter(index)))
        }
    }

    private var captionsList: some View {
        let tracks = vm.details?.captions ?? []
        return Group {
            PanelChoice(title: "Off", selected: vm.activeCaption == nil) {
                vm.setCaption(nil)
                close()
            }
            .focused(focus, equals: .panelRow(RowID.captionsOff))
            if tracks.isEmpty {
                Text("This video has no captions.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(tracks) { track in
                PanelChoice(title: track.name, subtitle: track.isAuto ? "Auto-generated" : nil,
                            selected: vm.activeCaption?.id == track.id) {
                    vm.setCaption(track)
                    close()
                }
                .focused(focus, equals: .panelRow(RowID.caption(track.id)))
            }
        }
    }

    private var speedList: some View {
        ForEach(Self.speeds, id: \.self) { speed in
            PanelChoice(title: speed == 1 ? "Normal" : String(format: "%g×", speed), selected: abs(player.speed - speed) < 0.01) {
                vm.setSpeed(speed)
                close()
            }
            .focused(focus, equals: .panelRow(RowID.speed(speed)))
        }
    }
}

extension PanelView {
    /// Where focus goes when `panel` opens: the current choice (chapter, caption track, speed,
    /// stream), else the first row, else Done. Nil for comments, which `CommentsPanel` lays out
    /// itself.
    static func initialFocus(for panel: WatchPanel, vm: WatchViewModel, player: MPVPlayer.State) -> WatchFocus? {
        switch panel {
        case .comments:
            return nil
        case .chapters:
            let chapters = vm.chapters
            guard !chapters.isEmpty else { return .panelDone }
            return .panelRow(RowID.chapter(ChapterParser.index(of: player.position, in: chapters) ?? 0))
        case .captions:
            if let active = vm.activeCaption, vm.details?.captions.contains(where: { $0.id == active.id }) == true {
                return .panelRow(RowID.caption(active.id))
            }
            return .panelRow(RowID.captionsOff)
        case .speed:
            let current = speeds.first { abs(player.speed - $0) < 0.01 } ?? 1
            return .panelRow(RowID.speed(current))
        case .quality:
            // Disabled (unplayable) rows can't take focus; the chosen stream never is one.
            if vm.isOverridden, let selection = vm.selection {
                let lists = vm.formatsForOverride
                if lists.video.contains(where: { $0.index == selection.video.index && QualitySelector.isStreamable($0) }) {
                    return .panelRow(RowID.video(selection.video.index))
                }
                if let audio = selection.audio,
                   lists.audio.contains(where: { $0.index == audio.index && QualitySelector.isStreamable($0) }) {
                    return .panelRow(RowID.audio(audio.index))
                }
            }
            return .panelRow(RowID.automaticQuality)
        case .info:
            guard let details = vm.details else { return .panelDone }
            if details.channel.id != nil { return .panelRow(RowID.channel) }
            if !InfoPanel.paragraphs(of: details.description).isEmpty { return .panelRow(RowID.paragraph(0)) }
            return .panelDone
        }
    }
}

/// Ids of the panel rows, for `WatchFocus.panelRow`.
private enum RowID {
    static let captionsOff = "captions.off"
    static let automaticQuality = "quality.auto"
    static let channel = "info.channel"
    static func chapter(_ index: Int) -> String { "chapter.\(index)" }
    static func caption(_ id: String) -> String { "caption.\(id)" }
    static func speed(_ speed: Double) -> String { "speed.\(speed)" }
    static func video(_ index: Int) -> String { "video.\(index)" }
    static func audio(_ index: Int) -> String { "audio.\(index)" }
    static func paragraph(_ index: Int) -> String { "info.paragraph.\(index)" }
}

/// One row of a side panel: a full-width button with optional artwork, a title, a secondary
/// line, and a checkmark on the current choice.
struct PanelChoice: View {
    let title: String
    var subtitle: String?
    /// Leading artwork (chapter thumbnails).
    var thumbnail: URL?
    let selected: Bool
    let action: () -> Void

    init(title: String, subtitle: String? = nil, thumbnail: URL? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.row) {
                if let thumbnail {
                    RemoteImage(url: thumbnail)
                        .frame(width: 160, height: 90)
                        .continuousCorners(Theme.Radius.thumbnail)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                // Always laid out, so titles line up whether or not a row is the current one.
                Image(systemName: "checkmark")
                    .font(.callout.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(!selected)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A heading inside a panel's list ("Video", "Audio", "Description").
private struct PanelSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.top, Theme.Spacing.row)
    }
}

/// A full-width action row of the info panel (subscribe, like, Watch Later).
private struct PanelActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InfoPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var vm: WatchViewModel
    var focus: FocusState<WatchFocus?>.Binding
    let openChannel: (String) -> Void

    /// The description split into paragraphs, so a long one scrolls a paragraph at a time.
    static func paragraphs(of description: String) -> [String] {
        description.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        if let details = vm.details {
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                Text(details.title).font(.headline)
                let metadata = [details.viewCountText, details.publishedText].compactMap { $0 }.joined(separator: " • ")
                if !metadata.isEmpty {
                    Text(metadata).font(.caption).foregroundStyle(.secondary)
                }
            }

            channelRow(details.channel)

            if model.isSignedIn {
                if details.channel.id != nil {
                    PanelActionRow(title: vm.isSubscribed == true ? "Subscribed" : "Subscribe",
                                   systemImage: vm.isSubscribed == true ? "bell.fill" : "plus") {
                        vm.toggleSubscription()
                    }
                }
                HStack(spacing: Theme.Spacing.row) {
                    PanelActionRow(title: details.likeCountText ?? "Like",
                                   systemImage: vm.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        vm.rate(.like)
                    }
                    PanelActionRow(title: "Dislike",
                                   systemImage: vm.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                        vm.rate(.dislike)
                    }
                }
                PanelActionRow(title: vm.inWatchLater == true ? "In Watch Later" : "Save to Watch Later",
                               systemImage: vm.inWatchLater == true ? "clock.fill" : "clock") {
                    vm.toggleWatchLater()
                }
            }

            let paragraphs = Self.paragraphs(of: details.description)
            if !paragraphs.isEmpty {
                PanelSectionTitle(title: "Description")
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    // Focusable only so the remote can scroll through the text; clicking does nothing.
                    // The same focus look as the comments' text rows.
                    Button {} label: {
                        DescriptionParagraph(text: paragraph)
                    }
                    .buttonStyle(PanelTextRowStyle())
                    .focused(focus, equals: .panelRow(RowID.paragraph(index)))
                }
            }
        }
    }

    /// The channel's avatar, name and subscribers; a row that opens the channel when it has an id.
    @ViewBuilder
    private func channelRow(_ channel: ChannelSummary) -> some View {
        let summary = HStack(spacing: Theme.Spacing.row) {
            RemoteImage(url: channel.avatar.flatMap(URL.init(string:)))
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                Text(channel.name).font(.callout.weight(.medium)).lineLimit(1)
                if let subscribers = channel.subscriberCountText {
                    Text(subscribers).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        if let channelId = channel.id {
            Button {
                openChannel(channelId)
            } label: {
                HStack(spacing: Theme.Spacing.row) {
                    summary
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Opens the channel")
            .focused(focus, equals: .panelRow(RowID.channel))
        } else {
            summary
        }
    }
}

/// A paragraph of the description: dimmed like secondary text, full brightness while focused (on
/// the row's platter).
private struct DescriptionParagraph: View {
    let text: String
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isFocused ? .primary : .secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QualityPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var vm: WatchViewModel
    var focus: FocusState<WatchFocus?>.Binding

    var body: some View {
        let lists = vm.formatsForOverride
        if let selection = vm.selection {
            Text("Playing: \(selection.summary)").font(.caption).foregroundStyle(.secondary)
        }
        PanelChoice(title: "Automatic (your quality rule)",
                    subtitle: "AV1 → VP9 → H.264, up to \(model.settings.maxHeight)p, Opus audio",
                    selected: !vm.isOverridden) {
            vm.resetQualityOverride()
        }
        .focused(focus, equals: .panelRow(RowID.automaticQuality))
        PanelSectionTitle(title: "Video")
        ForEach(lists.video) { format in
            PanelChoice(title: format.displayName,
                        subtitle: note(for: format),
                        selected: vm.isOverridden && vm.selection?.video.index == format.index) {
                vm.choose(video: format, audio: nil)
            }
            .disabled(!QualitySelector.isStreamable(format))
            .focused(focus, equals: .panelRow(RowID.video(format.index)))
        }
        PanelSectionTitle(title: "Audio")
        ForEach(lists.audio) { format in
            PanelChoice(title: format.displayName,
                        subtitle: note(for: format),
                        selected: vm.isOverridden && vm.selection?.audio?.index == format.index) {
                vm.choose(video: nil, audio: format)
            }
            .disabled(!QualitySelector.isStreamable(format))
            .focused(focus, equals: .panelRow(RowID.audio(format.index)))
        }
    }

    private func note(for format: StreamFormat) -> String? {
        var notes: [String] = ["itag \(format.itag)"]
        if format.isHdr { notes.append("HDR (shown as SDR)") }
        if format.isOtf { notes.append("segmented — not playable") }
        if format.isDrm { notes.append("DRM — not playable") }
        if !format.hasUrl { notes.append("no URL (SABR)") }
        if format.isSuperResolution { notes.append("AI upscaled") }
        if let size = format.contentLength { notes.append(Formatters.bytes(size)) }
        return notes.joined(separator: " · ")
    }
}
