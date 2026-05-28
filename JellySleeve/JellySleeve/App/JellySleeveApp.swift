import SwiftUI

@main
struct JellySleeveApp: App {
    var body: some Scene {
        WindowGroup {
            // TODO Fase 1: reemplazar por NSWindow borderless via AppDelegate.
            Text("JellySleeve")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 300, height: 380)
        }
    }
}
