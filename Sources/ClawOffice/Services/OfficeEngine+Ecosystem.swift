import Foundation
import SwiftUI

extension OfficeEngine {
    nonisolated static let ecosystemAndBrowserToolNames: Set<String> = [
        "browser_open", "browser_navigate", "browser_goto",
        "browser_snapshot",
        "browser_click",
        "browser_type",
        "browser_select",
        "browser_scroll",
        "browser_wait",
        "browser_eval",
        "browser_screenshot",
        "browser_handoff",
        "list_connectors",
        "use_connector",
        "create_connector",
        "search_github",
        "inspect_github_repo",
        "install_github_skill",
        "create_skill",
        "run_swarm",
        "swarm_status"
    ]

    nonisolated static func isEcosystemOrBrowserTool(_ name: String) -> Bool {
        ecosystemAndBrowserToolNames.contains(name.lowercased())
    }

    // MARK: - Connector & GitHub Hub UI Actions

    func saveConnectorSecret(id: UUID, apiKey: String) {
        guard let idx = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[idx].apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        connectors[idx].lastStatusMessage = connectors[idx].apiKey.isEmpty ? "Token temizlendi" : "Keychain için güncellendi"
        saveConfig()
    }

    func toggleConnector(id: UUID) {
        guard let idx = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[idx].isEnabled.toggle()
        saveConfig()
    }

    func addOrUpdateConnector(_ connector: ServiceConnector) {
        if let idx = connectors.firstIndex(where: { $0.id == connector.id || $0.slug.lowercased() == connector.slug.lowercased() }) {
            var merged = connector
            merged.id = connectors[idx].id
            if merged.apiKey.isEmpty { merged.apiKey = connectors[idx].apiKey }
            connectors[idx] = merged
        } else {
            connectors.insert(connector, at: 0)
        }
        saveConfig()
    }

    func removeConnector(id: UUID) {
        connectors.removeAll { $0.id == id }
        saveConfig()
    }

    func probeConnector(id: UUID) async -> (ready: Bool, message: String) {
        guard let conn = connectors.first(where: { $0.id == id }) else {
            return (false, "Connector bulunamadı.")
        }
        let res = await ConnectorAndGitHubService.probeConnector(conn, workspacePath: workspacePath)
        if let idx = connectors.firstIndex(where: { $0.id == id }) {
            connectors[idx].isVerifiedReady = res.ready
            connectors[idx].discoveredTools = res.tools
            connectors[idx].lastStatusMessage = String(res.message.prefix(160))
            connectors[idx].lastCheckedAt = Date()
            saveConfig()
        }
        log(res.ready ? .info : .warning, source: conn.name, res.message)
        return (res.ready, res.message)
    }

    func searchGitHubInHub(query: String, kind: String = "all") async -> String {
        let res = await ConnectorAndGitHubService.searchGitHubRepos(query: query, kind: kind, limit: 10)
        lastGitHubCandidates = res.candidates
        if let sid = selectedAgentId ?? agents.first?.id {
            var set = searchedTopicsByAgent[sid] ?? []
            for tok in ConnectorAndGitHubService.extractSearchTokens(from: query) {
                set.insert(tok)
            }
            searchedTopicsByAgent[sid] = set
        }
        return res.formatted
    }

    func installSkillFromGitHubUI(source: String, slugOverride: String? = nil) async -> (Bool, String) {
        let res = await ConnectorAndGitHubService.installSkillFromGitHub(
            source: source,
            slugOverride: slugOverride,
            openClawHome: openClawHomePath
        )
        if res.succeeded {
            let installedSlug: String = {
                if let path = res.installedPath, !path.isEmpty {
                    return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                }
                return deriveSkillSlug(from: source, override: slugOverride)
            }()
            let keepEnabled = Set(skills.filter { $0.isEnabled }.map { $0.id } + [installedSlug])
            refreshWorkspaceAndSkills(enabledIds: keepEnabled)
            saveConfig()
            log(.info, source: "GitHub Skill", res.message)
        } else {
            log(.warning, source: "GitHub Skill", res.message)
        }
        return (res.succeeded, res.message)
    }

