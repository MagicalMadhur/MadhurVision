"""
MadhurVision — Lens Distortion Correction
=============================================
Barrel distortion shader for VR headset lenses.
Corrects the pincushion distortion introduced by viewing through lenses.
Also handles chromatic aberration correction.
"""

import logging
from typing import Tuple

logger = logging.getLogger("MadhurVision.LensDistortion")

try:
    from OpenGL.GL import *
    from OpenGL.GL import shaders as gl_shaders
    OPENGL_AVAILABLE = True
except ImportError:
    OPENGL_AVAILABLE = False

from configs.settings import settings


# ─── Barrel Distortion Shader Source ─────────────────────────────────

DISTORTION_VERT = """
#version 330 core
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;

void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = aTexCoord;
}
"""

DISTORTION_FRAG = """
#version 330 core
in vec2 vTexCoord;
out vec4 FragColor;

uniform sampler2D uTexture;
uniform float uK1;           // Barrel distortion coefficient 1
uniform float uK2;           // Barrel distortion coefficient 2
uniform vec2 uCenter;        // Lens center (0.5, 0.5 for centered)
uniform vec2 uScale;         // Scale to fill viewport
uniform vec3 uChromaOffset;  // Chromatic aberration offset per channel

vec2 distort(vec2 uv, float k1, float k2) {
    vec2 centered = uv - uCenter;
    float r2 = dot(centered, centered);
    float r4 = r2 * r2;
    float distortion = 1.0 + k1 * r2 + k2 * r4;
    return uCenter + centered * distortion * uScale;
}

void main() {
    // Apply barrel distortion with per-channel chromatic aberration
    vec2 uvR = distort(vTexCoord, uK1 * uChromaOffset.r, uK2 * uChromaOffset.r);
    vec2 uvG = distort(vTexCoord, uK1 * uChromaOffset.g, uK2 * uChromaOffset.g);
    vec2 uvB = distort(vTexCoord, uK1 * uChromaOffset.b, uK2 * uChromaOffset.b);
    
    // Check bounds (black outside lens area)
    float r = texture(uTexture, uvR).r;
    float g = texture(uTexture, uvG).g;
    float b = texture(uTexture, uvB).b;
    
    // Vignette (darken edges)
    vec2 centered = vTexCoord - vec2(0.5);
    float vignette = 1.0 - dot(centered, centered) * 2.0;
    vignette = clamp(vignette, 0.0, 1.0);
    
    // Discard pixels outside the lens circle
    float radius = length(vTexCoord - uCenter);
    if (radius > 0.48) {
        FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    
    FragColor = vec4(r, g, b, 1.0) * vignette;
}
"""


class LensDistortion:
    """
    Post-processing barrel distortion for VR lenses.
    
    Applies per-eye distortion correction to counteract the pincushion
    effect of viewing through VR headset lenses.
    
    Usage:
        distortion = LensDistortion()
        distortion.init()
        
        # After rendering each eye:
        distortion.apply(eye_texture, is_left_eye=True)
    """

    # Preset distortion profiles for common headsets
    PROFILES = {
        "cardboard_v2": {"k1": 0.22, "k2": 0.24, "chroma": (1.0, 1.015, 1.03)},
        "vr_box": {"k1": 0.30, "k2": 0.20, "chroma": (1.0, 1.02, 1.04)},
        "diy_simple": {"k1": 0.18, "k2": 0.15, "chroma": (1.0, 1.01, 1.02)},
        "none": {"k1": 0.0, "k2": 0.0, "chroma": (1.0, 1.0, 1.0)},
    }

    def __init__(self, profile: str = "cardboard_v2"):
        self._k1 = settings.vr.distortion_k1
        self._k2 = settings.vr.distortion_k2
        self._chroma = (1.0, 1.015, 1.03)
        self._shader = None
        self._quad_vao = 0
        self._initialized = False

        # Apply profile if specified
        if profile in self.PROFILES:
            p = self.PROFILES[profile]
            self._k1 = p["k1"]
            self._k2 = p["k2"]
            self._chroma = p["chroma"]

    def init(self) -> None:
        """Compile distortion shader and create fullscreen quad."""
        if not OPENGL_AVAILABLE:
            return

        try:
            vert = gl_shaders.compileShader(DISTORTION_VERT, GL_VERTEX_SHADER)
            frag = gl_shaders.compileShader(DISTORTION_FRAG, GL_FRAGMENT_SHADER)
            self._shader = gl_shaders.compileProgram(vert, frag)
            self._initialized = True
            logger.info(f"LensDistortion shader compiled (k1={self._k1}, k2={self._k2})")
        except Exception as e:
            logger.error(f"Distortion shader compilation failed: {e}")

    def apply(
        self,
        texture: int,
        viewport: Tuple[int, int, int, int],
        is_left_eye: bool = True
    ) -> None:
        """
        Apply barrel distortion to a rendered eye texture.
        
        Args:
            texture: OpenGL texture containing rendered eye view
            viewport: (x, y, width, height) of the eye viewport
            is_left_eye: Whether this is the left eye (affects lens center)
        """
        if not self._initialized or not self._shader:
            return

        glUseProgram(self._shader)

        # Set uniforms
        loc = lambda name: glGetUniformLocation(self._shader, name)

        glUniform1f(loc("uK1"), self._k1)
        glUniform1f(loc("uK2"), self._k2)

        # Lens center (slightly offset for each eye)
        center_x = 0.5
        if not is_left_eye:
            center_x = 0.5
        glUniform2f(loc("uCenter"), center_x, 0.5)

        # Scale to fill after distortion
        glUniform2f(loc("uScale"), 1.0, 1.0)

        # Chromatic aberration
        glUniform3f(loc("uChromaOffset"), *self._chroma)

        # Bind texture and draw fullscreen quad
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, texture)
        glUniform1i(loc("uTexture"), 0)

        # Draw fullscreen quad
        glDisable(GL_DEPTH_TEST)
        glBegin(GL_QUADS)
        glVertex2f(-1, -1)
        glVertex2f(1, -1)
        glVertex2f(1, 1)
        glVertex2f(-1, 1)
        glEnd()
        glEnable(GL_DEPTH_TEST)

        glUseProgram(0)

    def set_profile(self, profile: str) -> None:
        """Switch to a predefined distortion profile."""
        if profile in self.PROFILES:
            p = self.PROFILES[profile]
            self._k1 = p["k1"]
            self._k2 = p["k2"]
            self._chroma = p["chroma"]
            logger.info(f"Distortion profile set to '{profile}'")

    @property
    def k1(self) -> float:
        return self._k1

    @k1.setter
    def k1(self, value: float) -> None:
        self._k1 = value

    @property
    def k2(self) -> float:
        return self._k2

    @k2.setter
    def k2(self, value: float) -> None:
        self._k2 = value
