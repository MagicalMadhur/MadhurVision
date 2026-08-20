"""
MadhurVision — Desktop Controller
====================================
Maps hand gestures to Windows desktop actions using PyAutoGUI.
Controls mouse, keyboard, and application launching.
"""

import subprocess
import logging
import time
from typing import Tuple, Optional

logger = logging.getLogger("MadhurVision.DesktopController")

try:
    import pyautogui
    pyautogui.FAILSAFE = True
    PYAUTOGUI_AVAILABLE = True
except ImportError:
    PYAUTOGUI_AVAILABLE = False
    logger.warning("PyAutoGUI not installed. Desktop control disabled.")

from configs.settings import settings
from gestures.gesture_events import (
    GestureType, GesturePhase, GestureEvent, GestureEventBus
)


class DesktopController:
    """
    Maps hand gestures to Windows desktop control.
    
    Gesture mappings:
        - Pinch START → Left mouse click (press)
        - Pinch RELEASE → Left mouse release
        - Pinch HOLD + move → Mouse drag
        - Scroll gesture → Mouse scroll
        - Open Palm → Release all buttons
    
    Also provides:
        - App launching via subprocess
        - Keyboard shortcut execution
        - Screen coordinate mapping
    
    Usage:
        controller = DesktopController(event_bus)
        
        # In main loop, controller auto-responds to gestures
        # Or call directly:
        controller.move_mouse(0.5, 0.5)  # Center screen
        controller.click()
        controller.launch_app("chrome")
    """

    # Common app paths on Windows
    APP_PATHS = {
        "chrome": r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        "firefox": r"C:\Program Files\Mozilla Firefox\firefox.exe",
        "notepad": "notepad.exe",
        "explorer": "explorer.exe",
        "cmd": "cmd.exe",
        "powershell": "powershell.exe",
        "calculator": "calc.exe",
        "paint": "mspaint.exe",
        "settings": "ms-settings:",
    }

    def __init__(self, event_bus: Optional[GestureEventBus] = None):
        if not PYAUTOGUI_AVAILABLE:
            logger.warning("DesktopController running in dry-run mode (no PyAutoGUI)")

        self._enabled = settings.desktop.failsafe
        self._sensitivity = settings.desktop.mouse_sensitivity
        self._screen_w, self._screen_h = self._get_screen_size()

        # State
        self._mouse_pressed = False
        self._last_cursor_pos: Tuple[int, int] = (0, 0)

        # Subscribe to gestures
        if event_bus:
            event_bus.subscribe(GestureType.PINCH, self._on_pinch)
            event_bus.subscribe(GestureType.SCROLL, self._on_scroll)
            event_bus.subscribe(GestureType.OPEN_PALM, self._on_open_palm)

    def _get_screen_size(self) -> Tuple[int, int]:
        """Get screen resolution."""
        if PYAUTOGUI_AVAILABLE:
            return pyautogui.size()
        return (1920, 1080)

    def move_mouse(self, nx: float, ny: float) -> None:
        """
        Move mouse to normalized coordinates (0-1).
        
        Args:
            nx: Normalized X (0=left, 1=right)
            ny: Normalized Y (0=top, 1=bottom)
        """
        if not PYAUTOGUI_AVAILABLE:
            return

        x = int(nx * self._screen_w)
        y = int(ny * self._screen_h)
        x = max(0, min(x, self._screen_w - 1))
        y = max(0, min(y, self._screen_h - 1))

        pyautogui.moveTo(x, y, _pause=False)
        self._last_cursor_pos = (x, y)

    def click(self, button: str = "left") -> None:
        """Perform a mouse click."""
        if PYAUTOGUI_AVAILABLE:
            pyautogui.click(button=button, _pause=False)

    def press_mouse(self, button: str = "left") -> None:
        """Press and hold mouse button."""
        if PYAUTOGUI_AVAILABLE and not self._mouse_pressed:
            pyautogui.mouseDown(button=button, _pause=False)
            self._mouse_pressed = True

    def release_mouse(self, button: str = "left") -> None:
        """Release mouse button."""
        if PYAUTOGUI_AVAILABLE and self._mouse_pressed:
            pyautogui.mouseUp(button=button, _pause=False)
            self._mouse_pressed = False

    def scroll(self, amount: int) -> None:
        """Scroll the mouse wheel."""
        if PYAUTOGUI_AVAILABLE:
            pyautogui.scroll(amount, _pause=False)

    def type_text(self, text: str) -> None:
        """Type text using keyboard."""
        if PYAUTOGUI_AVAILABLE:
            pyautogui.typewrite(text, interval=0.02)

    def hotkey(self, *keys) -> None:
        """Press a keyboard shortcut (e.g., hotkey('ctrl', 'c'))."""
        if PYAUTOGUI_AVAILABLE:
            pyautogui.hotkey(*keys)

    def launch_app(self, app_name: str, url: str = "") -> bool:
        """
        Launch an application by name.
        
        Args:
            app_name: App identifier (see APP_PATHS) or full path
            url: Optional URL for browsers
            
        Returns:
            True if launch succeeded
        """
        app_name_lower = app_name.lower().strip()

        # Check known apps
        if app_name_lower in self.APP_PATHS:
            path = self.APP_PATHS[app_name_lower]
        else:
            path = app_name

        try:
            if url and app_name_lower in ("chrome", "firefox"):
                subprocess.Popen([path, url])
            elif path.startswith("ms-"):
                # Windows URI scheme
                subprocess.Popen(["start", path], shell=True)
            else:
                subprocess.Popen([path])
            logger.info(f"Launched: {app_name}")
            return True
        except FileNotFoundError:
            logger.warning(f"App not found: {path}")
            # Try system search
            try:
                subprocess.Popen(["start", app_name_lower], shell=True)
                return True
            except Exception:
                return False
        except Exception as e:
            logger.error(f"Failed to launch {app_name}: {e}")
            return False

    def take_screenshot(self, path: str = "screenshot.png") -> str:
        """Take a screenshot and save to file."""
        if PYAUTOGUI_AVAILABLE:
            screenshot = pyautogui.screenshot()
            screenshot.save(path)
            logger.info(f"Screenshot saved: {path}")
            return path
        return ""

    # ─── Gesture Handlers ────────────────────────────────────────

    def _on_pinch(self, event: GestureEvent) -> None:
        """Map pinch to mouse click/drag."""
        if event.phase == GesturePhase.START:
            self.move_mouse(*event.position)
            self.press_mouse()
        elif event.phase == GesturePhase.HOLD:
            self.move_mouse(*event.position)
        elif event.phase == GesturePhase.RELEASE:
            self.release_mouse()

    def _on_scroll(self, event: GestureEvent) -> None:
        """Map scroll gesture to mouse scroll."""
        _, vy = event.velocity
        # Scale velocity to scroll amount
        amount = int(vy * -10)  # Negative because screen Y is inverted
        if abs(amount) > 0:
            self.scroll(amount)

    def _on_open_palm(self, event: GestureEvent) -> None:
        """Open palm = release everything."""
        if event.phase == GesturePhase.START:
            self.release_mouse()
