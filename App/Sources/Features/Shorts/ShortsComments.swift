import SwiftUI
import Core

/// The comments of a Short, in place of its info column (same place, same width), as in
/// YouTube's own TV app: "Comments 52" over a list of rounded cards, the focused card white with
/// dark text. The list keeps the focused card near the middle and loads the next page by itself
/// near its end. Selecting a card with replies (or one too long for a card) shows "Replies"
/// instead: the comment's whole text in a small box that scrolls, then the replies.
///
/// Built on `CommentsModel` / `CommentThreadModel` (shared with the watch page). The list stays
/// in place, hidden, while replies are open, so going back finds it where it was.
struct ShortsCommentsColumn: View {
    @ObservedObject var comments: CommentsModel
    /// The Short's own comment count ("1.2K"), when YouTube sent one.
    let countText: String?
    let focus: FocusState<ShortsFocus?>.Binding
    let moveFocus: (ShortsFocus) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShortsCommentList(comments: comments, countText: countText, focus: focus, moveFocus: moveFocus)
                .opacity(comments.thread == nil ? 1 : 0)
                .disabled(comments.thread != nil)
            if let thread = comments.thread {
                ShortsReplyList(thread: thread, comments: comments, focus: focus)
                    .id(thread.comment.id)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: comments.thread?.comment.id)
        .frame(width: ShortsLayout.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .focusSection()
    }

    /// Where focus goes in the comments: the first comment, or the line in place of the list
    /// (loading, none, or the failure's Retry).
    static func firstFocus(in comments: CommentsModel) -> ShortsFocus {
        if comments.error != nil { return .commentsRetry }
        if comments.isLoaded, let first = comments.items.first { return .comment(first.id) }
        return .commentsNote
    }
}

private struct ShortsCommentList: View {
    @ObservedObject var comments: CommentsModel
    let countText: String?
    let focus: FocusState<ShortsFocus?>.Binding
    let moveFocus: (ShortsFocus) -> Void
    /// Comments shown whole in place: longer than a card's three lines, with no replies to open.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: ShortsLayout.headerToList) {
            ShortsColumnHeader(title: "Comments", detail: countText ?? ShortsInfoColumn.count(from: comments.countText))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ShortsLayout.cardSpacing) {
                        content
                    }
                    .padding(.bottom, ShortsLayout.listBottom)
                }
                .onChange(of: focus.wrappedValue) { _, newFocus in
                    if case .comment(let id) = newFocus { centre(id, in: proxy) }
                }
            }
        }
        .padding(.top, ShortsLayout.commentsTop)
        // The line focus waited on (loading) makes way for the comments: focus goes to the first.
        .onChange(of: comments.isLoaded) { _, _ in settleFocus() }
        .onChange(of: comments.error) { _, _ in settleFocus() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = comments.error {
            ShortsNoteCard(text: error.userMessage, systemImage: "exclamationmark.triangle.fill", actionTitle: "Retry") {
                comments.reload()
            }
            .focused(focus, equals: .commentsRetry)
        } else if comments.isLoaded {
            if comments.items.isEmpty {
                ShortsNoteCard(text: "No comments yet.", systemImage: "text.bubble")
                    .focused(focus, equals: .commentsNote)
            }
            ForEach(comments.items) { comment in
                Button {
                    select(comment)
                } label: {
                    ShortsCommentCard(comment: comment, isExpanded: expanded.contains(comment.id))
                }
                .buttonStyle(ShortsCardStyle())
                .focused(focus, equals: .comment(comment.id))
                .id(comment.id)
                .onAppear {
                    if comment.id == loadTrigger { comments.loadMore(automatic: true) }
                }
            }
            if comments.hasMore {
                ShortsMoreCard(title: "Show more comments", state: comments.more) { comments.showMore() }
                    .focused(focus, equals: .moreComments)
                    .onAppear { comments.loadMore(automatic: true) }
            }
        } else {
            // Focusable, so focus has a place in the column while the first page loads.
            ShortsNoteCard(text: "Loading comments…", isLoading: true)
                .focused(focus, equals: .commentsNote)
                .onAppear { comments.load() }
        }
    }

    /// The third-last comment: when it comes on screen, the next page is asked for.
    private var loadTrigger: String? {
        let items = comments.items
        return items.count > 3 ? items[items.count - 3].id : items.last?.id
    }

    private func select(_ comment: Comment) {
        if comments.canOpen(comment) {
            comments.open(comment)
            moveFocus(.threadText(0))
        } else if expanded.contains(comment.id) {
            expanded.remove(comment.id)
        } else {
            expanded.insert(comment.id)
        }
    }

    private func settleFocus() {
        switch focus.wrappedValue {
        case nil, .commentsNote?, .commentsRetry?:
            moveFocus(ShortsCommentsColumn.firstFocus(in: comments))
        default:
            break
        }
    }
}

