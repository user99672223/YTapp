import SwiftUI
import Core

/// What can hold focus in the comments panel. Comments and replies are keyed by id, so focus stays
/// on the same comment while pages are added below it.
enum CommentFocus: Hashable {
    case back
    case done
    case draft
    case post
    case retryPost
    case comment(String)
    case moreComments
    /// Retry of a first page (of comments or of replies) that failed.
    case retry
    /// The "no comments" line.
    case empty
    /// A piece of the open comment's text (`CommentThreadModel.chunks`).
    case text(Int)
    case reply(String)
    case moreReplies
}

/// Measurements of the comments panel. The hosts let the panel's material reach the screen's
/// edges (it ignores the safe area), so its content keeps tvOS' 60-point top/bottom and 80-point
/// side margins itself.
enum CommentsLayout {
    static let top: CGFloat = 60
    static let bottom: CGFloat = 60
    static let leading = Theme.Spacing.panel
    static let trailing: CGFloat = 80
    static let avatar: CGFloat = 60
    static let replyAvatar: CGFloat = 44
    /// Replies sit this much further right than the comment they answer.
    static let replyIndent: CGFloat = 40
}

extension View {
    /// `focused(_:equals:)` when the list is in `CommentsPanel`, which moves focus by code.
    @ViewBuilder
    func commentFocus(_ binding: FocusState<CommentFocus?>.Binding?, _ value: CommentFocus) -> some View {
        if let binding {
            focused(binding, equals: value)
        } else {
            self
        }
    }
}

/// The scrolling column of the comments panel. Rows draw their focus platter `Theme.Spacing.row`
/// outside their text, so the column is that much wider than the panel's text margins.
struct CommentScroller<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                content
            }
            .padding(.leading, CommentsLayout.leading - Theme.Spacing.row)
            .padding(.trailing, CommentsLayout.trailing - Theme.Spacing.row)
            .padding(.bottom, Theme.Spacing.row)
        }
    }
}

/// The comment field and the comments of `CommentsModel` as rows of a lazy stack: one focusable
/// row per comment, then "Show more comments" while there are more. The next page also loads by
/// itself when the last rows come on screen.
struct CommentsList: View {
    @ObservedObject var comments: CommentsModel
    private let focus: FocusState<CommentFocus?>.Binding?
    @State private var draft = ""

    /// Rows only, for hosts without the panel's thread view: comments don't open their replies.
    init(comments: CommentsModel) {
        _comments = ObservedObject(wrappedValue: comments)
        focus = nil
    }

    init(comments: CommentsModel, focus: FocusState<CommentFocus?>.Binding) {
        _comments = ObservedObject(wrappedValue: comments)
        self.focus = focus
    }

    var body: some View {
        if comments.canPost {
            composer
        }
        if let error = comments.error {
            CommentFailure(message: error.userMessage, focus: focus, focusValue: .retry) {
                comments.reload()
            }
        } else if comments.isLoaded {
            if comments.items.isEmpty {
                CommentNoteRow(text: "No comments yet.", systemImage: "text.bubble")
                    .commentFocus(focus, .empty)
            }
            ForEach(comments.items) { comment in
                CommentRow(comment: comment, action: openAction(for: comment))
                    .commentFocus(focus, .comment(comment.id))
                    .onAppear {
                        if comment.id == loadTrigger { comments.loadMore(automatic: true) }
                    }
            }
            if comments.hasMore {
                CommentsMoreButton(title: "Show more comments", state: comments.more, focus: focus, focusValue: .moreComments) {
                    comments.showMore()
                }
                .onAppear { comments.loadMore(automatic: true) }
            }
        } else {
            CommentLoadingRow(text: "Loading comments…")
                .onAppear { comments.load() }
        }
    }

    /// The third-last comment: when it comes on screen, the next page is asked for.
    private var loadTrigger: String? {
        let items = comments.items
        return items.count > 3 ? items[items.count - 3].id : items.last?.id
    }

    private func openAction(for comment: Comment) -> (() -> Void)? {
        guard focus != nil, comments.canOpen(comment) else { return nil }
        return { comments.open(comment) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.textLines * 2) {
            HStack(spacing: 16) {
                TextField("Add a comment…", text: $draft)
                    .onSubmit { send() }
                    .commentFocus(focus, .draft)
                Button("Post") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .commentFocus(focus, .post)
            }
            if let status = comments.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let failed = comments.failedPost {
                Button {
                    comments.post(failed)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .commentFocus(focus, .retryPost)
            }
        }
        .padding(.horizontal, Theme.Spacing.row)
        .padding(.bottom, Theme.Spacing.row)
    }

    private func send() {
        let text = draft
        draft = ""
        comments.post(text)
    }
}

/// One comment: avatar, author, age, creator/pinned/heart markers, text, likes and replies. The
/// whole row is one focusable button; `action` opens the comment with its replies.
struct CommentRow: View {
    let comment: Comment
    var isReply = false
    /// Replaces the comment's text (the thread view shows it piece by piece).
    var text: String?
    var action: (() -> Void)?

