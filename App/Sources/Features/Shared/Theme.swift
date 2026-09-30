import SwiftUI

/// The app's shared look, following Apple's tvOS Human Interface Guidelines: the system font in
/// the standard text styles (`.title`, `.headline`, `.callout`, `.caption`, …, never fixed point
/// sizes for text), continuous corner radii, and one set of spacings. Focus effects come from the
/// system button styles (`.card` for artwork, `.bordered`/default for buttons), not custom ones.
enum Theme {
    /// Continuous corner radii (use with `RoundedRectangle(cornerRadius:style: .continuous)` or
    /// `View.continuousCorners(_:)`).
    enum Radius {
        /// Video, playlist and Short artwork (matches the `.card` button style's own rounding).
        static let card: CGFloat = 12
        /// Small artwork inside rows: chapter and up-next thumbnails, comment media.
        static let thumbnail: CGFloat = 8
        /// Duration/LIVE badges on artwork.
        static let badge: CGFloat = 6
        /// The Shorts player's 9:16 frame.
        static let player: CGFloat = 32
        /// Side panels and floating sheets (comments, captions, speed, quality).
        static let panel: CGFloat = 40
        /// Banners, toasts and loading boxes.
        static let floating: CGFloat = 24
    }

    /// Spacing in points. tvOS already keeps content out of its 60/80-point safe area; these are
    /// the gaps inside it.
    enum Spacing {
        /// Between a section title and its content.
        static let titleToContent: CGFloat = 24
        /// Between sections of a screen.
        static let section: CGFloat = 60
        /// Between the artwork of a card and its title.
        static let cardToText: CGFloat = 14
        /// Between lines of text under a card.
        static let textLines: CGFloat = 4
        /// Between rows of a list or panel.
        static let row: CGFloat = 20
        /// Inner padding of side panels.
        static let panel: CGFloat = 48
    }

    /// Width of the trailing side panels over a playing video (comments, info, captions, …).
    static let panelWidth: CGFloat = 760
}

extension View {
    /// Clips to a rounded rectangle with continuous (squircle) corners, like the system's own.
    func continuousCorners(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
