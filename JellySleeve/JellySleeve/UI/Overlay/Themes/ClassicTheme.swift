import AppKit
import SwiftUI

/// Horizontal layout. Square 120pt artwork on the left, info stack on the
/// right, compact controls beneath the info. Always-on controls because the
/// design is busy enough to read at a glance.
struct ClassicTheme: OverlayTheme {
    nonisolated let id = "classic"
    nonisolated let displayName = "Classic"
    nonisolated let author = "Built-in"

    nonisolated let layout = LayoutSpec(
        orientation: .horizontal,
        artworkSize: 120,
        controlsPosition: .below,
        windowSize: CGSize(width: 380, height: 140),
        padding: 10,
        cornerRadius: 14
    )

    nonisolated let typography = TypographySpec(
        title: .init(font: .body, weight: .semibold, opacity: 1.0),
        artist: .init(font: .callout, weight: .regular, opacity: 0.85),
        album: .init(font: .caption, weight: .regular, opacity: 0.65),
        showAlbum: true
    )

    nonisolated let behavior = BehaviorSpec(
        controlsAlwaysVisible: true,
        controlsHasBackground: false,
        glassMaterial: .hudWindow,
        shadowOpacity: 0.35
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(ClassicBody(track: track, store: store, theme: self))
    }
}

private struct ClassicBody: View {
    let track: TrackSnapshot
    let store: PlayerStore
    let theme: ClassicTheme

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(
                itemId: track.itemId,
                imageTag: track.imageTag,
                size: theme.layout.artworkSize ?? 120,
                cornerRadius: 6,
                shadowOpacity: theme.behavior.shadowOpacity
            )

            VStack(alignment: .leading, spacing: 4) {
                TrackInfoView(track: track, typography: theme.typography)

                ProgressBarView(
                    position: track.position,
                    runtime: track.runtime,
                    isPaused: store.isPaused
                )
                .padding(.top, 2)

                Spacer(minLength: 0)

                ControlsView(
                    isPaused: store.isPaused,
                    isCommandInFlight: store.isCommandInFlight,
                    behavior: theme.behavior,
                    isVisible: true,
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(theme.layout.padding)
    }
}
