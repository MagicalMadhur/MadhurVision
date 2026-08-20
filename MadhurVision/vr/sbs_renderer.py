"""
MadhurVision — Side-by-Side Stereo Renderer
===============================================
Renders the scene twice with horizontal camera offset for stereoscopic VR.
Supports Google Cardboard, VR Box, and DIY headsets.
"""

import math
import logging
from typing import Callable

logger = logging.getLogger("MadhurVision.SBSRenderer")

try:
    from OpenGL.GL import *
    from OpenGL.GLU import *
    OPENGL_AVAILABLE = True
except ImportError:
    OPENGL_AVAILABLE = False

from configs.settings import settings
from rendering.spatial_scene import SpatialScene, Vector3


class SBSRenderer:
    """
    Side-by-Side stereo renderer for VR headsets.
    
    Splits the screen into left and right halves, rendering the scene
    from two viewpoints separated by the interpupillary distance (IPD).
    
    Usage:
        sbs = SBSRenderer(scene, render_callback)
        
        # In render loop:
        sbs.render(width, height)
    """

    def __init__(self, scene: SpatialScene, render_callback: Callable = None):
        """
        Args:
            scene: SpatialScene for camera transforms
            render_callback: Function(eye_offset: Vector3) that renders the scene
                           for one eye. Called twice per frame (left eye, right eye).
        """
        self._scene = scene
        self._render_callback = render_callback
        self._ipd = settings.vr.ipd  # meters
        self._fov = settings.vr.fov

        # Framebuffer objects for each eye (optional, for post-processing)
        self._left_fbo = 0
        self._right_fbo = 0

        logger.info(f"SBSRenderer initialized (IPD={self._ipd*1000:.1f}mm, FOV={self._fov}°)")

    def render(self, screen_width: int, screen_height: int) -> None:
        """
        Render side-by-side stereo output.
        
        Splits the screen in half and renders the scene for each eye.
        
        Args:
            screen_width: Full screen width in pixels
            screen_height: Full screen height in pixels
        """
        if not OPENGL_AVAILABLE or not self._render_callback:
            return

        half_width = screen_width // 2
        half_ipd = self._ipd / 2.0

        # Save original camera position
        original_pos = Vector3(
            self._scene.camera_position.x,
            self._scene.camera_position.y,
            self._scene.camera_position.z
        )

        # ── Left Eye ────────────────────────────────────────
        glViewport(0, 0, half_width, screen_height)
        
        # Offset camera to the left
        left_offset = Vector3(-half_ipd, 0, 0)
        # Rotate offset by camera rotation for proper world-space offset
        world_offset = self._scene.camera_rotation.rotate_vector(left_offset)
        self._scene.set_camera_position(original_pos + world_offset)
        
        # Set up left eye projection (asymmetric frustum for toe-in)
        self._setup_projection(half_width, screen_height, -half_ipd)
        
        self._render_callback(left_offset)

        # ── Right Eye ───────────────────────────────────────
        glViewport(half_width, 0, half_width, screen_height)
        
        # Offset camera to the right
        right_offset = Vector3(half_ipd, 0, 0)
        world_offset = self._scene.camera_rotation.rotate_vector(right_offset)
        self._scene.set_camera_position(original_pos + world_offset)
        
        self._setup_projection(half_width, screen_height, half_ipd)
        
        self._render_callback(right_offset)

        # ── Restore ─────────────────────────────────────────
        glViewport(0, 0, screen_width, screen_height)
        self._scene.set_camera_position(original_pos)

        # Draw separator line between eyes
        self._draw_separator(screen_width, screen_height)

    def _setup_projection(self, width: int, height: int, eye_offset: float) -> None:
        """
        Set up asymmetric frustum projection for stereo rendering.
        
        Args:
            width: Viewport width (half screen)
            height: Viewport height
            eye_offset: Horizontal eye offset in meters
        """
        aspect = width / height
        near = settings.spatial.near_clip
        far = settings.spatial.far_clip
        fov_rad = math.radians(self._fov)

        top = near * math.tan(fov_rad / 2)
        bottom = -top
        
        # Asymmetric frustum: shift by eye offset projected to near plane
        convergence_distance = 2.0  # meters (where eyes converge)
        shift = eye_offset * near / convergence_distance
        
        left = -aspect * top + shift
        right = aspect * top + shift

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glFrustum(left, right, bottom, top, near, far)
        glMatrixMode(GL_MODELVIEW)

    def _draw_separator(self, width: int, height: int) -> None:
        """Draw a thin black line between left and right eye views."""
        glViewport(0, 0, width, height)
        glDisable(GL_DEPTH_TEST)
        glUseProgram(0)

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(0, width, height, 0, -1, 1)

        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        center_x = width // 2
        glColor4f(0, 0, 0, 1)
        glLineWidth(2.0)
        glBegin(GL_LINES)
        glVertex2f(center_x, 0)
        glVertex2f(center_x, height)
        glEnd()

        glEnable(GL_DEPTH_TEST)

    @property
    def ipd(self) -> float:
        return self._ipd

    @ipd.setter
    def ipd(self, value: float) -> None:
        """Set IPD in meters (typical range: 0.055 - 0.075)."""
        self._ipd = max(0.050, min(value, 0.080))
        logger.info(f"IPD set to {self._ipd*1000:.1f}mm")
