import XCTest
@testable import Core

/// Decodes the JSON produced by the JS bridge normalizers (js/test/bridge.test.mjs writes these
/// fixtures), so JS/Swift contract drift fails CI.
final class FixtureDecodingTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).json missing")
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: fixture(name))
    }

    func testSessionSummary() throws {
        let session = try Self.decode(SessionSummary.self, "session")
        XCTAssertTrue(session.loggedIn)
        XCTAssertTrue(session.hasDecipher)
        XCTAssertEqual(session.account?.name, "Test Household")
        XCTAssertEqual(session.account?.handle, "@testhousehold")
        XCTAssertEqual(session.playerId, "0a1b2c3d")
        XCTAssertEqual(session.signatureTimestamp, 20314)
    }

    func testHomeFeed() throws {
        let home = try Self.decode(FeedPage.self, "home")
        XCTAssertNotNil(home.continuation)
        let videos = home.sections.flatMap(\.videos)
        let first = try XCTUnwrap(videos.first { $0.id == "VIDEOID0001" })
        XCTAssertEqual(first.title, "First video")
        XCTAssertEqual(first.channelName, "Channel One")
        XCTAssertEqual(first.durationSeconds, 605)
        XCTAssertEqual(first.watchedPercent, 40)
        XCTAssertFalse(first.isShort)
        XCTAssertEqual(first.subtitle, "Channel One • 12K views • 3 days ago")
        let lockup = try XCTUnwrap(videos.first { $0.id == "LOCKUPVID01" })
        XCTAssertEqual(lockup.durationText, "1:02:03")
        let shelf = try XCTUnwrap(home.sections.first { $0.style == .shorts })
        XCTAssertEqual(shelf.title, "Shorts")
        XCTAssertEqual(shelf.videos.map(\.id), ["SHORTID0001", "SHORTID0002"])
        XCTAssertTrue(shelf.videos.allSatisfy(\.isShort))
        XCTAssertEqual(home.shorts.map(\.id), ["SHORTID0001", "SHORTID0002"])
    }

    func testContinuationAppendMergesGrid() throws {
        var home = try Self.decode(FeedPage.self, "home")
        let more = try Self.decode(FeedPage.self, "home-more")
        let sectionCount = home.sections.count
        let lastGridCount = home.sections.last?.items.count ?? 0
        home.append(more)
        XCTAssertEqual(home.sections.count, sectionCount, "an untitled grid continues the last grid")
        XCTAssertEqual(home.sections.last?.items.count, lastGridCount + 1)
        XCTAssertEqual(home.sections.last?.videos.last?.id, "VIDEOID0003")
        XCTAssertNil(home.continuation)
    }

    func testVideoDetails() throws {
        let video = try Self.decode(VideoDetails.self, "video")
        XCTAssertEqual(video.title, "First video")
        XCTAssertEqual(video.channel.isSubscribed, true)
        XCTAssertEqual(video.likeStatus, LikeStatus.none)
        XCTAssertEqual(video.chapters.map(\.title), ["Intro", "Part one"])
        XCTAssertEqual(video.captions.count, 2)
        XCTAssertTrue(video.captions[0].url.contains("fmt=vtt"))
        XCTAssertEqual(video.upNext.map(\.id), ["RELATEDVID1", "RELATEDVID2"])
        XCTAssertEqual(video.autoplayNextId, "RELATEDVID1")
        XCTAssertEqual(video.playerClient, "TV")
        XCTAssertTrue(video.trackingAvailable)
        XCTAssertEqual(video.formats.count, 7)
        let hdr = try XCTUnwrap(video.formats.first { $0.itag == 337 })
        XCTAssertTrue(hdr.isHdr)
        XCTAssertEqual(video.formats.first { $0.itag == 251 }?.codecFamily, .opus)
        XCTAssertEqual(video.formats.first { $0.itag == 401 }?.codecFamily, .av1)
    }

    func testSearchResults() throws {
        let page = try Self.decode(FeedPage.self, "search")
        let channels = page.allItems.compactMap { item -> ChannelItem? in
            if case .channel(let c) = item { return c }
            return nil
        }
        XCTAssertEqual(channels.first?.handle, "@channeltwo")
        XCTAssertEqual(channels.first?.isSubscribed, false)
        XCTAssertTrue(page.sections.contains { $0.style == .shorts })
    }

    func testShortDetails() throws {
        let short = try Self.decode(ShortDetails.self, "short")
        XCTAssertEqual(short.title, "Short one")
        XCTAssertEqual(short.likeStatus, .like)
        XCTAssertFalse(short.formats.isEmpty)
        XCTAssertTrue(short.trackingAvailable)
    }

    func testFeedItemRoundTrip() throws {
        let page = try Self.decode(FeedPage.self, "home")
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(FeedPage.self, from: data)
        XCTAssertEqual(decoded, page)
    }

    func testMissingOptionalFieldsDecode() throws {
        let json = #"{"sections":[{"id":"x","style":"somethingNew","items":[{"id":"abc","title":"T"},{"type":"channel","id":"UC1","name":"C"}]}]}"#
        let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.sections[0].style, .row)
        XCTAssertEqual(page.sections[0].videos.first?.isLive, false)
        XCTAssertEqual(page.allItems.count, 2)
        let empty = try JSONDecoder().decode(FeedPage.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
    }
}
