import SwiftUI
import AppKit

enum AppSection: String, CaseIterable, Identifiable {
    case office = "Sanal Ofis"
    case openClawHub = "OpenClaw · Maliyet · Cron"
    case swarmTasks = "Çoklu Ajan & Swarms"
    case connectors = "Connectorlar & GitHub"
    case workspace = "OpenClaw · AGENTS.md · Skiller"
    case powerTools = "Power Stack & Graphify"
    case evolution = "Öz-Gelişim & Build"
    case providers = "API Sağlayıcıları"
    case logs = "Aktivite Günlüğü"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .office: return "building.2.crop.circle.fill"
        case .openClawHub: return "gauge.with.dots.needle.67percent"
        case .swarmTasks: return "person.3.sequence.fill"
        case .connectors: return "puzzlepiece.extension.fill"
        case .workspace: return "brain.head.profile"
        case .powerTools: return "bolt.shield.fill"
        case .evolution: return "hammer.circle.fill"
        case .providers: return "key.horizontal.fill"
        case .logs: return "terminal.fill"
        }
    }
}

struct MainContentView: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.openWindow) private var openWindow
    @State private var section: AppSection = .office
    @State private var showAddAgent = false
    @State private var showResetOfficeConfirm = false

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: Color(hex: engine.selectedAgent?.accentHex ?? "#38BDF8"))

            NavigationSplitView {
                List(selection: $section) {
                    Section {
                        ForEach(AppSection.allCases) { s in
                            HStack(spacing: 6) {
                                Label(s.rawValue, systemImage: s.icon)
                                    .font(.callout.weight(section == s ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .tag(s)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            CrimsBrandLogoView(size: 20)
                            Text("Crims Office Studio")
                                .font(.caption.bold())
                        }
                        .padding(.leading, 6)
                    }
                    Section {
                        ForEach(engine.agents) { a in
                            let isSelected = engine.selectedAgentId == a.id
                            let dotColor: Color = {
                                switch a.status {
                                case .idle: return .green
                                case .chatting: return .teal
                                case .thinking: return .cyan
                                case .working: return .purple
                                case .runningTool: return .orange
                                case .collaborating: return .blue
                                case .improving: return .mint
                                case .error: return .red
                                }
                            }()
                            let shortModel = a.modelId.components(separatedBy: "/").last ?? a.modelId
                            HStack(spacing: 8) {
                                AgentAvatarView(
                                    agent: a,
                                    size: 32,
                                    showStatusDot: true,
                                    isSelected: isSelected,
                                    mode: .compactBadge
                                )

                                VStack(alignment: .leading, spacing: 1.5) {
                                    HStack(spacing: 4) {
                                        Text(a.name)
                                            .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .rounded))
                                            .lineLimit(1)
                                        Circle()
                                            .fill(dotColor)
                                            .frame(width: 6, height: 6)
                                            .shadow(color: dotColor.opacity(0.7), radius: 2.5)
                                    }
                                    Text(a.title)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(shortModel)
                                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color(hex: a.accentHex).opacity(0.92))
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 2)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(
                                        isSelected
                                            ? Color(hex: a.accentHex).opacity(0.18)
                                            : Color.white.opacity(0.05)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(
                                        isSelected
                                            ? Color(hex: a.accentHex).opacity(0.55)
                                            : Color.white.opacity(0.10),
                                        lineWidth: isSelected ? 1.1 : 0.7
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .onTapGesture { engine.selectedAgentId = a.id; section = .office }
                        }

                        VStack(spacing: 6) {
                            Button { showAddAgent = true } label: {
                                HStack {
                                    Spacer()
                                    Text("Yeni Ajan Ekle")
                                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .bold))
                                    Spacer()
                                }
                                .padding(.vertical, 7)
                                .liquidGlassCard(cornerRadius: 10, tint: .cyan, interactive: true)
                            }
                            .buttonStyle(.plain)

                            if engine.agents.count > 1 {
                                Button {
                                    showResetOfficeConfirm = true
                                } label: {
                                    HStack {
                                        Spacer()
                                        Text("Ofisi Sıfırla")
                                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 10.5, weight: .bold))
                                        Spacer()
                                    }
                                    .padding(.vertical, 7)
                                    .liquidGlassCard(cornerRadius: 10, tint: nil, interactive: true)
                                }
                                .buttonStyle(.plain)
                                .help("Ofisi 1 kişilik başlangıç kadrosuna sıfırla (Atlas)")
                            }
                        }
                        .padding(.top, 6)
                    } header: {
                        Text("Ajan Ekibi (\(engine.agents.count))")
                            .padding(.leading, 8)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 225, ideal: 245, max: 280)
            } detail: {
                ZStack {
                    switch section {
                    case .office:
                        OfficeFloorView()
                    case .openClawHub:
                        OpenClawControlCenterView()
                    case .swarmTasks:
                        MultiAgentTaskView()
                    case .connectors:
                        ConnectorsAndHubView()
                    case .workspace:
                        WorkspaceAndSkillsView()
                    case .powerTools:
                        PowerToolsAndGraphView()
                    case .evolution:
                        EvolutionAndProjectView()
                    case .providers:
                        ProvidersSettingsView()
                    case .logs:
                        ActivityLogView()
                    }
                }
                .background(.clear)
            }
        }
        .onAppear {
            ClawOfficeAppDelegate.shared?.reopenMainWindow = {
                openWindow(id: "main")
            }
        }
        .onChange(of: engine.requestedSectionRawValue) { _, targetRaw in
            if let raw = targetRaw, let target = AppSection(rawValue: raw) {
                section = target
                engine.requestedSectionRawValue = nil
            }
        }
        .sheet(isPresented: $showAddAgent) {
            AddAgentSheet().environmentObject(engine)
        }
        .confirmationDialog("Ofis 1 Kişilik Başlangıç Kadrosuna Sıfırlansın mı?", isPresented: $showResetOfficeConfirm, titleVisibility: .visible) {
            Button("Sıfırla (Sadece Atlas)", role: .destructive) {
                engine.resetToSingleAgentOffice()
            }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Atlas dışındaki tüm ajanlar, sohbet geçmişleri ve canlı ofis akışı kaldırılacaktır.")
        }
    }
}

