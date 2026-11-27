import SwiftUI
import AppKit

enum AvatarImageLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    static func nsImage(named assetName: String) -> NSImage? {
        guard !assetName.isEmpty else { return nil }
        let key = assetName as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let url = Bundle.module.url(forResource: assetName, withExtension: "png", subdirectory: "avatars"),
           let img = NSImage(contentsOf: url) {
            cache.setObject(img, forKey: key)
            return img
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("avatars/\(assetName).png"),
           let img = NSImage(contentsOf: resURL) {
            cache.setObject(img, forKey: key)
            return img
        }
        return nil
    }
}

enum AvatarDisplayMode {
    case compactBadge
    case floorSprite
}

struct CrimsBrandLogoView: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let nsImg = AvatarImageLoader.nsImage(named: "crims_logo") {
                Image(nsImage: nsImg)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                    .shadow(color: Color(hex: "#E11D48").opacity(0.45), radius: 5, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#9F1239"), Color(hex: "#E11D48")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "flame.fill")
                        .font(.system(size: size * 0.52, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
    }
}

struct AgentAvatarView: View {
    let agent: OfficeAgent
    var size: CGFloat = 44
    var showStatusDot: Bool = true
    var isSelected: Bool = false
    var isWalking: Bool = false
    var facingLeft: Bool = false
    var mode: AvatarDisplayMode = .compactBadge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Color(hex: agent.accentHex) }
    private var resolvedAsset: String { OfficeAvatarPreset.resolvedAsset(for: agent) }

    private var statusColor: Color {
        switch agent.status {
        case .idle: return .green
        case .chatting: return .teal
        case .thinking: return .cyan
        case .working: return .purple
        case .runningTool: return .orange
        case .collaborating: return .blue
        case .improving: return .mint
        case .error: return .red
        }
    }

    var body: some View {
        switch mode {
        case .compactBadge:
            compactBody
        case .floorSprite:
            floorSpriteBody
        }
    }

    private var compactBody: some View {
        ZStack {
            if agent.status.isBusy || agent.status == .chatting {
                PulseRingView(color: statusColor, size: size)
            } else if isSelected {
                Circle()
                    .stroke(accent.opacity(0.70), lineWidth: 2.0)
                    .frame(width: size + 6, height: size + 6)
                    .shadow(color: accent.opacity(0.45), radius: 5)
            }

            if let nsImg = AvatarImageLoader.nsImage(named: resolvedAsset) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.32), Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.75)],
                            center: .center,
                            startRadius: 1,
                            endRadius: size * 0.6
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Image(nsImage: nsImg)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .scaleEffect(1.85, anchor: .top)
                            .offset(y: size * 0.18)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    )
                    .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.78 : 0.45), lineWidth: 1.5))
                    .shadow(color: accent.opacity(0.35), radius: 5, y: 2)
            } else {
                fallbackBadge
            }

            if showStatusDot {
                Circle()
                    .fill(statusColor)
                    .frame(width: max(8, size * 0.24), height: max(8, size * 0.24))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.6))
                    .shadow(color: statusColor.opacity(0.6), radius: 2)
                    .offset(x: size * 0.35, y: size * 0.35)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(agent.name), \(agent.status.rawValue)"))
    }

    private var floorSpriteBody: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phaseOffset = Double(abs(agent.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % 100) * 0.07
            let activeMotion = !reduceMotion
            let freq = isWalking ? 8.6 : ((agent.status.isBusy || agent.status == .chatting) ? 3.2 : 1.7)
            let cycle = (t + phaseOffset) * freq
            let stepBounce: CGFloat = !activeMotion ? 0 : (isWalking ? CGFloat(abs(sin(cycle)) * -6.5) : CGFloat(sin(cycle) * -1.3))
            let bodyTilt: Double = !activeMotion ? 0 : (isWalking ? sin(cycle) * 3.8 : sin(cycle * 0.8) * 0.7)
            let shadowScale: CGFloat = !activeMotion ? 1.0 : (isWalking ? CGFloat(0.84 + 0.18 * abs(cos(cycle))) : 1.0)
            let pulseScale: CGFloat = !activeMotion ? 1.0 : CGFloat(0.95 + 0.22 * abs(sin(cycle * 0.55)))

            ZStack(alignment: .bottom) {
                // Luminous ground aura & dynamic sandal contact shadow
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                (isWalking || agent.status.isBusy || isSelected ? accent : Color.black)
                                    .opacity(isWalking || agent.status.isBusy || isSelected ? 0.45 : 0.32),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: size * 0.42
                        )
                    )
                    .frame(width: size * 0.78, height: max(12, size * 0.20))
                    .scaleEffect(x: shadowScale, y: shadowScale)
                    .offset(y: 4)

                if isWalking || agent.status.isBusy || agent.status == .chatting {
                    Ellipse()
                        .stroke((isWalking ? accent : statusColor).opacity(0.75), lineWidth: isWalking ? 2.1 : 1.7)
                        .frame(width: size * 0.70, height: max(10, size * 0.17))
                        .scaleEffect(pulseScale)
                        .opacity(isWalking ? 0.85 : 0.65)
                        .offset(y: 3)
                } else if isSelected {
                    Ellipse()
                        .stroke(accent.opacity(0.85), lineWidth: 2.0)
                        .frame(width: size * 0.72, height: max(11, size * 0.18))
                        .shadow(color: accent.opacity(0.65), radius: 6)
                        .offset(y: 3)
                }

                if let nsImg = AvatarImageLoader.nsImage(named: resolvedAsset) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: size)
                        .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
                        .rotationEffect(.degrees(bodyTilt), anchor: .bottom)
                        .shadow(color: (isSelected ? accent : .black).opacity(isSelected ? 0.55 : 0.32), radius: isSelected ? 8 : 4, y: 2)
                        .offset(y: stepBounce)
                } else {
                    fallbackBadge
                }

                if showStatusDot {
                    Circle()
                        .fill(isWalking ? accent : statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.6))
                        .shadow(color: (isWalking ? accent : statusColor).opacity(0.8), radius: 3)
                        .offset(x: size * 0.24, y: -size * 0.78 + stepBounce)
                }
            }
            .frame(width: max(52, size * 0.76), height: size + 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(agent.name), \(isWalking ? "Yürüyor" : agent.status.rawValue)"))
        }
    }

    private var fallbackBadge: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        accent.opacity(0.96),
                        accent.opacity(0.72),
                        Color(red: 0.07, green: 0.10, blue: 0.17)
                    ],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: size * 0.95
                )
            )
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1.3))
            .overlay(
                Text(agent.emoji.isEmpty ? "✨" : agent.emoji)
                    .font(.system(size: size * 0.46))
            )
            .shadow(color: accent.opacity(isSelected ? 0.50 : 0.32), radius: isSelected ? 8 : 5, y: 2.5)
    }
}

