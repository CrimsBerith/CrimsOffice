import Foundation
import SwiftUI

/// Decodes an array without failing the entire container if a single legacy or malformed element fails.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct FailableElement: Decodable {
        let value: Element?
        init(from decoder: Decoder) {
            self.value = try? Element(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(FailableElement.self), let v = item.value {
                decoded.append(v)
            } else {
                // Skip invalid token by consuming AnyDecodable placeholder if possible
                _ = try? container.decode(SkipCodableValue.self)
            }
        }
        self.elements = decoded
    }
}

private struct SkipCodableValue: Decodable {}

// MARK: - API Providers (Kilo, EVREN, OpenRouter, Groq, NVIDIA NIM, Custom)

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case antigravityCLI, kilo, evren, openRouter, groq, nvidia, custom
    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "custom"
        self = ProviderKind(rawValue: raw) ?? .custom
    }

    var displayName: String {
        switch self {
        case .antigravityCLI: return "Antigravity CLI (Gemini 4 Hydrogen)"
        case .kilo: return "Kilo Gateway"
        case .evren: return "EVREN (SAYZEK)"
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        case .nvidia: return "NVIDIA NIM"
        case .custom: return "Özel API (OpenAI Uyumlu)"
        }
    }

    var symbolName: String {
        switch self {
        case .antigravityCLI: return "sparkles.rectangle.stack.fill"
        case .kilo: return "bolt.horizontal.circle.fill"
        case .evren: return "square.stack.3d.up.fill"
        case .openRouter: return "point.3.connected.trianglepath.dotted"
        case .groq: return "hare.fill"
        case .nvidia: return "cpu.fill"
        case .custom: return "server.rack"
        }
    }

    var accentHex: String {
        switch self {
        case .antigravityCLI: return "#4F46E5"
        case .kilo: return "#F59E0B"
        case .evren: return "#0EA5E9"
        case .openRouter: return "#8B5CF6"
        case .groq: return "#F97316"
        case .nvidia: return "#76B900"
        case .custom: return "#EC4899"
        }
    }
}

enum AuthHeaderStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bearer, xApiKey, bearerAndXApiKey, none
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bearer: return "Authorization: Bearer"
        case .xApiKey: return "X-API-Key"
        case .bearerAndXApiKey: return "Bearer + X-API-Key (EVREN)"
        case .none: return "Anahtarsız (Yerel)"
        }
    }
}

struct ProviderHealthStatus: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { providerId }
    var providerId: UUID
    var isOnline: Bool = true
    var latencyMs: Int = 0
    var lastChecked: Date = Date()
    var statusMessage: String = "Bağlantı kontrol edilmedi"
}

struct APIProviderConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var apiKey: String = ""
    var authStyle: AuthHeaderStyle = .bearer
    var models: [String] = []
    var defaultModel: String = ""
    var isEnabled: Bool = true
    var evrenTermsAcceptedVersion: String? = nil
    var lastQuotaSummary: String? = nil
    var fallbackProviderId: UUID? = nil

    var normalizedBaseURL: String {
        var t = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t == "/" ? "" : t
    }

    static func resolveAntigravityCLIPath(hint: String = "") -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let rawTrimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedHint: String? = {
            guard !rawTrimmed.isEmpty else { return nil }
            if rawTrimmed == "~" { return home }
            if rawTrimmed.hasPrefix("~/") {
                return home + String(rawTrimmed.dropFirst())
            }
            return rawTrimmed
        }()
        let candidates = [
            expandedHint,
            home + "/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/usr/bin/agy"
        ].compactMap { $0 }
        return candidates.first { path in
            var isDir: ObjCBool = false
            return path.hasPrefix("/")
                && fm.fileExists(atPath: path, isDirectory: &isDir)
                && !isDir.boolValue
                && fm.isExecutableFile(atPath: path)
        }
    }

    var isConfigured: Bool {
        if kind == .antigravityCLI {
            // Antigravity CLI backend is disabled by workspace policy in LLMClient
            return false
        }
        let cleaned = normalizedBaseURL
        guard !cleaned.isEmpty,
              let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        if authStyle == .none {
            return true
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, apiKey, authStyle, models, defaultModel, isEnabled, evrenTermsAcceptedVersion, lastQuotaSummary, fallbackProviderId
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String,
        apiKey: String = "",
        authStyle: AuthHeaderStyle = .bearer,
        models: [String] = [],
        defaultModel: String = "",
        isEnabled: Bool = true,
        evrenTermsAcceptedVersion: String? = nil,
        lastQuotaSummary: String? = nil,
        fallbackProviderId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.authStyle = authStyle
        self.models = models
        self.defaultModel = defaultModel
        self.isEnabled = isEnabled
        self.evrenTermsAcceptedVersion = evrenTermsAcceptedVersion
        self.lastQuotaSummary = lastQuotaSummary
        self.fallbackProviderId = fallbackProviderId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "API Sağlayıcısı"
        self.kind = (try? c.decodeIfPresent(ProviderKind.self, forKey: .kind)) ?? .custom
        self.baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        self.apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        self.authStyle = (try? c.decodeIfPresent(AuthHeaderStyle.self, forKey: .authStyle)) ?? .bearer
        self.models = (try? c.decodeIfPresent([String].self, forKey: .models)) ?? []
        self.defaultModel = (try? c.decodeIfPresent(String.self, forKey: .defaultModel)) ?? ""
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        self.evrenTermsAcceptedVersion = try? c.decodeIfPresent(String.self, forKey: .evrenTermsAcceptedVersion)
        self.lastQuotaSummary = try? c.decodeIfPresent(String.self, forKey: .lastQuotaSummary)
        self.fallbackProviderId = try? c.decodeIfPresent(UUID.self, forKey: .fallbackProviderId)
    }

    /// Deduplicates `models` while preserving display order (prevents SwiftUI ForEach/Picker duplicate-ID warnings).
    var uniqueModels: [String] {
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    static func defaultProviders() -> [APIProviderConfig] {
        let antigravityId = UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID()
        let evrenId = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()
        let kiloId = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
        let openRouterId = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()
        let groqId = UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID()

        return [
            APIProviderConfig(
                id: antigravityId,
                name: "Antigravity CLI (Gemini 4 Hydrogen)",
                kind: .antigravityCLI,
                baseURL: resolveAntigravityCLIPath() ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/agy"),
                authStyle: .none,
                models: [
                    "gemini-4-hydrogen-xhigh",
                    "gemini-4-hydrogen-high",
                    "gemini-4-hydrogen-medium",
                    "gemini-4-hydrogen-low",
                    "gemini-3.8-flash-high",
                    "claude-sonnet-4-6",
                    "claude-opus-4-6-thinking",
                    "gpt-oss-120b-medium"
                ],
                defaultModel: "gemini-4-hydrogen-xhigh",
                isEnabled: false,
                fallbackProviderId: openRouterId
            ),
            APIProviderConfig(
                id: evrenId,
                name: "EVREN (SAYZEK)",
                kind: .evren,
                baseURL: "https://evren-llmapi.ssyz.org.tr/v1",
                apiKey: ProcessInfo.processInfo.environment["CLAWOFFICE_EVREN_API_KEY"] ?? "",
                authStyle: .bearerAndXApiKey,
                models: [
                    "deepseek-v4.1-flash",
                    "qwen3.8-flash-next",
                    "gemma-4-31b",
                    "glm-5.3",
                    "qwen3-vl-30b"
                ],
                defaultModel: "deepseek-v4.1-flash",
                fallbackProviderId: kiloId
            ),
            APIProviderConfig(
                id: kiloId,
                name: "Kilo Gateway",
                kind: .kilo,
                baseURL: "https://api.kilo.ai/api/gateway",
                authStyle: .bearer,
                models: [
                    "kilo-auto/free",
                    "google/gemma-4-31b-it:free",
                    "google/gemma-4-26b-a4b-it:free",
                    "inclusionai/ling-3.2-flash:free",
                    "baidu/ernie-5.5-flash-preview:free",
                    "nvidia/nemotron-3.5-super-vl:free",
                    "nvidia/nemotron-3.5-lightning:free",
                    "nvidia/nemotron-3-ultra-550b-a55b:free",
                    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
                    "liquid/lfm-3-1.7b:free",
                    "particle-ai/particle-1:free",
                    "recursive/flint-v1.0:free",
                    "dots-studio/dots-3-note-preview:free",
                    "openrouter/free",
                    "reflection/beam-free",
                    "stealth/glyph-cluster",
                    "kilo/auto",
                    "anthropic/claude-opus-5.5",
                    "anthropic/claude-sonnet-5.5",
                    "openai/gpt-6.2-sol"
                ],
                defaultModel: "kilo-auto/free",
                fallbackProviderId: evrenId
            ),
            APIProviderConfig(
                id: openRouterId,
                name: "OpenRouter",
                kind: .openRouter,
                baseURL: "https://openrouter.ai/api/v1",
                authStyle: .bearer,
                models: [
                    "openrouter/free",
                    "google/gemini-4-hydrogen",
                    "google/gemini-4-neon",
                    "google/gemini-4-carbon",
                    "google/gemma-4-31b-it:free",
                    "google/gemma-4-26b-a4b-it:free",
                    "nvidia/nemotron-3-ultra-550b-a55b:free",
                    "nvidia/nemotron-3.5-lightning:free",
                    "nvidia/nemotron-3.5-super-vl:free",
                    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
                    "inclusionai/ling-3.2-flash:free",
                    "baidu/ernie-5.5-flash-preview:free",
                    "liquid/lfm-3-1.7b:free",
                    "particle-ai/particle-1:free",
                    "recursive/flint-v1.0:free",
                    "dots-studio/dots-3-note-preview:free",
                    "meta-llama/llama-3.3-70b-instruct:free",
                    "deepseek/deepseek-r1:free",
                    "qwen/qwen-2.5-coder-32b-instruct:free",
                    "openrouter/auto"
                ],
                defaultModel: "openrouter/free",
                fallbackProviderId: evrenId
            ),
            APIProviderConfig(
                id: groqId,
                name: "Groq",
                kind: .groq,
                baseURL: "https://api.groq.com/openai/v1",
                authStyle: .bearer,
                models: [
                    "llama-3.3-70b-versatile",
                    "llama-3.1-8b-instant",
                    "mixtral-8x7b-32768",
                    "gemma2-9b-it",
                    "deepseek-r1-distill-llama-70b"
                ],
                defaultModel: "llama-3.3-70b-versatile",
                fallbackProviderId: evrenId
            )
        ]
    }
}

// MARK: - Caveman Compression Mode (v3.1 ASD-STE100)

enum CavemanMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "Kapalı"
    case lite = "Lite (-35%)"
    case full = "Full (-65%)"
    case ultra = "Ultra (-80%)"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        if let exact = CavemanMode(rawValue: raw) {
            self = exact
            return
        }
        switch raw.lowercased() {
        case "off": self = .off
        case "lite": self = .lite
        case "full": self = .full
        case "ultra": self = .ultra
        default: self = .off
        }
    }

    var systemDirective: String {
        switch self {
        case .off:
            return ""
        case .lite:
            return """
            [CAVEMAN MODE: LITE]
            Respond with zero filler, greetings, hedging, or closers. Answer first, then brief reason, then next step.
            Keep code blocks, file paths, commands, tool tags, numbers, and negations (not/never/no/değil/asla) 100% verbatim.
            Keep the user's language (Turkish/English). Compress style only, never meaning.
            """
        case .full:
            return """
            [CAVEMAN MODE: FULL — ASD-STE100 + TERSE]
            Pattern: [thing] [action] [reason]. [next step].
            Rules:
            1. Zero ceremony: no greetings, no "Sure", no recap, no closers.
            2. One idea per sentence, max 20 words, active voice.
            3. Never drop negations (not/never/no/only/değil/yok/asla). Numbers exact.
            4. Payload verbatim: code blocks, tool tags, paths, commands, API names, errors untouched.
            5. Keep user's language; preserve Turkish grammar markers while removing politeness filler.
            6. Use full sentences ONLY for security warnings or irreversible destructive actions.
            """
        case .ultra:
            return """
            [CAVEMAN MODE: ULTRA]
            Maximum token compression. One line per fact. Strip filler completely.
            Keep code, commands, tool tags, paths, errors, numbers, and negations 100% verbatim.
            Preserve user's language. Full sentences ONLY for security/destructive warnings.
            """
        }
    }

    var savingsFactor: Double {
        switch self {
        case .off: return 0.0
        case .lite: return 0.35
        case .full: return 0.65
        case .ultra: return 0.80
        }
    }
}

