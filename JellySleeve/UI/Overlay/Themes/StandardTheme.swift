import AppKit
import SwiftUI

/// Default theme: vertical, 200pt artwork, controls overlaid on the bottom
/// edge of the artwork on hover.
struct StandardTheme: OverlayTheme {
    nonisolated let id = "standard"
    nonisolated let displayName = "Standard"
    nonisolated let author = "Built-in"

    nonisolated let layout = LayoutSpec(
        orientation: .vertical,
        // Artwork fills the window edge-to-edge (window 280 minus padding 12*2).
        artworkSize: 256,
        controlsPosition: .overlayBottom,
        windowSize: CGSize(width: 280, height: 380),
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
        hasGlassBackground: true,
        shadowOpacity: 0.35
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(StandardBody(track: track, store: store, theme: self))
    }
}

/// Concrete `View` so we can keep `@State` (hover) and let SwiftUI handle the
/// fade naturally; `OverlayTheme.body` returns an `AnyView` and can't host
/// state directly.
private struct StandardBody: View {
    let track: TrackSnapshot
    let store: PlayerStore
    let theme: StandardTheme

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(
                itemId: track.itemId,
                imageTag: track.imageTag,
                size: theme.layout.artworkSize ?? 256,
                cornerRadius: 8,
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
                .padding(.bottom, 6)
            }
            .onHover { isHovering = $0 }

            TrackInfoView(track: track, typography: theme.typography)
                .frame(maxWidth: .infinity, alignment: .leading)

            ProgressBarView(
                trackKey: track.itemId,
                position: track.position,
                runtime: track.runtime,
                isPaused: store.isPaused,
                onSeek: { seconds in
                    Task { @MainActor in await store.seek(toSeconds: seconds) }
                }
            )
        }
        .padding(theme.layout.padding)
    }
}
