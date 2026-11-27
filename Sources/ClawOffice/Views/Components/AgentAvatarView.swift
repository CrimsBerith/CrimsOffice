import SwiftUI
import AppKit

enum AvatarImageLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    /// Paketlenmiş .app içinde Bundle.module fatalError riskine girmeden güvenli görsel yükleyici
    /// (swift test ortamında ise Bundle.module fallback'i ile tüm asset testlerini geçirir)
    static func nsImage(named assetName: String) -> NSImage? {
        guard !assetName.isEmpty else { return nil }
        let key = assetName as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let directCandidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("avatars/\(assetName).png"),
            Bundle.main.resourceURL?.appendingPathComponent("ClawOffice_ClawOffice.bundle/avatars/\(assetName).png"),
            Bundle.main.bundleURL.appendingPathComponent("ClawOffice_ClawOffice.bundle/avatars/\(assetName).png"),
            Bundle.main.url(forResource: assetName, withExtension: "png", subdirectory: "avatars"),
            safeSwiftPMResourceBundle()?.url(forResource: assetName, withExtension: "png", subdirectory: "avatars")
        ]

        for url in directCandidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                cache.setObject(img, forKey: key)
                return img
            }
        }

        // Son çare: yalnızca .app olmayan geliştirme / XCTest ortamında Bundle.module kullan
        if !Bundle.main.bundlePath.hasSuffix(".app"),
           let url = Bundle.module.url(forResource: assetName, withExtension: "png", subdirectory: "avatars"),
           let img = NSImage(contentsOf: url) {
            cache.setObject(img, forKey: key)
            return img
        }

        return nil
    }

    private static func safeSwiftPMResourceBundle() -> Bundle? {
        let bundleName = "ClawOffice_ClawOffice.bundle"
        let searchRoots: [URL] = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL ?? Bundle.main.bundleURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/release")
        ]
        for root in searchRoots {
            let candidate = root.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: candidate.path),
               let b = Bundle(url: candidate) {
                return b
            }
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

// MARK: - 10 Chibi Geliştirici Stil Profili

private struct ChibiCharacterStyle {
    enum OutfitKind {
        case hoodie, aloha, tee, floral, denim, cardigan, jacket
    }
    enum HairStyle {
        case spikyShort, neatShort, fluffyWaves, longWavy, twinTails, ponytail, bob
    }
    enum AccessoryKind {
        case headsetMic, headset, glassesHeadset, visorHeadset
    }

    let skinLight: Color
    let skin: Color
    let skinShade: Color
    let hair: Color
    let hairDeep: Color
    let hairHighlight: Color
    let topPrimary: Color
    let topDeep: Color
    let topAccent: Color
    let shortsColor: Color
    let shoeColor: Color
    let headsetColor: Color
    let eyeColor: Color
    let hairStyle: HairStyle
    let outfit: OutfitKind
    let accessory: AccessoryKind