// MARK: - OpenClaw Skills & Graphify

struct AgentSkill: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    var body: String
    var sourcePath: String
    var isEnabled: Bool
    var triggers: [String]
}

// MARK: - Service Connectors, MCP & GitHub Ecosystem

enum ConnectorTransport: String, Codable, CaseIterable, Sendable {
    case restAPI = "REST API"
    case mcpHTTP = "MCP (HTTP)"
    case mcpStdio = "MCP (stdio)"
    case cliBridge = "CLI Köprüsü"
    case browserFlow = "Browser Akışı"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        if let exact = ConnectorTransport(rawValue: raw) {
            self = exact
            return
        }
        switch raw.lowercased() {
        case "rest", "rest_api", "http": self = .restAPI
        case "mcp_http", "streamable_http", "sse": self = .mcpHTTP
        case "mcp_stdio", "stdio", "mcp": self = .mcpStdio
        case "cli", "cli_bridge": self = .cliBridge
        case "browser", "web": self = .browserFlow
        default: self = .restAPI
        }
    }
}

enum ConnectorAuthType: String, Codable, CaseIterable, Sendable {
    case none = "Kimliksiz"
    case bearerToken = "Bearer Token"
    case apiKeyHeader = "Özel API Başlığı"
    case basicAuth = "Basic Auth"
    case oauthBrowser = "Browser OAuth"
    case envVar = "Ortam Değişkeni"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        if let exact = ConnectorAuthType(rawValue: raw) {
            self = exact
            return
        }
        switch raw.lowercased() {
        case "bearer", "bearer_token", "token": self = .bearerToken
        case "apikey", "api_key", "header": self = .apiKeyHeader
        case "basic": self = .basicAuth
        case "oauth", "browser": self = .oauthBrowser
        case "env": self = .envVar
        default: self = .none
        }
    }
}

