# CARRY

An indoor delivery robot project developed by the **Stony Brook University CAD Lab**.

CARRY aims to transport small payloads—such as supplies, food, and packages—through structured indoor environments. The initial deployment target is Stony Brook University's Light Engineering building.

The project combines embedded AI, computer vision, motor control, and navigation. Development focuses first on a human-following delivery robot, followed by autonomous travel between predefined delivery points.

## Project status

**Prototype in development.** The following milestones are reported in the shared project log; they are not a claim of completed autonomous deployment.

| Date | Reported progress |
| --- | --- |
| May 7, 2026 | Both motors confirmed functional; robot driving independently of Jetson Nano integration. ESP32 USB connection verified. Camera code reported working. |
| May 8–13, 2026 | Camera and simulation run commands documented, alongside depth sensing, obstacle avoidance, and YOLO/depth fusion work. |
| August 27, 2026 | Base completed and installed; circuit reconfigured and CAD work continued. Cover chassis and mounts for the buck converter and WAGO connectors remained in progress; portable Jetson power was still pending. |

The repository is being initialized with project documentation. The scripts described below are referenced in the project log and still need to be added here before the documented commands can be run from this repository.

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

| Subsystem | Documented components and role |
| --- | --- |
| Onboard compute | NVIDIA Jetson Nano for perception and navigation decisions |
| Motor control | ESP32 / Arduino work documented; Jetson-to-controller integration remains a next step |
| Mobility | Motorized chassis; differential drive is described in the system proposal |
| Perception | Orbbec Astra depth camera with OpenNI2 in the development log; YOLO for object/person detection |
| Power | 3S 11.1 V LiPo battery, regulated 5 V supply, switch, fuse, and connectors described in the parts plan |
| Mechanical | Custom CAD/printed base, cover chassis, battery retention, and electronics mounts |
| Planned sensing | Wheel encoders and IMU for odometry and heading; LiDAR considered for later autonomy |

The source includes multiple hardware proposals, including RealSense and ultrasonic sensing alternatives. Confirm the assembled hardware before selecting drivers or wiring instructions.

The proposed control path is:

```text
Camera / depth sensing
        |
        v
Jetson Nano: detection and navigation
        |
        v
Serial motor bridge (integration planned)
        |
        v
Microcontroller -> motor driver -> motors
```

## Software referenced in the project log

These filenames describe the existing development workspace referenced by the team, rather than files currently included in this repository.

| Script | Documented purpose |
| --- | --- |
| `scripts/yolo_object_detection.py` | Camera-based YOLO object detection |
| `scripts/astra_camera.py` | Orbbec Astra depth camera integration using OpenNI2 |
| `scripts/nav_logic.py` | Depth zones, navigation thresholds, obstacle avoidance, and stuck recovery |
| `scripts/yolo_obstacle_detection.py` | YOLO detection combined with depth sensing |
| `scripts/sim.py` | Building map and simulator |
| `scripts/collect_collision_data.py` | Collision data collection |

Human-following code is also reported in the project log, but its entry-point filename is not specified.

## Development setup notes

The commands below reproduce the May 2026 project notes. They are not yet a verified installation procedure for a fresh checkout. The repository still needs the source code, dependency versions, and device-specific setup instructions.

### Existing lab environment

The documented Jetson workspace uses these machine-specific paths:

```bash
cd ~/jetbot-project
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
# Object detection
python3 scripts/yolo_object_detection.py

# Building simulation
python3 scripts/sim.py

# YOLO and depth-based obstacle detection
PYTHONPATH=scripts python3 scripts/yolo_obstacle_detection.py
```

## Safety protocol from the project log

- Keep the main motor power supply off while communicating with the ESP32 during bench setup, as directed in the project notes.
- Cut power immediately if humming or overheating occurs.
- Emergency stop, power protection, secure battery mounting, and safe stop behavior are part of the development plan and require verification before integrated driving tests.

## Roadmap

1. **Complete mechanical and power integration:** finish the cover chassis, secure the battery, mount the buck converter and connectors, and establish portable Jetson power.
2. **Connect perception to motor control:** implement and validate the Jetson-to-ESP32 serial bridge and motor command handling.
3. **Calibrate wheel encoders:** measure actual travel, determine ticks per meter for each wheel, and validate distance and turns.
4. **Integrate an IMU:** improve heading estimates and combine IMU measurements with encoder odometry.
5. **Integrate ROS:** select a compatible ROS environment, publish odometry and IMU data, and test movement commands.
6. **Improve navigation:** smooth steering, adjust speed to clearance, add wall following, and progress toward mapped routes and waypoint delivery.
7. **Integrate human following:** connect detection and distance estimates to motion control, including lost-target and obstacle stop behavior.
8. **Validate reliability:** conduct extended runs, test delivery payloads and safety behavior, and evaluate battery monitoring and a monitoring dashboard.

## Source documentation

This README summarizes the shared [CARRY project plan and development log](https://docs.google.com/document/d/1aS6I8t9bZzvT69oGxUss__Pbkqzwnhu3tOi9AWAEsmA/edit?tab=t.jsert22n468u), including the May–August 2026 progress notes and delivery robot proposal. Access to the source document may require permission.

Procurement estimates and runtime projections in the source are planning figures; a verified bill of materials and measured runtime should be added as the build is finalized.
