import SwiftUI

struct OfficeFloorView: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.colorScheme) private var colorScheme
    @State private var quickPrompt = ""
    @State private var showInspector = true
    @State private var planExpanded = true
    @State private var showDialogueFeed = true
    @State private var dialogueExpanded = true
    @State private var pendingSystemAction: PendingSystemAction? = nil
    @State private var isRebuilding = false
    @State private var showWorkspacePopover = false
    @State private var showEditsPopover = false
    @State private var selectedEditForDiff: FileEditRecord? = nil
    @State private var workspaceVerifyStatus: String = ""
    @State private var isRunningQuickVerify = false
    @State private var walkDestinationMarker: (point: CGPoint, accentHex: String, id: UUID)? = nil

    private enum PendingSystemAction: Identifiable {
        case selfRebuild
        case restartApp

        var id: String {
            switch self {
            case .selfRebuild: return "selfRebuild"
            case .restartApp: return "restartApp"
            }
        }
    }

    private var selfRepoPath: String {
        let fm = FileManager.default
        let candidates = [
            engine.workspacePath,
            AppConfig.detectDefaultWorkspacePath(),
            fm.currentDirectoryPath,
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path,
            "/Volumes/DATA/Builds/ClawOffice"
        ]
        for path in candidates where !path.isEmpty {
            if fm.fileExists(atPath: path + "/build_app.sh") {
                return path
            }
        }
        return AppConfig.detectDefaultWorkspacePath()
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                topHUD
                Divider()
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        backgroundLayer(size: geo.size)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                walkSelectedAgent(toScreenPoint: location, in: geo.size)
                            }
                        zonesLayer(size: geo.size)
                        desksLayer(size: geo.size)
                        walkTrailsLayer(size: geo.size)
                        if let marker = walkDestinationMarker {
                            FloorWalkMarkerView(accent: Color(hex: marker.accentHex))
                                .id(marker.id)
                                .position(marker.point)
                                .allowsHitTesting(false)
                        }
                        beamsLayer(size: geo.size)
                        flyingPacketsLayer(size: geo.size)
                        agentsLayer(size: geo.size)

                        // Sağ üstte yüzen cam Aktif Görev Planı kartı (tam geo.size içine sabitlenmiş)
                        if !engine.planTasks.isEmpty {
                            VStack {
                                HStack {
                                    Spacer()
                                    planBoardOverlay
                                        .padding(2)
                                        .frame(width: min(258, max(200, geo.size.width * 0.34)))
                                        .background(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .fill(Color(red: 0.07, green: 0.10, blue: 0.16).opacity(colorScheme == .dark ? 0.78 : 0.45))
                                        )
                                        .liquidGlassCard(cornerRadius: 16, tint: .blue, interactive: true)
                                        .shadow(color: Color.black.opacity(0.35), radius: 14, y: 5)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .zIndex(20_000)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                if showDialogueFeed {
                    Divider()
                    dialogueFeedOverlay
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlassBar(tint: .teal)
                }
                Divider()
                quickBar
            }
            .frame(minWidth: 520, idealWidth: 680)

            if showInspector {
                AgentInspectorView()
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    ForEach(CavemanMode.allCases) { m in
                        Button {
                            engine.cavemanMode = m
                            engine.saveConfig()
                        } label: {
                            HStack {
                                Text(m.rawValue)
                                if engine.cavemanMode == m { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label("Caveman: \(engine.cavemanMode.rawValue)", systemImage: "bolt.shield.fill")
                }

                Menu {
                    Button {
                        pendingSystemAction = .restartApp
                    } label: {
                        Label("Yeniden Başlat (Restart)", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRebuilding || engine.isRunningPipeline)

                    Divider()
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: engine.workspacePath)
                    } label: {
                        Label("Çalışma Klasörünü Finder'da Aç", systemImage: "folder")
                    }
                } label: {
                    Label("Mac & Sistem", systemImage: "macbook.and.iphone")
                }

                Button { engine.recallAllAgentsToDesks() } label: {
                    Label("Masalara Çağır", systemImage: "arrow.uturn.backward.circle")
                }

                Button { withAnimation { showInspector.toggle() } } label: {
                    Label("Panel", systemImage: "sidebar.right")
                }
            }
        }
        .confirmationDialog(
            pendingSystemAction == .selfRebuild
                ? "Crims Office Kendini Derlesin ve Yeniden Başlatsın mı?"
                : "Crims Office Yeniden Başlatılsın mı?",
            isPresented: Binding(
                get: { pendingSystemAction != nil },
                set: { if !$0 { pendingSystemAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if pendingSystemAction == .selfRebuild {
                Button("Derle ve Yeniden Başlat", role: .destructive) {
                    guard !isRebuilding else { return }
                    isRebuilding = true
                    Task { @MainActor in
                        _ = await engine.selfRebuildAndRestart(reason: "Araç çubuğundan onaylandı")
                        isRebuilding = false
                    }
                }
            } else if pendingSystemAction == .restartApp {
                Button("Yeniden Başlat", role: .destructive) {
                    engine.restartApp(reason: "Araç çubuğundan onaylandı")
                }
            }
            Button("İptal", role: .cancel) {
                pendingSystemAction = nil
            }
        }
    }

    private var topHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Satır 1: Stüdyo durumu + Workspace + Kod Yazma / Build Gate / Düzenlemeler / Git + Sağlayıcılar
            ScrollView(.horizontal, showsIndicators: false) {
                LiquidGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            CrimsBrandLogoView(size: 15)
                            Circle()
                                .fill(engine.activeBusyCount > 0 ? Color.green : Color(hex: "#E11D48"))
                                .frame(width: 7, height: 7)
                                .shadow(color: (engine.activeBusyCount > 0 ? Color.green : Color(hex: "#E11D48")).opacity(0.7), radius: 4)
                            Text(engine.isRunningPipeline ? engine.pipelineStatusText : (engine.activeBusyCount > 0 ? "\(engine.activeBusyCount) Ajan Aktif" : "Crims Studio"))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4.5)
                        .liquidGlassCapsule(tint: engine.activeBusyCount > 0 ? .green : Color(hex: "#E11D48"), interactive: false)

                        Button {
                            showWorkspacePopover.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.cyan)
                                Text("/\(URL(fileURLWithPath: engine.workspacePath).lastPathComponent)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: .blue, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("Aktif proje klasörü: \(engine.workspacePath) (Değiştir / Build & Test)")
                        .popover(isPresented: $showWorkspacePopover, arrowEdge: .bottom) {
                            workspacePopoverContent
                        }

                        Button {
                            engine.allowFileWrites.toggle()
                            engine.saveConfig()
                        } label: {
                            statusPill("Kod Yazma", active: engine.allowFileWrites, color: .green)
                        }
                        .buttonStyle(.plain)
                        .help("Ajanların dosya yazma/yamalama yetkisini aç/kapat")

                        Button {
                            engine.autoVerifyBuild.toggle()
                            engine.saveConfig()
                        } label: {
                            statusPill("Build Gate", active: engine.autoVerifyBuild, color: .green)
                        }
                        .buttonStyle(.plain)
                        .help("Kod düzenlemesi sonrası otomatik derleme/test doğrulamasını aç/kapat")

                        if !engine.fileEdits.isEmpty {
                            let activeEditCount = engine.fileEdits.filter { !$0.rolledBack }.count
                            Button {
                                if selectedEditForDiff == nil { selectedEditForDiff = engine.fileEdits.first }
                                showEditsPopover.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                                    Text("\(activeEditCount) Düzenleme")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4.5)
                                .liquidGlassCapsule(tint: .orange, interactive: true)
                            }
                            .buttonStyle(.plain)
                            .help("Ajanların yaptığı kod düzenlemelerini, diff ve geri alma (rollback) seçeneklerini incele")
                            .popover(isPresented: $showEditsPopover, arrowEdge: .bottom) {
                                editsRollbackPopoverContent
                            }
                        }

                        if let git = engine.gitBranchSummary {
                            statusPill("\(git.branch)\(git.dirtyCount > 0 ? " (\(git.dirtyCount))" : "")", active: true, color: git.dirtyCount > 0 ? .yellow : .mint)
                        }

                        ForEach(engine.providers) { p in
                            let health = engine.providerStatuses[p.id]
                            let tintCol: Color = health != nil ? (health!.isOnline ? .green : .red) : (p.isConfigured ? .blue : .gray)
                            Button {
                                engine.checkProvidersHealth()
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(tintCol)
                                        .frame(width: 6.5, height: 6.5)
                                    Text(p.name).font(.system(size: 10, weight: .medium))
                                    if let h = health, h.isOnline && h.latencyMs > 0 {
                                        Text("\(h.latencyMs)ms")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4.5)
                                .liquidGlassCapsule(tint: tintCol, interactive: true)
                            }
                            .buttonStyle(.plain)
                            .help("Sağlık kontrolü: \(health?.statusMessage ?? "Tıkla ve test et")")
                        }
                    }
                }
            }

            // Satır 2: OpenClaw WS + Ekip Sohbeti + Sahil Stüdyo + Yürüt + Masalara + Sistem Durumu
            ScrollView(.horizontal, showsIndicators: false) {
                LiquidGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            engine.requestedSectionRawValue = AppSection.openClawHub.rawValue
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(engine.openClawGatewaySnap.gatewayOnline ? Color.green : (engine.openClawGatewaySnap.cliInstalled ? Color.orange : Color.gray))
                                    .frame(width: 6, height: 6)
                                Text(engine.openClawGatewaySnap.gatewayOnline ? "OpenClaw WS" : "OpenClaw Hub")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: engine.openClawGatewaySnap.gatewayOnline ? .teal : .indigo, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("OpenClaw Gateway, Kanallar, Cron ve Maliyet/Güvenlik Panosu")

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showDialogueFeed.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(showDialogueFeed ? .cyan : .secondary)
                                Text("Ekip Sohbeti (\(engine.officeDialogues.count))")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: showDialogueFeed ? .teal : nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("Ajanların birbirleriyle konuşma akışını göster/gizle")

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                engine.useIllustratedFloorBackdrop.toggle()
                                engine.saveConfig()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: engine.useIllustratedFloorBackdrop ? "sun.max.fill" : "square.grid.2x2")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(engine.useIllustratedFloorBackdrop ? .cyan : .secondary)
                                Text(engine.useIllustratedFloorBackdrop ? "Sahil Stüdyo" : "Minimal Cam")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: engine.useIllustratedFloorBackdrop ? .cyan : nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("İzometrik Sahil Stüdyosu zeminini aç/kapat")

                        Button {
                            engine.tickAmbientOffice(forceStroll: true)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.cyan)
                                Text("Yürüt")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: .blue, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("Stüdyoda canlı yürüyüş başlat (Zeminde herhangi bir noktaya da tıklayabilirsiniz)")

                        Button {
                            engine.recallAllAgentsToDesks()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.left.circle.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                Text("Masalara")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .help("Tüm ekibi kendi çalışma masasına geri yürüt")

                        HStack(spacing: 4) {
                            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                                .foregroundStyle(.blue)
                                .font(.system(size: 9.5))
                            Text(engine.lastFailoverNotice.isEmpty ? "Devralma: Aktif\(engine.failoverEventCount > 0 ? " (\(engine.failoverEventCount))" : "")" : "🔄 \(engine.lastFailoverNotice)")
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4.5)
                        .liquidGlassCapsule(tint: engine.lastFailoverNotice.isEmpty ? .blue : .orange, interactive: false)
                        .help("Model dolu, kotada veya zaman aşımında sıradaki model/sağlayıcı görevi otomatik devralır.")

                        if engine.cavemanMode != .off {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.shield.fill").foregroundStyle(.yellow).font(.system(size: 9.5))
                                Text("Caveman \(engine.cavemanMode.rawValue)")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4.5)
                            .liquidGlassCapsule(tint: .yellow, interactive: false)
                        }

                        statusPill("RTK Proxy", active: engine.cliStatus.rtkInstalled && engine.enableRTKProxy, color: .orange)
                        statusPill("Graphify AI", active: engine.graphSnapshot != nil, color: .cyan)

                        if engine.totalToolCallsExecuted > 0 {
                            statusPill("\(engine.totalToolCallsExecuted) Araç", active: true, color: .indigo)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .liquidGlassBar()
    }

    private var workspacePopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Aktif Proje Çalışma Alanı", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                if let git = engine.gitBranchSummary {
                    Text("\(git.branch) · \(git.dirtyCount) değişiklik")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .liquidGlassCapsule(tint: git.dirtyCount > 0 ? .orange : .mint, interactive: false)
                }
            }
            Text(engine.workspacePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            let detectedBuild = PowerShellTools.detectBuildCommand(workspacePath: engine.workspacePath, customOverride: engine.customBuildCommand)
            let detectedTest = PowerShellTools.detectTestCommand(workspacePath: engine.workspacePath, customOverride: "")
            if detectedBuild != nil || detectedTest != nil {
                Text("Algılanan komutlar: \(detectedBuild ?? "-")\(detectedTest.map { " · \($0)" } ?? "")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Klasör Seç...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: engine.workspacePath)
                    if panel.runModal() == .OK, let url = panel.url {
                        engine.setWorkspacePath(url.path)
                        workspaceVerifyStatus = "Yeni çalışma alanı: \(url.lastPathComponent)"
                    }
                }
                .liquidGlassButton(prominent: true, tint: .blue)
                .controlSize(.small)

                if let runCmd = detectedBuild ?? detectedTest {
                    Button {
                        guard !isRunningQuickVerify else { return }
                        isRunningQuickVerify = true
                        workspaceVerifyStatus = "⏳ `\(runCmd)` çalışıyor..."
                        let ws = engine.workspacePath
                        let useRTK = engine.enableRTKProxy
                        Task { @MainActor in
                            let res = await PowerShellTools.runCommand(runCmd, workspacePath: ws, wrapWithRTK: useRTK)
                            isRunningQuickVerify = false
                            workspaceVerifyStatus = (res.succeeded ? "✅ Başarılı: " : "⚠️ Hata: ") + String(res.output.prefix(240))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isRunningQuickVerify { ProgressView().controlSize(.mini) }
                            Text("Derle / Doğrula")
                        }
                    }
                    .liquidGlassButton(prominent: false)
                    .controlSize(.small)
                    .disabled(isRunningQuickVerify)
                }

                Button("Finder'da Aç") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: engine.workspacePath)
                }
                .liquidGlassButton(prominent: false)
                .controlSize(.small)
            }

            if !workspaceVerifyStatus.isEmpty {
                ScrollView {
                    Text(workspaceVerifyStatus)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private var editsRollbackPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ajan Kod Düzenlemeleri & Geri Alma", systemImage: "arrow.uturn.backward.square.fill")
                    .font(.headline)
                Spacer()
                Text("\(engine.fileEdits.count) kayıt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.fileEdits.prefix(25)) { rec in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.relativePath)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                                Text("\(rec.agentName) · \(rec.summary)")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if rec.rolledBack {
                                Text("Geri Alındı")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.orange)
                            } else {
                                if !rec.backupPath.isEmpty {
                                    Button("Diff") {
                                        selectedEditForDiff = rec
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10, weight: .semibold))
                                }
                                Button("Geri Al") {
                                    _ = engine.rollbackEdit(id: rec.id)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            (selectedEditForDiff?.id == rec.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
            }
            .frame(maxHeight: 165)

            if let diffRec = selectedEditForDiff, !diffRec.backupPath.isEmpty {
                let currentURL = PowerShellTools.resolveSafeURL(diffRec.relativePath, workspacePath: engine.workspacePath)
                let newText = currentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let oldText = (try? String(contentsOfFile: diffRec.backupPath, encoding: .utf8)) ?? ""
                let diffLines = LineDiffUtility.unifiedDiff(oldText: oldText, newText: newText, maxLines: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diff Önizleme: \(diffRec.relativePath)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(diffLines.joined(separator: "\n"))
                            .font(.system(size: 9.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .frame(width: 480)
    }

    private func statusPill(_ title: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(active ? color : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4.5)
        .liquidGlassCapsule(tint: active ? color : nil, interactive: false)
    }

    private func backgroundLayer(size: CGSize) -> some View {
        ZStack {
            AmbientGlassBackdrop(accent: Color(hex: engine.selectedAgent?.accentHex ?? "#06B6D4"))
            if engine.useIllustratedFloorBackdrop,
               let bgImg = AvatarImageLoader.nsImage(named: "office_studio_floor") {
                Image(nsImage: bgImg)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .opacity(colorScheme == .dark ? 0.94 : 0.98)
                    .overlay(
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(colorScheme == .dark ? 0.16 : 0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            } else {
                Canvas { ctx, canvasSize in
                    var p = Path()
                    var x: CGFloat = 0
                    while x <= canvasSize.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: canvasSize.height)); x += 36 }
                    var y: CGFloat = 0
                    while y <= canvasSize.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: canvasSize.width, y: y)); y += 36 }
                    ctx.stroke(p, with: .color(colorScheme == .dark ? .white.opacity(0.04) : .black.opacity(0.05)), lineWidth: 1)
                }
                .drawingGroup()
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func zonesLayer(size: CGSize) -> some View {
        ZStack {
            meetingRoomZone(size: size)
            coffeeZone(size: size)
            macStudioZone(size: size)
        }
    }

    private func meetingRoomZone(size: CGSize) -> some View {
        let isMeetingActive = engine.isRunningPipeline || engine.agents.contains(where: { $0.currentZone == .meetingRoom })
        let w = min(190, size.width * 0.25)
        let h = min(84, size.height * 0.15)

        return ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            (isMeetingActive ? Color.cyan : Color.blue).opacity(isMeetingActive ? 0.16 : 0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: w * 0.52
                    )
                )
            Ellipse()
                .stroke(
                    (isMeetingActive ? Color.cyan : Color.white).opacity(isMeetingActive ? 0.45 : 0.18),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 5])
                )

            VStack(spacing: 3) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isMeetingActive ? Color.cyan : .white.opacity(0.65))
                Text("TOPLANTI ALANI")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(isMeetingActive ? Color.cyan : .white.opacity(0.68))
                    .tracking(0.6)

                if engine.isRunningPipeline {
                    Text("CANLI OTURUM")
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.cyan, in: Capsule())
                        .shadow(color: Color.cyan.opacity(0.6), radius: 5)
                }
            }
        }
        .frame(width: w, height: h)
        .contentShape(Ellipse())
        .position(x: size.width * 0.50, y: size.height * 0.52)
        .onTapGesture {
            walkSelectedAgent(toNormalized: Point2D(x: 0.50, y: 0.52), in: size, zoneOverride: .meetingRoom, bubbleOverride: "📝 Toplantı alanına geçiyor")
        }
    }

    private func coffeeZone(size: CGSize) -> some View {
        let w = min(194, max(164, size.width * 0.30))
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.22)).frame(width: 30, height: 30)
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange).font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text("Kahve & Dinlenme").font(.system(size: 10.5, weight: .bold, design: .rounded)).lineLimit(1)
                Text("Mola & Beyin Fırtınası")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: w, height: 54)
        .liquidGlassCard(cornerRadius: 16, tint: .orange, interactive: true)
        .position(x: size.width * 0.20, y: max(40, size.height - 40))
        .onTapGesture {
            walkSelectedAgent(toNormalized: Point2D(x: 0.24, y: 0.78), in: size, zoneOverride: .coffeeLounge, bubbleOverride: "☕️ Kahve molasına yürüyor")
        }
    }

    private func macStudioZone(size: CGSize) -> some View {
        let w = min(204, max(168, size.width * 0.31))
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.22)).frame(width: 30, height: 30)
                Image(systemName: "macstudio.fill").foregroundStyle(.cyan).font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text("Mac Studio Hub").font(.system(size: 10.5, weight: .bold, design: .rounded)).lineLimit(1)
                Text("\(engine.configuredProviderCount) API · \(engine.fileEdits.count) Patch")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: w, height: 54)
        .liquidGlassCard(cornerRadius: 16, tint: .cyan, interactive: true)
        .position(x: size.width * 0.80, y: max(40, size.height - 40))
        .onTapGesture {
            walkSelectedAgent(toNormalized: Point2D(x: 0.76, y: 0.78), in: size, zoneOverride: .serverRack, bubbleOverride: "🖥️ Mac Hub kontrolüne gidiyor")
        }
    }

    private func walkSelectedAgent(toScreenPoint location: CGPoint, in size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        let norm = Point2D(
            x: min(0.88, max(0.10, Double(location.x / size.width))),
            y: min(0.84, max(0.15, Double(location.y / size.height)))
        )
        walkSelectedAgent(toNormalized: norm, in: size)
    }

    private func walkSelectedAgent(
        toNormalized norm: Point2D,
        in size: CGSize,
        zoneOverride: OfficeZone? = nil,
        bubbleOverride: String? = nil
    ) {
        guard let targetAgent = engine.selectedAgent ?? engine.agents.first else { return }
        let classified = OfficeEngine.classifyFloorZone(for: norm, deskPosition: targetAgent.deskPosition)
        let zone = zoneOverride ?? classified.zone
        let bubble = bubbleOverride ?? classified.bubble

        let markerId = UUID()
        let screenPt = floorPoint(for: norm, in: size)
        walkDestinationMarker = (point: screenPt, accentHex: targetAgent.accentHex, id: markerId)

        engine.moveAgent(
            targetAgent.id,
            to: norm,
            zone: zone,
            status: targetAgent.status.isBusy ? nil : (zone == .desk ? .idle : .chatting),
            bubble: bubble
        )

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            if walkDestinationMarker?.id == markerId {
                walkDestinationMarker = nil
            }
        }
    }

    private func floorPoint(for pos: Point2D, in size: CGSize) -> CGPoint {
        let padX = min(size.width * 0.45, 92)
        let padTop = min(size.height * 0.45, 72)
        let padBottom = min(size.height * 0.45, 68)
        let rawX = size.width * pos.x
        let rawY = size.height * pos.y
        return CGPoint(
            x: min(max(rawX, padX), max(padX, size.width - padX)),
            y: min(max(rawY, padTop), max(padTop, size.height - padBottom))
        )
    }

    private func desksLayer(size: CGSize) -> some View {
        ForEach(engine.agents) { agent in
            let pt = floorPoint(for: agent.deskPosition, in: size)
            let working = agent.status.isBusy && agent.currentZone == .desk
            let isSelected = engine.selectedAgentId == agent.id
            let accent = Color(hex: agent.accentHex)
            let isAtOwnDesk = agent.currentZone == .desk

            ZStack {
                IsometricGlassDeskView(
                    accent: accent,
                    working: working,
                    isSelected: isSelected,
                    isDark: colorScheme == .dark
                )

                // Empty-desk nameplate shown ONLY when the agent walks away
                if !isAtOwnDesk {
                    Text("\(agent.emoji) \(agent.name) Masası")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(Color(red: 0.08, green: 0.12, blue: 0.18).opacity(0.76), in: Capsule())
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 0.7))
                        .offset(x: -10, y: 14)
                }
            }
            .position(x: pt.x, y: pt.y + 4)
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    engine.selectedAgentId = agent.id
                }
            }
        }
    }

    // Subtle Curved Stroll Trails showing active walking paths on the studio floor
    private func walkTrailsLayer(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: engine.activeWalkMotions.isEmpty)) { timeline in
            let now = timeline.date
            Canvas { ctx, canvasSize in
                for (agentId, motion) in engine.activeWalkMotions {
                    guard let agent = engine.agents.first(where: { $0.id == agentId }) else { continue }
                    let currentSample = motion.sample(at: now)
                    guard currentSample.progress < 0.98 else { continue }

                    var path = Path()
                    let steps = 16
                    for s in 0...steps {
                        let frac = currentSample.progress + (1.0 - currentSample.progress) * (Double(s) / Double(steps))
                        let probeDate = motion.startedAt.addingTimeInterval(motion.duration * frac)
                        let pt = floorPoint(for: motion.sample(at: probeDate).point, in: canvasSize)
                        let groundPt = CGPoint(x: pt.x, y: pt.y + 24)
                        if s == 0 {
                            path.move(to: groundPt)
                        } else {
                            path.addLine(to: groundPt)
                        }
                    }

                    let col = Color(hex: agent.accentHex)
                    // Yumuşak neon hale + kesikli rota çizgisi
                    ctx.stroke(
                        path,
                        with: .color(col.opacity(0.20)),
                        style: StrokeStyle(lineWidth: 5.0, lineCap: .round)
                    )
                    ctx.stroke(
                        path,
                        with: .color(Color.cyan.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 1.9, lineCap: .round, dash: [3.5, 5.5])
                    )

                    let endPt = floorPoint(for: motion.to, in: canvasSize)
                    let haloRect = CGRect(x: endPt.x - 10, y: endPt.y + 19, width: 20, height: 10)
                    ctx.stroke(Path(ellipseIn: haloRect), with: .color(Color.cyan.opacity(0.55)), lineWidth: 1.2)
                    let dotRect = CGRect(x: endPt.x - 4.5, y: endPt.y + 21.5, width: 9, height: 5)
                    ctx.fill(Path(ellipseIn: dotRect), with: .color(col.opacity(0.75)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // Animated Inter-Agent Communication Beams
    private func beamsLayer(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: engine.activeBeams.isEmpty)) { timeline in
            let dashPhase = CGFloat(timeline.date.timeIntervalSinceReferenceDate * -26.0)
                .truncatingRemainder(dividingBy: 24.0)
            ZStack {
                Canvas { ctx, canvasSize in
                    for beam in engine.activeBeams {
                        guard engine.agents.contains(where: { $0.id == beam.fromAgentId }),
                              engine.agents.contains(where: { $0.id == beam.toAgentId }) else { continue }
                        let p1 = floorPoint(for: engine.visualPosition(for: beam.fromAgentId, at: timeline.date), in: canvasSize)
                        let p2 = floorPoint(for: engine.visualPosition(for: beam.toAgentId, at: timeline.date), in: canvasSize)
                        let a1 = CGPoint(x: p1.x, y: p1.y - 4)
                        let a2 = CGPoint(x: p2.x, y: p2.y - 4)
                        let mid = CGPoint(x: (a1.x + a2.x) / 2, y: min(a1.y, a2.y) - 36)

                        var path = Path()
                        path.move(to: a1)
                        path.addQuadCurve(to: a2, control: mid)

                        let col = Color(hex: beam.accentHex)
                        ctx.stroke(path, with: .color(col.opacity(0.24)), lineWidth: 7)
                        ctx.stroke(
                            path,
                            with: .color(col.opacity(0.95)),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [7, 5], dashPhase: dashPhase)
                        )
                    }
                }

                ForEach(engine.activeBeams) { beam in
                    if engine.agents.contains(where: { $0.id == beam.fromAgentId }),
                       engine.agents.contains(where: { $0.id == beam.toAgentId }) {
                        let p1 = floorPoint(for: engine.visualPosition(for: beam.fromAgentId, at: timeline.date), in: size)
                        let p2 = floorPoint(for: engine.visualPosition(for: beam.toAgentId, at: timeline.date), in: size)
                        let labelPt = CGPoint(x: (p1.x + p2.x) / 2, y: min(p1.y - 4, p2.y - 4) - 24)

                        Text(beam.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(hex: beam.accentHex), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: Color(hex: beam.accentHex).opacity(0.45), radius: 4)
                            .position(labelPt)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func flyingPacketsLayer(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: engine.flyingPackets.isEmpty)) { timeline in
            ZStack {
                ForEach(engine.flyingPackets) { pkt in
                    if engine.agents.contains(where: { $0.id == pkt.fromAgentId }),
                       engine.agents.contains(where: { $0.id == pkt.toAgentId }) {
                        let elapsed = max(0, timeline.date.timeIntervalSince(pkt.createdAt))
                        let t = CGFloat(min(1.0, elapsed / 2.2))
                        let raw0 = floorPoint(for: engine.visualPosition(for: pkt.fromAgentId, at: timeline.date), in: size)
                        let raw1 = floorPoint(for: engine.visualPosition(for: pkt.toAgentId, at: timeline.date), in: size)
                        let p0 = CGPoint(x: raw0.x, y: raw0.y - 14)
                        let p1 = CGPoint(x: raw1.x, y: raw1.y - 14)
                        let ctrl = CGPoint(x: (p0.x + p1.x) / 2, y: min(p0.y, p1.y) - 48)
                        let mt = 1.0 - t
                        let curX = mt * mt * p0.x + 2 * mt * t * ctrl.x + t * t * p1.x
                        let curY = mt * mt * p0.y + 2 * mt * t * ctrl.y + t * t * p1.y
                        let opacity = t < 0.85 ? 1.0 : max(0.0, (1.0 - t) / 0.15)

                        HStack(spacing: 4) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(String(pkt.label.prefix(16)))
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color(hex: pkt.accentHex), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.65), lineWidth: 1))
                        .shadow(color: Color(hex: pkt.accentHex).opacity(0.75), radius: 7)
                        .opacity(opacity)
                        .position(x: curX, y: curY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func agentsLayer(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: engine.activeWalkMotions.isEmpty)) { timeline in
            let now = timeline.date
            ZStack(alignment: .topLeading) {
                ForEach(engine.agents) { agent in
                    let livePos = engine.visualPosition(for: agent.id, at: now)
                    let pt = floorPoint(for: livePos, in: size)
                    let isSelected = engine.selectedAgentId == agent.id
                    let isWalking = engine.walkingAgentIds.contains(agent.id)
                    let strideAmp = engine.strideIntensity(for: agent.id, at: now)
                    let facingLeft = engine.agentFacingLeft[agent.id] ?? false
                    let provName = engine.provider(for: agent.providerId)?.name ?? "API"
                    let cleanBubble = agent.statusBubble.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 60 FPS canlı perspektif: yürüdükçe yakınlaşıp büyür, uzaklaşıp küçülür
                    let depthScale = CGFloat(0.90 + min(max(livePos.y, 0.0), 1.0) * 0.16)
                    let spriteHeight = (isSelected ? 78.0 : 68.0) * depthScale

                    VStack(spacing: 2) {
                        if !cleanBubble.isEmpty {
                            let activeTalk = agent.status.isBusy || agent.status == .chatting || isWalking
                            Text(cleanBubble)
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.95) : Color.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 176)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(red: 0.08, green: 0.11, blue: 0.17).opacity(colorScheme == .dark ? 0.72 : 0.14))
                                )
                                .liquidGlassCard(
                                    cornerRadius: 10,
                                    tint: activeTalk ? Color(hex: agent.accentHex) : nil,
                                    interactive: false
                                )
                        }

                        AgentAvatarView(
                            agent: agent,
                            size: spriteHeight,
                            showStatusDot: true,
                            isSelected: isSelected,
                            isWalking: isWalking,
                            strideIntensity: strideAmp,
                            facingLeft: facingLeft,
                            mode: .floorSprite
                        )

                        VStack(spacing: 1) {
                            HStack(spacing: 3) {
                                Text("\(agent.emoji) \(agent.name)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(agent.title)
                                    .font(.system(size: 7.5, weight: .medium))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color(hex: agent.accentHex).opacity(0.28), in: Capsule())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 68)
                            }
                            .frame(maxWidth: 140)
                            Text("\(provName) · \(agent.modelId)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.68) : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 138)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.08, green: 0.11, blue: 0.17).opacity(colorScheme == .dark ? 0.74 : 0.14))
                        )
                        .liquidGlassCard(cornerRadius: 8, tint: isSelected ? Color(hex: agent.accentHex) : nil, interactive: true)
                    }
                    .position(x: pt.x, y: pt.y - 6)
                    .onTapGesture(count: 2) {
                        engine.selectedAgentId = agent.id
                        engine.moveAgent(
                            agent.id,
                            to: agent.deskPosition,
                            zone: .desk,
                            status: agent.status.isBusy ? nil : .idle,
                            bubble: "🚶‍♀️ Masasına dönüyor"
                        )
                    }
                    .onTapGesture(count: 1) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            engine.selectedAgentId = agent.id
                        }
                    }
                    .contextMenu {
                        Button("Masasına Yürüt") {
                            engine.selectedAgentId = agent.id
                            engine.moveAgent(agent.id, to: agent.deskPosition, zone: .desk, status: agent.status.isBusy ? nil : .idle, bubble: "🚶‍♀️ Masasına dönüyor")
                        }
                        Button("Kahve Molasına Gönder") {
                            engine.selectedAgentId = agent.id
                            engine.moveAgent(agent.id, to: Point2D(x: 0.24, y: 0.78), zone: .coffeeLounge, status: agent.status.isBusy ? nil : .chatting, bubble: "☕️ Kahve molası")
                        }
                        Button("Toplantı Odasına Gönder") {
                            engine.selectedAgentId = agent.id
                            engine.moveAgent(agent.id, to: Point2D(x: 0.50, y: 0.50), zone: .meetingRoom, status: agent.status.isBusy ? nil : .chatting, bubble: "📝 Toplantı odasına geçiyor")
                        }
                        Button("Mac Studio Hub'a Gönder") {
                            engine.selectedAgentId = agent.id
                            engine.moveAgent(agent.id, to: Point2D(x: 0.76, y: 0.78), zone: .serverRack, status: agent.status.isBusy ? nil : .chatting, bubble: "🖥️ Mac Hub kontrolü")
                        }
                        Divider()
                        Menu("Karakter Stilini Değiştir") {
                            ForEach(OfficeAvatarPreset.allPresets) { preset in
                                Button {
                                    var updated = agent
                                    updated.avatarAsset = preset.assetName
                                    updated.accentHex = preset.accentHex
                                    engine.updateAgent(updated)
                                } label: {
                                    HStack {
                                        Text(preset.label)
                                        if OfficeAvatarPreset.resolvedAsset(for: agent) == preset.assetName {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Sohbet Geçmişini Temizle") {
                            engine.clearHistory(for: agent.id)
                        }
                    }
                    .zIndex(isSelected ? 10_000 : Double(pt.y))
                }
            }
        }
    }

    private var quickBar: some View {
        HStack(spacing: 10) {
            if let a = engine.selectedAgent {
                Menu {
                    Section("Aktif Ajanı Seç") {
                        ForEach(engine.agents) { ag in
                            Button {
                                engine.selectedAgentId = ag.id
                            } label: {
                                HStack {
                                    Text("\(ag.emoji) \(ag.name) (\(ag.modelId))")
                                    if ag.id == a.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    if let prov = engine.provider(for: a.providerId), !prov.uniqueModels.isEmpty {
                        Section("\(a.name) Modelini Değiştir") {
                            ForEach(prov.uniqueModels.prefix(25), id: \.self) { m in
                                Button {
                                    var u = a
                                    u.modelId = m
                                    engine.updateAgent(u)
                                } label: {
                                    HStack {
                                        Text(m)
                                        if a.modelId == m { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(a.emoji).font(.system(size: 14))
                        Text(a.name)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .liquidGlassCapsule(tint: Color(hex: a.accentHex), interactive: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .layoutPriority(2)
            }

            let activeAgent = engine.selectedAgent
            GlassChatInputBar(
                text: $quickPrompt,
                placeholder: "Buraya yaz, ajanlar gerekeni yapsın... (↵ Gönder)",
                isBusy: activeAgent?.status.isBusy ?? false,
                accent: activeAgent.map { Color(hex: $0.accentHex) } ?? .accentColor,
                compact: true,
                onSend: { prompt in
                    guard let target = engine.selectedAgent, !target.status.isBusy else { return }
                    engine.sendMessage(to: target.id, text: prompt)
                },
                onStop: {
                    if let activeId = engine.selectedAgent?.id {
                        engine.cancelTask(for: activeId)
                    }
                }
            )
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liquidGlassBar()
    }

    private var planBoardOverlay: some View {
        let doneCount = engine.planTasks.filter { $0.status == .done }.count
        let total = engine.planTasks.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.blue)
                Text(engine.activePlanGoal.isEmpty ? "Aktif Görev Planı" : engine.activePlanGoal)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(doneCount)/\(total)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(.blue.opacity(0.20), in: Capsule())
                Button {
                    withAnimation(.spring(response: 0.25)) { planExpanded.toggle() }
                } label: {
                    Image(systemName: planExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if engine.activeBusyCount == 0 {
                    Button {
                        withAnimation { engine.clearPlan() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Plan panosunu temizle")
                }
            }

            if planExpanded {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 5) {
                        ForEach(Array(engine.planTasks.enumerated()), id: \.element.id) { idx, t in
                            HStack(spacing: 6) {
                                Image(systemName: taskIconName(for: t.status))
                                    .font(.system(size: 10))
                                    .foregroundStyle(taskColor(for: t.status))
                                Text("\(idx + 1). \(t.title)")
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .foregroundStyle(t.status == .done ? .secondary : .primary)
                                Spacer(minLength: 4)
                                Text(t.assigneeName)
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 14, tint: .blue, interactive: true)
    }

    private func taskIconName(for status: OfficeTaskStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "arrow.trianglehead.2.clockwise"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    private func taskColor(for status: OfficeTaskStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .done: return .green
        case .blocked: return .red
        }
    }

    private var dialogueFeedOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.teal)
                Text("Canlı Ekip Konuşmaları")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                Text("\(engine.officeDialogues.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(.teal.opacity(0.20), in: Capsule())
                Spacer(minLength: 4)
                if !engine.officeDialogues.isEmpty {
                    Button("Temizle") {
                        withAnimation { engine.clearDialogues() }
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                Button {
                    withAnimation(.spring(response: 0.25)) { dialogueExpanded.toggle() }
                } label: {
                    Image(systemName: dialogueExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if dialogueExpanded {
                if engine.officeDialogues.isEmpty {
                    Text("Ajanlar ofiste birbirleriyle sohbet ettiğinde veya görev devrettiğinde konuşmalar burada canlı akar.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(engine.officeDialogues.prefix(25)) { msg in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(msg.fromEmoji) \(msg.fromName)")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("→ \(msg.toName):")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(msg.content.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 10))
                                        .lineLimit(2)
                                    Spacer(minLength: 4)
                                    Text(msg.kind.rawValue)
                                        .font(.system(size: 8.5, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                                        .background(dialogueKindColor(msg.kind).opacity(0.18), in: Capsule())
                                        .foregroundStyle(dialogueKindColor(msg.kind))
                                    Text(msg.timestamp, format: .dateTime.hour().minute())
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 112)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 14, tint: .teal, interactive: true)
    }

    private func dialogueKindColor(_ kind: DialogueKind) -> Color {
        switch kind {
        case .social: return .teal
        case .debate: return .indigo
        case .handoff: return .purple
        case .review: return .green
        case .buildFix: return .orange
        case .retrospective: return .cyan
        }
    }
}


private struct IsometricGlassDeskView: View {
    let accent: Color
    let working: Bool
    let isSelected: Bool
    let isDark: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let cx = w * 0.5
            let cy = h * 0.54

            // 1) Yumuşak zemin gölgesi
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - 54, y: cy + 8, width: 108, height: 34)),
                with: .radialGradient(
                    Gradient(colors: [Color.black.opacity(isDark ? 0.50 : 0.25), .clear]),
                    center: CGPoint(x: cx, y: cy + 25),
                    startRadius: 4,
                    endRadius: 56
                )
            )

            // 2) Ergonomik döner sandalye (masanın hafif arkasında / sağında)
            let chairSeat = CGRect(x: cx + 10, y: cy - 6, width: 24, height: 14)
            let chairBack = CGRect(x: cx + 14, y: cy - 22, width: 20, height: 18)
            ctx.fill(Path(ellipseIn: CGRect(x: cx + 14, y: cy + 10, width: 18, height: 8)), with: .color(Color(hex: "#1E2532")))
            ctx.fill(Path(roundedRect: chairSeat, cornerRadius: 5), with: .color(Color(hex: "#2E384B")))
            ctx.stroke(Path(roundedRect: chairSeat, cornerRadius: 5), with: .color(Color.white.opacity(0.20)), lineWidth: 0.8)
            ctx.fill(Path(roundedRect: chairBack, cornerRadius: 6), with: .color(Color(hex: "#3A465C")))
            ctx.stroke(Path(roundedRect: chairBack, cornerRadius: 6), with: .color(Color.white.opacity(0.25)), lineWidth: 0.9)

            // 3) İzometrik masa ayakları (metalik)
            let topFront = CGPoint(x: cx - 2, y: cy + 16)
            let topLeft = CGPoint(x: cx - 52, y: cy - 4)
            let topBack = CGPoint(x: cx + 4, y: cy - 22)
            let topRight = CGPoint(x: cx + 52, y: cy - 2)

            for legTop in [topLeft, topFront, topRight] {
                var leg = Path()
                leg.move(to: legTop)
                leg.addLine(to: CGPoint(x: legTop.x, y: legTop.y + 18))
                ctx.stroke(leg, with: .color(Color(hex: "#94A3B8").opacity(0.75)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }

            // 4) Buzlu cam izometrik masa tablası + cyan kenar parıltısı
            var deskTop = Path()
            deskTop.move(to: topBack)
            deskTop.addLine(to: topRight)
            deskTop.addLine(to: topFront)
            deskTop.addLine(to: topLeft)
            deskTop.closeSubpath()

            ctx.fill(
                deskTop,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.65, green: 0.86, blue: 0.98).opacity(isSelected ? 0.34 : 0.24),
                        Color(red: 0.22, green: 0.38, blue: 0.56).opacity(0.32)
                    ]),
                    startPoint: topBack,
                    endPoint: topFront
                )
            )
            ctx.stroke(
                deskTop,
                with: .color((isSelected || working ? accent : Color.cyan).opacity(isSelected ? 0.92 : 0.68)),
                lineWidth: isSelected ? 1.6 : 1.15
            )

            // 5) Parlak cyan stüdyo monitörü (izometrik sol-arkaya dönük)
            let standPt = CGPoint(x: cx - 10, y: cy - 8)
            var stand = Path()
            stand.move(to: standPt)
            stand.addLine(to: CGPoint(x: standPt.x, y: standPt.y - 7))
            ctx.stroke(stand, with: .color(Color(hex: "#CBD5E1")), lineWidth: 2.2)

            var screen = Path()
            let sBL = CGPoint(x: cx - 28, y: cy - 10)
            let sBR = CGPoint(x: cx + 6, y: cy - 20)
            let sTR = CGPoint(x: cx + 6, y: cy - 42)
            let sTL = CGPoint(x: cx - 28, y: cy - 31)
            screen.move(to: sBL)
            screen.addLine(to: sBR)
            screen.addLine(to: sTR)
            screen.addLine(to: sTL)
            screen.closeSubpath()

            ctx.fill(
                screen,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: "#0284C7"), Color(hex: "#38BDF8")]),
                    startPoint: sBL,
                    endPoint: sTR
                )
            )
            ctx.stroke(screen, with: .color(Color(hex: "#0F172A")), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 13, y: cy - 36, width: 3.5, height: 3.5)), with: .color(working ? accent : .green))

            // 6) Mini saksı bitkisi + klavye
            let pot = CGRect(x: cx - 40, y: cy - 12, width: 8, height: 7)
            ctx.fill(Path(roundedRect: pot, cornerRadius: 2), with: .color(Color(hex: "#CBD5E1")))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 42, y: cy - 17, width: 12, height: 7)), with: .color(Color(hex: "#22C55E")))

            var kb = Path()
            kb.move(to: CGPoint(x: cx - 12, y: cy + 3))
            kb.addLine(to: CGPoint(x: cx + 4, y: cy - 1))
            ctx.stroke(kb, with: .color(Color.white.opacity(0.65)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        .frame(width: 132, height: 86)
    }
}

private struct FloorWalkMarkerView: View {
    let accent: Color
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(expanded ? 0.0 : 0.85), lineWidth: 2.0)
                .frame(width: expanded ? 44 : 12, height: expanded ? 22 : 6)
            Circle()
                .fill(accent.opacity(expanded ? 0.0 : 0.7))
                .frame(width: 6, height: 4)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.95)) {
                expanded = true
            }
        }
    }
}
