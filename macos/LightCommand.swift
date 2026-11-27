import Foundation

/// Commands other apps can send through the `yeelight-quickcontrol://` URL
/// scheme (Logi Options+ plugins, Shortcuts, Raycast, Alfred, `open`, …).
///
///     yeelight-quickcontrol://toggle
///     yeelight-quickcontrol://on            yeelight-quickcontrol://off
///     yeelight-quickcontrol://brightness/40
///     yeelight-quickcontrol://brightness/up      (…/down; default step 10, ?step=5)
///     yeelight-quickcontrol://white/2700         (color temperature in K)
///     yeelight-quickcontrol://color/250/60       (hue 0–359, saturation 0–100)
///     yeelight-quickcontrol://favorite/1         (1-based position)
///     yeelight-quickcontrol://favorite/Okuma     (name, case-insensitive, URL-encoded)
enum LightCommand: Equatable {
    case toggle
    case on
    case off
    case brightness(Int)
    case brightnessStep(Int)
    case white(kelvin: Int)
    case color(hue: Int, sat: Int)
    case favoriteIndex(Int)
    case favoriteNamed(String)

    static let scheme = "yeelight-quickcontrol"

    static func parse(_ url: URL) -> LightCommand? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.host?.lowercased() else { return nil }
        // URLComponents.path is percent-decoded (e.g. "favorite/Gece%20Modu").
        let args = components.path.split(separator: "/").map(String.init)
        func int(_ i: Int) -> Int? { i < args.count ? Int(args[i]) : nil }

        switch action {
        case "toggle" where args.isEmpty: return .toggle
        case "on" where args.isEmpty: return .on
        case "off" where args.isEmpty: return .off

        case "brightness":
            guard args.count == 1 else { return nil }
            if let value = int(0) { return (1...100).contains(value) ? .brightness(value) : nil }
            let stepText = components.queryItems?.first { $0.name == "step" }?.value
            guard let step = stepText.map({ Int($0) }) ?? 10, (1...100).contains(step) else { return nil }
            switch args[0].lowercased() {
            case "up": return .brightnessStep(step)
            case "down": return .brightnessStep(-step)
            default: return nil
            }

        case "white", "temperature", "ct":
            guard args.count == 1, let k = int(0), (1700...6500).contains(k) else { return nil }
            return .white(kelvin: k)

        case "color", "hsv":
            guard args.count == 2, let h = int(0), (0...359).contains(h),
                  let s = int(1), (0...100).contains(s) else { return nil }
            return .color(hue: h, sat: s)

        case "favorite", "favourite", "scene":
            guard args.count == 1 else { return nil }
            if let n = int(0) { return n >= 1 ? .favoriteIndex(n - 1) : nil }
            let name = args[0].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .favoriteNamed(name)

        default:
            return nil
        }
    }
}

/// Built-in favorites the dashboard shows until the user saves their own.
/// Values must match `defaultFavorites()` in dashboard.html; names are listed
/// in every UI language so `favorite/<name>` works whatever language is set.
enum DefaultFavorites {
    static let items: [(names: Set<String>, scene: [String: Any])] = [
        (["reading", "okuma", "lecture", "leitura", "阅读", "lesen", "lettura"],
         ["mode": "ct", "ct": 4000, "bright": 80]),
        (["evening", "akşam", "soirée", "entardecer", "傍晚", "abend", "sera"],
         ["mode": "ct", "ct": 2700, "bright": 45]),
        (["night", "gece", "nuit", "noite", "夜晚", "nacht", "notte"],
         ["mode": "ct", "ct": 1700, "bright": 5]),
        (["movie", "film", "filme", "电影"],
         ["mode": "hsv", "hue": 250, "sat": 60, "bright": 25]),
    ]
}

extension YeelightController {
    /// Resolves a favorite from the saved list, or from the built-in defaults when none was saved.
    static func favorite(for command: LightCommand, saved: [Any]?) -> [String: Any]? {
        let list = ConfigStore.sanitizeFavorites(saved)
        switch command {
        case .favoriteIndex(let index):
            if let list { return index < list.count ? list[index] : nil }
            return index < DefaultFavorites.items.count ? DefaultFavorites.items[index].scene : nil
        case .favoriteNamed(let name):
            let wanted = name.lowercased()
            if let list { return list.first { ($0["name"] as? String)?.lowercased() == wanted } }
            return DefaultFavorites.items.first { $0.names.contains(wanted) }?.scene
        default:
            return nil
        }
    }

    /// Builds the bulb command for a URL command. Brightness, white and color
    /// use `set_scene`, which also turns a switched-off bulb on.
    /// Returns nil when there is nothing to do (e.g. unknown favorite).
    func plan(_ command: LightCommand, favorites: [Any]?) -> (method: String, params: [Any])? {
        let isOn = props["power"] == "on"
        let bright = min(max(Int(props["bright"] ?? "") ?? 100, 1), 100)
        let isWhite = props["color_mode"] == "2"
        let ct = min(max(Int(props["ct"] ?? "") ?? 4000, 1700), 6500)
        let hue = min(max(Int(props["hue"] ?? "") ?? 0, 0), 359)
        let sat = min(max(Int(props["sat"] ?? "") ?? 100, 0), 100)
        func scene(bright b: Int) -> [Any] { isWhite ? ["ct", ct, b] : ["hsv", hue, sat, b] }

        switch command {
        case .toggle:
            return ("set_power", [isOn ? "off" : "on", "smooth", 300])
        case .on:
            return ("set_power", ["on", "smooth", 300])
        case .off:
            return ("set_power", ["off", "smooth", 300])
        case .brightness(let value):
            return ("set_scene", scene(bright: value))
        case .brightnessStep(let delta):
            // From off, "up" just turns the light on at its last brightness.
            if !isOn { return delta > 0 ? ("set_power", ["on", "smooth", 300]) : nil }
            return ("set_bright", [min(max(bright + delta, 1), 100), "smooth", 200])
        case .white(let kelvin):
            return ("set_scene", ["ct", kelvin, bright])
        case .color(let h, let s):
            return ("set_scene", ["hsv", h, s, bright])
        case .favoriteIndex, .favoriteNamed:
            guard let fav = Self.favorite(for: command, saved: favorites),
                  let b = jsonInteger(fav["bright"]) else { return nil }
            if fav["mode"] as? String == "ct", let k = jsonInteger(fav["ct"]) {
                return ("set_scene", ["ct", k, b])
            }
            if let h = jsonInteger(fav["hue"]), let s = jsonInteger(fav["sat"]) {
                return ("set_scene", ["hsv", h, s, b])
            }
            return nil
        }
    }

    /// Runs a URL command once the bulb is connected and its state is known.
    func perform(_ command: LightCommand, favorites: @escaping () -> [Any]?) {
        whenReady { [weak self] in
            guard let self, let step = self.plan(command, favorites: favorites()) else {
                NSLog("[URL] Nothing to do for %@", String(describing: command))
                return
            }
            self.send(method: step.method, params: step.params)
        }
    }
}
