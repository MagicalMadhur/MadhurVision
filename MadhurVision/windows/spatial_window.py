"""
MadhurVision — Spatial Window
================================
A single floating window in 3D space with position, rotation, scale,
content texture, and spatial anchor support.
"""

import time
import logging
from dataclasses import dataclass, field
from typing import Optional
from enum import Enum, auto

from rendering.spatial_scene import Vector3, Vector2, Quaternion, SpatialAnchor

logger = logging.getLogger("MadhurVision.SpatialWindow")


class WindowType(Enum):
    """Types of spatial windows."""
    DESKTOP_STREAM = auto()
    BROWSER = auto()
    VIDEO_PLAYER = auto()
    PDF_VIEWER = auto()
    TERMINAL = auto()
    CLOCK = auto()
    STATUS = auto()
    CUSTOM = auto()


@dataclass
class SpatialWindow:
    """
    A floating window in 3D space.
    
    Each window has a world-space position, rotation, and scale.
    Content is rendered as a textured quad facing the camera.
    Windows can be anchored to physical positions so they stay
    fixed relative to the real world.
    
    Attributes:
        id: Unique window identifier
        title: Display title (shown in title bar)
        window_type: Type of content
        position: World-space 3D position (center of window)
        rotation: Orientation quaternion
        scale: Width and height in meters
        content_texture: OpenGL texture ID for the window content
        is_focused: Whether this window currently has input focus
        is_minimized: Whether the window is minimized
        is_visible: Whether the window should be rendered
        opacity: Window transparency (0.0 = invisible, 1.0 = opaque)
        anchor: Optional spatial anchor for world-fixed positioning
        z_order: Rendering order (higher = in front)
    """
    id: str = ""
    title: str = "Untitled"
    window_type: WindowType = WindowType.CUSTOM

    # Transform
    position: Vector3 = field(default_factory=lambda: Vector3(0, 0, -1.5))
    rotation: Quaternion = field(default_factory=Quaternion.identity)
    scale: Vector2 = field(default_factory=lambda: Vector2(0.8, 0.5))

    # Visual state
    content_texture: int = 0  # OpenGL texture ID
    is_focused: bool = False
    is_minimized: bool = False
    is_visible: bool = True
    opacity: float = 0.92
    z_order: int = 0

    # Anchor
    anchor: Optional[SpatialAnchor] = None

    # Animation state
    _anim_opacity: float = field(default=0.0, repr=False)
    _anim_scale: float = field(default=0.0, repr=False)
    _created_at: float = field(default_factory=time.perf_counter, repr=False)
    _is_closing: bool = field(default=False, repr=False)

    # Title bar dimensions (relative to window)
    TITLE_BAR_HEIGHT: float = 0.04  # meters

    def move(self, delta: Vector3) -> None:
        """Move window by delta in world space."""
        self.position = self.position + delta

    def move_to(self, position: Vector3) -> None:
        """Move window to absolute position."""
        self.position = position

    def resize(self, new_width: float, new_height: float) -> None:
        """Resize window (in meters)."""
        new_width = max(0.2, min(new_width, 3.0))   # Clamp
        new_height = max(0.15, min(new_height, 2.0))
        self.scale = Vector2(new_width, new_height)

    def resize_by_factor(self, factor: float) -> None:
        """Scale window by a factor."""
        self.resize(self.scale.x * factor, self.scale.y * factor)

    def minimize(self) -> None:
        """Minimize the window (hide with animation)."""
        self.is_minimized = True
        self.is_focused = False
        logger.debug(f"Window '{self.title}' minimized")

    def restore(self) -> None:
        """Restore a minimized window."""
        self.is_minimized = False
        logger.debug(f"Window '{self.title}' restored")

    def close(self) -> None:
        """Mark window for closing (with animation)."""
        self._is_closing = True
        self.is_focused = False
        logger.debug(f"Window '{self.title}' closing")

    def focus(self) -> None:
        """Give this window input focus."""
        self.is_focused = True

    def unfocus(self) -> None:
        """Remove input focus from this window."""
        self.is_focused = False

    def attach_to_anchor(self, anchor: SpatialAnchor) -> None:
        """Attach window to a spatial anchor (stays fixed in physical space)."""
        self.anchor = anchor
        self.position = anchor.position
        self.rotation = anchor.rotation
        logger.info(f"Window '{self.title}' anchored to '{anchor.id}'")

    def detach_from_anchor(self) -> None:
        """Detach window from its spatial anchor."""
        self.anchor = None

    def update_animation(self, dt: float) -> None:
        """Update opening/closing animation state."""
        anim_speed = 5.0  # Animation speed multiplier

        if self._is_closing:
            self._anim_opacity = max(0.0, self._anim_opacity - dt * anim_speed)
            self._anim_scale = max(0.0, self._anim_scale - dt * anim_speed)
        elif not self.is_minimized:
            self._anim_opacity = min(1.0, self._anim_opacity + dt * anim_speed)
            self._anim_scale = min(1.0, self._anim_scale + dt * anim_speed)
        else:
            self._anim_opacity = max(0.0, self._anim_opacity - dt * anim_speed * 2)
            self._anim_scale = max(0.3, self._anim_scale - dt * anim_speed)

    @property
    def effective_opacity(self) -> float:
        """Opacity including animation state."""
        return self.opacity * self._anim_opacity

    @property
    def effective_scale(self) -> Vector2:
        """Scale including animation state."""
        return Vector2(
            self.scale.x * self._anim_scale,
            self.scale.y * self._anim_scale
        )

    @property
    def is_close_finished(self) -> bool:
        """Whether close animation has completed (safe to remove)."""
        return self._is_closing and self._anim_opacity <= 0.01

    @property
    def should_render(self) -> bool:
        """Whether this window should be rendered this frame."""
        return self.is_visible and self._anim_opacity > 0.01

    def contains_point_2d(self, px: float, py: float, cam_pos: Vector3) -> bool:
        """
        Simple hit-test: check if a 2D normalized point falls within
        this window's projected bounds. Approximate test for gesture interaction.
        
        This is a simplified test - the render engine does proper ray-plane
        intersection for accurate hit testing.
        """
        # Very rough approximation using window position projected
        dist = self.position.distance_to(cam_pos)
        if dist < 0.1:
            return False
        # Screen-space approximate size
        apparent_w = self.scale.x / dist * 0.5
        apparent_h = self.scale.y / dist * 0.5
        # Approximate screen position (very rough)
        cx = 0.5 - self.position.x * 0.3
        cy = 0.5 - self.position.y * 0.3
        return (abs(px - cx) < apparent_w and abs(py - cy) < apparent_h)

    def get_corner_positions(self) -> list:
        """Get 4 corner positions in world space for rendering."""
        hw = self.scale.x / 2
        hh = self.scale.y / 2
        corners = [
            Vector3(-hw, -hh, 0),  # Bottom-left
            Vector3( hw, -hh, 0),  # Bottom-right
            Vector3( hw,  hh, 0),  # Top-right
            Vector3(-hw,  hh, 0),  # Top-left
        ]
        # Rotate corners by window rotation
        rotated = [self.rotation.rotate_vector(c) for c in corners]
        # Translate to world position
        return [self.position + c for c in rotated]

    def to_dict(self) -> dict:
        """Serialize for saving layouts."""
        return {
            "id": self.id,
            "title": self.title,
            "type": self.window_type.name,
            "position": self.position.to_list(),
            "rotation": self.rotation.to_list(),
            "scale": [self.scale.x, self.scale.y],
            "opacity": self.opacity,
            "anchor_id": self.anchor.id if self.anchor else None
        }

    @staticmethod
    def from_dict(data: dict) -> 'SpatialWindow':
        """Deserialize from saved layout."""
        return SpatialWindow(
            id=data.get("id", ""),
            title=data.get("title", "Untitled"),
            window_type=WindowType[data.get("type", "CUSTOM")],
            position=Vector3.from_list(data.get("position", [0, 0, -1.5])),
            rotation=Quaternion(*data.get("rotation", [1, 0, 0, 0])),
            scale=Vector2(*data.get("scale", [0.8, 0.5])),
            opacity=data.get("opacity", 0.92)
        )
