// Integration tests for the native controller. Run with ./macos/Tests/run.sh
// Compiled together with ConfigStore.swift, Discovery.swift and
// YeelightController.swift; talks real TCP to an in-process fake bulb.

import Foundation
import Network

// MARK: Minimal harness

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failures += 1
        print("  ✗ line \(line): \(message)")
    }
}

/// Spins the main run loop (which also drains the main dispatch queue) until `condition` holds.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

func test(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch {
        failures += 1
        print("  ✗ threw \(error)")
    }
}

// MARK: Fake bulb

final class FakeBulb {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var buffers: [ObjectIdentifier: Data] = [:]
    var received: [(method: String, params: [Any])] = []
    var props: [String: String] = ["power": "on", "bright": "42", "ct": "3000", "rgb": "255", "hue": "120", "sat": "80", "color_mode": "2"]
    /// When set, every non-get_prop reply uses this id (to provoke ID collisions).
    var forcedReplyID: Int?
    var connectionCount: Int { connections.count }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: .main)
        guard waitUntil(3, { self.listener.port != nil && self.listener.port!.rawValue != 0 }) else {
            throw NSError(domain: "FakeBulb", code: 1)
        }
    }

    var port: UInt16 { listener.port!.rawValue }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: .main)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.handle(data, from: conn) }
            if done || error != nil {
                self.connections.removeAll { $0 === conn }
                return
            }
            self.receive(conn)
        }
    }

    private func handle(_ data: Data, from conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        var buffer = (buffers[key] ?? Data()) + data
        let sep = Data("\r\n".utf8)
        while let r = buffer.range(of: sep) {
            let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = msg["id"] as? Int, let method = msg["method"] as? String else { continue }
            let params = msg["params"] as? [Any] ?? []
            received.append((method, params))
            var reply: [String: Any]
            if method == "get_prop" {
                reply = ["id": id, "result": params.map { props[$0 as? String ?? ""] ?? "" }]
            } else {
                reply = ["id": forcedReplyID ?? id, "result": ["ok"]]
            }
            var out = try! JSONSerialization.data(withJSONObject: reply)
            out.append(sep)
            conn.send(content: out, completion: .contentProcessed { _ in })
        }
        buffers[key] = buffer
    }

    func push(_ params: [String: Any]) {
        var out = try! JSONSerialization.data(withJSONObject: ["method": "props", "params": params])
        out.append(Data("\r\n".utf8))
        connections.forEach { $0.send(content: out, completion: .contentProcessed { _ in }) }
    }

    func dropClients() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    func stop() {
        dropClients()
        listener.cancel()
    }
}

func tempConfig() -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yqc-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ConfigStore(directory: dir)
}

func connect(_ controller: YeelightController, _ bulb: FakeBulb) -> Bool {
    var result: Result<Void, Error>?
    controller.connect(host: "127.0.0.1", port: bulb.port) { result = $0 }
    waitUntil { result != nil }
    if case .success = result { return true }
    return false
}

// MARK: Tests

test("validate commands") {
    func ok(_ m: String, _ p: [Any]) -> [Any]? { try? YeelightController.validate(method: m, params: p).get() }
    check(ok("set_power", ["on"]) != nil, "power on")
    check(ok("set_power", ["maybe"]) == nil, "bad power")
    check(ok("set_bright", [0]) == nil && ok("set_bright", [101]) == nil, "bright out of range")
    check(ok("set_bright", [1]) != nil && ok("set_bright", [100]) != nil, "bright bounds")
    check(ok("set_bright", [50.5]) == nil, "non-integer bright")
    check(ok("set_bright", [true]) == nil, "bool is not a number")
    check((ok("set_bright", ["50"])?.first as? Int) == 50, "numeric string coerced")
    check(ok("set_hsv", [359, 100]) != nil && ok("set_hsv", [360, 100]) == nil && ok("set_hsv", [10, 101]) == nil, "hsv ranges")
    check(ok("set_ct_abx", [1700]) != nil && ok("set_ct_abx", [1699]) == nil && ok("set_ct_abx", [6501]) == nil, "ct ranges")
    check(ok("set_power", ["on", "smooth", 300])?.count == 3, "transition kept")
    check(ok("set_power", ["on", "fade", 300]) == nil, "bad effect")
    check(ok("set_power", ["on", "smooth", 20]) == nil && ok("set_power", ["on", "smooth", 10001]) == nil, "bad duration")
    check(ok("set_power", ["on", "smooth", 300, 1]) == nil, "too many params")
    check(ok("get_prop", ["power"]) == nil, "method not allowed")
}

