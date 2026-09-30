import XCTest
@testable import Core

/// Comments and replies as the JS normalizers produce them (js/test/bridge.test.mjs writes the
/// fixtures), the id-keyed list the panel shows, and the text pieces of the comment view.
final class CommentTests: XCTestCase {
    private static let busy = "UgxCOMMENT0003"

    func testCommentsPage() throws {
        let page = try FixtureDecodingTests.decode(CommentsPage.self, "comments")
        XCTAssertEqual(page.countText, "1,234")
        XCTAssertEqual(page.key, "comments:1")
        XCTAssertEqual(page.continuation, page.key)
        XCTAssertEqual(page.items.map(\.id), ["UgxCOMMENT0001", "UgxCOMMENT0002", Self.busy])
        let pinned = page.items[0]
        XCTAssertEqual(pinned.author, "@channelone")
        XCTAssertEqual(pinned.text, "Thanks for watching!\nChapters are in the description.")
        XCTAssertEqual(pinned.publishedText, "1 day ago")
        XCTAssertEqual(pinned.likeCountText, "1.2K")
        XCTAssertTrue(pinned.isPinned)
        XCTAssertTrue(pinned.isCreator)
        XCTAssertTrue(pinned.isHearted)
        XCTAssertTrue(pinned.hasReplies)
        XCTAssertEqual(pinned.repliesLabel, "2 replies")
        XCTAssertNotNil(pinned.authorAvatar.flatMap { URL(string: $0) })
        let plain = page.items[1]
        XCTAssertNil(plain.likeCountText)
        XCTAssertNil(plain.replyCountText)
        XCTAssertFalse(plain.hasReplies)
        XCTAssertNil(plain.repliesLabel)
    }

    func testNextPageSkipsRepeatedComments() throws {
        let page = try FixtureDecodingTests.decode(CommentsPage.self, "comments")
        let more = try FixtureDecodingTests.decode(CommentsPage.self, "comments-more")
        XCTAssertEqual(more.key, page.key)
        XCTAssertNil(more.continuation)
        var list = CommentList(page.items, continuation: page.continuation)
        let added = list.append(more.items, continuation: more.continuation)
        XCTAssertEqual(added, 2, "the repeated pinned comment is left out")
        XCTAssertEqual(list.items.map(\.id), ["UgxCOMMENT0001", "UgxCOMMENT0002", Self.busy, "UgxCOMMENT0004", "UgxCOMMENT0005"])
        XCTAssertNil(list.continuation)
        XCTAssertEqual(list.items.last?.repliesLabel, "1 reply")
        let repeated = list.append(more.items, continuation: nil)
        XCTAssertEqual(repeated, 0)
    }

    func testReplies() throws {
        let first = try FixtureDecodingTests.decode(CommentRepliesPage.self, "comment-replies")
        XCTAssertEqual(first.commentId, Self.busy)
        XCTAssertEqual(first.continuation, "comments:1#\(Self.busy)")
        XCTAssertEqual(first.items.first?.author, "@replier1")
        XCTAssertFalse(first.items.contains(where: \.hasReplies), "replies don't open replies")
        let rest = try FixtureDecodingTests.decode(CommentRepliesPage.self, "comment-replies-more")
        XCTAssertEqual(rest.commentId, Self.busy)
        XCTAssertNil(rest.continuation)
        var list = CommentList(first.items, continuation: first.continuation)
        list.append(rest.items, continuation: rest.continuation)
        XCTAssertEqual(list.items.map(\.id), ["REPLY1", "REPLY2", "REPLY3"].map { "\(Self.busy).\($0)" })
        XCTAssertNil(list.continuation)
    }

    func testServiceAsksForRepliesBySectionKey() async throws {
        let transport = FakeTransport()
        transport.responses["commentReplies"] = .success(String(decoding: try FixtureDecodingTests.fixture("comment-replies"), as: UTF8.self))
        transport.responses["commentRepliesMore"] = .success(String(decoding: try FixtureDecodingTests.fixture("comment-replies-more"), as: UTF8.self))
        let service = YouTubeService(transport: transport)
        let first = try await service.commentReplies(key: "comments:1", commentId: Self.busy)
        XCTAssertEqual(transport.calls[0].method, "commentReplies")
        XCTAssertEqual(transport.calls[0].args["key"] as? String, "comments:1")
        XCTAssertEqual(transport.calls[0].args["commentId"] as? String, Self.busy)
        let next = try XCTUnwrap(first.continuation)
        let more = try await service.moreCommentReplies(next)
        XCTAssertEqual(transport.calls[1].method, "commentRepliesMore")
        XCTAssertEqual(transport.calls[1].args["key"] as? String, "comments:1#\(Self.busy)")
        XCTAssertEqual(more.items.count, 1)
    }

    func testRepliesLabel() {
        var comment = Comment(id: "c", author: "a", text: "t")
        XCTAssertNil(comment.repliesLabel)
        comment.hasReplies = true
        XCTAssertEqual(comment.repliesLabel, "Replies")
        comment.replyCountText = "1"
        XCTAssertEqual(comment.repliesLabel, "1 reply")
        comment.replyCountText = "1.2K"
        XCTAssertEqual(comment.repliesLabel, "1.2K replies")
    }

    func testTextChunks() {
        XCTAssertEqual(Comment(id: "c", author: "a", text: "Short\n\ncomment").textChunks(), ["Short\n\ncomment"])
        XCTAssertEqual(Comment(id: "c", author: "a", text: "  \n ").textChunks(), [])

        let paragraph = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let long = Comment(id: "c", author: "a", text: [paragraph, paragraph, "", paragraph].joined(separator: "\r\n"))
        let chunks = long.textChunks(maxLength: 200)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 200 })
        XCTAssertEqual(chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).count, 90, "no word is lost")

        // One line longer than the limit is cut between words, or anywhere when it has no spaces.
        let wordy = Comment(id: "c", author: "a", text: String(repeating: "abcd ", count: 100)).textChunks(maxLength: 100)
        XCTAssertTrue(wordy.allSatisfy { $0.count <= 100 && !$0.hasPrefix(" ") })
        XCTAssertEqual(wordy.joined(separator: " ").split(separator: " ").count, 100)
        let unbroken = Comment(id: "c", author: "a", text: String(repeating: "x", count: 250)).textChunks(maxLength: 100)
        XCTAssertEqual(unbroken.map(\.count), [100, 100, 50])
    }
}
