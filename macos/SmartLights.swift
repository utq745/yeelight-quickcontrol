import Cocoa
import WebKit
import Carbon
import ServiceManagement

// ═══════════════════════════════════════════════════════════
//  Yeelight QuickControl — macOS Menu Bar App
//  Native Yeelight controller via NSStatusBar + WKWebView
// ═══════════════════════════════════════════════════════════

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // Hide from Dock
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let config = ConfigStore()
    private lazy var controller = YeelightController(config: config)
    private lazy var schemeHandler = AppSchemeHandler(controller: controller, config: config)

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var webView: WKWebView!
    private var eventMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var refreshScheduled = false

    /// `YEELIGHT_QUICKCONTROL_SELFTEST=1` loads the dashboard headlessly,
    /// exercises the API bridge, prints the result and exits (used by CI).
    private let isSelfTest = ProcessInfo.processInfo.environment["YEELIGHT_QUICKCONTROL_SELFTEST"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPopover()
        if isSelfTest { return }

        enableLoginItemByDefault()
        setupStatusItem()
        installHotKeyHandler()
        registerGlobalShortcut()

        controller.onChange = { [weak self] in self?.pushStateToWebView() }
        schemeHandler.onSettingsChanged = { [weak self] in self?.registerGlobalShortcut() }
        controller.autoConnect()

        // A transient popover does not always close when another app is
        // clicked while this accessory app is inactive.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    /// `yeelight-quickcontrol://…` URLs from other apps (see LightCommand.swift).
    /// If the app was not running, macOS launches it first; the command then
    /// waits until the bulb is connected.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isSelfTest else { return }
        for url in urls {
            guard let command = LightCommand.parse(url) else {
                NSLog("[URL] Unsupported URL: %@", url.absoluteString)
                continue
            }
            controller.perform(command) { [config] in config.favorites }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = hotKeyHandlerRef { RemoveEventHandler(handler) }
    }

    // MARK: Status item & popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Yeelight QuickControl")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        let webConfig = WKWebViewConfiguration()
        webConfig.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        for name in ["shortcutUpdated", "languageUpdated", "loginItemStatusRequested", "loginItemUpdated", "openLoginItemsSettings", "contentHeight"] {
            webConfig.userContentController.add(self, name: name)
        }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 360), configuration: webConfig)
        webView.navigationDelegate = self
        // Transparent background for the glass effect. This is a private
        // WebKit property, so only set it when it exists.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }

        let viewController = NSViewController()
        viewController.view = webView

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 360)
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = viewController
        popover.delegate = self

        // Load once; the page stays alive and is refreshed when shown.
        webView.load(URLRequest(url: AppSchemeHandler.rootURL))
    }

    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            setPanelActive(true)
            sendLoginItemStatusToWebView()
        }
    }

    /// The dashboard reports its natural height so the popover hugs the
    /// content and grows when more favorites are added.
    private func resizePopover(toContentHeight height: Double) {
        let clamped = min(max(height.rounded(.up), 200), 640)
        guard abs(popover.contentSize.height - clamped) >= 1 else { return }
        popover.contentSize = NSSize(width: 320, height: clamped)
    }

    func popoverDidClose(_ notification: Notification) {
        setPanelActive(false)
    }

    private func setPanelActive(_ active: Bool) {
        webView.evaluateJavaScript("window.setPanelActive && window.setPanelActive(\(active))", completionHandler: nil)
    }

    /// Pushes bulb changes to a visible dashboard right away instead of waiting for its next poll.
    private func pushStateToWebView() {
        guard popover?.isShown == true, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshScheduled = false
            self?.webView.evaluateJavaScript("window.refreshState && window.refreshState()", completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isSelfTest {
            runSelfTest()
        } else {
            setPanelActive(popover.isShown)
        }
    }

    // MARK: Context menu

    private static let languageMenuTitles = ["en": "Language", "tr": "Dil", "fr": "Langue", "pt": "Idioma", "zh": "语言", "de": "Sprache", "it": "Lingua"]
    private static let quitTitles = [
        "en": "Quit Yeelight QuickControl", "tr": "Çıkış Yap", "fr": "Quitter Yeelight QuickControl",
        "pt": "Sair do Yeelight QuickControl", "zh": "退出 Yeelight QuickControl",
        "de": "Yeelight QuickControl beenden", "it": "Esci da Yeelight QuickControl",
    ]
    private static let languages = [("English", "en"), ("Türkçe", "tr"), ("Français", "fr"), ("Português", "pt"), ("中文", "zh"), ("Deutsch", "de"), ("Italiano", "it")]

    private func showContextMenu() {
        let currentLang = config.language
        let menu = NSMenu()

        let langMenu = NSMenu()
        for (name, code) in Self.languages {
            let item = NSMenuItem(title: name, action: #selector(changeLanguageNative(_:)), keyEquivalent: "")
            item.representedObject = code
            item.state = code == currentLang ? .on : .off
            item.target = self
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: Self.languageMenuTitles[currentLang] ?? "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: Self.quitTitles[currentLang] ?? "Quit Yeelight QuickControl", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func changeLanguageNative(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? String, ConfigStore.allowedLanguages.contains(lang) else { return }
        config.update(["lang": lang])
        webView.evaluateJavaScript("window.refreshState && window.refreshState()", completionHandler: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Script messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "shortcutUpdated", "languageUpdated":
            registerGlobalShortcut()
        case "loginItemStatusRequested":
            sendLoginItemStatusToWebView()
        case "contentHeight":
            if let height = (message.body as? NSNumber)?.doubleValue { resizePopover(toContentHeight: height) }
        case "openLoginItemsSettings":
            SMAppService.openSystemSettingsLoginItems()
        case "loginItemUpdated":
            let enabled = (message.body as? NSNumber)?.boolValue ?? (message.body as? Bool) ?? false
            setLoginItem(enabled)
        default:
            break
        }
    }

    // MARK: Global shortcut

    /// Installs the Carbon hot-key handler once; shortcuts are (re)registered separately.
    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.controller.togglePower() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
    }

    private func registerGlobalShortcut() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        guard let shortcut = config.shortcut else { return }
        let hotKeyID = EventHotKeyID(signature: 0x534D_544C, id: 1) // "SMTL"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            NSLog("Global hot key registered: %@", shortcut.name)
        } else {
            NSLog("Could not register global hot key %@ (status %d); it may be in use by another app", shortcut.name, status)
        }
    }

    // MARK: Login item

    /// Login items point at a bundle path. A copy run from Downloads, a DMG or
    /// a build folder would register *that* path, so only install there.
    private var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private func enableLoginItemByDefault() {
        guard isInApplicationsFolder, SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Failed to enable automatic startup: %@", error.localizedDescription)
        }
    }

    /// Reports the login item state to the dashboard:
    /// "enabled" | "disabled" | "approval" (user must allow it in System Settings),
    /// plus an optional detail message (an error, or the "move to Applications" hint).
    private func sendLoginItemStatusToWebView(error: String? = nil) {
        let state: String
        switch SMAppService.mainApp.status {
        case .enabled: state = "enabled"
        case .requiresApproval: state = "approval"
        default: state = "disabled"
        }
        var detail = error
        if detail == nil && !isInApplicationsFolder { detail = "notInApplications" }
        let payload: [String: Any] = ["state": state, "detail": detail ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("setAutostartStatus(\(json))", completionHandler: nil)
    }

    private func setLoginItem(_ enabled: Bool) {
        var failure: String?
        do {
            let status = SMAppService.mainApp.status
            if enabled && status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled && (status == .enabled || status == .requiresApproval) {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Failed to update login item: %@", error.localizedDescription)
            failure = error.localizedDescription
        }
        // macOS may hold a new login item until the user approves it.
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        sendLoginItemStatusToWebView(error: failure)
    }

    // MARK: Self-test

    /// Exercises the dashboard ↔ native bridge without touching the bulb or saved settings.
    private func runSelfTest() {
        let script = """
        const results = {};
        const call = async (path, method = 'GET', body) => {
          const opts = { method, headers: { 'Content-Type': 'application/json' } };
          if (body !== undefined) opts.body = JSON.stringify(body);
          const res = await fetch('/api/' + path, opts);
          return { status: res.status, body: await res.json() };
        };
        results.page = !!document.getElementById('powerBtn');
        results.health = await call('health');
        results.status = await call('status');
        results.badPower = await call('command', 'POST', { method: 'set_power', params: ['maybe'] });
        results.notConnected = await call('command', 'POST', { method: 'set_bright', params: [50, 'smooth', 300] });
        results.badLang = await call('language', 'POST', { lang: 'xx' });
        // Invalid lists are rejected before anything is written to the real config.
        results.badFavorites = await call('favorites', 'POST', { favorites: [{ name: '', mode: 'ct', bright: 50, ct: 4000 }] });
        results.badScene = await call('command', 'POST', { method: 'set_scene', params: ['rgb', 1, 2] });
        results.hasFavoritesKey = 'favorites' in (results.status.body || {});
        results.missing = await call('nope');
        return JSON.stringify(results);
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            var ok = false
            switch result {
            case .success(let value):
                let text = value as? String ?? ""
                print("SELFTEST " + text)
                if let data = text.data(using: .utf8),
                   let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    func status(_ key: String) -> Int? { ((r[key] as? [String: Any])?["status"] as? NSNumber)?.intValue }
                    func error(_ key: String) -> String? { ((r[key] as? [String: Any])?["body"] as? [String: Any])?["error"] as? String }
                    ok = r["page"] as? Bool == true
                        && status("health") == 200
                        && status("status") == 200
                        && status("badPower") == 400 && error("badPower") == "power must be on or off"
                        && status("notConnected") == 503
                        && status("badLang") == 400
                        && status("badFavorites") == 400 && error("badFavorites") == "invalid favorites"
                        && status("badScene") == 400 && error("badScene") == "invalid scene"
                        && r["hasFavoritesKey"] as? Bool == true
                        && status("missing") == 404
                }
            case .failure(let error):
                print("SELFTEST error: \(error)")
            }
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
    }
}
