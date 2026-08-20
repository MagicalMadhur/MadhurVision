"""
MadhurVision — OpenGL Rendering Engine
=========================================
Main render loop using Pygame + PyOpenGL.
Renders passthrough camera feed, spatial windows, hand cursor, and HUD.
Targets 60 FPS with vsync.
"""

import sys
import time
import math
import ctypes
import logging
from typing import Optional, List

import numpy as np

logger = logging.getLogger("MadhurVision.RenderEngine")

try:
    import pygame
    from pygame.locals import *
    PYGAME_AVAILABLE = True
except ImportError:
    PYGAME_AVAILABLE = False

try:
    from OpenGL.GL import *
    from OpenGL.GL import shaders as gl_shaders
    from OpenGL.GLU import *
    OPENGL_AVAILABLE = True
except ImportError:
    OPENGL_AVAILABLE = False

from configs.settings import settings
from rendering.spatial_scene import SpatialScene, Vector3, Quaternion


class RenderEngine:
    """
    Main OpenGL rendering engine.
    
    Manages the Pygame window, OpenGL context, and the main render loop.
    Renders layers in order:
        1. Background: passthrough camera feed as fullscreen quad
        2. Spatial windows: 3D textured quads with glass effect
        3. Hand cursor: 3D hand skeleton overlay
        4. HUD: 2D debug/status overlay
    
    Usage:
        engine = RenderEngine(scene)
        engine.init()
        
        while engine.running:
            engine.begin_frame()
            engine.render_background(camera_texture)
            engine.render_windows(window_list)
            engine.render_hand(hand_data)
            engine.render_hud(hud_data)
            engine.end_frame()
        
        engine.shutdown()
    """

    def __init__(self, scene: SpatialScene):
        if not PYGAME_AVAILABLE:
            raise RuntimeError("Pygame not installed. Run: pip install pygame")
        if not OPENGL_AVAILABLE:
            raise RuntimeError("PyOpenGL not installed. Run: pip install PyOpenGL PyOpenGL-accelerate")

        self._scene = scene
        self._width = settings.display.width
        self._height = settings.display.height
        self._fullscreen = settings.display.fullscreen
        self._fps_target = settings.display.fps_target
        self._vr_mode = settings.display.vr_enabled

        self.running = True
        self._clock = None
        self._screen = None

        # OpenGL resources
        self._panel_shader = None
        self._bg_texture = 0
        self._quad_vao = 0
        self._quad_vbo = 0

        # Performance
        self._frame_count = 0
        self._fps = 0.0
        self._last_fps_time = 0.0
        self._frame_times = []

        # Time for shader animations
        self._start_time = time.perf_counter()

    def init(self) -> None:
        """Initialize Pygame window and OpenGL context."""
        pygame.init()
        pygame.display.set_caption("Madhur Vision")

        flags = OPENGL | DOUBLEBUF
        if self._fullscreen:
            flags |= FULLSCREEN

        try:
            # Request OpenGL 3.3 core profile
            pygame.display.gl_set_attribute(GL_CONTEXT_MAJOR_VERSION, 3)
            pygame.display.gl_set_attribute(GL_CONTEXT_MINOR_VERSION, 3)
            pygame.display.gl_set_attribute(GL_CONTEXT_PROFILE_MASK, GL_CONTEXT_PROFILE_CORE)
            pygame.display.gl_set_attribute(GL_MULTISAMPLEBUFFERS, 1)
            pygame.display.gl_set_attribute(GL_MULTISAMPLESAMPLES, 4)

            self._screen = pygame.display.set_mode(
                (self._width, self._height), flags
            )
        except Exception as e:
            logger.warning(f"OpenGL init with strict attributes failed: {e}. Trying fallback...")
            # Fallback for laptops with hybrid graphics (Optimus) where strict attributes fail
            pygame.display.gl_set_attribute(GL_CONTEXT_PROFILE_MASK, 0)
            pygame.display.gl_set_attribute(GL_MULTISAMPLEBUFFERS, 0)
            pygame.display.gl_set_attribute(GL_MULTISAMPLESAMPLES, 0)
            self._screen = pygame.display.set_mode(
                (self._width, self._height), flags
            )
        self._clock = pygame.time.Clock()

        # OpenGL setup
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        glEnable(GL_DEPTH_TEST)
        glDepthFunc(GL_LESS)
        glEnable(GL_MULTISAMPLE)
        glClearColor(0.02, 0.02, 0.04, 1.0)

        # Create resources
        self._init_quad()
        self._init_shaders()
        self._bg_texture = self._create_texture()

        self._last_fps_time = time.perf_counter()
        logger.info(f"RenderEngine initialized ({self._width}x{self._height}, "
                    f"fullscreen={self._fullscreen}, VR={self._vr_mode})")

    def _init_quad(self) -> None:
        """Create a unit quad VAO for rendering panels."""
        # Vertices: position (x,y,z) + texcoord (u,v)
        vertices = np.array([
            # Position         TexCoord
            -0.5, -0.5, 0.0,  0.0, 0.0,
             0.5, -0.5, 0.0,  1.0, 0.0,
             0.5,  0.5, 0.0,  1.0, 1.0,
            -0.5, -0.5, 0.0,  0.0, 0.0,
             0.5,  0.5, 0.0,  1.0, 1.0,
            -0.5,  0.5, 0.0,  0.0, 1.0,
        ], dtype=np.float32)

        self._quad_vao = glGenVertexArrays(1)
        self._quad_vbo = glGenBuffers(1)

        glBindVertexArray(self._quad_vao)
        glBindBuffer(GL_ARRAY_BUFFER, self._quad_vbo)
        glBufferData(GL_ARRAY_BUFFER, vertices.nbytes, vertices, GL_STATIC_DRAW)

        # Position attribute (location = 0)
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 20, ctypes.c_void_p(0))
        glEnableVertexAttribArray(0)

        # TexCoord attribute (location = 1)
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 20, ctypes.c_void_p(12))
        glEnableVertexAttribArray(1)

        glBindVertexArray(0)

    def _init_shaders(self) -> None:
        """Compile and link panel shaders."""
        import os
        shader_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "shaders"
        )

        vert_path = os.path.join(shader_dir, "panel.vert")
        frag_path = os.path.join(shader_dir, "panel.frag")

        with open(vert_path, 'r') as f:
            vert_src = f.read()
        with open(frag_path, 'r') as f:
            frag_src = f.read()

        try:
            vert = gl_shaders.compileShader(vert_src, GL_VERTEX_SHADER)
            frag = gl_shaders.compileShader(frag_src, GL_FRAGMENT_SHADER)
            self._panel_shader = gl_shaders.compileProgram(vert, frag)
            logger.info("Panel shaders compiled successfully")
        except Exception as e:
            logger.error(f"Shader compilation failed: {e}")
            logger.info("Falling back to fixed-function rendering")
            self._panel_shader = None

    def _create_texture(self) -> int:
        """Create an empty OpenGL texture for dynamic content."""
        tex = glGenTextures(1)
        glBindTexture(GL_TEXTURE_2D, tex)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        glBindTexture(GL_TEXTURE_2D, 0)
        return tex

    def update_texture(self, tex_id: int, image: np.ndarray) -> None:
        """
        Upload an OpenCV image to an OpenGL texture.
        
        Args:
            tex_id: OpenGL texture ID
            image: BGR or BGRA numpy array
        """
        if image is None:
            return

        h, w = image.shape[:2]
        channels = image.shape[2] if len(image.shape) > 2 else 1

        # Flip vertically for OpenGL (origin is bottom-left)
        image = np.flipud(image)

        glBindTexture(GL_TEXTURE_2D, tex_id)

        if channels == 3:
            # BGR → RGB for OpenGL
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, w, h, 0,
                        GL_BGR, GL_UNSIGNED_BYTE, image)
        elif channels == 4:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0,
                        GL_BGRA, GL_UNSIGNED_BYTE, image)
        else:
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RED, w, h, 0,
                        GL_RED, GL_UNSIGNED_BYTE, image)

        glBindTexture(GL_TEXTURE_2D, 0)

    def begin_frame(self) -> None:
        """Begin a new frame. Clear buffers, process events."""
        # Process Pygame events
        for event in pygame.event.get():
            if event.type == QUIT:
                self.running = False
            elif event.type == KEYDOWN:
                if event.key == K_ESCAPE:
                    self.running = False
                elif event.key == K_F11:
                    self._toggle_fullscreen()
                elif event.key == K_d:
                    settings.debug.enabled = not settings.debug.enabled

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

    def render_background(self, camera_frame: Optional[np.ndarray]) -> None:
        """
        Render camera passthrough as fullscreen background.
        
        Args:
            camera_frame: BGR numpy array from camera, or None for black
        """
        if camera_frame is not None:
            self.update_texture(self._bg_texture, camera_frame)

        # Render fullscreen quad with fixed-function pipeline
        # (background doesn't need 3D transform)
        glDisable(GL_DEPTH_TEST)
        glUseProgram(0)  # Fixed-function

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(-1, 1, -1, 1, -1, 1)

        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        glEnable(GL_TEXTURE_2D)
        glBindTexture(GL_TEXTURE_2D, self._bg_texture)

        glColor4f(1, 1, 1, 1)
        glBegin(GL_QUADS)
        glTexCoord2f(0, 0); glVertex2f(-1, -1)
        glTexCoord2f(1, 0); glVertex2f(1, -1)
        glTexCoord2f(1, 1); glVertex2f(1, 1)
        glTexCoord2f(0, 1); glVertex2f(-1, 1)
        glEnd()

        glDisable(GL_TEXTURE_2D)
        glEnable(GL_DEPTH_TEST)

    def render_window(self, window, content_texture: int = 0) -> None:
        """
        Render a single spatial window as a 3D panel.
        
        Args:
            window: SpatialWindow to render
            content_texture: OpenGL texture for window content
        """
        if not window.should_render:
            return

        eff_scale = window.effective_scale
        eff_opacity = window.effective_opacity

        if self._panel_shader:
            self._render_window_shader(window, content_texture, eff_scale, eff_opacity)
        else:
            self._render_window_fixed(window, content_texture, eff_scale, eff_opacity)

    def _render_window_shader(self, window, content_texture, eff_scale, eff_opacity):
        """Render window using shader pipeline."""
        glUseProgram(self._panel_shader)

        # Build model matrix
        pos = window.position
        model = [
            eff_scale.x, 0, 0, 0,
            0, eff_scale.y, 0, 0,
            0, 0, 1, 0,
            pos.x, pos.y, pos.z, 1
        ]

        aspect = self._width / self._height
        view = self._scene.get_view_matrix()
        proj = self._scene.get_projection_matrix(aspect)

        # Set uniforms
        loc = lambda name: glGetUniformLocation(self._panel_shader, name)
        glUniformMatrix4fv(loc("uModel"), 1, GL_FALSE, (ctypes.c_float * 16)(*model))
        glUniformMatrix4fv(loc("uView"), 1, GL_FALSE, (ctypes.c_float * 16)(*view))
        glUniformMatrix4fv(loc("uProjection"), 1, GL_FALSE, (ctypes.c_float * 16)(*proj))
        glUniform1f(loc("uOpacity"), eff_opacity)
        glUniform1i(loc("uIsFocused"), int(window.is_focused))
        glUniform1i(loc("uHasTexture"), int(content_texture > 0))
        glUniform4f(loc("uTintColor"), 0.2, 0.25, 0.4, 0.3)
        glUniform1f(loc("uBorderRadius"), 0.02)
        glUniform1f(loc("uTime"), time.perf_counter() - self._start_time)

        # Bind texture
        if content_texture > 0:
            glActiveTexture(GL_TEXTURE0)
            glBindTexture(GL_TEXTURE_2D, content_texture)
            glUniform1i(loc("uTexture"), 0)

        # Draw quad
        glBindVertexArray(self._quad_vao)
        glDrawArrays(GL_TRIANGLES, 0, 6)
        glBindVertexArray(0)

        glUseProgram(0)

    def _render_window_fixed(self, window, content_texture, eff_scale, eff_opacity):
        """Fallback: render window using fixed-function OpenGL."""
        pos = window.position
        aspect = self._width / self._height

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        gluPerspective(settings.vr.fov, aspect,
                       settings.spatial.near_clip, settings.spatial.far_clip)

        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        # Apply camera
        yaw, pitch, roll = self._scene.camera_rotation.to_euler().to_tuple()
        glRotatef(-math.degrees(pitch), 1, 0, 0)
        glRotatef(-math.degrees(yaw), 0, 1, 0)
        cam = self._scene.camera_position
        glTranslatef(-cam.x, -cam.y, -cam.z)

        # Draw window quad
        glPushMatrix()
        glTranslatef(pos.x, pos.y, pos.z)

        hw = eff_scale.x / 2
        hh = eff_scale.y / 2

        if content_texture > 0:
            glEnable(GL_TEXTURE_2D)
            glBindTexture(GL_TEXTURE_2D, content_texture)
        
        # Window body
        if window.is_focused:
            glColor4f(0.15, 0.18, 0.25, eff_opacity)
        else:
            glColor4f(0.1, 0.1, 0.15, eff_opacity)

        if content_texture > 0:
            glColor4f(1, 1, 1, eff_opacity)

        glBegin(GL_QUADS)
        glTexCoord2f(0, 0); glVertex3f(-hw, -hh, 0)
        glTexCoord2f(1, 0); glVertex3f(hw, -hh, 0)
        glTexCoord2f(1, 1); glVertex3f(hw, hh, 0)
        glTexCoord2f(0, 1); glVertex3f(-hw, hh, 0)
        glEnd()

        if content_texture > 0:
            glDisable(GL_TEXTURE_2D)

        # Title bar
        title_h = 0.04
        if window.is_focused:
            glColor4f(0.25, 0.3, 0.5, eff_opacity)
        else:
            glColor4f(0.15, 0.15, 0.2, eff_opacity)
        glBegin(GL_QUADS)
        glVertex3f(-hw, hh - title_h, 0.001)
        glVertex3f(hw, hh - title_h, 0.001)
        glVertex3f(hw, hh, 0.001)
        glVertex3f(-hw, hh, 0.001)
        glEnd()

        # Focus border glow
        if window.is_focused:
            glColor4f(0.4, 0.5, 1.0, eff_opacity * 0.6)
            glLineWidth(2.0)
            glBegin(GL_LINE_LOOP)
            glVertex3f(-hw, -hh, 0.001)
            glVertex3f(hw, -hh, 0.001)
            glVertex3f(hw, hh, 0.001)
            glVertex3f(-hw, hh, 0.001)
            glEnd()

        glPopMatrix()

    def render_hand_cursor(self, landmarks: list, hand_str: str = "Right") -> None:
        """
        Render hand skeleton and cursor in 3D.
        
        Args:
            landmarks: List of (x, y, z) normalized landmarks
            hand_str: "Left" or "Right"
        """
        if not landmarks or len(landmarks) < 21:
            return

        glDisable(GL_DEPTH_TEST)
        glUseProgram(0)

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(0, 1, 1, 0, -1, 1)  # Normalized coordinates

        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        # Draw landmark points
        glPointSize(6.0)
        glBegin(GL_POINTS)
        for i, (x, y, z) in enumerate(landmarks):
            if i in (4, 8):  # Thumb and index tips
                glColor4f(1.0, 0.4, 0.4, 0.9)
            else:
                glColor4f(0.3, 0.8, 1.0, 0.7)
            glVertex3f(x, y, 0)
        glEnd()

        # Draw connections (bones)
        connections = [
            (0,1),(1,2),(2,3),(3,4),       # Thumb
            (0,5),(5,6),(6,7),(7,8),       # Index
            (0,9),(9,10),(10,11),(11,12),   # Middle
            (0,13),(13,14),(14,15),(15,16), # Ring
            (0,17),(17,18),(18,19),(19,20), # Pinky
            (5,9),(9,13),(13,17),           # Palm
        ]

        glLineWidth(2.0)
        glBegin(GL_LINES)
        glColor4f(0.3, 0.7, 1.0, 0.5)
        for a, b in connections:
            if a < len(landmarks) and b < len(landmarks):
                glVertex3f(landmarks[a][0], landmarks[a][1], 0)
                glVertex3f(landmarks[b][0], landmarks[b][1], 0)
        glEnd()

        # Pinch indicator: circle between thumb and index
        thumb = landmarks[4]
        index = landmarks[8]
        cx = (thumb[0] + index[0]) / 2
        cy = (thumb[1] + index[1]) / 2
        dist = math.sqrt((thumb[0]-index[0])**2 + (thumb[1]-index[1])**2)
        
        # Color based on pinch distance
        if dist < 0.05:
            glColor4f(0.2, 1.0, 0.4, 0.8)  # Green = pinching
        elif dist < 0.08:
            glColor4f(1.0, 0.8, 0.2, 0.6)  # Yellow = close
        else:
            glColor4f(0.5, 0.5, 0.5, 0.3)  # Gray = open

        # Draw circle
        glBegin(GL_LINE_LOOP)
        for i in range(20):
            angle = 2 * math.pi * i / 20
            r = dist / 2
            glVertex3f(cx + math.cos(angle) * r, cy + math.sin(angle) * r, 0)
        glEnd()

        # Cursor dot at index tip
        glPointSize(10.0)
        glBegin(GL_POINTS)
        glColor4f(1.0, 1.0, 1.0, 0.9)
        glVertex3f(index[0], index[1], 0)
        glEnd()

        glEnable(GL_DEPTH_TEST)

    def render_hud(self, hud_info: dict = None) -> None:
        """
        Render 2D HUD overlay (FPS, status, etc).
        
        Args:
            hud_info: Dict with keys like 'fps', 'gesture', 'connection', etc.
        """
        if not settings.debug.show_fps and not settings.debug.enabled:
            return

        # We use Pygame font rendering overlaid on the OpenGL context
        # This is done by rendering text to a surface and blitting
        glDisable(GL_DEPTH_TEST)
        glUseProgram(0)

        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(0, self._width, self._height, 0, -1, 1)

        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        # Simple text rendering with OpenGL quads
        y = 10
        info_lines = [f"FPS: {self._fps:.0f}"]

        if hud_info:
            if 'gesture' in hud_info:
                info_lines.append(f"Gesture: {hud_info['gesture']}")
            if 'connection' in hud_info:
                info_lines.append(f"Connection: {hud_info['connection']}")
            if 'latency' in hud_info:
                info_lines.append(f"Latency: {hud_info['latency']:.1f}ms")
            if 'hands' in hud_info:
                info_lines.append(f"Hands: {hud_info['hands']}")
            if 'voice' in hud_info:
                info_lines.append(f"Voice: {hud_info['voice']}")

        # Render each line as a colored bar with text position marker
        for i, line in enumerate(info_lines):
            y_pos = 10 + i * 22

            # Background bar
            glColor4f(0.0, 0.0, 0.0, 0.5)
            glBegin(GL_QUADS)
            glVertex2f(5, y_pos - 2)
            glVertex2f(200, y_pos - 2)
            glVertex2f(200, y_pos + 18)
            glVertex2f(5, y_pos + 18)
            glEnd()

            # Simple dot indicator for each line
            glColor4f(0.3, 0.8, 1.0, 0.8)
            glPointSize(6.0)
            glBegin(GL_POINTS)
            glVertex2f(12, y_pos + 8)
            glEnd()

        glEnable(GL_DEPTH_TEST)

    def end_frame(self) -> None:
        """End frame: swap buffers, track FPS."""
        pygame.display.flip()
        self._clock.tick(self._fps_target)

        # Track FPS
        self._frame_count += 1
        now = time.perf_counter()
        elapsed = now - self._last_fps_time
        if elapsed >= 1.0:
            self._fps = self._frame_count / elapsed
            self._frame_count = 0
            self._last_fps_time = now

    def _toggle_fullscreen(self) -> None:
        """Toggle fullscreen mode."""
        self._fullscreen = not self._fullscreen
        flags = OPENGL | DOUBLEBUF
        if self._fullscreen:
            flags |= FULLSCREEN
        self._screen = pygame.display.set_mode(
            (self._width, self._height), flags
        )

    @property
    def fps(self) -> float:
        return self._fps

    @property
    def width(self) -> int:
        return self._width

    @property
    def height(self) -> int:
        return self._height

    @property
    def bg_texture(self) -> int:
        return self._bg_texture

    def create_content_texture(self) -> int:
        """Create a new texture for window content."""
        return self._create_texture()

    def shutdown(self) -> None:
        """Clean up OpenGL resources and close window."""
        if self._quad_vao:
            glDeleteVertexArrays(1, [self._quad_vao])
        if self._quad_vbo:
            glDeleteBuffers(1, [self._quad_vbo])
        if self._bg_texture:
            glDeleteTextures([self._bg_texture])
        if self._panel_shader:
            glDeleteProgram(self._panel_shader)
        pygame.quit()
        logger.info("RenderEngine shutdown complete")
