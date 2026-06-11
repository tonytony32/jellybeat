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

    @Environment(ArtworkCacheProvider.self) private var provider
    @Environment(SettingsStore.self) private var settings
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
        .accessibilityHint(String(localized: "Double-click to open the Jellyfin client"))
        .help(String(localized: "Double-click to open Jellyfin"))
        .onTapGesture(count: 2) {
            if let url = settings.baseURL {
                ClientLauncher.openJellyfin(url)
            }
        }
        .task(id: LoadKey(itemId: itemId, tag: imageTag, url: artworkURL, cacheReady: provider.cache != nil)) {
            await loadImage()
        }
        .animation(.easeInOut(duration: 0.4), value: image)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
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
            if scheme == "http" || scheme == "https",
               let data = try? await Self.directSession.data(from: artworkURL).0 {
                image = NSImage(data: data)
            }
            return
        }

        guard let cache = provider.cache else { return }
        if let data = await cache.data(forItemId: itemId, tag: imageTag) {
            image = NSImage(data: data)
        }
    }
}