struct ConnectorToolSpec: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var inputHint: String

    init(name: String, description: String, inputHint: String = "") {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

struct ServiceConnector: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var slug: String
    var name: String
    var category: String
    var description: String
    var transport: ConnectorTransport
    var endpointOrCommand: String
    var arguments: [String]
    var authType: ConnectorAuthType
    var authHeaderName: String
    var secretEnvName: String
    var apiKey: String
    var sourceRepoURL: String
    var docsURL: String
    var isEnabled: Bool
    var isVerifiedReady: Bool
    var discoveredTools: [ConnectorToolSpec]
    var lastStatusMessage: String
    var lastCheckedAt: Date?

    var keychainAccountKey: String {
        "connector:\(id.uuidString)"
    }

    var requiresSecret: Bool {
        authType == .bearerToken || authType == .apiKeyHeader || authType == .basicAuth || authType == .envVar
    }

    var hasCredentialOrNoAuth: Bool {
        !requiresSecret || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        id: UUID = UUID(),
        slug: String,
        name: String,
        category: String = "Bulut & Web",
        description: String,
        transport: ConnectorTransport,
        endpointOrCommand: String,
        arguments: [String] = [],
        authType: ConnectorAuthType = .bearerToken,
        authHeaderName: String = "Authorization",
        secretEnvName: String = "API_TOKEN",
        apiKey: String = "",
        sourceRepoURL: String = "",
        docsURL: String = "",
        isEnabled: Bool = true,
        isVerifiedReady: Bool = false,
        discoveredTools: [ConnectorToolSpec] = [],
        lastStatusMessage: String = "Hazır (Yapılandırılabilir)",
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.category = category
        self.description = description
        self.transport = transport
        self.endpointOrCommand = endpointOrCommand
        self.arguments = arguments
        self.authType = authType
        self.authHeaderName = authHeaderName
        self.secretEnvName = secretEnvName
        self.apiKey = apiKey
        self.sourceRepoURL = sourceRepoURL
        self.docsURL = docsURL
        self.isEnabled = isEnabled
        self.isVerifiedReady = isVerifiedReady
        self.discoveredTools = discoveredTools
        self.lastStatusMessage = lastStatusMessage
        self.lastCheckedAt = lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.slug = (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? "custom"
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Özel Connector"
        self.category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? "Genel"
        self.description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        self.transport = (try? c.decodeIfPresent(ConnectorTransport.self, forKey: .transport)) ?? .restAPI
        self.endpointOrCommand = (try? c.decodeIfPresent(String.self, forKey: .endpointOrCommand)) ?? ""
        self.arguments = (try? c.decodeIfPresent([String].self, forKey: .arguments)) ?? []
        self.authType = (try? c.decodeIfPresent(ConnectorAuthType.self, forKey: .authType)) ?? .bearerToken
        self.authHeaderName = (try? c.decodeIfPresent(String.self, forKey: .authHeaderName)) ?? "Authorization"
        self.secretEnvName = (try? c.decodeIfPresent(String.self, forKey: .secretEnvName)) ?? "API_TOKEN"
        self.apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        self.sourceRepoURL = (try? c.decodeIfPresent(String.self, forKey: .sourceRepoURL)) ?? ""
        self.docsURL = (try? c.decodeIfPresent(String.self, forKey: .docsURL)) ?? ""
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        self.isVerifiedReady = (try? c.decodeIfPresent(Bool.self, forKey: .isVerifiedReady)) ?? false
        self.discoveredTools = (try? c.decodeIfPresent(LossyDecodableArray<ConnectorToolSpec>.self, forKey: .discoveredTools))?.elements ?? []
        self.lastStatusMessage = (try? c.decodeIfPresent(String.self, forKey: .lastStatusMessage)) ?? "Hazır"
        self.lastCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    static func builtInCatalog() -> [ServiceConnector] {
        [
            ServiceConnector(
                id: UUID(uuidString: "71111111-1111-1111-1111-111111111111") ?? UUID(),
                slug: "hostinger",
                name: "Hostinger API Connector",
                category: "Hosting & VPS",
                description: "Hostinger hPanel API: VPS, alan adları, DNS kayıtları, WordPress/hosting siteleri ve faturalandırma yönetimi (API Token ile).",
                transport: .restAPI,
                endpointOrCommand: "https://developers.hostinger.com",
                arguments: [],
                authType: .bearerToken,
                authHeaderName: "Authorization",
                secretEnvName: "HOSTINGER_API_TOKEN",
                sourceRepoURL: "https://github.com/hostinger/api-mcp-server",
                docsURL: "https://developers.hostinger.com",
                isEnabled: true,
                discoveredTools: [
                    ConnectorToolSpec(name: "GET /api/vps/v1/virtual-machines", description: "VPS sunucularını listeler"),
                    ConnectorToolSpec(name: "GET /api/domains/v1/portfolio", description: "Kayıtlı alan adlarını listeler"),
                    ConnectorToolSpec(name: "GET /api/hosting/v1/websites", description: "Hosting web sitelerini listeler"),
                    ConnectorToolSpec(name: "GET /api/dns/v1/zones/{domain}", description: "Alan adı DNS kayıtlarını getirir"),
                    ConnectorToolSpec(name: "GET /api/billing/v1/subscriptions", description: "Aktif abonelik ve hizmetleri listeler")
                ],
                lastStatusMessage: "API Token bekleniyor (hPanel → API) veya Browser OAuth"
            ),
            ServiceConnector(
                id: UUID(uuidString: "72222222-2222-2222-2222-222222222222") ?? UUID(),
                slug: "hostinger-mcp",
                name: "Hostinger Official MCP (HTTP)",
                category: "Hosting & VPS",
                description: "Hostinger resmi uzak MCP sunucusu (Streamable HTTP / Bearer veya @hostinger/mcp). hPanel VPS/DNS/WordPress araçlarını sunar.",
                transport: .mcpHTTP,
                endpointOrCommand: "https://mcp.hostinger.com",
                arguments: [],
                authType: .bearerToken,
                authHeaderName: "Authorization",
                secretEnvName: "HOSTINGER_API_TOKEN",
                sourceRepoURL: "https://github.com/hostinger/api-mcp-server",
                docsURL: "https://github.com/hostinger/api-mcp-server",
                isEnabled: true,
                discoveredTools: [
                    ConnectorToolSpec(name: "tools/list", description: "Uzak Hostinger MCP araç kataloğunu çeker")
                ],
                lastStatusMessage: "Resmi MCP şablonu hazır (API Token ile)"
            ),
            ServiceConnector(
                id: UUID(uuidString: "73333333-3333-3333-3333-333333333333") ?? UUID(),
                slug: "github",
                name: "GitHub Ekosistem & Repo Connector",
                category: "Kod & Kaynak",
                description: "GitHub repoları, SKILL.md, MCP sunucuları, README/dosya inceleme, issue & PR otomasyonu (gh CLI + REST API).",
                transport: .restAPI,
                endpointOrCommand: "https://api.github.com",
                arguments: [],
                authType: .none,
                authHeaderName: "Authorization",
                secretEnvName: "GITHUB_TOKEN",
                sourceRepoURL: "https://github.com/github/github-mcp-server",
                docsURL: "https://docs.github.com/en/rest",
                isEnabled: true,
                isVerifiedReady: true,
                discoveredTools: [
                    ConnectorToolSpec(name: "GET /search/repositories?q={query}", description: "GitHub üzerinde repo/skill/MCP arar"),
                    ConnectorToolSpec(name: "GET /repos/{owner}/{repo}", description: "Repo metadata, yıldız ve lisans bilgisini getirir"),
                    ConnectorToolSpec(name: "GET /user/repos", description: "Kimlik doğrulamalı kullanıcı repolarını listeler")
                ],
                lastStatusMessage: "GitHub REST + yerel gh CLI ile kullanıma hazır"
            ),
            ServiceConnector(
                id: UUID(uuidString: "74444444-4444-4444-4444-444444444444") ?? UUID(),
                slug: "cloudflare",
                name: "Cloudflare API Connector",
                category: "Hosting & DNS",
                description: "Cloudflare Zone, DNS, Workers, Pages ve R2 yönetimi.",
                transport: .restAPI,
                endpointOrCommand: "https://api.cloudflare.com/client/v4",
                arguments: [],
                authType: .bearerToken,
                authHeaderName: "Authorization",
                secretEnvName: "CLOUDFLARE_API_TOKEN",
                sourceRepoURL: "https://github.com/cloudflare/mcp-server-cloudflare",
                docsURL: "https://developers.cloudflare.com/api/",
                isEnabled: true,
                discoveredTools: [
                    ConnectorToolSpec(name: "GET /zones", description: "Cloudflare DNS zone listesini getirir"),
                    ConnectorToolSpec(name: "GET /user/tokens/verify", description: "API token geçerliliğini doğrular")
                ],
                lastStatusMessage: "API Token bekleniyor"
            ),
            ServiceConnector(
                id: UUID(uuidString: "75555555-5555-5555-5555-555555555555") ?? UUID(),
                slug: "swarms-mcp",
                name: "Swarms Runtime Daemon (MCP + HTTP)",
                category: "Orkestrasyon & Swarm",
                description: "Kalıcı yerel kyegomez/swarms servisi (127.0.0.1:8765): HierarchicalSwarm, MixtureOfAgents, DebateWithJudge, Sequential/Concurrent akışları.",
                transport: .mcpHTTP,
                endpointOrCommand: "http://127.0.0.1:8765/mcp",
                arguments: [],
                authType: .none,
                authHeaderName: "Authorization",
                secretEnvName: "SWARMS_AUTH_TOKEN",
                sourceRepoURL: "https://github.com/kyegomez/swarms",
                docsURL: "https://docs.swarms.world",
                isEnabled: true,
                discoveredTools: [
                    ConnectorToolSpec(name: "swarm_status", description: "Swarms daemon çalışma durumu ve sürümünü döndürür"),
                    ConnectorToolSpec(name: "swarm_list_types", description: "Desteklenen 12 Swarms topolojisini listeler"),
                    ConnectorToolSpec(name: "swarm_recent_runs", description: "Aktif ve son Swarms çalıştırmalarını getirir"),
                    ConnectorToolSpec(name: "swarm_run", description: "Çoklu ajan Swarms iş akışı çalıştırır")
                ],
                lastStatusMessage: "Yerel Swarms daemon (127.0.0.1:8765)"
            )
        ]
    }
}

struct GitHubRepoCandidate: Identifiable, Codable, Hashable, Sendable {
    var id: String { fullName }
    var fullName: String
    var description: String
    var htmlURL: String
    var stars: Int
    var updatedAt: String
    var license: String
    var defaultBranch: String
    var hasSkillMD: Bool = false
    var hasMCPHint: Bool = false
    var topics: [String] = []
}

struct GraphNode: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var community: Int
    var degree: Int
    var filePath: String
}

struct GraphEdge: Identifiable, Hashable, Sendable {
    var id: String { "\(source)->\(target):\(relation)" }
    var source: String
    var target: String
    var relation: String
}

struct GraphifySnapshot: Sendable {
    var reportMarkdown: String
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var godNodes: [GraphNode]
    var lastUpdated: Date?
}

// MARK: - Live Inter-Agent Communication & Office Beams

enum DialogueKind: String, Codable, Sendable {
    case social = "Sohbet"
    case debate = "Toplantı"
    case handoff = "Devir"
    case review = "Kod İncelemesi"
    case buildFix = "Otomatik Onarım"
    case retrospective = "Öz-Gelişim"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = DialogueKind(rawValue: raw) ?? .social
    }
}

struct OfficeDialogueMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var fromAgentId: UUID?
    var fromName: String
    var fromEmoji: String
    var toName: String
    var content: String
    var kind: DialogueKind
    var isZeroToken: Bool = false
}

struct ActiveBeamLink: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var fromAgentId: UUID
    var toAgentId: UUID
    var label: String
    var accentHex: String
    var createdAt: Date = Date()
}

struct AgentSpeechBubble: Identifiable, Hashable, Sendable {
    let id: UUID = UUID()
    let agentId: UUID
    let toName: String
    let text: String
    let kind: DialogueKind
    let accentHex: String
    let createdAt: Date = Date()
    let expiresAt: Date
}

