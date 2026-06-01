import Foundation
import Testing
@testable import JellySleeve

/// `ClientLauncher.webRouteURL(base:route:)` composes the hash-routed Jellyfin
/// Web URL the artwork double-click jumps to (e.g. the now-playing `queue`
/// list). The base URL comes straight from user settings, so it may carry a
/// trailing slash, an explicit `/web`, a port, or be a sub-path install — all of
/// which must normalise to exactly one `…/web/#/<route>`. Pure value in/out, no
/// AppKit, so it runs anywhere.
nonisolated struct WebRouteURLTests {
    @Test
    func appendsWebHashRouteToBareHost() {
        let base = URL(string: "https://jelly.example.com")!
        #expect(ClientLauncher.webRouteURL(base: base, route: "queue").absoluteString
            == "https://jelly.example.com/web/#/queue")
    }

    @Test
    func toleratesTrailingSlash() {
        let base = URL(string: "https://jelly.example.com/")!
        #expect(ClientLauncher.webRouteURL(base: base, route: "queue").absoluteString
            == "https://jelly.example.com/web/#/queue")
    }

    @Test
    func doesNotDoubleAnExistingWebSegment() {
        for raw in ["https://jelly.example.com/web", "https://jelly.example.com/web/"] {
            let base = URL(string: raw)!
            #expect(ClientLauncher.webRouteURL(base: base, route: "queue").absoluteString
                == "https://jelly.example.com/web/#/queue")
        }
    }

    @Test
    func preservesPortAndScheme() {
        let base = URL(string: "http://192.168.3.80:8096")!
        #expect(ClientLauncher.webRouteURL(base: base, route: "queue").absoluteString
            == "http://192.168.3.80:8096/web/#/queue")
    }

    @Test
    func preservesSubPathInstall() {
        let base = URL(string: "https://example.com/jellyfin")!
        #expect(ClientLauncher.webRouteURL(base: base, route: "queue").absoluteString
            == "https://example.com/jellyfin/web/#/queue")
    }

    @Test
    func dropsLeftoverFragment() {
        let base = URL(string: "https://jelly.example.com/web/#/home.html")!
        #expect(ClientLauncher.webRouteURL(base: base, route: "queue").absoluteString
            == "https://jelly.example.com/web/#/queue")
    }
}
