# ROVERBOT iPhone App — Installation & Usage Guide

This guide takes you from a fresh ROVERBOT and an iPhone to driving the rover over Wi-Fi.
It has three parts: **A. Robot setup (once)**, **B. Install the app on an iPhone**, **C. Driving**.
Developer details live in `README.md`; this file is the operator-facing walkthrough.

---

## What you need

| Item | Notes |
|---|---|
| ROVERBOT with Jetson Orin Nano, ROS 2 Humble, ESP32 on `/dev/ttyUSB0`, Orbbec camera | The existing repo stack, built with `colcon` |
| A Wi-Fi network both the Jetson and the phone can join | Lab Wi-Fi works; a dedicated router or the Jetson's own hotspot is better (no one else can reach the rover) |
| iPhone running **iOS 17 or newer** | iPad also works |
| A Mac with **Xcode 16 or newer** | Only needed to install the app; free from the Mac App Store |
| An Apple ID | A free one lets you install on your own phone for 7 days at a time; the lab's paid Apple Developer account is needed for TestFlight / longer installs |

---

## Part A — Robot setup (do once per Jetson)

The stock repo has no network control. These steps add the bridge the app talks to.

**A1. Install rosbridge on the Jetson**

```bash
sudo apt update
sudo apt install ros-humble-rosbridge-suite
```

**A2. Apply the robot-side patch**

Copy `robot-side/0001-phone-bridge.patch` from this folder to the Jetson (USB stick, `scp`, or paste), then:

```bash
cd ~/ROVERBOT
git apply /path/to/0001-phone-bridge.patch
git status          # should list 6 changed/new files
```

What it changes: adds the WebSocket bridge (`:9090`) and the video server (`:5000`) to the launch
file, adds a Manual/Autonomous switch to the obstacle-avoidance node, adds a phone heartbeat so the
rover stops if the phone disappears while in Autonomous, and adds a `manual.launch.xml` that runs
without obstacle avoidance at all.

**A3. Rebuild**

```bash
source /opt/ros/humble/setup.bash
cd ~/ROVERBOT
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
source install/setup.bash
```

**A4. Launch the rover stack**

```bash
ros2 launch rover_bringup rover.launch.xml
```

Use `manual.launch.xml` instead if you only want phone driving with no obstacle avoidance.
The rover **always starts in Manual** — it will not move on its own after launch.

**A5. Find the Jetson's IP address**

```bash
hostname -I        # e.g. 192.168.1.42  ← type this into the app
```

**A6. Check from a laptop (optional but recommended)**

On any laptop on the same Wi-Fi, open `http://<jetson-ip>:5000` in a browser. You should see the
camera with YOLO boxes and a status bar. If this works, the phone will work too.

> Tip: give the Jetson a fixed IP in the router (DHCP reservation) so the address never changes.

---

## Part B — Install the app on an iPhone

**B1. Open the project**

1. Copy the whole `ROVERBOT-iOS` folder to the Mac (if it's on Google Drive, make sure it's downloaded, not "online-only").
2. Double-click `ROVERBOT.xcodeproj`. Xcode opens.

**B2. Set the signing team (required once)**

1. In the left file list click the blue **ROVERBOT** project icon at the top.
2. Select the **ROVERBOT** target → **Signing & Capabilities** tab.
3. Tick **Automatically manage signing** and pick your **Team**.
   - No team listed? Xcode → Settings → Accounts → **+** → sign in with your Apple ID, then come back.
4. If Xcode complains the bundle ID is taken, change **Bundle Identifier** to something unique,
   e.g. `edu.stonybrook.ece.roverbot.jenny`.

**B3. Install on the phone**

1. Plug the iPhone into the Mac with a cable. Tap **Trust** on the phone if asked.
2. In Xcode's top bar choose your iPhone as the run destination (not a Simulator).
3. Press **▶ Run** (⌘R). The first build takes a minute or two.
4. **First time only, on the phone:** Settings → General → VPN & Device Management → tap your
   Apple ID → **Trust**. Then launch the app from the home screen.
