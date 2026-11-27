import SwiftUI
import AppKit

struct EvolutionAndProjectView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var buildOutput = ""
    @State private var isTestingBuild = false
    @State private var isRebuilding = false
    @State private var rollbackFeedback = ""
    @State private var expandedDiffIds: Set<UUID> = []
    @State private var cachedDiffs: [UUID: [String]] = [:]
    @State private var customBuildDraft = ""
    @State private var detectedBuildCommandText = "(Otomatik bulunamadı)"
    @State private var pendingAction: PendingEvolutionAction? = nil

    private enum PendingEvolutionAction: Identifiable {
        case selfRebuild
        case restartApp
        case rollback(FileEditRecord)

        var id: String {
            switch self {
            case .selfRebuild: return "selfRebuild"
            case .restartApp: return "restartApp"
            case .rollback(let rec): return "rollback-\(rec.id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .selfRebuild: return "Crims Office Kendini Derlesin ve Yeniden Başlatsın mı?"
            case .restartApp: return "Crims Office Yeniden Başlatılsın mı?"
            case .rollback(let rec): return "'\(rec.relativePath)' Değişikliği Geri Alınsın mı?"
            }
        }

        var message: String {
            switch self {
            case .selfRebuild:
                return "Release derlemesi başarılı olursa uygulama kapanıp güncellenmiş paketle otomatik açılacaktır."
            case .restartApp:
                return "Uygulama ayarları kaydedilip yeniden başlatılacak; aktif görevler kesintiye uğrayabilir."
            case .rollback(let rec):
                return rec.wasNewFile
                    ? "Ajanın yeni oluşturduğu bu dosya silinecektir."
                    : "Dosya, düzenleme öncesi yedek sürümüne döndürülecektir."
            }
        }
    }

    private var workspaceExists: Bool {
        var isDir: ObjCBool = false
        return !engine.workspacePath.isEmpty
            && FileManager.default.fileExists(atPath: engine.workspacePath, isDirectory: &isDir)
            && isDir.boolValue
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
        ZStack {
            AmbientGlassBackdrop(accent: .purple)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack {
                        GlassSectionHeader(
                            title: "Proje Geliştirme & Öz-Gelişim Merkezi",
                            subtitle: "Güvenli otonom kod düzenleme, otomatik derleme/onarım kapısı (Build Gate), 1-tık geri alma ve ekip retrospektifi.",
                            systemImage: "hammer.circle.fill",
                            tint: .purple
                        )
                        Spacer()
                        Button { pickFolder() } label: {
                            Label("Proje Klasörü", systemImage: "folder.badge.gearshape")
                        }
                        .liquidGlassButton(prominent: true, tint: .purple)
                    }

                    // Crims Office Self-Evolution & Mac Control Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Crims Office Kendini Geliştirme (Self-Evolution & Reboot)", systemImage: "sparkles.rectangle.stack.fill")
                                .font(.headline)
                            Spacer()
                            Text(selfRepoPath)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .liquidGlassCapsule(tint: .purple, interactive: false)
                        }

                        Text("Crims Office kendi Swift kaynak kodunu okuyup düzenleyebilir, derleme hatalarını kontrol edebilir ve ardından tek tıkla veya otonom komutla kendini yeniden derleyip başlatabilir.")
                            .font(.caption).foregroundStyle(.secondary)

                        LiquidGlassContainer(spacing: 10) {
                            HStack(spacing: 10) {
                                Button {
                                    pendingAction = .selfRebuild
                                } label: {
                                    if isRebuilding {
                                        Label("Derleniyor...", systemImage: "hourglass")
                                    } else {
                                        Label("Kendini Derle ve Yeniden Başlat (Self-Rebuild)", systemImage: "hammer.fill")
                                    }
                                }
                                .liquidGlassButton(prominent: true, tint: .purple)
                                .disabled(isRebuilding || isTestingBuild || engine.isRunningPipeline)

                                Button {
                                    pendingAction = .restartApp
                                } label: {
                                    Label("Yeniden Başlat (Restart)", systemImage: "arrow.clockwise")
                                }
                                .liquidGlassButton(prominent: false)
                                .disabled(isRebuilding || engine.isRunningPipeline)

                                Button {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: selfRepoPath)
                                } label: {
                                    Label("Kaynak Klasörü (Finder)", systemImage: "folder")
                                }
                                .liquidGlassButton(prominent: false)
                            }
                        }
                    }
                    .padding(16)
                    .liquidGlassCard(cornerRadius: 18, tint: .purple)

                    // Autonomous Project Development Controls
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Otonom Proje Geliştirme & Güvenlik Kapısı", systemImage: "hammer.fill")
                            .font(.headline)

                        HStack {
                            Text("Hedef Proje: \(engine.workspacePath)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(workspaceExists ? Color.secondary : Color.orange)
                            Spacer()
                            if engine.workspacePath != selfRepoPath && FileManager.default.fileExists(atPath: selfRepoPath) {
                                Button("Crims Office Projesine Ayarla") {
                                    engine.setWorkspacePath(selfRepoPath)
                                }
                                .liquidGlassButton(prominent: false)
                                .controlSize(.small)
                            }
                        }

                        Toggle("Ajanların Projede Dosya Yazmasına/Yamalamasına İzin Ver (Otomatik .clawoffice-backups/ yedeği alınır)", isOn: Binding(
                            get: { engine.allowFileWrites },
                            set: { engine.allowFileWrites = $0; engine.saveConfig() }
                        ))

                        Toggle("Otonom Sprint Sonrası Otomatik Derleme/Test Doğrulama + 2 Kez Kendini Onarma (Self-Healing)", isOn: Binding(
                            get: { engine.autoVerifyBuild },
                            set: { engine.autoVerifyBuild = $0; engine.saveConfig() }
                        ))

                        Toggle("Ofiste Boşta Kalan Ajanların Kahve Molası Hareketi (0 Token)", isOn: Binding(
                            get: { engine.enableSocialChatter },
                            set: { engine.enableSocialChatter = $0; engine.saveConfig() }
                        ))

                        HStack(spacing: 8) {
                            TextField("Özel Build/Test Komutu (boşsa otomatik: \(detectedBuildCommandText))", text: $customBuildDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .onSubmit { commitCustomBuildCommand() }

                            Button(isTestingBuild ? "Çalışıyor..." : "Şimdi Doğrula") {
                                commitCustomBuildCommand()
                                runManualBuildCheck()
                            }
                            .liquidGlassButton(prominent: false)
                            .disabled(isTestingBuild || isRebuilding || !workspaceExists)

                            Button("Testleri Çalıştır") {
                                runManualTestCheck()
                            }
                            .liquidGlassButton(prominent: false, tint: .green)
                            .disabled(isTestingBuild || isRebuilding || !workspaceExists)
                        }

                        if let bv = engine.lastBuildVerification {
                            Text(bv.summary)
                                .font(.caption.bold())
                                .foregroundStyle(bv.passed ? .green : .orange)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .liquidGlassCapsule(tint: bv.passed ? .green : .orange, interactive: false)
                        }

                        if !buildOutput.isEmpty {
                            SmokedGlassSurface(cornerRadius: 12) {
                                ScrollView {
                                    Text(buildOutput)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                }
                                .frame(height: 120)
                                .foregroundStyle(Color(red: 0.48, green: 0.94, blue: 0.60))
                            }
                        }
                    }
                    .padding(16)
                    .liquidGlassCard(cornerRadius: 18, tint: .blue)

                    // Team Self-Improvement Engine
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Ekip Öz-Gelişim Motoru (Self-Improvement)", systemImage: "brain.head.profile")
                                .font(.headline)
                            Spacer()
                            Toggle("Sprint Sonrası Otomatik Öğren", isOn: Binding(
                                get: { engine.autoSelfImprove },
                                set: { engine.autoSelfImprove = $0; engine.saveConfig() }
                            )).controlSize(.small)
                        }
                        Text("Ekip toplantı odasında bir araya gelir, son hataları ve dosya değişikliklerini analiz eder, çıkarılan mühendislik derslerini kalıcı OpenClaw MEMORY.md + günlük memory/ dosyasına yazar ve isterse yeni bir SKILL.md yeteneği üretir.")
                            .font(.caption).foregroundStyle(.secondary)

                        LiquidGlassContainer(spacing: 10) {
                            HStack(spacing: 10) {
                                Button {
                                    engine.runTeamRetrospective(createNewSkill: false)
                                } label: {
                                    Label("Retrospektif & MEMORY.md Güncelle", systemImage: "sparkles")
                                }
                                .liquidGlassButton(prominent: true, tint: .indigo)
                                .disabled(engine.isRunningPipeline)

                                Button {
                                    engine.runTeamRetrospective(createNewSkill: true)
                                } label: {
                                    Label("Retrospektif + Yeni SKILL.md Üret", systemImage: "wand.and.stars")
                                }
                                .liquidGlassButton(prominent: false, tint: .purple)
                                .disabled(engine.isRunningPipeline)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 185))], spacing: 10) {
                            ForEach(engine.agents) { a in
                                HStack(spacing: 10) {
                                    AgentAvatarView(agent: a, size: 34, showStatusDot: false)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(a.emoji) \(a.name)").font(.subheadline.bold())
                                        Text("\(a.title) · \(a.completedTasks) görev").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .liquidGlassCard(cornerRadius: 12, tint: Color(hex: a.accentHex))
                            }
                        }
                    }
                    .padding(16)
                    .liquidGlassCard(cornerRadius: 18, tint: .indigo)

                    // Safe File Edit History & 1-Click Rollback
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Güvenli Dosya Değişiklikleri & Tek Tıkla Geri Alma (\(engine.fileEdits.count))", systemImage: "clock.arrow.circlepath")
                                .font(.headline)
                            Spacer()
                            if !rollbackFeedback.isEmpty {
                                Text(rollbackFeedback).font(.caption).foregroundStyle(.orange)
                            }
                        }

                        if engine.fileEdits.isEmpty {
                            Text("Ajanlar henüz proje dosyalarında düzenleme yapmadı. Otonom Proje Sprinti çalıştırdığınızda her düzenleme yedeklenerek burada listelenir.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(engine.fileEdits.prefix(20)) { rec in
                                let isDiffOpen = expandedDiffIds.contains(rec.id)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(rec.relativePath).font(.system(.callout, design: .monospaced).bold())
                                                Text(rec.agentName)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                                    .liquidGlassCapsule(tint: .accentColor, interactive: false)
                                                if rec.rolledBack {
                                                    Text("Geri Alındı").font(.caption2.bold()).foregroundStyle(.orange)
                                                }
                                            }
                                            Text("\(rec.summary) · \(rec.timestamp.formatted(date: .omitted, time: .shortened))")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if !rec.backupPath.isEmpty {
                                            Button(isDiffOpen ? "Farkı Gizle" : "Diff Gör") {
                                                toggleDiff(for: rec)
                                            }
                                            .liquidGlassButton(prominent: false)
                                            .controlSize(.small)
                                        }
                                        if !rec.rolledBack && (!rec.backupPath.isEmpty || rec.wasNewFile) {
                                            Button("Geri Al (Rollback)") {
                                                pendingAction = .rollback(rec)
                                            }
                                            .liquidGlassButton(prominent: false, tint: .orange)
                                        }
                                    }

                                    if isDiffOpen {
                                        let diffLines = cachedDiffs[rec.id] ?? ["Diff yükleniyor..."]
                                        SmokedGlassSurface(cornerRadius: 8) {
                                            ScrollView {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                                                        Text(line)
                                                            .font(.system(size: 10.5, design: .monospaced))
                                                            .foregroundStyle(
                                                                line.hasPrefix("+ ") ? Color.green :
                                                                (line.hasPrefix("- ") ? Color.red : Color.cyan)
                                                            )
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                    }
                                                }
                                                .padding(8)
                                            }
                                            .frame(maxHeight: 150)
                                        }
                                    }
                                }
                                .padding(10)
                                .liquidGlassCard(cornerRadius: 12)
                            }
                        }
                    }
                    .padding(16)
                    .liquidGlassCard(cornerRadius: 18)
                }
                .padding(22)
            }
        }
        .onAppear {
            customBuildDraft = engine.customBuildCommand
            refreshDetectedBuildCommand()
        }
        .onChange(of: engine.workspacePath) { _, _ in
            cachedDiffs.removeAll()
            refreshDetectedBuildCommand()
        }
        .onChange(of: engine.workspaceRefreshNonce) { _, _ in
            cachedDiffs.removeAll()
        }
        .onChange(of: engine.customBuildCommand) { _, newVal in
            if customBuildDraft != newVal {
                customBuildDraft = newVal
            }
        }
        .task(id: customBuildDraft) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            commitCustomBuildCommand()
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                switch action {
                case .selfRebuild:
                    Button("Derle ve Yeniden Başlat", role: .destructive) {
                        executeSelfRebuild()
                    }
                case .restartApp:
                    Button("Yeniden Başlat", role: .destructive) {
                        engine.restartApp(reason: "Arayüzden onaylandı")
                    }
                case .rollback(let rec):
                    Button("Geri Al (Rollback)", role: .destructive) {
                        let r = engine.rollbackEdit(id: rec.id)
                        rollbackFeedback = r.1
                        cachedDiffs.removeValue(forKey: rec.id)
                    }
                }
            }
            Button("İptal", role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.setWorkspacePath(url.path)
        }
    }

    private func refreshDetectedBuildCommand() {
        let ws = engine.workspacePath
        Task.detached(priority: .utility) {
            let detected = PowerShellTools.detectBuildCommand(workspacePath: ws, customOverride: "") ?? "(Otomatik bulunamadı)"
            await MainActor.run {
                detectedBuildCommandText = detected
            }
        }
    }

    private func commitCustomBuildCommand() {
        if engine.customBuildCommand != customBuildDraft {
            engine.customBuildCommand = customBuildDraft
            engine.saveConfig()
        }
    }

    private func executeSelfRebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        buildOutput = "$ swift build -c release && ./build_app.sh --skip-build\nDerleme başlatıldı..."
        Task { @MainActor in
            let res = await engine.selfRebuildAndRestart(reason: "Arayüzden onaylandı")
            isRebuilding = false
            buildOutput = res.0 ? "✅ \(res.1)" : "❌ \(res.1)"
        }
    }

    private func toggleDiff(for rec: FileEditRecord) {
        if expandedDiffIds.contains(rec.id) {
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                expandedDiffIds.remove(rec.id)
            }
            return
        }
        _ = withAnimation(.easeInOut(duration: 0.2)) {
            expandedDiffIds.insert(rec.id)
        }
        guard cachedDiffs[rec.id] == nil else { return }
        let ws = engine.workspacePath
        Task.detached(priority: .userInitiated) {
            let lines: [String]
            if let targetURL = PowerShellTools.resolveSafeURL(rec.relativePath, workspacePath: ws) {
                let oldText = (try? String(contentsOfFile: rec.backupPath, encoding: .utf8)) ?? ""
                let newText = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
                lines = LineDiffUtility.unifiedDiff(oldText: oldText, newText: newText)
            } else {
                lines = ["Dosya yolu çözümlenemedi."]
            }
            await MainActor.run {
                cachedDiffs[rec.id] = lines
            }
        }
    }

    private func runManualBuildCheck() {
        guard let cmd = PowerShellTools.detectBuildCommand(workspacePath: engine.workspacePath, customOverride: engine.customBuildCommand) else {
            buildOutput = "Otomatik derleme komutu tespit edilemedi. Yukarıdaki alana komut girin (ör: swift build)."
            return
        }
        runVerificationCommand(cmd)
    }

    private func runManualTestCheck() {
        guard let cmd = PowerShellTools.detectTestCommand(workspacePath: engine.workspacePath, customOverride: "") else {
            buildOutput = "Otomatik test komutu tespit edilemedi."
            return
        }
        runVerificationCommand(cmd)
    }

    private func runVerificationCommand(_ cmd: String) {
        guard workspaceExists else {
            buildOutput = "Çalışma klasörü bulunamadı: \(engine.workspacePath)"
            return
        }
        isTestingBuild = true
        buildOutput = "$ \(cmd)\n..."
        Task { @MainActor in
            let res = await PowerShellTools.runCommand(cmd, workspacePath: engine.workspacePath, wrapWithRTK: engine.enableRTKProxy)
            buildOutput = "$ \(res.commandUsed)\n\n\(res.output)"
            engine.lastBuildVerification = (res.succeeded, res.succeeded ? "✅ `\(cmd)` geçti" : "⚠️ `\(cmd)` hata verdi")
            isTestingBuild = false
        }
    }
}
