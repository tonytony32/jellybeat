import AppKit
import SwiftUI

/// Default theme: vertical, 200pt artwork, controls overlaid on the bottom
/// edge of the artwork on hover. Specs from plan §6 Fase 4.
struct ElegantTheme: OverlayTheme {
    nonisolated let id = "elegant"
    nonisolated let displayName = "Elegant"
    nonisolated let author = "Built-in"

    nonisolated let layout = LayoutSpec(
        orientation: .vertical,
        artworkSize: 200,
        controlsPosition: .overlayBottom,
        windowSize: CGSize(width: 280, height: 360),
        padding: 12,
        cornerRadius: 18
    )

    nonisolated let typography = TypographySpec(
        title: .init(font: .title3, weight: .semibold, opacity: 1.0),
        artist: .init(font: .callout, weight: .regular, opacity: 0.85),
        album: .init(font: .caption, weight: .regular, opacity: 0.65),
        showAlbum: true
    )

    nonisolated let behavior = BehaviorSpec(
        controlsAlwaysVisible: false,
        glassMaterial: .hudWindow,
        shadowOpacity: 0.35
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(
            VStack(spacing: 10) {
                ArtworkView(
                    itemId: track.itemId,
                    imageTag: track.imageTag,
                    size: layout.artworkSize ?? 200,
                    cornerRadius: 8,
                    shadowOpacity: behavior.shadowOpacity
                )
                .overlay(alignment: .bottom) {
                    ControlsView(
                        isPaused: store.isPaused,
                        isCommandInFlight: store.isCommandInFlight,
                        behavior: behavior,
                        action: { _ in /* Fase 5 */ }
                    )
                    .padding(.bottom, 6)
                }

                TrackInfoView(track: track, typography: typography)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(layout.padding)
        )
    }
}
