import AppKit
import SwiftUI

struct GeneralTab: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("App Icon") {
                Picker("Show in", selection: $settings.appPresence) {
                    ForEach(AppPresence.allCases) { presence in
                        Text(presence.displayName).tag(presence)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Sources") {
                Toggle("YouTube (Safari) bridge", isOn: $settings.youtubeBridgeEnabled)
                Text("Shows YouTube / YouTube Music playback as a source. JellyBeat runs the Safari bridge only while it's open — no background process at login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)

                Button("About JellyBeat…") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)

                Link("Source Code", destination: URL(string: "https://github.com/tonytony32/jellybeat")!)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

#Preview {
    GeneralTab()
        .environment(SettingsStore())
        .frame(width: 520, height: 420)
}
