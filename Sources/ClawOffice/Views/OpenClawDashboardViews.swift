import SwiftUI
import AppKit

/// Reusable 6-stage request tracker strip (openclaw-office RequestPipeline parity).
struct RequestPipelineStripView: View {
    @EnvironmentObject var engine: OfficeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("6 Aşamalı Canlı İstek Hattı (Request Pipeline)", systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(engine.trackedRequests.count) kayıt")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if engine.trackedRequests.isEmpty {
                Text("Bir ajana görev verdiğinizde Alındı → Analiz → Görev → Atandı → Çalışıyor → Tamamlandı aşamaları burada canlı izlenir.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(engine.trackedRequests.prefix(8)) { req in
                            requestCard(req)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 14, tint: .cyan)
    }

    private func requestCard(_ req: TrackedPipelineRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(req.isFailed ? Color.red : Color(hex: req.stage.tintHex))
                    .frame(width: 7, height: 7)
                Text(req.assignedAgentName)
                    .font(.caption.bold())
                Text("· \(req.modelName)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(req.isFailed ? "Hata" : req.stage.label)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((req.isFailed ? Color.red : Color(hex: req.stage.tintHex)).opacity(0.22), in: Capsule())
            }

            Text(req.promptPreview)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // 6 stage progress pills
            HStack(spacing: 3) {
                ForEach(RequestPipelineStage.allCases) { stage in
                    let reached = stage.rawValue <= req.stage.rawValue
                    Capsule()
                        .fill(reached ? (req.isFailed ? Color.red : Color(hex: stage.tintHex)) : Color.primary.opacity(0.10))
                        .frame(height: 4)
                }
            }

            HStack {
                if req.inputTokens + req.outputTokens > 0 {
                    Text("\(req.inputTokens + req.outputTokens) tok")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if req.latencyMs > 0 {
                    Text("\(req.latencyMs) ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 245)
        .liquidGlassCard(cornerRadius: 12, tint: req.stage == .done ? .green : .cyan)
    }
}

/// Full parity dashboard matching openclaw/openclaw & wickedapp/openclaw-office modules.
struct OpenClawControlCenterView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var selectedTab: ControlSubTab = .overview
    @State private var cronName = ""
    @State private var cronPrompt = ""
    @State private var cronAgent = ""
    @State private var cronMinutes = 60
    @State private var telegramTokenDraft = ""
    @State private var telegramTestInput = "Crims Office test bildirimi 🚀"
    @State private var gatewayFeedback = ""
    @State private var telegramFeedback = ""
    @State private var selectedDbTable = "sessions"

    enum ControlSubTab: String, CaseIterable, Identifiable {
        case overview = "Gateway & Pipeline"
        case cost = "Maliyet & Tasarruf"
        case team = "Ajan Düşünceleri"
        case channelsCron = "Kanallar & Cron"
        case security = "Güvenlik Tarama"
        case database = "Depolama & Oturum"

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: Color(hex: "#E11D48"))

            VStack(spacing: 0) {
                headerBar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch selectedTab {
                        case .overview: overviewTab
                        case .cost: costTab
                        case .team: teamThoughtsTab
                        case .channelsCron: channelsCronTab
                        case .security: securityTab
                        case .database: databaseTab
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            if telegramTokenDraft.isEmpty {
                telegramTokenDraft = engine.telegramBotToken
            }
            if cronAgent.isEmpty {
                cronAgent = engine.agents.first?.name ?? "Atlas"
            }
        }
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CrimsBrandLogoView(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Crims Office · OpenClaw Kontrol & Telemetri Merkezi")
                        .font(.headline)
                    Text("Gateway WS · Kanallar · Cron · Maliyet/FTE Tasarrufu · Güvenlik & Oturum JSONL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if engine.isCheckingOpenClaw {
                    ProgressView().controlSize(.small)
                }
                Button("Yenile") {
                    Task {
                        await engine.refreshOpenClawEcosystem()
                        await engine.runSecurityAudit()
                    }
                }
                .liquidGlassButton(prominent: false)
                .controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ControlSubTab.allCases) { tab in
                        Button(tab.rawValue) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedTab = tab
                            }
                        }
                        .liquidGlassButton(
                            prominent: selectedTab == tab,
                            tint: selectedTab == tab ? Color(hex: "#E11D48") : nil
                        )
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .liquidGlassBar()
    }

    // MARK: - Tab 1: Gateway + Discovery + 6-Stage Pipeline

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 10)], spacing: 10) {
                kpiBox(
                    title: "OpenClaw Gateway",
                    value: engine.openClawGatewaySnap.gatewayOnline ? "Çevrimiçi" : (engine.openClawGatewaySnap.cliInstalled ? "CLI Hazır" : "Beklemede"),
                    subtitle: "ws://127.0.0.1:\(engine.openClawGatewaySnap.gatewayPort) · \(engine.openClawGatewaySnap.webSocketConnected ? "WS Bağlı" : "HTTP/CLI")",
                    tint: engine.openClawGatewaySnap.gatewayOnline ? .green : .orange,
                    icon: "network"
                )
                kpiBox(
                    title: "Swarms 17.0.3",
                    value: engine.swarmsHealth?.isHealthy == true ? "Aktif" : "Başlatılabilir",
                    subtitle: "Bridge \(engine.swarmsHealth?.bridgeVersion ?? "-") · \(engine.swarmsHealth?.totalRuns ?? 0) çalışma",
                    tint: engine.swarmsHealth?.isHealthy == true ? .teal : .orange,
                    icon: "hexagon.fill"
                )
                kpiBox(
                    title: "Ed25519 Cihaz Kimliği",
                    value: engine.openClawGatewaySnap.deviceId.isEmpty ? "Standart" : "Doğrulandı",
                    subtitle: engine.openClawGatewaySnap.deviceId.isEmpty ? "~/.openclaw/identity yok" : String(engine.openClawGatewaySnap.deviceId.prefix(16)) + "…",
                    tint: .cyan,
                    icon: "key.viewfinder"
                )
                kpiBox(
                    title: "Toplam Tasarruf",
                    value: String(format: "$%.2f", engine.totalEstimatedSavingsUSD),
                    subtitle: "\(formatTokens(engine.totalTokensProcessed)) token · \(String(format: "%.2f", engine.totalFTEEquivalent)) FTE",
                    tint: .green,
                    icon: "dollarsign.circle.fill"
                )
            }

            // OpenClaw Gateway Actions & Auto-Sync
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("OpenClaw Gateway & Ajan Senkronizasyonu", systemImage: "bolt.horizontal.circle.fill")
                        .font(.headline)
                    Spacer()
                    if !engine.openClawGatewaySnap.cliVersion.isEmpty {
                        Text(engine.openClawGatewaySnap.cliVersion)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .liquidGlassCapsule(tint: .teal, interactive: false)
                    }
                }

                HStack(spacing: 8) {
                    Button("Gateway Başlat") { runGW("start") }.liquidGlassButton(prominent: true, tint: .teal).controlSize(.small)
                    Button("Yeniden Başlat") { runGW("restart") }.liquidGlassButton(prominent: false).controlSize(.small)
                    Button("Durum Sorgula") { runGW("status") }.liquidGlassButton(prominent: false).controlSize(.small)
                    Button("OpenClaw Ajanlarını İçe Aktar (\(engine.openClawGatewaySnap.discoveredAgents.count))") {
                        let count = engine.syncDiscoveredOpenClawAgents()
                        gatewayFeedback = count > 0 ? "\(count) yeni ajan bikinili avatarıyla eklendi ✓" : "Tüm OpenClaw ajanları zaten ofiste mevcut."
                    }
                    .liquidGlassButton(prominent: false, tint: .pink)
                    .controlSize(.small)
                    .disabled(engine.openClawGatewaySnap.discoveredAgents.isEmpty)
                }

                if !gatewayFeedback.isEmpty {
                    Text(gatewayFeedback)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 16, tint: .teal)

            RequestPipelineStripView()
        }
    }

    // MARK: - Tab 2: Cost & FTE Savings Dashboard

    private var costTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 10)], spacing: 10) {
                kpiBox(
                    title: "Tahmini Tasarruf",
                    value: String(format: "$%.2f", engine.totalEstimatedSavingsUSD),
                    subtitle: "AI Maliyeti: \(String(format: "$%.3f", engine.totalEstimatedCostUSD))",
                    tint: .green,
                    icon: "banknote.fill"
                )
                kpiBox(
                    title: "FTE Eşdeğeri",
                    value: String(format: "%.2f", engine.totalFTEEquivalent),
                    subtitle: "\(engine.agents.reduce(0) { $0 + $1.completedTasks }) görev · \(engine.totalToolCallsExecuted) araç",
                    tint: .cyan,
                    icon: "person.2.fill"
                )
                kpiBox(
                    title: "İşlenen Token",
                    value: formatTokens(engine.totalTokensProcessed),
                    subtitle: "RTK \(engine.enableRTKProxy ? "Açık" : "Kapalı") · Caveman \(engine.cavemanMode.rawValue)",
                    tint: .purple,
                    icon: "cpu.fill"
                )
                kpiBox(
                    title: "Oturum JSONL Token",
                    value: formatTokens(engine.openClawSessions.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }),
                    subtitle: "\(engine.openClawSessions.count) OpenClaw oturumu",
                    tint: .orange,
                    icon: "tray.full.fill"
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Ajan Maliyet & Tasarruf Sıralaması")
                    .font(.headline)

                if engine.agentCostTelemetry.isEmpty && engine.agents.isEmpty {
                    Text("Henüz token telemetrisi yok; bir ajana görev verdiğinizde gerçek zamanlı dolar/token metrikleri burada toplanır.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let rows: [AgentCostTelemetry] = engine.agents.map { a in
                        if let existing = engine.agentCostTelemetry.first(where: { $0.id == a.id }) {
                            return existing
                        }
                        return AgentCostTelemetry(
                            id: a.id,
                            name: a.name,
                            avatarAsset: OfficeAvatarPreset.resolvedAsset(for: a),
                            accentHex: a.accentHex,
                            tasksCompleted: a.completedTasks
                        )
                    }.sorted { $0.estimatedSavingsUSD > $1.estimatedSavingsUSD }

                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            if let img = AvatarImageLoader.nsImage(named: row.avatarAsset) {
                                Image(nsImage: img)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .scaleEffect(2.05, anchor: .top).offset(y: 4)
                                    .frame(width: 34, height: 34).clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(Color(hex: row.accentHex).opacity(0.25))
                                    .frame(width: 34, height: 34)
                                    .overlay(Text(row.name.prefix(1)).font(.caption.bold()))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.callout.bold())
                                Text("\(row.tasksCompleted) görev · \(row.toolCallsExecuted) araç · ort \(row.avgLatencyMs) ms")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "+$%.2f tasarruf", row.estimatedSavingsUSD))
                                    .font(.system(.caption, design: .monospaced).bold())
                                    .foregroundStyle(.green)
                                Text("\(formatTokens(row.totalTokens)) tok · $\(String(format: "%.3f", row.estimatedCostUSD))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 12, tint: Color(hex: row.accentHex))
                    }
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 16, tint: .green)
        }
    }

    // MARK: - Tab 3: Team Agent Thoughts Dashboard

    private var teamThoughtsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ekip Düşünceleri & Canlı Durum Kartları (\(engine.agents.count))")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(engine.agents) { agent in
                    let latestThought = agent.messages.last(where: { $0.role == "assistant" && !($0.reasoning ?? "").isEmpty })?.reasoning
                        ?? agent.messages.last(where: { $0.role == "assistant" })?.content
                        ?? agent.statusBubble
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            AgentAvatarView(agent: agent, size: 42, isSelected: engine.selectedAgentId == agent.id, mode: .compactBadge)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(agent.emoji) \(agent.name)").font(.headline)
                                Text(agent.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(agent.modelId)
                                .font(.system(size: 9.5, design: .monospaced))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .liquidGlassCapsule(tint: Color(hex: agent.accentHex), interactive: false)
                        }

                        Text("\"\(String(latestThought.replacingOccurrences(of: "\n", with: " ").prefix(170)))\"")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
                            .padding(9)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                        HStack {
                            Label("\(agent.messages.count)", systemImage: "bubble.left.and.bubble.right").font(.caption2)
                            Spacer()
                            Label("\(agent.completedTasks)", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                            Spacer()
                            Button("Sohbete Git") {
                                engine.selectedAgentId = agent.id
                                engine.requestedSectionRawValue = AppSection.office.rawValue
                            }
                            .liquidGlassButton(prominent: false)
                            .controlSize(.mini)
                        }
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 16, tint: Color(hex: agent.accentHex))
                }
            }
        }
    }

    // MARK: - Tab 4: Channels + Telegram + Cron Scheduler

    private var channelsCronTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenClaw İletişim Kanalları (\(engine.openClawGatewaySnap.channels.count))")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 10)], spacing: 10) {
                    ForEach(engine.openClawGatewaySnap.channels.isEmpty ? OpenClawGatewayService.extractChannels(from: nil) : engine.openClawGatewaySnap.channels) { ch in
                        HStack(spacing: 10) {
                            Image(systemName: ch.icon)
                                .font(.title3)
                                .foregroundStyle(ch.isRunning ? .green : (ch.isConfigured ? .orange : .secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.name).font(.callout.bold())
                                Text(ch.details).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(ch.isRunning ? Color.green : (ch.isConfigured ? Color.orange : Color.secondary.opacity(0.4)))
                                .frame(width: 8, height: 8)
                        }
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 12, tint: ch.isRunning ? .green : nil)
                    }
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 16, tint: .blue)

            // Telegram Bot Notification Bridge
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Telegram Bot Bildirim Köprüsü (Keychain Korumalı)", systemImage: "paperplane.fill").font(.headline)
                    Spacer()
                    Toggle("Görev Bitiminde Bildir", isOn: Binding(
                        get: { engine.telegramNotifyEnabled },
                        set: { engine.telegramNotifyEnabled = $0; engine.saveConfig() }
                    ))
                    .toggleStyle(.switch).controlSize(.small)
                }
                HStack(spacing: 8) {
                    SecureField("Bot Token (123456:ABC...)", text: $telegramTokenDraft)
                        .textFieldStyle(.roundedBorder)
                    TextField("Chat ID", text: Binding(
                        get: { engine.telegramChatId },
                        set: { engine.telegramChatId = $0; engine.saveConfig() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    Button("Kaydet") {
                        engine.telegramBotToken = telegramTokenDraft
                        telegramFeedback = "Token Keychain'e kaydedildi ✓"
                    }
                    .liquidGlassButton(prominent: false)
                }
                HStack(spacing: 8) {
                    TextField("Test mesajı...", text: $telegramTestInput).textFieldStyle(.roundedBorder)
                    Button("Test Mesajı Gönder") {
                        let cleanDraft = telegramTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanDraft.isEmpty {
                            engine.telegramBotToken = cleanDraft
                        }
                        Task {
                            let res = await engine.sendTelegramNotification(text: telegramTestInput)
                            telegramFeedback = res.1
                        }
                    }
                    .liquidGlassButton(prominent: true, tint: .blue)
                }
                if !telegramFeedback.isEmpty {
                    Text(telegramFeedback).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 16, tint: .indigo)

            // Cron Automation Scheduler
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cron & Heartbeat Zamanlayıcı (\(engine.cronJobs.count))", systemImage: "clock.arrow.2.circlepath").font(.headline)
                    Spacer()
                    if engine.openClawGatewaySnap.externalCronCount > 0 {
                        Text("\(engine.openClawGatewaySnap.externalCronCount) OpenClaw Cron")
                            .font(.caption2).padding(.horizontal, 8).padding(.vertical, 3)
                            .liquidGlassCapsule(tint: .teal, interactive: false)
                    }
                }

                HStack(spacing: 8) {
                    TextField("İş Adı (ör: Günlük Kod Sağlık Kontrolü)", text: $cronName).textFieldStyle(.roundedBorder)
                    Picker("Ajan", selection: $cronAgent) {
                        ForEach(engine.agents) { a in Text(a.name).tag(a.name) }
                    }.frame(width: 130)
                    Picker("Aralık", selection: $cronMinutes) {
                        Text("5 dk").tag(5)
                        Text("15 dk").tag(15)
                        Text("60 dk").tag(60)
                        Text("240 dk").tag(240)
                    }.frame(width: 100)
                }
                HStack(spacing: 8) {
                    TextField("Zamanlanacak otonom görev promptu...", text: $cronPrompt).textFieldStyle(.roundedBorder)
                    Button("Cron Ekle") {
                        let validAgent = engine.agents.contains(where: { $0.name == cronAgent })
                            ? cronAgent
                            : (engine.agents.first?.name ?? "Atlas")
                        engine.addCronJob(name: cronName, prompt: cronPrompt, targetAgentName: validAgent, intervalMinutes: cronMinutes)
                        cronName = ""
                        cronPrompt = ""
                    }
                    .liquidGlassButton(prominent: true, tint: .teal)
                    .disabled(cronName.trimmingCharacters(in: .whitespaces).isEmpty || cronPrompt.trimmingCharacters(in: .whitespaces).isEmpty || engine.agents.isEmpty)
                }

                ForEach(engine.cronJobs) { job in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { job.isEnabled },
                            set: { _ in engine.toggleCronJob(id: job.id) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("\(job.name) cron işini aç/kapat")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(job.name) · @\(job.targetAgentName) · her \(job.intervalMinutes) dk").font(.callout.bold())
                            Text("\(job.prompt) — \(job.lastStatus)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Şimdi Çalıştır") { engine.runCronJobNow(id: job.id) }
                            .liquidGlassButton(prominent: false).controlSize(.small)
                        Button { engine.deleteCronJob(id: job.id) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }.buttonStyle(.borderless)
                    }
                    .padding(10)
                    .liquidGlassCard(cornerRadius: 12, tint: job.isEnabled ? .teal : nil)
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 16, tint: .teal)
        }
    }

    // MARK: - Tab 5: Security Audit Dashboard

    private var securityTab: some View {
        let audit = engine.securityAudit
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 10).frame(width: 92, height: 92)
                    Circle()
                        .trim(from: 0, to: CGFloat(audit.score) / 100.0)
                        .stroke(audit.score >= 85 ? Color.green : Color.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 92, height: 92)
                    VStack(spacing: 0) {
                        Text("\(audit.score)").font(.title.bold())
                        Text("/100").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Güvenlik Sağlık Skoru").font(.title3.bold())
                    Text("Son tarama: \(audit.checkedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label("\(audit.keychainItemsCount) Keychain Sır", systemImage: "key.fill").font(.caption).foregroundStyle(.green)
                        Label("\(audit.blockedCommandsCount) Engellenen Komut", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
                        Label("\(audit.redactedSecretsCount) Devralma", systemImage: "shield.checkmark.fill").font(.caption).foregroundStyle(.cyan)
                    }
                }
                Spacer()
                Button("Güvenlik Taraması Çalıştır") {
                    Task { await engine.runSecurityAudit() }
                }
                .liquidGlassButton(prominent: true, tint: .green)
            }
            .padding(16)
            .liquidGlassCard(cornerRadius: 16, tint: .green)

            VStack(alignment: .leading, spacing: 8) {
                Text("Sistem Güvenlik Kontrolleri").font(.headline)
                ForEach(audit.findings) { f in
                    HStack(spacing: 10) {
                        Image(systemName: f.passed ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(f.passed ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.callout.bold())
                            Text(f.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(f.severity).font(.caption2).padding(.horizontal, 8).padding(.vertical, 2).liquidGlassCapsule(interactive: false)
                    }
                    .padding(10)
                    .liquidGlassCard(cornerRadius: 12, tint: f.passed ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Yerel Loopback Port Taraması (127.0.0.1)").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(audit.ports) { p in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(p.status == "Uyarı" ? Color.orange : (p.isListening ? Color.green : Color.secondary.opacity(0.4)))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(":\(p.port) · \(p.service)").font(.system(.caption, design: .monospaced).bold())
                                Text(p.details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(p.status).font(.caption2.bold())
                        }
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 12)
                    }
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: 16)
        }
    }

    // MARK: - Tab 6: Database & OpenClaw Session JSONL Explorer

    private var databaseTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Veri Tablosu", selection: $selectedDbTable) {
                Text("OpenClaw Oturumları (\(engine.openClawSessions.count))").tag("sessions")
                Text("Swarms Çalışmaları (\(engine.swarmsRecentRuns.count))").tag("swarms")
                Text("Dosya Düzenlemeleri & Yedekler (\(engine.fileEdits.count))").tag("edits")
            }
            .pickerStyle(.segmented)

            if selectedDbTable == "sessions" {
                if engine.openClawSessions.isEmpty {
                    Text("`~/.openclaw/agents/*/sessions/*.jsonl` altında henüz oturum bulunamadı.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(engine.openClawSessions) { s in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(s.agentId) · \(s.fileName)")
                                    .font(.system(.caption, design: .monospaced).bold())
                                Text(s.preview)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(s.messageCount) satır · \(formatTokens(s.inputTokens + s.outputTokens)) tok")
                                    .font(.system(size: 10, design: .monospaced))
                                Text(s.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 12)
                    }
                }
            } else if selectedDbTable == "swarms" {
                if engine.swarmsRecentRuns.isEmpty {
                    Text("Henüz Swarms çalışma kaydı bulunmuyor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    ForEach(engine.swarmsRecentRuns) { run in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(run.swarmType) · \(run.status)").font(.callout.bold())
                                Text(run.taskPreview).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(run.stepCount) adım · \(run.durationMs) ms")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 12)
                    }
                }
            } else {
                if engine.fileEdits.isEmpty {
                    Text("Henüz kaydedilmiş dosya düzenlemesi bulunmuyor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    ForEach(engine.fileEdits.prefix(40)) { rec in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.relativePath).font(.system(.caption, design: .monospaced).bold())
                            Text("\(rec.agentName) · \(rec.summary)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(rec.wasNewFile ? "Yeni Dosya" : (rec.rolledBack ? "Geri Alındı" : "Yedekli"))
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .liquidGlassCapsule(interactive: false)
                    }
                    .padding(10)
                    .liquidGlassCard(cornerRadius: 12)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func runGW(_ action: String) {
        Task {
            let res = await engine.runOpenClawGatewayAction(action)
            gatewayFeedback = res.1
        }
    }

    private func kpiBox(title: String, value: String, subtitle: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.bold())
            Text(subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: 14, tint: tint)
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000.0) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}
