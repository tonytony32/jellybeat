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
            // Full-window hit-catching surface. The themes that float over the
            // desktop (Aero / Classic have no glass background) leave the gaps
            // between cover / text / progress / controls fully transparent, and
            // SwiftUI does not hit-test fully-transparent areas. A click in
            // those gaps fell through to whatever sat behind the overlay — the
            // desktop — which selected the Finder and triggered macOS's "click
            // wallpaper to reveal desktop" gesture, sweeping every window aside.
            //
            // CRITICAL: this must be a real color with a tiny non-zero alpha,
            // NOT `Color.clear`. SwiftUI treats `Color.clear` as "no content"
            // and skips hit-testing it even with `.contentShape`. Worse, macOS
            // resolves the "click wallpaper to reveal desktop" gesture from the
            // window's actually-rendered alpha — a transparent gap counts as
            // wallpaper (a CGWindowList probe confirmed a gap pixel belonged to
            // the Finder window beneath, not to this overlay). A tiny black
            // fill gives every pixel real, opaque-enough content, so SwiftUI
            // hit-tests it AND the WindowServer counts the window as covering
            // the desktop. A near-miss on a control is swallowed instead of
            // revealing the desktop. Sits at the back of the ZStack, not gated
            // by theme/chrome opacity, so it protects every theme in every
            // state.
            //
            // Alpha kept as low as possible: 0.02 (~5/255) read as a faint grey
            // rectangle over the wallpaper in the frameless themes (Classic /
            // Aero). 0.005 (~1.3/255) is imperceptible while still a *real*
            // color. If gap clicks ever start revealing the desktop again,
            // nudge this up slightly.
            Color.black.opacity(0.005)
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
            VolumeFeedbackView(level: player.volumeFeedback)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: themes.current.layout.cornerRadius,
                style: .continuous
            )
        )
        .animation(.easeInOut(duration: 0.25), value: player.transientMessage)
        .animation(.easeInOut(duration: 0.15), value: player.volumeFeedback)
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
        case .reconnecting(let isOffline):
            if let track = player.currentTrack {
                // Keep the last track on screen for continuity, but dimmed and
                // topped with a quiet badge so it reads as "paused link, not a
                // crash". Controls are gated in PlayerStore, so a press here
                // just surfaces the reconnecting hint.
                themes.current.body(track: track, store: player)
                    .id(themes.current.id)
                    .opacity(0.4)
                    .overlay(alignment: .top) {
                        ReconnectingBadge(isOffline: isOffline)
                            .padding(.top, 8)
                    }
                    .transition(.opacity)
            } else {
                ReconnectingStateView(isOffline: isOffline)
            }
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

/// Quiet pill floated over the (dimmed) last track while the link is down and
/// the poller is retrying. Mirrors the transient toast's capsule treatment so
/// it reads as part of the overlay chrome, not an alert.
private struct ReconnectingBadge: View {
    let isOffline: Bool

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text(isOffline ? "Offline" : "Reconnecting…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
        }
    }
}

/// Shown when the link drops while nothing is playing (no track to dim). Gentle
/// on purpose: this is a transient, self-healing state, so — unlike
/// `ErrorStateView` — there's no red triangle and no "Open Settings" (the
/// config is fine; the server is just temporarily unreachable).
private struct ReconnectingStateView: View {
    let isOffline: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isOffline ? "wifi.slash" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(isOffline ? "You're offline" : "Lost connection to the server")
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                Text("Reconnecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
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

/// Centered volume readout flashed while the user scrolls over the overlay to
/// change the volume. Mirrors the system volume HUD in spirit: a speaker glyph
/// that reflects the level, a thin progress track, and the percentage.
private struct VolumeFeedbackView: View {
    let level: Int?

    var body: some View {
        if let level {
            VStack(spacing: 8) {
                Image(systemName: speakerSymbol(for: level))
                    .font(.system(size: 22, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 24)
                Capsule()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 90, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.primary)
                            .frame(width: 90 * CGFloat(level) / 100, height: 5)
                    }
                Text("\(level)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    private func speakerSymbol(for level: Int) -> String {
        switch level {
        case ...0: return "speaker.slash.fill"
        case 1...33: return "speaker.wave.1.fill"
        case 34...66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Ambient idle state: the window shrinks to artwork-size (see
/// `AppDelegate.applyWindowSizeForCurrentState`) and shows a large pair of
/// beamed eighth notes (♫) as a launch affordance. The glyph stays visible at all times but at a
/// subtle, low opacity; hovering brings it to full strength (and the
/// surrounding glass fades in via `chromeOpacity`). Tapping launches the
/// configured Jellyfin URL via `NSWorkspace.open`, which on macOS picks the
/// user's chosen handler — useful when the user has registered a Safari
/// "Add to Dock" web app for the Jellyfin URL.
private struct NothingPlayingView: View {
    let launchURL: URL?
    @Binding var isHovering: Bool
    let onLaunch: () -> Void
    @Environment(WindowSnapState.self) private var snapState

    var body: some View {
        GeometryReader { geo in
            // Scale the logo to the ambient window so it reads as "a bigger
            // icon" across themes whose artwork sizes differ (Classic 120 →
            // Standard/Aero ~256).
            let side = min(geo.size.width, geo.size.height) * 0.5
            let snapped = snapState.alignment != .center

            ZStack(alignment: snapState.alignment) {
                Color.clear.contentShape(Rectangle())

                Image("AmbientNotes")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 0.95 : 0.35)
                    .scaleEffect(isHovering ? 1.0 : 0.97)
                    .padding(snapped ? 8 : 0)
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: snapState.alignment)
    }
}

