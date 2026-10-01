import Foundation
import ImageIO
import SwiftUI
import UIKit

/// What a Short's poster tells the player before its video is known: the dark colour the screen
/// behind it takes (like YouTube's own TV app, which tints the Shorts player with the video's
/// colour) and the poster's shape, which is the Short's (9:16, 4:5, square).
struct ShortsSwatch: Equatable, Sendable {
    /// The background colour, already darkened (sRGB, 0…1).
    var red: Double
    var green: Double
    var blue: Double
    /// Width / height of the poster; nil when it came from a fallback thumbnail (16:9 with bars),
    /// which says nothing about the Short's shape.
    var aspectRatio: Double?

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Before any poster is known: near black with a hint of warmth.
    static let neutral = ShortsSwatch(red: 0.07, green: 0.07, blue: 0.08, aspectRatio: nil)
}

/// Works out the swatches of the Shorts around the current one, off the main thread, once per id.
///
/// The poster's bytes come from `URLCache.images` (the player warms the next posters into it);
/// ImageIO decodes a thumbnail of at most 24 pixels straight from the JPEG, and the colour is the
/// average of that, weighted towards its colourful pixels, then darkened.
@MainActor
final class ShortsPalette: ObservableObject {
    @Published private(set) var swatches: [String: ShortsSwatch] = [:]
    /// The ids in `swatches`, oldest first.
    private var order: [String] = []
    private var running: Set<String> = []
    /// Ids whose poster couldn't be read: not asked again in this session of the player.
    private var failed: Set<String> = []
    /// Ids whose poster and fallback both couldn't be read.
    private var gaveUp: Set<String> = []

    func swatch(for id: String?) -> ShortsSwatch? {
        id.flatMap { swatches[$0] }
    }

    /// Starts the swatch of `id` from its poster, or from `fallback` (the details' thumbnail) when
    /// the poster can't be read.
    func load(id: String, poster: URL?, fallback: URL?) {
        guard swatches[id] == nil, !running.contains(id), !gaveUp.contains(id) else { return }
        if failed.contains(id), fallback == nil { return }
        let usePoster = !failed.contains(id)
        guard let url = usePoster ? poster : fallback else { return }
        running.insert(id)
        Task {
            let result = await Task.detached(priority: .utility) {
                await Self.analyse(url, keepsShape: usePoster)
            }.value
            running.remove(id)
            if let result {
                swatches[id] = result
                order.append(id)
                trim()
            } else if usePoster {
                failed.insert(id)
                if let fallback { load(id: id, poster: nil, fallback: fallback) }
            } else {
                gaveUp.insert(id)
            }
        }
    }

    /// An endless feed would otherwise keep a swatch per Short for the whole session.
    private func trim() {
        while order.count > 40 {
            swatches[order.removeFirst()] = nil
        }
    }

    // MARK: - Analysis (off the main thread)

    nonisolated private static func analyse(_ url: URL, keepsShape: Bool) async -> ShortsSwatch? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        let data: Data
        if let stored = URLCache.images.cachedResponse(for: request) {
            data = stored.data
        } else {
            guard let loaded = try? await URLSession.shared.data(for: request) else { return nil }
            if let http = loaded.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            data = loaded.0
        }
        return swatch(from: data, keepsShape: keepsShape)
    }

    nonisolated private static func swatch(from data: Data, keepsShape: Bool) -> ShortsSwatch? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 24,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let average = averageColor(of: thumbnail) else { return nil }
        let (red, green, blue) = darkened(average.0, average.1, average.2)
        return ShortsSwatch(red: red, green: green, blue: blue, aspectRatio: keepsShape ? width / height : nil)
    }

    /// The average colour, each pixel weighted by how colourful it is, so a Short's colour wins
    /// over its black bars, white captions and grey sky.
    nonisolated private static func averageColor(of image: CGImage) -> (Double, Double, Double)? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sum = (r: 0.0, g: 0.0, b: 0.0, weight: 0.0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) / high : 0
            // Near-black and near-white pixels (bars, captions) count little.
            let lightness = high < 0.08 || low > 0.92 ? 0.15 : 1.0
            let weight = (0.2 + saturation) * lightness
            sum.r += r * weight
            sum.g += g * weight
            sum.b += b * weight
            sum.weight += weight
        }
        guard sum.weight > 0 else { return nil }
        return (sum.r / sum.weight, sum.g / sum.weight, sum.b / sum.weight)
    }

    /// The colour as a dark background: the hue kept, the brightness brought down to about a
    /// sixth (a little lighter for a strongly coloured Short), so white text always reads on it.
    nonisolated private static func darkened(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b)
        guard high > 0.001 else { return (0.07, 0.07, 0.08) }
        let saturation = (high - low) / high
        let brightness = 0.10 + 0.12 * saturation
        let newSaturation = min(0.85, saturation * 1.15)
        // Scale the colour to the new brightness, then pull it towards grey to the new saturation.
        let scale = brightness / high
        func channel(_ value: Double) -> Double {
            let scaled = value * scale
            guard saturation > 0.001 else { return brightness }
            let grey = brightness
            let t = newSaturation / saturation
            return min(1, max(0, grey + (scaled - grey) * t))
        }
        return (channel(r), channel(g), channel(b))
    }
}

/// A Short's poster drawn through `ImagePipeline` (decoded off the main thread at the size it is
/// shown, kept in memory), so a page that slides in draws its picture in its first frame. When
/// the vertical poster can't be loaded, the thumbnail from the Short's details is used.
struct ShortsPosterImage: View {
    let url: URL?
    let fallback: URL?
    let size: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, image: UIImage)?
    @State private var posterFailed = false

    init(url: URL?, fallback: URL?, size: CGSize) {
        self.url = url
        self.fallback = fallback
        self.size = size
    }

    private var pixels: CGSize {
        CGSize(width: (size.width * displayScale).rounded(.up), height: (size.height * displayScale).rounded(.up))
    }

    private var source: URL? { posterFailed ? fallback : url }

    private var image: UIImage? {
        if let loaded, loaded.url == source { return loaded.image }
        guard let source, size.width > 0, size.height > 0 else { return nil }
        return ImagePipeline.shared.cachedImage(source, pixels: pixels, mode: .fill, counts: false)
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source, size.width > 0, size.height > 0 else { return }
        do {
            let image = try await ImagePipeline.shared.image(source, pixels: pixels, mode: .fill)
            guard !Task.isCancelled else { return }
            loaded = (source, image)
        } catch {
            if !Task.isCancelled, source == url { posterFailed = true }
        }
    }
}
