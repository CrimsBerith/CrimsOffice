import Foundation

struct ModelRouteKey: Hashable, Sendable {
    let providerId: UUID
    let modelId: String
}

struct ModelRuntimeMetrics: Sendable {
    var inFlightCount: Int = 0
    var cooldownUntil: Date? = nil
    var consecutiveErrors: Int = 0
    var rateLimitCount: Int = 0
    var successCount: Int = 0
    var ewmaLatencyMs: Double = 0
    var lastUsedAt: Date? = nil

    func isInCooldown(now: Date = Date()) -> Bool {
        guard let until = cooldownUntil else { return false }
        return now < until
    }
}

enum RoleSpecialty: String, Sendable {
    case architectureLead
    case coding
    case securityAuditQA
    case researchDocs
    case uiuxDesign
    case devOpsDebug
    case general

    static func classify(name: String, title: String, prompt: String, hint: String = "") -> RoleSpecialty {
        let corpus = "\(name) \(title) \(prompt) \(hint)".lowercased()
        if corpus.contains("tasar") || corpus.contains("ui/ux") || corpus.contains("ui ") || corpus.contains(" ux") || corpus.contains("hig") || corpus.contains("görsel") || corpus.contains("design") {
            return .uiuxDesign
        }
        if corpus.contains("denet") || corpus.contains("güvenlik") || corpus.contains("security") || corpus.contains("audit") || corpus.contains("qa") || corpus.contains("kalite") || corpus.contains("test") {
            return .securityAuditQA
        }
        if corpus.contains("devops") || corpus.contains("ci/cd") || corpus.contains("deploy") || corpus.contains("hata ayık") || corpus.contains("debug") || corpus.contains("performans") || corpus.contains("build") {
            return .devOpsDebug
        }
        if corpus.contains("araştır") || corpus.contains("research") || corpus.contains("bilgi graf") || corpus.contains("graphify") || corpus.contains("doküman") || corpus.contains("analist") || corpus.contains("scout") {
            return .researchDocs
        }
        if corpus.contains("mimar") || corpus.contains("architect") || corpus.contains("lider") || corpus.contains("direktör") || corpus.contains("lead") || corpus.contains("stratej") {
            return .architectureLead
        }
        if corpus.contains("kod") || corpus.contains("swift") || corpus.contains("macos") || corpus.contains("ios") || corpus.contains("geliştir") || corpus.contains("yazılım") || corpus.contains("developer") || corpus.contains("engineer") || corpus.contains("full-stack") {
            return .coding
        }
        return .general
    }

    /// Ordered preference patterns from strongest fit to solid backup across all providers.
    var preferredModelPatterns: [String] {
        switch self {
        case .architectureLead:
            return [
                "gemini-4-hydrogen-xhigh",
                "google/gemini-4-hydrogen",
                "glm-5.3",
                "claude-opus-4-6-thinking",
                "gemini-4-hydrogen-high",
                "nvidia/nemotron-3-ultra-550b-a55b:free",
                "deepseek-v4.1-flash",
                "anthropic/claude-opus",
                "llama-3.3-70b-versatile",
                "qwen3.8-flash-next"
            ]
        case .coding:
            return [
                "deepseek-v4.1-flash",
                "claude-sonnet-4-6",
                "gemini-4-hydrogen-high",
                "qwen/qwen-2.5-coder-32b-instruct:free",
                "qwen3.8-flash-next",
                "glm-5.3",
                "anthropic/claude-sonnet",
                "kilo-auto/free",
                "qwen2.5-coder:14b",
                "qwen2.5-coder:7b"
            ]
        case .securityAuditQA:
            return [
                "glm-5.3",
                "claude-sonnet-4-6",
                "gemini-4-hydrogen-high",
                "nvidia/nemotron-3-ultra-550b-a55b:free",
                "deepseek/deepseek-r1:free",
                "qwen3.8-flash-next",
                "deepseek-v4.1-flash",
                "llama-3.3-70b-versatile",
                "openrouter/free"
            ]
        case .researchDocs:
            return [
                "qwen3.8-flash-next",
                "gemini-3.8-flash-high",
                "inclusionai/ling-3.2-flash:free",
                "baidu/ernie-5.5-flash-preview:free",
                "google/gemini-4-neon",
                "nvidia/nemotron-3.5-lightning:free",
                "llama-3.3-70b-versatile",
                "glm-5.3",
                "deepseek-v4.1-flash"
            ]
        case .uiuxDesign:
            return [
                "gemma-4-31b",
                "google/gemma-4-31b-it:free",
                "glm-5.3",
                "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
                "gemini-4-hydrogen-medium",
                "qwen3-vl-30b",
                "google/gemma-4-26b-a4b-it:free",
                "nvidia/nemotron-3.5-super-vl:free",
                "qwen3.8-flash-next"
            ]
        case .devOpsDebug:
            return [
                "qwen3.8-flash-next",
                "google/gemma-4-26b-a4b-it:free",
                "gemini-4-hydrogen-medium",
                "llama-3.3-70b-versatile",
                "deepseek-v4.1-flash",
                "glm-5.3",
                "kilo-auto/free",
                "qwen2.5-coder:7b"
            ]
        case .general:
            return [
                "glm-5.3",
                "qwen3.8-flash-next",
                "gemini-4-hydrogen-high",
                "deepseek-v4.1-flash",
                "gemma-4-31b",
                "llama-3.3-70b-versatile",
                "kilo-auto/free",
                "openrouter/free"
            ]
        }
    }

