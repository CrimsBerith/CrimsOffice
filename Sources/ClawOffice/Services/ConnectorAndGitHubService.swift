import Foundation

struct EcosystemCheckReport: Sendable {
    var topic: String
    var localSkillMatches: [String]
    var localAgentSkillMatches: [String]
    var connectorMatches: [ServiceConnector]
    var githubMatches: [GitHubRepoCandidate]
    var hasStrongMatch: Bool
    var summaryMarkdown: String
}

struct SecurityAuditResult: Sendable {
    var level: String // "TEMİZ" | "DİKKAT" | "RİSKLİ"
    var findings: [String]
    var isSafeToAutoInstall: Bool
}

enum ConnectorAndGitHubService {

    // MARK: - GitHub Repository & Skill Search

    static func parseOwnerRepo(from raw: String) -> (owner: String, repo: String, subpath: String?, branch: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let url = URL(string: trimmed),
                  let host = url.host?.lowercased(),
                  host == "github.com" || host == "www.github.com" || host == "raw.githubusercontent.com" else {
                return nil
            }
            var parts = url.pathComponents.filter { $0 != "/" }
            if host == "raw.githubusercontent.com" {
                guard parts.count >= 4 else { return nil }
                let owner = parts[0]
                let repo = parts[1].replacingOccurrences(of: ".git", with: "")
                let branch = parts[2]
                let sub = parts.dropFirst(3).joined(separator: "/")
                return (owner, repo, sub, branch)
            }
            guard parts.count >= 2 else { return nil }
            let owner = parts[0]
            let repo = parts[1].replacingOccurrences(of: ".git", with: "")
            parts.removeFirst(2)
            if parts.count >= 2 && (parts[0] == "blob" || parts[0] == "tree") {
                let branch = parts[1]
                let sub = parts.dropFirst(2).joined(separator: "/")
                return (owner, repo, sub.isEmpty ? nil : sub, branch)
            }
            return (owner, repo, nil, nil)
        }

