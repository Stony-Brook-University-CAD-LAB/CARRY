import SwiftUI
import UIKit

/// Hold-to-drive D-pad. A button only drives while the finger is down on it; lifting, sliding off,
/// or the system cancelling the touch (incoming call, alert, Control Center swipe) releases, which the
/// controller turns into a zero Twist.
struct DPadView: View {
    let enabled: Bool
    let active: DriveDirection?
    let onPress: (DriveDirection) -> Void
    let onRelease: () -> Void

    private let size: CGFloat = 68

    var body: some View {
        VStack(spacing: 8) {
            pad(.forward)
            HStack(spacing: 8) {
                pad(.left)
                centerDot
                pad(.right)
            }
            pad(.back)
        }
        .opacity(enabled ? 1 : 0.35)
        .overlay {
            if !enabled {
                Text("AUTONOMOUS\nrobot is driving")
                    .font(.caption.bold())
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var centerDot: some View {
        Circle()
            .fill(Color(white: 0.2))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "dot.circle").foregroundStyle(.secondary))
    }

    private func pad(_ dir: DriveDirection) -> some View {
        HoldButton(isActive: active == dir, enabled: enabled, size: size, symbol: dir.symbol) {
            onPress(dir)
        } onRelease: {
            onRelease()
        }
        .accessibilityLabel("Drive \(dir.rawValue)")
    }
}

/// A button that reports press and release separately, including system touch cancellation.
/// SwiftUI gestures have no cancel callback, so the touch handling is a UIKit view underneath.
struct HoldButton: View {
    let isActive: Bool
    let enabled: Bool
    let size: CGFloat
    let symbol: String
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(isActive ? Color.accentColor : Color(white: 0.22))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            )
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .overlay(
                TouchTracker(enabled: enabled) { down in
                    if down {
                        if !pressed { pressed = true; onPress() }
                    } else if pressed {
                        pressed = false; onRelease()
                    }
                }
            )
            .onChange(of: enabled) { _, nowEnabled in
                if !nowEnabled, pressed { pressed = false; onRelease() }
            }
    }
}

/// Transparent UIView that reports finger down / up / cancelled / slid-off as a single Bool.
struct TouchTracker: UIViewRepresentable {
    let enabled: Bool
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> TouchTrackingView {
        let v = TouchTrackingView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        return v
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.onChange = onChange
        uiView.isUserInteractionEnabled = enabled
        if !enabled { uiView.forceUp() }
    }

    final class TouchTrackingView: UIView {
        var onChange: ((Bool) -> Void)?
        private var isDown = false

        private func set(_ down: Bool) {
            guard down != isDown else { return }
            isDown = down
            onChange?(down)
        }

        func forceUp() { set(false) }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { set(true) }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            set(bounds.insetBy(dx: -12, dy: -12).contains(t.location(in: self)))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { set(false) }

        /// The important one: system interruptions (calls, alerts, edge swipes) land here.
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { set(false) }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { set(false) }
        }
    }
}

#Preview {
    DPadView(enabled: true, active: .forward, onPress: { _ in }, onRelease: {})
        .padding()
        .background(.black)
}
