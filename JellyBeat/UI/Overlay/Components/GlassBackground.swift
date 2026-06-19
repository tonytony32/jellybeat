import AppKit
import SwiftUI

/// Translucent glass background for the overlay window.
///
/// Phase 1 uses `NSVisualEffectView` with material `.hudWindow` as the plan
/// (Fase 1) specifies. Both `NSGlassEffectView` (AppKit, macOS 26+) and
/// SwiftUI's `View.glassEffect(_:in:)` are available in the macOS 26 SDK and
/// can be swapped in during Phase 6 polish for Liquid Glass once the
/// per-theme `BehaviorSpec.glassMaterial` knob is wired up.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var isEmphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = isEmphasized
    }
}
