"""
MadhurVision — Thread-Safe Frame Buffer
========================================
Ring buffer for camera frames with timestamp tracking.
Ensures low-latency frame delivery between producer (camera) and consumer (render) threads.
"""

import threading
import time
from dataclasses import dataclass, field
from collections import deque
from typing import Optional, Dict, Any

import numpy as np


@dataclass
class FrameData:
    """
    Container for a single captured frame with metadata.
    
    Attributes:
        frame: BGR numpy array (H, W, 3) — OpenCV convention
        timestamp: Time of capture (time.perf_counter)
        frame_id: Monotonically increasing frame counter
        orientation: Dict with yaw, pitch, roll from phone gyroscope (radians)
        depth_data: Optional raw depth data from LiDAR or depth sensor
        metadata: Any additional sensor data (accelerometer, etc.)
    """
    frame: np.ndarray
    timestamp: float = field(default_factory=time.perf_counter)
    frame_id: int = 0
    orientation: Optional[Dict[str, float]] = None
    depth_data: Optional[np.ndarray] = None
    metadata: Optional[Dict[str, Any]] = None


class FrameBuffer:
    """
    Thread-safe ring buffer for camera frames.
    
    Holds the latest N frames in a deque. The producer thread (camera/network)
    pushes frames, and the consumer thread (render loop) reads the latest.
    
    Usage:
        buffer = FrameBuffer(max_size=5)
        
        # Producer thread:
        buffer.push(FrameData(frame=bgr_array))
        
        # Consumer thread:
        frame_data = buffer.get_latest()
        if frame_data is not None:
            process(frame_data.frame)
    """

    def __init__(self, max_size: int = 5):
        """
        Args:
            max_size: Maximum number of frames to keep. Oldest are discarded.
                      Small values (3-5) minimize latency. Large values allow
                      temporal analysis but increase memory.
        """
        self._buffer: deque = deque(maxlen=max_size)
        self._lock = threading.Lock()
        self._frame_counter: int = 0
        self._new_frame_event = threading.Event()
        # Performance tracking
        self._push_times: deque = deque(maxlen=60)
        self._last_push_time: float = 0.0

    def push(self, frame_data: FrameData) -> None:
        """
        Push a new frame into the buffer. Thread-safe.
        Automatically assigns frame_id and timestamp if not set.
        
        Args:
            frame_data: FrameData to store
        """
        with self._lock:
            self._frame_counter += 1
            frame_data.frame_id = self._frame_counter
            if frame_data.timestamp == 0:
                frame_data.timestamp = time.perf_counter()
            
            self._buffer.append(frame_data)
            
            # Track push rate
            now = time.perf_counter()
            if self._last_push_time > 0:
                self._push_times.append(now - self._last_push_time)
            self._last_push_time = now
        
        # Signal any waiting consumers
        self._new_frame_event.set()

    def get_latest(self) -> Optional[FrameData]:
        """
        Get the most recent frame without removing it. Thread-safe.
        
        Returns:
            Most recent FrameData, or None if buffer is empty.
        """
        with self._lock:
            if len(self._buffer) == 0:
                return None
            return self._buffer[-1]

    def get_latest_and_clear(self) -> Optional[FrameData]:
        """
        Get the most recent frame and clear older ones. Thread-safe.
        Useful when you only care about the latest frame and want to
        minimize memory usage.
        
        Returns:
            Most recent FrameData, or None if buffer is empty.
        """
        with self._lock:
            if len(self._buffer) == 0:
                return None
            latest = self._buffer[-1]
            self._buffer.clear()
            self._buffer.append(latest)
            return latest

    def wait_for_frame(self, timeout: float = 1.0) -> Optional[FrameData]:
        """
        Block until a new frame arrives or timeout expires.
        
        Args:
            timeout: Maximum seconds to wait
            
        Returns:
            Latest FrameData, or None if timeout
        """
        self._new_frame_event.clear()
        if self._new_frame_event.wait(timeout=timeout):
            return self.get_latest()
        return self.get_latest()  # Return whatever we have, even if stale

    @property
    def size(self) -> int:
        """Current number of frames in buffer."""
        with self._lock:
            return len(self._buffer)

    @property
    def is_empty(self) -> bool:
        """Whether buffer has no frames."""
        with self._lock:
            return len(self._buffer) == 0

    @property
    def fps(self) -> float:
        """Estimated frames-per-second based on push rate."""
        with self._lock:
            if len(self._push_times) < 2:
                return 0.0
            avg_interval = sum(self._push_times) / len(self._push_times)
            return 1.0 / avg_interval if avg_interval > 0 else 0.0

    @property
    def latency_ms(self) -> float:
        """Latency of the latest frame in milliseconds."""
        with self._lock:
            if len(self._buffer) == 0:
                return 0.0
            latest = self._buffer[-1]
            return (time.perf_counter() - latest.timestamp) * 1000.0

    def clear(self) -> None:
        """Clear all frames from the buffer."""
        with self._lock:
            self._buffer.clear()
            self._new_frame_event.clear()
