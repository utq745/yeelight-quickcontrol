import Foundation
import WebKit

/// Serves the dashboard and its JSON API to the WKWebView through a private
/// URL scheme (`yeelight-app://app/`). Nothing listens on a network port, so
/// other apps and websites cannot reach the controller.
///
/// The routes and payloads mirror `server.js`, so `dashboard.html` runs
/// unchanged in both the app and the standalone browser mode.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "yeelight-app"
    static let rootURL = URL(string: "\(scheme)://app/")!

    private let controller: YeelightController
    private let config: ConfigStore
    private var activeTasks = Set<ObjectIdentifier>()
    private var scanWaiters: [([DiscoveredBulb]) -> Void] = []

    /// Notifies the app after settings that affect native UI change.
    var onSettingsChanged: (() -> Void)?

    init(controller: YeelightController, config: ConfigStore) {
        self.controller = controller
        self.config = config
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        activeTasks.insert(ObjectIdentifier(task))
        let request = task.request
        let path = request.url?.path ?? "/"
        let method = request.httpMethod ?? "GET"
        route(method: method, path: path.isEmpty ? "/" : path, body: Self.body(of: request), task: task)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    // MARK: Routing

    private func route(method: String, path: String, body: [String: Any]?, task: WKURLSchemeTask) {
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            guard let url = Bundle.main.url(forResource: "dashboard", withExtension: "html"),
                  let html = try? Data(contentsOf: url) else {
                return respond(task, status: 500, contentType: "text/html; charset=utf-8", body: Data("<h1>Error loading UI</h1>".utf8))
            }
            respond(task, status: 200, contentType: "text/html; charset=utf-8", body: html)

        case ("GET", "/api/health"):
            json(task, ["ok": true, "service": "yeelight-quickcontrol"])

        case ("GET", "/api/status"):
            json(task, statusPayload())

        case ("POST", "/api/scan"):
            scanShared { [weak self] found in
                self?.json(task, ["devices": found.map { ["host": $0.host, "port": Int($0.port)] }])
            }

        case ("POST", "/api/connect"):
            guard let body, let rawHost = body["host"] as? String, !rawHost.isEmpty else {
                return json(task, ["error": "valid JSON body and host required"], status: 400)
            }
            let host = rawHost.trimmingCharacters(in: .whitespaces)
            let portValue = body["port"] == nil ? 55443 : (Self.integer(body["port"]) ?? -1)
            guard Discovery.isIPv4(host), (1...65535).contains(portValue) else {
                return json(task, ["error": "invalid host or port"], status: 400)
            }
            controller.connect(host: host, port: UInt16(portValue)) { [weak self] result in
                switch result {
                case .success: self?.json(task, ["ok": true])
                case .failure(let error): self?.json(task, ["error": error.localizedDescription], status: 502)
                }
            }

        case ("POST", "/api/disconnect"):
            controller.disconnect()
            json(task, ["ok": true])

        case ("POST", "/api/command"):
            guard let body else { return json(task, ["error": "valid JSON body required"], status: 400) }
            let method = body["method"] as? String
            switch YeelightController.validate(method: method, params: body["params"] as? [Any]) {
            case .failure(let error):
                json(task, ["error": error.message], status: 400)
            case .success(let params):
                guard controller.isConnected, let method else {
                    return json(task, ["error": "device is not connected"], status: 503)
                }
                controller.send(method: method, params: params)
                json(task, ["ok": true])
            }

        case ("POST", "/api/favorites"):
            guard let favorites = ConfigStore.sanitizeFavorites(body?["favorites"]) else {
                return json(task, ["error": "invalid favorites"], status: 400)
            }
            guard config.update(["favorites": favorites]) else { return json(task, ["error": "could not save settings"], status: 500) }
            json(task, ["ok": true, "favorites": favorites])

        case ("POST", "/api/language"):
            guard let lang = body?["lang"] as? String, ConfigStore.allowedLanguages.contains(lang) else {
                return json(task, ["error": "unsupported language"], status: 400)
            }
            guard config.update(["lang": lang]) else { return json(task, ["error": "could not save settings"], status: 500) }
            onSettingsChanged?()
            json(task, ["ok": true])

        case ("POST", "/api/shortcut"):
            guard let shortcut = body?["shortcut"] as? String, shortcut.count <= 80,
                  !shortcut.trimmingCharacters(in: .whitespaces).isEmpty else {
                return json(task, ["error": "valid shortcut required"], status: 400)
            }
            let keyCode = body?["keyCode"] == nil ? 0 : (Self.integer(body?["keyCode"]) ?? -1)
            let modifiers = body?["modifiers"] == nil ? 0 : (Self.integer(body?["modifiers"]) ?? -1)
            guard (0...127).contains(keyCode), (0...65535).contains(modifiers) else {
                return json(task, ["error": "invalid shortcut key data"], status: 400)
            }
            guard config.update(["shortcut": shortcut, "shortcutKeyCode": keyCode, "shortcutModifiers": modifiers]) else {
                return json(task, ["error": "could not save settings"], status: 500)
            }
            onSettingsChanged?()
            json(task, ["ok": true])

        default:
            json(task, ["error": "not found"], status: 404)
        }
    }

    func statusPayload() -> [String: Any] {
        let cfg = config.load()
        var device: Any = NSNull()
        if let host = controller.host { device = ["host": host, "port": Int(controller.port)] }
        return [
            "connected": controller.isConnected,
            "reconnecting": !controller.isConnected && controller.isReconnecting,
            "device": device,
            "hasConfig": cfg != nil,
            "lang": config.language,
            "shortcut": cfg?["shortcut"] as? String ?? "None",
            "shortcutKeyCode": (cfg?["shortcutKeyCode"] as? NSNumber)?.intValue ?? 0,
            "shortcutModifiers": (cfg?["shortcutModifiers"] as? NSNumber)?.intValue ?? 0,
            // NSNull (not defaults) when never saved: the dashboard shows localized defaults.
            "favorites": (cfg?["favorites"] as? [Any]) ?? NSNull(),
            "props": controller.props,
        ]
    }

    /// Concurrent scan requests share one network scan.
    private func scanShared(_ completion: @escaping ([DiscoveredBulb]) -> Void) {
        scanWaiters.append(completion)
        guard scanWaiters.count == 1 else { return }
        Discovery.scan { [weak self] found in
            guard let self else { return }
            let waiters = self.scanWaiters
            self.scanWaiters.removeAll()
            waiters.forEach { $0(found) }
        }
    }

    // MARK: Responses

    private func json(_ task: WKURLSchemeTask, _ payload: [String: Any], status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        respond(task, status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, contentType: String, body: Data) {
        // WebKit raises if a stopped task is answered.
        guard activeTasks.remove(ObjectIdentifier(task)) != nil, let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": contentType,
                  "Content-Length": String(body.count),
                  "Cache-Control": "no-store",
              ]) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    private static func integer(_ value: Any?) -> Int? { jsonInteger(value) }

    private static func body(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, collected.count <= 16 * 1024 {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                collected.append(chunk, count: n)
            }
            data = collected
        }
        guard let data, data.count <= 16 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
