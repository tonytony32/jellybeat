import SwiftUI

/// Slim track-progress indicator. Reads `position` and `runtime` from a
/// `TrackSnapshot` and draws a horizontal bar that fills proportionally.
///
/// The bar updates on every `apply()` from the polling/WebSocket source. To
/// avoid jumps between server pushes it linearly interpolates locally while
/// the track is playing, snapping to the freshly reported position whenever
/// it arrives.
struct ProgressBarView: View {
    let position: Duration
    let runtime: Duration
    let isPaused: Bool
    var height: CGFloat = 4
    var foregroundOpacity: Double = 0.95
    var backgroundOpacity: Double = 0.30

    @State private var displayedSeconds: Double = 0
    @State private var lastSampleAt: Date = .distantPast

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

    var body: some View {
        Capsule()
            .fill(.primary.opacity(backgroundOpacity))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary.opacity(foregroundOpacity))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Track progress"))
            .accessibilityValue(String(format: "%.0f%%", fraction * 100))
            .onChange(of: reportedSeconds, initial: true) { _, newValue in
                displayedSeconds = newValue
                lastSampleAt = Date()
            }
            .onChange(of: isPaused) { _, _ in
                lastSampleAt = Date()
            }
            .task(id: isPaused) {
                guard !isPaused else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    let elapsed = Date().timeIntervalSince(lastSampleAt)
                    let projected = reportedSeconds + elapsed
                    if totalSeconds > 0 {
                        displayedSeconds = min(totalSeconds, projected)
                    }
                }
            }
            .animation(.linear(duration: 0.2), value: displayedSeconds)
    }

    private static func seconds(of duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
