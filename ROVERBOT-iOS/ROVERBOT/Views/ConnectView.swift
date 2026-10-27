import SwiftUI

/// Connect screen: enter the Jetson IP, pick a remembered rover, see connection state.
struct ConnectView: View {
    @EnvironmentObject private var rover: RoverClient

    @State private var host: String = ""
    @State private var port: String = "9090"
    @State private var videoPort: String = "5000"
    @State private var showSettings = false

    private var isConnecting: Bool { rover.connectionState == .connecting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "network")
                        TextField("Jetson IP (e.g. 192.168.1.42)", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(connect)
                    }
                    HStack {
                        Text("rosbridge port")
                        Spacer()
                        TextField("9090", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("Video port")
                        Spacer()
                        TextField("5000", text: $videoPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                } header: {
                    Text("Rover")
                } footer: {
                    Text("On the Jetson, run `ros2 launch rover_bringup rover.launch.xml`. Find its IP with `hostname -I`. Phone and rover must be on the same Wi-Fi.")
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView().padding(.trailing, 8)
                                Text("Connecting…")
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Connect")
                            }
                            Spacer()
                        }
                        .font(.headline)
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    if isConnecting {
                        Button("Cancel", role: .cancel) { rover.disconnect() }
                    }
                }

                if let error = rover.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                if !rover.savedRovers.isEmpty {
                    Section("Recent rovers") {
                        ForEach(rover.savedRovers) { saved in
                            Button {
                                host = saved.host
                                port = String(saved.port)
                                videoPort = String(saved.videoPort)
                                rover.connect(to: saved)
                            } label: {
                                HStack {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text(saved.host)
                                    Spacer()
                                    Text(":\(saved.port)").foregroundStyle(.secondary)
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete { idx in
                            let doomed = idx.map { rover.savedRovers[$0] }
                            doomed.forEach { rover.forget($0) }
                        }
                    }
                }

                Section {
                    LabeledContent("Safety") {
                        Text("Starts in Manual · STOP always wins · release = stop")
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("ROVERBOT")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear {
                if host.isEmpty, let last = rover.savedRovers.first {
                    host = last.host
                    port = String(last.port)
                    videoPort = String(last.videoPort)
                }
            }
        }
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        rover.clearError()
        rover.connect(to: SavedRover(host: h, port: Int(port) ?? 9090, videoPort: Int(videoPort) ?? 5000))
    }
}

#Preview {
    ConnectView().environmentObject(RoverClient())
}
