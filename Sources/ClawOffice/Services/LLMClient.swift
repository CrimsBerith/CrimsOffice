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
            return (false, 0, "Antigravity CLI artık desteklenmiyor.")
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
            throw LLMClientError.invalidURL("Antigravity CLI artık desteklenmiyor.")
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

    /// Public entry with retry before first emitted delta + EVREN 403 terms recovery
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
            throw LLMClientError.invalidURL("Antigravity CLI artık desteklenmiyor.")
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

    // MARK: - (Antigravity CLI kaldırıldı)

}