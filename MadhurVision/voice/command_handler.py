"""
MadhurVision — Command Handler
=================================
Maps recognized voice text to application actions.
Supports fuzzy matching for natural language tolerance.
"""

import logging
from typing import Callable, Dict, Optional, List, Tuple
from difflib import SequenceMatcher

logger = logging.getLogger("MadhurVision.CommandHandler")


class CommandHandler:
    """
    Maps recognized speech text to executable actions.
    
    Built-in commands:
        "open chrome"         → Launch Chrome browser
        "open youtube"        → Launch Chrome with YouTube
        "close window"        → Close the focused window
        "move window left"    → Reposition focused window left
        "move window right"   → Reposition focused window right
        "new window"          → Create a new desktop stream window
        "play music"          → Media play/pause
        "screenshot"          → Take a screenshot
        "minimize"            → Minimize focused window
        "show desktop"        → Minimize all windows
        "grid layout"         → Arrange windows in grid
        "arc layout"          → Arrange windows in arc
        "calibrate"           → Start gesture calibration
    
    Custom commands can be registered via register_command().
    Fuzzy matching handles pronunciation variations.
    
    Usage:
        handler = CommandHandler(window_manager, desktop_controller)
        voice_engine.on_text(handler.handle)
    """

    def __init__(self, window_manager=None, desktop_controller=None):
        self._wm = window_manager
        self._dc = desktop_controller
        self._commands: Dict[str, Callable] = {}
        self._min_confidence = 0.6  # Minimum fuzzy match score
        self._last_command = ""
        self._command_count = 0

        # Register built-in commands
        self._register_builtins()

    def _register_builtins(self) -> None:
        """Register all built-in voice commands."""

        def cmd_open_chrome():
            if self._dc:
                self._dc.launch_app("chrome")

        def cmd_open_youtube():
            if self._dc:
                self._dc.launch_app("chrome", "https://www.youtube.com")

        def cmd_open_notepad():
            if self._dc:
                self._dc.launch_app("notepad")

        def cmd_close_window():
            if self._wm:
                win = self._wm.get_focused_window()
                if win:
                    self._wm.close_window(win.id)

        def cmd_new_window():
            if self._wm:
                from windows.window_types import create_window
                win = create_window("desktop", title="Desktop Stream")
                self._wm._windows[win.id or f"win_{self._wm._window_counter + 1}"] = win

        def cmd_minimize():
            if self._wm:
                win = self._wm.get_focused_window()
                if win:
                    win.minimize()

        def cmd_move_left():
            if self._wm:
                win = self._wm.get_focused_window()
                if win:
                    from rendering.spatial_scene import Vector3
                    win.move(Vector3(-0.3, 0, 0))

        def cmd_move_right():
            if self._wm:
                win = self._wm.get_focused_window()
                if win:
                    from rendering.spatial_scene import Vector3
                    win.move(Vector3(0.3, 0, 0))

        def cmd_screenshot():
            if self._dc:
                self._dc.take_screenshot()

        def cmd_play_music():
            if self._dc:
                self._dc.hotkey('playpause')

        def cmd_grid_layout():
            if self._wm:
                self._wm.layout_grid()

        def cmd_arc_layout():
            if self._wm:
                self._wm.layout_arc()

        def cmd_show_desktop():
            if self._wm:
                for win in self._wm.windows:
                    win.minimize()

        # Register commands with multiple phrasings
        command_map = {
            "open chrome": cmd_open_chrome,
            "launch chrome": cmd_open_chrome,
            "open browser": cmd_open_chrome,
            "open youtube": cmd_open_youtube,
            "play youtube": cmd_open_youtube,
            "open notepad": cmd_open_notepad,
            "close window": cmd_close_window,
            "close this": cmd_close_window,
            "close": cmd_close_window,
            "new window": cmd_new_window,
            "create window": cmd_new_window,
            "add window": cmd_new_window,
            "minimize": cmd_minimize,
            "minimize window": cmd_minimize,
            "move window left": cmd_move_left,
            "move left": cmd_move_left,
            "move window right": cmd_move_right,
            "move right": cmd_move_right,
            "take screenshot": cmd_screenshot,
            "screenshot": cmd_screenshot,
            "capture screen": cmd_screenshot,
            "play music": cmd_play_music,
            "pause music": cmd_play_music,
            "play pause": cmd_play_music,
            "grid layout": cmd_grid_layout,
            "arrange grid": cmd_grid_layout,
            "arc layout": cmd_arc_layout,
            "arrange arc": cmd_arc_layout,
            "show desktop": cmd_show_desktop,
            "minimize all": cmd_show_desktop,
        }

        for phrase, action in command_map.items():
            self._commands[phrase] = action

    def register_command(self, phrase: str, action: Callable) -> None:
        """
        Register a custom voice command.
        
        Args:
            phrase: The trigger phrase (lowercase)
            action: Callable to execute when phrase is detected
        """
        self._commands[phrase.lower()] = action
        logger.info(f"Registered command: '{phrase}'")

    def handle(self, text: str) -> Optional[str]:
        """
        Process recognized text and execute matching command.
        Uses fuzzy matching for tolerance to recognition errors.
        
        Args:
            text: Recognized speech text
            
        Returns:
            Name of executed command, or None if no match
        """
        text = text.lower().strip()
        if not text:
            return None

        # 1. Try exact match first
        if text in self._commands:
            self._execute(text, self._commands[text])
            return text

        # 2. Try substring match
        for phrase, action in self._commands.items():
            if phrase in text:
                self._execute(phrase, action)
                return phrase

        # 3. Fuzzy matching
        best_match, best_score = self._fuzzy_match(text)
        if best_match and best_score >= self._min_confidence:
            self._execute(best_match, self._commands[best_match])
            return best_match

        logger.debug(f"No command match for: '{text}' (best: '{best_match}' @ {best_score:.2f})")
        return None

    def _fuzzy_match(self, text: str) -> Tuple[str, float]:
        """Find best fuzzy match for input text."""
        best_phrase = ""
        best_score = 0.0

        for phrase in self._commands:
            score = SequenceMatcher(None, text, phrase).ratio()
            if score > best_score:
                best_score = score
                best_phrase = phrase

        return best_phrase, best_score

    def _execute(self, command_name: str, action: Callable) -> None:
        """Execute a command and log it."""
        self._last_command = command_name
        self._command_count += 1
        logger.info(f"Executing voice command: '{command_name}'")

        try:
            action()
        except Exception as e:
            logger.error(f"Command '{command_name}' failed: {e}")

    @property
    def last_command(self) -> str:
        return self._last_command

    @property
    def command_count(self) -> int:
        return self._command_count

    @property
    def available_commands(self) -> List[str]:
        """List all registered command phrases."""
        return sorted(set(self._commands.keys()))
