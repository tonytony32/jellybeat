import AppKit
import SwiftUI

/// Popover listing the active client's play queue (`NowPlayingQueueFullItems`
/// from `/Sessions`). Read-only: Jellyfin exposes the queue but no "jump to
/// this entry" session command, so this is a preview of what's playing and
/// what's up next, with the current track highlighted. Reachable from the
/// list button in `ControlsView`.
struct QueuePopover: View {
    let queue: [QueueItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            if queue.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 380)
        // The overlay always renders as a dark HUD, but a popover lives in its
        // own window whose default *vibrant* material blurs whatever bright
        // content sits behind it — over a light wallpaper that reads near-white
        // and clashed. Rather than flatten it with an opaque fill, lay the same
        // `.hudWindow` glass the overlay uses over the content: that material is
        // dark by design (it stays dark regardless of what's behind), so the
        // popover keeps its translucent frosted feel while reliably reading
        // dark. `darkAqua` on the window then darkens the remaining chrome
        // (the arrow); `colorScheme(.dark)` keeps text/badges light over it.
        .background(GlassBackground())
        .colorScheme(.dark)
        .background(PopoverChromeStyler())
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing up next")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The player isn't reporting a queue.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue) { item in
                        QueueRow(item: item)
                            .id(item.id)
                        if item.id != queue.last?.id {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }
            .onAppear {
                // Surface the current track so the user sees "what's next"
                // without scrolling, even deep into a long queue.
                if let current = queue.first(where: { $0.isCurrent }) {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }
}

/// Reaches into the popover's backing `_NSPopoverWindow` and restyles its
/// *own* chrome so there's no contrasting rim around the content.
///
/// The system popover paints its frame, arrow and a pale rounded border with a
/// vibrant material that follows the system appearance — on a Light-mode Mac
/// that border reads as a bright outline around our dark content. Two steps fix
/// it: pin the window to `darkAqua`, then walk the window's view tree and switch
/// every `NSVisualEffectView` (the popover's background + border + arrow) to the
/// same dark `.hudWindow` glass the content uses. Chrome and content then share
/// one material, so the border effectively disappears (or is just a faint dark
/// edge), with no double-layer rim.
///
/// This runs from `viewDidMoveToWindow` — the moment the view is actually
/// attached to the popover window. Doing it in `updateNSView` is unreliable
/// because that first fires while `window` is still nil.
private struct PopoverChromeStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StylerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            // Start from the frame view (superview of contentView) so the
            // border/arrow effect views are included, not just the content's.
            let root = window.contentView?.superview ?? window.contentView
            root.map(Self.darken)
        }

        private static func darken(_ view: NSView) {
            if let fx = view as? NSVisualEffectView {
                fx.material = .hudWindow
                fx.blendingMode = .behindWindow
                fx.state = .active
                fx.appearance = NSAppearance(named: .darkAqua)
            }
            for sub in view.subviews { darken(sub) }
        }
    }
}

/// One queue entry: thumbnail + title/artist, with the now-playing row tinted
/// and badged.
private struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: 10) {
            QueueThumbnail(itemId: item.itemId, imageTag: item.imageTag)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .fontWeight(item.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if item.isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(item.isCurrent ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// Small album-art thumbnail backed by the same `ArtworkCache` the main
/// `ArtworkView` uses, so the current track's cover is already warm and the
/// upcoming items pre-fetch into the shared cache.
private struct QueueThumbnail: View {
    let itemId: String
    let imageTag: String?

    @Environment(ArtworkCacheProvider.self) private var provider
    @State private var image: NSImage?

    private struct LoadKey: Hashable {
        let itemId: String
        let tag: String?
        let ready: Bool
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .task(id: LoadKey(itemId: itemId, tag: imageTag, ready: provider.cache != nil)) {
                guard let cache = provider.cache else { return }
                if let data = await cache.data(forItemId: itemId, tag: imageTag) {
                    image = NSImage(data: data)
                }
            }
    }
}