    static func resolve(assetName: String, fallbackAccent: String) -> ChibiCharacterStyle {
        switch assetName {
        case "bikini_crimson":
            return .init(
                skinLight: Color(hex: "#FDE2CF"), skin: Color(hex: "#F5CBB0"), skinShade: Color(hex: "#DFA584"),
                hair: Color(hex: "#523225"), hairDeep: Color(hex: "#2E1A13"), hairHighlight: Color(hex: "#7D4E3B"),
                topPrimary: Color(hex: "#8F2535"), topDeep: Color(hex: "#671624"), topAccent: .white,
                shortsColor: Color(hex: "#5D6C7D"), shoeColor: Color(hex: "#5A3D36"), headsetColor: Color(hex: "#8FA8C8"),
                eyeColor: Color(hex: "#4B2B1C"), hairStyle: .spikyShort, outfit: .hoodie, accessory: .headsetMic
            )
        case "bikini_cyan":
            return .init(
                skinLight: Color(hex: "#F2C7A7"), skin: Color(hex: "#E1AC84"), skinShade: Color(hex: "#BE8359"),
                hair: Color(hex: "#232B38"), hairDeep: Color(hex: "#121720"), hairHighlight: Color(hex: "#4A5973"),
                topPrimary: Color(hex: "#DF7241"), topDeep: Color(hex: "#B54A22"), topAccent: Color(hex: "#F6BE65"),
                shortsColor: Color(hex: "#4F5B69"), shoeColor: Color(hex: "#435368"), headsetColor: Color(hex: "#38414E"),
                eyeColor: Color(hex: "#234978"), hairStyle: .neatShort, outfit: .aloha, accessory: .glassesHeadset
            )
        case "bikini_mint":
            return .init(
                skinLight: Color(hex: "#FFE4D1"), skin: Color(hex: "#F6CEB4"), skinShade: Color(hex: "#DDA585"),
                hair: Color(hex: "#F0C35A"), hairDeep: Color(hex: "#C59333"), hairHighlight: Color(hex: "#FFF0B3"),
                topPrimary: Color(hex: "#1CCBB7"), topDeep: Color(hex: "#0D9A8D"), topAccent: .white,
                shortsColor: Color(hex: "#EA6A5E"), shoeColor: Color(hex: "#397976"), headsetColor: Color(hex: "#6E8547"),
                eyeColor: Color(hex: "#1E6F64"), hairStyle: .fluffyWaves, outfit: .tee, accessory: .headset
            )
        case "bikini_lavender":
            return .init(
                skinLight: Color(hex: "#FFE6D8"), skin: Color(hex: "#F9D6C3"), skinShade: Color(hex: "#DEB097"),
                hair: Color(hex: "#71452C"), hairDeep: Color(hex: "#4A2A1A"), hairHighlight: Color(hex: "#9E6644"),
                topPrimary: Color(hex: "#4ED16E"), topDeep: Color(hex: "#2CA34B"), topAccent: Color(hex: "#FCEB6E"),
                shortsColor: Color(hex: "#F2695E"), shoeColor: .white, headsetColor: Color(hex: "#BD7CE6"),
                eyeColor: Color(hex: "#522E1C"), hairStyle: .longWavy, outfit: .floral, accessory: .headsetMic
            )
        case "bikini_gold":
            return .init(
                skinLight: Color(hex: "#FFE2CD"), skin: Color(hex: "#F5CEB5"), skinShade: Color(hex: "#D6A183"),
                hair: Color(hex: "#D89E54"), hairDeep: Color(hex: "#A56F2F"), hairHighlight: Color(hex: "#F8D59B"),
                topPrimary: Color(hex: "#6991BB"), topDeep: Color(hex: "#456891"), topAccent: .white,
                shortsColor: Color(hex: "#AE956C"), shoeColor: Color(hex: "#7E6753"), headsetColor: Color(hex: "#B8852C"),
                eyeColor: Color(hex: "#9E7324"), hairStyle: .neatShort, outfit: .denim, accessory: .glassesHeadset
            )
        case "bikini_coral":
            return .init(
                skinLight: Color(hex: "#FFE6DA"), skin: Color(hex: "#F7D3C2"), skinShade: Color(hex: "#DAAB95"),
                hair: Color(hex: "#CD6A4B"), hairDeep: Color(hex: "#964129"), hairHighlight: Color(hex: "#EE9A7C"),
                topPrimary: Color(hex: "#ED756D"), topDeep: Color(hex: "#C54C47"), topAccent: Color(hex: "#FBB4AC"),
                shortsColor: Color(hex: "#314262"), shoeColor: .white, headsetColor: Color(hex: "#F08C75"),
                eyeColor: Color(hex: "#2B3C4E"), hairStyle: .bob, outfit: .tee, accessory: .headsetMic
            )
        case "bikini_cobalt":
            return .init(
                skinLight: Color(hex: "#FFE1CD"), skin: Color(hex: "#F3CAAD"), skinShade: Color(hex: "#D09978"),
                hair: Color(hex: "#191E2A"), hairDeep: Color(hex: "#0D1017"), hairHighlight: Color(hex: "#3D4963"),
                topPrimary: Color(hex: "#E6ECF5"), topDeep: Color(hex: "#2566D8"), topAccent: Color(hex: "#2566D8"),
                shortsColor: Color(hex: "#2A303C"), shoeColor: Color(hex: "#265CD0"), headsetColor: Color(hex: "#2A68DF"),
                eyeColor: Color(hex: "#1F58C4"), hairStyle: .spikyShort, outfit: .jacket, accessory: .visorHeadset
            )
        case "bikini_rosegold":
            return .init(
                skinLight: Color(hex: "#FFE9E3"), skin: Color(hex: "#F9D9D0"), skinShade: Color(hex: "#DEB0A4"),
                hair: Color(hex: "#C8B8BE"), hairDeep: Color(hex: "#95838A"), hairHighlight: Color(hex: "#EFE5E8"),
                topPrimary: Color(hex: "#F6A7B5"), topDeep: Color(hex: "#D8788B"), topAccent: .white,
                shortsColor: Color(hex: "#7393BA"), shoeColor: Color(hex: "#E4D4CE"), headsetColor: Color(hex: "#D99280"),
                eyeColor: Color(hex: "#7A3B51"), hairStyle: .twinTails, outfit: .cardigan, accessory: .headsetMic
            )
        case "bikini_ruby":
            return .init(
                skinLight: Color(hex: "#FFE2CD"), skin: Color(hex: "#F4CAAE"), skinShade: Color(hex: "#D39D7D"),
                hair: Color(hex: "#1D2129"), hairDeep: Color(hex: "#0E1015"), hairHighlight: Color(hex: "#454E5E"),
                topPrimary: Color(hex: "#2F323B"), topDeep: Color(hex: "#1D1E24"), topAccent: Color(hex: "#B9313F"),
                shortsColor: Color(hex: "#2B2E36"), shoeColor: Color(hex: "#22242A"), headsetColor: Color(hex: "#363A44"),
                eyeColor: Color(hex: "#2E303A"), hairStyle: .neatShort, outfit: .tee, accessory: .headsetMic
            )
        case "bikini_emerald":
            return .init(
                skinLight: Color(hex: "#D69772"), skin: Color(hex: "#B97954"), skinShade: Color(hex: "#8F5638"),
                hair: Color(hex: "#46281A"), hairDeep: Color(hex: "#28140C"), hairHighlight: Color(hex: "#6F432D"),
                topPrimary: Color(hex: "#5CD3A6"), topDeep: Color(hex: "#32A87E"), topAccent: .white,
                shortsColor: Color(hex: "#273149"), shoeColor: .white, headsetColor: Color(hex: "#33B389"),
                eyeColor: Color(hex: "#3C2012"), hairStyle: .ponytail, outfit: .hoodie, accessory: .headsetMic
            )
        default:
            let col = Color(hex: fallbackAccent)
            return .init(
                skinLight: Color(hex: "#FDE2CF"), skin: Color(hex: "#F5CBB0"), skinShade: Color(hex: "#DFA584"),
                hair: Color(hex: "#462B22"), hairDeep: Color(hex: "#281611"), hairHighlight: Color(hex: "#784C3D"),
                topPrimary: col, topDeep: col.opacity(0.75), topAccent: .white,
                shortsColor: Color(hex: "#434C5E"), shoeColor: .white, headsetColor: col,
                eyeColor: Color(hex: "#3A2319"), hairStyle: .spikyShort, outfit: .hoodie, accessory: .headsetMic
            )
        }
    }
}

