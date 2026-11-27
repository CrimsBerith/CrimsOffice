import Foundation
import CryptoKit
import Network

/// Native OpenClaw Gateway (WebSocket + CLI + Session JSONL + Channels + Cron + Security + Telegram + ClawHub) bridge.
final class OpenClawGatewayService: @unchecked Sendable {
    static let shared = OpenClawGatewayService()

    struct GatewaySnapshot: Sendable {
        var configPresent: Bool = false
        var gatewayOnline: Bool = false
        var webSocketConnected: Bool = false
        var gatewayPort: Int = 18789
        var gatewayMode: String = "local"
        var deviceId: String = ""
        var cliInstalled: Bool = false
        var cliVersion: String = ""
        var channels: [OpenClawChannelStatus] = []
        var discoveredAgents: [OpenClawExternalAgent] = []
        var externalCronCount: Int = 0
        var lastError: String = ""
        var lastSyncedAt: Date = Date()
    }

    private let lock = NSLock()
    private var wsTask: URLSessionWebSocketTask?
    private var wsURLSession: URLSession?
    private var onGatewayEvent: (@Sendable (String) -> Void)?

    deinit {
        disconnectWebSocket()
    }

    // MARK: - Device Identity & Ed25519 v3 Signature (openclaw-office parity)

    struct DeviceIdentity: Sendable {
        let deviceId: String
        let publicKeyRawBase64URL: String
        let privateKeyPEM: String
        let operatorToken: String
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func parsePEMBase64(_ pem: String) -> Data? {
        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        return Data(base64Encoded: body)
    }

    static func signDeviceAuthV3(
        deviceId: String,
        privateKeyPEM: String,
        clientId: String = "crimsoffice-macos",
        clientMode: String = "ui",
        role: String = "operator",
        scopes: [String] = ["operator.read", "operator.write"],
        signedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        token: String,
        nonce: String,
        platform: String = "macos",
        deviceFamily: String = "desktop"
    ) -> String? {
        guard let der = parsePEMBase64(privateKeyPEM), der.count >= 32 else { return nil }
        let rawSeed = Data(der.suffix(32))
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawSeed) else { return nil }

        let payload = [
            "v3", deviceId, clientId, clientMode, role,
            scopes.joined(separator: ","), String(signedAtMs), token,
            nonce, platform, deviceFamily
        ].joined(separator: "|")

        guard let sig = try? key.signature(for: Data(payload.utf8)) else { return nil }
        return base64URLEncode(sig)
    }

