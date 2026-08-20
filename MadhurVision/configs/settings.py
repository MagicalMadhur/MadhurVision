"""
MadhurVision — Central Configuration
=====================================
All system-wide settings as a singleton dataclass.
Import via: from configs.settings import settings
"""

from dataclasses import dataclass, field
from typing import Tuple
import json
import os


@dataclass
class DisplaySettings:
    """Display and rendering configuration."""
    width: int = 1920
    height: int = 1080
    fps_target: int = 60
    fullscreen: bool = False
    vsync: bool = True
    # VR side-by-side splits this into two halves
    vr_enabled: bool = False


@dataclass
class CameraSettings:
    """Camera and video input configuration."""
    source: str = "local"  # "local" or "webrtc"
    local_camera_index: int = 0
    resolution: Tuple[int, int] = (1920, 1080)
    fps: int = 30
    # Flip horizontally for mirror-mode (useful for webcam dev)
    mirror: bool = True


@dataclass
class NetworkSettings:
    """WebRTC and networking configuration."""
    server_host: str = "0.0.0.0"
    server_port: int = 8080
    ssl_cert_path: str = "certs/cert.pem"
    ssl_key_path: str = "certs/key.pem"
    stun_server: str = "stun:stun.l.google.com:19302"
    # Maximum latency before warning (ms)
    max_latency_ms: int = 50


@dataclass
class TrackingSettings:
    """Hand and head tracking configuration."""
    # MediaPipe Hands
    min_detection_confidence: float = 0.7
    min_tracking_confidence: float = 0.7
    max_num_hands: int = 2
    # Head tracking
    head_smoothing_factor: float = 0.85  # Complementary filter alpha
    head_sensitivity: float = 1.0


@dataclass
class GestureSettings:
    """Gesture recognition thresholds."""
    # Pinch: distance between thumb tip and index tip (normalized coords)
    pinch_threshold: float = 0.05
    pinch_release_threshold: float = 0.07  # Hysteresis to prevent flicker
    # Grab: all fingertips within this distance of palm center
    grab_threshold: float = 0.10
    # Swipe: minimum velocity (normalized coords per second)
    swipe_velocity_threshold: float = 0.8
    swipe_min_distance: float = 0.15
    # Scroll: two-finger vertical movement threshold
    scroll_threshold: float = 0.02
    # Zoom: two-hand pinch distance change threshold
    zoom_threshold: float = 0.03
    # Debounce: minimum time between gesture events (seconds)
    debounce_time: float = 0.15
    # Calibration file path
    calibration_path: str = "configs/calibration.json"


@dataclass
class DepthSettings:
    """Depth estimation configuration."""
    enabled: bool = True
    # "MiDaS_small" (fast, ~30fps GPU) or "DPT_Large" (accurate, ~5fps)
    model_type: str = "MiDaS_small"
    # Use CUDA if available
    use_cuda: bool = True
    # Process every Nth frame to save performance
    process_interval: int = 3


@dataclass
class VoiceSettings:
    """Voice recognition configuration."""
    enabled: bool = True
    # Path to Vosk model directory (download from https://alphacephei.com/vosk/models)
    model_path: str = "models/vosk-model-small-en-us-0.15"
    sample_rate: int = 16000
    # Wake word (empty string = always listening)
    wake_word: str = ""
    # Auto-download model if not found
    auto_download: bool = True


@dataclass
class VRSettings:
    """VR stereo output configuration."""
    # Interpupillary distance in meters (average human: 0.063m)
    ipd: float = 0.063
    # Barrel distortion coefficients (k1, k2)
    distortion_k1: float = 0.22
    distortion_k2: float = 0.24
    # Field of view (degrees)
    fov: float = 90.0
    # Screen-to-lens distance for distortion calculation
    screen_to_lens: float = 0.042


@dataclass
class SpatialSettings:
    """Spatial computing engine configuration."""
    # Default window size in world-space meters
    default_window_width: float = 0.8
    default_window_height: float = 0.5
    # Default window distance from camera (meters)
    default_window_distance: float = 1.5
    # Maximum number of windows
    max_windows: int = 20
    # Window opacity
    default_opacity: float = 0.92
    # Anchor persistence file
    anchor_file: str = "configs/anchors.json"
    # Near/far clip planes
    near_clip: float = 0.1
    far_clip: float = 100.0


@dataclass
class DesktopSettings:
    """Desktop integration configuration."""
    # Screen capture rate (FPS)
    capture_fps: int = 30
    # Monitor index to capture (0 = primary)
    monitor_index: int = 0
    # PyAutoGUI failsafe (move mouse to corner to abort)
    failsafe: bool = True
    # Mouse sensitivity multiplier
    mouse_sensitivity: float = 1.5


@dataclass
class DebugSettings:
    """Debug and development settings."""
    enabled: bool = False
    show_fps: bool = True
    show_landmarks: bool = True
    show_depth_map: bool = False
    show_gesture_state: bool = True
    show_connection_status: bool = True
    log_level: str = "INFO"  # DEBUG, INFO, WARNING, ERROR
    # Performance profiling
    profile_enabled: bool = False


@dataclass
class Settings:
    """
    Master configuration for MadhurVision.
    
    Usage:
        from configs.settings import settings
        print(settings.display.width)
        settings.gesture.pinch_threshold = 0.06
        settings.save("my_config.json")
    """
    display: DisplaySettings = field(default_factory=DisplaySettings)
    camera: CameraSettings = field(default_factory=CameraSettings)
    network: NetworkSettings = field(default_factory=NetworkSettings)
    tracking: TrackingSettings = field(default_factory=TrackingSettings)
    gesture: GestureSettings = field(default_factory=GestureSettings)
    depth: DepthSettings = field(default_factory=DepthSettings)
    voice: VoiceSettings = field(default_factory=VoiceSettings)
    vr: VRSettings = field(default_factory=VRSettings)
    spatial: SpatialSettings = field(default_factory=SpatialSettings)
    desktop: DesktopSettings = field(default_factory=DesktopSettings)
    debug: DebugSettings = field(default_factory=DebugSettings)

    def save(self, path: str = "configs/settings.json") -> None:
        """Save current settings to JSON file."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = {}
        for field_name in self.__dataclass_fields__:
            sub = getattr(self, field_name)
            data[field_name] = {
                k: v for k, v in sub.__dict__.items()
                if not k.startswith('_')
            }
        with open(path, 'w') as f:
            json.dump(data, f, indent=2, default=str)

    def load(self, path: str = "configs/settings.json") -> None:
        """Load settings from JSON file, merging with defaults."""
        if not os.path.exists(path):
            return
        with open(path, 'r') as f:
            data = json.load(f)
        for section_name, section_data in data.items():
            if hasattr(self, section_name):
                section = getattr(self, section_name)
                for key, value in section_data.items():
                    if hasattr(section, key):
                        # Handle tuple conversion for JSON arrays
                        current = getattr(section, key)
                        if isinstance(current, tuple) and isinstance(value, list):
                            value = tuple(value)
                        setattr(section, key, value)


# ─── Singleton Instance ─────────────────────────────────────────────
# Import this everywhere: from configs.settings import settings
settings = Settings()

# Auto-load settings file if it exists
_settings_path = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "configs", "settings.json"
)
if os.path.exists(_settings_path):
    settings.load(_settings_path)
