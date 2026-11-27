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

// MARK: - 10 Bikinili Karakter Stil Profili

private struct BikiniCharacterStyle {
    let skinLight: Color
    let skin: Color
    let skinShade: Color
    let hair: Color
    let hairDeep: Color
    let hairHighlight: Color
    let bikiniPrimary: Color
    let bikiniDeep: Color
    let bikiniTrim: Color
    let lipTint: Color
    let hairLength: CGFloat
    let accessory: AccessoryKind

    enum AccessoryKind {
        case tablet, headphones, coffee, notepad, sunglasses, laptop, watch
    }

    static func resolve(assetName: String, fallbackAccent: String) -> BikiniCharacterStyle {
        switch assetName {
        case "bikini_crimson":
            return .init(skinLight: Color(hex: "#FCDCC6"), skin: Color(hex: "#F4C9AD"), skinShade: Color(hex: "#D99F7E"),
                         hair: Color(hex: "#2B1917"), hairDeep: Color(hex: "#170C0B"), hairHighlight: Color(hex: "#6B3D36"),
                         bikiniPrimary: Color(hex: "#E11D48"), bikiniDeep: Color(hex: "#9F1239"), bikiniTrim: Color(hex: "#FDA4AF"),
                         lipTint: Color(hex: "#D94A64"), hairLength: 1.18, accessory: .tablet)
        case "bikini_cyan":
            return .init(skinLight: Color(hex: "#FFE3CE"), skin: Color(hex: "#F7D3BA"), skinShade: Color(hex: "#DDA98A"),
                         hair: Color(hex: "#E6BE7E"), hairDeep: Color(hex: "#BA8E4F"), hairHighlight: Color(hex: "#FFF3D2"),
                         bikiniPrimary: Color(hex: "#06B6D4"), bikiniDeep: Color(hex: "#0E7490"), bikiniTrim: Color(hex: "#A5F3FC"),
                         lipTint: Color(hex: "#E06B7D"), hairLength: 1.04, accessory: .headphones)
        case "bikini_mint":
            return .init(skinLight: Color(hex: "#F5CBB0"), skin: Color(hex: "#E8B594"), skinShade: Color(hex: "#C58B67"),
                         hair: Color(hex: "#3D2314"), hairDeep: Color(hex: "#211209"), hairHighlight: Color(hex: "#784C2F"),
                         bikiniPrimary: Color(hex: "#10B981"), bikiniDeep: Color(hex: "#047857"), bikiniTrim: Color(hex: "#A7F3D0"),
                         lipTint: Color(hex: "#CD5B69"), hairLength: 0.94, accessory: .coffee)
        case "bikini_lavender":
            return .init(skinLight: Color(hex: "#FFE6D8"), skin: Color(hex: "#F8D7C4"), skinShade: Color(hex: "#DCB097"),
                         hair: Color(hex: "#2B2138"), hairDeep: Color(hex: "#17111F"), hairHighlight: Color(hex: "#6E588A"),
                         bikiniPrimary: Color(hex: "#A855F7"), bikiniDeep: Color(hex: "#7E22CE"), bikiniTrim: Color(hex: "#E9D5FF"),
                         lipTint: Color(hex: "#D65C82"), hairLength: 1.22, accessory: .notepad)
        case "bikini_gold":
            return .init(skinLight: Color(hex: "#F2C4A0"), skin: Color(hex: "#E4AC84"), skinShade: Color(hex: "#BF835A"),
                         hair: Color(hex: "#D6A354"), hairDeep: Color(hex: "#A27430"), hairHighlight: Color(hex: "#FDE8B0"),
                         bikiniPrimary: Color(hex: "#F59E0B"), bikiniDeep: Color(hex: "#B45309"), bikiniTrim: Color(hex: "#FFFFFF"),
                         lipTint: Color(hex: "#CF5E62"), hairLength: 1.12, accessory: .sunglasses)
        case "bikini_coral":
            return .init(skinLight: Color(hex: "#FCD5BC"), skin: Color(hex: "#F2C3A3"), skinShade: Color(hex: "#D19774"),
                         hair: Color(hex: "#753120"), hairDeep: Color(hex: "#461A10"), hairHighlight: Color(hex: "#B8593E"),
                         bikiniPrimary: Color(hex: "#FB7185"), bikiniDeep: Color(hex: "#BE123C"), bikiniTrim: Color(hex: "#FFE4E6"),
                         lipTint: Color(hex: "#E2556F"), hairLength: 1.08, accessory: .laptop)
        case "bikini_cobalt":
            return .init(skinLight: Color(hex: "#FFE1CD"), skin: Color(hex: "#F5CEB5"), skinShade: Color(hex: "#D69E7F"),
                         hair: Color(hex: "#1A1D28"), hairDeep: Color(hex: "#0D0F16"), hairHighlight: Color(hex: "#46506B"),
                         bikiniPrimary: Color(hex: "#3B82F6"), bikiniDeep: Color(hex: "#1D4ED8"), bikiniTrim: Color(hex: "#BFDBFE"),
                         lipTint: Color(hex: "#D85E75"), hairLength: 1.16, accessory: .tablet)
        case "bikini_rosegold":
            return .init(skinLight: Color(hex: "#FAD4BC"), skin: Color(hex: "#EDC0A3"), skinShade: Color(hex: "#CC9270"),
                         hair: Color(hex: "#523029"), hairDeep: Color(hex: "#2D1814"), hairHighlight: Color(hex: "#9B6254"),
                         bikiniPrimary: Color(hex: "#EC4899"), bikiniDeep: Color(hex: "#BE185D"), bikiniTrim: Color(hex: "#FDE68A"),
                         lipTint: Color(hex: "#E05288"), hairLength: 1.24, accessory: .watch)
        case "bikini_ruby":
            return .init(skinLight: Color(hex: "#EBB594"), skin: Color(hex: "#DC9E79"), skinShade: Color(hex: "#B2724E"),
                         hair: Color(hex: "#1A1518"), hairDeep: Color(hex: "#0B090B"), hairHighlight: Color(hex: "#5E313D"),
                         bikiniPrimary: Color(hex: "#DC2626"), bikiniDeep: Color(hex: "#991B1B"), bikiniTrim: Color(hex: "#18181B"),
                         lipTint: Color(hex: "#C73A4A"), hairLength: 0.98, accessory: .coffee)
        case "bikini_emerald":
            return .init(skinLight: Color(hex: "#FCDBC4"), skin: Color(hex: "#F3C8AC"), skinShade: Color(hex: "#D29674"),
                         hair: Color(hex: "#3A231A"), hairDeep: Color(hex: "#1F120D"), hairHighlight: Color(hex: "#7A4B38"),
                         bikiniPrimary: Color(hex: "#14B8A6"), bikiniDeep: Color(hex: "#0F766E"), bikiniTrim: Color(hex: "#CCFBF1"),
                         lipTint: Color(hex: "#D96073"), hairLength: 1.16, accessory: .headphones)
        default:
            return .init(skinLight: Color(hex: "#FCDCC6"), skin: Color(hex: "#F4C9AD"), skinShade: Color(hex: "#D99F7E"),
                         hair: Color(hex: "#2B1917"), hairDeep: Color(hex: "#170C0B"), hairHighlight: Color(hex: "#6B3D36"),
                         bikiniPrimary: Color(hex: fallbackAccent), bikiniDeep: Color(hex: fallbackAccent).opacity(0.75),
                         bikiniTrim: .white.opacity(0.88), lipTint: Color(hex: "#D95A6E"),
                         hairLength: 1.08, accessory: .tablet)
        }
    }
}

