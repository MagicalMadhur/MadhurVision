"""
╔══════════════════════════════════════════════════════════════════╗
║                      MADHUR VISION                               ║
║             DIY Spatial Computing Platform                        ║
║                                                                   ║
║  A Vision Pro-inspired system using:                              ║
║    iPhone camera → WebRTC → PC → OpenGL → VR Headset             ║
║                                                                   ║
║  Features:                                                        ║
║    • Real-world passthrough camera feed                           ║
║    • Floating 3D windows with spatial anchoring                   ║
║    • Hand tracking with 7 gesture types                           ║
║    • Head tracking via phone gyroscope                            ║
║    • Voice commands (offline via Vosk)                            ║
║    • Side-by-side VR stereo output                                ║
║    • Desktop integration (mouse/keyboard control)                 ║
║    • Real-time depth estimation (MiDaS)                           ║
║                                                                   ║
║  Usage:                                                           ║
║    python main.py                          # Default mode          ║
║    python main.py --mode vr                # VR stereo output      ║
║    python main.py --mode debug             # Debug dashboard       ║
║    python main.py --camera local           # Use webcam             ║
║    python main.py --camera webrtc          # Use iPhone             ║
║    python main.py --no-voice               # Disable voice          ║
║    python main.py --no-depth               # Disable depth          ║
║    python main.py --calibrate              # Run calibration        ║
╚══════════════════════════════════════════════════════════════════╝
"""

import sys
import os
import time
import argparse
import logging
import asyncio
import threading

# Add project root to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cv2
import numpy as np

from configs.settings import settings


