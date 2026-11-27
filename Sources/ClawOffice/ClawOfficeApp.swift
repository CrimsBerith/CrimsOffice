import SwiftUI
import AppKit

final class ClawOfficeWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var originalDelegate: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.originalDelegate = original
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        return (originalDelegate?.responds(to: aSelector) ?? false) || super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate !== self, originalDelegate.responds(to: aSelector) {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }

    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide rather than destroy the single main window so Dock/MenuBar reopen preserves IDE tabs and state.
        sender.orderOut(nil)
        return false
    }
}

final class ClawOfficeAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: ClawOfficeAppDelegate?
    var reopenMainWindow: (() -> Void)?
    weak var mainWindow: NSWindow?
    private var windowDelegateProxy: ClawOfficeWindowDelegateProxy?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.isReleasedWhenClosed = false
        if !(window.delegate is ClawOfficeWindowDelegateProxy) {
            let proxy = ClawOfficeWindowDelegateProxy(original: window.delegate)
            windowDelegateProxy = proxy
            window.delegate = proxy
        }
    }

    func showMainWindow(fallbackOpen: (() -> Void)? = nil) {
        if let win = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.className.contains("MenuBar") }) {
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        } else {
            (fallbackOpen ?? reopenMainWindow)?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.flush()
    }
}

private struct WindowLifecycleBridge: NSViewRepresentable {
    final class BridgeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfReady()
        }

        func attachIfReady() {
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                ClawOfficeAppDelegate.shared?.registerMainWindow(window)
            }
        }
    }

    func makeNSView(context: Context) -> BridgeView {
        BridgeView(frame: .zero)
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.attachIfReady()
    }
}

@main
struct ClawOfficeApp: App {
    @NSApplicationDelegateAdaptor(ClawOfficeAppDelegate.self) var delegate
    @StateObject private var engine = OfficeEngine()

    var body: some Scene {
        Window("Crims Office", id: "main") {
            MainContentView()
                .environmentObject(engine)
                .frame(minWidth: 1120, minHeight: 740)
                .background(WindowLifecycleBridge().allowsHitTesting(false))
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra {
            MenuBarContentView().environmentObject(engine)
        } label: {
            Label(
                engine.activeBusyCount > 0 ? "Crims Office (\(engine.activeBusyCount) Aktif)" : "Crims Office",
                systemImage: engine.activeBusyCount > 0 ? "sparkles" : "flame.fill"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
