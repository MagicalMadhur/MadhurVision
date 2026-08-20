"""
MadhurVision — Window Types
==============================
Concrete window types: DesktopStream, Terminal, Clock, Status.
Factory function for creating typed windows.
"""

import time
import logging
from typing import Optional

from windows.spatial_window import SpatialWindow, WindowType
from rendering.spatial_scene import Vector3, Vector2

logger = logging.getLogger("MadhurVision.WindowTypes")


def create_window(
    window_type: str,
    title: Optional[str] = None,
    position: Optional[Vector3] = None,
    scale: Optional[Vector2] = None,
    **kwargs
) -> SpatialWindow:
    """
    Factory function to create typed windows.
    
    Args:
        window_type: One of "desktop", "browser", "terminal", "clock", "status", "video"
        title: Window title (auto-generated if None)
        position: World position (auto-positioned if None)
        scale: Window size (type-appropriate default if None)
        **kwargs: Type-specific keyword arguments
        
    Returns:
        Configured SpatialWindow
    """
    type_map = {
        "desktop": _create_desktop_stream,
        "browser": _create_browser,
        "terminal": _create_terminal,
        "clock": _create_clock,
        "status": _create_status,
        "video": _create_video_player,
    }

    creator = type_map.get(window_type.lower())
    if creator is None:
        logger.warning(f"Unknown window type '{window_type}', creating custom")
        return SpatialWindow(
            title=title or "Custom Window",
            window_type=WindowType.CUSTOM,
            position=position or Vector3(0, 0, -1.5),
            scale=scale or Vector2(0.8, 0.5)
        )

    return creator(title=title, position=position, scale=scale, **kwargs)


def _create_desktop_stream(
    title: str = None,
    position: Vector3 = None,
    scale: Vector2 = None,
    monitor: int = 0,
    **kwargs
) -> SpatialWindow:
    """Desktop screen capture window."""
    return SpatialWindow(
        title=title or f"Desktop (Monitor {monitor})",
        window_type=WindowType.DESKTOP_STREAM,
        position=position or Vector3(0, 0, -1.5),
        scale=scale or Vector2(1.0, 0.56),  # 16:9 aspect
        opacity=0.95
    )


def _create_browser(
    title: str = None,
    position: Vector3 = None,
    scale: Vector2 = None,
    url: str = "",
    **kwargs
) -> SpatialWindow:
    """Browser window."""
    return SpatialWindow(
        title=title or "Browser",
        window_type=WindowType.BROWSER,
        position=position or Vector3(0.5, 0.1, -1.5),
        scale=scale or Vector2(0.9, 0.6),
        opacity=0.93
    )


def _create_terminal(
    title: str = None,
    position: Vector3 = None,
    scale: Vector2 = None,
    **kwargs
) -> SpatialWindow:
    """Terminal window."""
    return SpatialWindow(
        title=title or "Terminal",
        window_type=WindowType.TERMINAL,
        position=position or Vector3(-0.5, -0.1, -1.3),
        scale=scale or Vector2(0.7, 0.45),
        opacity=0.90
    )


def _create_clock(
    title: str = None,
    position: Vector3 = None,
    scale: Vector2 = None,
    **kwargs
) -> SpatialWindow:
    """Clock widget — smaller, decorative."""
    return SpatialWindow(
        title=title or "Clock",
        window_type=WindowType.CLOCK,
        position=position or Vector3(0.8, 0.5, -1.0),
        scale=scale or Vector2(0.25, 0.25),
        opacity=0.85
    )


def _create_status(
    title: str = None,
    position: Vector3 = None,
    scale: Vector2 = None,
    **kwargs
) -> SpatialWindow:
    """System status panel."""
    return SpatialWindow(
        title=title or "System Status",
        window_type=WindowType.STATUS,
        position=position or Vector3(-0.8, 0.5, -1.0),
        scale=scale or Vector2(0.35, 0.5),
        opacity=0.85
    )


def _create_video_player(
    title: str = None,
    position: Vector3 = None,
    scale: Vector2 = None,
    **kwargs
) -> SpatialWindow:
    """Video player window — 16:9 aspect."""
    return SpatialWindow(
        title=title or "Video Player",
        window_type=WindowType.VIDEO_PLAYER,
        position=position or Vector3(0, 0, -2.0),
        scale=scale or Vector2(1.2, 0.675),  # 16:9
        opacity=0.98
    )
