"""
MadhurVision — Gesture Recognizer
===================================
Analyzes hand landmark data per frame to detect 7+ gesture types.
Implements state machine for gesture lifecycle (START → HOLD → RELEASE).

Supported Gestures:
    - Pinch: Thumb tip ↔ Index tip distance < threshold
    - Grab: All fingertips curled toward palm
    - Open Palm: All five fingers extended
    - Swipe Left/Right: Palm centroid velocity exceeds threshold on X-axis
    - Scroll: Two-finger vertical movement
    - Zoom: Two-hand pinch distance change (requires both hands)
"""

import time
import math
import logging
from dataclasses import dataclass
from typing import List, Optional, Tuple, Dict
from collections import deque

from tracking.hand_tracker import HandData, HandTracker
from gestures.gesture_events import (
    GestureType, GesturePhase, GestureEvent, GestureEventBus
)

logger = logging.getLogger("MadhurVision.GestureRecognizer")


@dataclass
class _GestureState:
    """Internal per-hand gesture state tracking."""
    is_pinching: bool = False
    is_grabbing: bool = False
    is_open_palm: bool = False
    pinch_start_pos: Tuple[float, float] = (0.0, 0.0)
    grab_start_pos: Tuple[float, float] = (0.0, 0.0)
    # Position history for velocity calculation
    position_history: deque = None
    last_update: float = 0.0

    def __post_init__(self):
        if self.position_history is None:
            self.position_history = deque(maxlen=10)


