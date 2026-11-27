import Foundation
import AppKit
import Darwin

struct CLIToolStatus: Sendable {
    var rtkInstalled: Bool = false
    var rtkPath: String = ""
    var graphifyInstalled: Bool = false
    var graphifyPath: String = ""
    var openClawInstalled: Bool = false
    var openClawGatewayOnline: Bool = false
    var repomixInstalled: Bool = false
    var brewInstalled: Bool = false
    var uvInstalled: Bool = false
}

struct ParsedToolCall: Sendable {
    let name: String
    let argument: String
}

struct LocalToolResult: Sendable {
    let toolName: String
    let commandUsed: String
    let usedRTK: Bool
    let output: String
    let succeeded: Bool
    let editRecord: FileEditRecord?
}

enum OpenClawWorkspaceService {
    static let standardFiles = ["AGENTS.md", "SOUL.md", "USER.md", "MEMORY.md", "TOOLS.md", "HEARTBEAT.md"]

    static func ensureOpenClawWorkspaceExists(at path: String) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: path)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("skills"), withIntermediateDirectories: true)

        let defaults: [String: String] = [
            "AGENTS.md": """
            # AGENTS.md — ClawOffice v4 Çalışma Kılavuzu

            ## Mimari & İlkeler
            - Değişiklik yapmadan önce proje yapısını veya `graphify-out/GRAPH_REPORT.md` dosyasını incele.
            - Dosya düzenlerken `patch_file` veya `write_file` aracını kullan; her düzenlemeden önce otomatik yedek alınır.
            - Değişiklik sonrası mutlaka derleme/test doğrulaması (`swift build`, `npm run build`, `pytest` vb.) çalıştır.
            - Komut çıktılarını minimum token tüketmek için `rtk` proxy ile çalıştır.
            """,
            "SOUL.md": """
            # SOUL.md — Ekip Karakteri
            - Net, teknik, dürüst ve iş birliğine açık ol.
            - Farklı bir uzmanlık gerektiğinde ekip arkadaşına (`delegate`) iş devretmekten çekinme.
            - Hata yakaladığında kök nedeni açıkla ve bir sonraki görevde tekrarlanmaması için ders çıkar.
            """,
            "USER.md": """
            # USER.md — Kullanıcı Tercihleri
            - Birincil geliştirme ortamı: macOS + VS Code / Xcode
            - Yanıt dili: Türkçe (kod ve teknik terimler orijinal)
            """,
            "MEMORY.md": """
            # MEMORY.md — Uzun Süreli Kalıcı Hafıza & Öğrenilen Dersler
            - ClawOffice v4 (Canlı Ekip İletişimi + Otonom Proje Geliştirme + Öz-Gelişim) başlatıldı.
            """,
            "TOOLS.md": """
            # TOOLS.md — Yerel Araç Notları
            - `rtk`: Terminal çıktılarında %60-90 token tasarrufu sağlayan CLI proxy.
            - `graphify`: Proje bilgi grafı (`graphify-out/GRAPH_REPORT.md` & `graph.json`).
            - `.clawoffice-backups/`: Ajanların yaptığı her dosya değişikliğinin geri alınabilir yedeği.
            """,
            "HEARTBEAT.md": """
            # HEARTBEAT.md — Periyodik Sağlık & Gelişim Kontrolü
            - API sağlayıcılarının (Kilo, EVREN) bağlantısını, günlük `memory/` özetlerini ve proje derleme durumunu kontrol et.
            """
        ]

        for (name, body) in defaults {
            let fileURL = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: fileURL.path) {
                try? body.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    static func readFile(named filename: String, in directory: String) -> String {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func writeFile(named filename: String, content: String, in directory: String) throws {
        let dir = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    /// Appends a distilled self-improvement lesson to both MEMORY.md and daily memory/YYYY-MM-DD.md
    static func appendLearnedLesson(_ lesson: String, source: String, openClawHome: String) {
        let clean = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: Date())

        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let clock = tf.string(from: Date())

        let entry = "\n- [\(day) \(clock) · \(source)] \(clean)"

        // 1. Append to MEMORY.md (trim whole leading lines so markdown entries stay intact)
        var mem = readFile(named: "MEMORY.md", in: openClawHome)
        if mem.isEmpty { mem = "# MEMORY.md — Kalıcı Hafıza\n" }
        mem += entry + "\n"
        if mem.count > 18000 {
            let header = "# MEMORY.md — Kalıcı Hafıza\n"
            var lines = mem.components(separatedBy: "\n").drop(while: { $0.hasPrefix("# MEMORY.md") || $0.isEmpty })
            while lines.joined(separator: "\n").count > 15500 && lines.count > 1 {
                lines.removeFirst()
            }
            mem = header + lines.joined(separator: "\n")
        }
        try? writeFile(named: "MEMORY.md", content: mem, in: openClawHome)

        // 2. Append to daily memory/YYYY-MM-DD.md
        let dailyDir = URL(fileURLWithPath: openClawHome).appendingPathComponent("memory")
        try? FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let dailyURL = dailyDir.appendingPathComponent("\(day).md")
        var daily = (try? String(contentsOf: dailyURL, encoding: .utf8)) ?? "# Günlük Ekip Hafızası — \(day)\n"
        daily += entry + "\n"
        try? daily.write(to: dailyURL, atomically: true, encoding: .utf8)
    }

    /// Assembles SOUL, USER, and the newest MEMORY lessons within a balanced character budget so recent lessons are never truncated.
    static func assembleMemoryContext(openClawHome: String) -> String {
        let soul = readFile(named: "SOUL.md", in: openClawHome).trimmingCharacters(in: .whitespacesAndNewlines)
        let user = readFile(named: "USER.md", in: openClawHome).trimmingCharacters(in: .whitespacesAndNewlines)
        let mem = readFile(named: "MEMORY.md", in: openClawHome).trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if !soul.isEmpty {
            parts.append(soul.count > 900 ? String(soul.prefix(900)) + "\n..." : soul)
        }
        if !user.isEmpty {
            parts.append(user.count > 700 ? String(user.prefix(700)) + "\n..." : user)
        }
        if !mem.isEmpty {
            if mem.count > 1600 {
                parts.append("# MEMORY.md (En Güncel Dersler)\n...\n" + String(mem.suffix(1500)))
            } else {
                parts.append(mem)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Saves a newly evolved OpenClaw SKILL.md created by the agents during Self-Improvement
    static func saveEvolvedSkill(
        slug: String,
        name: String,
        description: String,
        body: String,
        openClawHome: String,
        triggers: [String] = []
    ) throws -> String {
        let ascii = slug
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeSlug = ascii.isEmpty ? "evolved-skill-\(Int(Date().timeIntervalSince1970) % 10000)" : ascii
        let safeName = name.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "---", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDesc = description.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "---", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTriggers = Array(Set(triggers
            .map { $0.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " \"'[],")) }
            .filter { !$0.isEmpty }
        )).sorted()
        let triggersLine = cleanTriggers.isEmpty ? "" : "\ntriggers: [\(cleanTriggers.joined(separator: ", "))]"

        let skillDir = URL(fileURLWithPath: openClawHome).appendingPathComponent("skills").appendingPathComponent(safeSlug)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let md = """
        ---
        name: \(safeName.isEmpty ? safeSlug : safeName)
        description: \(safeDesc)\(triggersLine)
        ---
        \(body)
        """
        let fileURL = skillDir.appendingPathComponent("SKILL.md")
        try md.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    static func deleteCustomSkill(at sourcePath: String, openClawHome: String) throws {
        guard sourcePath != "Dahili" else {
            throw NSError(domain: "ClawOfficeSkill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dahili sistem becerileri silinemez; yanındaki anahtardan kapatabilirsiniz."])
        }
        let skillFile = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let skillDir = skillFile.deletingLastPathComponent()
        let allowedRoots = [
            URL(fileURLWithPath: openClawHome).appendingPathComponent("skills").standardizedFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/skills").standardizedFileURL.path
        ]
        let isInsideAllowedRoot = allowedRoots.contains { root in
            skillDir.path.hasPrefix(root + "/")
        }
        guard isInsideAllowedRoot else {
            throw NSError(domain: "ClawOfficeSkill", code: 2, userInfo: [NSLocalizedDescriptionKey: "Güvenlik gereği yalnızca OpenClaw skills klasöründeki özel beceriler silinebilir."])
        }
        try FileManager.default.removeItem(at: skillDir)
    }

    static func discoverProjectAgentsMD(workspacePath: String) -> [(relativePath: String, content: String)] {
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL
        var results: [(String, String)] = []
        for t in ["AGENTS.md", "CLAUDE.md"] {
            let url = root.appendingPathComponent(t)
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append((t, text))
            }
        }
        if let subdirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for sub in subdirs.prefix(25) {
                let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir { continue }
                let nested = sub.appendingPathComponent("AGENTS.md")
                if let text = try? String(contentsOf: nested, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append(("\(sub.lastPathComponent)/AGENTS.md", text))
                }
            }
        }
        return results
    }

    static func discoverSkills(openClawHome: String, workspacePath: String) -> [AgentSkill] {
        var found: [String: AgentSkill] = [:]
        for builtIn in builtInSkills() { found[builtIn.id] = builtIn }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [openClawHome + "/skills", home + "/.openclaw/skills", workspacePath + "/skills", workspacePath + "/.claude/skills"]
        let fm = FileManager.default

        for rootPath in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: rootPath) else { continue }
            for item in items {
                let skillFile = URL(fileURLWithPath: rootPath).appendingPathComponent(item).appendingPathComponent("SKILL.md")
                guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                var parsed = parseSkillMarkdown(slug: item, raw: raw, path: skillFile.path)
                if let existing = found[parsed.id] {
                    // Diskteki SKILL.md dahili beceriyi güncellerken zengin tetikleyicileri ve varsayılan aktifliği korur
                    parsed.triggers = Array(Set(existing.triggers + parsed.triggers)).sorted()
                    parsed.isEnabled = existing.isEnabled
                }
                found[parsed.id] = parsed
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseSkillMarkdown(slug: String, raw: String, path: String) -> AgentSkill {
        var name = slug
        var desc = "OpenClaw SKILL.md yeteneği"
        var body = raw
        var triggers: [String] = [slug, "/\(slug)"]
        var inTriggersBlock = false

        if raw.hasPrefix("---") {
            let parts = raw.components(separatedBy: "---")
            if parts.count >= 3 {
                let front = parts[1]
                body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
                for line in front.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("name:") {
                        inTriggersBlock = false
                        name = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    } else if trimmed.hasPrefix("description:") {
                        inTriggersBlock = false
                        desc = trimmed.dropFirst(12).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    } else if trimmed.hasPrefix("triggers:") {
                        let inline = trimmed.dropFirst(9).trimmingCharacters(in: CharacterSet(charactersIn: " []\"'"))
                        if inline.isEmpty {
                            inTriggersBlock = true
                        } else {
                            inTriggersBlock = false
                            let extras = inline
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                                .filter { !$0.isEmpty }
                            triggers.append(contentsOf: extras)
                        }
                    } else if inTriggersBlock && trimmed.hasPrefix("-") {
                        let val = trimmed.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                        if !val.isEmpty { triggers.append(val) }
                    } else if !trimmed.isEmpty && trimmed.contains(":") {
                        inTriggersBlock = false
                    }
                }
            }
        }
        let uniqueTriggers = Array(Set(triggers)).sorted()
        return AgentSkill(id: slug, name: name, description: desc, body: body, sourcePath: path, isEnabled: false, triggers: uniqueTriggers)
    }

    static func builtInSkills() -> [AgentSkill] {
        [
            AgentSkill(
                id: "rtk-proxy", name: "RTK Token Killer",
                description: "Terminal/git/test çıktılarını rtk CLI proxy ile %60-90 sıkıştırır.",
                body: "Shell komutları çağırırken çıktı gürültüsünü en aza indir. `git`, `ls`, `swift`, `cargo`, `npm`, `pytest` komutları RTK proxy ile filtrelenir.",
                sourcePath: "Dahili", isEnabled: true, triggers: ["rtk", "terminal", "git", "test", "log"]
            ),
            AgentSkill(
                id: "graphify", name: "Graphify Bilgi Grafı",
                description: "Projeyi tek tek dosya okumadan graphify-out/GRAPH_REPORT.md üzerinden analiz eder.",
                body: "Kod tabanı mimarisinde önce `GRAPH_REPORT.md` ve God-Node listesini incele; ardından sadece ilgili dosyaları `read_file` veya `search_code` ile aç.",
                sourcePath: "Dahili", isEnabled: true, triggers: ["graphify", "graf", "mimari", "bağımlılık", "refactor"]
            ),
            AgentSkill(
                id: "swift-audit", name: "Swift & macOS/iOS Denetimi",
                description: "SwiftUI, Swift Concurrency (@MainActor/Sendable) ve bellek sızıntısı denetimi.",
                body: "Swift kodunu incelerken `@MainActor` güvenliğini, `[weak self]` yakalamalarını, Task iptalini ve Apple HIG uyumluluğunu doğrula.",
                sourcePath: "Dahili", isEnabled: true, triggers: ["swift", "swiftui", "ios", "macos", "audit"]
            ),
            AgentSkill(
                id: "self-evolution", name: "Öz-Gelişim & Kalıcı Öğrenme",
                description: "Görev sonrası çıkarılan dersleri OpenClaw MEMORY.md ve yeni SKILL.md dosyalarına işler.",
                body: "Karmaşık bir hatayı çözdüğünde veya yeni bir kalıp keşfettiğinde, kısa ve tekrar kullanılabilir tek satırlık teknik kural öner.",
                sourcePath: "Dahili", isEnabled: true, triggers: ["öğren", "retrospektif", "memory", "geliştir", "skill"]
            ),
            AgentSkill(
                id: "ecosystem-scout", name: "GitHub & Connector Önce-Ara",
                description: "0'dan skill/connector yazmadan önce yerel OpenClaw skillerini, katalog connectorlarını ve GitHub repolarını tarar.",
                body: """
                Yeni bir araç, entegrasyon, MCP veya skill gerekmeden önce SİRASİYLA şu sırayı izle:
                1. `list_connectors` ile Hostinger/GitHub/Cloudflare vb. hazır veya kayıtlı connectorları kontrol et.
                2. `search_github` (`sorgu|||skill` veya `sorgu|||mcp`) ile GitHub'da yıldızlı/güncel açık kaynak çözüm var mı ara.
                3. Bulunan adayı `inspect_github_repo` ile güvenlik (pipe-to-shell, yıkıcı komut) ve lisans/kalite açısından denetle.
                4. Uygunsa `install_github_skill` ile SKILL.md olarak kur veya `create_connector` ile bağla; yalnızca uygun hazır çözüm yoksa 0'dan `create_skill` / `create_connector` üret.
                """,
                sourcePath: "Dahili", isEnabled: true, triggers: ["skill", "connector", "mcp", "github", "hostinger", "entegrasyon", "araç", "ekle", "bul", "web"]
            ),
            AgentSkill(
                id: "caveman", name: "Caveman Sıkıştırma Modu",
                description: "Kod, komut ve dosya yollarını koruyarak yanıt token kullanımını %35-80 azaltır.",
                body: "Selamlama ve dolgu cümlelerini atla. Doğrudan sonuç, neden ve sonraki adımı ver; kod blokları, dosya yolları ve olumsuzlukları (`not`, `değil`, `asla`) birebir koru.",
                sourcePath: "Dahili", isEnabled: true, triggers: ["caveman", "kısa", "özet", "sıkıştır", "token"]
            ),
            AgentSkill(
                id: "swarms", name: "Swarms Çoklu Ajan Orkestrasyonu",
                description: "Swarms çerçevesiyle SequentialWorkflow, ConcurrentWorkflow, GraphWorkflow ve HierarchicalSwarm kurar.",
                body: "Çoklu ajan akışı kurarken Swarms Agent primitifini kullan; yerel köprü (swarms_bridge.py) üzerinden güvenli görev dağıtımı ve özet doğrulaması yap.",
                sourcePath: "Dahili", isEnabled: true, triggers: ["swarms", "swarm", "workflow", "orkestrasyon", "multi-agent", "ajanlar"]
            )
        ]
    }

    static func loadGraphifySnapshot(workspacePath: String) -> GraphifySnapshot? {
        let outDir = URL(fileURLWithPath: workspacePath).appendingPathComponent("graphify-out")
        let reportURL = outDir.appendingPathComponent("GRAPH_REPORT.md")
        let jsonURL = outDir.appendingPathComponent("graph.json")
        let reportText = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var degreeMap: [String: Int] = [:]

        if let data = try? Data(contentsOf: jsonURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func extractID(_ raw: Any?) -> String {
                if let s = raw as? String { return s }
                if let i = raw as? Int { return String(i) }
                if let d = raw as? [String: Any], let inner = d["id"] { return extractID(inner) }
                return ""
            }
            let rawLinks = (root["links"] as? [[String: Any]]) ?? (root["edges"] as? [[String: Any]]) ?? []
            for link in rawLinks.prefix(400) {
                let src = extractID(link["source"])
                let dst = extractID(link["target"])
                let rel = (link["relation"] as? String) ?? (link["type"] as? String) ?? "calls"
                if !src.isEmpty && !dst.isEmpty {
                    edges.append(GraphEdge(source: src, target: dst, relation: rel))
                    degreeMap[src, default: 0] += 1
                    degreeMap[dst, default: 0] += 1
                }
            }
            let rawNodes = (root["nodes"] as? [[String: Any]]) ?? []
            for n in rawNodes.prefix(200) {
                let id = extractID(n["id"])
                guard !id.isEmpty else { continue }
                let label = (n["label"] as? String) ?? (n["name"] as? String) ?? id
                let comm = (n["community"] as? Int) ?? (n["cluster"] as? Int) ?? 0
                let fpath = (n["file"] as? String) ?? (n["source_file"] as? String) ?? ""
                nodes.append(GraphNode(id: id, label: label, community: comm, degree: degreeMap[id, default: 0], filePath: fpath))
            }
        }
        if reportText.isEmpty && nodes.isEmpty { return nil }
        let gods = nodes.sorted { $0.degree > $1.degree }.prefix(8).map { $0 }
        let modDate = (try? FileManager.default.attributesOfItem(atPath: jsonURL.path)[.modificationDate] as? Date)
            ?? (try? FileManager.default.attributesOfItem(atPath: reportURL.path)[.modificationDate] as? Date)
        return GraphifySnapshot(reportMarkdown: reportText, nodes: nodes, edges: edges, godNodes: gods, lastUpdated: modDate)
    }
}

