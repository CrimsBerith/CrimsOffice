import Foundation

enum LLMClientError: LocalizedError {
    case invalidURL(String)
    case missingAPIKey(String)
    case httpError(Int, String)
    case cliError(Int32, String)
    case emptyResponse
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "Geçersiz API adresi: \(u)"
        case .missingAPIKey(let n): return "\(n) için API anahtarı girilmemiş."
        case .httpError(let c, let d): return "HTTP \(c): \(d)"
        case .cliError(let c, let d): return "CLI Çıkış \(c): \(d)"
        case .emptyResponse: return "Modelden boş yanıt döndü."
        case .decodingError(let m): return "Yanıt çözümlenemedi: \(m)"
        }
    }
}

struct LLMStreamDelta: Sendable {
    let contentChunk: String
    let reasoningChunk: String
    let resolvedModel: String?
    var activeToolBubble: String? = nil
    var completedToolCall: ToolCallRecord? = nil
    var touchedFilePath: String? = nil
    var conversationId: String? = nil
}

struct LLMFinalResponse: Sendable {
    let content: String
    let reasoning: String
    let resolvedModel: String
    let latencyMs: Int
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cachedTokens: Int = 0
    var reasoningTokens: Int = 0
    var toolCalls: [ToolCallRecord] = []
    var touchedFiles: [String] = []
    var agyConversationId: String? = nil
}

