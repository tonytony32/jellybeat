import AppKit
import SwiftUI
import os

/// Server connection settings. The actual values land in UserDefaults
/// (`SettingsStore`) and Keychain (`KeychainHelper`).
struct ServerTab: View {
    @Environment(SettingsStore.self) private var store
    @Environment(PlayerStore.self) private var player
    @State private var probe: ProbeResult = .idle
    @FocusState private var focused: Field?

    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "ui"
    )

    enum ProbeResult: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    enum Field: Hashable {
        case baseURL, apiKey, userId
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Server") {
                TextField(
                    "Base URL",
                    text: $store.baseURLString,
                    prompt: Text("https://jellyfin.example.com")
                )
                .textFieldStyle(.roundedBorder)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .focused($focused, equals: .baseURL)

                SecureField(
                    "API key",
                    text: $store.apiKey,
                    prompt: Text("Generate in Dashboard → Advanced → API Keys")
                )
                .textFieldStyle(.roundedBorder)
                .focused($focused, equals: .apiKey)

                TextField(
                    "User ID",
                    text: $store.userId,
                    prompt: Text("Dashboard → Users → your user → URL ends with userId=…")
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focused, equals: .userId)

                Toggle("Allow self-signed certificates", isOn: $store.allowSelfSigned)
                    .help("Enable for servers behind Tailscale, Caddy, or an internal CA.")

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Store API key in Keychain (encrypted at rest)",
                        isOn: $store.storeApiKeyInKeychain
                    )
                    Text("Off by default: the key is saved with the app's other settings. Enable for encrypted at-rest storage — note macOS may re-prompt for Keychain access after app updates or rebuilds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Polling") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(player.connectionMode.color)
                        .frame(width: 6, height: 6)
                    Text("Active transport: \(player.connectionMode.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Slider(
                        value: $store.refreshRate,
                        in: 1.0...5.0,
                        step: 0.25
                    ) {
                        Text("Refresh rate")
                    } minimumValueLabel: {
                        Text("1s").font(.caption2).monospacedDigit()
                    } maximumValueLabel: {
                        Text("5s").font(.caption2).monospacedDigit()
                    }

                    Text(String(format: "Poll every %.2f seconds.", store.refreshRate))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(
                        "Only a fallback for when the live connection is unavailable. While the live connection (WebSocket) is active, this has no effect — updates arrive in real time.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 12) {
                    Button(action: runProbe) {
                        if probe == .running {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(probe == .running || !store.isFullyConfigured)

                    Spacer()

                    statusIndicator
                }
            }
        }
        .formStyle(.grouped)
        // Prevent the first TextField from grabbing focus (and auto-selecting
        // its contents) when Settings opens with already-populated fields.
        // `onAppear` fires before AppKit assigns the window's initial first
        // responder, so we reach into the NSWindow and clear it directly.
        .background(WindowFirstResponderResetter())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch probe {
        case .idle, .running:
            EmptyView()
        case .success(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func runProbe() {
        guard let config = store.jellyfinConfiguration else {
            probe = .failure("Fill all fields first.")
            return
        }
        probe = .running
        let client = JellyfinClient(configuration: config)
        Task {
            do {
                let info = try await client.validateConnection()
                Self.logger.notice("Server probe OK: \(info.serverName, privacy: .public) v\(info.version, privacy: .public)")
                probe = .success("\(info.serverName) • v\(info.version)")
            } catch let error as NetworkError {
                Self.logger.error("Server probe failed: \(String(describing: error), privacy: .public)")
                probe = .failure(error.errorDescription ?? "Connection failed.")
            } catch {
                Self.logger.error("Server probe failed: \(String(describing: error), privacy: .public)")
                probe = .failure(error.localizedDescription)
            }
        }
    }
}

#Preview {
    ServerTab()
        .environment(SettingsStore())
        .environment(PlayerStore())
        .frame(width: 520, height: 420)
}

/// Invisible bridge that clears the hosting NSWindow's first responder once
/// it is attached. Used to keep `SecureField` / `TextField` from auto-
/// selecting their text when the Settings window opens.
private struct WindowFirstResponderResetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer to the next runloop turn so the window is already configured.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
