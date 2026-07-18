import AppKit
import SwiftUI

/// Renders the primary artwork for the currently playing item. Pulls bytes
/// from `ArtworkCache` on appear and on track change, falling back to a
/// neutral placeholder when no image is available yet.
struct ArtworkView: View {
    let itemId: String
    let imageTag: String?
    let size: CGFloat
    let cornerRadius: CGFloat
    let shadowOpacity: Double
    /// When set, the cover is loaded straight from this URL (e.g. the YouTube
    /// bridge's `artworkUrl`) instead of fetched by id through `ArtworkCache`.
    /// Sources whose artwork is id-based (Jellyfin) leave this `nil`.
    var artworkURL: URL? = nil
    /// True when the active source can raise its own window/tab (the YouTube
    /// bridge's `focusTab`). When set, a double-click invokes `onFocus` and the
    /// cover shows a pointer cursor + "go to the tab" tooltip; when false the
    /// double-click falls back to opening the Jellyfin client.
    var canFocusTab: Bool = false
    /// Invoked on double-click when `canFocusTab` is true. Wired by the theme to
    /// `PlayerStore.focusSource()`.
    var onFocus: (() -> Void)? = nil

    @Environment(ArtworkCacheProvider.self) private var provider
    @Environment(SettingsStore.self) private var settings
    @Environment(SourceRegistry.self) private var registry
    @Environment(SourceArbiter.self) private var arbiter
    @State private var image: NSImage?
    @State private var isLoading: Bool = false

    /// Key that invalidates the load task whenever the requested item, the
    /// direct artwork URL, or the availability of the cache changes. The
    /// `cacheReady` boolean is the piece that retriggers the load once
    /// `AppDelegate` finishes wiring the polling stack post-launch.
    private struct LoadKey: Hashable {
        let itemId: String
        let tag: String?
        let url: URL?
        let cacheReady: Bool
    }

    /// Shared session for direct artwork fetches (YouTube bridge URLs). Short
    /// timeout; covers are small and on a fast host.
    private static let directSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Delays between attempts at a direct-URL cover (so: three tries total).
    ///
    /// Without a retry, one transient failure is permanent. A direct-URL cover
    /// is cached nowhere — unlike Jellyfin's, which `ArtworkCache` keeps on
    /// disk — and `LoadKey` doesn't change while a track sits still, so nothing
    /// would ever re-run the load. A cover lost to a blip (the tab closing
    /// mid-fetch, a moment offline) would stay missing for as long as that
    /// track is on screen.
    private static let directFetchBackoff: [TimeInterval] = [0.5, 1.5]

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: size * 0.3, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(shadowOpacity), radius: 9, x: 0, y: 4)
        .accessibilityLabel(String(localized: "Album artwork"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(doubleClickHint)
        .help(doubleClickHint)
        // Pointer cursor only when the focus affordance is live; the Jellyfin
        // open-on-double-click fallback keeps the default cursor as before.
        .pointerStyle(canFocusTab ? .link : nil)
        .onTapGesture(count: 2) {
            if canFocusTab {
                onFocus?()
            } else if let url = settings.baseURL {
                ClientLauncher.openJellyfin(url)
            }
        }
        .contextMenu {
            AppMenuContent(settings: settings, registry: registry, arbiter: arbiter)
        }
        .task(id: LoadKey(itemId: itemId, tag: imageTag, url: artworkURL, cacheReady: provider.cache != nil)) {
            await loadImage()
        }
        .animation(.easeInOut(duration: 0.4), value: image)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }

    /// Tooltip + accessibility hint, matched to what the double-click does for
    /// the active source.
    private var doubleClickHint: String {
        canFocusTab
            ? String(localized: "Double-click to go to the YouTube tab")
            : String(localized: "Double-click to open the Jellyfin client")
    }

    private func loadImage() async {
        // Show a spinner only on the very first load. On a track change we
        // keep the previous image visible until the new one arrives so the
        // SwiftUI animation can cross-fade between them — no grey placeholder
        // flash in between.
        if image == nil { isLoading = true }
        defer { isLoading = false }

        // Direct-URL sources (YouTube bridge) bypass the id-based cache. Only
        // remote http(s) is fetched — never file:// or other schemes, so an
        // untrusted URL can't turn this into a local-file read.
        if let artworkURL {
            let scheme = artworkURL.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else {
                image = nil
                return
            }
            let loaded = await Self.retryingFetch(backoff: Self.directFetchBackoff) {
                guard let data = try? await Self.directSession.data(from: artworkURL).0 else {
                    return nil
                }
                return NSImage(data: data)
            }
            // A cancelled load belongs to a track we've already moved off;
            // let the newer load own the frame rather than clobbering it.
            guard !Task.isCancelled else { return }
            image = loaded
            return
        }

        // No cache wired yet — launch, or a server reconfigure in flight. That
        // is not an answer about *this item*, so leave whatever is on screen
        // alone; `LoadKey.cacheReady` re-runs the load once the cache arrives.
        guard let cache = provider.cache else { return }
        let data = await cache.data(forItemId: itemId, tag: imageTag)
        guard !Task.isCancelled else { return }
        // Assign unconditionally, including nil: an item with no cover has to
        // clear the previous one. The view's identity is deliberately held
        // across track changes (see `OverlayView.content`) so the cross-fade
        // works, which means anything left here shows up under the *next*
        // track's metadata.
        image = data.flatMap { NSImage(data: $0) }
    }

    /// Run `fetch` until it yields an image, waiting out `backoff` between
    /// attempts (`backoff.count + 1` tries in total). Returns nil once they're
    /// exhausted — a definitive "no cover", which the caller applies.
    ///
    /// Static and closure-driven so the retry policy is exercisable in tests
    /// without a live `URLSession` or a hosted view.
    static func retryingFetch(
        backoff: [TimeInterval],
        fetch: () async -> NSImage?
    ) async -> NSImage? {
        for attempt in 0...backoff.count {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(backoff[attempt - 1] * 1_000_000_000))
                if Task.isCancelled { return nil }
            }
            if let loaded = await fetch() { return loaded }
        }
        return nil
    }
}
