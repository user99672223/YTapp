import Foundation
import SwiftUI
import Core

/// Comments for one video (watch page and Shorts): first page, continuation, posting.
@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var page: CommentsPage?
    @Published private(set) var error: BridgeError?
    @Published private(set) var isLoading = false
    @Published private(set) var status: String?
    private(set) var videoId: String?
    private let model: AppModel
    /// Bumped whenever the list starts over; a request of an older one changes nothing.
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var canPost: Bool { model.isSignedIn }

    func reset(videoId: String?) {
        cancelLoading()
        self.videoId = videoId
        page = nil
        error = nil
        status = nil
    }

    /// Drops the running request, so the next video's (or a reload's) first page isn't blocked
    /// by `isLoading` of a request whose result would be thrown away.
    private func cancelLoading() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    func load() {
        guard let id = videoId, page == nil, !isLoading else { return }
        isLoading = true
        let current = generation
        loadTask = Task {
            defer { if generation == current { isLoading = false } }
            do {
                let result = try await model.api { try await $0.comments(videoId: id) }
                guard generation == current else { return }
                page = result
                error = nil
            } catch {
                guard generation == current else { return }
                self.error = BridgeError.wrap(error)
            }
        }
    }

    func reload() {
        cancelLoading()
        page = nil
        error = nil
        load()
    }

    func loadMore() {
        guard let key = page?.continuation, !isLoading else { return }
        isLoading = true
        let current = generation
        loadTask = Task {
            defer { if generation == current { isLoading = false } }
            do {
                let next = try await model.api { try await $0.moreComments(key) }
                guard generation == current else { return }
                page?.items.append(contentsOf: next.items)
                page?.continuation = next.continuation
            } catch {
                guard generation == current else { return }
                status = "Couldn't load more comments: \(BridgeError.wrap(error).userMessage)"
            }
        }
    }

    func post(_ text: String) {
        guard let id = videoId else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        status = "Posting…"
        Task {
            do {
                try await model.api { try await $0.postComment(videoId: id, text: body) }
                status = "Comment posted"
                reload()
            } catch {
                status = "Couldn't post the comment: \(BridgeError.wrap(error).userMessage)"
            }
        }
    }
}

/// Comment list with an input field; used in the watch panel and the Shorts panel.
struct CommentsList: View {
    @ObservedObject var comments: CommentsModel
    @State private var draft = ""

    var body: some View {
        if comments.canPost {
            HStack(spacing: 16) {
                TextField("Add a comment…", text: $draft)
                    .onSubmit { send() }
                Button("Post") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if let status = comments.status {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        if let error = comments.error {
            Text(error.userMessage).foregroundStyle(.secondary)
            Button("Retry") { comments.reload() }
        } else if let page = comments.page {
            if let count = page.countText { Text(count).font(.caption).foregroundStyle(.secondary) }
            if page.items.isEmpty { Text("No comments.").foregroundStyle(.secondary) }
            ForEach(Array(page.items.enumerated()), id: \.offset) { index, comment in
                CommentRow(comment: comment)
                    .onAppear {
                        if index >= page.items.count - 3 { comments.loadMore() }
                    }
            }
            if comments.isLoading { ProgressView() }
        } else {
            ProgressView().onAppear { comments.load() }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        comments.post(text)
    }
}

struct CommentRow: View {
    let comment: Comment

    var body: some View {
        Button {} label: {
            HStack(alignment: .top, spacing: 16) {
                RemoteImage(url: comment.authorAvatar.flatMap(URL.init(string:)))
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(comment.author).font(.caption.bold())
                        if comment.isCreator { Badge(text: "Creator", color: .gray) }
                        if comment.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                        if let published = comment.publishedText { Text(published).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(comment.text).font(.callout)
                    HStack(spacing: 16) {
                        if let likes = comment.likeCountText, !likes.isEmpty {
                            Label(likes, systemImage: "hand.thumbsup").font(.caption2)
                        }
                        if let replies = comment.replyCountText, !replies.isEmpty {
                            Label(replies, systemImage: "bubble.left").font(.caption2)
                        }
                        if comment.isHearted { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.red) }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}
