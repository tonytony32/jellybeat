import SwiftUI

/// Three-line track readout. Each theme passes its own `TypographySpec` so the
/// font scale, weights, and opacities can vary while the markup stays the same.
struct TrackInfoView: View {
    let track: TrackSnapshot
    let typography: TypographySpec

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .font(typography.title.font)
                .fontWeight(typography.title.weight)
                .opacity(typography.title.opacity)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(track.artist)
                .font(typography.artist.font)
                .fontWeight(typography.artist.weight)
                .opacity(typography.artist.opacity)
                .lineLimit(1)
                .truncationMode(.tail)

            if typography.showAlbum, !track.album.isEmpty {
                Text(track.album)
                    .font(typography.album.font)
                    .fontWeight(typography.album.weight)
                    .opacity(typography.album.opacity)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
