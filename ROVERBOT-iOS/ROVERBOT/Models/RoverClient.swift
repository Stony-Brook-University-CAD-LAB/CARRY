import Foundation
import SwiftUI
import Combine
import UIKit

/// High-level rover controller used by all views.
/// Owns the rosbridge connection, the dead-man drive timer, mode switching and the safety rules
/// from the engineering handoff:
///   • Drive commands are re-sent every 100 ms only while a button is held; release => zero Twist.
///   • Backgrounding the app or losing the connection => STOP, Manual, "rover stopped" banner.
///   • STOP always wins and switches to Manual.
///   • Always start in Manual; Autonomous only via explicit confirmed tap.
///   • stop_for_person is never touched.
@MainActor
final class RoverClient: ObservableObject {

    // MARK: Published state

    @Published private(set) var connectionState: RosbridgeClient.State = .disconnected
    @Published private(set) var latencyMs: Double?
    @Published private(set) var navStatus: NavStatus = .none
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var personVisible = false
    @Published private(set) var mode: RoverMode = .manual
    @Published private(set) var activeDirection: DriveDirection?
    @Published var connectionLostBanner: String?
    @Published private(set) var lastError: String? {
        // An alert can cancel an in-progress touch; never leave the wheels turning under an alert.
        didSet { if lastError != nil { stopDriving(sendStop: true) } }
    }
    @Published private(set) var eventLog: [LogEntry] = []

