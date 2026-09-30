import Foundation
import ImageIO
import SwiftUI
import UIKit
import os

extension URLCache {
    /// Downloaded artwork (thumbnails, avatars, banners) on disk, so scrolling back after a relaunch
    /// doesn't download it again. `URLCache.shared` is this cache too (set in AppModel). Its memory
    /// part is small: `ImagePipeline` keeps the decoded images, which are what scrolling needs.
    static let images: URLCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024,
                        directory: caches.appendingPathComponent("images", isDirectory: true))
    }()
}

/// Loads the artwork of the lists and grids for `RemoteImage`.
///
/// `AsyncImage`, used before, keeps nothing between appearances: a card that a lazy grid dropped
/// and made again while scrolling back started over from the grey placeholder, read its file
/// again, had the full-size picture (1280×720 for most thumbnails, up to 1080×1920 for Shorts)
/// decoded on the main thread in the middle of the scroll animation, and faded in. Here each image
/// - is decoded and scaled down to the pixel size it is drawn at, on a background queue (a grid
///   card's 1280×720 thumbnail becomes 364×205 pixels on a 1080p screen, 728×410 on a 4K one);
/// - stays decoded in memory (NSCache, emptied on a memory warning), so a card that comes back
///   draws its image in its first frame, without a placeholder or a fade;
/// - is requested once however many cards ask for it at the same time, through `URLCache.images`;
/// - stops downloading when every card waiting for it has left the screen.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private static let log = Logger(subsystem: "com.local.tube", category: "images")

    /// A decoded image and whether it is the picture's full resolution (a larger request can't
    /// do better than that one).
    private final class Entry {
        let image: UIImage
        let isFullSize: Bool
        let cost: Int

        init(image: UIImage, isFullSize: Bool, cost: Int) {
            self.image = image
            self.isFullSize = isFullSize
            self.cost = cost
        }
    }

    /// One download + decode, shared by the views waiting for the same URL at the same size.
    private final class Load {
        let task: Task<UIImage, Error>
        var waiters = 0

        init(task: Task<UIImage, Error>) {
            self.task = task
        }
    }

    /// One view's wait for a `Load`; it leaves exactly once, whether it finished or was cancelled.
    private final class Ticket {
        var hasLeft = false
    }

    private struct LoadKey: Hashable {
        let url: URL
        let width: Int
        let height: Int
        let fill: Bool
    }

    /// Counts for the stats line in the log (tools/tv/scrollstats.py reads the system's side).
    private struct Stats: Equatable {
        var fromMemory = 0
        var loaded = 0
        var downloaded = 0
        var cancelled = 0
        var failed = 0
        var bytes = 0
    }

    /// Keyed by URL alone: an entry serves every request it is large enough for (the same
    /// thumbnail in a grid and, smaller, in Up next).
    private let memory = NSCache<NSURL, Entry>()
    private let evictions = EvictionCounter()
    private let urlCache: URLCache
    private let session: URLSession
    private let decodeQueue = OperationQueue()
    private let lock = NSLock()
    private var loads: [LoadKey: Load] = [:]
    private var stats = Stats()
    private var loggedStats = Stats()
    private var lastStatsLog = Date.distantPast

    init(cache: URLCache = .images) {
        urlCache = cache
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        session = URLSession(configuration: config)
        decodeQueue.name = "com.local.tube.images.decode"
        decodeQueue.maxConcurrentOperationCount = 3
        decodeQueue.qualityOfService = .userInitiated
        // A few screens back: 400 cards, about 120 MB of grid thumbnails on a 1080p screen
        // (≈0.3 MB each); on a 4K one (≈1.2 MB each) the byte limit keeps about 100.
        memory.totalCostLimit = 128 * 1024 * 1024
        memory.countLimit = 400
        memory.delegate = evictions
        evictions.onEvict = { [weak self] object in
            guard let self, let entry = object as? Entry else { return }
            self.locked { self.stats.bytes -= entry.cost }
        }
    }

    // MARK: - Lookup

    /// The image for `url` if one at least `pixels` large is already decoded. Cheap enough for a
    /// view's body: it's what lets a card that comes back on screen draw its image at once.
    func cachedImage(_ url: URL, pixels: CGSize, mode: ContentMode) -> UIImage? {
        guard let entry = memory.object(forKey: url as NSURL), Self.isLargeEnough(entry, for: pixels, mode: mode) else {
            return nil
        }
        locked { stats.fromMemory += 1 }
        return entry.image
    }

    /// Downloads (or reads from disk), decodes and scales the image to fill (or fit) `pixels`,
    /// and keeps it in memory. Views asking for the same image at the same size share one load;
    /// it's cancelled when all of them are (their cards left the screen).
    func image(_ url: URL, pixels: CGSize, mode: ContentMode) async throws -> UIImage {
        if let hit = cachedImage(url, pixels: pixels, mode: mode) { return hit }
        let key = LoadKey(url: url, width: Int(pixels.width.rounded(.up)), height: Int(pixels.height.rounded(.up)), fill: mode == .fill)
        let ticket = Ticket()
        let load: Load = locked {
            if let running = loads[key] {
                running.waiters += 1
                return running
            }
            let new = Load(task: Task.detached(priority: .userInitiated) { [self] in
                try await self.fetch(key)
            })
            new.waiters = 1
            loads[key] = new
            return new
        }
        defer { leave(key, load, ticket, cancel: false) }
        return try await withTaskCancellationHandler {
            try await load.task.value
        } onCancel: {
            self.leave(key, load, ticket, cancel: true)
        }
    }

    /// Starts loading artwork a card will need soon (the next rows of a grid), so it's in memory
    /// when the card appears. Does nothing if it's already in memory or loading. Unlike a card's
    /// own load it isn't cancelled: it's for cards that don't exist yet.
    func prefetch(_ url: URL, pixels: CGSize, mode: ContentMode = .fill) {
        if let entry = memory.object(forKey: url as NSURL), Self.isLargeEnough(entry, for: pixels, mode: mode) { return }
        let key = LoadKey(url: url, width: Int(pixels.width.rounded(.up)), height: Int(pixels.height.rounded(.up)), fill: mode == .fill)
        guard locked({ loads[key] == nil }) else { return }
        Task.detached(priority: .utility) { [self] in
            _ = try? await self.image(url, pixels: pixels, mode: mode)
        }
    }

    /// Empties the decoded images (a memory warning; the files stay in `URLCache.images`).
    /// Returns how many bytes that freed.
    @discardableResult
    func removeAll() -> Int {
        let bytes = locked { stats.bytes }
        memory.removeAllObjects()
        return bytes
    }

    private func leave(_ key: LoadKey, _ load: Load, _ ticket: Ticket, cancel: Bool) {
        locked {
            guard !ticket.hasLeft else { return }
            ticket.hasLeft = true
            load.waiters -= 1
            guard load.waiters == 0 else { return }
            if loads[key] === load { loads[key] = nil }
            if cancel {
                load.task.cancel()
                stats.cancelled += 1
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Loading

    private func fetch(_ key: LoadKey) async throws -> UIImage {
        do {
            // Thumbnail URLs change when the picture does (YouTube signs them), so a stored copy
            // is used without asking the server again.
            let request = URLRequest(url: key.url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            let wasStored = urlCache.cachedResponse(for: request) != nil
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()
            let entry = try await decode(data, pixels: CGSize(width: key.width, height: key.height), fill: key.fill)
            // Two sizes of the same picture loading at once: keep the larger one.
            let kept = memory.object(forKey: key.url as NSURL)
            if kept == nil || !(kept!.isFullSize || kept!.image.size.width > entry.image.size.width) {
                memory.setObject(entry, forKey: key.url as NSURL, cost: entry.cost)
                locked { stats.bytes += entry.cost }
            }
            locked {
                stats.loaded += 1
                if !wasStored { stats.downloaded += 1 }
            }
            logStatsIfDue()
            return entry.image
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                locked { stats.failed += 1 }
                Self.log.info("image failed: \(key.url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// Decodes on `decodeQueue` (never the main thread), already scaled: ImageIO reads the JPEG
    /// or WebP straight into a bitmap of the requested size, so drawing it later costs nothing.
    private func decode(_ data: Data, pixels: CGSize, fill: Bool) async throws -> Entry {
        try await withCheckedThrowingContinuation { continuation in
            decodeQueue.addOperation {
                do {
                    continuation.resume(returning: try Self.downsample(data, pixels: pixels, fill: fill))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func downsample(_ data: Data, pixels: CGSize, fill: Bool) throws -> Entry {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        // EXIF orientations 5–8 are turned a quarter.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }
        let target = (width: Double(pixels.width), height: Double(pixels.height))
        let scale = fill ? max(target.width / width, target.height / height) : min(target.width / width, target.height / height)
        let isFullSize = scale >= 1 || target.width <= 0 || target.height <= 0
        let longSide = isFullSize ? max(width, height) : (max(width, height) * scale).rounded(.up)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return Entry(image: UIImage(cgImage: image), isFullSize: isFullSize, cost: image.bytesPerRow * image.height)
    }

    /// Large enough when drawing it at `pixels` enlarges it by at most 5%.
    private static func isLargeEnough(_ entry: Entry, for pixels: CGSize, mode: ContentMode) -> Bool {
        if entry.isFullSize { return true }
        let size = entry.image.size
        guard size.width > 0, size.height > 0 else { return false }
        let scale = mode == .fill
            ? max(pixels.width / size.width, pixels.height / size.height)
            : min(pixels.width / size.width, pixels.height / size.height)
        return scale <= 1.05
    }

    // MARK: - Stats

    /// At most every 10 s while images load: where the lists got their images since the last line.
    private func logStatsIfDue() {
        let line: String? = locked {
            guard Date().timeIntervalSince(lastStatsLog) >= 10, stats != loggedStats else { return nil }
            let s = stats
            let p = loggedStats
            lastStatsLog = Date()
            loggedStats = s
            let loaded = s.loaded - p.loaded
            let downloaded = s.downloaded - p.downloaded
            return "images: \(loaded) loaded (\(downloaded) downloaded, \(loaded - downloaded) from disk), "
                + "\(s.fromMemory - p.fromMemory) drawn from memory, \(s.cancelled - p.cancelled) cancelled, "
                + "\(s.failed - p.failed) failed; \(s.bytes / 1_048_576) MB decoded in memory"
        }
        if let line { Self.log.info("\(line, privacy: .public)") }
    }
}

/// NSCache tells its delegate (an NSObject) about evictions; this passes them on so the stats
/// line knows how much memory the decoded images take.
private final class EvictionCounter: NSObject, NSCacheDelegate, @unchecked Sendable {
    var onEvict: ((AnyObject) -> Void)?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        onEvict?(obj as AnyObject)
    }
}