test("validate set_scene") {
    func ok(_ p: [Any]) -> [Any]? { try? YeelightController.validate(method: "set_scene", params: p).get() }
    func error(_ p: [Any]) -> String? {
        if case .failure(let e) = YeelightController.validate(method: "set_scene", params: p) { return e.message }
        return nil
    }
    let ct = ok(["ct", 1700, 1])
    check(ct?.count == 3 && ct?[0] as? String == "ct" && ct?[1] as? Int == 1700 && ct?[2] as? Int == 1, "ct scene")
    check(ok(["ct", 6500, 100]) != nil, "ct upper bounds")
    let hsv = ok(["hsv", "359", "100", "100"])
    check(hsv?.count == 4 && hsv?[1] as? Int == 359 && hsv?[2] as? Int == 100 && hsv?[3] as? Int == 100, "hsv scene, strings coerced")
    check(ok(["hsv", 0, 0, 1]) != nil, "hsv lower bounds")
    check(error(["color", 16711680, 50]) == "invalid scene" && error(["CT", 2700, 50]) == "invalid scene" && error([]) == "invalid scene", "wrong mode")
    check(ok(["ct", 1699, 50]) == nil && ok(["ct", 6501, 50]) == nil && ok(["ct", 2700, 0]) == nil && ok(["ct", 2700, 101]) == nil, "ct out of range")
    check(ok(["hsv", 360, 50, 50]) == nil && ok(["hsv", -1, 50, 50]) == nil && ok(["hsv", 10, 101, 50]) == nil && ok(["hsv", 10, 50, 0]) == nil, "hsv out of range")
    check(ok(["ct", 2700]) == nil && ok(["ct", 2700, 50, "smooth"]) == nil && ok(["ct", 2700, 50, "smooth", 500]) == nil, "ct wrong length")
    check(ok(["hsv", 10, 50]) == nil && ok(["hsv", 10, 50, 50, "smooth"]) == nil, "hsv wrong length")
    check(ok(["ct", true, 50]) == nil && ok(["ct", 2700, true]) == nil && ok(["hsv", 10, false, 50]) == nil, "bools rejected")
    check(ok(["ct", 2700.5, 50]) == nil && ok(["hsv", 10, 50, "50.5"]) == nil, "fractions rejected")
}

test("favorites sanitizing") {
    func fav(_ extra: [String: Any] = [:], drop: [String] = []) -> [String: Any] {
        var f: [String: Any] = ["name": "Read", "mode": "ct", "bright": 80, "ct": 4000]
        extra.forEach { f[$0.key] = $0.value }
        drop.forEach { f.removeValue(forKey: $0) }
        return f
    }
    let out = ConfigStore.sanitizeFavorites([
        fav(["name": "  Read  ", "extra": 1, "hue": 10]),
        ["name": "Red", "mode": "hsv", "bright": "50", "hue": 0, "sat": 100, "ct": 3000],
    ])
    check(out?.count == 2, "valid list accepted")
    check(out.map { Set($0[0].keys) } == ["name", "mode", "bright", "ct"], "ct item stripped")
    check(out?[0]["name"] as? String == "Read", "name trimmed")
    check(out.map { Set($0[1].keys) } == ["name", "mode", "bright", "hue", "sat"], "hsv item stripped")
    check(out?[1]["bright"] as? Int == 50, "numeric string coerced")
    check(ConfigStore.sanitizeFavorites([Any]())?.isEmpty == true, "empty list valid")
    check(ConfigStore.sanitizeFavorites(Array(repeating: fav(), count: 12))?.count == 12, "12 items ok")
    check(ConfigStore.sanitizeFavorites(Array(repeating: fav(), count: 13)) == nil, "13 items rejected")
    check(ConfigStore.sanitizeFavorites([fav(["name": String(repeating: "x", count: 24)])]) != nil, "24-char name ok")
    check(ConfigStore.sanitizeFavorites([fav(["name": String(repeating: "💡", count: 24)])]) != nil, "24 emoji ok")
    let bad: [Any?] = [
        nil, "x", ["favorites": []], [NSNull()], [[1, 2]],
        [fav(["mode": "rgb"])], [fav(drop: ["mode"])], [fav(drop: ["ct"])], [fav(["ct": 1699])], [fav(["ct": true])],
        [fav(["bright": 0])], [fav(["bright": 101])], [fav(["bright": 50.5])],
        [fav(["name": String(repeating: "x", count: 25)])], [fav(["name": ""])], [fav(["name": "   "])], [fav(["name": 5])],
        [fav(["mode": "hsv", "hue": 10])], [fav(["mode": "hsv", "sat": 10])], [fav(["mode": "hsv", "hue": 360, "sat": 1])],
        [fav(), fav(["ct": 100])],
    ]
    for (i, value) in bad.enumerated() {
        check(ConfigStore.sanitizeFavorites(value) == nil, "invalid favorites #\(i) rejected")
    }
}

