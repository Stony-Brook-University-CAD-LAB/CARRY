"""Check obstacle_avoidance against synthetic depth scenes (no rover needed).

Renders a flat floor seen from a camera 0.20 m high, adds boxes, people and
"too close" blind spots, streams them to the node and checks its status.

    ros2 run rover_navigation obstacle_avoidance &
    python3 tools/obstacle_scene_test.py
"""
import struct
import subprocess
import sys
import time

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image
from std_msgs.msg import String

W, H, F = 640, 480, 570.0
CAM_H = 0.20  # matches the node's default camera_height


def render(wall=None, floor=True, close_blank=False):
    """wall = (distance_m, x_min_m, x_max_m) in camera coords (x right)."""
    data = bytearray(W * H * 2)
    for v in range(H):
        ry = (v - H / 2) / F
        for u in range(W):
            rx = (u - W / 2) / F
            z = float("inf")
            if floor and ry > 1e-6:
                z = CAM_H / ry
            if wall:
                d, x0, x1 = wall
                if x0 <= rx * d <= x1 and -CAM_H <= ry * d <= CAM_H:
                    z = min(z, d)
            if close_blank and W // 4 <= u < 3 * W // 4:
                z = 0.0  # camera can't measure: object closer than 0.4 m
            mm = 0 if z == float("inf") or z > 8.0 else int(z * 1000)
            struct.pack_into("<H", data, (v * W + u) * 2, mm)
    msg = Image()
    msg.height, msg.width, msg.encoding, msg.step = H, W, "16UC1", W * 2
    msg.data = bytes(data)
    return msg


def person(x, w=120):
    return '[{"class":"person","confidence":0.9,"x":%d,"y":120,"w":%d,"h":300}]' % (x, w)


def only(*ok):
    return lambda seen: bool(seen) and all(s in ok for s in seen)


def never(*bad):
    return lambda seen: bool(seen) and not any(s in bad for s in seen)


SCENES = [
    ("floor only", render(), only("PATH CLEAR")),
    ("box 0.45 m off to the side", render(wall=(0.45, 0.35, 0.60)), only("PATH CLEAR")),
    ("box 0.8 m ahead", render(wall=(0.8, -0.15, 0.15)), only("CAUTION")),
    ("person far left, 1.2 m", render(wall=(1.2, -0.6, 0.6)), only("PATH CLEAR"), person(0, 100)),
    ("person ahead, 3 m away", render(wall=(3.0, -0.6, 0.6)), only("PATH CLEAR"), person(260)),
    ("person ahead, 1.2 m", render(wall=(1.2, -0.6, 0.6)),
     never("PATH CLEAR", "CAUTION"), person(260)),
    ("box 0.45 m ahead", render(wall=(0.45, -0.15, 0.15)), never("PATH CLEAR", "CAUTION")),
    ("too close, no depth", render(close_blank=True), never("PATH CLEAR", "CAUTION")),
]


class Tester(Node):
    def __init__(self):
        super().__init__("oa_tester")
        self.pub = self.create_publisher(Image, "/camera/depth/image_raw", 10)
        self.det_pub = self.create_publisher(String, "/yolo/detections", 10)
        self.img = None
        self.det = "[]"
        self.seen = set()
        self.create_subscription(String, "/navigation/status", self.on_status, 10)
        self.create_timer(1 / 30, self.tick)

    def tick(self):
        if self.img is not None:
            self.img.header.stamp = self.get_clock().now().to_msg()
            self.pub.publish(self.img)
            self.det_pub.publish(String(data=self.det))

    def on_status(self, msg):
        self.seen.add(msg.data.split(" |")[0])


def spin_for(node, seconds):
    end = time.time() + seconds
    while time.time() < end:
        rclpy.spin_once(node, timeout_sec=0.01)


def main():
    rclpy.init()
    t = Tester()
    t.img = SCENES[0][1]
    spin_for(t, 1.0)
    subprocess.run(["ros2", "param", "set", "/obstacle_avoidance", "enabled", "true"],
                   check=True, capture_output=True)
    failures = 0
    for name, img, check, *det in SCENES:
        t.img = img
        t.det = det[0] if det else "[]"
        spin_for(t, 1.5)  # let the filter and state machine settle
        t.seen = set()
        spin_for(t, 1.0)
        seen = sorted(t.seen)
        ok = check(seen)
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name:28s} {seen}")
    rclpy.shutdown()
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