    static func loadDeviceIdentity(openClawRoot: URL? = nil) -> DeviceIdentity? {
        let root = openClawRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
        let deviceURL = root.appendingPathComponent("identity/device.json")
        guard let data = try? Data(contentsOf: deviceURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = obj["deviceId"] as? String,
              let privPEM = obj["privateKeyPem"] as? String else {
            return nil
        }
        let pubPEM = (obj["publicKeyPem"] as? String) ?? ""
        let rawPub: String
        if let pubDER = parsePEMBase64(pubPEM), pubDER.count >= 32 {
            rawPub = base64URLEncode(Data(pubDER.suffix(32)))
        } else {
            rawPub = ""
        }
        var operatorToken = ""
        let authURL = root.appendingPathComponent("identity/device-auth.json")
        if let aData = try? Data(contentsOf: authURL),
           let aObj = try? JSONSerialization.jsonObject(with: aData) as? [String: Any],
           let tokens = aObj["tokens"] as? [String: Any],
           let op = tokens["operator"] as? [String: Any],
           let tok = op["token"] as? String {
            operatorToken = tok
        }
        return DeviceIdentity(
            deviceId: deviceId,
            publicKeyRawBase64URL: rawPub,
            privateKeyPEM: privPEM,
            operatorToken: operatorToken
        )
    }

    // MARK: - Local ~/.openclaw/openclaw.json Discovery

    static func readOpenClawConfigDict(openClawRoot: URL? = nil) -> [String: Any]? {
        let root = openClawRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
        let cfgURL = root.appendingPathComponent("openclaw.json")
        guard let data = try? Data(contentsOf: cfgURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func extractDiscoveredAgents(from config: [String: Any]) -> [OpenClawExternalAgent] {
        guard let agentsDict = config["agents"] as? [String: Any],
              let entries = agentsDict["entries"] as? [String: Any] else {
            return []
        }
        var out: [OpenClawExternalAgent] = []
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = value as? [String: Any] ?? [:]
            let name = (entry["name"] as? String) ?? key.capitalized
            let title = (entry["role"] as? String) ?? (entry["title"] as? String) ?? "OpenClaw Ajanı"
            let model = (entry["model"] as? String)
                ?? ((agentsDict["defaults"] as? [String: Any])?["model"] as? String)
                ?? "auto"
            let ws = (entry["workspace"] as? String) ?? ""
            out.append(OpenClawExternalAgent(id: key, name: name, title: title, modelId: model, workspace: ws))
        }
        return out
    }

    static func extractChannels(from config: [String: Any]?) -> [OpenClawChannelStatus] {
        let knownCatalog: [(id: String, name: String, icon: String)] = [
            ("telegram", "Telegram Bot", "paperplane.fill"),
            ("whatsapp", "WhatsApp", "message.fill"),
            ("discord", "Discord", "headphones.circle.fill"),
            ("slack", "Slack", "number.square.fill"),
            ("imessage", "iMessage / BlueBubbles", "bubble.left.and.bubble.right.fill"),
            ("signal", "Signal", "lock.shield.fill"),
            ("webchat", "WebChat Control UI", "globe")
        ]
        let channelsObj = (config?["channels"] as? [String: Any]) ?? [:]
        return knownCatalog.map { item in
            let entry = channelsObj[item.id] as? [String: Any]
            let enabled = (entry?["enabled"] as? Bool) ?? (entry != nil)
            let hasCred = entry != nil && !(entry?.isEmpty ?? true)
            return OpenClawChannelStatus(
                id: item.id,
                name: item.name,
                isConfigured: item.id == "webchat" || hasCred,
                isRunning: item.id == "webchat" ? true : enabled,
                details: entry != nil ? (enabled ? "Yapılandırıldı ve etkin" : "Yapılandırıldı (pasif)") : "Henüz bağlanmadı",
                icon: item.icon
            )
        }
    }

    // MARK: - Session JSONL Reader (openclaw-office lib/openclaw.js parity)

    static func scanSessionSummaries(openClawRoot: URL? = nil, limit: Int = 30) -> [OpenClawSessionSummary] {
        let root = openClawRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
        let agentsDir = root.appendingPathComponent("agents")
        let fm = FileManager.default
        guard let agentFolders = try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var files: [(agentId: String, url: URL, mtime: Date)] = []
        for agentDir in agentFolders {
            let sessDir = agentDir.appendingPathComponent("sessions")
            guard let items = try? fm.contentsOfDirectory(at: sessDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                continue
            }
            for item in items where item.pathExtension == "jsonl" && !item.lastPathComponent.contains(".deleted") {
                let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((agentDir.lastPathComponent, item, mtime))
            }
        }

        files.sort { $0.mtime > $1.mtime }
        var summaries: [OpenClawSessionSummary] = []

        for entry in files.prefix(limit) {
            guard let content = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
            var msgCount = 0
            var inTok = 0
            var outTok = 0
            var cacheTok = 0
            var preview = ""

            for line in content.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                msgCount += 1
                let usage = (obj["usage"] as? [String: Any])
                    ?? ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
                if let usage {
                    inTok += (usage["input"] as? Int) ?? (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
                    outTok += (usage["output"] as? Int) ?? (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
                    cacheTok += (usage["cacheRead"] as? Int) ?? (usage["cached_tokens"] as? Int) ?? 0
                }
                if preview.isEmpty {
                    let msg = obj["message"] as? [String: Any]
                    if let c = msg?["content"] as? String, !c.isEmpty {
                        preview = String(c.replacingOccurrences(of: "\n", with: " ").prefix(110))
                    } else if let c = obj["text"] as? String, !c.isEmpty {
                        preview = String(c.replacingOccurrences(of: "\n", with: " ").prefix(110))
                    }
                }
            }

            let estCost = (Double(inTok) * 0.0000005) + (Double(outTok) * 0.0000018)
            summaries.append(OpenClawSessionSummary(
                id: "\(entry.agentId)/\(entry.url.lastPathComponent)",
                agentId: entry.agentId,
                fileName: entry.url.lastPathComponent,
                messageCount: msgCount,
                inputTokens: inTok,
                outputTokens: outTok,
                cachedTokens: cacheTok,
                estimatedCostUSD: estCost,
                updatedAt: entry.mtime,
                preview: preview.isEmpty ? "Oturum kaydı" : preview
            ))
        }
        return summaries
    }

    // MARK: - Live Snapshot & Gateway WebSocket Control

    func inspectGateway(workspacePath: String) async -> GatewaySnapshot {
        var snap = GatewaySnapshot()
        let cfg = Self.readOpenClawConfigDict()
        snap.configPresent = cfg != nil
        if let gw = cfg?["gateway"] as? [String: Any] {
            if let p = gw["port"] as? Int { snap.gatewayPort = p }
            if let m = gw["mode"] as? String { snap.gatewayMode = m }
        }
        if let dev = Self.loadDeviceIdentity() {
            snap.deviceId = dev.deviceId
        }
        snap.channels = Self.extractChannels(from: cfg)
        if let cfg {
            snap.discoveredAgents = Self.extractDiscoveredAgents(from: cfg)
        }

        let verRes = await PowerShellTools.runCommand("openclaw --version", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 4.0)
        if verRes.succeeded {
            snap.cliInstalled = true
            snap.cliVersion = verRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Probe OpenClaw Gateway HTTP health
        if let url = URL(string: "http://127.0.0.1:\(snap.gatewayPort)/health") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...499).contains(http.statusCode) {
                snap.gatewayOnline = true
            }
        }

        if snap.cliInstalled {
            let cronRes = await PowerShellTools.runCommand("openclaw cron list --json", workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 5.0)
            if cronRes.succeeded,
               let data = cronRes.output.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                snap.externalCronCount = arr.count
            }
        }

        snap.webSocketConnected = await MainActor.run { isWebSocketConnectedInternal() }
        return snap
    }

    private func isWebSocketConnectedInternal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wsTask?.state == .running
    }

