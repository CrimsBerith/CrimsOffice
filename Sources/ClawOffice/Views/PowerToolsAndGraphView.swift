import SwiftUI
import AppKit

struct PowerToolsAndGraphView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var cliOutput: String = ""
    @State private var isRunningCLI: Bool = false
    @State private var graphQuery: String = ""

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .cyan)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        GlassSectionHeader(
                            title: "Power Stack — RTK AI · Caveman · Graphify",
                            subtitle: "Token maliyetini %60-90 azaltan araçları tek tıkla kurun, projeyi bilgi grafına dönüştürün ve ajanlara bağlayın.",
                            systemImage: "bolt.shield.fill",
                            tint: .cyan
                        )
                        Spacer()
                        Button { pickWorkspaceFolder() } label: {
                            Label("Proje Klasörü Seç", systemImage: "folder.badge.gearshape")
                        }
                        .liquidGlassButton(prominent: true, tint: .cyan)
                    }

                    Text("Aktif Proje Klasörü: \(engine.workspacePath)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .liquidGlassCapsule(interactive: false)

                    HStack(alignment: .top, spacing: 16) {
                        cavemanCard
                        rtkCard
                    }

                    graphifyStudioCard

                    if !cliOutput.isEmpty || isRunningCLI {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Araç Konsol Çıktısı", systemImage: "terminal").font(.headline)
                                if isRunningCLI { ProgressView().controlSize(.small) }
                                Spacer()
                                Button("Temizle") { cliOutput = "" }.buttonStyle(.borderless)
                            }
                            SmokedGlassSurface(cornerRadius: 12) {
                                ScrollView {
                                    Text(cliOutput.isEmpty ? "Çalıştırılıyor..." : cliOutput)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                }
                                .frame(height: 155)
                                .foregroundStyle(Color(red: 0.48, green: 0.94, blue: 0.60))
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 18)
                    }
                }
                .padding(22)
            }
        }
    }

    private var cavemanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.shield.fill").foregroundStyle(.purple).font(.title3)
                Text("Caveman Modu").font(.headline)
                Spacer()
                Text(engine.cavemanMode.rawValue)
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .liquidGlassCapsule(tint: .purple, interactive: false)
            }
            Text("Kullanıcı promptuna dokunmadan ajan çıktısını %35-80 kısaltır; kod, araç etiketleri, yollar ve olumsuzluklar (değil/not) birebir korunur.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Seviye", selection: Binding(
                get: { engine.cavemanMode },
                set: { engine.cavemanMode = $0; engine.saveConfig() }
            )) {
                ForEach(CavemanMode.allCases) { m in Text(m.rawValue).tag(m) }
            }.pickerStyle(.segmented)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18, tint: .purple)
    }

    private var rtkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "flame.fill").foregroundStyle(.orange).font(.title3)
                Text("RTK AI (Rust Token Killer)").font(.headline)
                Spacer()
                Text(engine.cliStatus.rtkInstalled ? "Kurulu" : "Kurulu Değil")
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .liquidGlassCapsule(tint: engine.cliStatus.rtkInstalled ? .green : .orange, interactive: false)
            }
            Text("`git`, `ls`, `swift`, `cargo`, `npm`, `pytest` çıktılarını filtreleyerek %60-90 giriş tokenı tasarrufu sağlar.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Yerel Terminal Araçlarını RTK Proxy ile Sar", isOn: Binding(
                get: { engine.enableRTKProxy },
                set: { engine.enableRTKProxy = $0; engine.saveConfig() }
            )).font(.callout)

            HStack(spacing: 8) {
                if !engine.cliStatus.rtkInstalled {
                    Button("Homebrew ile Kur") { runCLI("brew install rtk") }
                        .liquidGlassButton(prominent: true, tint: .orange).disabled(isRunningCLI)
                } else {
                    Button("Tasarruf Raporu (rtk gain)") { runCLI("rtk gain") }
                        .liquidGlassButton(prominent: false).disabled(isRunningCLI)
                }
                Button("Yenile") { Task { await engine.refreshCLITools() } }
                    .liquidGlassButton(prominent: false)
            }
            if !engine.rtkGainSummary.isEmpty {
                Text(engine.rtkGainSummary).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 18, tint: .orange)
    }

    private var graphifyStudioCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.cyan).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Graphify Bilgi Grafı Stüdyosu").font(.headline)
                    Text("Projeyi `graphify-out/GRAPH_REPORT.md` + `graph.json` bilgi grafına çevirir; ajanlar dev kod tabanlarını çok az tokenla anlar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(engine.cliStatus.graphifyInstalled ? "CLI Hazır" : "Kurulmadı")
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .liquidGlassCapsule(tint: engine.cliStatus.graphifyInstalled ? .green : .orange, interactive: false)
            }

            Toggle("GRAPH_REPORT.md Özetini Ajan Bağlamına Otomatik Enjekte Et", isOn: Binding(
                get: { engine.injectGraphifyReport },
                set: { engine.injectGraphifyReport = $0; engine.saveConfig() }
            ))

            LiquidGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !engine.cliStatus.graphifyInstalled {
                        Button("Graphify Kur") {
                            let cmd = engine.cliStatus.uvInstalled ? "uv tool install \"graphifyy[mcp]\"" : "pip3 install \"graphifyy[mcp]\""
                            runCLI(cmd)
                        }.liquidGlassButton(prominent: true, tint: .cyan).disabled(isRunningCLI)
                    }
                    Button("Projeyi Graphify Et") { runCLI("graphify update . --force") }
                        .liquidGlassButton(prominent: true, tint: .cyan).disabled(isRunningCLI)
                    Button("Artımlı Güncelle") { runCLI("graphify update .") }
                        .liquidGlassButton(prominent: false).disabled(isRunningCLI)
                    Button("OpenClaw'a Bağla") { runCLI("graphify claw install") }
                        .liquidGlassButton(prominent: false).disabled(isRunningCLI)
                }
            }

            HStack(spacing: 8) {
                TextField("Grafı sorgula (örn: 'kim LLMClient çağırıyor?')...", text: $graphQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitGraphQuery() }
                Button("Sorgula") {
                    submitGraphQuery()
                }
                .liquidGlassButton(prominent: false)
                .disabled(graphQuery.trimmingCharacters(in: .whitespaces).isEmpty || isRunningCLI)
            }

            if let snap = engine.graphSnapshot {
                HStack(alignment: .top, spacing: 14) {
                    SmokedGlassSurface(cornerRadius: 14) {
                        GraphCanvasView(nodes: snap.nodes, edges: snap.edges)
                            .frame(height: 230).frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Çekirdek Düğümler (God Nodes)").font(.caption.bold())
                        Text("\(snap.nodes.count) düğüm · \(snap.edges.count) bağlantı").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        Divider()
                        ForEach(snap.godNodes.prefix(6)) { n in
                            HStack {
                                Circle().fill(Color.cyan).frame(width: 6, height: 6)
                                Text(n.label).font(.caption).lineLimit(1)
                                Spacer()
                                Text("\(n.degree)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(12).frame(width: 220, height: 230)
                    .liquidGlassCard(cornerRadius: 14, tint: .cyan)
                }
            } else {
                Text("Henüz graf verisi yok. Projeyi bilgi grafına dönüştürmek için \"Projeyi Graphify Et\" butonunu kullanın.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 18, tint: .cyan)
    }

    private func submitGraphQuery() {
        let trimmed = graphQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunningCLI else { return }
        let escaped = PowerShellTools.shellSingleQuoted(trimmed)
        runCLI("graphify query \(escaped)")
    }

    private func pickWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.setWorkspacePath(url.path)
        }
    }

    private func runCLI(_ cmd: String) {
        guard !isRunningCLI else { return }
        isRunningCLI = true
        cliOutput = "$ \(cmd)\n..."
        Task { @MainActor in
            let res = await PowerShellTools.runCommand(cmd, workspacePath: engine.workspacePath, wrapWithRTK: false)
            cliOutput = "$ \(res.commandUsed)\n\n\(res.output)"
            isRunningCLI = false
            engine.refreshWorkspaceAndSkills()
            await engine.refreshCLITools()
        }
    }
}

struct GraphCanvasView: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    private let palette: [Color] = [.cyan, .purple, .green, .orange, .pink, .blue, .yellow]

    @State private var selectedNodeId: String? = nil
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragBaseOffset: CGSize = .zero

    private var subsetNodes: [GraphNode] {
        Array(nodes.sorted { $0.degree > $1.degree }.prefix(48))
    }

    private func computeCoords(for size: CGSize, subset: [GraphNode]) -> [String: CGPoint] {
        let cx = size.width / 2 + panOffset.width
        let cy = size.height / 2 + panOffset.height
        let rx = max(60, size.width * 0.40) * zoomScale
        let ry = max(50, size.height * 0.38) * zoomScale
        var coords: [String: CGPoint] = [:]
        for (idx, node) in subset.enumerated() {
            let angle = (Double(idx) / Double(max(1, subset.count))) * Double.pi * 2.0
            let ring = node.degree > 4 ? 0.55 : 0.95
            coords[node.id] = CGPoint(x: cx + cos(angle) * rx * ring, y: cy + sin(angle) * ry * ring)
        }
        return coords
    }

    var body: some View {
        GeometryReader { geo in
            let subset = subsetNodes
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    guard !subset.isEmpty else { return }
                    let coords = computeCoords(for: size, subset: subset)
                    for e in edges {
                        guard let a = coords[e.source], let b = coords[e.target] else { continue }
                        let highlighted = selectedNodeId != nil && (e.source == selectedNodeId || e.target == selectedNodeId)
                        var p = Path(); p.move(to: a); p.addLine(to: b)
                        ctx.stroke(
                            p,
                            with: .color(highlighted ? Color.white.opacity(0.85) : Color.cyan.opacity(0.24)),
                            lineWidth: highlighted ? 1.8 : 1.0
                        )
                    }
                    for node in subset {
                        guard let pt = coords[node.id] else { continue }
                        let isSelected = selectedNodeId == node.id
                        let r = CGFloat(min(11, max(4, 4 + node.degree))) * (isSelected ? 1.25 : 1.0)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                            with: .color(palette[abs(node.community) % palette.count])
                        )
                        if isSelected {
                            ctx.stroke(
                                Path(ellipseIn: CGRect(x: pt.x - r - 2, y: pt.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)),
                                with: .color(.white),
                                lineWidth: 1.5
                            )
                        }
                        if isSelected || node.degree >= 3 || subset.count <= 16 {
                            let labelText = Text(String(node.label.prefix(18)))
                                .font(.system(size: 8.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(isSelected ? 1.0 : 0.90))
                            ctx.draw(labelText, at: CGPoint(x: pt.x, y: pt.y + r + 8))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if abs(value.translation.width) > 4 || abs(value.translation.height) > 4 {
                                panOffset = CGSize(
                                    width: dragBaseOffset.width + value.translation.width,
                                    height: dragBaseOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { value in
                            if abs(value.translation.width) <= 4 && abs(value.translation.height) <= 4 {
                                let coords = computeCoords(for: geo.size, subset: subset)
                                var bestId: String? = nil
                                var bestDist: CGFloat = 20
                                for node in subset {
                                    guard let pt = coords[node.id] else { continue }
                                    let d = hypot(pt.x - value.location.x, pt.y - value.location.y)
                                    if d < bestDist {
                                        bestDist = d
                                        bestId = node.id
                                    }
                                }
                                selectedNodeId = (selectedNodeId == bestId) ? nil : bestId
                            } else {
                                dragBaseOffset = panOffset
                            }
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            zoomScale = min(2.2, max(0.6, scale))
                        }
                )

                HStack(spacing: 6) {
                    if let sid = selectedNodeId, let node = subset.first(where: { $0.id == sid }) {
                        Text("\(node.label) · \(node.degree) bağ\(node.filePath.isEmpty ? "" : " · \(URL(fileURLWithPath: node.filePath).lastPathComponent)")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.black.opacity(0.65), in: Capsule())
                    }
                    Spacer()
                    Button { zoomScale = max(0.6, zoomScale - 0.2) } label: {
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("Grafiği uzaklaştır")
                    .help("Grafiği uzaklaştır")
                    Button { zoomScale = 1.0; panOffset = .zero; dragBaseOffset = .zero } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("Grafiği sıfırla")
                    .help("Yakınlaştırma ve konumu sıfırla")
                    Button { zoomScale = min(2.2, zoomScale + 0.2) } label: {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("Grafiği yakınlaştır")
                    .help("Grafiği yakınlaştır")
                }
                .padding(8)
            }
        }
    }
}
