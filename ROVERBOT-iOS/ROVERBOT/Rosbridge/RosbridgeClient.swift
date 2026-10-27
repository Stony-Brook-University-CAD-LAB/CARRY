import Foundation

/// Minimal rosbridge v2 protocol client over URLSessionWebSocketTask.
/// Handles advertise / publish / subscribe / call_service and measures latency with WebSocket pings.
/// All callbacks are delivered on the main thread.
final class RosbridgeClient: NSObject {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
    }

    typealias MessageHandler = ([String: Any]) -> Void
    typealias ServiceHandler = (Result<[String: Any], Error>) -> Void

    struct RosbridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    var onLatency: ((Double) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var subscriptions: [String: MessageHandler] = [:]
    private var pendingServices: [String: ServiceHandler] = [:]
    private var advertised: Set<String> = []
    private var pingTimer: Timer?
    private var missedPings = 0
    private var nextID = 0

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Connection

    func connect(host: String, port: Int, token: String?) {
        disconnect()
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/"
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components.url else { return }

        state = .connecting
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        subscriptions.removeAll()
        advertised.removeAll()
        let pending = pendingServices
        pendingServices.removeAll()
        for (_, handler) in pending {
            handler(.failure(RosbridgeError(message: "Disconnected")))
        }
        state = .disconnected
    }

    // MARK: - rosbridge operations

    func advertise(topic: String, type: String) {
        guard !advertised.contains(topic) else { return }
        advertised.insert(topic)
        send(["op": "advertise", "topic": topic, "type": type])
    }

    func publish(topic: String, msg: [String: Any]) {
        send(["op": "publish", "topic": topic, "msg": msg])
    }

    func subscribe(topic: String, type: String, throttleMs: Int = 0, handler: @escaping MessageHandler) {
        subscriptions[topic] = handler
        var op: [String: Any] = ["op": "subscribe", "topic": topic, "type": type, "queue_length": 1]
        if throttleMs > 0 { op["throttle_rate"] = throttleMs }
        send(op)
    }

    func unsubscribe(topic: String) {
        subscriptions[topic] = nil
        send(["op": "unsubscribe", "topic": topic])
    }

    func callService(_ service: String, type: String? = nil, args: [String: Any], completion: ServiceHandler? = nil) {
        nextID += 1
        let id = "svc_\(nextID)"
        if let completion {
            pendingServices[id] = completion
            // rosbridge blocks forever if the service does not exist; fail client-side after 3 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let handler = self.pendingServices.removeValue(forKey: id) else { return }
                handler(.failure(RosbridgeError(message: "\(service) timed out (is the node running?)")))
            }
        }
        var op: [String: Any] = ["op": "call_service", "id": id, "service": service, "args": args]
        if let type { op["type"] = type }
        send(op)
    }

    /// Set ROS 2 parameters on a node through its `<node>/set_parameters` service (rcl_interfaces/srv/SetParameters).
    func setParameters(node: String, _ params: [RosParameter], completion: ServiceHandler? = nil) {
        let args: [String: Any] = ["parameters": params.map { $0.json }]
        callService("\(node)/set_parameters", type: "rcl_interfaces/srv/SetParameters", args: args, completion: completion)
    }

    // MARK: - Internals

    private func send(_ dict: [String: Any]) {
        guard let task, state != .disconnected,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async { self?.handleDrop() }
            }
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleIncoming(text.data(using: .utf8) ?? Data())
                    case .data(let data): self.handleIncoming(data)
                    @unknown default: break
                    }
                    self.receiveLoop()
                case .failure:
                    self.handleDrop()
                }
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? String else { return }
        switch op {
        case "publish":
            if let topic = obj["topic"] as? String, let msg = obj["msg"] as? [String: Any] {
                subscriptions[topic]?(msg)
            }
        case "service_response":
            guard let id = obj["id"] as? String, let handler = pendingServices.removeValue(forKey: id) else { return }
            let ok = (obj["result"] as? Bool) ?? true
            if ok {
                handler(.success((obj["values"] as? [String: Any]) ?? [:]))
            } else {
                let values = obj["values"]
                handler(.failure(RosbridgeError(message: "\(values ?? "service failed")")))
            }
        case "status":
            // rosbridge status messages (errors, warnings) — useful in the Xcode console.
            if let level = obj["level"] as? String, let msg = obj["msg"] as? String, level != "info" {
                print("[rosbridge \(level)] \(msg)")
            }
        default:
            break
        }
    }

    private func startPinging() {
        pingTimer?.invalidate()
        missedPings = 0
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func sendPing() {
        guard let task else { return }
        missedPings += 1
        if missedPings > 3 {
            handleDrop()
            return
        }
        let start = Date()
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.task === task else { return }
                if error == nil {
                    self.missedPings = 0
                    self.onLatency?(Date().timeIntervalSince(start) * 1000)
                }
            }
        }
    }

    private func handleDrop() {
        guard state != .disconnected else { return }
        disconnect()
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RosbridgeClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        state = .connected
        startPinging()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        handleDrop()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        handleDrop()
    }
}

// MARK: - rcl_interfaces/msg/Parameter helper

/// One ROS 2 parameter in rcl_interfaces/msg/Parameter JSON form.
/// ParameterType constants: BOOL = 1, INTEGER = 2, DOUBLE = 3, STRING = 4.
enum RosParameter {
    case bool(String, Bool)
    case int(String, Int)
    case double(String, Double)
    case string(String, String)

    var json: [String: Any] {
        switch self {
        case .bool(let name, let v):
            return ["name": name, "value": ["type": 1, "bool_value": v]]
        case .int(let name, let v):
            return ["name": name, "value": ["type": 2, "integer_value": v]]
        case .double(let name, let v):
            return ["name": name, "value": ["type": 3, "double_value": v]]
        case .string(let name, let v):
            return ["name": name, "value": ["type": 4, "string_value": v]]
        }
    }
}
