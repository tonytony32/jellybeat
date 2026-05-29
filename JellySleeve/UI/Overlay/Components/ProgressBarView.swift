import AppKit
import SwiftUI

/// Slim track-progress indicator. Reads `position` and `runtime` from a
/// `TrackSnapshot` and draws a horizontal bar that fills proportionally.
///
/// Tap-to-seek: when `onSeek` is supplied, the caller can click anywhere on
/// the bar to jump to that fraction of the track. The bar updates
/// optimistically and the closure dispatches the seek command. While the
/// server propagates the new position back through the WebSocket (~1 s),
/// stale pre-seek pushes are dropped so the bar doesn't visibly bounce.
///
/// Between server pushes the bar advances locally at a 5 fps tick so it
/// moves smoothly; a fresh server push (outside of the post-seek window)
/// re-syncs the bar to authoritative truth.
struct ProgressBarView: View {
    /// Unique per song. When this changes the bar resets to the freshly
    /// reported position rather than interpolating from the previous track.
    let trackKey: String
    let position: Duration
    let runtime: Duration
    let isPaused: Bool
    /// Optional. If supplied the bar becomes interactive: clicking it asks
    /// the caller to seek to the corresponding number of seconds.
    var onSeek: ((Double) -> Void)? = nil
    var height: CGFloat = 4
    var foregroundOpacity: Double = 0.95
    var backgroundOpacity: Double = 0.30

    @State private var displayedSeconds: Double = 0
    @State private var seekedAt: Date? = nil
    @State private var isHovering: Bool = false

    private var totalSeconds: Double {
        max(0, Self.seconds(of: runtime))
    }

    private var reportedSeconds: Double {
        max(0, Self.seconds(of: position))
    }

    private var fraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1.0, max(0.0, displayedSeconds / totalSeconds))
    }

    /// Extra height the bar grows by on hover. Always reserved in the layout
    /// so neighbouring elements (title, artist, album) don't shift up when
    /// the cursor enters.
    private let extraHoverHeight: CGFloat = 2

    private var renderedHeight: CGFloat {
        guard onSeek != nil else { return height }
        return isHovering ? height + extraHoverHeight : height
    }

    private var reservedHeight: CGFloat {
        onSeek != nil ? height + extraHoverHeight : height
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Reserve the maximum height so the bar can grow on hover
                // without pushing the surrounding layout.
                Color.clear

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(backgroundOpacity))
                    Capsule()
                        .fill(.primary.opacity(foregroundOpacity))
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: renderedHeight)
            }
            .contentShape(Rectangle())
            .gesture(seekGesture(width: proxy.size.width))
            .onHover { isHovering = $0 }
            .background {
                // NSTrackingArea-based cursor updater. Unlike NSCursor.set()
                // inside .onHover, this fires `cursorUpdate(_:)` even when
                // JellySleeve isn't the key window, so the pointing-hand
                // cursor still appears the very first time the user moves
                // across the bar from another app.
                if onSeek != nil {
                    PointerCursorBridge(cursor: .pointingHand)
                }
            }
        }
        .frame(height: reservedHeight)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Track progress"))
        .accessibilityValue(String(format: "%.0f%%", fraction * 100))
        .onChange(of: trackKey, initial: true) { _, _ in
            displayedSeconds = reportedSeconds
            seekedAt = nil
        }
        .onChange(of: reportedSeconds) { _, newValue in
            // Inside the post-seek grace window, drop server pushes whose
            // value is still the pre-seek position (more than 3 s away from
            // what the user asked for). Close values are the server's
            // confirmation: accept and end the grace.
            if let seekedAt, Date().timeIntervalSince(seekedAt) < 2.0 {
                if abs(newValue - displayedSeconds) > 3.0 {
                    return
                }
                self.seekedAt = nil
            }
            displayedSeconds = newValue
        }
        .task(id: "\(trackKey)|\(isPaused)") {
            guard !isPaused else { return }
            // Tick: advance the displayed value by ~0.2 s every 0.2 s so the
            // bar moves smoothly between WebSocket pushes. Server pushes
            // re-anchor it via the onChange above.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, totalSeconds > 0 else { continue }
                displayedSeconds = min(totalSeconds, displayedSeconds + 0.2)
            }
        }
        .animation(.linear(duration: 0.2), value: displayedSeconds)
        .animation(.easeInOut(duration: 0.15), value: renderedHeight)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let onSeek, totalSeconds > 0, width > 0 else { return }
                let frac = max(0.0, min(1.0, value.location.x / width))
                let target = frac * totalSeconds
                displayedSeconds = target
                seekedAt = Date()
                onSeek(target)
            }
    }

    private static func seconds(of duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}

/// SwiftUI shim around an AppKit `NSView` that owns an
/// `NSTrackingArea(.cursorUpdate + .activeAlways)`. macOS will send
/// `cursorUpdate(_:)` to this view whenever the mouse is inside its bounds,
/// regardless of whether the host window currently has focus. The view
/// returns `nil` from `hitTest`, so it never intercepts clicks.
private struct PointerCursorBridge: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView {
        CursorView(cursor: cursor)
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.cursor = cursor
    }

    final class CursorView: NSView {
        var cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not implemented") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        // Pass clicks through so we don't fight the SwiftUI tap gesture
        // that lives in the parent view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
