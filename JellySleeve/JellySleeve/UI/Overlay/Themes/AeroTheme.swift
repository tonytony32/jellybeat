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
        glassMaterial: .underWindowBackground,
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
        VStack(spacing: 8) {
            ArtworkView(
                itemId: track.itemId,
                imageTag: track.imageTag,
                size: theme.layout.artworkSize ?? 260,
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
                    }
                )
                .padding(.bottom, 10)
            }
            .onHover { isHovering = $0 }

            TrackInfoView(track: track, typography: theme.typography)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            ProgressBarView(
                position: track.position,
                runtime: track.runtime,
                isPaused: store.isPaused
            )
        }
        .padding(theme.layout.padding)
    }
}
