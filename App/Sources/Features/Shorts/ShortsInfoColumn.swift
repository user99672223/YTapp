import SwiftUI
import Core

/// The column to the right of the Short, bottom-aligned with its video, as in YouTube's own TV
/// app: the title, the channel, Subscribe, then a row of round buttons (like, comments, More).
///
/// While the video has focus the rows are plain text and the buttons plain symbols. Once focus
/// is anywhere in the column the rows become rounded pills and the buttons circles, the focused
/// one white with dark text, and the focused button's caption (the like count, the comment count,
/// "More") appears under it.
///
/// More (⋮) swaps the rows above the buttons for a short menu: Dislike (YouTube's Shorts have no
/// dislike button of their own any more) and Go to channel. Back, or focus leaving it, closes it.
struct ShortsInfoColumn: View {
    @ObservedObject var vm: ShortsViewModel
    @ObservedObject var comments: CommentsModel
    let focus: FocusState<ShortsFocus?>.Binding
    /// Focus is in this column: the rows show as pills.
    let isActive: Bool
    let menuOpen: Bool
    @Binding var titleExpanded: Bool
    let openComments: () -> Void
    let toggleMenu: () -> Void
    let openChannel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ShortsLayout.rowSpacing) {
            if menuOpen {
                menuRows
            } else if let short = vm.current {
                infoRows(short)
            }
            buttonRow
        }
        .frame(width: ShortsLayout.columnWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, ShortsLayout.buttonRowBottom)
        .animation(.easeInOut(duration: 0.2), value: menuOpen)
    }

    // MARK: - Rows

    @ViewBuilder
    private func infoRows(_ short: ShortDetails) -> some View {
        // Select shows the whole title and the view count; again, back to three lines.
        Button {
            titleExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines * 2) {
                Text(short.title)
                    .font(.title3.bold())
                    .lineLimit(titleExpanded ? 8 : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if titleExpanded, let views = short.viewCountText, !views.isEmpty {
                    Text(views)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, ShortsLayout.pillPadding)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ShortsPillStyle(isActive: isActive))
        .focused(focus, equals: .title)
        .accessibilityHint("Shows the whole title")

        Button(action: openChannel) {
            ShortsRowLabel {
                ShortsChannelAvatar(channel: short.channel, size: ShortsLayout.avatarSize)
            } text: {
                Text(short.channel.name)
            }
        }
        .buttonStyle(ShortsPillStyle(isActive: isActive))
        .focused(focus, equals: .channel)
        .disabled(short.channel.id == nil)
        .accessibilityLabel("Go to \(short.channel.name)")

        if short.channel.id != nil {
            let subscribed = vm.isSubscribed == true
            Button {
                vm.toggleSubscription()
            } label: {
                ShortsRowLabel {
                    Image(systemName: subscribed ? "checkmark" : "plus")
                        .font(.system(size: 30, weight: .medium))
                } text: {
                    Text(subscribed ? "Subscribed" : "Subscribe")
                }
            }
            .buttonStyle(ShortsPillStyle(isActive: isActive))
            .focused(focus, equals: .subscribe)
        }
    }

    @ViewBuilder
    private var menuRows: some View {
        let disliked = vm.likeStatus == .dislike
        Button {
            vm.rate(.dislike)
        } label: {
            ShortsRowLabel {
                Image(systemName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 30, weight: .medium))
            } text: {
                Text(disliked ? "Disliked" : "Dislike")
            }
        }
        .buttonStyle(ShortsPillStyle(isActive: true))
        .focused(focus, equals: .menuDislike)
        .disabled(vm.current == nil)
        .accessibilityValue(disliked ? "On" : "Off")

        Button(action: openChannel) {
            ShortsRowLabel {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 30, weight: .medium))
            } text: {
                Text("Go to channel")
            }
        }
        .buttonStyle(ShortsPillStyle(isActive: true))
        .focused(focus, equals: .menuChannel)
        .disabled(vm.current?.channel.id == nil)
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: ShortsLayout.buttonSpacing) {
            ShortsRoundButton(title: "Like", caption: vm.current?.likeCountText ?? "Like",
                              systemImage: vm.likeStatus == .like ? "heart.fill" : "heart",
                              isActive: isActive, focus: focus, target: .like) {
                vm.rate(.like)
            }
            ShortsRoundButton(title: "Comments", caption: commentCount ?? "Comments", systemImage: "text.bubble",
                              isActive: isActive, focus: focus, target: .comments, action: openComments)
            ShortsRoundButton(title: "More", caption: "More", systemImage: "ellipsis", rotatesSymbol: true,
                              isActive: isActive || menuOpen, focus: focus, target: .more, action: toggleMenu)
        }
        // The symbols line up with the avatar in the channel row.
        .padding(.leading, ShortsLayout.pillPadding + (ShortsLayout.avatarSize - ShortsLayout.buttonSize) / 2)
        // Down from Subscribe lands on the like button, not the button nearest the row's middle.
        .focusSection()
        .defaultFocus(focus, .like, priority: .userInitiated)
        // Room for the caption under the focused button, so nothing moves when it appears.
        .padding(.bottom, ShortsLayout.captionHeight)
    }

    /// The Short's own count ("1.2K"), else the loaded comments' ("1,234 Comments" → "1,234").
    private var commentCount: String? {
        vm.current?.commentsCountText ?? ShortsInfoColumn.count(from: comments.countText)
    }

    /// "1,234 Comments" → "1,234"; nil when the text has no number.
    static func count(from text: String?) -> String? {
        guard let first = text?.split(separator: " ").first, first.first?.isNumber == true else { return nil }
        return String(first)
    }
}

