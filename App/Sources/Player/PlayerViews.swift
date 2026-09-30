import SwiftUI
import UIKit
import AVKit
import AVFoundation
import CoreMedia
import Darwin
import os
import Core

/// CAMetalLayer that ignores the 1x1 drawable size MoltenVK sometimes sets (mpv PR 13651).
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

final class MPVVideoUIView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }

    var metalLayer: MPVMetalLayer {
        // layerClass guarantees the type.
        layer as! MPVMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// SwiftUI host for the mpv video output.
struct MPVVideoView: UIViewRepresentable {
    let player: MPVPlayer

    func makeUIView(context: Context) -> MPVVideoUIView {
        let view = MPVVideoUIView(frame: .zero)
        player.attach(to: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MPVVideoUIView, context: Context) {}
}

/// Keeps the screensaver away while any player is playing (mpv doesn't do this like AVPlayer).
@MainActor
enum IdleTimer {
    private static var playing = Set<ObjectIdentifier>()

    static func set(_ owner: AnyObject, playing isPlaying: Bool) {
        let id = ObjectIdentifier(owner)
        if isPlaying { playing.insert(id) } else { playing.remove(id) }
        let disabled = !playing.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
}

/// Frame-rate matching: asks tvOS to switch the display to a refresh rate (SDR) and back. When
/// and to what is `FrameRateSwitcher`'s decision (Core); this only applies it.
///
/// tvOS 27 removed `-[UIWindow avDisplayManager]` (calling it raises "unrecognized selector" and
/// aborts the app), so the display manager is looked up dynamically: the window where it still
/// exists, else the window scene or the screen if a later tvOS moved it there. Without one,
/// frame-rate matching is simply off.
///
/// A real mode change shows up in the TV's log as this app's own
/// `[com.apple.BackBoard:Display] [FBSDisplaySource 1-1] updating <… mode: "1920x1080 24Hz …">`
/// line. A request for the mode that is already on only gets PineBoard's "Display mode update
/// specifies current mode, not changing anything", but still reports a switch in progress for
/// about 2.5 s.
@MainActor
enum DisplayCriteriaController {
    private static let log = Logger(subsystem: "com.local.tube", category: "display")
    private static let selector = NSSelectorFromString("avDisplayManager")
    private static var reported = false
    /// The rate Tube's criteria ask for; nil while none are set and the TV shows its own format.
    private(set) static var requestedRate: Double?
    private static var knownHomeRate: Double?

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ??
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first
    }

    private static var manager: AVDisplayManager? {
        let owners: [(String, NSObject?)] = [
            ("UIWindow", window),
            ("UIWindowScene", window?.windowScene),
            ("UIScreen", window?.screen)
        ]
        for (name, owner) in owners {
            guard let owner, owner.responds(to: selector),
                  let found = owner.value(forKey: "avDisplayManager") as? AVDisplayManager else { continue }
            report("display manager found on \(name)")
            return found
        }
        report("no AVDisplayManager on this tvOS (\(UIDevice.current.systemVersion)); frame-rate matching is off")
        return nil
    }

    private static func report(_ message: String) {
        guard !reported else { return }
        reported = true
        log.notice("\(message, privacy: .public)")
    }

    /// One frame-rate line in the TV log (category "display", notice level), e.g.
    /// "display: 23.976 fps → switching to 24 Hz (was 50 Hz)".
    static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    static var isAvailable: Bool { manager != nil }

    static var isMatchingEnabled: Bool {
        manager?.isDisplayCriteriaMatchingEnabled ?? false
    }

    static var isSwitching: Bool {
        manager?.isDisplayModeSwitchInProgress ?? false
    }

    /// Why Tube can't switch the display now, or nil when it can. tvOS ignores the criteria
    /// unless Settings → Video and Audio → Match Content → Match Frame Rate is on.
    static var unavailableReason: String? {
        guard let manager else { return "no AVDisplayManager on this tvOS (\(UIDevice.current.systemVersion))" }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            return "Match Frame Rate is off in Apple TV Settings → Video and Audio → Match Content"
        }
        return nil
    }

    /// The Apple TV side of frame-rate matching, for the Debug screen: whether tvOS lets apps
    /// switch at all, the TV's own rate, and the rate Tube asks for right now.
    static var status: String {
        guard let manager else { return "Not available on this tvOS" }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            return "Off — turn on Match Frame Rate in Apple TV Settings → Video and Audio → Match Content"
        }
        let home = "TV home rate \(RefreshRate.format(homeRate)) Hz"
        guard let requestedRate else { return "On · \(home)" }
        return "On · \(home) · Tube asked for \(RefreshRate.format(requestedRate)) Hz"
    }

    /// The TV's own refresh rate: the format picked in Apple TV Settings → Video and Audio, which
    /// the home screen and every unswitched video play at. tvOS has no API that names it; the
    /// screen's `maximumFramesPerSecond` follows the current output mode (Kodi reads the same
    /// through CADisplayLink), so it is read only while Tube has no criteria set and no switch is
    /// under way, and remembered for the times Tube's own rate is on. 50 when the screen says 50,
    /// else 60 (see `RefreshRate.home`).
    static var homeRate: Double {
        if requestedRate == nil, !isSwitching, let screen = window?.screen {
            let screenRate = screen.maximumFramesPerSecond
            let home = RefreshRate.home(screenFramesPerSecond: screenRate)
            if home != knownHomeRate {
                note("display: home rate \(RefreshRate.format(home)) Hz (screen reports \(screenRate) fps)")
            }
            knownHomeRate = home
        }
        return knownHomeRate ?? 60
    }

    /// Asks tvOS for `refreshRate` in SDR (BT.709). False when the criteria couldn't be built.
    static func request(refreshRate: Double, width: Int, height: Int) -> Bool {
        guard let manager else { return false }
        var format: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        ]
        let created = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: Int32(max(width, 16)), height: Int32(max(height, 16)),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard created == noErr, let format else { return false }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(refreshRate), formatDescription: format)
        requestedRate = refreshRate
        return true
    }

    /// Drops Tube's criteria: tvOS goes back to the TV's own format.
    static func reset() {
        manager?.preferredDisplayCriteria = nil
        requestedRate = nil
    }
}

/// CPU and memory of this process, for the debug screen.
enum ProcessStats {
    /// Sum of all threads' CPU usage in percent of one core (e.g. 350 = 3.5 cores busy).
    static func cpuPercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList else { return 0 }
        defer {
            // task_threads hands out a send right per thread plus the array itself.
            for index in 0..<Int(threadCount) { mach_port_deallocate(mach_task_self_, threadList[index]) }
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }
        var total = 0.0
        let infoCount = MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(infoCount)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: infoCount) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }
}
