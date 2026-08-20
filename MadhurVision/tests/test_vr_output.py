"""
MadhurVision — VR SBS Output Test
Renders a test scene in side-by-side stereo mode.
Run: python -m tests.test_vr_output
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import math
import time

try:
    import pygame
    from pygame.locals import *
    from OpenGL.GL import *
    from OpenGL.GLU import *
except ImportError:
    print("ERROR: pygame and PyOpenGL required")
    print("Install: pip install pygame PyOpenGL PyOpenGL-accelerate")
    sys.exit(1)

from configs.settings import settings


def draw_test_scene():
    """Draw a simple 3D test scene."""
    # Floor grid
    glColor4f(0.3, 0.3, 0.3, 1.0)
    glBegin(GL_LINES)
    for i in range(-5, 6):
        glVertex3f(i, -1, -5)
        glVertex3f(i, -1, 5)
        glVertex3f(-5, -1, i)
        glVertex3f(5, -1, i)
    glEnd()

    # Colored cubes at various positions
    cubes = [
        ((-1.5, 0, -3), (1.0, 0.3, 0.3)),   # Red
        ((0, 0, -4),     (0.3, 1.0, 0.3)),   # Green
        ((1.5, 0, -3),   (0.3, 0.3, 1.0)),   # Blue
        ((0, 1, -5),     (1.0, 1.0, 0.3)),   # Yellow
    ]

    for pos, color in cubes:
        glPushMatrix()
        glTranslatef(*pos)
        glColor4f(*color, 0.9)

        # Simple cube
        size = 0.3
        glBegin(GL_QUADS)
        # Front
        glVertex3f(-size, -size, size)
        glVertex3f(size, -size, size)
        glVertex3f(size, size, size)
        glVertex3f(-size, size, size)
        # Back
        glVertex3f(-size, -size, -size)
        glVertex3f(-size, size, -size)
        glVertex3f(size, size, -size)
        glVertex3f(size, -size, -size)
        # Top
        glVertex3f(-size, size, -size)
        glVertex3f(-size, size, size)
        glVertex3f(size, size, size)
        glVertex3f(size, size, -size)
        # Bottom
        glVertex3f(-size, -size, -size)
        glVertex3f(size, -size, -size)
        glVertex3f(size, -size, size)
        glVertex3f(-size, -size, size)
        glEnd()

        glPopMatrix()

    # Text label simulation (colored bar)
    glDisable(GL_DEPTH_TEST)
    glMatrixMode(GL_PROJECTION)
    glPushMatrix()
    glLoadIdentity()
    glOrtho(0, 1, 0, 1, -1, 1)
    glMatrixMode(GL_MODELVIEW)
    glPushMatrix()
    glLoadIdentity()

    glColor4f(0.1, 0.1, 0.15, 0.7)
    glBegin(GL_QUADS)
    glVertex2f(0, 0.92)
    glVertex2f(0.4, 0.92)
    glVertex2f(0.4, 1.0)
    glVertex2f(0, 1.0)
    glEnd()

    glColor4f(0.5, 0.7, 1.0, 0.8)
    glBegin(GL_QUADS)
    glVertex2f(0.02, 0.95)
    glVertex2f(0.15, 0.95)
    glVertex2f(0.15, 0.97)
    glVertex2f(0.02, 0.97)
    glEnd()

    glMatrixMode(GL_PROJECTION)
    glPopMatrix()
    glMatrixMode(GL_MODELVIEW)
    glPopMatrix()
    glEnable(GL_DEPTH_TEST)


def main():
    print("=" * 50)
    print("  VR SBS Output Test — MadhurVision")
    print("  Press ESC to quit")
    print("  Arrow keys to look around")
    print("=" * 50)

    width, height = 1920, 1080
    ipd = settings.vr.ipd
    fov = settings.vr.fov

    pygame.init()
    screen = pygame.display.set_mode((width, height), OPENGL | DOUBLEBUF)
    pygame.display.set_caption("VR SBS Test — MadhurVision")
    clock = pygame.time.Clock()

    glEnable(GL_DEPTH_TEST)
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glClearColor(0.02, 0.02, 0.04, 1.0)

    yaw, pitch = 0.0, 0.0
    running = True

    while running:
        for event in pygame.event.get():
            if event.type == QUIT:
                running = False
            elif event.type == KEYDOWN:
                if event.key == K_ESCAPE:
                    running = False

        # Keyboard look
        keys = pygame.key.get_pressed()
        if keys[K_LEFT]:
            yaw += 1.5
        if keys[K_RIGHT]:
            yaw -= 1.5
        if keys[K_UP]:
            pitch = min(pitch + 1.0, 45)
        if keys[K_DOWN]:
            pitch = max(pitch - 1.0, -45)

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

        half_w = width // 2
        half_ipd = ipd / 2.0

        for eye_idx in range(2):
            # Set viewport for each eye
            if eye_idx == 0:
                glViewport(0, 0, half_w, height)
                eye_offset = -half_ipd
            else:
                glViewport(half_w, 0, half_w, height)
                eye_offset = half_ipd

            aspect = half_w / height

            # Projection
            glMatrixMode(GL_PROJECTION)
            glLoadIdentity()
            gluPerspective(fov, aspect, 0.1, 100.0)

            # View
            glMatrixMode(GL_MODELVIEW)
            glLoadIdentity()
            glRotatef(-pitch, 1, 0, 0)
            glRotatef(-yaw, 0, 1, 0)
            glTranslatef(-eye_offset, 0, 0)

            draw_test_scene()

        # Separator
        glViewport(0, 0, width, height)
        glDisable(GL_DEPTH_TEST)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(0, width, height, 0, -1, 1)
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()
        glColor4f(0, 0, 0, 1)
        glLineWidth(2)
        glBegin(GL_LINES)
        glVertex2f(width // 2, 0)
        glVertex2f(width // 2, height)
        glEnd()
        glEnable(GL_DEPTH_TEST)

        pygame.display.flip()
        clock.tick(60)

    pygame.quit()
    print("VR test complete.")


if __name__ == "__main__":
    main()
