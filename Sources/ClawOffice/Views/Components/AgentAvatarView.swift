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

// MARK: - 10 LEGO Minifigür Karakter Stil Profili

private struct LegoMinifigStyle {
    enum HairStyle {
        case capWithTuft, sweptShort, wavyBob, ponytail, hardHat, sleekBob, cyberHelmet, twinTails, stealthHood, emeraldCap
    }
    enum TorsoPrint {
        case leadZipper, alohaLeaves, codeStripes, creativeGeo, denimPocket, coralBadge, cyberCore, cardiganSpark, stealthVest, cloudRacing
    }
    enum AccessoryKind {
        case headsetMic, headset, glassesHeadset, visorHeadset
    }

    let headLight: Color
    let headYellow: Color
    let headShade: Color
    let hair: Color
    let hairDeep: Color
    let hairHighlight: Color
    let torsoTop: Color
    let torsoBottom: Color
    let torsoAccent: Color
    let legsColor: Color
    let shoeStripe: Color
    let headsetColor: Color
    let hairStyle: HairStyle
    let torsoPrint: TorsoPrint
    let accessory: AccessoryKind

    static func resolve(assetName: String, fallbackAccent: String) -> LegoMinifigStyle {
        // Iconic glossy LEGO plastic yellow across minifigure heads & C-claw hands
        let yellowLight = Color(hex: "#FFE96B")
        let yellowBase = Color(hex: "#F5C518")
        let yellowShade = Color(hex: "#C89806")

        switch assetName {
        case "bikini_crimson":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#C81E3A"), hairDeep: Color(hex: "#881326"), hairHighlight: Color(hex: "#FB7185"),
                torsoTop: Color(hex: "#BE123C"), torsoBottom: Color(hex: "#881337"), torsoAccent: .white,
                legsColor: Color(hex: "#334155"), shoeStripe: Color(hex: "#E11D48"), headsetColor: Color(hex: "#CBD5E1"),
                hairStyle: .capWithTuft, torsoPrint: .leadZipper, accessory: .headsetMic
            )
        case "bikini_cyan":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#1E293B"), hairDeep: Color(hex: "#0F172A"), hairHighlight: Color(hex: "#475569"),
                torsoTop: Color(hex: "#0891B2"), torsoBottom: Color(hex: "#155E75"), torsoAccent: Color(hex: "#FDE047"),
                legsColor: Color(hex: "#1E293B"), shoeStripe: Color(hex: "#22D3EE"), headsetColor: Color(hex: "#F97316"),
                hairStyle: .sweptShort, torsoPrint: .alohaLeaves, accessory: .glassesHeadset
            )
        case "bikini_mint":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#FACC15"), hairDeep: Color(hex: "#CA8A04"), hairHighlight: Color(hex: "#FEF08A"),
                torsoTop: Color(hex: "#10B981"), torsoBottom: Color(hex: "#047857"), torsoAccent: .white,
                legsColor: Color(hex: "#0F172A"), shoeStripe: Color(hex: "#34D399"), headsetColor: Color(hex: "#14B8A6"),
                hairStyle: .wavyBob, torsoPrint: .codeStripes, accessory: .headset
            )
        case "bikini_lavender":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#78350F"), hairDeep: Color(hex: "#451A03"), hairHighlight: Color(hex: "#B45309"),
                torsoTop: Color(hex: "#9333EA"), torsoBottom: Color(hex: "#6B21A8"), torsoAccent: Color(hex: "#FDE047"),
                legsColor: Color(hex: "#312E81"), shoeStripe: .white, headsetColor: Color(hex: "#C084FC"),
                hairStyle: .ponytail, torsoPrint: .creativeGeo, accessory: .headsetMic
            )
        case "bikini_gold":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#F59E0B"), hairDeep: Color(hex: "#B45309"), hairHighlight: Color(hex: "#FDE68A"),
                torsoTop: Color(hex: "#2563EB"), torsoBottom: Color(hex: "#1D4ED8"), torsoAccent: Color(hex: "#FDE047"),
                legsColor: Color(hex: "#78716C"), shoeStripe: Color(hex: "#FBBF24"), headsetColor: Color(hex: "#D97706"),
                hairStyle: .hardHat, torsoPrint: .denimPocket, accessory: .glassesHeadset
            )
        case "bikini_coral":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#EA580C"), hairDeep: Color(hex: "#9A3412"), hairHighlight: Color(hex: "#FDBA74"),
                torsoTop: Color(hex: "#F43F5E"), torsoBottom: Color(hex: "#BE123C"), torsoAccent: .white,
                legsColor: Color(hex: "#1E3A8A"), shoeStripe: .white, headsetColor: Color(hex: "#FB7185"),
                hairStyle: .sleekBob, torsoPrint: .coralBadge, accessory: .headsetMic
            )
        case "bikini_cobalt":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#1D4ED8"), hairDeep: Color(hex: "#1E3A8A"), hairHighlight: Color(hex: "#60A5FA"),
                torsoTop: Color(hex: "#E2E8F0"), torsoBottom: Color(hex: "#94A3B8"), torsoAccent: Color(hex: "#2563EB"),
                legsColor: Color(hex: "#1E293B"), shoeStripe: Color(hex: "#38BDF8"), headsetColor: Color(hex: "#3B82F6"),
                hairStyle: .cyberHelmet, torsoPrint: .cyberCore, accessory: .visorHeadset
            )
        case "bikini_rosegold":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#EC4899"), hairDeep: Color(hex: "#9D174D"), hairHighlight: Color(hex: "#F9A8D4"),
                torsoTop: Color(hex: "#F472B6"), torsoBottom: Color(hex: "#DB2777"), torsoAccent: .white,
                legsColor: Color(hex: "#475569"), shoeStripe: Color(hex: "#FBCFE8"), headsetColor: Color(hex: "#F43F5E"),
                hairStyle: .twinTails, torsoPrint: .cardiganSpark, accessory: .headsetMic
            )
        case "bikini_ruby":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#27272A"), hairDeep: Color(hex: "#09090B"), hairHighlight: Color(hex: "#52525B"),
                torsoTop: Color(hex: "#18181B"), torsoBottom: Color(hex: "#09090B"), torsoAccent: Color(hex: "#DC2626"),
                legsColor: Color(hex: "#27272A"), shoeStripe: Color(hex: "#EF4444"), headsetColor: Color(hex: "#DC2626"),
                hairStyle: .stealthHood, torsoPrint: .stealthVest, accessory: .visorHeadset
            )
        case "bikini_emerald":
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#0D9488"), hairDeep: Color(hex: "#115E59"), hairHighlight: Color(hex: "#5EEAD4"),
                torsoTop: Color(hex: "#14B8A6"), torsoBottom: Color(hex: "#0F766E"), torsoAccent: .white,
                legsColor: Color(hex: "#1E293B"), shoeStripe: Color(hex: "#2DD4BF"), headsetColor: Color(hex: "#34D399"),
                hairStyle: .emeraldCap, torsoPrint: .cloudRacing, accessory: .headsetMic
            )
        default:
            let col = Color(hex: fallbackAccent)
            return .init(
                headLight: yellowLight, headYellow: yellowBase, headShade: yellowShade,
                hair: Color(hex: "#334155"), hairDeep: Color(hex: "#0F172A"), hairHighlight: Color(hex: "#64748B"),
                torsoTop: col, torsoBottom: col.opacity(0.75), torsoAccent: .white,
                legsColor: Color(hex: "#1E293B"), shoeStripe: col, headsetColor: col,
                hairStyle: .sweptShort, torsoPrint: .codeStripes, accessory: .headsetMic
            )
        }
    }
}

