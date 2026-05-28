import SwiftUI
import os

/// Root view rendered inside the borderless `NSWindow` created by `AppDelegate`.
///
/// Phase 1 is a placeholder: rounded glass rectangle with a centered title.
/// Phase 4 turns this into a delegate that observes `ThemeRegistry.current`
/// and renders `theme.body(track:, store:)`.
struct OverlayView: View {
    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 12) {
                Text("JellySleeve")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                #if DEBUG
                DebugConnectionProbe()
                #endif
            }
            .padding(.horizontal, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    OverlayView()
        .frame(width: 300, height: 380)
        .padding()
}

#if DEBUG

/// Temporary connection-probe widget for the end of Phase 2. Removed at the
/// start of Phase 3 once Settings owns the real configuration UI.
///
/// Reads the dev server config from UserDefaults so no secrets are committed:
///
/// ```
/// defaults write software.trypwood.jellysleeve dev.jellysleeve.baseURL "https://your-server"
/// defaults write software.trypwood.jellysleeve dev.jellysleeve.apiKey "your-api-key"
/// defaults write software.trypwood.jellysleeve dev.jellysleeve.userId "your-user-id"
/// defaults write software.trypwood.jellysleeve dev.jellysleeve.allowSelfSigned -bool false
/// ```
private struct DebugConnectionProbe: View {
    @State private var status: String = "Click to test against your server."
    @State private var inFlight: Bool = false

    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "dev-test"
    )

    var body: some View {
        VStack(spacing: 6) {
            Button {
                runProbe()
            } label: {
                Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(inFlight)
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 240)
        }
    }

    private func runProbe() {
        let defaults = UserDefaults.standard
        guard
            let urlString = defaults.string(forKey: "dev.jellysleeve.baseURL"),
            let url = URL(string: urlString),
            let apiKey = defaults.string(forKey: "dev.jellysleeve.apiKey"),
            !apiKey.isEmpty,
            let userId = defaults.string(forKey: "dev.jellysleeve.userId"),
            !userId.isEmpty
        else {
            status = "Set dev.jellysleeve.{baseURL,apiKey,userId} via `defaults write`."
            return
        }
        let allowSelfSigned = defaults.bool(forKey: "dev.jellysleeve.allowSelfSigned")

        inFlight = true
        status = "Connecting to \(url.host ?? urlString)…"

        let client = JellyfinClient(
            configuration: JellyfinConfiguration(
                baseURL: url,
                apiKey: apiKey,
                userId: userId,
                allowSelfSigned: allowSelfSigned
            )
        )

        Task {
            do {
                let info = try await client.validateConnection()
                let sessions = try await client.fetchSessions()
                let mySessions = sessions.filter { $0.userId == userId && $0.nowPlayingItem != nil }
                let summary = "OK • \(info.serverName) v\(info.version) • " +
                              "\(sessions.count) sessions (\(mySessions.count) playing)"
                Self.logger.notice("Probe OK: \(info.serverName, privacy: .public) v\(info.version, privacy: .public), \(sessions.count) sessions, \(mySessions.count) with NowPlayingItem")
                if let item = mySessions.first?.nowPlayingItem {
                    Self.logger.notice("Now playing: \(item.name, privacy: .public) — \(item.albumArtist ?? item.artists?.joined(separator: ", ") ?? "?", privacy: .public)")
                }
                status = summary
            } catch {
                Self.logger.error("Probe failed: \(String(describing: error), privacy: .public)")
                status = "Error: \(error.localizedDescription)"
            }
            inFlight = false
        }
    }
}

#endif
