import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProvidersSettingsView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var magicKey = ""
    @State private var magicStatus = ""
    @State private var isMagicRunning = false
    @State private var showAdd = false
    @State private var feedback: [UUID: (Bool, String)] = [:]
    @State private var busy: Set<UUID> = []

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .blue)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "wand.and.stars").foregroundStyle(.blue).font(.title3)
                            Text("Hızlı API Bağla (Tek Tıkla Otomatik Kurulum)").font(.headline)
                        }
                        Text("Kilo Gateway, EVREN (`evren_llm_...`), OpenRouter (`sk-or-...`), Groq (`gsk_...`) veya NVIDIA NIM (`nvapi-...`) anahtarınızı yapıştırın — sağlayıcıyı tanır, EVREN şartlarını onaylar, modelleri çeker ve test eder.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            SecureField("API anahtarınızı buraya yapıştırın...", text: $magicKey)
                                .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
                            Button(isMagicRunning ? "Bağlanıyor..." : "Otomatik Bağla") {
                                isMagicRunning = true; magicStatus = ""
                                Task {
                                    let res = await engine.quickConnectAPIKey(magicKey)
                                    magicStatus = res.1
                                    if res.0 { magicKey = "" }
                                    isMagicRunning = false
                                }
                            }
                            .liquidGlassButton(prominent: true)
                            .disabled(isMagicRunning || magicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if !magicStatus.isEmpty {
                            Text(magicStatus).font(.caption).foregroundStyle(.blue).textSelection(.enabled)
                        }
                    }
                    .padding(16)
                    .liquidGlassCard(cornerRadius: 18, tint: .accentColor)

                    HStack {
                        GlassSectionHeader(
                            title: "Kayıtlı API Sağlayıcıları",
                            subtitle: "API anahtarları macOS Keychain'de güvenle saklanır; diğer ayarlar 0600 izinli config-v4.json dosyasında tutulur.",
                            systemImage: "key.horizontal.fill",
                            tint: .blue
                        )
                        Spacer()
                        LiquidGlassContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button { engine.checkProvidersHealth() } label: {
                                    Label("Tümünü Test Et (Ping)", systemImage: "waveform.path.ecg")
                                }.liquidGlassButton(prominent: false)
                                Button { showAdd = true } label: {
                                    Label("Özel API Ekle", systemImage: "plus.circle.fill")
                                }.liquidGlassButton(prominent: false, tint: .blue)
                            }
                        }
                    }

                    ForEach(engine.providers) { prov in
                        ProviderCard(
                            provider: prov,
                            healthStatus: engine.providerStatuses[prov.id],
                            isBusy: busy.contains(prov.id),
                            feedback: feedback[prov.id],
                            onSave: { engine.updateProvider($0); feedback[$0.id] = (true, "Kaydedildi.") },
                            onFetch: { run(prov.id) { await engine.fetchModels(for: prov.id) } },
                            onTest: { run(prov.id) { await engine.testConnection(for: prov.id) } },
                            onEvrenTerms: { run(prov.id) { await engine.acceptEvrenTerms(for: prov.id) } },
                            onEvrenQuota: { run(prov.id) { await engine.checkEvrenQuota(for: prov.id) } },
                            onDelete: prov.kind == .custom ? { engine.deleteProvider(id: prov.id) } : nil
                        )
                    }
                }.padding(22)
            }
        }
        .sheet(isPresented: $showAdd) { AddProviderSheet().environmentObject(engine) }
    }

    private func run(_ id: UUID, op: @escaping () async -> (Bool, String)) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task { @MainActor in
            let r = await op()
            busy.remove(id)
            feedback[id] = r
        }
    }
}

struct ProviderCard: View {
    let provider: APIProviderConfig
    let healthStatus: ProviderHealthStatus?
    let isBusy: Bool
    let feedback: (Bool, String)?
    let onSave: (APIProviderConfig) -> Void
    let onFetch: () -> Void
    let onTest: () -> Void
    let onEvrenTerms: () -> Void
    let onEvrenQuota: () -> Void
    let onDelete: (() -> Void)?

    @State private var draft: APIProviderConfig
    @State private var newModel = ""
    @State private var isDirty = false
    @State private var revealAPIKey = false
    @State private var validationError: String? = nil