    /// Comments longer than this are cut to `cutLines` in the list and read in full in the thread
    /// view: the remote scrolls from focused row to focused row, so the middle of a row taller than
    /// the screen could never be read.
    static let longTextLength = 600
    static let cutLines = 10

    static func isLong(_ comment: Comment) -> Bool {
        // UTF-8 length is stored with the string: no walk over the text.
        comment.text.utf8.count > longTextLength
    }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.row) {
                RemoteImage(url: comment.authorAvatar.flatMap(URL.init(string:)))
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: Theme.Spacing.textLines * 2) {
                    if comment.isPinned {
                        Label("Pinned", systemImage: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    byline
                    if !shownText.isEmpty {
                        Text(shownText)
                            .font(.body)
                            .lineLimit(isCut ? Self.cutLines : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stats
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(CommentRowButtonStyle())
    }

    private var avatarSize: CGFloat { isReply ? CommentsLayout.replyAvatar : CommentsLayout.avatar }
    private var shownText: String { text ?? comment.text }
    private var isCut: Bool { text == nil && !isReply && Self.isLong(comment) }
    private var repliesLabel: String? { isReply ? nil : comment.repliesLabel }

    private var byline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(comment.author)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if comment.isCreator {
                Badge(text: "Creator", color: .gray)
            }
            if let published = comment.publishedText {
                Text(published)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var stats: some View {
        if comment.likeCountText != nil || comment.isHearted || repliesLabel != nil || isCut {
            HStack(spacing: 28) {
                if let likes = comment.likeCountText {
                    Label(likes, systemImage: "hand.thumbsup")
                }
                if comment.isHearted {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Hearted by the creator")
                }
                if let repliesLabel {
                    Label(repliesLabel, systemImage: "bubble.left.and.bubble.right")
                }
                if isCut {
                    Text("Read more")
                }
                if action != nil {
                    Image(systemName: "chevron.forward")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Focus look of comment rows: a rounded, continuous platter lights up behind the focused row, like
/// the rows of tvOS' own lists. The row doesn't grow or tilt: a lifted block of text would reach
/// past the panel's edges and blur while it scales.
struct CommentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CommentRowButtonBody(configuration: configuration)
    }
}

private struct CommentRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(Theme.Spacing.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.white.opacity(fillOpacity))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var fillOpacity: Double {
        if configuration.isPressed { return 0.28 }
        return isFocused ? 0.18 : 0
    }
}

/// A piece of a long comment after its first (thread view), lined up with the comment's text and
/// focusable on its own so the remote can scroll through it.
struct CommentTextRow: View {
    let text: String

    var body: some View {
        Button {} label: {
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(CommentRowButtonStyle())
        .padding(.leading, CommentsLayout.avatar + Theme.Spacing.row)
    }
}

/// A focusable line in place of rows ("No comments yet."), so focus has somewhere to land.
struct CommentNoteRow: View {
    let text: String
    let systemImage: String

    var body: some View {
        Button {} label: {
            Label(text, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(CommentRowButtonStyle())
    }
}

struct CommentLoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.row)
    }
}

/// A first page that failed: the plain message and Retry.
struct CommentFailure: View {
    let message: String
    let focus: FocusState<CommentFocus?>.Binding?
    let focusValue: CommentFocus
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .commentFocus(focus, focusValue)
        }
        .padding(Theme.Spacing.row)
    }
}

/// "Show more comments" / "Show more replies": one button whose label follows the state, so
/// focus stays on it while the page loads, and on a failure (message and Retry) — never a dead end.
struct CommentsMoreButton: View {
    let title: String
    let state: CommentsMoreState
    let focus: FocusState<CommentFocus?>.Binding?
    let focusValue: CommentFocus
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.textLines * 2) {
            if let error = state.error {
                Text(error.kind == .expired ? "This list is out of date. Retry loads it again." : error.userMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if state != .loading { action() }
            } label: {
                switch state {
                case .loading:
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Loading…")
                    }
                case .failed:
                    Label("Retry", systemImage: "arrow.clockwise")
                case .idle:
                    Text(title)
                }
            }
            .commentFocus(focus, focusValue)
        }
        .padding(Theme.Spacing.row)
    }
}
