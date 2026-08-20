"""
MadhurVision — Screen Capture
================================
Captures Windows desktop screen using MSS for fast, low-latency capture.
Outputs frames suitable for OpenGL texture upload.
"""

import threading
import time
import logging
from typing import Optional

import numpy as np

logger = logging.getLogger("MadhurVision.ScreenCapture")

try:
    import mss
    import mss.tools
    MSS_AVAILABLE = True
except ImportError:
    MSS_AVAILABLE = False
    logger.warning("MSS not installed. Screen capture disabled.")
    logger.warning("Install with: pip install mss")

from configs.settings import settings


class ScreenCapture:
    """
    High-performance screen capture using MSS.
    
    Captures the desktop or a specific monitor at configurable FPS.
    Runs in a background thread to keep the render loop responsive.
    
    Usage:
        capture = ScreenCapture()
        capture.start()
        
        # In render loop:
        frame = capture.get_frame()
        if frame is not None:
            engine.update_texture(tex_id, frame)
        
        capture.stop()
    """

    def __init__(self, monitor: int = None):
        """
        Args:
            monitor: Monitor index (0=all, 1=primary, 2=secondary, etc.)
                    Defaults to settings.desktop.monitor_index
        """
        if not MSS_AVAILABLE:
            raise RuntimeError("MSS not installed. Run: pip install mss")

        self._monitor = monitor or settings.desktop.monitor_index
        self._fps_target = settings.desktop.capture_fps
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._latest_frame: Optional[np.ndarray] = None
        self._frame_count = 0

    def start(self) -> None:
        """Start background screen capture thread."""
        if self._running:
            return

        self._running = True
        self._thread = threading.Thread(
            target=self._capture_loop,
            name="ScreenCapture",
            daemon=True
        )
        self._thread.start()
        logger.info(f"ScreenCapture started (monitor={self._monitor}, "
                    f"target={self._fps_target}fps)")

    def _capture_loop(self) -> None:
        """Background thread: continuously capture screen."""
        interval = 1.0 / self._fps_target

        with mss.mss() as sct:
            # Get monitor info
            monitors = sct.monitors
            if self._monitor >= len(monitors):
                logger.error(f"Monitor {self._monitor} not found, using primary")
                self._monitor = 1

            monitor = monitors[self._monitor]
            logger.info(f"Capturing monitor {self._monitor}: "
                       f"{monitor['width']}x{monitor['height']}")

            while self._running:
                start = time.perf_counter()

                # Capture screen
                shot = sct.grab(monitor)

                # Convert to numpy BGR array (MSS gives BGRA)
                frame = np.frombuffer(shot.raw, dtype=np.uint8)
                frame = frame.reshape((shot.height, shot.width, 4))
                # Drop alpha channel → BGR
                frame = frame[:, :, :3].copy()

                with self._lock:
                    self._latest_frame = frame
                    self._frame_count += 1

                # Maintain target FPS
                elapsed = time.perf_counter() - start
                sleep_time = interval - elapsed
                if sleep_time > 0:
                    time.sleep(sleep_time)

        logger.info("ScreenCapture loop stopped")

    def get_frame(self) -> Optional[np.ndarray]:
        """Get the latest captured frame (BGR numpy array)."""
        with self._lock:
            return self._latest_frame

    @property
    def frame_count(self) -> int:
        return self._frame_count

    @property
    def is_active(self) -> bool:
        return self._running and self._latest_frame is not None

    def stop(self) -> None:
        """Stop capture thread."""
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)
        logger.info("ScreenCapture stopped")