/// A row's content: a 52-point leading piece (the avatar or a symbol), then the text, padded so
/// the text sits where the pill's padding puts it whether or not the pill is drawn.
private struct ShortsRowLabel<Leading: View, Title: View>: View {
    let leading: Leading
    let text: Title

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder text: () -> Title) {
        self.leading = leading()
        self.text = text()
    }

    var body: some View {
        HStack(spacing: 18) {
            leading
                .frame(width: ShortsLayout.avatarSize, height: ShortsLayout.avatarSize)
            text
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, ShortsLayout.pillPadding)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One round button of the column with its caption under it, shown only while it has focus.
private struct ShortsRoundButton: View {
    let title: String
    let caption: String
    let systemImage: String
    /// The vertical ⋮ is the horizontal ellipsis turned a quarter.
    var rotatesSymbol = false
    let isActive: Bool
    let focus: FocusState<ShortsFocus?>.Binding
    let target: ShortsFocus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .rotationEffect(.degrees(rotatesSymbol ? 90 : 0))
                .frame(width: ShortsLayout.buttonSize, height: ShortsLayout.buttonSize)
        }
        .buttonStyle(ShortsCircleStyle(isActive: isActive))
        .focused(focus, equals: target)
        .accessibilityLabel(title)
        .accessibilityValue(caption == title ? "" : caption)
        .overlay(alignment: .top) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .offset(y: ShortsLayout.buttonSize + 14)
                .opacity(focus.wrappedValue == target ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: focus.wrappedValue == target)
                .accessibilityHidden(true)
        }
    }
}

/// The column's rows: plain text while the video has focus; with focus in the column, a dark
/// translucent pill, white with dark text when focused. No lift: the official app's rows don't
/// grow either, and a lifted row would overlap the next.
struct ShortsPillStyle: ButtonStyle {
    let isActive: Bool
    var radius: CGFloat = ShortsLayout.pillRadius

    func makeBody(configuration: Configuration) -> some View {
        ShortsPillBody(configuration: configuration, isActive: isActive, radius: radius)
    }
}

private struct ShortsPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    let radius: CGFloat
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.2), value: isActive)
    }

    private var fill: Color {
        if isFocused { return .white }
        return .white.opacity(isActive ? 0.12 : 0)
    }
}

/// The round buttons: a plain symbol while the video has focus; a dark translucent circle with
/// focus in the column, white with a dark symbol when focused.
private struct ShortsCircleStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        ShortsCircleBody(configuration: configuration, isActive: isActive)
    }
}

private struct ShortsCircleBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background {
                Circle().fill(isFocused ? Color.white : Color.white.opacity(isActive ? 0.12 : 0))
            }
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

/// The channel's avatar, or its initial on a plain circle (when the reel answer had no avatar).
struct ShortsChannelAvatar: View {
    let channel: ChannelSummary
    var size: CGFloat = ShortsLayout.avatarSize

    var body: some View {
        Group {
            if let avatar = channel.avatar, let url = URL(string: avatar) {
                RemoteImage(url: url)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .overlay(
                        Text(channel.name.drop(while: { $0 == "@" }).first.map { String($0).uppercased() } ?? "")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