// MARK: - 60 FPS Articulated LEGO Minifigure Walker & Bust Portrait

private struct ArticulatedLegoMinifigCanvas: View {
    let style: LegoMinifigStyle
    let accent: Color
    let status: AgentStatus
    let statusColor: Color
    let isWalking: Bool
    let strideIntensity: Double
    let isSelected: Bool
    let facingLeft: Bool
    let phaseOffset: Double
    let reduceMotion: Bool
    var bustOnly: Bool = false

    private let inkColor = Color(hex: "#161822")
    private var isBusy: Bool { status.isBusy }

    var body: some View {
        let shouldAnimate = !bustOnly && !reduceMotion && (isWalking || isBusy || status == .chatting || status == .collaborating || status == .improving || status == .error)
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shouldAnimate)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let walkCycle = (t + phaseOffset) * 9.0
            let idleCycle = (t + phaseOffset) * 2.2

            Canvas { ctx, size in
                if bustOnly {
                    drawBustPortrait(&ctx, size: size, blinking: false)
                    return
                }
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
                    if activeWalk { return CGFloat(abs(sin(walkCycle)) * -2.8 * amp) * unit }
                    if isErrorPose && !reduceMotion { return CGFloat(sin(t * 24.0) * 0.8) * unit }
                    return CGFloat(sin(idleCycle) * -0.5) * unit
                }()
                let shadowScale = activeWalk ? (0.86 + 0.14 * abs(cos(walkCycle)) * amp) : 1.0

