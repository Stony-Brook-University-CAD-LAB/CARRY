import cv2
import time

cap = cv2.VideoCapture(0, cv2.CAP_V4L2)

cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
cap.set(cv2.CAP_PROP_FPS, 30)

if not cap.isOpened():
    print("Could not open camera")
    exit()

frame_count = 0
start = time.time()

while frame_count < 300:
    ret, frame = cap.read()

    if not ret:
        print("Failed to read frame")
        break

    frame_count += 1

end = time.time()

elapsed = end - start
fps = frame_count / elapsed

print("Frames captured:", frame_count)
print("Time:", round(elapsed, 2), "seconds")
print("Actual FPS:", round(fps, 2))

cap.release()
