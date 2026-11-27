import SwiftUI
import AppKit

/// Renders structured Markdown replies safely: headings, lists, tables, blockquotes, inline styles, and copyable code blocks.
struct MarkdownMessageView: View {
    let text: String
    var baseFontSize: CGFloat = 13
    var compact: Bool = false
    var textColor: Color = .primary

    private enum Block: Identifiable {
        case prose(id: Int, text: String)
        case code(id: Int, language: String, code: String)
        case table(id: Int, headers: [String], rows: [[String]])

        var id: Int {
            switch self {
            case .prose(let id, _), .code(let id, _, _), .table(let id, _, _): return id
            }
        }
    }

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            ForEach(blocks) { block in
                switch block {
                case .prose(_, let content):
                    proseBlockView(content)
                case .code(_, let language, let code):
                    MarkdownCodeBlockView(language: language, code: code, compact: compact)
                case .table(_, let headers, let rows):
                    markdownTableView(headers: headers, rows: rows)
                }
            }
        }
    }

    private func parseBlocks(_ raw: String) -> [Block] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var activeFenceChar: Character? = nil
        var activeFenceLen = 0
        var codeLang = ""
        var nextId = 0

        func flushProse() {
            let slicedLines = proseLines
            proseLines.removeAll()
            var idx = 0
            var chunk: [String] = []

            func emitChunk() {
                let joined = chunk.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    blocks.append(.prose(id: nextId, text: joined))
                    nextId += 1
                }
                chunk.removeAll()
            }

            while idx < slicedLines.count {
                let line = slicedLines[idx]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("|") && idx + 1 < slicedLines.count {
                    let nextTrimmed = slicedLines[idx + 1].trimmingCharacters(in: .whitespaces)
                    if isTableSeparatorRow(nextTrimmed) {
                        emitChunk()
                        let headers = parseTableRow(trimmed)
                        idx += 2
                        var rows: [[String]] = []
                        while idx < slicedLines.count {
                            let rowLine = slicedLines[idx].trimmingCharacters(in: .whitespaces)
                            if !rowLine.hasPrefix("|") { break }
                            rows.append(parseTableRow(rowLine))
                            idx += 1
                        }
                        blocks.append(.table(id: nextId, headers: headers, rows: rows))
                        nextId += 1
                        continue
                    }
                }
                chunk.append(line)
                idx += 1
            }
            emitChunk()
        }

        func flushCode() {
            let joined = codeLines.joined(separator: "\n")
            blocks.append(.code(id: nextId, language: codeLang, code: joined))
            nextId += 1
            codeLines.removeAll()
            codeLang = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFenceChar {
                if let first = trimmed.first, first == fence {
                    let runLen = trimmed.prefix(while: { $0 == fence }).count
                    let rest = trimmed.dropFirst(runLen).trimmingCharacters(in: .whitespaces)
                    if runLen >= activeFenceLen && rest.isEmpty {
                        activeFenceChar = nil
                        activeFenceLen = 0
                        flushCode()
                        continue
                    }
                }
                codeLines.append(line)
            } else if let first = trimmed.first, first == "`" || first == "~" {
                let runLen = trimmed.prefix(while: { $0 == first }).count
                if runLen >= 3 {
                    flushProse()
                    activeFenceChar = first
                    activeFenceLen = runLen
                    codeLang = String(trimmed.dropFirst(runLen)).trimmingCharacters(in: .whitespaces)
                } else {
                    proseLines.append(line)
                }
            } else {
                proseLines.append(line)
            }
        }

        if activeFenceChar != nil {
            flushCode()
        } else {
            flushProse()
        }
        return blocks
    }

    private func isTableSeparatorRow(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("|") else { return false }
        let stripped = trimmed.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces)
        return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }

    private func parseTableRow(_ trimmed: String) -> [String] {
        var row = trimmed
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private enum ProseElement: Identifiable {
        case spacer(id: Int)
        case divider(id: Int)
        case heading(id: Int, level: Int, text: String)
        case quote(id: Int, text: String)
        case listItem(id: Int, marker: String, text: String, indent: Int)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .spacer(let id), .divider(let id), .heading(let id, _, _), .quote(let id, _), .listItem(let id, _, _, _), .paragraph(let id, _):
                return id
            }
        }
    }

    @ViewBuilder
    private func proseBlockView(_ content: String) -> some View {
        let elements = buildProseElements(from: content)
        VStack(alignment: .leading, spacing: compact ? 2.5 : 4) {
            ForEach(elements) { elem in
                switch elem {
                case .spacer:
                    Spacer().frame(height: compact ? 1.5 : 3)
                case .divider:
                    Divider().padding(.vertical, compact ? 1.5 : 3)
                case .heading(_, let level, let text):
                    let delta: CGFloat = level == 1 ? (compact ? 2.5 : 4) : (level == 2 ? (compact ? 1.5 : 2.5) : (level == 3 ? 1 : 0))
                    inlineText(text)
                        .font(.system(size: baseFontSize + delta, weight: .bold))
                        .foregroundStyle(textColor)
                        .padding(.top, compact ? (level <= 2 ? 2.5 : 1.5) : (level <= 2 ? 5 : 3))
                case .quote(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 3)
                        inlineText(text)
                            .font(.system(size: baseFontSize - 0.5))
                            .foregroundStyle(textColor.opacity(0.9))
                    }
                    .padding(.vertical, 2)
                case .listItem(_, let marker, let text, let indent):
                    HStack(alignment: .top, spacing: 6) {
                        if indent > 0 {
                            Spacer().frame(width: CGFloat(indent * 12))
                        }
                        Text(marker)
                            .font(.system(size: baseFontSize, weight: .semibold))
                            .foregroundStyle(textColor.opacity(0.75))
                        inlineText(text)
                            .font(.system(size: baseFontSize))
                            .foregroundStyle(textColor)
                    }
                case .paragraph(_, let text):
                    inlineText(text)
                        .font(.system(size: baseFontSize))
                        .foregroundStyle(textColor)
                }
            }
        }
    }

    private func buildProseElements(from content: String) -> [ProseElement] {
        let lines = content.components(separatedBy: "\n")
        var elements: [ProseElement] = []
        var paragraphBuffer: [String] = []
        var nextId = 0

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            elements.append(.paragraph(id: nextId, text: paragraphBuffer.joined(separator: "\n")))
            nextId += 1
            paragraphBuffer.removeAll()
        }

        for line in lines {
            let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                elements.append(.spacer(id: nextId))
                nextId += 1
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                elements.append(.divider(id: nextId))
                nextId += 1
            } else if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                    flushParagraph()
                    let headingText = String(trimmed.dropFirst(hashes + 1))
                    elements.append(.heading(id: nextId, level: hashes, text: headingText))
                    nextId += 1
                    continue
                }
                paragraphBuffer.append(line)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                elements.append(.quote(id: nextId, text: String(trimmed.dropFirst(2))))
                nextId += 1
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                elements.append(.listItem(id: nextId, marker: "•", text: String(trimmed.dropFirst(2)), indent: leadingSpaces / 2))
                nextId += 1
            } else if let dotRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let numMarker = String(trimmed[..<dotRange.upperBound]).trimmingCharacters(in: .whitespaces)
                let body = String(trimmed[dotRange.upperBound...])
                elements.append(.listItem(id: nextId, marker: numMarker, text: body, indent: leadingSpaces / 2))
                nextId += 1
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        return elements
    }

    @ViewBuilder
    private func markdownTableView(headers: [String], rows: [[String]]) -> some View {
        let colCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if colCount > 0 {
            let cellHPad: CGFloat = compact ? 8 : 10
            let cellVPad: CGFloat = compact ? 4 : 5
            let minColWidth: CGFloat = compact ? 76 : 90
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<colCount, id: \.self) { cIdx in
                            let title = cIdx < headers.count ? headers[cIdx] : ""
                            inlineText(title)
                                .font(.system(size: baseFontSize - 1, weight: .bold))
                                .padding(.horizontal, cellHPad).padding(.vertical, compact ? 5 : 6)
                                .frame(minWidth: minColWidth, maxWidth: compact ? 220 : 280, alignment: .leading)
                        }
                    }
                    .background(Color.primary.opacity(0.08))
                    Divider()
                        .gridCellUnsizedAxes([.horizontal])
                    ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                        GridRow {
                            ForEach(0..<colCount, id: \.self) { cIdx in
                                let cell = cIdx < row.count ? row[cIdx] : ""
                                inlineText(cell)
                                    .font(.system(size: baseFontSize - 1))
                                    .padding(.horizontal, cellHPad).padding(.vertical, cellVPad)
                                    .frame(minWidth: minColWidth, maxWidth: compact ? 220 : 280, alignment: .leading)
                            }
                        }
                        .background(rIdx % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear)
                    }
                }
                .foregroundStyle(textColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8))
            }
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if let attr = try? AttributedString(markdown: raw, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(raw)
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String
    let code: String
    let compact: Bool
    @State private var copied = false
    @State private var isExpanded: Bool

    private var lineCount: Int {
        max(1, code.components(separatedBy: "\n").count)
    }

    private var isCollapsible: Bool {
        lineCount > 5 || code.count > 240
    }

    init(language: String, code: String, compact: Bool = false) {
        self.language = language
        self.code = code
        self.compact = compact
        let lines = max(1, code.components(separatedBy: "\n").count)
        let shouldCollapse = compact ? (lines > 5 || code.count > 240) : (lines > 14 || code.count > 900)
        _isExpanded = State(initialValue: !shouldCollapse)
    }

    var body: some View {
        SmokedGlassSurface(cornerRadius: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.75)).frame(width: 7, height: 7)
                    Circle().fill(Color.yellow.opacity(0.75)).frame(width: 7, height: 7)
                    Circle().fill(Color.green.opacity(0.75)).frame(width: 7, height: 7)
                    Text("\(language.isEmpty ? "kod" : language) · \(lineCount) satır")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                    Spacer()
                    if isCollapsible {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(isExpanded ? "Daralt" : "Göster").font(.system(size: 9))
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 8.5))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9))
                            Text(copied ? "Kopyalandı ✓" : "Kopyala").font(.system(size: 9))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((copied ? Color.green : Color.white).opacity(copied ? 0.22 : 0.08), in: Capsule())
                        .foregroundStyle(copied ? Color.green : .white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.white.opacity(0.04))

                if isExpanded {
                    let codeText = Text(code)
                        .font(.system(size: compact ? 11 : 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 0.86, green: 0.94, blue: 1.0))
                        .textSelection(.enabled)
                        .padding(compact ? 8 : 10)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isCollapsible {
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            codeText
                        }
                        .frame(maxHeight: compact ? 150 : 220)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            codeText
                        }
                    }
                }
            }
        }
    }
}