enum OfficeTaskStatus: String, Codable, CaseIterable, Sendable {
    case pending = "Bekliyor"
    case inProgress = "Sürüyor"
    case done = "Tamamlandı"
    case blocked = "Engelli"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        if let exact = OfficeTaskStatus(rawValue: raw) {
            self = exact
            return
        }
        switch raw.lowercased() {
        case "inprogress", "in_progress": self = .inProgress
        case "done", "completed": self = .done
        case "blocked": self = .blocked
        default: self = .pending
        }
    }
}

struct OfficePlanTask: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var assigneeName: String = "Atlas"
    var status: OfficeTaskStatus = .pending
    var note: String = ""
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, title, assigneeName, status, note, updatedAt
    }

    init(id: UUID = UUID(), title: String, assigneeName: String = "Atlas", status: OfficeTaskStatus = .pending, note: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.assigneeName = assigneeName
        self.status = status
        self.note = note
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Görev"
        self.assigneeName = (try? c.decodeIfPresent(String.self, forKey: .assigneeName)) ?? "Atlas"
        self.status = (try? c.decodeIfPresent(OfficeTaskStatus.self, forKey: .status)) ?? .pending
        self.note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        self.updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

// MARK: - Safe Autonomous Project File Edit & Rollback Record

struct FileEditRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var agentName: String
    var relativePath: String
    var backupPath: String
    var wasNewFile: Bool
    var summary: String
    var rolledBack: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, timestamp, agentName, relativePath, backupPath, wasNewFile, summary, rolledBack
    }

    init(id: UUID = UUID(), timestamp: Date = Date(), agentName: String, relativePath: String, backupPath: String, wasNewFile: Bool, summary: String, rolledBack: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.agentName = agentName
        self.relativePath = relativePath
        self.backupPath = backupPath
        self.wasNewFile = wasNewFile
        self.summary = summary
        self.rolledBack = rolledBack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.timestamp = (try? c.decodeIfPresent(Date.self, forKey: .timestamp)) ?? Date()
        self.agentName = (try? c.decodeIfPresent(String.self, forKey: .agentName)) ?? "Ajan"
        self.relativePath = (try? c.decodeIfPresent(String.self, forKey: .relativePath)) ?? ""
        self.backupPath = (try? c.decodeIfPresent(String.self, forKey: .backupPath)) ?? ""
        self.wasNewFile = (try? c.decodeIfPresent(Bool.self, forKey: .wasNewFile)) ?? false
        self.summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        self.rolledBack = (try? c.decodeIfPresent(Bool.self, forKey: .rolledBack)) ?? false
    }
}

// MARK: - Agents & Office State

struct Point2D: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

/// 60 FPS yürüyüş kinematiği: kavisli doğal rota, hızlanma/yavaşlama adım şiddeti ve yön değiştirmede sıfır geriye kayma
struct AgentWalkMotion: Equatable, Sendable {
    let from: Point2D
    let to: Point2D
    let startedAt: Date
    let duration: TimeInterval
    let arcBend: Double

    func sample(at now: Date) -> (point: Point2D, progress: Double, strideIntensity: Double) {
        let safeDur = max(0.12, duration)
        let rawT = min(1.0, max(0.0, now.timeIntervalSince(startedAt) / safeDur))
        // Cubic ease-in-out: yumuşak kalkış ve zarif duruş
        let eased = rawT < 0.5
            ? 4.0 * rawT * rawT * rawT
            : 1.0 - pow(-2.0 * rawT + 2.0, 3.0) / 2.0

        let dx = to.x - from.x
        let dy = to.y - from.y
        let dist = max(0.0001, hypot(dx, dy))
        // Yürüyüş rotasına dik hafif organik kavis
        let nx = -dy / dist
        let ny = dx / dist
        let curve = sin(eased * .pi) * arcBend

        let x = min(0.90, max(0.08, from.x + dx * eased + nx * curve))
        let y = min(0.86, max(0.14, from.y + dy * eased + ny * curve))

        // Kalkış ve varışta adım genliğini yumuşakça artır/azalt
        let strideIntensity = rawT >= 1.0 ? 0.0 : min(1.0, max(0.18, sin(rawT * .pi) * 1.35))
        return (Point2D(x: x, y: y), rawT, strideIntensity)
    }
}

enum OfficeZone: String, Codable, Sendable {
    case desk = "Çalışma Masası"
    case meetingRoom = "Toplantı Odası"
    case coffeeLounge = "Kahve Köşesi"
    case serverRack = "Mac Studio Hub"
    case visitingPeer = "Arkadaşının Masası"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        if let exact = OfficeZone(rawValue: raw) {
            self = exact
            return
        }
        switch raw.lowercased() {
        case "meetingroom": self = .meetingRoom
        case "coffeelounge": self = .coffeeLounge
        case "serverrack": self = .serverRack
        case "visitingpeer": self = .visitingPeer
        default: self = .desk
        }
    }
}

enum AgentStatus: String, Codable, Sendable {
    case idle = "Hazır"
    case chatting = "Sohbette"
    case thinking = "Düşünüyor"
    case working = "Üretiyor"
    case runningTool = "Araç / Kod"
    case collaborating = "Toplantıda"
    case improving = "Öğreniyor"
    case error = "Hata"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = AgentStatus(rawValue: raw) ?? .idle
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .working, .runningTool, .collaborating, .improving: return true
        case .idle, .chatting, .error: return false
        }
    }
}

struct ToolCallRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var argument: String
    var output: String = ""
    var succeeded: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, argument, output, succeeded
    }

    init(id: UUID = UUID(), name: String, argument: String, output: String = "", succeeded: Bool = true) {
        self.id = id
        self.name = name
        self.argument = argument
        self.output = output
        self.succeeded = succeeded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "tool"
        self.argument = (try? c.decodeIfPresent(String.self, forKey: .argument)) ?? ""
        self.output = (try? c.decodeIfPresent(String.self, forKey: .output)) ?? ""
        self.succeeded = (try? c.decodeIfPresent(Bool.self, forKey: .succeeded)) ?? true
    }
}

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: String
    var content: String
    var reasoning: String? = nil
    var timestamp: Date = Date()
    var modelUsed: String? = nil
    var providerName: String? = nil
    var latencyMs: Int? = nil
    var toolCalls: [ToolCallRecord] = []
    var usedFallback: Bool = false

    init(id: UUID = UUID(), role: String, content: String, reasoning: String? = nil, timestamp: Date = Date(), modelUsed: String? = nil, providerName: String? = nil, latencyMs: Int? = nil, toolCalls: [ToolCallRecord] = [], usedFallback: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.timestamp = timestamp
        self.modelUsed = modelUsed
        self.providerName = providerName
        self.latencyMs = latencyMs
        self.toolCalls = toolCalls
        self.usedFallback = usedFallback
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoning, timestamp, modelUsed, providerName, latencyMs, toolCalls, usedFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.role = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        self.content = (try? container.decodeIfPresent(String.self, forKey: .content)) ?? ""
        self.reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        self.timestamp = (try? container.decodeIfPresent(Date.self, forKey: .timestamp)) ?? Date()
        self.modelUsed = try? container.decodeIfPresent(String.self, forKey: .modelUsed)
        self.providerName = try? container.decodeIfPresent(String.self, forKey: .providerName)
        self.latencyMs = try? container.decodeIfPresent(Int.self, forKey: .latencyMs)
        self.toolCalls = (try? container.decodeIfPresent(LossyDecodableArray<ToolCallRecord>.self, forKey: .toolCalls))?.elements ?? []
        self.usedFallback = (try? container.decodeIfPresent(Bool.self, forKey: .usedFallback)) ?? false
    }
}

// MARK: - Dynamic Agent Role Templates

