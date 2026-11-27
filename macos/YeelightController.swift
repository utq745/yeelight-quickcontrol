import Foundation
import Network

/// Talks to one Yeelight bulb over its LAN JSON protocol (TCP 55443).
///
/// All state lives on the main queue. The controller:
/// - reconnects automatically with exponential backoff and, every third
///   failed attempt, re-discovers the bulb in case its DHCP lease changed;
/// - matches property replies by request ID, so command replies can never be
///   mistaken for property values;
/// - rate-limits outgoing commands below the bulb's ~60/min quota and
///   coalesces bursts (e.g. slider drags) so only the latest value is sent.
final class YeelightController {
    static let propKeys = ["power", "bright", "ct", "rgb", "hue", "sat", "color_mode"]
    static let allowedCommands: Set<String> = ["set_power", "set_bright", "set_hsv", "set_ct_abx", "set_scene"]
    /// A queued scene supersedes these (it sets power, brightness and colour at once).
    static let supersededByScene: Set<String> = ["set_bright", "set_ct_abx", "set_hsv", "set_power"]

    // Quota tuning: bulbs drop clients that exceed ~60 commands per minute.
    private let quotaPerMinute = 50.0
    private let burst = 15.0
    private let pollInterval: TimeInterval = 10
    private let pollTokenReserve = 5.0
    private let reconnectBase: TimeInterval
    private let reconnectMax: TimeInterval

    private let config: ConfigStore
    private let scan: (@escaping ([DiscoveredBulb]) -> Void) -> Void

    private(set) var host: String?
    private(set) var port: UInt16 = Discovery.bulbPort
    private(set) var isConnected = false
    private(set) var props: [String: String] = [
        "power": "off", "bright": "100", "ct": "4000", "rgb": "16777215",
        "hue": "0", "sat": "100", "color_mode": "2",
    ]
    /// True once the bulb has answered a property query on the current connection.
    private(set) var hasState = false
    private var readyWaiters: [(deadline: Date, action: () -> Void)] = []
    /// True from the moment the link drops until it is restored or the user disconnects.
    private(set) var isReconnecting = false

    private var connection: NWConnection?
    /// Bumped by every user-initiated connect/disconnect. Background flows
    /// (auto-connect, reconnect, re-discovery) capture it and give up when it
    /// changes, so they can never override a newer user decision.
    private var epoch = 0
    private var connectionGeneration = 0
    private var pendingConnect: ((Result<Void, Error>) -> Void)?
    private var connectTimeout: DispatchWorkItem?
    private var manualDisconnect = false
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var nextID = 1
    private var pendingPropIDs: [Int] = []
    private var buffer = Data()

    private var tokens: Double
    private var lastRefill = Date()
    private var queue: [(method: String, params: [Any])] = []
    private var flushWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?

    /// Called on the main queue whenever connection state or properties change.
    var onChange: (() -> Void)?

