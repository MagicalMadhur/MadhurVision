"""
MadhurVision — Depth Estimator
=================================
Monocular depth estimation using MiDaS models via PyTorch Hub.

Supports:
    - MiDaS_small: Fast (~30 FPS on GPU), lower accuracy. Good for real-time.
    - DPT_Hybrid: Medium accuracy/speed.
    - DPT_Large: Highest accuracy (~5 FPS on GPU). For offline/analysis.

Note: MiDaS produces RELATIVE depth (not metric). Objects are ranked
by distance but actual meters are not provided.
"""

import logging
import time
from typing import Optional, Tuple

import cv2
import numpy as np

logger = logging.getLogger("MadhurVision.DepthEstimator")

try:
    import torch
    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False
    logger.warning("PyTorch not installed. Depth estimation disabled.")
    logger.warning("Install with: pip install torch torchvision")


class DepthEstimator:
    """
    Real-time monocular depth estimation using MiDaS.
    
    Generates depth maps from single RGB images. Uses GPU (CUDA) when available
    for real-time performance.
    
    Usage:
        estimator = DepthEstimator()
        
        # Process every Nth frame for performance:
        depth_map = estimator.estimate(rgb_frame)
        
        # Get colored visualization:
        depth_colored = estimator.colorize(depth_map)
        
        # Get depth at specific pixel:
        depth_value = estimator.depth_at(depth_map, x=500, y=300)
    """

    VALID_MODELS = ("MiDaS_small", "DPT_Hybrid", "DPT_Large")

    def __init__(self):
        if not TORCH_AVAILABLE:
            raise RuntimeError("PyTorch not installed. Run: pip install torch torchvision")

        from configs.settings import settings
        self._settings = settings.depth

        model_type = self._settings.model_type
        if model_type not in self.VALID_MODELS:
            logger.warning(f"Unknown model '{model_type}', falling back to MiDaS_small")
            model_type = "MiDaS_small"

        # Select device
        if self._settings.use_cuda and torch.cuda.is_available():
            self._device = torch.device("cuda")
            logger.info(f"Depth estimation using CUDA: {torch.cuda.get_device_name(0)}")
        else:
            self._device = torch.device("cpu")
            logger.info("Depth estimation using CPU (may be slow)")

        # Load model from PyTorch Hub
        logger.info(f"Loading MiDaS model: {model_type}...")
        self._model = torch.hub.load("intel-isl/MiDaS", model_type)
        self._model.to(self._device)
        self._model.eval()

        # Load transforms
        midas_transforms = torch.hub.load("intel-isl/MiDaS", "transforms")
        if model_type == "MiDaS_small":
            self._transform = midas_transforms.small_transform
        elif model_type == "DPT_Hybrid":
            self._transform = midas_transforms.dpt_transform
        else:
            self._transform = midas_transforms.dpt_transform

        # Performance tracking
        self._frame_count = 0
        self._total_inference_time = 0.0
        self._last_depth_map: Optional[np.ndarray] = None

        logger.info(f"DepthEstimator initialized ({model_type} on {self._device})")

    def estimate(self, rgb_frame: np.ndarray) -> np.ndarray:
        """
        Estimate depth from an RGB frame.
        
        Args:
            rgb_frame: RGB numpy array (H, W, 3).
                      Convert from BGR: cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        
        Returns:
            Depth map as float32 numpy array (H, W). Higher values = closer.
            Values are relative (not metric distance).
        """
        start = time.perf_counter()

        # Apply MiDaS transform
        input_batch = self._transform(rgb_frame).to(self._device)

        # Inference
        with torch.no_grad():
            prediction = self._model(input_batch)

            # Resize to original frame dimensions
            prediction = torch.nn.functional.interpolate(
                prediction.unsqueeze(1),
                size=rgb_frame.shape[:2],
                mode="bicubic",
                align_corners=False
            ).squeeze()

        depth_map = prediction.cpu().numpy()

        # Track performance
        self._frame_count += 1
        elapsed = time.perf_counter() - start
        self._total_inference_time += elapsed

        self._last_depth_map = depth_map
        return depth_map

    def estimate_if_due(self, rgb_frame: np.ndarray, frame_id: int) -> Optional[np.ndarray]:
        """
        Estimate depth only every Nth frame (per settings.depth.process_interval).
        Returns cached depth map on skipped frames.
        
        Args:
            rgb_frame: RGB frame
            frame_id: Current frame counter
            
        Returns:
            Depth map (fresh or cached), or None if no depth available yet.
        """
        if frame_id % self._settings.process_interval == 0:
            return self.estimate(rgb_frame)
        return self._last_depth_map

    @staticmethod
    def colorize(depth_map: np.ndarray, colormap: int = cv2.COLORMAP_MAGMA) -> np.ndarray:
        """
        Convert depth map to colored visualization.
        
        Args:
            depth_map: Float depth map from estimate()
            colormap: OpenCV colormap (MAGMA, INFERNO, PLASMA, JET, etc.)
            
        Returns:
            BGR colored depth image (H, W, 3) uint8
        """
        # Normalize to 0-255
        normalized = cv2.normalize(
            depth_map, None, 0, 255,
            norm_type=cv2.NORM_MINMAX, dtype=cv2.CV_8U
        )
        colored = cv2.applyColorMap(normalized, colormap)
        return colored

    @staticmethod
    def depth_at(depth_map: np.ndarray, x: int, y: int) -> float:
        """
        Get relative depth value at a specific pixel.
        
        Args:
            depth_map: Depth map from estimate()
            x, y: Pixel coordinates
            
        Returns:
            Relative depth value (higher = closer)
        """
        h, w = depth_map.shape[:2]
        x = max(0, min(x, w - 1))
        y = max(0, min(y, h - 1))
        return float(depth_map[y, x])

    @staticmethod
    def depth_at_normalized(
        depth_map: np.ndarray,
        nx: float, ny: float
    ) -> float:
        """
        Get depth at normalized coordinates (0-1).
        
        Args:
            depth_map: Depth map from estimate()
            nx, ny: Normalized coordinates (0.0 to 1.0)
            
        Returns:
            Relative depth value
        """
        h, w = depth_map.shape[:2]
        x = int(nx * w)
        y = int(ny * h)
        return DepthEstimator.depth_at(depth_map, x, y)

    @property
    def avg_inference_ms(self) -> float:
        """Average inference time in milliseconds."""
        if self._frame_count == 0:
            return 0.0
        return (self._total_inference_time / self._frame_count) * 1000.0

    @property
    def fps(self) -> float:
        """Estimated depth estimation FPS."""
        avg_ms = self.avg_inference_ms
        return 1000.0 / avg_ms if avg_ms > 0 else 0.0

    @property
    def last_depth_map(self) -> Optional[np.ndarray]:
        """Most recently computed depth map."""
        return self._last_depth_map
