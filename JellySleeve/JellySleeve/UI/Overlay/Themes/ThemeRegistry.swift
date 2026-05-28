import Foundation
import Observation
import SwiftUI

/// Holds the list of built-in themes and which one is active. Persists
/// `selectedId` to UserDefaults under `selectedThemeId` per plan §3bis.5.
///
/// `OverlayView` observes `current` and re-renders when the user picks
/// another theme from the Appearance tab (Fase 6). The `AppDelegate` watches
/// the same value to resize the borderless window to the new
/// `layout.windowSize`.
@MainActor
@Observable
final class ThemeRegistry {
    private static let storageKey = "selectedThemeId"

    let builtIn: [any OverlayTheme]

    var selectedId: String {
        didSet {
            UserDefaults.standard.set(selectedId, forKey: Self.storageKey)
        }
    }

    var current: any OverlayTheme {
        builtIn.first(where: { $0.id == selectedId }) ?? builtIn[0]
    }

    init() {
        // Phase 4 only ships ElegantTheme. The other four built-ins land in
        // Phase 6 alongside the Appearance tab.
        self.builtIn = [ElegantTheme()]
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? "elegant"
        self.selectedId = stored
    }

    func select(_ id: String) {
        guard builtIn.contains(where: { $0.id == id }) else { return }
        selectedId = id
    }
}
