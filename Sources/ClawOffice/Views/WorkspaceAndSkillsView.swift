import SwiftUI

struct WorkspaceAndSkillsView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var selectedDoc: String = "AGENTS.md"
    @State private var docContent: String = ""
    @State private var originalDocContent: String = ""
    @State private var saveBanner: String = ""
    @State private var saveSucceeded: Bool = true
    @State private var pendingDocSwitch: String? = nil
    @State private var showUnsavedSwitchAlert: Bool = false
    @State private var showOverwriteProjectAgentsAlert: Bool = false
    @State private var showSkillWorkbench: Bool = false
    @State private var wbSlug: String = ""
    @State private var wbName: String = ""
    @State private var wbDesc: String = ""
    @State private var wbTriggers: String = ""
    @State private var wbBody: String = "## Amaç\nBu skill için adım adım talimatları yazın.\n"
    @State private var wbFeedback: String = ""
    @State private var skillSearchText: String = ""
    @State private var pendingDeleteSkill: AgentSkill? = nil

    private var filteredSkills: [AgentSkill] {
        let q = skillSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return engine.skills }
        return engine.skills.filter { sk in
            sk.name.lowercased().contains(q)
                || sk.id.lowercased().contains(q)
                || sk.description.lowercased().contains(q)
                || sk.triggers.contains { $0.lowercased().contains(q) }
        }
    }

    private var isDirty: Bool {
        docContent != originalDocContent
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .teal)
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        GlassSectionHeader(
                            title: "OpenClaw Bellek & AGENTS.md",
                            subtitle: engine.openClawHomePath,
                            systemImage: "brain.head.profile",
                            tint: .teal
                        )
                        Spacer()
                        Toggle("AGENTS.md Enjekte", isOn: Binding(
                            get: { engine.injectAgentsMD },
                            set: { engine.injectAgentsMD = $0; engine.saveConfig() }
                        )).toggleStyle(.switch).controlSize(.small)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LiquidGlassContainer(spacing: 7) {
                            HStack(spacing: 7) {
                                ForEach(OpenClawWorkspaceService.standardFiles, id: \.self) { fname in
                                    Button(fname == selectedDoc && isDirty ? "\(fname) •" : fname) {
                                        switchToDoc(fname)
                                    }
                                    .liquidGlassButton(prominent: selectedDoc == fname, tint: .teal)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    TextEditor(text: $docContent)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 14)

                    HStack {
                        Button("Kaydet (\(selectedDoc))") {
                            saveCurrentDoc()
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .liquidGlassButton(prominent: true, tint: .teal)
                        .disabled(!isDirty)

                        Button("Proje Köküne AGENTS.md Oluştur") {
                            let target = URL(fileURLWithPath: engine.workspacePath).appendingPathComponent("AGENTS.md").path
                            if FileManager.default.fileExists(atPath: target) {
                                showOverwriteProjectAgentsAlert = true
                            } else {
                                writeProjectAgentsMD()
                            }
                        }.liquidGlassButton(prominent: false)

                        Spacer()
                        if !saveBanner.isEmpty {
                            Text(saveBanner)
                                .font(.caption)
                                .foregroundStyle(saveSucceeded ? Color.green : Color.red)
                        }
                    }

                    if !engine.discoveredAgentsMD.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Projede Bulunan AGENTS.md / CLAUDE.md Dosyaları:").font(.caption.bold())
                            ForEach(engine.discoveredAgentsMD, id: \.relativePath) { item in
                                Text("• \(item.relativePath) (\(item.content.count) karakter)")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassCard(cornerRadius: 14, tint: .teal)
                    }
                }
                .padding(18).frame(minWidth: 420)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        GlassSectionHeader(
                            title: "OpenClaw Skilleri (\(engine.skills.count))",
                            subtitle: "Progressive Disclosure: Yalnızca ilgili görevde yüklenir.",
                            systemImage: "sparkles.square.filled.on.square",
                            tint: .blue
                        )
                        Spacer()
                        Button {
                            wbSlug = ""
                            wbName = ""
                            wbDesc = ""
                            wbTriggers = ""
                            wbBody = "## Amaç\nBu skill için adım adım talimatları yazın.\n"
                            wbFeedback = ""
                            showSkillWorkbench = true
                        } label: {
                            Label("Yeni Skill", systemImage: "plus.circle.fill")
                                .lineLimit(1)
                        }
                        .liquidGlassButton(prominent: true, tint: .teal)
                        .controlSize(.small)

                        Button {
                            engine.requestedSectionRawValue = AppSection.connectors.rawValue
                        } label: {
                            Label("GitHub / ClawHub", systemImage: "magnifyingglass")
                                .lineLimit(1)
                        }
                        .liquidGlassButton(prominent: false, tint: .cyan)
                        .controlSize(.small)

                        Button { engine.refreshWorkspaceAndSkills() } label: { Image(systemName: "arrow.clockwise") }
                            .liquidGlassButton(prominent: false)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                        TextField("Skill veya tetikleyici ara...", text: $skillSearchText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                        if !skillSearchText.isEmpty {
                            Button { skillSearchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .liquidGlassCard(cornerRadius: 10)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredSkills) { sk in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(sk.name).font(.headline)
                                            Text("/\(sk.id) · \(sk.sourcePath)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Button {
                                            wbSlug = sk.id
                                            wbName = sk.name
                                            wbDesc = sk.description
                                            wbTriggers = sk.triggers
                                                .filter { $0 != sk.id && $0 != "/\(sk.id)" }
                                                .joined(separator: ", ")
                                            wbBody = sk.body
                                            wbFeedback = ""
                                            showSkillWorkbench = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Skill içeriğini düzenle")

                                        if sk.sourcePath != "Dahili" {
                                            Button(role: .destructive) {
                                                pendingDeleteSkill = sk
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.caption)
                                                    .foregroundStyle(.red.opacity(0.85))
                                            }
                                            .buttonStyle(.borderless)
                                            .help("Özel skilli sil")
                                        }

                                        Toggle(sk.name, isOn: Binding(get: { sk.isEnabled }, set: { _ in engine.toggleSkill(id: sk.id) }))
                                            .labelsHidden()
                                            .accessibilityLabel(Text("\(sk.name) yeteneğini aç/kapat"))
                                            .toggleStyle(.switch)
                                    }
                                    Text(sk.description).font(.caption).foregroundStyle(.secondary)
                                    if !sk.triggers.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 4) {
                                                ForEach(sk.triggers.prefix(8), id: \.self) { trig in
                                                    Text(trig)
                                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                                        .background(Color.teal.opacity(0.14), in: Capsule())
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .liquidGlassCard(cornerRadius: 14, tint: sk.isEnabled ? .teal : nil)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(18).frame(minWidth: 350, idealWidth: 400)
            }
        }
        .onAppear { loadCurrentDoc(); engine.refreshWorkspaceAndSkills() }
        .onChange(of: engine.workspaceRefreshNonce) { _, _ in
            if !isDirty {
                loadCurrentDoc()
            }
        }
        .alert("Kaydedilmemiş Değişiklikler", isPresented: $showUnsavedSwitchAlert) {
            Button("Kaydet ve Geç") {
                if saveCurrentDoc(), let next = pendingDocSwitch {
                    selectedDoc = next
                    pendingDocSwitch = nil
                    loadCurrentDoc()
                }
            }
            Button("Değişiklikleri At", role: .destructive) {
                if let next = pendingDocSwitch {
                    selectedDoc = next
                    pendingDocSwitch = nil
                    loadCurrentDoc()
                }
            }
            Button("İptal", role: .cancel) {
                pendingDocSwitch = nil
            }
        } message: {
            Text("\(selectedDoc) içinde kaydedilmemiş düzenlemeler var.")
        }
        .alert("Proje AGENTS.md Üzerine Yazılsın mı?", isPresented: $showOverwriteProjectAgentsAlert) {
            Button("Üzerine Yaz", role: .destructive) {
                writeProjectAgentsMD()
            }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Proje kökünde zaten bir AGENTS.md dosyası mevcut. OpenClaw şablonuyla değiştirilsin mi?")
        }
        .alert("Özel Skill Silinsin mi?", isPresented: Binding(
            get: { pendingDeleteSkill != nil },
            set: { if !$0 { pendingDeleteSkill = nil } }
        )) {
            Button("Sil", role: .destructive) {
                if let sk = pendingDeleteSkill {
                    do {
                        try OpenClawWorkspaceService.deleteCustomSkill(at: sk.sourcePath, openClawHome: engine.openClawHomePath)
                        let remaining = Set(engine.skills.filter { $0.isEnabled && $0.id != sk.id }.map { $0.id })
                        engine.refreshWorkspaceAndSkills(enabledIds: remaining)
                        engine.saveConfig()
                        saveSucceeded = true
                        saveBanner = "\(sk.name) silindi ✓"
                    } catch {
                        saveSucceeded = false
                        saveBanner = "Silinemedi: \(error.localizedDescription)"
                    }
                    pendingDeleteSkill = nil
                }
            }
            Button("İptal", role: .cancel) { pendingDeleteSkill = nil }
        } message: {
            Text("\(pendingDeleteSkill?.name ?? "") becerisinin SKILL.md klasörü kaldırılacak.")
        }
        .sheet(isPresented: $showSkillWorkbench) {
            skillWorkbenchSheet
        }
    }

    private var skillWorkbenchSheet: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .teal)
            VStack(alignment: .leading, spacing: 12) {
                GlassSectionHeader(
                    title: "Skill Workbench (SKILL.md Atölyesi)",
                    subtitle: "\(engine.openClawHomePath)/skills",
                    systemImage: "sparkles.square.filled.on.square",
                    tint: .teal
                )
                HStack(spacing: 8) {
                    TextField("Slug (ör: swift-release-check)", text: $wbSlug).textFieldStyle(.roundedBorder)
                    TextField("Skill Adı", text: $wbName).textFieldStyle(.roundedBorder)
                }
                TextField("Kısa Açıklama (progressive disclosure özeti)", text: $wbDesc).textFieldStyle(.roundedBorder)
                TextField("Tetikleyici Kelimeler (virgülle: swift, build, test)", text: $wbTriggers).textFieldStyle(.roundedBorder)
                TextEditor(text: $wbBody)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 190)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .liquidGlassCard(cornerRadius: 12)
                if !wbFeedback.isEmpty {
                    Text(wbFeedback).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Kapat") { showSkillWorkbench = false }.liquidGlassButton(prominent: false)
                    Button("SKILL.md Kaydet") {
                        do {
                            let rawTriggers = wbTriggers
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            let path = try OpenClawWorkspaceService.saveEvolvedSkill(
                                slug: wbSlug.isEmpty ? wbName : wbSlug,
                                name: wbName.isEmpty ? wbSlug : wbName,
                                description: wbDesc,
                                body: wbBody,
                                openClawHome: engine.openClawHomePath,
                                triggers: rawTriggers
                            )
                            let savedSlug = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                            let keepEnabled = Set(engine.skills.filter { $0.isEnabled }.map { $0.id } + [savedSlug])
                            engine.refreshWorkspaceAndSkills(enabledIds: keepEnabled)
                            engine.saveConfig()
                            wbFeedback = "Kaydedildi ve aktifleştirildi ✓ (\(path))"
                        } catch {
                            wbFeedback = "Hata: \(error.localizedDescription)"
                        }
                    }
                    .liquidGlassButton(prominent: true, tint: .teal)
                    .disabled(wbSlug.trimmingCharacters(in: .whitespaces).isEmpty && wbName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 440)
    }

    private func switchToDoc(_ target: String) {
        guard target != selectedDoc else { return }
        if isDirty {
            pendingDocSwitch = target
            showUnsavedSwitchAlert = true
            return
        }
        selectedDoc = target
        loadCurrentDoc()
    }

    @discardableResult
    private func saveCurrentDoc() -> Bool {
        do {
            try OpenClawWorkspaceService.writeFile(named: selectedDoc, content: docContent, in: engine.openClawHomePath)
            originalDocContent = docContent
            saveSucceeded = true
            saveBanner = "Kaydedildi ✓"
            engine.refreshWorkspaceAndSkills()
            return true
        } catch {
            saveSucceeded = false
            saveBanner = "Hata: \(error.localizedDescription)"
            return false
        }
    }

    private func writeProjectAgentsMD() {
        let template = OpenClawWorkspaceService.readFile(named: "AGENTS.md", in: engine.openClawHomePath)
        do {
            try OpenClawWorkspaceService.writeFile(named: "AGENTS.md", content: template, in: engine.workspacePath)
            engine.refreshWorkspaceAndSkills()
            saveSucceeded = true
            saveBanner = "Proje klasörüne AGENTS.md yazıldı ✓"
        } catch {
            saveSucceeded = false
            saveBanner = "AGENTS.md yazılamadı: \(error.localizedDescription)"
        }
    }

    private func loadCurrentDoc() {
        let content = OpenClawWorkspaceService.readFile(named: selectedDoc, in: engine.openClawHomePath)
        docContent = content
        originalDocContent = content
        saveBanner = ""
        saveSucceeded = true
    }
}
