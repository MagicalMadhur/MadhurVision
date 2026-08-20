"""
MadhurVision — Hand Tracker
=============================
MediaPipe Hands wrapper for real-time 21-landmark hand tracking.
Supports both hands simultaneously with handedness classification.
"""

import logging
from dataclasses import dataclass, field
from typing import List, Optional, Tuple

import numpy as np
import cv2

logger = logging.getLogger("MadhurVision.HandTracker")

try:
    import mediapipe as mp
    MEDIAPIPE_AVAILABLE = True
except ImportError:
    MEDIAPIPE_AVAILABLE = False
    logger.warning("MediaPipe not installed. Hand tracking disabled.")
    logger.warning("Install with: pip install mediapipe")


@dataclass
class Landmark:
    """Single hand landmark with 3D coordinates (normalized 0-1)."""
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0  # Depth relative to wrist

    def to_tuple(self) -> Tuple[float, float, float]:
        return (self.x, self.y, self.z)

    def to_pixel(self, width: int, height: int) -> Tuple[int, int]:
        """Convert normalized coords to pixel coordinates."""
        return (int(self.x * width), int(self.y * height))


@dataclass
class HandData:
    """
    Complete data for one detected hand.
    
    Landmark indices (MediaPipe convention):
        0: WRIST
        1-4: THUMB (CMC, MCP, IP, TIP)
        5-8: INDEX (MCP, PIP, DIP, TIP)
        9-12: MIDDLE (MCP, PIP, DIP, TIP)
        13-16: RING (MCP, PIP, DIP, TIP)
        17-20: PINKY (MCP, PIP, DIP, TIP)
    """
    landmarks: List[Landmark] = field(default_factory=lambda: [Landmark() for _ in range(21)])
    handedness: str = "Right"  # "Left" or "Right"
    confidence: float = 0.0
    
    # Convenience properties for commonly used landmarks
    @property
    def wrist(self) -> Landmark:
        return self.landmarks[0]

    @property
    def thumb_tip(self) -> Landmark:
        return self.landmarks[4]

    @property
    def index_tip(self) -> Landmark:
        return self.landmarks[8]

    @property
    def middle_tip(self) -> Landmark:
        return self.landmarks[12]

    @property
    def ring_tip(self) -> Landmark:
        return self.landmarks[16]

    @property
    def pinky_tip(self) -> Landmark:
        return self.landmarks[20]

    @property
    def index_mcp(self) -> Landmark:
        """Index finger base (metacarpophalangeal joint)."""
        return self.landmarks[5]

    @property
    def palm_center(self) -> Landmark:
        """Approximate palm center (average of wrist and middle MCP)."""
        w = self.wrist
        m = self.landmarks[9]  # Middle MCP
        return Landmark(
            x=(w.x + m.x) / 2,
            y=(w.y + m.y) / 2,
            z=(w.z + m.z) / 2
        )

    def fingertip_distances_to_palm(self) -> List[float]:
        """Distance from each fingertip to palm center."""
        palm = self.palm_center
        tips = [self.thumb_tip, self.index_tip, self.middle_tip,
                self.ring_tip, self.pinky_tip]
        return [
            ((t.x - palm.x)**2 + (t.y - palm.y)**2 + (t.z - palm.z)**2)**0.5
            for t in tips
        ]

    def finger_is_extended(self) -> List[bool]:
        """
        Check if each finger is extended (straightened).
        Returns [thumb, index, middle, ring, pinky].
        Uses comparison of tip position vs PIP/IP joint position.
        """
        # Thumb: compare tip.x to IP.x (depends on handedness)
        if self.handedness == "Right":
            thumb_ext = self.landmarks[4].x < self.landmarks[3].x
        else:
            thumb_ext = self.landmarks[4].x > self.landmarks[3].x

        # Other fingers: tip.y < pip.y means extended (in image coords, y increases downward)
        index_ext = self.landmarks[8].y < self.landmarks[6].y
        middle_ext = self.landmarks[12].y < self.landmarks[10].y
        ring_ext = self.landmarks[16].y < self.landmarks[14].y
        pinky_ext = self.landmarks[20].y < self.landmarks[18].y

        return [thumb_ext, index_ext, middle_ext, ring_ext, pinky_ext]


