"""
MadhurVision — Future Module Interfaces
==========================================
Abstract base classes for planned AI/ML features.
These define the API contracts that future implementations must follow,
allowing the rest of the system to be built against stable interfaces.
"""

from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Tuple, Any
import numpy as np


class EyeTracker(ABC):
    """
    Eye tracking interface (future).
    
    Implementation candidates:
        - MediaPipe Face Mesh iris landmarks
        - Tobii eye tracker SDK
        - Custom CNN model
    """

    @abstractmethod
    def process(self, frame: np.ndarray) -> Optional[Dict]:
        """
        Process a frame and detect eye gaze.
        
        Returns:
            Dict with:
                gaze_point: (x, y) normalized screen gaze point
                left_eye: (x, y, z) left eye position
                right_eye: (x, y, z) right eye position
                blink_left: bool
                blink_right: bool
                pupil_diameter: float (mm)
        """
        ...

    @abstractmethod
    def calibrate(self) -> bool:
        """Run eye tracking calibration. Returns True if successful."""
        ...


class FaceTracker(ABC):
    """
    Face tracking interface (future).
    
    Implementation candidates:
        - MediaPipe Face Mesh (468 landmarks)
        - dlib face detector
        - Apple ARKit blend shapes
    """

    @abstractmethod
    def process(self, frame: np.ndarray) -> Optional[Dict]:
        """
        Process a frame and detect face.
        
        Returns:
            Dict with:
                landmarks: List of (x, y, z) for facial landmarks
                head_pose: (pitch, yaw, roll) in radians
                expression: Dict of expression blend shapes (0-1)
                    e.g., {"smile": 0.8, "brow_up": 0.3}
                bounding_box: (x, y, w, h) face bounding box
        """
        ...


class BodyTracker(ABC):
    """
    Full body tracking interface (future).
    
    Implementation candidates:
        - MediaPipe Pose (33 landmarks)
        - OpenPose
        - MoveNet
    """

    @abstractmethod
    def process(self, frame: np.ndarray) -> Optional[Dict]:
        """
        Process a frame and detect body pose.
        
        Returns:
            Dict with:
                landmarks: List of (x, y, z) for 33 body landmarks
                confidence: per-landmark confidence scores
                skeleton: List of bone connections
        """
        ...


class AIAssistant(ABC):
    """
    AI conversational assistant interface (future).
    
    Implementation candidates:
        - OpenAI GPT API
        - Google Gemini API
        - Local LLM (llama.cpp, Ollama)
    """

    @abstractmethod
    def query(self, text: str, context: Optional[Dict] = None) -> str:
        """
        Send a text query to the AI assistant.
        
        Args:
            text: User's query
            context: Optional context (current windows, gestures, etc.)
            
        Returns:
            AI response text
        """
        ...

    @abstractmethod
    def stream_query(self, text: str) -> Any:
        """Stream response tokens for real-time display."""
        ...


class ObjectRecognizer(ABC):
    """
    Object recognition interface (future).
    
    Implementation candidates:
        - YOLOv8
        - MediaPipe Object Detection
        - Custom ONNX model
    """

    @abstractmethod
    def detect(self, frame: np.ndarray) -> List[Dict]:
        """
        Detect objects in a frame.
        
        Returns:
            List of dicts with:
                label: str (object class name)
                confidence: float (0-1)
                bbox: (x, y, w, h) bounding box
                position_3d: Optional (x, y, z) estimated world position
        """
        ...


class RoomScanner(ABC):
    """
    Room scanning / 3D reconstruction interface (future).
    
    Implementation candidates:
        - Open3D point cloud reconstruction
        - NeRF (Neural Radiance Fields)
        - TSDF volume integration
    """

    @abstractmethod
    def process_frame(
        self, color: np.ndarray, depth: np.ndarray,
        pose: Tuple[float, ...]
    ) -> None:
        """Integrate a color+depth frame into the 3D model."""
        ...

    @abstractmethod
    def get_mesh(self) -> Any:
        """Get the current reconstructed 3D mesh."""
        ...

    @abstractmethod
    def get_planes(self) -> List[Dict]:
        """
        Detect planes in the reconstruction.
        
        Returns:
            List of detected planes with:
                normal: (x, y, z)
                center: (x, y, z)
                bounds: (width, height)
                type: "floor" | "wall" | "ceiling" | "table" | "unknown"
        """
        ...
