import AppKit
import SwiftUI

/// Compact now-playing pill. Default: album art + transport controls in a
/// slim 360 × 56 bar. Hover: the bar grows upward to reveal title, artist,
/// and a seekable progress bar above it.
struct MinimTheme: OverlayTheme {
    nonisolated let id = "minim"
    nonisolated let displayName = "Minim"
    nonisolated let author = "Built-in"

    /// Height of the fully expanded (hovering) window.
    nonisolated static let expandedHeight: CGFloat = 128

    nonisolated let layout = LayoutSpec(
        orientation: .minimal,
        artworkSize: nil,
        controlsPosition: .beside,
        windowSize: CGSize(width: 360, height: 56),
        padding: 10,
        cornerRadius: 14
    )

    nonisolated let typography = TypographySpec(
        title: .init(font: .callout, weight: .semibold, opacity: 1.0),
        artist: .init(font: .caption, weight: .regular, opacity: 0.7),
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
        VStack(spacing: 0) {
            // VStack order flips depending on which side of the screen the bar
            // is on. The compact bar is always pinned at the window edge that
            // stays fixed during the resize; the info section fills the newly
            // revealed space on the other side.
            if store.minimGrowsUpward {
                infoSection   // grows into space above the bar
                compactBar
            } else {
                compactBar
                infoSection   // grows into space below the bar
            }
        }
        .onHover { store.minimHovered = $0 }
    }

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(theme.typography.title.font)
                .fontWeight(theme.typography.title.weight)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(track.artist)
                .font(theme.typography.artist.font)
                .fontWeight(theme.typography.artist.weight)
                .opacity(theme.typography.artist.opacity)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Text(formattedTime(track.position))
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.5)

                ProgressBarView(
                    trackKey: track.itemId,
                    position: track.position,
                    runtime: track.runtime,
                    isPaused: store.isPaused,
                    onSeek: { seconds in
                        Task { @MainActor in await store.seek(toSeconds: seconds) }
                    }
                )

                Text(formattedTime(track.runtime))
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var compactBar: some View {
        HStack(spacing: 10) {
            ArtworkView(
                itemId: track.artworkItemId,
                imageTag: track.imageTag,
                size: 36,
                cornerRadius: 6,
                shadowOpacity: 0,
                artworkURL: track.artworkURL,
                canFocusTab: store.capabilities.canFocusTab,
                onFocus: { Task { @MainActor in await store.focusSource() } }
            )

            Spacer()

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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 56)
    }

    private func formattedTime(_ duration: Duration) -> String {
        let totalSeconds = max(0, duration.components.seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
