import AppKit
import SwiftUI

/// No artwork. A single line of `title • artist` on the left, controls on the
/// right. Tooltip-style glass. Smallest footprint of any built-in.
struct MinimTheme: OverlayTheme {
    nonisolated let id = "minim"
    nonisolated let displayName = "Minim"
    nonisolated let author = "Built-in"

    nonisolated let layout = LayoutSpec(
        orientation: .minimal,
        artworkSize: nil,
        controlsPosition: .beside,
        windowSize: CGSize(width: 360, height: 80),
        padding: 12,
        cornerRadius: 14
    )

    nonisolated let typography = TypographySpec(
        title: .init(font: .callout, weight: .semibold, opacity: 1.0),
        artist: .init(font: .callout, weight: .regular, opacity: 0.7),
        album: .init(font: .caption, weight: .regular, opacity: 0.55),
        showAlbum: false
    )

    nonisolated let behavior = BehaviorSpec(
        controlsAlwaysVisible: true,
        controlsHasBackground: false,
        glassMaterial: .toolTip,
        hasGlassBackground: true,
        shadowOpacity: 0.25
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(MinimBody(track: track, store: store, theme: self))
    }
}

private struct MinimBody: View {
    let track: TrackSnapshot
    let store: PlayerStore
    let theme: MinimTheme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(theme.typography.title.font)
                    .fontWeight(theme.typography.title.weight)
                    .opacity(theme.typography.title.opacity)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(track.artist)
                    .font(theme.typography.artist.font)
                    .fontWeight(theme.typography.artist.weight)
                    .opacity(theme.typography.artist.opacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
                },
                isFavorite: track.isFavorite,
                onToggleFavorite: {
                    Task { @MainActor in await store.toggleFavorite() }
                }
            )
        }
        .padding(theme.layout.padding)
    }
}