// MARK: - 60 FPS İnce Çizgili Anime-Chibi Yürüyen Geliştirici Figürü

private struct ArticulatedChibiWalkerCanvas: View {
    let style: ChibiCharacterStyle
    let accent: Color
    let status: AgentStatus
    let statusColor: Color
    let isWalking: Bool
    let strideIntensity: Double
    let isSelected: Bool
    let facingLeft: Bool
    let phaseOffset: Double
    let reduceMotion: Bool

    private let inkColor = Color(hex: "#1D1724")
    private var isBusy: Bool { status.isBusy }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let walkCycle = (t + phaseOffset) * 9.2
            let idleCycle = (t + phaseOffset) * 2.2

            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let cx = w * 0.5
                let groundY = h * 0.93
                let unit = h / 100.0
                let inkW = max(1.0, 1.35 * unit)

                let activeWalk = isWalking && !reduceMotion
                let amp = activeWalk ? min(1.0, max(0.22, strideIntensity)) : 0.0
                let stride = activeWalk ? sin(walkCycle) * amp : 0.0
                let oppStride = activeWalk ? sin(walkCycle + .pi) * amp : 0.0

                let isWorkingPose = !activeWalk && (status == .working || status == .runningTool)
                let isThinkingPose = !activeWalk && status == .thinking
                let isChatPose = !activeWalk && (status == .chatting || status == .collaborating)
                let isImprovingPose = !activeWalk && status == .improving
                let isErrorPose = !activeWalk && status == .error

                let bob: CGFloat = {
                    if activeWalk { return CGFloat(abs(sin(walkCycle)) * -3.0 * amp) * unit }
                    if isErrorPose && !reduceMotion { return CGFloat(sin(t * 24.0) * 0.8) * unit }
                    return CGFloat(sin(idleCycle) * -0.7) * unit
                }()
                let hairBounce = activeWalk
                    ? CGFloat(sin(walkCycle - 0.7) * 2.4 * amp) * unit
                    : CGFloat(sin(idleCycle - 0.4) * 0.7) * unit
                let shadowScale = activeWalk ? (0.86 + 0.14 * abs(cos(walkCycle)) * amp) : 1.0

