import Foundation

/// Persists user settings in `~/.yeelight-quickcontrol.json`, the same file
/// and format the standalone `server.js` uses, so both modes share settings.
///
/// ```json
/// { "host": "192.168.1.50", "port": 55443, "lang": "en",
///   "shortcut": "Cmd + Shift + L", "shortcutKeyCode": 37, "shortcutModifiers": 768,
///   "favorites": [{ "name": "Read", "mode": "ct", "bright": 80, "ct": 4000 }] }
/// ```
final class ConfigStore {
    static let allowedLanguages: Set<String> = ["en", "tr", "fr", "pt", "zh", "de", "it"]
    static let maxFavorites = 12
    static let maxFavoriteName = 24

    let url: URL
    private let legacyURL: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        url = directory.appendingPathComponent(".yeelight-quickcontrol.json")
        legacyURL = directory.appendingPathComponent(".smart-lights.json")
    }

    /// The stored config, or nil when no (readable) config exists yet.
    func load() -> [String: Any]? {
        for candidate in [url, legacyURL] {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
            NSLog("[Config] Ignoring unreadable config at %@", candidate.path)
        }
        return nil
    }

    /// Merges `patch` into the stored config and writes it atomically.
    @discardableResult
    func update(_ patch: [String: Any]) -> Bool {
        var merged: [String: Any] = [
            "host": NSNull(), "port": 55443, "lang": "en",
            "shortcut": "None", "shortcutKeyCode": 0, "shortcutModifiers": 0,
        ]
        load()?.forEach { merged[$0.key] = $0.value }
        patch.forEach { merged[$0.key] = $0.value }
        do {
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[Config] Failed to save config: %@", error.localizedDescription)
            return false
        }
    }

    var language: String {
        if let lang = load()?["lang"] as? String, Self.allowedLanguages.contains(lang) { return lang }
        return "en"
    }

    var savedDevice: (host: String, port: UInt16)? {
        guard let cfg = load(), let host = cfg["host"] as? String, !host.isEmpty else { return nil }
        let port = (cfg["port"] as? NSNumber)?.intValue ?? 55443
        return (host, UInt16(clamping: port > 0 ? port : 55443))
    }

    /// The stored favorites list, or nil when none was ever saved (the dashboard then shows defaults).
    var favorites: [Any]? {
        load()?["favorites"] as? [Any]
    }

    /// Validates a full favorites list. Returns it sanitized (unknown and
    /// off-mode fields stripped, names trimmed, numbers coerced) or nil.
    /// Mirrors `sanitizeFavorites` in server.js.
    static func sanitizeFavorites(_ value: Any?) -> [[String: Any]]? {
        guard let list = value as? [Any], list.count <= maxFavorites else { return nil }
        var out: [[String: Any]] = []
        for element in list {
            guard let item = element as? [String: Any], let rawName = item["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unicode scalars, same as `[...name].length` in server.js.
            guard (1...maxFavoriteName).contains(name.unicodeScalars.count),
                  let bright = jsonInteger(item["bright"]), (1...100).contains(bright) else { return nil }
            switch item["mode"] as? String {
            case "ct":
                guard let ct = jsonInteger(item["ct"]), (1700...6500).contains(ct) else { return nil }
                out.append(["name": name, "mode": "ct", "bright": bright, "ct": ct])
            case "hsv":
                guard let hue = jsonInteger(item["hue"]), (0...359).contains(hue),
                      let sat = jsonInteger(item["sat"]), (0...100).contains(sat) else { return nil }
                out.append(["name": name, "mode": "hsv", "bright": bright, "hue": hue, "sat": sat])
            default:
                return nil
            }
        }
        return out
    }

    /// Carbon key code and modifier mask, or nil when no shortcut is set.
    var shortcut: (name: String, keyCode: UInt32, modifiers: UInt32)? {
        guard let cfg = load(),
              let name = cfg["shortcut"] as? String, name != "None",
              let key = cfg["shortcutKeyCode"] as? NSNumber,
              let mods = cfg["shortcutModifiers"] as? NSNumber,
              // A shortcut without modifiers would hijack a plain key system-wide.
              mods.uint32Value > 0 else { return nil }
        return (name, key.uint32Value, mods.uint32Value)
    }
}

/// Accepts JSON numbers and numeric strings holding a whole number; rejects bools and fractions.
func jsonInteger(_ value: Any?) -> Int? {
    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
        let d = n.doubleValue
        guard d.isFinite, abs(d) < 1e9 else { return nil }
        return Int(exactly: d)
    }
    if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}