5. iOS will ask *"ROVERBOT would like to find and connect to devices on your local network"* →
   tap **Allow**. (If you tapped Don't Allow: Settings → Privacy & Security → Local Network → ROVERBOT → on.)

Free Apple ID installs expire after 7 days; just press Run again to refresh. For lab staff phones
without a Mac, upload a build to **TestFlight** from the lab's paid developer account
(Product → Archive → Distribute App → TestFlight) and invite staff by email.

**B4. If Xcode refuses to open the project**

```bash
brew install xcodegen
cd ROVERBOT-iOS && xcodegen generate
```
then open the regenerated `ROVERBOT.xcodeproj` and repeat B2.

---

## Part C — Using the app

### C1. Connect

1. Put the iPhone on the **same Wi-Fi as the Jetson**.
2. Open ROVERBOT. On the Connect screen type the Jetson IP from step A5. Leave the ports at
   **9090** (control) and **5000** (video) unless you changed them.
3. Tap **Connect**. The Drive screen appears when the link is up.
4. Recently used rovers appear in a list — tap one to reconnect next time.

The pill in the top-left shows the rover IP and round-trip latency: **green** under 100 ms,
**yellow** under 300 ms, **red** above. If the pill is red, slow down.

### C2. The Drive screen

```
┌──────────────────────────────────────────────┐
│ ● 192.168.1.42 23 ms      [👁 2] [⚙] [✕]      │  ← connection, detections, settings, disconnect
├──────────────────────────────────────────────┤
│                                              │
│              LIVE VIDEO (YOLO boxes)         │
│                                              │
├──────────────────────────────────────────────┤
│ ● PATH CLEAR                 1.20 m  MANUAL  │  ← navigation status line
├──────────────────────────────────────────────┤
│        [ Manual | Autonomous ]               │  ← mode switch
│            ▲                                 │
│        ◀   ●   ▶          (  STOP  )         │  ← hold-to-drive pad   emergency stop
│            ▼                                 │
│  🏎 ────────●─────── 120    PWM L 120 · R 120 │  ← speed slider
└──────────────────────────────────────────────┘
```

Rotate the phone sideways for a bigger video with the controls on the right.

### C3. Driving (Manual mode)

- **Press and hold** an arrow to move. **Let go to stop.** There is no "cruise" — the rover only
  moves while your finger is down. Sliding your finger off the button also stops it.
- One direction at a time: forward, back, turn left, turn right. (The motor firmware can't curve.)
- **Speed slider** sets the motor power (PWM). Start around **100–120** indoors. The slider can't go
  above the indoor cap (150 by default; changeable in Settings).
- Rover drifts to one side? Settings → **Trim**: push it **+** if the rover pulls right, **−** if it
  pulls left. The change applies immediately and is remembered.

### C4. Autonomous mode

1. Tap **Autonomous** on the mode switch and confirm.
2. The rover drives itself: forward when clear, slows in CAUTION, stops and scans around obstacles,
   stops for people. The D-pad greys out because the robot owns the wheels.
3. Tap **Manual** or **STOP** at any time to take back control. Both stop the rover first.

Autonomous requires `rover.launch.xml` (not `manual.launch.xml`). If you get an error like
*"obstacle_avoidance is not running"*, that's why.

### C5. Status line colours

| Colour | Meaning | Examples |
|---|---|---|
| 🟢 Green | Path clear, > 1 m | `PATH CLEAR` |
| 🟡 Yellow | Something 0.5–1 m ahead | `CAUTION` |
| 🟠 Orange | Robot is working around an obstacle | `SCANNING LEFT`, `AVOIDING - TURN RIGHT`, `REVERSING` |
| 🔴 Red | Stopped | `PERSON DETECTED - STOP`, `BLOCKED - STOP`, `DEPTH LOST - STOP`, `TOO CLOSE - SCANNING` |
| 🔵 Blue | Manual mode (you are driving) | `MANUAL` |
| ⚪ Grey | No status received for 2 s | obstacle_avoidance not running or link problem |

The number on the right is the distance to the nearest thing straight ahead.

### C6. STOP and other safety behaviour

- **STOP** (big red button) always works, in any mode: it stops the wheels, turns Autonomous off, and
  returns to Manual. Use it first, ask questions later.
- Switching apps, locking the phone, or an incoming call = STOP.
- Losing Wi-Fi = the rover stops itself within ~1 s (its own watchdogs) and the app shows a full-screen
  **"Connection lost — rover stopped"** notice. Reconnect from the Connect screen.
- The app always connects in Manual. Person-stop in Autonomous cannot be turned off from the app.
- Rule of thumb: **never drive the rover you can't see.** The camera only looks forward; reversing is blind.

### C7. Detections

The badge next to the gear shows how many objects YOLO sees. It turns **red with a walking figure**
when a person is in view. Tap it for the list with confidence values.

### C8. Settings (⚙)

Speed and trim sliders · indoor PWM cap · optional bridge token (for a future secured bridge) · the
current mode and status · a timestamped **event log** of every connect, drive, stop, mode change and
PWM change (useful when something odd happens during a test).

---

## Troubleshooting

| Symptom | Check |
|---|---|
| "Could not connect" | Phone and Jetson on the same Wi-Fi? Correct IP (`hostname -I` on the Jetson)? Is `rover.launch.xml` running and did it print `Rosbridge WebSocket server started on port 9090`? Local Network permission allowed on the phone? |
| Connected but no video | Open `http://<jetson-ip>:5000` in a laptop browser. If that is blank, `web_stream_node` isn't running — check the launch output. |
| Video but rover doesn't move | Is the mode **Manual**? Is the speed slider above ~60? Does the launch log show `ESP32 connected on /dev/ttyUSB0`? Try `ls /dev/ttyUSB*` on the Jetson. |
| Rover moves but only in jerks | Latency pill red → Wi-Fi is too slow/far; move the router or use the Jetson hotspot. |
| Status line grey "NO STATUS" | obstacle_avoidance isn't running (you launched `manual.launch.xml`) or the depth camera is down. Manual driving still works. |
| "obstacle_avoidance is not running" when switching to Autonomous | Launch with `rover.launch.xml`. |
| Rover pulls to one side | Settings → Trim. |
| App icon is a blank grid | Normal — no icon has been added yet (drop a 1024×1024 PNG into `Assets.xcassets/AppIcon.appiconset`). |
| App stops opening after a week | Free Apple ID signing expired — press Run in Xcode again, or use TestFlight. |

---

## Pre-drive checklist (lab)

- [ ] Area clear of people who don't know the rover is about to move
- [ ] Jetson launched, laptop check of `:5000` video passed
- [ ] Phone connected, latency pill green or yellow
- [ ] Mode shows **MANUAL**, status line not grey
- [ ] Speed ≤ 120 for the first run
- [ ] Thumb knows where **STOP** is
