import XCTest
@testable import Core

final class QualitySelectorTests: XCTestCase {
    func video(_ index: Int, itag: Int, codecs: String, height: Int, fps: Double = 30, bitrate: Int = 1_000_000,
               hdr: Bool = false, otf: Bool = false, sr: Bool = false, hasUrl: Bool = true) -> StreamFormat {
        StreamFormat(index: index, itag: itag, mimeType: "video/x", codecs: codecs, hasVideo: true, width: height * 16 / 9,
                     height: height, fps: fps, bitrate: bitrate, isHdr: hdr, isOtf: otf, isSuperResolution: sr, hasUrl: hasUrl)
    }

    /// A vertical (Shorts) format: YouTube reports its real size, e.g. 1080×1920 for "1080p".
    func vertical(_ index: Int, itag: Int, codecs: String, width: Int) -> StreamFormat {
        StreamFormat(index: index, itag: itag, mimeType: "video/x", codecs: codecs, hasVideo: true, width: width,
                     height: width * 16 / 9, fps: 30, bitrate: width * 1000)
    }

    func audio(_ index: Int, itag: Int, codecs: String, bitrate: Int, drc: Bool = false, isDefault: Bool? = nil,
               autoDubbed: Bool? = nil) -> StreamFormat {
        StreamFormat(index: index, itag: itag, mimeType: "audio/x", codecs: codecs, hasAudio: true, bitrate: bitrate,
                     isDrc: drc, isDefaultAudio: isDefault, isAutoDubbed: autoDubbed)
    }

    func testFixturePicksAV1At2160AndOpus() throws {
        let details = try FixtureDecodingTests.decode(VideoDetails.self, "video")
        let selection = try QualitySelector.select(details.formats)
        XCTAssertEqual(selection.video.itag, 401, "2160p AV1 beats 2160p VP9 and the 2160p HDR stream is excluded")
        XCTAssertEqual(selection.audio?.itag, 251)
    }

    func testResolutionBeatsCodec() {
        let formats = [
            video(0, itag: 399, codecs: "av01.0.08M.08", height: 1080),
            video(1, itag: 313, codecs: "vp9", height: 2160),
            video(2, itag: 137, codecs: "avc1.640028", height: 1080)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(formats)?.itag, 313)
    }

    func testCodecOrderAtSameResolution() {
        let formats = [
            video(0, itag: 137, codecs: "avc1.640028", height: 1080, bitrate: 9_000_000),
            video(1, itag: 248, codecs: "vp9", height: 1080),
            video(2, itag: 399, codecs: "av01.0.08M.08", height: 1080)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(formats)?.itag, 399)
        let noAV1 = Array(formats.prefix(2))
        XCTAssertEqual(QualitySelector.selectVideo(noAV1)?.itag, 248)
    }

    func testHigherFrameRateWins() {
        let formats = [
            video(0, itag: 248, codecs: "vp9", height: 1080, fps: 30),
            video(1, itag: 303, codecs: "vp9", height: 1080, fps: 60)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(formats)?.itag, 303)
    }

    func testCapAt2160AndSkipHDRAndOTF() {
        let formats = [
            video(0, itag: 402, codecs: "av01.0.16M.08", height: 4320),
            video(1, itag: 337, codecs: "vp09.02.51.10", height: 2160, hdr: true),
            video(2, itag: 999, codecs: "av01.0.12M.08", height: 2160, otf: true),
            video(3, itag: 313, codecs: "vp9", height: 2160)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(formats)?.itag, 313)
    }

    func testVerticalVideosAreCappedOnTheShortSide() {
        let formats = [
            vertical(0, itag: 399, codecs: "av01.0.08M.08", width: 1080),
            vertical(1, itag: 398, codecs: "av01.0.05M.08", width: 720),
            vertical(2, itag: 397, codecs: "av01.0.04M.08", width: 480)
        ]
        XCTAssertEqual(formats[0].height, 1920)
        XCTAssertEqual(formats[0].shortSide, 1080)
        XCTAssertEqual(QualitySelector.selectVideo(formats, preferences: QualityPreferences(maxHeight: 1080))?.itag, 399,
                       "a 1080×1920 Short is 1080p, not 1920p")
        XCTAssertEqual(QualitySelector.selectVideo(formats, preferences: QualityPreferences(maxHeight: 1440))?.itag, 399)
        XCTAssertEqual(QualitySelector.selectVideo(formats, preferences: QualityPreferences(maxHeight: 720))?.itag, 398)
        XCTAssertEqual(QualitySelector.selectVideo(formats, preferences: QualityPreferences(maxHeight: 480))?.itag, 397)
        XCTAssertEqual(QualitySelector.overrideList(formats).video.map(\.itag), [399, 398, 397])
    }

    func testShortSideFallsBackToHeight() {
        let noWidth = StreamFormat(index: 0, itag: 137, mimeType: "video/x", codecs: "avc1.640028", hasVideo: true, height: 1080)
        XCTAssertEqual(noWidth.shortSide, 1080)
        XCTAssertEqual(video(0, itag: 137, codecs: "avc1.640028", height: 1080).shortSide, 1080)
    }