    init(provider: APIProviderConfig, healthStatus: ProviderHealthStatus? = nil, isBusy: Bool, feedback: (Bool, String)?,
         onSave: @escaping (APIProviderConfig) -> Void, onFetch: @escaping () -> Void,
         onTest: @escaping () -> Void, onEvrenTerms: @escaping () -> Void,
         onEvrenQuota: @escaping () -> Void, onDelete: (() -> Void)?) {
        self.provider = provider; self.healthStatus = healthStatus; self.isBusy = isBusy; self.feedback = feedback
        self.onSave = onSave; self.onFetch = onFetch; self.onTest = onTest
        self.onEvrenTerms = onEvrenTerms; self.onEvrenQuota = onEvrenQuota; self.onDelete = onDelete
        _draft = State(initialValue: provider)
    }

    private var pickerModels: [String] {
        var list = draft.uniqueModels
        if !draft.defaultModel.isEmpty && !list.contains(draft.defaultModel) { list.insert(draft.defaultModel, at: 0) }
        return list.isEmpty ? ["auto"] : list
    }

    private func validatedDraft() -> APIProviderConfig? {
        var normalized = draft
        normalized.baseURL = normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.apiKey = normalized.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.kind != .antigravityCLI {
            guard let url = URL(string: normalized.baseURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                validationError = "Geçerli bir http(s):// Base URL girin."
                return nil
            }
        }
        validationError = nil
        return normalized
    }

    @discardableResult
    private func commitSave() -> Bool {
        guard let valid = validatedDraft() else { return false }
        draft = valid
        isDirty = false
        onSave(valid)
        return true
    }

    var body: some View {
        let tint = Color(hex: provider.kind.accentHex)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: provider.kind.symbolName).foregroundStyle(tint).font(.title3)
                Text(provider.name).font(.headline)
                Text(provider.isConfigured ? "Aktif" : "Anahtar Gerekli")
                    .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .liquidGlassCapsule(tint: provider.isConfigured ? .green : .orange, interactive: false)
                if provider.kind == .evren {
                    let termsOK = (provider.evrenTermsAcceptedVersion?.isEmpty == false)
                    Text(termsOK ? "Şartlar Onaylı ✓" : "Şart Onayı Gerekli")
                        .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .liquidGlassCapsule(tint: termsOK ? .blue : .orange, interactive: false)
                }
                if let h = healthStatus {
                    HStack(spacing: 4) {
                        Circle().fill(h.isOnline ? Color.green : Color.red).frame(width: 6, height: 6)
                        Text(h.statusMessage)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .liquidGlassCapsule(tint: h.isOnline ? .green : .red, interactive: false)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                if let onDelete { Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless) }
            }

