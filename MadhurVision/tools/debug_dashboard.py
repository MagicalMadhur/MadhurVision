"""
MadhurVision — Debug Dashboard
==================================
Real-time OpenCV debug overlay showing camera feed, depth map,
hand landmarks, gesture state, and FPS graph.

Usage:
    dashboard = DebugDashboard()
    
    # In main loop:
    dashboard.update(frame, depth_map, hands, gestures, fps)
    dashboard.show()  # Press 'D' to toggle
"""

import time
import logging
from collections import deque
from typing import List, Optional, Dict

import cv2
import numpy as np

from configs.settings import settings

logger = logging.getLogger("MadhurVision.DebugDashboard")


class DebugDashboard:
    """
    Multi-panel debug visualization window.
    
    Panels:
        Top-left: Camera feed with hand landmarks
        Top-right: Depth map (colored)
        Bottom-left: Gesture state + active gestures
        Bottom-right: Performance metrics + FPS graph
    """

    PANEL_WIDTH = 480
    PANEL_HEIGHT = 270

    def __init__(self):
        self._visible = settings.debug.enabled
        self._fps_history: deque = deque(maxlen=120)
        self._latency_history: deque = deque(maxlen=120)
        self._last_frame: Optional[np.ndarray] = None
        self._last_depth: Optional[np.ndarray] = None
        self._gesture_text: List[str] = []
        self._info: Dict[str, str] = {}

    def update(
        self,
        camera_frame: Optional[np.ndarray] = None,
        depth_map: Optional[np.ndarray] = None,
        active_gestures: Optional[List[str]] = None,
        fps: float = 0.0,
        latency: float = 0.0,
        info: Optional[Dict[str, str]] = None
    ) -> None:
        """Update dashboard data."""
        self._last_frame = camera_frame
        self._last_depth = depth_map
        self._gesture_text = active_gestures or []
        self._fps_history.append(fps)
        self._latency_history.append(latency)
        self._info = info or {}

    def show(self) -> None:
        """Render and display the debug dashboard."""
        if not self._visible:
            return

        pw, ph = self.PANEL_WIDTH, self.PANEL_HEIGHT
        canvas = np.zeros((ph * 2, pw * 2, 3), dtype=np.uint8)

        # ── Panel 1: Camera Feed (top-left) ──────────────────
        if self._last_frame is not None:
            panel1 = cv2.resize(self._last_frame, (pw, ph))
        else:
            panel1 = np.zeros((ph, pw, 3), dtype=np.uint8)
            cv2.putText(panel1, "No Camera Feed", (pw//4, ph//2),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.7, (100, 100, 100), 2)
        self._draw_label(panel1, "Camera Feed")
        canvas[0:ph, 0:pw] = panel1

        # ── Panel 2: Depth Map (top-right) ───────────────────
        if self._last_depth is not None:
            depth_normalized = cv2.normalize(
                self._last_depth, None, 0, 255,
                cv2.NORM_MINMAX, cv2.CV_8U
            )
            depth_colored = cv2.applyColorMap(depth_normalized, cv2.COLORMAP_MAGMA)
            panel2 = cv2.resize(depth_colored, (pw, ph))
        else:
            panel2 = np.zeros((ph, pw, 3), dtype=np.uint8)
            cv2.putText(panel2, "Depth Disabled", (pw//4, ph//2),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.7, (100, 100, 100), 2)
        self._draw_label(panel2, "Depth Map")
        canvas[0:ph, pw:pw*2] = panel2

        # ── Panel 3: Gesture State (bottom-left) ─────────────
        panel3 = np.zeros((ph, pw, 3), dtype=np.uint8)
        self._draw_label(panel3, "Gestures")
        
        y = 40
        if self._gesture_text:
            for g in self._gesture_text[:8]:
                color = (100, 255, 100) if "HOLD" not in g else (100, 200, 255)
                cv2.putText(panel3, f"● {g}", (20, y),
                           cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
                y += 25
        else:
            cv2.putText(panel3, "No active gestures", (20, y),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (100, 100, 100), 1)

        # Show additional info
        y = ph - 80
        for key, value in list(self._info.items())[:4]:
            cv2.putText(panel3, f"{key}: {value}", (20, y),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 200), 1)
            y += 20

        canvas[ph:ph*2, 0:pw] = panel3

        # ── Panel 4: Performance (bottom-right) ──────────────
        panel4 = np.zeros((ph, pw, 3), dtype=np.uint8)
        self._draw_label(panel4, "Performance")

        # FPS text
        if self._fps_history:
            current_fps = self._fps_history[-1]
            avg_fps = sum(self._fps_history) / len(self._fps_history)
            fps_color = (100, 255, 100) if current_fps >= 30 else (100, 100, 255)
            cv2.putText(panel4, f"FPS: {current_fps:.0f} (avg: {avg_fps:.0f})",
                       (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.5, fps_color, 1)

        # Latency
        if self._latency_history:
            lat = self._latency_history[-1]
            lat_color = (100, 255, 100) if lat < 30 else (100, 100, 255)
            cv2.putText(panel4, f"Latency: {lat:.1f}ms",
                       (20, 65), cv2.FONT_HERSHEY_SIMPLEX, 0.5, lat_color, 1)

        # FPS graph
        self._draw_graph(panel4, self._fps_history, (20, 90, pw - 40, 80),
                        color=(100, 255, 100), max_val=120, label="FPS")

        # Latency graph
        self._draw_graph(panel4, self._latency_history, (20, 185, pw - 40, 60),
                        color=(100, 150, 255), max_val=100, label="Latency (ms)")

        canvas[ph:ph*2, pw:pw*2] = panel4

        cv2.imshow("Madhur Vision - Debug", canvas)
        cv2.waitKey(1)

    def _draw_label(self, panel: np.ndarray, text: str) -> None:
        """Draw panel label header."""
        h, w = panel.shape[:2]
        cv2.rectangle(panel, (0, 0), (w, 22), (30, 30, 40), -1)
        cv2.putText(panel, text, (10, 16),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 220), 1)

    def _draw_graph(
        self, panel: np.ndarray, data: deque,
        rect: tuple, color: tuple,
        max_val: float = 100, label: str = ""
    ) -> None:
        """Draw a line graph on the panel."""
        x, y, w, h = rect
        if len(data) < 2:
            return

        # Background
        cv2.rectangle(panel, (x, y), (x + w, y + h), (25, 25, 35), -1)
        cv2.rectangle(panel, (x, y), (x + w, y + h), (50, 50, 60), 1)

        # Label
        if label:
            cv2.putText(panel, label, (x + 5, y + 12),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.3, (150, 150, 150), 1)

        # Plot data
        points = list(data)
        step = w / max(len(points) - 1, 1)

        for i in range(1, len(points)):
            x1 = int(x + (i - 1) * step)
            y1 = int(y + h - (min(points[i-1], max_val) / max_val) * h)
            x2 = int(x + i * step)
            y2 = int(y + h - (min(points[i], max_val) / max_val) * h)
            cv2.line(panel, (x1, y1), (x2, y2), color, 1)

    def toggle(self) -> None:
        """Toggle dashboard visibility."""
        self._visible = not self._visible
        if not self._visible:
            cv2.destroyWindow("Madhur Vision - Debug")
        logger.info(f"Debug dashboard {'shown' if self._visible else 'hidden'}")

    @property
    def visible(self) -> bool:
        return self._visible

    def close(self) -> None:
        """Close the dashboard window."""
        self._visible = False
        try:
            cv2.destroyWindow("Madhur Vision - Debug")
        except Exception:
            pass
