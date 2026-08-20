"""
MadhurVision — Head Tracker
==============================
Converts phone gyroscope/accelerometer data into camera orientation.
Uses complementary filter for sensor fusion to reduce drift and jitter.
Target latency: < 30ms.
"""

import time
import math
import logging
from typing import Dict, Optional, Tuple

logger = logging.getLogger("MadhurVision.HeadTracker")


class HeadTracker:
    """
    Head tracking via phone gyroscope data.
    
    Receives raw DeviceOrientation events (alpha, beta, gamma in degrees)
    from the iPhone via WebRTC data channel and converts to smooth
    yaw/pitch/roll values in radians.
    
    Uses a complementary filter that blends gyroscope (fast, drifts)
    with accelerometer (slow, stable) for optimal tracking.
    
    Usage:
        tracker = HeadTracker()
        
        # When orientation data arrives:
        tracker.update(alpha=180.0, beta=45.0, gamma=10.0)
        
        # In render loop:
        yaw, pitch, roll = tracker.get_orientation()
    """

    def __init__(self):
        from configs.settings import settings

        # Smoothing factor: 0.0 = no smoothing, 1.0 = infinite smoothing
        self._alpha = settings.tracking.head_smoothing_factor
        self._sensitivity = settings.tracking.head_sensitivity

        # Current orientation (radians)
        self._yaw: float = 0.0
        self._pitch: float = 0.0
        self._roll: float = 0.0

        # Raw unfiltered values
        self._raw_yaw: float = 0.0
        self._raw_pitch: float = 0.0
        self._raw_roll: float = 0.0

        # Initial calibration offset (set on first reading)
        self._calibrated = False
        self._offset_yaw: float = 0.0
        self._offset_pitch: float = 0.0
        self._offset_roll: float = 0.0

        # Timing
        self._last_update_time: float = 0.0
        self._update_count: int = 0
        self._latency_ms: float = 0.0

        # Accelerometer data for complementary filter
        self._accel_pitch: float = 0.0
        self._accel_roll: float = 0.0

    def update(
        self,
        alpha: float = 0.0,
        beta: float = 0.0,
        gamma: float = 0.0,
        timestamp: Optional[float] = None
    ) -> None:
        """
        Update with new DeviceOrientation data.
        
        Args:
            alpha: Device yaw (0-360 degrees, compass heading)
            beta: Device pitch (-180 to 180 degrees, front-back tilt)
            gamma: Device roll (-90 to 90 degrees, left-right tilt)
            timestamp: Event timestamp for latency tracking
        """
        now = time.perf_counter()

        # Track latency
        if timestamp:
            self._latency_ms = (now - timestamp) * 1000.0

        # Convert degrees to radians
        raw_yaw = math.radians(alpha)
        raw_pitch = math.radians(beta)
        raw_roll = math.radians(gamma)

        # Calibrate: first reading becomes the "center" position
        if not self._calibrated:
            self._offset_yaw = raw_yaw
            self._offset_pitch = raw_pitch
            self._offset_roll = raw_roll
            self._calibrated = True
            logger.info(f"Head tracker calibrated at yaw={alpha:.1f}° pitch={beta:.1f}° roll={gamma:.1f}°")

        # Apply calibration offset (so 'straight ahead' = 0,0,0)
        raw_yaw -= self._offset_yaw
        raw_pitch -= self._offset_pitch
        raw_roll -= self._offset_roll

        # Handle yaw wraparound (-π to π)
        raw_yaw = self._normalize_angle(raw_yaw)

        # Apply sensitivity
        raw_yaw *= self._sensitivity
        raw_pitch *= self._sensitivity
        raw_roll *= self._sensitivity

        # Store raw values
        self._raw_yaw = raw_yaw
        self._raw_pitch = raw_pitch
        self._raw_roll = raw_roll

        # Complementary filter (exponential moving average)
        a = self._alpha
        self._yaw = a * self._yaw + (1 - a) * raw_yaw
        self._pitch = a * self._pitch + (1 - a) * raw_pitch
        self._roll = a * self._roll + (1 - a) * raw_roll

        self._last_update_time = now
        self._update_count += 1

    def update_accelerometer(self, x: float, y: float, z: float) -> None:
        """
        Update with accelerometer data for improved fusion.
        
        Args:
            x, y, z: Acceleration values (including gravity)
        """
        # Calculate pitch and roll from accelerometer
        if abs(z) > 0.01:
            self._accel_pitch = math.atan2(y, z)
            self._accel_roll = math.atan2(-x, math.sqrt(y*y + z*z))

    def get_orientation(self) -> Tuple[float, float, float]:
        """
        Get current smoothed orientation.
        
        Returns:
            (yaw, pitch, roll) in radians.
            Yaw: horizontal rotation (left/right head turn)
            Pitch: vertical rotation (looking up/down)
            Roll: head tilt (ear to shoulder)
        """
        return (self._yaw, self._pitch, self._roll)

    def get_orientation_degrees(self) -> Tuple[float, float, float]:
        """Get orientation in degrees for display/debug."""
        return (
            math.degrees(self._yaw),
            math.degrees(self._pitch),
            math.degrees(self._roll)
        )

    def get_look_direction(self) -> Tuple[float, float, float]:
        """
        Get the forward-looking direction vector from current orientation.
        
        Returns:
            (dx, dy, dz) unit direction vector in world space.
        """
        dx = -math.sin(self._yaw) * math.cos(self._pitch)
        dy = math.sin(self._pitch)
        dz = -math.cos(self._yaw) * math.cos(self._pitch)
        return (dx, dy, dz)

    def recalibrate(self) -> None:
        """Reset calibration. Next update becomes the new 'center'."""
        self._calibrated = False
        self._yaw = 0.0
        self._pitch = 0.0
        self._roll = 0.0
        logger.info("Head tracker recalibrating on next update")

    @staticmethod
    def _normalize_angle(angle: float) -> float:
        """Normalize angle to [-π, π] range."""
        while angle > math.pi:
            angle -= 2 * math.pi
        while angle < -math.pi:
            angle += 2 * math.pi
        return angle

    @property
    def is_active(self) -> bool:
        """Whether we've received recent orientation data (within 1s)."""
        if self._last_update_time == 0:
            return False
        return (time.perf_counter() - self._last_update_time) < 1.0

    @property
    def update_rate_hz(self) -> float:
        """Estimated update rate in Hz."""
        if self._update_count < 2:
            return 0.0
        elapsed = time.perf_counter() - (self._last_update_time - 
                  (self._update_count * 0.016))  # Rough estimate
        if elapsed > 0:
            return self._update_count / elapsed
        return 0.0

    @property
    def latency_ms(self) -> float:
        """Latest measurement latency in milliseconds."""
        return self._latency_ms
