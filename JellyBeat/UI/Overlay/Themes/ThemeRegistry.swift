import Foundation
import Observation
import SwiftUI

/// Holds the list of built-in themes and which one is active. Persists
/// `selectedId` to UserDefaults under `selectedThemeId`.
///
/// `OverlayView` observes `current` and re-renders when the user picks
/// another theme from the Appearance tab. The `AppDelegate` watches the
/// same value to resize the borderless window to the new
/// `layout.windowSize`.
@MainActor
@Observable
final class ThemeRegistry {
    private static let storageKey = "selectedThemeId"

    /// Injected so the hosted test runner can build this against a throwaway
    /// suite instead of writing `selectedThemeId` into the user's real
    /// `.standard` domain on first launch. Production passes `.standard`.
    private let defaults: UserDefaults

    let builtIn: [any OverlayTheme]

    var selectedId: String {
        didSet {
            defaults.set(selectedId, forKey: Self.storageKey)
        }
    }

    var current: any OverlayTheme {
        builtIn.first(where: { $0.id == selectedId }) ?? builtIn[0]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Display order. "Stack" was retired; the default theme used to be
        // called "Elegant" and is now "Standard". We migrate any persisted
        // id below.
        self.builtIn = [
            StandardTheme(),
            ClassicTheme(),
            MinimTheme(),
            AeroTheme(),
        ]
        let stored = defaults.string(forKey: Self.storageKey)
        switch stored {
        case nil, "elegant", "stack":
            // Map the renamed / retired ids to the new default.
            self.selectedId = "standard"
            defaults.set("standard", forKey: Self.storageKey)
        case let id?:
            self.selectedId = id
        }
    }

    func select(_ id: String) {
        guard builtIn.contains(where: { $0.id == id }) else { return }
        selectedId = id
    }
}
