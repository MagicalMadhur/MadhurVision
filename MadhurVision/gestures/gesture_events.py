"""
MadhurVision — Gesture Event System
=====================================
Observer-pattern event bus for decoupling gesture detection from action.

Components subscribe to specific gesture types and receive events when
those gestures are detected, without knowing about the tracking internals.
"""

import time
import logging
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Callable, Dict, List, Optional, Tuple, Any

logger = logging.getLogger("MadhurVision.GestureEvents")


class GestureType(Enum):
    """All supported gesture types."""
    PINCH = auto()
    GRAB = auto()
    OPEN_PALM = auto()
    SWIPE_LEFT = auto()
    SWIPE_RIGHT = auto()
    SCROLL = auto()
    ZOOM = auto()
    # Extended gestures
    POINT = auto()
    THUMBS_UP = auto()
    PEACE = auto()


class GesturePhase(Enum):
    """Lifecycle phase of a gesture."""
    START = auto()    # Gesture just began
    HOLD = auto()     # Gesture is being maintained
    RELEASE = auto()  # Gesture just ended
    INSTANT = auto()  # One-shot gesture (swipe, etc.)


@dataclass
class GestureEvent:
    """
    Data payload for a gesture event.
    
    Attributes:
        gesture_type: Which gesture was detected
        phase: START, HOLD, RELEASE, or INSTANT
        position: (x, y) normalized position where gesture occurred
        velocity: (vx, vy) movement velocity (for swipes/drags)
        scale: Scale factor (for zoom gesture)
        hand: "Left" or "Right"
        confidence: Detection confidence (0-1)
        timestamp: Time of detection
        data: Any additional gesture-specific data
    """
    gesture_type: GestureType
    phase: GesturePhase
    position: Tuple[float, float] = (0.0, 0.0)
    velocity: Tuple[float, float] = (0.0, 0.0)
    scale: float = 1.0
    hand: str = "Right"
    confidence: float = 1.0
    timestamp: float = field(default_factory=time.perf_counter)
    data: Optional[Dict[str, Any]] = None


# Type alias for gesture event callbacks
GestureCallback = Callable[[GestureEvent], None]


class GestureEventBus:
    """
    Publish-subscribe event bus for gesture events.
    
    Usage:
        bus = GestureEventBus()
        
        # Subscribe to pinch events:
        def on_pinch(event: GestureEvent):
            if event.phase == GesturePhase.START:
                print(f"Pinch at {event.position}!")
        
        bus.subscribe(GestureType.PINCH, on_pinch)
        
        # Publish (called by GestureRecognizer):
        bus.publish(GestureEvent(
            gesture_type=GestureType.PINCH,
            phase=GesturePhase.START,
            position=(0.5, 0.5)
        ))
        
        # Subscribe to all events:
        bus.subscribe_all(lambda e: print(f"Gesture: {e.gesture_type}"))
    """

    def __init__(self):
        self._subscribers: Dict[GestureType, List[GestureCallback]] = {}
        self._global_subscribers: List[GestureCallback] = []
        self._event_history: List[GestureEvent] = []
        self._max_history: int = 100

    def subscribe(self, gesture_type: GestureType, callback: GestureCallback) -> None:
        """Subscribe to a specific gesture type."""
        if gesture_type not in self._subscribers:
            self._subscribers[gesture_type] = []
        self._subscribers[gesture_type].append(callback)
        logger.debug(f"Subscribed to {gesture_type.name}")

    def subscribe_all(self, callback: GestureCallback) -> None:
        """Subscribe to ALL gesture types."""
        self._global_subscribers.append(callback)

    def unsubscribe(self, gesture_type: GestureType, callback: GestureCallback) -> None:
        """Remove a subscription."""
        if gesture_type in self._subscribers:
            self._subscribers[gesture_type] = [
                cb for cb in self._subscribers[gesture_type] if cb != callback
            ]

    def publish(self, event: GestureEvent) -> None:
        """
        Publish a gesture event to all subscribers.
        
        Args:
            event: GestureEvent to dispatch
        """
        # Store in history
        self._event_history.append(event)
        if len(self._event_history) > self._max_history:
            self._event_history.pop(0)

        # Notify type-specific subscribers
        if event.gesture_type in self._subscribers:
            for callback in self._subscribers[event.gesture_type]:
                try:
                    callback(event)
                except Exception as e:
                    logger.error(f"Error in gesture callback: {e}")

        # Notify global subscribers
        for callback in self._global_subscribers:
            try:
                callback(event)
            except Exception as e:
                logger.error(f"Error in global gesture callback: {e}")

    @property
    def last_event(self) -> Optional[GestureEvent]:
        """Most recent gesture event."""
        return self._event_history[-1] if self._event_history else None

    @property
    def history(self) -> List[GestureEvent]:
        """Recent gesture event history."""
        return self._event_history.copy()

    def clear_history(self) -> None:
        """Clear event history."""
        self._event_history.clear()
