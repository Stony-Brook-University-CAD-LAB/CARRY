import SwiftUI

/// Main operator screen: live video + status line, hold-to-drive D-pad, mode toggle, STOP, speed.
struct DriveView: View {
    @EnvironmentObject private var rover: RoverClient
    @StateObject private var video = MJPEGStream()

    @State private var showSettings = false
    @State private var showDetections = false
    @State private var confirmAutonomous = false
    @State private var pendingMode: RoverMode = .manual

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                if landscape {
                    HStack(spacing: 12) {
                        videoPanel
                        controls
                            .frame(width: min(geo.size.width * 0.42, 380))
                    }
                    .padding(12)
                } else {
                    VStack(spacing: 12) {
                        videoPanel
                            .frame(height: geo.size.width * 3 / 4)
                        controls
                    }
                    .padding(12)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { topBar }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showDetections) { DetectionsSheet() }
        .confirmationDialog("Switch to Autonomous?", isPresented: $confirmAutonomous, titleVisibility: .visible) {
            Button("Start Autonomous driving", role: .destructive) { rover.setMode(.autonomous) }
            Button("Stay in Manual", role: .cancel) {}
        } message: {
            Text("The rover will drive itself using obstacle avoidance. STOP returns control to you at any time.")
        }
        .alert("Rover", isPresented: Binding(get: { rover.lastError != nil }, set: { if !$0 { rover.clearError() } })) {
            Button("OK") { rover.clearError() }
        } message: {
            Text(rover.lastError ?? "")
        }
        .onAppear {
            if let url = rover.currentRover?.videoURL { video.start(url: url) }
        }
        .onDisappear { video.stop() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            ConnectionPill(latencyMs: rover.latencyMs, host: rover.currentRover?.host ?? "")

            Spacer()

            Button {
                showDetections = true
            } label: {
                Label("\(rover.detections.count)", systemImage: rover.personVisible ? "figure.walk" : "viewfinder")
                    .foregroundStyle(rover.personVisible ? .red : .primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button(role: .destructive) { rover.disconnect() } label: {
                Image(systemName: "xmark")
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6))
    }

    // MARK: - Video

    private var videoPanel: some View {
        VStack(spacing: 6) {
            VideoView(stream: video)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if rover.personVisible {
                        Label("PERSON", systemImage: "figure.walk")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.red, in: Capsule())
                            .padding(8)
                    }
                }
            StatusLine(status: rover.navStatus, mode: rover.mode)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            modePicker

            HStack(alignment: .center, spacing: 16) {
                DPadView(enabled: rover.mode == .manual, active: rover.activeDirection) { dir in
                    rover.startDriving(dir)
                } onRelease: {
                    rover.stopDriving()
                }
                .frame(maxWidth: .infinity)

                StopButton { rover.emergencyStop() }
                    .frame(width: 120, height: 120)
            }

            speedRow
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { rover.mode },
            set: { newMode in
                if newMode == .autonomous {
                    confirmAutonomous = true          // explicit confirm before handing control to the robot
                } else {
                    rover.setMode(.manual)
                }
            })) {
            ForEach(RoverMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    private var speedRow: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "speedometer")
                Slider(value: Binding(get: { Double(rover.speed) }, set: { rover.speed = Int($0.rounded()) }),
                       in: 0...Double(rover.pwmCap), step: 1)
                Text("\(rover.speed)")
                    .font(.system(.body, design: .monospaced).bold())
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("PWM  L \(rover.leftPWM) · R \(rover.rightPWM)")
                Spacer()
                Text(rover.trim == 0 ? "trim 0" : (rover.trim > 0 ? "trim +\(rover.trim) (left faster)" : "trim \(rover.trim) (right faster)"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

struct ConnectionPill: View {
    let latencyMs: Double?
    let host: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(host).font(.caption.bold()).lineLimit(1)
            if let latencyMs {
                Text("\(Int(latencyMs)) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var color: Color {
        guard let latencyMs else { return .yellow }
        return latencyMs < 100 ? .green : (latencyMs < 300 ? .yellow : .red)
    }
}

struct StatusLine: View {
    let status: NavStatus
    let mode: RoverMode

    var body: some View {
        HStack {
            Circle().fill(status.isStale ? Color.gray : status.color).frame(width: 12, height: 12)
            Text(status.isStale ? "NO STATUS" : status.text)
                .font(.system(.subheadline, design: .monospaced).bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            if !status.isStale { Text(status.distanceText).font(.system(.subheadline, design: .monospaced)) }
            Text(mode == .autonomous ? "AUTO" : "MANUAL")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(mode == .autonomous ? Color.orange : Color.blue, in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((status.isStale ? Color.gray : status.color).opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VideoView: View {
    @ObservedObject var stream: MJPEGStream

    var body: some View {
        ZStack {
            Color(white: 0.1)
            if let img = stream.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(stream.errorText ?? "Waiting for video on :5000/stream…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if stream.isStreaming {
                Text(String(format: "%.0f fps", stream.fps))
                    .font(.caption2.monospacedDigit())
                    .padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
    }
}

/// Big red always-visible emergency STOP.
struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.red)
                Circle().stroke(Color.white.opacity(0.6), lineWidth: 4).padding(6)
                Text("STOP")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(.white)
            }
            .shadow(color: .red.opacity(0.6), radius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Emergency stop")
    }
}

#Preview {
    DriveView().environmentObject(RoverClient())
}