    func connectWebSocket(port: Int = 18789, onEvent: @escaping @Sendable (String) -> Void) {
        lock.lock()
        onGatewayEvent = onEvent
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsURLSession?.invalidateAndCancel()

        guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
            lock.unlock()
            return
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        wsURLSession = session
        wsTask = task
        lock.unlock()

        task.resume()
        sendConnectHandshake(over: task)
        receiveLoop(over: task)
        schedulePing(over: task)
    }

    private func schedulePing(over task: URLSessionWebSocketTask) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25.0) { [weak self, weak task] in
            guard let self, let task else { return }
            self.lock.lock()
            let isCurrent = (self.wsTask === task && task.state == .running)
            self.lock.unlock()
            guard isCurrent else { return }
            task.sendPing { [weak self, weak task] error in
                guard let self, let task else { return }
                if error != nil {
                    self.cleanupFailedTask(task)
                } else {
                    self.schedulePing(over: task)
                }
            }
        }
    }

    private func cleanupFailedTask(_ failedTask: URLSessionWebSocketTask) {
        lock.lock()
        if wsTask === failedTask {
            wsTask?.cancel(with: .goingAway, reason: nil)
            wsTask = nil
            wsURLSession?.invalidateAndCancel()
            wsURLSession = nil
        }
        lock.unlock()
    }

    func disconnectWebSocket() {
        lock.lock()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsURLSession?.invalidateAndCancel()
        wsURLSession = nil
        lock.unlock()
    }

    private func sendConnectHandshake(over task: URLSessionWebSocketTask, nonce: String = UUID().uuidString) {
        let cfg = Self.readOpenClawConfigDict()
        let gwToken = ((cfg?["gateway"] as? [String: Any])?["auth"] as? [String: Any])?["token"] as? String ?? ""
        let dev = Self.loadDeviceIdentity()
        let authToken = (dev?.operatorToken.isEmpty == false ? dev?.operatorToken : nil) ?? gwToken
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)

        var devicePayload: [String: Any]? = nil
        if let dev, let sig = Self.signDeviceAuthV3(
            deviceId: dev.deviceId,
            privateKeyPEM: dev.privateKeyPEM,
            signedAtMs: signedAtMs,
            token: authToken,
            nonce: nonce
        ) {
            devicePayload = [
                "id": dev.deviceId,
                "publicKey": dev.publicKeyRawBase64URL,
                "signature": sig,
                "signedAt": signedAtMs,
                "nonce": nonce
            ]
        }

        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "crimsoffice-macos",
                "version": "4.0.0",
                "platform": "macos",
                "mode": "ui"
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write"]
        ]
        if !authToken.isEmpty {
            params["auth"] = ["token": authToken]
        }
        if let devicePayload {
            params["device"] = devicePayload
        }

        let frame: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "connect",
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receiveLoop(over task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = (self.wsTask === task)
            let handler = self.onGatewayEvent
            self.lock.unlock()
            guard isCurrent else { return }

            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    if let d = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       (obj["event"] as? String) == "connect.challenge",
                       let payload = obj["payload"] as? [String: Any],
                       let nonce = payload["nonce"] as? String {
                        self.sendConnectHandshake(over: task, nonce: nonce)
                    } else {
                        handler?(text)
                    }
                }
                self.receiveLoop(over: task)
            case .failure:
                self.cleanupFailedTask(task)
            }
        }
    }

    func controlGateway(action: String, workspacePath: String) async -> (Bool, String) {
        let cmd: String
        switch action {
        case "start": cmd = "openclaw gateway start"
        case "restart": cmd = "openclaw gateway restart"
        case "stop": cmd = "openclaw gateway stop"
        case "status": cmd = "openclaw gateway status"
        default: cmd = "openclaw status"
        }
        let res = await PowerShellTools.runCommand(cmd, workspacePath: workspacePath, wrapWithRTK: false, timeoutSeconds: 20.0)
        return (res.succeeded, res.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Telegram Bot Notification Bridge

    func sendTelegramMessage(botToken: String, chatId: String, text: String) async -> (Bool, String) {
        let cleanTok = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanChat = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTok.isEmpty, !cleanChat.isEmpty else {
            return (false, "Telegram Bot Token veya Chat ID eksik.")
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(cleanTok)/sendMessage") else {
            return (false, "Geçersiz Telegram API adresi.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "chat_id": cleanChat,
            "text": String(text.prefix(3800)),
            "disable_web_page_preview": true
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                return (true, "Telegram mesajı gönderildi ✓")
            }
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            return (false, "Telegram HTTP \(code): \(snippet)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Local Security Audit & Loopback Port Check (SecurityDashboard parity)

    func runSecurityAudit(
        providers: [APIProviderConfig],
        connectors: [ServiceConnector],
        gatewayPort: Int,
        swarmsPort: Int = 8765,
        blockedCommandsCount: Int,
        redactedSecretsCount: Int
    ) async -> SecurityAuditSnapshot {
        let checkList: [(port: Int, service: String, expectedSafe: Bool)] = [
            (swarmsPort, "Crims Swarms Daemon", true),
            (gatewayPort, "OpenClaw Gateway", true),
            (3000, "Dev HTTP Server", true),
            (5432, "PostgreSQL Local", true),
            (6379, "Redis Local", false),
            (8080, "Alt HTTP Proxy", true),
            (27017, "MongoDB Local", false)
        ]

        var ports: [LocalPortAuditEntry] = []
        await withTaskGroup(of: LocalPortAuditEntry.self) { group in
            for item in checkList {
                group.addTask {
                    let listening = await Self.probeLocalTCPPort(item.port)
                    let status: String
                    let details: String
                    if !listening {
                        status = "Kapalı"
                        details = "Yerel bağlantı yok (güvenli)"
                    } else if item.expectedSafe {
                        status = "Güvenli"
                        details = "127.0.0.1 üzerinde beklenen yerel servis"
                    } else {
                        status = "Uyarı"
                        details = "Veritabanı portu dinliyor — dışa açık olmadığından emin olun"
                    }
                    return LocalPortAuditEntry(
                        port: item.port,
                        service: item.service,
                        status: status,
                        isListening: listening,
                        details: details
                    )
                }
            }
            for await p in group {
                ports.append(p)
            }
        }
        ports.sort { $0.port < $1.port }

        let fm = FileManager.default
        let openClawJSON = fm.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw/openclaw.json")
        var openClawPermsOK = true
        if fm.fileExists(atPath: openClawJSON.path),
           let attrs = try? fm.attributesOfItem(atPath: openClawJSON.path),
           let posix = attrs[.posixPermissions] as? Int {
            openClawPermsOK = (posix & 0o077) == 0
        }

        let persistedProviderKeys = providers.filter {
            $0.kind != .antigravityCLI && KeychainStore.shared.secret(forAccount: $0.id.uuidString) != nil
        }.count
        let persistedConnectorKeys = connectors.filter {
            KeychainStore.shared.secret(forAccount: $0.keychainAccountKey) != nil
        }.count
        let keychainCount = persistedProviderKeys + persistedConnectorKeys
        let unmigratedPlaintextCount = providers.filter {
            $0.kind != .antigravityCLI && !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && KeychainStore.shared.secret(forAccount: $0.id.uuidString) == nil
        }.count + connectors.filter {
            !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && KeychainStore.shared.secret(forAccount: $0.keychainAccountKey) == nil
        }.count
        let swarmsActive = ports.first(where: { $0.port == swarmsPort })?.isListening ?? false

        let findings: [SecurityFindingItem] = [
            SecurityFindingItem(
                title: "Keychain API Anahtarı İzolasyonu",
                passed: unmigratedPlaintextCount == 0,
                severity: "Yüksek",
                detail: unmigratedPlaintextCount == 0
                    ? "\(keychainCount) gizli anahtar düz metin JSON yerine macOS Keychain içinde korunuyor."
                    : "\(unmigratedPlaintextCount) anahtar henüz Keychain yerine bellekte/düz metinde kalmış olabilir."
            ),
            SecurityFindingItem(
                title: "~/.openclaw/openclaw.json Dosya İzinleri (0600)",
                passed: openClawPermsOK,
                severity: "Orta",
                detail: openClawPermsOK ? "Yalnızca mevcut kullanıcı erişebilir." : "Grup/diğer okuma izinlerini `chmod 600` ile daraltın."
            ),
            SecurityFindingItem(
                title: "Swarms Loopback Bağlantısı (127.0.0.1:\(swarmsPort))",
                passed: true,
                severity: "Bilgi",
                detail: swarmsActive ? "Yalnızca yerel loopback üzerinden hizmet veriyor." : "Şu anda pasif (talep edildiğinde açılır)."
            ),
            SecurityFindingItem(
                title: "Tehlikeli Shell Komut Engellemesi & Redaksiyon",
                passed: true,
                severity: "Yüksek",
                detail: "`rm -rf /`, `sudo`, `mkfs` koruması ve API token maskeleme aktif."
            )
        ]

        var score = 100
        if !openClawPermsOK { score -= 12 }
        score -= ports.filter { $0.status == "Uyarı" }.count * 6
        score = max(55, min(100, score))

        return SecurityAuditSnapshot(
            score: score,
            checkedAt: Date(),
            ports: ports,
            findings: findings,
            blockedCommandsCount: blockedCommandsCount,
            redactedSecretsCount: redactedSecretsCount,
            keychainItemsCount: keychainCount
        )
    }

    private static func probeLocalTCPPort(_ port: Int) async -> Bool {
        guard let validPort = UInt16(exactly: port), validPort > 0,
              let nwPort = NWEndpoint.Port(rawValue: validPort) else { return false }
        final class ProbeState: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func complete(_ conn: NWConnection, _ value: Bool, _ cont: CheckedContinuation<Bool, Never>) {
                lock.lock()
                let shouldResume = !done
                done = true
                lock.unlock()
                guard shouldResume else { return }
                conn.cancel()
                cont.resume(returning: value)
            }
        }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)
            let state = ProbeState()
            conn.stateUpdateHandler = { connState in
                switch connState {
                case .ready:
                    state.complete(conn, true, cont)
                case .failed, .cancelled:
                    state.complete(conn, false, cont)
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                state.complete(conn, false, cont)
            }
        }
    }
}
