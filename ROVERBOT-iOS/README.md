# ROVERBOT iOS Control App

Native iPhone operator console for ROVERBOT (ROS 2 Humble on a Jetson Orin Nano).
Built from the Oct 22, 2026 engineering handoff. SwiftUI, iOS 17+, no third-party packages.

```
iPhone  ──WebSocket :9090 (rosbridge)──▶  Jetson: /cmd_vel, /navigation/status, /yolo/detections, set_parameters
        ◀──HTTP MJPEG :5000/stream─────  web_stream_node (YOLO boxes + status bar burned in)
```

## What's in this folder

| Path | What |
|---|---|
| `ROVERBOT.xcodeproj` | Xcode 16 project (uses a synchronized folder, so new Swift files are picked up automatically) |
| `ROVERBOT/` | App sources |
| `ROVERBOT/Rosbridge/RosbridgeClient.swift` | rosbridge v2 JSON protocol over `URLSessionWebSocketTask`; ping-based latency; auto-detects drops |
| `ROVERBOT/Models/RoverClient.swift` | The controller: dead-man drive timer (100 ms), STOP, mode switch, PWM/trim, event log, all safety rules |
| `ROVERBOT/Models/RoverModels.swift` | Twist / direction mapping, `/navigation/status` parser + colours, YOLO detection JSON |
| `ROVERBOT/Video/MJPEGStream.swift` | `multipart/x-mixed-replace` decoder for `:5000/stream`, auto-reconnect |
| `ROVERBOT/Views/` | Connect, Drive (video + status + D-pad + STOP + mode + speed), Settings, Detections |
| `Config/Info.plist` | ATS exception for plain `ws://` + `http://` on the lab LAN, local-network permission string |
| `robot-side/0001-phone-bridge.patch` | **Required** changes to the ROVERBOT repo (see below) |
| `project.yml` | XcodeGen fallback if Xcode ever dislikes the hand-written project |

## 1. Robot side (do this first)

The repo has no network control interface, nothing launches `web_stream_node`, and `obstacle_avoidance`
publishes `/cmd_vel` unconditionally. The patch fixes all three:

* adds `rosbridge_server` (`:9090`) and `web_stream_node` (`:5000`) to `rover.launch.xml`
* adds an `enabled` parameter to `obstacle_avoidance` — the Manual/Autonomous switch.
  `false` = Manual: the node only publishes `/navigation/status` as `MANUAL | <dist> m` and never touches `/cmd_vel`.
  `rover.launch.xml` now starts it `false`, so the rover always boots in Manual.
  Any attempt to set `stop_for_person=false` at runtime is rejected by the node.
* adds a `/phone/heartbeat` subscription (std_msgs/Empty, the app sends it 4×/s). If the heartbeat stops for
  `heartbeat_timeout_s` (1 s) while Autonomous, the node reverts to Manual and stops — so a phone that drops off
  Wi-Fi mid-Autonomous cannot leave the rover driving itself. Set the parameter to 0 for terminal-only autonomous runs.
* adds `manual.launch.xml` (cameras + YOLO + motors + stream + bridge, no obstacle avoidance) for pure phone driving

On the Jetson:

```bash
sudo apt install ros-humble-rosbridge-suite
cd ~/ROVERBOT
git apply /path/to/0001-phone-bridge.patch      # or open a PR with it
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
source install/setup.bash
ros2 launch rover_bringup rover.launch.xml      # full stack, starts in Manual
hostname -I                                     # <- the IP to type into the app
```

Quick check from a laptop on the same Wi-Fi: open `http://<jetson-ip>:5000` for video, and
`ros2 param get /obstacle_avoidance enabled` should print `false`.

## 2. Build the app

