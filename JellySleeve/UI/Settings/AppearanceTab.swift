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

/// Schematic miniature of each theme. Not pixel-perfect, but it mirrors the
/// traits that actually tell the four apart at a glance — which the old
/// orientation-only schematic couldn't (Standard and Aero rendered
/// identically). It keys off each theme's real `LayoutSpec`/`BehaviorSpec`:
///
/// - **Silhouette**: the preview takes the theme's window aspect ratio, so
///   Standard/Aero read as portrait, Classic as landscape, Minim as a thin bar.
/// - **Frame**: glass themes (Standard, Minim) sit in a frosted panel; floating
///   themes (Classic, Aero) render straight on the desktop with a drop shadow.
/// - **Controls**: overlaid as a pill on the artwork, in a row below, or beside
///   the text — matching `controlsPosition`.
private struct ThemeThumbnail: View {
    let theme: any OverlayTheme

    var body: some View {
        let size = theme.layout.windowSize
        GeometryReader { geo in
            schematic(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }

    private func schematic(width w: CGFloat, height h: CGFloat) -> some View {
        let layout = theme.layout
        let behavior = theme.behavior
        let inset = max(3, min(w, h) * 0.08)
        let scale = w / max(layout.windowSize.width, 1)
        let panelRadius = max(3, layout.cornerRadius * scale)

        return Group {
            switch layout.orientation {
            case .vertical: verticalBody(w: w, h: h, inset: inset)
            case .horizontal: horizontalBody(w: w, h: h, inset: inset)
            case .minimal: minimalBody(w: w, h: h, inset: inset)
            }
        }
        .background {
            // Glass themes sit in a frosted panel; floating themes (Classic,
            // Aero) show their elements straight on the card behind.
            if behavior.hasGlassBackground {
                RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }

    // MARK: Per-orientation layouts

    /// Standard / Aero: big artwork on top with a control pill overlaid on its
    /// lower edge, info + progress below.
    private func verticalBody(w: CGFloat, h: CGFloat, inset: CGFloat) -> some View {
        let innerW = w - inset * 2
        let line = max(2.5, h * 0.045)
        return VStack(alignment: .leading, spacing: inset * 0.8) {
            artwork(side: innerW, floating: !theme.behavior.hasGlassBackground)
                .overlay(alignment: .bottom) {
                    controlBar(scale: innerW * 0.8, boxed: theme.behavior.controlsHasBackground)
                        .padding(.bottom, max(2, innerW * 0.06))
                }
            textLines(width: innerW, line: line)
            progressLine(width: innerW)
            Spacer(minLength: 0)
        }
        .padding(inset)
        .frame(width: w, height: h, alignment: .topLeading)
    }

    /// Classic: small square artwork on the left, info + progress + a control
    /// row stacked on the right.
    private func horizontalBody(w: CGFloat, h: CGFloat, inset: CGFloat) -> some View {
        let artSide = h - inset * 2
        let rightW = max(0, w - artSide - inset * 3)
        let line = max(2.2, h * 0.09)
        return HStack(alignment: .center, spacing: inset) {
            artwork(side: artSide, floating: !theme.behavior.hasGlassBackground)
            VStack(alignment: .leading, spacing: line * 0.6) {
                textLines(width: rightW, line: line)
                progressLine(width: rightW)
                controlBar(scale: rightW, boxed: theme.behavior.controlsHasBackground)
            }
            .frame(width: rightW, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(inset)
        .frame(width: w, height: h, alignment: .leading)
    }

    /// Minim: no artwork — two short text lines on the left, controls beside
    /// them on the right.
    private func minimalBody(w: CGFloat, h: CGFloat, inset: CGFloat) -> some View {
        let line = max(2.5, h * 0.16)
        return HStack(spacing: inset * 1.5) {
            VStack(alignment: .leading, spacing: line * 0.7) {
                Capsule().fill(.primary.opacity(0.7)).frame(width: w * 0.34, height: line)
                Capsule().fill(.primary.opacity(0.5)).frame(width: w * 0.22, height: line * 0.85)
            }
            Spacer(minLength: 0)
            controlBar(scale: w * 0.42, boxed: theme.behavior.controlsHasBackground)
        }
        .padding(.horizontal, inset * 1.6)
        .padding(.vertical, inset)
        .frame(width: w, height: h)
    }

    // MARK: Pieces

    private func artwork(side: CGFloat, floating: Bool) -> some View {
        RoundedRectangle(cornerRadius: max(2, side * 0.06), style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: side, height: side)
            .shadow(
                color: .black.opacity(floating ? 0.35 : 0.12),
                radius: floating ? max(1.5, side * 0.07) : 1,
                y: floating ? max(1, side * 0.03) : 0.5
            )
    }

    @ViewBuilder
    private func textLines(width: CGFloat, line: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: line * 0.6) {
            Capsule().fill(.primary.opacity(0.7)).frame(width: width * 0.9, height: line)
            Capsule().fill(.primary.opacity(0.5)).frame(width: width * 0.6, height: line * 0.85)
            if theme.typography.showAlbum {
                Capsule().fill(.primary.opacity(0.35)).frame(width: width * 0.72, height: line * 0.8)
            }
        }
    }

    private func progressLine(width: CGFloat) -> some View {
        let barH = max(1.5, width * 0.03)
        return Capsule().fill(.primary.opacity(0.22))
            .frame(width: width, height: barH)
            .overlay(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.55)).frame(width: width * 0.42, height: barH)
            }
    }

    /// The transport cluster: prev · play · next, then favourite · queue. The
    /// pill background appears only when the theme floats its controls
    /// (`controlsHasBackground`).
    private func controlBar(scale: CGFloat, boxed: Bool) -> some View {
        let d = max(2.2, scale * 0.085)
        return HStack(spacing: d * 0.7) {
            dot(d)
            dot(d * 1.3)
            dot(d)
            dot(d * 0.9)
            dot(d * 0.9)
        }
        .padding(.horizontal, boxed ? d * 1.1 : 0)
        .padding(.vertical, boxed ? d * 0.5 : 0)
        .background {
            if boxed {
                Capsule(style: .continuous).fill(.regularMaterial)
            }
        }
    }

    private func dot(_ d: CGFloat) -> some View {
        Circle().fill(.primary.opacity(0.75)).frame(width: d, height: d)
    }
}

#Preview {
    AppearanceTab()
        .environment(ThemeRegistry())
        .environment(SettingsStore())
        .frame(width: 520, height: 420)
}