// MARK: - Safe Local Mac Tools + Autonomous Code Patching + Backup/Rollback + RTK Proxy

enum PowerShellTools {
    static func buildToolPromptAddendum(
        allowWrites: Bool,
        agentNames: [String],
        usesNativeAntigravityTools: Bool = false,
        connectorSummary: String = ""
    ) -> String {
        let peers = agentNames.joined(separator: ", ")
        let webConnectorAndGitHubSection = """

        [CONNECTOR/MCP, SWARMS & GİTHUB SKİLL FABRİKASI]
        Harici servis Connectorları (Hostinger, GitHub, MCP vb.), Swarms çoklu ajan orkestrasyonu ve GitHub Skill kurucu araçlara sahipsin:
        - Connector, MCP & Swarms Runtime (Hostinger, Swarms vb.):
          * Kayıtlı connectorları gör: <tool name="list_connectors">.</tool>
          * Connector/MCP çağır: <tool name="use_connector">slug|||TOOL_VEYA_METHOD_PATH[|||json_arg]</tool>
          * Swarms Çoklu Ajan Orkestrasyonu: <tool name="run_swarm">Auto|SequentialWorkflow|ConcurrentWorkflow|HierarchicalSwarm|DebateWithJudge|MixtureOfAgents|||görev[|||Ajan1,Ajan2]</tool> · Durum: <tool name="swarm_status">.</tool>
          * Yeni Connector/MCP tanımla: <tool name="create_connector">slug|||Ad|||rest|mcp_http|mcp_stdio|||endpoint_veya_komut|||açıklama[|||authHeaderOrEnv]</tool>
        - GitHub Keşif & Skill Yönetimi (ÖNCE HAZIRINI ARA, 0'DAN YAZMA!):
          * Kural: Yeni skill veya connector oluşturmadan ÖNCE mutlaka `list_connectors` ve `search_github` ile hazır açık kaynak / resmi MCP veya SKILL.md var mı kontrol et!
          * GitHub'da ara: <tool name="search_github">sorgu[|||skill|mcp|connector|all]</tool>
          * Depoyu & güvenliğini incele: <tool name="inspect_github_repo">owner/repo</tool>
          * GitHub'dan Skill kur: <tool name="install_github_skill">owner/repo[|||slug]</tool>
          * Hazır çözüm yoksa yeni Skill oluştur: <tool name="create_skill">slug|||Ad|||Açıklama|||SKILL_govdesi</tool>
        """
        let activeConnectorsBlock = connectorSummary.isEmpty ? "" : "\n[KAYITLI CONNECTORLAR]: \(connectorSummary)\n"
        if usesNativeAntigravityTools {
            return """
            [ANTIGRAVITY IDE / GEMINI 4 HYDROGEN YEREL YETENEKLERİ + OTONOM EKİP PLANLAMA]
            Doğrudan Antigravity IDE çalışma motoru üzerinden tam dosya ve terminal erişimine sahipsin:
            - Kod sorunlarını çözerken doğrudan yerleşik araçlarını (`read_file`/`view_file`, `list_dir`, `grep_search`, \(allowWrites ? "`replace_file_content`, `write_to_file`, `run_command`" : "`run_command` (salt okunur)")) kullanabilir, ayrıca her zaman ClawOffice RTK terminali `<tool name="shell">zsh_komutu</tool>` ile komut çalıştırabilirsin.
            - Büyük veya çok adımlı görevlerde önce plan oluştur, uzman işe al, görevleri dağıt ve derleme/test doğrulaması bitene kadar DURMADAN devam et:
              * İş Planı Oluştur: <tool name="create_plan">Hedef|||Görev 1 [@Atanan]; Görev 2 [@Atanan]; ...</tool>
              * Plan Görevi Güncelle: <tool name="update_task">GörevNo_veya_Başlık|||in_progress|done|blocked|||kısa_not</tool>
              * Mevcut Ekip: <tool name="list_agents">.</tool>
              * Yeni Ajan İşe Al: <tool name="hire_agent">AjanAdı|||Ünvan|||Emoji|||auto|||ÖzelSistemPromptu|||0.25</tool> (`auto` ile role, yoğunluğa ve sağlığa göre en uygun boşta model otomatik seçilir; veya özel modelId yaz)
              * Ajanı Görevlendir (Task Ver): <tool name="assign_task">AjanAdı|||GörevBaşlığı_veya_No|||detaylı_görev</tool>
              * Ekip Arkadaşına Devret: <tool name="delegate">AjanAdı|||detaylı_görev_metni</tool>
              * Mac Terminal (RTK): <tool name="shell">zsh_komutu</tool>
              * Ajanı Arşivle: <tool name="dismiss_agent">AjanAdı|||sebep</tool>
            \(webConnectorAndGitHubSection)\(activeConnectorsBlock)

            [DİSİPLİNLİ MÜHENDİSLİK RAPORU FORMATI]
            Tüm adımlar doğrulanıp tamamlandığında nihai cevabını şu 4 aşamalı profesyonel başlıklarla sun:
            ### 🎯 Durum & Analiz
            ### ⚡️ Yapılan İşlem & Araçlar
            ### 🔍 Kod & Değişiklik İncelemesi
            ### ✅ Sonuç & Doğrulama
            """
        }
        var text = """
        [YEREL MAC, TERMİNAL & SİSTEM KONTROLÜ + OTONOM EKİP PLANLAMA]
        Mac'i ve projeleri Antigravity IDE / Claude Code kalitesinde tam yetkiyle kontrol edebilirsin:
        - Klasör listele: <tool name="list_dir">/yol veya .</tool>
        - Dosya bul (glob): <tool name="find_files">*.swift</tool> veya <tool name="find_files">*Engine*|||Sources</tool>
        - Dosya oku: <tool name="read_file">/yol/dosya.swift</tool> veya satır aralığı: <tool name="read_file">yol/dosya.swift|||1|||200</tool>
        - Kodda ara (grep): <tool name="search_code">aranacakMetin</tool> veya klasörle: <tool name="search_code">aranacakMetin|||Sources</tool>
        - Git durum & diff: <tool name="git_status">.</tool> · <tool name="git_diff">.</tool>
        - Mac Terminal komutu (RTK): <tool name="shell">zsh_komutu</tool> (derleme, test, git, swift/npm/pytest/python vb.)
        - Mac sistem bilgisi: <tool name="system_info">.</tool>
        - Mac uygulaması aç: <tool name="open_app">Xcode</tool> veya <tool name="open_app">Visual Studio Code</tool>
        - Dosya/Klasörü Finder'da aç: <tool name="open_path">/Volumes/DATA</tool>
        - Graphify sorgu: <tool name="graphify_query">bağımlılık sorusu</tool>
        - Graphify güncelle: <tool name="graphify_update">.</tool>
        [OTONOM PLANLAMA, AJAN KAYNAKLARI (AR) & KESİNTİSİZ GÖREV DAĞITIMI]
        Durmadan uçtan uca mühendislik yürütmek için plan çıkar, uzmanları işe al ve taskları dağıt:
        - İş Planı Oluştur: <tool name="create_plan">Hedef|||Görev 1 [@Atanan]; Görev 2 [@Atanan]; ...</tool>
        - Plan Görevi Güncelle: <tool name="update_task">GörevNo_veya_Başlık|||in_progress|done|blocked|||kısa_not</tool>
        - Ajanı Planlı Görevlendir (Task Ver): <tool name="assign_task">AjanAdı|||GörevBaşlığı_veya_No|||detaylı_görev</tool>
        - Yeni Ajan İşe Al: <tool name="hire_agent">AjanAdı|||Ünvan|||Emoji|||modelId|||ÖzelSistemPromptu|||sıcaklık</tool>
          * Model Seçim Kuralı: `modelId` için `auto` yazarsan ClawOffice AR Yönlendiricisi uzmanlığa, model yoğunluğuna ve gecikmeye göre en iyi boşta modeli seçer (örn: Kodlama: deepseek-v4.1-flash, Mimari/Denetim: glm-5.3, Araştırma/DevOps: qwen3.8-flash-next, UI/UX: gemma-4-31b).
          * Özel Sistem Promptu: Ajanın uzmanlık alanını, araçlarını ve kurallarını belirten yüksek kaliteli prompt yaz.
        - Mevcut Ekibi Listele: <tool name="list_agents">.</tool>
        - Rol Şablonu Kaydet: <tool name="add_template">ŞablonAdı|||Ünvan|||SistemPromptu[|||Emoji]</tool>
        - Ekip Arkadaşına Görev Devret (\(peers)): <tool name="delegate">AjanAdı|||detaylı_görev_metni</tool>
        - Ajanı Ekipten Çıkar / Arşivle: <tool name="dismiss_agent">AjanAdı|||sebep</tool>
        \(webConnectorAndGitHubSection)\(activeConnectorsBlock)
        """
        if allowWrites {
            text += """

            [OTONOM GELİŞTİRME & KENDİNİ GÜNCELLEME (SELF-EVOLUTION)]
            Her düzenlemeden önce otomatik .clawoffice-backups/ yedeği alınır:
            - Dosya yaz/oluştur: <tool name="write_file">yol/dosya.swift|||tam_içerik</tool> (Kendi kodu dahil: /Volumes/DATA/Builds/ClawOffice/...)
            - Nokta atışı yama (patch): <tool name="patch_file">yol/dosya.swift|||eski|||yeni</tool>
            - Çoklu yama (tek dosyada birden fazla blok): <tool name="multi_patch">yol/dosya.swift|||eski1|||yeni1|||eski2|||yeni2</tool>
            - Kendini derle ve yeniden başlat: <tool name="rebuild_and_restart">güncelleme_özeti</tool>
            - Uygulamayı kapat-aç (restart): <tool name="restart_app">sebep</tool>
            """
        }
        text += """

        [DİSİPLİNLİ MÜHENDİSLİK RAPORU VE GERİ DÖNÜT FORMATI]
        Kullanıcıya veya ekibe yanıt verirken çalışmalarını daima şu 4 aşamalı standart ve profesyonel başlıklarla yapılandır:
        ### 🎯 Durum & Analiz
        - Üzerinde çalışılan dosya, hedef veya problem analizi.
        ### ⚡️ Yapılan İşlem & Araçlar
        - Hangi araçların çağrıldığı (veya çağrılacağı) ve elde edilen kilit bulgular.
        ### 🔍 Kod & Değişiklik İncelemesi
        - Yapılan düzenlemeler, eklenen/düzeltilen fonksiyonlar, satır analizleri.
        ### ✅ Sonuç & Sonraki Adım
        - Gelinen durum, derleme/test doğrulama sonucu ve bir sonraki planlanan adım.

        [KRİTİK ARAÇ ÇAĞIRMA VE YÜRÜTME DİSİPLİNİ — ASLA ÇIKTI UYDURMA, ASLA DONMA]
        1. Bir araç çalıştırmak istediğinde `<tool name="...">parametre</tool>` formatını kullan ve HEMEN DUR (STOP).
        2. Salt-okunur keşif araçlarını (`list_dir`, `find_files`, `read_file`, `search_code`, `git_status`, `git_diff`) tek turda paralel olarak en fazla 4-5 adet toplu çağırabilirsin; kod yazma/yamalama (`patch_file`, `write_file`, `multi_patch`) ve `shell` çağrılarını kontrollü sırada yap.
        3. Dosyayı düzenlemeden önce ilgili satırları `read_file` ile oku; kod değişikliğinden sonra mutlaka derleme/test komutuyla doğrula!
        4. ASLA aracın çıktısını kendin tahmin etme, uydurma veya simüle etme.
        5. Çağırdığın aracın gerçek sonucu sistem tarafından sana bir sonraki turda iletilecektir; analizini ve sonraki kararını SADECE o gerçek sonuca dayanarak vereceksin.
        """
        return text
    }

