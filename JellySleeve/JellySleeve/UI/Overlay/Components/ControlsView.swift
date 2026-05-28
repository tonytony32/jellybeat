import SwiftUI

/// Hover-revealed transport controls. The actual command wiring is supplied
/// by the enclosing theme via the `action` closure.
struct ControlsView: View {
    enum Action: Hashable, Sendable {
        case previous, playPause, next

        var accessibilityLabel: String {
            switch self {
            case .previous: return String(localized: "Previous track")
            case .playPause: return String(localized: "Play or pause")
            case .next: return String(localized: "Next track")
            }
        }
    }

    let isPaused: Bool
    let isCommandInFlight: Bool
    let behavior: BehaviorSpec
    /// Driven by the enclosing container's hover state so the whole artwork
    /// region acts as the trigger, not just the buttons themselves.
    let isVisible: Bool
    /// Recently-dispatched action, used to pulse the corresponding button so
    /// media-key presses (F7/F8/F9) get a visible confirmation even when the
    /// row was hover-hidden.
    let flashedAction: Action?
    let action: @MainActor (Action) -> Void

    @State private var hoveredAction: Action?

    var body: some View {
        HStack(spacing: 14) {
            controlButton(systemName: "backward.fill", action: .previous)
            controlButton(
                systemName: isPaused ? "play.fill" : "pause.fill",
                action: .playPause,
                emphasised: true
            )
            controlButton(systemName: "forward.fill", action: .next)
        }
        .padding(.horizontal, behavior.controlsHasBackground ? 12 : 0)
        .padding(.vertical, behavior.controlsHasBackground ? 6 : 0)
        .background {
            if behavior.controlsHasBackground {
                Capsule().fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(opacity > 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .animation(.easeInOut(duration: 0.2), value: isPaused)
    }

    private var opacity: Double {
        if behavior.controlsAlwaysVisible { return 1.0 }
        return isVisible ? 1.0 : 0.0
    }

    @ViewBuilder
    private func controlButton(
        systemName: String,
        action: Action,
        emphasised: Bool = false
    ) -> some View {
        Button {
            // The store's sendCommand already drops repeats while a command
            // is in flight, so we just no-op here instead of visually
            // disabling the button (which used to dim it to 0.45 and felt
            // like a "lost click").
            guard !isCommandInFlight else { return }
            self.action(action)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: emphasised ? 18 : 14, weight: .semibold))
                .frame(width: emphasised ? 28 : 24, height: emphasised ? 28 : 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.accessibilityLabel)
        .scaleEffect(scale(for: action))
        .onHover { hovering in
            hoveredAction = hovering ? action : nil
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hoveredAction)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: flashedAction)
        .focusEffectDisabled()
    }

    private func scale(for action: Action) -> CGFloat {
        if flashedAction == action { return 1.35 }
        if hoveredAction == action { return 1.12 }
        return 1.0
    }
}
