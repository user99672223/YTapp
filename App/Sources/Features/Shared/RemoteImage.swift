import SwiftUI
import UIKit

/// Remote artwork with a neutral placeholder, loaded through `ImagePipeline` at the pixel size it
/// is shown at. An image that is already in memory is drawn in the view's first frame, with no
/// placeholder and no fade, so cards that a lazy grid re-creates while scrolling back look as if
/// they had never left. Only an image that had to be fetched fades in, and only when its
/// placeholder was on screen long enough to be seen.
///
/// Takes the size it is offered (callers give it a frame and clip it), like the placeholder of
/// `AsyncImage` did; with `.fill` the picture covers that size and overflows it evenly.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        GeometryReader { geo in
            RemoteImageContent(url: url, contentMode: contentMode, size: geo.size)
        }
    }
}

private struct RemoteImageContent: View {
    let url: URL?
    let contentMode: ContentMode
    let size: CGSize
    @Environment(\.displayScale) private var displayScale
    /// The image on screen, held here too so it stays even if the pipeline's cache drops it.
    @State private var shown: Shown?
    @State private var failedURL: URL?

    init(url: URL?, contentMode: ContentMode, size: CGSize) {
        self.url = url
        self.contentMode = contentMode
        self.size = size
    }

    private struct Shown {
        let url: URL
        let image: UIImage
    }

    /// What a load is for; a new URL or a new size (in pixels) loads again.
    private struct Request: Equatable {
        let url: URL?
        let width: Int
        let height: Int
    }

    private var pixels: CGSize {
        CGSize(width: (size.width * displayScale).rounded(.up), height: (size.height * displayScale).rounded(.up))
    }

    /// The image to draw now: the one loaded for this URL, else one the pipeline already has.
    /// A smaller one loaded for the same URL stays up while a larger one loads (no placeholder).
    private var image: UIImage? {
        if let shown, shown.url == url { return shown.image }
        guard let url, size.width > 0, size.height > 0 else { return nil }
        // Not counted as a draw here: `load()` counts it, once per appearance.
        return ImagePipeline.shared.cachedImage(url, pixels: pixels, mode: contentMode, counts: false)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.white.opacity(0.08)
                    .overlay {
                        if let failedURL, failedURL == url {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: Request(url: url, width: Int(pixels.width), height: Int(pixels.height))) {
            await load()
        }
    }

    private func load() async {
        guard let url, size.width > 0, size.height > 0 else { return }
        if let cached = ImagePipeline.shared.cachedImage(url, pixels: pixels, mode: contentMode) {
            // Already drawn from the cache in the first frame; keep it.
            shown = Shown(url: url, image: cached)
            return
        }
        let started = Date()
        do {
            let loaded = try await ImagePipeline.shared.image(url, pixels: pixels, mode: contentMode)
            guard !Task.isCancelled else { return }
            failedURL = nil
            if shown?.url == url || Date().timeIntervalSince(started) < 0.1 {
                // A sharper copy of what's shown, or fast enough that no placeholder was seen.
                shown = Shown(url: url, image: loaded)
            } else {
                withAnimation(.easeOut(duration: 0.2)) { shown = Shown(url: url, image: loaded) }
            }
        } catch {
            // A card that leaves the screen cancels its load; that's not a failure. It retries
            // when it comes back.
            if !Task.isCancelled { failedURL = url }
        }
    }
}
