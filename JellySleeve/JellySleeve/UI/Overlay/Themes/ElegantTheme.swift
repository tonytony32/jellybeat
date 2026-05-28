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
        controlsHasBackground: true,
        glassMaterial: .hudWindow,
        shadowOpacity: 0.35
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(ElegantBody(track: track, store: store, theme: self))
    }
}

/// Concrete `View` so we can keep `@State` (hover) and let SwiftUI handle the
/// fade naturally; `OverlayTheme.body` returns an `AnyView` and can't host
/// state directly.
private struct ElegantBody: View {
    let track: TrackSnapshot
    let store: PlayerStore
    let theme: ElegantTheme

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(
                itemId: track.itemId,
                imageTag: track.imageTag,
                size: theme.layout.artworkSize ?? 200,
                cornerRadius: 8,
                shadowOpacity: theme.behavior.shadowOpacity
            )
            .overlay(alignment: .bottom) {
                ControlsView(
                    isPaused: store.isPaused,
                    isCommandInFlight: store.isCommandInFlight,
                    behavior: theme.behavior,
                    isVisible: isHovering,
                    action: { action in
                        Task { @MainActor in
                            switch action {
                            case .previous: await store.previousTrack()
                            case .playPause: await store.playPause()
                            case .next: await store.nextTrack()
                            }
                        }
                    }
                )
                .padding(.bottom, 6)
            }
            // Hover anywhere on the artwork region reveals the controls,
            // not just the buttons themselves.
            .onHover { isHovering = $0 }

            TrackInfoView(track: track, typography: theme.typography)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.layout.padding)
    }
}
