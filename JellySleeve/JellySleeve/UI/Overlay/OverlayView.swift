import SwiftUI

/// Root view rendered inside the borderless `NSWindow` created by
/// `AppDelegate`. Observes `ThemeRegistry.current` and delegates real-track
/// rendering to the theme's `body(track:store:)`. The special states (idle /
/// error / nothing playing) are handled here so every theme inherits them
/// without re-implementing.
struct OverlayView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(ThemeRegistry.self) private var themes
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            GlassBackground(material: themes.current.behavior.glassMaterial)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ConnectionDotView(state: player.connectionState)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .onTapGesture {
                    if case .error = player.connectionState {
                        openSettings()
                    }
                }
            TransientToastView(message: player.transientMessage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: themes.current.layout.cornerRadius,
                style: .continuous
            )
        )
        .animation(.easeInOut(duration: 0.25), value: player.transientMessage)
    }

    @ViewBuilder
    private var content: some View {
        switch player.connectionState {
        case .idle:
            IdleStateView(openSettings: openSettings)
        case .error(let message):
            ErrorStateView(message: message, openSettings: openSettings)
        case .connecting, .connected:
            if let track = player.currentTrack {
                themes.current.body(track: track, store: player)
                    // Anchor identity on (theme, itemId) so SwiftUI preserves
                    // internal @State (hover, cached NSImage) across the
                    // continuous stream of TrackSnapshots a single song
                    // produces. When the song or theme changes, the id
                    // changes and the inner state resets, letting the
                    // ArtworkView fade between the old and new artwork.
                    .id("\(themes.current.id)_\(track.itemId)")
                    .transition(.opacity)
            } else {
                NothingPlayingView()
            }
        }
    }
}

// MARK: - Universal special states

private struct IdleStateView: View {
    let openSettings: OpenSettingsAction

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Configure your Jellyfin server")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }
}

private struct ErrorStateView: View {
    let message: String
    let openSettings: OpenSettingsAction

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.bordered)
        }
        .padding(16)
    }
}

/// 2-second toast surfaced when a playback command fails (plan §6 Fase 5).
private struct TransientToastView: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct NothingPlayingView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "pause.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing playing")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
