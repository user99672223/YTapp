import SwiftUI
import UIKit
import AVKit
import AVFoundation
import CoreMedia
import Darwin
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

/// Frame-rate matching: asks tvOS to switch the display to the stream's frame rate (SDR).
@MainActor
enum DisplayCriteriaController {
    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ??
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first
    }

    static var isMatchingEnabled: Bool {
        window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false
    }

    static var isSwitching: Bool {
        window?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
    }

    /// Returns the applied refresh rate, or nil when matching is off or not possible.
    @discardableResult
    static func apply(fps: Double, width: Int, height: Int) -> Double? {
        guard let manager = window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled,
              let rate = RefreshRate.match(fps: fps) else { return nil }
        var format: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        ]
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: Int32(max(width, 16)), height: Int32(max(height, 16)),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { return nil }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(rate), formatDescription: format)
        return rate
    }

    static func reset() {
        window?.avDisplayManager.preferredDisplayCriteria = nil
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
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
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
