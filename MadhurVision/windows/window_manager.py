"""
MadhurVision — Window Manager
================================
Creates, manages, and orchestrates all spatial windows.
Handles focus, layout, drag, resize, and gesture→window interaction.
"""

import json
import os
import time
import math
import logging
from typing import List, Optional, Dict

from rendering.spatial_scene import Vector3, Vector2, Quaternion, SpatialScene
from windows.spatial_window import SpatialWindow, WindowType
from gestures.gesture_events import GestureType, GesturePhase, GestureEvent, GestureEventBus

logger = logging.getLogger("MadhurVision.WindowManager")


class WindowManager:
    """
    Manages all floating spatial windows.
    
    Handles:
        - Creating/destroying windows
        - Focus management (bring to front on pinch-click)
        - Dragging windows via pinch-hold + movement
        - Resizing via two-hand zoom gesture
        - Layout presets (grid, arc, stack)
        - Layout persistence
    
    Usage:
        scene = SpatialScene()
        bus = GestureEventBus()
        wm = WindowManager(scene, bus)
        
        # Create a window
        win = wm.create_window("My App", WindowType.DESKTOP_STREAM)
        
        # In main loop:
        wm.update(dt)
    """

    def __init__(self, scene: SpatialScene, event_bus: GestureEventBus):
        from configs.settings import settings

        self._scene = scene
        self._bus = event_bus
        self._settings = settings.spatial
        self._windows: Dict[str, SpatialWindow] = {}
        self._window_counter = 0
        self._focused_window: Optional[str] = None
        self._z_order_counter = 0

        # Drag state
        self._dragging_window: Optional[str] = None
        self._drag_start_pos: Optional[tuple] = None
        self._drag_window_start: Optional[Vector3] = None

        # Subscribe to gesture events
        self._bus.subscribe(GestureType.PINCH, self._on_pinch)
        self._bus.subscribe(GestureType.GRAB, self._on_grab)
        self._bus.subscribe(GestureType.ZOOM, self._on_zoom)
        self._bus.subscribe(GestureType.SWIPE_LEFT, self._on_swipe)
        self._bus.subscribe(GestureType.SWIPE_RIGHT, self._on_swipe)

    def create_window(
        self,
        title: str,
        window_type: WindowType = WindowType.CUSTOM,
        position: Optional[Vector3] = None,
        scale: Optional[Vector2] = None
    ) -> SpatialWindow:
        """
        Create a new spatial window.
        
        Args:
            title: Window title
            window_type: Type of window content
            position: World-space position (auto-positioned if None)
            scale: Window size in meters (uses defaults if None)
            
        Returns:
            The created SpatialWindow
        """
        if len(self._windows) >= self._settings.max_windows:
            logger.warning(f"Maximum windows ({self._settings.max_windows}) reached")
            # Close oldest non-focused window
            oldest = min(self._windows.values(), key=lambda w: w._created_at)
            self.close_window(oldest.id)

        self._window_counter += 1
        self._z_order_counter += 1

        win_id = f"win_{self._window_counter}"

        if position is None:
            position = self._auto_position()

        if scale is None:
            scale = Vector2(
                self._settings.default_window_width,
                self._settings.default_window_height
            )

        window = SpatialWindow(
            id=win_id,
            title=title,
            window_type=window_type,
            position=position,
            scale=scale,
            opacity=self._settings.default_opacity,
            z_order=self._z_order_counter
        )

        self._windows[win_id] = window
        self.focus_window(win_id)

        logger.info(f"Created window '{title}' ({win_id}) at {position.to_tuple()}")
        return window

    def close_window(self, window_id: str) -> None:
        """Start closing animation for a window."""
        if window_id in self._windows:
            self._windows[window_id].close()
            if self._focused_window == window_id:
                self._focused_window = None

    def remove_closed_windows(self) -> None:
        """Remove windows whose close animation has finished."""
        to_remove = [
            wid for wid, win in self._windows.items()
            if win.is_close_finished
        ]
        for wid in to_remove:
            del self._windows[wid]
            logger.info(f"Removed window {wid}")

    def focus_window(self, window_id: str) -> None:
        """Bring a window to focus."""
        # Unfocus all
        for win in self._windows.values():
            win.unfocus()

        if window_id in self._windows:
            self._z_order_counter += 1
            self._windows[window_id].focus()
            self._windows[window_id].z_order = self._z_order_counter
            self._focused_window = window_id

    def get_focused_window(self) -> Optional[SpatialWindow]:
        """Get the currently focused window."""
        if self._focused_window and self._focused_window in self._windows:
            return self._windows[self._focused_window]
        return None

    def get_window(self, window_id: str) -> Optional[SpatialWindow]:
        return self._windows.get(window_id)

    @property
    def windows(self) -> List[SpatialWindow]:
        """All windows sorted by z-order (back to front)."""
        return sorted(self._windows.values(), key=lambda w: w.z_order)

    @property
    def visible_windows(self) -> List[SpatialWindow]:
        """Windows that should be rendered."""
        return [w for w in self.windows if w.should_render]

    @property
    def window_count(self) -> int:
        return len(self._windows)

    def update(self, dt: float) -> None:
        """Update all windows (animations, cleanup)."""
        for window in self._windows.values():
            window.update_animation(dt)
        self.remove_closed_windows()

    def find_window_at(self, nx: float, ny: float) -> Optional[SpatialWindow]:
        """
        Find the topmost window at the given normalized screen coordinates.
        Checks windows from front to back (highest z-order first).
        """
        cam_pos = self._scene.camera_position
        # Check from front to back
        for window in reversed(self.windows):
            if window.should_render and window.contains_point_2d(nx, ny, cam_pos):
                return window
        return None

    # ─── Gesture Handlers ────────────────────────────────────────

    def _on_pinch(self, event: GestureEvent) -> None:
        """Handle pinch gesture (click/drag)."""
        if event.phase == GesturePhase.START:
            # Find window at pinch position → focus + start drag
            window = self.find_window_at(*event.position)
            if window:
                self.focus_window(window.id)
                self._dragging_window = window.id
                self._drag_start_pos = event.position
                self._drag_window_start = Vector3(
                    window.position.x, window.position.y, window.position.z
                )
        elif event.phase == GesturePhase.HOLD:
            # Drag the window
            if self._dragging_window and self._drag_start_pos:
                win = self._windows.get(self._dragging_window)
                if win:
                    dx = (event.position[0] - self._drag_start_pos[0]) * 2.0
                    dy = -(event.position[1] - self._drag_start_pos[1]) * 2.0
                    win.position = Vector3(
                        self._drag_window_start.x + dx,
                        self._drag_window_start.y + dy,
                        win.position.z
                    )
        elif event.phase == GesturePhase.RELEASE:
            self._dragging_window = None
            self._drag_start_pos = None
            self._drag_window_start = None

    def _on_grab(self, event: GestureEvent) -> None:
        """Handle grab gesture (move in depth)."""
        if event.phase == GesturePhase.HOLD:
            win = self.get_focused_window()
            if win:
                # Move in depth based on vertical velocity
                vx, vy = event.velocity
                win.position = Vector3(
                    win.position.x,
                    win.position.y,
                    win.position.z + vy * 0.01
                )

    def _on_zoom(self, event: GestureEvent) -> None:
        """Handle zoom gesture (resize focused window)."""
        if event.phase in (GesturePhase.START, GesturePhase.HOLD):
            win = self.get_focused_window()
            if win:
                win.resize_by_factor(event.scale)

    def _on_swipe(self, event: GestureEvent) -> None:
        """Handle swipe gestures."""
        if event.gesture_type == GestureType.SWIPE_LEFT:
            # Minimize focused window
            win = self.get_focused_window()
            if win:
                win.minimize()
        elif event.gesture_type == GestureType.SWIPE_RIGHT:
            # Restore last minimized window
            minimized = [w for w in self._windows.values() if w.is_minimized]
            if minimized:
                minimized[-1].restore()
                self.focus_window(minimized[-1].id)

    # ─── Layout Presets ──────────────────────────────────────────

    def layout_grid(self, columns: int = 3) -> None:
        """Arrange all windows in a grid pattern."""
        visible = [w for w in self._windows.values()
                   if not w.is_minimized and w.is_visible]
        if not visible:
            return

        spacing_x = self._settings.default_window_width * 1.1
        spacing_y = self._settings.default_window_height * 1.1

        for i, win in enumerate(visible):
            col = i % columns
            row = i // columns
            x = (col - columns / 2 + 0.5) * spacing_x
            y = -row * spacing_y + 0.3  # Start slightly above center
            win.position = Vector3(x, y, -self._settings.default_window_distance)

    def layout_arc(self, radius: float = 2.0) -> None:
        """Arrange windows in an arc around the user."""
        visible = [w for w in self._windows.values()
                   if not w.is_minimized and w.is_visible]
        if not visible:
            return

        arc_range = math.radians(120)  # 120-degree arc
        step = arc_range / max(len(visible) - 1, 1)
        start_angle = -arc_range / 2

        for i, win in enumerate(visible):
            angle = start_angle + i * step
            x = math.sin(angle) * radius
            z = -math.cos(angle) * radius
            win.position = Vector3(x, 0, z)
            # Face the center
            win.rotation = Quaternion.from_euler(0, -angle, 0)

    def layout_stack(self, offset: float = 0.05) -> None:
        """Stack all windows in a cascade."""
        visible = [w for w in self._windows.values()
                   if not w.is_minimized and w.is_visible]
        for i, win in enumerate(visible):
            win.position = Vector3(
                -0.5 + i * offset,
                0.3 - i * offset,
                -self._settings.default_window_distance + i * 0.01
            )

    def _auto_position(self) -> Vector3:
        """Generate a position for a new window that doesn't overlap existing ones."""
        existing = len(self._windows)
        # Spiral placement
        angle = existing * 0.5
        radius = 0.3 * (1 + existing * 0.1)
        x = math.sin(angle) * radius
        y = math.cos(angle) * 0.2
        z = -self._settings.default_window_distance
        return Vector3(x, y, z)

    # ─── Persistence ─────────────────────────────────────────────

    def save_layout(self, path: str = "configs/layout.json") -> None:
        """Save current window layout to file."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = {
            wid: win.to_dict()
            for wid, win in self._windows.items()
        }
        with open(path, 'w') as f:
            json.dump(data, f, indent=2)
        logger.info(f"Layout saved ({len(data)} windows)")

    def load_layout(self, path: str = "configs/layout.json") -> None:
        """Load window layout from file."""
        if not os.path.exists(path):
            return
        try:
            with open(path, 'r') as f:
                data = json.load(f)
            for wid, wdata in data.items():
                window = SpatialWindow.from_dict(wdata)
                self._windows[wid] = window
            logger.info(f"Layout loaded ({len(data)} windows)")
        except Exception as e:
            logger.error(f"Error loading layout: {e}")
