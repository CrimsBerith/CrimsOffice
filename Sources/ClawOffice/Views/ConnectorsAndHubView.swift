import SwiftUI

struct ConnectorsAndHubView: View {
    @EnvironmentObject var engine: OfficeEngine
    @State private var ghQuery: String = "hostinger mcp"
    @State private var ghKind: String = "all"
    @State private var isSearchingGH: Bool = false
    @State private var ghSummaryOutput: String = ""
    @State private var inspectResultText: String = ""
    @State private var showInspectSheet: Bool = false
    @State private var actionFeedback: String = ""
    @State private var showAddConnectorSheet: Bool = false
    @State private var tokenDrafts: [UUID: String] = [:]
    @State private var testingIds: Set<UUID> = []

    var body: some View {
        ZStack {
            AmbientGlassBackdrop(accent: .indigo)

            HSplitView {
                // Left Pane: Service Connectors & MCP Servers
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        GlassSectionHeader(
                            title: "Connectorlar & MCP Sunucuları (\(engine.connectors.count))",
                            subtitle: "Hostinger API/MCP, GitHub, Cloudflare ve özel servisler Keychain korumasıyla bağlanır.",
                            systemImage: "puzzlepiece.extension.fill",
                            tint: .indigo
                        )
                        Spacer()
                        Button {
                            showAddConnectorSheet = true
                        } label: {
                            Label("Yeni Connector", systemImage: "plus.circle.fill")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .liquidGlassButton(prominent: true, tint: .indigo)
                    }

                    if !actionFeedback.isEmpty {
                        HStack {
                            Text(actionFeedback).font(.caption).lineLimit(3)
                            Spacer()
                            Button("Temizle") { actionFeedback = "" }.controlSize(.small)
                        }
                        .padding(10)
                        .liquidGlassCard(cornerRadius: 12, tint: .teal)
                    }

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(engine.connectors) { conn in
                                connectorCard(conn)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(18)
                .frame(minWidth: 440)

                // Right Pane: GitHub Discovery & Reuse-First Skill Factory
                VStack(alignment: .leading, spacing: 12) {
                    GlassSectionHeader(
                        title: "GitHub Keşif & Hazır Skill/MCP Merkezi",
                        subtitle: "0'dan yazmadan önce GitHub & OpenClaw ekosisteminde doğrula, güvenlik tara ve kur.",
                        systemImage: "magnifyingglass.circle.fill",
                        tint: .cyan
                    )

                    HStack(spacing: 8) {
                        TextField("Ara: hostinger mcp, cloudflare skill, deployment...", text: $ghQuery)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .liquidGlassCard(cornerRadius: 10)
                            .onSubmit { runGHSearch() }

                        Picker("", selection: $ghKind) {
                            Text("Tümü").tag("all")
                            Text("MCP").tag("mcp")
                            Text("Skill").tag("skill")
                            Text("Connector").tag("connector")
                        }
                        .frame(width: 115)

                        Button {
                            runGHSearch()
                        } label: {
                            if isSearchingGH {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("GitHub Ara")
                            }
                        }
                        .liquidGlassButton(prominent: true, tint: .cyan)
                        .disabled(isSearchingGH || ghQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(["hostinger mcp", "openclaw skill", "cloudflare mcp", "supabase mcp"], id: \.self) { preset in
                                Button(preset) {
                                    ghQuery = preset
                                    runGHSearch()
                                }
                                .liquidGlassButton(prominent: false)
                                .controlSize(.small)
                            }
                        }
                    }

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if engine.lastGitHubCandidates.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Henüz arama yapılmadı")
                                        .font(.callout.bold())
                                    Text("Ajanlar `search_github`, `inspect_github_repo` ve `install_github_skill` araçlarını çalıştırdığında veya yukarıdan arama yaptığınızda adaylar güvenlik puanı ve kurulum butonlarıyla burada görünür.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .liquidGlassCard(cornerRadius: 14)
                            } else {
                                ForEach(engine.lastGitHubCandidates) { cand in
                                    githubCandidateCard(cand)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(18)
                .frame(minWidth: 380, idealWidth: 430)
            }
        }
        .onAppear {
            for c in engine.connectors where tokenDrafts[c.id] == nil {
                tokenDrafts[c.id] = c.apiKey
            }
        }
        .sheet(isPresented: $showInspectSheet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("GitHub Depo & Güvenlik Raporu").font(.headline)
                    Spacer()
                    Button("Kapat") { showInspectSheet = false }
                }
                ScrollView {
                    Text(inspectResultText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .liquidGlassCard(cornerRadius: 12)
            }
            .padding(18)
            .frame(minWidth: 640, minHeight: 460)
        }
        .sheet(isPresented: $showAddConnectorSheet) {
            AddConnectorSheet().environmentObject(engine)
        }
    }

    @ViewBuilder
    private func connectorCard(_ conn: ServiceConnector) -> some View {
        let draftBinding = Binding<String>(
            get: { tokenDrafts[conn.id] ?? conn.apiKey },
            set: { tokenDrafts[conn.id] = $0 }
        )
        let isTesting = testingIds.contains(conn.id)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(conn.name).font(.headline)
                        Text(conn.transport.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .liquidGlassCapsule(tint: .indigo)
                        Text("slug: \(conn.slug)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(conn.description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(conn.name, isOn: Binding(
                    get: { conn.isEnabled },
                    set: { _ in engine.toggleConnector(id: conn.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                Text(conn.endpointOrCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(conn.hasCredentialOrNoAuth ? "✅ Hazır" : "🔐 Token Gerekli")
                    .font(.caption2.bold())
                    .foregroundStyle(conn.hasCredentialOrNoAuth ? .green : .orange)
            }

            if conn.requiresSecret {
                HStack(spacing: 8) {
                    SecureField("\(conn.secretEnvName) (Keychain'de saklanır)...", text: draftBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .liquidGlassCard(cornerRadius: 8)

                    Button("Kaydet") {
                        let val = tokenDrafts[conn.id] ?? ""
                        engine.saveConnectorSecret(id: conn.id, apiKey: val)
                        actionFeedback = "✅ \(conn.name) anahtarı Keychain için kaydedildi."
                    }
                    .liquidGlassButton(prominent: true, tint: .indigo)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        testingIds.insert(conn.id)
                        Task {
                            let res = await engine.probeConnector(id: conn.id)
                            testingIds.remove(conn.id)
                            actionFeedback = "\(conn.name): \(res.message)"
                        }
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test Et & Araçları Çek", systemImage: "bolt.horizontal.circle")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .liquidGlassButton(prominent: false, tint: .cyan)
                    .controlSize(.small)
                    .disabled(isTesting)

                    if conn.slug == "swarms-mcp" {
                        Button {
                            testingIds.insert(conn.id)
                            Task {
                                let res = await engine.restartSwarmsDaemon()
                                testingIds.remove(conn.id)
                                actionFeedback = "Swarms Daemon: \(res.1)"
                            }
                        } label: {
                            Label("Daemon Başlat", systemImage: "arrow.clockwise.circle")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .liquidGlassButton(prominent: false, tint: .teal)
                        .controlSize(.small)
                        .disabled(isTesting)
                    }

                    if !conn.docsURL.isEmpty,
                       let targetURL = URL(string: conn.slug.contains("hostinger") ? "https://hpanel.hostinger.com" : conn.docsURL) {
                        Button {
                            NSWorkspace.shared.open(targetURL)
                        } label: {
                            Label(conn.slug.contains("hostinger") ? "hPanel Aç" : "Web'de Aç", systemImage: "arrow.up.right.square")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .liquidGlassButton(prominent: false, tint: .blue)
                        .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }

                Text(conn.lastStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !conn.discoveredTools.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(conn.discoveredTools.prefix(8)) { tool in
                            Text(tool.name)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .liquidGlassCapsule(tint: .teal)
                                .help(tool.description)
                        }
                    }
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 14, tint: conn.isVerifiedReady ? .teal : .indigo)
    }

    @ViewBuilder
    private func githubCandidateCard(_ cand: GitHubRepoCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(cand.fullName)
                    .font(.callout.bold())
                    .lineLimit(1)
                Spacer()
                Text("★ \(cand.stars)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .liquidGlassCapsule(tint: .yellow)
                if cand.hasMCPHint {
                    Text("MCP")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .liquidGlassCapsule(tint: .indigo)
                }
                if cand.hasSkillMD {
                    Text("Skill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .liquidGlassCapsule(tint: .teal)
                }
            }
            if !cand.description.isEmpty {
                Text(cand.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                Text("Lisans: \(cand.license) · \(cand.updatedAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("İncele") {
                    Task {
                        let res = await ConnectorAndGitHubService.inspectGitHubRepo(target: cand.fullName)
                        inspectResultText = res.summary
                        showInspectSheet = true
                    }
                }
                .liquidGlassButton(prominent: false, tint: .cyan)
                .controlSize(.small)

                Button("SKILL.md Kur") {
                    Task {
                        let res = await engine.installSkillFromGitHubUI(source: cand.fullName)
                        actionFeedback = res.1
                    }
                }
                .liquidGlassButton(prominent: true, tint: .teal)
                .controlSize(.small)

                if let repoURL = URL(string: cand.htmlURL) {
                    Button {
                        NSWorkspace.shared.open(repoURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .liquidGlassButton(prominent: false)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 14)
    }

    private func runGHSearch() {
        isSearchingGH = true
        Task {
            ghSummaryOutput = await engine.searchGitHubInHub(query: ghQuery, kind: ghKind)
            isSearchingGH = false
        }
    }
}

private struct AddConnectorSheet: View {
    @EnvironmentObject var engine: OfficeEngine
    @Environment(\.dismiss) private var dismiss
    @State private var slug: String = ""
    @State private var name: String = ""
    @State private var transport: ConnectorTransport = .restAPI
    @State private var authType: ConnectorAuthType = .bearerToken
    @State private var endpoint: String = ""
    @State private var description: String = ""
    @State private var secretEnvName: String = "API_TOKEN"
    @State private var apiKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Yeni Servis Connector / MCP Ekle").font(.headline)

            TextField("Kısa ad (slug, ör. hostinger-custom)", text: $slug)
                .textFieldStyle(.roundedBorder)
            TextField("Görünen Ad", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Protokol", selection: $transport) {
                ForEach(ConnectorTransport.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }

            Picker("Kimlik Doğrulama", selection: $authType) {
                ForEach(ConnectorAuthType.allCases, id: \.self) { a in
                    Text(a.rawValue).tag(a)
                }
            }

            TextField(transport == .mcpStdio ? "Komut (ör. npx -y @modelcontextprotocol/server-github)" : "Endpoint URL (https://...)", text: $endpoint)
                .textFieldStyle(.roundedBorder)
            TextField("Açıklama", text: $description)
                .textFieldStyle(.roundedBorder)
            TextField("Secret Env / Token Etiketi", text: $secretEnvName)
                .textFieldStyle(.roundedBorder)
            SecureField("API Anahtarı / Token (Keychain'de saklanır)", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("İptal") { dismiss() }
                Button("Kaydet") {
                    let cleanSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let conn = ServiceConnector(
                        slug: cleanSlug.isEmpty ? "custom" : cleanSlug,
                        name: name.isEmpty ? "Özel Connector" : name,
                        category: "Özel",
                        description: description,
                        transport: transport,
                        endpointOrCommand: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                        authType: authType,
                        secretEnvName: secretEnvName,
                        apiKey: apiKey
                    )
                    engine.addOrUpdateConnector(conn)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
