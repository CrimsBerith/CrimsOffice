import SwiftUI

// MARK: - macOS Tahoe 26+ Native Liquid Glass & Multi-Layer Frosted Fallbacks

/// Subtle atmospheric canvas placed behind glass toolbars and cards so translucency & refraction stay legible in both Light and Dark mode.
struct AmbientGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var accent: Color = .blue

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.055, green: 0.070, blue: 0.115), Color(red: 0.035, green: 0.045, blue: 0.080)]
                    : [Color(red: 0.945, green: 0.962, blue: 0.988), Color(red: 0.895, green: 0.925, blue: 0.968)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    accent.opacity(colorScheme == .dark ? 0.16 : 0.14),
                    accent.opacity(0.0)
                ],
                center: UnitPoint(x: 0.15, y: 0.12),
                startRadius: 20,
                endRadius: 520
            )

            RadialGradient(
                colors: [
                    Color.purple.opacity(colorScheme == .dark ? 0.12 : 0.09),
                    Color.purple.opacity(0.0)
                ],
                center: UnitPoint(x: 0.88, y: 0.20),
                startRadius: 20,
                endRadius: 460
            )

            RadialGradient(
                colors: [
                    Color.cyan.opacity(colorScheme == .dark ? 0.10 : 0.09),
                    Color.cyan.opacity(0.0)
                ],
                center: UnitPoint(x: 0.72, y: 0.88),
                startRadius: 20,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

/// Groups adjacent Liquid Glass views on macOS 26+ into a shared optical container.
struct LiquidGlassContainer<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 16
    var tint: Color? = nil
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder((tint ?? Color.primary).opacity(0.28), lineWidth: 1)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.10), radius: 8, y: 3)
        } else if #available(macOS 26.0, *) {
            let baseGlass: Glass = {
                var g = Glass.regular
                if let tint {
                    g = g.tint(tint.opacity(colorScheme == .dark ? 0.22 : 0.16))
                }
                if interactive {
                    g = g.interactive()
                }
                return g
            }()
            content
                .glassEffect(baseGlass, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.24 : 0.55),
                                    Color.white.opacity(0.04),
                                    (tint ?? .white).opacity(colorScheme == .dark ? 0.14 : 0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 14, y: 6)
        } else {
            content
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(colorScheme == .dark ? 0.11 : 0.08))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.26 : 0.65),
                                    Color.white.opacity(0.05),
                                    (tint ?? .primary).opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.08), radius: 12, y: 5)
        }
    }
}

struct LiquidGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var tint: Color? = nil
    var interactive: Bool = true

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder((tint ?? Color.primary).opacity(0.32), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            let baseGlass: Glass = {
                var g = Glass.regular
                if let tint {
                    g = g.tint(tint.opacity(colorScheme == .dark ? 0.26 : 0.18))
                }
                if interactive {
                    g = g.interactive()
                }
                return g
            }()
            content
                .glassEffect(baseGlass, in: .capsule)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.28 : 0.55),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.7
                        )
                )
        } else {
            content
                .background(
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        if let tint {
                            Capsule().fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            (tint ?? Color.white).opacity(colorScheme == .dark ? 0.28 : 0.40),
                            lineWidth: 0.85
                        )
                )
        }
    }
}

struct LiquidGlassBarModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        Rectangle().fill(.ultraThinMaterial)
                        if let tint {
                            tint.opacity(colorScheme == .dark ? 0.07 : 0.05)
                        }
                    }
                }
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    .frame(height: 0.5)
            }
    }
}

struct GlassActionButtonModifier: ViewModifier {
    var prominent: Bool = false
    var tint: Color? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content
                    .buttonStyle(.glassProminent)
                    .tint(tint ?? .accentColor)
            } else {
                content
                    .buttonStyle(.glass)
                    .tint(nil)
            }
        } else {
            if prominent {
                content
                    .buttonStyle(.borderedProminent)
                    .tint(tint ?? .accentColor)
            } else {
                content
                    .buttonStyle(.bordered)
                    .tint(tint)
            }
        }
    }
}

/// Smoked dark glass container used for terminal output, command consoles, and code blocks.
struct SmokedGlassSurface<Content: View>: View {
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.colorScheme, .dark)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.065, blue: 0.105).opacity(0.88))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.35))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.26), radius: 10, y: 4)
    }
}

/// Consistent section hero banner with glass medallion icon.
struct GlassSectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(0.45), lineWidth: 1)
                    )
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    func liquidGlassCard(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(LiquidGlassCapsuleModifier(tint: tint, interactive: interactive))
    }

    func liquidGlassBar(tint: Color? = nil) -> some View {
        modifier(LiquidGlassBarModifier(tint: tint))
    }

    func liquidGlassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassActionButtonModifier(prominent: prominent, tint: tint))
    }
}
