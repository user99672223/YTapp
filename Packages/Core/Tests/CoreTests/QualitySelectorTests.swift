import XCTest
@testable import Core

final class QualitySelectorTests: XCTestCase {
    func video(_ index: Int, itag: Int, codecs: String, height: Int, fps: Double = 30, bitrate: Int = 1_000_000,
               hdr: Bool = false, otf: Bool = false, sr: Bool = false, hasUrl: Bool = true) -> StreamFormat {
        StreamFormat(index: index, itag: itag, mimeType: "video/x", codecs: codecs, hasVideo: true, width: height * 16 / 9,
                     height: height, fps: fps, bitrate: bitrate, isHdr: hdr, isOtf: otf, isSuperResolution: sr, hasUrl: hasUrl)
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