    /// Base speed, written to both left_pwm and right_pwm on /rover_motor (0–255).
    @Published var speed: Int {
        didSet { UserDefaults.standard.set(speed, forKey: "speed"); schedulePWMUpdate() }
    }
    /// Trim: positive => left wheel faster (rover pulls right less). Applied as left = speed + trim, right = speed - trim.
    @Published var trim: Int {
        didSet { UserDefaults.standard.set(trim, forKey: "trim"); schedulePWMUpdate() }
    }
    /// Indoor PWM cap from the mission rules ("never exceed PWM 150 indoors"). The slider cannot go above it.
    @Published var pwmCap: Int {
        didSet { UserDefaults.standard.set(pwmCap, forKey: "pwmCap"); if speed > pwmCap { speed = pwmCap } }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }
    @Published var savedRovers: [SavedRover] {
        didSet {
            if let data = try? JSONEncoder().encode(savedRovers) {
                UserDefaults.standard.set(data, forKey: "savedRovers")
            }
        }
    }
    @Published private(set) var currentRover: SavedRover?

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
    }

    var isConnected: Bool { connectionState == .connected }

    // MARK: Private

    private let bridge = RosbridgeClient()
    private var driveTimer: Timer?
    private var heartbeatTimer: Timer?
    private var userRequestedDisconnect = false
    private var pwmDebounce: Timer?
    private var statusStaleTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let notice = UINotificationFeedbackGenerator()

    private enum Topics {
        static let cmdVel = "/cmd_vel"
        static let navStatus = "/navigation/status"
        static let detections = "/yolo/detections"
        static let motorNode = "/rover_motor"
        static let avoidanceNode = "/obstacle_avoidance"
        static let heartbeat = "/phone/heartbeat"
    }

    init() {
        let d = UserDefaults.standard
        speed = d.object(forKey: "speed") as? Int ?? 120
        trim = d.object(forKey: "trim") as? Int ?? 0
        pwmCap = d.object(forKey: "pwmCap") as? Int ?? 150
        token = d.string(forKey: "token") ?? ""
        if let data = d.data(forKey: "savedRovers"), let list = try? JSONDecoder().decode([SavedRover].self, from: data) {
            savedRovers = list
        } else {
            savedRovers = []
        }

        bridge.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleStateChange(state) }
        }
        bridge.onLatency = { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
        }
    }

    // MARK: - Connection

    func connect(to rover: SavedRover) {
        connectionLostBanner = nil
        lastError = nil
        userRequestedDisconnect = false
        currentRover = rover
        remember(rover)
        log("Connecting to \(rover.host):\(rover.port)")
        bridge.connect(host: rover.host, port: rover.port, token: token.isEmpty ? nil : token)
    }

    func disconnect() {
        userRequestedDisconnect = true
        stopDriving(sendStop: true)
        setAvoidanceEnabled(false, logFailure: false)
        log("Disconnected by user")
        navStatus = .none
        detections = []
        latencyMs = nil
        // Give the queued zero Twists ~100 ms to leave the socket before closing it.
        let bridge = self.bridge
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bridge.disconnect() }
    }

    private func handleStateChange(_ state: RosbridgeClient.State) {
        let wasConnected = connectionState == .connected
        connectionState = state
        switch state {
        case .connected:
            log("Connected")
            notice.notificationOccurred(.success)
            onConnected()
        case .disconnected:
            stopDriving(sendStop: false)   // socket is gone; nothing to send — the robot's own watchdogs stop it.
            heartbeatTimer?.invalidate(); heartbeatTimer = nil
            statusStaleTimer?.invalidate(); statusStaleTimer = nil
            mode = .manual
            latencyMs = nil
            navStatus = .none
            if userRequestedDisconnect {
                userRequestedDisconnect = false
            } else if wasConnected {
                connectionLostBanner = "Connection lost — rover stopped"
                log("Connection lost: rover stops by watchdog (500 ms Jetson / 750 ms ESP32; heartbeat timeout reverts Autonomous)")
                notice.notificationOccurred(.error)
            } else if currentRover != nil {
                lastError = "Could not connect. Check the Jetson IP, that rover.launch.xml (or manual.launch.xml) is running, and that the phone is on the same Wi-Fi."
            }
        case .connecting:
            break
        }
    }

    private func onConnected() {
        bridge.advertise(topic: Topics.cmdVel, type: "geometry_msgs/msg/Twist")
        bridge.advertise(topic: Topics.heartbeat, type: "std_msgs/msg/Empty")
        bridge.subscribe(topic: Topics.navStatus, type: "std_msgs/msg/String", throttleMs: 100) { [weak self] msg in
            guard let self, let raw = msg["data"] as? String else { return }
            self.navStatus = NavStatus(raw: raw)
        }
        bridge.subscribe(topic: Topics.detections, type: "std_msgs/msg/String", throttleMs: 200) { [weak self] msg in
            guard let self, let raw = msg["data"] as? String else { return }
            let list = Detection.parse(raw)
            self.detections = list
            self.personVisible = list.contains { $0.isPerson }
        }

        // Safety: always start in Manual, with the wheels stopped.
        mode = .manual
        bridge.publish(topic: Topics.cmdVel, msg: Twist.zero)
        setAvoidanceEnabled(false, logFailure: false)
        pushPWM()

        statusStaleTimer?.invalidate()
        statusStaleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }   // refresh "stale" indicator
        }

        // Heartbeat: obstacle_avoidance drops back to Manual (and stops) if it hears nothing for 1 s,
        // so a phone that vanishes mid-Autonomous cannot leave the rover driving itself.
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                self.bridge.publish(topic: Topics.heartbeat, msg: [:])
            }
        }
    }

    // MARK: - Driving (dead-man)

    func startDriving(_ direction: DriveDirection) {
        guard isConnected else { return }
        guard mode == .manual else { return }   // in Autonomous the node owns /cmd_vel
        if activeDirection != direction {
            haptic.impactOccurred()
            log("Drive \(direction.rawValue) start")
        }
        activeDirection = direction
        sendDrive()
        driveTimer?.invalidate()
        driveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendDrive() }
        }
    }

    func stopDriving(sendStop: Bool = true) {
        driveTimer?.invalidate()
        driveTimer = nil
        if activeDirection != nil { log("Drive stop") }
        activeDirection = nil
        if sendStop && isConnected {
            // Send the zero Twist a few times so one lost packet cannot leave the rover moving.
            for _ in 0..<3 { bridge.publish(topic: Topics.cmdVel, msg: Twist.zero) }
        }
    }

    private func sendDrive() {
        guard let dir = activeDirection, isConnected, mode == .manual else {
            stopDriving(sendStop: isConnected)
            return
        }
        bridge.publish(topic: Topics.cmdVel, msg: dir.twist)
    }

    // MARK: - Emergency STOP

    /// STOP always wins: zero Twist, obstacle_avoidance disabled, mode => Manual.
    func emergencyStop(reason: String = "STOP pressed") {
        notice.notificationOccurred(.warning)
        stopDriving(sendStop: true)
        mode = .manual
        setAvoidanceEnabled(false, logFailure: false)
        if isConnected { bridge.publish(topic: Topics.cmdVel, msg: Twist.zero) }
        log("EMERGENCY STOP (\(reason))")
    }

    /// Called from the App on scenePhase change. Backgrounding == STOP.
    func appWentToBackground() {
        guard isConnected else { return }
        emergencyStop(reason: "app backgrounded")
    }

    // MARK: - Mode

    func setMode(_ newMode: RoverMode) {
        guard isConnected else { return }
        switch newMode {
        case .manual:
            stopDriving(sendStop: true)
            mode = .manual
            setAvoidanceEnabled(false, logFailure: true)
            log("Mode -> Manual")
        case .autonomous:
            stopDriving(sendStop: true)
            setAvoidanceEnabled(true, logFailure: true) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.mode = .autonomous
                    self.log("Mode -> Autonomous")
                } else {
                    self.mode = .manual
                    self.lastError = "Could not enable Autonomous: obstacle_avoidance is not running (use rover.launch.xml, not manual.launch.xml)."
                }
            }
        }
    }

    private func setAvoidanceEnabled(_ enabled: Bool, logFailure: Bool, completion: ((Bool) -> Void)? = nil) {
        bridge.setParameters(node: Topics.avoidanceNode, [.bool("enabled", enabled)]) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let values):
                    // rcl_interfaces/srv/SetParameters returns results[] with successful/reason.
                    let results = values["results"] as? [[String: Any]] ?? []
                    let ok = results.first.flatMap { $0["successful"] as? Bool } ?? true
                    if !ok, logFailure { self?.lastError = "obstacle_avoidance refused: \(results.first?["reason"] ?? "")" }
                    completion?(ok)
                case .failure(let error):
                    if logFailure { self?.lastError = "set_parameters failed: \(error.localizedDescription)" }
                    completion?(false)
                }
            }
        }
    }

    // MARK: - Speed / trim

    var leftPWM: Int { clampPWM(speed + trim) }
    var rightPWM: Int { clampPWM(speed - trim) }

    private func clampPWM(_ v: Int) -> Int { max(0, min(pwmCap, v)) }

    private func schedulePWMUpdate() {
        pwmDebounce?.invalidate()
        pwmDebounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pushPWM() }
        }
    }

    private func pushPWM() {
        guard isConnected else { return }
        bridge.setParameters(node: Topics.motorNode, [.int("left_pwm", leftPWM), .int("right_pwm", rightPWM)]) { [weak self] result in
            Task { @MainActor in
                if case .failure(let error) = result {
                    self?.lastError = "Could not set PWM: \(error.localizedDescription)"
                } else {
                    self?.log("PWM L=\(self?.leftPWM ?? 0) R=\(self?.rightPWM ?? 0)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func remember(_ rover: SavedRover) {
        savedRovers.removeAll { $0.id == rover.id }
        savedRovers.insert(rover, at: 0)
        if savedRovers.count > 5 { savedRovers.removeLast(savedRovers.count - 5) }
    }

    func forget(_ rover: SavedRover) {
        savedRovers.removeAll { $0.id == rover.id }
    }

    func clearError() { lastError = nil }

    private func log(_ text: String) {
        eventLog.insert(LogEntry(time: Date(), text: text), at: 0)
        if eventLog.count > 300 { eventLog.removeLast() }
        print("[ROVERBOT] \(text)")
    }
}