    /// Computes fenced (` ``` ` / `~~~`) and single-backtick code ranges so documentation examples are not executed as live tools.
    private static func codeProtectedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var idx = text.startIndex
        var activeFence: Character? = nil
        var activeFenceLen = 0
        var fenceStart = text.startIndex

        while idx < text.endIndex {
            let lineEnd = text[idx...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[idx..<lineEnd]
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let first = trimmed.first, first == "`" || first == "~" {
                let runLen = trimmed.prefix(while: { $0 == first }).count
                if let fence = activeFence {
                    if first == fence && runLen >= activeFenceLen {
                        let closingEnd = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                        ranges.append(fenceStart..<closingEnd)
                        activeFence = nil
                    }
                } else if runLen >= 3 {
                    activeFence = first
                    activeFenceLen = runLen
                    fenceStart = idx
                }
            }
            idx = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        if activeFence != nil {
            ranges.append(fenceStart..<text.endIndex)
        }

        // Add inline single-backtick spans outside fenced blocks
        var scan = text.startIndex
        while scan < text.endIndex {
            if let containing = ranges.first(where: { $0.contains(scan) }) {
                scan = containing.upperBound
                continue
            }
            if text[scan] == "`" {
                let afterOpen = text.index(after: scan)
                if afterOpen < text.endIndex,
                   let close = text[afterOpen...].firstIndex(of: "`"),
                   !text[afterOpen..<close].contains("\n") {
                    let closeEnd = text.index(after: close)
                    ranges.append(scan..<closeEnd)
                    scan = closeEnd
                    continue
                }
            }
            scan = text.index(after: scan)
        }
        return ranges
    }

    static func canonicalToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "view_file", "read": return "read_file"
        case "grep_search", "grep", "ripgrep", "search": return "search_code"
        case "find_by_name", "find_file", "glob", "list_files": return "find_files"
        case "write_to_file", "create_file": return "write_file"
        case "replace_file_content", "edit_file", "smart_patch": return "patch_file"
        case "multi_replace_file_content": return "multi_patch"
        case "ls": return "list_dir"
        default: return trimmed
        }
    }

    static func isReadOnlyToolName(_ name: String) -> Bool {
        switch canonicalToolName(name).lowercased() {
        case "list_dir", "find_files", "read_file", "search_code", "git_status", "git_diff",
             "system_info", "list_agents", "list_connectors", "swarm_status", "graphify_query", "graphify_path":
            return true
        default:
            return false
        }
    }

    static func serializeToolCallArguments(toolName: String, params: [String: Any]) -> String {
        let canonical = canonicalToolName(toolName).lowercased()
        func firstStr(_ keys: [String]) -> String? {
            for k in keys {
                if let s = params[k] as? String, !s.isEmpty { return s }
                if let n = params[k] as? Int { return "\(n)" }
            }
            return nil
        }

        switch canonical {
        case "read_file":
            let path = firstStr(["path", "Path", "AbsolutePath", "TargetFile", "target_file", "file_path", "file", "arg", "argument"]) ?? ""
            if let s = firstStr(["start_line", "StartLine", "startLine", "offset"]),
               let e = firstStr(["end_line", "EndLine", "endLine", "limit"]) {
                return "\(path)|||\(s)|||\(e)"
            }
            if let s = firstStr(["start_line", "StartLine", "startLine"]) {
                return "\(path)|||\(s)"
            }
            return path
        case "write_file":
            let path = firstStr(["path", "Path", "TargetFile", "target_file", "file_path", "file"]) ?? ""
            let content = firstStr(["content", "Content", "CodeContent", "text", "body"]) ?? ""
            return path.isEmpty ? (firstStr(["argument", "arg"]) ?? content) : "\(path)|||\(content)"
        case "patch_file":
            let path = firstStr(["path", "Path", "TargetFile", "target_file", "file_path", "file"]) ?? ""
            let oldStr = firstStr(["old", "old_string", "old_text", "TargetContent", "target_content", "search"]) ?? ""
            let newStr = firstStr(["new", "new_string", "new_text", "ReplacementContent", "replacement_content", "replace"]) ?? ""
            return path.isEmpty ? (firstStr(["argument", "arg"]) ?? "") : "\(path)|||\(oldStr)|||\(newStr)"
        case "multi_patch":
            let path = firstStr(["path", "Path", "TargetFile", "target_file", "file_path"]) ?? ""
            if let chunks = (params["ReplacementChunks"] as? [[String: Any]]) ?? (params["edits"] as? [[String: Any]]) ?? (params["patches"] as? [[String: Any]]) {
                var parts = [path]
                for c in chunks {
                    let o = (c["TargetContent"] as? String) ?? (c["old_string"] as? String) ?? (c["old"] as? String) ?? ""
                    let n = (c["ReplacementContent"] as? String) ?? (c["new_string"] as? String) ?? (c["new"] as? String) ?? ""
                    parts.append(o)
                    parts.append(n)
                }
                return parts.joined(separator: "|||")
            }
            return firstStr(["argument", "arg"]) ?? path
        case "search_code":
            let q = firstStr(["query", "Query", "pattern", "Pattern", "text", "arg", "argument"]) ?? ""
            if let sub = firstStr(["subpath", "SearchPath", "path", "dir", "DirectoryPath"]), !sub.isEmpty, sub != "." {
                return "\(q)|||\(sub)"
            }
            return q
        case "find_files":
            let pat = firstStr(["pattern", "Pattern", "glob", "query", "Query", "name", "arg", "argument"]) ?? "*"
            if let sub = firstStr(["subpath", "SearchDirectory", "path", "dir", "DirectoryPath"]), !sub.isEmpty, sub != "." {
                return "\(pat)|||\(sub)"
            }
            return pat
        case "list_dir":
            return firstStr(["path", "Path", "DirectoryPath", "dir", "arg", "argument"]) ?? "."
        case "shell", "run_command", "terminal", "bash", "zsh", "exec":
            return firstStr(["command", "CommandLine", "cmd", "script", "arg", "argument"]) ?? ""
        case "git_diff":
            return firstStr(["path", "target", "file", "arg", "argument"]) ?? "."
        case "git_status", "swarm_status", "list_agents", "list_connectors", "system_info":
            return firstStr(["argument", "arg", "path"]) ?? "."
        case "delegate", "assign_task":
            let agent = firstStr(["agent", "target", "assignee", "AgentName", "to"]) ?? ""
            let title = firstStr(["title", "task_id", "TaskId"])
            let body = firstStr(["task", "prompt", "subtask", "description", "message"]) ?? ""
            if !agent.isEmpty {
                if let title, !title.isEmpty {
                    return "\(agent)|||\(title)|||\(body)"
                }
                return "\(agent)|||\(body)"
            }
            return firstStr(["argument", "arg"]) ?? ""
        default:
            if let direct = firstStr(["argument", "arg"]) { return direct }
            let vals = params.keys.sorted().compactMap { k -> String? in
                if let s = params[k] as? String, !s.isEmpty { return s }
                if let i = params[k] as? Int { return "\(i)" }
                if let b = params[k] as? Bool { return b ? "true" : "false" }
                return nil
            }
            return vals.isEmpty ? "." : vals.joined(separator: "|||")
        }
    }

    static func serializeToolTag(name: String, argumentsDict: [String: Any]?, rawArguments: String = "") -> String {
        let normName = canonicalToolName(name)
        let arg: String
        if let argumentsDict, !argumentsDict.isEmpty {
            arg = serializeToolCallArguments(toolName: normName, params: argumentsDict)
        } else if !rawArguments.isEmpty,
                  let data = rawArguments.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arg = serializeToolCallArguments(toolName: normName, params: parsed)
        } else {
            let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
            arg = trimmed.isEmpty ? "." : trimmed
        }
        return "<tool name=\"\(normName)\">\(arg)</tool>"
    }

    static func extractToolCalls(from text: String) -> [ParsedToolCall] {
        var found: [(offset: String.Index, call: ParsedToolCall)] = []
        let protected = codeProtectedRanges(in: text)
        let placeholders: Set<String> = [
            "parametre", "detaylı_görev_metni", "AjanAdı|||detaylı_görev_metni", "görev",
            "AjanAdı|||Ünvan|||Emoji|||modelId|||ÖzelSistemPromptu|||sıcaklık",
            "AjanAdı|||Ünvan|||Emoji|||modelId|||ÖzelSistemPromptu|||0.25",
            "ŞablonAdı|||Ünvan|||SistemPromptu[|||Emoji]",
            "Hedef|||Görev 1 [@Atanan]; Görev 2 [@Atanan]; ...",
            "GörevNo_veya_Başlık|||in_progress|done|blocked|||kısa_not",
            "AjanAdı|||GörevBaşlığı_veya_No|||detaylı_görev",
            "AjanAdı|||sebep", "yol/dosya.swift|||tam_içerik", "yol/dosya.swift|||eski|||yeni",
            "yol/dosya.swift|||eski1|||yeni1|||eski2|||yeni2",
            "aranacakMetin", "aranacakMetin|||Sources", "zsh_komutu", "bağımlılık sorusu",
            "güncelleme_özeti", "sebep", "dosya/yol", "/yol/dosya.swift", "/yol veya .",
            "yol/dosya.swift", "*.swift", "*Engine*|||Sources",
            "https://...", "@e1_veya_seçici", "@e1_veya_seçici|||metin[|||submit]",
            "@e1_veya_seçici|||seçenek", "down|up|top|bottom", "saniye_veya_seçici",
            "etiket", "js_kodu", "Kullanıcı girişi veya onay sebebi",
            "slug|||TOOL_VEYA_METHOD_PATH[|||json_arg]",
            "slug|||Ad|||rest|mcp_http|mcp_stdio|||endpoint_veya_komut|||açıklama[|||authHeaderOrEnv]",
            "sorgu[|||skill|mcp|connector|all]", "owner/repo", "owner/repo[|||slug]",
            "slug|||Ad|||Açıklama|||SKILL_govdesi"
        ]

        func isProtected(_ index: String.Index) -> Range<String.Index>? {
            protected.first(where: { $0.contains(index) })
        }

        // 1. Canonical <tool name="...">arg</tool> (including DSML-closed variant)
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            let dbl = text.range(of: "<tool name=\"", range: searchStart..<text.endIndex)
            let sgl = text.range(of: "<tool name='", range: searchStart..<text.endIndex)
            let s: Range<String.Index>
            let quoteChar: String
            switch (dbl, sgl) {
            case let (d?, sg?):
                if d.lowerBound <= sg.lowerBound { s = d; quoteChar = "\">" } else { s = sg; quoteChar = "'>" }
            case let (d?, nil): s = d; quoteChar = "\">"
            case let (nil, sg?): s = sg; quoteChar = "'>"
            case (nil, nil): searchStart = text.endIndex; continue
            }

            if let fence = isProtected(s.lowerBound) {
                searchStart = fence.upperBound
                continue
            }
            guard let q = text.range(of: quoteChar, range: s.upperBound..<text.endIndex) else { break }
            let endTool = text.range(of: "</tool>", range: q.upperBound..<text.endIndex)
            let endDSML = text.range(of: "</｜DSML｜", range: q.upperBound..<text.endIndex)
            let closeRange: Range<String.Index>? = {
                if let et = endTool, let ed = endDSML { return et.lowerBound <= ed.lowerBound ? et : ed }
                return endTool ?? endDSML
            }()
            guard let e = closeRange else { break }

            var nextPos = e.upperBound
            if text[e.lowerBound...].hasPrefix("</｜DSML｜"),
               let gt = text.range(of: ">", range: e.upperBound..<text.endIndex) {
                nextPos = gt.upperBound
            }
            let name = canonicalToolName(String(text[s.upperBound..<q.lowerBound]))
            let arg = String(text[q.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            searchStart = nextPos
            if !placeholders.contains(arg) && !name.isEmpty {
                found.append((s.lowerBound, ParsedToolCall(name: name, argument: arg)))
            }
        }

        // 2. Model pipe tokens: <|tool|>name<|/tool|> or <|tool|>name|||arg<|/tool|>
        searchStart = text.startIndex
        while searchStart < text.endIndex, let openPipe = text.range(of: "<|tool|>", range: searchStart..<text.endIndex) {
            if let fence = isProtected(openPipe.lowerBound) {
                searchStart = fence.upperBound
                continue
            }
            guard let closePipe = text.range(of: "<|/tool|>", range: openPipe.upperBound..<text.endIndex) else { break }
            let body = String(text[openPipe.upperBound..<closePipe.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            searchStart = closePipe.upperBound
            if !body.isEmpty {
                let parts = body.components(separatedBy: "|||")
                let name = canonicalToolName(parts[0])
                let arg = parts.count > 1 ? parts.dropFirst().joined(separator: "|||").trimmingCharacters(in: .whitespacesAndNewlines) : "."
                if !name.isEmpty && !placeholders.contains(arg) {
                    found.append((openPipe.lowerBound, ParsedToolCall(name: name, argument: arg)))
                }
            }
        }

        // 3. DeepSeek DSML / XML invoke blocks: <｜DSML｜invoke name="...">...</｜DSML｜invoke> or <invoke name="...">...</invoke>
        for (openPrefix, closeTag, paramOpenPrefix, paramCloseTag) in [
            ("<｜DSML｜invoke ", "</｜DSML｜invoke>", "<｜DSML｜parameter ", "</｜DSML｜parameter>"),
            ("<invoke ", "</invoke>", "<parameter ", "</parameter>")
        ] {
            searchStart = text.startIndex
            while searchStart < text.endIndex, let openInv = text.range(of: openPrefix, range: searchStart..<text.endIndex) {
                if let fence = isProtected(openInv.lowerBound) {
                    searchStart = fence.upperBound
                    continue
                }
                guard let gt = text.range(of: ">", range: openInv.upperBound..<text.endIndex),
                      let closeInv = text.range(of: closeTag, range: gt.upperBound..<text.endIndex) else { break }
                let attrs = String(text[openInv.upperBound..<gt.lowerBound])
                let inner = String(text[gt.upperBound..<closeInv.lowerBound])
                searchStart = closeInv.upperBound

                guard let rawName = OfficeEngine.extractAttr("name", from: attrs), !rawName.isEmpty else { continue }
                let normName = canonicalToolName(rawName)
                var paramDict: [String: Any] = [:]
                var pCursor = inner.startIndex
                while pCursor < inner.endIndex, let po = inner.range(of: paramOpenPrefix, range: pCursor..<inner.endIndex) {
                    guard let pgt = inner.range(of: ">", range: po.upperBound..<inner.endIndex),
                          let pc = inner.range(of: paramCloseTag, range: pgt.upperBound..<inner.endIndex) else { break }
                    let pAttrs = String(inner[po.upperBound..<pgt.lowerBound])
                    let pVal = String(inner[pgt.upperBound..<pc.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let pName = OfficeEngine.extractAttr("name", from: pAttrs) {
                        paramDict[pName] = pVal
                    }
                    pCursor = pc.upperBound
                }
                let arg = paramDict.isEmpty
                    ? inner.trimmingCharacters(in: .whitespacesAndNewlines)
                    : serializeToolCallArguments(toolName: normName, params: paramDict)
                let cleanArg = arg.isEmpty ? "." : arg
                if !placeholders.contains(cleanArg) {
                    found.append((openInv.lowerBound, ParsedToolCall(name: normName, argument: cleanArg)))
                }
            }
        }

        // 4. Hermes / Qwen JSON wrapper: <tool_call>{"name": "...", "arguments": {...}}</tool_call>
        searchStart = text.startIndex
        while searchStart < text.endIndex, let openTC = text.range(of: "<tool_call>", range: searchStart..<text.endIndex) {
            if let fence = isProtected(openTC.lowerBound) {
                searchStart = fence.upperBound
                continue
            }
            guard let closeTC = text.range(of: "</tool_call>", range: openTC.upperBound..<text.endIndex) else { break }
            let rawJSON = String(text[openTC.upperBound..<closeTC.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            searchStart = closeTC.upperBound
            if let data = rawJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawName = obj["name"] as? String {
                let normName = canonicalToolName(rawName)
                let argsObj = (obj["arguments"] as? [String: Any]) ?? (obj["parameters"] as? [String: Any]) ?? [:]
                let rawArgStr = (obj["arguments"] as? String) ?? ""
                let arg: String
                if !argsObj.isEmpty {
                    arg = serializeToolCallArguments(toolName: normName, params: argsObj)
                } else if !rawArgStr.isEmpty {
                    if let d2 = rawArgStr.data(using: .utf8), let p2 = try? JSONSerialization.jsonObject(with: d2) as? [String: Any] {
                        arg = serializeToolCallArguments(toolName: normName, params: p2)
                    } else {
                        arg = rawArgStr
                    }
                } else {
                    arg = "."
                }
                if !normName.isEmpty && !placeholders.contains(arg) {
                    found.append((openTC.lowerBound, ParsedToolCall(name: normName, argument: arg)))
                }
            }
        }

        found.sort { $0.offset < $1.offset }
        return Array(found.prefix(12).map(\.call))
    }

    /// Removes completed `<tool ...>`, `<|tool|>`, `<tool_call>`, `<｜DSML｜...>`, and `<invoke ...>` blocks from prose without collapsing internal spaces.
    static func stripToolTags(from raw: String, stripTrailingIncomplete: Bool = false) -> String {
        var cleaned = raw

        // 1. <tool name="...">...</tool> or </｜DSML｜...>
        while let s = cleaned.range(of: "<tool name=\"") ?? cleaned.range(of: "<tool name='") {
            let endTool = cleaned.range(of: "</tool>", range: s.upperBound..<cleaned.endIndex)
            let endDSML = cleaned.range(of: "</｜DSML｜", range: s.upperBound..<cleaned.endIndex)
            if let et = endTool, let ed = endDSML {
                let firstEnd = et.lowerBound <= ed.lowerBound
                    ? et.upperBound
                    : (cleaned.range(of: ">", range: ed.upperBound..<cleaned.endIndex)?.upperBound ?? ed.upperBound)
                cleaned.removeSubrange(s.lowerBound..<firstEnd)
            } else if let et = endTool {
                cleaned.removeSubrange(s.lowerBound..<et.upperBound)
            } else if let ed = endDSML {
                let endLine = cleaned.range(of: ">", range: ed.upperBound..<cleaned.endIndex)?.upperBound ?? ed.upperBound
                cleaned.removeSubrange(s.lowerBound..<endLine)
            } else {
                break
            }
        }

        // 2. <|tool|>...<|/tool|>
        while let s = cleaned.range(of: "<|tool|>"),
              let e = cleaned.range(of: "<|/tool|>", range: s.upperBound..<cleaned.endIndex) {
            cleaned.removeSubrange(s.lowerBound..<e.upperBound)
        }

        // 3. <tool_call>...</tool_call>
        while let s = cleaned.range(of: "<tool_call>"),
              let e = cleaned.range(of: "</tool_call>", range: s.upperBound..<cleaned.endIndex) {
            cleaned.removeSubrange(s.lowerBound..<e.upperBound)
        }

        // 4. <｜DSML｜function_calls>...</｜DSML｜function_calls>, <｜DSML｜invoke ...>...</｜DSML｜invoke>, <invoke ...>...</invoke>
        for (openTag, closeTag) in [
            ("<｜DSML｜function_calls", "</｜DSML｜function_calls>"),
            ("<｜DSML｜invoke ", "</｜DSML｜invoke>"),
            ("<invoke ", "</invoke>")
        ] {
            while let s = cleaned.range(of: openTag),
                  let e = cleaned.range(of: closeTag, range: s.upperBound..<cleaned.endIndex) {
                cleaned.removeSubrange(s.lowerBound..<e.upperBound)
            }
        }

        // 5. Stray/orphan DSML fragments like `</｜DSML｜ parameter>`, `</｜DSML｜ calls>`, `<｜DSML｜...>`
        cleaned = cleaned.replacingOccurrences(
            of: #"</?｜DSML｜[^>]*>"#,
            with: "",
            options: .regularExpression
        )

        if stripTrailingIncomplete {
            for pattern in [
                #"<tool(?:\s|>|$)"#,
                #"<\|tool\|"#,
                #"<tool_call(?:\s|>|$)"#,
                #"<｜DSML｜"#,
                #"<invoke\s"#
            ] {
                if let openPartial = cleaned.range(of: pattern, options: [.regularExpression, .backwards]) {
                    cleaned.removeSubrange(openPartial.lowerBound..<cleaned.endIndex)
                }
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func gitStatusSummary(workspacePath: String) async -> (branch: String, dirtyCount: Int)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard !workspacePath.isEmpty,
              fm.fileExists(atPath: workspacePath, isDirectory: &isDir),
              isDir.boolValue,
              fm.fileExists(atPath: URL(fileURLWithPath: workspacePath).appendingPathComponent(".git").path) else {
            return nil
        }
        let res = await runCommand("git status --porcelain --branch", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 4.0)
        guard res.succeeded else { return nil }
        let lines = res.output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return nil }
        var branch = "HEAD"
        if first.hasPrefix("## ") {
            let body = String(first.dropFirst(3))
            branch = body.components(separatedBy: "...").first?.trimmingCharacters(in: .whitespaces) ?? "HEAD"
        }
        let dirty = max(0, lines.count - 1)
        return (branch, dirty)
    }

    static func detectBuildCommand(workspacePath: String, customOverride: String) -> String? {
        let trimmed = customOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fm = FileManager.default
        let checks: [(String, String)] = [
            ("Package.swift", "swift build"),
            ("package.json", "npm run build"),
            ("Cargo.toml", "cargo check"),
            ("pyproject.toml", "pytest -q"),
            ("Makefile", "make"),
            ("build_app.sh", "./build_app.sh")
        ]
        for (marker, cmd) in checks {
            if fm.fileExists(atPath: URL(fileURLWithPath: workspacePath).appendingPathComponent(marker).path) {
                return cmd
            }
        }
        if let files = try? fm.contentsOfDirectory(atPath: workspacePath) {
            if files.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return "xcodebuild -quiet"
            }
        }
        return nil
    }

    static func detectTestCommand(workspacePath: String, customOverride: String) -> String? {
        let trimmed = customOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fm = FileManager.default
        let checks: [(String, String)] = [
            ("Package.swift", "swift test"),
            ("package.json", "npm test"),
            ("Cargo.toml", "cargo test"),
            ("pyproject.toml", "pytest -q"),
            ("Makefile", "make test")
        ]
        for (marker, cmd) in checks {
            if fm.fileExists(atPath: URL(fileURLWithPath: workspacePath).appendingPathComponent(marker).path) {
                return cmd
            }
        }
        if let files = try? fm.contentsOfDirectory(atPath: workspacePath) {
            if files.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                return "xcodebuild test -quiet"
            }
        }
        return nil
    }

    static func extendedEnvPath() -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/.openclaw/bin", base]).joined(separator: ":")
    }

    static func detectInstalledTools() async -> CLIToolStatus {
        await Task.detached(priority: .utility) {
            var st = CLIToolStatus()
            st.rtkPath = which("rtk")
            st.rtkInstalled = !st.rtkPath.isEmpty
            st.graphifyPath = which("graphify")
            st.graphifyInstalled = !st.graphifyPath.isEmpty
            st.openClawInstalled = !which("openclaw").isEmpty
            st.repomixInstalled = !which("repomix").isEmpty
            st.brewInstalled = !which("brew").isEmpty
            st.uvInstalled = !which("uv").isEmpty

            if let url = URL(string: "http://127.0.0.1:18789/health") {
                var req = URLRequest(url: url)
                req.timeoutInterval = 1.0
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse,
                   (200...499).contains(http.statusCode) {
                    st.openClawGatewayOnline = true
                }
            }
            return st
        }.value
    }

    private static func which(_ binary: String) -> String {
        let fm = FileManager.default
        if binary.hasPrefix("/") {
            return fm.isExecutableFile(atPath: binary) ? binary : ""
        }
        for dir in extendedEnvPath().split(separator: ":") {
            let candidate = String(dir) + "/" + binary
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return ""
    }

    static func killProcessTree(pid: pid_t) {
        guard pid > 1 else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", "\(pid)"]
        pkill.standardInput = FileHandle.nullDevice
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            let pkillForce = Process()
            pkillForce.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkillForce.arguments = ["-KILL", "-P", "\(pid)"]
            pkillForce.standardInput = FileHandle.nullDevice
            pkillForce.standardOutput = FileHandle.nullDevice
            pkillForce.standardError = FileHandle.nullDevice
            try? pkillForce.run()
            kill(pid, SIGKILL)
        }
    }

    static func readBoundedPipeData(from handle: FileHandle, maxBytes: Int = 262_144) -> (data: Data, truncated: Bool) {
        var collected = Data()
        var truncated = false
        while true {
            let chunk = (try? handle.read(upToCount: 32_768)) ?? Data()
            if chunk.isEmpty { break }
            if collected.count < maxBytes {
                let remaining = maxBytes - collected.count
                if chunk.count <= remaining {
                    collected.append(chunk)
                } else {
                    collected.append(chunk.prefix(remaining))
                    truncated = true
                }
            } else {
                truncated = true
            }
        }
        return (collected, truncated)
    }

    static func runCommand(_ command: String, workspacePath: String, wrapWithRTK: Bool = false, timeoutSeconds: TimeInterval? = nil) async -> LocalToolResult {
        let lower = command.lowercased()
        let blocked = ["rm -rf /", "rm -rf ~", "rm -rf /*", ":(){", "sudo ", "mkfs", "dd if=", "shutdown", "reboot", "diskutil erase"]
        for b in blocked where lower.contains(b) {
            return LocalToolResult(toolName: "shell", commandUsed: command, usedRTK: false, output: "Güvenlik politikası gereği engellendi: \(command)", succeeded: false, editRecord: nil)
        }

        let isLongRunning = lower.contains("swift build") || lower.contains("xcodebuild") || lower.contains("build_app.sh") || lower.contains("graphify") || lower.contains("npm run") || lower.contains("cargo ")
        let effectiveTimeout = timeoutSeconds ?? (isLongRunning ? 180.0 : 45.0)

        let rtkBin = which("rtk")
        let rtkCommands: Set<String> = ["git", "ls", "cat", "grep", "rg", "find", "cargo", "npm", "pnpm", "pytest", "swift", "docker", "gh"]
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmedCmd.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let isSimpleCommand = !trimmedCmd.isEmpty && !trimmedCmd.contains(where: { ";|&><$\n`".contains($0) })
        let shouldWrap = wrapWithRTK && !rtkBin.isEmpty && firstToken != "rtk" && rtkCommands.contains(firstToken) && isSimpleCommand
        let finalCmd = shouldWrap ? "rtk \(trimmedCmd)" : command

        let fm = FileManager.default
        let trimmedWS = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDir: ObjCBool = false
        let cwd: String
        if trimmedWS.isEmpty {
            cwd = fm.homeDirectoryForCurrentUser.path
        } else if fm.fileExists(atPath: trimmedWS, isDirectory: &isDir), isDir.boolValue {
            cwd = trimmedWS
        } else {
            return LocalToolResult(toolName: "shell", commandUsed: finalCmd, usedRTK: shouldWrap, output: "Çalışma klasörü bulunamadı: \(trimmedWS)", succeeded: false, editRecord: nil)
        }

        final class ProcBox: @unchecked Sendable {
            private let lock = NSLock()
            private var proc: Process?
            func set(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
            func terminateTree() {
                lock.lock()
                let p = proc
                lock.unlock()
                guard let p, p.isRunning else { return }
                PowerShellTools.killProcessTree(pid: p.processIdentifier)
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

        let procBox = ProcBox()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", finalCmd]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAWOFFICE_") {
            env.removeValue(forKey: k)
        }
        env["PATH"] = extendedEnvPath()
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let timedOutBox = FlagBox()
        let exitOnce = FlagBox()

        do {
            let (exitCode, outResult, errResult) = try await withTaskCancellationHandler { () async throws -> (Int32, (data: Data, truncated: Bool), (data: Data, truncated: Bool)) in
                try Task.checkCancellation()
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + effectiveTimeout)
                timer.setEventHandler {
                    timedOutBox.value = true
                    procBox.terminateTree()
                }
                defer {
                    timer.cancel()
                    try? outPipe.fileHandleForReading.close()
                    try? errPipe.fileHandleForReading.close()
                }

                let outTask = Task.detached(priority: .userInitiated) {
                    readBoundedPipeData(from: outPipe.fileHandleForReading)
                }
                let errTask = Task.detached(priority: .userInitiated) {
                    readBoundedPipeData(from: errPipe.fileHandleForReading, maxBytes: 65_536)
                }

                let status: Int32 = try await withCheckedThrowingContinuation { cont in
                    p.terminationHandler = { finished in
                        if exitOnce.compareAndSetTrue() {
                            cont.resume(returning: finished.terminationStatus)
                        }
                    }
                    do {
                        try p.run()
                        procBox.set(p)
                        timer.resume()
                        if Task.isCancelled {
                            procBox.terminateTree()
                        }
                    } catch {
                        p.terminationHandler = nil
                        if exitOnce.compareAndSetTrue() {
                            cont.resume(throwing: error)
                        }
                    }
                }

                let outRes = await outTask.value
                let errRes = await errTask.value
                return (status, outRes, errRes)
            } onCancel: {
                procBox.terminateTree()
            }

            if Task.isCancelled {
                return LocalToolResult(toolName: "shell", commandUsed: finalCmd, usedRTK: shouldWrap, output: "⏹️ Komut iptal edildi.", succeeded: false, editRecord: nil)
            }

            let stdout = String(decoding: outResult.data, as: UTF8.self) + (outResult.truncated ? "\n... [stdout 256KB sınırına ulaştı]" : "")
            let stderr = String(decoding: errResult.data, as: UTF8.self) + (errResult.truncated ? "\n... [stderr 64KB sınırına ulaştı]" : "")
            let joined = [stdout, stderr.isEmpty ? "" : "[stderr]\n\(stderr)"].filter { !$0.isEmpty }.joined(separator: "\n")
            let clipped = joined.count > 10000 ? String(joined.prefix(10000)) + "\n... [kısaltıldı]" : joined

            if timedOutBox.value {
                let msg = "⏱️ Komut \(Int(effectiveTimeout)) sn zaman aşımına uğradı.\n\(clipped)"
                return LocalToolResult(toolName: "shell", commandUsed: finalCmd, usedRTK: shouldWrap, output: msg, succeeded: false, editRecord: nil)
            }
            return LocalToolResult(
                toolName: "shell",
                commandUsed: finalCmd,
                usedRTK: shouldWrap,
                output: clipped.isEmpty ? "(Çıktı yok · exit \(exitCode))" : clipped,
                succeeded: exitCode == 0,
                editRecord: nil
            )
        } catch is CancellationError {
            return LocalToolResult(toolName: "shell", commandUsed: finalCmd, usedRTK: shouldWrap, output: "⏹️ Komut iptal edildi.", succeeded: false, editRecord: nil)
        } catch {
            return LocalToolResult(toolName: "shell", commandUsed: finalCmd, usedRTK: shouldWrap, output: "Başlatılamadı: \(error.localizedDescription)", succeeded: false, editRecord: nil)
        }
    }

    private static func canonicalURL(for rawURL: URL) -> URL {
        let fm = FileManager.default
        var current = rawURL.standardizedFileURL
        var trailing: [String] = []
        while !fm.fileExists(atPath: current.path) {
            let last = current.lastPathComponent
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            trailing.append(last)
            current = parent
        }
        var resolved = current.resolvingSymlinksInPath().standardizedFileURL
        for comp in trailing.reversed() {
            resolved.appendPathComponent(comp, isDirectory: false)
        }
        return resolved.standardizedFileURL
    }

    private static func isPath(_ candidate: String, insideRoot root: String) -> Bool {
        let normCandidate = candidate.lowercased()
        let normRoot = root.lowercased()
        return normCandidate == normRoot || normCandidate.hasPrefix(normRoot.hasSuffix("/") ? normRoot : normRoot + "/")
    }

    static func resolveSafeURL(_ pathString: String, workspacePath: String, additionalAllowedRoots: [String] = []) -> URL? {
        let cleanWS = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWS.isEmpty else { return nil }

        var clean = pathString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.contains("\0") else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if clean == "~" {
            clean = home
        } else if clean.hasPrefix("~/") {
            clean = home + String(clean.dropFirst())
        } else if clean.hasPrefix("~") {
            // Reject `~otheruser` style paths
            return nil
        }

        let wsURL = canonicalURL(for: URL(fileURLWithPath: cleanWS))
        let isExplicitAbsoluteOrHome = clean.hasPrefix("/") || clean.hasPrefix("~")
        let rawTarget: URL
        if clean.hasPrefix("/") {
            rawTarget = URL(fileURLWithPath: clean)
        } else {
            rawTarget = (clean.isEmpty || clean == ".") ? wsURL : wsURL.appendingPathComponent(clean)
        }
        let target = canonicalURL(for: rawTarget)

        // Relative paths must never escape the workspace root via `..` traversal or outward symlinks.
        if !isExplicitAbsoluteOrHome && !isPath(target.path, insideRoot: wsURL.path) {
            return nil
        }

        // Block case-insensitive `.git` segments and critical macOS system directories
        if target.pathComponents.contains(where: { $0.lowercased() == ".git" }) {
            return nil
        }
        let lowerPath = target.path.lowercased()
        let blockedPrefixes = [
            "/system", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib",
            "/library/launchdaemons", "/library/launchagents",
            "/private/var/db", "/private/etc", "/etc", "/dev", "/cores"
        ]
        for b in blockedPrefixes where lowerPath == b || lowerPath.hasPrefix(b + "/") {
            return nil
        }

        var allowedRoots: [String] = [
            wsURL.path,
            canonicalURL(for: URL(fileURLWithPath: home).appendingPathComponent(".openclaw")).path,
            canonicalURL(for: URL(fileURLWithPath: NSTemporaryDirectory())).path
        ]
        for extra in additionalAllowedRoots {
            let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                allowedRoots.append(canonicalURL(for: URL(fileURLWithPath: trimmed)).path)
            }
        }

        guard allowedRoots.contains(where: { isPath(target.path, insideRoot: $0) }) else {
            return nil
        }
        return target
    }

    static func rollbackFileEdit(_ record: FileEditRecord, workspacePath: String) -> (Bool, String) {
        guard let targetURL = resolveSafeURL(record.relativePath, workspacePath: workspacePath) else {
            return (false, "Geçersiz dosya yolu.")
        }
        let wsCanon = canonicalURL(for: URL(fileURLWithPath: workspacePath))
        guard targetURL.path != wsCanon.path else {
            return (false, "Çalışma klasörünün kökü silinemez.")
        }
        let fm = FileManager.default
        if record.wasNewFile {
            do {
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
                return (true, "Yeni oluşturulan dosya geri alındı (silindi): \(record.relativePath)")
            } catch {
                return (false, "Silme hatası: \(error.localizedDescription)")
            }
        } else {
            let backupCanon = canonicalURL(for: URL(fileURLWithPath: record.backupPath))
            let allowedBackupRoots = [
                wsCanon.appendingPathComponent(".clawoffice-backups").path,
                canonicalURL(for: URL(fileURLWithPath: fm.homeDirectoryForCurrentUser.path).appendingPathComponent(".clawoffice-backups")).path,
                canonicalURL(for: URL(fileURLWithPath: NSTemporaryDirectory())).path
            ]
            guard allowedBackupRoots.contains(where: { isPath(backupCanon.path, insideRoot: $0) }),
                  fm.fileExists(atPath: backupCanon.path) else {
                return (false, "Geçerli yedek dosyası bulunamadı: \(record.backupPath)")
            }
            do {
                let oldData = try Data(contentsOf: backupCanon)
                try oldData.write(to: targetURL, options: [.atomic])
                return (true, "Eski sürüm geri yüklendi: \(record.relativePath)")
            } catch {
                return (false, "Geri yükleme hatası: \(error.localizedDescription)")
            }
        }
    }

    static func isReadOnlySafeShellCommand(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let forbiddenMeta = [";", "&&", "||", "|", ">", "<", "$(", "`", "\n", "\r", "&"]
        if forbiddenMeta.contains(where: { trimmed.contains($0) }) {
            return false
        }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let head = parts.first else { return false }
        let idx = head == "rtk" ? 1 : 0
        guard idx < parts.count else { return false }
        let exe = parts[idx].lowercased()
        let second = (idx + 1 < parts.count) ? parts[idx + 1].lowercased() : ""
        let readOnlyCommands: Set<String> = ["ls", "pwd", "cat", "head", "tail", "wc", "grep", "rg", "which", "echo", "stat", "file", "uname", "sw_vers", "df", "env", "date"]
        if readOnlyCommands.contains(exe) {
            return true
        }
        if exe == "git" {
            let safeGitSubcommands: Set<String> = ["status", "diff", "log", "branch", "show", "rev-parse", "ls-files"]
            return safeGitSubcommands.contains(second)
        }
        if exe == "swift" && (second == "--version" || second == "-version") {
            return true
        }
        return false
    }

    static func executeAgentTool(
        name: String,
        argument: String,
        agentName: String,
        workspacePath: String,
        useRTK: Bool,
        allowWrites: Bool
    ) async -> LocalToolResult {
        let resolvedName = canonicalToolName(name)
        switch resolvedName {
        case "list_dir":
            guard let target = resolveSafeURL(argument, workspacePath: workspacePath) else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Güvenlik politikası: Bu sistem veya kapsam dışı dizin listelenemez.", succeeded: false, editRecord: nil)
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.path, isDirectory: &isDir) else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Klasör bulunamadı: \(target.path)", succeeded: false, editRecord: nil)
            }
            guard isDir.boolValue else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Bu yol bir klasör değil (dosya): \(target.path). İçeriği görmek için read_file kullanın.", succeeded: false, editRecord: nil)
            }
            do {
                let rawItems = try fm.contentsOfDirectory(atPath: target.path).sorted()
                let formatted = rawItems.prefix(120).map { item -> String in
                    var subDir: ObjCBool = false
                    let full = target.appendingPathComponent(item).path
                    _ = fm.fileExists(atPath: full, isDirectory: &subDir)
                    return subDir.boolValue ? "\(item)/" : item
                }
                return LocalToolResult(toolName: name, commandUsed: target.path, usedRTK: false, output: formatted.isEmpty ? "(Boş klasör)" : formatted.joined(separator: "\n"), succeeded: true, editRecord: nil)
            } catch {
                return LocalToolResult(toolName: name, commandUsed: target.path, usedRTK: false, output: "Klasör okunamadı: \(error.localizedDescription)", succeeded: false, editRecord: nil)
            }

        case "find_files":
            let parts = argument.components(separatedBy: "|||")
            let rawPattern = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = rawPattern.isEmpty || rawPattern == "." ? "*" : rawPattern
            let subDirArg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "."
            guard let searchRoot = resolveSafeURL(subDirArg.isEmpty ? "." : subDirArg, workspacePath: workspacePath) else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Güvenlik politikası: Arama dizinine erişilemez.", succeeded: false, editRecord: nil)
            }
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: searchRoot.path, isDirectory: &isDir), isDir.boolValue else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Arama klasörü bulunamadı: \(searchRoot.path)", succeeded: false, editRecord: nil)
            }
            let ignoredDirs: Set<String> = [".git", ".build", "deriveddata", "node_modules", ".venv", "venv", ".clawoffice-backups", "build"]
            let rootPrefix = searchRoot.path.hasSuffix("/") ? searchRoot.path : searchRoot.path + "/"
            var matches: [String] = []
            let hasGlobChars = pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
            let lowerPat = pattern.lowercased()
            if let enumerator = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                while let item = enumerator.nextObject() as? URL {
                    let fname = item.lastPathComponent
                    if let vals = try? item.resourceValues(forKeys: [.isDirectoryKey]), vals.isDirectory == true {
                        if ignoredDirs.contains(fname.lowercased()) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    let rel = item.path.hasPrefix(rootPrefix) ? String(item.path.dropFirst(rootPrefix.count)) : fname
                    let isMatch: Bool
                    if hasGlobChars {
                        isMatch = fnmatch(pattern, fname, FNM_CASEFOLD) == 0 || fnmatch(pattern, rel, FNM_CASEFOLD) == 0
                    } else {
                        isMatch = rel.lowercased().contains(lowerPat) || fname.lowercased().contains(lowerPat)
                    }
                    if isMatch {
                        matches.append(rel)
                        if matches.count >= 120 { break }
                    }
                }
            }
            matches.sort()
            let limited = matches.prefix(80)
            let out = limited.isEmpty
                ? "Eşleşen dosya bulunamadı (\(pattern))."
                : "Bulunan dosyalar (\(matches.count)\(matches.count > 80 ? ", ilk 80" : "")):\n" + limited.joined(separator: "\n")
            return LocalToolResult(toolName: name, commandUsed: "\(pattern) in \(subDirArg)", usedRTK: false, output: out, succeeded: true, editRecord: nil)

        case "read_file":
            let readParts = argument.components(separatedBy: "|||")
            let fileArg = readParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let target = resolveSafeURL(fileArg, workspacePath: workspacePath),
                  let content = try? String(contentsOf: target, encoding: .utf8) else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Dosya okunamadı: \(argument)", succeeded: false, editRecord: nil)
            }
            let lines = content.components(separatedBy: "\n")
            if readParts.count >= 2, let rawStart = Int(readParts[1].trimmingCharacters(in: .whitespaces)) {
                let startLine = max(1, min(rawStart, max(1, lines.count)))
                let rawEnd = readParts.count >= 3 ? (Int(readParts[2].trimmingCharacters(in: .whitespaces)) ?? (startLine + 249)) : (startLine + 249)
                let endLine = max(startLine, min(rawEnd, lines.count))
                let numbered = (startLine...endLine).map { idx in "\(idx): \(lines[idx - 1])" }.joined(separator: "\n")
                let clipped = numbered.count > 14000 ? String(numbered.prefix(14000)) + "\n... [kısaltıldı]" : numbered
                let header = "[\(fileArg) · Satır \(startLine)-\(endLine) / \(lines.count)]\n"
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: header + clipped, succeeded: true, editRecord: nil)
            }
            if content.count > 14000 {
                var headLines: [String] = []
                var charTotal = 0
                for (idx, ln) in lines.enumerated() {
                    let formatted = "\(idx + 1): \(ln)"
                    if charTotal + formatted.count > 13500 { break }
                    headLines.append(formatted)
                    charTotal += formatted.count + 1
                }
                let shown = headLines.count
                let note = "\n... [Toplam \(lines.count) satır, 1-\(shown) gösterildi. Devamı için `<tool name=\"read_file\">\(fileArg)|||\(shown + 1)|||\(min(lines.count, shown + 250))</tool>` kullan]"
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: headLines.joined(separator: "\n") + note, succeeded: true, editRecord: nil)
            }
            return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: content, succeeded: true, editRecord: nil)

        case "search_code":
            let searchParts = argument.components(separatedBy: "|||")
            let query = searchParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Aranacak metin boş olamaz.", succeeded: false, editRecord: nil)
            }
            let subTarget = searchParts.count > 1 ? searchParts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "."
            var searchRootPath = workspacePath
            if !subTarget.isEmpty && subTarget != "." {
                guard let resolvedSub = resolveSafeURL(subTarget, workspacePath: workspacePath) else {
                    return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Güvenlik politikası: Bu dizinde arama yapılamaz.", succeeded: false, editRecord: nil)
                }
                searchRootPath = resolvedSub.path
            }
            let posixEscaped = shellSingleQuoted(query)
            let cmd = which("rg").isEmpty
                ? "grep -rnI --exclude-dir=.git --exclude-dir=.build --exclude-dir=build --exclude-dir=.venv --exclude-dir=venv --exclude-dir=node_modules --exclude-dir=.clawoffice-backups --exclude-dir=DerivedData -F -- \(posixEscaped) . | head -n 60; ec=${pipestatus[1]}; [ $ec -eq 1 ] && exit 0 || exit $ec"
                : "rg -n --no-heading --fixed-strings --glob '!.git' --glob '!.build' --glob '!build' --glob '!.venv' --glob '!venv' --glob '!*/.venv/**' --glob '!.clawoffice-backups' --glob '!node_modules' --glob '!DerivedData' --glob '!*.png' --glob '!*.icns' -- \(posixEscaped) . | head -n 60; ec=${pipestatus[1]}; [ $ec -eq 1 ] && exit 0 || exit $ec"
            let res = await runCommand(cmd, workspacePath: searchRootPath, wrapWithRTK: false)
            if res.succeeded && (res.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || res.output.contains("(Çıktı yok · exit 0)")) {
                return LocalToolResult(toolName: name, commandUsed: query, usedRTK: false, output: "Eşleşme bulunamadı.", succeeded: true, editRecord: nil)
            }
            return LocalToolResult(toolName: name, commandUsed: res.commandUsed, usedRTK: false, output: res.output, succeeded: res.succeeded, editRecord: nil)

        case "git_status":
            return await runCommand("git status --short --branch", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 8.0)

        case "git_diff":
            let cleanArg = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanArg.isEmpty || cleanArg == "." {
                return await runCommand("git diff --stat && git diff", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 10.0)
            }
            guard let target = resolveSafeURL(cleanArg, workspacePath: workspacePath) else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Güvenlik politikası: Bu yolun diff'i okunamaz.", succeeded: false, editRecord: nil)
            }
            return await runCommand("git diff -- \(shellSingleQuoted(target.path))", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 10.0)

        case "shell", "terminal", "bash", "zsh", "run_command", "exec":
            if !allowWrites && !isReadOnlySafeShellCommand(argument) {
                return LocalToolResult(
                    toolName: name,
                    commandUsed: argument,
                    usedRTK: false,
                    output: "Güvenlik engeli: Yazma izni kapalıyken yalnızca zincirsiz salt-okunur komutlara (ls, cat, rg, git status/diff/log vb.) izin verilir.",
                    succeeded: false,
                    editRecord: nil
                )
            }
            return await runCommand(argument, workspacePath: workspacePath, wrapWithRTK: useRTK)

        case "write_file":
            guard allowWrites else {
                return LocalToolResult(toolName: name, commandUsed: "write_file", usedRTK: false, output: "Güvenlik ayarı: Dosya yazma kapalı. Sanal Ofis üst çubuğundan etkinleştirin.", succeeded: false, editRecord: nil)
            }
            let parts = argument.components(separatedBy: "|||")
            guard parts.count >= 2 else {
                return LocalToolResult(toolName: name, commandUsed: "write_file", usedRTK: false, output: "Format hatası. Beklenen: yol/dosya|||içerik", succeeded: false, editRecord: nil)
            }
            let relPath = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let newContent = parts.dropFirst().joined(separator: "|||")
            return performSafeWrite(relPath: relPath, newContent: newContent, agentName: agentName, workspacePath: workspacePath, summary: "Dosya yazıldı")

        case "patch_file":
            guard allowWrites else {
                return LocalToolResult(toolName: name, commandUsed: "patch_file", usedRTK: false, output: "Güvenlik ayarı: Dosya yazma kapalı.", succeeded: false, editRecord: nil)
            }
            let parts = argument.components(separatedBy: "|||")
            guard parts.count >= 3 else {
                return LocalToolResult(toolName: name, commandUsed: "patch_file", usedRTK: false, output: "Format hatası. Beklenen: yol/dosya|||eski|||yeni", succeeded: false, editRecord: nil)
            }
            let relPath = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let oldSnippet = parts[1]
            let newSnippet = parts.dropFirst(2).joined(separator: "|||")
            guard let target = resolveSafeURL(relPath, workspacePath: workspacePath),
                  let current = try? String(contentsOf: target, encoding: .utf8) else {
                return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Yamalanacak dosya okunamadı: \(relPath)", succeeded: false, editRecord: nil)
            }
            if oldSnippet == newSnippet {
                return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Yama atlandı: Eski ve yeni kod parçaları birebir aynı.", succeeded: false, editRecord: nil)
            }

            switch smartPatchDetailed(current: current, oldSnippet: oldSnippet, newSnippet: newSnippet) {
            case .applied(let updated):
                return performSafeWrite(relPath: relPath, newContent: updated, agentName: agentName, workspacePath: workspacePath, summary: "Akıllı yama (patch) uygulandı")
            case .ambiguous(let count):
                return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Belirsiz yama: Eski kod parçası dosyada \(count) kez geçiyor; daha fazla çevre bağlamı ekleyin: \(relPath)", succeeded: false, editRecord: nil)
            case .notFound:
                return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Eski kod parçası dosyada bulunamadı (whitespace ve satır sonu toleransı denendi): \(relPath)", succeeded: false, editRecord: nil)
            }

        case "multi_patch":
            guard allowWrites else {
                return LocalToolResult(toolName: name, commandUsed: "multi_patch", usedRTK: false, output: "Güvenlik ayarı: Dosya yazma kapalı.", succeeded: false, editRecord: nil)
            }
            let parts = argument.components(separatedBy: "|||")
            guard parts.count >= 3 && (parts.count - 1).isMultiple(of: 2) else {
                return LocalToolResult(toolName: name, commandUsed: "multi_patch", usedRTK: false, output: "Format hatası. Beklenen: yol/dosya|||eski1|||yeni1|||eski2|||yeni2...", succeeded: false, editRecord: nil)
            }
            let relPath = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let target = resolveSafeURL(relPath, workspacePath: workspacePath),
                  var workingContent = try? String(contentsOf: target, encoding: .utf8) else {
                return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Çoklu yama dosyası okunamadı: \(relPath)", succeeded: false, editRecord: nil)
            }
            let pairCount = (parts.count - 1) / 2
            var appliedCount = 0
            for idx in 0..<pairCount {
                let oldBlock = parts[1 + idx * 2]
                let newBlock = parts[2 + idx * 2]
                if oldBlock == newBlock { continue }
                switch smartPatchDetailed(current: workingContent, oldSnippet: oldBlock, newSnippet: newBlock) {
                case .applied(let updated):
                    workingContent = updated
                    appliedCount += 1
                case .ambiguous(let count):
                    return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Çoklu yama blok #\(idx + 1) belirsiz (\(count) eşleşme): \(relPath)", succeeded: false, editRecord: nil)
                case .notFound:
                    return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Çoklu yama blok #\(idx + 1) bulunamadı: \(relPath)", succeeded: false, editRecord: nil)
                }
            }
            guard appliedCount > 0 else {
                return LocalToolResult(toolName: name, commandUsed: relPath, usedRTK: false, output: "Çoklu yama atlandı: Net değişiklik yok.", succeeded: false, editRecord: nil)
            }
            return performSafeWrite(relPath: relPath, newContent: workingContent, agentName: agentName, workspacePath: workspacePath, summary: "Çoklu akıllı yama (\(appliedCount) blok)")

        case "graphify_query":
            let escaped = shellSingleQuoted(argument.trimmingCharacters(in: .whitespacesAndNewlines))
            return await runCommand("graphify query \(escaped)", workspacePath: workspacePath, wrapWithRTK: false)

        case "graphify_update":
            guard allowWrites else {
                return LocalToolResult(toolName: name, commandUsed: "graphify_update", usedRTK: false, output: "Güvenlik ayarı: Dosya yazma kapalı.", succeeded: false, editRecord: nil)
            }
            return await runCommand("graphify update .", workspacePath: workspacePath, wrapWithRTK: false)

        case "graphify_path":
            let parts = argument.components(separatedBy: "|||")
            if parts.count >= 2 {
                let a = shellSingleQuoted(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
                let b = shellSingleQuoted(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                return await runCommand("graphify path \(a) \(b)", workspacePath: workspacePath, wrapWithRTK: false)
            }
            let single = shellSingleQuoted(argument.trimmingCharacters(in: .whitespacesAndNewlines))
            return await runCommand("graphify path \(single)", workspacePath: workspacePath, wrapWithRTK: false)

        case "open_app":
            let rawApp = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawApp.isEmpty, !rawApp.hasPrefix("-") else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Geçersiz uygulama adı: \(argument)", succeeded: false, editRecord: nil)
            }
            let cleanApp = shellSingleQuoted(rawApp)
            return await runCommand("open -a \(cleanApp)", workspacePath: workspacePath, wrapWithRTK: false)

        case "open_path":
            let rawPath = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty, !rawPath.hasPrefix("-"),
                  let safeTarget = resolveSafeURL(rawPath, workspacePath: workspacePath) else {
                return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Güvenlik engeli: Bu yol açılamaz (\(argument)).", succeeded: false, editRecord: nil)
            }
            return await runCommand("open -- \(shellSingleQuoted(safeTarget.path))", workspacePath: workspacePath, wrapWithRTK: false)

        case "system_info":
            let cmd = "echo '=== macOS SİSTEM BİLGİSİ ===' && sw_vers && echo '--- Disk Durumu ---' && (df -h / /Volumes/DATA 2>/dev/null || df -h /) && echo '--- Geliştirici Ortamı ---' && (which swift xcodebuild code brew rtk graphify 2>/dev/null || true)"
            return await runCommand(cmd, workspacePath: workspacePath, wrapWithRTK: false)

        case "rebuild_and_restart", "self_rebuild":
            guard allowWrites else {
                return LocalToolResult(toolName: name, commandUsed: name, usedRTK: false, output: "Güvenlik ayarı: Dosya yazma/derleme kapalı.", succeeded: false, editRecord: nil)
            }
            let buildRes = await performSelfRebuild(workspacePath: workspacePath, timeoutSeconds: 240)
            if buildRes.0 {
                return LocalToolResult(toolName: name, commandUsed: "build_app.sh", usedRTK: false, output: "✅ Crims Office release derlemesi tamamlandı, paketlenip yeniden başlatılıyor!", succeeded: true, editRecord: nil)
            } else {
                return LocalToolResult(toolName: name, commandUsed: "swift build -c release", usedRTK: false, output: "❌ \(buildRes.1)", succeeded: false, editRecord: nil)
            }

        case "restart_app":
            guard allowWrites else {
                return LocalToolResult(toolName: name, commandUsed: name, usedRTK: false, output: "Güvenlik ayarı: Yeniden başlatma salt-okunur modda kapalı.", succeeded: false, editRecord: nil)
            }
            triggerAppRelaunch()
            return LocalToolResult(toolName: name, commandUsed: "restart_app", usedRTK: false, output: "Crims Office yeniden başlatılıyor...", succeeded: true, editRecord: nil)

        default:
            return LocalToolResult(toolName: name, commandUsed: argument, usedRTK: false, output: "Bilinmeyen veya izin verilmeyen araç: '\(name)'.", succeeded: false, editRecord: nil)
        }
    }

    private static func resolveSelfProjectDirectory(preferred: String?) -> String? {
        let fm = FileManager.default
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
        let candidates = [
            preferred,
            AppConfig.detectDefaultWorkspacePath(),
            fm.currentDirectoryPath,
            bundleParent,
            "/Volumes/DATA/Builds/ClawOffice"
        ].compactMap { $0 }
        for cand in candidates where !cand.isEmpty {
            let pkg = URL(fileURLWithPath: cand).appendingPathComponent("Package.swift").path
            let script = URL(fileURLWithPath: cand).appendingPathComponent("build_app.sh").path
            if fm.fileExists(atPath: pkg) && fm.fileExists(atPath: script) {
                return cand
            }
        }
        return nil
    }

    static func performSelfRebuild(workspacePath: String = AppConfig.detectDefaultWorkspacePath(), timeoutSeconds: TimeInterval = 240) async -> (Bool, String) {
        guard let projectDir = resolveSelfProjectDirectory(preferred: workspacePath) else {
            return (false, "Crims Office kaynak proje klasörü (Package.swift + build_app.sh) bulunamadı.")
        }
        let buildRes = await runCommand("swift build -c release", workspacePath: projectDir, wrapWithRTK: false, timeoutSeconds: timeoutSeconds)
        guard buildRes.succeeded else {
            return (false, "Derleme başarısız:\n\(buildRes.output)")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let quotedDir = shellSingleQuoted(projectDir)
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; cd \(quotedDir) && /bin/bash ./build_app.sh --skip-build > /tmp/clawoffice-rebuild.log 2>&1"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return (false, "Paketleme betiği başlatılamadı: \(error.localizedDescription)")
        }
        ConfigStore.shared.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
        return (true, "Başarıyla derlendi, paketleniyor ve yeniden başlatılıyor.")
    }

    static func triggerAppRelaunch() {
        let fm = FileManager.default
        let detectedBuildApp = resolveSelfProjectDirectory(preferred: nil).map { $0 + "/build/Crims Office.app" }
        let targetApp: String
        if Bundle.main.bundlePath.hasSuffix(".app") {
            targetApp = Bundle.main.bundlePath
        } else if fm.fileExists(atPath: "/Applications/Crims Office.app") {
            targetApp = "/Applications/Crims Office.app"
        } else if let detectedBuildApp, fm.fileExists(atPath: detectedBuildApp) {
            targetApp = detectedBuildApp
        } else {
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(shellSingleQuoted(targetApp)) >> /tmp/clawoffice-rebuild.log 2>&1"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        ConfigStore.shared.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    private static func performSafeWrite(relPath: String, newContent: String, agentName: String, workspacePath: String, summary: String) -> LocalToolResult {
        guard let targetURL = resolveSafeURL(relPath, workspacePath: workspacePath) else {
            return LocalToolResult(toolName: "write_file", commandUsed: relPath, usedRTK: false, output: "Güvenlik engeli: Bu dizine yazılamaz.", succeeded: false, editRecord: nil)
        }
        let fm = FileManager.default
        var targetIsDir: ObjCBool = false
        if fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir), targetIsDir.boolValue {
            return LocalToolResult(toolName: "write_file", commandUsed: relPath, usedRTK: false, output: "Yazma hatası: Hedef bir klasör (\(targetURL.path)).", succeeded: false, editRecord: nil)
        }

        let existed = fm.fileExists(atPath: targetURL.path)
        var originalPosixPerms: Any? = nil
        var backupPath = ""
        let wsURL = canonicalURL(for: URL(fileURLWithPath: workspacePath))
        let wsPrefix = wsURL.path.hasSuffix("/") ? wsURL.path : wsURL.path + "/"

        if existed {
            originalPosixPerms = (try? fm.attributesOfItem(atPath: targetURL.path))?[.posixPermissions]
            let home = fm.homeDirectoryForCurrentUser.path
            let backupDir: URL
            if targetURL.path == wsURL.path || targetURL.path.hasPrefix(wsPrefix) {
                backupDir = wsURL.appendingPathComponent(".clawoffice-backups")
            } else {
                backupDir = URL(fileURLWithPath: home).appendingPathComponent(".clawoffice-backups")
            }
            do {
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let stampMs = Int(Date().timeIntervalSince1970 * 1000)
                let uniqueTag = String(UUID().uuidString.prefix(4))
                let safeName = targetURL.lastPathComponent.replacingOccurrences(of: "/", with: "__")
                let backupURL = backupDir.appendingPathComponent("\(stampMs)_\(uniqueTag)_\(safeName)")
                try fm.copyItem(at: targetURL, to: backupURL)
                backupPath = backupURL.path
            } catch {
                return LocalToolResult(toolName: "write_file", commandUsed: relPath, usedRTK: false, output: "Yedek alınamadığı için yazma iptal edildi: \(error.localizedDescription)", succeeded: false, editRecord: nil)
            }
        }

        let displayRelPath: String
        if targetURL.path.hasPrefix(wsPrefix) {
            displayRelPath = String(targetURL.path.dropFirst(wsPrefix.count))
        } else {
            displayRelPath = relPath
        }

        do {
            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newContent.write(to: targetURL, atomically: true, encoding: .utf8)
            if let perms = originalPosixPerms {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: targetURL.path)
            }
            let rec = FileEditRecord(
                agentName: agentName,
                relativePath: displayRelPath,
                backupPath: backupPath,
                wasNewFile: !existed,
                summary: "\(summary) (\(newContent.count) karakter)"
            )
            return LocalToolResult(
                toolName: "write_file",
                commandUsed: relPath,
                usedRTK: false,
                output: "Başarıyla kaydedildi: \(relPath) (\(existed ? "Otomatik yedek alındı" : "Yeni dosya")).",
                succeeded: true,
                editRecord: rec
            )
        } catch {
            return LocalToolResult(toolName: "write_file", commandUsed: relPath, usedRTK: false, output: "Yazma hatası: \(error.localizedDescription)", succeeded: false, editRecord: nil)
        }
    }

    enum SmartPatchOutcome {
        case applied(String)
        case notFound
        case ambiguous(Int)
    }

    static func smartPatchDetailed(current: String, oldSnippet: String, newSnippet: String) -> SmartPatchOutcome {
        guard !oldSnippet.isEmpty else { return .notFound }
        let usesCRLF = current.contains("\r\n")
        let styledNew = usesCRLF
            ? newSnippet.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            : newSnippet.replacingOccurrences(of: "\r\n", with: "\n")

        func matchRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
            var out: [Range<String.Index>] = []
            var pos = haystack.startIndex
            while let r = haystack.range(of: needle, range: pos..<haystack.endIndex) {
                out.append(r)
                pos = r.upperBound
                if out.count > 4 { break }
            }
            return out
        }

        let exactMatches = matchRanges(of: oldSnippet, in: current)
        if exactMatches.count == 1 {
            return .applied(current.replacingCharacters(in: exactMatches[0], with: styledNew))
        } else if exactMatches.count > 1 {
            return .ambiguous(exactMatches.count)
        }

        let normCurrent = current.replacingOccurrences(of: "\r\n", with: "\n")
        let normOld = oldSnippet.replacingOccurrences(of: "\r\n", with: "\n")
        let normNew = newSnippet.replacingOccurrences(of: "\r\n", with: "\n")
        let normMatches = matchRanges(of: normOld, in: normCurrent)
        if normMatches.count == 1 {
            let result = normCurrent.replacingCharacters(in: normMatches[0], with: normNew)
            return .applied(usesCRLF ? result.replacingOccurrences(of: "\n", with: "\r\n") : result)
        } else if normMatches.count > 1 {
            return .ambiguous(normMatches.count)
        }

        let currentLines = normCurrent.components(separatedBy: "\n")
        var rawOldLines = normOld.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        while rawOldLines.first?.isEmpty == true { rawOldLines.removeFirst() }
        while rawOldLines.last?.isEmpty == true { rawOldLines.removeLast() }
        guard !rawOldLines.isEmpty, currentLines.count >= rawOldLines.count else { return .notFound }

        var lineMatches: [Int] = []
        for i in 0...(currentLines.count - rawOldLines.count) {
            var match = true
            for j in 0..<rawOldLines.count {
                if currentLines[i + j].trimmingCharacters(in: .whitespaces) != rawOldLines[j] {
                    match = false
                    break
                }
            }
            if match {
                lineMatches.append(i)
                if lineMatches.count > 4 { break }
            }
        }
        if lineMatches.count == 1, let startIdx = lineMatches.first {
            var newLines = currentLines
            let replacementLines = normNew.components(separatedBy: "\n")
            newLines.replaceSubrange(startIdx..<(startIdx + rawOldLines.count), with: replacementLines)
            let joined = newLines.joined(separator: "\n")
            return .applied(usesCRLF ? joined.replacingOccurrences(of: "\n", with: "\r\n") : joined)
        } else if lineMatches.count > 1 {
            return .ambiguous(lineMatches.count)
        }
        return .notFound
    }

    static func smartPatch(current: String, oldSnippet: String, newSnippet: String) -> String? {
        if case .applied(let updated) = smartPatchDetailed(current: current, oldSnippet: oldSnippet, newSnippet: newSnippet) {
            return updated
        }
        return nil
    }
}