/// One comment's replies: the comment's whole text in a box that scrolls, then the replies.
private struct ShortsReplyList: View {
    @ObservedObject var thread: CommentThreadModel
    let comments: CommentsModel
    let focus: FocusState<ShortsFocus?>.Binding
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: ShortsLayout.headerToList) {
            ShortsColumnHeader(title: "Replies")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ShortsLayout.cardSpacing) {
                        ShortsThreadParent(comment: thread.comment, chunks: thread.comment.textChunks(maxLength: 110), focus: focus)
                            .id(Self.parentId)
                        replies
                    }
                    .padding(.bottom, ShortsLayout.listBottom)
                }
                .onChange(of: focus.wrappedValue) { _, newFocus in
                    switch newFocus {
                    case .reply(let id)?:
                        centre(id, in: proxy)
                    case .threadText?:
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(Self.parentId, anchor: .top) }
                    default:
                        break
                    }
                }
            }
        }
        .padding(.top, ShortsLayout.commentsTop)
    }

    private static let parentId = "parent"

    @ViewBuilder
    private var replies: some View {
        if let error = thread.error {
            ShortsNoteCard(text: error.userMessage, systemImage: "exclamationmark.triangle.fill", actionTitle: "Retry") {
                comments.retryReplies(of: thread)
            }
            .focused(focus, equals: .repliesRetry)
        } else if thread.isLoaded {
            ForEach(thread.replies.items) { reply in
                Button {
                    if expanded.contains(reply.id) { expanded.remove(reply.id) } else { expanded.insert(reply.id) }
                } label: {
                    ShortsCommentCard(comment: reply, showsReplies: false, isExpanded: expanded.contains(reply.id))
                }
                .buttonStyle(ShortsCardStyle())
                .focused(focus, equals: .reply(reply.id))
                .id(reply.id)
                .onAppear {
                    if reply.id == loadTrigger { thread.loadMore(automatic: true) }
                }
            }
            if thread.hasMore {
                ShortsMoreCard(title: "Show more replies", state: thread.more) { thread.showMore() }
                    .focused(focus, equals: .moreReplies)
                    .onAppear { thread.loadMore(automatic: true) }
            }
        } else if thread.comment.hasReplies {
            // Not focusable: focus stays on the comment's text above meanwhile.
            ProgressLabel("Loading replies…")
                .padding(ShortsLayout.cardPadding)
        }
    }

    private var loadTrigger: String? {
        let items = thread.replies.items
        return items.count > 3 ? items[items.count - 3].id : items.last?.id
    }
}

/// Scrolls `id` to the middle of the list, so the cards around the focused one show too.
private func centre(_ id: String, in proxy: ScrollViewProxy) {
    withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(id, anchor: .center)
    }
}

/// "Comments 52" / "Replies" at the top of the column.
private struct ShortsColumnHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.title3.bold())
            if let detail, !detail.isEmpty {
                Text(detail).font(.title3)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
    }
}

