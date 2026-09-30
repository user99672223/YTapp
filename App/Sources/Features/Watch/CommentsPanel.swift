import SwiftUI
import Core

/// The comments side panel, shared by the watch page and Shorts: "Comments" with the count and
/// Done, then the list, or one comment with its replies. The host places it at the trailing edge
/// (width, material background, focus section, transition) and keeps the video playing
/// underneath; Back/Menu on the list is handled by the host, which closes the panel. In a thread,
/// Menu goes back to the list.
struct CommentsPanel: View {
    @ObservedObject var comments: CommentsModel
    let close: () -> Void
    @FocusState private var focus: CommentFocus?
    /// Focus goes to the first comment (or Retry, or the "no comments" line) as soon as the list
    /// has one, once per opening or reload. Until then it rests on Done, never in the comment field.
    @State private var placesInitialFocus = true

    /// Focus moves wait this long (60 ms), so the target is laid out and enabled when it's asked for.
    static let focusDelay: UInt64 = 60_000_000

    init(comments: CommentsModel, close: @escaping () -> Void) {
        _comments = ObservedObject(wrappedValue: comments)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
            header
                .padding(.leading, CommentsLayout.leading)
                .padding(.trailing, CommentsLayout.trailing)
                .padding(.top, CommentsLayout.top)
            ZStack(alignment: .topLeading) {
                // The list stays while a thread is open (hidden and disabled), so Back finds it
                // scrolled where it was, with the comment to focus on screen.
                CommentScroller {
                    CommentsList(comments: comments, focus: $focus)
                }
                .opacity(isThreadOpen ? 0 : 1)
                .disabled(isThreadOpen)
                .accessibilityHidden(isThreadOpen)
                if let thread = comments.thread {
                    CommentThreadView(thread: thread, comments: comments, focus: $focus)
                        .id(thread.comment.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.bottom, CommentsLayout.bottom)
        }
        .animation(.easeInOut(duration: 0.25), value: comments.thread?.comment.id)
        .defaultFocus($focus, initialTarget ?? .done)
        .onExitCommand(perform: backToList)
        .onAppear {
            comments.load()
            placesInitialFocus = true
            placeInitialFocus()
        }
        .onChange(of: initialTarget) { _, target in
            // The list started over (reload, another video): place focus again when it's back.
            if target == nil {
                placesInitialFocus = true
            } else {
                placeInitialFocus()
            }
        }
        .onChange(of: comments.thread?.comment.id) { old, new in
            if new != nil {
                move(to: .text(0))
            } else if let old {
                move(to: .comment(old))
            }
        }
        .onChange(of: comments.items.count) { old, new in
            // "Show more comments" pressed: go on reading at the first new comment, not below them.
            guard new > old, focus == .moreComments else { return }
            move(to: .comment(comments.items[old].id))
        }
    }

    private var isThreadOpen: Bool { comments.thread != nil }

    private var header: some View {
        HStack(spacing: 20) {
            if isThreadOpen {
                Button {
                    comments.closeThread()
                } label: {
                    Label("Comments", systemImage: "chevron.backward")
                }
                .focused($focus, equals: .back)
            } else {
                Text("Comments")
                    .font(.title3.bold())
                if let count = comments.countText {
                    Text(count)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("Done", action: close)
                .focused($focus, equals: .done)
        }
    }

    /// Menu in a thread goes back to the list; on the list it's left to the host (nil).
    private var backToList: (() -> Void)? {
        guard isThreadOpen else { return nil }
        return { comments.closeThread() }
    }

    private var initialTarget: CommentFocus? {
        if let first = comments.items.first { return .comment(first.id) }
        if comments.error != nil { return .retry }
        if comments.isLoaded { return .empty }
        return nil
    }

    private func placeInitialFocus() {
        guard placesInitialFocus, !isThreadOpen, let target = initialTarget else { return }
        placesInitialFocus = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.focusDelay)
            // Unless the user went somewhere meanwhile (a comment, Post, …).
            switch focus {
            case nil, .some(.done), .some(.draft):
                focus = target
            default:
                break
            }
        }
    }

    private func move(to target: CommentFocus) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.focusDelay)
            focus = target
        }
    }
}
