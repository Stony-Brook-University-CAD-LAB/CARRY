import SwiftUI

/// Connection and tuning: speed, left/right trim, indoor PWM cap, bridge token, event log.
struct SettingsView: View {
    @EnvironmentObject private var rover: RoverClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $rover.speed, in: 0...rover.pwmCap, step: 5) {
                        LabeledContent("Speed (both wheels)", value: "\(rover.speed)")
                    }
                    Slider(value: Binding(get: { Double(rover.speed) }, set: { rover.speed = Int($0.rounded()) }),
                           in: 0...Double(rover.pwmCap), step: 1)

                    Stepper(value: $rover.trim, in: -40...40, step: 1) {
                        LabeledContent("Trim", value: rover.trim > 0 ? "+\(rover.trim)" : "\(rover.trim)")
                    }
                    Slider(value: Binding(get: { Double(rover.trim) }, set: { rover.trim = Int($0.rounded()) }),
                           in: -40...40, step: 1)

                    LabeledContent("Sent to /rover_motor", value: "left_pwm \(rover.leftPWM) · right_pwm \(rover.rightPWM)")
                        .font(.footnote)
                } header: {
                    Text("Speed & trim")
                } footer: {
                    Text("Rover pulls right? Increase trim (+) to speed up the left wheel. Pulls left? Decrease trim (−). Values are live-applied to the motor node and remembered.")
                }

                Section {
                    Stepper(value: $rover.pwmCap, in: 50...255, step: 5) {
                        LabeledContent("Indoor PWM cap", value: "\(rover.pwmCap)")
                    }
                } footer: {
                    Text("Lab rule: never exceed PWM 150 indoors. The speed slider cannot go above this cap.")
                }

                Section {
                    SecureField("Bridge token (optional)", text: $rover.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Security")
                } footer: {
                    Text("Sent as ?token=… on the WebSocket URL. Plain rosbridge ignores it; a custom bridge or reverse proxy can check it.")
                }

                Section {
                    LabeledContent("Mode", value: rover.mode.rawValue)
                    LabeledContent("Status", value: rover.navStatus.isStale ? "no status" : rover.navStatus.text)
                    LabeledContent("stop_for_person", value: "always on (not controllable from the app)")
                        .font(.footnote)
                } header: {
                    Text("Rover")
                }

                Section("Event log") {
                    if rover.eventLog.isEmpty {
                        Text("No events yet").foregroundStyle(.secondary)
                    }
                    ForEach(rover.eventLog.prefix(100)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.time, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.text).font(.caption)
                        }
                    }
                }

                Section {
                    LabeledContent("App", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    Link("ROVERBOT repository", destination: URL(string: "https://github.com/Danny13213/ROVERBOT")!)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Live list of YOLO detections from /yolo/detections.
struct DetectionsSheet: View {
    @EnvironmentObject private var rover: RoverClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if rover.detections.isEmpty {
                    Text("Nothing detected").foregroundStyle(.secondary)
                }
                ForEach(rover.detections) { d in
                    HStack {
                        Image(systemName: d.isPerson ? "figure.walk" : "cube")
                            .foregroundStyle(d.isPerson ? .red : .primary)
                        Text(d.cls.capitalized)
                        Spacer()
                        Text(String(format: "%.0f%%", d.confidence * 100))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Detections")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SettingsView().environmentObject(RoverClient())
}
