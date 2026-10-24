# CARRY

An indoor delivery robot project developed by the **Stony Brook University CAD Lab**.

CARRY aims to transport small payloads—such as supplies, food, and packages—through structured indoor environments. The initial deployment target is Stony Brook University's Light Engineering building.

The project combines embedded AI, computer vision, motor control, and navigation. Development focuses first on a human-following delivery robot, followed by autonomous travel between predefined delivery points.

The current build (V1) is a **tracked rover that delivers mail while avoiding obstacles**, running ROS 2 on an NVIDIA Jetson Orin Nano with an ESP32 motor controller and an Orbbec Astra Pro depth camera. It can be driven manually or switched to autonomous obstacle avoidance from an iPad app.

**Team (Fall 2026):** Danny Ouyang (EE), Siddhant Mohile (CS), Marco Wu (CME), Akeen Karkare (CS). **Mentor:** Jenny Chen, ECE CAD Lab.

## Project status

**Prototype in development.** The following milestones are reported in the shared project log; they are not a claim of completed autonomous deployment.

| Date | Reported progress |
| --- | --- |
| May 7, 2026 | Both motors confirmed functional; robot driving independently of Jetson Nano integration. ESP32 USB connection verified. Camera code reported working. |
| May 8–13, 2026 | Camera and simulation run commands documented, alongside depth sensing, obstacle avoidance, and YOLO/depth fusion work. |
| August 27, 2026 | Base completed and installed; circuit reconfigured and CAD work continued. Cover chassis and mounts for the buck converter and WAGO connectors remained in progress; portable Jetson power was still pending. |
| September 24, 2026 | Autonomy plan set: build a floor map with RTAB-Map, place AprilTags at drift-prone spots, add a navigation stack for point-to-point paths, and bridge planner output to the motors over serial. Tag detection and camera setup in testing. |
| October 9, 2026 | Rover presented at Poster Day. V1 demo shows basic control and obstacle avoidance. |
| October 23, 2026 | End-to-end test with the iPad app over SSH: rosbridge (port 9090), motor node, video stream (port 5000) and autonomous mode brought up. Fixes merged as `ros2_ws/` (see [Run the rover with the iPad app](#run-the-rover-with-the-ipad-app)). |

The navigation, perception, and simulation source has been merged into this repository and is listed under [Repository layout](#repository-layout). The ROS 2 workspace the rover runs today is in `ros2_ws/`.

## Delivery modes

### Human-following MVP

- Detect and follow a designated person while carrying items.
- Maintain an appropriate following distance and stop when the person stops.
- Incorporate obstacle avoidance and stop conditions for lost targets or blocked sensing.

### Autonomous delivery target

- Localize the robot within the building.
- Navigate hallways while avoiding people and obstacles.
- Travel between predefined delivery waypoints.
- Support arrival notification as part of the intended delivery workflow.

These are development objectives; full integration and validation remain ongoing.

## Hardware and architecture

V1 hardware as presented at Poster Day (October 2026):

| Subsystem | Component and role |
| --- | --- |
| Compute ("brain") | NVIDIA Jetson Orin Nano: runs ROS 2, perception, YOLO and navigation |
| Motor control | ESP32: turns serial commands from the Jetson into motor signals and reads the encoders |
| Motor driver | TB6612FNG dual driver: PWM and direction for both track motors |
| Mobility ("body") | Tracked chassis with 2 DC motors with encoders, in an enclosed electronics box |
| Perception ("eyes") | Orbbec Astra Pro RGB-D camera over USB 3.0, depth range 0.4–8 m |
| Power | 11.1 V 3S 5000 mAh LiPo → XT60 inline switch → 15 A blade fuse → E-STOP; UBEC steps down to 5 V / 5 A for the Jetson; motors run on 11.1 V |
| Safety | Red mushroom E-STOP cuts main power and signals the software on GPIO4 |
| Mechanical | Custom CAD base, cover chassis, battery retention and electronics mounts |

Earlier proposals in the project log (RealSense, ultrasonic sensors, LiDAR) are not part of the V1 build.

Control path (sense → think → act):

```text
Orbbec Astra Pro (depth + RGB)
        | USB 3.0
        v
Jetson Orin Nano: ROS 2, YOLO, obstacle avoidance
        | serial (USB, /dev/ttyUSB0, 115200)
        v
ESP32 -> TB6612FNG (PWM + direction) -> track motors
```

Autonomy stack: ROS 2 for communication, RTAB-Map SLAM for mapping, YOLO for obstacle and person detection, wheel encoders for odometry, and a stop–scan–re-route behaviour when the path is blocked.

## Repository layout

The development workspace has been merged in; these files are present in this repository.

| Path | Purpose |
| --- | --- |
| `scripts/nav_logic.py` | Depth-zone navigation policy: L/C/R zone analysis, GO/AVOID/STOP thresholds, and stuck recovery. Pure numpy, with no camera or display dependency. |
| `scripts/astra_camera.py` | Orbbec Astra Pro integration. RGB over V4L2, depth over OpenNI2; returns synchronized colour and depth frames. |
| `scripts/yolo_obstacle_detection.py` | Live navigator. Depth drives steering; YOLO labels what is visible but does not influence throttle or steer. |
| `scripts/sim.py` | Top-down simulator. Ray-casts a synthetic depth view against the building map and drives the same `nav_logic` policy as the live navigator. |
| `scripts/building_map.py` | Occupancy grid of Light Engineering floor 2 (100 x 80 ft outer, 8 ft corridors, 10 cm cells). |
| `scripts/collect_collision_data.py` | Capture tool for free/blocked training pairs: colour JPEG plus uint16 depth PNG sharing a timestamp. |
| `scripts/motor_driver.py` | Motor command wrapper. Ships in `DRY_RUN` mode and only prints commands; the serial bridge to the microcontroller is not yet implemented. |
| `scripts/test_camera_preview.py` | Minimal preview for confirming the Astra is enumerating. |
| `camera_stream.py` | Flask MJPEG server on port 5000 (`/stream` or `/video_feed`) for viewing the navigation overlay from a browser or the iPad app. |
| `fps_test.py` | Raw V4L2 capture-rate benchmark. |
| `data/collision/` | Captured free/blocked image pairs. |
| `building_map.png` | Rendered occupancy map. |
| `ros2_ws/` | ROS 2 Humble workspace that runs on the rover with the iPad app: motor, camera, YOLO, obstacle-avoidance and launch packages. See `ros2_ws/README.md`. |

Two items named in the project log are **not** present in this repository: a
`scripts/yolo_object_detection.py` entry point, and the human-following code. The
closest existing file is `scripts/yolo_obstacle_detection.py`, which is the
depth-plus-YOLO navigator rather than standalone object detection.

## Run the rover with the iPad app

This is the procedure tested on October 23, 2026. The rover and iPad must both be on the lab UniFi Wi-Fi.

The full step-by-step guide is in [`ros2_ws/docs/rover-startup-ipad.md`](ros2_ws/docs/rover-startup-ipad.md).

| What | Value |
| --- | --- |
| SSH | `ssh cad281@<rover-ip>` |
| App connection (rosbridge) | port `9090` |
| Video stream | port `5000`, path `/stream` |
| ROS 2 workspace on the rover | `~/ROVERBOT` (same code as `ros2_ws/` here) |

One command starts rosbridge, both cameras, YOLO, obstacle avoidance, the motor node and the video stream:

```bash
cd ~/ROVERBOT && source /opt/ros/humble/setup.bash && source install/setup.bash
ros2 launch rover_bringup full.launch.xml
```

Then open the iPad app, set rosbridge to `9090` and video to `5000`, and tap **Connect**. **Manual** uses the arrow buttons; **Autonomous** turns on obstacle avoidance. **STOP** always works.

| App message | Cause | Fix |
| --- | --- | --- |
| Can't connect / port 9090 refused | rosbridge not running | Start rosbridge (included in `full.launch.xml`) |
| "Service /rover_motor/set_parameters does not exist" | Motor node not running | Run the launch file, or `ros2 run rover_motor motor_node` |
| "Package 'rover_motor' not found" | Workspace not sourced | `source install/setup.bash` in every new terminal |
| "Video: Could not connect" | Nothing on port 5000 | Start the launch file, or `camera_stream.py` for manual-only use |
| Camera "Resource busy" | Another program holds the Astra (only one can) | `pkill -f camera_stream.py`, then relaunch |
| "Could not enable Autonomous" | `obstacle_avoidance` not running | Use `full.launch.xml` / `rover.launch.xml` |

Run only one copy of each program: two motor nodes fight over the ESP32 serial port, and two camera programs fight over the Astra.

## Development setup notes

These commands are for the Python scripts at the repository root and reproduce the May 2026 project notes. They are not yet a verified installation procedure for a fresh checkout; dependency versions and device-specific setup still need to be documented. For the ROS 2 stack, see `ros2_ws/README.md`.

### Existing lab environment

Run commands from the repository root. The lab Jetson uses a virtualenv at a machine-specific path:

```bash
cd /path/to/CARRY
source /home/cad281/jetson-ai/bin/activate
```

Adjust these paths to match your own workspace and Python environment.

### Dependencies recorded in the log

```bash
pip3 install opencv-python pyserial numpy ultralytics
```

The Astra integration also references OpenNI2. Jetson software compatibility, camera drivers, and dependency versions need to be documented and verified on the target device.

### Identify USB serial devices

```bash
ls /dev/ttyUSB*
```

### Check camera availability

```bash
python3 - <<'PY'
import cv2

cap = cv2.VideoCapture(0)
print(cap.isOpened())
cap.release()
PY
```

### Run the documented scripts

After the scripts and required dependencies are available, run the appropriate command from the development project root:

```bash
# Top-down simulator (no camera required; runs on any machine)
PYTHONPATH=scripts python3 scripts/sim.py

# Render the building occupancy map
PYTHONPATH=scripts python3 scripts/building_map.py

# Live YOLO + depth navigator (requires the Astra camera)
PYTHONPATH=scripts python3 scripts/yolo_obstacle_detection.py

# Browser-viewable navigation stream, then open http://<jetson-ip>:5000
PYTHONPATH=scripts python3 camera_stream.py

# Collect free/blocked training data
PYTHONPATH=scripts python3 scripts/collect_collision_data.py
```

`scripts/` is not a package, so the modules import each other flat; `PYTHONPATH=scripts`
is required for every entry point above.

## Safety

Bench setup (project log):

- Keep the main motor power supply off while communicating with the ESP32 during bench setup.
- Cut power immediately if humming or overheating occurs.

Lab safety guidelines for demos:

- **Know the E-STOP:** press the red E-STOP to cut all power to the rover instantly.
- **Keep a clear zone:** stay at least 1 m (3 ft) back while the rover is driving.
- **Power off first:** switch off at the XT60 before touching tracks, motors, or wiring.
- **Care for the LiPo:** charge on a balance charger in a fire-safe bag, never unattended.
- **Spot warning signs:** stop and report a swollen battery, hot wires, or a burning smell.
- **Run with supervision:** operate the rover only with trained lab staff present.

In an emergency: press the E-STOP, step back, and alert lab staff.

## Roadmap

Done in V1: ROS 2 on the Jetson, Jetson-to-ESP32 serial motor control (`rover_motor`), depth-based obstacle avoidance with YOLO person stop, and iPad manual/autonomous control.

Next for V1:

1. **Mapping and localization:** build a floor map with RTAB-Map and place AprilTags at drift-prone spots.
2. **Path planning:** add a navigation stack so the rover can plan between any two points, not only drive forward, and bridge its output to the motors.
3. **Calibrate wheel encoders and add an IMU:** ticks per meter for each track, then fuse IMU heading with encoder odometry.
4. **Fix known issues from the October 23 test:** left and right controls are swapped in the app; the camera view is too zoomed in, so objects look closer than they are. Obstacle detection now ignores the floor and anything outside the rover's path (needs tuning on the rover; see `ros2_ws/README.md`).
5. **Connectivity:** the rover only works on the UniFi network; evaluate Bluetooth or a USB Wi-Fi dongle.
6. **Human following:** connect person detection and distance to motion control, with lost-target and obstacle stops.
7. **Reliability:** 30+ minute runs, battery monitoring, and multiple delivery waypoints on the building map.

V2 (next-generation upgrade, planned): keeps the V1 compute and depth camera and adds a robotic arm with gripper, mecanum wheels, sweeper brushes and a front-mounted depth camera, so the rover can pick up, carry and clean along its route. Core parts are estimated at under $800.

## Source documentation

This README summarizes the shared [CARRY project plan and development log](https://docs.google.com/document/d/1aS6I8t9bZzvT69oGxUss__Pbkqzwnhu3tOi9AWAEsmA/edit?tab=t.jsert22n468u), including the May–September 2026 progress notes and delivery robot proposal, plus the October 2026 Poster Day poster and presentation (*Autonomous Delivery Rover*), the V2 shopping list, and the October 23 iPad startup test. Access to the source documents may require permission.

Procurement estimates and runtime projections in the source are planning figures; a verified bill of materials and measured runtime should be added as the build is finalized.
