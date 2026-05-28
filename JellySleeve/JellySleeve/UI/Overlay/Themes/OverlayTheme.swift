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

nonisolated struct BehaviorSpec: Equatable, Sendable {
    let controlsAlwaysVisible: Bool
    let glassMaterial: NSVisualEffectView.Material
    let shadowOpacity: Double
}
