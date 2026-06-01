import AppKit
import Observation
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

    /// Beak direction + position, written by `OverlayWindowController` when it
    /// places the panel, so the tail points back at the overlay it opened from.
    @Environment(QueuePanelChrome.self) private var chrome

    /// The panel's outline: a rounded card with a small beak on the side facing
    /// the overlay. Reused for both the glass clip and the hairline border so
    /// the tail is part of one continuous shape with no seam.
    private var outline: BubbleWithBeak {
        BubbleWithBeak(
            edge: chrome.beakEdge,
            cornerRadius: QueuePanelBeak.cornerRadius,
            beakWidth: QueuePanelBeak.width,
            beakHeight: QueuePanelBeak.height,
            beakCenterY: chrome.beakCenterFromTop
        )
    }

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
        // Reserve the beak strip on the side facing the overlay so the header
        // and list never slide under the tail.
        .padding(chrome.beakEdge == .leading ? .leading : .trailing, QueuePanelBeak.width)
        // Dark frosted glass (the `.hudWindow` material stays dark regardless
        // of the wallpaper behind it), clipped to the card+beak outline with a
        // hairline border — the panel window itself is borderless and
        // transparent, so this is the panel's whole visible chrome.
        // `colorScheme(.dark)` keeps text and badges light over the dark glass.
        .background(GlassBackground())
        .colorScheme(.dark)
        .clipShape(outline)
        // A soft "lit-from-above" glass rim instead of a flat hairline: brighter
        // along the top edge, fading to a whisper at the bottom. Reads as a
        // polished edge rather than the murky dark contour the window's own
        // shadow left around the card.
        .overlay(
            outline.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
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

// MARK: - Panel beak (the "where it came from" tail)

/// Which vertical edge of the queue panel the beak sticks out of — always the
/// side that faces the overlay.
enum QueuePanelBeakEdge: Equatable {
    case leading   // overlay is to the panel's left  → beak points left
    case trailing  // overlay is to the panel's right → beak points right
}

/// Beak metrics, shared between the panel's drawing (`BubbleWithBeak`) and the
/// window controller that sizes and positions the panel.
enum QueuePanelBeak {
    /// Panel corner radius (kept here so the shape and the corner-avoidance
    /// clamp stay in agreement).
    static let cornerRadius: CGFloat = 12
    /// How far the beak protrudes past the card.
    static let width: CGFloat = 8
    /// Height of the beak's base where it meets the card.
    static let height: CGFloat = 18
    /// Gap left between the beak's tip and the overlay's edge.
    static let tipGap: CGFloat = 2
}

/// View-layout hints for the panel's beak, written by `OverlayWindowController`
/// when it positions the panel and read by `QueuePopover` to aim the tail. Kept
/// separate from `PlayerStore` so window geometry never leaks into the playback
/// model.
@MainActor
@Observable
final class QueuePanelChrome {
    var beakEdge: QueuePanelBeakEdge = .leading
    /// Vertical center of the beak in panel-local points, measured from the top.
    var beakCenterFromTop: CGFloat = 60
    /// Vertical center of the "Up Next" (queue) button, measured in points from
    /// the *top* of the overlay window. Published by `ControlsView` as it lays
    /// out so `OverlayWindowController` can aim the beak straight at the button
    /// it sprang from instead of at the overlay's center. `nil` until the button
    /// has been laid out (controller falls back to the overlay center).
    var queueButtonCenterFromOverlayTop: CGFloat?
}

/// Carries the queue button's vertical center (in overlay-window-top points) up
/// from `ControlsView` to the root so it can be stored on `QueuePanelChrome`.
/// A preference rather than a direct write keeps the geometry read on SwiftUI's
/// post-layout pass (no "modifying state during update" churn).
struct QueueButtonCenterKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// A rounded "card" with a small beak (speech-bubble tail) protruding from one
/// vertical edge. The card and beak form one continuous outline, so filling it
/// with glass and stroking its border draw a single seamless shape.
struct BubbleWithBeak: InsettableShape {
    var edge: QueuePanelBeakEdge
    var cornerRadius: CGFloat
    var beakWidth: CGFloat
    var beakHeight: CGFloat
    /// Vertical center of the beak, measured from the top of the shape.
    var beakCenterY: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let ia = insetAmount
        let r = max(0, cornerRadius - ia)
        let halfBase = max(0, beakHeight / 2 - ia)
        let top = rect.minY + ia
        let bottom = rect.maxY - ia
        // Keep the beak on the straight part of the edge, clear of the corners.
        let lo = top + r + halfBase
        let hi = bottom - r - halfBase
        let cy = min(max(beakCenterY, lo), max(lo, hi))

        // Card body horizontal extent: the beak strip is carved off the side
        // the tail protrudes from, so the rounded body never overlaps the beak.
        let left: CGFloat
        let right: CGFloat
        let tipX: CGFloat
        switch edge {
        case .leading:
            left = rect.minX + beakWidth + ia
            right = rect.maxX - ia
            tipX = rect.minX + ia
        case .trailing:
            left = rect.minX + ia
            right = rect.maxX - beakWidth - ia
            tipX = rect.maxX - ia
        }

        // Fraction of the tail length spanned by the softly-rounded apex, so the
        // beak ends in a gentle point rather than a sharp spike.
        let k: CGFloat = 0.35

        let tl = CGPoint(x: left, y: top)
        let tr = CGPoint(x: right, y: top)
        let br = CGPoint(x: right, y: bottom)
        let bl = CGPoint(x: left, y: bottom)

        // One continuous outline (card + beak), traced clockwise in SwiftUI's
        // y-down space. A single subpath — rather than a card plus an overlaid
        // beak — means stroking the border leaves no seam where the tail joins
        // the card. Corners use circular arcs; at r=12 the difference from a
        // `.continuous` squircle is imperceptible and buys the seamless stroke.
        var path = Path()
        switch edge {
        case .leading:
            let apexX = left + (tipX - left) * (1 - k)
            path.move(to: CGPoint(x: left + r, y: top))
            path.addArc(tangent1End: tr, tangent2End: br, radius: r)   // top-right
            path.addArc(tangent1End: br, tangent2End: bl, radius: r)   // bottom-right
            path.addArc(tangent1End: bl, tangent2End: tl, radius: r)   // bottom-left
            // up the left edge, out around the beak, back to the edge
            path.addLine(to: CGPoint(x: left, y: cy + halfBase))
            path.addLine(to: CGPoint(x: apexX, y: cy + halfBase * k))
            path.addQuadCurve(to: CGPoint(x: apexX, y: cy - halfBase * k),
                              control: CGPoint(x: tipX, y: cy))
            path.addLine(to: CGPoint(x: left, y: cy - halfBase))
            path.addArc(tangent1End: tl, tangent2End: tr, radius: r)   // top-left
        case .trailing:
            let apexX = right + (tipX - right) * (1 - k)
            path.move(to: CGPoint(x: left + r, y: top))
            path.addArc(tangent1End: tr, tangent2End: br, radius: r)   // top-right
            // down the right edge, out around the beak, back to the edge
            path.addLine(to: CGPoint(x: right, y: cy - halfBase))
            path.addLine(to: CGPoint(x: apexX, y: cy - halfBase * k))
            path.addQuadCurve(to: CGPoint(x: apexX, y: cy + halfBase * k),
                              control: CGPoint(x: tipX, y: cy))
            path.addLine(to: CGPoint(x: right, y: cy + halfBase))
            path.addArc(tangent1End: br, tangent2End: bl, radius: r)   // bottom-right
            path.addArc(tangent1End: bl, tangent2End: tl, radius: r)   // bottom-left
            path.addArc(tangent1End: tl, tangent2End: tr, radius: r)   // top-left
        }
        path.closeSubpath()
        return path
    }
}
