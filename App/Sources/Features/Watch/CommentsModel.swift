import Foundation
import SwiftUI
import Core

/// Where the next page of a comment list (comments, or one comment's replies) stands.
enum CommentsMoreState: Equatable {
    case idle
    case loading
    case failed(BridgeError)

    var error: BridgeError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

/// Comments for one video (watch page and Shorts): the first page, the next pages, the comment
/// whose replies are open, posting.
@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var list = CommentList()
    /// The number of comments ("1,234").
    @Published private(set) var countText: String?
    /// The first page arrived (it may have no comments).
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    /// The first page failed.
    @Published private(set) var error: BridgeError?
    @Published private(set) var more: CommentsMoreState = .idle
    /// The comment the panel shows with its replies instead of the list.
    @Published private(set) var thread: CommentThreadModel?
    @Published private(set) var status: String?
    /// The last comment couldn't be posted: its text, for Retry.
    @Published private(set) var failedPost: String?
    private(set) var videoId: String?
    private let model: AppModel
    /// The bridge's handle on this comment section, for replies.
    private var key: String?
    /// Bumped whenever the list starts over; a request of an older one changes nothing.
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    /// A page failed or brought nothing new: rows coming on screen no longer load the next one,
    /// only "Show more comments" / Retry does. Keeps a failing continuation from being requested
    /// over and over.
    private var automaticPaused = false
    /// Threads opened in this list, so going back into one shows the replies already loaded.
    private var threads: [String: CommentThreadModel] = [:]

    init(model: AppModel) {
        self.model = model
    }

    var canPost: Bool { model.isSignedIn }
    var items: [Comment] { list.items }
    var hasMore: Bool { list.continuation != nil }

    func reset(videoId: String?) {
        cancelLoading()
        self.videoId = videoId
        clear()
        status = nil
        failedPost = nil
    }

    private func clear() {
        list = CommentList()
        countText = nil
        isLoaded = false
        error = nil
        more = .idle
        key = nil
        automaticPaused = false
        thread = nil
        threads = [:]
    }

    /// Drops the running requests, so the next video's (or a reload's) first page isn't blocked
    /// by `isLoading` of a request whose result would be thrown away.
    private func cancelLoading() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        moreTask?.cancel()
        moreTask = nil
        isLoading = false
        for thread in threads.values { thread.cancel() }
    }

    func load() {
        guard let id = videoId, !isLoaded, !isLoading else { return }
        isLoading = true
        error = nil
        let current = generation
        loadTask = Task {
            defer { if generation == current { isLoading = false } }
            do {
                let page = try await model.api { try await $0.comments(videoId: id) }
                guard generation == current else { return }
                list = CommentList(page.items, continuation: page.continuation)
                countText = page.countText
                key = page.key
                isLoaded = true
            } catch {
                guard generation == current else { return }
                self.error = BridgeError.wrap(error)
            }
        }
    }

    func reload() {
        cancelLoading()
        clear()
        load()
    }

    /// The next page. `automatic` loads (the last rows coming on screen) stop after a failure or
    /// a page with nothing new; "Show more comments" always asks.
    func loadMore(automatic: Bool = false) {
        guard isLoaded, let continuation = list.continuation, more != .loading else { return }
        if automatic, automaticPaused { return }
        more = .loading
        let current = generation
        moreTask = Task {
            do {
                let page = try await model.api { try await $0.moreComments(continuation) }
                guard generation == current else { return }
                let added = list.append(page.items, continuation: page.continuation)
                if let count = page.countText { countText = count }
                automaticPaused = added == 0
                more = .idle
            } catch {
                guard generation == current else { return }
                automaticPaused = true
                more = .failed(BridgeError.wrap(error))
            }
        }
    }

    /// "Show more comments" / its Retry. A section the bridge no longer knows (evicted, or the
    /// session was recreated) can't continue: it starts over.
    func showMore() {
        if more.error?.kind == .expired {
            reload()
        } else {
            loadMore()
        }
    }

    // MARK: - Replies

    /// Comments open in the thread view when they have replies or are too long for a row.
    func canOpen(_ comment: Comment) -> Bool {
        key != nil && (comment.hasReplies || CommentRow.isLong(comment))
    }

    func open(_ comment: Comment) {
        guard let key, canOpen(comment) else { return }
        let opened = threads[comment.id] ?? CommentThreadModel(comment: comment, sectionKey: key, model: model)
        threads[comment.id] = opened
        thread = opened
        opened.load()
    }

    func closeThread() {
        thread = nil
    }

    /// Retry of the replies' first batch. When the section itself expired, the comments start over.
    func retryReplies(of thread: CommentThreadModel) {
        if thread.error?.kind == .expired {
            reload()
        } else {
            thread.load()
        }
    }

    // MARK: - Posting

    func post(_ text: String) {
        guard let id = videoId else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        status = "Posting…"
        failedPost = nil
        let current = generation
        Task {
            do {
                try await model.api { try await $0.postComment(videoId: id, text: body) }
                guard generation == current else { return }
                status = "Comment posted"
                reload()
            } catch {
                guard generation == current else { return }
                status = "Couldn't post the comment: \(BridgeError.wrap(error).userMessage)"
                failedPost = body
            }
        }
    }
}

