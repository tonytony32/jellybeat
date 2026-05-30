import AppKit
import SwiftUI

/// Root view rendered inside the borderless `NSWindow` created by
/// `AppDelegate`. Observes `ThemeRegistry.current` and delegates real-track
/// rendering to the theme's `body(track:store:)`. The special states (idle /
/// error / nothing playing) are handled here so every theme inherits them
/// without re-implementing.
struct OverlayView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(ThemeRegistry.self) private var themes
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

    /// Drives the cross-fade from "invisible square" to "interactive overlay"
    /// while in ambient idle mode. Lifted to this level so the GlassBackground
    /// and contents fade together.
    @State private var ambientHover: Bool = false

    private var isAmbient: Bool {
        if case .connected = player.connectionState, player.currentTrack == nil {
            return true
        }
        return false
    }

    private var chromeOpacity: Double {
        if !isAmbient { return 1.0 }
        return (ambientHover || player.anticipating) ? 1.0 : 0.0
    }

    var body: some View {
        ZStack {
            if themes.current.behavior.hasGlassBackground {
                GlassBackground(material: themes.current.behavior.glassMaterial)
                    .opacity(chromeOpacity)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .animation(.easeInOut(duration: 0.25), value: ambientHover)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: player.commandFeedback)
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
                    // Anchor identity on the theme only. We deliberately do
                    // NOT include track.itemId here: keeping the same
                    // identity across track changes lets ArtworkView hold on
                    // to the previous NSImage while fetching the new one, so
                    // the user sees a clean cross-fade instead of a
                    // placeholder flash between songs. Identity still flips
                    // on theme change so the inner state resets cleanly when
                    // the layout changes.
                    .id(themes.current.id)
                    .transition(.opacity)
            } else {
                NothingPlayingView(
                    launchURL: settings.baseURL,
                    isHovering: $ambientHover,
                    onLaunch: { player.markAnticipating() }
                )
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

/// Ambient idle state: the window shrinks to artwork-size (see
/// `AppDelegate.applyWindowSizeForCurrentState`) and shows a large Jellyfin
/// logo as a launch affordance. The logo stays visible at all times but at a
/// subtle, low opacity; hovering brings it to full strength (and the
/// surrounding glass fades in via `chromeOpacity`). Tapping launches the
/// configured Jellyfin URL via `NSWorkspace.open`, which on macOS picks the
/// user's chosen handler — useful when the user has registered a Safari
/// "Add to Dock" web app for the Jellyfin URL.
private struct NothingPlayingView: View {
    let launchURL: URL?
    @Binding var isHovering: Bool
    let onLaunch: () -> Void

    var body: some View {
        GeometryReader { geo in
            // Scale the logo to the ambient window so it reads as "a bigger
            // icon" across themes whose artwork sizes differ (Classic 120 →
            // Standard/Aero ~256).
            let side = min(geo.size.width, geo.size.height) * 0.5

            ZStack {
                Color.clear.contentShape(Rectangle())

                Image("JellyfinLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 0.95 : 0.35)
                    .scaleEffect(isHovering ? 1.0 : 0.97)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let launchURL {
                ClientLauncher.openJellyfin(launchURL)
                onLaunch()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHovering)
    }
}
