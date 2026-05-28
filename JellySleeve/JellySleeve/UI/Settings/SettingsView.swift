import SwiftUI

/// Top-level Settings scene content. `Cmd+,` and the standard menu entry come
/// from `Settings { SettingsView() }` declared in `JellySleeveApp`.
struct SettingsView: View {
    var body: some View {
        TabView {
            ServerTab()
                .tabItem { Label("Server", systemImage: "server.rack") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            DiagnosticsTab()
                .tabItem { Label("Diagnostics", systemImage: "ladybug") }
        }
        .frame(width: 520, height: 420)
    }
}

#Preview {
    SettingsView()
        .environment(SettingsStore())
}
