import AppKit
import SwiftUI

/// Contract for an overlay layout preset. Themes are layout presets, not
/// cosmetic skins (plan §3bis): switching themes changes the view tree, the
/// window size, and the typographic scale.
@MainActor
protocol OverlayTheme: Identifiable, Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var author: String { get }
    nonisolated var layout: LayoutSpec { get }
    nonisolated var typography: TypographySpec { get }
    nonisolated var behavior: BehaviorSpec { get }

    /// Build the theme's body for a given track. Themes receive the
    /// `PlayerStore` so they can hook controls and other interactive bits
    /// directly. Idle / error / nothing-playing states are handled centrally
    /// in `OverlayView`, so themes can assume a real track.
    @ViewBuilder
    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView
}

// MARK: - Specs

nonisolated struct LayoutSpec: Equatable, Sendable {
    enum Orientation: Sendable { case vertical, horizontal, minimal }
    enum ControlsPosition: Sendable {
        case below
        case overlayBottom
        case hidden
        case beside
    }

    let orientation: Orientation
    /// nil disables the artwork view (used by Minim).
    let artworkSize: CGFloat?
    let controlsPosition: ControlsPosition
    let windowSize: CGSize
    let padding: CGFloat
    let cornerRadius: CGFloat
}

nonisolated struct TypographySpec: Equatable, Sendable {
    struct LineStyle: Equatable, Sendable {
        let font: Font
        let weight: Font.Weight
        let opacity: Double
    }

    let title: LineStyle
    let artist: LineStyle
    let album: LineStyle
    let showAlbum: Bool
}

extension OverlayTheme {
    /// Where the artwork sits inside the window when rendered at full size,
    /// in window coordinates (origin bottom-left). Used by `AppDelegate` to
    /// reposition the borderless window when entering/leaving ambient idle
    /// mode so the artwork stays pinned to the same pixel on screen.
    ///
    /// Returns `nil` for themes without an artwork (Minim) — those skip the
    /// shrink-on-idle transition.
    nonisolated var artworkFrame: CGRect? {
        guard let artSize = layout.artworkSize else { return nil }
        switch layout.orientation {
        case .vertical:
            // Centered horizontally, top-aligned with padding.
            let x = (layout.windowSize.width - artSize) / 2
            let yFromBottom = layout.windowSize.height - layout.padding - artSize
            return CGRect(x: x, y: yFromBottom, width: artSize, height: artSize)
        case .horizontal:
            // Left-aligned, vertically centered.
            let x = layout.padding
            let yFromBottom = (layout.windowSize.height - artSize) / 2
            return CGRect(x: x, y: yFromBottom, width: artSize, height: artSize)
        case .minimal:
            return nil
        }
    }
}

nonisolated struct BehaviorSpec: Equatable, Sendable {
    let controlsAlwaysVisible: Bool
    /// Whether to wrap the transport controls in a translucent capsule.
    /// Useful when the controls float over artwork (Elegant, Aero) and need a
    /// visual container; out of place when they're part of the layout
    /// (Stack, Classic, Minim).
    let controlsHasBackground: Bool
    let glassMaterial: NSVisualEffectView.Material
    let shadowOpacity: Double
}
