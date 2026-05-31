import AppKit
import SwiftUI

/// Popover listing the active client's play queue (`NowPlayingQueueFullItems`
/// from `/Sessions`), with the current track highlighted. Tapping a row jumps
/// the client to that track (`onSelect`). Reachable from the list button in
/// `ControlsView`.
struct QueuePopover: View {
    let queue: [QueueItem]
    /// Invoked with the tapped queue entry so the client jumps to it.
    let onSelect: (QueueItem) -> Void

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
        .background(PopoverDarkAppearance())
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
                        QueueRow(item: item) { onSelect(item) }
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

/// Reaches the popover's backing `_NSPopoverWindow` and pins its appearance to
/// dark, so the popover's own chrome (rounded frame, arrow, vibrant material)
/// matches the dark overlay regardless of the system's Light/Dark setting.
/// `colorScheme(.dark)` alone only affects SwiftUI content, not that chrome.
///
/// The appearance must be set when the view actually enters its window —
/// doing it in `updateNSView` is unreliable because that first runs while the
/// view's `window` is still nil and SwiftUI may not call it again. A custom
/// `NSView` overriding `viewDidMoveToWindow` fires at exactly the right moment.
private struct PopoverDarkAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AppearancePinningView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AppearancePinningView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// One queue entry: thumbnail + title/artist, with the now-playing row tinted
/// and badged. Tapping a non-current row jumps the client to that track; the
/// row highlights on hover (with a play glyph) to read as actionable.
private struct QueueRow: View {
    let item: QueueItem
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                QueueThumbnail(itemId: item.itemId, imageTag: item.imageTag)
                    .frame(width: 36, height: 36)
                    .overlay {
                        // On hover over an upcoming row, hint that tapping plays
                        // it by darkening the thumbnail under a play glyph.
                        if isHovered && !item.isCurrent {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.black.opacity(0.45))
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
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
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Drop the blue keyboard-focus ring macOS puts on the focused button
        // (matches the transport controls, which do the same).
        .focusEffectDisabled()
        // The current track is already playing — nothing to jump to.
        .disabled(item.isCurrent)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if item.isCurrent { return Color.primary.opacity(0.06) }
        return isHovered ? Color.primary.opacity(0.10) : Color.clear
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
