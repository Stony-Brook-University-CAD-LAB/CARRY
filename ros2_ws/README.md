# ROVERBOT

ROS 2 C++ rover stack for NVIDIA Jetson Orin Nano, ROS 2 Humble, Orbbec Astra Pro, YOLO/TensorRT, RTAB-Map, ESP32, and TB6612FNG motor control.

## Structure

- `firmware/esp32_motor/` - ESP32 motor firmware
- `src/rover_motor/` - manual and ROS motor control
- `src/rover_camera/` - RGB and depth camera nodes
- `src/rover_yolo/` - TensorRT YOLO node
- `src/rover_bringup/` - ROS 2 launch files
- `models/` - local YOLO model/engine location (model binaries are ignored by Git)

## Build

```bash
cd ~/ROVERBOT
source /opt/ros/humble/setup.bash
chmod +x install.sh
./install.sh
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release
source install/setup.bash
```

## Manual control

```bash
ros2 run rover_motor rover_control
```

Controls: W forward, S backward, A left, D right, SPACE stop, `[`/`]` left PWM down/up, `-`/`=` right PWM down/up, P show PWM, Q quit.

## Camera

```bash
ros2 run rover_camera rgb_node
ros2 run rover_camera depth_node
```

## Sensors launch

```bash
ros2 launch rover_bringup sensors.launch.xml
```

## YOLO

Place a TensorRT engine at `~/ROVERBOT/models/yolo11n.engine`, then run:

```bash
ros2 run rover_yolo yolo_node --ros-args -p engine:=$HOME/ROVERBOT/models/yolo11n.engine
```

## Measure the camera mount first

Obstacle detection and mapping both need to know where the camera sits. Measure on the rover and set:

| Value | Where | Default |
| --- | --- | --- |
| Lens height above the floor (m) | `camera_height` in `rover.launch.xml`, `camera_z:=` for mapping | 0.20 |
| Downward tilt | `camera_pitch_deg` (degrees) in `rover.launch.xml`, `camera_pitch:=` (radians) for mapping | 0 |
| Camera distance ahead of the rover's centre (m) | `camera_x:=` for mapping | 0.10 |
| Rover width (m) | `robot_width` in `rover.launch.xml` | 0.30 |

If the rover stops on an empty floor, `camera_height` or `camera_pitch_deg` is wrong.

## Obstacle detection

`obstacle_avoidance` turns each depth frame into 3D points, drops the floor (below `floor_margin`) and anything above `max_obstacle_height`, and looks for the nearest obstacle in three lanes: the rover's own path and a window to each side. It uses the median of the last 3 frames, treats missing depth right in front (closer than the camera's 0.4 m minimum) as blocked, and only stops for a person who is in the path and within `person_stop_distance`.

## RTAB-Map

```bash
# New map (deletes the old one), driving with the iPad app in manual mode
ros2 launch rover_bringup mapping.launch.xml rtabmap_args:=-d camera_z:=0.20 camera_x:=0.10

# Add to the existing map
ros2 launch rover_bringup mapping.launch.xml

# Use the saved map without changing it
ros2 launch rover_bringup mapping.launch.xml localization:=true
```

The map is saved to `~/.ros/rtabmap.db` when you stop with Ctrl+C. Drive slowly and avoid fast turns in front of blank walls, where visual odometry loses track.

## Full rover

```bash
ros2 launch rover_bringup rover.launch.xml
```

Test motors, RGB, depth, YOLO, and RTAB-Map individually before running the full stack.
