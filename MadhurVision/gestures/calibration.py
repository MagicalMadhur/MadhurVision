"""
MadhurVision — Gesture Calibration
=====================================
Interactive calibration screen for tuning gesture thresholds.
Guides the user through performing each gesture and records optimal distances.
"""

import json
import os
import time
import logging
from typing import Dict, Optional

import cv2
import numpy as np

from tracking.hand_tracker import HandTracker, HandData
from configs.settings import settings

logger = logging.getLogger("MadhurVision.Calibration")


class GestureCalibrator:
    """
    Interactive gesture calibration.
    
    Opens a webcam window and guides the user through performing each gesture.
    Records the distance/velocity values and saves calibrated thresholds to JSON.
    
    Usage:
        calibrator = GestureCalibrator()
        calibrator.run()
        # Follow on-screen instructions
        # Results saved to configs/calibration.json
    """

    STEPS = [
        {
            "name": "PINCH",
            "instruction": "Pinch your thumb and index finger together",
            "measure": "pinch_distance",
            "samples_needed": 30,
        },
        {
            "name": "PINCH_RELEASE",
            "instruction": "Now slowly open your thumb and index finger",
            "measure": "pinch_release",
            "samples_needed": 20,
        },
        {
            "name": "GRAB",
            "instruction": "Close your hand into a fist (grab gesture)",
            "measure": "grab_score",
            "samples_needed": 30,
        },
        {
            "name": "OPEN_PALM",
            "instruction": "Open your hand fully with all fingers extended",
            "measure": "open_palm",
            "samples_needed": 30,
        },
    ]

    def __init__(self):
        self._tracker = HandTracker()
        self._samples: Dict[str, list] = {}
        self._current_step = 0
        self._collecting = False
        self._collected_count = 0

    def run(self) -> Optional[Dict]:
        """
        Run interactive calibration with webcam.
        
        Returns:
            Dict of calibrated thresholds, or None if cancelled.
        """
        cap = cv2.VideoCapture(settings.camera.local_camera_index)
        if not cap.isOpened():
            logger.error("Cannot open camera for calibration")
            return None

        logger.info("Starting gesture calibration...")
        results = {}

        while self._current_step < len(self.STEPS):
            step = self.STEPS[self._current_step]
            step_name = step["name"]

            if step_name not in self._samples:
                self._samples[step_name] = []
                self._collecting = False
                self._collected_count = 0

            ret, frame = cap.read()
            if not ret:
                continue

            if settings.camera.mirror:
                frame = cv2.flip(frame, 1)

            # Process hand tracking
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            hands = self._tracker.process(rgb)
            frame = self._tracker.draw_landmarks(frame)

            # Draw UI
            h, w = frame.shape[:2]
            overlay = frame.copy()

            # Header bar
            cv2.rectangle(overlay, (0, 0), (w, 80), (20, 20, 30), -1)
            cv2.addWeighted(overlay, 0.8, frame, 0.2, 0, frame)

            # Step counter
            cv2.putText(frame, f"Step {self._current_step + 1}/{len(self.STEPS)}",
                       (20, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (150, 150, 200), 2)

            # Instruction
            cv2.putText(frame, step["instruction"],
                       (20, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (200, 200, 255), 1)

            # Progress bar
            progress = self._collected_count / step["samples_needed"]
            bar_width = int(w * 0.6)
            bar_x = (w - bar_width) // 2
            cv2.rectangle(frame, (bar_x, h - 40), (bar_x + bar_width, h - 20),
                         (50, 50, 60), -1)
            cv2.rectangle(frame, (bar_x, h - 40),
                         (bar_x + int(bar_width * progress), h - 20),
                         (100, 200, 100), -1)
            cv2.putText(frame, f"{self._collected_count}/{step['samples_needed']}",
                       (bar_x + bar_width + 10, h - 25),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

            # Collect samples when hand is detected
            if hands and len(hands) > 0:
                hand = hands[0]

                if step["measure"] == "pinch_distance":
                    value = HandTracker.pinch_distance(hand)
                    cv2.putText(frame, f"Pinch dist: {value:.4f}",
                               (20, h - 60), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                               (100, 255, 100), 2)
                elif step["measure"] == "pinch_release":
                    value = HandTracker.pinch_distance(hand)
                    cv2.putText(frame, f"Release dist: {value:.4f}",
                               (20, h - 60), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                               (100, 255, 100), 2)
                elif step["measure"] == "grab_score":
                    value = HandTracker.grab_score(hand)
                    cv2.putText(frame, f"Grab score: {value:.4f}",
                               (20, h - 60), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                               (100, 255, 100), 2)
                elif step["measure"] == "open_palm":
                    fingers = hand.finger_is_extended()
                    value = sum(fingers) / 5.0
                    cv2.putText(frame, f"Open score: {value:.2f} ({sum(fingers)}/5 fingers)",
                               (20, h - 60), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                               (100, 255, 100), 2)

                if self._collecting:
                    self._samples[step_name].append(value)
                    self._collected_count += 1

                    if self._collected_count >= step["samples_needed"]:
                        # Process samples
                        samples = self._samples[step_name]
                        results[step_name] = {
                            "mean": sum(samples) / len(samples),
                            "min": min(samples),
                            "max": max(samples),
                            "samples": len(samples)
                        }
                        logger.info(f"Calibrated {step_name}: mean={results[step_name]['mean']:.4f}")
                        self._current_step += 1
                        continue

            # Instructions at bottom
            if not self._collecting:
                cv2.putText(frame, "Press SPACE to start recording | ESC to cancel",
                           (20, h - 80), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                           (180, 180, 180), 1)

            cv2.imshow("Madhur Vision - Calibration", frame)
            key = cv2.waitKey(1) & 0xFF

            if key == 27:  # ESC
                logger.info("Calibration cancelled")
                cap.release()
                cv2.destroyAllWindows()
                return None
            elif key == 32:  # SPACE
                self._collecting = True

        cap.release()
        cv2.destroyAllWindows()

        # Calculate and save thresholds
        thresholds = self._calculate_thresholds(results)
        self._save_calibration(thresholds)
        return thresholds

    def _calculate_thresholds(self, results: Dict) -> Dict:
        """Calculate optimal thresholds from calibration data."""
        thresholds = {}

        if "PINCH" in results:
            # Pinch threshold = mean pinch distance + small margin
            thresholds["pinch_threshold"] = results["PINCH"]["mean"] * 1.3

        if "PINCH_RELEASE" in results:
            # Release threshold should be higher than pinch threshold
            thresholds["pinch_release_threshold"] = results["PINCH_RELEASE"]["mean"] * 0.8

        if "GRAB" in results:
            thresholds["grab_threshold"] = results["GRAB"]["mean"] * 0.85

        logger.info(f"Calculated thresholds: {thresholds}")
        return thresholds

    def _save_calibration(self, thresholds: Dict) -> None:
        """Save calibration results to JSON file."""
        path = settings.gesture.calibration_path
        os.makedirs(os.path.dirname(path), exist_ok=True)

        data = {
            "thresholds": thresholds,
            "calibrated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "raw_samples": {k: {"mean": v} for k, v in 
                          self._samples.items() if v}
        }

        with open(path, 'w') as f:
            json.dump(data, f, indent=2)

        logger.info(f"Calibration saved to {path}")

        # Apply to active settings
        for key, value in thresholds.items():
            if hasattr(settings.gesture, key):
                setattr(settings.gesture, key, value)
                logger.info(f"  Applied {key} = {value:.4f}")


def run_calibration():
    """Entry point for standalone calibration."""
    logging.basicConfig(level=logging.INFO)
    calibrator = GestureCalibrator()
    result = calibrator.run()
    if result:
        print("\n✅ Calibration complete!")
        for k, v in result.items():
            print(f"  {k}: {v:.4f}")
    else:
        print("\n❌ Calibration cancelled")


if __name__ == "__main__":
    run_calibration()