                // 1) Zemin temas gölgesi & ışıklı seçim/yürüyüş halkası
                let shadowRect = CGRect(
                    x: cx - 17.5 * unit * shadowScale,
                    y: groundY - 4.0 * unit,
                    width: 35.0 * unit * shadowScale,
                    height: 8.0 * unit
                )
                ctx.fill(
                    Path(ellipseIn: shadowRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            (isSelected || isWalking ? accent : Color.black).opacity(isSelected ? 0.50 : 0.36),
                            .clear
                        ]),
                        center: CGPoint(x: shadowRect.midX, y: shadowRect.midY),
                        startRadius: 1,
                        endRadius: shadowRect.width * 0.55
                    )
                )

                if activeWalk {
                    let stepPhase = fmod(abs(walkCycle / .pi), 1.0)
                    let rippleW = (16 + stepPhase * 22) * unit
                    let rippleH = (4.0 + stepPhase * 5.2) * unit
                    let rippleRect = CGRect(x: cx - rippleW * 0.5, y: groundY - rippleH * 0.5, width: rippleW, height: rippleH)
                    ctx.stroke(
                        Path(ellipseIn: rippleRect),
                        with: .color(Color.cyan.opacity((1.0 - stepPhase) * 0.55)),
                        lineWidth: 1.2
                    )
                }

                if isWalking || isBusy || isSelected {
                    let ringPulse = reduceMotion ? 1.0 : (0.96 + 0.08 * abs(sin(idleCycle)))
                    let rw = 32.0 * unit * ringPulse
                    let rh = 8.4 * unit * ringPulse
                    let ringRect = CGRect(x: cx - rw * 0.5, y: groundY - rh * 0.5, width: rw, height: rh)
                    ctx.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color((isWalking || isSelected ? Color.cyan : statusColor).opacity(0.82)),
                        lineWidth: isSelected ? 2.0 : 1.35
                    )
                }

                // Yürüyüş yönüne göre yatay ayna
                var fig = ctx
                if facingLeft {
                    fig.translateBy(x: w, y: 0)
                    fig.scaleBy(x: -1, y: 1)
                }

                // Chibi eklem merkezleri (~2.65:1 sevimli oran: büyük kafa, kompakt gövde ve adımlayan bacaklar)
                let hipY = groundY - 22.5 * unit + bob
                let hipCenter = CGPoint(x: cx, y: hipY)
                let shoulderCenter = CGPoint(x: cx + (activeWalk ? CGFloat(amp) * 0.8 * unit : 0), y: hipY - 21.5 * unit)
                let headCenter = CGPoint(x: shoulderCenter.x + 0.6 * unit, y: shoulderCenter.y - 19.5 * unit)

                let backThigh = activeWalk ? oppStride * 0.48 : -0.06
                let backKnee = activeWalk ? max(0.0, sin(walkCycle + .pi - 0.55)) * 0.65 * amp : 0.03
                let frontThigh = activeWalk ? stride * 0.48 : 0.06
                let frontKnee = activeWalk ? max(0.0, sin(walkCycle - 0.55)) * 0.65 * amp : 0.02

                let backShoulder: Double = {
                    if activeWalk { return stride * 0.52 }
                    if isWorkingPose && !reduceMotion { return -0.36 + cos(idleCycle * 4.5) * 0.08 }
                    if isChatPose && !reduceMotion { return -0.25 + sin(idleCycle * 2.8) * 0.14 }
                    return 0.16
                }()
                let backElbow: Double = {
                    if activeWalk { return 0.25 * amp + 0.12 }
                    if isWorkingPose { return 0.80 }
                    if isChatPose { return 0.55 }
                    return 0.16
                }()
                let frontShoulder: Double = {
                    if activeWalk { return oppStride * 0.52 }
                    if isWorkingPose && !reduceMotion { return -0.52 + sin(idleCycle * 5.0) * 0.10 }
                    if isThinkingPose && !reduceMotion { return -0.78 + sin(idleCycle * 1.4) * 0.05 }
                    if isChatPose && !reduceMotion { return -0.42 + sin(idleCycle * 3.1) * 0.26 }
                    if isErrorPose { return -0.62 }
                    return -0.14
                }()
                let frontElbow: Double = {
                    if activeWalk { return 0.28 * amp + 0.14 }
                    if isWorkingPose { return 0.84 }
                    if isThinkingPose { return 1.15 }
                    if isChatPose { return 0.72 }
                    if isErrorPose { return 0.90 }
                    return 0.16
                }()

                // 2) Uzun/kuyruk arka saç (varsa)
                drawChibiBackHair(&fig, head: headCenter, unit: unit, bounce: hairBounce)

                // 3) Arka kol
                drawChibiArm(
                    &fig,
                    shoulder: CGPoint(x: shoulderCenter.x - 8.2 * unit, y: shoulderCenter.y + 3.0 * unit),
                    upperAngle: backShoulder,
                    elbowBend: backElbow,
                    unit: unit,
                    inkW: inkW,
                    skin: style.skinShade,
                    sleeve: style.topDeep
                )

                // 4) Arka & ön adımlayan bacaklar + spor ayakkabılar
                drawChibiLeg(
                    &fig,
                    hip: CGPoint(x: hipCenter.x - 4.0 * unit, y: hipCenter.y + 1.0 * unit),
                    thighAngle: backThigh,
                    kneeBend: backKnee,
                    unit: unit,
                    inkW: inkW,
                    skin: style.skinShade
                )

                // 5) Şort + Gövde / Hoodie / Tişört
                drawChibiTorsoAndShorts(&fig, hip: hipCenter, shoulder: shoulderCenter, unit: unit, inkW: inkW)

                drawChibiLeg(
                    &fig,
                    hip: CGPoint(x: hipCenter.x + 3.8 * unit, y: hipCenter.y + 1.0 * unit),
                    thighAngle: frontThigh,
                    kneeBend: frontKnee,
                    unit: unit,
                    inkW: inkW,
                    skin: style.skin
                )

                // 6) Büyük anime-chibi kafa + kulaklık + gözlük + gülümseme + ön saç
                let isBlinking = !reduceMotion && fmod(t + phaseOffset, 4.1) > 3.96
                drawChibiHeadAndHair(&fig, shoulder: shoulderCenter, head: headCenter, unit: unit, inkW: inkW, bounce: hairBounce, blinking: isBlinking)

                // 7) Ön kol
                drawChibiArm(
                    &fig,
                    shoulder: CGPoint(x: shoulderCenter.x + 8.6 * unit, y: shoulderCenter.y + 3.0 * unit),
                    upperAngle: frontShoulder,
                    elbowBend: frontElbow,
                    unit: unit,
                    inkW: inkW,
                    skin: style.skin,
                    sleeve: style.topPrimary
                )

                // 8) Durum mikro efektleri
                if !reduceMotion {
                    if isWorkingPose {
                        let glowPt = CGPoint(x: shoulderCenter.x + 12.5 * unit, y: shoulderCenter.y + 7.5 * unit)
                        let glowR = 10.5 * unit
                        fig.fill(
                            Path(ellipseIn: CGRect(x: glowPt.x - glowR, y: glowPt.y - glowR, width: glowR * 2, height: glowR * 2)),
                            with: .radialGradient(Gradient(colors: [Color.cyan.opacity(0.40), .clear]), center: glowPt, startRadius: 1, endRadius: glowR)
                        )
                    } else if isThinkingPose {
                        for idx in 0..<3 {
                            let p = t * 2.0 + phaseOffset + Double(idx) * 1.9
                            let tx = headCenter.x + 17.5 * unit + CGFloat(cos(p)) * 2.8 * unit
                            let ty = headCenter.y - 16.0 * unit - CGFloat(idx) * 4.0 * unit
                            let r = (1.2 + Double(idx) * 0.55) * unit
                            fig.fill(Path(ellipseIn: CGRect(x: tx - r, y: ty - r, width: r * 2, height: r * 2)), with: .color(Color.cyan.opacity(0.78)))
                        }
                    } else if isImprovingPose {
                        for idx in 0..<4 {
                            let p = fmod(t * 0.75 + phaseOffset + Double(idx) * 0.25, 1.0)
                            let sx = cx + CGFloat(sin(Double(idx) * 1.7 + p * 4.0)) * 16.0 * unit
                            let sy = groundY - CGFloat(p) * 82.0 * unit
                            let r = 1.6 * unit
                            fig.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)), with: .color(Color.mint.opacity((1.0 - p) * 0.85)))
                        }
                    } else if isErrorPose {
                        let pulse = 0.55 + 0.45 * abs(sin(t * 7.0))
                        let ex = headCenter.x + 17.0 * unit
                        let ey = headCenter.y - 14.0 * unit
                        fig.fill(Path(ellipseIn: CGRect(x: ex - 3.6 * unit, y: ey - 3.6 * unit, width: 7.2 * unit, height: 7.2 * unit)), with: .color(Color.red.opacity(pulse)))
                    }
                }
            }
        }
    }

    private func limbCapsule(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Path {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(0.001, hypot(dx, dy))
        let nx = -dy / len
        let ny = dx / len
        var p = Path()
        p.move(to: CGPoint(x: a.x + nx * radius, y: a.y + ny * radius))
        p.addLine(to: CGPoint(x: b.x + nx * radius, y: b.y + ny * radius))
        p.addQuadCurve(to: CGPoint(x: b.x - nx * radius, y: b.y - ny * radius), control: CGPoint(x: b.x + (dx / len) * radius * 1.2, y: b.y + (dy / len) * radius * 1.2))
        p.addLine(to: CGPoint(x: a.x - nx * radius, y: a.y - ny * radius))
        p.addQuadCurve(to: CGPoint(x: a.x + nx * radius, y: a.y + ny * radius), control: CGPoint(x: a.x - (dx / len) * radius * 1.2, y: a.y - (dy / len) * radius * 1.2))
        p.closeSubpath()
        return p
    }

    private func drawChibiBackHair(_ ctx: inout GraphicsContext, head: CGPoint, unit: CGFloat, bounce: CGFloat) {
        switch style.hairStyle {
        case .longWavy, .twinTails, .bob, .ponytail:
            let len: CGFloat = {
                switch style.hairStyle {
                case .longWavy: return 27.0 * unit
                case .twinTails, .ponytail: return 24.0 * unit
                default: return 15.5 * unit
                }
            }()
            var p = Path()
            p.move(to: CGPoint(x: head.x - 16.5 * unit, y: head.y - 2.0 * unit))
            p.addQuadCurve(
                to: CGPoint(x: head.x - 18.5 * unit - bounce, y: head.y + len),
                control: CGPoint(x: head.x - 21.5 * unit, y: head.y + len * 0.55)
            )
            p.addQuadCurve(
                to: CGPoint(x: head.x + 15.0 * unit - bounce * 0.5, y: head.y + len * 0.85),
                control: CGPoint(x: head.x, y: head.y + len * 1.15)
            )
            p.addLine(to: CGPoint(x: head.x + 16.0 * unit, y: head.y - 2.0 * unit))
            p.closeSubpath()
            ctx.fill(p, with: .color(style.hairDeep))
            ctx.stroke(p, with: .color(inkColor), lineWidth: max(0.9, 1.15 * unit))
        default:
            break
        }
    }

    private func drawChibiLeg(
        _ ctx: inout GraphicsContext,
        hip: CGPoint,
        thighAngle: Double,
        kneeBend: Double,
        unit: CGFloat,
        inkW: CGFloat,
        skin: Color
    ) {
        let thighLen = 9.5 * unit
        let calfLen = 9.2 * unit
        let knee = CGPoint(x: hip.x + sin(thighAngle) * thighLen, y: hip.y + cos(thighAngle) * thighLen)
        let calfAngle = thighAngle - kneeBend
        let ankle = CGPoint(x: knee.x + sin(calfAngle) * calfLen, y: knee.y + cos(calfAngle) * calfLen)

        let legPath = limbCapsule(from: hip, to: ankle, radius: 2.55 * unit)
        ctx.fill(legPath, with: .color(skin))
        ctx.stroke(legPath, with: .color(inkColor), lineWidth: inkW * 0.9)

        // Chunky Chibi Sneaker with white midsole
        let shoeRect = CGRect(x: ankle.x - 3.6 * unit, y: ankle.y - 1.2 * unit, width: 10.0 * unit, height: 5.2 * unit)
        let shoe = Path(roundedRect: shoeRect, cornerRadius: 2.3 * unit)
        ctx.fill(shoe, with: .color(style.shoeColor))
        ctx.stroke(shoe, with: .color(inkColor), lineWidth: inkW * 0.9)

        let soleRect = CGRect(x: shoeRect.minX + 0.5 * unit, y: shoeRect.maxY - 1.7 * unit, width: shoeRect.width - 1.0 * unit, height: 1.5 * unit)
        ctx.fill(Path(roundedRect: soleRect, cornerRadius: 0.7 * unit), with: .color(.white))
    }

    private func drawChibiTorsoAndShorts(
        _ ctx: inout GraphicsContext,
        hip: CGPoint,
        shoulder: CGPoint,
        unit: CGFloat,
        inkW: CGFloat
    ) {
        // Şort
        let shortsRect = CGRect(x: hip.x - 9.4 * unit, y: hip.y - 4.2 * unit, width: 18.8 * unit, height: 9.2 * unit)
        let shortsPath = Path(roundedRect: shortsRect, cornerRadius: 2.6 * unit)
        ctx.fill(shortsPath, with: .color(style.shortsColor))
        ctx.stroke(shortsPath, with: .color(inkColor), lineWidth: inkW)

        // Gövde Üstü (Hoodie / Aloha / Tişört)
        var torso = Path()
        torso.move(to: CGPoint(x: shoulder.x - 8.6 * unit, y: shoulder.y + 1.0 * unit))
        torso.addQuadCurve(
            to: CGPoint(x: shoulder.x + 8.8 * unit, y: shoulder.y + 1.0 * unit),
            control: CGPoint(x: shoulder.x, y: shoulder.y - 2.0 * unit)
        )
        torso.addLine(to: CGPoint(x: hip.x + 9.2 * unit, y: hip.y - 2.0 * unit))
        torso.addLine(to: CGPoint(x: hip.x - 9.2 * unit, y: hip.y - 2.0 * unit))
        torso.closeSubpath()

        ctx.fill(
            torso,
            with: .linearGradient(
                Gradient(colors: [style.topPrimary, style.topDeep]),
                startPoint: shoulder,
                endPoint: hip
            )
        )
        ctx.stroke(torso, with: .color(inkColor), lineWidth: inkW)

        // Kıyafet detayı (fermuar / tişört yakası / cep)
        if style.outfit == .hoodie || style.outfit == .cardigan || style.outfit == .denim || style.outfit == .jacket {
            let centerW = 3.8 * unit
            let innerRect = CGRect(x: shoulder.x - centerW * 0.5, y: shoulder.y + 0.5 * unit, width: centerW, height: 18.0 * unit)
            ctx.fill(Path(innerRect), with: .color(style.topAccent.opacity(0.88)))
            ctx.stroke(Path(innerRect), with: .color(inkColor.opacity(0.65)), lineWidth: inkW * 0.65)
        } else if style.outfit == .aloha || style.outfit == .floral {
            // Küçük tropikal desen noktaları
            for dx in stride(from: -4.5, through: 4.5, by: 4.5) {
                for dy in stride(from: 6.0, through: 13.0, by: 6.5) {
                    let pt = CGPoint(x: shoulder.x + dx * unit, y: shoulder.y + dy * unit)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 1.4 * unit, y: pt.y - 1.4 * unit, width: 2.8 * unit, height: 2.8 * unit)), with: .color(style.topAccent.opacity(0.85)))
                }
            }
        }
    }

    private func drawChibiHeadAndHair(
        _ ctx: inout GraphicsContext,
        shoulder: CGPoint,
        head: CGPoint,
        unit: CGFloat,
        inkW: CGFloat,
        bounce: CGFloat,
        blinking: Bool
    ) {
        // Yüz ovali (geniş & yuvarlak sevimli chibi kafa)
        let hw: CGFloat = 33.0 * unit
        let hh: CGFloat = 30.5 * unit
        let faceRect = CGRect(x: head.x - hw * 0.5, y: head.y - hh * 0.5, width: hw, height: hh)
        let facePath = Path(ellipseIn: faceRect)
        ctx.fill(
            facePath,
            with: .radialGradient(
                Gradient(colors: [style.skinLight, style.skin, style.skinShade]),
                center: CGPoint(x: head.x + 4 * unit, y: head.y - 4 * unit),
                startRadius: 2,
                endRadius: hw * 0.65
            )
        )
        ctx.stroke(facePath, with: .color(inkColor), lineWidth: inkW)

        // Gözler & beyaz ışıltı noktaları
        let eyeY = head.y + 1.8 * unit
        let leftEyeX = head.x - 3.5 * unit
        let rightEyeX = head.x + 8.0 * unit
        if blinking {
            var blink = Path()
            blink.move(to: CGPoint(x: leftEyeX - 2.6 * unit, y: eyeY))
            blink.addQuadCurve(to: CGPoint(x: leftEyeX + 2.6 * unit, y: eyeY), control: CGPoint(x: leftEyeX, y: eyeY + 1.6 * unit))
            blink.move(to: CGPoint(x: rightEyeX - 2.6 * unit, y: eyeY))
            blink.addQuadCurve(to: CGPoint(x: rightEyeX + 2.6 * unit, y: eyeY), control: CGPoint(x: rightEyeX, y: eyeY + 1.6 * unit))
            ctx.stroke(blink, with: .color(inkColor), style: StrokeStyle(lineWidth: inkW * 1.1, lineCap: .round))
        } else {
            for (ex, ew) in [(leftEyeX, 5.0 * unit), (rightEyeX, 4.6 * unit)] {
                let eh = 6.0 * unit
                let eRect = CGRect(x: ex - ew * 0.5, y: eyeY - eh * 0.5, width: ew, height: eh)
                ctx.fill(Path(ellipseIn: eRect), with: .color(.white))
                ctx.stroke(Path(ellipseIn: eRect), with: .color(inkColor), lineWidth: inkW * 0.7)
                let irisRect = CGRect(x: ex - ew * 0.36, y: eyeY - eh * 0.38, width: ew * 0.78, height: eh * 0.80)
                ctx.fill(Path(ellipseIn: irisRect), with: .color(style.eyeColor))
                // Specular gloss highlights
                ctx.fill(Path(ellipseIn: CGRect(x: ex - ew * 0.10, y: eyeY - eh * 0.30, width: 1.7 * unit, height: 1.7 * unit)), with: .color(.white))
            }
        }

        // Kaşlar
        var brows = Path()
        brows.move(to: CGPoint(x: leftEyeX - 2.6 * unit, y: eyeY - 4.4 * unit))
        brows.addQuadCurve(to: CGPoint(x: leftEyeX + 2.6 * unit, y: eyeY - 4.5 * unit), control: CGPoint(x: leftEyeX, y: eyeY - 5.5 * unit))
        brows.move(to: CGPoint(x: rightEyeX - 2.4 * unit, y: eyeY - 4.4 * unit))
        brows.addQuadCurve(to: CGPoint(x: rightEyeX + 2.4 * unit, y: eyeY - 4.5 * unit), control: CGPoint(x: rightEyeX, y: eyeY - 5.5 * unit))
        ctx.stroke(brows, with: .color(style.hairDeep), style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round))

        // Pembe yanak allığı & sevimli gülümseme
        ctx.fill(Path(ellipseIn: CGRect(x: leftEyeX - 4.2 * unit, y: eyeY + 3.2 * unit, width: 4.0 * unit, height: 2.0 * unit)), with: .color(Color(hex: "#FB7185").opacity(0.36)))
        ctx.fill(Path(ellipseIn: CGRect(x: rightEyeX + 0.4 * unit, y: eyeY + 3.2 * unit, width: 4.0 * unit, height: 2.0 * unit)), with: .color(Color(hex: "#FB7185").opacity(0.36)))

        var smile = Path()
        smile.move(to: CGPoint(x: head.x - 0.6 * unit, y: eyeY + 5.8 * unit))
        smile.addQuadCurve(to: CGPoint(x: head.x + 5.6 * unit, y: eyeY + 5.6 * unit), control: CGPoint(x: head.x + 2.5 * unit, y: eyeY + 8.0 * unit))
        ctx.stroke(smile, with: .color(Color(hex: "#8F3A36")), style: StrokeStyle(lineWidth: 1.15 * unit, lineCap: .round))

        // Opsiyonel gözlük / vizör
        if style.accessory == .glassesHeadset || style.accessory == .visorHeadset {
            let lGlass = CGRect(x: leftEyeX - 3.6 * unit, y: eyeY - 3.5 * unit, width: 7.2 * unit, height: 6.4 * unit)
            let rGlass = CGRect(x: rightEyeX - 3.4 * unit, y: eyeY - 3.5 * unit, width: 7.0 * unit, height: 6.4 * unit)
            let frameCol = style.accessory == .visorHeadset ? Color(hex: "#2563EB") : style.headsetColor
            if style.accessory == .visorHeadset {
                ctx.fill(Path(roundedRect: lGlass, cornerRadius: 1.5 * unit), with: .color(Color.cyan.opacity(0.22)))
                ctx.fill(Path(roundedRect: rGlass, cornerRadius: 1.5 * unit), with: .color(Color.cyan.opacity(0.22)))
            }
            ctx.stroke(Path(roundedRect: lGlass, cornerRadius: 1.5 * unit), with: .color(frameCol), lineWidth: 1.2 * unit)
            ctx.stroke(Path(roundedRect: rGlass, cornerRadius: 1.5 * unit), with: .color(frameCol), lineWidth: 1.2 * unit)
            var bridge = Path()
            bridge.move(to: CGPoint(x: lGlass.maxX, y: eyeY - 0.8 * unit))
            bridge.addLine(to: CGPoint(x: rGlass.minX, y: eyeY - 0.8 * unit))
            ctx.stroke(bridge, with: .color(frameCol), lineWidth: 1.2 * unit)
        }

        // Ön saç tacı & kaküller
        var crown = Path()
        crown.move(to: CGPoint(x: head.x - 16.5 * unit, y: head.y - 1.5 * unit))
        crown.addQuadCurve(
            to: CGPoint(x: head.x + 16.8 * unit, y: head.y - 3.0 * unit),
            control: CGPoint(x: head.x, y: head.y - 24.5 * unit)
        )
        // Kıvrımlı chibi kakül dişleri
        crown.addQuadCurve(to: CGPoint(x: head.x + 9.5 * unit, y: head.y - 4.0 * unit), control: CGPoint(x: head.x + 14.0 * unit, y: head.y - 7.5 * unit))
        crown.addQuadCurve(to: CGPoint(x: head.x + 3.0 * unit, y: head.y - 6.8 * unit), control: CGPoint(x: head.x + 6.5 * unit, y: head.y - 2.0 * unit))
        crown.addQuadCurve(to: CGPoint(x: head.x - 5.5 * unit, y: head.y - 5.5 * unit), control: CGPoint(x: head.x - 1.2 * unit, y: head.y - 1.8 * unit))
        crown.addQuadCurve(
            to: CGPoint(x: head.x - 16.5 * unit, y: head.y - 1.5 * unit),
            control: CGPoint(x: head.x - 12.0 * unit, y: head.y - 0.5 * unit + bounce * 0.25)
        )
        crown.closeSubpath()
        ctx.fill(crown, with: .color(style.hair))
        ctx.stroke(crown, with: .color(inkColor), lineWidth: inkW * 0.9)

        // Parlak saç ışığı bandı
        var sheen = Path()
        sheen.move(to: CGPoint(x: head.x - 7.5 * unit, y: head.y - 11.5 * unit))
        sheen.addQuadCurve(to: CGPoint(x: head.x + 7.5 * unit, y: head.y - 11.2 * unit), control: CGPoint(x: head.x, y: head.y - 14.2 * unit))
        ctx.stroke(sheen, with: .color(style.hairHighlight.opacity(0.62)), style: StrokeStyle(lineWidth: 2.0 * unit, lineCap: .round))

        // Kulaklık (Çift kulak yastığı + kafa bandı + mikrofon kolu)
        let rightEarCup = CGRect(x: head.x + 12.6 * unit, y: head.y - 3.0 * unit, width: 5.4 * unit, height: 8.8 * unit)
        ctx.fill(Path(roundedRect: rightEarCup, cornerRadius: 2.5 * unit), with: .color(style.headsetColor.opacity(0.92)))
        ctx.stroke(Path(roundedRect: rightEarCup, cornerRadius: 2.5 * unit), with: .color(inkColor), lineWidth: inkW * 0.85)

        var band = Path()
        band.move(to: CGPoint(x: head.x - 16.0 * unit, y: head.y - 1.5 * unit))
        band.addQuadCurve(
            to: CGPoint(x: head.x + 15.2 * unit, y: head.y - 2.0 * unit),
            control: CGPoint(x: head.x - 0.4 * unit, y: head.y - 25.5 * unit)
        )
        ctx.stroke(band, with: .color(inkColor), style: StrokeStyle(lineWidth: 4.0 * unit, lineCap: .round))
        ctx.stroke(band, with: .color(style.headsetColor), style: StrokeStyle(lineWidth: 2.3 * unit, lineCap: .round))

        let earCup = CGRect(x: head.x - 19.2 * unit, y: head.y - 3.5 * unit, width: 6.8 * unit, height: 10.0 * unit)
        ctx.fill(Path(roundedRect: earCup, cornerRadius: 3.0 * unit), with: .color(style.headsetColor))
        ctx.stroke(Path(roundedRect: earCup, cornerRadius: 3.0 * unit), with: .color(inkColor), lineWidth: inkW * 0.85)

        if style.accessory != .headset {
            var mic = Path()
            mic.move(to: CGPoint(x: earCup.maxX - 1.0 * unit, y: earCup.maxY - 2.0 * unit))
            mic.addQuadCurve(
                to: CGPoint(x: head.x + 2.2 * unit, y: eyeY + 7.2 * unit),
                control: CGPoint(x: head.x - 7.5 * unit, y: eyeY + 8.5 * unit)
            )
            ctx.stroke(mic, with: .color(inkColor), style: StrokeStyle(lineWidth: 1.4 * unit, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + 1.0 * unit, y: eyeY + 5.8 * unit, width: 3.2 * unit, height: 2.4 * unit)), with: .color(inkColor))
        }
    }

    private func drawChibiArm(
        _ ctx: inout GraphicsContext,
        shoulder: CGPoint,
        upperAngle: Double,
        elbowBend: Double,
        unit: CGFloat,
        inkW: CGFloat,
        skin: Color,
        sleeve: Color
    ) {
        let upperLen = 6.2 * unit
        let lowerLen = 5.4 * unit
        let elbow = CGPoint(x: shoulder.x + sin(upperAngle) * upperLen, y: shoulder.y + cos(upperAngle) * upperLen)
        let lowerAngle = upperAngle + elbowBend
        let hand = CGPoint(x: elbow.x + sin(lowerAngle) * lowerLen, y: elbow.y + cos(lowerAngle) * lowerLen)

        let forearm = limbCapsule(from: elbow, to: hand, radius: 2.0 * unit)
        ctx.fill(forearm, with: .color(skin))
        ctx.stroke(forearm, with: .color(inkColor), lineWidth: inkW * 0.8)

        let sleeveArm = limbCapsule(from: shoulder, to: elbow, radius: 2.45 * unit)
        ctx.fill(sleeveArm, with: .color(sleeve))
        ctx.stroke(sleeveArm, with: .color(inkColor), lineWidth: inkW * 0.85)

        ctx.fill(Path(ellipseIn: CGRect(x: hand.x - 2.2 * unit, y: hand.y - 2.0 * unit, width: 4.4 * unit, height: 4.4 * unit)), with: .color(skin))
        ctx.stroke(Path(ellipseIn: CGRect(x: hand.x - 2.2 * unit, y: hand.y - 2.0 * unit, width: 4.4 * unit, height: 4.4 * unit)), with: .color(inkColor), lineWidth: inkW * 0.75)
    }
}

