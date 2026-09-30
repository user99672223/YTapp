import SwiftUI
import Core

/// A comment in full with its replies, shown in the comments panel in place of the list (Back
/// returns to the list, on the comment it came from).
///
/// Replies open here rather than expanding under their comment because of how the focus engine
/// moves: in the list every comment stays one row, so Down always reaches the next comment; a long
/// thread doesn't push the following comments pages away; "Show more replies" doesn't sit in the
/// middle of the list next to its own "Show more comments"; and collapsing never removes the
/// focused row from under the user. Long comments are read here too, piece by piece.
struct CommentThreadView: View {
    @ObservedObject var thread: CommentThreadModel
    /// For Retry when the whole section expired.
    let comments: CommentsModel
    let focus: FocusState<CommentFocus?>.Binding

    var body: some View {
        CommentScroller {
            CommentRow(comment: thread.comment, text: thread.chunks.first ?? "")
                .focused(focus, equals: .text(0))
            ForEach(Array(thread.chunks.enumerated().dropFirst()), id: \.offset) { index, chunk in
                CommentTextRow(text: chunk)
                    .focused(focus, equals: .text(index))
            }
            if thread.comment.hasReplies {
                Text(thread.comment.repliesLabel ?? "Replies")
                    .font(.headline)
                    .padding(.horizontal, Theme.Spacing.row)
                    .padding(.top, Theme.Spacing.row)
                replies
            }
        }
        .onChange(of: thread.replies.items.count) { old, new in
            // "Show more replies" pressed: go on reading at the first new reply, not below them.
            guard new > old, focus.wrappedValue == .moreReplies else { return }
            let first = thread.replies.items[old].id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: CommentsPanel.focusDelay)
                focus.wrappedValue = .reply(first)
            }
        }
    }

    @ViewBuilder
    private var replies: some View {
        if let error = thread.error {
            CommentFailure(message: error.userMessage, focus: focus, focusValue: .retry) {
                comments.retryReplies(of: thread)
            }
        } else if thread.isLoaded {
            ForEach(thread.replies.items) { reply in
                CommentRow(comment: reply, isReply: true)
                    .focused(focus, equals: .reply(reply.id))
                    .padding(.leading, CommentsLayout.replyIndent)
                    .onAppear {
                        if reply.id == loadTrigger { thread.loadMore(automatic: true) }
                    }
            }
            if thread.hasMore {
                CommentsMoreButton(title: "Show more replies", state: thread.more, focus: focus, focusValue: .moreReplies) {
                    thread.showMore()
                }
                .padding(.leading, CommentsLayout.replyIndent)
                .onAppear { thread.loadMore(automatic: true) }
            }
        } else {
            CommentLoadingRow(text: "Loading replies…")
                .padding(.leading, CommentsLayout.replyIndent)
        }
    }

    /// The third-last reply: when it comes on screen, the next batch is asked for.
    private var loadTrigger: String? {
        let items = thread.replies.items
        return items.count > 3 ? items[items.count - 3].id : items.last?.id
    }
}