    var recommendedTemplateKeyword: String {
        switch self {
        case .architectureLead: return "glm"
        case .coding: return "deepseek"
        case .securityAuditQA: return "glm"
        case .researchDocs: return "qwen"
        case .uiuxDesign: return "gemma"
        case .devOpsDebug: return "qwen"
        case .general: return "glm"
        }
    }
}

struct ModelSelectionDecision: Sendable {
    let provider: APIProviderConfig
    let modelId: String
    let fallbackModelIds: [String]
    let reason: String
    let specialty: RoleSpecialty
}

/// Role-optimal, load-aware, and availability-aware model router for agent hiring & template resolution.
enum ModelRouter: Sendable {
    private static let nonChatMarkers = [
        "ocr", "embedding", "reranker", "asr", "guard", "voxcpm", "clef", "laya",
        "lyria", "whisper", "tts", "dall-e", "imagen", "moderation", "audio-preview"
    ]

    static func isChatCapableModel(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        guard !lower.isEmpty else { return false }
        return !nonChatMarkers.contains { lower.contains($0) }
    }

    static func inferTemplateKeyword(name: String, title: String, prompt: String) -> String {
        RoleSpecialty.classify(name: name, title: title, prompt: prompt).recommendedTemplateKeyword
    }

    static func selectModelForHire(
        name: String,
        title: String,
        systemPrompt: String,
        requestedModel: String,
        providers: [APIProviderConfig],
        existingAgents: [OfficeAgent],
        providerStatuses: [UUID: ProviderHealthStatus],
        providerCooldowns: [UUID: Date],
        modelMetrics: [ModelRouteKey: ModelRuntimeMetrics],
        now: Date = Date()
    ) -> ModelSelectionDecision {
        let specialty = RoleSpecialty.classify(name: name, title: title, prompt: systemPrompt, hint: requestedModel)
        let trimmedRequest = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerReq = trimmedRequest.lowercased()
        let autoTokens: Set<String> = ["", "auto", "best", "recommended", "otomatik", "smart"]
        let isAutoRequest = autoTokens.contains(lowerReq)

        let enabledConfigured = providers.filter { $0.isEnabled && $0.isConfigured }
        let onlineConfigured = enabledConfigured.filter { p in
            providerStatuses[p.id]?.isOnline != false
        }
        let usableProviders = !onlineConfigured.isEmpty
            ? onlineConfigured
            : (!enabledConfigured.isEmpty ? enabledConfigured : providers.filter { $0.isConfigured })
        let fallbackBaseProviders = usableProviders.isEmpty ? providers : usableProviders

        // Build candidate list across usable providers
        var pool: [(provider: APIProviderConfig, model: String)] = []
        for p in fallbackBaseProviders {
            let candidates = p.uniqueModels.filter { isChatCapableModel($0) }
            let list = candidates.isEmpty ? [p.defaultModel].filter { !$0.isEmpty } : candidates
            for m in list {
                pool.append((p, m))
            }
        }
        if pool.isEmpty, let firstP = providers.first {
            let m = firstP.defaultModel.isEmpty ? "deepseek-v4.1-flash" : firstP.defaultModel
            pool.append((firstP, m))
        }

        // Map existing team load / saturation per model & provider
        var agentsPerModel: [String: Int] = [:]
        var busyAgentsPerModel: [String: Int] = [:]
        var agentsPerProvider: [UUID: Int] = [:]
        for a in existingAgents {
            let mk = a.modelId.lowercased()
            agentsPerModel[mk, default: 0] += 1
            if a.status.isBusy {
                busyAgentsPerModel[mk, default: 0] += 1
            }
            agentsPerProvider[a.providerId, default: 0] += 1
        }

        func isProviderCooled(_ id: UUID) -> Bool {
            guard let until = providerCooldowns[id] else { return false }
            return now < until
        }

        func scoreCandidate(provider p: APIProviderConfig, model m: String) -> (score: Double, note: String) {
            let lowerM = m.lowercased()
            let key = ModelRouteKey(providerId: p.id, modelId: m)
            let metrics = modelMetrics[key]
            var score = 0.0
            var reasons: [String] = []

            // 1. Role capability preference match (exact tier or strong substring match)
            let patterns = specialty.preferredModelPatterns
            if let exactIdx = patterns.firstIndex(where: { lowerM == $0.lowercased() }) {
                score += Double(110 - exactIdx * 9)
                reasons.append("rol uyumu #\(exactIdx + 1)")
            } else if let partialIdx = patterns.firstIndex(where: { lowerM.contains($0.lowercased()) || $0.lowercased().contains(lowerM) }) {
                score += Double(90 - partialIdx * 8)
                reasons.append("rol ailesi")
            } else {
                // Family heuristics for dynamically fetched models (e.g. OpenRouter/Kilo catalogs)
                switch specialty {
                case .coding:
                    if lowerM.contains("coder") || lowerM.contains("deepseek") || lowerM.contains("sonnet") || lowerM.contains("codestral") { score += 55 }
                case .securityAuditQA, .architectureLead:
                    if lowerM.contains("opus") || lowerM.contains("glm") || lowerM.contains("ultra") || lowerM.contains("hydrogen") || lowerM.contains("-r1") || lowerM.contains("reasoning") { score += 55 }
                case .researchDocs:
                    if lowerM.contains("flash") || lowerM.contains("ling") || lowerM.contains("ernie") || lowerM.contains("lightning") || lowerM.contains("neon") { score += 52 }
                case .uiuxDesign:
                    if lowerM.contains("gemma") || lowerM.contains("-vl") || lowerM.contains("omni") || lowerM.contains("vision") { score += 52 }
                case .devOpsDebug:
                    if lowerM.contains("flash") || lowerM.contains("gemma-4-26b") || lowerM.contains("coder") || lowerM.contains("70b") { score += 50 }
                case .general:
                    if lowerM.contains("glm") || lowerM.contains("hydrogen") || lowerM.contains("qwen") { score += 45 }
                }
            }

            // Slight preference for reliable fast/free-tier or explicitly configured primary providers over generic routers
            if p.kind == .evren || p.kind == .antigravityCLI {
                score += 12
            } else if p.kind == .groq {
                score += 8
            } else if lowerM.contains(":free") || lowerM.contains("/free") {
                score += 6
            }
            if lowerM == "auto" || lowerM.hasSuffix("/auto") || lowerM == "openrouter/free" || lowerM == "kilo-auto/free" {
                score -= 12 // Prefer deterministic named specialists when available
            }

            // 2. Explicit non-auto hint boost
            if !isAutoRequest {
                if lowerM == lowerReq {
                    score += 85
                    reasons.append("istenen model")
                } else if lowerM.contains(lowerReq) {
                    score += 55
                    reasons.append("istenen anahtar")
                }
            }

            // 3. Health & Cooldown penalties
            let onlineStatus = providerStatuses[p.id]
            if onlineStatus?.isOnline == false {
                score -= 500
                reasons.append("çevrimdışı")
            }
            if isProviderCooled(p.id) {
                score -= 320
                reasons.append("sağlayıcı beklemede")
            }
            if metrics?.isInCooldown(now: now) == true {
                score -= 280
                reasons.append("model beklemede")
            }

            // 4. Live In-Flight Load & Team Congestion penalties
            let inFlight = metrics?.inFlightCount ?? 0
            if inFlight > 0 {
                score -= Double(inFlight) * 145.0
                reasons.append("aktif yoğunluk(\(inFlight))")
            }
            let provInFlight = modelMetrics
                .filter { $0.key.providerId == p.id }
                .reduce(0) { $0 + $1.value.inFlightCount }
            if provInFlight > 0 {
                score -= Double(provInFlight) * 30.0
            }
            if p.kind == .evren && provInFlight >= 3 {
                score -= 220.0
                reasons.append("EVREN eşzamanlı sınır(\(provInFlight)/4)")
            }

            // Penalize piling all agents onto the exact same model when healthy alternatives exist
            let assignedCount = agentsPerModel[lowerM, default: 0]
            let busyCount = busyAgentsPerModel[lowerM, default: 0]
            if assignedCount > 0 {
                score -= Double(assignedCount) * 38.0
                reasons.append("ekip dağılımı(\(assignedCount))")
            }
            if busyCount > 0 {
                score -= Double(busyCount) * 65.0
            }
            let provAgents = agentsPerProvider[p.id, default: 0]
            if provAgents >= 3 {
                score -= Double(provAgents - 2) * 14.0
            }

            // 5. Latency & reliability adjustments
            if let mStat = metrics {
                if mStat.consecutiveErrors > 0 {
                    score -= Double(mStat.consecutiveErrors) * 60.0
                }
                if mStat.rateLimitCount > 0 {
                    score -= Double(min(4, mStat.rateLimitCount)) * 25.0
                }
                if mStat.ewmaLatencyMs > 0 {
                    if mStat.ewmaLatencyMs < 2500 {
                        score += 12
                    } else if mStat.ewmaLatencyMs > 15_000 {
                        score -= 24
                    }
                }
            }
            if let lat = onlineStatus?.latencyMs, onlineStatus?.isOnline == true, lat > 0 {
                if lat < 400 { score += 6 }
                else if lat > 2500 { score -= 12 }
            }

            return (score, reasons.joined(separator: ", "))
        }

        // Filter out cooled candidates whenever any non-cooled healthy option exists in pool.
        let uncooledPool = pool.filter { item in
            let key = ModelRouteKey(providerId: item.provider.id, modelId: item.model)
            return !isProviderCooled(item.provider.id) && (modelMetrics[key]?.isInCooldown(now: now) != true)
        }
        let scoringPool = uncooledPool.isEmpty ? pool : uncooledPool

        // Check if caller requested a specific exact model that is healthy, idle, and not oversaturated
        if !isAutoRequest,
           let exactMatch = scoringPool.first(where: { $0.model.lowercased() == lowerReq }) {
            let key = ModelRouteKey(providerId: exactMatch.provider.id, modelId: exactMatch.model)
            let metrics = modelMetrics[key]
            let isHealthy = exactMatch.provider.isEnabled
                && exactMatch.provider.isConfigured
                && !isProviderCooled(exactMatch.provider.id)
                && providerStatuses[exactMatch.provider.id]?.isOnline != false
                && (metrics?.isInCooldown(now: now) != true)
                && (metrics?.consecutiveErrors ?? 0) == 0
            let inFlight = metrics?.inFlightCount ?? 0
            let provInFlight = modelMetrics
                .filter { $0.key.providerId == exactMatch.provider.id }
                .reduce(0) { $0 + $1.value.inFlightCount }
            let evrenSaturated = exactMatch.provider.kind == .evren && provInFlight >= 3
            let assigned = agentsPerModel[exactMatch.model.lowercased(), default: 0]
            let hasIdleHealthyAlternative = scoringPool.contains { alt in
                alt.model.lowercased() != exactMatch.model.lowercased()
                && (!evrenSaturated || alt.provider.id != exactMatch.provider.id)
                && !isProviderCooled(alt.provider.id)
                && providerStatuses[alt.provider.id]?.isOnline != false
                && (modelMetrics[ModelRouteKey(providerId: alt.provider.id, modelId: alt.model)]?.isInCooldown(now: now) != true)
                && (modelMetrics[ModelRouteKey(providerId: alt.provider.id, modelId: alt.model)]?.inFlightCount ?? 0) == 0
            }

            // If a non-coding specialist was given a generic deepseek request while a stronger idle specialist exists,
            // let the full role+load scorer choose instead of blindly locking onto deepseek.
            let isGenericDeepseekForSpecialist = lowerReq.contains("deepseek")
                && specialty != .coding
                && specialty != .general
                && hasIdleHealthyAlternative

            if isHealthy && inFlight == 0 && !(evrenSaturated && hasIdleHealthyAlternative) && (assigned == 0 || !hasIdleHealthyAlternative) && !isGenericDeepseekForSpecialist {
                let fallbacks = buildDiverseFallbacks(
                    selected: exactMatch,
                    pool: pool,
                    scoreCandidate: scoreCandidate
                )
                return ModelSelectionDecision(
                    provider: exactMatch.provider,
                    modelId: exactMatch.model,
                    fallbackModelIds: fallbacks,
                    reason: "İstenen model hazır ve boşta",
                    specialty: specialty
                )
            }
        }

        // Score uncooled pool (or full pool if every candidate is cooled) and pick optimal role+load-balanced model
        let scored = scoringPool.map { item -> (provider: APIProviderConfig, model: String, score: Double, note: String) in
            let s = scoreCandidate(provider: item.provider, model: item.model)
            return (item.provider, item.model, s.score, s.note)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.model < rhs.model
        }

        let chosen = scored.first ?? (
            provider: providers.first ?? APIProviderConfig.defaultProviders()[0],
            model: trimmedRequest.isEmpty ? "deepseek-v4.1-flash" : trimmedRequest,
            score: 0,
            note: "varsayılan"
        )

        let fallbacks = buildDiverseFallbacks(
            selected: (chosen.provider, chosen.model),
            pool: pool,
            scoreCandidate: scoreCandidate
        )

        let reasonPrefix: String
        if !isAutoRequest && chosen.model.lowercased() != lowerReq {
            reasonPrefix = "'\(trimmedRequest)' yoğun/beklemede veya role göre daha uygun aday seçildi"
        } else {
            reasonPrefix = "Rol (\(specialty.rawValue)) + yük dengesi seçimi"
        }
        let reasonText = chosen.note.isEmpty ? reasonPrefix : "\(reasonPrefix) [\(chosen.note)]"

        return ModelSelectionDecision(
            provider: chosen.provider,
            modelId: chosen.model,
            fallbackModelIds: fallbacks,
            reason: reasonText,
            specialty: specialty
        )
    }

    private static func buildDiverseFallbacks(
        selected: (provider: APIProviderConfig, model: String),
        pool: [(provider: APIProviderConfig, model: String)],
        scoreCandidate: (APIProviderConfig, String) -> (score: Double, note: String)
    ) -> [String] {
        let ranked = pool
            .filter { !($0.provider.id == selected.provider.id && $0.model == selected.model) }
            .map { item -> (provider: APIProviderConfig, model: String, score: Double) in
                (item.provider, item.model, scoreCandidate(item.provider, item.model).score)
            }
            .sorted { $0.score > $1.score }

        var out: [String] = []
        // First pick up to 3 top candidates from DIFFERENT providers for resilient cross-provider failover
        var seenProviders: Set<UUID> = [selected.provider.id]
        for item in ranked where !seenProviders.contains(item.provider.id) {
            if !out.contains(item.model) {
                out.append(item.model)
                seenProviders.insert(item.provider.id)
            }
            if out.count >= 3 { break }
        }
        // Then add top same-provider or remaining models up to 6 total fallbacks
        for item in ranked {
            if !out.contains(item.model) {
                out.append(item.model)
            }
            if out.count >= 6 { break }
        }
        return out
    }
}
