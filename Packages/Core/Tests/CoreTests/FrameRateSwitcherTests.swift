import XCTest
@testable import Core

final class FrameRateTargetTests: XCTestCase {
    func testTwentyFourFamilyGoesTo24Hz() {
        XCTAssertEqual(RefreshRate.target(fps: 23.976), 24)
        XCTAssertEqual(RefreshRate.target(fps: 23.98), 24)
        XCTAssertEqual(RefreshRate.target(fps: 24), 24)
    }

    func testPALFamilyGoesTo50Hz() {
        XCTAssertEqual(RefreshRate.target(fps: 25), 50)
        XCTAssertEqual(RefreshRate.target(fps: 50), 50)
    }

    func testNTSCFamilyGoesTo60HzNever30() {
        for fps in [29.97, 30, 59.94, 60] {
            XCTAssertEqual(RefreshRate.target(fps: fps), 60, "\(fps) fps")
        }
        for fps in stride(from: 5.0, through: 130.0, by: 0.01) {
            XCTAssertNotEqual(RefreshRate.target(fps: fps), 30, "\(fps) fps must never ask for 30 Hz")
        }
    }

    func testOtherRatesHaveNoTarget() {
        let rates: [Double] = [0, -24, 6, 12, 15, 20, 47.952, 48, 90, 100, 120, .nan, .infinity]
        for fps in rates {
            XCTAssertNil(RefreshRate.target(fps: fps), "\(fps) fps")
        }
    }

    func testHomeRateFromScreen() {
        XCTAssertEqual(RefreshRate.home(screenFramesPerSecond: 50), 50)
        XCTAssertEqual(RefreshRate.home(screenFramesPerSecond: 60), 60)
        XCTAssertEqual(RefreshRate.home(screenFramesPerSecond: 59), 60)
        XCTAssertEqual(RefreshRate.home(screenFramesPerSecond: 24), 60, "24 can only be a switch still in effect")
        XCTAssertEqual(RefreshRate.home(screenFramesPerSecond: 0), 60)
        XCTAssertEqual(RefreshRate.home(screenFramesPerSecond: 120), 60)
    }

    func testVideoRatePrefersContainerOnlyWhenItAgrees() {
        XCTAssertEqual(RefreshRate.videoRate(container: 23.976, listed: 24), 23.976)
        XCTAssertEqual(RefreshRate.videoRate(container: 59.94, listed: 60), 59.94)
        XCTAssertEqual(RefreshRate.videoRate(container: 0, listed: 24), 24, "mpv hasn't reported it yet")
        XCTAssertEqual(RefreshRate.videoRate(container: 1000, listed: 24), 24, "bogus container rate")
        XCTAssertEqual(RefreshRate.videoRate(container: 29.97, listed: nil), 29.97)
        XCTAssertEqual(RefreshRate.videoRate(container: .nan, listed: nil), 0)
        XCTAssertEqual(RefreshRate.videoRate(container: 0, listed: nil), 0)
    }

    func testFormat() {
        XCTAssertEqual(RefreshRate.format(23.976), "23.976")
        XCTAssertEqual(RefreshRate.format(24), "24")
        XCTAssertEqual(RefreshRate.format(29.97), "29.97")
        XCTAssertEqual(RefreshRate.format(59.94), "59.94")
        XCTAssertEqual(RefreshRate.format(50), "50")
    }
}

final class FrameRateSwitcherTests: XCTestCase {
    private typealias Decision = FrameRateSwitcher.Decision

    /// Plays `videos` (id, fps) one after another in one player session, then leaves; returns
    /// every decision including the one on leaving.
    private func session(_ videos: [(String, Double)], mode: FrameRateMatching, home: Double = 60) -> [Decision] {
        var switcher = FrameRateSwitcher()
        var decisions = videos.map { switcher.decide(videoId: $0.0, fps: $0.1, mode: mode, homeRate: home).decision }
        decisions.append(switcher.leave().decision)
        return decisions
    }