struct AgentAvatarView: View {
    let agent: OfficeAgent
    var size: CGFloat = 44
    var showStatusDot: Bool = true
    var isSelected: Bool = false
    var isWalking: Bool = false
    var strideIntensity: Double = 1.0
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
                    .stroke(accent.opacity(0.75), lineWidth: 2.0)
                    .frame(width: size + 6, height: size + 6)
                    .shadow(color: accent.opacity(0.45), radius: 5)
            }

            if let nsImg = AvatarImageLoader.nsImage(named: resolvedAsset) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.32), Color(red: 0.08, green: 0.11, blue: 0.18).opacity(0.85)],
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
                            .scaleEffect(1.98, anchor: .top)
                            .offset(y: size * 0.08)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    )
                    .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.80 : 0.45), lineWidth: 1.4))
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
        let style = ChibiCharacterStyle.resolve(assetName: resolvedAsset, fallbackAccent: agent.accentHex)
        let phaseOffset = Double(abs(agent.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % 100) * 0.07

        return ZStack(alignment: .topTrailing) {
            ArticulatedChibiWalkerCanvas(
                style: style,
                accent: accent,
                status: agent.status,
                statusColor: statusColor,
                isWalking: isWalking,
                strideIntensity: strideIntensity,
                isSelected: isSelected,
                facingLeft: facingLeft,
                phaseOffset: phaseOffset,
                reduceMotion: reduceMotion
            )
            .frame(width: max(60, size * 0.84), height: size + 10)

            if showStatusDot {
                Circle()
                    .fill(isWalking ? Color.cyan : statusColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: (isWalking ? Color.cyan : statusColor).opacity(0.85), radius: 3)
                    .offset(x: -8, y: 8)
            }
        }
        .frame(width: max(60, size * 0.84), height: size + 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(agent.name), \(isWalking ? "Yürüyor" : agent.status.rawValue)"))
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
            Text("Ofis Çalışanı Karakteri (Chibi Stüdyo Ekibi)")
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
                                if let nsImg = AvatarImageLoader.nsImage(named: preset.assetName) {
                                    Image(nsImage: nsImg)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 48, height: 60)
                                } else {
                                    Circle().fill(Color(hex: preset.accentHex).opacity(0.35)).frame(width: 42, height: 42)
                                }
                                Text(preset.label.components(separatedBy: " · ").first ?? preset.label)
                                    .font(.system(size: 8.5, weight: isSel ? .bold : .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(width: 78)
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
