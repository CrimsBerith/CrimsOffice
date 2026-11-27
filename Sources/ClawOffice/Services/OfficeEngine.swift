import Foundation
import SwiftUI

final class ConfigStore {
    static let shared = ConfigStore()
    private let fileURL: URL
    private let keychain: KeychainStore?
    private let saveQueue = DispatchQueue(label: "com.clawoffice.configstore", qos: .utility)
    private(set) var lastLoadWarning: String? = nil

    convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        let dir = base.appendingPathComponent("CrimsOffice", isDirectory: true)
        let targetURL = dir.appendingPathComponent("config-v4.json")
        let legacyURL = base.appendingPathComponent("ClawOffice", isDirectory: true).appendingPathComponent("config-v4.json")
        try? fm.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if !fm.fileExists(atPath: targetURL.path), fm.fileExists(atPath: legacyURL.path) {
            try? fm.copyItem(at: legacyURL, to: targetURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        }
        let kc: KeychainStore? = KeychainStore.isNonInteractiveProcess ? nil : .shared
        self.init(fileURL: targetURL, keychain: kc)
    }

    init(fileURL: URL, keychain: KeychainStore? = nil) {
        self.fileURL = fileURL
        self.keychain = keychain
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    var configPath: String { fileURL.path }

    func load() -> AppConfig {
        saveQueue.sync {
            loadUnlocked()
        }
    }

    func flush() {
        saveQueue.sync {}
    }

    private func loadUnlocked() -> AppConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            var def = AppConfig.makeDefault()
            hydrateAPIKeys(&def)
            return def
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            lastLoadWarning = "config-v4.json okunamadı; varsayılan ayarlar yüklendi."
            return AppConfig.makeDefault()
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var cfg = try? dec.decode(AppConfig.self, from: data) else {
            // Preserve unreadable config before falling back to defaults
            let ts = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent("config-v4.corrupt-\(ts).json")
            try? data.write(to: backupURL, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            lastLoadWarning = "config-v4.json çözümlenemedi; yedeği alındı (\(backupURL.lastPathComponent))."
            NSLog("[ClawOffice] ⚠️ %@", lastLoadWarning ?? "")
            var def = AppConfig.makeDefault()
            hydrateAPIKeys(&def)
            return def
        }

        lastLoadWarning = nil
        var didNormalize = migrateAPIKeysToKeychainIfNeeded(&cfg)

        // Ensure disabled Antigravity CLI backend cannot stay active under policy
        for i in cfg.providers.indices where cfg.providers[i].kind == .antigravityCLI && cfg.providers[i].isEnabled {
            cfg.providers[i].isEnabled = false
            didNormalize = true
        }

        // Run one-time schema v2 migrations without clobbering intentional user overrides on every launch
        if cfg.schemaVersion < 2 {
            for i in cfg.providers.indices {
                if cfg.providers[i].kind == .evren {
                    if cfg.providers[i].defaultModel == "auto" || cfg.providers[i].defaultModel.isEmpty {
                        cfg.providers[i].defaultModel = "deepseek-v4.1-flash"
                    }
                    let defaults = ["deepseek-v4.1-flash", "qwen3.8-flash-next", "gemma-4-31b", "glm-5.3", "qwen3-vl-30b"]
                    for m in defaults where !cfg.providers[i].models.contains(m) {
                        cfg.providers[i].models.append(m)
                    }
                } else if cfg.providers[i].kind == .openRouter {
                    let flagship = ["google/gemini-4-hydrogen", "google/gemini-4-neon", "google/gemini-4-carbon"]
                    for m in flagship.reversed() {
                        if let idx = cfg.providers[i].models.firstIndex(of: m) {
                            cfg.providers[i].models.remove(at: idx)
                        }
                        let pos = min(1, cfg.providers[i].models.count)
                        cfg.providers[i].models.insert(m, at: pos)
                    }
                }
            }
            cfg.schemaVersion = 2
            didNormalize = true
        }

        // Merge any missing built-in connector templates (e.g. Hostinger, GitHub, Cloudflare)
        let existingSlugs = Set(cfg.connectors.map { $0.slug.lowercased() })
        for builtInConn in ServiceConnector.builtInCatalog() where !existingSlugs.contains(builtInConn.slug.lowercased()) {
            cfg.connectors.append(builtInConn)
            didNormalize = true
        }

        hydrateAPIKeys(&cfg)

        let configuredProv = cfg.providers.first(where: { $0.isEnabled && $0.isConfigured })
        let stalePrefixes = [
            "retrospektif", "öğreniyor", "bağlanıyor", "inceliyor",
            "akıl yürütüyor", "bekleniyor", "⚡️", "🤝", "🧠"
        ]

        for i in cfg.agents.indices {
            cfg.agents[i].status = .idle
            cfg.agents[i].currentZone = .desk
            cfg.agents[i].agyConversationId = nil
            let rawAvatar = cfg.agents[i].avatarAsset.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawAvatar.isEmpty || !OfficeAvatarPreset.allPresets.contains(where: { $0.assetName == rawAvatar }) {
                cfg.agents[i].avatarAsset = OfficeAvatarPreset.defaultAsset(forIndex: i)
                didNormalize = true
            }

            let lowerBubble = cfg.agents[i].statusBubble.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowerBubble.isEmpty || stalePrefixes.contains(where: { lowerBubble.contains($0) }) {
                cfg.agents[i].statusBubble = "Masasında · Hazır"
                didNormalize = true
            }

            if let cp = configuredProv {
                let currentP = cfg.providers.first(where: { $0.id == cfg.agents[i].providerId })
                if currentP?.isConfigured != true {
                    cfg.agents[i].providerId = cp.id
                    didNormalize = true
                }
            }
            let currentProv = cfg.providers.first(where: { $0.id == cfg.agents[i].providerId })
            let currentModel = cfg.agents[i].modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            let primarySupported = currentProv.map {
                $0.isConfigured && !currentModel.isEmpty && currentModel != "auto" && SwarmsRuntimeService.providerSupportsModel($0, modelId: currentModel)
            } ?? false

            if !primarySupported {
                if !currentModel.isEmpty,
                   currentModel != "auto",
                   let owningProv = cfg.providers.first(where: { $0.isConfigured && SwarmsRuntimeService.providerSupportsModel($0, modelId: currentModel) }) {
                    cfg.agents[i].providerId = owningProv.id
                    didNormalize = true
                } else {
                    let decision = ModelRouter.selectModelForHire(
                        name: cfg.agents[i].name,
                        title: cfg.agents[i].title,
                        systemPrompt: cfg.agents[i].systemPrompt,
                        requestedModel: "auto",
                        providers: cfg.providers,
                        existingAgents: cfg.agents,
                        providerStatuses: [:],
                        providerCooldowns: [:],
                        modelMetrics: [:]
                    )
                    cfg.agents[i].providerId = decision.provider.id
                    cfg.agents[i].modelId = decision.modelId
                    if cfg.agents[i].fallbackModelIds.isEmpty {
                        cfg.agents[i].fallbackModelIds = decision.fallbackModelIds
                    }
                    didNormalize = true
                }
            }

            let repairedModel = cfg.agents[i].modelId
            var seenFallback: Set<String> = [repairedModel]
            let cleanedFallbacks = cfg.agents[i].fallbackModelIds.compactMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seenFallback.insert(trimmed).inserted else { return nil }
                let supportedAnywhere = cfg.providers.contains {
                    $0.isConfigured && SwarmsRuntimeService.providerSupportsModel($0, modelId: trimmed)
                }
                return supportedAnywhere ? trimmed : nil
            }
            if cleanedFallbacks != cfg.agents[i].fallbackModelIds {
                cfg.agents[i].fallbackModelIds = cleanedFallbacks
                didNormalize = true
            }
            if cfg.agents[i].fallbackModelIds.isEmpty {
                let finalProv = cfg.providers.first(where: { $0.id == cfg.agents[i].providerId })
                let decision = ModelRouter.selectModelForHire(
                    name: cfg.agents[i].name,
                    title: cfg.agents[i].title,
                    systemPrompt: cfg.agents[i].systemPrompt,
                    requestedModel: "auto",
                    providers: cfg.providers,
                    existingAgents: cfg.agents,
                    providerStatuses: [:],
                    providerCooldowns: [:],
                    modelMetrics: [:]
                )
                var defaults = decision.fallbackModelIds.filter { $0 != repairedModel }
                if defaults.isEmpty {
                    if finalProv?.kind == .evren {
                        defaults = ["qwen3.8-flash-next", "gemma-4-31b", "glm-5.3"].filter { $0 != repairedModel }
                    } else if let firstM = finalProv?.defaultModel, !firstM.isEmpty, firstM != repairedModel {
                        defaults = [firstM]
                    }
                }
                if !defaults.isEmpty {
                    cfg.agents[i].fallbackModelIds = defaults
                    didNormalize = true
                }
            }
        }

        var seen = Set<String>()
        let beforeCount = cfg.agents.count
        cfg.agents.removeAll { a in
            let k = a.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.contains(k) { return true }
            seen.insert(k)
            return false
        }
        if cfg.agents.count != beforeCount {
            didNormalize = true
        }

        if OfficeEngine.normalizeCollidingDeskPositions(&cfg.agents) {
            didNormalize = true
        }

        for i in cfg.agents.indices {
            cfg.agents[i].currentPosition = cfg.agents[i].deskPosition
        }

        if didNormalize {
            writeConfigAtomically(cfg)
        }
        return cfg
    }

    private func migrateAPIKeysToKeychainIfNeeded(_ cfg: inout AppConfig) -> Bool {
        guard let keychain else { return false }
        var migrated = false
        for i in cfg.providers.indices {
            let rawKey = cfg.providers[i].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawKey.isEmpty else { continue }
            if keychain.setSecret(rawKey, forAccount: cfg.providers[i].id.uuidString) {
                migrated = true
            }
        }
        for i in cfg.connectors.indices {
            let rawKey = cfg.connectors[i].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawKey.isEmpty else { continue }
            if keychain.setSecret(rawKey, forAccount: cfg.connectors[i].keychainAccountKey) {
                migrated = true
            }
        }
        return migrated
    }

    private func hydrateAPIKeys(_ cfg: inout AppConfig) {
        guard let keychain else { return }
        for i in cfg.providers.indices {
            if let stored = keychain.secret(forAccount: cfg.providers[i].id.uuidString), !stored.isEmpty {
                cfg.providers[i].apiKey = stored
            }
        }
        for i in cfg.connectors.indices {
            if let stored = keychain.secret(forAccount: cfg.connectors[i].keychainAccountKey), !stored.isEmpty {
                cfg.connectors[i].apiKey = stored
            }
        }
    }

    func save(_ config: AppConfig) {
        let trimmed = trimForPersistence(config)
        saveQueue.async { [weak self] in
            guard let self else { return }
            self.writeConfigAtomically(trimmed)
        }
    }

    private func writeConfigAtomically(_ config: AppConfig) {
        var sanitized = config
        if let keychain {
            for i in sanitized.providers.indices {
                let rawKey = sanitized.providers[i].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawKey.isEmpty {
                    keychain.deleteSecret(forAccount: sanitized.providers[i].id.uuidString)
                } else if keychain.setSecret(rawKey, forAccount: sanitized.providers[i].id.uuidString) {
                    // Scrub secret from plaintext JSON only when Keychain persistence succeeds
                    sanitized.providers[i].apiKey = ""
                }
            }
            for i in sanitized.connectors.indices {
                let rawKey = sanitized.connectors[i].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if rawKey.isEmpty {
                    keychain.deleteSecret(forAccount: sanitized.connectors[i].keychainAccountKey)
                } else if keychain.setSecret(rawKey, forAccount: sanitized.connectors[i].keychainAccountKey) {
                    sanitized.connectors[i].apiKey = ""
                }
            }
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(sanitized) else {
            NSLog("[ClawOffice] ⚠️ Config JSON encode failed.")
            return
        }

        let dir = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmpURL = dir.appendingPathComponent(".config-v4-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmpURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            NSLog("[ClawOffice] ⚠️ Config temp file create failed: %@", tmpURL.path)
            return
        }
        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL, backupItemName: nil, options: [.usingNewMetadataOnly])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? fm.removeItem(at: tmpURL)
            NSLog("[ClawOffice] ⚠️ Config save failed: %@", error.localizedDescription)
        }
    }

    private func trimForPersistence(_ config: AppConfig) -> AppConfig {
        var copy = config
        for i in copy.agents.indices {
            if copy.agents[i].messages.count > 50 {
                copy.agents[i].messages = Array(copy.agents[i].messages.suffix(50))
            }
            for mi in copy.agents[i].messages.indices {
                for ti in copy.agents[i].messages[mi].toolCalls.indices {
                    let out = copy.agents[i].messages[mi].toolCalls[ti].output
                    if out.count > 4000 {
                        copy.agents[i].messages[mi].toolCalls[ti].output = String(out.prefix(4000)) + "\n... [kısaltıldı]"
                    }
                }
            }
        }
        return copy
    }
}

@MainActor
final class OfficeEngine: ObservableObject {
    @Published var providers: [APIProviderConfig]
    @Published var agents: [OfficeAgent]
    @Published var selectedAgentId: UUID?
    @Published var logs: [ActivityLogEntry] = []

    // Live Inter-Agent Communication & Beams
    @Published var officeDialogues: [OfficeDialogueMessage] = []
    @Published var activeBeams: [ActiveBeamLink] = []

    // OpenClaw + Power Stack + Project Evolution State
    @Published var workspacePath: String
    @Published var openClawHomePath: String
    @Published var cavemanMode: CavemanMode
    @Published var enableRTKProxy: Bool
    @Published var enableLocalTools: Bool
    @Published var allowFileWrites: Bool
    @Published var autoVerifyBuild: Bool
    @Published var customBuildCommand: String
    @Published var autoSelfImprove: Bool
    @Published var injectAgentsMD: Bool
    @Published var injectOpenClawMemory: Bool
    @Published var injectGraphifyReport: Bool
    @Published var enableAmbientMovement: Bool
    @Published var enableSocialChatter: Bool
    @Published var enableStreaming: Bool

    @Published var roleTemplates: [AgentRoleTemplate] = AgentRoleTemplate.defaultTemplates()
    @Published var fileEdits: [FileEditRecord]
    @Published var skills: [AgentSkill] = []
    @Published var cliStatus: CLIToolStatus = CLIToolStatus()
    @Published var rtkGainSummary: String = ""
    @Published var graphSnapshot: GraphifySnapshot? = nil
    @Published var discoveredAgentsMD: [(relativePath: String, content: String)] = []
    @Published var providerStatuses: [UUID: ProviderHealthStatus] = [:]
    @Published var failoverEventCount: Int = 0
    @Published var lastFailoverNotice: String = ""
    @Published var totalToolCallsExecuted: Int = 0
    @Published var gitBranchSummary: (branch: String, dirtyCount: Int)? = nil
    @Published var activePlanGoal: String = ""
    @Published var planTasks: [OfficePlanTask] = []

    @Published var isRunningPipeline = false
    @Published var pipelineStatusText = ""
    @Published var lastPipelineOutputs: [(agentName: String, title: String, model: String, output: String)] = []
    @Published var lastBuildVerification: (passed: Bool, summary: String)? = nil
    @Published var workspaceRefreshNonce: Int = 0
    @Published var connectors: [ServiceConnector]
    @Published var browserHomeURL: String
    @Published var allowBrowserLocalNetwork: Bool
    @Published var lastGitHubCandidates: [GitHubRepoCandidate] = []
    @Published var requestedSectionRawValue: String? = nil
    @Published var swarmsHealth: SwarmsDaemonHealth? = nil
    @Published var swarmsRecentRuns: [SwarmsRunSummary] = []
    @Published var isCheckingSwarms: Bool = false
    @Published var cronJobs: [OfficeCronJob] = []
    @Published var telegramChatId: String = ""
    @Published var telegramNotifyEnabled: Bool = false
    @Published var useIllustratedFloorBackdrop: Bool = true
    @Published var trackedRequests: [TrackedPipelineRequest] = []
    @Published var flyingPackets: [FlyingTaskPacket] = []
    @Published var agentCostTelemetry: [AgentCostTelemetry] = []
    @Published var openClawGatewaySnap: OpenClawGatewayService.GatewaySnapshot = .init()
    @Published var openClawSessions: [OpenClawSessionSummary] = []
    @Published var isCheckingOpenClaw: Bool = false
    @Published var securityAudit: SecurityAuditSnapshot = SecurityAuditSnapshot()

    let browser = BrowserAutomationService()
    var searchedTopicsByAgent: [UUID: Set<String>] = [:]

    private var ambientTimer: Timer?
    var cronTimer: Timer?
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskTokens: [UUID: UUID] = [:]
    private var pipelineTask: Task<Void, Never>? = nil
    private var pipelineToken: UUID? = nil
    var providerCooldowns: [UUID: Date] = [:]
    private var providerConsecutiveErrors: [UUID: Int] = [:]
    @Published var walkingAgentIds: Set<UUID> = []
    @Published var agentFacingLeft: [UUID: Bool] = [:]
    @Published var activeWalkMotions: [UUID: AgentWalkMotion] = [:]
    private var walkTokens: [UUID: UUID] = [:]
    private var ambientStepIndex: Int = 0
    private var graphifyIndexingPaths: Set<String> = []
    private var lastGraphifyIndexedAt: [String: Date] = [:]
    @Published private(set) var modelMetrics: [ModelRouteKey: ModelRuntimeMetrics] = [:]
    @Published private(set) var compactionEventCount: Int = 0
    let persistConfig: Bool

    deinit {
        let aTimer = ambientTimer
        let cTimer = cronTimer
        if Thread.isMainThread {
            aTimer?.invalidate()
            cTimer?.invalidate()
        } else if aTimer != nil || cTimer != nil {
            DispatchQueue.main.async {
                aTimer?.invalidate()
                cTimer?.invalidate()
            }
        }
        pipelineTask?.cancel()
        for t in activeTasks.values {
            t.cancel()
        }
    }

    init(
        persistConfig: Bool = true,
        customWorkspacePath: String? = nil,
        customOpenClawHome: String? = nil,
        customProviders: [APIProviderConfig]? = nil,
        customAgents: [OfficeAgent]? = nil
    ) {
        self.persistConfig = persistConfig
        let cfg = persistConfig ? ConfigStore.shared.load() : AppConfig.makeDefault()
        self.providers = customProviders ?? cfg.providers
        self.agents = customAgents ?? cfg.agents
        self.workspacePath = customWorkspacePath ?? cfg.workspacePath
        self.openClawHomePath = customOpenClawHome ?? cfg.openClawHomePath
        self.cavemanMode = cfg.cavemanMode
        self.enableRTKProxy = cfg.enableRTKProxy
        self.enableLocalTools = cfg.enableLocalTools
        self.allowFileWrites = cfg.allowFileWrites
        self.autoVerifyBuild = cfg.autoVerifyBuild
        self.customBuildCommand = cfg.customBuildCommand
        self.autoSelfImprove = cfg.autoSelfImprove
        self.injectAgentsMD = cfg.injectAgentsMD
        self.injectOpenClawMemory = cfg.injectOpenClawMemory
        self.injectGraphifyReport = cfg.injectGraphifyReport
        self.enableAmbientMovement = cfg.enableAmbientMovement
        self.enableSocialChatter = cfg.enableSocialChatter
        self.enableStreaming = cfg.enableStreaming
        self.fileEdits = cfg.fileEdits
        self.roleTemplates = cfg.roleTemplates.isEmpty ? AgentRoleTemplate.defaultTemplates() : cfg.roleTemplates
        self.activePlanGoal = cfg.activePlanGoal
        self.planTasks = cfg.planTasks
        self.connectors = cfg.connectors
        self.browserHomeURL = cfg.browserHomeURL
        self.allowBrowserLocalNetwork = cfg.allowBrowserLocalNetwork
        self.cronJobs = cfg.cronJobs
        self.telegramChatId = cfg.telegramChatId
        self.telegramNotifyEnabled = cfg.telegramNotifyEnabled
        self.useIllustratedFloorBackdrop = cfg.useIllustratedFloorBackdrop
        self.browser.allowLocalNetwork = cfg.allowBrowserLocalNetwork
        if !cfg.browserHomeURL.isEmpty {
            self.browser.currentURLString = cfg.browserHomeURL
        }
        for i in self.agents.indices where self.agents[i].status.isBusy {
            self.agents[i].status = .idle
        }
        self.selectedAgentId = self.agents.first?.id

        // Auto-link/migrate agents assigned to removed/disabled/unconfigured providers onto healthy HTTP providers
        let hasHealthyHttp = self.providers.contains { $0.kind != .antigravityCLI && $0.isEnabled && $0.isConfigured }
        if hasHealthyHttp {
            var didReassign = false
            for idx in self.agents.indices {
                let currentP = self.provider(for: self.agents[idx].providerId)
                let needsMigration = currentP == nil || !currentP!.isEnabled || !currentP!.isConfigured || currentP!.kind == .antigravityCLI
                if needsMigration {
                    let decision = ModelRouter.selectModelForHire(
                        name: self.agents[idx].name,
                        title: self.agents[idx].title,
                        systemPrompt: self.agents[idx].systemPrompt,
                        requestedModel: "auto",
                        providers: self.providers,
                        existingAgents: self.agents.enumerated().filter { $0.offset != idx }.map(\.element),
                        providerStatuses: self.providerStatuses,
                        providerCooldowns: self.providerCooldowns,
                        modelMetrics: self.modelMetrics
                    )
                    self.agents[idx].providerId = decision.provider.id
                    self.agents[idx].modelId = decision.modelId
                    self.agents[idx].fallbackModelIds = decision.fallbackModelIds
                    self.agents[idx].agyConversationId = nil
                    didReassign = true
                }
            }
            if didReassign && persistConfig {
                saveConfig()
            }
        }

        OpenClawWorkspaceService.ensureOpenClawWorkspaceExists(at: self.openClawHomePath)
        refreshWorkspaceAndSkills(enabledIds: Set(cfg.enabledSkillIds))
        ensureProjectPowerStackActive(for: self.workspacePath, scheduleAutoIndex: false, reason: "Başlangıç")
        if persistConfig, let warn = ConfigStore.shared.lastLoadWarning {
            log(.warning, source: "Sistem", warn)
        }
        log(.info, source: "Sistem", "Crims Office (Canlı Ekip · OpenClaw · Swarms) başlatıldı.")
        if persistConfig {
            startAmbientLoop()
            startCronSchedulerLoop()
            checkProvidersHealth()
            Task { [weak self] in
                guard let self else { return }
                await refreshCLITools()
                await scheduleGraphifyAutoIndexIfNeeded(for: self.workspacePath, incremental: false)
                await ensureSwarmsRuntimeReady()
                await refreshOpenClawEcosystem()
                await runSecurityAudit()
            }
        }
    }

    var selectedAgent: OfficeAgent? {
        agents.first(where: { $0.id == selectedAgentId }) ?? agents.first
    }

    var activeBusyCount: Int { agents.filter { $0.status.isBusy }.count }
    var configuredProviderCount: Int { providers.filter { $0.isConfigured }.count }
    func provider(for id: UUID) -> APIProviderConfig? { providers.first(where: { $0.id == id }) }