    func testDecodeBudgetSkipsFormatsTooHeavyForSoftwareDecoding() {
        let prefs = QualityPreferences(decodeBudget: DecodeBudget(softwarePixelsPerSecond: 3840 * 2160 * 30, hardware: [.avc]))
        let sixty = [
            video(0, itag: 401, codecs: "av01.0.13M.08", height: 2160, fps: 60),
            video(1, itag: 315, codecs: "vp9", height: 2160, fps: 60),
            video(2, itag: 400, codecs: "av01.0.12M.08", height: 1440, fps: 60),
            video(3, itag: 299, codecs: "avc1.64002a", height: 1080, fps: 60)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(sixty, preferences: prefs)?.itag, 400, "2160p60 is over the budget; 1440p60 AV1 is the best within it")
        XCTAssertEqual(QualitySelector.selectVideo(sixty)?.itag, 401, "without a budget the rule is unchanged")
        let thirty = [
            video(0, itag: 401, codecs: "av01.0.12M.08", height: 2160, fps: 30),
            video(1, itag: 400, codecs: "av01.0.12M.08", height: 1440, fps: 30)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(thirty, preferences: prefs)?.itag, 401, "2160p30 fits the budget")
        let onlyHeavy = [video(0, itag: 401, codecs: "av01.0.13M.08", height: 2160, fps: 60)]
        XCTAssertEqual(QualitySelector.selectVideo(onlyHeavy, preferences: prefs)?.itag, 401, "with nothing lighter, the rule's own pick is kept")
        XCTAssertTrue(DecodeBudget(softwarePixelsPerSecond: 1, hardware: [.avc]).allows(sixty[3]), "hardware codecs are always allowed")
    }

    func testSuperResolutionAvoidedWhenNativeExists() {
        let formats = [
            video(0, itag: 1401, codecs: "av01.0.12M.08", height: 2160, sr: true),
            video(1, itag: 399, codecs: "av01.0.08M.08", height: 1080)
        ]
        XCTAssertEqual(QualitySelector.selectVideo(formats)?.itag, 399)
        XCTAssertEqual(QualitySelector.selectVideo([formats[0]])?.itag, 1401, "SR is used when it is all there is")
    }

    func testAudioPreferences() {
        let formats = [
            audio(0, itag: 140, codecs: "mp4a.40.2", bitrate: 130_000),
            audio(1, itag: 250, codecs: "opus", bitrate: 70_000),
            audio(2, itag: 251, codecs: "opus", bitrate: 160_000, drc: true),
            audio(3, itag: 251, codecs: "opus", bitrate: 150_000)
        ]
        let chosen = QualitySelector.selectAudio(formats)
        XCTAssertEqual(chosen?.index, 3, "non-DRC itag 251 wins")
        XCTAssertEqual(QualitySelector.selectAudio([formats[0]])?.itag, 140, "AAC fallback")
    }

    func testAudioPrefersDefaultTrackOverDubs() {
        let formats = [
            audio(0, itag: 251, codecs: "opus", bitrate: 160_000, isDefault: false, autoDubbed: true),
            audio(1, itag: 251, codecs: "opus", bitrate: 140_000, isDefault: true)
        ]
        XCTAssertEqual(QualitySelector.selectAudio(formats)?.index, 1)
    }

    func testErrorsExplainWhy() {
        XCTAssertThrowsError(try QualitySelector.select([audio(0, itag: 251, codecs: "opus", bitrate: 1)])) { error in
            guard case QualityError.noVideoFormats = error else { return XCTFail("\(error)") }
        }
        let sabr = [video(0, itag: 313, codecs: "vp9", height: 2160, hasUrl: false)]
        XCTAssertThrowsError(try QualitySelector.select(sabr)) { error in
            XCTAssertTrue((error as? QualityError)?.errorDescription?.contains("SABR") ?? false)
        }
        let live = [video(0, itag: 313, codecs: "vp9", height: 2160, otf: true)]
        XCTAssertThrowsError(try QualitySelector.select(live)) { error in
            XCTAssertTrue((error as? QualityError)?.errorDescription?.contains("live") ?? false)
        }
    }

    func testOverrideListOrder() throws {
        let details = try FixtureDecodingTests.decode(VideoDetails.self, "video")
        let list = QualitySelector.overrideList(details.formats)
        XCTAssertEqual(list.video.first?.height, 2160)
        XCTAssertEqual(list.audio.first?.itag, 251)
        XCTAssertEqual(list.video.count + list.audio.count, details.formats.count)
    }

    func testDisplayNames() {
        let v = video(0, itag: 401, codecs: "av01.0.12M.08", height: 2160, bitrate: 12_000_000)
        XCTAssertTrue(v.displayName.contains("AV1"))
        XCTAssertTrue(v.displayName.contains("12.0 Mb/s"))
        let a = audio(0, itag: 251, codecs: "opus", bitrate: 160_000)
        XCTAssertTrue(a.displayName.hasPrefix("Opus"))
    }
}
