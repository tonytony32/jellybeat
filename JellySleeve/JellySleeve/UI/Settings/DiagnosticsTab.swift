import SwiftUI

/// Placeholder for Fase 6. Will show the last ~100 os_log events, a
/// "Copy to clipboard" button, and a link to open the log file.
struct DiagnosticsTab: View {
    var body: some View {
        ContentUnavailableView {
            Label("Diagnostics coming in Fase 6", systemImage: "ladybug")
        } description: {
            Text("Recent events from os_log will appear here with a one-click copy to clipboard.")
        }
    }
}

#Preview {
    DiagnosticsTab()
        .frame(width: 520, height: 420)
}
