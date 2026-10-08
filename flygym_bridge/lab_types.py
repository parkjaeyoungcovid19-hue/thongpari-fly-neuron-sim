from __future__ import annotations
import math
import copy
from collections import deque
from dataclasses import dataclass, field
import sandbox_models as sm

PHYSICAL = "PHYSICAL"
SENSORY_MODEL = "SENSORY-MODEL"

FAR_POS = (0.0, 0.0, -500.0)
MAX_OBJECT_ID_LEN = 64
MAX_EVENTS = 64
# Engineering lab-force scale, not a biological wind law. Leg adhesion holds a
# standing fly, so the old 10000 mm/s² moved it only ~0.08 mm/s at strength 1.
# V6.5 (user request "강화"): 60000 mm/s² on the thorax, fading to zero as the
# thorax reaches WIND_SPEED_MAX_MM_S × strength along the wind, so a fly that
# loses its footing drifts with the wind instead of being flung away. Measured
# on the shipped NeuroMechFly (2 s, standing): strength .25 → 0.8 mm, .5 → 5 mm,
# 1 → 18 mm; side and tail winds stay upright, a strong head-on wind tips the
# fly over (accepted by the user), and no run raised a MuJoCo instability warning.
WIND_ACCEL_MAX_MM_S2 = 60000.0
WIND_SPEED_MAX_MM_S = 30.0
TOUCH_ACCEL_MAX_MM_S2 = 16000.0
FOOD_ODOR_DECAY_MM = 30.0
# V6.5 continuous-wind edit properties -> the _wind_state() key holding the
# applied value. wind.continuous/duration_ms describe puffs and have no applier.
WIND_EDIT_FIELDS = {"wind.strength": "strength", "wind.direction_deg": "direction_deg",
                    "wind.physical": "physical_enabled", "wind.sensory": "sensory_enabled"}
# V5.6.2 feeding (engineering rule, not a feeding motor program: the proboscis
# is not actuated). While the haustellum geom is within FEED_CONTACT_MM of a
# food model's surface, the food shrinks at FEED_SHRINK_MM_S (diameter) and a
# modeled sugar-contact signal is reported; below FEED_MIN_DIAMETER_MM it is gone.
FEED_CONTACT_MM = 0.15
FEED_SHRINK_MM_S = 1.2
FEED_MIN_DIAMETER_MM = 0.4
MOUTH_SEGMENT = "c_haustellum"
TRAP_LIFT_MM = 4.0
TRAP_FLOOR_GAP_MM = 0.02
TRAP_DROP_SPEED_MM_S = 60.0
# 2000 mm/s moves 0.2 mm per 0.1 ms substep (pellet radius 0.6 mm: no tunnelling)
# and reaches v^2/g ~ 408 mm, so every crosshair point in range has a flat arc.
BB_SPEED_MM_S = 2000.0
# The pellet leaves the muzzle (right hand) but is aimed at the point under the
# crosshair: the look ray from the eye, up to BB_AIM_RANGE_MM, with the launch
# angle solved for real gravity. A parallel shot from the hand lands ~3 mm low
# and then drops (2026-09-27 user report: "총이 제대로 안 나감").
BB_AIM_RANGE_MM = 150.0
BB_LIFETIME_S = 2.0
BB_POOL_SIZE = 8
BB_RATE_LIMIT_S = 0.15

# Fixed topology, bounded memory. Food uses non-colliding sphere slots. Its
# odor field is a bounded sensory model only; taste/reward/feeding and direct
# neural wiring remain intentionally absent.
DEFAULT_SLOT_COUNTS = {
    # Runtime MuJoCo topology is fixed after compilation, so keep a generous
    # preallocated pool. These mocap geoms are hidden/inactive until used, but
    # MuJoCo still poses every geom on every substep, so the pools are not free.
    "box": 64,
    "sphere": 64,
    "wall": 64,
    # Each food slot carries the whole food palette (~17 hidden geoms), and
    # every geom is posed on every substep: 32 slots cost ~11% of a body step
    # (2026-09-28 paired measurement), so the pool is kept small.
    "food": 8,
    # Toy slots are multi-part too; 8 cars + 4 traps cost ~10% idle, 4 + 2 ~3%.
    "car": 4,
    "trap": 2,
    # V6.4 walkable terrain: unlike the obstacle pools, every ramp slot carries
    # explicit pairs with the fly's tibiae, tarsi and body (43 geoms), so its
    # pool stays small.
    "ramp": 4,
}

MAX_SLOT_COUNT_PER_SHAPE = 256

