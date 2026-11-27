import Foundation

// MARK: - Swarms Runtime Daemon Models

struct SwarmsDaemonHealth: Codable, Sendable, Equatable {
    var status: String
    var service: String
    var swarmsVersion: String
    var bridgeVersion: String?
    var uptimeSeconds: Double
    var activeRuns: Int
    var totalRuns: Int
    var workspaceDir: String
    var supportedSwarmTypes: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case service
        case swarmsVersion = "swarms_version"
        case bridgeVersion = "bridge_version"
        case uptimeSeconds = "uptime_seconds"
        case activeRuns = "active_runs"
        case totalRuns = "total_runs"
        case workspaceDir = "workspace_dir"
        case supportedSwarmTypes = "supported_swarm_types"
    }

    var isHealthy: Bool { status.lowercased() == "ok" }
}

struct SwarmsRunSummary: Identifiable, Codable, Sendable, Equatable {
    var id: String { runId }
    var runId: String
    var swarmType: String
    var taskPreview: String
    var agentNames: [String]
    var status: String
    var durationMs: Int
    var stepCount: Int
    var outputPreview: String
    var error: String?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case swarmType = "swarm_type"
        case taskPreview = "task_preview"
        case agentNames = "agent_names"
        case status
        case durationMs = "duration_ms"
        case stepCount = "step_count"
        case outputPreview = "output_preview"
        case error
    }
}

struct SwarmsRunsListResponse: Codable, Sendable {
    var active: [SwarmsRunSummary]
    var recent: [SwarmsRunSummary]
    var totalRuns: Int

    enum CodingKeys: String, CodingKey {
        case active
        case recent
        case totalRuns = "total_runs"
    }
}

struct SwarmsStepResult: Codable, Sendable, Equatable {
    var agentName: String
    var role: String
    var model: String
    var output: String

    enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case role
        case model
        case output
    }
}

struct SwarmsCandidateFailure: Codable, Sendable, Equatable {
    var providerKind: String
    var providerName: String
    var modelName: String
    var error: String
    var isProviderFatal: Bool

    enum CodingKeys: String, CodingKey {
        case providerKind = "provider_kind"
        case providerName = "provider_name"
        case modelName = "model_name"
        case error
        case isProviderFatal = "is_provider_fatal"
    }
}

struct SwarmsCandidateSuccess: Codable, Sendable, Equatable {
    var providerKind: String
    var providerName: String
    var modelName: String
    var usedFallback: Bool

    enum CodingKeys: String, CodingKey {
        case providerKind = "provider_kind"
        case providerName = "provider_name"
        case modelName = "model_name"
        case usedFallback = "used_fallback"
    }
}

struct SwarmsRunTelemetry: Codable, Sendable, Equatable {
    var failedCandidates: [SwarmsCandidateFailure]
    var usedRoutes: [SwarmsCandidateSuccess]

    enum CodingKeys: String, CodingKey {
        case failedCandidates = "failed_candidates"
        case usedRoutes = "used_routes"
    }
}

struct SwarmsRunResult: Codable, Sendable {
    var runId: String
    var swarmType: String
    var status: String
    var durationMs: Int
    var finalOutput: String
    var steps: [SwarmsStepResult]
    var telemetry: SwarmsRunTelemetry?

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case swarmType = "swarm_type"
        case status
        case durationMs = "duration_ms"
        case finalOutput = "final_output"
        case steps
        case telemetry
    }
}

struct SwarmsProviderPayload: Codable, Sendable {
    var kind: String
    var name: String
    var baseUrl: String
    var apiKey: String
    var authStyle: String
    var modelName: String
    var fallbackModels: [String]
    var timeoutSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case name
        case baseUrl = "base_url"
        case apiKey = "api_key"
        case authStyle = "auth_style"
        case modelName = "model_name"
        case fallbackModels = "fallback_models"
        case timeoutSeconds = "timeout_seconds"
    }
}

