import SwiftUI

/// Root view rendered inside the borderless `NSWindow` created by `AppDelegate`.
///
/// Phase 1 is a placeholder: rounded glass rectangle with a centered title.
/// Phase 4 turns this into a delegate that observes `ThemeRegistry.current`
/// and renders `theme.body(track:, store:)`.
struct OverlayView: View {
    var body: some View {
        ZStack {
            GlassBackground()
            Text("JellySleeve")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    OverlayView()
        .frame(width: 300, height: 380)
        .padding()
}
