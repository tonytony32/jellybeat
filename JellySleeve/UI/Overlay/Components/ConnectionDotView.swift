import SwiftUI

/// Top-right status indicator that **only appears when there is something to
/// report** — connecting in progress or an error. In the happy path
/// (idle / connected) it renders nothing so the overlay stays clean.
struct ConnectionDotView: View {
    let state: ConnectionState

    var body: some View {
        if let color = warningColor {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .help(tooltip)
        }
    }

    private var warningColor: Color? {
        switch state {
        case .idle, .connected:
            return nil
        case .connecting:
            return Color.yellow.opacity(0.95)
        case .error:
            return Color.red.opacity(0.95)
        }
    }

    private var tooltip: String {
        switch state {
        case .connecting: return String(localized: "Connecting…")
        case .error(let message): return "\(String(localized: "Error: "))\(message)"
        default: return ""
        }
    }
}
