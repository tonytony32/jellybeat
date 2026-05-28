import SwiftUI

/// Placeholder for Fase 6. The theme switcher (grid of built-in themes,
/// per-theme thumbnails, global window-level / opacity / always-show-controls
/// toggles) lives here.
struct AppearanceTab: View {
    var body: some View {
        ContentUnavailableView {
            Label("Themes coming in Fase 6", systemImage: "paintpalette")
        } description: {
            Text("Built-in layouts (Elegant, Stack, Classic, Minim, Aero) will be selectable here.")
        }
    }
}

#Preview {
    AppearanceTab()
        .frame(width: 520, height: 420)
}
