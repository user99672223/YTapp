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
        /// Between a card's artwork, lifted by focus, and its title. Unfocused, the title sits
        /// `Layout.focusOverflow` lower, so the lifted card never covers it and nothing moves.
        static let cardToText: CGFloat = 14
        /// Between lines of text under a card.
        static let textLines: CGFloat = 4
        /// Between rows of a list or panel.
        static let row: CGFloat = 20
        /// Inner padding of side panels.
        static let panel: CGFloat = 48
        /// Between a badge (duration, LIVE, a playlist's size) and the edges of its artwork.
        static let badgeInset: CGFloat = 10
        /// Inner padding of banners and toasts.
        static let floating: CGFloat = 28
    }

    /// Width of the trailing side panels over a playing video (comments, info, captions, …).
    static let panelWidth: CGFloat = 760

    /// Longest line of a centred message (errors, empty lists, banners): about 60 characters of
    /// body text, so it reads as a paragraph rather than one line across the whole TV.
    static let messageWidth: CGFloat = 1000

    /// The big symbol above an error or an empty list: the one place text-free SF Symbols take a
    /// fixed size, since no text style is that large.
    static let heroSymbolSize: CGFloat = 80
}

extension View {
    /// Clips to a rounded rectangle with continuous (squircle) corners, like the system's own.
    func continuousCorners(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
