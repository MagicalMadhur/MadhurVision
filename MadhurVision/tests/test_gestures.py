"""
MadhurVision — Standalone Gesture Recognition Test
Run: python -m tests.test_gestures
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cv2
from configs.settings import settings
from tracking.hand_tracker import HandTracker
from gestures.gesture_events import GestureEventBus, GestureType, GesturePhase
from gestures.gesture_recognizer import GestureRecognizer


def main():
    print("=" * 50)
    print("  Gesture Recognition Test — MadhurVision")
    print("  Press Q to quit")
    print("=" * 50)

    bus = GestureEventBus()
    tracker = HandTracker()
    recognizer = GestureRecognizer(bus)

    # Log all events
    def on_any_gesture(event):
        if event.phase in (GesturePhase.START, GesturePhase.INSTANT):
            print(f"  🎯 {event.gesture_type.name} [{event.phase.name}] "
                  f"hand={event.hand} pos=({event.position[0]:.2f}, {event.position[1]:.2f})")

    bus.subscribe_all(on_any_gesture)

    cap = cv2.VideoCapture(settings.camera.local_camera_index)
    if not cap.isOpened():
        print("ERROR: Cannot open camera")
        return

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame = cv2.flip(frame, 1)
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        hands = tracker.process(rgb)
        frame = tracker.draw_landmarks(frame)

        events = recognizer.update(hands)

        # Display active gestures
        h, w = frame.shape[:2]
        cv2.rectangle(frame, (0, 0), (w, 35), (20, 20, 30), -1)
        cv2.putText(frame, "Gesture Recognition Test", (10, 25),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 255), 2)

        active = recognizer.active_gestures
        for i, g in enumerate(active):
            y = 60 + i * 30
            color = (0, 255, 0) if "START" not in g else (0, 255, 255)
            cv2.putText(frame, f"● {g}", (10, y),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

        if not active:
            cv2.putText(frame, "No active gestures", (10, 60),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.6, (100, 100, 100), 1)

        cv2.imshow("Gesture Test", frame)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    tracker.close()
    cap.release()
    cv2.destroyAllWindows()
    print("Test complete.")


if __name__ == "__main__":
    main()
