import SwiftUI

@main
struct ROVERBOTApp: App {
    @StateObject private var rover = RoverClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(rover)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Safety rule: leaving the foreground is treated exactly like pressing STOP.
            if phase != .active {
                rover.appWentToBackground()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var rover: RoverClient

    var body: some View {
        Group {
            if rover.isConnected {
                DriveView()
            } else {
                ConnectView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rover.isConnected)
        .overlay(alignment: .top) {
            if let banner = rover.connectionLostBanner {
                ConnectionLostBanner(text: banner) { rover.connectionLostBanner = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: rover.connectionLostBanner)
    }
}

/// Full-screen "Connection lost — rover stopped" notice required by the safety spec.
struct ConnectionLostBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.red)
                Text(text)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("The rover stops itself when commands stop arriving (500 ms on the Jetson, 750 ms on the ESP32). Reconnect to drive again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("OK", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(32)
        }
    }
}
