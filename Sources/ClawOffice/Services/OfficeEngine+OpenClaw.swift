import Foundation
import SwiftUI

extension OfficeEngine {

    // MARK: - 6-Stage Request Pipeline & Flying Task Packets (openclaw-office parity)

    @discardableResult
    func beginTrackedRequest(title: String, prompt: String, agentName: String, modelName: String) -> UUID {
        let req = TrackedPipelineRequest(
            title: String(title.prefix(64)),
            promptPreview: String(prompt.replacingOccurrences(of: "\n", with: " ").prefix(140)),
            assignedAgentName: agentName,
            modelName: modelName,
            stage: .received
        )
        trackedRequests.insert(req, at: 0)
        if trackedRequests.count > 40 {
            trackedRequests.removeLast(trackedRequests.count - 40)
        }
        return req.id
    }

    func advanceTrackedRequest(
        _ id: UUID,
        to stage: RequestPipelineStage,
        agentName: String? = nil,
        modelName: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        latencyMs: Int = 0,
        failed: Bool = false
    ) {
        guard let idx = trackedRequests.firstIndex(where: { $0.id == id }) else { return }
        trackedRequests[idx].stage = stage
        trackedRequests[idx].updatedAt = Date()
        if let agentName, !agentName.isEmpty { trackedRequests[idx].assignedAgentName = agentName }
        if let modelName, !modelName.isEmpty { trackedRequests[idx].modelName = modelName }
        if inputTokens > 0 { trackedRequests[idx].inputTokens += inputTokens }
        if outputTokens > 0 { trackedRequests[idx].outputTokens += outputTokens }
        if latencyMs > 0 { trackedRequests[idx].latencyMs += latencyMs }
        if failed { trackedRequests[idx].isFailed = true }
        if stage == .done {
            trackedRequests[idx].completedAt = Date()
        }
    }

