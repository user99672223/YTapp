import SwiftUI
import Core

/// The comments side panel, shared by the watch page and Shorts: "Comments" with the count and
/// Done, then the list, or one comment with its replies. The host places it at the trailing edge
/// (width, material background, focus section, transition), picks the margins that go with that
/// placement, and keeps the video playing underneath; Back/Menu on the list is handled by the
/// host, which closes the panel. In a thread, Menu goes back to the list. Closing the panel also
/// closes the thread, so the next opening starts on the list.
struct CommentsPanel: View {
    @ObservedObject var comments: CommentsModel
    let margins: CommentsMargins
    let close: () -> Void
    @FocusState private var focus: CommentFocus?
    /// Focus goes to the first comment (or Retry, or the "no comments" line) as soon as the list
    /// has one, once per opening or reload. Until then it rests on Done, never in the comment field.
    @State private var placesInitialFocus = true

    /// Focus moves wait this long (60 ms), so the target is laid out and enabled when it's asked for.
    static let focusDelay: UInt64 = 60_000_000

    /// `margins`: `CommentsLayout.floating` on a sheet inside the safe area, like the watch page's
    /// panels; `CommentsLayout.screenEdge` (the default) when the host lets the panel's material
    /// reach the screen's edges, as Shorts does. The default is the one that keeps the content out
    /// of the TV's overscan band wherever the panel is placed.
    init(comments: CommentsModel, margins: CommentsMargins = CommentsLayout.screenEdge, close: @escaping () -> Void) {
        _comments = ObservedObject(wrappedValue: comments)
        self.margins = margins
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
            header
                .padding(.leading, margins.leading)
                .padding(.trailing, margins.trailing)
                .padding(.top, margins.top)
            ZStack(alignment: .topLeading) {
                // The list stays while a thread is open (hidden and disabled), so Back finds it
                // scrolled where it was, with the comment to focus on screen.
                CommentScroller(margins: margins) {
                    CommentsList(comments: comments, focus: $focus)
                }
                .opacity(isThreadOpen ? 0 : 1)
                .disabled(isThreadOpen)
                .accessibilityHidden(isThreadOpen)
                if let thread = comments.thread {
                    CommentThreadView(thread: thread, comments: comments, margins: margins, focus: $focus)
                        .id(thread.comment.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.bottom, margins.outsideBottom)
        }
        .animation(.easeInOut(duration: 0.25), value: comments.thread?.comment.id)
        .defaultFocus($focus, initialTarget ?? .done)
        .onExitCommand(perform: backToList)
        .onAppear {
            comments.load()
            placesInitialFocus = true
            placeInitialFocus()
        }
        .onDisappear {
            // Done or Back inside a thread: the next opening (the same video's comments are kept)
            // starts on the list, where the first comment takes focus.
            comments.closeThread()
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