struct AddAgentSheet: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var title = ""
    @State private var emoji = "🤖"
    @State private var avatarAsset = OfficeAvatarPreset.defaultAsset(forIndex: 0)
    @State private var hex = "#E11D48"
    @State private var providerId = UUID()
    @State private var modelId = ""
    @State private var useAutoModel = true
    @State private var routeHintText = ""
    @State private var temperature = 0.25
    @State private var prompt = "Sen uzman bir yapay zeka ajanısın."
    @State private var formError = ""

    private let palette = ["#38BDF8", "#A855F7", "#10B981", "#F59E0B", "#EC4899", "#6366F1", "#14B8A6", "#EF4444"]

    private var selectableProviders: [APIProviderConfig] {
        let active = engine.providers.filter { $0.kind != .antigravityCLI && $0.isEnabled }
        return active.isEmpty ? engine.providers.filter { $0.kind != .antigravityCLI } : active
    }

    private var currentProvider: APIProviderConfig? {
        engine.provider(for: providerId) ?? selectableProviders.first ?? engine.providers.first
    }

    private func applySmartRecommendation() {
        let decision = engine.recommendedHireRoute(
            name: name.isEmpty ? "YeniAjan" : name,
            title: title.isEmpty ? "Uzman Mühendis" : title,
            prompt: prompt,
            requestedModel: "auto"
        )
        providerId = decision.provider.id
        modelId = decision.modelId
        routeHintText = decision.reason
    }

    private func resolveModelSelection(preferredKeyword: String, provider: APIProviderConfig) -> String {
        let models = provider.models
        guard !models.isEmpty else {
            return provider.defaultModel
        }

        let normalizedKeyword = preferredKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1) Exact model id match preserving provider's original casing (e.g. "Kilo-Auto/free" or "kilo-auto/free").
        if let exactMatch = models.first(where: { $0.lowercased() == normalizedKeyword }) {
            return exactMatch
        }

        // 2) Family / keyword match (e.g. "deepseek", "qwen", "gemini", "claude").
        if !normalizedKeyword.isEmpty,
           let match = models.first(where: { $0.lowercased().contains(normalizedKeyword) }) {
            return match
        }

        // 3) Provider default, then first available model.
        if !provider.defaultModel.isEmpty, models.contains(provider.defaultModel) {
            return provider.defaultModel
        }
        return models.first ?? provider.defaultModel
    }

    private func deriveModelKeyword(from model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("hydrogen") { return "hydrogen" }
        if lower.contains("gemini") { return "gemini" }
        if lower.contains("claude") { return "claude" }
        if lower.contains("deepseek") { return "deepseek" }
        if lower.contains("qwen") { return "qwen" }
        if lower.contains("gemma") { return "gemma" }
        if lower.contains("glm") { return "glm" }
        if lower.contains("gpt") || lower.contains("openai") { return "gpt" }
        if lower.contains("kilo-auto") { return "kilo-auto" }
        if lower.contains("auto") { return "auto" }
        return lower.split(separator: "/").last.map(String.init) ?? "deepseek"
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: Color(hex: hex))
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    GlassSectionHeader(
                        title: "Yeni Ajan Ekle",
                        subtitle: currentProvider?.name ?? "Sağlayıcı Seçin",
                        systemImage: "person.badge.plus.fill",
                        tint: Color(hex: hex)
                    )
                    Spacer()
                }

                // Quick Role Templates
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Gelişmiş Ajan Şablonları").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Mevcut Tanımı Şablon Kaydet") {
                            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleanName.isEmpty {
                                let t = AgentRoleTemplate(
                                    name: cleanName,
                                    title: cleanTitle.isEmpty ? "Uzman Ajan" : cleanTitle,
                                    emoji: emoji.isEmpty ? "⚡️" : emoji,
                                    accentHex: hex,
                                    prompt: prompt,
                                    defaultModelKeyword: deriveModelKeyword(from: modelId),
                                    isCustom: true
                                )
                                engine.addRoleTemplate(t)
                            }
                        }
                        .font(.caption)
                        .liquidGlassButton(prominent: false)
                        .controlSize(.mini)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LiquidGlassContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(engine.roleTemplates) { t in
                                    HStack(spacing: 4) {
                                        Button {
                                            name = t.name
                                            title = t.title
                                            emoji = t.emoji
                                            hex = t.accentHex
                                            prompt = t.prompt
                                            formError = ""
                                            useAutoModel = true
                                            applySmartRecommendation()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(t.emoji)
                                                Text(t.name).font(.caption.bold())
                                                if t.isCustom {
                                                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)

                                        if t.isCustom {
                                            Button {
                                                engine.deleteRoleTemplate(id: t.id)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Özel şablonu sil")
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .liquidGlassCapsule(tint: Color(hex: t.accentHex), interactive: true)
                                }
                            }
                        }
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("Emoji", text: $emoji).frame(width: 48).textFieldStyle(.roundedBorder)
                            TextField("Ad", text: $name).textFieldStyle(.roundedBorder)
                            TextField("Rol / Ünvan", text: $title).textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 10) {
                            let availableProvs = selectableProviders
                            let validProviderId = availableProvs.contains(where: { $0.id == providerId })
                                ? providerId
                                : (availableProvs.first?.id ?? providerId)
                            Picker("API Sağlayıcı", selection: Binding(
                                get: { validProviderId },
                                set: { newId in
                                    useAutoModel = false
                                    routeHintText = ""
                                    providerId = newId
                                    if let p = engine.provider(for: newId) {
                                        let kw = deriveModelKeyword(from: modelId)
                                        let resolved = resolveModelSelection(preferredKeyword: kw, provider: p)
                                        modelId = resolved
                                    }
                                }
                            )) {
                                ForEach(availableProvs) { p in
                                    Text("\(p.name)\(p.isConfigured ? " (Aktif)" : "")").tag(p.id)
                                }
                            }

                            HStack(spacing: 5) {
                                ForEach(palette, id: \.self) { cHex in
                                    Circle()
                                        .fill(Color(hex: cHex))
                                        .frame(width: 15, height: 15)
                                        .overlay(Circle().stroke(Color.white, lineWidth: hex == cHex ? 2 : 0))
                                        .scaleEffect(hex == cHex ? 1.15 : 1.0)
                                        .onTapGesture { hex = cHex }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Model ID").font(.caption.weight(.medium))
                                Button {
                                    useAutoModel = true
                                    applySmartRecommendation()
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "sparkles").font(.system(size: 9))
                                        Text(useAutoModel ? "Akıllı Seçim Açık" : "Rol+Çeşitlilik Öner")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .liquidGlassCapsule(tint: useAutoModel ? .mint : .blue, interactive: true)
                                }
                                .buttonStyle(.plain)
                                .help("Ekip dağılımı, sağlayıcı sağlığı ve role göre en uygun farklı modeli otomatik seç")
                                Spacer()
                                Text("Yaratıcılık: \(String(format: "%.2f", temperature))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Slider(value: $temperature, in: 0.0...1.0, step: 0.05)
                                    .frame(width: 90)

                                if let prov = currentProvider, !prov.uniqueModels.isEmpty {
                                    let allModels = prov.uniqueModels
                                    let freeModels = allModels.filter { $0.contains(":free") || $0.contains("/free") || $0.lowercased().contains("free") }
                                    let regularModels = allModels.filter { !freeModels.contains($0) }

                                    Menu {
                                        if !freeModels.isEmpty {
                                            Section("🎁 Ücretsiz Modeller") {
                                                ForEach(freeModels, id: \.self) { m in
                                                    Button("🎁 " + m) {
                                                        useAutoModel = false
                                                        routeHintText = ""
                                                        modelId = m
                                                    }
                                                }
                                            }
                                        }
                                        if !regularModels.isEmpty {
                                            Section("Standart & Diğer Modeller") {
                                                ForEach(regularModels, id: \.self) { m in
                                                    Button(m) {
                                                        useAutoModel = false
                                                        routeHintText = ""
                                                        modelId = m
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Listeden Seç", systemImage: "list.bullet.rectangle.portrait.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }

                            TextField("Model ID (otomatik atanır, seçin veya yazın)", text: $modelId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            if !routeHintText.isEmpty {
                                Text("🤖 \(routeHintText)")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.mint)
                                    .lineLimit(1)
                            }

                            let crossSuggestions = engine.suggestedModelCandidates(name: name, title: title, prompt: prompt, limit: 6)
                            if !crossSuggestions.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Tüm Sağlayıcılardan Önerilen Çeşitli Modeller:")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 5) {
                                            ForEach(crossSuggestions) { sug in
                                                let isSel = (providerId == sug.provider.id && modelId == sug.modelId)
                                                Button {
                                                    useAutoModel = false
                                                    routeHintText = sug.note
                                                    providerId = sug.provider.id
                                                    modelId = sug.modelId
                                                } label: {
                                                    HStack(spacing: 4) {
                                                        Text(sug.provider.name.components(separatedBy: " ").first ?? sug.provider.name)
                                                            .font(.system(size: 8.5, weight: .bold))
                                                            .foregroundStyle(Color(hex: sug.provider.kind.accentHex))
                                                        Text(sug.modelId.components(separatedBy: "/").last ?? sug.modelId)
                                                            .font(.system(size: 10, weight: isSel ? .bold : .regular, design: .monospaced))
                                                    }
                                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                                    .liquidGlassCapsule(tint: isSel ? .mint : Color(hex: sug.provider.kind.accentHex).opacity(0.65), interactive: true)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }

                            if let prov = currentProvider, !prov.uniqueModels.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(prov.uniqueModels.prefix(16), id: \.self) { m in
                                            let isSelected = modelId == m
                                            let isFree = m.contains(":free") || m.contains("/free")
                                            Button {
                                                useAutoModel = false
                                                routeHintText = ""
                                                modelId = m
                                            } label: {
                                                HStack(spacing: 3) {
                                                    if isFree { Text("🎁").font(.system(size: 8)) }
                                                    Text(m.components(separatedBy: "/").last ?? m)
                                                        .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .monospaced))
                                                }
                                                .padding(.horizontal, 8).padding(.vertical, 3.5)
                                                .liquidGlassCapsule(tint: isSelected ? .accentColor : nil, interactive: true)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        TextEditor(text: $prompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 82)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        BikiniAvatarPickerStrip(selectedAsset: $avatarAsset, accentHex: hex)
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 14)
                }

                if !formError.isEmpty {
                    Text(formError).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("İptal") { dismiss() }
                        .liquidGlassButton(prominent: false)
                    Button("Ajanı Ekle") {
                        let resolvedProvId = engine.providers.contains(where: { $0.id == providerId })
                            ? providerId
                            : (currentProvider?.id ?? providerId)
                        let finalModel = modelId.isEmpty ? (currentProvider?.defaultModel ?? "auto") : modelId
                        let res = engine.addAgent(name: name, title: title, emoji: emoji, accentHex: hex, providerId: resolvedProvId, modelId: finalModel, systemPrompt: prompt, temperature: temperature, avatarAsset: avatarAsset)
                        if res.0 {
                            dismiss()
                        } else {
                            formError = res.1
                        }
                    }
                    .liquidGlassButton(prominent: true, tint: Color(hex: hex))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
        }
        .frame(minWidth: 560, minHeight: 590, idealHeight: 670)
        .onChange(of: title) { _, _ in
            if useAutoModel { applySmartRecommendation() }
        }
        .onAppear {
            avatarAsset = OfficeAvatarPreset.defaultAsset(forIndex: engine.agents.count)
            applySmartRecommendation()
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.openWindow) private var openWindow
    @State private var quick = ""

    var body: some View {
        let selectedAgent = engine.selectedAgent
        let selectedBusy = selectedAgent?.status.isBusy ?? false
        ZStack {
            AmbientGlassBackdrop(accent: Color(hex: selectedAgent?.accentHex ?? "#38BDF8"))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CrimsBrandLogoView(size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Crims Office v4").font(.headline)
                        if let ag = selectedAgent {
                            Text("\(ag.emoji) \(ag.name) · \(ag.status.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(engine.cavemanMode == .off ? "Normal" : "Caveman")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .liquidGlassCapsule(tint: engine.cavemanMode == .off ? nil : .yellow, interactive: false)
                }
                HStack {
                    TextField(selectedBusy ? "\(selectedAgent?.name ?? "Ajan") çalışıyor..." : "Seçili ajana hızlı görev...", text: $quick)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .liquidGlassCard(cornerRadius: 10)
                        .disabled(selectedBusy || selectedAgent == nil)
                        .onSubmit {
                            guard !selectedBusy, let id = selectedAgent?.id else { return }
                            let t = quick.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty {
                                engine.sendMessage(to: id, text: t)
                                quick = ""
                            }
                        }
                    if selectedBusy, let active = selectedAgent {
                        Button("Durdur") {
                            engine.cancelTask(for: active.id)
                        }
                        .liquidGlassButton(prominent: true, tint: .red)
                        .controlSize(.small)
                        .accessibilityLabel("Aktif görevi durdur")
                    } else {
                        Button("Gönder") {
                            let t = quick.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty, let id = selectedAgent?.id {
                                engine.sendMessage(to: id, text: t)
                                quick = ""
                            }
                        }
                        .liquidGlassButton(prominent: true)
                        .controlSize(.small)
                        .disabled(quick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAgent == nil)
                    }
                }
                HStack {
                    Button("Pencereyi Aç") {
                        ClawOfficeAppDelegate.shared?.showMainWindow {
                            openWindow(id: "main")
                        }
                    }
                    .liquidGlassButton(prominent: false)
                    .controlSize(.small)
                    Spacer()
                    Button("Çıkış") { NSApp.terminate(nil) }
                        .liquidGlassButton(prominent: false, tint: .red)
                        .controlSize(.small)
                }
            }
            .padding(14)
        }
        .frame(width: 315)
    }
}