                // 1) LEGO Baseplate Contact Shadow & Stud Plate Ring
                let shadowRect = CGRect(
                    x: cx - 18.0 * unit * shadowScale,
                    y: groundY - 4.2 * unit,
                    width: 36.0 * unit * shadowScale,
                    height: 8.4 * unit
                )
                ctx.fill(
                    Path(ellipseIn: shadowRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            (isSelected || isWalking ? accent : Color.black).opacity(isSelected ? 0.52 : 0.36),
                            .clear
                        ]),
                        center: CGPoint(x: shadowRect.midX, y: shadowRect.midY),
                        startRadius: 1,
                        endRadius: shadowRect.width * 0.55
                    )
                )

                if activeWalk {
                    let stepPhase = fmod(abs(walkCycle / .pi), 1.0)
                    let rippleW = (18 + stepPhase * 22) * unit
                    let rippleH = (4.2 + stepPhase * 5.2) * unit
                    let rippleRect = CGRect(x: cx - rippleW * 0.5, y: groundY - rippleH * 0.5, width: rippleW, height: rippleH)
                    ctx.stroke(
                        Path(ellipseIn: rippleRect),
                        with: .color(Color.cyan.opacity((1.0 - stepPhase) * 0.55)),
                        lineWidth: 1.2
                    )
                }

                // Miniature 2x2 LEGO baseplate under active/selected minifig
                if isWalking || isBusy || isSelected {
                    let plateW = 30.0 * unit
                    let plateH = 7.4 * unit
                    let plateRect = CGRect(x: cx - plateW * 0.5, y: groundY - plateH * 0.48, width: plateW, height: plateH)
                    let plateCol = (isWalking || isSelected ? accent : statusColor)
                    ctx.fill(Path(roundedRect: plateRect, cornerRadius: 2.2 * unit), with: .color(plateCol.opacity(0.24)))
                    ctx.stroke(Path(roundedRect: plateRect, cornerRadius: 2.2 * unit), with: .color(plateCol.opacity(0.88)), lineWidth: isSelected ? 1.8 : 1.25)
                }

                var fig = ctx
                if facingLeft {
                    fig.translateBy(x: w, y: 0)
                    fig.scaleBy(x: -1, y: 1)
                }

                let hipY = groundY - 22.5 * unit + bob
                let hipCenter = CGPoint(x: cx, y: hipY)
                let torsoTopY = hipY - 25.0 * unit
                let shoulderCenter = CGPoint(x: cx, y: torsoTopY)
                let headCenter = CGPoint(x: cx, y: torsoTopY - 17.5 * unit)

                let backLegSwing = activeWalk ? oppStride * 0.54 : -0.05
                let frontLegSwing = activeWalk ? stride * 0.54 : 0.05

                let backArmSwing: Double = {
                    if activeWalk { return stride * 0.58 }
                    if isWorkingPose && !reduceMotion { return -0.62 + cos(idleCycle * 4.8) * 0.10 }
                    if isChatPose && !reduceMotion { return -0.35 + sin(idleCycle * 3.0) * 0.16 }
                    return 0.14
                }()
                let frontArmSwing: Double = {
                    if activeWalk { return oppStride * 0.58 }
                    if isWorkingPose && !reduceMotion { return -0.78 + sin(idleCycle * 5.2) * 0.12 }
                    if isThinkingPose && !reduceMotion { return -0.96 + sin(idleCycle * 1.4) * 0.06 }
                    if isChatPose && !reduceMotion { return -0.58 + sin(idleCycle * 3.2) * 0.24 }
                    if isImprovingPose && !reduceMotion { return -2.2 + sin(idleCycle * 4.5) * 0.25 }
                    if isErrorPose { return -1.85 }
                    return -0.14
                }()

                // 2) Long Back Hair (ponytail / twinTails / wavyBob / sleekBob)
                drawLegoBackHair(&fig, head: headCenter, unit: unit, inkW: inkW, sway: activeWalk ? CGFloat(stride) * 1.8 * unit : 0)

                // 3) Back LEGO Arm + C-Claw
                drawLegoArm(
                    &fig,
                    shoulder: CGPoint(x: shoulderCenter.x - 10.6 * unit, y: shoulderCenter.y + 4.0 * unit),
                    angle: backArmSwing,
                    elbowBend: isWorkingPose ? 0.55 : (activeWalk ? 0.22 * amp : 0.12),
                    unit: unit,
                    inkW: inkW,
                    sleeve: style.torsoBottom,
                    hand: style.headShade
                )

                // 4) Back Rectangular LEGO Leg
                drawLegoBlockLeg(
                    &fig,
                    hip: CGPoint(x: hipCenter.x - 5.4 * unit, y: hipCenter.y + 1.2 * unit),
                    swing: backLegSwing,
                    unit: unit,
                    inkW: inkW,
                    legColor: style.legsColor,
                    isBack: true
                )

                // 5) Iconic Trapezoidal LEGO Torso & Hip Piece
                drawLegoTorsoAndHip(&fig, hip: hipCenter, shoulder: shoulderCenter, unit: unit, inkW: inkW)

                // 6) Front Rectangular LEGO Leg
                drawLegoBlockLeg(
                    &fig,
                    hip: CGPoint(x: hipCenter.x + 5.2 * unit, y: hipCenter.y + 1.2 * unit),
                    swing: frontLegSwing,
                    unit: unit,
                    inkW: inkW,
                    legColor: style.legsColor,
                    isBack: false
                )

                // 7) Cylindrical LEGO Head + Top Stud + Printed Expression + Molded Hair/Hat/Headset
                let isBlinking = !reduceMotion && fmod(t + phaseOffset, 4.1) > 3.96
                drawLegoHeadAndGear(&fig, head: headCenter, unit: unit, inkW: inkW, blinking: isBlinking)

                // 8) Front LEGO Arm + Iconic C-Claw Hand
                drawLegoArm(
                    &fig,
                    shoulder: CGPoint(x: shoulderCenter.x + 11.0 * unit, y: shoulderCenter.y + 4.0 * unit),
                    angle: frontArmSwing,
                    elbowBend: isWorkingPose ? 0.65 : (isThinkingPose ? 0.85 : (activeWalk ? 0.25 * amp : 0.14)),
                    unit: unit,
                    inkW: inkW,
                    sleeve: style.torsoTop,
                    hand: style.headYellow
                )

                // 9) Active Status Micro-FX (LEGO Hologram Brick / Stud Bubbles / Error Alert)
                if !reduceMotion {
                    if isWorkingPose {
                        let laptopPt = CGPoint(x: shoulderCenter.x + 14.0 * unit, y: shoulderCenter.y + 8.5 * unit)
                        let glowR = 11.0 * unit
                        fig.fill(
                            Path(ellipseIn: CGRect(x: laptopPt.x - glowR, y: laptopPt.y - glowR, width: glowR * 2, height: glowR * 2)),
                            with: .radialGradient(Gradient(colors: [Color.cyan.opacity(0.42), .clear]), center: laptopPt, startRadius: 1, endRadius: glowR)
                        )
                    } else if isThinkingPose {
                        for idx in 0..<3 {
                            let p = t * 2.0 + phaseOffset + Double(idx) * 1.8
                            let bx = headCenter.x + 16.0 * unit + CGFloat(cos(p)) * 2.5 * unit
                            let by = headCenter.y - 14.5 * unit - CGFloat(idx) * 4.2 * unit
                            let sz = (2.6 + Double(idx) * 0.9) * unit
                            fig.fill(Path(roundedRect: CGRect(x: bx - sz * 0.5, y: by - sz * 0.5, width: sz, height: sz * 0.72), cornerRadius: 0.7 * unit), with: .color(Color.cyan.opacity(0.84)))
                        }
                    } else if isImprovingPose {
                        for idx in 0..<4 {
                            let p = fmod(t * 0.75 + phaseOffset + Double(idx) * 0.25, 1.0)
                            let sx = cx + CGFloat(sin(Double(idx) * 1.7 + p * 4.0)) * 16.0 * unit
                            let sy = groundY - CGFloat(p) * 82.0 * unit
                            let s = 3.0 * unit
                            fig.fill(Path(roundedRect: CGRect(x: sx - s * 0.5, y: sy - s * 0.4, width: s, height: s * 0.7), cornerRadius: 0.6 * unit), with: .color(Color.mint.opacity((1.0 - p) * 0.88)))
                        }
                    } else if isErrorPose {
                        let pulse = 0.55 + 0.45 * abs(sin(t * 7.0))
                        let ex = headCenter.x + 16.0 * unit
                        let ey = headCenter.y - 13.5 * unit
                        fig.fill(Path(ellipseIn: CGRect(x: ex - 3.6 * unit, y: ey - 3.6 * unit, width: 7.2 * unit, height: 7.2 * unit)), with: .color(Color.red.opacity(pulse)))
                    }
                }
            }
        }
    }

    private func drawBustPortrait(_ ctx: inout GraphicsContext, size: CGSize, blinking: Bool) {
        let unit = min(size.width, size.height) / 48.0
        let inkW = max(0.85, 1.25 * unit)
        let cx = size.width * 0.5
        let headCenter = CGPoint(x: cx, y: size.height * 0.46)
        let shoulderCenter = CGPoint(x: cx, y: headCenter.y + 15.5 * unit)

        drawLegoBackHair(&ctx, head: headCenter, unit: unit, inkW: inkW, sway: 0)
        // Compact Torso Shoulders Peak
        var bust = Path()
        bust.move(to: CGPoint(x: shoulderCenter.x - 13.0 * unit, y: shoulderCenter.y))
        bust.addQuadCurve(to: CGPoint(x: shoulderCenter.x + 13.0 * unit, y: shoulderCenter.y), control: CGPoint(x: shoulderCenter.x, y: shoulderCenter.y - 3.0 * unit))
        bust.addLine(to: CGPoint(x: shoulderCenter.x + 15.5 * unit, y: size.height + 4))
        bust.addLine(to: CGPoint(x: shoulderCenter.x - 15.5 * unit, y: size.height + 4))
        bust.closeSubpath()
        ctx.fill(bust, with: .linearGradient(Gradient(colors: [style.torsoTop, style.torsoBottom]), startPoint: shoulderCenter, endPoint: CGPoint(x: cx, y: size.height)))
        ctx.stroke(bust, with: .color(inkColor), lineWidth: inkW)
        drawLegoHeadAndGear(&ctx, head: headCenter, unit: unit, inkW: inkW, blinking: blinking)
    }

    private func drawLegoBackHair(_ ctx: inout GraphicsContext, head: CGPoint, unit: CGFloat, inkW: CGFloat, sway: CGFloat) {
        switch style.hairStyle {
        case .ponytail, .twinTails, .wavyBob, .sleekBob, .emeraldCap:
            let len: CGFloat = (style.hairStyle == .ponytail || style.hairStyle == .twinTails) ? 20.0 * unit : 13.0 * unit
            var p = Path()
            p.move(to: CGPoint(x: head.x - 12.2 * unit, y: head.y - 3.0 * unit))
            p.addQuadCurve(to: CGPoint(x: head.x - 13.8 * unit - sway, y: head.y + len), control: CGPoint(x: head.x - 16.5 * unit, y: head.y + len * 0.5))
            p.addQuadCurve(to: CGPoint(x: head.x + 12.6 * unit - sway * 0.5, y: head.y + len * 0.86), control: CGPoint(x: head.x, y: head.y + len * 1.12))
            p.addLine(to: CGPoint(x: head.x + 12.0 * unit, y: head.y - 3.0 * unit))
            p.closeSubpath()
            ctx.fill(p, with: .color(style.hairDeep))
            ctx.stroke(p, with: .color(inkColor), lineWidth: inkW * 0.9)
        default:
            break
        }
    }

    private func drawLegoBlockLeg(
        _ ctx: inout GraphicsContext,
        hip: CGPoint,
        swing: Double,
        unit: CGFloat,
        inkW: CGFloat,
        legColor: Color,
        isBack: Bool
    ) {
        let legW: CGFloat = 10.2 * unit
        let legH: CGFloat = 15.6 * unit
        let ankleY = hip.y + cos(swing) * legH
        let ankleX = hip.x + sin(swing) * legH

        var legCtx = ctx
        legCtx.translateBy(x: hip.x, y: hip.y)
        legCtx.rotate(by: Angle(radians: -swing))

        let blockRect = CGRect(x: -legW * 0.5, y: 0, width: legW, height: legH)
        let blockPath = Path(roundedRect: blockRect, cornerRadius: 1.4 * unit)
        legCtx.fill(
            blockPath,
            with: .linearGradient(
                Gradient(colors: [
                    isBack ? legColor.opacity(0.84) : legColor,
                    Color.black.opacity(isBack ? 0.25 : 0.08)
                ]),
                startPoint: CGPoint(x: -legW * 0.5, y: 0),
                endPoint: CGPoint(x: legW * 0.5, y: legH)
            )
        )
        legCtx.stroke(blockPath, with: .color(inkColor), lineWidth: inkW)

        // Chunky forward-extruded LEGO toe foot block + side brick seam
        let footRect = CGRect(x: -legW * 0.48, y: legH - 4.4 * unit, width: legW * 1.16, height: 4.5 * unit)
        let footPath = Path(roundedRect: footRect, cornerRadius: 1.2 * unit)
        legCtx.fill(footPath, with: .color(isBack ? legColor.opacity(0.9) : legColor))
        legCtx.stroke(footPath, with: .color(inkColor), lineWidth: inkW * 0.9)

        let stripeRect = CGRect(x: footRect.minX + 1.0 * unit, y: footRect.minY + 1.1 * unit, width: footRect.width - 2.0 * unit, height: 1.5 * unit)
        legCtx.fill(Path(roundedRect: stripeRect, cornerRadius: 0.6 * unit), with: .color(style.shoeStripe))
        _ = (ankleX, ankleY)
    }

    private func drawLegoTorsoAndHip(
        _ ctx: inout GraphicsContext,
        hip: CGPoint,
        shoulder: CGPoint,
        unit: CGFloat,
        inkW: CGFloat
    ) {
        // Boxy LEGO Hip Bar with center notch
        let hipRect = CGRect(x: hip.x - 11.4 * unit, y: hip.y - 3.6 * unit, width: 22.8 * unit, height: 6.0 * unit)
        let hipPath = Path(roundedRect: hipRect, cornerRadius: 1.5 * unit)
        ctx.fill(hipPath, with: .color(style.legsColor))
        ctx.stroke(hipPath, with: .color(inkColor), lineWidth: inkW)
        ctx.fill(Path(CGRect(x: hip.x - 1.2 * unit, y: hipRect.minY + 1.0 * unit, width: 2.4 * unit, height: hipRect.height - 1.5 * unit)), with: .color(inkColor.opacity(0.45)))

        // Classic Trapezoidal Molded LEGO Torso
        var torso = Path()
        torso.move(to: CGPoint(x: shoulder.x - 9.4 * unit, y: shoulder.y))
        torso.addLine(to: CGPoint(x: shoulder.x + 9.4 * unit, y: shoulder.y))
        torso.addLine(to: CGPoint(x: hip.x + 11.4 * unit, y: hip.y - 3.0 * unit))
        torso.addLine(to: CGPoint(x: hip.x - 11.4 * unit, y: hip.y - 3.0 * unit))
        torso.closeSubpath()

        ctx.fill(
            torso,
            with: .linearGradient(
                Gradient(colors: [style.torsoTop, style.torsoBottom]),
                startPoint: CGPoint(x: shoulder.x - 8 * unit, y: shoulder.y),
                endPoint: CGPoint(x: hip.x + 10 * unit, y: hip.y)
            )
        )
        ctx.stroke(torso, with: .color(inkColor), lineWidth: inkW)

        // Plastic left edge highlight
        var shine = Path()
        shine.move(to: CGPoint(x: shoulder.x - 7.5 * unit, y: shoulder.y + 1.8 * unit))
        shine.addLine(to: CGPoint(x: hip.x - 9.0 * unit, y: hip.y - 4.8 * unit))
        ctx.stroke(shine, with: .color(Color.white.opacity(0.32)), style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round))

        // Printed LEGO chest graphic
        let midY = (shoulder.y + hip.y - 3.0 * unit) * 0.5
        switch style.torsoPrint {
        case .leadZipper, .coralBadge, .cardiganSpark:
            let badge = CGRect(x: shoulder.x - 4.0 * unit, y: midY - 4.2 * unit, width: 8.0 * unit, height: 8.0 * unit)
            ctx.fill(Path(roundedRect: badge, cornerRadius: 2.0 * unit), with: .color(style.torsoAccent.opacity(0.92)))
            ctx.stroke(Path(roundedRect: badge, cornerRadius: 2.0 * unit), with: .color(inkColor.opacity(0.65)), lineWidth: inkW * 0.55)
        case .codeStripes, .cloudRacing:
            for dy in [-3.0, 2.0] {
                let bar = CGRect(x: shoulder.x - 7.5 * unit, y: midY + dy * unit, width: 15.0 * unit, height: 2.2 * unit)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 0.7 * unit), with: .color(style.torsoAccent.opacity(0.88)))
            }
        case .cyberCore, .stealthVest:
            let core = Path(ellipseIn: CGRect(x: shoulder.x - 4.2 * unit, y: midY - 4.2 * unit, width: 8.4 * unit, height: 8.4 * unit))
            ctx.fill(core, with: .color(style.torsoAccent.opacity(0.95)))
            ctx.stroke(core, with: .color(inkColor), lineWidth: inkW * 0.7)
        default:
            // Collar V + utility pocket
            var collar = Path()
            collar.move(to: CGPoint(x: shoulder.x - 4.2 * unit, y: shoulder.y + 0.5 * unit))
            collar.addLine(to: CGPoint(x: shoulder.x, y: shoulder.y + 5.2 * unit))
            collar.addLine(to: CGPoint(x: shoulder.x + 4.2 * unit, y: shoulder.y + 0.5 * unit))
            ctx.stroke(collar, with: .color(style.torsoAccent.opacity(0.90)), style: StrokeStyle(lineWidth: 1.5 * unit, lineJoin: .round))
            let pkt = CGRect(x: shoulder.x + 2.2 * unit, y: midY - 1.5 * unit, width: 5.0 * unit, height: 4.5 * unit)
            ctx.fill(Path(roundedRect: pkt, cornerRadius: 0.8 * unit), with: .color(style.torsoAccent.opacity(0.75)))
        }
    }

    private func drawLegoHeadAndGear(
        _ ctx: inout GraphicsContext,
        head: CGPoint,
        unit: CGFloat,
        inkW: CGFloat,
        blinking: Bool
    ) {
        // Neck Collar Pin
        let neckRect = CGRect(x: head.x - 4.8 * unit, y: head.y + 9.2 * unit, width: 9.6 * unit, height: 3.6 * unit)
        ctx.fill(Path(roundedRect: neckRect, cornerRadius: 1.2 * unit), with: .color(style.headShade))
        ctx.stroke(Path(roundedRect: neckRect, cornerRadius: 1.2 * unit), with: .color(inkColor), lineWidth: inkW * 0.85)

        // Signature Top LEGO Stud (clearly visible on cylindrical head!)
        let studW = 9.8 * unit
        let studH = 4.2 * unit
        let studRect = CGRect(x: head.x - studW * 0.5, y: head.y - 14.2 * unit, width: studW, height: studH + 1.5 * unit)
        ctx.fill(
            Path(roundedRect: studRect, cornerRadius: 1.6 * unit),
            with: .linearGradient(
                Gradient(colors: [style.headLight, style.headYellow, style.headShade]),
                startPoint: CGPoint(x: studRect.minX, y: studRect.midY),
                endPoint: CGPoint(x: studRect.maxX, y: studRect.midY)
            )
        )
        ctx.stroke(Path(roundedRect: studRect, cornerRadius: 1.6 * unit), with: .color(inkColor), lineWidth: inkW * 0.9)

        // Cylindrical Beveled LEGO Head Block
        let hw: CGFloat = 23.8 * unit
        let hh: CGFloat = 20.6 * unit
        let headRect = CGRect(x: head.x - hw * 0.5, y: head.y - hh * 0.5, width: hw, height: hh)
        let headPath = Path(roundedRect: headRect, cornerRadius: 5.2 * unit)
        ctx.fill(
            headPath,
            with: .linearGradient(
                Gradient(colors: [style.headLight, style.headYellow, style.headShade]),
                startPoint: CGPoint(x: headRect.minX + 2 * unit, y: headRect.midY - 3 * unit),
                endPoint: CGPoint(x: headRect.maxX, y: headRect.midY + 3 * unit)
            )
        )
        ctx.stroke(headPath, with: .color(inkColor), lineWidth: inkW)

        // Cylindrical plastic vertical sheen strip
        let glossRect = CGRect(x: headRect.minX + 3.2 * unit, y: headRect.minY + 3.0 * unit, width: 3.2 * unit, height: hh - 6.0 * unit)
        ctx.fill(Path(roundedRect: glossRect, cornerRadius: 1.5 * unit), with: .color(Color.white.opacity(0.32)))

        // Classic Printed LEGO Minifigure Face
        let eyeY = head.y + 0.6 * unit
        let leftEyeX = head.x - 2.8 * unit
        let rightEyeX = head.x + 5.8 * unit
        if blinking {
            var blink = Path()
            blink.move(to: CGPoint(x: leftEyeX - 2.0 * unit, y: eyeY))
            blink.addQuadCurve(to: CGPoint(x: leftEyeX + 2.0 * unit, y: eyeY), control: CGPoint(x: leftEyeX, y: eyeY + 1.2 * unit))
            blink.move(to: CGPoint(x: rightEyeX - 2.0 * unit, y: eyeY))
            blink.addQuadCurve(to: CGPoint(x: rightEyeX + 2.0 * unit, y: eyeY), control: CGPoint(x: rightEyeX, y: eyeY + 1.2 * unit))
            ctx.stroke(blink, with: .color(inkColor), style: StrokeStyle(lineWidth: inkW * 1.1, lineCap: .round))
        } else {
            for ex in [leftEyeX, rightEyeX] {
                let er = CGRect(x: ex - 1.75 * unit, y: eyeY - 2.2 * unit, width: 3.5 * unit, height: 4.4 * unit)
                ctx.fill(Path(ellipseIn: er), with: .color(inkColor))
                ctx.fill(Path(ellipseIn: CGRect(x: ex - 0.6 * unit, y: eyeY - 1.4 * unit, width: 1.4 * unit, height: 1.4 * unit)), with: .color(.white))
            }
        }

        // Expressive printed LEGO eyebrows
        var brows = Path()
        brows.move(to: CGPoint(x: leftEyeX - 2.2 * unit, y: eyeY - 3.6 * unit))
        brows.addQuadCurve(to: CGPoint(x: leftEyeX + 2.0 * unit, y: eyeY - 3.8 * unit), control: CGPoint(x: leftEyeX, y: eyeY - 4.7 * unit))
        brows.move(to: CGPoint(x: rightEyeX - 2.0 * unit, y: eyeY - 3.8 * unit))
        brows.addQuadCurve(to: CGPoint(x: rightEyeX + 2.0 * unit, y: eyeY - 3.6 * unit), control: CGPoint(x: rightEyeX, y: eyeY - 4.7 * unit))
        ctx.stroke(brows, with: .color(inkColor), style: StrokeStyle(lineWidth: 1.15 * unit, lineCap: .round))

        // Printed LEGO mouth based on live status
        if status == .error {
            ctx.fill(Path(ellipseIn: CGRect(x: head.x + 0.3 * unit, y: eyeY + 3.6 * unit, width: 3.2 * unit, height: 2.8 * unit)), with: .color(inkColor))
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: head.x - 1.2 * unit, y: eyeY + 4.4 * unit))
            smile.addQuadCurve(
                to: CGPoint(x: head.x + 4.4 * unit, y: eyeY + 4.2 * unit),
                control: CGPoint(x: head.x + 1.6 * unit, y: eyeY + (status.isBusy ? 5.3 : 6.7) * unit)
            )
            ctx.stroke(smile, with: .color(inkColor), style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round))
        }

        // Glasses / Cyber Visor Accessory
        if style.accessory == .glassesHeadset || style.accessory == .visorHeadset {
            let lGlass = CGRect(x: leftEyeX - 3.0 * unit, y: eyeY - 3.0 * unit, width: 6.0 * unit, height: 5.2 * unit)
            let rGlass = CGRect(x: rightEyeX - 2.8 * unit, y: eyeY - 3.0 * unit, width: 5.8 * unit, height: 5.2 * unit)
            let frameCol = style.accessory == .visorHeadset ? Color(hex: "#06B6D4") : style.hairDeep
            if style.accessory == .visorHeadset {
                ctx.fill(Path(roundedRect: lGlass, cornerRadius: 1.2 * unit), with: .color(Color.cyan.opacity(0.28)))
                ctx.fill(Path(roundedRect: rGlass, cornerRadius: 1.2 * unit), with: .color(Color.cyan.opacity(0.28)))
            }
            ctx.stroke(Path(roundedRect: lGlass, cornerRadius: 1.2 * unit), with: .color(frameCol), lineWidth: 1.2 * unit)
            ctx.stroke(Path(roundedRect: rGlass, cornerRadius: 1.2 * unit), with: .color(frameCol), lineWidth: 1.2 * unit)
            var bridge = Path()
            bridge.move(to: CGPoint(x: lGlass.maxX, y: eyeY - 0.5 * unit))
            bridge.addLine(to: CGPoint(x: rGlass.minX, y: eyeY - 0.5 * unit))
            ctx.stroke(bridge, with: .color(frameCol), lineWidth: 1.2 * unit)
        }

        // Sculpted Molded LEGO Hairpiece / Cap / Hard-Hat / Cyber Helmet
        drawLegoHeadgear(&ctx, headRect: headRect, studRect: studRect, head: head, unit: unit, inkW: inkW)

        // Studio Headset + Mic Clip
        let earCup = CGRect(x: headRect.minX - 2.8 * unit, y: head.y - 2.8 * unit, width: 4.8 * unit, height: 8.2 * unit)
        ctx.fill(Path(roundedRect: earCup, cornerRadius: 2.0 * unit), with: .color(style.headsetColor))
        ctx.stroke(Path(roundedRect: earCup, cornerRadius: 2.0 * unit), with: .color(inkColor), lineWidth: inkW * 0.8)

        if style.accessory != .headset {
            var mic = Path()
            mic.move(to: CGPoint(x: earCup.maxX - 0.6 * unit, y: earCup.maxY - 1.5 * unit))
            mic.addQuadCurve(to: CGPoint(x: head.x + 1.5 * unit, y: eyeY + 5.6 * unit), control: CGPoint(x: head.x - 6.0 * unit, y: eyeY + 6.4 * unit))
            ctx.stroke(mic, with: .color(inkColor), style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round))
        }
    }

    private func drawLegoHeadgear(
        _ ctx: inout GraphicsContext,
        headRect: CGRect,
        studRect: CGRect,
        head: CGPoint,
        unit: CGFloat,
        inkW: CGFloat
    ) {
        switch style.hairStyle {
        case .capWithTuft, .emeraldCap, .hardHat:
            // Molded LEGO Cap / Architect Hard Hat resting cleanly above brows, with top brick stud preserved!
            let capRect = CGRect(x: headRect.minX - 1.4 * unit, y: headRect.minY - 3.6 * unit, width: headRect.width + 2.8 * unit, height: 9.0 * unit)
            let capPath = Path(roundedRect: capRect, cornerRadius: 4.2 * unit)
            ctx.fill(capPath, with: .linearGradient(Gradient(colors: [style.hairHighlight, style.hair, style.hairDeep]), startPoint: CGPoint(x: capRect.minX, y: capRect.minY), endPoint: CGPoint(x: capRect.maxX, y: capRect.maxY)))
            ctx.stroke(capPath, with: .color(inkColor), lineWidth: inkW * 0.9)

            // Front LEGO cap visor bill
            let brimRect = CGRect(x: headRect.midX + 1.0 * unit, y: capRect.maxY - 3.0 * unit, width: 14.5 * unit, height: 3.4 * unit)
            ctx.fill(Path(roundedRect: brimRect, cornerRadius: 1.5 * unit), with: .color(style.hairDeep))
            ctx.stroke(Path(roundedRect: brimRect, cornerRadius: 1.5 * unit), with: .color(inkColor), lineWidth: inkW * 0.85)

            // Matching color stud button atop cap/helmet!
            ctx.fill(Path(roundedRect: studRect, cornerRadius: 1.4 * unit), with: .color(style.hair))
            ctx.stroke(Path(roundedRect: studRect, cornerRadius: 1.4 * unit), with: .color(inkColor), lineWidth: inkW * 0.85)

        case .cyberHelmet, .stealthHood:
            // Futuristic LEGO Cowl / Helmet enclosing sides & brow
            var cowl = Path()
            cowl.move(to: CGPoint(x: headRect.minX - 1.8 * unit, y: head.y + 4.5 * unit))
            cowl.addLine(to: CGPoint(x: headRect.minX - 1.8 * unit, y: headRect.minY - 3.5 * unit))
            cowl.addQuadCurve(to: CGPoint(x: headRect.maxX + 1.8 * unit, y: headRect.minY - 3.5 * unit), control: CGPoint(x: head.x, y: headRect.minY - 6.8 * unit))
            cowl.addLine(to: CGPoint(x: headRect.maxX + 1.8 * unit, y: headRect.minY + 5.2 * unit))
            cowl.addLine(to: CGPoint(x: headRect.maxX - 3.5 * unit, y: headRect.minY + 3.2 * unit))
            cowl.addLine(to: CGPoint(x: headRect.minX + 3.8 * unit, y: headRect.minY + 3.8 * unit))
            cowl.addLine(to: CGPoint(x: headRect.minX + 2.8 * unit, y: head.y + 4.5 * unit))
            cowl.closeSubpath()
            ctx.fill(cowl, with: .linearGradient(Gradient(colors: [style.hairHighlight, style.hair, style.hairDeep]), startPoint: CGPoint(x: headRect.minX, y: headRect.minY), endPoint: CGPoint(x: headRect.maxX, y: headRect.maxY)))
            ctx.stroke(cowl, with: .color(inkColor), lineWidth: inkW * 0.9)

        default:
            // Chunky Snap-On Sculpted LEGO Hairpiece leaving glowing yellow LEGO stud silhouette clear or crisp hair swoop
            var hair = Path()
            hair.move(to: CGPoint(x: headRect.minX - 1.6 * unit, y: head.y + 1.0 * unit))
            hair.addQuadCurve(to: CGPoint(x: headRect.minX - 0.5 * unit, y: headRect.minY - 4.2 * unit), control: CGPoint(x: headRect.minX - 3.0 * unit, y: headRect.minY))
            hair.addQuadCurve(to: CGPoint(x: headRect.maxX + 1.4 * unit, y: headRect.minY - 1.2 * unit), control: CGPoint(x: head.x + 2.0 * unit, y: headRect.minY - 7.0 * unit))
            hair.addQuadCurve(to: CGPoint(x: headRect.maxX - 2.0 * unit, y: headRect.minY + 5.5 * unit), control: CGPoint(x: headRect.maxX + 1.5 * unit, y: headRect.minY + 3.0 * unit))
            hair.addQuadCurve(to: CGPoint(x: head.x + 1.5 * unit, y: headRect.minY + 3.5 * unit), control: CGPoint(x: head.x + 5.0 * unit, y: headRect.minY + 1.8 * unit))
            hair.addQuadCurve(to: CGPoint(x: headRect.minX + 2.4 * unit, y: head.y + 2.0 * unit), control: CGPoint(x: headRect.minX + 4.5 * unit, y: headRect.minY + 5.5 * unit))
            hair.closeSubpath()
            ctx.fill(hair, with: .linearGradient(Gradient(colors: [style.hairHighlight, style.hair, style.hairDeep]), startPoint: CGPoint(x: headRect.minX, y: headRect.minY), endPoint: CGPoint(x: headRect.maxX, y: headRect.maxY)))
            ctx.stroke(hair, with: .color(inkColor), lineWidth: inkW * 0.9)
        }
    }

    private func drawLegoArm(
        _ ctx: inout GraphicsContext,
        shoulder: CGPoint,
        angle: Double,
        elbowBend: Double,
        unit: CGFloat,
        inkW: CGFloat,
        sleeve: Color,
        hand: Color
    ) {
        let upperLen = 6.8 * unit
        let lowerLen = 5.8 * unit
        let elbow = CGPoint(x: shoulder.x + sin(angle) * upperLen, y: shoulder.y + cos(angle) * upperLen)
        let lowerAngle = angle + elbowBend
        let wrist = CGPoint(x: elbow.x + sin(lowerAngle) * lowerLen, y: elbow.y + cos(lowerAngle) * lowerLen)

        let upperArm = limbCapsule(from: shoulder, to: elbow, radius: 2.55 * unit)
        let foreArm = limbCapsule(from: elbow, to: wrist, radius: 2.35 * unit)
        ctx.fill(foreArm, with: .color(sleeve))
        ctx.stroke(foreArm, with: .color(inkColor), lineWidth: inkW * 0.85)
        ctx.fill(upperArm, with: .color(sleeve))
        ctx.stroke(upperArm, with: .color(inkColor), lineWidth: inkW * 0.9)

        // Iconic Yellow C-Shaped LEGO Claw Hand!
        var clawCtx = ctx
        clawCtx.translateBy(x: wrist.x, y: wrist.y)
        clawCtx.rotate(by: Angle(radians: -lowerAngle))
        let clawR = 3.1 * unit
        var clawPath = Path()
        clawPath.addArc(
            center: CGPoint(x: 0, y: 1.6 * unit),
            radius: clawR,
            startAngle: .degrees(-48),
            endAngle: .degrees(228),
            clockwise: false
        )
        clawCtx.stroke(clawPath, with: .color(inkColor), style: StrokeStyle(lineWidth: 2.7 * unit, lineCap: .round))
        clawCtx.stroke(clawPath, with: .color(hand), style: StrokeStyle(lineWidth: 1.65 * unit, lineCap: .round))
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
        p.addQuadCurve(to: CGPoint(x: b.x - nx * radius, y: b.y - ny * radius), control: CGPoint(x: b.x + (dx / len) * radius * 1.15, y: b.y + (dy / len) * radius * 1.15))
        p.addLine(to: CGPoint(x: a.x - nx * radius, y: a.y - ny * radius))
        p.addQuadCurve(to: CGPoint(x: a.x + nx * radius, y: a.y + ny * radius), control: CGPoint(x: a.x - (dx / len) * radius * 1.15, y: a.y - (dy / len) * radius * 1.15))
        p.closeSubpath()
        return p
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
        let style = LegoMinifigStyle.resolve(assetName: resolvedAsset, fallbackAccent: agent.accentHex)
        return ZStack {
            if agent.status.isBusy || agent.status == .chatting {
                PulseRingView(color: statusColor, size: size)
            } else if isSelected {
                Circle()
                    .stroke(accent.opacity(0.80), lineWidth: 2.0)
                    .frame(width: size + 6, height: size + 6)
                    .shadow(color: accent.opacity(0.45), radius: 5)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.36), Color(red: 0.08, green: 0.11, blue: 0.19).opacity(0.92)],
                        center: .topLeading,
                        startRadius: 1,
                        endRadius: size * 0.7
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    ArticulatedLegoMinifigCanvas(
                        style: style,
                        accent: accent,
                        status: agent.status,
                        statusColor: statusColor,
                        isWalking: false,
                        strideIntensity: 0,
                        isSelected: isSelected,
                        facingLeft: false,
                        phaseOffset: 0,
                        reduceMotion: true,
                        bustOnly: true
                    )
                    .frame(width: size * 0.94, height: size * 0.94)
                    .clipShape(Circle())
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.85 : 0.48), lineWidth: 1.4))
                .shadow(color: accent.opacity(0.38), radius: 5, y: 2)

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
        let style = LegoMinifigStyle.resolve(assetName: resolvedAsset, fallbackAccent: agent.accentHex)
        let phaseOffset = Double(abs(agent.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % 100) * 0.07

        return ZStack(alignment: .topTrailing) {
            ArticulatedLegoMinifigCanvas(
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
            .frame(width: max(62, size * 0.86), height: size + 12)

            if showStatusDot {
                Circle()
                    .fill(isWalking ? Color.cyan : statusColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: (isWalking ? Color.cyan : statusColor).opacity(0.85), radius: 3)
                    .offset(x: -8, y: 8)
            }
        }
        .frame(width: max(62, size * 0.86), height: size + 12)
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

typealias BikiniAvatarPickerStrip = LegoAvatarPickerStrip

struct LegoAvatarPickerStrip: View {
    @Binding var selectedAsset: String
    var accentHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LEGO Minifigür Karakter Stili (10 Özgün Figür)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(OfficeAvatarPreset.allPresets) { preset in
                        let isSel = selectedAsset == preset.assetName
                        let style = LegoMinifigStyle.resolve(assetName: preset.assetName, fallbackAccent: preset.accentHex)
                        Button {
                            selectedAsset = preset.assetName
                        } label: {
                            VStack(spacing: 4) {
                                ArticulatedLegoMinifigCanvas(
                                    style: style,
                                    accent: Color(hex: preset.accentHex),
                                    status: .idle,
                                    statusColor: .green,
                                    isWalking: false,
                                    strideIntensity: 0,
                                    isSelected: isSel,
                                    facingLeft: false,
                                    phaseOffset: 0,
                                    reduceMotion: true
                                )
                                .frame(width: 50, height: 62)

                                Text(preset.label.components(separatedBy: " · ").last ?? preset.label)
                                    .font(.system(size: 8.5, weight: isSel ? .bold : .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .frame(width: 82)
                            .liquidGlassCard(
                                cornerRadius: 12,
                                tint: isSel ? Color(hex: accentHex) : nil,
                                interactive: true
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
