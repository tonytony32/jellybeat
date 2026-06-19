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