def setup_logging(level: str = "INFO") -> None:
    """Configure logging for the application."""
    log_format = (
        "%(asctime)s │ %(name)-30s │ %(levelname)-7s │ %(message)s"
    )
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format=log_format,
        datefmt="%H:%M:%S"
    )


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Madhur Vision — DIY Spatial Computing Platform",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python main.py                        Start with webcam, desktop mode
  python main.py --mode vr              VR stereo output
  python main.py --camera webrtc        Use iPhone camera via WebRTC
  python main.py --mode debug           Show debug dashboard
  python main.py --calibrate            Run gesture calibration
  python main.py --no-voice --no-depth  Lightweight mode
        """
    )
    parser.add_argument(
        "--mode", choices=["desktop", "vr", "debug"],
        default="desktop",
        help="Rendering mode (default: desktop)"
    )
    parser.add_argument(
        "--camera", choices=["local", "webrtc", "native"],
        default="local",
        help="Camera source (default: local webcam)"
    )
    parser.add_argument(
        "--no-voice", action="store_true",
        help="Disable voice recognition"
    )
    parser.add_argument(
        "--no-depth", action="store_true",
        help="Disable depth estimation"
    )
    parser.add_argument(
        "--no-desktop", action="store_true",
        help="Disable desktop control (no mouse/keyboard)"
    )
    parser.add_argument(
        "--calibrate", action="store_true",
        help="Run gesture calibration and exit"
    )
    parser.add_argument(
        "--fullscreen", action="store_true",
        help="Start in fullscreen mode"
    )
    parser.add_argument(
        "--width", type=int, default=1920,
        help="Window width (default: 1920)"
    )
    parser.add_argument(
        "--height", type=int, default=1080,
        help="Window height (default: 1080)"
    )
    parser.add_argument(
        "--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging level"
    )
    return parser.parse_args()


def run_calibration():
    """Run gesture calibration and exit."""
    from gestures.calibration import run_calibration
    run_calibration()


def start_webrtc_server(camera_manager):
    """Start WebRTC server in a separate asyncio event loop."""
    from networking.webrtc_server import WebRTCServer

    server = WebRTCServer(camera_manager)
    camera_manager.set_webrtc_server(server)

    loop = asyncio.new_event_loop()

    def run_server():
        asyncio.set_event_loop(loop)
        loop.run_until_complete(server.start())
        loop.run_forever()

    thread = threading.Thread(target=run_server, name="WebRTCServer", daemon=True)
    thread.start()

    return server, loop

def start_native_server(camera_manager):
    """Start Native iOS Socket Server."""
    from networking.socket_server import NativeSocketServer
    
    server = NativeSocketServer()
    camera_manager.set_native_server(server)
    server.start()
    
    return server



def main():
    """Main application entry point."""
    args = parse_args()
    setup_logging(args.log_level)
    logger = logging.getLogger("MadhurVision")

    # ── Banner ───────────────────────────────────────────────
    logger.info("=" * 60)
    logger.info("   MADHUR VISION — Spatial Computing Platform")
    logger.info("=" * 60)
    logger.info(f"   Mode: {args.mode}")
    logger.info(f"   Camera: {args.camera}")
    logger.info(f"   Voice: {'enabled' if not args.no_voice else 'disabled'}")
    logger.info(f"   Depth: {'enabled' if not args.no_depth else 'disabled'}")
    logger.info("=" * 60)

    # ── Handle calibration ───────────────────────────────────
    if args.calibrate:
        run_calibration()
        return

    # ── Apply CLI settings ───────────────────────────────────
    settings.camera.source = args.camera
    settings.display.fullscreen = args.fullscreen
    settings.display.width = args.width
    settings.display.height = args.height
    settings.display.vr_enabled = (args.mode == "vr")
    
    # In VR mode, mirroring causes severe brain/depth disorientation
    if settings.display.vr_enabled:
        settings.camera.mirror = False
        
    settings.voice.enabled = not args.no_voice
    settings.depth.enabled = not args.no_depth
    settings.debug.enabled = (args.mode == "debug")

    # ── Initialize subsystems ────────────────────────────────
    logger.info("Initializing subsystems...")

    # 1. Camera
    from cameras.camera_manager import CameraManager
    camera = CameraManager()

    # 2. WebRTC / Native (if needed)
    webrtc_server = None
    native_server = None
    
    if args.camera == "webrtc":
        try:
            webrtc_server, webrtc_loop = start_webrtc_server(camera)
            logger.info("WebRTC server started — open URL on iPhone Safari")
        except Exception as e:
            logger.error(f"WebRTC failed: {e}")
            logger.info("Falling back to local camera")
            settings.camera.source = "local"
    elif args.camera == "native":
        try:
            native_server = start_native_server(camera)
            logger.info("Native iOS Socket Server started — connect using MadhurVision app")
        except Exception as e:
            logger.error(f"Native server failed: {e}")
            settings.camera.source = "local"

    camera.start()

    # 3. Hand Tracker
    from tracking.hand_tracker import HandTracker
    try:
        hand_tracker = HandTracker()
    except Exception as e:
        logger.error(f"Hand tracker init failed: {e}")
        hand_tracker = None

    # 4. Head Tracker
    from tracking.head_tracker import HeadTracker
    head_tracker = HeadTracker()

    # 5. Gesture System
    from gestures.gesture_events import GestureEventBus
    from gestures.gesture_recognizer import GestureRecognizer
    gesture_bus = GestureEventBus()
    gesture_recognizer = GestureRecognizer(gesture_bus) if hand_tracker else None

    # 6. Spatial Scene
    from rendering.spatial_scene import SpatialScene
    scene = SpatialScene()

    # 7. Window Manager
    from windows.window_manager import WindowManager
    from windows.window_types import create_window
    window_manager = WindowManager(scene, gesture_bus)

    # Create initial windows
    from windows.spatial_window import WindowType
    desktop_win = window_manager.create_window(title="Desktop Stream", window_type=WindowType.DESKTOP_STREAM)
    
    from rendering.spatial_scene import Vector3
    status_win = create_window("status", position=Vector3(-0.8, 0.5, -1.0))
    window_manager._windows[f"win_{window_manager._window_counter + 1}"] = status_win

    # 8. Desktop Controller
    desktop_controller = None
    if not args.no_desktop:
        from desktop.desktop_controller import DesktopController
        desktop_controller = DesktopController(gesture_bus)

    # 9. Screen Capture
    from desktop.screen_capture import ScreenCapture
    try:
        screen_capture = ScreenCapture()
        screen_capture.start()
    except Exception as e:
        logger.warning(f"Screen capture unavailable: {e}")
        screen_capture = None

    # 10. Voice Engine
    voice_engine = None
    command_handler = None
    if settings.voice.enabled:
        from voice.voice_engine import VoiceEngine
        from voice.command_handler import CommandHandler
        voice_engine = VoiceEngine()
        command_handler = CommandHandler(window_manager, desktop_controller)
        voice_engine.on_text(command_handler.handle)
        try:
            voice_engine.start()
        except Exception as e:
            logger.warning(f"Voice engine unavailable: {e}")
            voice_engine = None

    # 11. Depth Estimator
    depth_estimator = None
    if settings.depth.enabled:
        try:
            from depth.depth_estimator import DepthEstimator
            depth_estimator = DepthEstimator()
        except Exception as e:
            logger.warning(f"Depth estimation unavailable: {e}")

    # 12. Render Engine
    from rendering.engine import RenderEngine
    engine = RenderEngine(scene)
    try:
        engine.init()
    except Exception as e:
        import traceback
        logger.error(f"Render engine failed to init: {e}")
        logger.debug(f"Render engine crash traceback:\n{traceback.format_exc()}")
        logger.info("Falling back to OpenCV-only mode")
        engine = None

    # 13. VR Renderer
    sbs_renderer = None
    if args.mode == "vr" and engine:
        from vr.sbs_renderer import SBSRenderer
        sbs_renderer = SBSRenderer(scene)

    # 14. Debug Dashboard
    debug_dashboard = None
    if args.mode == "debug" or settings.debug.enabled:
        from tools.debug_dashboard import DebugDashboard
        debug_dashboard = DebugDashboard()

    # Create content textures
    desktop_texture = engine.create_content_texture() if engine else 0

    logger.info("All subsystems initialized. Starting main loop...")
    logger.info("Press ESC to quit | F11 for fullscreen | D for debug")

    # ── Main Loop ────────────────────────────────────────────
    frame_count = 0
    last_time = time.perf_counter()
    depth_map = None

    try:
        while engine is None or engine.running:
            dt = time.perf_counter() - last_time
            last_time = time.perf_counter()
            frame_count += 1

            # ── 1. Capture ───────────────────────────────────
            frame_data = camera.get_frame()
            bgr_frame = frame_data.frame if frame_data else None

            # Update head tracker from orientation data
            if frame_data and frame_data.orientation:
                o = frame_data.orientation
                head_tracker.update(
                    alpha=o.get("yaw", 0),
                    beta=o.get("pitch", 0),
                    gamma=o.get("roll", 0)
                )

            # ── 2. Track ─────────────────────────────────────
            hands = []
            if hand_tracker and bgr_frame is not None:
                rgb_frame = cv2.cvtColor(bgr_frame, cv2.COLOR_BGR2RGB)
                hands = hand_tracker.process(rgb_frame)

                # Draw landmarks on frame for passthrough display
                if settings.debug.show_landmarks:
                    bgr_frame = hand_tracker.draw_landmarks(bgr_frame.copy())

            # ── 3. Recognize Gestures ────────────────────────
            if gesture_recognizer and hands:
                gesture_recognizer.update(hands)

            # ── 4. Depth Estimation ──────────────────────────
            if depth_estimator and bgr_frame is not None:
                rgb = cv2.cvtColor(bgr_frame, cv2.COLOR_BGR2RGB)
                depth_map = depth_estimator.estimate_if_due(rgb, frame_count)

            # ── 5. Update Scene ──────────────────────────────
            yaw, pitch, roll = head_tracker.get_orientation()
            scene.update_camera(yaw, pitch, roll)
            window_manager.update(dt)

            # Update desktop texture
            if screen_capture and engine:
                desktop_frame = screen_capture.get_frame()
                if desktop_frame is not None:
                    engine.update_texture(desktop_texture, desktop_frame)

            # ── 6. Render ────────────────────────────────────
            if engine:
                engine.begin_frame()

                if sbs_renderer:
                    # VR mode: stereo rendering
                    def render_eye(eye_offset):
                        engine.render_background(bgr_frame)
                        for win in window_manager.visible_windows:
                            tex = desktop_texture if win.id == desktop_win.id else 0
                            engine.render_window(win, tex)
                        # Render hand cursor
                        for hand in hands:
                            lm = [(l.x, l.y, l.z) for l in hand.landmarks]
                            engine.render_hand_cursor(lm, hand.handedness)

                    sbs_renderer.render(engine.width, engine.height)
                else:
                    # Desktop mode: single view
                    engine.render_background(bgr_frame)

                    for win in window_manager.visible_windows:
                        tex = desktop_texture if win.id == desktop_win.id else 0
                        engine.render_window(win, tex)

                    for hand in hands:
                        lm = [(l.x, l.y, l.z) for l in hand.landmarks]
                        engine.render_hand_cursor(lm, hand.handedness)

                # HUD
                hud_info = {
                    "fps": engine.fps,
                    "hands": len(hands),
                    "gesture": ", ".join(gesture_recognizer.active_gestures) if gesture_recognizer else "N/A",
                    "connection": camera.source,
                    "latency": camera.latency_ms,
                    "voice": command_handler.last_command if command_handler else "disabled",
                }
                engine.render_hud(hud_info)
                engine.end_frame()

                if webrtc_server or native_server:
                    import pygame
                    surface = pygame.display.get_surface()
                    if surface:
                        # Pygame surfarray is (width, height, 3) RGB
                        rgb_array = pygame.surfarray.pixels3d(surface)
                        rgb_array = rgb_array.transpose([1, 0, 2])
                        bgr_array = cv2.cvtColor(rgb_array, cv2.COLOR_RGB2BGR)
                        
                        if webrtc_server:
                            # Resize for lower network latency on WiFi
                            small_bgr = cv2.resize(bgr_array, (960, 540))
                            webrtc_server.push_rendered_frame(small_bgr)
                        if native_server:
                            # Send full HD frame over USB
                            native_server.push_rendered_frame(bgr_array)

            # ── 7. Debug Dashboard ───────────────────────────
            if debug_dashboard:
                debug_dashboard.update(
                    camera_frame=bgr_frame,
                    depth_map=depth_map,
                    active_gestures=gesture_recognizer.active_gestures if gesture_recognizer else [],
                    fps=engine.fps if engine else 0,
                    latency=camera.latency_ms,
                    info={
                        "Windows": str(window_manager.window_count),
                        "Camera": camera.source,
                        "Voice": voice_engine.last_text if voice_engine else "off",
                        "Head": f"{head_tracker.get_orientation_degrees()[0]:.0f}°"
                    }
                )
                debug_dashboard.show()

            # ── Fallback: OpenCV-only mode ───────────────────
            if engine is None and bgr_frame is not None:
                display_frame = bgr_frame.copy()
                
                # Draw miniature desktop stream in the center (Picture-in-Picture)
                if screen_capture:
                    desktop_img = screen_capture.get_frame()
                    if desktop_img is not None:
                        dh, dw = display_frame.shape[0] // 2, display_frame.shape[1] // 2
                        small_desktop = cv2.resize(desktop_img, (dw, dh))
                        cy, cx = display_frame.shape[0] // 2, display_frame.shape[1] // 2
                        sy, sx = cy - (dh // 2), cx - (dw // 2)
                        display_frame[sy:sy+dh, sx:sx+dw] = small_desktop

                # If VR mode was requested but OpenGL failed, create a simple OpenCV split-screen
                if args.mode == "vr":
                    h, w = display_frame.shape[:2]
                    half_width = w // 2
                    half_frame = cv2.resize(display_frame, (half_width, h))
                    # Add a vertical divider line
                    cv2.line(half_frame, (half_width - 1, 0), (half_width - 1, h), (50, 50, 50), 2)
                    display_frame = np.hstack((half_frame, half_frame))
                    cv2.imshow("Madhur Vision (VR Fallback)", display_frame)
                else:
                    cv2.imshow("Madhur Vision (OpenCV)", display_frame)
                    
                if webrtc_server:
                    small_bgr = cv2.resize(display_frame, (960, 540))
                    webrtc_server.push_rendered_frame(small_bgr)
                if native_server:
                    native_server.push_rendered_frame(display_frame)
                    
                key = cv2.waitKey(1) & 0xFF
                if key == 27:
                    break
                elif key == ord('d') or key == ord('D'):
                    if debug_dashboard is None:
                        from tools.debug_dashboard import DebugDashboard
                        debug_dashboard = DebugDashboard()
                    debug_dashboard.toggle()

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
    except Exception as e:
        logger.error(f"Main loop error: {e}", exc_info=True)
    finally:
        # ── Shutdown ─────────────────────────────────────────
        logger.info("Shutting down...")

        if voice_engine:
            voice_engine.stop()
        if screen_capture:
            screen_capture.stop()
        camera.stop()
        if hand_tracker:
            hand_tracker.close()
        if debug_dashboard:
            debug_dashboard.close()
        if engine:
            engine.shutdown()
        if webrtc_server:
            asyncio.run_coroutine_threadsafe(
                webrtc_server.stop(), webrtc_loop
            )

        # Save state
        try:
            scene.save_anchors()
            window_manager.save_layout()
            settings.save()
        except Exception as e:
            logger.warning(f"Failed to save state: {e}")

        logger.info("Madhur Vision stopped. Goodbye! 👋")


if __name__ == "__main__":
    main()