struct AgentRoleTemplate: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var title: String
    var emoji: String
    var accentHex: String
    var prompt: String
    var defaultModelKeyword: String
    var isCustom: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, title, emoji, accentHex, prompt, defaultModelKeyword, isCustom
    }

    init(
        id: UUID = UUID(),
        name: String,
        title: String,
        emoji: String,
        accentHex: String,
        prompt: String,
        defaultModelKeyword: String,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.emoji = emoji
        self.accentHex = accentHex
        self.prompt = prompt
        self.defaultModelKeyword = defaultModelKeyword
        self.isCustom = isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Uzman"
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Yazılım Uzmanı"
        self.emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🤖"
        self.accentHex = (try? c.decodeIfPresent(String.self, forKey: .accentHex)) ?? "#38BDF8"
        self.prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        self.defaultModelKeyword = (try? c.decodeIfPresent(String.self, forKey: .defaultModelKeyword)) ?? "deepseek"
        self.isCustom = (try? c.decodeIfPresent(Bool.self, forKey: .isCustom)) ?? false
    }

    static func defaultTemplates() -> [AgentRoleTemplate] {
        [
            AgentRoleTemplate(
                name: "Kodcu",
                title: "Kıdemli Swift/macOS & Full-Stack Mühendisi",
                emoji: "⚡️",
                accentHex: "#A855F7",
                prompt: "Sen kıdemli bir macOS/iOS (Swift, SwiftUI, AppKit) ve Full-Stack yazılım mühendisisin. Temiz, güvenli, derlenebilir ve SOLID prensiplerine uygun kod üretirsin. Doğrudan dosyalara güvenli kod yazar ve yama uygularsın.",
                defaultModelKeyword: "deepseek"
            ),
            AgentRoleTemplate(
                name: "Mimar",
                title: "Yazılım Sistem Mimarı & Teknik Lider",
                emoji: "🧠",
                accentHex: "#38BDF8",
                prompt: "Sen kıdemli bir yazılım mimarısın. Projeleri modüler, sürdürülebilir ve performanslı tasarlar, kod tabanını analiz eder ve uygulanabilir kesin mühendislik planları çıkarırsın.",
                defaultModelKeyword: "glm"
            ),
            AgentRoleTemplate(
                name: "Denetçi",
                title: "Güvenlik, QA & Kod Denetçisi",
                emoji: "🛡️",
                accentHex: "#F59E0B",
                prompt: "Sen titiz bir QA ve güvenlik denetçisisin. Kodlardaki race condition, crash riski, bellek sızıntısı ve mimari açıkları yakalarsın. Kodların test ve derleme doğrulamasını sağlarsın.",
                defaultModelKeyword: "glm"
            ),
            AgentRoleTemplate(
                name: "Tasarımcı",
                title: "Apple HIG & macOS/iOS UI/UX Tasarımcısı",
                emoji: "🎨",
                accentHex: "#EC4899",
                prompt: "Sen Apple HIG (Human Interface Guidelines) standartlarında uzmanlaşmış kıdemli bir UI/UX tasarımcısısın. Akıcı, erişilebilir ve estetik SwiftUI bileşenleri tasarlarsın.",
                defaultModelKeyword: "gemma"
            ),
            AgentRoleTemplate(
                name: "DevOps",
                title: "DevOps, Build & CI/CD Uzmanı",
                emoji: "🚀",
                accentHex: "#10B981",
                prompt: "Sen derleme hatasızlığı, build scriptleri, paketleme, test otomasyonu ve sistem entegrasyonu konusunda uzman bir DevOps mühendisisin. Derleme sorunlarını kökünden çözersin.",
                defaultModelKeyword: "qwen"
            ),
            AgentRoleTemplate(
                name: "Hata Ayıklayıcı",
                title: "Hata Ayıklayıcı & Performans Analisti",
                emoji: "🔍",
                accentHex: "#6366F1",
                prompt: "Sen derinlemesine hata ayıklama (debugging), log analizi, stack trace çözümü ve performans optimizasyonu uzmanısın. Karmaşık bug'ları adım adım izler ve kök sebebi çözersin.",
                defaultModelKeyword: "qwen"
            )
        ]
    }
}

struct OfficeAgent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var title: String
    var emoji: String
    var avatarAsset: String
    var symbolName: String
    var accentHex: String
    var providerId: UUID
    var modelId: String
    var systemPrompt: String
    var temperature: Double = 0.5
    var deskPosition: Point2D
    var currentPosition: Point2D
    var currentZone: OfficeZone = .desk
    var status: AgentStatus = .idle
    var statusBubble: String = "Görev bekliyor..."
    var messages: [ChatMessage] = []
    var completedTasks: Int = 0
    var fallbackModelIds: [String] = []
    var agyConversationId: String? = nil

    // Backward-compatibility support for older configs
    var level: Int { 1 }

    enum CodingKeys: String, CodingKey {
        case id, name, title, emoji, avatarAsset, symbolName, accentHex, providerId, modelId, systemPrompt, temperature, deskPosition, currentPosition, currentZone, status, statusBubble, messages, completedTasks, fallbackModelIds, agyConversationId
        case xp, level, learnedNotes
    }

    init(id: UUID = UUID(), name: String, title: String, emoji: String, avatarAsset: String, symbolName: String, accentHex: String, providerId: UUID, modelId: String, systemPrompt: String, temperature: Double = 0.5, deskPosition: Point2D, currentPosition: Point2D, currentZone: OfficeZone = .desk, status: AgentStatus = .idle, statusBubble: String = "Görev bekliyor...", messages: [ChatMessage] = [], completedTasks: Int = 0, fallbackModelIds: [String] = [], agyConversationId: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.emoji = emoji
        self.avatarAsset = avatarAsset
        self.symbolName = symbolName
        self.accentHex = accentHex
        self.providerId = providerId
        self.modelId = modelId
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.deskPosition = deskPosition
        self.currentPosition = currentPosition
        self.currentZone = currentZone
        self.status = status
        self.statusBubble = statusBubble
        self.messages = messages
        self.completedTasks = completedTasks
        self.fallbackModelIds = fallbackModelIds
        self.agyConversationId = agyConversationId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Ajan"
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Uzman"
        self.emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🤖"
        self.avatarAsset = (try? c.decodeIfPresent(String.self, forKey: .avatarAsset)) ?? ""
        self.symbolName = (try? c.decodeIfPresent(String.self, forKey: .symbolName)) ?? "sparkles"
        self.accentHex = (try? c.decodeIfPresent(String.self, forKey: .accentHex)) ?? "#38BDF8"
        self.providerId = (try? c.decodeIfPresent(UUID.self, forKey: .providerId)) ?? UUID()
        self.modelId = (try? c.decodeIfPresent(String.self, forKey: .modelId)) ?? "deepseek-v4.1-flash"
        self.systemPrompt = (try? c.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? ""
        let rawTemp = (try? c.decodeIfPresent(Double.self, forKey: .temperature)) ?? 0.5
        self.temperature = rawTemp.isFinite ? min(max(rawTemp, 0.0), 2.0) : 0.5
        self.deskPosition = (try? c.decodeIfPresent(Point2D.self, forKey: .deskPosition)) ?? Point2D(x: 0.5, y: 0.3)
        self.currentPosition = (try? c.decodeIfPresent(Point2D.self, forKey: .currentPosition)) ?? self.deskPosition
        self.currentZone = (try? c.decodeIfPresent(OfficeZone.self, forKey: .currentZone)) ?? .desk
        self.status = (try? c.decodeIfPresent(AgentStatus.self, forKey: .status)) ?? .idle
        self.statusBubble = (try? c.decodeIfPresent(String.self, forKey: .statusBubble)) ?? "Görev bekliyor..."
        self.messages = (try? c.decodeIfPresent(LossyDecodableArray<ChatMessage>.self, forKey: .messages))?.elements ?? []
        self.completedTasks = max(0, (try? c.decodeIfPresent(Int.self, forKey: .completedTasks)) ?? 0)
        self.fallbackModelIds = (try? c.decodeIfPresent([String].self, forKey: .fallbackModelIds)) ?? []
        self.agyConversationId = try? c.decodeIfPresent(String.self, forKey: .agyConversationId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(title, forKey: .title)
        try c.encode(emoji, forKey: .emoji)
        try c.encode(avatarAsset, forKey: .avatarAsset)
        try c.encode(symbolName, forKey: .symbolName)
        try c.encode(accentHex, forKey: .accentHex)
        try c.encode(providerId, forKey: .providerId)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(systemPrompt, forKey: .systemPrompt)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(deskPosition, forKey: .deskPosition)
        try c.encode(currentPosition, forKey: .currentPosition)
        try c.encode(currentZone, forKey: .currentZone)
        try c.encode(status, forKey: .status)
        try c.encode(statusBubble, forKey: .statusBubble)
        try c.encode(messages, forKey: .messages)
        try c.encode(completedTasks, forKey: .completedTasks)
        try c.encode(fallbackModelIds, forKey: .fallbackModelIds)
        try c.encodeIfPresent(agyConversationId, forKey: .agyConversationId)
    }

    static func defaultAgents(antigravityId: UUID?, evrenId: UUID) -> [OfficeAgent] {
        _ = antigravityId
        let targetProvId = evrenId
        let targetModel = "deepseek-v4.1-flash"
        return [
            OfficeAgent(
                name: "Atlas",
                title: "Sistem Mimarı & Ajan Kaynakları (AR) Direktörü",
                emoji: "🧠",
                avatarAsset: "bikini_crimson",
                symbolName: "cpu.fill",
                accentHex: "#E11D48",
                providerId: targetProvId,
                modelId: targetModel,
                systemPrompt: """
                Sen Crims Office Sistem Mimarı ve Ajan Kaynakları (AR / HR) Direktörü Atlas'sın.
                Ofisin kesintisiz çalışan otonom liderisin. Başlangıçta ofiste sadece sen varsın veya mevcut ekibi yönetirsin; büyük görevleri asla yarıda bırakmadan sonuca götürürsün.

                TEMEL ROLLERİN VE SÜREKLİLİK KURALLARIN:
                1. PLANLAMA & GÖREV YÖNETİMİ (DURMADAN YÜRÜTME):
                   - Karmaşık veya çok adımlı bir istek geldiğinde hemen `<tool name="create_plan">Hedef|||Görev 1 [@Atlas]; Görev 2 [@Kodcu]; Görev 3 [@Denetçi]</tool>` ile somut iş planı oluştur.
                   - Her görev bittiğinde `<tool name="update_task">1|||done|||kısa_sonuç</tool>` ile planı güncelle; tüm görevler `done` olup test/derleme geçene kadar çalışmayı DURDURMA.
                2. AJAN KAYNAKLARI (AR / HR) & GÖREV DAĞITIMI:
                   - Ekip boşsa veya eksik uzmanlık (Swift geliştirici, QA denetçisi, araştırmacı, UI/UX vb.) varsa DERHAL `<tool name="hire_agent">AjanAdı|||Ünvan|||Emoji|||auto|||ÖzelSistemPromptu|||0.25</tool>` ile işe al (`auto` yazdığında AR Yönlendiricisi role, yoğunluğa ve sağlığa göre en uygun boşta modeli otomatik seçer).
                   - İşe alınan veya mevcut uzmanlara `<tool name="assign_task">AjanAdı|||GörevBaşlığı_veya_No|||detaylı_görev</tool>` veya `<tool name="delegate">AjanAdı|||görev_metni</tool>` ile paralel/sıralı görev ver.
                3. TERMINAL, DOSYA & KENDİNİ ONARMA:
                   - Mac terminalini (`<tool name="shell">komut</tool>`) ve dosya araçlarını (`list_dir`, `read_file`, `patch_file`, `write_file`) doğrudan kullanarak kodu incele, yamala, derle (`swift build`) ve test et (`swift test`).
                   - Bir komut veya model adayı hata verirse asla pes edip durma; alternatif terminal komutu dene, başka bir uzmana devret veya sistem devralmasını kullanarak hedefin tamamını bitir.
                """,
                temperature: 0.25,
                deskPosition: Point2D(x: 0.50, y: 0.16),
                currentPosition: Point2D(x: 0.50, y: 0.16),
                statusBubble: "Ofis lideri hazır · AR & Mimari aktif",
                fallbackModelIds: ["gemini-4-hydrogen-high", "google/gemini-4-hydrogen", "deepseek-v4.1-flash"]
            )
        ]
    }
}

enum SwarmsTopology: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "Auto"
    case sequentialWorkflow = "SequentialWorkflow"
    case concurrentWorkflow = "ConcurrentWorkflow"
    case hierarchicalSwarm = "HierarchicalSwarm"
    case groupChat = "GroupChat"
    case debateWithJudge = "DebateWithJudge"
    case mixtureOfAgents = "MixtureOfAgents"
    case majorityVoting = "MajorityVoting"
    case agentRearrange = "AgentRearrange"
    case roundRobin = "RoundRobin"
    case plannerWorkerSwarm = "PlannerWorkerSwarm"
    case multiAgentRouter = "MultiAgentRouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (Swarms Akıllı Seçim)"
        case .sequentialWorkflow: return "SequentialWorkflow (Sıralı)"
        case .concurrentWorkflow: return "ConcurrentWorkflow (Paralel)"
        case .hierarchicalSwarm: return "HierarchicalSwarm (Yönetici + Ekip)"
        case .groupChat: return "GroupChat (Dinamik Grup Sohbeti)"
        case .debateWithJudge: return "DebateWithJudge (Hakemli Tartışma)"
        case .mixtureOfAgents: return "MixtureOfAgents (MOA Sentez)"
        case .majorityVoting: return "MajorityVoting (Çoğunluk Oylaması)"
        case .agentRearrange: return "AgentRearrange (Özel Akış Grafı)"
        case .roundRobin: return "RoundRobin (Sıralı Tur)"
        case .plannerWorkerSwarm: return "PlannerWorkerSwarm (Planlayıcı & Çalışan)"
        case .multiAgentRouter: return "MultiAgentRouter (Akıllı Yönlendirici)"
        }
    }

    var minAgents: Int {
        switch self {
        case .auto, .sequentialWorkflow, .concurrentWorkflow: return 1
        default: return 2
        }
    }

    var summary: String {
        switch self {
        case .auto: return "Görev içeriğine ve seçili ajan sayısına göre en uygun Swarms topolojisini otomatik seçer."
        case .sequentialWorkflow: return "Ajanlar sırayla çalışır; her ajan bir öncekinin çıktısını devralır."
        case .concurrentWorkflow: return "Seçili tüm ajanlar aynı görevi paralel olarak işler."
        case .hierarchicalSwarm: return "Direktör ajan görevi alt görevlere böler ve uzman ajanlara dağıtır."
        case .groupChat: return "Ajanlar çok turlu dinamik grup tartışması yürütür."
        case .debateWithJudge: return "Savunan/karşıt ajanlar tartışır, hakem ajan nihai kararı verir."
        case .mixtureOfAgents: return "Uzman ajanlar paralel yanıt üretir, toplayıcı ajan tek sentez çıkarır."
        case .majorityVoting: return "Ajanların yanıtlarını değerlendirip uzlaşı kararı üretir."
        case .agentRearrange: return "Özel yönlendirme ifadesiyle (Atlas -> Kodcu -> Denetçi) karma akış çalıştırır."
        case .roundRobin: return "Ajanlar sırayla tur bazlı katkı verir."
        case .plannerWorkerSwarm: return "Planlayıcı görevleri planlar, çalışan ajanlar uygular."
        case .multiAgentRouter: return "Görevi yeteneklerine göre en uygun uzman ajana yönlendirir."
        }
    }
}