struct SwarmsAgentPayload: Codable, Sendable {
    var name: String
    var title: String
    var systemPrompt: String
    var modelName: String
    var temperature: Double
    var role: String
    var provider: SwarmsProviderPayload
    var fallbackProvider: SwarmsProviderPayload?
    var fallbackProviders: [SwarmsProviderPayload]

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case systemPrompt = "system_prompt"
        case modelName = "model_name"
        case temperature
        case role
        case provider
        case fallbackProvider = "fallback_provider"
        case fallbackProviders = "fallback_providers"
    }
}

struct SwarmsRetryPolicy: Codable, Sendable {
    var maxRetries: Int
    var initialDelay: Double
    var multiplier: Double

    enum CodingKeys: String, CodingKey {
        case maxRetries = "max_retries"
        case initialDelay = "initial_delay"
        case multiplier
    }

    init(maxRetries: Int = 3, initialDelay: Double = 1.0, multiplier: Double = 2.0) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.multiplier = multiplier
    }
}

struct SwarmsRunRequestPayload: Codable, Sendable {
    var task: String
    var swarmType: String
    var maxLoops: Int
    var rearrangeFlow: String?
    var workspacePath: String?
    var allowLocalEdits: Bool
    var agents: [SwarmsAgentPayload]
    var director: SwarmsAgentPayload?
    var retryPolicy: SwarmsRetryPolicy?

    enum CodingKeys: String, CodingKey {
        case task
        case swarmType = "swarm_type"
        case maxLoops = "max_loops"
        case rearrangeFlow = "rearrange_flow"
        case workspacePath = "workspace_path"
        case allowLocalEdits = "allow_local_edits"
        case agents
        case director
        case retryPolicy = "retry_policy"
    }
}

enum SwarmsRuntimeError: LocalizedError {
    case invalidEndpoint(String)
    case daemonUnavailable(String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let u): return "Geçersiz Swarms daemon adresi: \(u)"
        case .daemonUnavailable(let r): return "Swarms servisine erişilemedi: \(r)"
        case .serverError(let code, let msg): return "Swarms HTTP \(code): \(msg)"
        }
    }
}

// MARK: - Persistent Swarms Daemon Client & LaunchAgent Manager

enum SwarmsRuntimeService {
    static let defaultBaseURL = "http://127.0.0.1:8765"
    static let launchAgentLabel = "com.clawoffice.swarms"
    static let expectedBridgeVersion = "2026.11.26.2"

