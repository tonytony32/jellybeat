import AppKit
import SwiftUI

/// Compact now-playing strip. Default: a slim bar — album art, transport
/// controls, volume. On hover it unfolds (toward the screen interior) to add
/// title, artist, and a seekable progress scrubber above (or below) the strip.
struct MinimTheme: OverlayTheme {
    nonisolated let id = "minim"
    nonisolated let displayName = "Minim"
    nonisolated let author = "Built-in"

    /// Fixed heights. The window is `barHeight` when collapsed and
    /// `barHeight + infoHeight` (== `expandedHeight`) when hovered; the info
    /// section is given exactly `infoHeight` so the reveal is deterministic
    /// rather than relying on intrinsic-size overflow.
    nonisolated static let barHeight: CGFloat = 52
    nonisolated static let infoHeight: CGFloat = 78
    nonisolated static let expandedHeight: CGFloat = barHeight + infoHeight

    nonisolated let layout = LayoutSpec(
        orientation: .minimal,
        artworkSize: nil,
        controlsPosition: .beside,
        windowSize: CGSize(width: 360, height: MinimTheme.barHeight),
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

    /// Volume level captured before a click-to-mute, restored on the next click.
    @State private var volumeBeforeMute: Int?

    var body: some View {
        VStack(spacing: 0) {
            // The info section is laid out at a fixed height and the bar is
            // pinned to the window's anchored edge (bottom when the strip grows
            // upward, top when it grows downward). While collapsed the window is
            // only `barHeight` tall, so the info section sits beyond the edge
            // and is clipped by the window's rounded rect; as the window grows
            // it scrolls into view.
            if store.minimGrowsUpward {
                infoSection
                compactBar
            } else {
                compactBar
                infoSection
            }
        }
        .frame(
            maxHeight: .infinity,
            alignment: store.minimGrowsUpward ? .bottom : .top
        )
        .onHover { store.minimHovered = $0 }
    }

    // MARK: - Compact bar

    private var compactBar: some View {
        HStack(spacing: 8) {
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

            Spacer(minLength: 0)

            // Transport only — favorite/queue live in the expanded section.
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
                onToggleFavorite: {},
                showsFavorite: false,
                showsQueue: false
            )

            Spacer(minLength: 0)

            if store.capabilities.canSetVolume {
                volumeButton
            }
        }
        .padding(.horizontal, 14)
        .frame(height: MinimTheme.barHeight)
    }

    /// Speaker glyph reflecting the current level. Click toggles mute; the
    /// overlay's scroll-to-change-volume still works for fine adjustment.
    private var volumeButton: some View {
        Button {
            if store.volume > 0 {
                volumeBeforeMute = store.volume
                store.nudgeVolume(by: -store.volume)
            } else {
                store.nudgeVolume(by: volumeBeforeMute ?? 100)
                volumeBeforeMute = nil
            }
        } label: {
            Image(systemName: speakerSymbol(for: store.volume))
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22, height: 24)
                .contentTransition(.symbolEffect(.replace))
                .overlayHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.volume > 0
            ? String(localized: "Mute")
            : String(localized: "Unmute"))
        .focusEffectDisabled()
    }

    private func speakerSymbol(for level: Int) -> String {
        switch level {
        case ...0: return "speaker.slash.fill"
        case 1...33: return "speaker.wave.1.fill"
        case 34...66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    // MARK: - Expanded info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
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
                }

                Spacer(minLength: 0)

                // Favorite + queue only (transport lives in the bar).
                ControlsView(
                    isPaused: store.isPaused,
                    isCommandInFlight: store.isCommandInFlight,
                    behavior: theme.behavior,
                    isVisible: true,
                    flashedAction: nil,
                    action: { _ in },
                    isFavorite: track.isFavorite,
                    onToggleFavorite: {
                        Task { @MainActor in await store.toggleFavorite() }
                    },
                    showsTransport: false
                )
            }

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
                    onSeek: store.capabilities.canSeek
                        ? { seconds in Task { @MainActor in await store.seek(toSeconds: seconds) } }
                        : nil
                )

                Text(formattedTime(track.runtime))
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .frame(height: MinimTheme.infoHeight)
    }

    private func formattedTime(_ duration: Duration) -> String {
        let totalSeconds = max(0, duration.components.seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