        let cleaned = trimmed.replacingOccurrences(of: ".git", with: "")
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        let validPattern = #"^[A-Za-z0-9._-]+$"#
        guard owner.range(of: validPattern, options: .regularExpression) != nil,
              repo.range(of: validPattern, options: .regularExpression) != nil else {
            return nil
        }
        let subpath = parts.count > 2 ? parts.dropFirst(2).joined(separator: "/") : nil
        return (owner, repo, subpath, nil)
    }

    static func searchGitHubRepos(query: String, kind: String = "all", limit: Int = 8) async -> (candidates: [GitHubRepoCandidate], formatted: String, error: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([], "GitHub araması için sorgu metni boş olamaz.", "Boş sorgu")
        }

        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerQ = trimmed.lowercased()
        var effectiveQuery = trimmed
        if normalizedKind == "mcp" && !lowerQ.contains("mcp") {
            effectiveQuery += " mcp server"
        } else if normalizedKind == "skill" && !lowerQ.contains("skill") {
            effectiveQuery += " skill"
        } else if normalizedKind == "connector" && !lowerQ.contains("api") && !lowerQ.contains("mcp") && !lowerQ.contains("connector") {
            effectiveQuery += " api mcp connector"
        }

        let clampedLimit = max(1, min(12, limit))

        // Prefer authenticated `gh` CLI when available so private/org repos and higher rate limits work seamlessly.
        if let ghData = await runGHAPI(path: "search/repositories?q=\(percentEncoded(effectiveQuery))&sort=stars&order=desc&per_page=\(clampedLimit)") {
            let parsed = decodeSearchResponse(data: ghData, defaultHintMCP: normalizedKind == "mcp", defaultHintSkill: normalizedKind == "skill")
            if !parsed.isEmpty {
                return (parsed, formatCandidates(parsed, query: effectiveQuery), nil)
            }
        }

        var comps = URLComponents(string: "https://api.github.com/search/repositories")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: effectiveQuery),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(clampedLimit))
        ]
        guard let url = comps.url else {
            return ([], "GitHub arama URL'si oluşturulamadı.", "URL hatası")
        }
        do {
            let data = try await fetchGitHubAPI(url: url)
            let parsed = decodeSearchResponse(data: data, defaultHintMCP: normalizedKind == "mcp", defaultHintSkill: normalizedKind == "skill")
            if parsed.isEmpty {
                return ([], "GitHub'da '\(effectiveQuery)' için eşleşen depo bulunamadı.", nil)
            }
            return (parsed, formatCandidates(parsed, query: effectiveQuery), nil)
        } catch {
            return ([], "GitHub araması başarısız: \(error.localizedDescription)", error.localizedDescription)
        }
    }

    private static func decodeSearchResponse(data: Data, defaultHintMCP: Bool, defaultHintSkill: Bool) -> [GitHubRepoCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let fullName = item["full_name"] as? String,
                  let htmlURL = item["html_url"] as? String else { return nil }
            let desc = (item["description"] as? String) ?? ""
            let stars = (item["stargazers_count"] as? Int) ?? 0
            let updated = String(((item["updated_at"] as? String) ?? "").prefix(10))
            let branch = (item["default_branch"] as? String) ?? "main"
            let licObj = item["license"] as? [String: Any]
            let license = (licObj?["spdx_id"] as? String) ?? (licObj?["name"] as? String) ?? "-"
            let topics = (item["topics"] as? [String]) ?? []
            let combined = (fullName + " " + desc + " " + topics.joined(separator: " ")).lowercased()
            let hasSkill = defaultHintSkill || combined.contains("skill") || combined.contains("openclaw") || combined.contains("claude-skill") || combined.contains("agent-skill")
            let hasMCP = defaultHintMCP || combined.contains("mcp") || combined.contains("modelcontextprotocol")
            return GitHubRepoCandidate(
                fullName: fullName,
                description: desc,
                htmlURL: htmlURL,
                stars: stars,
                updatedAt: updated,
                license: license,
                defaultBranch: branch,
                hasSkillMD: hasSkill,
                hasMCPHint: hasMCP,
                topics: topics
            )
        }
    }

    private static func formatCandidates(_ items: [GitHubRepoCandidate], query: String) -> String {
        var lines = ["🔎 GitHub Arama Sonuçları (`\(query)` · \(items.count) sonuç):"]
        for (i, r) in items.enumerated() {
            var tags: [String] = []
            if r.hasMCPHint { tags.append("MCP") }
            if r.hasSkillMD { tags.append("Skill") }
            let tagStr = tags.isEmpty ? "" : " [\(tags.joined(separator: "/"))]"
            lines.append("\(i + 1). ★\(r.stars) **\(r.fullName)**\(tagStr) · Lisans: \(r.license) · Güncelleme: \(r.updatedAt)")
            if !r.description.isEmpty {
                lines.append("   \(r.description)")
            }
            lines.append("   \(r.htmlURL)")
        }
        lines.append("\nİncelemek için `<tool name=\"inspect_github_repo\">owner/repo</tool>`, SKILL.md kurmak için `<tool name=\"install_github_skill\">owner/repo</tool>` kullan.")
        return lines.joined(separator: "\n")
    }

    // MARK: - GitHub Repo Inspection & Security Audit

    static func inspectGitHubRepo(target: String) async -> (succeeded: Bool, summary: String) {
        guard let parsed = parseOwnerRepo(from: target) else {
            return (false, "Geçersiz GitHub depo referansı: '\(target)'. Örnek: hostinger/api-mcp-server veya https://github.com/owner/repo")
        }
        let repoSlug = "\(parsed.owner)/\(parsed.repo)"
        guard let repoURL = URL(string: "https://api.github.com/repos/\(repoSlug)") else {
            return (false, "Repo URL oluşturulamadı.")
        }

        do {
            let repoData = try await fetchGitHubDataPreferringGH(apiPath: "repos/\(repoSlug)", fallbackURL: repoURL)
            guard let repoObj = try? JSONSerialization.jsonObject(with: repoData) as? [String: Any],
                  let fullName = repoObj["full_name"] as? String else {
                return (false, "Depo metadata çözümlenemedi: \(repoSlug)")
            }
            let desc = (repoObj["description"] as? String) ?? "-"
            let stars = (repoObj["stargazers_count"] as? Int) ?? 0
            let defaultBranch = parsed.branch ?? (repoObj["default_branch"] as? String) ?? "main"
            let updatedAt = String(((repoObj["pushed_at"] as? String) ?? "").prefix(10))
            let licObj = repoObj["license"] as? [String: Any]
            let license = (licObj?["spdx_id"] as? String) ?? "Belirtilmemiş"
            let archived = (repoObj["archived"] as? Bool) == true

            // Inspect root files
            var rootFiles: [String] = []
            if let contURL = URL(string: "https://api.github.com/repos/\(repoSlug)/contents?ref=\(percentEncoded(defaultBranch))"),
               let contData = try? await fetchGitHubDataPreferringGH(apiPath: "repos/\(repoSlug)/contents", fallbackURL: contURL),
               let arr = try? JSONSerialization.jsonObject(with: contData) as? [[String: Any]] {
                rootFiles = arr.compactMap { $0["name"] as? String }
            }

            let hasSkillRoot = rootFiles.contains(where: { $0.uppercased() == "SKILL.MD" })
            let hasPackageJSON = rootFiles.contains("package.json")
            let hasPyproject = rootFiles.contains("pyproject.toml")
            let hasSkillsFolder = rootFiles.contains(where: { $0.lowercased() == "skills" })

            // Fetch SKILL.md or README.md
            var skillPreview = ""
            if hasSkillRoot,
               let raw = await fetchRawGitHubFile(owner: parsed.owner, repo: parsed.repo, branch: defaultBranch, path: "SKILL.md") {
                skillPreview = raw
            } else if let sub = parsed.subpath,
                      let raw = await fetchRawGitHubFile(owner: parsed.owner, repo: parsed.repo, branch: defaultBranch, path: sub) {
                skillPreview = raw
            }

            var readmePreview = ""
            for cand in ["README.md", "readme.md"] where rootFiles.contains(cand) || rootFiles.isEmpty {
                if let raw = await fetchRawGitHubFile(owner: parsed.owner, repo: parsed.repo, branch: defaultBranch, path: cand) {
                    readmePreview = raw
                    break
                }
            }

            var pkgSummary = ""
            if hasPackageJSON,
               let rawPkg = await fetchRawGitHubFile(owner: parsed.owner, repo: parsed.repo, branch: defaultBranch, path: "package.json"),
               let pkgData = rawPkg.data(using: .utf8),
               let pkgObj = try? JSONSerialization.jsonObject(with: pkgData) as? [String: Any] {
                let pkgName = (pkgObj["name"] as? String) ?? "-"
                let binField = pkgObj["bin"]
                let engines = pkgObj["engines"] as? [String: Any]
                let nodeReq = (engines?["node"] as? String) ?? "-"
                pkgSummary = "npm paketi: `\(pkgName)` · Node: \(nodeReq) · bin: \(binField != nil ? "var" : "yok")"
            }

            let auditTarget = [skillPreview, readmePreview].joined(separator: "\n")
            let audit = securityAuditMarkdown(content: auditTarget)

            var out: [String] = [
                "📦 GitHub Depo İncelemesi: **\(fullName)**",
                "• ★ \(stars) yıldız · Lisans: \(license) · Son push: \(updatedAt)\(archived ? " · ⚠️ ARŞİVLENMİŞ" : "")",
                "• Açıklama: \(desc)",
                "• Kök dosyalar: \(rootFiles.prefix(20).joined(separator: ", "))",
                "• Yetenek/MCP Sinyalleri: SKILL.md=\(hasSkillRoot ? "VAR" : (hasSkillsFolder ? "skills/ klasörü var" : "yok")), package.json=\(hasPackageJSON ? "var" : "yok"), pyproject=\(hasPyproject ? "var" : "yok")",
                pkgSummary.isEmpty ? nil : "• \(pkgSummary)",
                "• Güvenlik Ön Taraması: **\(audit.level)**" + (audit.findings.isEmpty ? " (Tehlikeli kurulum/eval kalıbı görülmedi)" : " — " + audit.findings.joined(separator: "; "))
            ].compactMap { $0 }

            if !skillPreview.isEmpty {
                out.append("\n[SKILL.md Önizlemesi]\n" + String(skillPreview.prefix(3200)))
            }
            if !readmePreview.isEmpty {
                out.append("\n[README.md Özeti]\n" + String(readmePreview.prefix(3200)))
            }
            if hasSkillRoot || hasSkillsFolder {
                out.append("\nKurmak için: `<tool name=\"install_github_skill\">\(repoSlug)</tool>`")
            }
            return (true, out.joined(separator: "\n"))
        } catch {
            return (false, "GitHub depo incelenemedi (\(repoSlug)): \(error.localizedDescription)")
        }
    }

    static func securityAuditMarkdown(content: String) -> SecurityAuditResult {
        let lower = content.lowercased()
        let criticalPatterns: [(pattern: String, label: String)] = [
            (#"curl\s+[^|\n]+\|\s*(?:ba)?sh"#, "Pipe-to-shell kurulum (`curl | sh`) içeriyor"),
            (#"wget\s+[^|\n]+\|\s*(?:ba)?sh"#, "Pipe-to-shell kurulum (`wget | sh`) içeriyor"),
            (#"rm\s+-rf\s+/(?:\s|$|\*)"#, "Yıkıcı kök dizin silme komutu içeriyor"),
            (#"rm\s+-rf\s+~/"#, "Ev dizini silme komutu içeriyor"),
            (#"base64\s+-d[^\n]*\|\s*(?:ba)?sh"#, "Gizlenmiş (base64 decode) shell çalıştırma içeriyor"),
            (#"eval\s*\(\s*(?:atob|buffer\.from)"#, "Gizlenmiş dinamik eval kodu içeriyor")
        ]
        var findings: [String] = []
        var critical = false
        for item in criticalPatterns {
            if lower.range(of: item.pattern, options: .regularExpression) != nil {
                findings.append(item.label)
                critical = true
            }
        }
        let warnPatterns: [(String, String)] = [
            ("sudo ", "Ayrıcalıklı `sudo` kullanımı içeriyor"),
            ("chmod 777", "Geniş dosya izni (`chmod 777`) içeriyor")
        ]
        for (pat, label) in warnPatterns where lower.contains(pat) {
            findings.append(label)
        }
        if critical {
            return SecurityAuditResult(level: "RİSKLİ", findings: findings, isSafeToAutoInstall: false)
        }
        if !findings.isEmpty {
            return SecurityAuditResult(level: "DİKKAT", findings: findings, isSafeToAutoInstall: true)
        }
        return SecurityAuditResult(level: "TEMİZ", findings: [], isSafeToAutoInstall: true)
    }

    // MARK: - Install Skill From GitHub

    static func installSkillFromGitHub(
        source: String,
        slugOverride: String? = nil,
        openClawHome: String
    ) async -> (succeeded: Bool, message: String, installedPath: String?) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Kurulacak GitHub repo veya raw SKILL.md URL'si belirtilmedi.", nil)
        }

        // Handle direct raw.githubusercontent.com / gist.githubusercontent.com URL
        if let directURL = URL(string: trimmed),
           let host = directURL.host?.lowercased(),
           (host == "raw.githubusercontent.com" || host == "gist.githubusercontent.com"),
           directURL.scheme?.lowercased() == "https" {
            do {
                let rawText = try await fetchText(url: directURL)
                return finalizeSkillInstall(rawMarkdown: rawText, defaultSlug: slugOverride ?? directURL.deletingLastPathComponent().lastPathComponent, sourceURL: trimmed, openClawHome: openClawHome)
            } catch {
                return (false, "Skill URL indirilemedi: \(error.localizedDescription)", nil)
            }
        }

        guard let parsed = parseOwnerRepo(from: trimmed) else {
            return (false, "Güvenlik engeli: Yalnızca geçerli `owner/repo` veya `github.com`/`raw.githubusercontent.com` URL'leri kurulabilir.", nil)
        }

        let repoSlug = "\(parsed.owner)/\(parsed.repo)"
        var branch = parsed.branch ?? "main"
        if parsed.branch == nil,
           let metaURL = URL(string: "https://api.github.com/repos/\(repoSlug)"),
           let metaData = try? await fetchGitHubDataPreferringGH(apiPath: "repos/\(repoSlug)", fallbackURL: metaURL),
           let metaObj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let b = metaObj["default_branch"] as? String {
            branch = b
        }

        var candidatePaths: [String] = []
        if let sub = parsed.subpath, !sub.isEmpty {
            candidatePaths.append(sub.hasSuffix(".md") ? sub : "\(sub)/SKILL.md")
        }
        candidatePaths.append(contentsOf: ["SKILL.md", "skill/SKILL.md", "skills/\(parsed.repo)/SKILL.md"])

        var fetchedContent: String? = nil
        var resolvedSourceURL = "https://github.com/\(repoSlug)"

        for rel in candidatePaths {
            if let text = await fetchRawGitHubFile(owner: parsed.owner, repo: parsed.repo, branch: branch, path: rel) {
                fetchedContent = text
                resolvedSourceURL = "https://github.com/\(repoSlug)/blob/\(branch)/\(rel)"
                break
            }
        }

        // If still not found, check `skills/` directory listing for first subdirectory with SKILL.md
        if fetchedContent == nil,
           let skillsDirURL = URL(string: "https://api.github.com/repos/\(repoSlug)/contents/skills?ref=\(percentEncoded(branch))"),
           let skillsData = try? await fetchGitHubDataPreferringGH(apiPath: "repos/\(repoSlug)/contents/skills", fallbackURL: skillsDirURL),
           let items = try? JSONSerialization.jsonObject(with: skillsData) as? [[String: Any]] {
            for item in items.prefix(6) {
                if (item["type"] as? String) == "dir", let dirName = item["name"] as? String {
                    let rel = "skills/\(dirName)/SKILL.md"
                    if let text = await fetchRawGitHubFile(owner: parsed.owner, repo: parsed.repo, branch: branch, path: rel) {
                        fetchedContent = text
                        resolvedSourceURL = "https://github.com/\(repoSlug)/blob/\(branch)/\(rel)"
                        break
                    }
                }
            }
        }

        guard let markdown = fetchedContent else {
            return (false, "'\(repoSlug)' deposunda `SKILL.md` dosyası bulunamadı. Bu bir MCP/API projesi ise `<tool name=\"inspect_github_repo\">\(repoSlug)</tool>` veya `<tool name=\"create_connector\">` kullanın.", nil)
        }

        let slug = (slugOverride?.isEmpty == false ? slugOverride! : parsed.repo)
        return finalizeSkillInstall(rawMarkdown: markdown, defaultSlug: slug, sourceURL: resolvedSourceURL, openClawHome: openClawHome)
    }

    private static func finalizeSkillInstall(
        rawMarkdown: String,
        defaultSlug: String,
        sourceURL: String,
        openClawHome: String
    ) -> (succeeded: Bool, message: String, installedPath: String?) {
        let audit = securityAuditMarkdown(content: rawMarkdown)
        guard audit.isSafeToAutoInstall else {
            return (false, "⛔️ Güvenlik engeli: İndirilen skill yüksek riskli kalıplar içerdiği için kurulmadı (\(audit.findings.joined(separator: "; "))).", nil)
        }

        var name = defaultSlug
        var desc = "GitHub'dan içe aktarılan OpenClaw skill'i (\(sourceURL))"
        var body = rawMarkdown
        if rawMarkdown.hasPrefix("---") {
            let parts = rawMarkdown.components(separatedBy: "---")
            if parts.count >= 3 {
                let front = parts[1]
                body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
                for line in front.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("name:") {
                        name = t.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    } else if t.hasPrefix("description:") {
                        desc = t.dropFirst(12).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    }
                }
            }
        }
        let bodyWithSource = "<!-- source: \(sourceURL) -->\n\n" + body
        do {
            let savedPath = try OpenClawWorkspaceService.saveEvolvedSkill(
                slug: defaultSlug,
                name: name,
                description: desc,
                body: bodyWithSource,
                openClawHome: openClawHome
            )
            let warnNote = audit.level == "DİKKAT" ? "\n⚠️ Güvenlik Notu: \(audit.findings.joined(separator: "; "))" : ""
            return (true, "✅ GitHub skill'i kuruldu ve etkinleştirildi: `\(name)` → \(savedPath)\(warnNote)", savedPath)
        } catch {
            return (false, "Skill diske yazılamadı: \(error.localizedDescription)", nil)
        }
    }

    // MARK: - Reuse-First Ecosystem Check (Search Before Writing From Scratch)

    static func checkExistingSolutionsBeforeCreating(
        topic: String,
        openClawHome: String,
        workspacePath: String,
        connectors: [ServiceConnector],
        performRemoteSearch: Bool = true
    ) async -> EcosystemCheckReport {
        let tokens = extractSearchTokens(from: topic)
        let query = tokens.isEmpty ? topic.trimmingCharacters(in: .whitespacesAndNewlines) : tokens.prefix(4).joined(separator: " ")

        // 1. Check OpenClaw & workspace skills
        let openClawSkills = OpenClawWorkspaceService.discoverSkills(openClawHome: openClawHome, workspacePath: workspacePath)
        let localMatches = openClawSkills.filter { sk in
            let hay = "\(sk.id) \(sk.name) \(sk.description)".lowercased()
            return tokens.contains { hay.contains($0) }
        }.map { "\($0.name) (/\($0.id)): \($0.description)" }

        // 2. Check user's shared ~/.agents/skills directory
        var sharedMatches: [String] = []
        let sharedDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.agents/skills"
        if let items = try? FileManager.default.contentsOfDirectory(atPath: sharedDir) {
            for item in items where tokens.contains(where: { item.lowercased().contains($0) }) {
                sharedMatches.append("~/.agents/skills/\(item)/SKILL.md")
            }
        }

        // 3. Check registered + catalog connectors
        var mergedConnectors: [String: ServiceConnector] = [:]
        for c in ServiceConnector.builtInCatalog() { mergedConnectors[c.slug.lowercased()] = c }
        for c in connectors { mergedConnectors[c.slug.lowercased()] = c }
        let connectorMatches = mergedConnectors.values.filter { c in
            let hay = "\(c.slug) \(c.name) \(c.category) \(c.description)".lowercased()
            return tokens.contains { hay.contains($0) }
        }.sorted { $0.name < $1.name }

        // 4. Search GitHub if allowed
        var githubMatches: [GitHubRepoCandidate] = []
        if performRemoteSearch && !query.isEmpty {
            let res = await searchGitHubRepos(query: query, kind: "all", limit: 5)
            githubMatches = res.candidates
        }

        let strongGitHub = githubMatches.contains { $0.stars >= 5 || $0.hasSkillMD || $0.hasMCPHint }
        let hasStrong = !localMatches.isEmpty || !connectorMatches.isEmpty || strongGitHub

        var lines: [String] = ["🔍 0'dan Oluşturma Öncesi Hazır Kaynak Kontrolü (`\(query)`):"]
        if !localMatches.isEmpty {
            lines.append("• Yerel OpenClaw Skilleri: " + localMatches.joined(separator: " | "))
        }
        if !sharedMatches.isEmpty {
            lines.append("• ~/.agents/skills Eşleşmeleri: " + sharedMatches.joined(separator: ", "))
        }
        if !connectorMatches.isEmpty {
            lines.append("• Mevcut/Katalog Connectorlar: " + connectorMatches.map { "\($0.name) (slug=\($0.slug), \($0.transport.rawValue))" }.joined(separator: " | "))
        }
        if !githubMatches.isEmpty {
            lines.append("• GitHub Hazır Adayları:")
            for g in githubMatches.prefix(5) {
                lines.append("  - ★\(g.stars) `\(g.fullName)` — \(g.description.isEmpty ? g.htmlURL : g.description) (\(g.htmlURL))")
            }
        }
        if !hasStrong {
            lines.append("• Doğrudan güçlü bir hazır eşleşme bulunamadı; sıfırdan oluşturabilirsiniz.")
        }

        return EcosystemCheckReport(
            topic: query,
            localSkillMatches: localMatches,
            localAgentSkillMatches: sharedMatches,
            connectorMatches: connectorMatches,
            githubMatches: githubMatches,
            hasStrongMatch: hasStrong,
            summaryMarkdown: lines.joined(separator: "\n")
        )
    }

    static func extractSearchTokens(from raw: String) -> [String] {
        let stopWords: Set<String> = [
            "için", "ve", "ile", "bir", "yeni", "skill", "connector", "aracı", "oluştur", "yap",
            "baglanti", "bağlantı", "api", "mcp", "server", "the", "for", "and", "with", "create", "new"
        ]
        let lower = raw.lowercased()
            .replacingOccurrences(of: "[^a-z0-9ğüşöçıİ_-]+", with: " ", options: .regularExpression)
        return lower
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    // MARK: - Connector Execution & Probing (REST API + MCP HTTP + MCP stdio)

    static func executeConnectorAction(
        connector: ServiceConnector,
        action: String,
        argumentsJSON: String = "",
        workspacePath: String
    ) async -> (succeeded: Bool, output: String) {
        let cleanAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connector.isEnabled else {
            return (false, "Connector devre dışı: \(connector.name). Connectorlar sekmesinden etkinleştirin.")
        }

        switch connector.transport {
        case .restAPI:
            return await executeRESTConnector(connector: connector, action: cleanAction, jsonBody: argumentsJSON)
        case .mcpHTTP:
            return await executeMCPHTTP(connector: connector, action: cleanAction, argumentsJSON: argumentsJSON)
        case .mcpStdio:
            return await executeMCPStdio(connector: connector, action: cleanAction, argumentsJSON: argumentsJSON, workspacePath: workspacePath)
        case .cliBridge:
            let baseCmd = connector.endpointOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseCmd.isEmpty else {
                return (false, "CLI köprüsü komutu tanımlı değil.")
            }
            let full = cleanAction.isEmpty ? baseCmd : "\(baseCmd) \(cleanAction)"
            let res = await PowerShellTools.runCommand(full, workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 45)
            return (res.succeeded, res.output)
        case .browserFlow:
            return (false, "'\(connector.name)' tarayıcı tabanlı bir akıştır; doğrudan `\(connector.endpointOrCommand)` üzerinden açılabilir.")
        }
    }

    static func probeConnector(_ connector: ServiceConnector, workspacePath: String) async -> (ready: Bool, tools: [ConnectorToolSpec], message: String) {
        switch connector.transport {
        case .mcpHTTP, .mcpStdio:
            let res = await executeConnectorAction(connector: connector, action: "tools/list", argumentsJSON: "{}", workspacePath: workspacePath)
            if res.succeeded {
                let tools = parseMCPToolsList(from: res.output)
                let finalTools = tools.isEmpty ? connector.discoveredTools : tools
                return (true, finalTools, "MCP bağlantısı doğrulandı (\(finalTools.count) araç)")
            }
            return (false, connector.discoveredTools, res.output)
        case .restAPI:
            if connector.requiresSecret && connector.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (false, connector.discoveredTools, "Keychain'de API Token tanımlanmalı (\(connector.secretEnvName)).")
            }
            let probePath = connector.discoveredTools.first?.name.components(separatedBy: " ").last(where: { $0.hasPrefix("/") && !$0.contains("{") })
                ?? (connector.slug == "github" ? "/zen" : "/")
            let res = await executeRESTConnector(connector: connector, action: "GET \(probePath)", jsonBody: "")
            return (res.succeeded, connector.discoveredTools, res.succeeded ? "REST API bağlantısı doğrulandı ✓" : res.output)
        case .cliBridge:
            let cmd = connector.endpointOrCommand.split(separator: " ").first.map(String.init) ?? ""
            guard !cmd.isEmpty else { return (false, [], "CLI komutu boş.") }
            let check = await PowerShellTools.runCommand("which \(PowerShellTools.shellSingleQuoted(cmd))", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 5)
            return (check.succeeded, connector.discoveredTools, check.succeeded ? "CLI hazır: \(check.output)" : "CLI bulunamadı: \(cmd)")
        case .browserFlow:
            return (true, connector.discoveredTools, "Web bağlantısı hazır")
        }
    }

    private static func executeRESTConnector(
        connector: ServiceConnector,
        action: String,
        jsonBody: String
    ) async -> (succeeded: Bool, output: String) {
        if connector.requiresSecret && connector.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (false, "🔐 '\(connector.name)' için API anahtarı eksik! Connectorlar sekmesinden Keychain'e token ekleyin (\(connector.secretEnvName)).")
        }

        let parts = action.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let httpMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
        let method: String
        let pathOrURL: String
        if parts.count == 2 && httpMethods.contains(parts[0].uppercased()) {
            method = parts[0].uppercased()
            pathOrURL = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            method = jsonBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "GET" : "POST"
            pathOrURL = action.isEmpty ? "/" : action
        }

        let baseStr = connector.endpointOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullURLString: String
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") {
            fullURLString = pathOrURL
        } else {
            let cleanBase = baseStr.hasSuffix("/") ? String(baseStr.dropLast()) : baseStr
            let cleanPath = pathOrURL.hasPrefix("/") ? pathOrURL : "/" + pathOrURL
            fullURLString = cleanBase + cleanPath
        }

        guard let targetURL = URL(string: fullURLString) else {
            return (false, "Geçersiz connector URL'si: \(fullURLString)")
        }
        let safety = BrowserAutomationService.validateBrowserURL(targetURL, allowLocalNetwork: true)
        guard safety.allowed else {
            return (false, safety.reason ?? "Güvenlik engeli.")
        }
        // Prevent sending a connector's secret token to a completely unrelated host via full URL override.
        if let baseHost = URL(string: baseStr)?.host?.lowercased(),
           let targetHost = targetURL.host?.lowercased(),
           baseHost != targetHost && !targetHost.hasSuffix("." + baseHost) {
            return (false, "Güvenlik engeli: '\(connector.name)' anahtarı yalnızca `\(baseHost)` alan adına gönderilebilir (hedef: `\(targetHost)`).")
        }

        var req = URLRequest(url: targetURL, timeoutInterval: 25)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClawOffice/4.0", forHTTPHeaderField: "User-Agent")

        let key = connector.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            switch connector.authType {
            case .bearerToken:
                req.setValue("Bearer \(key)", forHTTPHeaderField: connector.authHeaderName.isEmpty ? "Authorization" : connector.authHeaderName)
            case .apiKeyHeader:
                req.setValue(key, forHTTPHeaderField: connector.authHeaderName.isEmpty ? "X-API-Key" : connector.authHeaderName)
            case .basicAuth:
                let encoded = Data(key.utf8).base64EncodedString()
                req.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            case .none, .oauthBrowser, .envVar:
                break
            }
        }

        let trimmedBody = jsonBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty && method != "GET" && method != "HEAD" {
            req.httpBody = Data(trimmedBody.utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let formatted = prettyFormatData(data)
            let clipped = formatted.count > 10000 ? String(formatted.prefix(10000)) + "\n... [kısaltıldı]" : formatted
            let ok = (200...299).contains(status)
            return (ok, "[\(connector.name) · HTTP \(status) · \(method) \(targetURL.path)]\n\(clipped)")
        } catch {
            return (false, "Connector HTTP hatası: \(error.localizedDescription)")
        }
    }

    private static func executeMCPHTTP(
        connector: ServiceConnector,
        action: String,
        argumentsJSON: String
    ) async -> (succeeded: Bool, output: String) {
        guard let url = URL(string: connector.endpointOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (false, "Geçersiz MCP HTTP adresi: \(connector.endpointOrCommand)")
        }
        let safety = BrowserAutomationService.validateBrowserURL(url, allowLocalNetwork: true)
        guard safety.allowed else {
            return (false, safety.reason ?? "MCP URL güvenlik engeli.")
        }

        func sendRPC(method: String, params: Any, id: Int?, sessionId: String?) async throws -> (status: Int, body: String, nextSession: String?) {
            var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if let id { payload["id"] = id }
            var req = URLRequest(url: url, timeoutInterval: 25)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("ClawOffice/4.0", forHTTPHeaderField: "User-Agent")
            if let sessionId, !sessionId.isEmpty {
                req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            }
            let token = connector.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionId
            let rawText = String(decoding: data, as: UTF8.self)
            let parsedSSE = extractSSEJSONPayload(rawText) ?? rawText
            return (status, parsedSSE, sid)
        }

        do {
            let initParams: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "ClawOffice", "version": "4.0"]
            ]
            let initRes = try await sendRPC(method: "initialize", params: initParams, id: 1, sessionId: nil)
            if initRes.status == 401 || initRes.status == 403 {
                return (false, "🔐 MCP sunucusu kimlik doğrulaması istedi (HTTP \(initRes.status)). Connector ayarlarına API Token girin.")
            }
            guard (200...299).contains(initRes.status) else {
                return (false, "MCP initialize başarısız (HTTP \(initRes.status)): \(initRes.body)")
            }
            let sid = initRes.nextSession
            _ = try? await sendRPC(method: "notifications/initialized", params: [:], id: nil, sessionId: sid)

            let isToolsList = action.isEmpty || action.lowercased() == "tools/list" || action.lowercased() == "list"
            let res: (status: Int, body: String, nextSession: String?)
            if isToolsList {
                res = try await sendRPC(method: "tools/list", params: [:], id: 2, sessionId: sid)
            } else {
                let parsedArgs = parseJSONDict(argumentsJSON) ?? [:]
                res = try await sendRPC(method: "tools/call", params: ["name": action, "arguments": parsedArgs], id: 2, sessionId: sid)
            }
            let clipped = res.body.count > 10000 ? String(res.body.prefix(10000)) + "\n... [kısaltıldı]" : res.body
            let ok = (200...299).contains(res.status) && !clipped.contains("\"error\"")
            return (ok, "[\(connector.name) · MCP HTTP \(res.status)]\n\(clipped)")
        } catch {
            return (false, "MCP HTTP hatası: \(error.localizedDescription)")
        }
    }

    private static func executeMCPStdio(
        connector: ServiceConnector,
        action: String,
        argumentsJSON: String,
        workspacePath: String
    ) async -> (succeeded: Bool, output: String) {
        let cmdLine = connector.endpointOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdLine.isEmpty else {
            return (false, "MCP stdio komutu boş.")
        }

        let isToolsList = action.isEmpty || action.lowercased() == "tools/list" || action.lowercased() == "list"
        let req2Dict: [String: Any]
        if isToolsList {
            req2Dict = ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        } else {
            req2Dict = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": action, "arguments": parseJSONDict(argumentsJSON) ?? [:]]]
        }
        let initReq: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "ClawOffice", "version": "4.0"]
            ]
        ]
        let notifReq: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]]

        guard let d1 = try? JSONSerialization.data(withJSONObject: initReq),
              let dNotif = try? JSONSerialization.data(withJSONObject: notifReq),
              let d2 = try? JSONSerialization.data(withJSONObject: req2Dict),
              let s1 = String(data: d1, encoding: .utf8),
              let sNotif = String(data: dNotif, encoding: .utf8),
              let s2 = String(data: d2, encoding: .utf8) else {
            return (false, "MCP JSON-RPC paketi serileştirilemedi.")
        }

        let inputLines = s1 + "\n" + sNotif + "\n" + s2 + "\n"
        let argSuffix = connector.arguments.map { PowerShellTools.shellSingleQuoted($0) }.joined(separator: " ")
        let fullShell = argSuffix.isEmpty ? cmdLine : "\(cmdLine) \(argSuffix)"
        var extraEnv: [String: String] = [:]
        let secret = connector.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty && !connector.secretEnvName.isEmpty {
            extraEnv[connector.secretEnvName] = secret
        }

        let procRes = await runBoundedSubprocess(
            executablePath: "/bin/zsh",
            arguments: ["-c", fullShell],
            currentDirectory: workspacePath,
            extraEnv: extraEnv,
            stdinData: Data(inputLines.utf8),
            timeoutSeconds: 20
        )
        let stdout = String(decoding: procRes.stdout, as: UTF8.self)
        let stderr = String(decoding: procRes.stderr, as: UTF8.self)
        let lines = stdout.components(separatedBy: .newlines).filter { $0.contains("\"id\":2") || $0.contains("\"id\": 2") }
        let body = lines.last ?? (stdout.isEmpty ? stderr : stdout)
        let clipped = body.count > 10000 ? String(body.prefix(10000)) + "\n... [kısaltıldı]" : body
        let ok = !clipped.isEmpty && !clipped.contains("\"error\"") && (procRes.exitCode == 0 || !lines.isEmpty)
        return (ok, "[\(connector.name) · MCP stdio]\n\(clipped)")
    }

    static func parseMCPToolsList(from raw: String) -> [ConnectorToolSpec] {
        var jsonCandidate = raw
        if let firstBrace = raw.firstIndex(of: "{") {
            jsonCandidate = String(raw[firstBrace...])
        }
        guard let data = jsonCandidate.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return []
        }
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let desc = (t["description"] as? String) ?? ""
            return ConnectorToolSpec(name: name, description: desc)
        }
    }

    // MARK: - Helpers

    private static func runBoundedSubprocess(
        executablePath: String,
        arguments: [String],
        currentDirectory: String? = nil,
        extraEnv: [String: String] = [:],
        stdinData: Data? = nil,
        timeoutSeconds: TimeInterval = 15
    ) async -> (exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executablePath)
                p.arguments = arguments
                if let currentDirectory, !currentDirectory.isEmpty {
                    p.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                }
                var env = ProcessInfo.processInfo.environment
                for k in env.keys where k.hasPrefix("CLAWOFFICE_") { env.removeValue(forKey: k) }
                env["PATH"] = PowerShellTools.extendedEnvPath()
                for (k, v) in extraEnv { env[k] = v }
                p.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                let inPipe = stdinData != nil ? Pipe() : nil
                p.standardOutput = outPipe
                p.standardError = errPipe
                p.standardInput = inPipe ?? FileHandle.nullDevice

                let readGroup = DispatchGroup()
                var outData = Data()
                var errData = Data()

                do {
                    try p.run()
                } catch {
                    try? inPipe?.fileHandleForWriting.close()
                    try? outPipe.fileHandleForReading.close()
                    try? errPipe.fileHandleForReading.close()
                    cont.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8), false))
                    return
                }

                // Read both streams concurrently so large outputs never deadlock the child pipe buffer.
                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = PowerShellTools.readBoundedPipeData(from: outPipe.fileHandleForReading, maxBytes: 262_144).data
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = PowerShellTools.readBoundedPipeData(from: errPipe.fileHandleForReading, maxBytes: 65_536).data
                    readGroup.leave()
                }

                if let inPipe, let stdinData {
                    inPipe.fileHandleForWriting.write(stdinData)
                    try? inPipe.fileHandleForWriting.close()
                }

                var timedOut = false
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while p.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if p.isRunning {
                    timedOut = true
                    PowerShellTools.killProcessTree(pid: p.processIdentifier)
                    p.waitUntilExit()
                }
                readGroup.wait()
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                cont.resume(returning: (p.terminationStatus, outData, errData, timedOut))
            }
        }
    }

    private static func runGHAPI(path: String) async -> Data? {
        let res = await runBoundedSubprocess(
            executablePath: "/usr/bin/env",
            arguments: ["gh", "api", path],
            timeoutSeconds: 10
        )
        return (!res.timedOut && res.exitCode == 0 && !res.stdout.isEmpty) ? res.stdout : nil
    }

    private static func fetchGitHubDataPreferringGH(apiPath: String, fallbackURL: URL) async throws -> Data {
        if let gh = await runGHAPI(path: apiPath) {
            return gh
        }
        return try await fetchGitHubAPI(url: fallbackURL)
    }

    private static func fetchGitHubAPI(url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClawOffice/4.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(decoding: data, as: UTF8.self)
            throw NSError(domain: "GitHubAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg.prefix(220))"])
        }
        return data
    }

    private static func fetchRawGitHubFile(owner: String, repo: String, branch: String, path: String) async -> String? {
        let encodedPath = path.split(separator: "/").map { percentEncoded(String($0)) }.joined(separator: "/")
        guard let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(percentEncoded(branch))/\(encodedPath)") else {
            return nil
        }
        return try? await fetchText(url: url)
    }

    private static func fetchText(url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("ClawOffice/4.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractSSEJSONPayload(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines)
        var lastData: String? = nil
        for ln in lines {
            let t = ln.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("data:") {
                let body = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty && body != "[DONE]" {
                    lastData = body
                }
            }
        }
        return lastData
    }

    private static func parseJSONDict(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func prettyFormatData(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: pretty, encoding: .utf8) {
            return str
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