enum LineDiffUtility {
    static func unifiedDiff(oldText: String, newText: String, maxLines: Int = 80) -> [String] {
        let oldLines = oldText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let newLines = newText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        if diff.isEmpty { return ["(Değişiklik yok)"] }

        var changedOldIndices = Set<Int>()
        var changedNewIndices = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): changedOldIndices.insert(offset)
            case .insert(let offset, _, _): changedNewIndices.insert(offset)
            }
        }

        let startOld = max(0, (changedOldIndices.min() ?? 0) - 2)
        let endOld = min(oldLines.count, (changedOldIndices.max() ?? 0) + 3)
        let startNew = max(0, (changedNewIndices.min() ?? 0) - 2)
        let endNew = min(newLines.count, (changedNewIndices.max() ?? 0) + 3)

        var output: [String] = [
            "@@ -\(startOld + 1),\(max(0, endOld - startOld)) +\(startNew + 1),\(max(0, endNew - startNew)) @@"
        ]

        var oi = startOld
        var ni = startNew
        while oi < endOld || ni < endNew {
            if oi < endOld && changedOldIndices.contains(oi) {
                output.append("- \(oi + 1): \(oldLines[oi])")
                oi += 1
            } else if ni < endNew && changedNewIndices.contains(ni) {
                output.append("+ \(ni + 1): \(newLines[ni])")
                ni += 1
            } else if oi < endOld && ni < endNew {
                output.append("  \(oi + 1): \(oldLines[oi])")
                oi += 1
                ni += 1
            } else if oi < endOld {
                output.append("  \(oi + 1): \(oldLines[oi])")
                oi += 1
            } else {
                output.append("  \(ni + 1): \(newLines[ni])")
                ni += 1
            }
        }

        if output.count > maxLines {
            let remaining = output.count - maxLines
            output = Array(output.prefix(maxLines)) + ["... [\(remaining) satır daha]"]
        }
        return output
    }
}