    func saveConfig() {
        guard persistConfig else { return }
        ConfigStore.shared.save(AppConfig(
            schemaVersion: 2,
            providers: providers,
            agents: agents,
            workspacePath: workspacePath,
            openClawHomePath: openClawHomePath,
            cavemanMode: cavemanMode,
            enableRTKProxy: enableRTKProxy,
            enableLocalTools: enableLocalTools,
            allowFileWrites: allowFileWrites,
            autoVerifyBuild: autoVerifyBuild,
            customBuildCommand: customBuildCommand,
            autoSelfImprove: autoSelfImprove,
            injectAgentsMD: injectAgentsMD,
            injectOpenClawMemory: injectOpenClawMemory,
            injectGraphifyReport: injectGraphifyReport,
            enabledSkillIds: skills.filter { $0.isEnabled }.map { $0.id },
            enableAmbientMovement: enableAmbientMovement,
            enableSocialChatter: enableSocialChatter,
            enableStreaming: enableStreaming,
            fileEdits: Array(fileEdits.prefix(80)),
            roleTemplates: roleTemplates,
            activePlanGoal: activePlanGoal,
            planTasks: Array(planTasks.prefix(50)),
            connectors: connectors,
            browserHomeURL: browserHomeURL,
            allowBrowserLocalNetwork: allowBrowserLocalNetwork,
            cronJobs: cronJobs,
            telegramChatId: telegramChatId,
            telegramNotifyEnabled: telegramNotifyEnabled,
            useIllustratedFloorBackdrop: useIllustratedFloorBackdrop
        ))
    }

    func addRoleTemplate(_ template: AgentRoleTemplate) {
        if let idx = roleTemplates.firstIndex(where: { $0.id == template.id || $0.name.lowercased() == template.name.lowercased() }) {
            roleTemplates[idx] = template
        } else {
            roleTemplates.append(template)
        }
        saveConfig()
    }

    func deleteRoleTemplate(id: UUID) {
        roleTemplates.removeAll { $0.id == id && $0.isCustom }
        saveConfig()
    }

    func log(_ level: LogLevel, source: String, _ message: String) {
        logs.insert(ActivityLogEntry(level: level, source: source, message: message), at: 0)
        if logs.count > 250 { logs.removeLast(logs.count - 250) }
    }

    func recordDialogue(from agent: OfficeAgent?, toName: String, content: String, kind: DialogueKind, zeroToken: Bool = false) {
        let msg = OfficeDialogueMessage(
            fromAgentId: agent?.id,
            fromName: agent?.name ?? "Sistem",
            fromEmoji: agent?.emoji ?? "🏢",
            toName: toName,
            content: content,
            kind: kind,
            isZeroToken: zeroToken
        )
        officeDialogues.insert(msg, at: 0)
        if officeDialogues.count > 120 {
            officeDialogues.removeLast(officeDialogues.count - 120)
        }
    }

    func clearDialogues() {
        officeDialogues.removeAll()
    }

    func showBeam(from: UUID, to: UUID, label: String, accentHex: String, duration: Double = 4.5) {
        let beam = ActiveBeamLink(fromAgentId: from, toAgentId: to, label: label, accentHex: accentHex)
        withAnimation(.easeInOut(duration: 0.3)) {
            activeBeams.append(beam)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            withAnimation(.easeOut(duration: 0.4)) {
                self?.activeBeams.removeAll { $0.id == beam.id }
            }
        }
    }