    private static let healthSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.5
        cfg.timeoutIntervalForResource = 4.0
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private static let runSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 900
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    static func checkHealth(baseURL: String = defaultBaseURL) async -> SwarmsDaemonHealth? {
        guard let url = URL(string: "\(baseURL)/health") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 2.5)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await healthSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(SwarmsDaemonHealth.self, from: data)
        } catch {
            return nil
        }
    }

    static func fetchRecentRuns(baseURL: String = defaultBaseURL) async -> SwarmsRunsListResponse? {
        guard let url = URL(string: "\(baseURL)/v1/swarm/runs") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3.0)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await healthSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(SwarmsRunsListResponse.self, from: data)
        } catch {
            return nil
        }
    }

    static func runSwarm(
        _ payload: SwarmsRunRequestPayload,
        baseURL: String = defaultBaseURL
    ) async throws -> SwarmsRunResult {
        guard let url = URL(string: "\(baseURL)/v1/swarm/run") else {
            throw SwarmsRuntimeError.invalidEndpoint(baseURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CrimsOffice/4.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await runSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errMsg = obj["error"] as? String {
                throw SwarmsRuntimeError.serverError(status, errMsg)
            }
            let text = String(decoding: data, as: UTF8.self)
            throw SwarmsRuntimeError.serverError(status, text.isEmpty ? "Bilinmeyen hata" : String(text.prefix(400)))
        }
        return try JSONDecoder().decode(SwarmsRunResult.self, from: data)
    }

    static func cancelRun(runId: String, baseURL: String = defaultBaseURL) async {
        guard !runId.isEmpty, let url = URL(string: "\(baseURL)/v1/swarm/cancel/\(runId)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 3.0)
        req.httpMethod = "POST"
        _ = try? await healthSession.data(for: req)
    }

    static func cancelAllActiveRuns(baseURL: String = defaultBaseURL) async {
        guard let list = await fetchRecentRuns(baseURL: baseURL) else { return }
        for r in list.active {
            await cancelRun(runId: r.runId, baseURL: baseURL)
        }
    }

    // MARK: - Payload Mapping (Zero Secret Persistence)

    static func providerSupportsModel(_ provider: APIProviderConfig, modelId: String) -> Bool {
        let clean = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, ModelRouter.isChatCapableModel(clean) else { return false }
        let catalog = provider.uniqueModels
        if catalog.isEmpty { return true }
        return catalog.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    static func makeProviderPayload(
        _ provider: APIProviderConfig,
        overrideModel: String? = nil,
        fallbackModels: [String] = []
    ) -> SwarmsProviderPayload {
        let cleanDefault = (overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? overrideModel!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (provider.defaultModel.isEmpty ? (provider.uniqueModels.first ?? "deepseek-v4.1-flash") : provider.defaultModel)
        var sanitizedFallbacks: [String] = []
        for fb in fallbackModels {
            let trimmed = fb.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != cleanDefault,
               providerSupportsModel(provider, modelId: trimmed),
               !sanitizedFallbacks.contains(trimmed) {
                sanitizedFallbacks.append(trimmed)
            }
            if sanitizedFallbacks.count >= 5 { break }
        }
        return SwarmsProviderPayload(
            kind: provider.kind.rawValue,
            name: provider.name,
            baseUrl: provider.normalizedBaseURL,
            apiKey: provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            authStyle: provider.authStyle.rawValue,
            modelName: cleanDefault,
            fallbackModels: sanitizedFallbacks
        )
    }

    static func buildAgentPayloads(
        agents: [OfficeAgent],
        providers: [APIProviderConfig],
        providerStatuses: [UUID: ProviderHealthStatus] = [:],
        providerCooldowns: [UUID: Date] = [:],
        modelMetrics: [ModelRouteKey: ModelRuntimeMetrics] = [:],
        now: Date = Date()
    ) -> [SwarmsAgentPayload] {
        func isProviderCooled(_ id: UUID) -> Bool {
            guard let until = providerCooldowns[id] else { return false }
            return now < until
        }
        func isModelCooled(_ provId: UUID, _ modelId: String) -> Bool {
            modelMetrics[ModelRouteKey(providerId: provId, modelId: modelId)]?.isInCooldown(now: now) == true
        }
        func inFlight(_ provId: UUID, _ modelId: String) -> Int {
            modelMetrics[ModelRouteKey(providerId: provId, modelId: modelId)]?.inFlightCount ?? 0
        }

        let enabledConfigured = providers.filter { $0.isEnabled && $0.isConfigured }
        let orderedProviders = enabledConfigured.sorted { lhs, rhs in
            let lOnline = providerStatuses[lhs.id]?.isOnline != false && !isProviderCooled(lhs.id)
            let rOnline = providerStatuses[rhs.id]?.isOnline != false && !isProviderCooled(rhs.id)
            if lOnline != rOnline { return lOnline }
            let lLat = providerStatuses[lhs.id]?.latencyMs ?? 500
            let rLat = providerStatuses[rhs.id]?.latencyMs ?? 500
            if lLat != rLat { return lLat < rLat }
            return lhs.name < rhs.name
        }

        return agents.map { agent in
            let assigned = providers.first(where: { $0.id == agent.providerId && $0.isEnabled && $0.isConfigured })
            let assignedHealthy = assigned.map { providerStatuses[$0.id]?.isOnline != false && !isProviderCooled($0.id) } ?? false
            let candidatePrimaryModel = agent.modelId.trimmingCharacters(in: .whitespacesAndNewlines)

            // Promote a healthy online provider if the agent's assigned provider is offline, cooled, or unsupported
            let primary: APIProviderConfig
            if let assigned, assignedHealthy || orderedProviders.isEmpty {
                if candidatePrimaryModel.isEmpty || providerSupportsModel(assigned, modelId: candidatePrimaryModel) {
                    primary = assigned
                } else if let owning = orderedProviders.first(where: { providerSupportsModel($0, modelId: candidatePrimaryModel) }) {
                    primary = owning
                } else {
                    primary = assigned
                }
            } else if let best = orderedProviders.first {
                primary = best
            } else {
                primary = assigned ?? providers.first ?? APIProviderConfig(name: "Antigravity CLI", kind: .antigravityCLI, baseURL: "")
            }

            // Pick a healthy non-cooled, non-busy model from `primary` when its configured model is unusable
            var resolvedModel = candidatePrimaryModel
            if resolvedModel.isEmpty || !providerSupportsModel(primary, modelId: resolvedModel) {
                resolvedModel = primary.defaultModel.isEmpty ? (primary.uniqueModels.first ?? "deepseek-v4.1-flash") : primary.defaultModel
            }
            if isModelCooled(primary.id, resolvedModel) || inFlight(primary.id, resolvedModel) > 0 {
                if let idleBetter = (agent.fallbackModelIds + primary.uniqueModels).first(where: { m in
                    providerSupportsModel(primary, modelId: m)
                        && !isModelCooled(primary.id, m)
                        && inFlight(primary.id, m) == 0
                }) {
                    resolvedModel = idleBetter
                }
            }

            // Build intra-provider fallbacks strictly validated against `primary`'s model catalog
            var primaryFallbacks: [String] = []
            for fb in (agent.fallbackModelIds + primary.uniqueModels) where fb != resolvedModel {
                if providerSupportsModel(primary, modelId: fb),
                   !isModelCooled(primary.id, fb),
                   !primaryFallbacks.contains(fb) {
                    primaryFallbacks.append(fb)
                }
                if primaryFallbacks.count >= 5 { break }
            }

            // Build complete ordered chain of fallback providers: ALL healthy/online backups before any cooled/offline ones
            let healthyOrdered = orderedProviders.filter {
                providerStatuses[$0.id]?.isOnline != false && !isProviderCooled($0.id)
            }
            let degradedOrdered = orderedProviders.filter { p in
                !healthyOrdered.contains(where: { $0.id == p.id })
            }

            var fbProvs: [APIProviderConfig] = []
            func appendProviders(from pool: [APIProviderConfig]) {
                if let explicitId = primary.fallbackProviderId,
                   let expProv = pool.first(where: { $0.id == explicitId }),
                   expProv.id != primary.id,
                   !fbProvs.contains(where: { $0.id == expProv.id }) {
                    fbProvs.append(expProv)
                }
                for fbModel in agent.fallbackModelIds where fbModel != resolvedModel {
                    if let owner = pool.first(where: { p in
                        p.id != primary.id && !fbProvs.contains(where: { $0.id == p.id }) && providerSupportsModel(p, modelId: fbModel)
                    }) {
                        fbProvs.append(owner)
                    }
                }
                for other in pool where other.id != primary.id && !fbProvs.contains(where: { $0.id == other.id }) {
                    fbProvs.append(other)
                }
            }
            appendProviders(from: healthyOrdered)
            appendProviders(from: degradedOrdered)

            let fbPayloads: [SwarmsProviderPayload] = fbProvs.map { fbP in
                let chatModels = fbP.uniqueModels.filter { providerSupportsModel(fbP, modelId: $0) }
                let preferredFBModel = agent.fallbackModelIds.first(where: { providerSupportsModel(fbP, modelId: $0) })
                    ?? chatModels.first(where: { !isModelCooled(fbP.id, $0) && inFlight(fbP.id, $0) == 0 })
                    ?? (fbP.defaultModel.isEmpty ? (chatModels.first ?? "") : fbP.defaultModel)
                let backupModels = Array(chatModels.filter { $0 != preferredFBModel }.prefix(5))
                return makeProviderPayload(fbP, overrideModel: preferredFBModel, fallbackModels: backupModels)
            }

            return SwarmsAgentPayload(
                name: agent.name,
                title: agent.title,
                systemPrompt: agent.systemPrompt,
                modelName: resolvedModel,
                temperature: agent.temperature,
                role: inferSwarmRole(for: agent),
                provider: makeProviderPayload(primary, overrideModel: resolvedModel, fallbackModels: primaryFallbacks),
                fallbackProvider: fbPayloads.first,
                fallbackProviders: fbPayloads
            )
        }
    }

    static func inferSwarmRole(for agent: OfficeAgent) -> String {
        let hay = "\(agent.name) \(agent.title)".lowercased()
        if hay.contains("mimar") || hay.contains("architect") { return "architect" }
        if hay.contains("direktör") || hay.contains("director") || hay.contains("lider") || hay.contains("lead") { return "director" }
        if hay.contains("denet") || hay.contains("audit") || hay.contains("güvenlik") { return "auditor" }
        if hay.contains("qa") || hay.contains("test") { return "qa" }
        if hay.contains("tasar") || hay.contains("design") || hay.contains("ui") || hay.contains("ux") { return "designer" }
        if hay.contains("araştır") || hay.contains("research") { return "researcher" }
        if hay.contains("kod") || hay.contains("yazılım") || hay.contains("developer") || hay.contains("swift") || hay.contains("engineer") {
            return "developer"
        }
        return "specialist"
    }

    // MARK: - LaunchAgent Lifecycle (KeepAlive Daemon)

    static func resolveRuntimePaths(workspacePath: String) -> (pythonBin: String, bridgeScript: String, runtimeDir: String)? {
        let fm = FileManager.default
        let detected = AppConfig.detectDefaultWorkspacePath()
        let bundleRes = Bundle.main.resourceURL?.appendingPathComponent("swarms-runtime").path ?? ""
        let homeSwarms = fm.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/swarms-runtime").path
        let candidates = [
            workspacePath,
            detected,
            bundleRes,
            homeSwarms,
            fm.currentDirectoryPath,
            "/Volumes/DATA/Builds/ClawOffice"
        ]
        // 1) Öncelik: hazır .venv/bin/python + swarms_bridge.py
        for root in candidates where !root.isEmpty {
            let rtDir = root.hasSuffix("swarms-runtime")
                ? root
                : URL(fileURLWithPath: root).appendingPathComponent("swarms-runtime").path
            let py = URL(fileURLWithPath: rtDir).appendingPathComponent(".venv/bin/python").path
            let bridge = URL(fileURLWithPath: rtDir).appendingPathComponent("swarms_bridge.py").path
            if fm.isExecutableFile(atPath: py) && fm.fileExists(atPath: bridge) {
                return (py, bridge, rtDir)
            }
        }
        // 2) Fallback: sistem python3 + swarms_bridge.py (ör. paketlenmiş .app içindeki köprü)
        let systemPythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let sysPy = systemPythons.first(where: { fm.isExecutableFile(atPath: $0) }) {
            for root in candidates where !root.isEmpty {
                let rtDir = root.hasSuffix("swarms-runtime")
                    ? root
                    : URL(fileURLWithPath: root).appendingPathComponent("swarms-runtime").path
                let bridge = URL(fileURLWithPath: rtDir).appendingPathComponent("swarms_bridge.py").path
                if fm.fileExists(atPath: bridge) {
                    return (sysPy, bridge, rtDir)
                }
            }
        }
        return nil
    }

    static func launchAgentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    @discardableResult
    static func installLaunchAgentPlistIfPossible(workspacePath: String) -> Bool {
        guard let paths = resolveRuntimePaths(workspacePath: workspacePath) else {
            return false
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let logsDir = "\(home)/Library/Logs/ClawOffice"
        let wsDir = paths.runtimeDir.contains(".app/Contents/Resources")
            ? "\(home)/.openclaw/swarms-runtime/workspace"
            : URL(fileURLWithPath: paths.runtimeDir).appendingPathComponent("workspace").path
        try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: wsDir, withIntermediateDirectories: true)

        let plistURL = launchAgentPlistURL()
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(paths.pythonBin)</string>
                <string>\(paths.bridgeScript)</string>
                <string>--host</string>
                <string>127.0.0.1</string>
                <string>--port</string>
                <string>8765</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(paths.runtimeDir)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logsDir)/swarms-daemon.log</string>
            <key>StandardErrorPath</key>
            <string>\(logsDir)/swarms-daemon-error.log</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(home)</string>
                <key>PATH</key>
                <string>\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
                <key>PYTHONUNBUFFERED</key>
                <string>1</string>
                <key>SWARMS_TELEMETRY_ENABLED</key>
                <string>false</string>
                <key>LITELLM_LOG</key>
                <string>ERROR</string>
                <key>WORKSPACE_DIR</key>
                <string>\(wsDir)</string>
            </dict>
        </dict>
        </plist>
        """
        do {
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static func ensureDaemonRunning(workspacePath: String) async -> (online: Bool, health: SwarmsDaemonHealth?, message: String) {
        if let health = await checkHealth(), health.isHealthy {
            if health.bridgeVersion == expectedBridgeVersion {
                return (true, health, "Swarms v\(health.swarmsVersion) aktif (127.0.0.1:8765)")
            }
            // Upgrade running stale daemon automatically so new resilience fixes take effect immediately.
            let upgraded = await restartDaemon(workspacePath: workspacePath)
            if upgraded.online {
                return upgraded
            }
            return (true, health, "Swarms v\(health.swarmsVersion) aktif (yenileme bekleniyor)")
        }

        let plistURL = launchAgentPlistURL()
        _ = installLaunchAgentPlistIfPossible(workspacePath: workspacePath)

        if FileManager.default.fileExists(atPath: plistURL.path) {
            let uid = getuid()
            _ = await runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
            _ = await runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(launchAgentLabel)"])

            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let health = await checkHealth(), health.isHealthy {
                    return (true, health, "Swarms v\(health.swarmsVersion) LaunchAgent başlatıldı ✓")
                }
            }
        }

        // Direct background fallback if LaunchAgent bootstrap cannot run (e.g. non-GUI session)
        if launchDetachedDaemonFallback(workspacePath: workspacePath) {
            for _ in 0..<14 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let health = await checkHealth(), health.isHealthy {
                    return (true, health, "Swarms v\(health.swarmsVersion) doğrudan başlatıldı ✓")
                }
            }
        }

        return (false, nil, "Swarms daemon yanıt vermedi (~/Library/Logs/ClawOffice/swarms-daemon-error.log kontrol edin).")
    }

    private static func launchDetachedDaemonFallback(workspacePath: String) -> Bool {
        guard let paths = resolveRuntimePaths(workspacePath: workspacePath) else { return false }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: paths.pythonBin)
        p.arguments = [paths.bridgeScript, "--host", "127.0.0.1", "--port", "8765"]
        p.currentDirectoryURL = URL(fileURLWithPath: paths.runtimeDir)
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAWOFFICE_") { env.removeValue(forKey: k) }
        env["PATH"] = PowerShellTools.extendedEnvPath()
        let safeWs = paths.runtimeDir.contains(".app/Contents/Resources")
            ? "\(home)/.openclaw/swarms-runtime/workspace"
            : URL(fileURLWithPath: paths.runtimeDir).appendingPathComponent("workspace").path
        try? fm.createDirectory(atPath: safeWs, withIntermediateDirectories: true)
        env["WORKSPACE_DIR"] = safeWs
        env["SWARMS_TELEMETRY_ENABLED"] = "false"
        env["LITELLM_LOG"] = "ERROR"
        env["PYTHONUNBUFFERED"] = "1"
        env["HOME"] = home
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? p.run()) != nil
    }

    static func restartDaemon(workspacePath: String) async -> (online: Bool, health: SwarmsDaemonHealth?, message: String) {
        _ = installLaunchAgentPlistIfPossible(workspacePath: workspacePath)
        let plistURL = launchAgentPlistURL()
        let uid = getuid()
        _ = await runLaunchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        _ = await runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(launchAgentLabel)"])

        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let health = await checkHealth(), health.isHealthy {
                return (true, health, "Swarms v\(health.swarmsVersion) yeniden başlatıldı ✓")
            }
        }
        return (false, nil, "Swarms yeniden başlatılamadı.")
    }

    private static func runLaunchctl(_ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus)
                } catch {
                    cont.resume(returning: -1)
                }
            }
        }
    }
}