/// One comment with its replies, shown in the comments panel in place of the list.
@MainActor
final class CommentThreadModel: ObservableObject {
    let comment: Comment
    /// The comment's text in screen-sized pieces, each focusable on its own (worked out once).
    let chunks: [String]
    @Published private(set) var replies = CommentList()
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    /// The first batch failed.
    @Published private(set) var error: BridgeError?
    @Published private(set) var more: CommentsMoreState = .idle
    private let sectionKey: String
    private let model: AppModel
    private var generation = 0
    private var task: Task<Void, Never>?
    /// Like `CommentsModel.automaticPaused`, for "Show more replies".
    private var automaticPaused = false

    init(comment: Comment, sectionKey: String, model: AppModel) {
        self.comment = comment
        chunks = comment.textChunks()
        self.sectionKey = sectionKey
        self.model = model
    }

    var hasMore: Bool { replies.continuation != nil }

    func load() {
        guard comment.hasReplies, !isLoaded, !isLoading else { return }
        isLoading = true
        error = nil
        let current = generation
        let key = sectionKey
        let id = comment.id
        task = Task {
            defer { if generation == current { isLoading = false } }
            do {
                let page = try await model.api { try await $0.commentReplies(key: key, commentId: id) }
                guard generation == current else { return }
                replies = CommentList(page.items, continuation: page.continuation)
                isLoaded = true
            } catch {
                guard generation == current else { return }
                self.error = BridgeError.wrap(error)
            }
        }
    }

    func loadMore(automatic: Bool = false) {
        guard isLoaded, let continuation = replies.continuation, more != .loading else { return }
        if automatic, automaticPaused { return }
        more = .loading
        let current = generation
        task = Task {
            do {
                let page = try await model.api { try await $0.moreCommentReplies(continuation) }
                guard generation == current else { return }
                let added = replies.append(page.items, continuation: page.continuation)
                automaticPaused = added == 0
                more = .idle
            } catch {
                guard generation == current else { return }
                automaticPaused = true
                more = .failed(BridgeError.wrap(error))
            }
        }
    }

    /// "Show more replies" / its Retry. The bridge keeps a limited number of reply lists; when
    /// this one was dropped, the replies start over from the first batch.
    func showMore() {
        if more.error?.kind == .expired {
            reload()
        } else {
            loadMore()
        }
    }

    /// Starts the replies over from the first batch (an expired list, or Retry after a first
    /// batch that came back without replies).
    func reload() {
        cancel()
        replies = CommentList()
        isLoaded = false
        error = nil
        more = .idle
        automaticPaused = false
        load()
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
        if more == .loading { more = .idle }
    }
}