    func emitFlyingPacket(from: UUID, to: UUID, label: String, accentHex: String, duration: Double = 2.6) {
        guard from != to else { return }
        let pkt = FlyingTaskPacket(fromAgentId: from, toAgentId: to, label: label, accentHex: accentHex)
        flyingPackets.append(pkt)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self?.flyingPackets.removeAll { $0.id == pkt.id }
        }
    }

    // MARK: - Cost, Token Telemetry & FTE Savings

    func recordTurnCostTelemetry(
        agentId: UUID,
        provider: APIProviderConfig,
        modelId: String,
        response: LLMFinalResponse,
        promptChars: Int,
        toolCallsCount: Int
    ) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }
        let inTok = response.inputTokens > 0 ? response.inputTokens : max(32, promptChars / 4)
        let outTok = response.outputTokens > 0 ? response.outputTokens : max(16, (response.content.count + response.reasoning.count) / 4)
        let cachedTok = response.cachedTokens
        let reasonTok = response.reasoningTokens

        let lowerM = modelId.lowercased()
        let isFreeOrLocal = provider.kind == .antigravityCLI
            || lowerM.contains(":free")
            || lowerM.contains("/free")
            || lowerM.contains("free")
        let actualCost: Double = isFreeOrLocal
            ? 0.0
            : (Double(inTok) * 0.00000045 + Double(outTok + reasonTok) * 0.0000016)
        // Baseline cloud cost + engineering labor equivalent saved via RTK/Caveman/routing
        let baselineCloudCost = Double(inTok) * 0.000003 + Double(outTok + reasonTok) * 0.000015
        let cavemanSavingsBonus = cavemanMode != .off ? Double(outTok) * 0.000006 : 0.0
        let rtkSavingsBonus = (cliStatus.rtkInstalled && enableRTKProxy) ? Double(inTok) * 0.0000015 : 0.0
        let taskHumanValue = isFreeOrLocal || toolCallsCount > 0 ? 1.85 : 0.65
        let savedDelta = max(0, (baselineCloudCost - actualCost) + cavemanSavingsBonus + rtkSavingsBonus + taskHumanValue)

        let idx = agentCostTelemetry.firstIndex(where: { $0.id == agentId }) ?? {
            let entry = AgentCostTelemetry(
                id: agentId,
                name: agent.name,
                avatarAsset: OfficeAvatarPreset.resolvedAsset(for: agent),
                accentHex: agent.accentHex
            )
            agentCostTelemetry.append(entry)
            return agentCostTelemetry.count - 1
        }()

        agentCostTelemetry[idx].name = agent.name
        agentCostTelemetry[idx].avatarAsset = OfficeAvatarPreset.resolvedAsset(for: agent)
        agentCostTelemetry[idx].accentHex = agent.accentHex
        agentCostTelemetry[idx].inputTokens += inTok
        agentCostTelemetry[idx].outputTokens += outTok
        agentCostTelemetry[idx].cachedTokens += cachedTok
        agentCostTelemetry[idx].reasoningTokens += reasonTok
        agentCostTelemetry[idx].estimatedCostUSD += actualCost
        agentCostTelemetry[idx].estimatedSavingsUSD += savedDelta
        agentCostTelemetry[idx].tasksCompleted += 1
        agentCostTelemetry[idx].toolCallsExecuted += toolCallsCount
        agentCostTelemetry[idx].totalLatencyMs += response.latencyMs
    }

    var totalTokensProcessed: Int {
        agentCostTelemetry.reduce(0) { $0 + $1.totalTokens }
    }

    var totalEstimatedCostUSD: Double {
        agentCostTelemetry.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    var totalEstimatedSavingsUSD: Double {
        agentCostTelemetry.reduce(0) { $0 + $1.estimatedSavingsUSD }
    }

    var totalFTEEquivalent: Double {
        let completed = agents.reduce(0) { $0 + $1.completedTasks }
        let humanHours = Double(completed) * 0.35 + Double(totalToolCallsExecuted) * 0.08
        return humanHours / (8.0 * 30.0)
    }

    // MARK: - OpenClaw Gateway, Channels, WebSocket & Sessions

    func refreshOpenClawEcosystem() async {
        isCheckingOpenClaw = true
        defer { isCheckingOpenClaw = false }

        let snap = await OpenClawGatewayService.shared.inspectGateway(workspacePath: workspacePath)
        openClawGatewaySnap = snap
        cliStatus.openClawInstalled = snap.cliInstalled
        cliStatus.openClawGatewayOnline = snap.gatewayOnline

        if snap.gatewayOnline && !snap.webSocketConnected {
            OpenClawGatewayService.shared.connectWebSocket(port: snap.gatewayPort) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.openClawGatewaySnap.webSocketConnected = true
                    self?.openClawSessions = OpenClawGatewayService.scanSessionSummaries(limit: 30)
                }
            }
        }
        openClawSessions = OpenClawGatewayService.scanSessionSummaries(limit: 30)
    }

    func runOpenClawGatewayAction(_ action: String) async -> (Bool, String) {
        let res = await OpenClawGatewayService.shared.controlGateway(action: action, workspacePath: workspacePath)
        await refreshOpenClawEcosystem()
        log(res.0 ? .info : .warning, source: "OpenClaw Gateway", res.1.isEmpty ? action : String(res.1.prefix(240)))
        return res
    }

    @discardableResult
    func syncDiscoveredOpenClawAgents() -> Int {
        var added = 0
        for ext in openClawGatewaySnap.discoveredAgents {
            if agents.contains(where: { $0.name.lowercased() == ext.name.lowercased() }) {
                continue
            }
            let preset = OfficeAvatarPreset.defaultAsset(forIndex: agents.count + 1)
            let hire = hireAgent(
                name: ext.name,
                title: ext.title,
                emoji: "🦞",
                modelId: ext.modelId.isEmpty ? "auto" : ext.modelId,
                systemPrompt: "OpenClaw Gateway ajanı (\(ext.id)). Çalışma dizini: \(ext.workspace)"
            )
            if hire.success, var created = hire.agent {
                created.avatarAsset = preset
                updateAgent(created)
                added += 1
            }
        }
        if added > 0 {
            log(.success, source: "OpenClaw Sync", "\(added) OpenClaw ajanı Crims Office ekibine aktarıldı.")
        }
        return added
    }

    // MARK: - Cron / Heartbeat Automation Scheduler

    func startCronSchedulerLoop() {
        cronTimer?.invalidate()
        cronTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickDueCronJobs() }
        }
    }

    func tickDueCronJobs() {
        let now = Date()
        for idx in cronJobs.indices where cronJobs[idx].isEnabled {
            let intervalSec = TimeInterval(max(1, cronJobs[idx].intervalMinutes) * 60)
            let due: Bool
            if let last = cronJobs[idx].lastRunAt {
                due = now.timeIntervalSince(last) >= intervalSec
            } else {
                due = false
            }
            if due {
                runCronJobNow(id: cronJobs[idx].id)
            }
        }
    }

    func addCronJob(name: String, prompt: String, targetAgentName: String, intervalMinutes: Int) {
        let cleanN = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanP = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanN.isEmpty, !cleanP.isEmpty else { return }
        let job = OfficeCronJob(
            name: cleanN,
            prompt: cleanP,
            targetAgentName: targetAgentName.isEmpty ? (agents.first?.name ?? "Atlas") : targetAgentName,
            intervalMinutes: max(1, intervalMinutes),
            isEnabled: true
        )
        cronJobs.insert(job, at: 0)
        saveConfig()
    }

    func toggleCronJob(id: UUID) {
        guard let i = cronJobs.firstIndex(where: { $0.id == id }) else { return }
        cronJobs[i].isEnabled.toggle()
        saveConfig()
    }

    func deleteCronJob(id: UUID) {
        cronJobs.removeAll { $0.id == id }
        saveConfig()
    }

    func runCronJobNow(id: UUID) {
        guard let idx = cronJobs.firstIndex(where: { $0.id == id }) else { return }
        let targetName = cronJobs[idx].targetAgentName
        let agent = agents.first(where: { $0.name.lowercased() == targetName.lowercased() }) ?? agents.first
        guard let target = agent else { return }
        cronJobs[idx].lastRunAt = Date()
        cronJobs[idx].lastStatus = "Çalıştırıldı (\(Date().formatted(date: .omitted, time: .shortened)))"
        saveConfig()
        log(.info, source: "Cron", "⏰ '\(cronJobs[idx].name)' → \(target.name)")
        sendMessage(to: target.id, text: "[ZAMANLANMIŞ CRON GÖREVİ: \(cronJobs[idx].name)]\n\(cronJobs[idx].prompt)")
    }

    // MARK: - Telegram Notification Bridge & Security Audit

    var telegramBotToken: String {
        get { persistConfig ? (KeychainStore.shared.secret(forAccount: "telegram_bot_token") ?? "") : "" }
        set {
            if persistConfig {
                _ = KeychainStore.shared.setSecret(newValue, forAccount: "telegram_bot_token")
            }
        }
    }

    func sendTelegramNotification(text: String) async -> (Bool, String) {
        let res = await OpenClawGatewayService.shared.sendTelegramMessage(
            botToken: telegramBotToken,
            chatId: telegramChatId,
            text: text
        )
        log(res.0 ? .success : .warning, source: "Telegram", res.1)
        return res
    }

    func runSecurityAudit() async {
        let blockedCount = logs.filter { $0.message.contains("Güvenlik politikası gereği engellendi") }.count
        let snap = await OpenClawGatewayService.shared.runSecurityAudit(
            providers: providers,
            connectors: connectors,
            gatewayPort: openClawGatewaySnap.gatewayPort,
            blockedCommandsCount: blockedCount,
            redactedSecretsCount: failoverEventCount
        )
        securityAudit = snap
    }
}
