"""
MadhurVision — Unified Camera Manager
=======================================
Provides a single interface to get frames regardless of source (WebRTC/local webcam).
Manages camera lifecycle, thread-safe frame delivery, and automatic fallback.
"""

import threading
import time
import logging
from typing import Optional

import cv2
import numpy as np

from configs.settings import settings
from cameras.frame_buffer import FrameBuffer, FrameData

logger = logging.getLogger("MadhurVision.CameraManager")


class CameraManager:
    """
    Unified camera abstraction.
    
    Handles both local webcam and WebRTC sources behind a single interface.
    Runs capture in a background thread to keep the main render loop responsive.
    
    Usage:
        cam = CameraManager()
        cam.start()
        
        # In render loop:
        frame_data = cam.get_frame()
        if frame_data:
            cv2.imshow("feed", frame_data.frame)
        
        cam.stop()
    """

    def __init__(self):
        self._buffer = FrameBuffer(max_size=5)
        self._capture: Optional[cv2.VideoCapture] = None
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._source = settings.camera.source
        # Remote servers
        self._webrtc_server = None
        self._native_server = None

    def set_webrtc_server(self, server) -> None:
        """Attach a WebRTC server for remote camera feed."""
        self._webrtc_server = server
        self._source = "webrtc"
        
    def set_native_server(self, server) -> None:
        """Attach a Native iOS TCP server for remote camera feed."""
        self._native_server = server
        self._source = "native"

    def push_frame(self, frame_data: FrameData) -> None:
        """External push for WebRTC/Native or any remote source."""
        self._buffer.push(frame_data)

    def start(self) -> None:
        """Start capturing frames in a background thread."""
        if self._running:
            logger.warning("CameraManager already running")
            return

        self._running = True

        if self._source == "local":
            self._start_local_camera()
        elif self._source == "webrtc":
            # WebRTC frames are pushed externally via push_frame()
            logger.info("CameraManager: Waiting for WebRTC frames...")
        else:
            logger.error(f"Unknown camera source: {self._source}")
            # Fallback to local
            logger.info("Falling back to local camera")
            self._source = "local"
            self._start_local_camera()

    def _start_local_camera(self) -> None:
        """Initialize local webcam capture in background thread."""
        cam_index = settings.camera.local_camera_index
        logger.info(f"Opening local camera (index={cam_index})")

        self._capture = cv2.VideoCapture(cam_index)
        if not self._capture.isOpened():
            logger.error(f"Failed to open camera index {cam_index}")
            self._running = False
            return

        # Set resolution
        w, h = settings.camera.resolution
        self._capture.set(cv2.CAP_PROP_FRAME_WIDTH, w)
        self._capture.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
        self._capture.set(cv2.CAP_PROP_FPS, settings.camera.fps)

        # Read actual resolution
        actual_w = int(self._capture.get(cv2.CAP_PROP_FRAME_WIDTH))
        actual_h = int(self._capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
        logger.info(f"Camera opened: {actual_w}x{actual_h}")

        self._thread = threading.Thread(
            target=self._capture_loop,
            name="CameraCapture",
            daemon=True
        )
        self._thread.start()

    def _capture_loop(self) -> None:
        """Background thread: continuously read frames from local camera."""
        logger.info("Camera capture loop started")
        target_interval = 1.0 / settings.camera.fps

        while self._running:
            start = time.perf_counter()

            ret, frame = self._capture.read()
            if not ret:
                logger.warning("Failed to read frame from camera")
                time.sleep(0.01)
                continue

            # Mirror if configured (useful for development)
            if settings.camera.mirror:
                frame = cv2.flip(frame, 1)

            frame_data = FrameData(
                frame=frame,
                timestamp=time.perf_counter()
            )
            self._buffer.push(frame_data)

            # Maintain target FPS
            elapsed = time.perf_counter() - start
            sleep_time = target_interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)

        logger.info("Camera capture loop stopped")

    def get_frame(self) -> Optional[FrameData]:
        """
        Get the latest frame. Non-blocking.
        
        Returns:
            Latest FrameData, or None if no frames available.
        """
        return self._buffer.get_latest()

    def wait_for_frame(self, timeout: float = 1.0) -> Optional[FrameData]:
        """
        Block until a new frame arrives.
        
        Args:
            timeout: Maximum seconds to wait
            
        Returns:
            Latest FrameData, or None on timeout
        """
        return self._buffer.wait_for_frame(timeout=timeout)

    @property
    def fps(self) -> float:
        """Current camera FPS (measured)."""
        return self._buffer.fps

    @property
    def latency_ms(self) -> float:
        """Latency of the latest frame in ms."""
        return self._buffer.latency_ms

    @property
    def is_active(self) -> bool:
        """Whether camera is actively producing frames."""
        return self._running and not self._buffer.is_empty

    @property
    def source(self) -> str:
        """Current camera source type."""
        return self._source

    def stop(self) -> None:
        """Stop capture and release resources."""
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)
        if self._capture and self._capture.isOpened():
            self._capture.release()
            logger.info("Local camera released")
        self._buffer.clear()
