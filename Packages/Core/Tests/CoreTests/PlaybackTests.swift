import XCTest
@testable import Core

final class WatchTimeTrackerTests: XCTestCase {
    func testContinuousPlaybackSplitsAtFlush() {
        let tracker = WatchTimeTracker()
        for t in stride(from: 0.0, through: 30.0, by: 0.5) { tracker.record(position: t, isPlaying: true) }
        XCTAssertEqual(tracker.flush(), [WatchSegment(start: 0, end: 30)])
        for t in stride(from: 30.5, through: 60.0, by: 0.5) { tracker.record(position: t, isPlaying: true) }
        XCTAssertEqual(tracker.flush(), [WatchSegment(start: 30, end: 60)], "next report continues from the previous end")
    }

    func testSeekCreatesNewSegment() {
        let tracker = WatchTimeTracker()
        for t in stride(from: 0.0, through: 10.0, by: 0.5) { tracker.record(position: t, isPlaying: true) }
        tracker.seeked(to: 100, isPlaying: true)
        for t in stride(from: 100.0, through: 105.0, by: 0.5) { tracker.record(position: t, isPlaying: true) }
        XCTAssertEqual(tracker.flush(), [WatchSegment(start: 0, end: 10), WatchSegment(start: 100, end: 105)])
    }

    func testImplicitJumpIsDetected() {
        let tracker = WatchTimeTracker()
        tracker.record(position: 0, isPlaying: true)
        tracker.record(position: 1, isPlaying: true)
        tracker.record(position: 50, isPlaying: true)
        tracker.record(position: 51, isPlaying: true)
        XCTAssertEqual(tracker.flush(), [WatchSegment(start: 0, end: 1), WatchSegment(start: 50, end: 51)])
    }

    func testPauseClosesSegment() {
        let tracker = WatchTimeTracker()
        for t in stride(from: 0.0, through: 5.0, by: 1.0) { tracker.record(position: t, isPlaying: true) }
        tracker.record(position: 5, isPlaying: false)
        tracker.record(position: 5, isPlaying: false)
        XCTAssertEqual(tracker.flush(), [WatchSegment(start: 0, end: 5)])
        XCTAssertEqual(tracker.flush(), [], "nothing new while paused")
        tracker.record(position: 5, isPlaying: true)
        tracker.record(position: 7, isPlaying: true)
        XCTAssertEqual(tracker.flush(), [WatchSegment(start: 5, end: 7)])
    }

    func testReportArguments() {
        let report = WatchTimeReport(segments: [WatchSegment(start: 0, end: 30.12345)], currentTime: 30.12345, isPlaying: true,
                                     isFinal: false, length: 605, lastActivityMs: 1500.7, realTime: 31.9999,
                                     videoItag: 401, audioItag: 251)
        let args = report.bridgeArguments
        XCTAssertEqual(args["cmt"] as? Double, 30.123)
        XCTAssertEqual(args["playing"] as? Bool, true)
        XCTAssertEqual(args["final"] as? Bool, false)
        XCTAssertEqual(args["lact"] as? Int, 1500)
        XCTAssertEqual(args["fmt"] as? Int, 401)
        XCTAssertEqual(args["afmt"] as? Int, 251)
        XCTAssertEqual((args["segments"] as? [[Double]])?.first, [0, 30.123])
    }
}

final class PolicyTests: XCTestCase {
    func testResume() {
        XCTAssertNil(ResumePolicy.startPosition(saved: nil, duration: 600))
        XCTAssertNil(ResumePolicy.startPosition(saved: 10, duration: 600), "too early to bother")
        XCTAssertEqual(ResumePolicy.startPosition(saved: 120, duration: 600), 118)
        XCTAssertNil(ResumePolicy.startPosition(saved: 590, duration: 600), "finished videos start over")
        XCTAssertTrue(ResumePolicy.isFinished(position: 585, duration: 600))
        XCTAssertFalse(ResumePolicy.isFinished(position: 300, duration: 600))
    }

    func testRefreshPolicy() {
        let now = Date()
        XCTAssertTrue(RefreshPolicy.isFresh(fetchedAt: now.addingTimeInterval(-14 * 60), category: .home, now: now))
        XCTAssertFalse(RefreshPolicy.isFresh(fetchedAt: now.addingTimeInterval(-16 * 60), category: .subscriptions, now: now))
        XCTAssertFalse(RefreshPolicy.isFresh(fetchedAt: now.addingTimeInterval(-6 * 60), category: .videoInfo, now: now))
        XCTAssertTrue(RefreshPolicy.isFresh(fetchedAt: now.addingTimeInterval(-59 * 60), category: .channel, now: now))
        XCTAssertEqual(RefreshPolicy.ttl(.videoInfo), 300)
    }

    func testTTLCache() {
        let cache = TTLCache<String, Int>()
        let now = Date()
        cache.set(1, for: "a", ttl: 10, now: now)
        XCTAssertEqual(cache.value(for: "a", now: now.addingTimeInterval(5)), 1)
        XCTAssertNil(cache.value(for: "a", now: now.addingTimeInterval(11)))
    }

    func testChapterParser() {
        let description = """
        My video
        0:00 Intro
        1:15 - The part
        (12:30) Later
        1:02:03 Finale
        not a chapter 5:00
        """
        let chapters = ChapterParser.chapters(fromDescription: description, duration: 4000)
        XCTAssertEqual(chapters.map(\.title), ["Intro", "The part", "Later", "Finale"])
        XCTAssertEqual(chapters.map(\.startSeconds), [0, 75, 750, 3723])
        XCTAssertTrue(ChapterParser.chapters(fromDescription: "1:00 a\n2:00 b\n3:00 c").isEmpty, "must start at 0:00")
        XCTAssertEqual(ChapterParser.index(of: 80, in: chapters), 1)
        XCTAssertEqual(ChapterParser.index(of: 0, in: chapters), 0)
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.duration(3723), "1:02:03")
        XCTAssertEqual(Formatters.duration(65), "1:05")
        XCTAssertEqual(Formatters.duration(-1), "0:00")
        XCTAssertEqual(Formatters.bitrate(12_345_678), "12.3 Mb/s")
        XCTAssertEqual(Formatters.bitrate(160_000), "160 kb/s")
        XCTAssertEqual(Formatters.bytes(1536), "1.5 KB")
    }

    func testEffectiveChaptersFallBackToDescription() {
        var details = VideoDetails(id: "x", title: "t", channel: ChannelSummary(id: nil, name: "c"))
        details.description = "0:00 A\n0:30 B\n1:00 C"
        details.durationSeconds = 120
        XCTAssertEqual(details.effectiveChapters.count, 3)
    }
}

final class BridgeErrorTests: XCTestCase {
    func testDecodesUnknownKinds() throws {
        let json = #"{"kind":"somethingNew","message":"boom","status":500}"#
        let error = try JSONDecoder().decode(BridgeError.self, from: Data(json.utf8))
        XCTAssertEqual(error.kind, .unknown)
        XCTAssertEqual(error.userMessage, "boom")
    }

    func testAuthMessageMentionsSettings() {
        let error = BridgeError(kind: .auth, message: "Request failed with status code 401")
        XCTAssertTrue(error.isAuthFailure)
        XCTAssertTrue(error.userMessage.contains("Re-enter cookies"))
    }
}
