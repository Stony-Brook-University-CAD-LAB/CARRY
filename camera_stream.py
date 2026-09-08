import sys
import cv2
import numpy as np
from flask import Flask, Response

# Allow imports from the GitHub repo's scripts folder
sys.path.append("scripts")

from astra_camera import AstraCamera
from nav_logic import (
    Navigator,
    analyze_depth_zones,
    BAND_TOP_FRAC,
    BAND_BOT_FRAC
)

app = Flask(__name__)

cam = AstraCamera()
nav = Navigator()


def distance_text(distance):
    if distance == float("inf"):
        return "BLOCKED / TOO CLOSE"
    return f"{distance:.2f} m"


def generate_frames():

    while True:

        try:
            color, depth_mm = cam.read()

        except Exception as e:
            print("Camera error:", e)
            continue

        # -----------------------------------------
        # USE GITHUB NAVIGATION LOGIC
        # -----------------------------------------

        left_m, center_m, right_m = analyze_depth_zones(depth_mm)

        decision = nav.step(
            (left_m, center_m, right_m)
        )

        status = decision["status"]

        # -----------------------------------------
        # Draw navigation zones
        # -----------------------------------------

        h, w = color.shape[:2]

        y0 = int(h * BAND_TOP_FRAC)
        y1 = int(h * BAND_BOT_FRAC)

        zone_width = w // 3

        # Bounding area used for depth navigation
        cv2.rectangle(
            color,
            (0, y0),
            (w - 1, y1),
            (255, 255, 255),
            2
        )

        # Left / center / right dividers
        cv2.line(
            color,
            (zone_width, y0),
            (zone_width, y1),
            (255, 255, 255),
            2
        )

        cv2.line(
            color,
            (zone_width * 2, y0),
            (zone_width * 2, y1),
            (255, 255, 255),
            2
        )

        # -----------------------------------------
        # Distance labels
        # -----------------------------------------

        cv2.putText(
            color,
            "LEFT",
            (20, y0 + 25),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (255, 255, 255),
            2
        )

        cv2.putText(
            color,
            distance_text(left_m),
            (20, y0 + 50),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (255, 255, 255),
            2
        )

        cv2.putText(
            color,
            "CENTER",
            (zone_width + 20, y0 + 25),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (255, 255, 255),
            2
        )

        cv2.putText(
            color,
            distance_text(center_m),
            (zone_width + 20, y0 + 50),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (255, 255, 255),
            2
        )

        cv2.putText(
            color,
            "RIGHT",
            (zone_width * 2 + 20, y0 + 25),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (255, 255, 255),
            2
        )

        cv2.putText(
            color,
            distance_text(right_m),
            (zone_width * 2 + 20, y0 + 50),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (255, 255, 255),
            2
        )

        # -----------------------------------------
        # Navigation status
        # -----------------------------------------

        if status == "STOP":
            status_color = (0, 0, 255)

        elif status == "AVOID":
            status_color = (0, 165, 255)

        else:
            status_color = (0, 255, 0)

        cv2.putText(
            color,
            f"NAV: {status}",
            (20, 40),
            cv2.FONT_HERSHEY_SIMPLEX,
            1,
            status_color,
            3
        )

        cv2.putText(
            color,
            f"Throttle: {decision['throttle']:.2f}  "
            f"Steer: {decision['steer']:+.2f}",
            (20, 75),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            status_color,
            2
        )

        # -----------------------------------------
        # JPEG compression for browser
        # -----------------------------------------

        success, buffer = cv2.imencode(
            ".jpg",
            color,
            [cv2.IMWRITE_JPEG_QUALITY, 70]
        )

        if not success:
            continue

        frame = buffer.tobytes()

        yield (
            b"--frame\r\n"
            b"Content-Type: image/jpeg\r\n\r\n"
            + frame +
            b"\r\n"
        )


@app.route("/")
def index():

    return """
    <html>
        <head>
            <title>Delivery Rover Navigation</title>
        </head>

        <body>
            <h1>Delivery Rover Navigation</h1>

            <img src="/video_feed"
                 width="640"
                 height="480">

        </body>
    </html>
    """


@app.route("/video_feed")
def video_feed():

    return Response(
        generate_frames(),
        mimetype="multipart/x-mixed-replace; boundary=frame"
    )


if __name__ == "__main__":

    app.run(
        host="0.0.0.0",
        port=5000,
        threaded=True
    )