test("set_scene reaches the bulb and updates props") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    check(connect(controller, bulb), "connects")
    waitUntil { controller.props["bright"] == "42" }
    controller.send(method: "set_power", params: ["off"])
    waitUntil { bulb.received.contains { $0.method == "set_power" } }

    controller.send(method: "set_scene", params: ["ct", 2700, 30])
    check(controller.props["power"] == "on" && controller.props["bright"] == "30" && controller.props["ct"] == "2700" && controller.props["color_mode"] == "2", "ct scene optimistic props")
    check(waitUntil { bulb.received.contains { $0.method == "set_scene" } }, "ct scene delivered")
    let first = bulb.received.first { $0.method == "set_scene" }?.params
    check(first?.count == 3 && first?[0] as? String == "ct" && first?[1] as? Int == 2700 && first?[2] as? Int == 30, "ct params as numbers")

    controller.send(method: "set_scene", params: ["hsv", 200, 70, 90])
    check(controller.props["bright"] == "90" && controller.props["hue"] == "200" && controller.props["sat"] == "70" && controller.props["color_mode"] == "3", "hsv scene optimistic props")
    check(waitUntil { bulb.received.filter { $0.method == "set_scene" }.count == 2 }, "hsv scene delivered")
    let second = bulb.received.last { $0.method == "set_scene" }?.params
    check(second?.count == 4 && second?[0] as? String == "hsv" && second?[1] as? Int == 200 && second?[2] as? Int == 70 && second?[3] as? Int == 90, "hsv params as numbers")
    controller.disconnect()
}

test("a queued scene drops superseded commands") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    check(connect(controller, bulb), "connects")
    waitUntil { !bulb.received.isEmpty }
    for v in 1...20 { controller.send(method: "set_bright", params: [v]) } // exhaust the burst
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let brightBefore = bulb.received.filter { $0.method == "set_bright" }.count
    controller.send(method: "set_ct_abx", params: [3000])
    controller.send(method: "set_hsv", params: [10, 20])
    controller.send(method: "set_power", params: ["off"])
    controller.send(method: "set_bright", params: [77])
    controller.send(method: "set_scene", params: ["ct", 4000, 60])
    controller.send(method: "set_bright", params: [55]) // after the scene: kept
    check(waitUntil(4) { bulb.received.contains { $0.method == "set_bright" && $0.params.first as? Int == 55 } }, "post-scene set_bright delivered")
    let sent = bulb.received.filter { $0.method != "get_prop" }
    check(sent.filter { $0.method == "set_scene" }.count == 1, "scene sent once")
    check(!sent.contains { ["set_ct_abx", "set_hsv", "set_power"].contains($0.method) }, "superseded commands dropped")
    check(!sent.contains { $0.method == "set_bright" && $0.params.first as? Int == 77 }, "superseded set_bright dropped")
    check(sent.filter { $0.method == "set_bright" }.count == brightBefore + 1, "only the post-scene set_bright added")
    check(sent.suffix(2).map { $0.method } == ["set_scene", "set_bright"], "scene then later bright")
    controller.disconnect()
}

test("favorites persist across other config writes") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let config = tempConfig()
    check(config.favorites == nil, "favorites nil when never saved")
    check(config.update(["lang": "de"]) && config.favorites == nil, "other writes do not invent favorites")
    let list = ConfigStore.sanitizeFavorites([
        ["name": "Read", "mode": "ct", "bright": 80, "ct": 4000],
        ["name": "Blue", "mode": "hsv", "bright": 30, "hue": 240, "sat": 100],
    ])!
    check(config.update(["favorites": list]), "write favorites")
    check(config.update(["lang": "tr"]), "write lang")
    check(config.update(["shortcut": "Cmd + L", "shortcutKeyCode": 37, "shortcutModifiers": 256]), "write shortcut")
    let controller = YeelightController(config: config, scan: { $0([]) })
    check(connect(controller, bulb), "connects (saves host/port)")
    check(config.savedDevice?.port == bulb.port && config.language == "tr", "device and lang saved")
    let stored = config.favorites as? [[String: Any]]
    check(stored?.count == 2 && stored?[0]["name"] as? String == "Read" && stored?[1]["hue"] as? Int == 240, "favorites survived")
    check(config.update(["favorites": [[String: Any]]()]) && (config.favorites?.isEmpty == true), "[] stored as [], not nil")
    controller.disconnect()
}