1. Open `ROVERBOT.xcodeproj` in **Xcode 16 or newer**.
2. Select the ROVERBOT target → *Signing & Capabilities* → pick your Team (a free personal Apple ID works for
   running on your own phone; TestFlight for lab staff needs the lab's paid Developer account).
3. Plug in an iPhone running iOS 17+ and press Run. (The Simulator works for the UI, but the Simulator can
   reach the rover only if the Mac is on the lab Wi-Fi.)
4. First launch: iOS asks for *Local Network* permission — tap Allow, or the app can't see the Jetson.

If Xcode refuses the project file for any reason: `brew install xcodegen && xcodegen generate` in this folder
rebuilds an identical project from `project.yml`.

## 3. Use it

* **Connect** – type the Jetson IP (ports default 9090 / 5000). Recent rovers are remembered.
* **Drive** – hold a D-pad arrow to move; let go to stop. Only one direction at a time (that is all
  `motor_node` supports: it sends `F/B/L/R/S` to the ESP32).
* **STOP** – big red button, always visible, always works: zero Twist ×3 + Autonomous off + Manual.
* **Mode** – Manual / Autonomous segmented control; Autonomous asks for confirmation. In Autonomous the D-pad
  is disabled because `obstacle_avoidance` owns `/cmd_vel`.
* **Status line** – `/navigation/status` colour-coded: green PATH CLEAR, yellow CAUTION, orange scanning/avoiding,
  red any STOP, blue MANUAL, grey when no status has arrived for 2 s.
* **Speed / trim** – slider sets both PWMs; Settings has trim (+ = left wheel faster) and the indoor PWM cap
  (default 150, from the lab mission rules). Values are sent live to `/rover_motor` via `set_parameters`.
* **Detections** – the badge in the top bar turns red with a walking figure when YOLO sees a person; tap for the list.

## Safety behaviour (as implemented)

| Rule from the handoff | Where |
|---|---|
| Drive commands repeat every 100 ms only while held; release = zero Twist | `RoverClient.startDriving / stopDriving` |
| App goes to background ⇒ STOP | `ROVERBOTApp.onChange(of: scenePhase)` |
| Wi-Fi / socket drop ⇒ stop sending, show full-screen "Connection lost — rover stopped", mode ⇒ Manual | `RoverClient.handleStateChange` (+ robot watchdogs 500 ms / 750 ms, + heartbeat timeout in Autonomous) |
| System cancels a touch (call, alert, edge swipe) while driving ⇒ release | `DPadView.TouchTracker.touchesCancelled`; any error alert also calls `stopDriving` |
| STOP overrides Autonomous | `RoverClient.emergencyStop` |
| Always connect in Manual; Autonomous only via confirmed tap | `onConnected` + `DriveView.confirmAutonomous` |
| Never disable `stop_for_person` | app never sends it; node rejects `false` anyway |
| One driver at a time | **not yet** — rosbridge accepts any client; see Open items |

## Open items / next steps

* **One-driver lock + token check.** Plain rosbridge has no auth. The app already sends `?token=…`; either put
  a tiny WebSocket proxy in front of 9090 that checks it and admits one controlling client, or replace rosbridge
  with a small custom node. Until then, run the rover on a dedicated lab SSID or the Jetson's own hotspot.
* **Proportional speed** needs ESP32 firmware changes (v2 in the handoff). Today speed is the PWM slider only.
* **Mission / delivery mode** (route legs, pickup wait, detour bookkeeping from the mission-controller spec) is a
  natural next layer on top of `RoverClient`: it only needs `startDriving/stopDriving`, `setMode`, `navStatus`
  and `detections`, which are all already exposed.
* Later screens from the handoff: map view (RTAB-Map), delivery stops (Nav2).
* App icon: drop a 1024×1024 PNG into `ROVERBOT/Assets.xcassets/AppIcon.appiconset`.

## Protocol reference (what the app sends)

```jsonc
{"op":"advertise","topic":"/cmd_vel","type":"geometry_msgs/msg/Twist"}
{"op":"publish","topic":"/phone/heartbeat","msg":{}}            // every 250 ms while connected
{"op":"publish","topic":"/cmd_vel","msg":{"linear":{"x":0.2,"y":0,"z":0},"angular":{"x":0,"y":0,"z":0}}}
{"op":"subscribe","topic":"/navigation/status","type":"std_msgs/msg/String","throttle_rate":100}
{"op":"subscribe","topic":"/yolo/detections","type":"std_msgs/msg/String","throttle_rate":200}
{"op":"call_service","service":"/rover_motor/set_parameters","type":"rcl_interfaces/srv/SetParameters",
 "args":{"parameters":[{"name":"left_pwm","value":{"type":2,"integer_value":120}}]}}
{"op":"call_service","service":"/obstacle_avoidance/set_parameters","type":"rcl_interfaces/srv/SetParameters",
 "args":{"parameters":[{"name":"enabled","value":{"type":1,"bool_value":true}}]}}
```
