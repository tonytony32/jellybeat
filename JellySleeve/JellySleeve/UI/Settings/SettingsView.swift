import SwiftUI

/// Phase 1 placeholder. Phase 3 turns this into a `TabView` with
/// Server / Appearance / Diagnostics tabs.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Configuration arrives in Fase 3.")
                .foregroundStyle(.secondary)
        }
        .frame(width: 420, height: 240)
        .padding()
    }
}

#Preview {
    SettingsView()
}