test("discovery helpers") {
    let hosts = Discovery.hostsForInterface(address: "192.168.1.10", netmask: "255.255.255.0")
    check(hosts.count == 253 && !hosts.contains("192.168.1.10") && hosts.first == "192.168.1.1" && hosts.last == "192.168.1.254", "/24 range")
    check(Discovery.hostsForInterface(address: "10.0.5.7", netmask: "255.255.0.0").count == 253, "/16 narrowed to /24")
    check(Discovery.hostsForInterface(address: "10.0.0.1", netmask: "255.255.255.252") == ["10.0.0.2"], "/30")
    let reply = "HTTP/1.1 200 OK\r\nCache-Control: max-age=3600\r\nLocation: yeelight://192.168.1.239:55443\r\nid: 0x1\r\n"
    check(Discovery.parseSSDPResponse(reply) == DiscoveredBulb(host: "192.168.1.239", port: 55443), "ssdp parse")
    check(Discovery.parseSSDPResponse("Location: yeelight://evil.example:1\r\n") == nil, "ssdp rejects hostnames")
}

test("probe verifies the Yeelight protocol") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    var result: Bool?
    Discovery.probe(host: "127.0.0.1", port: bulb.port, timeout: 1) { ok in DispatchQueue.main.async { result = ok } }
    waitUntil { result != nil }
    check(result == true, "probe accepts fake bulb")

    let silent = try NWListener(using: .tcp, on: .any)
    var held: [NWConnection] = []
    silent.newConnectionHandler = { c in held.append(c); c.start(queue: .main) }
    silent.start(queue: .main)
    waitUntil { silent.port != nil && silent.port!.rawValue != 0 }
    result = nil
    Discovery.probe(host: "127.0.0.1", port: silent.port!.rawValue, timeout: 0.5) { ok in DispatchQueue.main.async { result = ok } }
    waitUntil { result != nil }
    check(result == false, "probe rejects a silent TCP service")
    silent.cancel()
}

test("connect, read props, persist device") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let config = tempConfig()
    let controller = YeelightController(config: config, scan: { $0([]) })
    check(connect(controller, bulb), "connects")
    check(waitUntil { controller.props["bright"] == "42" }, "props loaded from get_prop")
    check(controller.props["hue"] == "120", "hue loaded")
    check(config.savedDevice?.port == bulb.port, "device saved to config")

    bulb.push(["power": "off", "bright": 7])
    check(waitUntil { controller.props["power"] == "off" && controller.props["bright"] == "7" }, "props notification applied")
    controller.disconnect()
}

test("command replies never overwrite props (ID collision regression)") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    check(connect(controller, bulb), "connects")
    waitUntil { controller.props["bright"] == "42" }
    bulb.forcedReplyID = 1 // the id of the initial get_prop
    for i in 0..<5 { controller.send(method: "set_bright", params: [10 + i]) ; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(controller.props["power"] != "ok", "power not clobbered by a command reply")
    check(controller.props["bright"] == "14", "optimistic brightness kept")
    controller.disconnect()
}

test("rate limiting coalesces bursts, latest value wins") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    check(connect(controller, bulb), "connects")
    waitUntil { !bulb.received.isEmpty }
    for v in 1...40 { controller.send(method: "set_bright", params: [v]) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let early = bulb.received.filter { $0.method == "set_bright" }
    check(early.count <= 16, "burst capped (got \(early.count))")
    check(waitUntil(3) { (bulb.received.last { $0.method == "set_bright" }?.params.first as? Int) == 40 }, "last value delivered")
    let total = bulb.received.filter { $0.method == "set_bright" }.count
    check(total < 20, "intermediate values coalesced (got \(total))")
    controller.disconnect()
}

