"""
Motor driver wrapper.

Starts in DRY_RUN mode so nothing moves until you explicitly enable motors.
"""

DRY_RUN = True

MAX_SPEED = 1.0
MIN_SPEED = -1.0


def clamp(x, lo=MIN_SPEED, hi=MAX_SPEED):
    return max(lo, min(hi, x))


class MotorDriver:
    def __init__(self):
        if DRY_RUN:
            print("[MOTOR] DRY_RUN enabled. Motors will not move.")
        else:
            print("[MOTOR] LIVE mode enabled.")

            # TODO: put real motor setup here
            # Example if using JetBot:
            # from jetbot import Robot
            # self.robot = Robot()

    def drive(self, throttle, steer):
        left = clamp(throttle - steer)
        right = clamp(throttle + steer)

        print(f"[MOTOR] throttle={throttle:+.2f} steer={steer:+.2f} | left={left:+.2f} right={right:+.2f}")

        if DRY_RUN:
            return left, right

        # TODO: uncomment/change based on your motor library
        # self.robot.left_motor.value = left
        # self.robot.right_motor.value = right

        return left, right

    def stop(self):
        print("[MOTOR] STOP")

        if DRY_RUN:
            return

        # TODO: real stop command
        # self.robot.stop()
