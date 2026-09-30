import SwiftUI
import Core

/// The comments side panel, shared by the watch page and Shorts: "Comments" with the count and
/// Done, then the list, or one comment with its replies. The host places it at the trailing edge
/// (width, material background, focus section, transition), picks the margins that go with that
/// placement, and keeps the video playing underneath. Back/Menu is handled here, one step per
/// press: in a thread it goes back to the list, on the list it closes the panel (`close`, like
/// Done). Closing the panel also closes the thread, so the next opening starts on the list.
///
/// Focus: each opening, and each time the list starts over, puts it on the first comment (or on
/// Retry, or on the "no comments" line) as soon as the list has one; until then it rests on Done.
/// A thread opens on its comment; Back from it lands on the comment it came from, in the list
/// still scrolled where it was. Focus coming into the panel from outside (Shorts' action column),
/// or found again after the host dropped it, lands on the row that had it last. Once placed,
/// focus is left alone: nothing moves it while the viewer reads.
struct CommentsPanel: View {
    @ObservedObject var comments: CommentsModel
    let margins: CommentsMargins
    let close: () -> Void
    @FocusState private var focus: CommentFocus?
    /// The first row of the list still has to take focus: from each opening, and from each time
    /// the list starts over, until the list has a first row to put it on.
    @State private var needsInitialFocus = true
    /// The row of the list that last had focus (see `entryTarget`).
    @State private var listFocus: CommentFocus?
    /// The row of the open thread that last had focus.
    @State private var threadFocus: CommentFocus?
    /// Focus has been in the panel since it appeared. When it isn't any more, the viewer took it
    /// elsewhere (Shorts' action column, or the video to page on), and a list that starts over
    /// (the next Short's comments) doesn't pull it back.
    @State private var hasHadFocus = false
    /// The running `place(_:while:)`.
    @State private var placement: Task<Void, Never>?
    @State private var isOnScreen = false

    /// Focus moves wait this long (60 ms), so the target is laid out and enabled when it's asked for.
    static let focusDelay: UInt64 = 60_000_000
    /// `place(_:while:)` looks at focus this many times, `focusDelay` apart: about 0.6 s, longer
    /// than the panel's and the thread's slide-in and slide-out.
    private static let placementChecks = 10

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
        // Whenever the focus engine picks a row here by itself (the button that opened the panel
        // went away, the focused row of a thread slid off, the viewer moves in from outside), it
        // takes `entryTarget`, not the row nearest to where focus was.
        .focusSection()
        .defaultFocus($focus, entryTarget, priority: .userInitiated)
        .onExitCommand(perform: goBack)
        .onAppear {
            isOnScreen = true
            comments.load()
            needsInitialFocus = true
            listFocus = nil
            hasHadFocus = false
            placeInitialFocus()
        }
        .onDisappear {
            isOnScreen = false
            placement?.cancel()
            // Done or Back inside a thread: the next opening (the same video's comments are kept)
            // starts on the list, where the first comment takes focus.
            comments.closeThread()
        }
        .onChange(of: focus) { _, new in remember(new) }
        .onChange(of: initialTarget) { _, target in
            if target == nil {
                // The list started over (reload, another video): place focus again when it's back.
                placement?.cancel()
                needsInitialFocus = true
                listFocus = nil
            } else {
                placeInitialFocus()
            }
        }
        .onChange(of: comments.thread?.comment.id) { old, new in
            threadFocus = nil
            if let new {
                place(.text(0)) { comments.thread?.comment.id == new }
            } else if let old, comments.showsRow(.comment(old)) {
                // Back on the comment whose replies were open, in the list still scrolled there.
                let target = CommentFocus.comment(old)
                listFocus = target
                place(target) { !isThreadOpen && comments.showsRow(target) }
            }
        }
        .onChange(of: comments.items.count) { old, new in
            // "Show more comments" pressed: go on reading at the first new comment, not below them.
            guard new > old, focus == .moreComments else { return }
            let target = CommentFocus.comment(comments.items[old].id)
            place(target) { !isThreadOpen && comments.showsRow(target) }
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

    /// Back/Menu, one step per press: from a thread to the list, from the list out of the panel
    /// (like Done). It's decided when the button is pressed, not when the panel was last drawn:
    /// a handler that switched between "close the thread" and nil (left to the host) could still
    /// be the thread's one after the thread had closed, and swallow the press that should have
    /// closed the panel.
    private func goBack() {
        if isThreadOpen {
            comments.closeThread()
        } else {
            close()
        }
    }

    /// The first row of the list: the first comment, else Retry, else the "no comments" line; nil
    /// while the first page loads.
    private var initialTarget: CommentFocus? {
        if let first = comments.items.first { return .comment(first.id) }
        if comments.error != nil { return .retry }
        if comments.isLoaded { return .empty }
        return nil
    }

    /// Where focus lands when the focus engine picks it in the panel by itself: the row of the
    /// thread, or of the list, that had it last, while that row is still shown; else the
    /// thread's comment, or the list's first row; else Done, while the list loads.
    private var entryTarget: CommentFocus {
        if let thread = comments.thread {
            if let threadFocus, thread.showsRow(threadFocus) { return threadFocus }
            return .text(0)
        }
        if let listFocus, comments.showsRow(listFocus) { return listFocus }
        return initialTarget ?? .done
    }

    /// Keeps `listFocus` and `threadFocus` up to date. A row of the side that's going away (the
    /// list's comment while its thread opens, the thread's rows while it closes) doesn't count.
    private func remember(_ new: CommentFocus?) {
        guard let new else { return }
        hasHadFocus = true
        if isThreadOpen {
            if new.isThreadRow { threadFocus = new }
        } else if new.isListRow {
            listFocus = new
        }
    }

    /// Focus to the list's first row, once it has one. From outside the panel (focus still on the
    /// button that opened it) only until focus has been in the panel: see `hasHadFocus`.
    private func placeInitialFocus() {
        guard needsInitialFocus, !isThreadOpen, let target = initialTarget else { return }
        needsInitialFocus = false
        place(target) { !isThreadOpen && initialTarget == target && (focus != nil || !hasHadFocus) }
    }

    /// Puts focus on `target` and keeps it there while the focus engine settles. A single move
    /// can lose: the row may not take focus yet (still being laid out, or sliding in), and the
    /// engine may land afterwards on the row nearest to where focus was (the button that opened
    /// the panel, a thread sliding away). So it looks every `focusDelay`, for about 0.6 s, and
    /// puts focus (back) on the target until the target has kept it over two looks. It stops
    /// early when `isWanted` no longer holds, or when the viewer is on Post or on the post's
    /// Retry, which they only reach on purpose.
    private func place(_ target: CommentFocus, while isWanted: @escaping @MainActor () -> Bool) {
        placement?.cancel()
        placement = Task { @MainActor in
            var kept = 0
            for _ in 0..<Self.placementChecks {
                try? await Task.sleep(nanoseconds: Self.focusDelay)
                guard !Task.isCancelled, isOnScreen, isWanted() else { return }
                if focus == target {
                    kept += 1
                    if kept == 2 { return }
                } else if focus == .post || focus == .retryPost {
                    return
                } else {
                    kept = 0
                    focus = target
                }
            }
        }
    }
}