// MARK: - 60 FPS Anatomik İncelen Uzuvlu, Gerçek Yürüyen Minik Bikinili Figür

private struct ArticulatedBikiniWalkerCanvas: View {
    let style: BikiniCharacterStyle
    let accent: Color
    let status: AgentStatus
    let statusColor: Color
    let isWalking: Bool
    let strideIntensity: Double
    let isSelected: Bool
    let facingLeft: Bool
    let phaseOffset: Double
    let reduceMotion: Bool

    private var isBusy: Bool { status.isBusy }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let walkCycle = (t + phaseOffset) * 9.0
            let idleCycle = (t + phaseOffset) * 2.1

            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                let cx = w * 0.5
                let groundY = h * 0.92
                let unit = h / 100.0

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
                    if activeWalk { return CGFloat(abs(sin(walkCycle)) * -3.1 * amp) * unit }
                    if isErrorPose && !reduceMotion { return CGFloat(sin(t * 22.0) * 0.8) * unit }
                    return CGFloat(sin(idleCycle) * -0.85) * unit
                }()
                // Dururken doğal contrapposto ağırlık aktarımı; yürürken ritmik kalça salınımı
                let hipSway: CGFloat = {
                    if activeWalk { return CGFloat(cos(walkCycle) * 2.0 * amp) * unit }
                    if isErrorPose && !reduceMotion { return CGFloat(sin(t * 26.0) * 1.1) * unit }
                    return CGFloat(sin(idleCycle * 0.55) * 1.1) * unit
                }()
                let torsoLean: Double = {
                    if activeWalk { return (0.068 + cos(walkCycle * 2) * 0.022) * amp }
                    if isWorkingPose { return 0.075 }
                    if isThinkingPose { return -0.025 }
                    if isChatPose { return 0.02 + sin(idleCycle * 1.8) * 0.02 }
                    return 0.0
                }()
                let hairWave = activeWalk
                    ? CGFloat(sin(walkCycle - 0.85) * 4.5 * amp) * unit
                    : CGFloat(sin(idleCycle - 0.5) * 1.35) * unit
                let shadowScale = activeWalk ? (0.85 + 0.16 * abs(cos(walkCycle)) * amp) : 1.0

                // 1) Zemin temas gölgesi, yürüyüş adım halkası ve durum aurası
                let shadowRect = CGRect(
                    x: cx - 16.5 * unit * shadowScale,
                    y: groundY - 3.6 * unit,
                    width: 33 * unit * shadowScale,
                    height: 7.4 * unit
                )
                ctx.fill(
                    Path(ellipseIn: shadowRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            (isSelected || isWalking ? accent : Color.black).opacity(isSelected ? 0.46 : 0.34),
                            .clear
                        ]),
                        center: CGPoint(x: shadowRect.midX, y: shadowRect.midY),
                        startRadius: 1,
                        endRadius: shadowRect.width * 0.55
                    )
                )

                // Yürürken zeminde yumuşak adım dalgası
                if activeWalk {
                    let stepPhase = fmod(abs(walkCycle / .pi), 1.0)
                    let rippleW = (14 + stepPhase * 22) * unit
                    let rippleH = (3.4 + stepPhase * 5.2) * unit
                    let rippleRect = CGRect(x: cx - rippleW * 0.5, y: groundY - rippleH * 0.5, width: rippleW, height: rippleH)
                    ctx.stroke(
                        Path(ellipseIn: rippleRect),
                        with: .color(accent.opacity((1.0 - stepPhase) * 0.48)),
                        lineWidth: 1.15
                    )
                }

                if isWalking || isBusy || isSelected {
                    let ringPulse = reduceMotion ? 1.0 : (0.96 + 0.09 * abs(sin(idleCycle)))
                    let rw = 29.5 * unit * ringPulse
                    let rh = 7.2 * unit * ringPulse
                    let ringRect = CGRect(x: cx - rw * 0.5, y: groundY - rh * 0.5, width: rw, height: rh)
                    ctx.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color((isWalking || isSelected ? accent : statusColor).opacity(0.76)),
                        lineWidth: isSelected ? 2.0 : 1.35
                    )
                }

                // Yürüyüş yönüne göre yatay ayna
                var fig = ctx
                if facingLeft {
                    fig.translateBy(x: w, y: 0)
                    fig.scaleBy(x: -1, y: 1)
                }

                // Anatomik eklem merkezleri (doğal 7.5 baş oranlı zarif minyatür silüet)
                let hipY = groundY - 41.5 * unit + bob
                let hipCenter = CGPoint(x: cx + hipSway, y: hipY)
                let waistCenter = CGPoint(x: hipCenter.x + CGFloat(torsoLean) * 7.5 * unit, y: hipY - 12.2 * unit)
                let shoulderCenter = CGPoint(x: waistCenter.x + CGFloat(torsoLean) * 9.5 * unit, y: hipY - 25.0 * unit)
                let headCenter = CGPoint(x: shoulderCenter.x + 0.7 * unit, y: shoulderCenter.y - 11.8 * unit)

                // Gerçek adım kinematiği: uyluk salınımı + diz bükülmesi + ayak bileği kaldırma
                let backThighAngle = activeWalk ? oppStride * 0.48 : -0.07
                let backKneeBend = activeWalk ? max(0.0, sin(walkCycle + .pi - 0.62)) * 0.68 * amp : 0.06
                let frontThighAngle = activeWalk ? stride * 0.48 : 0.08
                let frontKneeBend = activeWalk ? max(0.0, sin(walkCycle - 0.62)) * 0.68 * amp : 0.04

                // Duruma özel tam gövde el-kol koreografisi
                let backShoulderAngle: Double = {
                    if activeWalk { return stride * 0.46 }
                    if isWorkingPose && !reduceMotion { return -0.34 + cos(idleCycle * 4.4) * 0.06 }
                    if isChatPose && !reduceMotion { return -0.26 + sin(idleCycle * 2.6) * 0.14 }
                    return -0.16
                }()
                let backElbowBend: Double = {
                    if activeWalk { return (0.24 + max(0, stride) * 0.34) * amp + 0.16 * (1 - amp) }
                    if isWorkingPose { return 0.78 }
                    if isChatPose { return 0.56 }
                    return 0.26
                }()
                let frontShoulderAngle: Double = {
                    if activeWalk { return oppStride * 0.48 }
                    if isWorkingPose && !reduceMotion { return -0.52 + sin(idleCycle * 5.0) * 0.08 }
                    if isThinkingPose && !reduceMotion { return -0.82 + sin(idleCycle * 1.4) * 0.04 }
                    if isChatPose && !reduceMotion { return -0.38 + sin(idleCycle * 3.2) * 0.22 }
                    if isErrorPose { return -0.62 }
                    return 0.12
                }()
                let frontElbowBend: Double = {
                    if activeWalk { return (0.26 + max(0, oppStride) * 0.36) * amp + 0.18 * (1 - amp) }
                    if isWorkingPose { return 0.84 }
                    if isThinkingPose { return 1.18 }
                    if isChatPose { return 0.68 }
                    if isErrorPose { return 0.92 }
                    return 0.26
                }()

                // 2) Arka dalgalı saç hacmi
                drawBackHair(&fig, head: headCenter, unit: unit, wave: hairWave)

                // 3) Arka kol (incelen anatomik form)
                drawTaperedArm(
                    &fig,
                    shoulder: CGPoint(x: shoulderCenter.x - 4.3 * unit, y: shoulderCenter.y + 1.5 * unit),
                    upperAngle: backShoulderAngle,
                    elbowBend: backElbowBend,
                    unit: unit,
                    mainColor: style.skinShade,
                    lightColor: style.skin,
                    accessory: nil
                )

                // 4) Arka bacak (şekilli uyluk + incelen baldır + zarif bilek + sandalet)
                drawTaperedLeg(
                    &fig,
                    hip: CGPoint(x: hipCenter.x - 3.2 * unit, y: hipCenter.y + 1.2 * unit),
                    thighAngle: backThighAngle,
                    kneeBend: backKneeBend,
                    unit: unit,
                    mainColor: style.skinShade,
                    lightColor: style.skin,
                    sandalColor: style.bikiniDeep
                )

                // 5) Doğal kıvrımlı, ışık-gölgeli gövde + detaylı bikini üst/alt
                drawTorsoAndBikini(&fig, hip: hipCenter, waist: waistCenter, shoulder: shoulderCenter, unit: unit)

                // 6) Ön bacak
                drawTaperedLeg(
                    &fig,
                    hip: CGPoint(x: hipCenter.x + 2.9 * unit, y: hipCenter.y + 1.2 * unit),
                    thighAngle: frontThighAngle,
                    kneeBend: frontKneeBend,
                    unit: unit,
                    mainColor: style.skin,
                    lightColor: style.skinLight,
                    sandalColor: style.bikiniPrimary
                )

                // 7) Boyun, baş, kirpikli/göz kırpan yüz ve katmanlı ön saç
                let isBlinking = !reduceMotion && fmod(t + phaseOffset, 4.3) > 4.16
                drawHeadAndFrontHair(&fig, shoulder: shoulderCenter, head: headCenter, unit: unit, wave: hairWave, blinking: isBlinking)

                // 8) Ön kol + karakter aksesuarı
                drawTaperedArm(
                    &fig,
                    shoulder: CGPoint(x: shoulderCenter.x + 4.7 * unit, y: shoulderCenter.y + 1.5 * unit),
                    upperAngle: frontShoulderAngle,
                    elbowBend: frontElbowBend,
                    unit: unit,
                    mainColor: style.skin,
                    lightColor: style.skinLight,
                    accessory: style.accessory
                )

                // 9) Duruma özel canlı atmosfer efektleri (holografik ekran parıltısı, düşünce/gelişim ışıltıları)
                if !reduceMotion {
                    if isWorkingPose {
                        let glowPt = CGPoint(x: shoulderCenter.x + 11.5 * unit, y: shoulderCenter.y + 7.0 * unit)
                        let glowR = 11.0 * unit
                        fig.fill(
                            Path(ellipseIn: CGRect(x: glowPt.x - glowR, y: glowPt.y - glowR, width: glowR * 2, height: glowR * 2)),
                            with: .radialGradient(
                                Gradient(colors: [statusColor.opacity(0.38), .clear]),
                                center: glowPt,
                                startRadius: 1,
                                endRadius: glowR
                            )
                        )
                        // Yükselen mini kod/enerji kıvılcımları
                        for idx in 0..<3 {
                            let p = fmod(t * 0.9 + phaseOffset + Double(idx) * 0.33, 1.0)
                            let sx = glowPt.x + CGFloat(sin(p * 6.28 + Double(idx))) * 4.0 * unit
                            let sy = glowPt.y - CGFloat(p) * 16.0 * unit
                            let r = (1.6 - p * 0.9) * unit
                            fig.fill(
                                Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)),
                                with: .color(statusColor.opacity((1.0 - p) * 0.85))
                            )
                        }
                    } else if isThinkingPose {
                        for idx in 0..<3 {
                            let p = t * 2.0 + phaseOffset + Double(idx) * 1.9
                            let tx = headCenter.x + 10.5 * unit + CGFloat(cos(p)) * 3.0 * unit
                            let ty = headCenter.y - 11.0 * unit - CGFloat(idx) * 3.8 * unit + CGFloat(sin(p)) * 1.4 * unit
                            let r = (1.1 + Double(idx) * 0.55) * unit
                            fig.fill(
                                Path(ellipseIn: CGRect(x: tx - r, y: ty - r, width: r * 2, height: r * 2)),
                                with: .color(Color.cyan.opacity(0.72))
                            )
                        }
                    } else if isImprovingPose {
                        for idx in 0..<4 {
                            let p = fmod(t * 0.75 + phaseOffset + Double(idx) * 0.25, 1.0)
                            let sx = cx + CGFloat(sin(Double(idx) * 1.7 + p * 4.0)) * 14.0 * unit
                            let sy = groundY - CGFloat(p) * 78.0 * unit
                            let r = 1.5 * unit
                            fig.fill(
                                Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)),
                                with: .color(Color.mint.opacity((1.0 - p) * 0.85))
                            )
                        }
                    } else if isErrorPose {
                        let pulse = 0.55 + 0.45 * abs(sin(t * 7.0))
                        let ex = headCenter.x + 11.0 * unit
                        let ey = headCenter.y - 9.0 * unit
                        fig.fill(
                            Path(ellipseIn: CGRect(x: ex - 3.2 * unit, y: ey - 3.2 * unit, width: 6.4 * unit, height: 6.4 * unit)),
                            with: .color(Color.red.opacity(pulse))
                        )
                    }
                }
            }
        }
    }

    /// İki nokta arasında uçtan uca incelen organik uzuv segmenti (çubuk/Lego hissini tamamen bitirir)
    private func taperedLimbPath(from a: CGPoint, to b: CGPoint, rStart: CGFloat, rEnd: CGFloat, bulge: CGFloat = 0) -> Path {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(0.001, hypot(dx, dy))
        let nx = -dy / len
        let ny = dx / len
        let mx = (a.x + b.x) * 0.5
        let my = (a.y + b.y) * 0.5
        let rMid = (rStart + rEnd) * 0.5 + bulge

        let aL = CGPoint(x: a.x + nx * rStart, y: a.y + ny * rStart)
        let aR = CGPoint(x: a.x - nx * rStart, y: a.y - ny * rStart)
        let bL = CGPoint(x: b.x + nx * rEnd, y: b.y + ny * rEnd)
        let bR = CGPoint(x: b.x - nx * rEnd, y: b.y - ny * rEnd)
        let cL = CGPoint(x: mx + nx * rMid, y: my + ny * rMid)
        let cR = CGPoint(x: mx - nx * rMid, y: my - ny * rMid)

        var p = Path()
        p.move(to: aL)
        p.addQuadCurve(to: bL, control: cL)
        p.addQuadCurve(to: bR, control: CGPoint(x: b.x + (dx / len) * rEnd * 0.9, y: b.y + (dy / len) * rEnd * 0.9))
        p.addQuadCurve(to: aR, control: cR)
        p.addQuadCurve(to: aL, control: CGPoint(x: a.x - (dx / len) * rStart * 0.9, y: a.y - (dy / len) * rStart * 0.9))
        p.closeSubpath()
        return p
    }

    private func drawBackHair(_ ctx: inout GraphicsContext, head: CGPoint, unit: CGFloat, wave: CGFloat) {
        let len = 26.0 * unit * style.hairLength
        var p = Path()
        p.move(to: CGPoint(x: head.x - 8.6 * unit, y: head.y - 3.5 * unit))
        p.addQuadCurve(
            to: CGPoint(x: head.x - 12.6 * unit - wave * 0.95, y: head.y + len),
            control: CGPoint(x: head.x - 15.2 * unit - wave * 0.40, y: head.y + len * 0.52)
        )
        p.addQuadCurve(
            to: CGPoint(x: head.x - 2.0 * unit - wave * 0.70, y: head.y + len * 0.94),
            control: CGPoint(x: head.x - 7.4 * unit - wave * 0.95, y: head.y + len * 1.12)
        )
        p.addQuadCurve(
            to: CGPoint(x: head.x + 6.4 * unit - wave * 0.40, y: head.y + len * 0.78),
            control: CGPoint(x: head.x + 2.5 * unit - wave * 0.55, y: head.y + len * 0.96)
        )
        p.addLine(to: CGPoint(x: head.x + 7.6 * unit, y: head.y - 2.2 * unit))
        p.closeSubpath()
        ctx.fill(
            p,
            with: .linearGradient(
                Gradient(colors: [style.hair, style.hairDeep]),
                startPoint: CGPoint(x: head.x, y: head.y - 6 * unit),
                endPoint: CGPoint(x: head.x - 8 * unit, y: head.y + len)
            )
        )
    }

    private func drawTaperedLeg(
        _ ctx: inout GraphicsContext,
        hip: CGPoint,
        thighAngle: Double,
        kneeBend: Double,
        unit: CGFloat,
        mainColor: Color,
        lightColor: Color,
        sandalColor: Color
    ) {
        let thighLen = 19.6 * unit
        let calfLen = 19.4 * unit

        let knee = CGPoint(
            x: hip.x + sin(thighAngle) * thighLen,
            y: hip.y + cos(thighAngle) * thighLen
        )
        let calfAngle = thighAngle - kneeBend
        let ankle = CGPoint(
            x: knee.x + sin(calfAngle) * calfLen,
            y: knee.y + cos(calfAngle) * calfLen
        )

        let limbGrad = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [lightColor, mainColor]),
            startPoint: CGPoint(x: hip.x + 4 * unit, y: hip.y),
            endPoint: CGPoint(x: hip.x - 4 * unit, y: ankle.y)
        )

        // Şekilli uyluk (kalçada dolgun, dize doğru zarif incelen)
        let thigh = taperedLimbPath(from: hip, to: knee, rStart: 3.7 * unit, rEnd: 2.35 * unit, bulge: 0.45 * unit)
        ctx.fill(thigh, with: limbGrad)

        // Diz yuvarlağı + ince baldır → ince ayak bileği
        let calf = taperedLimbPath(from: knee, to: ankle, rStart: 2.35 * unit, rEnd: 1.45 * unit, bulge: 0.35 * unit)
        ctx.fill(calf, with: limbGrad)

        // Zarif topuklu/bantlı yazlık sandalet
        let heel = CGPoint(x: ankle.x - 1.2 * unit, y: ankle.y + 2.4 * unit)
        let toe = CGPoint(x: ankle.x + 5.0 * unit, y: ankle.y + 1.9 * unit)
        var foot = Path()
        foot.move(to: CGPoint(x: ankle.x - 1.3 * unit, y: ankle.y + 0.3 * unit))
        foot.addQuadCurve(to: toe, control: CGPoint(x: ankle.x + 2.4 * unit, y: ankle.y + 0.4 * unit))
        foot.addLine(to: CGPoint(x: toe.x - 0.5 * unit, y: toe.y + 1.1 * unit))
        foot.addQuadCurve(to: heel, control: CGPoint(x: ankle.x + 1.6 * unit, y: ankle.y + 2.1 * unit))
        foot.closeSubpath()
        ctx.fill(foot, with: .color(mainColor))

        var sole = Path()
        sole.move(to: heel)
        sole.addLine(to: CGPoint(x: heel.x + 0.6 * unit, y: heel.y + 0.9 * unit))
        sole.move(to: CGPoint(x: ankle.x - 0.4 * unit, y: ankle.y + 1.8 * unit))
        sole.addLine(to: CGPoint(x: toe.x + 0.2 * unit, y: toe.y + 0.9 * unit))
        ctx.stroke(sole, with: .color(sandalColor), style: StrokeStyle(lineWidth: 1.45 * unit, lineCap: .round))

        // İnce sandalet bilek/parmak bandı
        var strap = Path()
        strap.move(to: CGPoint(x: ankle.x - 1.1 * unit, y: ankle.y + 0.4 * unit))
        strap.addLine(to: CGPoint(x: ankle.x + 1.6 * unit, y: ankle.y + 0.8 * unit))
        strap.move(to: CGPoint(x: ankle.x + 2.4 * unit, y: ankle.y + 0.9 * unit))
        strap.addLine(to: CGPoint(x: ankle.x + 3.8 * unit, y: ankle.y + 2.0 * unit))
        ctx.stroke(strap, with: .color(style.bikiniTrim), style: StrokeStyle(lineWidth: 0.85 * unit, lineCap: .round))
    }

    private func drawTorsoAndBikini(
        _ ctx: inout GraphicsContext,
        hip: CGPoint,
        waist: CGPoint,
        shoulder: CGPoint,
        unit: CGFloat
    ) {
        // Kum saati oranlı doğal gövde
        var body = Path()
        body.move(to: CGPoint(x: shoulder.x - 6.3 * unit, y: shoulder.y))
        body.addQuadCurve(
            to: CGPoint(x: waist.x - 4.3 * unit, y: waist.y),
            control: CGPoint(x: shoulder.x - 6.0 * unit, y: (shoulder.y + waist.y) * 0.5)
        )
        body.addQuadCurve(
            to: CGPoint(x: hip.x - 7.6 * unit, y: hip.y + 1.4 * unit),
            control: CGPoint(x: hip.x - 8.0 * unit, y: waist.y + 5.2 * unit)
        )
        body.addQuadCurve(
            to: CGPoint(x: hip.x + 7.6 * unit, y: hip.y + 1.4 * unit),
            control: CGPoint(x: hip.x, y: hip.y + 7.2 * unit)
        )
        body.addQuadCurve(
            to: CGPoint(x: waist.x + 4.6 * unit, y: waist.y),
            control: CGPoint(x: hip.x + 8.0 * unit, y: waist.y + 5.2 * unit)
        )
        body.addQuadCurve(
            to: CGPoint(x: shoulder.x + 6.6 * unit, y: shoulder.y),
            control: CGPoint(x: shoulder.x + 7.2 * unit, y: (shoulder.y + waist.y) * 0.5)
        )
        body.closeSubpath()
        ctx.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [style.skinLight, style.skin, style.skinShade]),
                startPoint: CGPoint(x: shoulder.x + 6 * unit, y: shoulder.y),
                endPoint: CGPoint(x: hip.x - 7 * unit, y: hip.y + 4 * unit)
            )
        )

        // İnce göbek hattı vurgusu
        ctx.fill(
            Path(ellipseIn: CGRect(x: waist.x + 0.2 * unit, y: waist.y + 3.2 * unit, width: 1.0 * unit, height: 1.4 * unit)),
            with: .color(style.skinShade.opacity(0.65))
        )

        let bikiniGrad = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [style.bikiniPrimary, style.bikiniDeep]),
            startPoint: CGPoint(x: shoulder.x + 4 * unit, y: shoulder.y + 3 * unit),
            endPoint: CGPoint(x: hip.x - 5 * unit, y: hip.y + 6 * unit)
        )

        // Bikini alt + yan bağcık detayı
        var bottom = Path()
        bottom.move(to: CGPoint(x: hip.x - 7.5 * unit, y: hip.y - 2.6 * unit))
        bottom.addQuadCurve(
            to: CGPoint(x: hip.x + 7.5 * unit, y: hip.y - 2.6 * unit),
            control: CGPoint(x: hip.x, y: hip.y - 0.2 * unit)
        )
        bottom.addLine(to: CGPoint(x: hip.x + 1.3 * unit, y: hip.y + 5.8 * unit))
        bottom.addLine(to: CGPoint(x: hip.x - 1.3 * unit, y: hip.y + 5.8 * unit))
        bottom.closeSubpath()
        ctx.fill(bottom, with: bikiniGrad)
        ctx.stroke(bottom, with: .color(style.bikiniTrim.opacity(0.75)), lineWidth: 0.85 * unit)

        // Yan kurdele bağcıkları
        var ties = Path()
        ties.move(to: CGPoint(x: hip.x + 7.4 * unit, y: hip.y - 2.4 * unit))
        ties.addLine(to: CGPoint(x: hip.x + 9.2 * unit, y: hip.y + 0.5 * unit))
        ties.move(to: CGPoint(x: hip.x - 7.4 * unit, y: hip.y - 2.4 * unit))
        ties.addLine(to: CGPoint(x: hip.x - 8.9 * unit, y: hip.y + 0.4 * unit))
        ctx.stroke(ties, with: .color(style.bikiniTrim), style: StrokeStyle(lineWidth: 0.9 * unit, lineCap: .round))

        // Bikini üst + boyun askıları + hafif parlaklık
        let chestY = shoulder.y + 7.6 * unit
        var strap = Path()
        strap.move(to: CGPoint(x: shoulder.x - 2.8 * unit, y: shoulder.y + 0.4 * unit))
        strap.addLine(to: CGPoint(x: shoulder.x - 2.2 * unit, y: chestY))
        strap.move(to: CGPoint(x: shoulder.x + 3.0 * unit, y: shoulder.y + 0.4 * unit))
        strap.addLine(to: CGPoint(x: shoulder.x + 2.8 * unit, y: chestY))
        ctx.stroke(strap, with: .color(style.bikiniTrim), lineWidth: 1.0 * unit)

        var top = Path()
        top.move(to: CGPoint(x: shoulder.x - 6.1 * unit, y: chestY + 2.4 * unit))
        top.addQuadCurve(
            to: CGPoint(x: shoulder.x + 0.2 * unit, y: chestY + 1.1 * unit),
            control: CGPoint(x: shoulder.x - 3.0 * unit, y: chestY - 4.4 * unit)
        )
        top.addQuadCurve(
            to: CGPoint(x: shoulder.x + 6.8 * unit, y: chestY + 2.4 * unit),
            control: CGPoint(x: shoulder.x + 3.8 * unit, y: chestY - 4.4 * unit)
        )
        top.addQuadCurve(
            to: CGPoint(x: shoulder.x - 6.1 * unit, y: chestY + 2.4 * unit),
            control: CGPoint(x: shoulder.x + 0.3 * unit, y: chestY + 4.4 * unit)
        )
        top.closeSubpath()
        ctx.fill(top, with: bikiniGrad)
        ctx.stroke(top, with: .color(style.bikiniTrim.opacity(0.78)), lineWidth: 0.85 * unit)
    }

    private func drawHeadAndFrontHair(
        _ ctx: inout GraphicsContext,
        shoulder: CGPoint,
        head: CGPoint,
        unit: CGFloat,
        wave: CGFloat,
        blinking: Bool
    ) {
        // İnce boyun
        let neck = taperedLimbPath(
            from: CGPoint(x: shoulder.x, y: shoulder.y + 0.8 * unit),
            to: CGPoint(x: head.x - 0.3 * unit, y: head.y + 6.8 * unit),
            rStart: 2.1 * unit,
            rEnd: 1.75 * unit
        )
        ctx.fill(neck, with: .color(style.skinShade))

        // Yüz ovali
        let headRect = CGRect(
            x: head.x - 7.9 * unit,
            y: head.y - 8.5 * unit,
            width: 15.8 * unit,
            height: 17.0 * unit
        )
        ctx.fill(
            Path(ellipseIn: headRect),
            with: .radialGradient(
                Gradient(colors: [style.skinLight, style.skin, style.skinShade]),
                center: CGPoint(x: head.x + 2.2 * unit, y: head.y - 2.0 * unit),
                startRadius: 1,
                endRadius: 10.5 * unit
            )
        )

        // Gözler, kirpikler veya güneş gözlüğü
        let eyeY = head.y - 0.4 * unit
        if style.accessory == .sunglasses {
            let glassRect = CGRect(x: head.x - 1.2 * unit, y: eyeY - 2.0 * unit, width: 8.6 * unit, height: 3.6 * unit)
            ctx.fill(Path(roundedRect: glassRect, cornerRadius: 1.6 * unit), with: .color(Color.black.opacity(0.86)))
            ctx.stroke(Path(roundedRect: glassRect, cornerRadius: 1.6 * unit), with: .color(style.bikiniPrimary), lineWidth: 0.85 * unit)
        } else if blinking {
            var blink = Path()
            blink.move(to: CGPoint(x: head.x + 1.0 * unit, y: eyeY))
            blink.addQuadCurve(to: CGPoint(x: head.x + 3.2 * unit, y: eyeY), control: CGPoint(x: head.x + 2.1 * unit, y: eyeY + 0.7 * unit))
            blink.move(to: CGPoint(x: head.x + 4.7 * unit, y: eyeY))
            blink.addQuadCurve(to: CGPoint(x: head.x + 6.7 * unit, y: eyeY), control: CGPoint(x: head.x + 5.7 * unit, y: eyeY + 0.7 * unit))
            ctx.stroke(blink, with: .color(Color(hex: "#2B1917")), style: StrokeStyle(lineWidth: 1.05 * unit, lineCap: .round))
        } else {
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + 1.2 * unit, y: eyeY - 1.2 * unit, width: 2.1 * unit, height: 2.4 * unit)), with: .color(Color(hex: "#1E1615")))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + 4.7 * unit, y: eyeY - 1.2 * unit, width: 1.9 * unit, height: 2.3 * unit)), with: .color(Color(hex: "#1E1615")))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + 1.7 * unit, y: eyeY - 0.85 * unit, width: 0.75 * unit, height: 0.75 * unit)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + 5.1 * unit, y: eyeY - 0.85 * unit, width: 0.65 * unit, height: 0.65 * unit)), with: .color(.white))
            // İnce kirpik vurgusu
            var lash = Path()
            lash.move(to: CGPoint(x: head.x + 0.8 * unit, y: eyeY - 1.1 * unit))
            lash.addLine(to: CGPoint(x: head.x + 3.3 * unit, y: eyeY - 1.2 * unit))
            lash.move(to: CGPoint(x: head.x + 4.5 * unit, y: eyeY - 1.1 * unit))
            lash.addLine(to: CGPoint(x: head.x + 6.8 * unit, y: eyeY - 1.2 * unit))
            ctx.stroke(lash, with: .color(Color(hex: "#1E1615")), style: StrokeStyle(lineWidth: 0.75 * unit, lineCap: .round))
        }

        // Yanak allığı & gülümseme
        ctx.fill(Path(ellipseIn: CGRect(x: head.x + 0.1 * unit, y: head.y + 1.5 * unit, width: 2.5 * unit, height: 1.3 * unit)), with: .color(Color(hex: "#FB7185").opacity(0.34)))

        var smile = Path()
        smile.move(to: CGPoint(x: head.x + 1.8 * unit, y: head.y + 3.5 * unit))
        smile.addQuadCurve(
            to: CGPoint(x: head.x + 5.3 * unit, y: head.y + 3.3 * unit),
            control: CGPoint(x: head.x + 3.6 * unit, y: head.y + 4.9 * unit)
        )
        ctx.stroke(smile, with: .color(style.lipTint), style: StrokeStyle(lineWidth: 1.15 * unit, lineCap: .round))

        // Ön saç tacı + yüz çerçeveleyen hareketli tutam
        var crown = Path()
        crown.move(to: CGPoint(x: head.x - 8.4 * unit, y: head.y - 1.4 * unit))
        crown.addQuadCurve(
            to: CGPoint(x: head.x + 8.3 * unit, y: head.y - 4.0 * unit),
            control: CGPoint(x: head.x + 0.6 * unit, y: head.y - 13.6 * unit)
        )
        crown.addQuadCurve(
            to: CGPoint(x: head.x - 1.6 * unit, y: head.y - 3.3 * unit),
            control: CGPoint(x: head.x + 3.0 * unit, y: head.y - 5.4 * unit)
        )
        crown.addQuadCurve(
            to: CGPoint(x: head.x - 8.4 * unit, y: head.y + 6.4 * unit + wave * 0.30),
            control: CGPoint(x: head.x - 5.8 * unit, y: head.y + 1.4 * unit)
        )
        crown.closeSubpath()
        ctx.fill(crown, with: .color(style.hair))

        var sheen = Path()
        sheen.move(to: CGPoint(x: head.x - 4.0 * unit, y: head.y - 8.0 * unit))
        sheen.addQuadCurve(
            to: CGPoint(x: head.x + 3.1 * unit, y: head.y - 7.4 * unit),
            control: CGPoint(x: head.x - 0.4 * unit, y: head.y - 10.0 * unit)
        )
        ctx.stroke(sheen, with: .color(style.hairHighlight.opacity(0.68)), style: StrokeStyle(lineWidth: 1.45 * unit, lineCap: .round))

        if style.accessory == .headphones {
            var band = Path()
            band.move(to: CGPoint(x: head.x - 5.6 * unit, y: head.y - 2.4 * unit))
            band.addQuadCurve(
                to: CGPoint(x: head.x + 4.1 * unit, y: head.y - 6.3 * unit),
                control: CGPoint(x: head.x - 1.1 * unit, y: head.y - 12.0 * unit)
            )
            ctx.stroke(band, with: .color(style.bikiniPrimary), lineWidth: 1.65 * unit)
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 6.8 * unit, y: head.y - 2.4 * unit, width: 3.7 * unit, height: 4.9 * unit)), with: .color(style.bikiniPrimary))
        }
    }

    private func drawTaperedArm(
        _ ctx: inout GraphicsContext,
        shoulder: CGPoint,
        upperAngle: Double,
        elbowBend: Double,
        unit: CGFloat,
        mainColor: Color,
        lightColor: Color,
        accessory: BikiniCharacterStyle.AccessoryKind?
    ) {
        let upperLen = 11.6 * unit
        let lowerLen = 10.8 * unit

        let elbow = CGPoint(
            x: shoulder.x + sin(upperAngle) * upperLen,
            y: shoulder.y + cos(upperAngle) * upperLen
        )
        let lowerAngle = upperAngle + elbowBend
        let hand = CGPoint(
            x: elbow.x + sin(lowerAngle) * lowerLen,
            y: elbow.y + cos(lowerAngle) * lowerLen
        )

        let armGrad = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [lightColor, mainColor]),
            startPoint: shoulder,
            endPoint: hand
        )

        ctx.fill(taperedLimbPath(from: shoulder, to: elbow, rStart: 1.9 * unit, rEnd: 1.45 * unit), with: armGrad)
        ctx.fill(taperedLimbPath(from: elbow, to: hand, rStart: 1.45 * unit, rEnd: 1.05 * unit), with: armGrad)
        // Zarif el
        ctx.fill(Path(ellipseIn: CGRect(x: hand.x - 1.2 * unit, y: hand.y - 1.2 * unit, width: 2.4 * unit, height: 2.6 * unit)), with: .color(mainColor))

        switch accessory {
        case .tablet, .notepad:
            let rect = CGRect(x: hand.x - 0.9 * unit, y: hand.y - 4.2 * unit, width: 5.8 * unit, height: 7.4 * unit)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.2 * unit), with: .color(Color(hex: "#1E293B")))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 1.2 * unit), with: .color(style.bikiniTrim), lineWidth: 0.8 * unit)
        case .coffee:
            let cup = CGRect(x: hand.x - 1.5 * unit, y: hand.y - 3.6 * unit, width: 4.4 * unit, height: 5.2 * unit)
            ctx.fill(Path(roundedRect: cup, cornerRadius: 1.0 * unit), with: .color(.white))
            ctx.fill(Path(CGRect(x: cup.minX, y: cup.minY + 1.5 * unit, width: cup.width, height: 1.8 * unit)), with: .color(style.bikiniPrimary))
        case .laptop:
            let lap = CGRect(x: hand.x - 0.8 * unit, y: hand.y - 2.6 * unit, width: 7.2 * unit, height: 4.8 * unit)
            ctx.fill(Path(roundedRect: lap, cornerRadius: 1.0 * unit), with: .color(Color(hex: "#CBD5E1")))
        case .watch:
            ctx.fill(Path(ellipseIn: CGRect(x: hand.x - 1.6 * unit, y: hand.y - 1.6 * unit, width: 2.8 * unit, height: 2.8 * unit)), with: .color(style.bikiniTrim))
        default:
            break
        }
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
        let style = BikiniCharacterStyle.resolve(assetName: resolvedAsset, fallbackAccent: agent.accentHex)
        let phaseOffset = Double(abs(agent.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % 100) * 0.07

        return ZStack(alignment: .topTrailing) {
            ArticulatedBikiniWalkerCanvas(
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
            .frame(width: max(54, size * 0.78), height: size + 10)

            if showStatusDot {
                Circle()
                    .fill(isWalking ? accent : statusColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: (isWalking ? accent : statusColor).opacity(0.8), radius: 3)
                    .offset(x: -8, y: 8)
            }
        }
        .frame(width: max(54, size * 0.78), height: size + 10)
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
            Text("Ofis Çalışanı Karakteri (Canlı Yürüyen Bikinili Figür)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(OfficeAvatarPreset.allPresets) { preset in
                        let isSel = selectedAsset == preset.assetName
                        let style = BikiniCharacterStyle.resolve(assetName: preset.assetName, fallbackAccent: preset.accentHex)
                        Button {
                            selectedAsset = preset.assetName
                        } label: {
                            VStack(spacing: 4) {
                                ArticulatedBikiniWalkerCanvas(
                                    style: style,
                                    accent: Color(hex: preset.accentHex),
                                    status: .idle,
                                    statusColor: .green,
                                    isWalking: isSel,
                                    strideIntensity: isSel ? 1.0 : 0.0,
                                    isSelected: isSel,
                                    facingLeft: false,
                                    phaseOffset: Double(abs(preset.assetName.hashValue) % 30) * 0.1,
                                    reduceMotion: false
                                )
                                .frame(width: 48, height: 64)
                                Text(preset.label.components(separatedBy: " · ").first ?? preset.label)
                                    .font(.system(size: 8.5, weight: isSel ? .bold : .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(width: 72)
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