test("reconnects after the bulb drops the connection") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let controller = YeelightController(config: tempConfig(), reconnectBase: 0.05, reconnectMax: 0.2, scan: { $0([]) })
    check(connect(controller, bulb), "connects")
    bulb.dropClients()
    check(waitUntil { !controller.isConnected }, "notices drop")
    check(controller.isReconnecting, "reports reconnecting")
    check(waitUntil(3) { controller.isConnected }, "reconnected")
    check(!controller.isReconnecting, "reconnecting cleared")

    controller.disconnect()
    let before = bulb.connectionCount
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(!controller.isConnected && !controller.isReconnecting && bulb.connectionCount <= before, "manual disconnect stops retries")
}

test("re-discovers a bulb that moved") {
    let oldBulb = try FakeBulb()
    let newBulb = try FakeBulb()
    defer { newBulb.stop() }
    let config = tempConfig()
    var scans = 0
    let controller = YeelightController(config: config, reconnectBase: 0.05, reconnectMax: 0.1, scan: { done in
        scans += 1
        done([DiscoveredBulb(host: "127.0.0.1", port: newBulb.port)])
    })
    check(connect(controller, oldBulb), "connects to old")
    oldBulb.stop()
    check(waitUntil(5) { controller.isConnected && controller.port == newBulb.port }, "moved to new bulb")
    check(scans >= 1, "scan was used")
    check(config.savedDevice?.port == newBulb.port, "config updated to new port")
    controller.disconnect()
}

test("config writes merge and survive failures") {
    let config = tempConfig()
    check(config.update(["lang": "tr"]), "write lang")
    check(config.update(["shortcut": "Cmd + Shift + L", "shortcutKeyCode": 37, "shortcutModifiers": 768]), "write shortcut")
    check(config.language == "tr", "lang preserved after another write")
    check(config.shortcut?.keyCode == 37, "shortcut read back")
    let broken = ConfigStore(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    check(!broken.update(["lang": "en"]), "write failure reported, not thrown")
}

test("review regressions: huge numbers and case-folding never crash") {
    check((try? YeelightController.validate(method: "set_bright", params: [1e30]).get()) == nil, "1e30 rejected, no trap")
    check((try? YeelightController.validate(method: "set_bright", params: [Double.infinity]).get()) == nil, "inf rejected")
    check(Discovery.parseSSDPResponse("Location: İİİİ yeelight://1.2.3.4:55443\r\n") == DiscoveredBulb(host: "1.2.3.4", port: 55443) ||
          Discovery.parseSSDPResponse("Location: İİİİ yeelight://1.2.3.4:55443\r\n") == nil, "expanding lowercase does not crash")
    check(Discovery.parseSSDPResponse("LOCATION: YEELIGHT://10.0.0.9:55443\r\n") == DiscoveredBulb(host: "10.0.0.9", port: 55443), "case-insensitive")
}

test("review regressions: pending connects always complete") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    var first: Result<Void, Error>?
    var second: Result<Void, Error>?
    // 10.255.255.1 is unroutable: the first attempt stays pending until superseded.
    controller.connect(host: "10.255.255.1", port: 55443) { first = $0 }
    controller.connect(host: "127.0.0.1", port: bulb.port) { second = $0 }
    check(waitUntil { first != nil && second != nil }, "both completions called")
    if case .failure = first {} else { check(false, "first was superseded") }
    if case .success = second {} else { check(false, "second connected") }

    var third: Result<Void, Error>?
    controller.connect(host: "10.255.255.1", port: 55443) { third = $0 }
    controller.disconnect()
    check(waitUntil { third != nil }, "disconnect completes a pending connect")
}

test("review regressions: no stuck reconnecting, no stale retries") {
    let bulb = try FakeBulb()
    var scans = 0
    let controller = YeelightController(config: tempConfig(), reconnectBase: 0.05, reconnectMax: 0.1, scan: { done in
        scans += 1
        done([DiscoveredBulb(host: "127.0.0.1", port: bulb.port)])
    })
    check(connect(controller, bulb), "connects")
    let deadPort = bulb.port
    bulb.stop()
    check(waitUntil { controller.isReconnecting }, "reconnecting after drop")
    // The user now picks a dead address: background reconnection must stop and the flag must clear.
    var result: Result<Void, Error>?
    controller.connect(host: "127.0.0.1", port: deadPort &+ 1) { result = $0 }
    check(waitUntil(6) { result != nil }, "manual connect finished")
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(!controller.isReconnecting, "reconnecting cleared after user takes over")
    let scansAfter = scans
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(scans == scansAfter && !controller.isConnected, "no stale background retries")
}