# V6.4 ramp: a fixed (never carried/approached) box tilted by pitch_deg about
# its own Y axis after yaw, raising its +X end. Pitch and size edits pivot about
# the middle of the low top edge, so a ramp laid flush with the lawn stays flush.
RAMP_PITCH_MAX_DEG = 45.0
RAMP_DEFAULT_SIZE_MM = (40.0, 20.0, 1.0)
RAMP_DEFAULT_PITCH_DEG = 15.0
RAMP_SIZE_RANGE_MM = ((5.0, 200.0), (2.0, 200.0), (0.2, 20.0))

DEFAULT_COLORS = {
    # Match VisionLoomDetector's configured magenta target for ordinary lab
    # objects, so looming still comes from rendered eye pixels.
    "box": (0.92, 0.08, 0.72, 1.0),
    "sphere": (0.92, 0.08, 0.72, 1.0),
    "wall": (0.92, 0.08, 0.72, 1.0),
    # Food is a visible odor-source marker. Green excludes it from the legacy
    # configured-color occupancy path; the generic raw-frame motion estimator
    # may still report expansion if its rendered geometry actually approaches.
    "food": (0.18, 0.82, 0.22, 1.0),
    "car": (1.0, 1.0, 1.0, 0.0),
    "trap": (1.0, 1.0, 1.0, 0.0),
    # Terrain, not a looming target: kept off the configured magenta.
    "ramp": (0.62, 0.52, 0.38, 1.0),
}


class LabError(ValueError):
    pass


class CapacityError(LabError):
    """A shape's fixed slot pool is full; the world is unchanged."""
    status = "rejected_capacity"


def ramp_flush_center_z(size_mm, pitch_deg):
    """Center height that puts a ramp's low top edge on the lawn (z = 0)."""
    p = math.radians(pitch_deg)
    return 0.5 * size_mm[0] * math.sin(p) - 0.5 * size_mm[2] * math.cos(p)


def _finite(value, default=0.0):
    try:
        out = float(value)
    except (TypeError, ValueError):
        return float(default)
    return out if math.isfinite(out) else float(default)


def _clamp(value, lo, hi, default=0.0):
    return max(lo, min(hi, _finite(value, default)))


def _vec3(value, default):
    # Any 3+ sequence, including the NumPy arrays MuJoCo poses arrive as;
    # strings and mappings fall back to the default.
    try:
        if isinstance(value, (str, bytes)) or len(value) < 3:
            raise TypeError
        value = [value[i] for i in range(3)]
    except (TypeError, KeyError, IndexError):
        value = default
    return [_finite(value[i], default[i]) for i in range(3)]


def _normalize3(value, default=(0.0, 1.0, 0.0)):
    vec = _vec3(value, default)
    mag = math.sqrt(sum(v * v for v in vec))
    if mag < 1e-9:
        vec = list(default)
        mag = math.sqrt(sum(v * v for v in vec))
    return [v / mag for v in vec]


def _tool_number(value, name, lo, hi):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LabError(f"{name} must be numeric")
    value = float(value)
    if not math.isfinite(value) or not lo < value <= hi:
        raise LabError(f"{name} out of range")
    return value


def _tool_id(args):
    value = args.get("id")
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > MAX_OBJECT_ID_LEN:
        raise LabError("id is required")
    return value.strip()


def _tool_actor(args):
    value = args.get("actor_id")
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 64:
        raise LabError("actor_id is required")
    return value.strip()


def _ballistic_velocity(start, target, speed, gravity):
    """Launch velocity reaching `target` from `start` at `speed` under gravity.

    Takes the flatter of the two ballistic arcs; out of reach, straight at it.
    """
    dx, dy, dz = (t - s for s, t in zip(start, target))
    horizontal = math.hypot(dx, dy)
    if horizontal < 1e-9:
        return [0.0, 0.0, speed if dz >= 0.0 else -speed]
    v2 = speed * speed
    root = v2 * v2 - gravity * (gravity * horizontal * horizontal + 2.0 * dz * v2)
    angle = (math.atan2(v2 - math.sqrt(root), gravity * horizontal) if root >= 0.0
             else math.atan2(dz, horizontal))
    ux, uy = dx / horizontal, dy / horizontal
    return [speed * math.cos(angle) * ux, speed * math.cos(angle) * uy, speed * math.sin(angle)]


def _tool_direction(value):
    if not isinstance(value, (tuple, list)) or len(value) != 3:
        raise LabError("direction must be a unit 3-vector")
    xyz = []
    for i, v in enumerate(value):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
            raise LabError(f"direction[{i}] must be finite")
        xyz.append(float(v))
    if abs(math.sqrt(sum(v * v for v in xyz)) - 1.0) > 1e-3:
        raise LabError("direction must be a unit 3-vector")
    return xyz


