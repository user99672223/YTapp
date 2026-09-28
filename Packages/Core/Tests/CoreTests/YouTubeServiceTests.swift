import XCTest
@testable import Core

/// Records calls and answers with canned JSON — stands in for the JavaScriptCore runtime.
final class FakeTransport: BridgeTransport, @unchecked Sendable {
    var calls: [(method: String, args: [String: Any])] = []
    var responses: [String: Result<String, BridgeError>] = [:]

    func call(method: String, argsJSON: String) async throws -> Data {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
        calls.append((method, args))
        switch responses[method] {
        case .success(let json): return Data(json.utf8)
        case .failure(let error): throw error
        case nil: throw BridgeError(kind: .invalid, message: "no canned response for \(method)")
        }
    }
}

final class YouTubeServiceTests: XCTestCase {
    func testVideoInfoAndResolve() async throws {
        let transport = FakeTransport()
        transport.responses["videoInfo"] = .success(String(decoding: try FixtureDecodingTests.fixture("video"), as: UTF8.self))
        transport.responses["resolveFormats"] = .success(#"{"urls":{"1":"https://rr1.googlevideo.com/videoplayback?itag=401","5":"https://rr1.googlevideo.com/videoplayback?itag=251"},"userAgent":"UA","headers":{"Origin":"https://www.youtube.com"}}"#)
        let service = YouTubeService(transport: transport)
        let details = try await service.videoInfo("VIDEOID0001", client: "TV")
        XCTAssertEqual(transport.calls[0].method, "videoInfo")
        XCTAssertEqual(transport.calls[0].args["client"] as? String, "TV")
        let selection = try QualitySelector.select(details.formats)
        let streams = try await service.resolveFormats(videoId: details.id, formats: [selection.video, selection.audio!])
        XCTAssertEqual(transport.calls[1].args["indices"] as? [Int], [selection.video.index, selection.audio!.index])
        XCTAssertEqual(streams.url(for: selection.video)?.absoluteString, "https://rr1.googlevideo.com/videoplayback?itag=401")
        XCTAssertEqual(streams.userAgent, "UA")
    }

    func testErrorsPropagate() async {
        let transport = FakeTransport()
        transport.responses["home"] = .failure(BridgeError(kind: .auth, message: "401"))
        let service = YouTubeService(transport: transport)
        do {
            _ = try await service.home()
            XCTFail("expected error")
        } catch let error as BridgeError {
            XCTAssertEqual(error.kind, .auth)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBadJSONBecomesParseError() async {
        let transport = FakeTransport()
        transport.responses["home"] = .success(#"{"sections":"nope"}"#)
        let service = YouTubeService(transport: transport)
        do {
            _ = try await service.home()
            XCTFail("expected error")
        } catch let error as BridgeError {
            XCTAssertEqual(error.kind, .parse)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSearchFiltersEncoding() async throws {
        let transport = FakeTransport()
        transport.responses["search"] = .success(#"{"sections":[]}"#)
        let service = YouTubeService(transport: transport)
        _ = try await service.search("cats", filters: SearchFilters(uploadDate: .week, type: .video, duration: .long))
        let filters = transport.calls[0].args["filters"] as? [String: Any]
        XCTAssertEqual(filters?["upload_date"] as? String, "week")
        XCTAssertEqual(filters?["type"] as? String, "video")
        XCTAssertEqual(filters?["duration"] as? String, "over_twenty_mins")
    }

    func testInitSendsOptionsAndWatchtimeArgs() async throws {
        let transport = FakeTransport()
        transport.responses["init"] = .success(String(decoding: try FixtureDecodingTests.fixture("session"), as: UTF8.self))
        transport.responses["watchtime"] = .success(#"{"ok":true,"status":204}"#)
        let service = YouTubeService(transport: transport)
        let summary = try await service.initialize(SessionOptions(cookie: "SID=1", client: "TV", visitorData: "VD"))
        XCTAssertTrue(summary.loggedIn)
        XCTAssertEqual(transport.calls[0].args["cookie"] as? String, "SID=1")
        XCTAssertEqual(transport.calls[0].args["visitorData"] as? String, "VD")
        let report = WatchTimeReport(segments: [WatchSegment(start: 0, end: 10)], currentTime: 10, isPlaying: true,
                                     isFinal: true, length: 100, lastActivityMs: 0, realTime: 10)
        let ping = try await service.watchtime(videoId: "abc", report: report)
        XCTAssertTrue(ping.ok)
        XCTAssertEqual(transport.calls[1].args["id"] as? String, "abc")
        XCTAssertEqual(transport.calls[1].args["final"] as? Bool, true)
    }
}
