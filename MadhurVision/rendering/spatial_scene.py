"""
MadhurVision — Spatial Scene Graph
=====================================
3D coordinate system, spatial anchors, and scene management.

Coordinate System: Right-handed, Y-up
    +X = right
    +Y = up
    +Z = toward viewer (out of screen)
    
Units: Meters (1.0 = 1 meter in physical space)
"""

import json
import math
import os
import logging
from dataclasses import dataclass, field
from typing import List, Optional, Dict, Tuple

logger = logging.getLogger("MadhurVision.SpatialScene")


# ─── Math Primitives ─────────────────────────────────────────────────

@dataclass
class Vector3:
    """3D vector / point."""
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def __add__(self, other: 'Vector3') -> 'Vector3':
        return Vector3(self.x + other.x, self.y + other.y, self.z + other.z)

    def __sub__(self, other: 'Vector3') -> 'Vector3':
        return Vector3(self.x - other.x, self.y - other.y, self.z - other.z)

    def __mul__(self, scalar: float) -> 'Vector3':
        return Vector3(self.x * scalar, self.y * scalar, self.z * scalar)

    def __neg__(self) -> 'Vector3':
        return Vector3(-self.x, -self.y, -self.z)

    def dot(self, other: 'Vector3') -> float:
        return self.x * other.x + self.y * other.y + self.z * other.z

    def cross(self, other: 'Vector3') -> 'Vector3':
        return Vector3(
            self.y * other.z - self.z * other.y,
            self.z * other.x - self.x * other.z,
            self.x * other.y - self.y * other.x
        )

    def length(self) -> float:
        return math.sqrt(self.x**2 + self.y**2 + self.z**2)

    def normalized(self) -> 'Vector3':
        l = self.length()
        if l < 1e-8:
            return Vector3(0, 0, 0)
        return Vector3(self.x / l, self.y / l, self.z / l)

    def distance_to(self, other: 'Vector3') -> float:
        return (self - other).length()

    def lerp(self, other: 'Vector3', t: float) -> 'Vector3':
        """Linear interpolation between self and other."""
        return Vector3(
            self.x + (other.x - self.x) * t,
            self.y + (other.y - self.y) * t,
            self.z + (other.z - self.z) * t
        )

    def to_list(self) -> List[float]:
        return [self.x, self.y, self.z]

    def to_tuple(self) -> Tuple[float, float, float]:
        return (self.x, self.y, self.z)

    @staticmethod
    def from_list(data: List[float]) -> 'Vector3':
        return Vector3(data[0], data[1], data[2] if len(data) > 2 else 0.0)

    # Common vectors
    @staticmethod
    def zero() -> 'Vector3': return Vector3(0, 0, 0)
    @staticmethod
    def one() -> 'Vector3': return Vector3(1, 1, 1)
    @staticmethod
    def up() -> 'Vector3': return Vector3(0, 1, 0)
    @staticmethod
    def right() -> 'Vector3': return Vector3(1, 0, 0)
    @staticmethod
    def forward() -> 'Vector3': return Vector3(0, 0, -1)


@dataclass
class Vector2:
    """2D vector for window sizing."""
    x: float = 0.0
    y: float = 0.0

    def to_tuple(self) -> Tuple[float, float]:
        return (self.x, self.y)


