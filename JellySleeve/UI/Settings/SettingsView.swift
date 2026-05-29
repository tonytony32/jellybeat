import SwiftUI

/// Top-level Settings scene content. `Cmd+,` and the standard menu entry come
/// from `Settings { SettingsView() }` declared in `JellySleeveApp`.
struct SettingsView: View {
    var body: some View {
        TabView {
            ServerTab()
                .tabItem {
                    Label {
                        Text("Server")
                    } icon: {
                        // Sized + tinted like the sibling SF Symbols
                        // (paintpalette, ladybug). The asset is registered as a
                        // template image, so the system tint applies.
                        Image("JellyfinLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 11, height: 11)
                    }
                }
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