final class LLMClient: Sendable {
    static let shared = LLMClient()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: cfg)
    }

    func ping(provider: APIProviderConfig) async -> (isOnline: Bool, latencyMs: Int, message: String) {
        if provider.kind == .antigravityCLI {
            let start = Date()
            if let bin = APIProviderConfig.resolveAntigravityCLIPath(hint: provider.normalizedBaseURL) {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return (true, max(1, elapsed), "agy CLI hazır (\(URL(fileURLWithPath: bin).lastPathComponent))")
            }
            return (false, 0, "agy CLI bulunamadı (~/.local/bin/agy)")
        }
        if !provider.isConfigured && provider.authStyle != .none {
            return (false, 0, "API anahtarı girilmedi")
        }
        let start = Date()
        do {
            let pingPath: String
            switch provider.kind {
            case .evren: pingPath = "/terms/status"
            default: pingPath = "/models"
            }
            var req = try buildRequest(provider: provider, path: pingPath)
            req.timeoutInterval = 4.5
            let (_, resp) = try await session.data(for: req)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            if let http = resp as? HTTPURLResponse {
                if (200...399).contains(http.statusCode) {
                    return (true, elapsed, "Aktif (\(http.statusCode)) · \(elapsed) ms")
                } else if http.statusCode == 403 && provider.kind == .evren {
                    return (true, elapsed, "Şart Onayı Bekliyor (403) · \(elapsed) ms")
                } else if http.statusCode == 429 {
                    return (false, elapsed, "Hız Sınırı (429) · \(elapsed) ms")
                } else {
                    return (false, elapsed, "HTTP \(http.statusCode) · \(elapsed) ms")
                }
            }
            return (true, elapsed, "\(elapsed) ms")
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let desc = (error as NSError).localizedDescription
            return (false, elapsed, desc.prefix(40).description)
        }
    }

    private func buildRequest(provider: APIProviderConfig, path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let base = provider.normalizedBaseURL
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        guard !base.isEmpty,
              let url = URL(string: base + cleanPath),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            throw LLMClientError.invalidURL(base + cleanPath)
        }
        let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.authStyle != .none && key.isEmpty {
            throw LLMClientError.missingAPIKey(provider.name)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CrimsOffice-macOS/4.0", forHTTPHeaderField: "User-Agent")

        switch provider.authStyle {
        case .bearer:
            if Self.isAnthropicAPI(provider) {
                req.setValue(key, forHTTPHeaderField: "x-api-key")
            } else {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .xApiKey:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case .bearerAndXApiKey:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case .none:
            break
        }
        if Self.isAnthropicAPI(provider) {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if provider.kind == .openRouter {
            req.setValue("https://crimsoffice.local", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Crims Office macOS", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = body
        return req
    }

    static func isAnthropicAPI(_ provider: APIProviderConfig) -> Bool {
        provider.normalizedBaseURL.lowercased().contains("api.anthropic.com")
    }

    func fetchModels(provider: APIProviderConfig) async throws -> [String] {
        if provider.kind == .antigravityCLI {
            return try await fetchAntigravityCLIModels(provider: provider)
        }
        let req = try buildRequest(provider: provider, path: "/models")
        let (data, resp) = try await session.data(for: req)
        try validate(resp, data: data, provider: provider)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = json["data"] as? [[String: Any]] {
            var freeList: [String] = []
            var standardList: [String] = []
            for item in arr {
                guard let id = item["id"] as? String, !id.isEmpty else { continue }
                if provider.kind == .evren {
                    let nonChat = ["ocr", "embedding", "reranker", "asr", "guard", "voxcpm", "clef", "laya"]
                    if nonChat.contains(where: { id.lowercased().contains($0) }) { continue }
                }
                let isFree = (item["isFree"] as? Bool) == true
                let pricing = (item["pricing"] as? [String: Any])?["prompt"] as? String
                if isFree || id.contains(":free") || pricing == "0" || id.lowercased().contains("free") {
                    if !freeList.contains(id) { freeList.append(id) }
                } else {
                    if !standardList.contains(id) { standardList.append(id) }
                }
            }
            freeList.sort()
            standardList.sort()
            var ids = freeList + standardList
            if provider.kind == .evren {
                let priority = ["deepseek-v4.1-flash", "qwen3.8-flash-next", "gemma-4-31b", "glm-5.3", "qwen3-vl-30b"]
                for p in priority.reversed() {
                    if let idx = ids.firstIndex(of: p) {
                        ids.remove(at: idx)
                        ids.insert(p, at: 0)
                    }
                }
                if let idx = ids.firstIndex(of: "auto") { ids.remove(at: idx); ids.append("auto") }
            }
            if provider.kind == .kilo || provider.kind == .openRouter {
                let flagship = ["google/gemini-4-hydrogen", "google/gemini-4-neon", "google/gemini-4-carbon"]
                for m in flagship.reversed() {
                    if let idx = ids.firstIndex(of: m) {
                        ids.remove(at: idx)
                        let insertPos = min(1, ids.count)
                        ids.insert(m, at: insertPos)
                    }
                }
            }
            if provider.kind == .kilo {
                for m in ["kilo-auto/free", "kilo/auto"].reversed() {
                    if let idx = ids.firstIndex(of: m) {
                        ids.remove(at: idx)
                        ids.insert(m, at: 0)
                    }
                }
            }
            if !ids.isEmpty { return ids }
        }
        throw LLMClientError.decodingError("Model listesi boş veya biçimi tanınamadı.")
    }

    func acceptEvrenTerms(provider: APIProviderConfig) async throws -> (version: String, summary: String) {
        let statusReq = try buildRequest(provider: provider, path: "/terms/status")
        let (sData, sResp) = try await session.data(for: statusReq)
        try validate(sResp, data: sData, provider: provider)

        let obj = (try? JSONSerialization.jsonObject(with: sData) as? [String: Any]) ?? [:]
        let version: String
        if let vStr = obj["current_version"] as? String {
            version = vStr
        } else if let vInt = obj["current_version"] as? Int {
            version = "\(vInt)"
        } else if let vStr2 = obj["version"] as? String {
            version = vStr2
        } else if let vInt2 = obj["version"] as? Int {
            version = "\(vInt2)"
        } else {
            version = "1"
        }

        if (obj["accepted"] as? Bool) == true {
            return (version, "EVREN kullanım şartları zaten onaylı (Sürüm: \(version)).")
        }
        guard !version.isEmpty else {
            throw LLMClientError.decodingError("current_version alınamadı.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["version": version])
        let accReq = try buildRequest(provider: provider, path: "/terms/accept", method: "POST", body: body)
        let (aData, aResp) = try await session.data(for: accReq)
        try validate(aResp, data: aData, provider: provider)
        return (version, "EVREN kullanım şartları onaylandı (Sürüm: \(version)).")
    }

    func fetchEvrenQuota(provider: APIProviderConfig) async throws -> String {
        let req = try buildRequest(provider: provider, path: "/quota")
        let (data, resp) = try await session.data(for: req)
        try validate(resp, data: data, provider: provider)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var parts: [String] = []
            if let cr = json["remaining_cr"] {
                parts.append("Kalan Kredi: \(cr)")
            }
            if let dailyRem = json["daily_remaining_tokens"] as? Int {
                let m = Double(dailyRem) / 1_000_000.0
                parts.append("Günlük Token: \(String(format: "%.1f", m))M")
            }
            if let lvl = json["level"] as? String {
                parts.append("Durum: \(lvl.uppercased())")
            }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return String(data: data, encoding: .utf8) ?? "Kota alındı."
    }

    private static func usesEvrenReasoningParams(provider: APIProviderConfig, model: String) -> Bool {
        let lowerModel = model.lowercased()
        let isGemma = lowerModel.contains("gemma")
        let isReasoningModel = lowerModel.contains("deepseek")
            || lowerModel.contains("glm")
            || lowerModel.contains("qwen")
            || lowerModel.contains("reasoning")
            || lowerModel.contains("o1")
            || lowerModel.contains("o3")
        return provider.kind == .evren && isReasoningModel && !isGemma
    }

    /// Public entry with retry before first emitted delta + EVREN 403 terms recovery + Antigravity CLI backend
    func streamChat(
        provider: APIProviderConfig,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        stream: Bool,
        workspacePath: String? = nil,
        allowLocalEdits: Bool = true,
        agyConversationId: String? = nil,
        streamTimeouts: (firstToken: TimeInterval, interChunk: TimeInterval)? = nil,
        onDelta: @escaping @Sendable (LLMStreamDelta) -> Void
    ) async throws -> LLMFinalResponse {
        if provider.kind == .antigravityCLI {
            return try await executeAntigravityCLIChat(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                workspacePath: workspacePath,
                allowLocalEdits: allowLocalEdits,
                agyConversationId: agyConversationId,
                onDelta: onDelta
            )
        }
        var attempt = 0
        var evrenRecovered = false
        var useReasoningParams = Self.usesEvrenReasoningParams(provider: provider, model: model)

        final class DeltaTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var _emitted = false
            var emitted: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _emitted }
                set { lock.lock(); _emitted = newValue; lock.unlock() }
            }
        }

        while true {
            try Task.checkCancellation()
            let deltaTracker = DeltaTracker()
            do {
                return try await executeStreamChatOnce(
                    provider: provider,
                    model: model,
                    systemPrompt: systemPrompt,
                    messages: messages,
                    temperature: temperature,
                    stream: stream,
                    includeReasoningParams: useReasoningParams,
                    streamTimeouts: streamTimeouts,
                    onDelta: { delta in
                        if !delta.contentChunk.isEmpty || !delta.reasoningChunk.isEmpty {
                            deltaTracker.emitted = true
                        }
                        onDelta(delta)
                    }
                )
            } catch let err as LLMClientError {
                if deltaTracker.emitted {
                    // Never duplicate streamed partial deltas into the UI consumer
                    throw err
                }
                if case .httpError(let code, let msg) = err {
                    if provider.kind == .evren && code == 403 && !evrenRecovered {
                        let lowerMsg = msg.lowercased()
                        if lowerMsg.contains("term") || lowerMsg.contains("şart") || lowerMsg.contains("accept") {
                            evrenRecovered = true
                            _ = try await acceptEvrenTerms(provider: provider)
                            continue
                        }
                    }
                    if (code == 400 || code == 422) && useReasoningParams {
                        useReasoningParams = false
                        continue
                    }
                    if code == 429 {
                        throw err
                    }
                    let retryable = [502, 503, 504].contains(code)
                    if retryable && attempt < 1 {
                        try Task.checkCancellation()
                        attempt += 1
                        try await Task.sleep(nanoseconds: 900_000_000)
                        try Task.checkCancellation()
                        continue
                    }
                }
                throw err
            } catch {
                if Task.isCancelled { throw error }
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && (ns.code == NSURLErrorCancelled || ns.code == NSURLErrorTimedOut) {
                    throw error
                }
                if deltaTracker.emitted {
                    throw error
                }
                if attempt < 1 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try Task.checkCancellation()
                    continue
                }
                throw error
            }
        }
    }

    private final class StreamProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivityAt = Date()
        private var hasReceivedPayload = false
        private var initialHeaderRecorded = false

        func recordActivity(isContentDelta: Bool) {
            lock.lock()
            if isContentDelta {
                lastActivityAt = Date()
                hasReceivedPayload = true
            } else if !initialHeaderRecorded {
                // Record HTTP header arrival once; subsequent empty keepalive frames must NOT reset first-token timeout
                initialHeaderRecorded = true
                lastActivityAt = Date()
            } else if hasReceivedPayload {
                // Only extend inter-chunk idle window for real metadata/usage frames once content already started
                lastActivityAt = Date()
            }
            lock.unlock()
        }

        func status(now: Date = Date()) -> (idleSeconds: TimeInterval, hasPayload: Bool) {
            lock.lock()
            let idle = now.timeIntervalSince(lastActivityAt)
            let has = hasReceivedPayload
            lock.unlock()
            return (idle, has)
        }
    }

    private struct AccumulatedToolCall {
        var name: String = ""
        var arguments: String = ""
    }

    private static func serializeOpenAIToolCalls(_ map: [Int: AccumulatedToolCall]) -> String {
        guard !map.isEmpty else { return "" }
        let sortedKeys = map.keys.sorted()
        let tags: [String] = sortedKeys.compactMap { idx in
            guard let item = map[idx], !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return PowerShellTools.serializeToolTag(name: item.name, argumentsDict: nil, rawArguments: item.arguments)
        }
        return tags.joined(separator: "\n")
    }

    static func extractNativeToolCallTags(fromMessageDict msg: [String: Any]) -> String {
        guard let rawCalls = msg["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty else { return "" }
        var map: [Int: AccumulatedToolCall] = [:]
        for (idx, tc) in rawCalls.enumerated() {
            let fn = (tc["function"] as? [String: Any]) ?? tc
            let name = (fn["name"] as? String) ?? ""
            let argsStr: String
            if let s = fn["arguments"] as? String {
                argsStr = s
            } else if let obj = fn["arguments"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let s = String(data: data, encoding: .utf8) {
                argsStr = s
            } else {
                argsStr = ""
            }
            map[idx] = AccumulatedToolCall(name: name, arguments: argsStr)
        }
        return serializeOpenAIToolCalls(map)
    }

    private func executeAnthropicChatOnce(
        provider: APIProviderConfig,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        stream: Bool,
        streamTimeouts: (firstToken: TimeInterval, interChunk: TimeInterval)? = nil,
        onDelta: @escaping @Sendable (LLMStreamDelta) -> Void
    ) async throws -> LLMFinalResponse {
        let started = Date()
        var anthropicMsgs: [[String: String]] = []
        for m in messages where !m.content.isEmpty {
            let role = (m.role == "assistant") ? "assistant" : "user"
            if let last = anthropicMsgs.last, last["role"] == role {
                anthropicMsgs[anthropicMsgs.count - 1]["content"] = (last["content"] ?? "") + "\n\n" + m.content
            } else {
                anthropicMsgs.append(["role": role, "content": m.content])
            }
        }
        if anthropicMsgs.isEmpty {
            anthropicMsgs.append(["role": "user", "content": "."])
        }
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "temperature": temperature,
            "messages": anthropicMsgs,
            "stream": stream
        ]
        if !systemPrompt.isEmpty {
            payload["system"] = systemPrompt
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var req = try buildRequest(provider: provider, path: "/messages", method: "POST", body: body)
        req.timeoutInterval = 40

        if !stream {
            let (data, resp) = try await session.data(for: req)
            try validate(resp, data: data, provider: provider)
            return try parseAnthropicJSONResponse(data, fallbackModel: model, started: started, onDelta: onDelta)
        }

        let firstTokenTimeout: TimeInterval = streamTimeouts?.firstToken ?? 35.0
        let interChunkTimeout: TimeInterval = streamTimeouts?.interChunk ?? 30.0
        let tracker = StreamProgressTracker()

        return try await withThrowingTaskGroup(of: LLMFinalResponse.self) { group in
            group.addTask { [self] in
                let (bytes, resp) = try await session.bytes(for: req)
                tracker.recordActivity(isContentDelta: false)
                guard let http = resp as? HTTPURLResponse else { throw LLMClientError.emptyResponse }
                if !(200...299).contains(http.statusCode) {
                    var errBytes = Data()
                    errBytes.reserveCapacity(4096)
                    for try await b in bytes {
                        errBytes.append(b)
                        if errBytes.count >= 16_384 { break }
                    }
                    throw makeHTTPError(http.statusCode, raw: String(decoding: errBytes, as: UTF8.self), provider: provider)
                }

                var fullContent = ""
                var fullReasoning = ""
                var resolvedModel = model
                var usageTotals = (input: 0, output: 0, cached: 0)
                var toolAccum: [Int: AccumulatedToolCall] = [:]

                for try await raw in bytes.lines {
                    try Task.checkCancellation()
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.hasPrefix("data:") else { continue }
                    tracker.recordActivity(isContentDelta: false)
                    let payloadStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if payloadStr.isEmpty || payloadStr == "[DONE]" { continue }
                    guard let d = payloadStr.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let evType = obj["type"] as? String else { continue }

                    switch evType {
                    case "message_start":
                        if let msgObj = obj["message"] as? [String: Any] {
                            if let m = msgObj["model"] as? String, !m.isEmpty { resolvedModel = m }
                            if let u = msgObj["usage"] as? [String: Any] {
                                usageTotals.input = max(usageTotals.input, (u["input_tokens"] as? Int) ?? 0)
                                usageTotals.cached = max(usageTotals.cached, (u["cache_read_input_tokens"] as? Int) ?? 0)
                            }
                        }
                    case "content_block_start":
                        if let idx = obj["index"] as? Int,
                           let cb = obj["content_block"] as? [String: Any],
                           (cb["type"] as? String) == "tool_use",
                           let name = cb["name"] as? String {
                            tracker.recordActivity(isContentDelta: true)
                            toolAccum[idx] = AccumulatedToolCall(name: name, arguments: "")
                        }
                    case "content_block_delta":
                        if let delta = obj["delta"] as? [String: Any],
                           let dt = delta["type"] as? String {
                            if dt == "text_delta", let txt = delta["text"] as? String, !txt.isEmpty {
                                tracker.recordActivity(isContentDelta: true)
                                fullContent += txt
                                onDelta(LLMStreamDelta(contentChunk: txt, reasoningChunk: "", resolvedModel: resolvedModel))
                            } else if dt == "thinking_delta", let th = delta["thinking"] as? String, !th.isEmpty {
                                tracker.recordActivity(isContentDelta: true)
                                fullReasoning += th
                                onDelta(LLMStreamDelta(contentChunk: "", reasoningChunk: th, resolvedModel: resolvedModel))
                            } else if dt == "input_json_delta",
                                      let idx = obj["index"] as? Int,
                                      let pj = delta["partial_json"] as? String {
                                tracker.recordActivity(isContentDelta: true)
                                toolAccum[idx, default: AccumulatedToolCall()].arguments += pj
                            }
                        }
                    case "message_delta":
                        if let u = obj["usage"] as? [String: Any] {
                            usageTotals.output = max(usageTotals.output, (u["output_tokens"] as? Int) ?? 0)
                        }
                    case "error":
                        let errMsg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Anthropic akış hatası"
                        throw makeHTTPError(502, raw: errMsg, provider: provider)
                    default:
                        break
                    }
                }

                let toolTags = Self.serializeOpenAIToolCalls(toolAccum)
                if !toolTags.isEmpty {
                    fullContent = fullContent.isEmpty ? toolTags : (fullContent + "\n" + toolTags)
                }

                let (cleanContent, extractedThink) = splitInlineThinkTags(fullContent)
                let mergedReasoning = [fullReasoning, extractedThink].filter { !$0.isEmpty }.joined(separator: "\n")
                if cleanContent.isEmpty && mergedReasoning.isEmpty { throw LLMClientError.emptyResponse }
                return LLMFinalResponse(
                    content: cleanContent,
                    reasoning: mergedReasoning,
                    resolvedModel: resolvedModel,
                    latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                    inputTokens: usageTotals.input,
                    outputTokens: usageTotals.output,
                    cachedTokens: usageTotals.cached
                )
            }

            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let st = tracker.status()
                    let limit = st.hasPayload ? interChunkTimeout : firstTokenTimeout
                    if st.idleSeconds >= limit {
                        throw LLMClientError.httpError(504, "Claude akışı durdu (\(Int(limit)) sn); sıradaki modele geçiliyor.")
                    }
                }
                throw CancellationError()
            }

            guard let first = try await group.next() else { throw LLMClientError.emptyResponse }
            group.cancelAll()
            return first
        }
    }

    private func parseAnthropicJSONResponse(_ data: Data, fallbackModel: String, started: Date, onDelta: @escaping @Sendable (LLMStreamDelta) -> Void) throws -> LLMFinalResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMClientError.decodingError("Anthropic JSON çözümlenemedi.")
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        var texts: [String] = []
        var thinks: [String] = []
        for b in blocks {
            let t = b["type"] as? String ?? ""
            if t == "text", let txt = b["text"] as? String, !txt.isEmpty {
                texts.append(txt)
            } else if t == "thinking", let th = b["thinking"] as? String, !th.isEmpty {
                thinks.append(th)
            } else if t == "tool_use", let name = b["name"] as? String {
                let inputDict = b["input"] as? [String: Any]
                texts.append(PowerShellTools.serializeToolTag(name: name, argumentsDict: inputDict))
            }
        }
        let content = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = thinks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty && reasoning.isEmpty { throw LLMClientError.emptyResponse }
        let resolved = (obj["model"] as? String) ?? fallbackModel
        let u = obj["usage"] as? [String: Any]
        onDelta(LLMStreamDelta(contentChunk: content, reasoningChunk: reasoning, resolvedModel: resolved))
        return LLMFinalResponse(
            content: content,
            reasoning: reasoning,
            resolvedModel: resolved,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            inputTokens: (u?["input_tokens"] as? Int) ?? 0,
            outputTokens: (u?["output_tokens"] as? Int) ?? 0,
            cachedTokens: (u?["cache_read_input_tokens"] as? Int) ?? 0
        )
    }

    private func executeStreamChatOnce(
        provider: APIProviderConfig,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        stream: Bool,
        includeReasoningParams: Bool = true,
        streamTimeouts: (firstToken: TimeInterval, interChunk: TimeInterval)? = nil,
        onDelta: @escaping @Sendable (LLMStreamDelta) -> Void
    ) async throws -> LLMFinalResponse {
        if Self.isAnthropicAPI(provider) {
            return try await executeAnthropicChatOnce(
                provider: provider,
                model: model,
                systemPrompt: systemPrompt,
                messages: messages,
                temperature: temperature,
                stream: stream,
                streamTimeouts: streamTimeouts,
                onDelta: onDelta
            )
        }
        let started = Date()
        var payloadMsgs: [[String: String]] = []
        if !systemPrompt.isEmpty { payloadMsgs.append(["role": "system", "content": systemPrompt]) }
        for m in messages where !m.content.isEmpty {
            payloadMsgs.append(["role": m.role, "content": m.content])
        }
        var payloadDict: [String: Any] = [
            "model": model,
            "messages": payloadMsgs,
            "temperature": temperature,
            "stream": stream,
            "max_tokens": 8192
        ]
        if includeReasoningParams && Self.usesEvrenReasoningParams(provider: provider, model: model) {
            payloadDict["reasoning_effort"] = "high"
            payloadDict["reasoning"] = [
                "effort": "high",
                "enabled": true
            ]
            payloadDict["include_reasoning"] = true
            payloadDict["max_tokens"] = 16384
        }
        let body = try JSONSerialization.data(withJSONObject: payloadDict)
        var req = try buildRequest(provider: provider, path: "/chat/completions", method: "POST", body: body)
        req.timeoutInterval = 32

        if !stream {
            let (data, resp) = try await session.data(for: req)
            try validate(resp, data: data, provider: provider)
            return try parseJSONResponse(data, provider: provider, fallbackModel: model, started: started, onDelta: onDelta)
        }

        let firstTokenTimeout: TimeInterval = streamTimeouts?.firstToken
            ?? ((provider.kind == .evren || provider.kind == .openRouter || provider.kind == .kilo) ? 35.0 : 25.0)
        let interChunkTimeout: TimeInterval = streamTimeouts?.interChunk ?? 30.0
        let tracker = StreamProgressTracker()

        return try await withThrowingTaskGroup(of: LLMFinalResponse.self) { group in
            group.addTask { [self] in
                let (bytes, resp) = try await session.bytes(for: req)
                tracker.recordActivity(isContentDelta: false)
                guard let http = resp as? HTTPURLResponse else { throw LLMClientError.emptyResponse }
                if !(200...299).contains(http.statusCode) {
                    var errBytes = Data()
                    errBytes.reserveCapacity(4096)
                    for try await b in bytes {
                        errBytes.append(b)
                        if errBytes.count >= 16_384 { break }
                    }
                    let errBody = String(decoding: errBytes, as: UTF8.self)
                    throw makeHTTPError(http.statusCode, raw: errBody, provider: provider)
                }

                var fullContent = ""
                var fullReasoning = ""
                var resolvedModel = model
                var rawFallback = ""
                var sawSSE = false
                var sseDataLines: [String] = []
                var usageTotals = (input: 0, output: 0, cached: 0, reasoning: 0)
                var sseToolCalls: [Int: AccumulatedToolCall] = [:]

                func processSSEPayload(_ payload: String) throws -> Bool {
                    let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedPayload.isEmpty { return false }
                    if trimmedPayload == "[DONE]" { return true }
                    guard let d = trimmedPayload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
                    if let errObj = obj["error"] as? [String: Any],
                       let msg = errObj["message"] as? String {
                        let code = (errObj["code"] as? Int) ?? Int((errObj["code"] as? String) ?? "") ?? 502
                        throw makeHTTPError(code, raw: msg, provider: provider)
                    }
                    if let errStr = obj["error"] as? String, !errStr.isEmpty {
                        throw makeHTTPError(502, raw: errStr, provider: provider)
                    }
                    if let m = obj["model"] as? String, !m.isEmpty { resolvedModel = m }
                    if let u = Self.parseUsageDict(obj["usage"] as? [String: Any]) {
                        usageTotals = (
                            max(usageTotals.input, u.input),
                            max(usageTotals.output, u.output),
                            max(usageTotals.cached, u.cached),
                            max(usageTotals.reasoning, u.reasoning)
                        )
                    }
                    if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
                        let delta = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any]) ?? [:]
                        let c = (delta["content"] as? String) ?? ""
                        var r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
                        if r.isEmpty, let rDetails = delta["reasoning_details"] as? [[String: Any]] {
                            r = rDetails.compactMap { $0["text"] as? String }.joined()
                        }
                        if let tcs = delta["tool_calls"] as? [[String: Any]], !tcs.isEmpty {
                            tracker.recordActivity(isContentDelta: true)
                            for tc in tcs {
                                let idx = (tc["index"] as? Int) ?? 0
                                let fn = (tc["function"] as? [String: Any]) ?? tc
                                if let name = fn["name"] as? String, !name.isEmpty {
                                    sseToolCalls[idx, default: AccumulatedToolCall()].name += name
                                }
                                if let argFrag = fn["arguments"] as? String, !argFrag.isEmpty {
                                    sseToolCalls[idx, default: AccumulatedToolCall()].arguments += argFrag
                                }
                            }
                        }
                        if !c.isEmpty || !r.isEmpty {
                            tracker.recordActivity(isContentDelta: true)
                            fullContent += c
                            fullReasoning += r
                            onDelta(LLMStreamDelta(contentChunk: c, reasoningChunk: r, resolvedModel: resolvedModel))
                        }
                    }
                    return false
                }

                for try await raw in bytes.lines {
                    try Task.checkCancellation()
                    let line = raw.trimmingCharacters(in: .newlines)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        if !sseDataLines.isEmpty {
                            let joined = sseDataLines.joined(separator: "\n")
                            sseDataLines.removeAll(keepingCapacity: true)
                            if try processSSEPayload(joined) { break }
                        }
                        continue
                    }
                    if trimmed.hasPrefix(":") {
                        // SSE keepalive comments must not indefinitely mask an unresponsive upstream model.
                        sawSSE = true
                        continue
                    }
                    if trimmed.hasPrefix("event:") || trimmed.hasPrefix("id:") || trimmed.hasPrefix("retry:") {
                        sawSSE = true
                        continue
                    }
                    if trimmed.hasPrefix("data:") {
                        sawSSE = true
                        tracker.recordActivity(isContentDelta: false)
                        let part = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if part == "[DONE]" {
                            if !sseDataLines.isEmpty {
                                _ = try processSSEPayload(sseDataLines.joined(separator: "\n"))
                                sseDataLines.removeAll()
                            }
                            break
                        }
                        // Try standalone JSON object per data: line immediately for low-latency streaming; buffer multi-line JSON otherwise
                        if sseDataLines.isEmpty,
                           let d = part.data(using: .utf8),
                           (try? JSONSerialization.jsonObject(with: d)) != nil {
                            if try processSSEPayload(part) { break }
                        } else {
                            sseDataLines.append(part)
                        }
                    } else if !sawSSE {
                        tracker.recordActivity(isContentDelta: true)
                        rawFallback += line + "\n"
                    }
                }
                if !sseDataLines.isEmpty {
                    _ = try processSSEPayload(sseDataLines.joined(separator: "\n"))
                }

                if !sawSSE && !rawFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return try parseJSONResponse(Data(rawFallback.utf8), provider: provider, fallbackModel: model, started: started, onDelta: onDelta)
                }

                let nativeToolTags = Self.serializeOpenAIToolCalls(sseToolCalls)
                if !nativeToolTags.isEmpty {
                    fullContent = fullContent.isEmpty ? nativeToolTags : (fullContent + "\n" + nativeToolTags)
                }

                let (cleanContent, extractedThink) = splitInlineThinkTags(fullContent)
                let mergedReasoning = [fullReasoning, extractedThink].filter { !$0.isEmpty }.joined(separator: "\n")
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if cleanContent.isEmpty && mergedReasoning.isEmpty { throw LLMClientError.emptyResponse }
                return LLMFinalResponse(
                    content: cleanContent,
                    reasoning: mergedReasoning,
                    resolvedModel: resolvedModel,
                    latencyMs: ms,
                    inputTokens: usageTotals.input,
                    outputTokens: usageTotals.output,
                    cachedTokens: usageTotals.cached,
                    reasoningTokens: usageTotals.reasoning
                )
            }

            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let st = tracker.status()
                    let limit = st.hasPayload ? interChunkTimeout : firstTokenTimeout
                    if st.idleSeconds >= limit {
                        throw LLMClientError.httpError(
                            504,
                            "Model akışı durdu (\(Int(limit)) sn yanıt gelmedi); diğer modele geçiliyor."
                        )
                    }
                }
                throw CancellationError()
            }

            guard let firstResult = try await group.next() else {
                throw LLMClientError.emptyResponse
            }
            group.cancelAll()
            return firstResult
        }
    }

    func splitInlineThinkTags(_ text: String) -> (content: String, think: String) {
        var remaining = text
        var thoughts: [String] = []

        while let s = remaining.range(of: "<think>") {
            if let e = remaining.range(of: "</think>", range: s.upperBound..<remaining.endIndex) {
                let thought = String(remaining[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !thought.isEmpty { thoughts.append(thought) }
                remaining.removeSubrange(s.lowerBound..<e.upperBound)
            } else {
                let thought = String(remaining[s.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !thought.isEmpty { thoughts.append(thought) }
                remaining.removeSubrange(s.lowerBound..<remaining.endIndex)
                break
            }
        }

        return (remaining.trimmingCharacters(in: .whitespacesAndNewlines), thoughts.joined(separator: "\n"))
    }

    private func parseJSONResponse(_ data: Data, provider: APIProviderConfig, fallbackModel: String, started: Date, onDelta: @escaping @Sendable (LLMStreamDelta) -> Void) throws -> LLMFinalResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMClientError.decodingError("JSON çözümlenemedi.")
        }
        if let errObj = obj["error"] as? [String: Any],
           let msg = errObj["message"] as? String {
            let code = (errObj["code"] as? Int) ?? Int((errObj["code"] as? String) ?? "") ?? 502
            throw makeHTTPError(code, raw: msg, provider: provider)
        }
        if let errStr = obj["error"] as? String, !errStr.isEmpty {
            throw makeHTTPError(502, raw: errStr, provider: provider)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw LLMClientError.decodingError("JSON choices alanı bulunamadı.")
        }
        let msg = (first["message"] as? [String: Any]) ?? [:]
        var rawContent = (msg["content"] as? String) ?? ""
        let nativeTags = Self.extractNativeToolCallTags(fromMessageDict: msg)
        if !nativeTags.isEmpty {
            rawContent = rawContent.isEmpty ? nativeTags : (rawContent + "\n" + nativeTags)
        }
        var rawReasoning = (msg["reasoning_content"] as? String) ?? (msg["reasoning"] as? String) ?? ""
        if rawReasoning.isEmpty, let rDetails = msg["reasoning_details"] as? [[String: Any]] {
            rawReasoning = rDetails.compactMap { $0["text"] as? String }.joined()
        }
        let (cleanContent, thinkPart) = splitInlineThinkTags(rawContent)
        let mergedReasoning = [rawReasoning, thinkPart].filter { !$0.isEmpty }.joined(separator: "\n")
        if cleanContent.isEmpty && mergedReasoning.isEmpty {
            throw LLMClientError.emptyResponse
        }
        let resolved = (obj["model"] as? String) ?? fallbackModel
        let u = Self.parseUsageDict(obj["usage"] as? [String: Any])
        if !cleanContent.isEmpty || !mergedReasoning.isEmpty {
            onDelta(LLMStreamDelta(contentChunk: cleanContent, reasoningChunk: mergedReasoning, resolvedModel: resolved))
        }
        return LLMFinalResponse(
            content: cleanContent,
            reasoning: mergedReasoning,
            resolvedModel: resolved,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000),
            inputTokens: u?.input ?? 0,
            outputTokens: u?.output ?? 0,
            cachedTokens: u?.cached ?? 0,
            reasoningTokens: u?.reasoning ?? 0
        )
    }

    private static func parseUsageDict(_ usage: [String: Any]?) -> (input: Int, output: Int, cached: Int, reasoning: Int)? {
        guard let usage else { return nil }
        let input = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? (usage["input"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? (usage["output"] as? Int) ?? 0
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let compDetails = usage["completion_tokens_details"] as? [String: Any]
        let cached = (usage["cached_tokens"] as? Int) ?? (promptDetails?["cached_tokens"] as? Int) ?? 0
        let reasoning = (usage["reasoning_tokens"] as? Int) ?? (compDetails?["reasoning_tokens"] as? Int) ?? 0
        return (input, output, cached, reasoning)
    }

    private func validate(_ resp: URLResponse, data: Data, provider: APIProviderConfig) throws {
        guard let http = resp as? HTTPURLResponse else { throw LLMClientError.emptyResponse }
        if !(200...299).contains(http.statusCode) {
            throw makeHTTPError(http.statusCode, raw: String(decoding: data, as: UTF8.self), provider: provider)
        }
    }

    private func makeHTTPError(_ code: Int, raw: String, provider: APIProviderConfig) -> LLMClientError {
        var detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let m = err["message"] as? String { detail = m }
            else if let errStr = json["error"] as? String { detail = errStr }
            else if let m = json["detail"] as? String { detail = m }
            else if let m = json["message"] as? String { detail = m }
        }
        if provider.kind == .evren && code == 403 {
            detail += " — İpucu: EVREN kullanım şartları onayı gerekli (Sağlayıcılar sekmesinden onaylayabilirsiniz)."
        }
        return .httpError(code, String(detail.prefix(340)))
    }

    // MARK: - Antigravity CLI (`agy`) Native Backend (Gemini 4 Hydrogen XHigh / IDE Session)

    private static func sanitizedCLIEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAWOFFICE_") {
            env.removeValue(forKey: key)
        }
        env["PATH"] = PowerShellTools.extendedEnvPath()
        return env
    }

    private func fetchAntigravityCLIModels(provider: APIProviderConfig) async throws -> [String] {
        guard let bin = APIProviderConfig.resolveAntigravityCLIPath(hint: provider.normalizedBaseURL) else {
            throw LLMClientError.invalidURL("Antigravity CLI (agy) bulunamadı.")
        }

        final class ProcBox: @unchecked Sendable {
            private let lock = NSLock()
            private var proc: Process?
            func set(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
            func terminate() {
                lock.lock()
                let p = proc
                lock.unlock()
                guard let p, p.isRunning else { return }
                p.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }

        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func fire() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }

        let box = ProcBox()
        let timedOut = OnceFlag()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["models"]
        p.standardInput = FileHandle.nullDevice
        p.environment = Self.sanitizedCLIEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let (exitCode, raw, errText, didTimeout) = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let exitResumeFlag = OnceFlag()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 15.0)
            timer.setEventHandler {
                _ = timedOut.fire()
                box.terminate()
            }
            timer.resume()
            defer {
                timer.cancel()
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
            }

            let outTask = Task.detached(priority: .utility) { () -> String in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data.prefix(65_536), as: UTF8.self)
            }
            let errTask = Task.detached(priority: .utility) { () -> String in
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data.prefix(8_192), as: UTF8.self)
            }

            let status: Int32 = try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { finishedProc in
                    if exitResumeFlag.fire() {
                        cont.resume(returning: finishedProc.terminationStatus)
                    }
                }
                do {
                    try p.run()
                    box.set(p)
                    if Task.isCancelled {
                        box.terminate()
                    }
                } catch {
                    p.terminationHandler = nil
                    if exitResumeFlag.fire() {
                        cont.resume(throwing: error)
                    }
                }
            }

            let outStr = await outTask.value
            let errStr = await errTask.value
            let wasTimedOut = !timedOut.fire()
            return (status, outStr, errStr, wasTimedOut)
        } onCancel: {
            box.terminate()
        }

        try Task.checkCancellation()
        if didTimeout {
            throw LLMClientError.cliError(408, "agy models 15 sn içinde yanıt vermedi.")
        }
        if exitCode != 0 {
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LLMClientError.cliError(exitCode, detail.isEmpty ? "agy models çıkış kodu \(exitCode)" : String(detail.prefix(300)))
        }

        var ids: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let cleanLine = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLine.isEmpty,
                  !cleanLine.lowercased().contains("fetching available models"),
                  let firstToken = cleanLine.split(whereSeparator: { $0.isWhitespace }).first else { continue }
            let id = String(firstToken)
            if id.contains("-") && !ids.contains(id) {
                ids.append(id)
            }
        }
        if ids.isEmpty {
            throw LLMClientError.decodingError("agy models çıktısı okunamadı.")
        }
        return ids
    }

    private func shouldRetryWithoutResume(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let msg = error.localizedDescription.lowercased()
        let fatalMarkers = ["401", "403", "429", "unauthorized", "forbidden", "quota", "rate limit", "model not found", "zaman aşım"]
        if fatalMarkers.contains(where: { msg.contains($0) }) {
            return false
        }
        return true
    }

    private func executeAntigravityCLIChat(
        provider: APIProviderConfig,
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        workspacePath: String?,
        allowLocalEdits: Bool,
        agyConversationId: String? = nil,
        onDelta: @escaping @Sendable (LLMStreamDelta) -> Void
    ) async throws -> LLMFinalResponse {
        guard let bin = APIProviderConfig.resolveAntigravityCLIPath(hint: provider.normalizedBaseURL) else {
            throw LLMClientError.invalidURL("Antigravity CLI (agy) bulunamadı (~/.local/bin/agy).")
        }

        let started = Date()
        let chosenModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (provider.defaultModel.isEmpty ? "gemini-4-hydrogen-xhigh" : provider.defaultModel)
            : model

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let cwd: String
        if let ws = workspacePath, !ws.isEmpty, fm.fileExists(atPath: ws, isDirectory: &isDir), isDir.boolValue {
            cwd = ws
        } else {
            cwd = fm.homeDirectoryForCurrentUser.path
        }

        let cleanResumeId = agyConversationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deltaPrompt = buildAntigravityResumePrompt(messages: messages)
        if let resumeId = cleanResumeId, !resumeId.isEmpty,
           !deltaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                return try await runAntigravityInvocation(
                    bin: bin,
                    prompt: deltaPrompt,
                    chosenModel: chosenModel,
                    cwd: cwd,
                    allowLocalEdits: allowLocalEdits,
                    resumeConversationId: resumeId,
                    started: started,
                    onDelta: onDelta
                )
            } catch {
                if !shouldRetryWithoutResume(error) {
                    throw error
                }
                // Resumed session appears stale/missing; retry once with a fresh session.
            }
        }

        let packagedPrompt = buildAntigravityPrompt(systemPrompt: systemPrompt, messages: messages)
        guard !packagedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMClientError.cliError(400, "Antigravity CLI için boş istem gönderilemez.")
        }
        return try await runAntigravityInvocation(
            bin: bin,
            prompt: packagedPrompt,
            chosenModel: chosenModel,
            cwd: cwd,
            allowLocalEdits: allowLocalEdits,
            resumeConversationId: nil,
            started: started,
            onDelta: onDelta
        )
    }

    private func runAntigravityInvocation(
        bin: String,
        prompt: String,
        chosenModel: String,
        cwd: String,
        allowLocalEdits: Bool,
        resumeConversationId: String?,
        started: Date,
        onDelta: @escaping @Sendable (LLMStreamDelta) -> Void
    ) async throws -> LLMFinalResponse {
        var args: [String] = []
        if let cid = resumeConversationId, !cid.isEmpty {
            args.append(contentsOf: ["--conversation", cid])
        }
        args.append(contentsOf: [
            "-p", prompt,
            "--model", chosenModel,
            "--output-format", "stream-json",
            "--disable-slash-commands"
        ])
        if allowLocalEdits {
            args.append("--dangerously-skip-permissions")
        } else {
            args.append("--sandbox")
        }

        final class ProcessHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?
            func set(_ p: Process) { lock.lock(); process = p; lock.unlock() }
            func terminate() {
                lock.lock()
                let p = process
                lock.unlock()
                guard let p, p.isRunning else { return }
                p.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }

        final class FlagBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = false
            var value: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _value }
                set { lock.lock(); _value = newValue; lock.unlock() }
            }
            func compareAndSetTrue() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if _value { return false }
                _value = true
                return true
            }
        }

        let holder = ProcessHolder()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardInput = FileHandle.nullDevice
        p.environment = Self.sanitizedCLIEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let timedOutBox = FlagBox()
            let stalledBox = FlagBox()
            let lastCLILineLock = NSLock()
            var lastCLIActivityAt = Date()
            func touchCLIActivity() {
                lastCLILineLock.lock()
                lastCLIActivityAt = Date()
                lastCLILineLock.unlock()
            }
            func cliIdleSeconds() -> TimeInterval {
                lastCLILineLock.lock()
                let diff = Date().timeIntervalSince(lastCLIActivityAt)
                lastCLILineLock.unlock()
                return diff
            }

            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 300.0)
            timer.setEventHandler {
                timedOutBox.value = true
                holder.terminate()
            }

            let stallTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            stallTimer.schedule(deadline: .now() + 5.0, repeating: 5.0)
            stallTimer.setEventHandler {
                if cliIdleSeconds() >= 95.0 {
                    stalledBox.value = true
                    holder.terminate()
                }
            }

            final class TerminationBox: @unchecked Sendable {
                private let lock = NSLock()
                private var exitCode: Int32? = nil
                private var waiter: CheckedContinuation<Int32, Never>? = nil

                func complete(_ status: Int32) {
                    lock.lock()
                    if exitCode == nil {
                        exitCode = status
                    }
                    let cont = waiter
                    waiter = nil
                    let code = exitCode ?? status
                    lock.unlock()
                    cont?.resume(returning: code)
                }

                func wait() async -> Int32 {
                    await withCheckedContinuation { cont in
                        lock.lock()
                        if let code = exitCode {
                            lock.unlock()
                            cont.resume(returning: code)
                        } else {
                            waiter = cont
                            lock.unlock()
                        }
                    }
                }
            }

            let termBox = TerminationBox()
            p.terminationHandler = { finishedProc in
                termBox.complete(finishedProc.terminationStatus)
            }

            var errTask: Task<String, Never>? = nil
            defer {
                timer.cancel()
                stallTimer.cancel()
                holder.terminate()
                errTask?.cancel()
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
            }

            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                termBox.complete(-1)
                throw error
            }
            holder.set(p)
            if !p.isRunning {
                termBox.complete(p.terminationStatus)
            }
            touchCLIActivity()
            timer.resume()
            stallTimer.resume()
            if Task.isCancelled {
                holder.terminate()
                throw CancellationError()
            }

            let startedErrTask = Task.detached(priority: .utility) { () -> String in
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data.prefix(16_384), as: UTF8.self)
            }
            errTask = startedErrTask

            var fullContent = ""
            var resultResponse: String? = nil
            var resultError: String? = nil
            var resolvedModel = chosenModel
            var capturedConversationId: String? = resumeConversationId
            var recordedTools: [ToolCallRecord] = []
            var touchedFiles: [String] = []
            var sawToolSinceLastProse = false

            for try await rawLine in outPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                touchCLIActivity()
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("{"),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let eventType = obj["event"] as? String else { continue }

                if let topCid = obj["conversation_id"] as? String, !topCid.isEmpty {
                    capturedConversationId = topCid
                }

                switch eventType {
                case "init":
                    if let initObj = obj["init"] as? [String: Any] {
                        if let m = initObj["model"] as? String, !m.isEmpty {
                            resolvedModel = m
                        }
                        if let cid = (initObj["conversation_id"] as? String) ?? (initObj["session_id"] as? String), !cid.isEmpty {
                            capturedConversationId = cid
                        }
                    }

                case "step_update":
                    guard let su = obj["step_update"] as? [String: Any],
                          let stepType = su["step_type"] as? String else { continue }
                    if let cid = su["conversation_id"] as? String, !cid.isEmpty {
                        capturedConversationId = cid
                    }

                    if stepType == "agent_response" {
                        if let delta = su["text_delta"] as? String, !delta.isEmpty {
                            var chunk = delta
                            if sawToolSinceLastProse && !fullContent.isEmpty && !fullContent.hasSuffix("\n\n") && !delta.hasPrefix("\n") {
                                chunk = "\n\n" + delta
                            }
                            sawToolSinceLastProse = false
                            fullContent += chunk
                            onDelta(LLMStreamDelta(contentChunk: chunk, reasoningChunk: "", resolvedModel: resolvedModel, conversationId: capturedConversationId))
                        }
                    } else if stepType == "tool" {
                        let state = (su["state"] as? String) ?? ""
                        let toolName = (su["tool_name"] as? String) ?? ((su["tool_info"] as? [String: Any])?["name"] as? String) ?? "tool"
                        let toolInfo = su["tool_info"] as? [String: Any] ?? [:]
                        let params = toolInfo["parameters"] as? [String: Any] ?? [:]
                        let argSummary = summarizeToolParams(toolName: toolName, params: params)

                        if state == "ACTIVE" {
                            onDelta(LLMStreamDelta(
                                contentChunk: "",
                                reasoningChunk: "",
                                resolvedModel: resolvedModel,
                                activeToolBubble: "⚡️ \(toolName): \(String(argSummary.prefix(22)))",
                                conversationId: capturedConversationId
                            ))
                        } else if state == "DONE" {
                            sawToolSinceLastProse = true
                            let rawError = toolInfo["error"]
                            let errorString: String? = {
                                if let s = rawError as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    return s
                                }
                                if let dict = rawError as? [String: Any], let m = dict["message"] as? String, !m.isEmpty {
                                    return m
                                }
                                return nil
                            }()
                            let outText = (toolInfo["output"] as? String)
                                ?? errorString
                                ?? (toolInfo["result"] as? String)
                                ?? "(Tamamlandı)"
                            let hasNonNullError: Bool = {
                                guard let rawError, !(rawError is NSNull) else { return false }
                                if errorString != nil { return true }
                                if let s = rawError as? String { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                if let d = rawError as? [String: Any] { return !d.isEmpty }
                                if let b = rawError as? Bool { return b }
                                return true
                            }()
                            let isErr = hasNonNullError || outText.lowercased().contains("error in tool execution")
                            let record = ToolCallRecord(name: toolName, argument: argSummary, output: outText, succeeded: !isErr)
                            recordedTools.append(record)

                            let editToolNames: Set<String> = ["edit_file", "replace_file_content", "multi_replace_file_content", "write_to_file", "write_file", "patch_file"]
                            var touched: String? = nil
                            if !isErr && editToolNames.contains(toolName) {
                                touched = (params["AbsolutePath"] as? String)
                                    ?? (params["Path"] as? String)
                                    ?? (params["path"] as? String)
                                    ?? (params["TargetFile"] as? String)
                                    ?? (params["target_file"] as? String)
                                    ?? (params["file_path"] as? String)
                                    ?? (params["FilePath"] as? String)
                                if let t = touched, !t.isEmpty, !touchedFiles.contains(t) {
                                    touchedFiles.append(t)
                                }
                            }

                            onDelta(LLMStreamDelta(
                                contentChunk: "",
                                reasoningChunk: "",
                                resolvedModel: resolvedModel,
                                activeToolBubble: nil,
                                completedToolCall: record,
                                touchedFilePath: touched,
                                conversationId: capturedConversationId
                            ))
                        }
                    }

                case "result":
                    if let resObj = obj["result"] as? [String: Any] {
                        if let cid = (resObj["conversation_id"] as? String) ?? (resObj["session_id"] as? String), !cid.isEmpty {
                            capturedConversationId = cid
                        }
                        let status = (resObj["status"] as? String)?.uppercased() ?? "SUCCESS"
                        if let respText = resObj["response"] as? String, !respText.isEmpty {
                            resultResponse = respText
                        }
                        if status != "SUCCESS" {
                            resultError = (resObj["error"] as? String)
                                ?? (resObj["message"] as? String)
                                ?? "agy CLI durum: \(status)"
                        }
                    }

                default:
                    break
                }
            }

            let exitStatus = await termBox.wait()
            let errText = await startedErrTask.value

            try Task.checkCancellation()

            if stalledBox.value {
                throw LLMClientError.cliError(408, "Antigravity CLI (agy) 95 sn yanıt vermeden durdu; sıradaki modele geçiliyor.")
            }
            if timedOutBox.value {
                throw LLMClientError.cliError(408, "Antigravity CLI (agy) 300 sn zaman aşımına uğradı.")
            }
            if let rErr = resultError {
                throw LLMClientError.cliError(500, rErr)
            }
            if exitStatus != 0 && fullContent.isEmpty && (resultResponse?.isEmpty ?? true) {
                let errDetail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LLMClientError.cliError(exitStatus, errDetail.isEmpty ? "agy CLI çıkış kodu \(exitStatus)" : String(errDetail.prefix(340)))
            }

            let finalContent = (resultResponse?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? resultResponse!.trimmingCharacters(in: .whitespacesAndNewlines)
                : fullContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if finalContent.isEmpty {
                throw LLMClientError.emptyResponse
            }

            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return LLMFinalResponse(
                content: finalContent,
                reasoning: "",
                resolvedModel: resolvedModel,
                latencyMs: ms,
                toolCalls: recordedTools,
                touchedFiles: touchedFiles,
                agyConversationId: capturedConversationId
            )
        } onCancel: {
            holder.terminate()
        }
    }

    private func buildAntigravityResumePrompt(messages: [ChatMessage]) -> String {
        if let latest = messages.last {
            return String(latest.content.prefix(24000))
        }
        return ""
    }

    private func buildAntigravityPrompt(systemPrompt: String, messages: [ChatMessage]) -> String {
        var parts: [String] = []
        let cleanSys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSys.isEmpty {
            parts.append("[CLAWOFFICE ROL & SİSTEM TALİMATI]\n\(String(cleanSys.prefix(16000)))")
        }

        let summaryMsgs = messages.dropLast().filter { ContextCompactor.isSummaryMessage($0) }
        let nonSummaryTail = messages.filter { !ContextCompactor.isSummaryMessage($0) }
        let recent = Array(nonSummaryTail.suffix(10))

        var contextSections: [String] = []
        if let latestSummary = summaryMsgs.last {
            let cleanSum = latestSummary.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSum.isEmpty {
                contextSections.append(String(cleanSum.prefix(4500)))
            }
        }
        if recent.count > 1 {
            let histLines = recent.dropLast().compactMap { m -> String? in
                let c = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !c.isEmpty else { return nil }
                let roleLabel = m.role == "user" ? "Kullanıcı" : "Ajan"
                return "[\(roleLabel)]: \(String(c.prefix(2400)))"
            }
            contextSections.append(contentsOf: histLines)
        }
        if !contextSections.isEmpty {
            parts.append("[ÖNCEKİ KONUŞMA BAĞLAMI]\n" + contextSections.joined(separator: "\n\n"))
        }

        if let latest = messages.last {
            parts.append("[GÜNCEL GÖREV]\n\(String(latest.content.prefix(24000)))")
        }

        return parts.joined(separator: "\n\n---\n\n")
    }

    private func summarizeToolParams(toolName: String, params: [String: Any]) -> String {
        let priorityKeys = ["TargetFile", "Path", "AbsolutePath", "CommandLine", "Query", "SearchPath", "DirectoryPath", "Description", "CodeItemName"]
        for k in priorityKeys {
            if let v = params[k] as? String, !v.isEmpty {
                return v
            }
        }
        if let firstStr = params.values.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            return firstStr
        }
        return toolName
    }
}
