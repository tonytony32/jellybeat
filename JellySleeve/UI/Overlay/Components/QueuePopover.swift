import AppKit
import SwiftUI

/// Live wrapper hosted in the queue side-panel window: reads the queue from the
/// store so the list updates as playback advances, and jumps the client to a
/// tapped row (closing the panel). The window itself is created and positioned
/// by `OverlayWindowController` — to the right of the overlay, so it never
/// covers the now-playing frame and never pushes the overlay around.
struct QueuePanelView: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        QueuePopover(queue: player.queue) { item in
            player.isQueuePopoverOpen = false
            Task { @MainActor in await player.playQueueItem(item) }
        }
    }
}

/// The play-queue list ("Up Next") with the current track highlighted. Tapping
/// a row jumps the client to that track (`onSelect`). Rendered inside the
/// side-panel window managed by `OverlayWindowController`.
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
        // Dark frosted glass (the `.hudWindow` material stays dark regardless
        // of the wallpaper behind it), clipped to a rounded rect with a hairline
        // border — the panel window itself is borderless and transparent, so
        // this is the panel's whole visible chrome. `colorScheme(.dark)` keeps
        // text and badges light over the dark material.
        .background(GlassBackground())
        .colorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
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