@dataclass
class LabObject:
    object_id: str
    shape: str
    slot: str
    position_mm: list
    size_mm: list
    yaw_deg: float = 0.0
    revision: int = 0
    variant: str | None = None
    trap_state: str | None = None
    pitch_deg: float = 0.0

    def quat_wxyz(self):
        """Yaw about world Z, then (ramps) pitch about the local Y axis."""
        cy, sy = math.cos(math.radians(self.yaw_deg) * 0.5), math.sin(math.radians(self.yaw_deg) * 0.5)
        cp, sp = math.cos(math.radians(self.pitch_deg) * 0.5), math.sin(math.radians(self.pitch_deg) * 0.5)
        return [cy * cp, sy * sp, -cy * sp, sy * cp]

    def local_to_world(self, local):
        y, p = math.radians(self.yaw_deg), math.radians(self.pitch_deg)
        x = math.cos(p) * local[0] - math.sin(p) * local[2]
        z = math.sin(p) * local[0] + math.cos(p) * local[2]
        return [self.position_mm[0] + math.cos(y) * x - math.sin(y) * local[1],
                self.position_mm[1] + math.sin(y) * x + math.cos(y) * local[1],
                self.position_mm[2] + z]

    def ramp_anchor(self):
        """World point at the middle of the low top edge."""
        return self.local_to_world((-0.5 * self.size_mm[0], 0.0, 0.5 * self.size_mm[2]))

    def state(self):
        food = self.shape == "food"
        out = {
            "id": self.object_id,
            "shape": self.shape,
            "position_mm": [float(v) for v in self.position_mm],
            "size_mm": [float(v) for v in self.size_mm],
            "yaw_deg": float(self.yaw_deg),
            "revision": int(self.revision),
            "classification": PHYSICAL,
            "visual_marker_only": False,
        }
        if not food:
            out["neural_connected"] = True
        if food:
            out.update(
                odor_source_modeled=True,
                odor_classification=SENSORY_MODEL,
                backend_direct_neural=False,
                integrated_neural_target="ORN_DM1/VA2 via Swift",
                food_variant=self.variant,
                sugar_content=sm.FOOD_SUGAR.get(self.variant, 0.0),
                taste_modeled=True,
                taste_classification=SENSORY_MODEL,
                reward_modeled=False,
                feeding_modeled=True,
                behavior_scripted=False,
                note=("Odor source modeled; haustellum contact shrinks the food and reports a "
                      "modeled sugar-contact signal; no reward/hunger; no scripted seeking"),
            )
        if self.shape == "trap":
            out["trap_state"] = self.trap_state
        if self.shape == "ramp":
            out.update(pitch_deg=float(self.pitch_deg), fixed_terrain=True,
                       fly_leg_contact=True)
        return out


@dataclass
class ApproachMotion:
    object_id: str
    target_xy_mm: tuple
    end_distance_mm: float
    speed_mm_s: float


@dataclass
class DriveMotion:
    object_id: str
    speed_mm_s: float
    remaining_mm: float


@dataclass
class Projectile:
    id: str
    index: int
    position_mm: list
    velocity_mm_s: list
    fired_s: float
    hit_fly: bool = False
    hit_object: bool = False
    trail: list = field(default_factory=list)  # (sim s, position) for the tracer



__all__ = ['PHYSICAL', 'SENSORY_MODEL', 'FAR_POS', 'MAX_OBJECT_ID_LEN', 'MAX_EVENTS', 'WIND_ACCEL_MAX_MM_S2', 'WIND_SPEED_MAX_MM_S', 'TOUCH_ACCEL_MAX_MM_S2', 'FOOD_ODOR_DECAY_MM', 'WIND_EDIT_FIELDS', 'FEED_CONTACT_MM', 'FEED_SHRINK_MM_S', 'FEED_MIN_DIAMETER_MM', 'MOUTH_SEGMENT', 'TRAP_LIFT_MM', 'TRAP_FLOOR_GAP_MM', 'TRAP_DROP_SPEED_MM_S', 'BB_SPEED_MM_S', 'BB_AIM_RANGE_MM', 'BB_LIFETIME_S', 'BB_POOL_SIZE', 'BB_RATE_LIMIT_S', 'DEFAULT_SLOT_COUNTS', 'MAX_SLOT_COUNT_PER_SHAPE', 'RAMP_PITCH_MAX_DEG', 'RAMP_DEFAULT_SIZE_MM', 'RAMP_DEFAULT_PITCH_DEG', 'RAMP_SIZE_RANGE_MM', 'DEFAULT_COLORS', 'LabError', 'CapacityError', 'ramp_flush_center_z', '_finite', '_clamp', '_vec3', '_normalize3', '_tool_number', '_tool_id', '_tool_actor', '_ballistic_velocity', '_tool_direction', 'LabObject', 'ApproachMotion', 'DriveMotion', 'Projectile']
