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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
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
            self.action(action)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: emphasised ? 18 : 14, weight: .semibold))
                .frame(width: emphasised ? 28 : 24, height: emphasised ? 28 : 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.accessibilityLabel)
        .disabled(isCommandInFlight)
        .opacity(isCommandInFlight ? 0.45 : 1.0)
        .scaleEffect(hoveredAction == action ? 1.12 : 1.0)
        .onHover { hovering in
            hoveredAction = hovering ? action : nil
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hoveredAction)
        .focusEffectDisabled()
    }
}