            if provider.kind == .antigravityCLI {
                TextField("Antigravity CLI Yolu (agy)", text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onChange(of: draft.baseURL) { _, _ in isDirty = true }
            } else {
                HStack {
                    TextField("Base URL", text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .onChange(of: draft.baseURL) { _, _ in isDirty = true }
                    Picker("Auth", selection: $draft.authStyle) {
                        ForEach(AuthHeaderStyle.allCases) { s in Text(s.label).tag(s) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .onChange(of: draft.authStyle) { _, _ in isDirty = true }
                }

                if draft.authStyle != .none {
                    HStack(spacing: 6) {
                        Group {
                            if revealAPIKey {
                                TextField(provider.kind == .evren ? "EVREN API Key (evren_llm_...)" : "API Key", text: $draft.apiKey)
                            } else {
                                SecureField(provider.kind == .evren ? "EVREN API Key (evren_llm_...)" : "API Key", text: $draft.apiKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .onChange(of: draft.apiKey) { _, _ in isDirty = true }

                        Button { revealAPIKey.toggle() } label: {
                            Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(revealAPIKey ? "Anahtarı gizle" : "Anahtarı göster")

                        if !draft.apiKey.isEmpty {
                            Button {
                                draft.apiKey = ""
                                isDirty = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("API anahtarını temizle")
                        }
                    }
                }
            }

            HStack {
                Picker("Varsayılan Model", selection: $draft.defaultModel) {
                    ForEach(pickerModels, id: \.self) { m in Text(m).tag(m) }
                }
                .onChange(of: draft.defaultModel) { _, _ in isDirty = true }

                TextField("Manuel model ekle...", text: $newModel).textFieldStyle(.roundedBorder).frame(width: 185)
                Button("Ekle") {
                    let c = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !c.isEmpty && !draft.models.contains(c) {
                        draft.models.insert(c, at: 0); draft.defaultModel = c; newModel = ""; _ = commitSave()
                    }
                }
                .liquidGlassButton(prominent: false)
                .disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !draft.uniqueModels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(draft.uniqueModels.prefix(8), id: \.self) { m in
                            let isDef = draft.defaultModel == m
                            Button {
                                draft.defaultModel = m
                                _ = commitSave()
                            } label: {
                                Text(m.components(separatedBy: "/").last ?? m)
                                    .font(.system(size: 10, weight: isDef ? .bold : .regular, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .liquidGlassCapsule(tint: isDef ? .accentColor : nil, interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let q = provider.lastQuotaSummary, !q.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill").foregroundStyle(.blue).font(.caption2)
                    Text(q).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .liquidGlassCapsule(tint: .blue, interactive: false)
            }

            LiquidGlassContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(isDirty ? "Kaydet *" : "Kaydet") { _ = commitSave() }
                        .liquidGlassButton(prominent: true, tint: tint)
                        .disabled(isBusy)
                    Button("Modelleri Çek") { if commitSave() { onFetch() } }
                        .liquidGlassButton(prominent: false)
                        .disabled(isBusy)
                    Button("Test Et") { if commitSave() { onTest() } }
                        .liquidGlassButton(prominent: false)
                        .disabled(isBusy)
                    if provider.kind == .evren {
                        Button("EVREN Şartlarını Onayla") { if commitSave() { onEvrenTerms() } }
                            .liquidGlassButton(prominent: false, tint: .blue)
                            .disabled(isBusy)
                        Button("Kota") { if commitSave() { onEvrenQuota() } }
                            .liquidGlassButton(prominent: false)
                            .disabled(isBusy)
                    }
                }
            }

            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            } else if let fb = feedback {
                Text(fb.1).font(.caption).foregroundStyle(fb.0 ? .green : .red).textSelection(.enabled)
            }
        }
        .padding(16)
        .liquidGlassCard(cornerRadius: 18, tint: tint)
        .onChange(of: provider) { _, u in
            // Preserve unsaved user edits to credentials/URL while still applying server metadata updates.
            if isDirty {
                draft.models = u.models
                draft.evrenTermsAcceptedVersion = u.evrenTermsAcceptedVersion
                draft.lastQuotaSummary = u.lastQuotaSummary
            } else {
                draft = u
            }
        }
    }
}

struct AddProviderSheet: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = "https://"
    @State private var apiKey = ""
    @State private var auth: AuthHeaderStyle = .bearer
    @State private var model = ""

    private var hasValidBaseURL: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Yeni Özel API Ekle").font(.title3.bold())
            Form {
                TextField("Ad", text: $name)
                TextField("Base URL", text: $baseURL)
                Picker("Auth", selection: $auth) { ForEach(AuthHeaderStyle.allCases) { s in Text(s.label).tag(s) } }
                if auth != .none { SecureField("API Key", text: $apiKey) }
                TextField("Varsayılan Model", text: $model)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("İptal") { dismiss() }
                Button("Ekle") {
                    engine.addCustomProvider(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                        authStyle: auth,
                        defaultModel: model.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasValidBaseURL || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 440, height: 340)
    }
}

struct MultiAgentTaskView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var goal = ""
    @State private var selected: Set<UUID> = []
    @State private var mode: PipelineMode = .swarms
    @State private var rounds: Int = 2
    @State private var swarmTopology: SwarmsTopology = .auto
    @State private var swarmMaxLoops: Int = 1
    @State private var rearrangeFlow: String = ""
    @State private var swarmFeedback: String = ""

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .indigo)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassSectionHeader(
                        title: "Swarms Orkestrasyon & Çoklu Ajan Toplantısı",
                        subtitle: "Kalıcı Swarms çalışma zamanı (127.0.0.1:8765) ile çoklu ajan akışları, canlı tartışma veya otonom proje sprinti başlatın.",
                        systemImage: "person.3.sequence.fill",
                        tint: .indigo
                    )

                    // Persistent Swarms Daemon Status Bar
                    HStack(spacing: 10) {
                        let online = engine.swarmsHealth?.isHealthy == true
                        Circle()
                            .fill(online ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        if let h = engine.swarmsHealth, online {
                            let bridgeTag = h.bridgeVersion.map { " · Bridge \($0)" } ?? ""
                            Text("Swarms v\(h.swarmsVersion)\(bridgeTag) · 127.0.0.1:8765 · Uptime \(Int(h.uptimeSeconds))s · \(h.totalRuns) çalışma")
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            Text("Swarms Daemon (127.0.0.1:8765) kontrol ediliyor veya çevrimdışı")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !swarmFeedback.isEmpty {
                            Text("· \(swarmFeedback)")
                                .font(.caption2)
                                .foregroundStyle(.teal)
                                .lineLimit(1)
                        }
                        Spacer()
                        if engine.isCheckingSwarms {
                            ProgressView().controlSize(.small)
                        }
                        Button("Modelleri Dengele") {
                            swarmFeedback = engine.rebalanceAgentsToHealthyProviders()
                        }
                        .liquidGlassButton(prominent: false)
                        .controlSize(.small)

                        Button("Yenile") {
                            Task { await engine.refreshSwarmsStatus() }
                        }
                        .liquidGlassButton(prominent: false)
                        .controlSize(.small)

                        Button(engine.swarmsHealth?.isHealthy == true ? "Yeniden Başlat" : "Daemon Başlat") {
                            Task {
                                let res = await engine.restartSwarmsDaemon()
                                swarmFeedback = res.1
                            }
                        }
                        .liquidGlassButton(prominent: false, tint: .teal)
                        .controlSize(.small)
                        .disabled(engine.isCheckingSwarms)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlassCard(cornerRadius: 12, tint: engine.swarmsHealth?.isHealthy == true ? .teal : .orange)

                    RequestPipelineStripView()

                    TextEditor(text: $goal)
                        .font(.system(size: 13))
                        .frame(height: 98)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LiquidGlassContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                Button("🔍 Mimari İnceleme") {
                                    mode = .debate
                                    goal = "Aktif projedeki mimari darboğazları, bağımlılıkları ve teknik borçları inceleyip önceliklendirilmiş iyileştirme planı çıkarın."
                                }.liquidGlassButton(prominent: false).controlSize(.small)

                                Button("🛡️ Güvenlik & Swift Audit") {
                                    mode = .projectSprint
                                    goal = "Projeyi @MainActor izolasyonu, bellek sızıntıları, kabuk enjeksiyonu ve hata yönetimi açısından denetleyin, bulduğunuz hataları yamalayın ve build ile doğrulayın."
                                }.liquidGlassButton(prominent: false).controlSize(.small)

                                Button("🧪 Test & Build Sprinti") {
                                    mode = .projectSprint
                                    goal = "Kritik modüllerdeki eksik birim testlerini belirleyip ekleyin, test ve derleme doğrulamasının hatasız geçtiğini kanıtlayın."
                                }.liquidGlassButton(prominent: false).controlSize(.small)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Mod", selection: $mode) {
                                ForEach(PipelineMode.allCases) { m in Text(m.rawValue).tag(m) }
                            }
                            .frame(maxWidth: 340)

                            if mode == .swarms {
                                Picker("Topoloji", selection: $swarmTopology) {
                                    ForEach(SwarmsTopology.allCases) { t in
                                        Text(t.displayName).tag(t)
                                    }
                                }
                                .frame(maxWidth: 280)

                                Stepper("Tur: \(swarmMaxLoops)", value: $swarmMaxLoops, in: 1...4)
                                    .frame(width: 105)
                            } else if mode == .debate {
                                Stepper("Tur: \(rounds)", value: $rounds, in: 2...4)
                                    .frame(width: 110)
                            }

                            Spacer()

                            if engine.isRunningPipeline {
                                Button(role: .destructive) {
                                    engine.cancelPipeline()
                                } label: {
                                    Label("Durdur", systemImage: "stop.circle.fill")
                                }
                                .liquidGlassButton(prominent: true, tint: .red)
                            } else {
                                let notEnoughAgents = (mode == .debate && selected.count < 2)
                                    || (mode == .swarms && selected.count < swarmTopology.minAgents)
                                Button("Başlat") {
                                    let ids = engine.agents.filter { selected.contains($0.id) }.map { $0.id }
                                    engine.runOfficePipeline(
                                        goal: goal,
                                        participantIds: ids,
                                        mode: mode,
                                        debateRounds: rounds,
                                        swarmTopology: swarmTopology,
                                        swarmMaxLoops: swarmMaxLoops,
                                        rearrangeFlow: rearrangeFlow
                                    )
                                }
                                .liquidGlassButton(prominent: true, tint: .indigo)
                                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty || notEnoughAgents)
                            }
                        }

                        if mode == .swarms && swarmTopology == .agentRearrange {
                            TextField("Özel Akış Grafı (örn: Atlas -> Kodcu -> Denetçi)", text: $rearrangeFlow)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }

                        if mode == .debate && selected.count < 2 {
                            Text("⚠️ Canlı Tartışma (Çok Turlu) modu için aşağıdan en az 2 ajan seçin.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if mode == .swarms && selected.count < swarmTopology.minAgents {
                            Text("⚠️ \(swarmTopology.rawValue) topolojisi için en az \(swarmTopology.minAgents) ajan seçin.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if mode == .swarms {
                            Text(swarmTopology.summary).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 16, tint: .indigo)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225))], spacing: 10) {
                        ForEach(engine.agents) { a in
                            let on = selected.contains(a.id)
                            let prov = engine.provider(for: a.providerId)
                            let ready = prov?.isConfigured ?? false
                            Button {
                                if on { selected.remove(a.id) } else { selected.insert(a.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    AgentAvatarView(agent: a, size: 32, showStatusDot: false)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(a.emoji) \(a.name)").bold().font(.subheadline)
                                        Text(a.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        HStack(spacing: 4) {
                                            Circle().fill(ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                                            Text("\(prov?.name ?? "API") · \(a.modelId)")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(on ? Color(hex: a.accentHex) : .secondary)
                                }
                                .padding(10)
                                .liquidGlassCard(cornerRadius: 14, tint: on ? Color(hex: a.accentHex) : nil, interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if engine.isRunningPipeline || !engine.pipelineStatusText.isEmpty {
                        HStack(spacing: 8) {
                            if engine.isRunningPipeline { ProgressView().controlSize(.small) }
                            Text(engine.pipelineStatusText).font(.callout.weight(.medium))
                            Spacer()
                            if let bv = engine.lastBuildVerification {
                                Text(bv.summary)
                                    .font(.caption.bold())
                                    .foregroundStyle(bv.passed ? .green : .orange)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .liquidGlassCapsule(tint: bv.passed ? .green : .orange, interactive: false)
                            }
                        }
                        .padding(12)
                        .liquidGlassCard(cornerRadius: 14, tint: engine.isRunningPipeline ? .accentColor : nil)
                    }

                    ForEach(Array(engine.lastPipelineOutputs.enumerated()), id: \.offset) { idx, item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(idx + 1). \(item.agentName) — \(item.title)").font(.headline)
                                Spacer()
                                Text(item.model)
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .liquidGlassCapsule(interactive: false)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.output, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc").font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            Divider()
                            MarkdownMessageView(text: item.output, baseFontSize: 13)
                                .textSelection(.enabled)
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 16)
                        .id("\(idx)-\(item.agentName)-\(item.title)")
                    }
                }.padding(22)
            }
        }
        .onAppear {
            if selected.isEmpty { selected = Set(engine.agents.prefix(4).map { $0.id }) }
        }
        .onChange(of: engine.agents.map(\.id)) { _, newIds in
            let valid = Set(newIds)
            selected = selected.intersection(valid)
            if selected.isEmpty { selected = Set(newIds.prefix(4)) }
        }
    }
}

struct ActivityLogView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var levelFilter: LogLevel? = nil
    @State private var searchQuery: String = ""
    @State private var agentFilter: String = ""

    private var filteredLogs: [ActivityLogEntry] {
        engine.logs.filter { entry in
            let matchesLevel = (levelFilter == nil || entry.level == levelFilter)
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery = q.isEmpty
                || entry.source.localizedCaseInsensitiveContains(q)
                || entry.message.localizedCaseInsensitiveContains(q)
            let matchesAgent = agentFilter.isEmpty || entry.source == agentFilter
            return matchesLevel && matchesQuery && matchesAgent
        }
    }

    private var uniqueAgents: [String] {
        Array(Set(engine.logs.map { $0.source })).sorted()
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .tool: return .purple
        case .evolve: return .cyan
        }
    }

    private func exportLogs(format: ExportFormat) {
        let logs = filteredLogs
        guard !logs.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        let ts = Self.exportFilenameFormatter.string(from: Date())
        panel.nameFieldStringValue = "activity_log_\(ts).\(format.fileExtension)"
        panel.title = "Aktivite Günlüğünü Dışa Aktar (\(format.rawValue.uppercased()))"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let content = format == .csv ? generateCSV(logs) : generateJSON(logs)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Export failed: \(error)")
            }
        }
    }

    private static let exportFilenameFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df
    }()

    private func generateCSV(_ logs: [ActivityLogEntry]) -> String {
        var lines = ["timestamp,level,source,message"]
        let formatter = ISO8601DateTimeFormatter()
        func csvEscape(_ raw: String) -> String {
            var s = raw
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            if let first = s.first, ["=", "+", "-", "@"].contains(first) {
                s = "'" + s
            }
            return s
        }
        for entry in logs {
            let timestamp = formatter.string(from: entry.timestamp)
            lines.append("\"\(timestamp)\",\"\(entry.level.rawValue)\",\"\(csvEscape(entry.source))\",\"\(csvEscape(entry.message))\"")
        }
        return lines.joined(separator: "\n")
    }

    private func generateJSON(_ logs: [ActivityLogEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try? encoder.encode(logs)
        return String(data: data ?? Data(), encoding: .utf8) ?? "[]"
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .blue)
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack {
                        Label("Aktivite Günlüğü (\(filteredLogs.count)/\(engine.logs.count))", systemImage: "terminal.fill")
                            .font(.headline)
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                            TextField("Loglarda ara...", text: $searchQuery)
                                .textFieldStyle(.plain)
                                .font(.caption)
                                .frame(width: 170)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .liquidGlassCard(cornerRadius: 9)

                        if !uniqueAgents.isEmpty {
                            Menu {
                                Button("Tümü") { agentFilter = "" }
                                Divider()
                                ForEach(uniqueAgents, id: \.self) { agent in
                                    Button(agent) { agentFilter = agent }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.2.fill").font(.caption)
                                    Text(agentFilter.isEmpty ? "Ajan" : agentFilter)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                            }
                            .liquidGlassCard(cornerRadius: 9)
                            .menuStyle(.borderlessButton)
                        }

                        Button("Kopyala") {
                            let dump = filteredLogs.map { "[\($0.level.rawValue)] \($0.source): \($0.message)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dump, forType: .string)
                        }
                        .liquidGlassButton(prominent: false)
                        .controlSize(.small)
                        .disabled(filteredLogs.isEmpty)

                        Menu {
                            Button("CSV") { exportLogs(format: .csv) }
                            Button("JSON") { exportLogs(format: .json) }
                        } label: {
                            Label("Dışa Aktar", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .liquidGlassButton(prominent: false)
                        .controlSize(.small)
                        .disabled(filteredLogs.isEmpty)
                        .menuStyle(.borderlessButton)

                        Button("Temizle") {
                            engine.logs.removeAll()
                        }
                        .liquidGlassButton(prominent: false, tint: .red)
                        .controlSize(.small)
                        .disabled(engine.logs.isEmpty)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LiquidGlassContainer(spacing: 6) {
                            HStack(spacing: 6) {
                                Button { levelFilter = nil } label: {
                                    Text("Tümü").font(.system(size: 10, weight: levelFilter == nil ? .bold : .regular))
                                        .padding(.horizontal, 9).padding(.vertical, 3.5)
                                        .liquidGlassCapsule(tint: levelFilter == nil ? .accentColor : nil, interactive: true)
                                }.buttonStyle(.plain)

                                ForEach([LogLevel.info, .success, .warning, .error, .tool, .evolve], id: \.self) { lvl in
                                    let on = levelFilter == lvl
                                    Button { levelFilter = on ? nil : lvl } label: {
                                        Text(lvl.rawValue)
                                            .font(.system(size: 10, weight: on ? .bold : .regular))
                                            .padding(.horizontal, 9).padding(.vertical, 3.5)
                                            .liquidGlassCapsule(tint: on ? levelColor(lvl) : nil, interactive: true)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .liquidGlassBar()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredLogs) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(e.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(e.level.rawValue)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .liquidGlassCapsule(tint: levelColor(e.level), interactive: false)
                                    .foregroundStyle(levelColor(e.level))
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(e.source)
                                    .font(.caption.bold())
                                    .frame(width: 115, alignment: .leading)
                                Text(e.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .liquidGlassCard(cornerRadius: 10, tint: e.level == .error || e.level == .warning ? levelColor(e.level) : nil)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

private enum ExportFormat: String, CaseIterable {
    case csv, json
    var fileExtension: String { rawValue }
    var utType: UTType { rawValue == "csv" ? .commaSeparatedText : .json }
}

private struct ISO8601DateTimeFormatter {
    private let formatter = ISO8601DateFormatter()
    func string(from date: Date) -> String { formatter.string(from: date) }
}
