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
    /// Corner radius applied directly to the effect view via `maskImage`. Done
    /// at the AppKit layer rather than relying on SwiftUI's `.clipShape` so the
    /// glass stays crisply rounded *during* the window's hover-resize — a SwiftUI
    /// clip mask lags a frame behind an animated frame change, which flashed
    /// square corners at the start of the Minim unfold.
    var cornerRadius: CGFloat = 14

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = isEmphasized
        if context.coordinator.cornerRadius != cornerRadius {
            nsView.maskImage = Self.maskImage(cornerRadius: cornerRadius)
            context.coordinator.cornerRadius = cornerRadius
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cornerRadius: cornerRadius)
    }

    final class Coordinator {
        var cornerRadius: CGFloat
        init(cornerRadius: CGFloat) { self.cornerRadius = cornerRadius }
    }

    /// A rounded-rect mask sized to the corner so `NSVisualEffectView` stretches
    /// it across any frame via cap insets: the four corners keep their radius,
    /// the centre stretches. Because it's the view's own layer mask, it resizes
    /// in lockstep with the view — no one-frame square flash on resize.
    private static func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}
