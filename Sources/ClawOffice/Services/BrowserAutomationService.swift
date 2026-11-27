import Foundation
import AppKit
@preconcurrency import WebKit

/// Embedded interactive browser runtime controlled by both the user UI and autonomous agents.
@MainActor
final class BrowserAutomationService: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var currentURLString: String = "https://developers.hostinger.com"
    @Published var pageTitle: String = "ClawOffice Canlı Browser"
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var useEphemeralSession: Bool = false
    @Published var allowLocalNetwork: Bool = true
    @Published var lastSnapshotSummary: String = ""
    @Published var lastScreenshotPath: String = ""
    @Published var lastActorName: String = ""
    @Published var pendingHumanHandoffReason: String? = nil
    @Published var pendingHandoffAgentId: UUID? = nil
    @Published var navigationError: String? = nil
    @Published var actionLogs: [String] = []

    private(set) var webView: WKWebView
    private var navContinuation: CheckedContinuation<Result<Void, Error>, Never>?
    private var navTimeoutWorkItem: DispatchWorkItem?
    private var kvObservations: [NSKeyValueObservation] = []

    init(ephemeral: Bool = false) {
        self.useEphemeralSession = ephemeral
        self.webView = Self.makeWebView(ephemeral: ephemeral)
        super.init()
        configureWebView(self.webView)
    }

    private static func makeWebView(ephemeral: Bool) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = ephemeral ? .nonPersistent() : .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: cfg)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    private func configureWebView(_ wv: WKWebView) {
        kvObservations.removeAll()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        kvObservations.append(wv.observe(\.title, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                let t = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !t.isEmpty { self?.pageTitle = t }
            }
        })
        kvObservations.append(wv.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                if let u = view.url?.absoluteString, !u.isEmpty {
                    self?.currentURLString = u
                }
            }
        })
        kvObservations.append(wv.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                self?.isLoading = view.isLoading
                self?.canGoBack = view.canGoBack
                self?.canGoForward = view.canGoForward
            }
        })
    }

    func switchSessionProfile(ephemeral: Bool) {
        guard ephemeral != useEphemeralSession else { return }
        finishPendingNavigation(with: .failure(CancellationError()))
        let current = webView.url
        useEphemeralSession = ephemeral
        let nextView = Self.makeWebView(ephemeral: ephemeral)
        configureWebView(nextView)
        webView = nextView
        appendLog(ephemeral ? "Gizli tarayıcı oturumuna geçildi." : "Kalıcı tarayıcı oturumuna geçildi.")
        if let current, validateURL(current).allowed {
            webView.load(URLRequest(url: current))
        }
    }

    private func appendLog(_ line: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        actionLogs.insert("[\(df.string(from: Date()))] \(line)", at: 0)
        if actionLogs.count > 60 {
            actionLogs.removeLast(actionLogs.count - 60)
        }
    }

    nonisolated static func validateBrowserURL(_ url: URL, allowLocalNetwork: Bool) -> (allowed: Bool, reason: String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (false, "Yalnızca http:// ve https:// URL adreslerine izin verilir (engellendi: \(url.scheme ?? "yok")).")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return (false, "Geçersiz URL host.")
        }
        if host == "metadata.google.internal" || host.hasPrefix("169.254.") || host == "fe80::" {
            return (false, "Güvenlik politikası: Bulut metadata / link-local adresine tarayıcı erişimi engellendi.")
        }
        if !allowLocalNetwork {
            let localHosts = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
            if localHosts.contains(host) || host.hasSuffix(".local") || isPrivateIPv4(host) {
                return (false, "Güvenlik ayarı: Yerel ağ/localhost tarayıcı erişimi kapalı (\(host)).")
            }
        }
        return (true, nil)
    }

    nonisolated private static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    private func validateURL(_ url: URL) -> (allowed: Bool, reason: String?) {
        Self.validateBrowserURL(url, allowLocalNetwork: allowLocalNetwork)
    }

    // MARK: - User UI Controls

    func openFromAddressBar(_ raw: String) {
        let normalized = normalizeURLInput(raw)
        guard let url = URL(string: normalized) else {
            navigationError = "Geçersiz URL: \(raw)"
            return
        }
        let check = validateURL(url)
        guard check.allowed else {
            navigationError = check.reason
            appendLog("⛔️ \(check.reason ?? "Engellendi")")
            return
        }
        navigationError = nil
        currentURLString = url.absoluteString
        webView.load(URLRequest(url: url))
        appendLog("Kullanıcı → \(url.absoluteString)")
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func loadHTMLForTesting(_ html: String, baseURL: URL? = URL(string: "https://example.test/")) async {
        navigationError = nil
        let res = await performNavigation(timeoutSeconds: 8) { [weak self] in
            self?.webView.loadHTMLString(html, baseURL: baseURL)
        }
        if case .failure(let err) = res {
            navigationError = err.localizedDescription
        }
        lastSnapshotSummary = await buildDOMSnapshot(maxTextChars: 2400)
    }

    func clearPendingHandoff() {
        pendingHumanHandoffReason = nil
        pendingHandoffAgentId = nil
    }

    // MARK: - Agent Browser Actions

    func normalizeURLInput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
            return "http://" + trimmed
        }
        return "https://" + trimmed
    }

    func agentNavigate(to rawURL: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let normalized = normalizeURLInput(rawURL)
        guard let url = URL(string: normalized) else {
            return (false, "Geçersiz URL: \(rawURL)")
        }
        let check = validateURL(url)
        guard check.allowed else {
            appendLog("⛔️ [\(agentName)] \(check.reason ?? "Engellendi")")
            return (false, check.reason ?? "URL güvenlik engeline takıldı.")
        }

        navigationError = nil
        pendingHumanHandoffReason = nil
        currentURLString = url.absoluteString
        appendLog("🌐 [\(agentName)] Açılıyor: \(url.absoluteString)")

        let navResult = await performNavigation(timeoutSeconds: 22) { [weak self] in
            self?.webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20))
        }

        switch navResult {
        case .success:
            try? await Task.sleep(nanoseconds: 550_000_000)
            var snap = await buildDOMSnapshot(maxTextChars: 2200)
            // Allow single-page apps a brief hydration retry if body text looks empty right after didFinish.
            if snap.contains("Sayfa Metni:\n(Boş)") {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                snap = await buildDOMSnapshot(maxTextChars: 2200)
            }
            lastSnapshotSummary = snap
            return (true, snap)
        case .failure(let err):
            let snap = await buildDOMSnapshot(maxTextChars: 1200)
            if !snap.isEmpty && (webView.title?.isEmpty == false) {
                lastSnapshotSummary = snap
                return (true, "[Kısmi Yükleme Uyarısı: \(err.localizedDescription)]\n\n\(snap)")
            }
            navigationError = err.localizedDescription
            return (false, "Sayfa yüklenemedi (\(url.absoluteString)): \(err.localizedDescription)")
        }
    }

    func agentSnapshot(filter: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let cleanFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let snap = await buildDOMSnapshot(filter: cleanFilter == "." ? "" : cleanFilter, maxTextChars: 3000)
        lastSnapshotSummary = snap
        appendLog("🔎 [\(agentName)] DOM Snapshot (\(snap.count) kr)")
        return (true, snap)
    }

    func agentClick(target: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return (false, "Tıklanacak hedef boş (@e1, CSS seçici veya buton metni verin).")
        }
        let targetJSON = jsQuoted(clean)
        let script = """
        (() => {
            \(Self.sharedElementLookupJS)
            const el = clawFindTarget(\(targetJSON));
            if (!el) return JSON.stringify({ ok: false, error: "Öğe bulunamadı: " + \(targetJSON) + ". Güncel @eN referansları için browser_snapshot çalıştır." });
            el.scrollIntoView({ block: 'center', inline: 'center' });
            const href = (el.getAttribute && el.getAttribute('href')) || '';
            const tag = (el.tagName || '').toLowerCase();
            const label = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 80);
            try { el.focus(); } catch (_) {}
            el.click();
            return JSON.stringify({ ok: true, tag, label, href });
        })()
        """
        do {
            let raw = try await evaluateJSString(script)
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (obj["ok"] as? Bool) == true {
                    let tag = (obj["tag"] as? String) ?? "element"
                    let label = (obj["label"] as? String) ?? clean
                    appendLog("🖱️ [\(agentName)] Tıklandı: \(clean) (\(tag): \(label))")
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    let snap = await buildDOMSnapshot(maxTextChars: 1800)
                    lastSnapshotSummary = snap
                    return (true, "Tıklandı: <\(tag)> \"\(label)\"\n\n\(snap)")
                } else {
                    return (false, (obj["error"] as? String) ?? "Tıklama başarısız.")
                }
            }
            return (true, "Tıklama çalıştırıldı: \(raw)")
        } catch {
            return (false, "Tıklama JS hatası: \(error.localizedDescription)")
        }
    }

    func agentType(argument: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let parts = argument.components(separatedBy: "|||")
        guard parts.count >= 2 else {
            return (false, "Format hatası. Beklenen: @e1_veya_seçici|||yazılacak_metin[|||submit]")
        }
        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1]
        let shouldSubmit = parts.count >= 3 && ["submit", "enter", "true", "1", "evet"].contains(parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())

        let script = """
        (() => {
            \(Self.sharedElementLookupJS)
            const el = clawFindTarget(\(jsQuoted(target)));
            if (!el) return JSON.stringify({ ok: false, error: "Girdi alanı bulunamadı: " + \(jsQuoted(target)) });
            el.scrollIntoView({ block: 'center', inline: 'center' });
            el.focus();
            const nextVal = \(jsQuoted(value));
            const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            if (setter && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) {
                setter.call(el, nextVal);
            } else if ('value' in el) {
                el.value = nextVal;
            } else if (el.isContentEditable) {
                el.innerText = nextVal;
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            let submitted = false;
            if (\(shouldSubmit ? "true" : "false")) {
                if (el.form && typeof el.form.requestSubmit === 'function') {
                    el.form.requestSubmit();
                    submitted = true;
                } else if (el.form) {
                    el.form.submit();
                    submitted = true;
                } else {
                    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
                    el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
                }
            }
            return JSON.stringify({ ok: true, submitted, type: el.type || el.tagName });
        })()
        """
        do {
            let raw = try await evaluateJSString(script)
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["ok"] as? Bool) == false {
                return (false, (obj["error"] as? String) ?? "Yazma başarısız.")
            }
            let masked = value.count > 24 ? String(value.prefix(24)) + "..." : value
            appendLog("⌨️ [\(agentName)] Yazıldı → \(target): \(masked)")
            if shouldSubmit {
                try? await Task.sleep(nanoseconds: 800_000_000)
                let snap = await buildDOMSnapshot(maxTextChars: 1800)
                lastSnapshotSummary = snap
                return (true, "Metin girildi ve form gönderildi.\n\n\(snap)")
            }
            return (true, "Metin girildi → \(target)")
        } catch {
            return (false, "Yazma JS hatası: \(error.localizedDescription)")
        }
    }

    func agentSelect(argument: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let parts = argument.components(separatedBy: "|||")
        guard parts.count >= 2 else {
            return (false, "Format hatası. Beklenen: @e1_veya_seçici|||seçenek_değeri_veya_etiketi")
        }
        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let option = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let script = """
        (() => {
            \(Self.sharedElementLookupJS)
            const el = clawFindTarget(\(jsQuoted(target)));
            if (!el || el.tagName.toLowerCase() !== 'select') {
                return JSON.stringify({ ok: false, error: "Select öğesi bulunamadı: " + \(jsQuoted(target)) });
            }
            const want = \(jsQuoted(option)).toLowerCase();
            const opt = Array.from(el.options).find(o => o.value.toLowerCase() === want || o.text.trim().toLowerCase() === want || o.text.toLowerCase().includes(want));
            if (!opt) return JSON.stringify({ ok: false, error: "Seçenek bulunamadı: " + \(jsQuoted(option)) });
            el.value = opt.value;
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return JSON.stringify({ ok: true, selectedValue: opt.value, selectedText: opt.text });
        })()
        """
        do {
            let raw = try await evaluateJSString(script)
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["ok"] as? Bool) == false {
                return (false, (obj["error"] as? String) ?? "Seçim başarısız.")
            }
            appendLog("🔽 [\(agentName)] Seçildi: \(target) = \(option)")
            return (true, "Seçim güncellendi: \(raw)")
        } catch {
            return (false, "Select JS hatası: \(error.localizedDescription)")
        }
    }

    func agentScroll(argument: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let dir = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let deltaExpr: String
        switch dir {
        case "top", "yukarı_baş": deltaExpr = "window.scrollTo({ top: 0, behavior: 'smooth' })"
        case "bottom", "alt", "en_alt": deltaExpr = "window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' })"
        case "up", "yukarı": deltaExpr = "window.scrollBy({ top: -640, behavior: 'smooth' })"
        default: deltaExpr = "window.scrollBy({ top: 640, behavior: 'smooth' })"
        }
        let script = "(() => { \(deltaExpr); return JSON.stringify({ y: Math.round(window.scrollY), h: document.body.scrollHeight }); })()"
        do {
            let pos = try await evaluateJSString(script)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let snap = await buildDOMSnapshot(maxTextChars: 1800)
            lastSnapshotSummary = snap
            appendLog("📜 [\(agentName)] Kaydırıldı (\(dir.isEmpty ? "down" : dir))")
            return (true, "Kaydırıldı (\(pos))\n\n\(snap)")
        } catch {
            return (false, "Kaydırma hatası: \(error.localizedDescription)")
        }
    }

    func agentWait(argument: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let clean = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if let secs = Double(clean), secs > 0 {
            let clamped = min(15.0, secs)
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            let snap = await buildDOMSnapshot(maxTextChars: 2000)
            lastSnapshotSummary = snap
            appendLog("⏱️ [\(agentName)] Beklendi: \(clamped) sn")
            return (true, "\(clamped) sn beklendi.\n\n\(snap)")
        }
        guard !clean.isEmpty else {
            return (false, "Bekleme parametresi saniye veya CSS seçici olmalı.")
        }
        let selectorJS = jsQuoted(clean)
        for _ in 0..<20 {
            let exists = (try? await evaluateJSString("Boolean(document.querySelector(\(selectorJS))) ? '1' : '0'")) == "1"
            if exists {
                let snap = await buildDOMSnapshot(maxTextChars: 2000)
                lastSnapshotSummary = snap
                appendLog("⏱️ [\(agentName)] Öğe göründü: \(clean)")
                return (true, "Öğe yüklendi: \(clean)\n\n\(snap)")
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return (false, "10 sn içinde seçici görünmedi: \(clean)")
    }

    func agentEvalJS(script: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Çalıştırılacak JavaScript boş olamaz.")
        }
        let wrapped = """
        (() => {
            try {
                const res = (function() { \(trimmed) })();
                if (res === undefined) return "(undefined)";
                if (typeof res === "string") return res;
                return JSON.stringify(res, null, 2);
            } catch (e) {
                return "JS_ERROR: " + (e && e.message ? e.message : String(e));
            }
        })()
        """
        do {
            let out = try await evaluateJSString(wrapped)
            let clipped = out.count > 8000 ? String(out.prefix(8000)) + "\n... [kısaltıldı]" : out
            appendLog("⚡ [\(agentName)] browser_eval (\(clipped.count) kr)")
            return (!out.hasPrefix("JS_ERROR:"), clipped)
        } catch {
            return (false, "browser_eval hatası: \(error.localizedDescription)")
        }
    }

    func agentScreenshot(label: String, workspacePath: String, agentName: String) async -> (succeeded: Bool, output: String) {
        lastActorName = agentName
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression)
        let tag = cleanLabel.isEmpty || cleanLabel == "-" ? "shot" : cleanLabel
        let fm = FileManager.default
        let baseDir = workspacePath.isEmpty ? NSTemporaryDirectory() : (workspacePath + "/.clawoffice-backups/browser-shots")
        try? fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        let fileURL = URL(fileURLWithPath: baseDir).appendingPathComponent("\(Int(Date().timeIntervalSince1970))_\(tag).png")

        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        do {
            let image: NSImage = try await withCheckedThrowingContinuation { cont in
                webView.takeSnapshot(with: cfg) { img, err in
                    if let err {
                        cont.resume(throwing: err)
                    } else if let img {
                        cont.resume(returning: img)
                    } else {
                        cont.resume(throwing: NSError(domain: "BrowserAutomation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Görüntü oluşturulamadı."]))
                    }
                }
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                return (false, "Ekran görüntüsü PNG formatına dönüştürülemedi.")
            }
            try png.write(to: fileURL, options: .atomic)
            lastScreenshotPath = fileURL.path
            appendLog("📸 [\(agentName)] Ekran görüntüsü: \(fileURL.lastPathComponent)")
            return (true, "Ekran görüntüsü kaydedildi: \(fileURL.path)\nSayfa: \(webView.title ?? "-") (\(webView.url?.absoluteString ?? currentURLString))")
        } catch {
            return (false, "Ekran görüntüsü alınamadı (sekme açık olmayabilir): \(error.localizedDescription)")
        }
    }

    func agentRequestHumanHandoff(reason: String, agentId: UUID, agentName: String) -> (succeeded: Bool, output: String) {
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = clean.isEmpty ? "Giriş / 2FA / doğrulama için Canlı Browser sekmesinde kullanıcı onayı gerekiyor." : clean
        pendingHumanHandoffReason = display
        pendingHandoffAgentId = agentId
        lastActorName = agentName
        appendLog("🧑💻 [\(agentName)] İnsan devri: \(display)")
        return (true, "İnsan müdahalesi/onayı bekleniyor: \(display)\nKullanıcı 'Canlı Browser' sekmesinden işlemi tamamladıktan sonra devam edebilirsin. Şu anda giriş/CAPTCHA adımını atlamaya çalışma.")
    }

    // MARK: - DOM Snapshot Helper

    func buildDOMSnapshot(filter: String = "", maxTextChars: Int = 2500) async -> String {
        let filterJS = jsQuoted(filter.lowercased())
        let script = """
        (() => {
            const title = (document.title || '').trim();
            const href = location.href;
            const filter = \(filterJS);
            const hasPassword = Boolean(document.querySelector('input[type="password"]'));
            const hasChallenge = Boolean(document.querySelector('iframe[src*="captcha"], iframe[src*="turnstile"], #cf-challenge-running, .g-recaptcha, .h-captcha'));

            const selector = 'a[href], button, input:not([type="hidden"]), select, textarea, [role="button"], [role="link"], [role="textbox"], [role="combobox"], [role="menuitem"]';
            const nodes = Array.from(document.querySelectorAll(selector));
            const items = [];
            let refIdx = 0;

            for (const el of nodes) {
                const rect = el.getBoundingClientRect();
                const style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden' || rect.width === 0 || rect.height === 0) continue;
                refIdx += 1;
                const ref = '@e' + refIdx;
                el.setAttribute('data-claw-ref', ref);

                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type') || '';
                const placeholder = el.getAttribute('placeholder') || '';
                const aria = el.getAttribute('aria-label') || '';
                const text = (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 70);
                const val = ('value' in el && el.type !== 'password') ? String(el.value || '').slice(0, 40) : '';
                const link = tag === 'a' ? (el.getAttribute('href') || '').slice(0, 80) : '';

                const descParts = [];
                descParts.push(tag + (type ? ':' + type : ''));
                const label = text || aria || placeholder;
                if (label) descParts.push('"' + label + '"');
                if (placeholder && placeholder !== label) descParts.push('placeholder="' + placeholder + '"');
                if (val) descParts.push('val="' + val + '"');
                if (link) descParts.push('-> ' + link);

                const line = ref + ' [' + descParts[0] + '] ' + descParts.slice(1).join(' ');
                if (!filter || line.toLowerCase().includes(filter)) {
                    items.push(line);
                }
                if (items.length >= 75) break;
            }

            const bodyText = (document.body ? (document.body.innerText || '') : '')
                .replace(/\\n{3,}/g, '\\n\\n')
                .trim()
                .slice(0, \(maxTextChars));

            return JSON.stringify({ title, href, hasPassword, hasChallenge, count: items.length, items, bodyText });
        })()
        """
        guard let raw = try? await evaluateJSString(script),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "URL: \(webView.url?.absoluteString ?? currentURLString)\nBaşlık: \(pageTitle)\n(DOM snapshot alınamadı)"
        }

        let title = (obj["title"] as? String) ?? pageTitle
        let href = (obj["href"] as? String) ?? currentURLString
        let hasPass = (obj["hasPassword"] as? Bool) == true
        let hasChallenge = (obj["hasChallenge"] as? Bool) == true
        let items = (obj["items"] as? [String]) ?? []
        let bodyText = (obj["bodyText"] as? String) ?? ""

        var lines: [String] = [
            "🌐 URL: \(href)",
            "📄 Başlık: \(title)"
        ]
        if hasChallenge {
            lines.append("⚠️ DOĞRULAMA UYARISI: Sayfada CAPTCHA / anti-bot ekranı tespit edildi! Aşmaya çalışma; kullanıcıdan tamamlamasını istemek için `<tool name=\"browser_handoff\">Doğrulama/CAPTCHA kullanıcı müdahalesi bekliyor</tool>` çağır.")
        } else if hasPass {
            lines.append("🔐 GİRİŞ FORMU: Sayfada şifre alanı tespit edildi. Kullanıcının kendi hesabına giriş yapması gerekiyorsa `browser_handoff` kullanabilirsin.")
        }
        lines.append("")
        lines.append("🧩 Etkileşimli Öğeler (\(items.count)) — `browser_click @e1` veya `browser_type @e2|||değer` kullan:")
        if items.isEmpty {
            lines.append("(Görünür etkileşimli öğe bulunamadı)")
        } else {
            lines.append(contentsOf: items)
        }
        lines.append("")
        lines.append("📝 Sayfa Metni:")
        lines.append(bodyText.isEmpty ? "(Boş)" : bodyText)
        return lines.joined(separator: "\n")
    }

    private func evaluateJSString(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let str = result as? String {
                    cont.resume(returning: str)
                } else if let res = result {
                    cont.resume(returning: String(describing: res))
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    private func jsQuoted(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let json = String(data: data, encoding: .utf8),
           json.count >= 2 {
            // Strip outer '[' and ']' to obtain a valid JS string literal.
            return String(json.dropFirst().dropLast())
        }
        return "\"\""
    }

    private static let sharedElementLookupJS = """
    function clawFindTarget(t) {
        if (!t) return null;
        if (t.startsWith('@e')) {
            const byRef = document.querySelector('[data-claw-ref="' + t + '"]');
            if (byRef) return byRef;
        }
        try {
            const byCss = document.querySelector(t);
            if (byCss) return byCss;
        } catch (_) {}
        const needle = t.replace(/^text=/i, '').trim().toLowerCase();
        if (!needle) return null;
        const candidates = Array.from(document.querySelectorAll('a, button, [role="button"], input[type="submit"], input, textarea, select, label'));
        return candidates.find(c => {
            const txt = (c.innerText || c.textContent || c.getAttribute('aria-label') || c.getAttribute('placeholder') || '').trim().toLowerCase();
            return txt === needle || txt.includes(needle);
        }) || null;
    }
    """

    // MARK: - Navigation Continuation & Delegates

    private func performNavigation(timeoutSeconds: TimeInterval, trigger: @escaping () -> Void) async -> Result<Void, Error> {
        finishPendingNavigation(with: .failure(CancellationError()))
        return await withCheckedContinuation { cont in
            self.navContinuation = cont
            let work = DispatchWorkItem { [weak self] in
                self?.finishPendingNavigation(with: .failure(NSError(
                    domain: "BrowserAutomation",
                    code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: "Sayfa yükleme zaman aşımı (\(Int(timeoutSeconds)) sn)."]
                )))
            }
            self.navTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
            trigger()
        }
    }

    private func finishPendingNavigation(with result: Result<Void, Error>) {
        navTimeoutWorkItem?.cancel()
        navTimeoutWorkItem = nil
        if let cont = navContinuation {
            navContinuation = nil
            cont.resume(returning: result)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // `about:blank` and `about:srcdoc` appear briefly during loadHTMLString or empty frames.
        if url.absoluteString.hasPrefix("about:") {
            decisionHandler(.allow)
            return
        }
        let check = Self.validateBrowserURL(url, allowLocalNetwork: self.allowLocalNetwork)
        if check.allowed {
            decisionHandler(.allow)
        } else {
            self.navigationError = check.reason
            self.appendLog("⛔️ Navigasyon engellendi: \(url.absoluteString)")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.finishPendingNavigation(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.finishPendingNavigation(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.finishPendingNavigation(with: .failure(error))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep OAuth popups / target=_blank inside the embedded browser frame instead of spawning untracked windows.
        if let url = navigationAction.request.url {
            if Self.validateBrowserURL(url, allowLocalNetwork: self.allowLocalNetwork).allowed {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }
}
