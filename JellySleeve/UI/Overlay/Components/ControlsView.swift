import SwiftUI

/// Hover-revealed transport controls. The actual command wiring is supplied
/// by the enclosing theme via the `action` closure.
struct ControlsView: View {
    /// Alias kept for call-site readability; the canonical type is the
    /// domain-level `PlaybackAction`.
    typealias Action = PlaybackAction

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
    /// Whether the current track is favorited; drives the heart's filled state.
    let isFavorite: Bool
    /// Toggles the favorite flag on the current track.
    let onToggleFavorite: @MainActor () -> Void
    /// The active client's play queue, shown in the queue popover.
    let queue: [QueueItem]
    /// Invoked when the user taps a row in the queue popover to jump to that
    /// track. The popover dismisses itself first.
    let onSelectQueueItem: @MainActor (QueueItem) -> Void

    /// Used only to publish the queue-popover open state so scroll-to-volume
    /// can suspend itself while the list is up.
    @Environment(PlayerStore.self) private var player

    @State private var hoveredAction: Action?
    @State private var favoriteHovered = false
    @State private var queueHovered = false
    @State private var showQueue = false

    var body: some View {
        // Tight spacing because each button now claims a 44 pt hit target
        // (see `overlayHitTarget`); the boxes sit edge-to-edge so the whole
        // row is contiguously tappable while the glyphs stay where they were.
        HStack(spacing: 0) {
            controlButton(systemName: "backward.fill", action: .previous)
            controlButton(
                systemName: isPaused ? "play.fill" : "pause.fill",
                action: .playPause,
                emphasised: true
            )
            controlButton(systemName: "forward.fill", action: .next)
            favoriteButton
            queueButton
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
        .onChange(of: showQueue, initial: true) { _, open in
            player.isQueuePopoverOpen = open
        }
        .onDisappear { player.isQueuePopoverOpen = false }
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
                .overlayHitTarget()
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

    /// Favorite toggle. Sits at the trailing edge of the transport row (after
    /// the forward button) so it rides the same hover/capsule treatment as the
    /// other controls. Filled when the track is a favorite, an outline
    /// otherwise; it inherits the same colour as the transport glyphs (white on
    /// the dark overlay) rather than tinting itself.
    @ViewBuilder
    private var favoriteButton: some View {
        Button {
            onToggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
                .overlayHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isFavorite
                ? String(localized: "Remove from favorites")
                : String(localized: "Add to favorites")
        )
        .scaleEffect(favoriteHovered ? 1.12 : 1.0)
        .onHover { favoriteHovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: favoriteHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isFavorite)
        .focusEffectDisabled()
    }

    /// Opens the queue popover ("up next"). Sits at the trailing edge after the
    /// heart and rides the same hover/capsule treatment as the rest of the row.
    @ViewBuilder
    private var queueButton: some View {
        Button {
            showQueue.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 24, height: 24)
                .overlayHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Show queue"))
        .scaleEffect(queueHovered ? 1.12 : 1.0)
        .onHover { queueHovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: queueHovered)
        .focusEffectDisabled()
        // Open upward, above the controls, into open screen space. A
        // side/`.trailing` popover is centred vertically on the button, so when
        // the overlay sits low (near the Dock) the tall list overflows the
        // bottom and AppKit shoves the whole overlay window *up* above the Dock
        // to make room — which is exactly the "it jumps up" complaint. Anchored
        // to `.top` the list grows into the empty space above instead, so the
        // window never has to move. SwiftUI auto-flips to `.bottom` if the
        // overlay is near the top of the screen.
        .popover(isPresented: $showQueue, arrowEdge: .top) {
            QueuePopover(queue: queue) { item in
                showQueue = false
                onSelectQueueItem(item)
            }
        }
    }

    private func scale(for action: Action) -> CGFloat {
        if flashedAction == action { return 1.35 }
        if hoveredAction == action { return 1.12 }
        return 1.0
    }
}

// MARK: - Reusable hit target

extension View {
    /// Guarantees a minimum interactive area (Apple's 44 pt HIG minimum by
    /// default) and makes the whole rectangle tappable, *without* enlarging
    /// the drawn content. Apply to every overlay control — current and future.
    ///
    /// The borderless overlay window absorbs any click inside its bounds (see
    /// `ClickableHostingView`), so a generous hit target keeps a near-miss on
    /// the control instead of letting the click fall through to the desktop —
    /// which on macOS Sonoma+ triggers "click wallpaper to reveal desktop"
    /// and shoves every window aside.
    func overlayHitTarget(_ minSize: CGFloat = 44) -> some View {
        frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}

// MARK: - UI mapping

private extension PlaybackAction {
    var accessibilityLabel: String {
        switch self {
        case .previous: return String(localized: "Previous track")
        case .playPause: return String(localized: "Play or pause")
        case .next: return String(localized: "Next track")
        }
    }
}
