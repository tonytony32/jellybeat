import SwiftUI

/// Hover-revealed transport controls. The actual command wiring lands in
/// Fase 5; Fase 4 only provides the structural piece so themes can compose it.
struct ControlsView: View {
    enum Action: Hashable, Sendable {
        case previous, playPause, next
    }

    let isPaused: Bool
    let isCommandInFlight: Bool
    let behavior: BehaviorSpec
    /// Driven by the enclosing container's hover state so the whole artwork
    /// region acts as the trigger, not just the buttons themselves.
    let isVisible: Bool
    let action: @MainActor (Action) -> Void

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
        .disabled(isCommandInFlight)
        .opacity(isCommandInFlight ? 0.5 : 1.0)
    }
}
