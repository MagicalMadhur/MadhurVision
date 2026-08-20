"""
MadhurVision — Standalone Hand Tracking Test
Run: python -m tests.test_hand_tracking
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cv2
from configs.settings import settings
from tracking.hand_tracker import HandTracker


def main():
    print("=" * 50)
    print("  Hand Tracking Test — MadhurVision")
    print("  Press Q to quit")
    print("=" * 50)

    tracker = HandTracker()
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

        # Display info
        h, w = frame.shape[:2]
        cv2.putText(frame, f"Hands: {len(hands)}", (10, 30),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)

        for i, hand in enumerate(hands):
            y = 60 + i * 90
            pinch = tracker.pinch_distance(hand)
            grab = tracker.grab_score(hand)
            fingers = hand.finger_is_extended()
            ext_count = sum(fingers)

            cv2.putText(frame, f"{hand.handedness}:", (10, y),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 200, 0), 2)
            cv2.putText(frame, f"  Pinch: {pinch:.3f}", (10, y + 20),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
            cv2.putText(frame, f"  Grab: {grab:.2f}", (10, y + 40),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
            cv2.putText(frame, f"  Fingers: {ext_count}/5", (10, y + 60),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

            # Pinch indicator
            if pinch < settings.gesture.pinch_threshold:
                cv2.putText(frame, "PINCH!", (w - 200, y),
                           cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 0), 3)

        cv2.imshow("Hand Tracking Test", frame)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    tracker.close()
    cap.release()
    cv2.destroyAllWindows()
    print("Test complete.")


if __name__ == "__main__":
    main()