    func incrementCompletedTasks(for agentId: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentId }) else { return }
        agents[i].completedTasks += 1
    }

    // MARK: - Refresh Workspace, Skills, Graphify & CLI Tools

    func setWorkspacePath(_ newPath: String) {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspacePath else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue else {
            log(.warning, source: "Sistem", "Çalışma klasörü bulunamadı veya geçersiz: \(trimmed)")
            return
        }
        workspacePath = trimmed
        for i in agents.indices {
            agents[i].agyConversationId = nil
        }
        workspaceRefreshNonce += 1
        refreshWorkspaceAndSkills()
        ensureProjectPowerStackActive(for: trimmed, scheduleAutoIndex: persistConfig, reason: "Proje değişimi")
        saveConfig()
    }

    /// Her projede Graphify AI, Caveman ve RTK AI katmanlarının aktif olmasını ve bilgi grafının otomatik oluşmasını sağlar.
    func ensureProjectPowerStackActive(for targetPath: String, scheduleAutoIndex: Bool = true, reason: String = "Proje") {
        var changed = false
        if cavemanMode == .off {
            cavemanMode = .full
            changed = true
        }
        if !enableRTKProxy {
            enableRTKProxy = true
            changed = true
        }
        if !injectGraphifyReport {
            injectGraphifyReport = true
            changed = true
        }
        let requiredPowerSkills: Set<String> = ["rtk-proxy", "graphify", "caveman"]
        for i in skills.indices where requiredPowerSkills.contains(skills[i].id) && !skills[i].isEnabled {
            skills[i].isEnabled = true
            changed = true
        }
        if changed && persistConfig {
            saveConfig()
        }
        if scheduleAutoIndex && persistConfig {
            Task { @MainActor [weak self] in
                await self?.scheduleGraphifyAutoIndexIfNeeded(for: targetPath, incremental: false)
            }
        }
    }

    func scheduleGraphifyAutoIndexIfNeeded(for targetPath: String, incremental: Bool) async {
        guard persistConfig, injectGraphifyReport else { return }
        let fm = FileManager.default
        let standardized = URL(fileURLWithPath: targetPath).standardizedFileURL.path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard !standardized.isEmpty, standardized != "/", standardized != home else { return }
        guard !graphifyIndexingPaths.contains(standardized) else { return }
        guard !PowerShellTools.which("graphify").isEmpty else { return }

        let graphJsonPath = URL(fileURLWithPath: standardized).appendingPathComponent("graphify-out/graph.json").path
        let reportPath = URL(fileURLWithPath: standardized).appendingPathComponent("graphify-out/GRAPH_REPORT.md").path
        let hasGraph = fm.fileExists(atPath: graphJsonPath) && fm.fileExists(atPath: reportPath)

        if hasGraph && !incremental {
            if URL(fileURLWithPath: workspacePath).standardizedFileURL.path == standardized && graphSnapshot == nil {
                graphSnapshot = OpenClawWorkspaceService.loadGraphifySnapshot(workspacePath: standardized)
            }
            return
        }
        if hasGraph, let lastAt = lastGraphifyIndexedAt[standardized], Date().timeIntervalSince(lastAt) < 15 {
            return
        }

        graphifyIndexingPaths.insert(standardized)
        defer {
            graphifyIndexingPaths.remove(standardized)
            lastGraphifyIndexedAt[standardized] = Date()
        }

        let projName = URL(fileURLWithPath: standardized).lastPathComponent
        if !hasGraph {
            log(.info, source: "Graphify", "📊 '\(projName)' için Graphify bilgi grafı otomatik oluşturuluyor...")
        }
        let res = await OpenClawWorkspaceService.runGraphifyUpdate(workspacePath: standardized, force: !hasGraph)
        if res.succeeded {
            let loadedSnap = OpenClawWorkspaceService.loadGraphifySnapshot(workspacePath: standardized)
            if URL(fileURLWithPath: workspacePath).standardizedFileURL.path == standardized {
                graphSnapshot = loadedSnap
            }
            let nodeCount = loadedSnap?.nodes.count ?? 0
            log(.success, source: "Graphify", "📊 '\(projName)' bilgi grafı aktif (\(nodeCount > 0 ? "\(nodeCount) çekirdek düğüm" : "GRAPH_REPORT.md hazır")).")
        } else {
            log(.warning, source: "Graphify", "⚠️ '\(projName)' graf güncellemesi atlandı: \(res.output.prefix(120))")
        }
    }

    func refreshWorkspaceAndSkills(enabledIds: Set<String>? = nil) {
        let hasExplicitSelection = (enabledIds != nil) || !skills.isEmpty
        let keep = enabledIds ?? Set(skills.filter { $0.isEnabled }.map { $0.id })
        var scanned = OpenClawWorkspaceService.discoverSkills(openClawHome: openClawHomePath, workspacePath: workspacePath)
        if hasExplicitSelection {
            for i in scanned.indices {
                scanned[i].isEnabled = keep.contains(scanned[i].id)
            }
        }
        skills = scanned
        discoveredAgentsMD = OpenClawWorkspaceService.discoverProjectAgentsMD(workspacePath: workspacePath)
        graphSnapshot = OpenClawWorkspaceService.loadGraphifySnapshot(workspacePath: workspacePath)
        if persistConfig {
            Task { @MainActor [weak self] in
                await self?.refreshGitSummary()
            }
        }
    }

    func refreshGitSummary() async {
        gitBranchSummary = await PowerShellTools.gitStatusSummary(workspacePath: workspacePath)
    }

    func refreshCLITools() async {
        cliStatus = await PowerShellTools.detectInstalledTools()
        if cliStatus.rtkInstalled {
            let gain = await PowerShellTools.runCommand("rtk gain", workspacePath: workspacePath, wrapWithRTK: false)
            if gain.succeeded {
                rtkGainSummary = gain.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        await refreshGitSummary()
    }

    func checkProvidersHealth() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = self.providers
            await withTaskGroup(of: (UUID, ProviderHealthStatus).self) { [weak self] group in
                for p in snapshot {
                    group.addTask {
                        if p.kind == .antigravityCLI {
                            return (p.id, ProviderHealthStatus(
                                providerId: p.id,
                                isOnline: false,
                                latencyMs: 0,
                                lastChecked: Date(),
                                statusMessage: "Devre dışı"
                            ))
                        }
                        let r = await LLMClient.shared.ping(provider: p)
                        return (p.id, ProviderHealthStatus(
                            providerId: p.id,
                            isOnline: r.isOnline,
                            latencyMs: r.latencyMs,
                            lastChecked: Date(),
                            statusMessage: r.message
                        ))
                    }
                }
                for await (id, st) in group {
                    if Task.isCancelled { break }
                    self?.providerStatuses[id] = st
                }
            }
        }
    }

    // MARK: - Self-Evolution & Mac System Control

    @discardableResult
    func selfRebuildAndRestart(reason: String = "") async -> (Bool, String) {
        log(.info, source: "Öz-Gelişim", "Crims Office kendini derliyor ve yeniden başlatıyor: \(reason)")
        let res = await PowerShellTools.performSelfRebuild(workspacePath: workspacePath, timeoutSeconds: 240)
        if res.0 {
            log(.success, source: "Öz-Gelişim", res.1)
        } else {
            log(.error, source: "Öz-Gelişim", String(res.1.prefix(300)))
        }
        return res
    }

    func restartApp(reason: String = "") {
        log(.info, source: "Sistem", "Uygulama yeniden başlatılıyor... \(reason)")
        PowerShellTools.triggerAppRelaunch()
    }

    func toggleSkill(id: String) {
        if let i = skills.firstIndex(where: { $0.id == id }) {
            skills[i].isEnabled.toggle()
            saveConfig()
        }
    }

    // MARK: - 1-Click Magic API Key Auto-Setup

    func quickConnectAPIKey(_ rawKey: String) async -> (Bool, String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (false, "API anahtarı boş.") }

        let targetKind: ProviderKind
        if key.hasPrefix("evren_llm_") || key.lowercased().hasPrefix("evren_") {
            targetKind = .evren
        } else if key.hasPrefix("sk-or-") {
            targetKind = .openRouter
        } else if key.hasPrefix("gsk_") {
            targetKind = .groq
        } else if key.hasPrefix("nvapi-") {
            targetKind = .nvidia
        } else {
            targetKind = .kilo
        }

        let targetId: UUID
        if let idx = providers.firstIndex(where: { $0.kind == targetKind }) {
            providers[idx].apiKey = key
            providers[idx].isEnabled = true
            targetId = providers[idx].id
        } else {
            let newProv: APIProviderConfig
            switch targetKind {
            case .groq:
                newProv = APIProviderConfig(name: "Groq", kind: .groq, baseURL: "https://api.groq.com/openai/v1", apiKey: key, authStyle: .bearer, models: ["llama-3.3-70b-versatile"], defaultModel: "llama-3.3-70b-versatile")
            case .nvidia:
                newProv = APIProviderConfig(name: "NVIDIA NIM", kind: .nvidia, baseURL: "https://integrate.api.nvidia.com/v1", apiKey: key, authStyle: .bearer, models: ["meta/llama-3.3-70b-instruct"], defaultModel: "meta/llama-3.3-70b-instruct")
            default:
                newProv = APIProviderConfig(name: targetKind.displayName, kind: targetKind, baseURL: "https://api.kilo.ai/api/gateway", apiKey: key, authStyle: .bearer, models: ["kilo/auto"], defaultModel: "kilo/auto")
            }
            providers.append(newProv)
            targetId = newProv.id
        }
        saveConfig()

        if targetKind == .evren {
            _ = await acceptEvrenTerms(for: targetId)
        }
        let modelRes = await fetchModels(for: targetId)
        let testRes = await testConnection(for: targetId)
        if testRes.0 {
            return (true, "\(targetKind.displayName) otomatik kuruldu! \(modelRes.1) · \(testRes.1)")
        } else {
            return (false, "\(targetKind.displayName) kaydedildi ancak test yanıtı: \(testRes.1)")
        }
    }

    // MARK: - Ambient Movement & Inter-Agent Social Chatter (0 Token!)

    private func startAmbientLoop() {
        ambientTimer?.invalidate()
        let timer = Timer(timeInterval: 2.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickAmbientOffice() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ambientTimer = timer
        // Açılışta ekibin hemen canlanması için kısa bir başlangıç yürüyüşü tetikle
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            self?.tickAmbientOffice(forceStroll: true)
        }
    }

    static func classifyFloorZone(for point: Point2D, deskPosition: Point2D) -> (zone: OfficeZone, bubble: String) {
        if hypot(point.x - deskPosition.x, point.y - deskPosition.y) < 0.09 {
            return (.desk, "🚶‍♀️ Masasına dönüyor")
        }
        if point.x < 0.36 && point.y > 0.66 {
            return (.coffeeLounge, "☕️ Kahve köşesine yürüyor")
        }
        if point.x > 0.64 && point.y > 0.66 {
            return (.serverRack, "🖥️ Mac Studio Hub'a gidiyor")
        }
        if point.x > 0.34 && point.x < 0.66 && point.y > 0.36 && point.y < 0.64 {
            return (.meetingRoom, "✨ Toplantı odasına geçiyor")
        }
        return (.visitingPeer, "🚶‍♀️ Stüdyoda yürüyor")
    }

    func resolveNonOverlappingTarget(_ raw: Point2D, for agentId: UUID) -> Point2D {
        var candidate = Point2D(
            x: min(0.88, max(0.10, raw.x)),
            y: min(0.84, max(0.15, raw.y))
        )
        for other in agents where other.id != agentId {
            let dx = candidate.x - other.currentPosition.x
            let dy = candidate.y - other.currentPosition.y
            let dist = hypot(dx, dy)
            if dist < 0.055 {
                let angle = dist > 0.001 ? atan2(dy, dx) : Double(abs(agentId.hashValue) % 628) / 100.0
                candidate.x = min(0.88, max(0.10, other.currentPosition.x + cos(angle) * 0.068))
                candidate.y = min(0.84, max(0.15, other.currentPosition.y + sin(angle) * 0.068))
            }
        }
        return candidate
    }

    /// Ajanın o anki gerçek 60 FPS ekrandaki konumunu döndürür (yürürken ara nokta, dururken currentPosition)
    func visualPosition(for agentId: UUID, at now: Date = Date()) -> Point2D {
        if let motion = activeWalkMotions[agentId] {
            return motion.sample(at: now).point
        }
        return agents.first(where: { $0.id == agentId })?.currentPosition ?? Point2D(x: 0.5, y: 0.5)
    }

    /// Yürüyüş kalkış/varış yumuşatma faktörü (0.0...1.0)
    func strideIntensity(for agentId: UUID, at now: Date = Date()) -> Double {
        if let motion = activeWalkMotions[agentId] {
            return motion.sample(at: now).strideIntensity
        }
        return walkingAgentIds.contains(agentId) ? 1.0 : 0.0
    }

    @MainActor
    func moveAgent(
        _ agentId: UUID,
        to rawTarget: Point2D,
        zone: OfficeZone,
        status: AgentStatus? = nil,
        bubble: String? = nil
    ) {
        guard let idx = agents.firstIndex(where: { $0.id == agentId }) else { return }
        let now = Date()
        let target = zone == .desk ? rawTarget : resolveNonOverlappingTarget(rawTarget, for: agentId)
        // Yürüyüş ortasında yön değiştirilirse ekrandaki GERÇEK konumdan başla (geriye kayma/moonwalk sıfır)
        let start = visualPosition(for: agentId, at: now)
        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = hypot(dx, dy)

        if abs(dx) > 0.012 {
            agentFacingLeft[agentId] = dx < 0
        }

        if let status {
            agents[idx].status = status
        }
        if let bubble {
            agents[idx].statusBubble = bubble
        }

        guard distance > 0.02 else {
            agents[idx].currentPosition = target
            agents[idx].currentZone = zone
            walkTokens[agentId] = nil
            walkingAgentIds.remove(agentId)
            activeWalkMotions[agentId] = nil
            return
        }

        let token = UUID()
        walkTokens[agentId] = token
        let duration = min(3.8, max(1.3, distance * 4.8))
        let bendSign: Double = (abs(agentId.hashValue) % 2 == 0) ? 1.0 : -1.0
        let arcBend = min(0.032, distance * 0.12) * bendSign

        activeWalkMotions[agentId] = AgentWalkMotion(
            from: start,
            to: target,
            startedAt: now,
            duration: duration,
            arcBend: arcBend
        )
        walkingAgentIds.insert(agentId)
        agents[idx].currentPosition = target
        agents[idx].currentZone = zone

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.walkTokens[agentId] == token else { return }
            self.walkingAgentIds.remove(agentId)
            self.activeWalkMotions[agentId] = nil
            self.walkTokens[agentId] = nil
            if let arrivedIdx = self.agents.firstIndex(where: { $0.id == agentId }),
               self.agents[arrivedIdx].currentZone == .desk,
               !self.agents[arrivedIdx].status.isBusy {
                self.agents[arrivedIdx].status = .idle
                self.agents[arrivedIdx].statusBubble = "Masasında · Hazır"
            }
        }
    }

    private static let ambientDialoguePairs: [(String, String)] = [
        ("Yeni görev var mı?", "Masada hazırım, gönder gelsin 🚀"),
        ("Ekip senkronu nasıl gidiyor?", "Her şey yolunda, akış pürüzsüz ✨"),
        ("Yeni bir fikrim var 💡", "Süper, hemen masada bakalım!"),
        ("Kahve molası verelim mi?", "Olur, 2 dakika nefes alalım ☕️"),
        ("API yanıt süreleri nasıl?", "Gayet hızlı, gecikme düşük ⚡️"),
        ("Son durumu kontrol ettin mi?", "Evet, her şey temiz ve hazır ✅"),
        ("Araştırma notları hazır mı?", "Toparladım, özetini paylaşıyorum 📊"),
        ("Sıradaki göreve hazır mısın?", "Her zaman hazırım, başlayalım 🎯")
    ]

    func tickAmbientOffice(forceStroll: Bool = false) {
        guard enableAmbientMovement else { return }
        let idleAgents = agents.filter { ($0.status == .idle || $0.status == .chatting) && !walkingAgentIds.contains($0.id) }
        guard !idleAgents.isEmpty else { return }

        // Masasından uzaklaşanlardan birini arada yumuşak adımlarla masasına geri yürüt
        if !forceStroll,
           let awayAgent = idleAgents.first(where: { $0.currentZone != .desk }),
           Int.random(in: 0..<3) == 0 {
            moveAgent(
                awayAgent.id,
                to: awayAgent.deskPosition,
                zone: .desk,
                status: .idle,
                bubble: "🚶‍♀️ Masasına dönüyor"
            )
            // Masadaki başka bir kızı aynı anda stüdyo turuna çıkar ki ofis hep canlı kalsın
        }

        // Aynı anda en fazla 3 çalışan stüdyo içinde dolaşsın (ofis hep canlı kalsın)
        let activeStrollers = agents.filter { $0.currentZone != .desk && ($0.status == .idle || $0.status == .chatting || walkingAgentIds.contains($0.id)) }.count
        guard activeStrollers < 3 else { return }

        let deskCandidates = idleAgents.filter { $0.currentZone == .desk }
        guard !deskCandidates.isEmpty else { return }
        let chosen = deskCandidates[ambientStepIndex % deskCandidates.count]
        ambientStepIndex += 1

        // Sosyal sohbet açıksa ekip arkadaşının yanına uğrayıp UI'da canlı iki yönlü sohbet başlat (0 token)
        if enableSocialChatter,
           (forceStroll || ambientStepIndex.isMultiple(of: 2)),
           let peer = idleAgents.first(where: { $0.id != chosen.id && $0.currentZone == .desk }) {
            triggerAmbientPeerDialogue(from: chosen, to: peer)
            return
        }

        let scenicSpots: [(Point2D, OfficeZone, String)] = [
            (Point2D(x: 0.28, y: 0.76), .coffeeLounge, "☕️ Kahve molası"),
            (Point2D(x: 0.39, y: 0.17), .coffeeLounge, "🌊 Sahil terası"),
            (Point2D(x: 0.74, y: 0.75), .serverRack, "🖥️ Mac Hub kontrolü"),
            (Point2D(x: 0.59, y: 0.51), .meetingRoom, "✨ Stüdyo senkronu"),
            (Point2D(x: 0.62, y: 0.17), .coffeeLounge, "🌴 Balkon havası"),
            (Point2D(x: 0.41, y: 0.49), .meetingRoom, "📝 Toplantı notu")
        ]
        let pick = scenicSpots[ambientStepIndex % scenicSpots.count]
        moveAgent(chosen.id, to: pick.0, zone: pick.1, status: .chatting, bubble: pick.2)
    }

    /// İki ajanı sohbet/toplantı sırasında birbirine doğru döndürür
    func updateMutualFacing(between firstId: UUID, and secondId: UUID) {
        guard let a = agents.first(where: { $0.id == firstId }),
              let b = agents.first(where: { $0.id == secondId }) else { return }
        let dx = b.currentPosition.x - a.currentPosition.x
        if abs(dx) > 0.005 {
            agentFacingLeft[firstId] = dx < 0
            agentFacingLeft[secondId] = dx > 0
        }
    }

    private func triggerAmbientPeerDialogue(from chosen: OfficeAgent, to peer: OfficeAgent) {
        let pair = Self.ambientDialoguePairs[ambientStepIndex % Self.ambientDialoguePairs.count]
        let offsetX = peer.deskPosition.x > 0.5 ? -0.075 : 0.075
        let spot = Point2D(
            x: min(0.86, max(0.14, peer.deskPosition.x + offsetX)),
            y: min(0.82, max(0.18, peer.deskPosition.y + 0.025))
        )
        moveAgent(chosen.id, to: spot, zone: .visitingPeer, status: .chatting, bubble: "💬 \(pair.0)")
        showBeam(from: chosen.id, to: peer.id, label: "💬 Sohbet", accentHex: chosen.accentHex, duration: 4.5)
        recordDialogue(from: chosen, toName: peer.name, content: pair.0, kind: .social, zeroToken: true)

        let peerId = peer.id
        let chosenId = chosen.id
        let chosenName = chosen.name
        let peerAccent = peer.accentHex
        let replyLine = pair.1

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self,
                  let peerIdx = self.agents.firstIndex(where: { $0.id == peerId }),
                  !self.agents[peerIdx].status.isBusy else { return }
            self.updateMutualFacing(between: chosenId, and: peerId)
            self.agents[peerIdx].status = .chatting
            self.agents[peerIdx].statusBubble = "💬 \(replyLine)"
            let livePeer = self.agents[peerIdx]
            self.showBeam(from: peerId, to: chosenId, label: "💬 Yanıt", accentHex: peerAccent, duration: 3.4)
            self.recordDialogue(from: livePeer, toName: chosenName, content: replyLine, kind: .social, zeroToken: true)

            try? await Task.sleep(for: .seconds(3.8))
            guard let restoreIdx = self.agents.firstIndex(where: { $0.id == peerId }),
                  self.agents[restoreIdx].status == .chatting else { return }
            self.agents[restoreIdx].status = .idle
            self.agents[restoreIdx].statusBubble = "Masasında · Hazır"
        }
    }

    func recallAllAgentsToDesks() {
        for agent in agents {
            let statusOverride: AgentStatus? = agent.status.isBusy ? nil : .idle
            let bubbleOverride: String? = agent.status.isBusy ? nil : "🚶‍♀️ Masasına dönüyor"
            moveAgent(
                agent.id,
                to: agent.deskPosition,
                zone: .desk,
                status: statusOverride,
                bubble: bubbleOverride
            )
        }
    }

    // MARK: - Provider & Agent CRUD

    func updateProvider(_ p: APIProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.id == p.id }) {
            providers[idx] = p
            saveConfig()
        }
    }

    func addCustomProvider(name: String, baseURL: String, apiKey: String, authStyle: AuthHeaderStyle, defaultModel: String) {
        let m = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prov = APIProviderConfig(
            name: name.isEmpty ? "Özel API" : name,
            kind: .custom,
            baseURL: baseURL,
            apiKey: apiKey,
            authStyle: authStyle,
            models: [m.isEmpty ? "gpt-4o-mini" : m],
            defaultModel: m.isEmpty ? "gpt-4o-mini" : m
        )
        providers.append(prov)
        saveConfig()
    }

    func deleteProvider(id: UUID) {
        guard providers.count > 1 else { return }
        providers.removeAll { $0.id == id }
        providerStatuses.removeValue(forKey: id)
        providerCooldowns.removeValue(forKey: id)
        if let replacement = providers.first(where: { $0.isEnabled && $0.isConfigured }) ?? providers.first {
            for i in agents.indices where agents[i].providerId == id {
                agents[i].providerId = replacement.id
                agents[i].modelId = replacement.defaultModel
                agents[i].agyConversationId = nil
            }
        }
        saveConfig()
    }

    func fetchModels(for id: UUID) async -> (Bool, String) {
        guard let initialProv = provider(for: id) else { return (false, "Sağlayıcı yok.") }
        do {
            let list = try await LLMClient.shared.fetchModels(provider: initialProv)
            guard let i = providers.firstIndex(where: { $0.id == id }) else {
                return (false, "Sağlayıcı artık mevcut değil.")
            }
            providers[i].models = list
            if !list.contains(providers[i].defaultModel), let first = list.first {
                providers[i].defaultModel = first
            }
            saveConfig()
            log(.success, source: providers[i].name, "\(list.count) model çekildi.")
            return (true, "\(list.count) model senkronize edildi.")
        } catch {
            log(.error, source: initialProv.name, error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    func testConnection(for id: UUID) async -> (Bool, String) {
        guard let prov = provider(for: id) else { return (false, "Sağlayıcı yok.") }
        let model = prov.defaultModel.isEmpty ? (prov.models.first ?? "auto") : prov.defaultModel
        do {
            let res = try await LLMClient.shared.streamChat(
                provider: prov, model: model, systemPrompt: "Kısa cevap ver.",
                messages: [ChatMessage(role: "user", content: "Sadece 'Aktif' yaz.")],
                temperature: 0.1, stream: false, allowLocalEdits: false, onDelta: { _ in }
            )
            let msg = "Bağlandı (\(res.resolvedModel) · \(res.latencyMs) ms)"
            log(.success, source: prov.name, msg)
            return (true, msg)
        } catch {
            log(.error, source: prov.name, error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    func acceptEvrenTerms(for id: UUID) async -> (Bool, String) {
        guard let initialProv = provider(for: id) else { return (false, "Bulunamadı.") }
        do {
            let res = try await LLMClient.shared.acceptEvrenTerms(provider: initialProv)
            guard let i = providers.firstIndex(where: { $0.id == id }) else {
                return (false, "Sağlayıcı artık mevcut değil.")
            }
            providers[i].evrenTermsAcceptedVersion = res.version
            saveConfig()
            log(.success, source: providers[i].name, res.summary)
            return (true, res.summary)
        } catch {
            log(.error, source: initialProv.name, error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    func checkEvrenQuota(for id: UUID) async -> (Bool, String) {
        guard let initialProv = provider(for: id) else { return (false, "Bulunamadı.") }
        do {
            let q = try await LLMClient.shared.fetchEvrenQuota(provider: initialProv)
            guard let i = providers.firstIndex(where: { $0.id == id }) else {
                return (false, "Sağlayıcı artık mevcut değil.")
            }
            providers[i].lastQuotaSummary = q
            saveConfig()
            log(.info, source: providers[i].name, q)
            return (true, q)
        } catch {
            log(.error, source: initialProv.name, error.localizedDescription)
            return (false, error.localizedDescription)
        }
    }

    func updateAgent(_ updated: OfficeAgent) {
        if let i = agents.firstIndex(where: { $0.id == updated.id }) {
            var next = updated
            let trimmedName = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
            next.name = trimmedName.isEmpty ? agents[i].name : trimmedName
            next.temperature = next.temperature.isFinite ? min(max(next.temperature, 0.0), 2.0) : 0.5
            if agents[i].providerId != next.providerId || agents[i].modelId != next.modelId || agents[i].systemPrompt != next.systemPrompt {
                next.agyConversationId = nil
            }
            agents[i] = next
            saveConfig()
        }
    }

    nonisolated static let standardDeskPositions: [Point2D] = [
        Point2D(x: 0.50, y: 0.16), // Desk 0 (Top Center Lead - Atlas)
        Point2D(x: 0.17, y: 0.22), // Desk 1 (Left Upper Wing)
        Point2D(x: 0.83, y: 0.22), // Desk 2 (Right Upper Wing)
        Point2D(x: 0.17, y: 0.56), // Desk 3 (Left Wing)
        Point2D(x: 0.83, y: 0.56), // Desk 4 (Right Wing)
        Point2D(x: 0.50, y: 0.82), // Desk 5 (Bottom Center Command)
        Point2D(x: 0.33, y: 0.34), // Desk 6 (Left Inner)
        Point2D(x: 0.67, y: 0.34), // Desk 7 (Right Inner)
        Point2D(x: 0.33, y: 0.68), // Desk 8 (Left Lower Inner)
        Point2D(x: 0.67, y: 0.68)  // Desk 9 (Right Lower Inner)
    ]

    /// Reassigns desk positions cleanly when loaded configs contain colliding legacy coordinates or overlapping desks.
    @discardableResult
    nonisolated static func normalizeCollidingDeskPositions(_ agents: inout [OfficeAgent]) -> Bool {
        guard !agents.isEmpty else { return false }

        let legacyTopRow = agents.contains { abs($0.deskPosition.y - 0.30) < 0.02 || abs($0.deskPosition.y - 0.65) < 0.02 || abs($0.deskPosition.y - 0.48) < 0.02 }
        var hasClosePair = false
        for i in 0..<agents.count {
            for j in (i + 1)..<agents.count {
                let dx = agents[i].deskPosition.x - agents[j].deskPosition.x
                let dy = agents[i].deskPosition.y - agents[j].deskPosition.y
                if abs(dx) < 0.26 && abs(dy) < 0.16 {
                    hasClosePair = true
                    break
                }
            }
            if hasClosePair { break }
        }
        guard legacyTopRow || hasClosePair else { return false }

        // Keep Atlas pinned to the lead top-center seat (Slot 0)
        if let atlasIdx = agents.firstIndex(where: { $0.name.lowercased() == "atlas" }), atlasIdx != 0 {
            agents.swapAt(0, atlasIdx)
        }
        for i in agents.indices {
            let slot = Self.standardDeskPositions[i % Self.standardDeskPositions.count]
            agents[i].deskPosition = slot
            agents[i].currentPosition = slot
        }
        return true
    }

    func nextAvailableDeskPosition() -> Point2D {
        for pos in Self.standardDeskPositions {
            let occupied = agents.contains { a in
                let dx = a.deskPosition.x - pos.x
                let dy = a.deskPosition.y - pos.y
                return abs(dx) < 0.18 && abs(dy) < 0.14
            }
            if !occupied { return pos }
        }
        let c = agents.count
        return Point2D(x: 0.18 + Double(c % 3) * 0.32, y: 0.20 + Double((c / 3) % 3) * 0.28)
    }

    func recommendedHireRoute(
        name: String,
        title: String,
        prompt: String,
        requestedModel: String = "auto"
    ) -> ModelSelectionDecision {
        ModelRouter.selectModelForHire(
            name: name,
            title: title,
            systemPrompt: prompt,
            requestedModel: requestedModel,
            providers: providers,
            existingAgents: agents,
            providerStatuses: providerStatuses,
            providerCooldowns: providerCooldowns,
            modelMetrics: modelMetrics
        )
    }

    @discardableResult
    func hireAgent(
        name: String,
        title: String,
        emoji: String,
        modelId: String,
        systemPrompt: String,
        temperature: Double = 0.25,
        avatarAsset: String? = nil,
        hiredBy: OfficeAgent? = nil
    ) -> (success: Bool, message: String, agent: OfficeAgent?) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            return (false, "Ajan adı boş olamaz.", nil)
        }
        if let existing = agents.first(where: { $0.name.lowercased() == cleanName.lowercased() }) {
            return (true, "'\(existing.name)' (\(existing.title)) zaten ofiste çalışıyor (Model: \(existing.modelId)). Doğrudan <tool name=\"delegate\">\(existing.name)|||görev</tool> ile görev devredebilirsin.", existing)
        }

        let pos = nextAvailableDeskPosition()
        let colorPalette = ["#A855F7", "#10B981", "#F59E0B", "#EC4899", "#6366F1", "#14B8A6", "#E11D48", "#8B5CF6"]
        let accentHex = colorPalette[agents.count % colorPalette.count]
        let symbols = ["chevron.left.forwardslash.chevron.right", "magnifyingglass.circle.fill", "checkmark.shield.fill", "paintbrush.pointed.fill", "wrench.and.screwdriver.fill", "bolt.fill", "terminal.fill"]
        let symbolName = symbols[agents.count % symbols.count]

        let resolvedTitle = title.isEmpty ? "Uzman Mühendis" : title
        let resolvedPrompt = systemPrompt.isEmpty
            ? "Sen \(cleanName), \(resolvedTitle) görevindeki uzmansın. Verilen görevleri en yüksek mühendislik kalitesiyle yerine getirirsin."
            : systemPrompt
        let decision = recommendedHireRoute(
            name: cleanName,
            title: resolvedTitle,
            prompt: resolvedPrompt,
            requestedModel: modelId
        )
        let matchedProv = decision.provider
        let cleanModel = decision.modelId
        let fallbacks = decision.fallbackModelIds
        let clampedTemp = temperature.isFinite ? min(max(temperature, 0.0), 2.0) : 0.25

        let resolvedAvatar = (avatarAsset?.isEmpty == false)
            ? avatarAsset!
            : OfficeAvatarPreset.defaultAsset(forIndex: agents.count)

        let newAgent = OfficeAgent(
            name: cleanName,
            title: resolvedTitle,
            emoji: emoji.isEmpty ? "⚡️" : emoji,
            avatarAsset: resolvedAvatar,
            symbolName: symbolName,
            accentHex: accentHex,
            providerId: matchedProv.id,
            modelId: cleanModel,
            systemPrompt: resolvedPrompt,
            temperature: clampedTemp,
            deskPosition: pos,
            currentPosition: pos,
            currentZone: .desk,
            status: .idle,
            statusBubble: "İşe alındı, görev bekliyor",
            messages: [],
            completedTasks: 0,
            fallbackModelIds: fallbacks
        )

        agents.append(newAgent)
        if hiredBy == nil || selectedAgentId == nil {
            selectedAgentId = newAgent.id
        }
        saveConfig()

        if let lead = hiredBy {
            showBeam(from: lead.id, to: newAgent.id, label: "🎉 İşe Alındı", accentHex: accentHex, duration: 6.0)
            recordDialogue(
                from: lead,
                toName: "Tüm Ofis",
                content: "🎉 Ajan Kaynakları (AR): '\(cleanName)' (\(newAgent.title)) işe alındı. Model: \(cleanModel) (\(matchedProv.name)) · \(decision.reason)",
                kind: .social
            )
        }
        log(.success, source: "Ajan Kaynakları", "\(cleanName) (\(newAgent.title)) işe alındı → \(cleanModel) (\(matchedProv.name)) [\(decision.reason)]")

        return (true, "✅ '\(cleanName)' (\(newAgent.title)) başarıyla işe alındı ve masasına oturdu. Model: \(cleanModel) (\(matchedProv.name)) — Seçim gerekçesi: \(decision.reason). Artık <tool name=\"delegate\">\(cleanName)|||görev detayı</tool> ile görev devredebilirsin.", newAgent)
    }

    @discardableResult
    func addAgent(
        name: String,
        title: String,
        emoji: String,
        accentHex: String,
        providerId: UUID,
        modelId: String,
        systemPrompt: String,
        temperature: Double = 0.25,
        avatarAsset: String? = nil
    ) -> (Bool, String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            return (false, "Ajan adı boş olamaz.")
        }
        if let existing = agents.first(where: { $0.name.lowercased() == cleanName.lowercased() }) {
            selectedAgentId = existing.id
            log(.warning, source: "Ajan Kaynakları", "'\(existing.name)' zaten ofiste mevcut; yeni kopya eklenmedi.")
            return (false, "'\(existing.name)' adlı ajan zaten ofiste var.")
        }
        let pos = nextAvailableDeskPosition()
        let prov = provider(for: providerId)
        let fallbacks: [String]
        switch prov?.kind {
        case .antigravityCLI:
            fallbacks = ["gemini-4-hydrogen-high", "google/gemini-4-hydrogen", "deepseek-v4.1-flash"]
        case .evren:
            fallbacks = ["deepseek-v4.1-flash", "qwen3.8-flash-next", "gemma-4-31b", "glm-5.3"]
        default:
            fallbacks = prov?.uniqueModels.filter { $0 != modelId }.prefix(3).map { $0 } ?? []
        }
        let resolvedAvatar = (avatarAsset?.isEmpty == false)
            ? avatarAsset!
            : OfficeAvatarPreset.defaultAsset(forIndex: agents.count)
        let a = OfficeAgent(
            name: cleanName, title: title.isEmpty ? "Uzman Ajan" : title,
            emoji: emoji.isEmpty ? "🤖" : emoji, avatarAsset: resolvedAvatar, symbolName: "sparkles",
            accentHex: accentHex.isEmpty ? "#38BDF8" : accentHex, providerId: providerId, modelId: modelId,
            systemPrompt: systemPrompt, temperature: temperature, deskPosition: pos, currentPosition: pos,
            fallbackModelIds: fallbacks
        )
        agents.append(a)
        selectedAgentId = a.id
        saveConfig()
        log(.success, source: "Ajan Kaynakları", "\(cleanName) (\(a.title)) ofise eklendi.")
        return (true, "\(cleanName) eklendi.")
    }

    private func clearWalkState(for id: UUID) {
        walkTokens.removeValue(forKey: id)
        walkingAgentIds.remove(id)
        activeWalkMotions.removeValue(forKey: id)
    }

    private func cleanupRemovedAgentUI(id: UUID) {
        clearWalkState(for: id)
        agentFacingLeft.removeValue(forKey: id)
        activeBeams.removeAll { $0.fromAgentId == id || $0.toAgentId == id }
        flyingPackets.removeAll { $0.fromAgentId == id || $0.toAgentId == id }
        searchedTopicsByAgent.removeValue(forKey: id)
    }

    private func appendFileEditRecord(_ record: FileEditRecord) {
        fileEdits.insert(record, at: 0)
        if fileEdits.count > 200 {
            fileEdits.removeLast(fileEdits.count - 200)
        }
        workspaceRefreshNonce += 1
    }

    func resetToSingleAgentOffice() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        activeTaskTokens.removeAll()
        walkTokens.removeAll()
        walkingAgentIds.removeAll()
        activeWalkMotions.removeAll()
        agentFacingLeft.removeAll()
        flyingPackets.removeAll()
        searchedTopicsByAgent.removeAll()
        let evrenId = providers.first(where: { $0.kind == .evren })?.id ?? (providers.first(where: { $0.kind != .antigravityCLI })?.id ?? UUID())
        agents = OfficeAgent.defaultAgents(antigravityId: nil, evrenId: evrenId)
        selectedAgentId = agents.first?.id
        officeDialogues.removeAll()
        activeBeams.removeAll()
        saveConfig()
        log(.info, source: "Ajan Kaynakları", "Ofis 1 kişilik başlangıç ekibine (Atlas AR Direktörü) sıfırlandı.")
    }

    func deleteAgent(id: UUID) {
        cancelIndividualTask(for: id)
        cleanupRemovedAgentUI(id: id)
        agents.removeAll { $0.id == id }
        if selectedAgentId == id { selectedAgentId = agents.first?.id }
        saveConfig()
    }

    func clearHistory(for id: UUID) {
        cancelIndividualTask(for: id)
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].messages.removeAll()
            agents[i].agyConversationId = nil
            saveConfig()
        }
    }

    private func cancelIndividualTask(for id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        activeTaskTokens.removeValue(forKey: id)
        clearWalkState(for: id)
        if let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].status = .idle
            agents[i].statusBubble = "Durduruldu"
            agents[i].currentPosition = agents[i].deskPosition
            agents[i].currentZone = .desk
        }
    }

    func cancelTask(for id: UUID) {
        let hadIndividual = activeTasks[id] != nil
        cancelIndividualTask(for: id)
        if isRunningPipeline, !hadIndividual {
            cancelPipeline()
        }
    }

    func rollbackEdit(id: UUID) -> (Bool, String) {
        guard let idx = fileEdits.firstIndex(where: { $0.id == id }) else {
            return (false, "Kayıt bulunamadı.")
        }
        guard !fileEdits[idx].rolledBack else {
            return (false, "Bu değişiklik daha önce geri alındı.")
        }
        let res = PowerShellTools.rollbackFileEdit(fileEdits[idx], workspacePath: workspacePath)
        if res.0 {
            fileEdits[idx].rolledBack = true
            workspaceRefreshNonce += 1
            saveConfig()
            log(.warning, source: "Geri Alma", res.1)
        }
        return res
    }

    // MARK: - OpenClaw Context Assembly

    func assembleEffectiveSystemPrompt(for agent: OfficeAgent, providerOverride: APIProviderConfig? = nil, userPrompt: String) -> String {
        var sections: [String] = [agent.systemPrompt]
        let effectiveProvider = providerOverride ?? provider(for: agent.providerId)

        let cleanWS = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanWS.isEmpty {
            var wsLines = ["- Dizin: \(cleanWS)"]
            if let git = gitBranchSummary {
                wsLines.append("- Git Dalı: \(git.branch) (\(git.dirtyCount) değiştirilmiş dosya)")
            }
            if let buildCmd = PowerShellTools.detectBuildCommand(workspacePath: cleanWS, customOverride: customBuildCommand) {
                let testCmd = PowerShellTools.detectTestCommand(workspacePath: cleanWS, customOverride: "")
                wsLines.append("- Algılanan Derleme/Test: `\(buildCmd)`" + (testCmd.map { " · test: `\($0)`" } ?? ""))
            }
            wsLines.append("- Yetkiler: Dosya Yazma \(allowFileWrites ? "AÇIK" : "KAPALI (salt-okunur)") · Otomatik Build Gate \(autoVerifyBuild ? "AÇIK" : "KAPALI")")
            if let items = try? FileManager.default.contentsOfDirectory(atPath: cleanWS) {
                let visible = items.filter { !$0.hasPrefix(".") }.sorted().prefix(28).map { name -> String in
                    var subDir: ObjCBool = false
                    let full = URL(fileURLWithPath: cleanWS).appendingPathComponent(name).path
                    _ = FileManager.default.fileExists(atPath: full, isDirectory: &subDir)
                    return subDir.boolValue ? "\(name)/" : name
                }
                if !visible.isEmpty {
                    wsLines.append("- Kök İçerik: \(visible.joined(separator: ", "))")
                }
            }
            sections.append("[AKTİF PROJE ÇALIŞMA ALANI]\n" + wsLines.joined(separator: "\n"))
        }

        if enableLocalTools {
            let usesNativeAgy = effectiveProvider?.kind == .antigravityCLI
            let connSummary = connectors
                .filter { $0.isEnabled }
                .map { "\($0.slug)(\($0.transport.rawValue), \($0.hasCredentialOrNoAuth ? "hazır" : "token bekliyor"))" }
                .joined(separator: ", ")
            sections.append(PowerShellTools.buildToolPromptAddendum(
                allowWrites: allowFileWrites,
                agentNames: agents.filter { $0.id != agent.id }.map { $0.name },
                usesNativeAntigravityTools: usesNativeAgy,
                connectorSummary: connSummary
            ))
        }

        if !planTasks.isEmpty {
            sections.append(planStatusBoardSummary())
        }

        var powerStackFlags: [String] = []
        if cavemanMode != .off {
            powerStackFlags.append("Caveman: \(cavemanMode.rawValue)")
            sections.append(cavemanMode.systemDirective)
        }
        if enableRTKProxy {
            powerStackFlags.append("RTK AI: Aktif (git/swift/npm/pytest/ls/rg/go otomatik filtrelenir)")
        }
        if injectGraphifyReport {
            powerStackFlags.append("Graphify AI: \(graphSnapshot != nil ? "Graf Hazır" : "Otomatik İndeksleniyor")")
        }
        if !powerStackFlags.isEmpty {
            sections.append("[PROJE POWER STACK AKTİF]\n- " + powerStackFlags.joined(separator: "\n- ") + "\n- Önce `graphify_query` / `GRAPH_REPORT.md` ile grafı sorgula, shell/test komutlarını RTK ile kısa tut.")
        }

        let lowerModel = agent.modelId.lowercased()
        let isFastProfile = lowerModel.contains("-low") || lowerModel.contains("-medium") || lowerModel.contains("flash") || lowerModel.contains("lite")
        if isFastProfile {
            sections.append("[AKIL YÜRÜTME DİSİPLİNİ]\nAdım adım kök neden analizi yap, kanıta dayan ve kısa-net sonuca ulaş.")
        } else {
            sections.append("""
            [AKIL YÜRÜTME & DÜŞÜNME TALİMATI — MAXIMUM REASONING EFFORT]
            Her görevde ve cevapta daima EN DERİNLEMESİNE, ADIM ADIM VE MAKSİMUM ÇABAYLA DÜŞÜN (deep chain-of-thought, maximum reasoning effort).
            Aceleci veya yüzeysel cevap verme; problemi temel bileşenlerine ayır, alternatif çözüm yollarını, olası yan etkileri ve uç durumları (edge cases) etraflıca incele, ardından en kesin ve eksiksiz çözümü üret.
            """)
        }

        if injectOpenClawMemory {
            let combined = OpenClawWorkspaceService.assembleMemoryContext(openClawHome: openClawHomePath)
            if !combined.isEmpty {
                sections.append("[OPENCLAW WORKSPACE BELLEĞİ & ÖĞRENİLEN DERSLER]\n" + combined)
            }
        }

        if injectAgentsMD && !discoveredAgentsMD.isEmpty {
            let merged = discoveredAgentsMD.map { "### \($0.relativePath)\n\($0.content)" }.joined(separator: "\n\n")
            sections.append("[PROJE AGENTS.MD KURALLARI]\n" + String(merged.prefix(3200)))
        }

        if injectGraphifyReport, let g = graphSnapshot, !g.reportMarkdown.isEmpty {
            sections.append("[GRAPHIFY BİLGİ GRAFI ÖZETİ]\n" + String(g.reportMarkdown.prefix(3500)))
        }

        let activeSkills = skills.filter { $0.isEnabled }
        if !activeSkills.isEmpty {
            let lowerPrompt = userPrompt.lowercased()
            let tokenDelimiters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/_-")).inverted
            let promptTokens = Set(
                lowerPrompt
                    .components(separatedBy: tokenDelimiters)
                    .filter { !$0.isEmpty }
            )
            var indexLines: [String] = []
            var loadedBodies: [String] = []
            var remainingBudget = 6000

            for sk in activeSkills {
                indexLines.append("- \(sk.name) (/\(sk.id)): \(sk.description)")
                let explicitSlash = lowerPrompt.contains("/\(sk.id.lowercased())")
                let triggerMatched = sk.triggers.contains { trig in
                    let clean = trig.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !clean.isEmpty else { return false }
                    if clean.contains(" ") || clean.hasPrefix("/") {
                        return lowerPrompt.contains(clean)
                    }
                    return promptTokens.contains(clean)
                }
                if (explicitSlash || triggerMatched), remainingBudget > 220 {
                    let perSkillCap = min(2400, remainingBudget)
                    let clipped = sk.body.count > perSkillCap
                        ? String(sk.body.prefix(perSkillCap)) + "\n… [bağlam bütçesi için kısaltıldı]"
                        : sk.body
                    loadedBodies.append("### Skill: \(sk.name)\n\(clipped)")
                    remainingBudget -= clipped.count
                }
            }
            sections.append("[AKTİF YETENEKLER (PROGRESSIVE DISCLOSURE)]\n" + indexLines.joined(separator: "\n"))
            if !loadedBodies.isEmpty {
                sections.append("[YÜKLENEN SKILL TALİMATLARI]\n" + loadedBodies.joined(separator: "\n\n"))
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Autonomous Plan Board, Cooldown & Shared Delegation Helpers

    func clearPlan() {
        activePlanGoal = ""
        planTasks = []
        saveConfig()
    }

    func applyCreatePlan(goal: String, rawTasks: String, by callerName: String) -> String {
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: ";\n")
        let items = rawTasks
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        activePlanGoal = cleanGoal.isEmpty ? "Otonom Görev Planı" : cleanGoal
        let knownNames = Set(agents.map { $0.name.lowercased() } + roleTemplates.map { $0.name.lowercased() })
        planTasks = items.enumerated().map { idx, item in
            var title = item
            var assignee = callerName
            if let atRange = item.range(of: "[@"), let closeRange = item.range(of: "]", range: atRange.upperBound..<item.endIndex) {
                let candidate = String(item[atRange.upperBound..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    assignee = candidate
                }
                title.removeSubrange(atRange.lowerBound..<closeRange.upperBound)
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let matchRange = item.range(of: #"(?:^|\s)@([\p{L}\p{N}_-]+)(?=$|\s|[,.;:])"#, options: .regularExpression) {
                let matched = String(item[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let candidate = matched.hasPrefix("@") ? String(matched.dropFirst()) : matched
                if knownNames.contains(candidate.lowercased()) || !item[matchRange.upperBound...].hasPrefix(".") {
                    assignee = candidate
                    title.removeSubrange(matchRange)
                    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if title.isEmpty { title = "Görev \(idx + 1)" }
            return OfficePlanTask(title: title, assigneeName: assignee.isEmpty ? callerName : assignee, status: .pending)
        }
        if planTasks.isEmpty {
            planTasks = [OfficePlanTask(title: activePlanGoal, assigneeName: callerName, status: .inProgress)]
        }
        log(.info, source: callerName, "📋 Plan oluşturuldu (\(planTasks.count) görev): \(activePlanGoal.prefix(80))")
        saveConfig()
        return planStatusBoardSummary()
    }

    func findPlanTaskIndex(matching identifier: String) -> Int? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let numericToken = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if let oneBased = Int(numericToken), oneBased >= 1, oneBased <= planTasks.count {
            return oneBased - 1
        }
        let lower = trimmed.lowercased()
        if let exact = planTasks.firstIndex(where: { $0.title.lowercased() == lower }) {
            return exact
        }
        if let prefixMatch = planTasks.firstIndex(where: { $0.title.lowercased().hasPrefix(lower) }) {
            return prefixMatch
        }
        return planTasks.firstIndex(where: { $0.title.lowercased().contains(lower) || lower.contains($0.title.lowercased()) })
    }

    func applyUpdateTask(identifier: String, rawStatus: String, note: String = "", assignee: String? = nil) -> String {
        guard let idx = findPlanTaskIndex(matching: identifier) else {
            return "Görev bulunamadı: '\(identifier)'. Mevcut görevler:\n\(planStatusBoardSummary())"
        }
        let s = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch s {
        case "in_progress", "inprogress", "sürüyor", "active", "working":
            planTasks[idx].status = .inProgress
        case "done", "completed", "tamamlandı", "ok", "finished":
            planTasks[idx].status = .done
        case "blocked", "engelli", "failed", "error":
            planTasks[idx].status = .blocked
        default:
            planTasks[idx].status = .pending
        }
        if let a = assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            planTasks[idx].assigneeName = a
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanNote.isEmpty {
            planTasks[idx].note = cleanNote
        }
        planTasks[idx].updatedAt = Date()
        saveConfig()
        return "Görev #\(idx + 1) güncellendi → \(planTasks[idx].status.rawValue)\n\(planStatusBoardSummary())"
    }

    func planStatusBoardSummary() -> String {
        guard !planTasks.isEmpty else { return "" }
        let doneCount = planTasks.filter { $0.status == .done }.count
        var lines = ["[AKTİF GÖREV PLANI: \(activePlanGoal) (\(doneCount)/\(planTasks.count) tamam)]"]
        for (i, t) in planTasks.enumerated() {
            let icon: String
            switch t.status {
            case .done: icon = "✅"
            case .inProgress: icon = "🔄"
            case .blocked: icon = "⚠️"
            case .pending: icon = "⏳"
            }
            let notePart = t.note.isEmpty ? "" : " — \(t.note)"
            lines.append("\(i + 1). \(icon) [\(t.status.rawValue)] \(t.title) (@\(t.assigneeName))\(notePart)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func autoContinuationDirective(
        userPrompt: String,
        currentProse: String,
        planTasks: [OfficePlanTask],
        hiredInTurn: Int,
        delegatedInTurn: Int,
        autoContinueCount: Int,
        maxAutoContinues: Int,
        handoffDepth: Int
    ) -> String? {
        guard handoffDepth == 0, autoContinueCount < maxAutoContinues else { return nil }

        let trimmed = currentProse.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let lowerPrompt = userPrompt.lowercased()

        if trimmed.hasSuffix("?") && (lower.contains("lütfen") || lower.contains("onay") || lower.contains("tercih")) {
            return nil
        }

        let remainingTasks = planTasks.enumerated().filter { $0.element.status == .pending || $0.element.status == .inProgress }
        if !remainingTasks.isEmpty {
            let pendingList = remainingTasks.map { "#\($0.offset + 1) \($0.element.title) (@\($0.element.assigneeName))" }.joined(separator: ", ")
            return """
            [OTONOM SÜREKLİLİK KONTROLÜ (\(autoContinueCount + 1)/\(maxAutoContinues))]:
            Aktif planda hâlâ tamamlanmamış görevler var: \(pendingList).
            Durmadan devam et! Sıradaki görevi ilgili araçla (`assign_task`, `delegate`, `shell`, `patch_file`, `write_file`) hemen yürüt ve biten görevleri `<tool name="update_task">no|||done|||özet</tool>` ile kapat.
            """
        }

        let promptExpectsExecutionAfterHire = lowerPrompt.contains("geliştir")
            || lowerPrompt.contains("çöz")
            || lowerPrompt.contains("düzelt")
            || lowerPrompt.contains("plan")
            || lowerPrompt.contains("task")
            || lowerPrompt.contains("görev ver")
            || lowerPrompt.contains("devret")
            || lowerPrompt.contains("build")
            || lowerPrompt.contains("test")
        if hiredInTurn > 0 && delegatedInTurn == 0 && promptExpectsExecutionAfterHire && !lowerPrompt.contains("hire_agent") {
            return """
            [OTONOM SÜREKLİLİK KONTROLÜ (\(autoContinueCount + 1)/\(maxAutoContinues))]:
            Bu turda yeni ekip arkadaşı işe aldın ancak henüz hiçbirine görev atamadın!
            Durmadan devam et: işe aldığın ajana `<tool name="assign_task">` veya `<tool name="delegate">` ile somut görev ver ya da `<tool name="shell">` ile terminalden doğrula.
            """
        }

        let looksLikeIncompleteAction = !lower.contains("### ✅")
            && !trimmed.isEmpty
            && (lower.contains("sonraki adım")
                || lower.contains("devam ed")
                || lower.contains("yapacağım")
                || lower.contains("inceleyeceğim")
                || lower.contains("çalıştıracağım")
                || lower.contains("kontrol edeceğim")
                || lower.contains("düzelteceğim"))
        if looksLikeIncompleteAction {
            return """
            [OTONOM SÜREKLİLİK KONTROLÜ (\(autoContinueCount + 1)/\(maxAutoContinues))]:
            Yanıtında sıradaki adımı belirttin fakat ilgili `<tool>` çağrısını henüz göndermedin.
            Yarıda durma! Bir sonraki aksiyonu şimdi `<tool name="...">parametre</tool>` ile gerçekten yürüt (terminal için `<tool name="shell">...</tool>`, ekip için `hire_agent` / `assign_task` / `delegate`); ancak tüm iş bittiğinde `### ✅ Sonuç & Doğrulama` ile nihai raporu ver.
            """
        }
        return nil
    }

    func isProviderInCooldown(_ id: UUID) -> Bool {
        guard let until = providerCooldowns[id] else { return false }
        if Date() >= until {
            providerCooldowns.removeValue(forKey: id)
            return false
        }
        return true
    }

    func markProviderCooldown(_ id: UUID, seconds: TimeInterval = 60) {
        providerCooldowns[id] = Date().addingTimeInterval(seconds)
    }

    func isModelInCooldown(providerId: UUID, modelId: String, now: Date = Date()) -> Bool {
        let key = ModelRouteKey(providerId: providerId, modelId: modelId)
        guard let metrics = modelMetrics[key] else { return false }
        if metrics.isInCooldown(now: now) { return true }
        if metrics.cooldownUntil != nil {
            modelMetrics[key]?.cooldownUntil = nil
        }
        return false
    }

    func markModelCooldown(providerId: UUID, modelId: String, seconds: TimeInterval, isRateLimit: Bool = false) {
        let key = ModelRouteKey(providerId: providerId, modelId: modelId)
        var m = modelMetrics[key, default: ModelRuntimeMetrics()]
        m.consecutiveErrors += 1
        if isRateLimit { m.rateLimitCount += 1 }
        m.cooldownUntil = Date().addingTimeInterval(seconds)
        modelMetrics[key] = m
    }

    func beginModelInFlight(providerId: UUID, modelId: String) {
        let key = ModelRouteKey(providerId: providerId, modelId: modelId)
        var m = modelMetrics[key, default: ModelRuntimeMetrics()]
        m.inFlightCount += 1
        m.lastUsedAt = Date()
        modelMetrics[key] = m
    }

    func endModelInFlight(providerId: UUID, modelId: String) {
        let key = ModelRouteKey(providerId: providerId, modelId: modelId)
        guard var m = modelMetrics[key] else { return }
        m.inFlightCount = max(0, m.inFlightCount - 1)
        modelMetrics[key] = m
    }

    func providerInFlightCount(_ providerId: UUID) -> Int {
        modelMetrics
            .filter { $0.key.providerId == providerId }
            .reduce(0) { $0 + $1.value.inFlightCount }
    }

    static func isRateLimitErrorMessage(_ rawError: String) -> Bool {
        let lower = rawError.lowercased()
        let markers = [
            "429", "rate limit", "ratelimiterror", "too many requests",
            "quota", "capacity", "overloaded", "busy", "unavailable",
            "eşzamanlı", "yoğun", "akışı durdu", "yanıt vermeyi durdurdu"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func isFatalAuthOrNetworkMessage(_ rawError: String) -> Bool {
        let lower = rawError.lowercased()
        let markers = [
            "http 401", "http 403", "unauthorized", "authentication",
            "invalid token", "sign in again", "invalid url",
            "geçersiz api", "api anahtarı", "could not connect",
            "cannot connect", "cannot find host", "connection refused", "bulunamadı"
        ]
        return markers.contains { lower.contains($0) }
    }

    private func recordModelSuccess(providerId: UUID, modelId: String, latencyMs: Int) {
        let key = ModelRouteKey(providerId: providerId, modelId: modelId)
        var m = modelMetrics[key, default: ModelRuntimeMetrics()]
        m.consecutiveErrors = 0
        m.cooldownUntil = nil
        m.successCount += 1
        let ms = Double(max(1, latencyMs))
        m.ewmaLatencyMs = m.ewmaLatencyMs == 0 ? ms : (m.ewmaLatencyMs * 0.7 + ms * 0.3)
        m.lastUsedAt = Date()
        modelMetrics[key] = m
        providerCooldowns.removeValue(forKey: providerId)
        providerConsecutiveErrors[providerId] = 0
    }

    private func recordModelFailure(provider: APIProviderConfig, modelId: String, error: Error) {
        let rawDesc = error.localizedDescription
        let isRateLimit = Self.isRateLimitErrorMessage(rawDesc)
        let isAuthOrOffline = Self.isFatalAuthOrNetworkMessage(rawDesc)

        let key = ModelRouteKey(providerId: provider.id, modelId: modelId)
        let prevErrs = modelMetrics[key]?.consecutiveErrors ?? 0
        let modelCooldownSecs: TimeInterval
        if isRateLimit {
            let exp = min(3, prevErrs)
            modelCooldownSecs = min(240, 35.0 * pow(2.0, Double(exp)))
        } else {
            modelCooldownSecs = min(150, Double(max(1, prevErrs + 1)) * 30.0)
        }
        markModelCooldown(providerId: provider.id, modelId: modelId, seconds: modelCooldownSecs, isRateLimit: isRateLimit)

        let provStreak = (providerConsecutiveErrors[provider.id] ?? 0) + 1
        providerConsecutiveErrors[provider.id] = provStreak

        if isAuthOrOffline {
            markProviderCooldown(provider.id, seconds: 300)
        } else if provStreak >= 2 {
            // Back-to-back timeouts/stalls/5xx on the same gateway immediately yield to healthy providers
            markProviderCooldown(provider.id, seconds: 45)
        } else {
            let now = Date()
            let cooledModelsOnProv = modelMetrics.filter {
                $0.key.providerId == provider.id && $0.value.isInCooldown(now: now)
            }.count
            let provModelCount = max(1, provider.uniqueModels.count)
            if cooledModelsOnProv >= min(3, provModelCount) {
                markProviderCooldown(provider.id, seconds: 60)
            }
        }
    }

    private func performDelegation(
        fromAgentId agentId: UUID,
        callerName: String,
        targetName: String,
        subTask: String,
        taskIdentifier: String? = nil,
        zone: OfficeZone,
        handoffDepth: Int,
        handoffChain: Set<UUID>
    ) async -> (output: String, record: ToolCallRecord, succeeded: Bool) {
        let nextChain = handoffChain.union([agentId])
        guard let peer = agents.first(where: { $0.name.lowercased() == targetName.lowercased() && $0.id != agentId }),
              let caller = agents.first(where: { $0.id == agentId }) else {
            let err = "'\(targetName)' adlı ekip arkadaşı bulunamadı. Önce hire_agent ile işe alabilirsin."
            return ("[Delegate Hatası]: \(err)", ToolCallRecord(name: "delegate", argument: targetName, output: err, succeeded: false), false)
        }

        if nextChain.contains(peer.id) {
            let err = "'\(peer.name)' zaten bu ekip görev zincirinde aktif ve senden yanıt bekliyor. Döngüyü önlemek için başka uzmana devret veya elindeki çıktıyı doğrudan sun."
            log(.warning, source: callerName, "Döngüsel devir engellendi → \(peer.name)")
            return ("[Delegate Engellendi (\(peer.name))]: \(err)", ToolCallRecord(name: "delegate", argument: targetName, output: err, succeeded: false), false)
        }

        var matchedTaskId: UUID? = nil
        if let tid = taskIdentifier, !tid.isEmpty {
            if let idx = findPlanTaskIndex(matching: tid) {
                matchedTaskId = planTasks[idx].id
                planTasks[idx].status = .inProgress
                planTasks[idx].assigneeName = peer.name
                planTasks[idx].updatedAt = Date()
            } else {
                let newTask = OfficePlanTask(title: tid, assigneeName: peer.name, status: .inProgress)
                planTasks.append(newTask)
                matchedTaskId = newTask.id
            }
            saveConfig()
        }

        showBeam(from: agentId, to: peer.id, label: "🤝 Görev", accentHex: caller.accentHex, duration: 5.5)
        emitFlyingPacket(from: agentId, to: peer.id, label: taskIdentifier ?? "Görev", accentHex: caller.accentHex)
        recordDialogue(from: caller, toName: peer.name, content: subTask, kind: .handoff)
        log(.tool, source: callerName, "Ekip görevi → \(peer.name): \(subTask.prefix(80))")

        if let curIdx = agents.firstIndex(where: { $0.id == agentId }) {
            agents[curIdx].status = .collaborating
            agents[curIdx].statusBubble = "🤝 \(peer.name) bekleniyor..."
        }

        let childToken = UUID()
        activeTaskTokens[peer.id] = childToken
        let childTask = Task { @MainActor [weak self] () -> String? in
            guard let self else { return nil }
            return await self.executeTurn(
                agentId: peer.id,
                prompt: "[\(callerName) EKİP GÖREVİ]\n\(subTask)",
                zone: zone,
                handoffDepth: handoffDepth + 1,
                handoffChain: nextChain,
                turnToken: childToken
            )
        }
        activeTasks[peer.id] = Task { _ = await childTask.value }
        let peerReply = await withTaskCancellationHandler {
            await childTask.value
        } onCancel: {
            childTask.cancel()
        }
        if activeTaskTokens[peer.id] == childToken {
            activeTasks.removeValue(forKey: peer.id)
            activeTaskTokens.removeValue(forKey: peer.id)
        }
        if Task.isCancelled {
            return (
                "[Delegate İptal Edildi]: Görev kullanıcı tarafından durduruldu.",
                ToolCallRecord(name: taskIdentifier != nil ? "assign_task" : "delegate", argument: "\(peer.name): \(subTask.prefix(40))", output: "Durduruldu", succeeded: false),
                false
            )
        }

        if let peerReply {
            if let curIdx = agents.firstIndex(where: { $0.id == agentId }) {
                agents[curIdx].status = .working
                agents[curIdx].statusBubble = "✅ \(peer.name) yanıtladı"
            }
            if let tId = matchedTaskId, let tidx = planTasks.firstIndex(where: { $0.id == tId }) {
                planTasks[tidx].status = .done
                planTasks[tidx].note = String(peerReply.prefix(120))
                planTasks[tidx].updatedAt = Date()
                saveConfig()
            }
            showBeam(from: peer.id, to: agentId, label: "✅ İnceleme", accentHex: peer.accentHex, duration: 4.5)
            recordDialogue(from: peer, toName: callerName, content: String(peerReply.prefix(240)), kind: .review)
            return (
                "[\(peer.name) İnceleme Yanıtı]:\n\(peerReply)",
                ToolCallRecord(name: taskIdentifier != nil ? "assign_task" : "delegate", argument: "\(peer.name): \(subTask.prefix(40))", output: peerReply, succeeded: true),
                true
            )
        } else {
            if let curIdx = agents.firstIndex(where: { $0.id == agentId }) {
                agents[curIdx].status = .working
                agents[curIdx].statusBubble = "⚠️ \(peer.name) yanıtlayamadı"
            }
            if let tId = matchedTaskId, let tidx = planTasks.firstIndex(where: { $0.id == tId }) {
                planTasks[tidx].status = .blocked
                planTasks[tidx].note = "\(peer.name) yanıt veremedi"
                planTasks[tidx].updatedAt = Date()
                saveConfig()
            }
            let err = "\(peer.name) görev sırasında yanıt veremedi veya görev durduruldu."
            return (
                "[Delegate Hatası (\(peer.name))]: \(err)",
                ToolCallRecord(name: taskIdentifier != nil ? "assign_task" : "delegate", argument: "\(peer.name): \(subTask.prefix(40))", output: err, succeeded: false),
                false
            )
        }
    }

    private func runTurnStepWithFailover(
        agentId: UUID,
        replyId: UUID,
        zone: OfficeZone,
        agentSnapshot: OfficeAgent,
        primaryProvider: APIProviderConfig,
        primaryModel: String,
        userPrompt: String,
        messages: [ChatMessage],
        maxAttempts: Int,
        agyConversationId: String?,
        bannerPrefix: String,
        reasoningStepLabel: String?,
        preserveExistingProseWhenEmpty: Bool
    ) async -> (response: LLMFinalResponse, provider: APIProviderConfig, usedFallback: Bool, lastError: Error?) {
        let baseCandidates = failoverCandidates(
            primaryProvider: primaryProvider,
            primaryModel: primaryModel,
            agentFallbackModelIds: agentSnapshot.fallbackModelIds,
            preferIdleOverBusy: true
        )
        let limited = Array(baseCandidates.prefix(maxAttempts))
        var activeMessages = messages
        var overflowCompactionCount = 0
        var lastErr: Error? = nil

        for (idx, cand) in limited.enumerated() {
            if Task.isCancelled {
                return (LLMFinalResponse(content: "", reasoning: "", resolvedModel: cand.model, latencyMs: 0), cand.provider, idx > 0, CancellationError())
            }
            let currentProv = cand.provider
            let currentModel = cand.model
            let isSwitchedFromPrimary = (currentProv.id != primaryProvider.id || currentModel != primaryModel)
            let isFallbackAttempt = idx > 0 || cand.isFallback || isSwitchedFromPrimary
            let candAgyConvId = (!isSwitchedFromPrimary && currentProv.kind == .antigravityCLI) ? agyConversationId : nil

            if idx > 0 || cand.isFallback {
                let primaryBusyOrCooled = (modelMetrics[ModelRouteKey(providerId: primaryProvider.id, modelId: primaryModel)]?.inFlightCount ?? 0) > 0
                    || isModelInCooldown(providerId: primaryProvider.id, modelId: primaryModel)
                    || isProviderInCooldown(primaryProvider.id)
                let verb = (idx == 0 && primaryBusyOrCooled) ? "Yoğunluk Geçişi" : "Otomatik Devralma"
                log(.warning, source: agentSnapshot.name, "🔄 [\(verb)] \(currentProv.name) / \(currentModel) devralıyor...")
                failoverEventCount += 1
                lastFailoverNotice = "\(primaryProvider.name) → \(currentProv.name)"
                withAnimation {
                    if let ai = agents.firstIndex(where: { $0.id == agentId }) {
                        agents[ai].statusBubble = "🔄 Devraldı: \(currentModel.components(separatedBy: "/").last ?? currentModel)"
                    }
                }
                showBeam(from: agentId, to: agentId, label: "🔄 Devraldı", accentHex: "#F59E0B", duration: 3.5)
            } else {
                log(.info, source: agentSnapshot.name, "İstek → \(currentProv.name) / \(currentModel)")
            }

            let stepSystem = assembleEffectiveSystemPrompt(
                for: agentSnapshot,
                providerOverride: currentProv,
                userPrompt: userPrompt
            )

            var overflowAttemptsForCand = 0
            while true {
                beginModelInFlight(providerId: currentProv.id, modelId: currentModel)
                do {
                    let res = try await streamTurnWithLiveUpdates(
                        agentId: agentId,
                        replyId: replyId,
                        zone: zone,
                        provider: currentProv,
                        model: currentModel,
                        systemPrompt: stepSystem,
                        messages: activeMessages,
                        temperature: agentSnapshot.temperature,
                        agyConversationId: candAgyConvId,
                        bannerPrefix: bannerPrefix,
                        reasoningStepLabel: reasoningStepLabel,
                        preserveExistingProseWhenEmpty: preserveExistingProseWhenEmpty
                    )
                    endModelInFlight(providerId: currentProv.id, modelId: currentModel)
                    recordModelSuccess(providerId: currentProv.id, modelId: currentModel, latencyMs: res.latencyMs)
                    if !isFallbackAttempt && idx == 0 {
                        lastFailoverNotice = ""
                    }
                    return (res, currentProv, isFallbackAttempt, nil)
                } catch {
                    endModelInFlight(providerId: currentProv.id, modelId: currentModel)
                    if Task.isCancelled {
                        return (LLMFinalResponse(content: "", reasoning: "", resolvedModel: currentModel, latencyMs: 0), currentProv, isFallbackAttempt, error)
                    }
                    if ContextCompactor.isContextOverflowError(error) && overflowCompactionCount < 2 && overflowAttemptsForCand == 0 {
                        overflowAttemptsForCand += 1
                        overflowCompactionCount += 1
                        let budget = overflowCompactionCount == 1 ? 12_000 : 5_500
                        let keepCount = overflowCompactionCount == 1 ? 4 : 2
                        let compacted = ContextCompactor.compactHistory(activeMessages, charBudget: budget, keepRecentCount: keepCount, force: true)
                        if compacted.didCompact && !compacted.messages.isEmpty {
                            activeMessages = compacted.messages
                            compactionEventCount += 1
                            log(.warning, source: agentSnapshot.name, "🗜️ Bağlam sınırı aşıldı; oto-compact #\(overflowCompactionCount) uygulandı (\(compacted.originalCharCount) → \(compacted.finalCharCount) kr), aynı modelde yeniden deneniyor.")
                            continue
                        }
                    }
                    lastErr = error
                    recordModelFailure(provider: currentProv, modelId: currentModel, error: error)
                    log(.warning, source: agentSnapshot.name, "⚠️ \(currentProv.name) / \(currentModel) yanıt vermedi: \(error.localizedDescription)")
                    break
                }
            }

            if idx + 1 < limited.count {
                let next = limited[idx + 1]
                log(.warning, source: agentSnapshot.name, "➡️ Sıradaki modele geçiliyor: \(next.provider.name) / \(next.model)")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return (LLMFinalResponse(content: "", reasoning: "", resolvedModel: primaryModel, latencyMs: 0), primaryProvider, false, lastErr ?? LLMClientError.emptyResponse)
    }

    @discardableResult
    func compactAgentHistory(
        for agentId: UUID,
        charBudget: Int = 24_000,
        keepRecentCount: Int = 10,
        force: Bool = true
    ) -> ContextCompactor.CompactionResult {
        guard let idx = agents.firstIndex(where: { $0.id == agentId }) else {
            return ContextCompactor.CompactionResult(messages: [], summaryText: "", compactedMessageCount: 0, originalCharCount: 0, finalCharCount: 0)
        }
        let result = ContextCompactor.compactHistory(
            agents[idx].messages,
            charBudget: charBudget,
            keepRecentCount: keepRecentCount,
            force: force
        )
        if result.didCompact && !result.messages.isEmpty {
            agents[idx].messages = result.messages
            agents[idx].agyConversationId = nil
            compactionEventCount += 1
            saveConfig()
            log(.info, source: agents[idx].name, "🗜️ Oto-Compact: \(result.compactedMessageCount) mesaj özetlendi (\(result.originalCharCount) → \(result.finalCharCount) kr).")
        }
        return result
    }

    // MARK: - Direct Execution + Multi-Step Tools + Inter-Agent Delegation (Loop Guarded)

    func sendMessage(to agentId: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.lowercased() == "/compact" {
            let res = compactAgentHistory(for: agentId, force: true)
            if !res.didCompact {
                log(.info, source: "Auto-Compact", "Sıkıştırılacak yeterli geçmiş yok (\(res.originalCharCount) kr).")
            }
            return
        }

        let lowerTrimmed = trimmed.lowercased()
        if lowerTrimmed == "/caveman" || lowerTrimmed.hasPrefix("/caveman ") {
            let arg = lowerTrimmed.dropFirst("/caveman".count).trimmingCharacters(in: .whitespaces)
            switch arg {
            case "off", "stop": cavemanMode = .off
            case "lite": cavemanMode = .lite
            case "ultra": cavemanMode = .ultra
            default: cavemanMode = .full
            }
            saveConfig()
            log(.info, source: "Caveman", "Mod → \(cavemanMode.rawValue)")
            return
        }

        activeTasks[agentId]?.cancel()
        let token = UUID()
        activeTaskTokens[agentId] = token
        activeTasks[agentId] = Task { @MainActor [weak self] in
            _ = await self?.executeTurn(agentId: agentId, prompt: trimmed, zone: .desk, handoffDepth: 0, turnToken: token)
            if self?.activeTaskTokens[agentId] == token {
                self?.activeTasks.removeValue(forKey: agentId)
                self?.activeTaskTokens.removeValue(forKey: agentId)
            }
        }
    }

    private func streamTurnWithLiveUpdates(
        agentId: UUID,
        replyId: UUID,
        zone: OfficeZone,
        provider: APIProviderConfig,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        agyConversationId: String?,
        bannerPrefix: String,
        reasoningStepLabel: String?,
        preserveExistingProseWhenEmpty: Bool
    ) async throws -> LLMFinalResponse {
        let (stream, continuation) = AsyncStream.makeStream(of: LLMStreamDelta.self)
        let consumer = Task { @MainActor [weak self] in
            var streamedRaw = ""
            for await delta in stream {
                guard let self, !Task.isCancelled,
                      let ai = self.agents.firstIndex(where: { $0.id == agentId }),
                      let mi = self.agents[ai].messages.firstIndex(where: { $0.id == replyId }) else { continue }

                if let toolBubble = delta.activeToolBubble {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        self.agents[ai].status = .runningTool
                        if reasoningStepLabel == nil {
                            self.agents[ai].currentPosition = Point2D(x: 0.80, y: 0.72)
                            self.agents[ai].currentZone = .serverRack
                        }
                        self.agents[ai].statusBubble = toolBubble
                    }
                }
                if let completed = delta.completedToolCall {
                    self.agents[ai].messages[mi].toolCalls.append(completed)
                    self.totalToolCallsExecuted += 1
                }
                if delta.touchedFilePath != nil {
                    self.workspaceRefreshNonce += 1
                }
                if !delta.reasoningChunk.isEmpty {
                    self.agents[ai].messages[mi].reasoning = (self.agents[ai].messages[mi].reasoning ?? "") + delta.reasoningChunk
                    self.agents[ai].status = .thinking
                    self.agents[ai].statusBubble = reasoningStepLabel ?? "🧠 Akıl yürütüyor..."
                }
                if !delta.contentChunk.isEmpty {
                    streamedRaw += delta.contentChunk
                    let cleanLive = PowerShellTools.stripToolTags(from: streamedRaw, stripTrailingIncomplete: true)
                    if !cleanLive.isEmpty {
                        self.agents[ai].messages[mi].content = bannerPrefix + cleanLive
                    } else if !preserveExistingProseWhenEmpty {
                        self.agents[ai].messages[mi].content = "⚡️ Araç çalıştırılıyor..."
                    }
                    if reasoningStepLabel == nil && zone != .meetingRoom && self.agents[ai].currentZone == .serverRack {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                            self.agents[ai].currentPosition = self.agents[ai].deskPosition
                            self.agents[ai].currentZone = zone
                        }
                    }
                    self.agents[ai].status = zone == .meetingRoom ? .collaborating : .working
                    self.agents[ai].statusBubble = String((cleanLive.isEmpty ? streamedRaw : cleanLive).replacingOccurrences(of: "\n", with: " ").suffix(38))
                }
            }
        }

        do {
            let res = try await LLMClient.shared.streamChat(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                stream: enableStreaming,
                workspacePath: workspacePath,
                allowLocalEdits: allowFileWrites,
                agyConversationId: agyConversationId,
                onDelta: { delta in
                    continuation.yield(delta)
                }
            )
            continuation.finish()
            await consumer.value
            return res
        } catch {
            continuation.finish()
            consumer.cancel()
            await consumer.value
            throw error
        }
    }

    @discardableResult
    func executeTurn(agentId: UUID, prompt: String, zone: OfficeZone, handoffDepth: Int = 0, handoffChain: Set<UUID> = [], turnToken: UUID? = nil) async -> String? {
        guard let initialIdx = agents.firstIndex(where: { $0.id == agentId }),
              let prov = provider(for: agents[initialIdx].providerId) else { return nil }

        withAnimation(.spring(response: 0.85, dampingFraction: 0.78)) {
            if zone == .meetingRoom {
                let angle = Double(initialIdx) * (2.0 * Double.pi / Double(max(1, agents.count)))
                agents[initialIdx].currentPosition = Point2D(x: 0.50 + cos(angle) * 0.125, y: 0.50 + sin(angle) * 0.082)
            } else {
                agents[initialIdx].currentPosition = agents[initialIdx].deskPosition
            }
            agents[initialIdx].currentZone = zone
            agents[initialIdx].status = zone == .meetingRoom ? .collaborating : .thinking
            agents[initialIdx].statusBubble = "\(prov.name) bağlanıyor..."
        }

        agents[initialIdx].messages.append(ChatMessage(role: "user", content: prompt))
        let replyId = UUID()
        agents[initialIdx].messages.append(ChatMessage(id: replyId, role: "assistant", content: "", modelUsed: agents[initialIdx].modelId, providerName: prov.name))

        func liveIndices() -> (ai: Int, mi: Int)? {
            guard let aIdx = agents.firstIndex(where: { $0.id == agentId }),
                  let mIdx = agents[aIdx].messages.firstIndex(where: { $0.id == replyId }) else { return nil }
            return (aIdx, mIdx)
        }

        let model = agents[initialIdx].modelId.isEmpty ? prov.defaultModel : agents[initialIdx].modelId
        let initialConvId = (zone == .desk && prov.kind == .antigravityCLI) ? agents[initialIdx].agyConversationId : nil
        let agentName = agents[initialIdx].name
        let reqId = beginTrackedRequest(title: prompt, prompt: prompt, agentName: agentName, modelName: model)
        advanceTrackedRequest(reqId, to: .analyzing, agentName: agentName, modelName: model)

        func resetCancelled() {
            advanceTrackedRequest(reqId, to: .done, agentName: agentName, modelName: model, failed: true)
            let isCurrentTurn = (turnToken == nil) || (activeTaskTokens[agentId] == nil) || (activeTaskTokens[agentId] == turnToken)
            if isCurrentTurn, let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                    agents[aIdx].status = .idle
                    agents[aIdx].statusBubble = "Durduruldu"
                    agents[aIdx].currentPosition = agents[aIdx].deskPosition
                    agents[aIdx].currentZone = .desk
                }
                if let mIdx = agents[aIdx].messages.firstIndex(where: { $0.id == replyId }),
                   agents[aIdx].messages[mIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    agents[aIdx].messages[mIdx].content = "⏹️ Görev kullanıcı tarafından durduruldu."
                }
                saveConfig()
            }
        }

        // Proactive in-place compaction for multi-hour sessions so persistent memory never truncates goals blindly
        let priorMessages = Array(agents[initialIdx].messages.dropLast(2))
        if priorMessages.count > 34 || ContextCompactor.estimatedChars(of: priorMessages) > 42_000 {
            let persistentCompact = ContextCompactor.compactHistory(priorMessages, charBudget: 24_000, keepRecentCount: 12)
            if persistentCompact.didCompact && !persistentCompact.messages.isEmpty {
                let tailTwo = Array(agents[initialIdx].messages.suffix(2))
                agents[initialIdx].messages = persistentCompact.messages + tailTwo
                agents[initialIdx].agyConversationId = nil
                compactionEventCount += 1
                saveConfig()
                log(.info, source: agentName, "🗜️ Oto-Compact (Oturum): \(persistentCompact.compactedMessageCount) eski mesaj özetlendi (\(persistentCompact.originalCharCount) → \(persistentCompact.finalCharCount) kr).")
            }
        }

        let rawTurnHistory = Array(agents[initialIdx].messages.dropLast())
        let compactedTurn = ContextCompactor.compactHistory(rawTurnHistory, charBudget: 24_000, keepRecentCount: 10)
        if compactedTurn.didCompact && !compactedTurn.messages.isEmpty {
            compactionEventCount += 1
            log(.info, source: agentName, "🗜️ Bağlam Sıkıştırıldı: \(compactedTurn.compactedMessageCount) mesaj özetlendi (\(compactedTurn.originalCharCount) → \(compactedTurn.finalCharCount) kr).")
        }
        let history = compactedTurn.messages.isEmpty ? Array(rawTurnHistory.suffix(10)) : compactedTurn.messages
        let initialSnapshot = agents[initialIdx]

        let initialOutcome = await runTurnStepWithFailover(
            agentId: agentId,
            replyId: replyId,
            zone: zone,
            agentSnapshot: initialSnapshot,
            primaryProvider: prov,
            primaryModel: model,
            userPrompt: prompt,
            messages: history,
            maxAttempts: 12,
            agyConversationId: initialConvId,
            bannerPrefix: "",
            reasoningStepLabel: nil,
            preserveExistingProseWhenEmpty: false
        )

        if Task.isCancelled {
            resetCancelled()
            return nil
        }

        if let initialErr = initialOutcome.lastError {
            advanceTrackedRequest(reqId, to: .done, agentName: agentName, modelName: model, failed: true)
            if let loc = liveIndices() {
                agents[loc.ai].messages[loc.mi].content = "⚠️ Hata: Tüm model adayları denendi ancak yanıt alınamadı (\(initialErr.localizedDescription))."
                agents[loc.ai].status = .error
                agents[loc.ai].statusBubble = "API Hatası"
                saveConfig()
            }
            if telegramNotifyEnabled && handoffDepth == 0 && !telegramChatId.isEmpty {
                Task { await sendTelegramNotification(text: "⚠️ Crims Office (\(agentName)) hata: \(initialErr.localizedDescription)") }
            }
            log(.error, source: agentName, "Tüm model adayları başarısız: \(initialErr.localizedDescription)")
            return nil
        }

        let res = initialOutcome.response
        var successfulProv = initialOutcome.provider
        advanceTrackedRequest(
            reqId,
            to: .working,
            agentName: agentName,
            modelName: res.resolvedModel,
            inputTokens: res.inputTokens,
            outputTokens: res.outputTokens,
            latencyMs: res.latencyMs
        )
        var bannerPrefix = initialOutcome.usedFallback
            ? "> ⚡️ **Otomatik Devralma:** `\(prov.name) / \(model)` yerine `\(successfulProv.name) / \(res.resolvedModel)` görevi devraldı.\n\n"
            : ""

        guard let startLoc = liveIndices() else {
            advanceTrackedRequest(reqId, to: .done, agentName: agentName, modelName: res.resolvedModel, failed: true)
            return res.content
        }
        let initialClean = PowerShellTools.stripToolTags(from: res.content)
        let hasInitialTools = enableLocalTools && !PowerShellTools.extractToolCalls(from: res.content).isEmpty
        if !initialClean.isEmpty {
            agents[startLoc.ai].messages[startLoc.mi].content = bannerPrefix + initialClean
        } else if hasInitialTools {
            agents[startLoc.ai].messages[startLoc.mi].content = bannerPrefix + "⚡️ Araçlar çalıştırılıyor..."
        } else {
            agents[startLoc.ai].messages[startLoc.mi].content = bannerPrefix + res.content
        }
        if !res.reasoning.isEmpty { agents[startLoc.ai].messages[startLoc.mi].reasoning = res.reasoning }
        agents[startLoc.ai].messages[startLoc.mi].modelUsed = res.resolvedModel
        agents[startLoc.ai].messages[startLoc.mi].providerName = successfulProv.name
        agents[startLoc.ai].messages[startLoc.mi].latencyMs = res.latencyMs
        agents[startLoc.ai].messages[startLoc.mi].usedFallback = initialOutcome.usedFallback
        if successfulProv.kind != .antigravityCLI {
            agents[startLoc.ai].agyConversationId = nil
        } else if zone == .desk, let cid = res.agyConversationId, !cid.isEmpty {
            agents[startLoc.ai].agyConversationId = cid
        }
        if !res.toolCalls.isEmpty {
            agents[startLoc.ai].messages[startLoc.mi].toolCalls = res.toolCalls
        }
        if !res.touchedFiles.isEmpty {
            let wsPrefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
            for full in res.touchedFiles {
                let rel = full.hasPrefix(wsPrefix) ? String(full.dropFirst(wsPrefix.count)) : full
                appendFileEditRecord(FileEditRecord(agentName: agentName, relativePath: rel, backupPath: "", wasNewFile: false, summary: "Araç düzenlemesi"))
            }
        }
        if agents[startLoc.ai].currentZone == .serverRack && zone != .meetingRoom {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                agents[startLoc.ai].currentPosition = agents[startLoc.ai].deskPosition
                agents[startLoc.ai].currentZone = zone
            }
        }

        // Continuous Multi-Step Autonomous ReAct Loop (extended for multi-hour collaboration: 48 lead / 24 sub-delegate)
        let maxIterations = handoffDepth == 0 ? 48 : 24
        let maxAutoContinues = handoffDepth == 0 ? 8 : 0
        var activeModelName = res.resolvedModel
        var totalLatencyMs = res.latencyMs
        var totalInputTokens = res.inputTokens
        var totalOutputTokens = res.outputTokens
        var totalCachedTokens = res.cachedTokens
        var totalReasoningTokens = res.reasoningTokens
        var turnAgyConversationId = successfulProv.kind == .antigravityCLI ? res.agyConversationId : nil
        var didStepFail = false
        var didRequestHumanHandoff = false
        var didEditCodeInTurn = !res.touchedFiles.isEmpty
        var didRunBuildOrTestInTurn = res.toolCalls.contains { Self.isBuildOrTestCommand("\($0.name) \($0.argument)") }
        var buildGateCycles = 0
        if handoffDepth == 0 {
            searchedTopicsByAgent[agentId] = []
        }

        if enableLocalTools {
            var currentContent = res.content
            var lastMeaningfulProse = initialClean
            var iterationCount = 0
            var autoContinueCount = 0
            var hiredInTurn = 0
            var delegatedInTurn = 0
            var lastToolSignature: String? = nil
            var duplicateCallStreak = 0
            var recentToolSignatures: [String] = []
            var allRecordedToolCalls: [ToolCallRecord] = res.toolCalls
            var currentHistory = history
            currentHistory.append(ChatMessage(role: "assistant", content: res.content))

            func applyStepOutcome(
                _ outcome: (response: LLMFinalResponse, provider: APIProviderConfig, usedFallback: Bool, lastError: Error?),
                stepLabel: String
            ) -> Bool {
                if Task.isCancelled { return false }
                if let err = outcome.lastError {
                    didStepFail = true
                    log(.error, source: agentName, "\(stepLabel) başarısız: \(err.localizedDescription)")
                    if let loc = liveIndices() {
                        let base = lastMeaningfulProse.isEmpty ? agents[loc.ai].messages[loc.mi].content : (bannerPrefix + lastMeaningfulProse)
                        agents[loc.ai].messages[loc.mi].content = base + "\n\n> ⚠️ **İşlem Uyarısı (\(stepLabel)):** Tüm model adayları yanıt veremedi (\(err.localizedDescription)). Araç çıktıları yukarıdaki rozetlerde görüntülenebilir."
                    }
                    return false
                }
                let nextStep = outcome.response
                let prevProv = successfulProv
                let prevModel = activeModelName
                successfulProv = outcome.provider
                activeModelName = nextStep.resolvedModel
                if outcome.usedFallback || successfulProv.id != prevProv.id || activeModelName != prevModel {
                    bannerPrefix = "> ⚡️ **Otomatik Devralma:** Göreve `\(successfulProv.name) / \(activeModelName)` kesintisiz devam ediyor.\n\n"
                    log(.warning, source: agentName, "🔄 \(stepLabel) model geçişi → \(successfulProv.name) / \(activeModelName)")
                    if let loc = liveIndices() {
                        agents[loc.ai].messages[loc.mi].usedFallback = true
                    }
                }
                if successfulProv.kind != .antigravityCLI {
                    turnAgyConversationId = nil
                    if let loc = liveIndices() {
                        agents[loc.ai].agyConversationId = nil
                    }
                } else if let newCid = nextStep.agyConversationId, !newCid.isEmpty {
                    turnAgyConversationId = newCid
                    if zone == .desk, let loc = liveIndices() {
                        agents[loc.ai].agyConversationId = newCid
                    }
                }
                totalLatencyMs += nextStep.latencyMs
                totalInputTokens += nextStep.inputTokens
                totalOutputTokens += nextStep.outputTokens
                totalCachedTokens += nextStep.cachedTokens
                totalReasoningTokens += nextStep.reasoningTokens
                if !nextStep.toolCalls.isEmpty {
                    allRecordedToolCalls.append(contentsOf: nextStep.toolCalls)
                    if nextStep.toolCalls.contains(where: { Self.isBuildOrTestCommand("\($0.name) \($0.argument)") && $0.succeeded }) {
                        didRunBuildOrTestInTurn = true
                    }
                }
                if !nextStep.touchedFiles.isEmpty {
                    didEditCodeInTurn = true
                    didRunBuildOrTestInTurn = false
                    let wsPrefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
                    for full in nextStep.touchedFiles {
                        let rel = full.hasPrefix(wsPrefix) ? String(full.dropFirst(wsPrefix.count)) : full
                        appendFileEditRecord(FileEditRecord(agentName: agentName, relativePath: rel, backupPath: "", wasNewFile: false, summary: "Araç düzenlemesi"))
                    }
                }
                currentContent = nextStep.content
                currentHistory.append(ChatMessage(role: "assistant", content: nextStep.content))
                let nextProse = PowerShellTools.stripToolTags(from: nextStep.content)
                if !nextProse.isEmpty {
                    lastMeaningfulProse = nextProse
                }
                if let loc = liveIndices() {
                    let displayBody: String
                    if !nextProse.isEmpty {
                        displayBody = nextProse
                    } else if !lastMeaningfulProse.isEmpty {
                        displayBody = lastMeaningfulProse
                    } else {
                        displayBody = "✅ \(iterationCount) araç adımı tamamlandı."
                    }
                    agents[loc.ai].messages[loc.mi].content = bannerPrefix + displayBody
                    agents[loc.ai].messages[loc.mi].toolCalls = allRecordedToolCalls
                    agents[loc.ai].messages[loc.mi].modelUsed = activeModelName
                    agents[loc.ai].messages[loc.mi].providerName = successfulProv.name
                    agents[loc.ai].messages[loc.mi].latencyMs = totalLatencyMs
                    if !nextStep.reasoning.isEmpty {
                        agents[loc.ai].messages[loc.mi].reasoning = [agents[loc.ai].messages[loc.mi].reasoning, nextStep.reasoning].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n---\n")
                    }
                }
                return true
            }

            while iterationCount < maxIterations {
                if Task.isCancelled {
                    resetCancelled()
                    return nil
                }
                let calls = PowerShellTools.extractToolCalls(from: currentContent)
                if calls.isEmpty {
                    // Automatic Build & Test Verification Gate when agent edited code but hasn't verified build yet
                    if handoffDepth == 0,
                       autoVerifyBuild,
                       didEditCodeInTurn,
                       !didRunBuildOrTestInTurn,
                       !didRequestHumanHandoff,
                       buildGateCycles < 2,
                       iterationCount + 1 < maxIterations,
                       let verifyCmd = PowerShellTools.detectBuildCommand(workspacePath: workspacePath, customOverride: customBuildCommand) {
                        if let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                            agents[aIdx].status = .runningTool
                            agents[aIdx].statusBubble = "🔨 Build Gate: \(verifyCmd)"
                        }
                        log(.tool, source: "Build Gate", "Otomatik doğrulama çalıştırılıyor: `\(verifyCmd)`")
                        let gateRes = await PowerShellTools.runCommand(verifyCmd, workspacePath: workspacePath, wrapWithRTK: enableRTKProxy)
                        if Task.isCancelled {
                            resetCancelled()
                            return nil
                        }
                        allRecordedToolCalls.append(ToolCallRecord(name: "build_gate", argument: verifyCmd, output: gateRes.output, succeeded: gateRes.succeeded))
                        totalToolCallsExecuted += 1
                        if let loc = liveIndices() {
                            agents[loc.ai].messages[loc.mi].toolCalls = allRecordedToolCalls
                        }
                        if gateRes.succeeded {
                            didRunBuildOrTestInTurn = true
                            lastBuildVerification = (true, "✅ `\(verifyCmd)` hatasız geçti!")
                            log(.success, source: "Build Gate", "✅ \(verifyCmd) geçti.")
                            if let loc = liveIndices(),
                               !agents[loc.ai].messages[loc.mi].content.contains("Build Gate") {
                                agents[loc.ai].messages[loc.mi].content += "\n\n> ✅ **Otomatik Build Gate:** `\(verifyCmd)` hatasız geçti."
                            }
                        } else {
                            buildGateCycles += 1
                            iterationCount += 1
                            lastBuildVerification = (false, "⚠️ `\(verifyCmd)` hata verdi (Onarım \(buildGateCycles)/2)")
                            log(.warning, source: "Build Gate", "⚠️ \(verifyCmd) başarısız (Onarım \(buildGateCycles)/2); ajan düzeltmeye yönlendiriliyor.")
                            let repairDirective = """
                            [OTOMATİK BUILD GATE HATASI — ONARIM \(buildGateCycles)/2]:
                            Yaptığın dosya değişiklikleri sonrası çalıştırılan `\(verifyCmd)` komutu başarısız oldu:
                            ```
                            \(String(gateRes.output.prefix(3500)))
                            ```
                            Hatanın kök nedenini hemen `read_file`/`search_code` ile incele, `patch_file`/`write_file` ile düzelt ve tekrar doğrula.
                            """
                            currentHistory.append(ChatMessage(role: "user", content: repairDirective))
                            let snap = agents.first(where: { $0.id == agentId }) ?? initialSnapshot
                            let fixOutcome = await runTurnStepWithFailover(
                                agentId: agentId,
                                replyId: replyId,
                                zone: zone,
                                agentSnapshot: snap,
                                primaryProvider: successfulProv,
                                primaryModel: activeModelName,
                                userPrompt: prompt,
                                messages: currentHistory,
                                maxAttempts: 6,
                                agyConversationId: successfulProv.kind == .antigravityCLI ? turnAgyConversationId : nil,
                                bannerPrefix: bannerPrefix,
                                reasoningStepLabel: "🔧 Build onarımı (\(buildGateCycles)/2)...",
                                preserveExistingProseWhenEmpty: true
                            )
                            if Task.isCancelled {
                                resetCancelled()
                                return nil
                            }
                            if !applyStepOutcome(fixOutcome, stepLabel: "Build Onarımı \(buildGateCycles)") { break }
                            continue
                        }
                    }

                    let currentProse = PowerShellTools.stripToolTags(from: currentContent)
                    if !didRequestHumanHandoff, let continuePrompt = Self.autoContinuationDirective(
                        userPrompt: prompt,
                        currentProse: currentProse,
                        planTasks: planTasks,
                        hiredInTurn: hiredInTurn,
                        delegatedInTurn: delegatedInTurn,
                        autoContinueCount: autoContinueCount,
                        maxAutoContinues: maxAutoContinues,
                        handoffDepth: handoffDepth
                    ), iterationCount + 1 < maxIterations {
                        autoContinueCount += 1
                        iterationCount += 1
                        if let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                            agents[aIdx].status = .thinking
                            agents[aIdx].statusBubble = "🚀 Otonom devam (\(autoContinueCount)/\(maxAutoContinues))..."
                        }
                        log(.info, source: agentName, "🚀 Otonom süreklilik tetiklendi (\(autoContinueCount)/\(maxAutoContinues))")
                        currentHistory.append(ChatMessage(role: "user", content: continuePrompt))
                        let reactCompact = ContextCompactor.compactReActHistory(
                            currentHistory,
                            originalUserPrompt: prompt,
                            charBudget: 28_000,
                            keepRecent: 8
                        )
                        if reactCompact.didCompact && !reactCompact.messages.isEmpty {
                            currentHistory = reactCompact.messages
                            compactionEventCount += 1
                            log(.info, source: agentName, "🗜️ ReAct Oto-Compact: \(reactCompact.compactedMessageCount) adım özetlendi (\(reactCompact.originalCharCount) → \(reactCompact.finalCharCount) kr).")
                        }
                        let snap = agents.first(where: { $0.id == agentId }) ?? initialSnapshot
                        let contOutcome = await runTurnStepWithFailover(
                            agentId: agentId,
                            replyId: replyId,
                            zone: zone,
                            agentSnapshot: snap,
                            primaryProvider: successfulProv,
                            primaryModel: activeModelName,
                            userPrompt: prompt,
                            messages: currentHistory,
                            maxAttempts: 6,
                            agyConversationId: successfulProv.kind == .antigravityCLI ? turnAgyConversationId : nil,
                            bannerPrefix: bannerPrefix,
                            reasoningStepLabel: "🚀 Otonom devam (\(iterationCount)/\(maxIterations))...",
                            preserveExistingProseWhenEmpty: true
                        )
                        if Task.isCancelled {
                            resetCancelled()
                            return nil
                        }
                        if !applyStepOutcome(contOutcome, stepLabel: "Otonom Devam \(autoContinueCount)") { break }
                        continue
                    }
                    break
                }

                iterationCount += 1
                var iterationOutputs: [String] = []

                func checkDuplicateAndTrack(_ call: ParsedToolCall) -> String? {
                    let callSig = "\(call.name)::\(call.argument)"
                    if callSig == lastToolSignature {
                        duplicateCallStreak += 1
                    } else {
                        lastToolSignature = callSig
                        duplicateCallStreak = 0
                    }
                    recentToolSignatures.append(callSig)
                    if recentToolSignatures.count > 8 {
                        recentToolSignatures.removeFirst(recentToolSignatures.count - 8)
                    }
                    let isABABCycle = recentToolSignatures.count >= 4 && {
                        let n = recentToolSignatures.count
                        return recentToolSignatures[n - 1] == recentToolSignatures[n - 3]
                            && recentToolSignatures[n - 2] == recentToolSignatures[n - 4]
                            && recentToolSignatures[n - 1] != recentToolSignatures[n - 2]
                    }()
                    if duplicateCallStreak >= 2 || isABABCycle {
                        return "Aynı araç çağrısı döngüsü (\(call.name)) tespit edildi; farklı bir parametre/komut kullan veya sonraki plan görevine geç."
                    }
                    return nil
                }

                // Execute pure read-only batches concurrently using unified PowerShellTools.isReadOnlyToolName
                let engineHandledReadOnly: Set<String> = ["list_agents", "list_connectors", "swarm_status"]
                let allPureLocalReads = calls.count > 1 && calls.allSatisfy {
                    let cname = PowerShellTools.canonicalToolName($0.name).lowercased()
                    return PowerShellTools.isReadOnlyToolName(cname) && !engineHandledReadOnly.contains(cname)
                }
                if allPureLocalReads {
                    var uniqueCalls: [(Int, ParsedToolCall)] = []
                    var blockedIndices: [Int: String] = [:]
                    for (idx, call) in calls.enumerated() {
                        if let loopMsg = checkDuplicateAndTrack(call) {
                            blockedIndices[idx] = loopMsg
                        } else {
                            uniqueCalls.append((idx, call))
                        }
                    }
                    if let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                            agents[aIdx].status = .runningTool
                            agents[aIdx].currentPosition = Point2D(x: 0.80, y: 0.72)
                            agents[aIdx].currentZone = .serverRack
                            agents[aIdx].statusBubble = "⚡️ \(uniqueCalls.count) paralel okuma..."
                        }
                    }
                    let wsSnapshot = workspacePath
                    let rtkSnapshot = enableRTKProxy
                    let writesSnapshot = allowFileWrites
                    let resultsMap = await withTaskGroup(of: (Int, LocalToolResult).self) { group in
                        for (idx, c) in uniqueCalls {
                            group.addTask {
                                let res = await PowerShellTools.executeAgentTool(
                                    name: c.name,
                                    argument: c.argument,
                                    agentName: agentName,
                                    workspacePath: wsSnapshot,
                                    useRTK: rtkSnapshot,
                                    allowWrites: writesSnapshot
                                )
                                return (idx, res)
                            }
                        }
                        var map: [Int: LocalToolResult] = [:]
                        for await (idx, res) in group {
                            map[idx] = res
                        }
                        return map
                    }
                    if Task.isCancelled {
                        resetCancelled()
                        return nil
                    }
                    for (idx, call) in calls.enumerated() {
                        if let loopMsg = blockedIndices[idx] {
                            iterationOutputs.append("[Tekrar Koruması]: \(loopMsg)")
                            allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: call.argument, output: loopMsg, succeeded: false))
                        } else if let toolRes = resultsMap[idx] {
                            log(.tool, source: agentName, "⚡️ \(call.name) → \(toolRes.commandUsed.prefix(50))")
                            iterationOutputs.append("[\(call.name) (`\(toolRes.commandUsed)`)]:\n\(toolRes.output)")
                            allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: call.argument, output: toolRes.output, succeeded: toolRes.succeeded))
                            totalToolCallsExecuted += 1
                        }
                    }
                    if let loc = liveIndices() {
                        agents[loc.ai].messages[loc.mi].toolCalls = allRecordedToolCalls
                    }
                } else {
                    for call in calls {
                        if Task.isCancelled {
                            resetCancelled()
                            return nil
                        }
                        if let loopMsg = checkDuplicateAndTrack(call) {
                            iterationOutputs.append("[Tekrar Koruması]: \(loopMsg)")
                            allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: call.argument, output: loopMsg, succeeded: false))
                            continue
                        }

                    if call.name == "create_plan" {
                        let parts = call.argument.components(separatedBy: "|||")
                        let pGoal = parts.count > 1 ? parts[0] : prompt
                        let pTasks = parts.count > 1 ? parts.dropFirst().joined(separator: "|||") : call.argument
                        let summary = applyCreatePlan(goal: pGoal, rawTasks: pTasks, by: agentName)
                        if let loc = liveIndices() {
                            agents[loc.ai].statusBubble = "📋 Plan oluşturuldu (\(planTasks.count) görev)"
                        }
                        if let caller = agents.first(where: { $0.id == agentId }) {
                            recordDialogue(from: caller, toName: "Tüm Ofis", content: "📋 Yeni Plan (\(planTasks.count) görev): \(activePlanGoal)", kind: .handoff)
                        }
                        iterationOutputs.append(summary)
                        allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: activePlanGoal, output: summary, succeeded: true))
                    } else if call.name == "update_task" {
                        let parts = call.argument.components(separatedBy: "|||")
                        let tId = parts[0]
                        let tStatus = parts.count > 1 ? parts[1] : "done"
                        let tNote = parts.count > 2 ? parts[2] : ""
                        let tAssignee = parts.count > 3 ? parts[3] : nil
                        let msg = applyUpdateTask(identifier: tId, rawStatus: tStatus, note: tNote, assignee: tAssignee)
                        iterationOutputs.append(msg)
                        allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: "\(tId) → \(tStatus)", output: msg, succeeded: true))
                    } else if call.name == "assign_task" && handoffDepth < 3 {
                        let parts = call.argument.components(separatedBy: "|||")
                        let targetName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let taskIdOrTitle = parts.count >= 3 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "Ekip Görevi (\(targetName))"
                        let subTask = parts.count >= 3 ? parts.dropFirst(2).joined(separator: "|||") : (parts.count == 2 ? parts[1] : call.argument)
                        let resDel = await performDelegation(
                            fromAgentId: agentId,
                            callerName: agentName,
                            targetName: targetName,
                            subTask: subTask,
                            taskIdentifier: taskIdOrTitle,
                            zone: zone,
                            handoffDepth: handoffDepth,
                            handoffChain: handoffChain
                        )
                        if resDel.succeeded { delegatedInTurn += 1 }
                        iterationOutputs.append(resDel.output)
                        allRecordedToolCalls.append(resDel.record)
                    } else if call.name == "hire_agent" {
                        let parts = call.argument.components(separatedBy: "|||")
                        let hName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let matchingTemplate = roleTemplates.first(where: { $0.name.lowercased() == hName.lowercased() || $0.title.lowercased().contains(hName.lowercased()) })
                        let hTitle = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : (matchingTemplate?.title ?? "Uzman Yazılımcı")
                        let hEmoji = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : (matchingTemplate?.emoji ?? "⚡️")
                        let hModel = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                        let hPrompt = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : (matchingTemplate?.prompt ?? "")
                        let hTemp = parts.count > 5 ? (Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.25) : 0.25

                        let callerSnapshot = agents.first(where: { $0.id == agentId })
                        let hireResult = hireAgent(
                            name: hName,
                            title: hTitle,
                            emoji: hEmoji,
                            modelId: hModel,
                            systemPrompt: hPrompt,
                            temperature: hTemp,
                            hiredBy: callerSnapshot
                        )
                        if hireResult.success { hiredInTurn += 1 }
                        iterationOutputs.append("[Ajan Kaynakları (AR)]:\n\(hireResult.message)")
                        allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: "\(hName) (\(hTitle))", output: hireResult.message, succeeded: hireResult.success))
                    } else if call.name == "add_template" {
                        let parts = call.argument.components(separatedBy: "|||")
                        if parts.count >= 3 {
                            let tName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            let tTitle = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            let tPrompt = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                            let tEmoji = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : "⚡️"
                            let inferredKw = ModelRouter.inferTemplateKeyword(name: tName, title: tTitle, prompt: tPrompt)
                            let t = AgentRoleTemplate(name: tName, title: tTitle, emoji: tEmoji, accentHex: "#38BDF8", prompt: tPrompt, defaultModelKeyword: inferredKw, isCustom: true)
                            addRoleTemplate(t)
                            let msg = "Yeni şablon kaydedildi: \(tName) (\(tTitle))"
                            iterationOutputs.append("[Şablon Sistemi]: \(msg)")
                            allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: tName, output: msg, succeeded: true))
                        } else {
                            let err = "add_template format hatası. Beklenen: Ad|||Ünvan|||SistemPromptu[|||Emoji]"
                            iterationOutputs.append("[Şablon Hatası]: \(err)")
                            allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: call.argument, output: err, succeeded: false))
                        }
                    } else if call.name == "list_agents" {
                        var listText = "MEVCUT OFİS EKİBİ (\(agents.count) Ajan):\n"
                        for a in agents {
                            let provName = provider(for: a.providerId)?.name ?? "API"
                            listText += "- \(a.emoji) \(a.name) (\(a.title)) · Model: \(a.modelId) (\(provName))\n"
                        }
                        iterationOutputs.append("[Ekip Listesi]:\n\(listText)")
                        allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: ".", output: listText, succeeded: true))
                    } else if call.name == "delegate" && handoffDepth < 3 {
                        let parts = call.argument.components(separatedBy: "|||")
                        let targetName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let subTask = parts.count > 1 ? parts.dropFirst().joined(separator: "|||") : call.argument
                        let resDel = await performDelegation(
                            fromAgentId: agentId,
                            callerName: agentName,
                            targetName: targetName,
                            subTask: subTask,
                            taskIdentifier: nil,
                            zone: zone,
                            handoffDepth: handoffDepth,
                            handoffChain: handoffChain
                        )
                        if resDel.succeeded { delegatedInTurn += 1 }
                        iterationOutputs.append(resDel.output)
                        allRecordedToolCalls.append(resDel.record)
                    } else if call.name == "dismiss_agent" {
                        let parts = call.argument.components(separatedBy: "|||")
                        let targetName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "Görev tamamlandı"
                        if let targetIndex = agents.firstIndex(where: { $0.name.lowercased() == targetName.lowercased() }) {
                            let dismissedAgent = agents[targetIndex]
                            if dismissedAgent.id == agentId {
                                let msg = "Ajan kendini ekipten çıkaramaz."
                                iterationOutputs.append("[Dismiss Hatası]: \(msg)")
                                allRecordedToolCalls.append(ToolCallRecord(name: "dismiss_agent", argument: targetName, output: msg, succeeded: false))
                            } else {
                                cancelIndividualTask(for: dismissedAgent.id)
                                cleanupRemovedAgentUI(id: dismissedAgent.id)
                                agents.removeAll { $0.id == dismissedAgent.id }
                                if selectedAgentId == dismissedAgent.id { selectedAgentId = agentId }
                                saveConfig()
                                let msg = "'\(dismissedAgent.name)' (\(dismissedAgent.title)) ekipten çıkarıldı ve arşivlendi. Sebep: \(reason)"
                                iterationOutputs.append("[Ekip Yönetimi]: \(msg)")
                                allRecordedToolCalls.append(ToolCallRecord(name: "dismiss_agent", argument: targetName, output: msg, succeeded: true))
                                log(.info, source: agentName, msg)
                            }
                        } else {
                            let err = "'\(targetName)' adlı ajan bulunamadı."
                            iterationOutputs.append("[Dismiss Hatası]: \(err)")
                            allRecordedToolCalls.append(ToolCallRecord(name: "dismiss_agent", argument: targetName, output: err, succeeded: false))
                        }
                    } else if Self.isEcosystemOrBrowserTool(call.name) {
                        if let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                                agents[aIdx].status = .runningTool
                                agents[aIdx].currentPosition = Point2D(x: 0.80, y: 0.72)
                                agents[aIdx].currentZone = .serverRack
                                agents[aIdx].statusBubble = "🌐 \(call.name): \(call.argument.prefix(20))"
                            }
                        }
                        let ecoRes = await executeEcosystemOrBrowserTool(
                            name: call.name,
                            argument: call.argument,
                            agentId: agentId,
                            agentName: agentName
                        )
                        if ecoRes.requestedHandoff {
                            didRequestHumanHandoff = true
                        }
                        log(.tool, source: agentName, "\(call.name) → \(call.argument.prefix(60))")
                        iterationOutputs.append("[\(call.name)]:\n\(ecoRes.output)")
                        allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: call.argument, output: ecoRes.output, succeeded: ecoRes.succeeded))
                        totalToolCallsExecuted += 1
                    } else {
                        if let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                                agents[aIdx].status = .runningTool
                                agents[aIdx].currentPosition = Point2D(x: 0.80, y: 0.72)
                                agents[aIdx].currentZone = .serverRack
                                agents[aIdx].statusBubble = "⚡️ \(call.name): \(call.argument.prefix(20))"
                            }
                        }
                        let toolRes = await PowerShellTools.executeAgentTool(
                            name: call.name,
                            argument: call.argument,
                            agentName: agentName,
                            workspacePath: workspacePath,
                            useRTK: enableRTKProxy,
                            allowWrites: allowFileWrites
                        )
                        if let editRec = toolRes.editRecord {
                            appendFileEditRecord(editRec)
                            didEditCodeInTurn = true
                            didRunBuildOrTestInTurn = false
                            saveConfig()
                        } else if Self.isBuildOrTestCommand("\(call.name) \(call.argument)") && toolRes.succeeded {
                            didRunBuildOrTestInTurn = true
                        }
                        log(.tool, source: agentName, "\(toolRes.usedRTK ? "[RTK] " : "")\(call.name) → \(toolRes.commandUsed.prefix(60))")
                        iterationOutputs.append("[\(call.name) (`\(toolRes.commandUsed)`)]:\n\(toolRes.output)")
                        allRecordedToolCalls.append(ToolCallRecord(name: call.name, argument: call.argument, output: toolRes.output, succeeded: toolRes.succeeded))
                        totalToolCallsExecuted += 1
                    }

                    if let loc = liveIndices() {
                        agents[loc.ai].messages[loc.mi].toolCalls = allRecordedToolCalls
                    }
                    }
                }

                guard !iterationOutputs.isEmpty else { break }

                if let aIdx = agents.firstIndex(where: { $0.id == agentId }) {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
                        agents[aIdx].status = zone == .meetingRoom ? .collaborating : .thinking
                        if zone != .meetingRoom {
                            agents[aIdx].currentPosition = agents[aIdx].deskPosition
                        }
                        agents[aIdx].currentZone = zone
                        agents[aIdx].statusBubble = "🧠 İnceliyor (Adım \(iterationCount)/\(maxIterations))..."
                    }
                }

                let reachedFinalStep = iterationCount >= maxIterations
                let planNote = planTasks.isEmpty ? "" : "\n\n\(planStatusBoardSummary())"
                let stepFeedback: String
                if reachedFinalStep {
                    stepFeedback = """
                    [ARAÇ VE İŞLEM ÇIKTILARI - ADIM \(iterationCount)/\(maxIterations) (NİHAİ ADIM SINIRI)]:
                    \(iterationOutputs.joined(separator: "\n\n"))\(planNote)

                    [NİHAİ RAPOR TALİMATI]:
                    - Maksimum araç yürütme adımına ulaştın. Artık YENİ `<tool>` ÇAĞIRMA!
                    - Şu ana kadarki gerçek araç çıktılarına dayanarak elde ettiğin tüm bulguları ve yapılanları aşağıdaki 4 aşamalı mühendislik formatında eksiksiz sun:
                      ### 🎯 Durum & Analiz
                      ### ⚡️ Yapılan İşlem & Araçlar
                      ### 🔍 Kod & Değişiklik İncelemesi
                      ### ✅ Sonuç & Sonraki Adım
                    """
                } else {
                    stepFeedback = """
                    [ARAÇ VE İŞLEM ÇIKTILARI - ADIM \(iterationCount)/\(maxIterations)]:
                    \(iterationOutputs.joined(separator: "\n\n"))\(planNote)

                    [DİSİPLİNLİ MÜHENDİSLİK & SÜREKLİLİK TALİMATI]:
                    - Yukarıdaki gerçek araç çıktılarını dikkatle incele.
                    - Aktif planda açık görev varsa veya yeni doğrulama/kodlama/terminal komutu gerekiyorsa YARIDA DURMA; hemen sıradaki `<tool name="...">parametre</tool>` etiketini çağır.
                    - Yalnızca tüm plan görevleri tamamlanıp doğrulandıysa aşağıdaki 4 aşamalı mühendislik formatında nihai raporunu sun:
                      ### 🎯 Durum & Analiz
                      ### ⚡️ Yapılan İşlem & Araçlar
                      ### 🔍 Kod & Değişiklik İncelemesi
                      ### ✅ Sonuç & Sonraki Adım
                    """
                }

                currentHistory.append(ChatMessage(role: "user", content: stepFeedback))
                let reactCompact = ContextCompactor.compactReActHistory(
                    currentHistory,
                    originalUserPrompt: prompt,
                    charBudget: 28_000,
                    keepRecent: 8
                )
                if reactCompact.didCompact && !reactCompact.messages.isEmpty {
                    currentHistory = reactCompact.messages
                    compactionEventCount += 1
                    log(.info, source: agentName, "🗜️ ReAct Oto-Compact: \(reactCompact.compactedMessageCount) adım özetlendi (\(reactCompact.originalCharCount) → \(reactCompact.finalCharCount) kr).")
                }

                let snap = agents.first(where: { $0.id == agentId }) ?? initialSnapshot
                let stepOutcome = await runTurnStepWithFailover(
                    agentId: agentId,
                    replyId: replyId,
                    zone: zone,
                    agentSnapshot: snap,
                    primaryProvider: successfulProv,
                    primaryModel: activeModelName,
                    userPrompt: prompt,
                    messages: currentHistory,
                    maxAttempts: 6,
                    agyConversationId: successfulProv.kind == .antigravityCLI ? turnAgyConversationId : nil,
                    bannerPrefix: bannerPrefix,
                    reasoningStepLabel: "🧠 Akıl yürütüyor (Adım \(iterationCount)/\(maxIterations))...",
                    preserveExistingProseWhenEmpty: true
                )

                if Task.isCancelled {
                    resetCancelled()
                    return nil
                }

                if !applyStepOutcome(stepOutcome, stepLabel: "ReAct Adım \(iterationCount)") { break }
                if reachedFinalStep { break }
            }
        }

        if Task.isCancelled {
            resetCancelled()
            return nil
        }

        if handoffDepth == 0 {
            searchedTopicsByAgent.removeValue(forKey: agentId)
        }

        if didStepFail {
            advanceTrackedRequest(reqId, to: .done, agentName: agentName, modelName: activeModelName, failed: true)
            if let aiErr = agents.firstIndex(where: { $0.id == agentId }) {
                agents[aiErr].status = .error
                agents[aiErr].statusBubble = "Adım Hatası"
                saveConfig()
            }
            return nil
        }

        guard let aiFinal = agents.firstIndex(where: { $0.id == agentId }) else {
            advanceTrackedRequest(reqId, to: .done, agentName: agentName, modelName: activeModelName, failed: true)
            return res.content
        }
        let finalMsg = agents[aiFinal].messages.first(where: { $0.id == replyId })
        let finalToolsCount = finalMsg?.toolCalls.count ?? res.toolCalls.count
        agents[aiFinal].completedTasks += 1
        agents[aiFinal].status = .idle
        agents[aiFinal].statusBubble = didRequestHumanHandoff
            ? "🧑💻 Browser onayı bekliyor"
            : "Tamamlandı (\(totalLatencyMs) ms)"
        let aggregatedResponse = LLMFinalResponse(
            content: finalMsg?.content ?? res.content,
            reasoning: finalMsg?.reasoning ?? res.reasoning,
            resolvedModel: activeModelName,
            latencyMs: totalLatencyMs,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            cachedTokens: totalCachedTokens,
            reasoningTokens: totalReasoningTokens
        )
        recordTurnCostTelemetry(
            agentId: agentId,
            provider: successfulProv,
            modelId: activeModelName,
            response: aggregatedResponse,
            promptChars: prompt.count,
            toolCallsCount: finalToolsCount
        )
        advanceTrackedRequest(
            reqId,
            to: .done,
            agentName: agentName,
            modelName: activeModelName,
            inputTokens: max(0, totalInputTokens - res.inputTokens),
            outputTokens: max(0, totalOutputTokens - res.outputTokens),
            latencyMs: max(0, totalLatencyMs - res.latencyMs)
        )
        saveConfig()
        if persistConfig && handoffDepth == 0 && didEditCodeInTurn {
            let targetWS = workspacePath
            Task { @MainActor [weak self] in
                await self?.scheduleGraphifyAutoIndexIfNeeded(for: targetWS, incremental: true)
            }
        }
        log(.success, source: agentName, "Tamamlandı (\(activeModelName) · \(totalLatencyMs) ms)")
        let replyContent = finalMsg?.content ?? res.content
        if telegramNotifyEnabled && handoffDepth == 0 && !telegramChatId.isEmpty {
            let preview = String(replyContent.replacingOccurrences(of: "\n", with: " ").prefix(280))
            Task { await sendTelegramNotification(text: "✅ Crims Office · \(agentName) (\(activeModelName)):\n\(preview)") }
        }
        return replyContent
    }

    // MARK: - Multi-Agent Orchestrator (Live Debate, Autonomous Project Sprint + Build Self-Heal, Sequential, Parallel)

    // MARK: - Swarms Persistent Runtime Lifecycle

    func ensureSwarmsRuntimeReady() async {
        guard !isCheckingSwarms else { return }
        isCheckingSwarms = true
        defer { isCheckingSwarms = false }

        let result = await SwarmsRuntimeService.ensureDaemonRunning(workspacePath: workspacePath)
        swarmsHealth = result.health
        if result.online, let runs = await SwarmsRuntimeService.fetchRecentRuns() {
            swarmsRecentRuns = runs.recent
        }
        syncSwarmsConnectorState(online: result.online, health: result.health, message: result.message)
        if result.online {
            log(.success, source: "Swarms", result.message)
        } else {
            log(.warning, source: "Swarms", result.message)
        }
    }

    func refreshSwarmsStatus() async {
        isCheckingSwarms = true
        defer { isCheckingSwarms = false }
        let health = await SwarmsRuntimeService.checkHealth()
        swarmsHealth = health
        if let runs = await SwarmsRuntimeService.fetchRecentRuns() {
            swarmsRecentRuns = runs.recent
        }
        let online = health?.isHealthy == true
        let msg = online
            ? "Swarms v\(health?.swarmsVersion ?? "?") aktif · \(health?.totalRuns ?? 0) çalışma"
            : "Swarms daemon çevrimdışı (127.0.0.1:8765)"
        syncSwarmsConnectorState(online: online, health: health, message: msg)
    }

    func restartSwarmsDaemon() async -> (Bool, String) {
        isCheckingSwarms = true
        defer { isCheckingSwarms = false }
        let res = await SwarmsRuntimeService.restartDaemon(workspacePath: workspacePath)
        swarmsHealth = res.health
        if res.online, let runs = await SwarmsRuntimeService.fetchRecentRuns() {
            swarmsRecentRuns = runs.recent
        }
        syncSwarmsConnectorState(online: res.online, health: res.health, message: res.message)
        log(res.online ? .success : .warning, source: "Swarms", res.message)
        return (res.online, res.message)
    }

    func syncSwarmsConnectorState(online: Bool, health: SwarmsDaemonHealth?, message: String) {
        guard let idx = connectors.firstIndex(where: { $0.slug.lowercased() == "swarms-mcp" }) else { return }
        connectors[idx].isVerifiedReady = online
        connectors[idx].lastCheckedAt = Date()
        if let h = health, online {
            connectors[idx].lastStatusMessage = "Aktif v\(h.swarmsVersion) · \(h.totalRuns) çalışma · uptime \(Int(h.uptimeSeconds))s"
        } else {
            connectors[idx].lastStatusMessage = String(message.prefix(160))
        }
    }

    func cancelPipeline() {
        isRunningPipeline = false
        pipelineToken = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        for a in agents {
            cancelIndividualTask(for: a.id)
        }
        Task {
            await SwarmsRuntimeService.cancelAllActiveRuns()
        }
        pipelineStatusText = "Oturum durduruldu."
        recallAllAgentsToDesks()
        log(.warning, source: "Ofis Görevi", "Çoklu ajan oturumu kullanıcı tarafından durduruldu.")
    }

    func runOfficePipeline(
        goal: String,
        participantIds: [UUID],
        mode: PipelineMode,
        debateRounds: Int = 2,
        swarmTopology: SwarmsTopology = .auto,
        swarmMaxLoops: Int = 1,
        rearrangeFlow: String = ""
    ) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunningPipeline, !trimmed.isEmpty, !participantIds.isEmpty else { return }

        let pToken = UUID()
        pipelineToken = pToken
        isRunningPipeline = true
        lastPipelineOutputs = []
        lastBuildVerification = nil
        pipelineStatusText = mode == .swarms
            ? "Swarms (\(swarmTopology.rawValue)) oturumu hazırlanıyor..."
            : "Ajanlar toplantı odasında toplanıyor..."
        log(.info, source: "Ofis Görevi", "Başlatıldı: \(mode.rawValue) (\(participantIds.count) ajan)")

        pipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pipelineToken == pToken {
                    self.isRunningPipeline = false
                    self.pipelineTask = nil
                    self.pipelineToken = nil
                    self.recallAllAgentsToDesks()
                }
            }

            switch mode {
            case .swarms:
                await self.runSwarmsOrchestration(
                    goal: trimmed,
                    participantIds: participantIds,
                    topology: swarmTopology,
                    maxLoops: max(1, min(6, swarmMaxLoops)),
                    rearrangeFlow: rearrangeFlow
                )
            case .debate:
                await self.runLiveDebate(goal: trimmed, participantIds: participantIds, rounds: max(2, min(4, debateRounds)))
            case .projectSprint:
                await self.runAutonomousProjectSprint(goal: trimmed, participantIds: participantIds)
            case .sequential:
                var ctx = "ANA HEDEF:\n\(trimmed)"
                var prevId: UUID? = nil
                for (step, id) in participantIds.enumerated() {
                    if Task.isCancelled { break }
                    guard let a = self.agents.first(where: { $0.id == id }) else { continue }
                    if let pId = prevId {
                        self.showBeam(from: pId, to: id, label: "➡️ Devir", accentHex: a.accentHex, duration: 5.0)
                    }
                    self.pipelineStatusText = "Adım \(step + 1)/\(participantIds.count): \(a.name) çalışıyor..."
                    let p = step == 0
                        ? "OFİS GÖREVİ:\n\(trimmed)"
                        : "OFİS GÖREVİ (Adım \(step + 1)):\n\(ctx)\n\nRolün (\(a.title)) kapsamında görevi bir sonraki aşamaya taşı."
                    if let out = await self.executeTurn(agentId: id, prompt: p, zone: .meetingRoom) {
                        self.lastPipelineOutputs.append((a.name, a.title, a.modelId, out))
                        self.recordDialogue(from: a, toName: "Ekip", content: String(out.prefix(260)), kind: .handoff)
                        ctx += "\n\n--- \(a.name) ÇIKTISI ---\n\(String(out.prefix(2400)))"
                    }
                    prevId = id
                }
            case .parallel:
                self.pipelineStatusText = "\(participantIds.count) ajan paralel çalışıyor..."
                await withTaskGroup(of: (UUID, String?).self) { group in
                    for id in participantIds {
                        group.addTask { @MainActor in
                            let out = await self.executeTurn(agentId: id, prompt: "PARALEL OFİS GÖREVİ:\n\(trimmed)", zone: .meetingRoom)
                            return (id, out)
                        }
                    }
                    for await (id, out) in group {
                        if let out, let a = self.agents.first(where: { $0.id == id }) {
                            self.lastPipelineOutputs.append((a.name, a.title, a.modelId, out))
                            self.recordDialogue(from: a, toName: "Ekip", content: String(out.prefix(220)), kind: .debate)
                        }
                    }
                }
            }

            if !Task.isCancelled && self.autoSelfImprove && !self.lastPipelineOutputs.isEmpty {
                await self.distillLessonFromRecentWork(topic: trimmed, outputs: self.lastPipelineOutputs)
            }

            if Task.isCancelled {
                self.pipelineStatusText = "Görev durduruldu."
            } else {
                self.pipelineStatusText = "Görev tamamlandı (\(self.lastPipelineOutputs.count) çıktı)."
            }
        }
    }

    private func runSwarmsOrchestration(
        goal: String,
        participantIds: [UUID],
        topology: SwarmsTopology,
        maxLoops: Int,
        rearrangeFlow: String
    ) async {
        let participants = participantIds.compactMap { id in agents.first(where: { $0.id == id }) }
        guard !participants.isEmpty else { return }

        for (idx, a) in participants.enumerated() {
            if let ai = agents.firstIndex(where: { $0.id == a.id }) {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.8)) {
                    let angle = Double(idx) * (2.0 * Double.pi / Double(max(1, participants.count)))
                    agents[ai].currentPosition = Point2D(x: 0.50 + cos(angle) * 0.125, y: 0.50 + sin(angle) * 0.082)
                    agents[ai].currentZone = .meetingRoom
                    agents[ai].status = .collaborating
                    agents[ai].statusBubble = "🐝 Swarms (\(topology.rawValue))"
                }
            }
        }

        pipelineStatusText = "Swarms Daemon doğrulanıyor..."
        let boot = await SwarmsRuntimeService.ensureDaemonRunning(workspacePath: workspacePath)
        swarmsHealth = boot.health
        syncSwarmsConnectorState(online: boot.online, health: boot.health, message: boot.message)

        guard boot.online else {
            log(.warning, source: "Swarms", "Daemon erişilemedi (\(boot.message)); yerel Swift akışına geçiliyor.")
            pipelineStatusText = "Swarms çevrimdışı; yerel çoklu ajan akışına geçildi..."
            if participants.count >= 2 && (topology == .debateWithJudge || topology == .groupChat || topology == .roundRobin) {
                await runLiveDebate(goal: goal, participantIds: participantIds, rounds: 2)
            } else {
                for id in participantIds {
                    if Task.isCancelled { break }
                    if let a = agents.first(where: { $0.id == id }),
                       let out = await executeTurn(agentId: id, prompt: "SWARMS YEDEK GÖREVİ:\n\(goal)", zone: .meetingRoom) {
                        lastPipelineOutputs.append((a.name, a.title, a.modelId, out))
                    }
                }
            }
            return
        }

        if participants.count >= 2 {
            for i in 0..<(participants.count - 1) {
                showBeam(from: participants[i].id, to: participants[i + 1].id, label: "🐝 \(topology.rawValue)", accentHex: participants[i].accentHex, duration: 6.0)
            }
        }

        pipelineStatusText = "🐝 Swarms (\(topology.rawValue)) çalışıyor (\(participants.count) ajan)..."
        let payloads = SwarmsRuntimeService.buildAgentPayloads(
            agents: participants,
            providers: providers,
            providerStatuses: providerStatuses,
            providerCooldowns: providerCooldowns,
            modelMetrics: modelMetrics
        )
        let trimmedFlow = rearrangeFlow.trimmingCharacters(in: .whitespacesAndNewlines)
        let req = SwarmsRunRequestPayload(
            task: goal,
            swarmType: topology.rawValue,
            maxLoops: maxLoops,
            rearrangeFlow: (topology == .agentRearrange && !trimmedFlow.isEmpty) ? trimmedFlow : nil,
            workspacePath: workspacePath,
            allowLocalEdits: allowFileWrites,
            agents: payloads,
            director: payloads.first
        )

        do {
            let res = try await SwarmsRuntimeService.runSwarm(req)
            if Task.isCancelled { return }
            recordSwarmsTelemetry(res.telemetry)
            await refreshSwarmsStatus()

            if res.steps.isEmpty && !res.finalOutput.isEmpty {
                let lead = participants[0]
                lastPipelineOutputs.append((lead.name, "Swarms · \(res.swarmType)", lead.modelId, res.finalOutput))
                recordDialogue(from: lead, toName: "Swarms", content: String(res.finalOutput.prefix(260)), kind: .debate)
                incrementCompletedTasks(for: lead.id)
            } else {
                var prevAgentId: UUID? = nil
                for step in res.steps {
                    let matched = participants.first(where: { $0.name.lowercased() == step.agentName.lowercased() })
                    let modelLabel = step.model.isEmpty ? (matched?.modelId ?? "swarms") : step.model
                    lastPipelineOutputs.append((step.agentName, "\(step.role) · \(res.swarmType)", modelLabel, step.output))
                    if let matched {
                        incrementCompletedTasks(for: matched.id)
                        recordDialogue(from: matched, toName: "Swarms (\(res.swarmType))", content: String(step.output.prefix(260)), kind: .debate)
                        if let prev = prevAgentId, prev != matched.id {
                            showBeam(from: prev, to: matched.id, label: "🐝 Devir", accentHex: matched.accentHex, duration: 4.5)
                        }
                        prevAgentId = matched.id
                    } else {
                        recordDialogue(from: nil, toName: step.agentName, content: String(step.output.prefix(260)), kind: .debate)
                    }
                }
            }
            log(.success, source: "Swarms", "\(res.swarmType) tamamlandı (\(res.durationMs) ms, \(res.steps.count) adım).")
        } catch {
            if Task.isCancelled { return }
            log(.warning, source: "Swarms", "Çalıştırma hatası (\(error.localizedDescription)); yerel Swift tartışmasına geçiliyor.")
            pipelineStatusText = "Swarms hatası sonrası yerel yedek akış çalışıyor..."
            await runLiveDebate(goal: goal, participantIds: participantIds, rounds: 2)
        }
    }

    private func runLiveDebate(goal: String, participantIds: [UUID], rounds: Int) async {
        var transcript = "TOPLANTI KONUSU: \(goal)"
        var lastSpeakerId: UUID? = nil
        let effectiveRounds = participantIds.count < 2 ? 1 : rounds
        if participantIds.count < 2 {
            log(.warning, source: "Toplantı", "Tartışma modu için en az 2 ajan önerilir; tek ajan derin analizi çalıştırılıyor.")
        }

        for round in 1...effectiveRounds {
            for id in participantIds {
                if Task.isCancelled { return }
                guard let a = agents.first(where: { $0.id == id }) else { continue }
                pipelineStatusText = "Tur \(round)/\(effectiveRounds) — \(a.emoji) \(a.name) söz aldı..."
                if let prev = lastSpeakerId, prev != id {
                    showBeam(from: prev, to: id, label: "🗣️ Tur \(round)", accentHex: a.accentHex, duration: 5.5)
                }

                let prompt: String
                if effectiveRounds == 1 {
                    prompt = "TEK AJAN MİMARİ DEĞERLENDİRMESİ\nKonu: \(goal)\n\nRolün (\(a.title)) kapsamında artıları, eksileri, riskleri ve kesin teknik kararı 4 aşamalı raporda sun."
                } else if round == 1 && lastSpeakerId == nil {
                    prompt = "CANLI EKİP TARTIŞMASI (Tur 1/\(effectiveRounds))\nKonu: \(goal)\n\nAçılış görüşünü ve somut teknik önerini kısa, net ve tartışmaya açık biçimde sun."
                } else if round == effectiveRounds {
                    prompt = "CANLI EKİP TARTIŞMASI (Final Turu \(round)/\(effectiveRounds))\n\(transcript)\n\nDiğer ekip arkadaşlarının argümanlarını değerlendir, çelişkileri çöz ve kendi rolün (\(a.title)) açısından nihai uzlaşma kararını yaz."
                } else {
                    prompt = "CANLI EKİP TARTIŞMASI (Tur \(round)/\(effectiveRounds))\n\(transcript)\n\nÖnceki konuşmacılara doğrudan isim vererek yanıt ver: katıldığın ve itiraz ettiğin noktaları, riskleri ve daha iyi alternatifi belirt."
                }

                if let out = await executeTurn(agentId: id, prompt: prompt, zone: .meetingRoom) {
                    lastPipelineOutputs.append(("\(a.name) (Tur \(round))", a.title, a.modelId, out))
                    recordDialogue(from: a, toName: "Toplantı Odası", content: String(out.prefix(280)), kind: .debate)
                    transcript += "\n\n[\(a.name) — \(a.title) (Tur \(round))]:\n\(String(out.prefix(2000)))"
                    transcript = ContextCompactor.compactDebateTranscript(transcript, goal: goal, maxChars: 12_000)
                    lastSpeakerId = id
                }
            }
        }
    }

    private func runAutonomousProjectSprint(goal: String, participantIds: [UUID]) async {
        // Dynamically resolve roles from participant agents
        let archCandidate = participantIds.first(where: { pid in
            guard let a = agents.first(where: { $0.id == pid }) else { return false }
            let n = a.name.lowercased(), t = a.title.lowercased()
            return n.contains("atlas") || n.contains("mimar") || t.contains("mimar") || t.contains("architect")
        }) ?? participantIds[0]

        let coderCandidate = participantIds.first(where: { pid in
            guard pid != archCandidate, let a = agents.first(where: { $0.id == pid }) else { return false }
            let n = a.name.lowercased(), t = a.title.lowercased()
            return n.contains("kod") || t.contains("yazılım") || t.contains("geliştirici") || t.contains("developer") || t.contains("swift")
        }) ?? (participantIds.first(where: { $0 != archCandidate }) ?? archCandidate)

        let auditorCandidate = participantIds.first(where: { pid in
            guard pid != archCandidate && pid != coderCandidate, let a = agents.first(where: { $0.id == pid }) else { return false }
            let n = a.name.lowercased(), t = a.title.lowercased()
            return n.contains("denet") || n.contains("kalkan") || t.contains("denet") || t.contains("güvenlik") || t.contains("audit") || t.contains("qa")
        }) ?? (participantIds.last ?? archCandidate)

        let architectId = archCandidate
        let coderId = coderCandidate
        let auditorId = auditorCandidate

        let coderAgent = agents.first(where: { $0.id == coderId })
        let coderName = coderAgent?.name ?? "Geliştirici"

        // Phase 1: Architect plans after inspecting workspace
        var sprintContext = "PROJE SPRINT HEDEFİ:\n\(goal)\nAktif Klasör: \(workspacePath)"
        if let arch = agents.first(where: { $0.id == architectId }) {
            pipelineStatusText = "1/4 Mimari Plan: \(arch.name) projeyi inceliyor..."
            let p1 = "\(sprintContext)\n\nGerekirse `list_dir` veya `read_file` kullanarak proje yapısını kontrol et. Değişecek dosyaları ve kesin uygulama adımlarını çıkar."
            if let out1 = await executeTurn(agentId: architectId, prompt: p1, zone: .meetingRoom) {
                lastPipelineOutputs.append((arch.name, "1. Mimari Plan", arch.modelId, out1))
                recordDialogue(from: arch, toName: coderName, content: "Plan hazır: " + String(out1.prefix(220)), kind: .handoff)
                sprintContext += "\n\n--- MİMARİ PLAN (\(arch.name)) ---\n\(String(out1.prefix(2600)))"
            }
        }
        if Task.isCancelled { return }

        // Phase 2: Coder implements changes safely (or prepares dry-run diff if writes are locked)
        if let coder = coderAgent {
            if architectId != coderId {
                showBeam(from: architectId, to: coderId, label: "📐 Plan → Kod", accentHex: coder.accentHex, duration: 5.5)
            }
            pipelineStatusText = "2/4 Geliştirme: \(coder.name) \(allowFileWrites ? "kodu uyguluyor..." : "yama önerisi hazırlıyor...")"
            let p2 = allowFileWrites
                ? "\(sprintContext)\n\n[FAZ 2 — GELİŞTİRME ROLÜ]\nPlanı uygula. Dosya düzenlemesi gerekiyorsa `patch_file` veya `write_file` aracını kullan (her değişiklik otomatik yedeklenir)."
                : "\(sprintContext)\n\n[FAZ 2 — SALT-OKUNUR ÖNERİ MODU]\nDosya yazma izni kapalı olduğu için dosyalara yazma yapmadan yalnızca doğrulanmış kod yama önerisi sun."
            if let out2 = await executeTurn(agentId: coderId, prompt: p2, zone: .desk) {
                lastPipelineOutputs.append((coder.name, allowFileWrites ? "2. Uygulama" : "2. Yama Önerisi", coder.modelId, out2))
                recordDialogue(from: coder, toName: "Ekip", content: "Uygulama tamam: " + String(out2.prefix(220)), kind: .handoff)
                sprintContext += "\n\n--- KOD UYGULAMASI (\(coder.name)) ---\n\(String(out2.prefix(2600)))"
            }
        }
        if Task.isCancelled { return }

        // Phase 3: Build/Test Verification + Automatic Self-Healing (up to 2 retries when writes allowed!)
        if autoVerifyBuild, let buildCmd = PowerShellTools.detectBuildCommand(workspacePath: workspacePath, customOverride: customBuildCommand) {
            var attempt = 0
            while attempt <= 2 {
                if Task.isCancelled { return }
                let label = attempt == 0 ? "İlk Kontrol" : "Onarım Sonrası \(attempt)/2"
                pipelineStatusText = "3/4 Doğrulama: `\(buildCmd)` çalıştırılıyor (\(label))..."
                let buildRes = await PowerShellTools.runCommand(buildCmd, workspacePath: workspacePath, wrapWithRTK: enableRTKProxy)
                if Task.isCancelled { return }
                if buildRes.succeeded {
                    lastBuildVerification = (true, "✅ `\(buildCmd)` hatasız geçti!")
                    log(.success, source: "Build Gate", "`\(buildCmd)` başarılı.")
                    recordDialogue(from: nil, toName: "Ekip", content: "✅ Derleme/Test geçti: `\(buildCmd)`", kind: .buildFix)
                    sprintContext += "\n\n--- BUILD DOĞRULAMA: BAŞARILI (`\(buildCmd)`) ---"
                    break
                } else {
                    lastBuildVerification = (false, "⚠️ `\(buildCmd)` hata verdi (\(label))")
                    if !allowFileWrites {
                        log(.warning, source: "Build Gate", "Derleme hatası tespit edildi; dosya yazma kapalı olduğu için otomatik onarım atlandı.")
                        sprintContext += "\n\n--- BUILD HATASI (Salt-okunur mod) ---\n\(buildRes.output.prefix(2500))"
                        break
                    }
                    if attempt == 2 {
                        sprintContext += "\n\n--- BUILD HATASI (2 onarım sonrası) ---\n\(buildRes.output.prefix(2500))"
                        break
                    }
                    log(.warning, source: "Build Gate", "Hata tespit edildi, \(coderName)'ye otomatik onarım \(attempt + 1)/2 gönderiliyor...")
                    if let coder = coderAgent {
                        showBeam(from: auditorId, to: coderId, label: "🔧 Onarım #\(attempt + 1)", accentHex: "#EF4444", duration: 5.0)
                        recordDialogue(from: nil, toName: coder.name, content: "Build hatası yakalandı, otomatik onarım \(attempt + 1)/2 başlatıldı.", kind: .buildFix)
                        let fixPrompt = "OTOMATİK ONARIM (Deneme \(attempt + 1)/2)\n`\(buildCmd)` komutu şu hatayla başarısız oldu:\n```\n\(buildRes.output.prefix(3500))\n```\nKök nedeni bul ve `patch_file` / `write_file` ile hatayı düzelt."
                        if let fixOut = await executeTurn(agentId: coderId, prompt: fixPrompt, zone: .desk) {
                            lastPipelineOutputs.append((coder.name, "Otomatik Onarım #\(attempt + 1)", coder.modelId, fixOut))
                        }
                    }
                    attempt += 1
                }
            }
        }
        if Task.isCancelled { return }

        // Phase 4: Security & Quality Audit
        if let auditor = agents.first(where: { $0.id == auditorId }) {
            if coderId != auditorId {
                showBeam(from: coderId, to: auditorId, label: "🛡️ Audit", accentHex: auditor.accentHex, duration: 5.0)
            }
            pipelineStatusText = "4/4 Denetim: \(auditor.name) son kontrolü yapıyor..."
            let p4 = "\(sprintContext)\n\n[FAZ 4 — GÜVENLİK & KALİTE DENETİMİ]\nYapılan değişiklikleri ve doğrulama sonucunu denetle. Kalan riskleri veya onay durumunu net yaz."
            if let out4 = await executeTurn(agentId: auditorId, prompt: p4, zone: .meetingRoom) {
                lastPipelineOutputs.append((auditor.name, "4. Güvenlik & Kalite Denetimi", auditor.modelId, out4))
                recordDialogue(from: auditor, toName: "Ekip", content: "Denetim: " + String(out4.prefix(220)), kind: .debate)
            }
        }
    }

    // MARK: - Self-Improvement Engine (Distill Lessons into MEMORY.md + Generate New OpenClaw SKILL.md)

    func failoverCandidates(
        primaryProvider prov: APIProviderConfig,
        primaryModel model: String,
        agentFallbackModelIds: [String],
        preferIdleOverBusy: Bool = true
    ) -> [(provider: APIProviderConfig, model: String, isFallback: Bool)] {
        var candidates: [(provider: APIProviderConfig, model: String, isFallback: Bool)] = []
        if prov.isEnabled && prov.isConfigured {
            if SwarmsRuntimeService.providerSupportsModel(prov, modelId: model) {
                candidates.append((provider: prov, model: model, isFallback: false))
            } else if let owningProv = providers.first(where: { $0.id != prov.id && $0.isEnabled && $0.isConfigured && SwarmsRuntimeService.providerSupportsModel($0, modelId: model) }) {
                candidates.append((provider: owningProv, model: model, isFallback: true))
            } else {
                candidates.append((provider: prov, model: model, isFallback: false))
            }
            for fb in agentFallbackModelIds where fb != model && SwarmsRuntimeService.providerSupportsModel(prov, modelId: fb) {
                if candidates.count < 4 {
                    candidates.append((provider: prov, model: fb, isFallback: true))
                }
            }
            for extra in prov.uniqueModels where SwarmsRuntimeService.providerSupportsModel(prov, modelId: extra)
                && !candidates.contains(where: { $0.provider.id == prov.id && $0.model == extra }) {
                if candidates.count < 4 {
                    candidates.append((provider: prov, model: extra, isFallback: true))
                }
            }
        }

        // Cross-provider matching for explicitly listed fallback models
        for fb in agentFallbackModelIds where fb != model {
            if let matchingProv = providers.first(where: { $0.id != prov.id && $0.isEnabled && $0.isConfigured && SwarmsRuntimeService.providerSupportsModel($0, modelId: fb) }),
               !candidates.contains(where: { $0.provider.id == matchingProv.id && $0.model == fb }) {
                candidates.append((provider: matchingProv, model: fb, isFallback: true))
            }
        }

        func appendFallbackProvider(_ altProv: APIProviderConfig) {
            guard altProv.isEnabled, altProv.isConfigured else { return }
            let primaryM = altProv.defaultModel.isEmpty ? (altProv.models.first ?? "") : altProv.defaultModel
            if !primaryM.isEmpty
                && ModelRouter.isChatCapableModel(primaryM)
                && !candidates.contains(where: { $0.provider.id == altProv.id && $0.model == primaryM }) {
                candidates.append((provider: altProv, model: primaryM, isFallback: true))
            }
            for backupM in altProv.uniqueModels where backupM != primaryM
                && ModelRouter.isChatCapableModel(backupM)
                && !candidates.contains(where: { $0.provider.id == altProv.id && $0.model == backupM }) {
                candidates.append((provider: altProv, model: backupM, isFallback: true))
                break
            }
        }

        if let fProvId = prov.fallbackProviderId, let altProv = provider(for: fProvId) {
            appendFallbackProvider(altProv)
        }
        for otherProv in providers where otherProv.id != prov.id {
            appendFallbackProvider(otherProv)
        }

        if candidates.isEmpty, let anyConfigured = providers.first(where: { $0.isEnabled && $0.isConfigured }) ?? providers.first(where: { $0.isConfigured }) {
            let altM = anyConfigured.defaultModel.isEmpty ? (anyConfigured.models.first ?? "deepseek-v4.1-flash") : anyConfigured.defaultModel
            candidates.append((provider: anyConfigured, model: altM, isFallback: true))
        }

        // Prioritize non-cooled, online, and (when requested) idle models while keeping cooled backups as last resort.
        let now = Date()
        func isCandCooled(_ c: (provider: APIProviderConfig, model: String, isFallback: Bool)) -> Bool {
            isProviderInCooldown(c.provider.id) || isModelInCooldown(providerId: c.provider.id, modelId: c.model, now: now)
        }
        func isCandOnline(_ c: (provider: APIProviderConfig, model: String, isFallback: Bool)) -> Bool {
            return providerStatuses[c.provider.id]?.isOnline != false
        }
        func inFlight(_ c: (provider: APIProviderConfig, model: String, isFallback: Bool)) -> Int {
            modelMetrics[ModelRouteKey(providerId: c.provider.id, modelId: c.model)]?.inFlightCount ?? 0
        }
        func isProvSaturated(_ c: (provider: APIProviderConfig, model: String, isFallback: Bool)) -> Bool {
            guard c.provider.kind == .evren else { return false }
            return providerInFlightCount(c.provider.id) >= 3
        }

        let healthy = candidates.filter { !isCandCooled($0) }
        let onlineHealthy = healthy.filter { isCandOnline($0) }
        let offlineHealthy = healthy.filter { !isCandOnline($0) }
        let cooled = candidates.filter { isCandCooled($0) }

        let orderedOnlineHealthy: [(provider: APIProviderConfig, model: String, isFallback: Bool)]
        if preferIdleOverBusy {
            let underCapIdle = onlineHealthy.filter { inFlight($0) == 0 && !isProvSaturated($0) }
            let busyOrSaturated = onlineHealthy
                .filter { inFlight($0) > 0 || isProvSaturated($0) }
                .sorted { lhs, rhs in
                    let lSat = isProvSaturated(lhs) ? 1 : 0
                    let rSat = isProvSaturated(rhs) ? 1 : 0
                    if lSat != rSat { return lSat < rSat }
                    let lIn = inFlight(lhs)
                    let rIn = inFlight(rhs)
                    if lIn != rIn { return lIn < rIn }
                    return providerInFlightCount(lhs.provider.id) < providerInFlightCount(rhs.provider.id)
                }
            orderedOnlineHealthy = underCapIdle + busyOrSaturated
        } else {
            orderedOnlineHealthy = onlineHealthy
        }
        return Array((orderedOnlineHealthy + offlineHealthy + cooled).prefix(12))
    }

    func recordSwarmsTelemetry(_ telemetry: SwarmsRunTelemetry?) {
        guard let telemetry else { return }
        func resolveProvider(kind: String, name: String) -> APIProviderConfig? {
            providers.first(where: { !$0.name.isEmpty && $0.name == name && $0.kind.rawValue == kind })
                ?? providers.first(where: { !$0.name.isEmpty && $0.name == name })
                ?? providers.first(where: { $0.kind.rawValue == kind })
        }
        var fatalProviderIds: Set<UUID> = []
        for used in telemetry.usedRoutes {
            guard let prov = resolveProvider(kind: used.providerKind, name: used.providerName) else { continue }
            recordModelSuccess(providerId: prov.id, modelId: used.modelName, latencyMs: 1200)
        }
        for fail in telemetry.failedCandidates {
            guard let prov = resolveProvider(kind: fail.providerKind, name: fail.providerName) else { continue }
            if fail.isProviderFatal || Self.isFatalAuthOrNetworkMessage(fail.error) {
                fatalProviderIds.insert(prov.id)
                markProviderCooldown(prov.id, seconds: 300)
            } else if !fatalProviderIds.contains(prov.id) {
                markModelCooldown(
                    providerId: prov.id,
                    modelId: fail.modelName,
                    seconds: 45,
                    isRateLimit: Self.isRateLimitErrorMessage(fail.error)
                )
            }
        }
    }

    @discardableResult
    func rebalanceAgentsToHealthyProviders() -> String {
        var updatedCount = 0
        var workingRoster = agents
        for idx in workingRoster.indices {
            let a = workingRoster[idx]
            let currentProv = provider(for: a.providerId)
            let provHealthy = (currentProv?.isEnabled == true)
                && (currentProv?.isConfigured == true)
                && !isProviderInCooldown(a.providerId)
                && (providerStatuses[a.providerId]?.isOnline != false)
            let modelHealthy = !isModelInCooldown(providerId: a.providerId, modelId: a.modelId)
                && (currentProv.map { SwarmsRuntimeService.providerSupportsModel($0, modelId: a.modelId) } ?? false)
            guard !provHealthy || !modelHealthy else { continue }

            let decision = ModelRouter.selectModelForHire(
                name: a.name,
                title: a.title,
                systemPrompt: a.systemPrompt,
                requestedModel: "auto",
                providers: providers,
                existingAgents: workingRoster.enumerated().filter { $0.offset != idx }.map(\.element),
                providerStatuses: providerStatuses,
                providerCooldowns: providerCooldowns,
                modelMetrics: modelMetrics
            )
            workingRoster[idx].providerId = decision.provider.id
            workingRoster[idx].modelId = decision.modelId
            workingRoster[idx].fallbackModelIds = decision.fallbackModelIds
            workingRoster[idx].agyConversationId = nil
            updatedCount += 1
            log(.info, source: a.name, "⚖️ Akıllı Dengeleme → \(decision.provider.name) / \(decision.modelId)")
        }
        if updatedCount > 0 {
            agents = workingRoster
            saveConfig()
            return "\(updatedCount) ajan sağlıklı ve müsait modellere dengelendi ✓"
        }
        return "Tüm ajanlar zaten sağlıklı ve uyumlu modeller üzerinde çalışıyor."
    }

    private func runOneShotWithFailover(
        lead: OfficeAgent,
        prov: APIProviderConfig,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double
    ) async throws -> LLMFinalResponse {
        let primaryModel = lead.modelId.isEmpty ? prov.defaultModel : lead.modelId
        let candidates = failoverCandidates(primaryProvider: prov, primaryModel: primaryModel, agentFallbackModelIds: lead.fallbackModelIds)
        var lastError: Error = LLMClientError.emptyResponse
        for (idx, c) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let res = try await LLMClient.shared.streamChat(
                    provider: c.provider,
                    model: c.model,
                    systemPrompt: systemPrompt,
                    messages: [ChatMessage(role: "user", content: userPrompt)],
                    temperature: temperature,
                    stream: enableStreaming,
                    workspacePath: workspacePath,
                    allowLocalEdits: false,
                    onDelta: { _ in }
                )
                if idx > 0 {
                    log(.warning, source: "Öz-Gelişim", "🔄 Devralma: \(c.provider.name) / \(res.resolvedModel)")
                }
                return res
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                log(.warning, source: "Öz-Gelişim", "\(c.provider.name) / \(c.model) hata: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    func distillLessonFromRecentWork(topic: String, outputs: [(agentName: String, title: String, model: String, output: String)]) async {
        guard let lead = agents.first(where: { provider(for: $0.providerId)?.isConfigured == true }),
              let prov = provider(for: lead.providerId) else { return }

        pipelineStatusText = "Öz-Gelişim: Ekip öğrendiklerini MEMORY.md'ye işliyor..."
        let digest = outputs.map { "\($0.agentName): \($0.output.prefix(350))" }.joined(separator: "\n")
        let prompt = "Son tamamlanan görev ('\(topic)') ve ekip çıktılarından gelecekte hataları önleyecek EN DEĞERLİ 1-2 somut teknik kuralı tek paragrafta (maksimum 220 karakter) özetle:\n\(digest)"

        do {
            let res = try await runOneShotWithFailover(
                lead: lead,
                prov: prov,
                systemPrompt: "Kısa, somut, tekrar kullanılabilir tek mühendislik dersi yaz.",
                userPrompt: prompt,
                temperature: 0.2
            )
            let lesson = res.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            OpenClawWorkspaceService.appendLearnedLesson(lesson, source: "Sprint Öz-Gelişim", openClawHome: openClawHomePath)
            recordDialogue(from: lead, toName: "MEMORY.md", content: "🧠 Öğrenildi: \(lesson)", kind: .retrospective)
            log(.evolve, source: "Öz-Gelişim", "MEMORY.md güncellendi: \(lesson.prefix(120))")
            saveConfig()
        } catch {
            log(.warning, source: "Öz-Gelişim", "Öğrenilen ders işlenemedi: \(error.localizedDescription)")
        }
    }

    func runTeamRetrospective(createNewSkill: Bool) {
        guard !isRunningPipeline else { return }
        guard let lead = agents.first(where: { provider(for: $0.providerId)?.isConfigured == true }) else {
            log(.warning, source: "Öz-Gelişim", "Retrospektif için en az bir yapılandırılmış API sağlayıcısı gerekir.")
            return
        }
        let pToken = UUID()
        pipelineToken = pToken
        isRunningPipeline = true
        pipelineStatusText = "Ekip retrospektifi & öz-gelişim oturumu başlıyor..."

        pipelineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pipelineToken == pToken {
                    self.isRunningPipeline = false
                    self.pipelineTask = nil
                    self.pipelineToken = nil
                    self.recallAllAgentsToDesks()
                }
            }
            guard let prov = self.provider(for: lead.providerId) else {
                self.pipelineStatusText = "Retrospektif için geçerli API sağlayıcısı bulunamadı."
                return
            }
            for i in self.agents.indices {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) {
                    let angle = Double(i) * (2.0 * Double.pi / Double(max(1, self.agents.count)))
                    self.agents[i].currentPosition = Point2D(x: 0.50 + cos(angle) * 0.125, y: 0.50 + sin(angle) * 0.082)
                    self.agents[i].currentZone = .meetingRoom
                    self.agents[i].status = .improving
                    self.agents[i].statusBubble = "Retrospektif · Öğreniyor..."
                }
            }

            let recentErrors = self.logs.filter { $0.level == .error || $0.level == .warning }.prefix(8).map { "\($0.source): \($0.message)" }.joined(separator: "\n")
            let recentEdits = self.fileEdits.prefix(8).map { "\($0.agentName) → \($0.relativePath): \($0.summary)" }.joined(separator: "\n")
            let currentMem = OpenClawWorkspaceService.readFile(named: "MEMORY.md", in: self.openClawHomePath)

            let retroPrompt = """
            EKİP RETROSPEKTİFİ & ÖZ-GELİŞİM OTURUMU
            Son Uyarı/Hatalar:
            \(recentErrors.isEmpty ? "(Hata yok)" : recentErrors)

            Son Dosya Değişiklikleri:
            \(recentEdits.isEmpty ? "(Henüz yok)" : recentEdits)

            Mevcut MEMORY.md Özeti:
            \(String(currentMem.suffix(1200)))

            GÖREV:
            1) Ekibin bir sonraki projede daha az hata yapması ve daha hızlı teslim etmesi için 3 somut iyileştirme kuralı çıkar.
            \(createNewSkill ? "2) En alta tam şu formatta yeni bir OpenClaw yeteneği ekle: <new_skill slug=\"kisa-ad\" name=\"Skill Adı\" desc=\"Kısa açıklama\">Skill talimat gövdesi</new_skill>" : "")
            """

            do {
                let res = try await self.runOneShotWithFailover(
                    lead: lead,
                    prov: prov,
                    systemPrompt: "Sen kendini sürekli geliştiren kıdemli bir mühendislik liderisin.",
                    userPrompt: retroPrompt,
                    temperature: 0.35
                )
                try Task.checkCancellation()
                let text = res.content
                OpenClawWorkspaceService.appendLearnedLesson(String(text.prefix(420)).replacingOccurrences(of: "\n", with: " "), source: "Ekip Retrospektifi", openClawHome: self.openClawHomePath)
                self.recordDialogue(from: lead, toName: "Tüm Ekip", content: "🧠 Retrospektif tamamlandı ve MEMORY.md'ye kaydedildi.", kind: .retrospective)
                self.lastPipelineOutputs.insert((lead.name, "Ekip Retrospektifi (Öz-Gelişim)", res.resolvedModel, text), at: 0)

                // Parse optional <new_skill ...>...</new_skill>
                if createNewSkill,
                   let sTag = text.range(of: "<new_skill "),
                   let closeOpen = text.range(of: ">", range: sTag.upperBound..<text.endIndex),
                   let endTag = text.range(of: "</new_skill>", range: closeOpen.upperBound..<text.endIndex) {
                    let attrs = String(text[sTag.upperBound..<closeOpen.lowerBound])
                    let body = String(text[closeOpen.upperBound..<endTag.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let slug = Self.extractAttr("slug", from: attrs) ?? "evolved-skill-\(Int(Date().timeIntervalSince1970) % 1000)"
                    let name = Self.extractAttr("name", from: attrs) ?? "Geliştirilmiş Yetenek"
                    let desc = Self.extractAttr("desc", from: attrs) ?? "Ekip retrospektifinde otomatik oluşturuldu."
                    if let savedPath = try? OpenClawWorkspaceService.saveEvolvedSkill(slug: slug, name: name, description: desc, body: body, openClawHome: self.openClawHomePath) {
                        self.log(.evolve, source: "Yeni Skill", "Otomatik SKILL.md üretildi: \(savedPath)")
                        self.refreshWorkspaceAndSkills(enabledIds: Set(self.skills.filter { $0.isEnabled }.map { $0.id } + [slug]))
                    }
                }

                self.incrementCompletedTasks(for: lead.id)
                self.log(.evolve, source: "Öz-Gelişim", "Ekip retrospektifi tamamlandı, MEMORY.md ve kurallar güncellendi.")
                self.saveConfig()
                self.pipelineStatusText = "Retrospektif başarıyla tamamlandı."
            } catch {
                self.log(.error, source: "Öz-Gelişim", "Retrospektif hatası: \(error.localizedDescription)")
                self.pipelineStatusText = "Retrospektif başarısız: \(error.localizedDescription)"
            }
        }
    }

    private static func isBuildOrTestCommand(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "swift build", "swift test", "xcodebuild", "build_app.sh",
            "npm run build", "npm test", "pnpm build", "pnpm test",
            "cargo build", "cargo check", "cargo test", "pytest",
            "python -m unittest", "tsc ", "make test"
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    nonisolated static func extractAttr(_ key: String, from raw: String) -> String? {
        for q in ["\"", "'"] {
            if let kRange = raw.range(of: "\(key)=\(q)"),
               let endQuote = raw.range(of: q, range: kRange.upperBound..<raw.endIndex) {
                return String(raw[kRange.upperBound..<endQuote.lowerBound])
            }
        }
        return nil
    }
}