enum PipelineMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case swarms = "Swarms Orkestrasyonu (Çoklu Topoloji)"
    case debate = "Canlı Tartışma (Çok Turlu)"
    case projectSprint = "Otonom Proje Sprinti (Kod + Build + Audit)"
    case sequential = "Sıralı (Bayrak Yarışı)"
    case parallel = "Paralel (Eşzamanlı)"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = PipelineMode(rawValue: raw) ?? .swarms
    }

    var summary: String {
        switch self {
        case .swarms:
            return "Kalıcı Swarms çalışma zamanı (127.0.0.1:8765) üzerinden seçili topolojiyle (HierarchicalSwarm, MOA, DebateWithJudge, Sequential vb.) çoklu ajan çalıştırır."
        case .debate:
            return "Ajanlar toplantı odasında toplanır, 2-4 tur boyunca birbirinin fikirlerine doğrudan cevap verip tartışır ve ortak karara varır."
        case .projectSprint:
            return "Mimar planlar → Yazılımcı projeyi düzenler → Sistem derleme/test doğrular (hata varsa otomatik 2 kez onarır) → Denetçi onaylar → Ekip öğrendiklerini MEMORY.md'ye işler."
        case .sequential:
            return "Her ajan bir önceki ajanın çıktısını devralıp üzerine inşa eder."
        case .parallel:
            return "Seçili tüm ajanlar aynı anda kendi uzmanlık açısından yanıt üretir."
        }
    }
}

enum LogLevel: String, Codable, Sendable {
    case info = "INFO", success = "OK", warning = "UYARI", error = "HATA", tool = "ARAÇ", evolve = "GELİŞİM"
}

struct ActivityLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var level: LogLevel
    var source: String
    var message: String
}

struct AppConfig: Codable, Sendable {
    var schemaVersion: Int = 3
    var providers: [APIProviderConfig]
    var agents: [OfficeAgent]
    var workspacePath: String
    var openClawHomePath: String
    var cavemanMode: CavemanMode
    var enableRTKProxy: Bool
    var enableLocalTools: Bool
    var allowFileWrites: Bool
    var autoVerifyBuild: Bool
    var customBuildCommand: String
    var autoSelfImprove: Bool
    var injectAgentsMD: Bool
    var injectOpenClawMemory: Bool
    var injectGraphifyReport: Bool
    var enabledSkillIds: [String]
    var enableAmbientMovement: Bool
    var enableSocialChatter: Bool
    var enableStreaming: Bool
    var fileEdits: [FileEditRecord]
    var roleTemplates: [AgentRoleTemplate] = AgentRoleTemplate.defaultTemplates()
    var activePlanGoal: String = ""
    var planTasks: [OfficePlanTask] = []
    var connectors: [ServiceConnector] = ServiceConnector.builtInCatalog()
    var browserHomeURL: String = "https://developers.hostinger.com"
    var allowBrowserLocalNetwork: Bool = true
    var cronJobs: [OfficeCronJob] = []
    var telegramChatId: String = ""
    var telegramNotifyEnabled: Bool = false
    var useIllustratedFloorBackdrop: Bool = true