class GestureRecognizer:
    """
    Recognizes hand gestures from HandData landmarks.
    
    Processes each frame's hand data, detects gestures using distance/velocity
    thresholds, and publishes events through the GestureEventBus.
    
    Usage:
        bus = GestureEventBus()
        recognizer = GestureRecognizer(bus)
        
        # Subscribe to events
        bus.subscribe(GestureType.PINCH, lambda e: print("Pinch!", e.phase))
        
        # In processing loop:
        hands = hand_tracker.process(frame)
        recognizer.update(hands)
    """

    def __init__(self, event_bus: GestureEventBus):
        from configs.settings import settings

        self._bus = event_bus
        self._settings = settings.gesture

        # Per-hand state (keyed by "Left"/"Right")
        self._hand_states: Dict[str, _GestureState] = {
            "Left": _GestureState(),
            "Right": _GestureState()
        }

        # Two-hand state for zoom
        self._prev_two_hand_distance: Optional[float] = None
        self._is_zooming: bool = False

        # Swipe detection
        self._swipe_cooldown: float = 0.0

        # Frame counter
        self._frame_count: int = 0

        # Active gesture display (for debug/HUD)
        self._active_gestures: List[str] = []

    def update(self, hands: List[HandData]) -> List[GestureEvent]:
        """
        Process hand data for the current frame and detect gestures.
        
        Args:
            hands: List of HandData from HandTracker.process()
            
        Returns:
            List of GestureEvents detected this frame
        """
        self._frame_count += 1
        now = time.perf_counter()
        events: List[GestureEvent] = []
        self._active_gestures.clear()

        # Build hand lookup
        hand_map: Dict[str, HandData] = {}
        for hand in hands:
            hand_map[hand.handedness] = hand

        # Process each hand independently
        for handedness in ("Left", "Right"):
            state = self._hand_states[handedness]
            hand = hand_map.get(handedness)

            if hand is None:
                # Hand disappeared — release any active gestures
                events.extend(self._release_all(handedness, now))
                state.position_history.clear()
                continue

            # Track position history for velocity
            palm = hand.palm_center
            state.position_history.append((palm.x, palm.y, now))
            state.last_update = now

            # ── Pinch Detection ─────────────────────────────────
            pinch_dist = HandTracker.pinch_distance(hand)
            pinch_pos = (
                (hand.thumb_tip.x + hand.index_tip.x) / 2,
                (hand.thumb_tip.y + hand.index_tip.y) / 2
            )

            if not state.is_pinching:
                if pinch_dist < self._settings.pinch_threshold:
                    state.is_pinching = True
                    state.pinch_start_pos = pinch_pos
                    evt = GestureEvent(
                        gesture_type=GestureType.PINCH,
                        phase=GesturePhase.START,
                        position=pinch_pos,
                        hand=handedness,
                        confidence=hand.confidence
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                    self._active_gestures.append(f"PINCH:{handedness}")
            else:
                if pinch_dist > self._settings.pinch_release_threshold:
                    state.is_pinching = False
                    evt = GestureEvent(
                        gesture_type=GestureType.PINCH,
                        phase=GesturePhase.RELEASE,
                        position=pinch_pos,
                        hand=handedness
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                else:
                    # Still pinching — emit HOLD
                    velocity = self._calculate_velocity(state)
                    evt = GestureEvent(
                        gesture_type=GestureType.PINCH,
                        phase=GesturePhase.HOLD,
                        position=pinch_pos,
                        velocity=velocity,
                        hand=handedness
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                    self._active_gestures.append(f"PINCH_HOLD:{handedness}")

            # ── Grab Detection ──────────────────────────────────
            grab_score = HandTracker.grab_score(hand)
            grab_pos = (palm.x, palm.y)

            if not state.is_grabbing:
                if grab_score > 0.7:  # 70% closed
                    state.is_grabbing = True
                    state.grab_start_pos = grab_pos
                    evt = GestureEvent(
                        gesture_type=GestureType.GRAB,
                        phase=GesturePhase.START,
                        position=grab_pos,
                        hand=handedness
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                    self._active_gestures.append(f"GRAB:{handedness}")
            else:
                if grab_score < 0.4:  # Released
                    state.is_grabbing = False
                    evt = GestureEvent(
                        gesture_type=GestureType.GRAB,
                        phase=GesturePhase.RELEASE,
                        position=grab_pos,
                        hand=handedness
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                else:
                    velocity = self._calculate_velocity(state)
                    evt = GestureEvent(
                        gesture_type=GestureType.GRAB,
                        phase=GesturePhase.HOLD,
                        position=grab_pos,
                        velocity=velocity,
                        hand=handedness
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                    self._active_gestures.append(f"GRAB_HOLD:{handedness}")

            # ── Open Palm Detection ─────────────────────────────
            fingers = hand.finger_is_extended()
            all_extended = all(fingers)

            if all_extended and not state.is_open_palm:
                state.is_open_palm = True
                evt = GestureEvent(
                    gesture_type=GestureType.OPEN_PALM,
                    phase=GesturePhase.START,
                    position=(palm.x, palm.y),
                    hand=handedness
                )
                events.append(evt)
                self._bus.publish(evt)
                self._active_gestures.append(f"OPEN_PALM:{handedness}")
            elif not all_extended and state.is_open_palm:
                state.is_open_palm = False
                evt = GestureEvent(
                    gesture_type=GestureType.OPEN_PALM,
                    phase=GesturePhase.RELEASE,
                    position=(palm.x, palm.y),
                    hand=handedness
                )
                events.append(evt)
                self._bus.publish(evt)

            # ── Swipe Detection ─────────────────────────────────
            if now > self._swipe_cooldown:
                velocity = self._calculate_velocity(state)
                vx, vy = velocity

                if abs(vx) > self._settings.swipe_velocity_threshold:
                    if all_extended or sum(fingers) >= 3:
                        swipe_type = GestureType.SWIPE_RIGHT if vx > 0 else GestureType.SWIPE_LEFT
                        evt = GestureEvent(
                            gesture_type=swipe_type,
                            phase=GesturePhase.INSTANT,
                            position=(palm.x, palm.y),
                            velocity=velocity,
                            hand=handedness
                        )
                        events.append(evt)
                        self._bus.publish(evt)
                        self._swipe_cooldown = now + self._settings.debounce_time
                        self._active_gestures.append(f"SWIPE:{handedness}")

            # ── Scroll Detection (two-finger vertical) ──────────
            if fingers[1] and fingers[2] and not fingers[3] and not fingers[4]:
                # Index and middle extended, ring and pinky closed
                velocity = self._calculate_velocity(state)
                vx, vy = velocity
                if abs(vy) > self._settings.scroll_threshold:
                    evt = GestureEvent(
                        gesture_type=GestureType.SCROLL,
                        phase=GesturePhase.HOLD,
                        position=(palm.x, palm.y),
                        velocity=(0.0, vy),
                        hand=handedness
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                    self._active_gestures.append(f"SCROLL:{handedness}")

        # ── Zoom Detection (two hands) ──────────────────────────
        if "Left" in hand_map and "Right" in hand_map:
            left = hand_map["Left"]
            right = hand_map["Right"]

            # Distance between the two index tips
            dist = math.sqrt(
                (left.index_tip.x - right.index_tip.x) ** 2 +
                (left.index_tip.y - right.index_tip.y) ** 2
            )

            if self._prev_two_hand_distance is not None:
                delta = dist - self._prev_two_hand_distance
                if abs(delta) > self._settings.zoom_threshold:
                    scale = dist / self._prev_two_hand_distance if self._prev_two_hand_distance > 0 else 1.0
                    center = (
                        (left.index_tip.x + right.index_tip.x) / 2,
                        (left.index_tip.y + right.index_tip.y) / 2
                    )

                    if not self._is_zooming:
                        self._is_zooming = True
                        phase = GesturePhase.START
                    else:
                        phase = GesturePhase.HOLD

                    evt = GestureEvent(
                        gesture_type=GestureType.ZOOM,
                        phase=phase,
                        position=center,
                        scale=scale,
                        hand="Both"
                    )
                    events.append(evt)
                    self._bus.publish(evt)
                    self._active_gestures.append("ZOOM")

            self._prev_two_hand_distance = dist
        else:
            if self._is_zooming:
                self._is_zooming = False
                evt = GestureEvent(
                    gesture_type=GestureType.ZOOM,
                    phase=GesturePhase.RELEASE,
                    position=(0.5, 0.5),
                    hand="Both"
                )
                events.append(evt)
                self._bus.publish(evt)
            self._prev_two_hand_distance = None

        return events

    def _calculate_velocity(self, state: _GestureState) -> Tuple[float, float]:
        """Calculate palm movement velocity from position history."""
        history = state.position_history
        if len(history) < 2:
            return (0.0, 0.0)

        # Use last 3 points for velocity
        recent = list(history)[-3:]
        x0, y0, t0 = recent[0]
        x1, y1, t1 = recent[-1]
        dt = t1 - t0

        if dt < 0.001:
            return (0.0, 0.0)

        return ((x1 - x0) / dt, (y1 - y0) / dt)

    def _release_all(self, handedness: str, now: float) -> List[GestureEvent]:
        """Release all active gestures for a hand that disappeared."""
        events = []
        state = self._hand_states[handedness]

        if state.is_pinching:
            state.is_pinching = False
            evt = GestureEvent(
                gesture_type=GestureType.PINCH,
                phase=GesturePhase.RELEASE,
                position=state.pinch_start_pos,
                hand=handedness,
                timestamp=now
            )
            events.append(evt)
            self._bus.publish(evt)

        if state.is_grabbing:
            state.is_grabbing = False
            evt = GestureEvent(
                gesture_type=GestureType.GRAB,
                phase=GesturePhase.RELEASE,
                position=state.grab_start_pos,
                hand=handedness,
                timestamp=now
            )
            events.append(evt)
            self._bus.publish(evt)

        if state.is_open_palm:
            state.is_open_palm = False
            evt = GestureEvent(
                gesture_type=GestureType.OPEN_PALM,
                phase=GesturePhase.RELEASE,
                position=(0.5, 0.5),
                hand=handedness,
                timestamp=now
            )
            events.append(evt)
            self._bus.publish(evt)

        return events

    @property
    def active_gestures(self) -> List[str]:
        """List of currently active gesture names (for debug display)."""
        return self._active_gestures.copy()

    @property
    def frame_count(self) -> int:
        return self._frame_count
