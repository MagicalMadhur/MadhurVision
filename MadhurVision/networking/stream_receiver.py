"""
MadhurVision — Stream Receiver
================================
Decodes and processes incoming video frames and orientation data
from the WebRTC connection. Provides latency tracking and frame statistics.
"""

import time
import logging
from collections import deque
from typing import Optional, Dict

import numpy as np

logger = logging.getLogger("MadhurVision.StreamReceiver")


class StreamReceiver:
    """
    Processes and tracks statistics for incoming WebRTC streams.
    
    Works alongside WebRTCServer to provide:
    - Frame decode verification
    - Latency measurement
    - Orientation data smoothing
    - Connection quality metrics
    """

    def __init__(self):
        self._frame_count: int = 0
        self._orientation_count: int = 0
        self._latency_samples: deque = deque(maxlen=120)
        self._last_frame_time: float = 0.0
        self._last_orientation: Dict[str, float] = {
            "yaw": 0.0, "pitch": 0.0, "roll": 0.0
        }
        # Smoothed orientation (complementary filter applied)
        self._smoothed_orientation: Dict[str, float] = {
            "yaw": 0.0, "pitch": 0.0, "roll": 0.0
        }
        self._smooth_alpha: float = 0.85  # Higher = more smoothing

    def process_frame(self, frame: np.ndarray, timestamp: float) -> np.ndarray:
        """
        Process an incoming video frame.
        
        Args:
            frame: BGR numpy array
            timestamp: Time the frame was captured
            
        Returns:
            Processed frame (currently passthrough, can add corrections)
        """
        self._frame_count += 1

        # Track latency
        latency_ms = (time.perf_counter() - timestamp) * 1000.0
        self._latency_samples.append(latency_ms)
        self._last_frame_time = time.perf_counter()

        return frame

    def process_orientation(self, data: Dict[str, float]) -> Dict[str, float]:
        """
        Process orientation data with smoothing filter.
        
        Args:
            data: Dict with yaw, pitch, roll in radians
            
        Returns:
            Smoothed orientation dict
        """
        self._orientation_count += 1
        alpha = self._smooth_alpha

        for axis in ("yaw", "pitch", "roll"):
            raw = data.get(axis, 0.0)
            prev = self._smoothed_orientation[axis]
            self._smoothed_orientation[axis] = alpha * prev + (1 - alpha) * raw

        self._last_orientation = data
        return self._smoothed_orientation.copy()

    @property
    def avg_latency_ms(self) -> float:
        """Average frame latency in milliseconds."""
        if not self._latency_samples:
            return 0.0
        return sum(self._latency_samples) / len(self._latency_samples)

    @property
    def frame_count(self) -> int:
        """Total frames received."""
        return self._frame_count

    @property
    def smoothed_orientation(self) -> Dict[str, float]:
        """Current smoothed orientation."""
        return self._smoothed_orientation.copy()

    @property
    def connection_quality(self) -> str:
        """Connection quality assessment based on latency."""
        avg = self.avg_latency_ms
        if avg < 20:
            return "excellent"
        elif avg < 50:
            return "good"
        elif avg < 100:
            return "fair"
        else:
            return "poor"