    struct ControllerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        static let superseded = ControllerError(message: "superseded by a newer connection request")
    }

    init(config: ConfigStore,
         reconnectBase: TimeInterval = 2,
         reconnectMax: TimeInterval = 60,
         scan: @escaping (@escaping ([DiscoveredBulb]) -> Void) -> Void = Discovery.scan) {
        self.config = config
        self.reconnectBase = reconnectBase
        self.reconnectMax = reconnectMax
        self.scan = scan
        tokens = burst
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
    }

    deinit {
        pollTimer?.invalidate()
        connection?.cancel()
    }

    // MARK: Connection lifecycle

    /// Connects to the saved bulb; on failure re-discovers it, then keeps retrying in the background.
    func autoConnect() {
        guard let saved = config.savedDevice else { return }
        let myEpoch = epoch
        manualDisconnect = false
        isReconnecting = true
        open(host: saved.host, port: saved.port) { [weak self] result in
            guard let self, case .failure = result, myEpoch == self.epoch else { return }
            self.scan { found in
                guard myEpoch == self.epoch else { return }
                if let target = found.first(where: { $0.host == saved.host }) ?? found.first {
                    self.open(host: target.host, port: target.port) { result in
                        if case .failure = result, myEpoch == self.epoch { self.scheduleReconnect() }
                    }
                } else {
                    self.host = saved.host
                    self.port = saved.port
                    self.scheduleReconnect()
                }
            }
        }
    }

    /// User-initiated connect. Cancels any background reconnection.
    func connect(host: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        epoch += 1
        manualDisconnect = false
        isReconnecting = false
        reconnectAttempts = 0
        open(host: host, port: port, completion: completion)
    }

    func disconnect() {
        epoch += 1
        manualDisconnect = true
        isReconnecting = false
        cancelReconnect()
        failPendingConnect(.superseded)
        tearDown()
        host = nil
        port = Discovery.bulbPort
        onChange?()
    }

    private func failPendingConnect(_ error: ControllerError) {
        guard let completion = pendingConnect else { return }
        pendingConnect = nil
        completion(.failure(error))
    }

    private func open(host: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        // Answer an earlier, still-pending request so its caller never hangs.
        failPendingConnect(.superseded)
        tearDown()
        cancelReconnect()
        self.host = host
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return completion(.failure(ControllerError(message: "invalid port")))
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        connectionGeneration += 1
        let generation = connectionGeneration
        self.connection = connection
        pendingConnect = completion

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, generation == self.connectionGeneration else { return }
            switch state {
            case .ready:
                self.didConnect()
            case .waiting(let error), .failed(let error):
                self.didFail(error.localizedDescription)
            case .cancelled:
                self.didFail("connection cancelled")
            default:
                break
            }
        }
        connection.start(queue: .main)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == self.connectionGeneration, !self.isConnected else { return }
            self.didFail("timeout")
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func didConnect() {
        connectTimeout?.cancel()
        connectTimeout = nil
        isConnected = true
        isReconnecting = false
        reconnectAttempts = 0
        buffer.removeAll()
        pendingPropIDs.removeAll()
        if let host { config.update(["host": host, "port": Int(port)]) }
        NSLog("[Yeelight] Connected to %@:%d", host ?? "?", Int(port))
        receive(generation: connectionGeneration)
        queryProps()
        let completion = pendingConnect
        pendingConnect = nil
        completion?(.success(()))
        onChange?()
    }

    private func didFail(_ reason: String) {
        let wasConnected = isConnected
        tearDown()
        failPendingConnect(ControllerError(message: reason))
        if wasConnected {
            NSLog("[Yeelight] Disconnected: %@", reason)
            scheduleReconnect()
        }
        onChange?()
    }

    /// Cancels the current connection without touching `host` or reconnection state.
    private func tearDown() {
        connectionGeneration += 1
        connectTimeout?.cancel()
        connectTimeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        hasState = false
        // Never replay commands queued for a previous connection.
        queue.removeAll()
        flushWorkItem?.cancel()
        flushWorkItem = nil
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func scheduleReconnect() {
        guard !manualDisconnect, let host, reconnectWorkItem == nil else { return }
        let delay = min(reconnectMax, reconnectBase * pow(2, Double(min(reconnectAttempts, 5))))
        isReconnecting = true
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        let port = self.port
        let myEpoch = epoch
        NSLog("[Yeelight] Reconnecting in %.0f s (attempt %d)", delay, attempt)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.manualDisconnect, myEpoch == self.epoch else { return }
            self.open(host: host, port: port) { result in
                guard case .failure = result, myEpoch == self.epoch else { return }
                guard attempt % 3 == 0 else { return self.scheduleReconnect() }
                // The bulb may have a new DHCP lease: look for it.
                self.scan { found in
                    guard myEpoch == self.epoch, !self.manualDisconnect, !self.isConnected else { return }
                    if let target = found.first(where: { $0.host == host }) ?? found.first {
                        self.open(host: target.host, port: target.port) { result in
                            if case .failure = result, myEpoch == self.epoch { self.scheduleReconnect() }
                        }
                    } else {
                        self.scheduleReconnect()
                    }
                }
            }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        onChange?()
    }

    // MARK: Protocol I/O

    private func receive(generation: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, generation == self.connectionGeneration else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if isComplete || error != nil {
                self.didFail(error?.localizedDescription ?? "closed by bulb")
                return
            }
            self.receive(generation: generation)
        }
    }

    private func handle(_ data: Data) {
        buffer.append(data)
        if buffer.count > 64 * 1024 { buffer.removeAll() }
        let separator = Data("\r\n".utf8)
        var changed = false
        while let range = buffer.range(of: separator) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }

            if let id = (msg["id"] as? NSNumber)?.intValue, let index = pendingPropIDs.firstIndex(of: id) {
                pendingPropIDs.remove(at: index) // also on an error reply
                if let result = msg["result"] as? [Any] {
                    for (i, key) in Self.propKeys.enumerated() where i < result.count {
                        let value = Self.string(result[i])
                        if !value.isEmpty { props[key] = value }
                    }
                    hasState = true
                    changed = true
                }
            }
            if msg["method"] as? String == "props", let params = msg["params"] as? [String: Any] {
                for (key, value) in params where Self.propKeys.contains(key) {
                    props[key] = Self.string(value)
                }
                changed = true
            }
        }
        if changed {
            runReadyWaiters()
            onChange?()
        }
    }

    // MARK: Deferred actions

    /// Runs `action` as soon as the bulb is connected and its state is known
    /// (immediately if it already is). Dropped after `timeout` seconds, e.g.
    /// when an external app launches us via URL and the bulb is unreachable.
    func whenReady(timeout: TimeInterval = 15, _ action: @escaping () -> Void) {
        if isConnected && hasState { return action() }
        readyWaiters.append((Date().addingTimeInterval(timeout), action))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 0.05) { [weak self] in
            guard let self else { return }
            let now = Date()
            let expired = self.readyWaiters.filter { $0.deadline <= now }.count
            self.readyWaiters.removeAll { $0.deadline <= now }
            if expired > 0 { NSLog("[Yeelight] Dropped %d command(s): bulb not reachable in time", expired) }
        }
    }

    private func runReadyWaiters() {
        guard isConnected, hasState, !readyWaiters.isEmpty else { return }
        let now = Date()
        let due = readyWaiters.filter { $0.deadline > now }
        readyWaiters.removeAll()
        due.forEach { $0.action() }
    }

    private static func string(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    @discardableResult
    private func write(method: String, params: [Any]) -> Int? {
        guard isConnected, let connection else { return nil }
        let id = nextID
        nextID = nextID >= Int(Int32.max) ? 1 : nextID + 1
        guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else {
            return nil
        }
        data.append(contentsOf: Array("\r\n".utf8))
        connection.send(content: data, completion: .contentProcessed { _ in })
        return id
    }

    private func queryProps() {
        guard let id = write(method: "get_prop", params: Self.propKeys) else { return }
        pendingPropIDs.append(id)
        if pendingPropIDs.count > 32 { pendingPropIDs.removeFirst() }
    }

    private func heartbeat() {
        // State changes arrive as "props" notifications; this slow poll is
        // only a safety net and yields to user commands.
        if isConnected, queue.isEmpty, takeToken(reserve: pollTokenReserve) { queryProps() }
    }

    // MARK: Rate limiting

    private func takeToken(reserve: Double = 0) -> Bool {
        let now = Date()
        tokens = min(burst, tokens + now.timeIntervalSince(lastRefill) * quotaPerMinute / 60)
        lastRefill = now
        guard tokens >= 1 + reserve else { return false }
        tokens -= 1
        return true
    }

    private func flush() {
        flushWorkItem = nil
        while let next = queue.first {
            guard isConnected else { queue.removeAll(); return }
            guard takeToken() else {
                let wait = max(0.02, (1 - tokens) * 60 / quotaPerMinute)
                let work = DispatchWorkItem { [weak self] in self?.flush() }
                flushWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
                return
            }
            queue.removeFirst()
            write(method: next.method, params: next.params)
        }
    }

    // MARK: Commands

    /// Validates a command and returns sanitized params, or an error message.
    static func validate(method: String?, params: [Any]?) -> Result<[Any], ControllerError> {
        guard let method, allowedCommands.contains(method), let params else {
            return .failure(ControllerError(message: "unsupported method or invalid params"))
        }
        func int(_ i: Int) -> Int? { i < params.count ? jsonInteger(params[i]) : nil }
        func fail(_ message: String) -> Result<[Any], ControllerError> { .failure(ControllerError(message: message)) }

        // set_scene: ["ct", kelvin, bright] or ["hsv", hue, sat, bright]; no transition.
        if method == "set_scene" {
            let mode = params.first as? String
            if mode == "ct", params.count == 3,
               let k = int(1), (1700...6500).contains(k), let b = int(2), (1...100).contains(b) {
                return .success(["ct", k, b])
            }
            if mode == "hsv", params.count == 4,
               let h = int(1), (0...359).contains(h), let s = int(2), (0...100).contains(s),
               let b = int(3), (1...100).contains(b) {
                return .success(["hsv", h, s, b])
            }
            return fail("invalid scene")
        }

        var head: [Any]
        let restStart: Int
        switch method {
        case "set_power":
            guard let p = params.first as? String, p == "on" || p == "off" else { return fail("power must be on or off") }
            head = [p]; restStart = 1
        case "set_bright":
            guard let v = int(0), (1...100).contains(v) else { return fail("brightness must be between 1 and 100") }
            head = [v]; restStart = 1
        case "set_hsv":
            guard let h = int(0), (0...359).contains(h), let s = int(1), (0...100).contains(s) else {
                return fail("hue or saturation is out of range")
            }
            head = [h, s]; restStart = 2
        default: // set_ct_abx
            guard let k = int(0), (1700...6500).contains(k) else {
                return fail("color temperature must be between 1700 and 6500")
            }
            head = [k]; restStart = 1
        }

        let rest = params.count > restStart ? Array(params[restStart...]) : []
        if rest.count > 2 { return fail("too many params") }
        let transitionError = "invalid transition (effect must be smooth/sudden, duration 30-10000 ms)"
        if let effect = rest.first {
            guard let e = effect as? String, e == "smooth" || e == "sudden" else { return fail(transitionError) }
            head.append(e)
            if rest.count == 2 {
                guard let d = int(restStart + 1), (30...10000).contains(d) else { return fail(transitionError) }
                head.append(d)
            }
        }
        return .success(head)
    }

    /// Queues a validated command; repeated commands of the same kind collapse to the latest.
    func send(method: String, params: [Any]) {
        queue.removeAll { $0.method == method || (method == "set_scene" && Self.supersededByScene.contains($0.method)) }
        queue.append((method, params))

        switch method {
        case "set_power": props["power"] = params[0] as? String
        case "set_bright": props["bright"] = "\(params[0])"
        case "set_hsv":
            props["hue"] = "\(params[0])"
            props["sat"] = "\(params[1])"
            props["color_mode"] = "3"
        case "set_ct_abx":
            props["ct"] = "\(params[0])"
            props["color_mode"] = "2"
        case "set_scene":
            props["power"] = "on"
            props["bright"] = "\(params[params.count - 1])"
            if params[0] as? String == "ct" {
                props["ct"] = "\(params[1])"
                props["color_mode"] = "2"
            } else {
                props["hue"] = "\(params[1])"
                props["sat"] = "\(params[2])"
                props["color_mode"] = "3"
            }
        default: break
        }
        if flushWorkItem == nil { flush() }
    }

    func togglePower() {
        guard isConnected else { return }
        send(method: "set_power", params: [props["power"] == "on" ? "off" : "on", "smooth", 300])
        onChange?()
    }
}
