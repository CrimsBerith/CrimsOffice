import SwiftUI
import AppKit

struct ToolCallBadgeView: View {
    let call: ToolCallRecord
    @State private var isExpanded = false

    var toolIcon: String {
        switch call.name {
        case "list_dir", "find_by_name", "find_files", "glob": return "folder.fill"
        case "read_file", "view_file": return "doc.text.fill"
        case "grep_search", "search_code": return "magnifyingglass"
        case "write_file", "patch_file", "multi_patch", "write_to_file", "replace_file_content", "multi_replace_file_content": return "pencil.and.outline"
        case "git_status", "git_diff": return "arrow.triangle.branch"
        case "build_gate": return "hammer.fill"
        case "shell", "run_command": return "terminal.fill"
        case "hire_agent": return "person.badge.plus.fill"
        case "delegate", "assign_task": return "arrow.right.circle.fill"
        case "dismiss_agent": return "person.badge.minus"
        case "graphify_query", "graphify_update", "graphify_path": return "point.3.connected.trianglepath.dotted"
        case "system_info": return "cpu.fill"
        case "open_app": return "macwindow"
        case "open_path": return "folder.badge.gearshape"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    var accentColor: Color {
        switch call.name {
        case "hire_agent", "delegate", "assign_task": return .purple
        case "write_file", "patch_file", "multi_patch", "write_to_file", "replace_file_content", "multi_replace_file_content": return .green
        case "shell", "run_command", "system_info", "build_gate": return .orange
        case "read_file", "view_file", "list_dir", "grep_search", "search_code", "find_by_name", "find_files", "glob", "git_status", "git_diff": return .blue
        case "graphify_query", "graphify_update": return .cyan
        default: return .secondary
        }
    }

    var body: some View {
        let effectiveColor = call.succeeded ? accentColor : Color.red
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if !call.output.isEmpty {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: call.succeeded ? toolIcon : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(effectiveColor)
                    Text(call.name)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !call.argument.isEmpty && call.argument != "." {
                        Text(call.argument)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: call.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(call.succeeded ? Color.green.opacity(0.85) : Color.red)
                    if !call.output.isEmpty {
                        HStack(spacing: 3) {
                            Text(isExpanded ? "Gizle" : "Çıktı")
                                .font(.system(size: 9, weight: .medium))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .liquidGlassCard(cornerRadius: 10, tint: effectiveColor, interactive: !call.output.isEmpty)
            }
            .buttonStyle(.plain)

            if isExpanded && !call.output.isEmpty {
                SmokedGlassSurface(cornerRadius: 10) {
                    VStack(spacing: 0) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.red.opacity(0.85)).frame(width: 7, height: 7)
                            Circle().fill(Color.yellow.opacity(0.85)).frame(width: 7, height: 7)
                            Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7)
                            Text("Terminal Çıktısı · \(call.name)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.70))
                                .padding(.leading, 4)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(call.output, forType: .string)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.on.doc").font(.system(size: 8))
                                    Text("Kopyala").font(.system(size: 8))
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .foregroundStyle(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.white.opacity(0.05))

                        Divider().background(Color.white.opacity(0.1))

                        ScrollView {
                            Text(call.output)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 185)
                        .foregroundStyle(Color(red: 0.48, green: 0.94, blue: 0.60))
                    }
                }
            }
        }
    }
}

struct ChatMessageBubbleView: View {
    let msg: ChatMessage
    let agent: OfficeAgent
    @State private var isExpanded = false

    private var isSummary: Bool {
        ContextCompactor.isSummaryMessage(msg)
    }

    private var isLongMessage: Bool {
        let nl = msg.content.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        return msg.content.count > 420 || nl >= 7
    }

    var body: some View {
        VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 6) {
            if isSummary {
                summaryCollapsibleCard
            } else {
                // Deep Reasoning Box (if available)
                if let r = msg.reasoning, !r.isEmpty {
                    DisclosureGroup {
                        ScrollView {
                            Text(r)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 220)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    } label: {
                        Label("Derin Akıl Yürütme (\(r.count) karakter)", systemImage: "brain.head.profile")
                            .font(.caption.bold())
                            .foregroundStyle(.purple)
                    }
                    .padding(.vertical, 2)
                }

                // Interactive Tool Execution Badges
                if !msg.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(msg.toolCalls) { call in
                            ToolCallBadgeView(call: call)
                        }
                    }
                }

                // Main Message Content
                let clean = PowerShellTools.stripToolTags(from: msg.content)
                let rawDisplay = clean.isEmpty
                    ? (msg.content.isEmpty ? "Yanıt üretiliyor..." : (msg.toolCalls.isEmpty ? msg.content : "⚡️ *Araç adımları tamamlandı.*"))
                    : clean
                let clippedDisplay: String = {
                    guard isLongMessage && !isExpanded else { return rawDisplay }
                    let lines = rawDisplay.components(separatedBy: "\n")
                    let headLines = Array(lines.prefix(5)).joined(separator: "\n")
                    if headLines.count > 320 {
                        return String(headLines.prefix(320)) + "…"
                    }
                    return headLines + (lines.count > 5 ? "\n…" : "")
                }()

                messageBubbleContent(displayText: clippedDisplay, fullLength: rawDisplay.count)

                // Assistant Footer Metadata
                if msg.role != "user", let m = msg.modelUsed {
                    HStack(spacing: 6) {
                        if msg.usedFallback {
                            Text("⚡️ Devraldı: \(m)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .liquidGlassCapsule(tint: .orange, interactive: false)
                        } else {
                            Text("\(msg.providerName ?? "") · \(m)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if let ms = msg.latencyMs {
                            Text("· \(ms) ms").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(msg.content, forType: .string)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc").font(.system(size: 9))
                                Text("Kopyala").font(.system(size: 9))
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: (msg.role == "user" && !isSummary) ? .trailing : .leading)
    }

    private var summaryCollapsibleCard: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(msg.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.compress.vertical").foregroundStyle(.teal)
                Text("Otomatik Bağlam Özeti (\(msg.content.count) kr)")
                    .font(.caption.bold())
                    .foregroundStyle(.teal)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .liquidGlassCard(cornerRadius: 12, tint: .teal, interactive: true)
    }

    @ViewBuilder
    private func messageBubbleContent(displayText: String, fullLength: Int) -> some View {
        let bodyContent = VStack(alignment: .leading, spacing: 6) {
            if isExpanded && isLongMessage {
                ScrollView {
                    MarkdownMessageView(
                        text: displayText,
                        baseFontSize: 13,
                        textColor: msg.role == "user" ? Color.white : Color.primary
                    )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            } else {
                MarkdownMessageView(
                    text: displayText,
                    baseFontSize: 13,
                    textColor: msg.role == "user" ? Color.white : Color.primary
                )
                .textSelection(.enabled)
            }

            if isLongMessage {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                            .font(.system(size: 10))
                        Text(isExpanded ? "Mesajı Daralt" : "Tamamını Göster (\(fullLength) kr)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(msg.role == "user" ? Color.white.opacity(0.92) : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)

        if msg.role == "user" {
            bodyContent
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: agent.accentHex), Color(hex: agent.accentHex).opacity(0.76)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                        )
                        .shadow(color: Color(hex: agent.accentHex).opacity(0.32), radius: 8, y: 3)
                )
        } else {
            bodyContent.liquidGlassCard(cornerRadius: 16, tint: nil, interactive: false)
        }
    }
}

struct AgentInspectorView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var text = ""
    @State private var editingAgent: OfficeAgent? = nil
    @State private var clearConfirmAgentId: UUID? = nil
    @State private var autoFollowBottom = true

    var body: some View {
        directChatBody
            .background(Color.clear)
            .sheet(item: $editingAgent) { target in
                AgentEditSheet(agent: target).environmentObject(engine)
            }
            .confirmationDialog(
                "Sohbet Geçmişini Temizle?",
                isPresented: Binding(
                    get: { clearConfirmAgentId != nil },
                    set: { if !$0 { clearConfirmAgentId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Geçmişi Temizle", role: .destructive) {
                    if let id = clearConfirmAgentId {
                        engine.clearHistory(for: id)
                    }
                    clearConfirmAgentId = nil
                }
                Button("İptal", role: .cancel) { clearConfirmAgentId = nil }
            } message: {
                Text("Bu ajanın tüm mesaj geçmişi ve aktif oturum belleği sıfırlanacaktır.")
            }
    }

    @ViewBuilder
    private var directChatBody: some View {
        if let agent = engine.selectedAgent {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    AgentAvatarView(agent: agent, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(agent.emoji) \(agent.name)").font(.headline)
                        Text("\(agent.title) · \(agent.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        _ = engine.compactAgentHistory(for: agent.id, force: true)
                    } label: { Image(systemName: "rectangle.compress.vertical") }
                        .buttonStyle(.borderless)
                        .disabled(agent.messages.count < 4 || agent.status.isBusy)
                        .help("Sohbet geçmişini akıllıca özetle (Auto-Compact)")
                    Button { editingAgent = agent } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .help("Ajan ayarlarını ve sistem promptunu düzenle")
                    Button { clearConfirmAgentId = agent.id } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(agent.messages.isEmpty && !agent.status.isBusy)
                        .help("Sohbet geçmişini temizle")
                }
                .padding(12).background(.bar)

                Divider()

                HStack(spacing: 8) {
                    let validProviderId = engine.providers.contains(where: { $0.id == agent.providerId })
                        ? agent.providerId
                        : (engine.providers.first?.id ?? agent.providerId)
                    Picker("API", selection: Binding(
                        get: { validProviderId },
                        set: { newId in
                            var u = agent; u.providerId = newId
                            if let p = engine.provider(for: newId) {
                                u.modelId = p.defaultModel.isEmpty ? (p.models.first ?? "") : p.defaultModel
                            }
                            engine.updateAgent(u)
                        }
                    )) {
                        ForEach(engine.providers) { p in Text(p.name).tag(p.id) }
                    }.labelsHidden().frame(minWidth: 155, idealWidth: 185, maxWidth: 215)

                    let models = engine.provider(for: validProviderId)?.uniqueModels ?? []
                    let freeModels = models.filter { $0.contains(":free") || $0.contains("/free") || $0.lowercased().contains("free") }
                    let regularModels = models.filter { !freeModels.contains($0) }

                    Menu {
                        if freeModels.isEmpty && regularModels.isEmpty {
                            Text("Kayıtlı model listesi yok (Düzenle'den ekleyin)")
                        }
                        if !freeModels.isEmpty {
                            Section("🎁 Ücretsiz Modeller") {
                                ForEach(freeModels, id: \.self) { m in
                                    Button("🎁 " + m) { var u = agent; u.modelId = m; engine.updateAgent(u) }
                                }
                            }
                        }
                        if !regularModels.isEmpty {
                            Section("Standart & Diğer Modeller") {
                                ForEach(regularModels, id: \.self) { m in
                                    Button(m) { var u = agent; u.modelId = m; engine.updateAgent(u) }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(agent.modelId).font(.system(.caption, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }.menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(agent.messages) { msg in
                                ChatMessageBubbleView(msg: msg, agent: agent)
                                    .id(msg.id)
                            }
                        }.padding(12)
                    }
                    .onChange(of: agent.messages.count) { _, _ in
                        if autoFollowBottom, let last = agent.messages.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                    .task(id: "\(agent.id.uuidString)-\(agent.messages.last?.content.count ?? 0)") {
                        guard autoFollowBottom, agent.status.isBusy else { return }
                        try? await Task.sleep(nanoseconds: 140_000_000)
                        guard !Task.isCancelled else { return }
                        if let last = agent.messages.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }

                if agent.status.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(agent.statusBubble.isEmpty ? "Çalışıyor..." : agent.statusBubble)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12).padding(.bottom, 4)
                }

                Divider()

                GlassChatInputBar(
                    text: $text,
                    placeholder: "Buraya yaz, \(agent.name) ve ekibi gerekeni yapsın... (↵ Gönder)",
                    isBusy: agent.status.isBusy,
                    accent: Color(hex: agent.accentHex),
                    compact: false,
                    onSend: { prompt in
                        autoFollowBottom = true
                        engine.sendMessage(to: agent.id, text: prompt)
                    },
                    onStop: {
                        engine.cancelTask(for: agent.id)
                    }
                )
                .padding(10)
                .liquidGlassBar()
            }
        } else {
            ContentUnavailableView(
                "Ajan Seçilmedi",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Sanal ofisten bir ajana tıklayın ve doğrudan görev verin.")
            )
        }
    }
}

struct AgentEditSheet: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.dismiss) private var dismiss
    @State var draft: OfficeAgent
    @State private var fallbackText: String
    @State private var showDeleteConfirm = false

    private let palette = ["#38BDF8", "#A855F7", "#10B981", "#F59E0B", "#EC4899", "#6366F1", "#14B8A6", "#EF4444"]

    init(agent: OfficeAgent) {
        _draft = State(initialValue: agent)
        _fallbackText = State(initialValue: agent.fallbackModelIds.joined(separator: ", "))
    }

    private var currentProvider: APIProviderConfig? {
        engine.provider(for: draft.providerId) ?? engine.providers.first
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: Color(hex: draft.accentHex))
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeader(
                    title: "Ajanı Düzenle — \(draft.emoji) \(draft.name)",
                    subtitle: currentProvider?.name ?? "API Sağlayıcı",
                    systemImage: "slider.horizontal.3",
                    tint: Color(hex: draft.accentHex)
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("Emoji", text: $draft.emoji).frame(width: 48).textFieldStyle(.roundedBorder)
                            TextField("Ad", text: $draft.name).textFieldStyle(.roundedBorder)
                            TextField("Rol", text: $draft.title).textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 10) {
                            let validProvId = engine.providers.contains(where: { $0.id == draft.providerId })
                                ? draft.providerId
                                : (engine.providers.first?.id ?? draft.providerId)
                            Picker("API Sağlayıcı", selection: Binding(
                                get: { validProvId },
                                set: { newId in
                                    draft.providerId = newId
                                    if let p = engine.provider(for: newId) {
                                        draft.modelId = p.defaultModel.isEmpty ? (p.models.first ?? "") : p.defaultModel
                                    }
                                }
                            )) {
                                ForEach(engine.providers) { p in
                                    Text("\(p.name)\(p.isConfigured ? " (Aktif)" : "")").tag(p.id)
                                }
                            }

                            HStack(spacing: 5) {
                                ForEach(palette, id: \.self) { cHex in
                                    Circle()
                                        .fill(Color(hex: cHex))
                                        .frame(width: 15, height: 15)
                                        .overlay(Circle().stroke(Color.white, lineWidth: draft.accentHex == cHex ? 2 : 0))
                                        .scaleEffect(draft.accentHex == cHex ? 1.15 : 1.0)
                                        .onTapGesture { draft.accentHex = cHex }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Model ID").font(.caption.weight(.medium))
                                Spacer()
                                Text("Sıcaklık: \(String(format: "%.2f", draft.temperature))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Slider(value: $draft.temperature, in: 0.0...1.0, step: 0.05)
                                    .frame(width: 90)
                                if let prov = currentProvider, !prov.uniqueModels.isEmpty {
                                    let allModels = prov.uniqueModels
                                    let freeModels = allModels.filter { $0.contains(":free") || $0.contains("/free") || $0.lowercased().contains("free") }
                                    let regularModels = allModels.filter { !freeModels.contains($0) }

                                    Menu {
                                        if !freeModels.isEmpty {
                                            Section("🎁 Ücretsiz Modeller") {
                                                ForEach(freeModels, id: \.self) { m in Button("🎁 " + m) { draft.modelId = m } }
                                            }
                                        }
                                        if !regularModels.isEmpty {
                                            Section("Standart & Diğer Modeller") {
                                                ForEach(regularModels, id: \.self) { m in Button(m) { draft.modelId = m } }
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

                            TextField("Model ID", text: $draft.modelId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            if let prov = currentProvider, !prov.uniqueModels.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(prov.uniqueModels.prefix(7), id: \.self) { m in
                                            let isSelected = draft.modelId == m
                                            let isFree = m.contains(":free") || m.contains("/free")
                                            Button { draft.modelId = m } label: {
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

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Yedek Modeller (virgülle ayırın)")
                                .font(.caption2).foregroundStyle(.secondary)
                            TextField("ör: gemini-4-hydrogen-high, deepseek-v4.1-flash", text: $fallbackText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }

                        TextEditor(text: $draft.systemPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 95)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        BikiniAvatarPickerStrip(
                            selectedAsset: Binding(
                                get: { draft.avatarAsset.isEmpty ? OfficeAvatarPreset.resolvedAsset(for: draft) : draft.avatarAsset },
                                set: { draft.avatarAsset = $0 }
                            ),
                            accentHex: draft.accentHex
                        )
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 16)
                }

                HStack {
                    if engine.agents.count > 1 {
                        Button("Sil", role: .destructive) { showDeleteConfirm = true }
                            .liquidGlassButton(prominent: false, tint: .red)
                    }
                    Spacer()
                    Button("İptal") { dismiss() }
                        .liquidGlassButton(prominent: false)
                    Button("Kaydet") {
                        // Merge only edited config fields onto live agent so concurrent messages/status aren't clobbered.
                        var merged = engine.agents.first(where: { $0.id == draft.id }) ?? draft
                        merged.emoji = draft.emoji
                        merged.avatarAsset = draft.avatarAsset
                        merged.name = draft.name
                        merged.title = draft.title
                        merged.accentHex = draft.accentHex
                        merged.providerId = draft.providerId
                        merged.modelId = draft.modelId
                        merged.temperature = draft.temperature
                        merged.systemPrompt = draft.systemPrompt
                        merged.fallbackModelIds = fallbackText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        engine.updateAgent(merged)
                        dismiss()
                    }
                    .liquidGlassButton(prominent: true, tint: Color(hex: draft.accentHex))
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
        }
        .frame(minWidth: 530, minHeight: 500, idealHeight: 580)
        .confirmationDialog("'\(draft.name)' Ekipten Silinsin mi?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Ajanı Sil", role: .destructive) {
                engine.deleteAgent(id: draft.id)
                dismiss()
            }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Ajanın tüm konuşma geçmişi kalıcı olarak silinecektir.")
        }
    }
}
