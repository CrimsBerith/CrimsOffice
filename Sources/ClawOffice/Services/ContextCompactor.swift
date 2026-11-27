import Foundation

/// Compacts long agent conversations and in-turn ReAct tool traces without dropping core goals or file/tool history.
enum ContextCompactor: Sendable {
    static let summaryHeader = "[OTOMATİK BAĞLAM ÖZETİ — AUTO-COMPACT]"
    static let reactSummaryHeader = "[RE-ACT ADIM ÖZETİ — AUTO-COMPACT]"

    struct CompactionResult: Sendable {
        let messages: [ChatMessage]
        let summaryText: String
        let compactedMessageCount: Int
        let originalCharCount: Int
        let finalCharCount: Int

        var didCompact: Bool {
            compactedMessageCount > 0 || finalCharCount < originalCharCount
        }
    }

    static func estimatedChars(of messages: [ChatMessage]) -> Int {
        messages.reduce(0) { sum, m in
            let toolCost = m.toolCalls.reduce(0) { $0 + $1.name.count + min(120, $1.argument.count) + 16 }
            return sum + m.content.count + toolCost + 24
        }
    }

    static func estimatedTokens(of text: String) -> Int {
        max(1, text.count / 3)
    }

    static func isContextOverflowError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        let markers = [
            "context length",
            "context_length",
            "maximum context",
            "too many tokens",
            "token limit",
            "max_tokens",
            "prompt is too long",
            "exceeds the model",
            "payload too large",
            "request too large",
            "http 413"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func isSummaryMessage(_ message: ChatMessage) -> Bool {
        let t = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix(summaryHeader) || t.hasPrefix(reactSummaryHeader)
    }

    /// Compacts persistent or turn-start chat history while preserving the initial objective, tool/file ledger, and recent turns.
    static func compactHistory(
        _ messages: [ChatMessage],
        charBudget: Int = 24_000,
        keepRecentCount: Int = 8,
        force: Bool = false,
        customLLMSummary: String? = nil
    ) -> CompactionResult {
        let originalChars = estimatedChars(of: messages)
        guard !messages.isEmpty else {
            return CompactionResult(messages: [], summaryText: "", compactedMessageCount: 0, originalCharCount: 0, finalCharCount: 0)
        }

        let safeKeep = max(2, keepRecentCount)
        if !force && messages.count <= safeKeep + 1 && originalChars <= charBudget {
            return CompactionResult(
                messages: messages,
                summaryText: "",
                compactedMessageCount: 0,
                originalCharCount: originalChars,
                finalCharCount: originalChars
            )
        }

        let existingSummaries = messages.filter { isSummaryMessage($0) }
        let nonSummaryMessages = messages.filter { !isSummaryMessage($0) }

        if nonSummaryMessages.count <= safeKeep && !force && originalChars <= charBudget {
            return CompactionResult(
                messages: messages,
                summaryText: "",
                compactedMessageCount: 0,
                originalCharCount: originalChars,
                finalCharCount: originalChars
            )
        }

        let splitIndex = max(0, nonSummaryMessages.count - safeKeep)
        let middle = Array(nonSummaryMessages.prefix(splitIndex))
        var recent = Array(nonSummaryMessages.suffix(nonSummaryMessages.count - splitIndex))
        let initialUserGoal = nonSummaryMessages.first(where: {
            $0.role == "user"
            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[ARAÇ VE İŞLEM ÇIKTILARI")
            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[OTONOM SÜREKLİLİK")
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalInRecent = initialUserGoal.map { g in
            recent.contains { $0.role == "user" && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == g }
        } ?? true

        let summaryBody: String
        if let llmSum = customLLMSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !llmSum.isEmpty {
            summaryBody = """
            \(summaryHeader)
            \(llmSum)
            """
        } else {
            summaryBody = buildStructuredSummary(
                header: summaryHeader,
                existingSummaries: existingSummaries,
                olderMessages: middle,
                pinnedGoal: goalInRecent ? nil : initialUserGoal,
                maxSummaryChars: max(2200, charBudget / 3)
            )
        }

        recent = fitRecentMessages(recent, remainingBudget: max(4_000, charBudget - summaryBody.count))

        var output: [ChatMessage] = []
        if !middle.isEmpty || !existingSummaries.isEmpty || (customLLMSummary?.isEmpty == false) {
            output.append(ChatMessage(
                role: "user",
                content: summaryBody,
                modelUsed: "auto-compact",
                providerName: "ContextCompactor"
            ))
        }
        output.append(contentsOf: recent)

        let finalChars = estimatedChars(of: output)
        return CompactionResult(
            messages: output,
            summaryText: summaryBody,
            compactedMessageCount: middle.count,
            originalCharCount: originalChars,
            finalCharCount: finalChars
        )
    }

    /// Compacts in-turn ReAct messages while keeping the turn's original prompt pinned at index 0.
    static func compactReActHistory(
        _ messages: [ChatMessage],
        originalUserPrompt: String,
        charBudget: Int = 32_000,
        keepRecent: Int = 6
    ) -> CompactionResult {
        let originalChars = estimatedChars(of: messages)
        guard !messages.isEmpty else {
            return CompactionResult(messages: [], summaryText: "", compactedMessageCount: 0, originalCharCount: 0, finalCharCount: 0)
        }

        let cleanGoal = originalUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeKeep = max(2, keepRecent)

        if messages.count <= safeKeep + 2 && originalChars <= charBudget {
            return CompactionResult(
                messages: messages,
                summaryText: "",
                compactedMessageCount: 0,
                originalCharCount: originalChars,
                finalCharCount: originalChars
            )
        }

        let existingSummaries = messages.filter { isSummaryMessage($0) }
        let nonSummary = messages.filter { !isSummaryMessage($0) }

        // Pin original goal as first user message if it isn't already covered inside recent tail.
        let recentCount = min(safeKeep, nonSummary.count)
        let splitIdx = max(0, nonSummary.count - recentCount)
        let middle = Array(nonSummary.prefix(splitIdx))
        var recent = Array(nonSummary.suffix(recentCount))

        let goalAlreadyInRecent = !cleanGoal.isEmpty && recent.contains {
            $0.role == "user" && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == cleanGoal
        }

        let summaryBody = buildStructuredSummary(
            header: reactSummaryHeader,
            existingSummaries: existingSummaries,
            olderMessages: middle,
            pinnedGoal: goalAlreadyInRecent ? nil : cleanGoal,
            maxSummaryChars: max(2400, charBudget / 3)
        )

        var output: [ChatMessage] = []
        let pinnedGoalMsg: ChatMessage? = (!goalAlreadyInRecent && !cleanGoal.isEmpty)
            ? ChatMessage(role: "user", content: "[ANA GÖREV HEDEFİ]\n\(clipMiddleText(cleanGoal, maxChars: 3500))")
            : nil

        let reservedChars = summaryBody.count + (pinnedGoalMsg?.content.count ?? 0)
        recent = fitRecentMessages(recent, remainingBudget: max(4_500, charBudget - reservedChars))

        if let pinnedGoalMsg {
            output.append(pinnedGoalMsg)
        }
        if !middle.isEmpty || !existingSummaries.isEmpty {
            output.append(ChatMessage(
                role: "user",
                content: summaryBody,
                modelUsed: "auto-compact",
                providerName: "ContextCompactor"
            ))
        }
        output.append(contentsOf: recent)

        let finalChars = estimatedChars(of: output)
        return CompactionResult(
            messages: output,
            summaryText: summaryBody,
            compactedMessageCount: middle.count,
            originalCharCount: originalChars,
            finalCharCount: finalChars
        )
    }

    /// Compacts multi-round debate transcript while preserving the meeting topic and early speaker positions.
    static func compactDebateTranscript(_ transcript: String, goal: String, maxChars: Int = 12_000) -> String {
        guard transcript.count > maxChars else { return transcript }

        let blocks = transcript.components(separatedBy: "\n\n[")
        guard blocks.count > 3 else {
            return "TOPLANTI KONUSU: \(goal)\n\n...[önceki bölüm özetlendi]...\n\n" + String(transcript.suffix(max(2000, maxChars - 300)))
        }

        var olderBullets: [String] = []
        var keptTail: [String] = []
        var tailChars = 0
        let tailBudget = Int(Double(maxChars) * 0.62)

        for block in blocks.dropFirst().reversed() {
            let formatted = "[" + block
            if tailChars + formatted.count <= tailBudget || keptTail.count < 2 {
                keptTail.insert(formatted, at: 0)
                tailChars += formatted.count + 2
            } else {
                let firstLine = formatted.components(separatedBy: .newlines).first ?? ""
                let bodyLines = formatted.components(separatedBy: .newlines).dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(2)
                    .joined(separator: " ")
                olderBullets.insert("• \(firstLine) \(String(bodyLines.prefix(180)))", at: 0)
            }
        }

        let summaryBlock = olderBullets.isEmpty
            ? ""
            : "\n\n[ÖNCEKİ TURLARIN ÖZETİ]:\n" + olderBullets.suffix(12).joined(separator: "\n")
        return "TOPLANTI KONUSU: \(goal)\(summaryBlock)\n\n" + keptTail.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private static func buildStructuredSummary(
        header: String,
        existingSummaries: [ChatMessage],
        olderMessages: [ChatMessage],
        pinnedGoal: String?,
        maxSummaryChars: Int
    ) -> String {
        var userDirectives: [String] = []
        var toolLedger: [String] = []
        var keyFindings: [String] = []
        var carriedSummaryLines: [String] = []

        for s in existingSummaries {
            let lines = s.content.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[OTOMATİK BAĞLAM") && !$0.hasPrefix("[RE-ACT ADIM") }
            carriedSummaryLines.append(contentsOf: lines)
        }

        for m in olderMessages {
            let clean = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if m.role == "user" {
                if clean.hasPrefix("[ARAÇ VE İŞLEM ÇIKTILARI") {
                    let toolHeaders = clean.components(separatedBy: .newlines)
                        .filter { $0.hasPrefix("[") && !$0.hasPrefix("[ARAÇ VE") && !$0.hasPrefix("[DİSİPLİNLİ") && !$0.hasPrefix("[NİHAİ") }
                    for h in toolHeaders.prefix(4) {
                        let entry = String(h.prefix(120))
                        if !toolLedger.contains(entry) { toolLedger.append(entry) }
                    }
                } else if clean.hasPrefix("[OTONOM SÜREKLİLİK") || clean.hasPrefix("[ANA GÖREV HEDEFİ]") {
                    continue
                } else if !clean.isEmpty {
                    let condensed = clean.replacingOccurrences(of: "\n", with: " ")
                    userDirectives.append("• " + String(condensed.prefix(200)))
                }
            } else {
                for tc in m.toolCalls {
                    let status = tc.succeeded ? "✓" : "✗"
                    let line = "\(status) \(tc.name)(\(String(tc.argument.replacingOccurrences(of: "\n", with: " ").prefix(70))))"
                    if !toolLedger.contains(line) { toolLedger.append(line) }
                }
                let stripped = PowerShellTools.stripToolTags(from: clean)
                if !stripped.isEmpty {
                    let important = stripped.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter {
                            !$0.isEmpty
                            && !$0.hasPrefix("⚡️ Araçlar")
                            && !$0.hasPrefix("⚡️ *Araç")
                            && ($0.hasPrefix("###") || $0.hasPrefix("- ") || $0.hasPrefix("✅") || $0.hasPrefix("⚠️") || $0.count > 24)
                        }
                        .prefix(2)
                        .joined(separator: " | ")
                    if !important.isEmpty {
                        keyFindings.append("• " + String(important.prefix(210)))
                    }
                }
            }
        }

        var sections: [String] = [header]
        let carriedGoal = carriedSummaryLines.first(where: { $0.hasPrefix("Ana Hedef:") })
        if let g = pinnedGoal, !g.isEmpty {
            sections.append("Ana Hedef: " + String(g.replacingOccurrences(of: "\n", with: " ").prefix(280)))
        } else if let cg = carriedGoal {
            sections.append(cg)
        }
        let nonGoalCarried = carriedSummaryLines.filter { !$0.hasPrefix("Ana Hedef:") }
        if !nonGoalCarried.isEmpty {
            sections.append("Önceki Özet:\n" + nonGoalCarried.suffix(14).joined(separator: "\n"))
        }
        if !userDirectives.isEmpty {
            sections.append("Kullanıcı İstekleri:\n" + userDirectives.suffix(6).joined(separator: "\n"))
        }
        if !toolLedger.isEmpty {
            sections.append("Yürütülen Araç & Dosya İşlemleri:\n" + toolLedger.suffix(14).joined(separator: "\n"))
        }
        if !keyFindings.isEmpty {
            sections.append("Kilit Bulgular & Kararlar:\n" + keyFindings.suffix(8).joined(separator: "\n"))
        }

        let joined = sections.joined(separator: "\n\n")
        if joined.count > maxSummaryChars {
            return String(joined.prefix(maxSummaryChars)) + "\n... [özet kırpıldı]"
        }
        return joined
    }

    private static func fitRecentMessages(_ recent: [ChatMessage], remainingBudget: Int) -> [ChatMessage] {
        var result = recent
        var total = estimatedChars(of: result)
        guard total > remainingBudget else { return result }

        // Pass 1: clip oversized messages individually, keeping final message generous
        for i in result.indices {
            if total <= remainingBudget { break }
            let isLast = (i == result.count - 1)
            let cap = isLast ? max(2000, remainingBudget / 2) : 1600
            if result[i].content.count > cap {
                let oldLen = result[i].content.count
                result[i].content = clipMiddleText(result[i].content, maxChars: cap)
                total -= max(0, oldLen - result[i].content.count)
            }
        }

        // Pass 2: if aggregate size still exceeds budget, shrink older messages harder (down to 420 chars)
        if total > remainingBudget {
            for i in result.indices.dropLast() {
                if total <= remainingBudget { break }
                if result[i].content.count > 420 {
                    let oldLen = result[i].content.count
                    result[i].content = clipMiddleText(result[i].content, maxChars: 420)
                    total -= max(0, oldLen - result[i].content.count)
                }
            }
        }

        // Pass 3: drop oldest non-final turns if many recent messages keep aggregate over tight overflow budget
        while total > remainingBudget && result.count > 2 {
            result.removeFirst()
            total = estimatedChars(of: result)
        }
        return result
    }

    private static func clipMiddleText(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars, maxChars > 200 else { return text }
        let head = Int(Double(maxChars) * 0.62)
        let tail = max(60, maxChars - head - 32)
        return String(text.prefix(head)) + "\n... [bağlam sıkıştırıldı] ...\n" + String(text.suffix(tail))
    }
}
