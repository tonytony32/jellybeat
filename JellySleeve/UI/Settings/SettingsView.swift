import SwiftUI

/// Top-level Settings scene content. `Cmd+,` and the standard menu entry come
/// from `Settings { SettingsView() }` declared in `JellySleeveApp`.
struct SettingsView: View {
    @State private var selection: Tab = .general

    enum Tab { case general, server, appearance, diagnostics }

    var body: some View {
        TabView(selection: $selection) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)
            ServerTab()
                .tabItem {
                    Label {
                        Text("Server")
                    } icon: {
                        Image("JellyfinLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 11, height: 11)
                    }
                }
                .tag(Tab.server)
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(Tab.appearance)
            DiagnosticsTab()
                .tabItem { Label("Diagnostics", systemImage: "ladybug") }
                .tag(Tab.diagnostics)
        }
        .frame(width: 520, height: 420)
    }
}

#Preview {
    SettingsView()
        .environment(SettingsStore())
}