struct BikiniAvatarPickerStrip: View {
    @Binding var selectedAsset: String
    var accentHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ofis Çalışanı Karakteri (Bikinili UI)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(OfficeAvatarPreset.allPresets) { preset in
                        let isSel = selectedAsset == preset.assetName
                        Button {
                            selectedAsset = preset.assetName
                        } label: {
                            VStack(spacing: 4) {
                                if let img = AvatarImageLoader.nsImage(named: preset.assetName) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 44, height: 64)
                                } else {
                                    Image(systemName: "person.fill")
                                        .frame(width: 44, height: 64)
                                }
                                Text(preset.label.components(separatedBy: " · ").first ?? preset.label)
                                    .font(.system(size: 8.5, weight: isSel ? .bold : .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(width: 68)
                            .liquidGlassCard(
                                cornerRadius: 11,
                                tint: isSel ? Color(hex: accentHex) : nil,
                                interactive: true
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(isSel ? Color(hex: accentHex) : .clear, lineWidth: 1.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct PulseRingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let size: CGFloat
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.55), lineWidth: 2.2)
            .frame(width: size * 1.16, height: size * 1.16)
            .scaleEffect(reduceMotion ? 1.05 : (animate ? 1.18 : 0.94))
            .opacity(reduceMotion ? 0.65 : (animate ? 0.08 : 0.88))
            .onAppear {
                guard !reduceMotion else { return }
                animate = false
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}
