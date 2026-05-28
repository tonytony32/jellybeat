import AppKit
import SwiftUI

/// Vertical, artwork 220pt on top, info + controls stacked below. Controls
/// always visible because they are part of the stack rather than overlaid.
struct StackTheme: OverlayTheme {
    nonisolated let id = "stack"
    nonisolated let displayName = "Stack"
    nonisolated let author = "Built-in"

    nonisolated let layout = LayoutSpec(
        orientation: .vertical,
        artworkSize: 220,
        controlsPosition: .below,
        windowSize: CGSize(width: 260, height: 400),
        padding: 14,
        cornerRadius: 18
    )

    nonisolated let typography = TypographySpec(
        title: .init(font: .headline, weight: .semibold, opacity: 1.0),
        artist: .init(font: .subheadline, weight: .regular, opacity: 0.85),
        album: .init(font: .caption, weight: .regular, opacity: 0.65),
        showAlbum: true
    )

    nonisolated let behavior = BehaviorSpec(
        controlsAlwaysVisible: true,
        controlsHasBackground: false,
        glassMaterial: .popover,
        shadowOpacity: 0.30
    )

    func body(track: TrackSnapshot, store: PlayerStore) -> AnyView {
        AnyView(StackBody(track: track, store: store, theme: self))
    }
}

private struct StackBody: View {
    let track: TrackSnapshot
    let store: PlayerStore
    let theme: StackTheme

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(
                itemId: track.itemId,
                imageTag: track.imageTag,
                size: theme.layout.artworkSize ?? 220,
                cornerRadius: 10,
                shadowOpacity: theme.behavior.shadowOpacity
            )

            TrackInfoView(track: track, typography: theme.typography)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

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
        }
        .padding(theme.layout.padding)
    }
}