    private func changes(_ decisions: [Decision]) -> Int {
        decisions.filter { $0 != .keep }.count
    }

    // MARK: - Off

    func testOffNeverTouchesTheDisplay() {
        let decisions = session([("a", 23.976), ("b", 60), ("c", 50), ("d", 24), ("a", 25)], mode: .off)
        XCTAssertEqual(decisions, Array(repeating: .keep, count: 6), "not even a reset on leaving")
    }

    func testOffMessage() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 24, mode: .off, homeRate: 60),
                       .init(decision: .keep, message: "display: matching off"))
        XCTAssertNil(switcher.requested)
        XCTAssertEqual(switcher.leave(), .init(decision: .keep, message: "display: leaving player → nothing to reset"))
    }

    // MARK: - 24 fps videos only

    func testOnly24SwitchesA24pVideoAndResetsOnLeaving() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "film", fps: 23.976, mode: .only24, homeRate: 60),
                       .init(decision: .switchTo(24), message: "display: 23.976 fps → switching to 24 Hz (was 60 Hz)"))
        XCTAssertEqual(switcher.requested, 24)
        XCTAssertEqual(switcher.current, 24)
        XCTAssertEqual(switcher.leave(),
                       .init(decision: .resetToHome, message: "display: leaving player → reset to home 60 Hz (was 24 Hz)"))
        XCTAssertNil(switcher.requested)
    }

    func testOnly24LeavesOtherVideosAtTheHomeRate() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 60, mode: .only24, homeRate: 50),
                       .init(decision: .keep, message: "display: 60 fps → keeping 50 Hz (only 24 fps videos switch)"))
        XCTAssertEqual(switcher.decide(videoId: "b", fps: 25, mode: .only24, homeRate: 50).decision, .keep)
        XCTAssertEqual(switcher.decide(videoId: "c", fps: 29.97, mode: .only24, homeRate: 50).decision, .keep)
        XCTAssertEqual(switcher.decide(videoId: "d", fps: 48, mode: .only24, homeRate: 50).decision, .keep)
        XCTAssertEqual(switcher.leave().decision, .keep, "Tube changed nothing, so nothing is reset")
    }

    func testOnly24ConsecutiveFilmsKeepTheMode() {
        let decisions = session([("a", 24), ("b", 23.976), ("c", 24), ("d", 23.976)], mode: .only24)
        XCTAssertEqual(decisions, [.switchTo(24), .keep, .keep, .keep, .resetToHome])
    }

    func testOnly24OtherVideoAfterAFilmGoesBackToHome() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "film", fps: 24, mode: .only24, homeRate: 50).decision, .switchTo(24))
        XCTAssertEqual(switcher.decide(videoId: "sport", fps: 59.94, mode: .only24, homeRate: 24),
                       .init(decision: .resetToHome, message: "display: 59.94 fps → reset to home 50 Hz (was 24 Hz)"),
                       "while at 24 Hz the screen reports 24; the home rate read before stays")
        XCTAssertNil(switcher.requested)
        XCTAssertEqual(switcher.decide(videoId: "vlog", fps: 30, mode: .only24, homeRate: 50).decision, .keep)
        XCTAssertEqual(switcher.leave().decision, .keep, "already back at home")
    }

    func testOnly24UnmatchedRateAfterAFilmAlsoGoesBackToHome() {
        let decisions = session([("film", 24), ("odd", 48)], mode: .only24)
        XCTAssertEqual(decisions, [.switchTo(24), .resetToHome, .keep])
    }

    func testOnly24MixedAutoplayChain() {
        let chain: [(String, Double)] = [("a", 24), ("b", 24), ("c", 23.976), ("d", 60), ("e", 30),
                                         ("f", 24), ("g", 24), ("h", 50)]
        let decisions = session(chain, mode: .only24)
        XCTAssertEqual(decisions, [.switchTo(24), .keep, .keep, .resetToHome, .keep,
                                   .switchTo(24), .keep, .resetToHome, .keep])
        XCTAssertEqual(changes(decisions), 4)
    }

    // MARK: - Once per video

    func testRestartsOfTheSameVideoNeverSwitchAgain() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 24, mode: .only24, homeRate: 60).decision, .switchTo(24))
        // Quality change to a format mpv reports differently, Retry, two reconnects.
        for fps in [25.0, 60, 24, 0] {
            XCTAssertEqual(switcher.decide(videoId: "a", fps: fps, mode: .only24, homeRate: 60),
                           .init(decision: .keep,
                                 message: "display: same video again (quality change, Retry or reconnect) → keeping 24 Hz"))
        }
        XCTAssertEqual(switcher.requested, 24)
        XCTAssertTrue(switcher.hasDecided("a"))
        XCTAssertFalse(switcher.hasDecided("b"))
    }

    func testRestartOfAVideoThatKeptTheModeDoesNotSwitchEither() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 60, mode: .all, homeRate: 60).decision, .keep)
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 24, mode: .all, homeRate: 60).decision, .keep,
                       "a different format of the same video doesn't get a second decision")
        XCTAssertNil(switcher.requested)
    }

    func testOnly24UnknownRateAfterAFilmGoesBackToHome() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "film", fps: 24, mode: .only24, homeRate: 60).decision, .switchTo(24))
        XCTAssertEqual(switcher.decide(videoId: "unlisted", fps: 0, mode: .only24, homeRate: 24),
                       .init(decision: .resetToHome, message: "display: frame rate unknown → reset to home 60 Hz (was 24 Hz)"),
                       "a video not known to be 24 fps may be a 60 fps one")
        XCTAssertNil(switcher.requested)
        XCTAssertEqual(switcher.decide(videoId: "unlisted2", fps: .nan, mode: .only24, homeRate: 60),
                       .init(decision: .keep, message: "display: frame rate unknown → keeping 60 Hz"),
                       "at the home rate there is nothing to reset")
        XCTAssertEqual(switcher.leave().decision, .keep)
    }

    func testUnknownFrameRateUsesUpTheDecision() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 0, mode: .all, homeRate: 60),
                       .init(decision: .keep, message: "display: frame rate unknown → keeping 60 Hz"))
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 24, mode: .all, homeRate: 60).decision, .keep)
    }

    func testTheSameVideoLaterInTheSessionDecidesAgain() {
        let decisions = session([("film", 24), ("sport", 60), ("film", 24)], mode: .only24)
        XCTAssertEqual(decisions, [.switchTo(24), .resetToHome, .switchTo(24), .resetToHome])
    }

    func testANewSessionDecidesAfresh() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 24, mode: .only24, homeRate: 60).decision, .switchTo(24))
        XCTAssertEqual(switcher.leave().decision, .resetToHome)
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 24, mode: .only24, homeRate: 60).decision, .switchTo(24),
                       "the player was left and the TV reset; opening the video again matches it again")
    }

    // MARK: - All videos

    func testAllVideosWithA60HzHome() {
        let chain: [(String, Double)] = [("a", 23.976), ("b", 50), ("c", 25), ("d", 60), ("e", 29.97),
                                         ("f", 59.94), ("g", 24)]
        let decisions = session(chain, mode: .all, home: 60)
        XCTAssertEqual(decisions, [.switchTo(24), .switchTo(50), .keep, .resetToHome, .keep,
                                   .keep, .switchTo(24), .resetToHome])
    }

    func testAllVideosWithA50HzHome() {
        let chain: [(String, Double)] = [("a", 50), ("b", 25), ("c", 60), ("d", 29.97), ("e", 50),
                                         ("f", 24), ("g", 23.976)]
        let decisions = session(chain, mode: .all, home: 50)
        XCTAssertEqual(decisions, [.keep, .keep, .switchTo(60), .keep, .resetToHome,
                                   .switchTo(24), .keep, .resetToHome])
    }

    func testAllVideosMessages() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 59.94, mode: .all, homeRate: 50),
                       .init(decision: .switchTo(60), message: "display: 59.94 fps → switching to 60 Hz (was 50 Hz)"))
        XCTAssertEqual(switcher.decide(videoId: "b", fps: 60, mode: .all, homeRate: 60),
                       .init(decision: .keep, message: "display: 60 fps → keeping 60 Hz"))
        XCTAssertEqual(switcher.decide(videoId: "c", fps: 25, mode: .all, homeRate: 60),
                       .init(decision: .resetToHome, message: "display: 25 fps → reset to home 50 Hz (was 60 Hz)"))
        XCTAssertEqual(switcher.decide(videoId: "d", fps: 48, mode: .all, homeRate: 50),
                       .init(decision: .keep, message: "display: 48 fps → no matching refresh rate, keeping 50 Hz"))
    }

    func testAllVideosOtherRatesNeverSwitch() {
        XCTAssertEqual(session([("a", 15), ("b", 48), ("c", 120)], mode: .all), [.keep, .keep, .keep, .keep])
        XCTAssertEqual(session([("film", 24), ("odd", 48), ("slides", 15)], mode: .all),
                       [.switchTo(24), .keep, .keep, .resetToHome],
                       "an unmatched rate keeps the mode on; leaving resets it")
    }

    func testNeverRequests30Hz() {
        var switcher = FrameRateSwitcher()
        for (index, fps) in stride(from: 1.0, through: 130.0, by: 0.25).enumerated() {
            for mode in FrameRateMatching.allCases {
                let decision = switcher.decide(videoId: "\(mode)-\(index)", fps: fps, mode: mode, homeRate: 60).decision
                if case .switchTo(let rate) = decision {
                    XCTAssertTrue([24, 50, 60].contains(rate), "\(fps) fps asked for \(rate) Hz")
                }
            }
        }
    }

    // MARK: - Home rate and switch counts

    func testHomeRateIsTakenOnlyWhileNothingIsRequested() {
        var switcher = FrameRateSwitcher()
        XCTAssertEqual(switcher.homeRate, 60)
        XCTAssertEqual(switcher.decide(videoId: "a", fps: 50, mode: .all, homeRate: 50).decision, .keep)
        XCTAssertEqual(switcher.homeRate, 50)
        XCTAssertEqual(switcher.decide(videoId: "b", fps: 24, mode: .all, homeRate: 50).decision, .switchTo(24))
        XCTAssertEqual(switcher.decide(videoId: "c", fps: 23.976, mode: .all, homeRate: 60).decision, .keep)
        XCTAssertEqual(switcher.homeRate, 50, "the screen showed Tube's rate, not the home one")
        XCTAssertEqual(switcher.decide(videoId: "d", fps: 50, mode: .all, homeRate: nil).decision, .resetToHome)
    }

    func testSwitchCountsForATypicalEvening() {
        // Two films, then a run of 60 fps clips and a 30 fps vlog, then a film again.
        let evening: [(String, Double)] = [("f1", 23.976), ("f2", 24), ("c1", 60), ("c2", 59.94), ("v1", 30), ("f3", 24)]
        XCTAssertEqual(changes(session(evening, mode: .off, home: 50)), 0)
        // 24 Hz, back to 50, 24 Hz, back to 50 on leaving.
        XCTAssertEqual(changes(session(evening, mode: .only24, home: 50)), 4)
        // 24 Hz, 60 Hz, 24 Hz, back to 50 on leaving.
        XCTAssertEqual(changes(session(evening, mode: .all, home: 50)), 4)
        // With a 60 Hz home the clips need no mode of their own: 24, back to 60, 24, back on leaving.
        XCTAssertEqual(changes(session(evening, mode: .all, home: 60)), 4)
    }
}
