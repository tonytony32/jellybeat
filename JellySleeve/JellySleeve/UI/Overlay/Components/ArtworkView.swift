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

    @Environment(ArtworkCacheProvider.self) private var provider
    @State private var image: NSImage?

    /// Key that invalidates the load task whenever either the requested item
    /// or the availability of the cache changes. The `cacheReady` boolean is
    /// the piece that retriggers the load once `AppDelegate` finishes wiring
    /// the polling stack post-launch.
    private struct LoadKey: Hashable {
        let itemId: String
        let tag: String?
        let cacheReady: Bool
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(shadowOpacity), radius: 6, x: 0, y: 2)
        .task(id: LoadKey(itemId: itemId, tag: imageTag, cacheReady: provider.cache != nil)) {
            await loadImage()
        }
        .animation(.easeInOut(duration: 0.4), value: image)
    }

    private func loadImage() async {
        guard let cache = provider.cache else { return }
        if let data = await cache.data(forItemId: itemId, tag: imageTag) {
            image = NSImage(data: data)
        }
    }
}
