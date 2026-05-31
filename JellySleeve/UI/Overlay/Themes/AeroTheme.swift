import AppKit
import SwiftUI

/// Artwork-forward. 260pt cover dominates, controls are overlaid on the lower
/// quarter with an intense backdrop blur. Info sits below the artwork.
struct AeroTheme: OverlayTheme {
    nonisolated let id = "aero"
    nonisolated let displayName = "Aero"
    nonisolated let author = "Built-in"

    nonisolated let layout = LayoutSpec(
        orientation: .vertical,
        artworkSize: 260,
        controlsPosition: .overlayBottom,
        windowSize: CGSize(width: 300, height: 420),
        padding: 14,
        cornerRadius: 22
    )

    nonisolated let typography = TypographySpec(
        title: .init(font: .title3, weight: .bold, opacity: 1.0),
        artist: .init(font: .callout, weight: .medium, opacity: 0.9),
        album: .init(font: .caption, weight: .regular, opacity: 0.7),
        showAlbum: true
    )

    nonisolated let behavior = BehaviorSpec(
        controlsAlwaysVisible: false,
        controlsHasBackground: true,
        // Aero turns off the glass frame so only the artwork and its
        // floating controls sit on the desktop.
        glassMaterial: .underWindowBackground,
        hasGlassBackground: false,
        shadowOpacity: 0.45
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(AeroBody(track: track, store: store, theme: self))
    }
}

private struct AeroBody: View {
    let track: TrackSnapshot
    let store: PlayerStore
    let theme: AeroTheme

    @State private var isHovering = false

    var body: some View {
        let artworkSize = theme.layout.artworkSize ?? 260

        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(
                itemId: track.itemId,
                imageTag: track.imageTag,
                size: artworkSize,
                cornerRadius: 14,
                shadowOpacity: theme.behavior.shadowOpacity
            )
            .overlay(alignment: .bottom) {
                ControlsView(
                    isPaused: store.isPaused,
                    isCommandInFlight: store.isCommandInFlight,
                    behavior: theme.behavior,
                    isVisible: isHovering || store.commandFeedback != nil,
                    flashedAction: store.commandFeedback,
                    action: { action in
                        Task { @MainActor in
                            switch action {
                            case .previous: await store.previousTrack()
                            case .playPause: await store.playPause()
                            case .next: await store.nextTrack()
                            }
                        }
                    },
                    isFavorite: track.isFavorite,
                    onToggleFavorite: {
                        Task { @MainActor in await store.toggleFavorite() }
                    }
                )
                .padding(.bottom, 10)
            }
            .onHover { isHovering = $0 }

            TrackInfoView(track: track, typography: theme.typography)
                .frame(width: artworkSize, alignment: .leading)
                .multilineTextAlignment(.leading)

            ProgressBarView(
                trackKey: track.itemId,
                position: track.position,
                runtime: track.runtime,
                isPaused: store.isPaused,
                onSeek: { seconds in
                    Task { @MainActor in await store.seek(toSeconds: seconds) }
                }
            )
            .frame(width: artworkSize)
        }
        // Left-align the whole column inside the window so the artwork sits
        // flush with the leading padding instead of being centred.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.layout.padding)
        // Aero floats over the desktop, so the text is always rendered on
        // an unpredictable background. Lock it to "dark mode" rendering so
        // `.primary` reads as white and stays legible over album artwork.
        .colorScheme(.dark)
    }
}
