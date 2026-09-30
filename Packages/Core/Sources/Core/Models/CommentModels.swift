import Foundation

/// One batch of replies to a top-level comment (`YouTubeService.commentReplies`, then
/// `moreCommentReplies` with `continuation`).
public struct CommentRepliesPage: Codable, Hashable, Sendable {
    public var commentId: String
    @DefaultEmpty public var items: [Comment] = []
    public var continuation: String?
}

/// Comments or replies that grow page by page. Rows are identified by comment id, and YouTube
/// repeats comments at page edges (the pinned comment on page two, the last reply of a batch at the
/// start of the next), so a comment already listed is not added again.
public struct CommentList: Hashable, Sendable {
    public private(set) var items: [Comment] = []
    public var continuation: String?
    private var ids: Set<String> = []

    public init(_ items: [Comment] = [], continuation: String? = nil) {
        self.continuation = continuation
        append(items, continuation: continuation)
    }

    /// Adds the comments not listed yet and takes the page's continuation. Returns how many were
    /// added (0 for a page of repeats, which callers treat like an empty page).
    @discardableResult
    public mutating func append(_ more: [Comment], continuation: String?) -> Int {
        let before = items.count
        for comment in more where ids.insert(comment.id).inserted {
            items.append(comment)
        }
        self.continuation = continuation
        return items.count - before
    }
}

extension Comment {
    /// "1 reply", "12 replies", "1.2K replies"; "Replies" when YouTube gave no count; nil when
    /// there are none to open.
    public var repliesLabel: String? {
        guard let count = replyCountText, !count.isEmpty, count != "0" else { return hasReplies ? "Replies" : nil }
        return count == "1" ? "1 reply" : "\(count) replies"
    }

    /// The text in pieces of at most about `maxLength` characters, cut between lines (or, inside a
    /// very long line, between words). The comment view makes each piece focusable on its own: the
    /// remote scrolls from focused view to focused view, so a single view taller than the screen
    /// could never be read to the end.
    public func textChunks(maxLength: Int = 400) -> [String] {
        let limit = max(maxLength, 40)
        var chunks: [String] = []
        var current = ""
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            current = ""
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var rest = Substring(line)
            while rest.count > limit {
                flush()
                let window = rest.prefix(limit)
                var cut = window.lastIndex(of: " ") ?? window.endIndex
                if cut == rest.startIndex { cut = window.endIndex }
                current = String(rest[..<cut])
                flush()
                rest = rest[cut...].drop(while: { $0 == " " })
            }
            if !current.isEmpty, current.count + 1 + rest.count > limit { flush() }
            if !current.isEmpty { current.append("\n") }
            current.append(contentsOf: rest)
        }
        flush()
        return chunks
    }
}
