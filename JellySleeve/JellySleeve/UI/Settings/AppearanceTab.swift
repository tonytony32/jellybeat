import SwiftUI

/// Theme switcher (grid of built-in themes) plus the cross-theme overlay
/// preferences from plan §6 Fase 6.
struct AppearanceTab: View {
    @Environment(ThemeRegistry.self) private var themes
    @Environment(SettingsStore.self) private var settings

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 12)]

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Themes grid
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme")
                        .font(.headline)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(themes.builtIn, id: \.id) { theme in
                            ThemeCard(
                                theme: theme,
                                isSelected: theme.id == themes.selectedId,
                                onSelect: { themes.select(theme.id) }
                            )
                        }
                    }
                }

                // Overlay-wide preferences
                VStack(alignment: .leading, spacing: 10) {
                    Text("Overlay")
                        .font(.headline)
                    Form {
                        Picker("Window level", selection: $settings.windowLevel) {
                            ForEach(OverlayWindowLevel.allCases) { level in
                                Text(level.displayName).tag(level)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Slider(
                                value: $settings.windowOpacity,
                                in: 0.5...1.0
                            ) {
                                Text("Window opacity")
                            } minimumValueLabel: {
                                Text("50%").font(.caption2).monospacedDigit()
                            } maximumValueLabel: {
                                Text("100%").font(.caption2).monospacedDigit()
                            }
                            Text(String(format: "Currently %.0f%%.", settings.windowOpacity * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .padding()
        }
    }
}

/// Selectable card for one built-in theme. Renders a schematic preview based
/// on the theme's LayoutSpec.
private struct ThemeCard: View {
    let theme: any OverlayTheme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ThemeThumbnail(theme: theme)
                    .frame(width: 120, height: 90)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }
                VStack(spacing: 1) {
                    Text(theme.displayName)
                        .font(.callout)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(theme.author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isSelected {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
            .padding(8)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .contentShape(Rectangle())
    }
}

/// Quick schematic of where the artwork / text / controls sit. Not a
/// pixel-perfect preview — just a recognisable silhouette per theme.
private struct ThemeThumbnail: View {
    let theme: any OverlayTheme

    var body: some View {
        let layout = theme.layout
        switch layout.orientation {
        case .vertical:
            VStack(spacing: 4) {
                if let size = layout.artworkSize, size > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.35))
                        .aspectRatio(1, contentMode: .fit)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Capsule().fill(.primary.opacity(0.55)).frame(height: 4)
                    Capsule().fill(.secondary.opacity(0.55)).frame(width: 50, height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if layout.controlsPosition == .below {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(.secondary.opacity(0.6))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(8)
        case .horizontal:
            HStack(spacing: 6) {
                if let size = layout.artworkSize, size > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.35))
                        .aspectRatio(1, contentMode: .fit)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(.primary.opacity(0.55)).frame(height: 4)
                    Capsule().fill(.secondary.opacity(0.55)).frame(width: 40, height: 3)
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(.secondary.opacity(0.6))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .padding(8)
        case .minimal:
            HStack(spacing: 6) {
                Capsule().fill(.primary.opacity(0.55)).frame(height: 4)
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 20, height: 3)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(.secondary.opacity(0.6))
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

#Preview {
    AppearanceTab()
        .environment(ThemeRegistry())
        .environment(SettingsStore())
        .frame(width: 520, height: 420)
}