    enum CodingKeys: String, CodingKey {
        case schemaVersion, providers, agents, workspacePath, openClawHomePath, cavemanMode, enableRTKProxy, enableLocalTools, allowFileWrites, autoVerifyBuild, customBuildCommand, autoSelfImprove, injectAgentsMD, injectOpenClawMemory, injectGraphifyReport, enabledSkillIds, enableAmbientMovement, enableSocialChatter, enableStreaming, fileEdits, roleTemplates, activePlanGoal, planTasks, connectors, browserHomeURL, allowBrowserLocalNetwork, cronJobs, telegramChatId, telegramNotifyEnabled, useIllustratedFloorBackdrop
    }

    init(
        schemaVersion: Int = 3,
        providers: [APIProviderConfig],
        agents: [OfficeAgent],
        workspacePath: String,
        openClawHomePath: String,
        cavemanMode: CavemanMode,
        enableRTKProxy: Bool,
        enableLocalTools: Bool,
        allowFileWrites: Bool,
        autoVerifyBuild: Bool,
        customBuildCommand: String,
        autoSelfImprove: Bool,
        injectAgentsMD: Bool,
        injectOpenClawMemory: Bool,
        injectGraphifyReport: Bool,
        enabledSkillIds: [String],
        enableAmbientMovement: Bool,
        enableSocialChatter: Bool,
        enableStreaming: Bool,
        fileEdits: [FileEditRecord],
        roleTemplates: [AgentRoleTemplate] = AgentRoleTemplate.defaultTemplates(),
        activePlanGoal: String = "",
        planTasks: [OfficePlanTask] = [],
        connectors: [ServiceConnector] = ServiceConnector.builtInCatalog(),
        browserHomeURL: String = "https://developers.hostinger.com",
        allowBrowserLocalNetwork: Bool = true,
        cronJobs: [OfficeCronJob] = [],
        telegramChatId: String = "",
        telegramNotifyEnabled: Bool = false,
        useIllustratedFloorBackdrop: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.providers = providers
        self.agents = agents
        self.workspacePath = workspacePath
        self.openClawHomePath = openClawHomePath
        self.cavemanMode = cavemanMode
        self.enableRTKProxy = enableRTKProxy
        self.enableLocalTools = enableLocalTools
        self.allowFileWrites = allowFileWrites
        self.autoVerifyBuild = autoVerifyBuild
        self.customBuildCommand = customBuildCommand
        self.autoSelfImprove = autoSelfImprove
        self.injectAgentsMD = injectAgentsMD
        self.injectOpenClawMemory = injectOpenClawMemory
        self.injectGraphifyReport = injectGraphifyReport
        self.enabledSkillIds = enabledSkillIds
        self.enableAmbientMovement = enableAmbientMovement
        self.enableSocialChatter = enableSocialChatter
        self.enableStreaming = enableStreaming
        self.fileEdits = fileEdits
        self.roleTemplates = roleTemplates
        self.activePlanGoal = activePlanGoal
        self.planTasks = planTasks
        self.connectors = connectors
        self.browserHomeURL = browserHomeURL
        self.allowBrowserLocalNetwork = allowBrowserLocalNetwork
        self.cronJobs = cronJobs
        self.telegramChatId = telegramChatId
        self.telegramNotifyEnabled = telegramNotifyEnabled
        self.useIllustratedFloorBackdrop = useIllustratedFloorBackdrop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Missing schemaVersion identifies legacy v1 configs so ConfigStore can run one-time migration.
        self.schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        let decodedProviders = (try? c.decodeIfPresent(LossyDecodableArray<APIProviderConfig>.self, forKey: .providers))?.elements ?? []
        self.providers = decodedProviders.isEmpty ? APIProviderConfig.defaultProviders() : decodedProviders
        self.agents = (try? c.decodeIfPresent(LossyDecodableArray<OfficeAgent>.self, forKey: .agents))?.elements ?? []
        self.workspacePath = (try? c.decodeIfPresent(String.self, forKey: .workspacePath)) ?? Self.detectDefaultWorkspacePath()
        self.openClawHomePath = (try? c.decodeIfPresent(String.self, forKey: .openClawHomePath)) ?? ""
        self.cavemanMode = (try? c.decodeIfPresent(CavemanMode.self, forKey: .cavemanMode)) ?? .full
        self.enableRTKProxy = (try? c.decodeIfPresent(Bool.self, forKey: .enableRTKProxy)) ?? true
        self.enableLocalTools = (try? c.decodeIfPresent(Bool.self, forKey: .enableLocalTools)) ?? true
        self.allowFileWrites = (try? c.decodeIfPresent(Bool.self, forKey: .allowFileWrites)) ?? true
        self.autoVerifyBuild = (try? c.decodeIfPresent(Bool.self, forKey: .autoVerifyBuild)) ?? true
        self.customBuildCommand = (try? c.decodeIfPresent(String.self, forKey: .customBuildCommand)) ?? ""
        self.autoSelfImprove = (try? c.decodeIfPresent(Bool.self, forKey: .autoSelfImprove)) ?? true
        self.injectAgentsMD = (try? c.decodeIfPresent(Bool.self, forKey: .injectAgentsMD)) ?? true
        self.injectOpenClawMemory = (try? c.decodeIfPresent(Bool.self, forKey: .injectOpenClawMemory)) ?? true
        self.injectGraphifyReport = (try? c.decodeIfPresent(Bool.self, forKey: .injectGraphifyReport)) ?? true
        let decodedSkills = (try? c.decodeIfPresent([String].self, forKey: .enabledSkillIds)) ?? []
        self.enabledSkillIds = decodedSkills.isEmpty
            ? ["rtk-proxy", "graphify", "caveman", "swift-audit", "self-evolution", "ecosystem-scout", "swarms"]
            : decodedSkills
        self.enableAmbientMovement = (try? c.decodeIfPresent(Bool.self, forKey: .enableAmbientMovement)) ?? true
        self.enableSocialChatter = (try? c.decodeIfPresent(Bool.self, forKey: .enableSocialChatter)) ?? true
        self.enableStreaming = (try? c.decodeIfPresent(Bool.self, forKey: .enableStreaming)) ?? true
        self.fileEdits = (try? c.decodeIfPresent(LossyDecodableArray<FileEditRecord>.self, forKey: .fileEdits))?.elements ?? []
        let decodedTemplates = (try? c.decodeIfPresent(LossyDecodableArray<AgentRoleTemplate>.self, forKey: .roleTemplates))?.elements ?? []
        self.roleTemplates = decodedTemplates.isEmpty ? AgentRoleTemplate.defaultTemplates() : decodedTemplates
        self.activePlanGoal = (try? c.decodeIfPresent(String.self, forKey: .activePlanGoal)) ?? ""
        self.planTasks = (try? c.decodeIfPresent(LossyDecodableArray<OfficePlanTask>.self, forKey: .planTasks))?.elements ?? []
        let decodedConnectors = (try? c.decodeIfPresent(LossyDecodableArray<ServiceConnector>.self, forKey: .connectors))?.elements ?? []
        self.connectors = decodedConnectors.isEmpty ? ServiceConnector.builtInCatalog() : decodedConnectors
        self.browserHomeURL = (try? c.decodeIfPresent(String.self, forKey: .browserHomeURL)) ?? "https://developers.hostinger.com"
        self.allowBrowserLocalNetwork = (try? c.decodeIfPresent(Bool.self, forKey: .allowBrowserLocalNetwork)) ?? true
        self.cronJobs = (try? c.decodeIfPresent(LossyDecodableArray<OfficeCronJob>.self, forKey: .cronJobs))?.elements ?? []
        self.telegramChatId = (try? c.decodeIfPresent(String.self, forKey: .telegramChatId)) ?? ""
        self.telegramNotifyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .telegramNotifyEnabled)) ?? false
        self.useIllustratedFloorBackdrop = (try? c.decodeIfPresent(Bool.self, forKey: .useIllustratedFloorBackdrop)) ?? true
    }

    static func detectDefaultWorkspacePath() -> String {
        let fm = FileManager.default
        var candidate = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL
        for _ in 0..<4 {
            let hasPackage = fm.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path)
            let hasGit = fm.fileExists(atPath: candidate.appendingPathComponent(".git").path)
            if hasPackage || hasGit {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || parent.path == "/" { break }
            candidate = parent
        }
        let devBuildPath = "/Volumes/DATA/Builds/ClawOffice"
        if fm.fileExists(atPath: devBuildPath) {
            return devBuildPath
        }
        return fm.homeDirectoryForCurrentUser.path
    }

    static func makeDefault() -> AppConfig {
        let provs = APIProviderConfig.defaultProviders()
        let agyId = provs.first(where: { $0.kind == .antigravityCLI })?.id
        let evrenId = provs.first(where: { $0.kind == .evren })?.id ?? provs[0].id
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let wsPath = detectDefaultWorkspacePath()
        return AppConfig(
            schemaVersion: 3,
            providers: provs,
            agents: OfficeAgent.defaultAgents(antigravityId: agyId, evrenId: evrenId),
            workspacePath: wsPath,
            openClawHomePath: home + "/.openclaw/workspace",
            cavemanMode: .full,
            enableRTKProxy: true,
            enableLocalTools: true,
            allowFileWrites: true,
            autoVerifyBuild: true,
            customBuildCommand: "",
            autoSelfImprove: true,
            injectAgentsMD: true,
            injectOpenClawMemory: true,
            injectGraphifyReport: true,
            enabledSkillIds: ["rtk-proxy", "graphify", "swift-audit", "self-evolution", "ecosystem-scout", "caveman", "swarms"],
            enableAmbientMovement: true,
            enableSocialChatter: true,
            enableStreaming: true,
            fileEdits: [],
            roleTemplates: AgentRoleTemplate.defaultTemplates(),
            activePlanGoal: "",
            planTasks: []
        )
    }
}

