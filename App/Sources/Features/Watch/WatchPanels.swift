import SwiftUI
import Core

/// Right-hand panel over the playing video.
struct PanelView: View {
    let panel: WatchPanel
    @ObservedObject var vm: WatchViewModel
    @ObservedObject var player: MPVPlayer.State
    let close: () -> Void
    let openChannel: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Button("Done", action: close)
            }
            .padding(.horizontal, 40)
            .padding(.top, 50)
            .padding(.bottom, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
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
        case .upNext: return "Up next"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .info: InfoPanel(vm: vm, openChannel: openChannel)
        case .chapters: chaptersList
        case .captions: captionsList
        case .speed: speedList
        case .quality: QualityPanel(vm: vm)
        case .comments: CommentsList(comments: vm.comments)
        case .upNext: upNextList
        }
    }

    private var chaptersList: some View {
        let chapters = vm.details?.effectiveChapters ?? []
        let current = ChapterParser.index(of: player.position, in: chapters)
        return ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
            Button {
                vm.seek(to: chapter.startSeconds)
                close()
            } label: {
                HStack(spacing: 20) {
                    if let thumb = chapter.thumbnail, let url = URL(string: thumb) {
                        RemoteImage(url: url).frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(chapter.title).lineLimit(2)
                        Text(Formatters.duration(chapter.startSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if index == current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.red) }
                }
            }
        }
    }

    private var captionsList: some View {
        let tracks = vm.details?.captions ?? []
        return Group {
            PanelChoice(title: "Off", selected: vm.activeCaption == nil) {
                vm.setCaption(nil)
                close()
            }
            if tracks.isEmpty {
                Text("This video has no captions.").foregroundStyle(.secondary)
            }
            ForEach(tracks) { track in
                PanelChoice(title: track.name, subtitle: track.isAuto ? "Auto-generated" : nil, selected: vm.activeCaption?.id == track.id) {
                    vm.setCaption(track)
                    close()
                }
            }
        }
    }

    private var speedList: some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
            PanelChoice(title: speed == 1 ? "Normal" : String(format: "%.2g×", speed), selected: abs(player.speed - speed) < 0.01) {
                vm.setSpeed(speed)
                close()
            }
        }
    }

    private var upNextList: some View {
        ForEach(Array((vm.details?.upNext ?? []).enumerated()), id: \.offset) { _, video in
            Button {
                vm.play(video)
                close()
            } label: {
                HStack(spacing: 20) {
                    RemoteImage(url: video.thumbnailURL).frame(width: 200, height: 112).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.title).lineLimit(2)
                        Text(video.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct PanelChoice: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
        }
    }
}

private struct InfoPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var vm: WatchViewModel
    let openChannel: (String) -> Void

    var body: some View {
        if let details = vm.details {
            Text(details.title).font(.headline)
            Text([details.viewCountText, details.publishedText].compactMap { $0 }.joined(separator: " • "))
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 20) {
                RemoteImage(url: details.channel.avatar.flatMap(URL.init(string:)))
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(details.channel.name).font(.headline)
                    if let subs = details.channel.subscriberCountText { Text(subs).font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 16) {
                if let channelId = details.channel.id {
                    Button("Channel") { openChannel(channelId) }
                }
                if model.isSignedIn, details.channel.id != nil {
                    Button {
                        vm.toggleSubscription()
                    } label: {
                        Label(vm.isSubscribed == true ? "Subscribed" : "Subscribe",
                              systemImage: vm.isSubscribed == true ? "bell.fill" : "plus")
                    }
                    .tint(vm.isSubscribed == true ? .gray : .red)
                }
            }

            if model.isSignedIn {
                HStack(spacing: 16) {
                    Button {
                        vm.rate(.like)
                    } label: {
                        Label(details.likeCountText ?? "Like", systemImage: vm.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    Button {
                        vm.rate(.dislike)
                    } label: {
                        Image(systemName: vm.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    Button {
                        vm.toggleWatchLater()
                    } label: {
                        Label(vm.inWatchLater == true ? "In Watch Later" : "Watch Later",
                              systemImage: vm.inWatchLater == true ? "clock.fill" : "clock")
                    }
                }
            }

            if !details.description.isEmpty {
                Text("Description").font(.headline).padding(.top, 10)
                // Split into paragraphs so long descriptions scroll with the remote.
                ForEach(Array(details.description.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .focusable()
                }
            }
        }
    }
}

private struct QualityPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var vm: WatchViewModel

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
        Text("Video").font(.headline).padding(.top, 10)
        ForEach(lists.video) { format in
            PanelChoice(title: format.displayName,
                        subtitle: note(for: format),
                        selected: vm.isOverridden && vm.selection?.video.index == format.index) {
                vm.choose(video: format, audio: nil)
            }
            .disabled(!QualitySelector.isStreamable(format))
        }
        Text("Audio").font(.headline).padding(.top, 10)
        ForEach(lists.audio) { format in
            PanelChoice(title: format.displayName,
                        subtitle: note(for: format),
                        selected: vm.isOverridden && vm.selection?.audio?.index == format.index) {
                vm.choose(video: nil, audio: format)
            }
            .disabled(!QualitySelector.isStreamable(format))
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
