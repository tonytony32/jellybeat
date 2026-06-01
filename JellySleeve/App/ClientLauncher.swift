import AppKit
import os

/// Opens the configured Jellyfin URL, preferring a Safari "Add to Dock"
/// web app whose underlying URL matches the server, so the user gets the
/// dedicated standalone window they registered instead of a tab in their
/// general-purpose browser.
///
/// Why we don't just rely on `NSWorkspace.urlsForApplications(toOpen:)`:
/// Safari web apps in macOS Tahoe declare only `x-webkit-app-launch` as a
/// URL scheme in their Info.plist. LaunchServices therefore does not list
/// them as handlers for `http(s)://` URLs, even though that's the URL the
/// user originally pinned. The user-visible URL is stashed in the app's
/// `Info.plist > Manifest > start_url`. We enumerate the candidate apps
/// ourselves, peek at that key, and match by host + port.
@MainActor
enum ClientLauncher {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    private static let webAppBundleIDPrefix = "com.apple.Safari.WebApp."

    static func openJellyfin(_ url: URL) {
        if let appURL = findWebApp(matching: url) {
            let config = NSWorkspace.OpenConfiguration()
            // A deep link (e.g. `/web/#/queue`) must actually *navigate* the
            // pinned web app to that route. `openApplication(at:)` only launches
            // or re-activates the app and drops the URL on the floor — leaving
            // the user on whatever screen it last showed. So for a routed URL,
            // open it *with* the app explicitly: passing the app sidesteps the
            // LaunchServices scheme gate (web apps only advertise
            // `x-webkit-app-launch`, so http(s) URLs never resolve to them on
            // their own — see the type doc above).
            if url.fragment?.isEmpty == false {
                logger.notice("Opening Jellyfin route in web app: \(appURL.lastPathComponent, privacy: .public)")
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: appURL,
                    configuration: config,
                    completionHandler: nil
                )
            } else {
                // No specific route: just bring the web app forward wherever it
                // was (the long-standing behaviour for the idle launch).
                logger.notice("Launching Jellyfin via web app: \(appURL.lastPathComponent, privacy: .public)")
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: config,
                    completionHandler: nil
                )
            }
            return
        }
        logger.notice("No matching Safari web app; falling back to default browser")
        NSWorkspace.shared.open(url)
    }

    /// Composes a hash-routed Jellyfin Web URL from the server base URL. Jellyfin
    /// Web is a single-page app routed in the fragment, so the now-playing queue
    /// list lives at `<base>/web/#/queue` — matching the web client's own
    /// `showNowPlaying()` (`show('queue')`).
    ///
    /// The base comes straight from user settings, so it's normalised
    /// defensively: a trailing slash, an explicit `/web` segment, or a leftover
    /// query/fragment are all stripped before composing, while a sub-path install
    /// is preserved (`https://host/jellyfin` → `https://host/jellyfin/web/#/queue`).
    /// Falls back to `base` if the composed string isn't a valid URL.
    nonisolated static func webRouteURL(base: URL, route: String) -> URL {
        var origin = base.absoluteString
        // Keep only scheme://host[:port]/path — drop any query/fragment.
        if let cut = origin.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            origin = String(origin[..<cut])
        }
        while origin.hasSuffix("/") { origin.removeLast() }
        // Don't double the SPA mount if the base already points at `/web`.
        if origin.lowercased().hasSuffix("/web") { origin.removeLast(4) }
        while origin.hasSuffix("/") { origin.removeLast() }
        return URL(string: "\(origin)/web/#/\(route)") ?? base
    }

    // MARK: - Internals

    private static func findWebApp(matching target: URL) -> URL? {
        let directories: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
        ]
        for dir in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for appURL in contents where appURL.pathExtension == "app" {
                if isMatchingWebApp(at: appURL, target: target) {
                    return appURL
                }
            }
        }
        return nil
    }

    private static func isMatchingWebApp(at appURL: URL, target: URL) -> Bool {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID.hasPrefix(webAppBundleIDPrefix) else {
            return false
        }
        guard let manifest = plist["Manifest"] as? NSDictionary,
              let startURLString = manifest["start_url"] as? String,
              let startURL = URL(string: startURLString) else {
            return false
        }
        // Match by host + port; the manifest URL usually has a path like
        // `/web/index.html#/home` that the user's base URL doesn't.
        guard let targetHost = target.host?.lowercased(),
              let appHost = startURL.host?.lowercased(),
              targetHost == appHost,
              startURL.port == target.port else {
            return false
        }
        return true
    }
}