test("URL commands: parsing") {
    func p(_ s: String) -> LightCommand? { LightCommand.parse(URL(string: s)!) }
    check(p("yeelight-quickcontrol://toggle") == .toggle, "toggle")
    check(p("YEELIGHT-QUICKCONTROL://ON") == .on && p("yeelight-quickcontrol://off") == .off, "on/off, case-insensitive")
    check(p("yeelight-quickcontrol://brightness/40") == .brightness(40), "absolute brightness")
    check(p("yeelight-quickcontrol://brightness/0") == nil && p("yeelight-quickcontrol://brightness/101") == nil, "brightness range")
    check(p("yeelight-quickcontrol://brightness/up") == .brightnessStep(10), "step up default 10")
    check(p("yeelight-quickcontrol://brightness/down?step=5") == .brightnessStep(-5), "step down custom")
    check(p("yeelight-quickcontrol://brightness/up?step=abc") == nil, "bad step")
    check(p("yeelight-quickcontrol://white/2700") == .white(kelvin: 2700) && p("yeelight-quickcontrol://white/9000") == nil, "white")
    check(p("yeelight-quickcontrol://color/250/60") == .color(hue: 250, sat: 60) && p("yeelight-quickcontrol://color/360/60") == nil, "color")
    check(p("yeelight-quickcontrol://favorite/1") == .favoriteIndex(0) && p("yeelight-quickcontrol://favorite/0") == nil, "favorite index is 1-based")
    check(p("yeelight-quickcontrol://favorite/Gece%20Modu") == .favoriteNamed("Gece Modu"), "favorite name decoded")
    check(p("yeelight-quickcontrol://toggle/extra") == nil && p("yeelight-quickcontrol://explode") == nil, "unknown rejected")
    check(p("https://toggle") == nil, "other schemes rejected")
}

test("URL commands: planning against bulb state") {
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    // Default props: power off, ct mode 4000K, bright 100.
    let off = controller.plan(.toggle, favorites: nil)
    check(off?.method == "set_power" && off?.params.first as? String == "on", "toggle from off turns on")
    let b = controller.plan(.brightness(30), favorites: nil)
    check(b?.method == "set_scene" && (b?.params as? [AnyHashable]) == ["ct", 4000, 30] as [AnyHashable], "brightness uses a ct scene (turns on)")
    check(controller.plan(.brightnessStep(-10), favorites: nil) == nil, "down while off does nothing")
    check(controller.plan(.brightnessStep(10), favorites: nil)?.method == "set_power", "up while off turns on")
    let fav = controller.plan(.favoriteNamed("GECE"), favorites: nil)
    check((fav?.params as? [AnyHashable]) == ["ct", 1700, 5] as [AnyHashable], "default favorite by localized name")
    let saved: [Any] = [["name": "Film Gecesi", "mode": "hsv", "hue": 10, "sat": 90, "bright": 30]]
    check((controller.plan(.favoriteIndex(0), favorites: saved)?.params as? [AnyHashable]) == ["hsv", 10, 90, 30] as [AnyHashable], "saved favorite by index")
    check(controller.plan(.favoriteIndex(3), favorites: saved) == nil, "missing index ignored")
    check(controller.plan(.favoriteNamed("okuma"), favorites: saved) == nil, "defaults not used once a list is saved")
}

test("URL commands: queued before connect, run once state is known") {
    let bulb = try FakeBulb()
    defer { bulb.stop() }
    bulb.props["power"] = "on"
    bulb.props["bright"] = "50"
    let controller = YeelightController(config: tempConfig(), scan: { $0([]) })
    // Like a URL arriving while the app is still launching.
    controller.perform(.toggle) { nil }
    controller.perform(.brightnessStep(10)) { nil }
    check(waitUntil(1) { false } == false && bulb.received.isEmpty, "nothing sent before connecting")
    check(connect(controller, bulb), "connects")
    check(waitUntil { bulb.received.contains { $0.method == "set_power" } }, "toggle delivered after state is known")
    let power = bulb.received.first { $0.method == "set_power" }
    check(power?.params.first as? String == "off", "toggle used the real state (bulb was on)")
    controller.disconnect()

    // Commands are dropped if the bulb never becomes reachable.
    let lonely = YeelightController(config: tempConfig(), scan: { $0([]) })
    var ran = false
    lonely.whenReady(timeout: 0.2) { ran = true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    check(!ran, "expired command never runs")
}

print(failures == 0 ? "\nALL PASSED (\(passed) checks)" : "\n\(failures) FAILED, \(passed) passed")
exit(failures == 0 ? 0 : 1)
