import SwiftUI

/// Top-right status indicator, 4pt diameter, universal across themes
/// (plan §5.6). Click handler is wired in `OverlayView` so it can open
/// Settings when the connection is in error.
struct ConnectionDotView: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(tooltip)
    }

    private var color: Color {
        switch state {
        case .idle: return Color.gray.opacity(0.5)
        case .connecting: return Color.yellow.opacity(0.85)
        case .connected: return Color.green.opacity(0.6)
        case .error: return Color.red.opacity(0.85)
        }
    }

    private var tooltip: String {
        switch state {
        case .idle: return "Not configured"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let message): return "Error: \(message)"
        }
    }
}