/// A comment card: avatar, @handle · age, the text (three lines unless `isExpanded`), likes and
/// replies.
struct ShortsCommentCard: View {
    let comment: Comment
    var showsReplies = true
    var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ShortsCommentByline(comment: comment)
            if !comment.text.isEmpty {
                Text(comment.text)
                    .font(.body)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 32) {
            HStack(spacing: 8) {
                Image(systemName: "hand.thumbsup")
                if let likes = comment.likeCountText, !likes.isEmpty {
                    Text(likes)
                }
            }
            if comment.isHearted {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Hearted by the creator")
            }
            if showsReplies, comment.hasReplies {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                    if let count = comment.replyCountText, !count.isEmpty, count != "0" {
                        Text(count)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(comment.repliesLabel ?? "Replies")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Avatar, "@handle • 4 days ago", and the pinned / creator markers.
private struct ShortsCommentByline: View {
    let comment: Comment

    var body: some View {
        HStack(spacing: 22) {
            RemoteImage(url: comment.authorAvatar.flatMap(URL.init(string:)))
                .frame(width: ShortsLayout.avatarSize, height: ShortsLayout.avatarSize)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                if comment.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(comment.author)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if comment.isCreator {
                        Image(systemName: "checkmark.seal.fill")
                            .accessibilityLabel("Creator")
                    }
                    if let published = comment.publishedText, !published.isEmpty {
                        Text("• \(published)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// The comment whose replies are open: its byline, then its whole text. Text longer than the box
/// scrolls inside it: each piece of the text (`Comment.textChunks`, at most about three lines) is
/// focusable, so Up/Down read through it, and a bar beside it shows where.
private struct ShortsThreadParent: View {
    let comment: Comment
    let chunks: [String]
    let focus: FocusState<ShortsFocus?>.Binding
    /// The text's height laid out as the pieces are, measured once it's on screen.
    @State private var textHeight: CGFloat = 0

    private static let boxHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ShortsCommentByline(comment: comment)
            Group {
                if textHeight > Self.boxHeight {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView {
                            pieces
                        }
                        .frame(height: Self.boxHeight)
                        indicator
                    }
                } else {
                    pieces
                }
            }
            .background(alignment: .topLeading) {
                // Measures the text without taking part in focus.
                Text(pieceTexts.joined(separator: "\n"))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background {
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { textHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, height in textHeight = height }
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .padding(ShortsLayout.cardPadding)
        .foregroundStyle(Color.white.opacity(0.85))
    }

    /// At least one piece, so a comment without text still takes focus.
    private var pieceTexts: [String] { chunks.isEmpty ? [comment.text] : chunks }

    private var pieces: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pieceTexts.enumerated()), id: \.offset) { index, text in
                Button {} label: {
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ShortsTextPieceStyle())
                .focused(focus, equals: .threadText(index))
            }
        }
    }

    private var focusedPiece: Int? {
        if case .threadText(let index)? = focus.wrappedValue { return index }
        return nil
    }

    /// A scroll bar: white while the text has focus, its thumb at the focused piece.
    private var indicator: some View {
        let track = Self.boxHeight - 20
        let thumb: CGFloat = 48
        let count = pieceTexts.count
        let fraction = count > 1 ? CGFloat(focusedPiece ?? 0) / CGFloat(count - 1) : 0
        return Capsule()
            .fill(Color.white.opacity(0.15))
            .frame(width: 8, height: track)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(focusedPiece == nil ? 0.45 : 1))
                    .frame(width: 8, height: thumb)
                    .offset(y: fraction * (track - thumb))
                    .animation(.easeInOut(duration: 0.2), value: fraction)
            }
            .padding(.top, 10)
            .accessibilityHidden(true)
    }
}

/// A piece of the open comment's text: brighter, on a faint platter, while focused; the box's
/// bar shows where it is in a long text.
private struct ShortsTextPieceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShortsTextPieceBody(configuration: configuration)
    }
}

private struct ShortsTextPieceBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.75))
            .background {
                RoundedRectangle(cornerRadius: ShortsLayout.cardRadius / 2, style: .continuous)
                    .fill(Color.white.opacity(isFocused ? 0.12 : 0))
                    .padding(.horizontal, -10)
                    .padding(.vertical, -4)
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Comment cards: a dark translucent rounded card, white with dark text while focused. No lift,
/// so a focused card never reaches past the column or over its neighbours.
struct ShortsCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShortsCardBody(configuration: configuration)
    }
}

private struct ShortsCardBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(ShortsLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isFocused ? Color.black : Color.white.opacity(0.85))
            .background {
                RoundedRectangle(cornerRadius: ShortsLayout.cardRadius, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: ShortsLayout.cardRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// A card with a line of text in place of comments: loading, none, a failure with Retry.
private struct ShortsNoteCard: View {
    let text: String
    var systemImage: String?
    var isLoading = false
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    if isLoading {
                        ShortsSpinner()
                    } else if let systemImage {
                        Image(systemName: systemImage)
                    }
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle {
                    Label(actionTitle, systemImage: "arrow.clockwise")
                        .fontWeight(.semibold)
                }
            }
            .font(.callout)
        }
        .buttonStyle(ShortsCardStyle())
    }
}

/// "Show more comments" / "Show more replies": one card whose content follows the page's state,
/// so focus stays on it while the page loads and when it fails (message and Retry).
private struct ShortsMoreCard: View {
    let title: String
    let state: CommentsMoreState
    let action: () -> Void

    var body: some View {
        Button {
            if state != .loading { action() }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                switch state {
                case .loading:
                    HStack(spacing: 18) {
                        ShortsSpinner()
                        Text("Loading…")
                    }
                case .failed(let error):
                    Text(error.kind == .expired ? "This list is out of date. Retry loads it again." : error.userMessage)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Retry", systemImage: "arrow.clockwise")
                        .fontWeight(.semibold)
                case .idle:
                    Label(title, systemImage: "chevron.down")
                }
            }
            .font(.callout)
        }
        .buttonStyle(ShortsCardStyle())
    }
}

/// A spinner that stays visible on a focused (white) card.
private struct ShortsSpinner: View {
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ProgressView()
            .tint(isFocused ? Color.black : Color.white)
    }
}