@dataclass
class Quaternion:
    """Quaternion for 3D rotation (w, x, y, z)."""
    w: float = 1.0
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def __mul__(self, other: 'Quaternion') -> 'Quaternion':
        """Quaternion multiplication (rotation composition)."""
        return Quaternion(
            w=self.w*other.w - self.x*other.x - self.y*other.y - self.z*other.z,
            x=self.w*other.x + self.x*other.w + self.y*other.z - self.z*other.y,
            y=self.w*other.y - self.x*other.z + self.y*other.w + self.z*other.x,
            z=self.w*other.z + self.x*other.y - self.y*other.x + self.z*other.w
        )

    def normalized(self) -> 'Quaternion':
        l = math.sqrt(self.w**2 + self.x**2 + self.y**2 + self.z**2)
        if l < 1e-8:
            return Quaternion()
        return Quaternion(self.w/l, self.x/l, self.y/l, self.z/l)

    def rotate_vector(self, v: Vector3) -> Vector3:
        """Rotate a Vector3 by this quaternion."""
        qv = Quaternion(0, v.x, v.y, v.z)
        conj = Quaternion(self.w, -self.x, -self.y, -self.z)
        result = self * qv * conj
        return Vector3(result.x, result.y, result.z)

    def to_euler(self) -> Vector3:
        """Convert to Euler angles (pitch, yaw, roll) in radians."""
        # Roll (x-axis rotation)
        sinr_cosp = 2 * (self.w * self.x + self.y * self.z)
        cosr_cosp = 1 - 2 * (self.x**2 + self.y**2)
        roll = math.atan2(sinr_cosp, cosr_cosp)

        # Pitch (y-axis rotation)
        sinp = 2 * (self.w * self.y - self.z * self.x)
        sinp = max(-1.0, min(1.0, sinp))
        pitch = math.asin(sinp)

        # Yaw (z-axis rotation)
        siny_cosp = 2 * (self.w * self.z + self.x * self.y)
        cosy_cosp = 1 - 2 * (self.y**2 + self.z**2)
        yaw = math.atan2(siny_cosp, cosy_cosp)

        return Vector3(pitch, yaw, roll)

    def to_matrix_4x4(self) -> List[float]:
        """Convert to 4x4 rotation matrix (column-major for OpenGL)."""
        xx = self.x * self.x
        xy = self.x * self.y
        xz = self.x * self.z
        xw = self.x * self.w
        yy = self.y * self.y
        yz = self.y * self.z
        yw = self.y * self.w
        zz = self.z * self.z
        zw = self.z * self.w

        return [
            1 - 2*(yy+zz), 2*(xy+zw),     2*(xz-yw),     0,
            2*(xy-zw),      1 - 2*(xx+zz), 2*(yz+xw),     0,
            2*(xz+yw),      2*(yz-xw),     1 - 2*(xx+yy), 0,
            0,              0,             0,              1
        ]

    def slerp(self, other: 'Quaternion', t: float) -> 'Quaternion':
        """Spherical linear interpolation."""
        dot = self.w*other.w + self.x*other.x + self.y*other.y + self.z*other.z
        
        # If negative dot, negate one to take shorter path
        if dot < 0:
            other = Quaternion(-other.w, -other.x, -other.y, -other.z)
            dot = -dot

        if dot > 0.9995:
            # Very close, use linear interpolation
            return Quaternion(
                self.w + t * (other.w - self.w),
                self.x + t * (other.x - self.x),
                self.y + t * (other.y - self.y),
                self.z + t * (other.z - self.z)
            ).normalized()

        theta = math.acos(dot)
        sin_theta = math.sin(theta)
        wa = math.sin((1 - t) * theta) / sin_theta
        wb = math.sin(t * theta) / sin_theta

        return Quaternion(
            wa * self.w + wb * other.w,
            wa * self.x + wb * other.x,
            wa * self.y + wb * other.y,
            wa * self.z + wb * other.z
        )

    @staticmethod
    def from_euler(pitch: float, yaw: float, roll: float) -> 'Quaternion':
        """Create from Euler angles (radians)."""
        cy = math.cos(yaw * 0.5)
        sy = math.sin(yaw * 0.5)
        cp = math.cos(pitch * 0.5)
        sp = math.sin(pitch * 0.5)
        cr = math.cos(roll * 0.5)
        sr = math.sin(roll * 0.5)

        return Quaternion(
            w=cr*cp*cy + sr*sp*sy,
            x=sr*cp*cy - cr*sp*sy,
            y=cr*sp*cy + sr*cp*sy,
            z=cr*cp*sy - sr*sp*cy
        )

    @staticmethod
    def identity() -> 'Quaternion':
        return Quaternion(1, 0, 0, 0)

    def to_list(self) -> List[float]:
        return [self.w, self.x, self.y, self.z]


# ─── Spatial Anchor ──────────────────────────────────────────────────

@dataclass
class SpatialAnchor:
    """
    Binds a virtual object to a physical location.
    
    Anchors persist across sessions so windows stay attached to their
    physical positions (e.g., browser attached to wall, clock on desk).
    """
    id: str = ""
    position: Vector3 = field(default_factory=Vector3.zero)
    rotation: Quaternion = field(default_factory=Quaternion.identity)
    label: str = ""  # Human-readable description
    created_at: float = 0.0

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "position": self.position.to_list(),
            "rotation": self.rotation.to_list(),
            "label": self.label,
            "created_at": self.created_at
        }

    @staticmethod
    def from_dict(data: dict) -> 'SpatialAnchor':
        return SpatialAnchor(
            id=data.get("id", ""),
            position=Vector3.from_list(data.get("position", [0, 0, 0])),
            rotation=Quaternion(*data.get("rotation", [1, 0, 0, 0])),
            label=data.get("label", ""),
            created_at=data.get("created_at", 0.0)
        )


# ─── Scene Graph ─────────────────────────────────────────────────────