class HandTracker:
    """
    Real-time hand tracking using MediaPipe Hands.
    
    Processes RGB frames and returns HandData for each detected hand (up to 2).
    
    Usage:
        tracker = HandTracker()
        
        # In processing loop:
        hands = tracker.process(rgb_frame)
        for hand in hands:
            print(f"{hand.handedness}: index tip at {hand.index_tip.x:.2f}, {hand.index_tip.y:.2f}")
            print(f"  Pinch distance: {tracker.pinch_distance(hand):.3f}")
    """

    # MediaPipe landmark connections for drawing
    CONNECTIONS = None  # Set in __init__ if MediaPipe available

    def __init__(self):
        if not MEDIAPIPE_AVAILABLE:
            raise RuntimeError("MediaPipe not installed. Run: pip install mediapipe")

        from configs.settings import settings

        self._mp_hands = mp.solutions.hands
        self._mp_drawing = mp.solutions.drawing_utils
        self._mp_styles = mp.solutions.drawing_styles

        self._hands = self._mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=settings.tracking.max_num_hands,
            min_detection_confidence=settings.tracking.min_detection_confidence,
            min_tracking_confidence=settings.tracking.min_tracking_confidence,
            model_complexity=1  # 0=lite, 1=full
        )

        HandTracker.CONNECTIONS = self._mp_hands.HAND_CONNECTIONS

        self._last_results = None
        self._frame_count = 0
        logger.info(
            f"HandTracker initialized (max_hands={settings.tracking.max_num_hands}, "
            f"det_conf={settings.tracking.min_detection_confidence})"
        )

    def process(self, rgb_frame: np.ndarray) -> List[HandData]:
        """
        Process an RGB frame and detect hands.
        
        Args:
            rgb_frame: RGB numpy array (H, W, 3). NOTE: Must be RGB, not BGR!
                      Convert with: cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        
        Returns:
            List of HandData, one per detected hand (0-2 items).
        """
        self._frame_count += 1

        # MediaPipe requires writable=False for performance
        rgb_frame.flags.writeable = False
        results = self._mp_hands.Hands.process(self._hands, rgb_frame)
        rgb_frame.flags.writeable = True

        self._last_results = results
        hands: List[HandData] = []

        if results.multi_hand_landmarks and results.multi_handedness:
            for hand_landmarks, handedness_info in zip(
                results.multi_hand_landmarks,
                results.multi_handedness
            ):
                hand = HandData()

                # Extract handedness
                classification = handedness_info.classification[0]
                hand.handedness = classification.label
                hand.confidence = classification.score

                # Extract 21 landmarks
                for i, lm in enumerate(hand_landmarks.landmark):
                    hand.landmarks[i] = Landmark(x=lm.x, y=lm.y, z=lm.z)

                hands.append(hand)

        return hands

    def draw_landmarks(
        self,
        frame: np.ndarray,
        hands: Optional[List[HandData]] = None,
        draw_connections: bool = True
    ) -> np.ndarray:
        """
        Draw hand landmarks on a BGR frame for visualization.
        
        Args:
            frame: BGR frame to draw on (modified in-place and returned)
            hands: HandData list (if None, uses last results)
            draw_connections: Whether to draw bones between landmarks
            
        Returns:
            Frame with landmarks drawn
        """
        if self._last_results and self._last_results.multi_hand_landmarks:
            for hand_landmarks in self._last_results.multi_hand_landmarks:
                if draw_connections:
                    self._mp_drawing.draw_landmarks(
                        frame,
                        hand_landmarks,
                        self._mp_hands.HAND_CONNECTIONS,
                        self._mp_styles.get_default_hand_landmarks_style(),
                        self._mp_styles.get_default_hand_connections_style()
                    )
                else:
                    self._mp_drawing.draw_landmarks(
                        frame, hand_landmarks, None
                    )
        return frame

    @staticmethod
    def pinch_distance(hand: HandData) -> float:
        """
        Calculate distance between thumb tip and index tip.
        Used for pinch gesture detection.
        
        Returns:
            Euclidean distance in normalized coordinates.
            Typical pinch threshold: < 0.05
        """
        t = hand.thumb_tip
        i = hand.index_tip
        return ((t.x - i.x)**2 + (t.y - i.y)**2 + (t.z - i.z)**2) ** 0.5

    @staticmethod
    def grab_score(hand: HandData) -> float:
        """
        Calculate how 'grabbed' the hand is (0=open, 1=fully closed).
        Based on average fingertip-to-palm distance.
        """
        distances = hand.fingertip_distances_to_palm()
        avg_dist = sum(distances) / len(distances)
        # Normalize: ~0.25 is open, ~0.05 is closed
        score = 1.0 - min(max((avg_dist - 0.05) / 0.20, 0.0), 1.0)
        return score

    @property
    def frame_count(self) -> int:
        return self._frame_count

    def close(self) -> None:
        """Release MediaPipe resources."""
        self._hands.close()
        logger.info("HandTracker closed")
