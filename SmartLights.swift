import Cocoa
import WebKit
import Carbon
import ServiceManagement

// ═══════════════════════════════════════════════════════════
//  Yeelight QuickControl — macOS Menu Bar App
//  Lightweight Yeelight controller via NSStatusBar + WKWebView
// ═══════════════════════════════════════════════════════════

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var webView: WKWebView!
    var serverProcess: Process?
    var eventMonitor: Any?
    var currentHotKeyRef: EventHotKeyRef?
    var currentHandlerRef: EventHandlerRef?

    func configurationURL() -> URL {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let current = homeDirectory.appendingPathComponent(".yeelight-quickcontrol.json")
        if FileManager.default.fileExists(atPath: current.path) {
            return current
        }
        return homeDirectory.appendingPathComponent(".smart-lights.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startServer()
        enableLoginItemByDefault()
        setupStatusItem()
        setupPopover()

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
        
        // Initial shortcut load
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.registerGlobalShortcut()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "shortcutUpdated" || message.name == "languageUpdated" {
            DispatchQueue.main.async { [weak self] in
                self?.registerGlobalShortcut()
            }
        } else if message.name == "loginItemStatusRequested" {
            DispatchQueue.main.async { [weak self] in
                self?.sendLoginItemStatusToWebView()
            }
        } else if message.name == "loginItemUpdated" {
            let enabled = (message.body as? NSNumber)?.boolValue ?? (message.body as? Bool) ?? false
            DispatchQueue.main.async { [weak self] in
                self?.setLoginItem(enabled)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverProcess?.terminate()
        serverProcess?.waitUntilExit()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Unregister global hotkey
        if let ref = currentHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let href = currentHandlerRef {
            RemoveEventHandler(href)
        }
    }

    // ── Status Bar Item ──
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "Yeelight QuickControl")
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // ── Popover with WKWebView ──
    func setupPopover() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "shortcutUpdated")
        config.userContentController.add(self, name: "languageUpdated")
        config.userContentController.add(self, name: "loginItemStatusRequested")
        config.userContentController.add(self, name: "loginItemUpdated")

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 420), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let vc = NSViewController()
        vc.view = webView

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = vc
    }

    @objc func togglePopover() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            registerGlobalShortcut() // Reload global shortcut
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            webView.load(URLRequest(url: URL(string: "http://127.0.0.1:7655")!))
        }
    }

    func showContextMenu() {
        let menu = NSMenu()
        
        let configUrl = configurationURL()
        var currentLang = "en"
        if let data = try? Data(contentsOf: configUrl),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lang = json["lang"] as? String {
            currentLang = lang
        }

        let langTitles: [String: String] = [
            "en": "Language",
            "tr": "Dil",
            "fr": "Langue",
            "pt": "Idioma",
            "zh": "语言",
            "de": "Sprache",
            "it": "Lingua"
        ]
        let quitTitles: [String: String] = [
            "en": "Quit Yeelight QuickControl",
            "tr": "Çıkış Yap",
            "fr": "Quitter Yeelight QuickControl",
            "pt": "Sair do Yeelight QuickControl",
            "zh": "退出 Yeelight QuickControl",
            "de": "Yeelight QuickControl beenden",
            "it": "Esci da Yeelight QuickControl"
        ]
        // Language Submenu
        let langMenu = NSMenu()
        let languages = [
            ("English", "en"),
            ("Türkçe", "tr"),
            ("Français", "fr"),
            ("Português", "pt"),
            ("中文", "zh"),
            ("Deutsch", "de"),
            ("Italiano", "it")
        ]
        for (name, code) in languages {
            let item = NSMenuItem(title: name, action: #selector(changeLanguageNative(_:)), keyEquivalent: "")
            item.representedObject = code
            item.state = (code == currentLang) ? .on : .off
            item.target = self
            langMenu.addItem(item)
        }
        
        let langMenuItem = NSMenuItem(title: langTitles[currentLang] ?? "Language", action: nil, keyEquivalent: "")
        langMenuItem.submenu = langMenu
        menu.addItem(langMenuItem)
        
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: quitTitles[currentLang] ?? "Quit Yeelight QuickControl", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }
    
    @objc func changeLanguageNative(_ sender: NSMenuItem) {
        guard let lang = sender.representedObject as? String else { return }
        let url = URL(string: "http://127.0.0.1:7655/api/language")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let json = ["lang": lang]
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.registerGlobalShortcut()
                self?.webView.reload()
            }
        }
        task.resume()
    }

    func registerGlobalShortcut() {
        if let ref = currentHotKeyRef {
            UnregisterEventHotKey(ref)
            currentHotKeyRef = nil
        }
        if let href = currentHandlerRef {
            RemoveEventHandler(href)
            currentHandlerRef = nil
        }
        
        let configUrl = configurationURL()
        guard let data = try? Data(contentsOf: configUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shortcut = json["shortcut"] as? String,
              shortcut != "None",
              let kNum = json["shortcutKeyCode"] as? NSNumber,
              let mNum = json["shortcutModifiers"] as? NSNumber,
              kNum.uint32Value > 0 || mNum.uint32Value > 0 else {
            return
        }
        
        let keyCode = kNum.uint32Value
        let modifiers = mNum.uint32Value
        
        let hotKeyHandler: EventHandlerProcPtr = { (nextHandler, theEvent, userData) -> OSStatus in
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.togglePowerFromSwift()
            }
            return noErr
        }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var href: EventHandlerRef?
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, &href)
        if handlerStatus == noErr {
            currentHandlerRef = href
        }
        
        let hotKeyID = EventHotKeyID(signature: 1397969996, id: 1) // "SMTL"
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if registerStatus == noErr {
            currentHotKeyRef = ref
            print("✓ Global HotKey registered: \(shortcut)")
        }
    }
    
    func togglePowerFromSwift() {
        let statusUrl = URL(string: "http://127.0.0.1:7655/api/status")!
        let task = URLSession.shared.dataTask(with: statusUrl) { [weak self] data, response, _ in
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = json["props"] as? [String: Any],
                  let currentPower = props["power"] as? String else { return }
            
            let newPower = currentPower == "on" ? "off" : "on"
            
            let cmdUrl = URL(string: "http://127.0.0.1:7655/api/command")!
            var request = URLRequest(url: cmdUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["method": "set_power", "params": [newPower, "smooth", 300]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            
            URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
                // Reload web view to reflect new state
                DispatchQueue.main.async {
                    self?.webView.reload()
                }
            }.resume()
        }
        task.resume()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func isLoginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func enableLoginItemByDefault() {
        guard #available(macOS 13.0, *) else { return }
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("Failed to enable automatic startup: \(error)")
        }
    }

    func sendLoginItemStatusToWebView() {
        let enabled = isLoginItemEnabled() ? "true" : "false"
        webView?.evaluateJavaScript("setAutostartStatus(\(enabled), true)", completionHandler: nil)
    }

    func setLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            sendLoginItemStatusToWebView()
            return
        }
        do {
            if enabled && !isLoginItemEnabled() {
                try SMAppService.mainApp.register()
            } else if !enabled && isLoginItemEnabled() {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update Login Item: \(error)")
        }
        sendLoginItemStatusToWebView()
    }

    // ── Node.js Server Management ──
    func startServer() {
        // Reuse a controller left behind by a previous app instance. Never
        // kill an arbitrary process that happens to own port 7655.
        let healthURL = URL(string: "http://127.0.0.1:7655/api/health")!
        var healthRequest = URLRequest(url: healthURL)
        healthRequest.timeoutInterval = 0.5
        URLSession.shared.dataTask(with: healthRequest) { [weak self] _, response, _ in
            let isController = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Yeelight-QuickControl") == "1"
            if isController {
                print("Yeelight QuickControl server is already running")
                return
            }
            DispatchQueue.main.async {
                self?.launchServerProcess()
            }
        }.resume()
    }

    func launchServerProcess() {
        guard serverProcess == nil else { return }
        // Locate server.js inside the app bundle
        guard let serverPath = Bundle.main.path(forResource: "server", ofType: "js") else {
            print("Error: server.js not found in bundle Resources")
            return
        }

        let nodeCandidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        guard let nodePath = nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            print("Error: Node.js was not found. Install Node.js and restart Yeelight QuickControl.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [serverPath]
        process.currentDirectoryURL = URL(fileURLWithPath: (serverPath as NSString).deletingLastPathComponent)
        var env = ProcessInfo.processInfo.environment
        env["YEELIGHT_QUICKCONTROL_EMBEDDED"] = "1"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.serverProcess = nil
                }
            }
            print("Yeelight QuickControl server started (PID: \(process.processIdentifier))")
        } catch {
            print("Failed to start server: \(error)")
        }
    }
}

// ── Entry Point ──
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Hide from Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