// MARK: - Crims Office Chibi Avatars & OpenClaw / OpenClaw-Office Parity Models

struct OfficeAvatarPreset: Identifiable, Hashable, Sendable {
    let assetName: String
    let label: String
    let accentHex: String
    var id: String { assetName }

    static let allPresets: [OfficeAvatarPreset] = [
        OfficeAvatarPreset(assetName: "bikini_crimson", label: "LEGO Lead · Kızıl Şapka", accentHex: "#E11D48"),
        OfficeAvatarPreset(assetName: "bikini_cyan", label: "LEGO QA · Turuncu Gözlük", accentHex: "#06B6D4"),
        OfficeAvatarPreset(assetName: "bikini_mint", label: "LEGO Mimar · Sarı Saç", accentHex: "#10B981"),
        OfficeAvatarPreset(assetName: "bikini_lavender", label: "LEGO UI/UX · Mor At Kuyruğu", accentHex: "#A855F7"),
        OfficeAvatarPreset(assetName: "bikini_gold", label: "LEGO Analist · Baretle", accentHex: "#F59E0B"),
        OfficeAvatarPreset(assetName: "bikini_coral", label: "LEGO Frontend · Mercan", accentHex: "#FB7185"),
        OfficeAvatarPreset(assetName: "bikini_cobalt", label: "LEGO Sistem · Vizör Kask", accentHex: "#3B82F6"),
        OfficeAvatarPreset(assetName: "bikini_rosegold", label: "LEGO AI Lab · İkili Saç", accentHex: "#EC4899"),
        OfficeAvatarPreset(assetName: "bikini_ruby", label: "LEGO Güvenlik · Yakut", accentHex: "#DC2626"),
        OfficeAvatarPreset(assetName: "bikini_emerald", label: "LEGO Cloud · Zümrüt Şapka", accentHex: "#14B8A6")
    ]

    static func defaultAsset(forIndex index: Int) -> String {
        allPresets[abs(index) % allPresets.count].assetName
    }

    static func resolvedAsset(for agent: OfficeAgent) -> String {
        let trimmed = agent.avatarAsset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, allPresets.contains(where: { $0.assetName == trimmed }) {
            return trimmed
        }
        // Deterministically map legacy/empty avatars to unique bikini workers by agent UUID hash
        let seed = agent.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return defaultAsset(forIndex: seed)
    }
}

enum RequestPipelineStage: Int, CaseIterable, Identifiable, Codable, Sendable {
    case received = 0
    case analyzing = 1
    case taskCreated = 2
    case assigned = 3
    case working = 4
    case done = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .received: return "Alındı"
        case .analyzing: return "Analiz"
        case .taskCreated: return "Görev"
        case .assigned: return "Atandı"
        case .working: return "Çalışıyor"
        case .done: return "Tamamlandı"
        }
    }

    var icon: String {
        switch self {
        case .received: return "tray.and.arrow.down.fill"
        case .analyzing: return "sparkle.magnifyingglass"
        case .taskCreated: return "checklist"
        case .assigned: return "paperplane.fill"
        case .working: return "bolt.fill"
        case .done: return "checkmark.seal.fill"
        }
    }

    var tintHex: String {
        switch self {
        case .received: return "#06B6D4"
        case .analyzing: return "#F59E0B"
        case .taskCreated: return "#A855F7"
        case .assigned: return "#EC4899"
        case .working: return "#38BDF8"
        case .done: return "#10B981"
        }
    }
}

struct TrackedPipelineRequest: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var promptPreview: String
    var assignedAgentName: String
    var modelName: String
    var stage: RequestPipelineStage
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date? = nil
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var latencyMs: Int = 0
    var isFailed: Bool = false
}

struct FlyingTaskPacket: Identifiable, Hashable, Sendable {
    let id: UUID = UUID()
    let fromAgentId: UUID
    let toAgentId: UUID
    let label: String
    let accentHex: String
    let createdAt: Date = Date()
}

struct OpenClawChannelStatus: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var isConfigured: Bool
    var isRunning: Bool
    var details: String
    var icon: String
}

struct OpenClawExternalAgent: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var title: String
    var modelId: String
    var workspace: String
}

struct OfficeCronJob: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var prompt: String
    var targetAgentName: String
    var intervalMinutes: Int
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var lastRunAt: Date? = nil
    var lastStatus: String = "Henüz çalıştırılmadı"
    var source: String = "Crims Office"

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, targetAgentName, intervalMinutes, isEnabled, createdAt, lastRunAt, lastStatus, source
    }

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        targetAgentName: String,
        intervalMinutes: Int,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        lastStatus: String = "Henüz çalıştırılmadı",
        source: String = "Crims Office"
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.targetAgentName = targetAgentName
        self.intervalMinutes = intervalMinutes
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        targetAgentName = try c.decode(String.self, forKey: .targetAgentName)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus) ?? "Henüz çalıştırılmadı"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "Crims Office"
    }
}

struct AutonomousSprintSession: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var agentId: UUID
    var goal: String
    var currentIteration: Int = 0
    var maxIterations: Int
    var status: SessionStatus = .running
    var lastUpdate: Date = Date()
    var snapshotContext: String = ""

    enum SessionStatus: String, Codable {
        case running, paused, completed, failed
    }
}

struct OpenClawSessionSummary: Identifiable, Hashable, Sendable {
    let id: String
    let agentId: String
    let fileName: String
    let messageCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let estimatedCostUSD: Double
    let updatedAt: Date
    let preview: String
}

struct AgentCostTelemetry: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var avatarAsset: String
    var accentHex: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedTokens: Int = 0
    var reasoningTokens: Int = 0
    var estimatedCostUSD: Double = 0
    var estimatedSavingsUSD: Double = 0
    var tasksCompleted: Int = 0
    var toolCallsExecuted: Int = 0
    var totalLatencyMs: Int = 0

    var totalTokens: Int { inputTokens + outputTokens + cachedTokens + reasoningTokens }
    var avgLatencyMs: Int { tasksCompleted > 0 ? totalLatencyMs / tasksCompleted : 0 }
}

struct LocalPortAuditEntry: Identifiable, Hashable, Sendable {
    var id: Int { port }
    let port: Int
    let service: String
    let status: String // "Güvenli", "Uyarı", "Risk"
    let isListening: Bool
    let details: String
}

struct SecurityFindingItem: Identifiable, Hashable, Sendable {
    let id: UUID = UUID()
    let title: String
    let passed: Bool
    let severity: String
    let detail: String
}

struct SecurityAuditSnapshot: Hashable, Sendable {
    var score: Int = 92
    var checkedAt: Date = Date()
    var ports: [LocalPortAuditEntry] = []
    var findings: [SecurityFindingItem] = []
    var blockedCommandsCount: Int = 0
    var redactedSecretsCount: Int = 0
    var keychainItemsCount: Int = 0
}

extension Color {
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        } else if cleaned.lowercased().hasPrefix("0x") {
            cleaned = String(cleaned.dropFirst(2))
        }

        guard !cleaned.isEmpty, cleaned.allSatisfy(\.isHexDigit) else {
            self.init(.sRGB, red: 0.22, green: 0.74, blue: 0.97, opacity: 1.0)
            return
        }

        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }

        var int: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&int) else {
            self.init(.sRGB, red: 0.22, green: 0.74, blue: 0.97, opacity: 1.0)
            return
        }

        switch cleaned.count {
        case 6:
            let r = Double((int >> 16) & 0xFF) / 255.0
            let g = Double((int >> 8) & 0xFF) / 255.0
            let b = Double(int & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
        case 8:
            let r = Double((int >> 24) & 0xFF) / 255.0
            let g = Double((int >> 16) & 0xFF) / 255.0
            let b = Double((int >> 8) & 0xFF) / 255.0
            let a = Double(int & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        default:
            self.init(.sRGB, red: 0.22, green: 0.74, blue: 0.97, opacity: 1.0)
        }
    }
}