    func resumeAgentAfterBrowserHandoff() {
        let targetId = browser.pendingHandoffAgentId ?? selectedAgentId ?? agents.first?.id
        browser.clearPendingHandoff()
        guard let targetId else { return }
        let msg = "Canlı Browser üzerinde kullanıcı girişi/onayı tamamlandı (`\(browser.currentURLString)`). `browser_snapshot` alıp kaldığın görevden devam et."
        sendMessage(to: targetId, text: msg)
    }

    private func deriveSkillSlug(from source: String, override: String?) -> String {
        if let o = override?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            return sanitizeSlug(o)
        }
        if let parsed = ConnectorAndGitHubService.parseOwnerRepo(from: source) {
            return sanitizeSlug(parsed.repo)
        }
        return "github-skill"
    }

    private func sanitizeSlug(_ raw: String) -> String {
        let ascii = raw
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ascii.isEmpty ? "custom-tool" : ascii
    }

    // MARK: - Unified Agent Tool Execution (Browser + Connectors/MCP + GitHub/Skills)

    func executeEcosystemOrBrowserTool(
        name: String,
        argument: String,
        agentId: UUID,
        agentName: String,
        performRemoteReuseCheck: Bool = true
    ) async -> (output: String, succeeded: Bool, requestedHandoff: Bool) {
        let lowerName = name.lowercased()

        switch lowerName {
        // MARK: Browser Tools
        case "browser_open", "browser_navigate", "browser_goto":
            let res = await browser.agentNavigate(to: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_snapshot":
            let res = await browser.agentSnapshot(filter: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_click":
            let res = await browser.agentClick(target: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_type":
            let res = await browser.agentType(argument: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_select":
            let res = await browser.agentSelect(argument: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_scroll":
            let res = await browser.agentScroll(argument: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_wait":
            let res = await browser.agentWait(argument: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_eval":
            guard allowFileWrites else {
                return ("Güvenlik ayarı: Sayfa içi JavaScript çalıştırma salt-okunur modda kapalı.", false, false)
            }
            let res = await browser.agentEvalJS(script: argument, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_screenshot":
            let res = await browser.agentScreenshot(label: argument, workspacePath: workspacePath, agentName: agentName)
            return (res.output, res.succeeded, false)

        case "browser_handoff":
            let res = browser.agentRequestHumanHandoff(reason: argument, agentId: agentId, agentName: agentName)
            return (res.output, res.succeeded, true)

        // MARK: Connector & MCP Tools
        case "list_connectors":
            let filter = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matching = connectors.filter { c in
                filter.isEmpty || filter == "." || "\(c.slug) \(c.name) \(c.category) \(c.description)".lowercased().contains(filter)
            }
            if matching.isEmpty {
                return ("Eşleşen connector bulunamadı ('\(argument)'). `search_github` ile hazır MCP/API ara.", true, false)
            }
            var lines = ["🔌 Kayıtlı Connectorlar (\(matching.count)):"]
            for c in matching {
                let authState = c.hasCredentialOrNoAuth ? "✅ Hazır" : "🔐 Token Eksik (\(c.secretEnvName))"
                lines.append("- **\(c.name)** (`slug=\(c.slug)`) · \(c.transport.rawValue) · \(authState) · Endpoint: \(c.endpointOrCommand)")
                if !c.discoveredTools.isEmpty {
                    let preview = c.discoveredTools.prefix(4).map { $0.name }.joined(separator: ", ")
                    lines.append("  Araçlar/Endpointler: \(preview)")
                }
            }
            return (lines.joined(separator: "\n"), true, false)

        case "use_connector":
            let parts = argument.components(separatedBy: "|||")
            guard parts.count >= 2 else {
                return ("Format hatası. Beklenen: slug|||TOOL_VEYA_METHOD_PATH[|||json_arg]", false, false)
            }
            let slug = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let action = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonArg = parts.count >= 3 ? parts.dropFirst(2).joined(separator: "|||") : ""

            guard let conn = connectors.first(where: { $0.slug.lowercased() == slug || $0.name.lowercased() == slug }) else {
                let available = connectors.map { $0.slug }.joined(separator: ", ")
                return ("'\(slug)' adlı connector bulunamadı. Mevcutlar: \(available). Önce `list_connectors` veya `search_github` ile ara.", false, false)
            }
            let isReadOnlyConnectorAction = action.lowercased() == "tools/list" || action.lowercased() == "list" || action.uppercased().hasPrefix("GET ")
            if !allowFileWrites && !isReadOnlyConnectorAction && conn.transport == .mcpStdio {
                return ("Güvenlik ayarı: Yerel süreç çalıştıran MCP stdio eylemi salt-okunur modda kapalı.", false, false)
            }
            let res = await ConnectorAndGitHubService.executeConnectorAction(
                connector: conn,
                action: action,
                argumentsJSON: jsonArg,
                workspacePath: workspacePath
            )
            if res.succeeded {
                if let idx = connectors.firstIndex(where: { $0.id == conn.id }) {
                    connectors[idx].isVerifiedReady = true
                    connectors[idx].lastCheckedAt = Date()
                    if action.lowercased() == "tools/list" {
                        let parsedTools = ConnectorAndGitHubService.parseMCPToolsList(from: res.output)
                        if !parsedTools.isEmpty {
                            connectors[idx].discoveredTools = parsedTools
                        }
                    }
                    saveConfig()
                }
            }
            return (res.output, res.succeeded, false)

        case "create_connector":
            guard allowFileWrites else {
                return ("Güvenlik ayarı: Yeni connector tanımlama salt-okunur modda kapalı.", false, false)
            }
            let rawParts = argument.components(separatedBy: "|||")
            let hasForce = rawParts.last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "force"
            let parts = hasForce ? Array(rawParts.dropLast()) : rawParts
            guard parts.count >= 4 else {
                return ("Format hatası. Beklenen: slug|||Ad|||rest|mcp_http|mcp_stdio|||endpoint_veya_komut|||açıklama[|||authHeaderOrEnv][|||force]", false, false)
            }
            let slug = sanitizeSlug(parts[0])
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let transportRaw = parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let endpoint = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let desc = parts.count >= 5 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : "Özel API/MCP Connector"
            let envOrHeader = parts.count >= 6 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : ""

            let topicTokens = ConnectorAndGitHubService.extractSearchTokens(from: "\(slug) \(title) \(desc)")
            let agentTopics = searchedTopicsByAgent[agentId] ?? []
            let alreadySearched = !topicTokens.isEmpty && topicTokens.allSatisfy { agentTopics.contains($0) }

            // Reuse-First Guardrail: search existing catalog & GitHub before creating from scratch.
            if !hasForce && !alreadySearched {
                let check = await ConnectorAndGitHubService.checkExistingSolutionsBeforeCreating(
                    topic: "\(slug) \(title)",
                    openClawHome: openClawHomePath,
                    workspacePath: workspacePath,
                    connectors: connectors,
                    performRemoteSearch: performRemoteReuseCheck
                )
                var updatedTopics = searchedTopicsByAgent[agentId] ?? []
                for tok in topicTokens { updatedTopics.insert(tok) }
                searchedTopicsByAgent[agentId] = updatedTopics
                if !check.githubMatches.isEmpty {
                    lastGitHubCandidates = check.githubMatches
                }
                if check.hasStrongMatch {
                    return (
                        """
                        ⏸️ **Önce Hazırını Kontrol Et (0'dan Connector Üretimi Duraklatıldı):**
                        \(check.summaryMarkdown)

                        Önce mevcut/GitHub adayını `inspect_github_repo` veya `use_connector` ile doğrula. Hiçbiri ihtiyacını karşılamıyorsa aynı çağrının sonuna `|||force` ekleyerek yeniden çağır.
                        """,
                        false,
                        false
                    )
                }
            }

            let transport: ConnectorTransport
            switch transportRaw {
            case "mcp_http", "streamable_http", "http_mcp": transport = .mcpHTTP
            case "mcp_stdio", "stdio", "mcp": transport = .mcpStdio
            case "cli", "cli_bridge": transport = .cliBridge
            case "browser", "web": transport = .browserFlow
            default: transport = .restAPI
            }

            if transport == .restAPI || transport == .mcpHTTP {
                guard let url = URL(string: endpoint),
                      BrowserAutomationService.validateBrowserURL(url, allowLocalNetwork: true).allowed else {
                    return ("Güvenlik/Format hatası: Geçerli bir http/https endpoint URL'si girin (\(endpoint)).", false, false)
                }
            }

            let newConn = ServiceConnector(
                slug: slug,
                name: title.isEmpty ? slug : title,
                category: "Özel & Keşfedilen",
                description: desc,
                transport: transport,
                endpointOrCommand: endpoint,
                arguments: [],
                authType: envOrHeader.isEmpty ? .none : (transport == .mcpStdio ? .envVar : .bearerToken),
                authHeaderName: "Authorization",
                secretEnvName: envOrHeader.isEmpty ? "\(slug.uppercased().replacingOccurrences(of: "-", with: "_"))_API_TOKEN" : envOrHeader,
                lastStatusMessage: envOrHeader.isEmpty ? "Hazır (Kimliksiz)" : "Keychain token girilebilir"
            )
            addOrUpdateConnector(newConn)
            log(.info, source: agentName, "🔌 Yeni connector kaydedildi: \(newConn.name) (\(newConn.slug))")
            return ("✅ Connector kaydedildi: **\(newConn.name)** (`slug=\(newConn.slug)`, \(newConn.transport.rawValue)). Kullanıcı Connectorlar sekmesinden Keychain anahtarı girebilir veya `<tool name=\"use_connector\">\(newConn.slug)|||...</tool>` ile çağırabilirsin.", true, false)

        // MARK: GitHub Discovery & Skill Factory
        case "search_github":
            let parts = argument.components(separatedBy: "|||")
            let q = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "all"
            let res = await ConnectorAndGitHubService.searchGitHubRepos(query: q, kind: kind, limit: 8)
            if !res.candidates.isEmpty {
                lastGitHubCandidates = res.candidates
            }
            var qTopics = searchedTopicsByAgent[agentId] ?? []
            for tok in ConnectorAndGitHubService.extractSearchTokens(from: q) {
                qTopics.insert(tok)
            }
            searchedTopicsByAgent[agentId] = qTopics
            return (res.formatted, res.error == nil, false)

        case "inspect_github_repo":
            let res = await ConnectorAndGitHubService.inspectGitHubRepo(target: argument)
            var iTopics = searchedTopicsByAgent[agentId] ?? []
            for tok in ConnectorAndGitHubService.extractSearchTokens(from: argument) {
                iTopics.insert(tok)
            }
            searchedTopicsByAgent[agentId] = iTopics
            return (res.summary, res.succeeded, false)

        case "install_github_skill":
            guard allowFileWrites else {
                return ("Güvenlik ayarı: GitHub'dan skill kurulumu salt-okunur modda kapalı.", false, false)
            }
            let parts = argument.components(separatedBy: "|||")
            let src = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let slugOverride = parts.count >= 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let res = await ConnectorAndGitHubService.installSkillFromGitHub(
                source: src,
                slugOverride: slugOverride,
                openClawHome: openClawHomePath
            )
            if res.succeeded {
                refreshWorkspaceAndSkills()
                let installedSlug = res.installedPath.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
                } ?? deriveSkillSlug(from: src, override: slugOverride)
                if let idx = skills.firstIndex(where: { $0.id.lowercased() == installedSlug.lowercased() }) {
                    skills[idx].isEnabled = true
                    saveConfig()
                }
            }
            return (res.message, res.succeeded, false)

        case "create_skill":
            guard allowFileWrites else {
                return ("Güvenlik ayarı: Skill oluşturma salt-okunur modda kapalı.", false, false)
            }
            let rawParts = argument.components(separatedBy: "|||")
            let hasForce = rawParts.last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "force"
            let parts = hasForce ? Array(rawParts.dropLast()) : rawParts
            guard parts.count >= 4 else {
                return ("Format hatası. Beklenen: slug|||Ad|||Açıklama|||SKILL_govdesi[|||force]", false, false)
            }
            let slug = sanitizeSlug(parts[0])
            let skName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let skDesc = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let skBody = parts.dropFirst(3).joined(separator: "|||").trimmingCharacters(in: .whitespacesAndNewlines)

            let topicTokens = ConnectorAndGitHubService.extractSearchTokens(from: "\(slug) \(skName) \(skDesc)")
            let agentTopics = searchedTopicsByAgent[agentId] ?? []
            let alreadySearched = !topicTokens.isEmpty && topicTokens.allSatisfy { agentTopics.contains($0) }

            if !hasForce && !alreadySearched {
                let check = await ConnectorAndGitHubService.checkExistingSolutionsBeforeCreating(
                    topic: "\(slug) \(skName)",
                    openClawHome: openClawHomePath,
                    workspacePath: workspacePath,
                    connectors: connectors,
                    performRemoteSearch: performRemoteReuseCheck
                )
                var updatedTopics = searchedTopicsByAgent[agentId] ?? []
                for tok in topicTokens { updatedTopics.insert(tok) }
                searchedTopicsByAgent[agentId] = updatedTopics
                if !check.githubMatches.isEmpty {
                    lastGitHubCandidates = check.githubMatches
                }
                if check.hasStrongMatch {
                    return (
                        """
                        ⏸️ **Önce Hazırını Kontrol Et (0'dan Skill Oluşturma Duraklatıldı):**
                        \(check.summaryMarkdown)

                        Önce mevcut/GitHub çözümünü `inspect_github_repo` veya `install_github_skill` ile inceleyip kur. Mevcutlar yetersizse aynı çağrının sonuna `|||force` ekleyerek sıfırdan oluştur.
                        """,
                        false,
                        false
                    )
                }
            }

            do {
                let savedPath = try OpenClawWorkspaceService.saveEvolvedSkill(
                    slug: slug,
                    name: skName,
                    description: skDesc,
                    body: skBody,
                    openClawHome: openClawHomePath
                )
                refreshWorkspaceAndSkills()
                if let idx = skills.firstIndex(where: { $0.id.lowercased() == slug.lowercased() }) {
                    skills[idx].isEnabled = true
                    saveConfig()
                }
                log(.info, source: agentName, "✨ Yeni SKILL.md oluşturuldu: \(skName) → \(savedPath)")
                return ("✅ Yeni skill oluşturuldu ve etkinleştirildi: `\(skName)` (`/\(slug)`) → \(savedPath)", true, false)
            } catch {
                return ("Skill oluşturulamadı: \(error.localizedDescription)", false, false)
            }

        // MARK: Swarms Multi-Agent Runtime Tools
        case "swarm_status":
            let boot = await SwarmsRuntimeService.ensureDaemonRunning(workspacePath: workspacePath)
            swarmsHealth = boot.health
            let runsResp = await SwarmsRuntimeService.fetchRecentRuns()
            if let runsResp { swarmsRecentRuns = runsResp.recent }
            syncSwarmsConnectorState(online: boot.online, health: boot.health, message: boot.message)
            guard let h = boot.health, boot.online else {
                return ("Swarms daemon çevrimdışı: \(boot.message)", false, false)
            }
            var lines = [
                "🐝 **Swarms Runtime Daemon** (`127.0.0.1:8765`)",
                "• Durum: `\(h.status)` · Sürüm: `\(h.swarmsVersion)` · Uptime: `\(Int(h.uptimeSeconds))s`",
                "• Aktif Çalışma: `\(h.activeRuns)` · Toplam Çalışma: `\(h.totalRuns)`",
                "• Topolojiler: \(h.supportedSwarmTypes.joined(separator: ", "))"
            ]
            if let recent = runsResp?.recent.prefix(5), !recent.isEmpty {
                lines.append("• Son Çalışmalar:")
                for r in recent {
                    lines.append("  - [\(r.status)] \(r.swarmType) (\(r.durationMs) ms, \(r.stepCount) adım): \(r.taskPreview)")
                }
            }
            return (lines.joined(separator: "\n"), true, false)

        case "run_swarm":
            let parts = argument.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let knownTypes = Set(SwarmsTopology.allCases.map { $0.rawValue.lowercased() })
            let swarmType: String
            let taskText: String
            let agentFilterRaw: String

            if parts.count >= 2 && knownTypes.contains(parts[0].lowercased()) {
                swarmType = SwarmsTopology.allCases.first(where: { $0.rawValue.lowercased() == parts[0].lowercased() })?.rawValue ?? "Auto"
                taskText = parts[1]
                agentFilterRaw = parts.count >= 3 ? parts[2] : ""
            } else {
                swarmType = "Auto"
                taskText = parts.first ?? argument.trimmingCharacters(in: .whitespacesAndNewlines)
                agentFilterRaw = parts.count >= 2 ? parts[1] : ""
            }

            guard !taskText.isEmpty else {
                return ("Format hatası. Beklenen: [SwarmTipi|||]görev[|||Ajan1,Ajan2]", false, false)
            }

            let boot = await SwarmsRuntimeService.ensureDaemonRunning(workspacePath: workspacePath)
            swarmsHealth = boot.health
            guard boot.online else {
                return ("Swarms daemon başlatılamadı: \(boot.message)", false, false)
            }

            let requestedNames = agentFilterRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            var participants = requestedNames.isEmpty
                ? agents
                : agents.filter { requestedNames.contains($0.name.lowercased()) }
            if participants.isEmpty { participants = agents }

            if participants.count >= 2 {
                for i in 0..<(participants.count - 1) {
                    showBeam(from: participants[i].id, to: participants[i + 1].id, label: "🐝 \(swarmType)", accentHex: participants[i].accentHex, duration: 5.5)
                }
            }

            let agentPayloads = SwarmsRuntimeService.buildAgentPayloads(
                agents: participants,
                providers: providers,
                providerStatuses: providerStatuses,
                providerCooldowns: providerCooldowns,
                modelMetrics: modelMetrics
            )
            let req = SwarmsRunRequestPayload(
                task: taskText,
                swarmType: swarmType,
                maxLoops: 1,
                rearrangeFlow: nil,
                workspacePath: workspacePath,
                allowLocalEdits: allowFileWrites,
                agents: agentPayloads,
                director: agentPayloads.first,
                retryPolicy: SwarmsRetryPolicy(maxRetries: 3, initialDelay: 1.0, multiplier: 2.0)
            )
            do {
                let res = try await SwarmsRuntimeService.runSwarm(req)
                lastSwarmsTelemetry = res.telemetry
                recordSwarmsTelemetry(res.telemetry)
                await refreshSwarmsStatus()
                for step in res.steps {
                    if let matched = participants.first(where: { $0.name.lowercased() == step.agentName.lowercased() }) {
                        incrementCompletedTasks(for: matched.id)
                        recordDialogue(from: matched, toName: "Swarms (\(res.swarmType))", content: String(step.output.prefix(240)), kind: .debate)
                    }
                }
                var outLines = [
                    "🐝 **Swarms Çalışması Tamamlandı** (`\(res.swarmType)` · \(res.durationMs) ms · \(res.steps.count) adım)"
                ]
                for (i, s) in res.steps.enumerated() {
                    outLines.append("\n### \(i + 1). \(s.agentName) (\(s.role))\n\(s.output)")
                }
                if res.steps.isEmpty && !res.finalOutput.isEmpty {
                    outLines.append("\n\(res.finalOutput)")
                }
                return (outLines.joined(separator: "\n"), true, false)
            } catch {
                return ("Swarms çalıştırma hatası: \(error.localizedDescription)", false, false)
            }

        default:
            return ("Bilinmeyen ekosistem/browser aracı: \(name)", false, false)
        }
    }
}