class SpatialScene:
    """
    3D scene graph managing all spatial objects and anchors.
    
    Provides:
        - Anchor management (create, persist, load)
        - Camera transform (from head tracking)
        - Ray casting for gesture→window hit testing
        - Frustum culling for rendering optimization
    """

    def __init__(self):
        from configs.settings import settings

        self._anchors: Dict[str, SpatialAnchor] = {}
        self._anchor_file = settings.spatial.anchor_file
        self._anchor_counter = 0

        # Camera state
        self._camera_position = Vector3(0, 0, 0)
        self._camera_rotation = Quaternion.identity()
        self._camera_fov = settings.vr.fov

        # Near/far clip planes
        self._near = settings.spatial.near_clip
        self._far = settings.spatial.far_clip

        # Load saved anchors
        self._load_anchors()

    def create_anchor(
        self,
        position: Vector3,
        rotation: Optional[Quaternion] = None,
        label: str = ""
    ) -> SpatialAnchor:
        """Create a new spatial anchor at the given position."""
        import time
        self._anchor_counter += 1
        anchor = SpatialAnchor(
            id=f"anchor_{self._anchor_counter}",
            position=position,
            rotation=rotation or Quaternion.identity(),
            label=label,
            created_at=time.time()
        )
        self._anchors[anchor.id] = anchor
        logger.info(f"Created anchor '{anchor.id}' at {position.to_tuple()}")
        return anchor

    def get_anchor(self, anchor_id: str) -> Optional[SpatialAnchor]:
        return self._anchors.get(anchor_id)

    def remove_anchor(self, anchor_id: str) -> None:
        if anchor_id in self._anchors:
            del self._anchors[anchor_id]

    @property
    def anchors(self) -> Dict[str, SpatialAnchor]:
        return self._anchors

    def update_camera(self, yaw: float, pitch: float, roll: float) -> None:
        """Update camera orientation from head tracking data."""
        self._camera_rotation = Quaternion.from_euler(pitch, yaw, roll)

    def set_camera_position(self, position: Vector3) -> None:
        self._camera_position = position

    @property
    def camera_position(self) -> Vector3:
        return self._camera_position

    @property
    def camera_rotation(self) -> Quaternion:
        return self._camera_rotation

    def get_view_matrix(self) -> List[float]:
        """Get 4x4 view matrix for OpenGL (column-major)."""
        # Inverse of camera transform
        rot = self._camera_rotation
        inv_rot = Quaternion(rot.w, -rot.x, -rot.y, -rot.z)
        inv_pos = inv_rot.rotate_vector(-self._camera_position)

        m = inv_rot.to_matrix_4x4()
        # Set translation
        m[12] = inv_pos.x
        m[13] = inv_pos.y
        m[14] = inv_pos.z
        return m

    def get_projection_matrix(self, aspect: float) -> List[float]:
        """Get perspective projection matrix (column-major)."""
        fov_rad = math.radians(self._camera_fov)
        f = 1.0 / math.tan(fov_rad / 2.0)
        n = self._near
        far = self._far
        nf = n - far

        return [
            f / aspect, 0, 0, 0,
            0, f, 0, 0,
            0, 0, (far + n) / nf, -1,
            0, 0, (2 * far * n) / nf, 0
        ]

    def screen_to_ray(
        self,
        nx: float, ny: float,
        screen_width: int, screen_height: int
    ) -> Tuple[Vector3, Vector3]:
        """
        Cast a ray from screen coordinates into the scene.
        
        Args:
            nx, ny: Normalized screen coordinates (0-1)
            screen_width, screen_height: Screen dimensions
            
        Returns:
            (ray_origin, ray_direction) in world space
        """
        aspect = screen_width / screen_height
        fov_rad = math.radians(self._camera_fov)

        # Convert to NDC (-1 to 1)
        ndc_x = (nx * 2.0) - 1.0
        ndc_y = 1.0 - (ny * 2.0)

        # Calculate direction in camera space
        tan_half_fov = math.tan(fov_rad / 2.0)
        dir_x = ndc_x * aspect * tan_half_fov
        dir_y = ndc_y * tan_half_fov
        dir_z = -1.0

        direction = Vector3(dir_x, dir_y, dir_z).normalized()

        # Transform to world space
        world_dir = self._camera_rotation.rotate_vector(direction)
        return (self._camera_position, world_dir)

    def ray_intersect_plane(
        self,
        ray_origin: Vector3, ray_dir: Vector3,
        plane_pos: Vector3, plane_normal: Vector3
    ) -> Optional[Vector3]:
        """
        Ray-plane intersection test.
        
        Returns:
            Intersection point, or None if parallel/behind
        """
        denom = plane_normal.dot(ray_dir)
        if abs(denom) < 1e-6:
            return None

        t = (plane_pos - ray_origin).dot(plane_normal) / denom
        if t < 0:
            return None

        return ray_origin + ray_dir * t

    def save_anchors(self) -> None:
        """Persist anchors to disk."""
        os.makedirs(os.path.dirname(self._anchor_file) or ".", exist_ok=True)
        data = {
            aid: anchor.to_dict()
            for aid, anchor in self._anchors.items()
        }
        with open(self._anchor_file, 'w') as f:
            json.dump(data, f, indent=2)
        logger.info(f"Saved {len(data)} anchors to {self._anchor_file}")

    def _load_anchors(self) -> None:
        """Load persisted anchors from disk."""
        if not os.path.exists(self._anchor_file):
            return
        try:
            with open(self._anchor_file, 'r') as f:
                data = json.load(f)
            for aid, adict in data.items():
                self._anchors[aid] = SpatialAnchor.from_dict(adict)
                self._anchor_counter = max(
                    self._anchor_counter,
                    int(aid.split('_')[-1]) if '_' in aid else 0
                )
            logger.info(f"Loaded {len(self._anchors)} anchors")
        except Exception as e:
            logger.error(f"Error loading anchors: {e}")
