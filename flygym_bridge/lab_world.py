"""Virtual Fly Lab world state and MuJoCo-side physical stimuli.

The lab intentionally separates three kinds of intervention:

* PHYSICAL: kinematic MuJoCo objects plus external wind/touch forces.
* SENSORY_MODEL: eye masking and modeled temperature state.  These do not
  pretend to be measured FlyWire pathways.
* DIRECT_NEURAL: owned by the Swift/Metal brain, never implemented here.

MuJoCo model topology cannot be changed cheaply after compilation.  Real mode
therefore installs a small fixed pool of hidden object slots before Simulation
is constructed and activates/moves/resizes those slots at runtime.  All methods
that touch mjModel/mjData are called by RealFlyBody on its simulation-owner
thread.
"""
from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field
import sandbox_models as sm
from player_body import PlayerBody
from environment_properties import EDIT_DESCRIPTORS, MAX_REVISION, EditError, environment_capabilities, validate_edit
from interaction import (InteractionState, InteractionError, parse_interaction_args,
                         participant_center,
                         INTERACTION_REACH_MM, INTERACTION_RAY_ORIGIN_TOL_FACTOR,
                         CARRY_SPEED_MM_S, CARRY_PENETRATION_TOL_MM, CARRY_GAP_MM,
                         CARRY_CONTACT_SKIN_MM)


PHYSICAL = "PHYSICAL"
SENSORY_MODEL = "SENSORY-MODEL"
DIRECT_NEURAL = "DIRECT-NEURAL"

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


class LabWorld:
    """Bounded dynamic lab state; optionally backed by a compiled MuJoCo model."""

    def __init__(self, world=None, slot_counts=None):
        counts = dict(DEFAULT_SLOT_COUNTS)
        if slot_counts:
            for shape, count in slot_counts.items():
                if shape in counts:
                    counts[shape] = max(0, min(MAX_SLOT_COUNT_PER_SHAPE, int(count)))
        self.slot_counts = counts
        self.objects = {}
        self._free_slots = {
            shape: deque(f"lab_{shape}_{i}" for i in range(count))
            for shape, count in counts.items()
        }
        self._slot_shape = {
            f"lab_{shape}_{i}": shape
            for shape, count in counts.items()
            for i in range(count)
        }
        self._slot_ids = {}
        self._counter = 0
        self._food_palettes = {}
        self._food_part_owner = {}      # palette geom id -> food slot
        self._toy_palettes = {}
        self._toy_part_owner = {}
        self._solid_by_slot = {}
        self._bb_names = [(f"lab_bb_{i}", f"lab_bb_{i}_geom", f"lab_bb_{i}_joint")
                           for i in range(BB_POOL_SIZE)]
        self._bb_ids = []
        self._bb_tracers = []           # (mocap id, geom id) per pellet slot
        self.projectiles = {}
        self._bb_counter = 0
        self._last_bb_fire_s = -math.inf
        self._sim_time_s = 0.0
        self._food_spawn_count = 0
        self._mouth_geom_names = []
        self._mouth_geom_ids = []
        self.feeding = {}               # food id -> accumulated contact seconds
        self._eating_id = None
        self.revision = 0
        # Render revision advances for every visible pose/size/topology change.
        # Structural revision advances only when the ray-query scene contract is
        # invalidated (objects added/removed/resized/reset). Pure pose motion is
        # intentionally excluded so a just-rendered frame may still be used as
        # provenance for a current-owner ray while an approach is moving.
        self.structure_revision = 0
        # Singleton environment settings (temperature, eyes, wind) have their own
        # revision so unrelated object motion never makes an edit look stale.
        self.environment_revision = 0
        self._bound = False
        self._mujoco = None
        self.model = None
        self.data = None
        self.force_body_ids = {}
        self._previous_forces = {}
        self.approaches = {}
        self.drives = {}
        self._trap_blocked = set()
        self.events = deque(maxlen=MAX_EVENTS)
        # V5.4 participant is one dedicated actor, not part of the generic
        # LabObject pool. LabWorld still owns its lifecycle/revision semantics.
        self.player = PlayerBody()
        self.interaction = InteractionState(self.player.actor_id, mock=world is None)
        self._interaction_tick_ms = 0
        self._fly_contact_geoms = {}
        self._installed_fly_geom_names = {}
        self._terrain_pair_count = 0
        self._terrain_template_count = 0
        self._ground_geom_names = []
        self._ground_geom_ids = []
        self.wind = {
            "strength": 0.0,
            "direction_deg": 0.0,
            "continuous": False,
            "remaining_s": 0.0,
            "physical_enabled": True,
            "sensory_enabled": True,
        }
        self.touch = None
        self.eyes = {
            "left_enabled": True,
            "right_enabled": True,
            "left_mask": 0.0,
            "right_mask": 0.0,
        }
        self.temperature = {
            "celsius": 25.0,
            "mode": "environment_only",
            "neural_connected": False,
            "controller_tempo_via_brain_packet": False,
        }
        self.flash = {
            "eye": "both",
            "intensity": 0.0,
            "remaining_s": 0.0,
        }
        if world is not None:
            self.install(world)

    # ------------------------------------------------------------------
    # MuJoCo topology and binding
    # ------------------------------------------------------------------
    def install(self, world):
        """Install hidden kinematic mocap slots before Simulation compiles MJCF."""
        import mujoco
        self._ground_geom_names = [geom.name for geom in world.ground_geoms]

        for slot, shape in self._slot_shape.items():
            # Mocap bodies are kinematic runtime objects: MuJoCo keeps them in
            # the compiled model and exposes data.mocap_pos/quat for safe motion.
            body = world.mjcf_root.worldbody.add_body(name=slot, pos=FAR_POS, mocap=True)
            if shape in ("box", "wall", "ramp"):
                geom_type = mujoco.mjtGeom.mjGEOM_BOX
                # Compile broad-phase bounds at the maximum runtime half-size.
                # MuJoCo keeps `geom_rbound`/BVH bounds as model constants even
                # when `geom_size` is edited at runtime. A conservative maximum
                # bound prevents large resized objects from being culled before
                # narrow-phase collision, while narrow-phase still uses the live
                # `geom_size` below.
                size = [100.0, 100.0, 100.0]
            else:
                geom_type = mujoco.mjtGeom.mjGEOM_SPHERE
                size = [50.0]
            rgba = list(DEFAULT_COLORS[shape])
            rgba[3] = 0.0
            if shape == "food":
                # Food is drawn by a palette of model parts (sandbox_models);
                # the core sphere stays hidden and non-colliding.
                self._food_palettes[slot] = sm.Palette(sm.FOOD_PALETTE).install(
                    body, slot, max_extent_mm=60.0, collidable=False)
            elif shape in ("car", "trap"):
                counts = sm.CAR_PALETTE if shape == "car" else sm.TRAP_PALETTE
                self._toy_palettes[slot] = sm.Palette(counts).install(
                    body, slot, max_extent_mm=60.0, collidable=True)
            body.add_geom(
                name=f"{slot}_geom",
                type=geom_type,
                size=size,
                rgba=rgba,
                # Keep ordinary collision eligibility in the compiled model;
                # `_deactivate_slot` immediately masks inactive slots back to
                # 0/0 after binding. MuJoCo cannot promote a geom compiled with
                # 0/0 into the generic collision candidate set at runtime.
                contype=1,
                conaffinity=1,
            )
        for body_name, geom_name, joint_name in self._bb_names:
            body = world.mjcf_root.worldbody.add_body(name=body_name, pos=FAR_POS)
            body.gravcomp = 1.0
            body.add_freejoint(name=joint_name)
            body.add_geom(name=geom_name, type=mujoco.mjtGeom.mjGEOM_SPHERE,
                          size=[sm.BB_RADIUS_MM], rgba=sm.BB_RGBA,
                          mass=2e-5, contype=1, conaffinity=1)
            tracer = world.mjcf_root.worldbody.add_body(
                name=f"{body_name}_tracer", pos=FAR_POS, mocap=True)
            tracer.add_geom(name=f"{body_name}_tracer_geom", type=mujoco.mjtGeom.mjGEOM_CAPSULE,
                            size=[sm.BB_TRACER_RADIUS_MM, 200.0], rgba=[1, 1, 1, 0],
                            group=sm.VIEW_ONLY_GROUP, contype=0, conaffinity=0)
        self.player.install(world)

    def install_fly_contact_pairs(self, world, fly, segments=("thorax", "head", "abdomen")):
        """Compile object-slot/fly pairs using the installed FlyGym geom mapping."""
        names = {"thorax": "c_thorax", "head": "c_head", "abdomen": "c_abdomen4"}
        for segment in segments:
            matches = [(key, geoms) for key, geoms in fly.bodyseg_to_mjcfgeom.items()
                       if getattr(key, "name", str(key)) == names[segment]]
            if not matches:
                if segment == "thorax":
                    raise RuntimeError("fly thorax contact geom unavailable")
                continue
            self._installed_fly_geom_names[segment] = [geom.name for geom in matches[0][1]]
            for slot, shape in self._slot_shape.items():
                # Ramps get the full ground-contact set in install_terrain_contact_pairs.
                if shape in ("food", "ramp"):
                    continue
                if shape in ("car", "trap"):
                    parts = sm.CAR_PARTS if shape == "car" else sm.TRAP_PARTS
                    names_by_type = self._toy_palettes[slot].names
                    used = {kind: 0 for kind in names_by_type}
                    solid_names = []
                    for part in parts:
                        name = names_by_type[part.type][used[part.type]]
                        used[part.type] += 1
                        if part.collide:
                            solid_names.append(name)
                else:
                    solid_names = [f"{slot}_geom"]
                for index, geom in enumerate(matches[0][1]):
                    for part_index, name in enumerate(solid_names):
                        world.mjcf_root.add_pair(
                            geomname1=name, geomname2=geom.name,
                            name=f"v56-{slot}-{segment}-{index}-{part_index}")
            for index, geom in enumerate(matches[0][1]):
                for pellet_index, (_, pellet_geom, _) in enumerate(self._bb_names):
                    world.mjcf_root.add_pair(
                        geomname1=pellet_geom, geomname2=geom.name,
                        name=f"v562-bb-{pellet_index}-{segment}-{index}")
        for pellet_index, (_, pellet_geom, _) in enumerate(self._bb_names):
            for ground_index, name in enumerate(self._ground_geom_names):
                world.mjcf_root.add_pair(geomname1=pellet_geom, geomname2=name,
                                         name=f"v562-bb-{pellet_index}-ground-{ground_index}")
        # Feeding needs only a distance query, not a contact pair.
        self._mouth_geom_names = [geom.name for key, geoms in fly.bodyseg_to_mjcfgeom.items()
                                  if getattr(key, "name", str(key)) == MOUTH_SEGMENT
                                  for geom in geoms]

    # Walking touches a ramp through tibiae and tarsi (FlyGym's own
    # "tibia_tarsus_only" contact preset); the body segments catch a fall.
    # Coxae and femora are left out: fly geoms are meshes, and box/mesh
    # contact is GJK, not the plane's closed form (2026-10-06 measurement).
    TERRAIN_FLY_LINKS = ("tibia", "tarsus", "thorax", "head", "abdomen")

    def install_terrain_contact_pairs(self, world, fly):
        """Give each ramp slot copies of the fly's own lawn contact pairs.

        FlyGym's fly geoms are contype 0 and touch the lawn only through
        explicit pairs, so a ramp needs the same pairs (and the same friction
        and solver parameters) for legs to stand on it. Leg adhesion acts on any
        contact of tarsus5, so it grips a ramp as it grips the lawn.
        """
        ground = set(self._ground_geom_names)
        fly_geoms = {geom.name for key, geoms in fly.bodyseg_to_mjcfgeom.items()
                     if getattr(key, "name", str(key)).split("_")[-1].startswith(self.TERRAIN_FLY_LINKS)
                     for geom in geoms}
        templates = [pair for pair in world.mjcf_root.pairs
                     if pair.geomname2 in ground and pair.geomname1 in fly_geoms]
        if not templates:
            raise RuntimeError("no fly/ground contact pairs to copy for ramps")
        self._terrain_pair_count = 0
        for slot, shape in self._slot_shape.items():
            if shape != "ramp":
                continue
            for index, pair in enumerate(templates):
                world.mjcf_root.add_pair(
                    geomname1=pair.geomname1, geomname2=f"{slot}_geom",
                    name=f"v64-{slot}-{index}", condim=pair.condim,
                    friction=list(pair.friction), solref=list(pair.solref),
                    solimp=list(pair.solimp), margin=pair.margin, gap=pair.gap)
                self._terrain_pair_count += 1
        self._terrain_template_count = len(templates)

    def bind(self, sim, force_body_ids=None):
        """Resolve slot/body ids after Simulation construction."""
        import mujoco

        import numpy as np

        self._mujoco = mujoco
        self._fromto = np.zeros(6)  # reused mj_geomDistance witness buffer
        self.model = sim.mj_model
        self.data = sim.mj_data
        for slot in self._slot_shape:
            bid = self._compiled_id(mujoco.mjtObj.mjOBJ_BODY, slot)
            gid = self._compiled_id(mujoco.mjtObj.mjOBJ_GEOM, f"{slot}_geom")
            if bid < 0 or gid < 0:
                raise LabError(f"compiled lab slot missing: {slot}")
            mocap_id = int(self.model.body_mocapid[bid])
            self._slot_ids[slot] = (bid, gid, mocap_id)
        self.force_body_ids = dict(force_body_ids or {})
        self.player.bind(sim)
        self._ground_geom_ids = [gid for name in self._ground_geom_names
                                 if (gid := self._compiled_id(mujoco.mjtObj.mjOBJ_GEOM, name)) >= 0]
        for segment, names in self._installed_fly_geom_names.items():
            for name in names:
                gid = self._compiled_id(mujoco.mjtObj.mjOBJ_GEOM, name)
                if gid >= 0:
                    self._fly_contact_geoms[gid] = segment
        for slot, palette in self._food_palettes.items():
            palette.bind(self.model)
            for gid in palette.all_gids():
                self._food_part_owner[gid] = slot
        for slot, palette in self._toy_palettes.items():
            palette.bind(self.model)
            for gid in palette.all_gids():
                self._toy_part_owner[gid] = slot
        for body_name, geom_name, joint_name in self._bb_names:
            bid = self._compiled_id(mujoco.mjtObj.mjOBJ_BODY, body_name)
            gid = self._compiled_id(mujoco.mjtObj.mjOBJ_GEOM, geom_name)
            jid = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_JOINT, joint_name)
            if min(bid, gid, jid) < 0:
                raise LabError(f"compiled BB slot missing: {body_name}")
            self._bb_ids.append((bid, gid, int(self.model.jnt_qposadr[jid]),
                                 int(self.model.jnt_dofadr[jid])))
            tbid = self._compiled_id(mujoco.mjtObj.mjOBJ_BODY, f"{body_name}_tracer")
            tgid = self._compiled_id(mujoco.mjtObj.mjOBJ_GEOM, f"{body_name}_tracer_geom")
            if min(tbid, tgid) < 0:
                raise LabError(f"compiled BB tracer missing: {body_name}")
            self._bb_tracers.append((int(self.model.body_mocapid[tbid]), tgid))
        self._mouth_geom_ids = [gid for name in self._mouth_geom_names
                                if (gid := self._compiled_id(mujoco.mjtObj.mjOBJ_GEOM, name)) >= 0]
        # interaction_post_step only reacts to contacts touching one of these.
        self._post_step_watch = np.zeros(self.model.ngeom, dtype=bool)
        self._post_step_watch[list(self._fly_contact_geoms)] = True
        self._post_step_watch[[gid for _, gid, _, _ in self._bb_ids]] = True
        self._bound = True
        self._park_all_bbs()
        self._sync_all()
        # Mask writes above already resync their bodies; this covers any body
        # whose geoms none of them touched.
        for bid in range(self.model.nbody):
            sm.sync_body_collision_mask(self.model, bid)

    def _compiled_id(self, obj_type, local_name):
        """Resolve dm_control/FlyGym names with or without world namespace."""
        mujoco = self._mujoco
        exact = mujoco.mj_name2id(self.model, obj_type, local_name)
        if exact >= 0:
            return exact
        if obj_type == mujoco.mjtObj.mjOBJ_BODY:
            count = self.model.nbody
        elif obj_type == mujoco.mjtObj.mjOBJ_GEOM:
            count = self.model.ngeom
        else:
            return -1
        suffix = "/" + local_name
        matches = []
        for idx in range(count):
            name = mujoco.mj_id2name(self.model, obj_type, idx)
            if name and (name == local_name or name.endswith(suffix)):
                matches.append(idx)
        return matches[0] if len(matches) == 1 else -1

    def resync_after_sim_reset(self):
        """Restore active LabObject slots and the free-joint participant after reset."""
        self._previous_forces = {}
        self.release_interaction("body_reset")
        self.reset_runtime_tools()
        self._sync_all()
        self.player.resync_after_sim_reset()

    def reset_runtime_tools(self):
        self.drives.clear()
        self._trap_blocked.clear()
        self._park_all_bbs()
        self._last_bb_fire_s = -math.inf
        self._sim_time_s = 0.0

    def _clear_applied_forces(self):
        """Remove only force vectors previously contributed by this LabWorld."""
        if self._bound and self.data is not None:
            for bid, vec in self._previous_forces.items():
                self.data.xfrc_applied[bid, :3] -= vec
        self._previous_forces = {}

    # ------------------------------------------------------------------
    # Object lifecycle
    # ------------------------------------------------------------------
    def _bump_revision(self, obj=None, *, structural=False):
        self.revision += 1
        if structural:
            self.structure_revision += 1
        if obj is not None:
            obj.revision = self.revision
        return self.revision

    def set_player_active(self, active):
        if not active and self.player.active:
            self.release_interaction("participant_inactive")
            self.player.set_gun_visible(False)
        changed, pose = self.player.set_active(active)
        if changed:
            self._bump_revision(structural=True)
        return {"player": pose, "player_active": self.player.active}

    def set_player_pose(self, *, position_mm=None, orientation_quat_xyzw=None, mode=None):
        """Owner-thread participant pose update; no input/wire policy lives here."""
        self.player.set_pose(position_mm=position_mm,
                             orientation_quat_xyzw=orientation_quat_xyzw,
                             mode=mode)
        self.interaction.previous_distances = None
        if self.player.active:
            self._bump_revision(structural=False)
        return self.player.render_pose()

    def reset_player_pose(self, *, preserve_active=True):
        was_active = self.player.active
        self.player.reset_pose(preserve_active=preserve_active)
        self.interaction.previous_distances = None
        if was_active and self.player.active:
            self._bump_revision(structural=False)

    def begin_player_quantum(self):
        return self.player.begin_physics_quantum()

    def player_substep(self):
        self.player.apply_servo_substep()

    def end_player_quantum(self, start):
        changed = self.player.end_physics_quantum(start)
        if changed:
            self._bump_revision(structural=False)
        return changed

    def render_player(self):
        return self.player.render_pose()

    def _object_id(self, requested, shape):
        if requested is not None:
            object_id = str(requested).strip()
            if not object_id or len(object_id) > MAX_OBJECT_ID_LEN:
                raise LabError("invalid object id")
            if object_id in self.objects:
                raise LabError(f"object already exists: {object_id}")
            return object_id
        while True:
            self._counter += 1
            object_id = f"{shape}_{self._counter}"
            if object_id not in self.objects:
                return object_id

    def _shape(self, shape):
        shape = str(shape or "box").strip().lower()
        aliases = {"food_marker": "food", "food_source": "food"}
        shape = aliases.get(shape, shape)
        if shape not in self._free_slots:
            raise LabError(f"unsupported shape: {shape}")
        return shape

    def _sanitize_size(self, shape, size_mm):
        if shape in ("car", "trap"):
            value = size_mm[0] if isinstance(size_mm, (list, tuple)) and size_mm else size_mm
            default = 14.0 if shape == "car" else 20.0
            length = _clamp(value, 4.0 if shape == "car" else 8.0, 60.0, default)
            return ([length, length * sm.CAR_WIDTH_RATIO, length * sm.CAR_HEIGHT_RATIO]
                    if shape == "car" else [length, length, length * sm.TRAP_HEIGHT_RATIO])
        if shape in ("sphere", "food"):
            if isinstance(size_mm, (int, float)):
                diameter = _clamp(size_mm, 0.2, 100.0, 3.0)
            elif isinstance(size_mm, (list, tuple)) and size_mm:
                diameter = _clamp(size_mm[0], 0.2, 100.0, 3.0)
            else:
                diameter = 3.0 if shape == "food" else 5.0
            return [diameter, diameter, diameter]
        if shape == "ramp":
            raw = _vec3(size_mm, RAMP_DEFAULT_SIZE_MM)
            return [_clamp(v, lo, hi, RAMP_DEFAULT_SIZE_MM[i])
                    for i, (v, (lo, hi)) in enumerate(zip(raw, RAMP_SIZE_RANGE_MM))]
        default = [10.0, 10.0, 10.0] if shape == "box" else [2.0, 30.0, 15.0]
        raw = _vec3(size_mm, default)
        return [_clamp(v, 0.2, 200.0, default[i]) for i, v in enumerate(raw)]

    def _food_variant(self, requested):
        """Requested model, or the next one in a fixed rotation (deterministic)."""
        if requested is not None:
            name = str(requested).strip().lower()
            if name not in sm.FOOD_VARIANTS:
                raise LabError(f"unknown food variant: {name}")
            return name
        name = sm.FOOD_VARIANT_ORDER[self._food_spawn_count % len(sm.FOOD_VARIANT_ORDER)]
        self._food_spawn_count += 1
        return name

    def spawn_object(self, *, shape="box", object_id=None, position_mm=None,
                     size_mm=None, yaw_deg=0.0, variant=None, pitch_deg=None):
        shape = self._shape(shape)
        if variant is not None and shape != "food":
            raise LabError("variant applies only to food")
        if pitch_deg is not None and shape != "ramp":
            raise LabError("pitch_deg applies only to ramp")
        if not self._free_slots[shape]:
            raise CapacityError(f"no free {shape} slots")
        object_id = self._object_id(object_id, shape)
        size = self._sanitize_size(shape, size_mm)
        pitch = 0.0
        if shape == "ramp":
            pitch = _clamp(RAMP_DEFAULT_PITCH_DEG if pitch_deg is None else pitch_deg,
                           0.0, RAMP_PITCH_MAX_DEG, RAMP_DEFAULT_PITCH_DEG)
        slot = self._free_slots[shape].popleft()
        pos_default = [40.0, 0.0, 5.0]
        if shape == "ramp":
            pos_default = [40.0, 0.0, ramp_flush_center_z(size, pitch)]
        elif shape == "wall":
            pos_default = [40.0, 0.0, 7.5]
        elif shape == "food":
            pos_default = [20.0, 0.0, 1.5]
        elif shape == "car":
            pos_default = [40.0, 0.0, 0.205 * size[0]]
        elif shape == "trap":
            pos_default = [40.0, 0.0, 0.5 * size[2] + TRAP_LIFT_MM]
        pos = [_clamp(v, -1000.0, 1000.0, pos_default[i])
               for i, v in enumerate(_vec3(position_mm, pos_default))]
        try:
            food_variant = self._food_variant(variant) if shape == "food" else None
        except LabError:
            self._free_slots[shape].appendleft(slot)
            raise
        obj = LabObject(
            object_id=object_id,
            shape=shape,
            slot=slot,
            position_mm=pos,
            size_mm=size,
            yaw_deg=_clamp(yaw_deg, -36000.0, 36000.0, 0.0) % 360.0,
            variant=food_variant,
            trap_state="armed" if shape == "trap" else None,
            pitch_deg=pitch,
        )
        self.objects[object_id] = obj
        self._bump_revision(obj, structural=True)
        self._sync_object(obj)
        self.interaction.previous_distances = None
        return obj.state()

    def move_object(self, object_id, *, position_mm=None, yaw_deg=None):
        obj = self._require_object(object_id)
        self.drives.pop(object_id, None)
        self._trap_blocked.discard(object_id)
        if position_mm is not None:
            raw = _vec3(position_mm, obj.position_mm)
            obj.position_mm = [_clamp(v, -1000.0, 1000.0, obj.position_mm[i])
                               for i, v in enumerate(raw)]
        if yaw_deg is not None:
            obj.yaw_deg = _clamp(yaw_deg, -36000.0, 36000.0, obj.yaw_deg) % 360.0
        self._bump_revision(obj)
        self._sync_object(obj)
        self.interaction.previous_distances = None
        return obj.state()

    def resize_object(self, object_id, *, size_mm):
        obj = self._require_object(object_id)
        self.drives.pop(object_id, None)
        self._trap_blocked.discard(object_id)
        anchor = obj.ramp_anchor() if obj.shape == "ramp" else None
        obj.size_mm = self._sanitize_size(obj.shape, size_mm)
        if anchor is not None:
            self._pin_ramp_anchor(obj, anchor)
        self._bump_revision(obj, structural=True)
        self._sync_object(obj)
        self.interaction.previous_distances = None
        return obj.state()

    def set_ramp_pitch(self, object_id, *, pitch_deg):
        obj = self._require_object(object_id)
        if obj.shape != "ramp":
            raise LabError("pitch_deg applies only to ramp")
        anchor = obj.ramp_anchor()
        obj.pitch_deg = _clamp(pitch_deg, 0.0, RAMP_PITCH_MAX_DEG, obj.pitch_deg)
        self._pin_ramp_anchor(obj, anchor)
        self._bump_revision(obj)
        self._sync_object(obj)
        return obj.state()

    @staticmethod
    def _pin_ramp_anchor(obj, anchor):
        """Shift the center so the low top edge returns to `anchor`."""
        moved = obj.ramp_anchor()
        obj.position_mm = [_clamp(c + a - m, -1000.0, 1000.0, c)
                           for c, a, m in zip(obj.position_mm, anchor, moved)]

    def remove_object(self, object_id):
        obj = self._require_object(object_id)
        self.drives.pop(object_id, None)
        self._trap_blocked.discard(object_id)
        if self.interaction.held_object_id == obj.object_id:
            self.release_interaction("object_removed")
        self.approaches.pop(obj.object_id, None)
        contact_s = self.feeding.pop(obj.object_id, 0.0)
        if self._eating_id == obj.object_id:
            self._eating_id = None
            self._append_event({"event": "feeding_end", "classification": PHYSICAL,
                                "id": obj.object_id, "contact_s": contact_s,
                                "reason": "object_removed"})
        self._deactivate_slot(obj.slot)
        self.interaction.previous_distances = None
        del self.objects[obj.object_id]
        self._free_slots[obj.shape].append(obj.slot)
        self._bump_revision(structural=True)
        return obj.state()

    def reset(self):
        self.events.clear()
        self.release_interaction("world_reset")
        self.player.set_gun_visible(False)
        self.interaction.contacts.clear()
        self._clear_applied_forces()
        for obj in list(self.objects.values()):
            self._deactivate_slot(obj.slot)
        self.objects.clear()
        self.approaches.clear()
        self.drives.clear()
        self._trap_blocked.clear()
        self._park_all_bbs()
        self._last_bb_fire_s = -math.inf
        self._bb_counter = 0
        self._sim_time_s = 0.0
        self.feeding.clear()
        self._food_spawn_count = 0
        self._eating_id = None
        self._free_slots = {
            shape: deque(f"lab_{shape}_{i}" for i in range(count))
            for shape, count in self.slot_counts.items()
        }
        self._counter = 0
        self.wind.update(
            strength=0.0,
            direction_deg=0.0,
            continuous=False,
            remaining_s=0.0,
            physical_enabled=True,
            sensory_enabled=True,
        )
        self.touch = None
        self.flash.update(eye="both", intensity=0.0, remaining_s=0.0)
        self.eyes.update(left_enabled=True, right_enabled=True, left_mask=0.0, right_mask=0.0)
        self.temperature.update(celsius=25.0, mode="environment_only",
                                neural_connected=False, neural_target=None,
                                controller_tempo_via_brain_packet=False)
        self.environment_revision += 1
        # Preserve the required object_placed event across the world reset.
        self._bump_revision(structural=True)

    def _require_object(self, object_id):
        object_id = str(object_id or "")
        try:
            return self.objects[object_id]
        except KeyError as exc:
            raise LabError(f"unknown object: {object_id}") from exc

    # ------------------------------------------------------------------
    # V5.6 interaction and contact lifecycle
    # ------------------------------------------------------------------
    def _interaction_event(self, name, **fields):
        self.events.append({"event": name, "classification": PHYSICAL,
                            "sim_tick_ms": int(self._interaction_tick_ms), **fields})

    def _append_event(self, event):
        event["sim_tick_ms"] = int(self._interaction_tick_ms)
        self.events.append(event)

    def release_interaction(self, reason):
        held = self.interaction.held_object_id
        if held is None:
            return
        obj = self.objects.get(held)
        self.interaction.held_object_id = None
        self.interaction.previous_position = None
        self.interaction.previous_distances = None
        self.interaction.carry_blocked = False
        self.interaction.blocking_geom_kind = None
        self.interaction.limited_by = None
        self._interaction_event("object_placed", id=held, actor_id=self.player.actor_id,
                                position_mm=(list(obj.position_mm) if obj else None), reason=reason)

    def apply_interaction(self, command, *, ray_pick=None):
        tool = command.args.get("tool_id") if isinstance(command.args, dict) else None
        try:
            try:
                args = parse_interaction_args(command.args)
            except ValueError as exc:
                raise InteractionError(f"invalid_interaction: {exc}") from exc
            if not self.player.active:
                raise InteractionError("not_participating")
            if args.actor_id != self.player.actor_id:
                raise InteractionError("wrong_actor")
            held = self.interaction.held_object_id
            if args.tool_id == "place":
                if held is None:
                    raise InteractionError("not_holding")
                if args.target_id is not None and args.target_id != held:
                    raise InteractionError("target_mismatch")
                self.release_interaction("place")
                self.interaction.record(command.seq, args.tool_id, True, target_id=held)
                return self.interaction.state()
            if held is not None:
                raise InteractionError("already_holding")
            center = participant_center(self.player)
            if math.dist(center, args.ray_origin_mm) > (
                    INTERACTION_RAY_ORIGIN_TOL_FACTOR * self.player.radius_mm):
                raise InteractionError("ray_origin_not_at_participant")
            if ray_pick is None:
                raise RuntimeError("interaction ray picker unavailable")
            hit = ray_pick(args.ray_origin_mm, args.ray_direction)
            if not hit.get("hit"):
                raise InteractionError("ray_miss")
            if hit.get("target_kind") != "lab_object":
                raise InteractionError(f"unsupported_target: {hit.get('target_kind', 'unknown')}")
            distance = math.dist(center, hit["point_mm"])
            if distance > INTERACTION_REACH_MM:
                raise InteractionError(f"out_of_reach: {distance:.3f}mm")
            object_id = hit["target_id"]
            if args.target_id is not None and args.target_id != object_id:
                raise InteractionError("target_mismatch")
            if object_id not in self.objects:
                raise InteractionError("ray_miss")
            if self.objects[object_id].shape == "ramp":
                raise InteractionError("fixed_terrain")
            self.approaches.pop(object_id, None)
            self.drives.pop(object_id, None)
            self.interaction.held_object_id = object_id
            self.interaction.previous_distances = None
            self.interaction.carry_blocked = False
            self.interaction.limited_by = None
            self.interaction.record(command.seq, args.tool_id, True,
                                    target_id=object_id, hit_distance_mm=distance)
            self._interaction_event("object_grabbed", id=object_id,
                                    actor_id=self.player.actor_id, hit_distance_mm=distance)
            return self.interaction.state()
        except InteractionError as exc:
            self.interaction.record(command.seq, tool, False, str(exc).split(":", 1)[0])
            raise

    def interaction_pre_step(self, dt):
        held = self.interaction.held_object_id
        if held is None:
            return
        obj = self.objects.get(held)
        if obj is None:
            self.release_interaction("object_removed")
            return
        if not self.player.active:
            self.release_interaction("participant_inactive")
            return
        # Contract §1 compares the post-step signed distance with the last
        # committed pose. An external resize/move invalidates that baseline.
        self.interaction.distance_limit_mm = (CARRY_PENETRATION_TOL_MM +
                                               CARRY_SPEED_MM_S * dt + 0.01)
        if self._bound and self.interaction.previous_distances is None:
            self._mujoco.mj_forward(self.model, self.data)
            held_gid, candidates = self._carry_candidates()
            self.interaction.previous_distances = self._carry_distances(held_gid, candidates)
        constraints = self._carry_constraints if self._bound else ()
        x, y = self.interaction.carry_step_xy(self.player, obj, CARRY_SPEED_MM_S * dt, constraints)
        self.interaction.previous_position = list(obj.position_mm)
        if math.hypot(x - obj.position_mm[0], y - obj.position_mm[1]) > 1e-12:
            obj.position_mm[0] = x
            obj.position_mm[1] = y
            self._bump_revision(obj)
            self._sync_object(obj)

    def _carry_candidates(self):
        held = self.interaction.held_object_id
        held_gids = (self._object_solid_geoms(self.objects[held])
                     if held is not None and held in self.objects else [])
        if not held_gids:
            return [], []
        obj = self.objects[held]
        anchor = self.interaction.carry_filter_anchor
        if (self.interaction.previous_distances is None or anchor is None or
                math.dist(anchor, obj.position_mm) > 0.5):
            # A candidate excluded at this anchor is farther than the sum of
            # both bounding spheres plus 0.5 mm travel and the query horizon.
            # The filter is rebuilt before the held center travels 0.5 mm;
            # external object edits and approach motion invalidate the cache.
            held_radius = (obj.size_mm[0] * 0.5 if obj.shape == "sphere" else
                           math.sqrt(sum((v * 0.5) ** 2 for v in obj.size_mm)))
            near = []
            for other in self.objects.values():
                if other.object_id == held or other.shape == "food":
                    continue
                radius = (other.size_mm[0] * 0.5 if other.shape == "sphere" else
                          math.sqrt(sum((v * 0.5) ** 2 for v in other.size_mm)))
                reach = held_radius + radius + 0.5 + self.interaction.distance_limit_mm
                if math.dist(obj.position_mm, other.position_mm) <= reach:
                    near.extend((gid, "lab_object", other)
                                for gid in self._object_solid_geoms(other))
            self.interaction.carry_filter_anchor = tuple(obj.position_mm)
            self.interaction.carry_filter_candidates = near
        candidates = ([(gid, "ground", None) for gid in self._ground_geom_ids] +
                      self.interaction.carry_filter_candidates +
                      ([(gid, "player", None) for gid in self.player.solid_geom_ids()]
                       if self.player.active else []))
        return held_gids, candidates

    def _object_solid_geoms(self, obj):
        if obj.shape == "food" or not self._bound:
            return []
        if obj.shape in ("car", "trap"):
            return self._solid_by_slot.get(obj.slot, [])
        return [self._slot_ids[obj.slot][1]]

    def _carry_constraints(self):
        """Surfaces near the held object at its committed pose, as carry_step_xy constraints.

        The participant keeps CARRY_GAP_MM of clearance; other LabObjects are
        approached to CARRY_CONTACT_SKIN_MM. Floors are skipped: a horizontal
        step does not deepen a plane contact (the post-step guard still checks).
        """
        held_gids, candidates = self._carry_candidates()
        if not held_gids:
            return ()
        fromto = self._fromto
        constraints = []
        for gid, kind, _ in candidates:
            if kind == "ground":
                continue
            margin = CARRY_GAP_MM if kind == "player" else CARRY_CONTACT_SKIN_MM
            horizon = margin + self.interaction.distance_limit_mm
            for held_gid in held_gids:
                distance = float(self._mujoco.mj_geomDistance(
                    self.model, self.data, held_gid, gid, horizon, fromto))
                if distance >= horizon or abs(distance) < 1e-9:
                    continue
            # With the held geom first, (from - to) / distance points from the
            # other surface to the held object whether or not they overlap.
                nx = float(fromto[0] - fromto[3]) / distance
                ny = float(fromto[1] - fromto[4]) / distance
                horizontal = math.hypot(nx, ny)
                if horizontal < 0.1:
                    continue
                constraints.append((nx / horizontal, ny / horizontal,
                                    max(0.0, distance - margin) / horizontal, kind))
        return constraints

    def _carry_distances(self, held_gids, candidates):
        # MuJoCo 3.9.0 returns distmax for separated geoms beyond this limit,
        # while penetrating pairs still return their full negative distance.
        limit = self.interaction.distance_limit_mm
        return {(held_gid, gid): float(self._mujoco.mj_geomDistance(
                self.model, self.data, held_gid, gid, limit, None))
                for held_gid in held_gids for gid, _, _ in candidates}

    def interaction_post_step(self):
        """Read real fly contacts and apply the contract §1 geometry guard."""
        if not self._bound or (not self.objects and not self.interaction.contacts and not self.projectiles):
            return
        import numpy as np
        mujoco = self._mujoco
        contact_now = {}
        car_hits = {}
        bb_fly_hits = {}
        bb_object_hits = {}
        held = self.interaction.held_object_id
        blocked_kind = None
        moved = (held is not None and held in self.objects and
                 self.interaction.previous_position is not None and
                 math.dist(self.interaction.previous_position,
                           self.objects[held].position_mm) > 1e-12)
        held_gids, candidates = self._carry_candidates() if moved else ([], [])
        # Both branches below need a penetrating contact on a fly-segment or BB
        # geom. Selecting those in numpy skips building a Python contact object
        # for every leg/floor contact on every 0.1 ms substep.
        contacts = self.data.contact              # sized to ncon
        hit = self._post_step_watch[contacts.geom]
        watched = (np.flatnonzero((contacts.dist <= 0.0) & hit.any(axis=1)).tolist()
                   if hit.any() else [])
        if watched:
            bb_by_geom = {self._bb_ids[p.index][1]: p for p in self.projectiles.values()}
            object_by_geom = {gid: obj.object_id for obj in self.objects.values()
                              for gid in self._object_solid_geoms(obj)}
        for index in watched:
            contact = contacts[index]
            g1, g2 = int(contact.geom1), int(contact.geom2)
            if float(contact.dist) <= 0.0:
                for bb_gid, other_gid in ((g1, g2), (g2, g1)):
                    pellet = bb_by_geom.get(bb_gid)
                    if pellet is None:
                        continue
                    segment = self._fly_contact_geoms.get(other_gid)
                    object_id = object_by_geom.get(other_gid)
                    if segment is not None and not pellet.hit_fly:
                        import numpy as np
                        force = np.zeros(6, dtype=float)
                        mujoco.mj_contactForce(self.model, self.data, index, force)
                        peak = max(0.0, float(force[0]))
                        if pellet.id not in bb_fly_hits or peak > bb_fly_hits[pellet.id][2]:
                            bb_fly_hits[pellet.id] = (pellet, segment, peak)
                    elif object_id is not None and not pellet.hit_object:
                        bb_object_hits[pellet.id] = (pellet, object_id)
            for object_gid, fly_gid in ((g1, g2), (g2, g1)):
                object_id = object_by_geom.get(object_gid)
                segment = self._fly_contact_geoms.get(fly_gid)
                if object_id is not None and segment is not None and float(contact.dist) <= 0.0:
                    import numpy as np
                    force = np.zeros(6, dtype=float)
                    mujoco.mj_contactForce(self.model, self.data, index, force)
                    key = (object_id, segment)
                    contact_now[key] = max(contact_now.get(key, 0.0), max(0.0, float(force[0])))
                    if object_id in self.drives:
                        car_hits[object_id] = max(car_hits.get(object_id, 0.0),
                                                  max(0.0, float(force[0])))
        for object_id, force in car_hits.items():
            self.drives.pop(object_id, None)
            self._interaction_event("car_hit_fly", id=object_id,
                                    peak_normal_force=force, force_units="mujoco_model")
        for pellet, segment, peak in bb_fly_hits.values():
            pellet.hit_fly = True
            self._interaction_event("bb_hit_fly", id=pellet.id, fly_segment=segment,
                                    peak_normal_force=peak, force_units="mujoco_model")
        for pellet, object_id in bb_object_hits.values():
            pellet.hit_object = True
            self._interaction_event("bb_hit_object", id=pellet.id, object_id=object_id)
        # Contract §1: mocap pairs and mocap/fixed-plane pairs need explicit
        # mj_geomDistance checks. Only a *deeper* penetration beyond tolerance
        # blocks carry; an initial overlap may move sideways or out of contact.
        if held_gids and self.interaction.previous_position is not None:
            previous = self.interaction.previous_distances or {}
            distances = self._carry_distances(held_gids, candidates)
            for (held_gid, other_gid), distance in distances.items():
                kind = next(k for gid, k, _ in candidates if gid == other_gid)
                if (distance < -CARRY_PENETRATION_TOL_MM and
                        distance < previous.get((held_gid, other_gid), distance) - 1e-9):
                    blocked_kind = kind
                    break
            self.interaction.previous_distances = distances
        if blocked_kind is not None:
            # Safety net behind the pre-step constraints: undo a deepening step.
            obj = self.objects.get(held)
            if obj is not None:
                obj.position_mm = self.interaction.previous_position
                self._bump_revision(obj)
                self._sync_object(obj)
                mujoco.mj_forward(self.model, self.data)
                # The next comparison must use the restored pose, not the
                # rejected pose from the just-completed physics substep.
                self.interaction.previous_distances = self._carry_distances(held_gids, candidates)
        elif held is not None:
            # A step the pre-step constraints cut to under half is blocked too.
            blocked_kind = self.interaction.limited_by
        if blocked_kind is not None:
            if not self.interaction.carry_blocked:
                self._interaction_event("carry_blocked", id=held, blocking_geom_kind=blocked_kind)
            self.interaction.carry_blocked = True
            self.interaction.blocking_geom_kind = blocked_kind
        elif self.interaction.carry_blocked:
            self._interaction_event("carry_unblocked", id=held,
                                    blocking_geom_kind=self.interaction.blocking_geom_kind)
            self.interaction.carry_blocked = False
            self.interaction.blocking_geom_kind = None
        old = self.interaction.contacts
        for key, force in contact_now.items():
            if key not in old:
                old[key] = (self._interaction_tick_ms, force)
                self._interaction_event("object_contact_begin", id=key[0], fly_segment=key[1],
                                        normal_force=force, force_units="mujoco_model")
            else:
                begin, peak = old[key]
                old[key] = (begin, max(peak, force))
        for key in list(old):
            if key not in contact_now:
                begin, peak = old.pop(key)
                self._interaction_event("object_contact_end", id=key[0], fly_segment=key[1],
                                        peak_normal_force=peak,
                                        duration_ms=max(0, self._interaction_tick_ms - begin),
                                        force_units="mujoco_model")

    # ------------------------------------------------------------------
    # Motion / stimuli
    # ------------------------------------------------------------------
    def start_approach(self, object_id, *, fly_position_mm, end_distance_mm=8.0,
                       speed_mm_s=80.0):
        obj = self._require_object(object_id)
        if obj.shape == "ramp":
            raise LabError("ramp is fixed terrain")
        target = _vec3(fly_position_mm, [0.0, 0.0, 0.0])
        motion = ApproachMotion(
            object_id=obj.object_id,
            target_xy_mm=(target[0], target[1]),
            end_distance_mm=_clamp(end_distance_mm, 0.5, 500.0, 8.0),
            speed_mm_s=_clamp(speed_mm_s, 0.1, 2000.0, 80.0),
        )
        self.drives.pop(obj.object_id, None)
        self.approaches[obj.object_id] = motion
        return {
            "id": obj.object_id,
            "target_xy_mm": list(motion.target_xy_mm),
            "end_distance_mm": motion.end_distance_mm,
            "speed_mm_s": motion.speed_mm_s,
        }

    def set_wind(self, *, direction_deg=0.0, strength=0.0, duration_ms=None,
                 continuous=None, physical=True, sensory=True):
        strength = _clamp(strength, 0.0, 1.0, 0.0)
        if continuous is None:
            continuous = duration_ms is None
        continuous = bool(continuous and strength > 0.0)
        remaining = 0.0
        if not continuous and strength > 0.0:
            remaining = _clamp(500.0 if duration_ms is None else duration_ms,
                               1.0, 10000.0, 500.0) / 1000.0
        self.wind.update(
            strength=strength,
            direction_deg=_clamp(direction_deg, -36000.0, 36000.0, 0.0) % 360.0,
            continuous=continuous,
            remaining_s=remaining,
            physical_enabled=bool(physical),
            sensory_enabled=bool(sensory),
        )
        self.environment_revision += 1
        if strength <= 0.0:
            self.stop_wind()
        return self._wind_state()

    def stop_wind(self):
        self.wind.update(strength=0.0, continuous=False, remaining_s=0.0)
        self.environment_revision += 1

    def apply_touch(self, *, target="thorax", strength=0.5, duration_ms=20.0,
                    direction_world=None, sensory=True):
        target = str(target or "thorax").strip().lower()
        if target not in self.force_body_ids and self._bound:
            raise LabError(f"unsupported touch target: {target}")
        strength = _clamp(strength, 0.0, 1.0, 0.5)
        duration_s = _clamp(duration_ms, 1.0, 1000.0, 20.0) / 1000.0
        self.touch = {
            "target": target,
            "strength": strength,
            "remaining_s": duration_s,
            "direction_world": _normalize3(direction_world),
            "sensory_enabled": bool(sensory),
        }
        self._append_event({
            "event": "touch_started",
            "classification": PHYSICAL,
            "target": target,
            "strength": strength,
            "sensory_enabled": bool(sensory),
        })
        return self._touch_state()

    def set_eye_state(self, *, left_enabled=None, right_enabled=None,
                      left_mask=None, right_mask=None):
        if left_enabled is not None:
            self.eyes["left_enabled"] = bool(left_enabled)
        if right_enabled is not None:
            self.eyes["right_enabled"] = bool(right_enabled)
        if left_mask is not None:
            self.eyes["left_mask"] = _clamp(left_mask, 0.0, 1.0, 0.0)
        if right_mask is not None:
            self.eyes["right_mask"] = _clamp(right_mask, 0.0, 1.0, 0.0)
        self.environment_revision += 1
        return dict(self.eyes)

    def flash_eye(self, *, eye="both", intensity=1.0, duration_ms=100.0):
        eye = str(eye or "both").strip().lower()
        if eye not in ("left", "right", "both"):
            raise LabError("flash eye must be left, right, or both")
        intensity = _clamp(intensity, 0.0, 1.0, 1.0)
        duration_s = (0.0 if intensity <= 0.0 else
                      _clamp(duration_ms, 1.0, 5000.0, 100.0) / 1000.0)
        self.flash.update(eye=eye, intensity=intensity, remaining_s=duration_s)
        if intensity > 0.0:
            self._append_event({
                "event": "flash_started",
                "classification": SENSORY_MODEL,
                "eye": eye,
                "intensity": intensity,
            })
        return self._flash_state()

    def set_temperature(self, *, celsius=25.0, mode="environment_only"):
        mode = str(mode or "environment_only").strip().lower()
        if mode not in ("environment_only", "modeled_physiology", "flywire_sensory"):
            raise LabError(
                "temperature mode must be environment_only, modeled_physiology, or flywire_sensory")
        self.temperature.update(
            celsius=_clamp(celsius, 0.0, 50.0, 25.0),
            mode=mode,
            # The Python side only stores the environment value. In
            # flywire_sensory mode the paired Swift brain maps deviation from
            # 25C into identified TRN_VP2 (warm) / TRN_VP3a+b (cool) cell types.
            # The temperature->current transfer function remains a sensory model.
            neural_connected=(mode == "flywire_sensory"),
            neural_target=("TRN_VP2 / TRN_VP3a+VP3b" if mode == "flywire_sensory" else None),
            controller_tempo_via_brain_packet=(mode == "modeled_physiology"),
        )
        self.environment_revision += 1
        return dict(self.temperature)

    def apply_edit(self, edit):
        """V6.2 strict single-property edit; any rejection leaves the world untouched.

        Every check (schema, bounds, target, applier, revision) runs before the
        first setter. Legacy setters then apply an already in-range value, so
        their clamps are no-ops; yaw keeps its documented modulo-360 normalization.
        Object properties use the object's revision, temperature/eyes/wind use
        environment_revision. A wind edit configures the continuous wind only
        (V6.5): strength > 0 turns it on, 0 turns it off, and direction or the
        physical/sensory flags change while the strength is kept. A timed puff
        is an action, not a setting, so an edit never overwrites a running one.
        """
        d, value = validate_edit(edit, EDIT_DESCRIPTORS)
        pid, target, field = d["property_id"], edit["target_id"], d["legacy_field"]
        if pid.startswith("object."):
            obj = self.objects.get(target)
            if obj is None:
                raise EditError("edit.target_id", "unknown object", status="rejected_target")
            shape = pid.split(".")[1] if pid.count(".") == 2 else None
            if shape is not None and shape != obj.shape:
                raise EditError("edit.target_id", f"target is a {obj.shape}, not a {shape}",
                                status="rejected_target")
            if self.interaction.held_object_id == obj.object_id:
                raise EditError("edit.target_id", "object is held", status="rejected_target")
            current = obj.revision
        elif pid.startswith(("temperature.", "eyes.")):
            current = self.environment_revision
        elif pid in WIND_EDIT_FIELDS:
            if self.wind["strength"] > 0.0 and not self.wind["continuous"]:
                raise EditError("edit.property_id",
                                "a timed wind puff is running; wait for it to end or stop it",
                                status="rejected_busy")
            current = self.environment_revision
        else:
            raise EditError("edit.property_id", "no V6.2 edit applier for this property",
                            status="rejected_unsupported")
        if int(edit["expected_revision"]) != current:
            raise EditError("edit.expected_revision", "stale revision",
                            status="rejected_stale_revision", current_revision=current)
        if field == "position_mm":
            actual = self.move_object(target, position_mm=value)["position_mm"]
        elif field == "pitch_deg":
            actual = self.set_ramp_pitch(target, pitch_deg=value)["pitch_deg"]
        elif field == "yaw_deg":
            actual = self.move_object(target, yaw_deg=value)["yaw_deg"]
        elif field == "size_mm":
            size = self.resize_object(target, size_mm=value)["size_mm"]
            actual = size if d["value_type"] == "vector" else size[0]
        elif pid.startswith("temperature."):
            settings = {"celsius": self.temperature["celsius"], "mode": self.temperature["mode"]}
            actual = self.set_temperature(**{**settings, field: value})[field]
        elif pid in WIND_EDIT_FIELDS:
            w = self.wind
            settings = {"strength": w["strength"], "direction_deg": w["direction_deg"],
                        "physical": w["physical_enabled"], "sensory": w["sensory_enabled"]}
            state = self.set_wind(**{**settings, field: value}, continuous=True)
            actual = state[WIND_EDIT_FIELDS[pid]]
        else:
            actual = self.set_eye_state(**{field: value})[field]
        revision = obj.revision if pid.startswith("object.") else self.environment_revision
        return {"ok": True, "status": "applied", "property_id": pid, "target_id": target,
                "actual_value": actual, "revision": int(revision)}

    def edit_object(self, edit):
        """V6.3 discrete object mutation; validate completely before owner mutation."""
        def reject(path, reason, status="rejected_invalid", **detail):
            raise EditError(path, reason, status=status, **detail)
        fields = ("schema_version", "operation", "target_id", "expected_revision")
        if not isinstance(edit, dict):
            reject("object_edit", "must be an object")
        for key in sorted(set(edit) - set(fields)):
            reject("object_edit." + key, "unknown field")
        for key in fields:
            if key not in edit:
                reject("object_edit." + key, "required")
        version = edit["schema_version"]
        if isinstance(version, bool) or not isinstance(version, (int, float)) or version != 1:
            reject("object_edit.schema_version", "unsupported schema_version")
        operation = edit["operation"]
        if not isinstance(operation, str) or operation not in ("duplicate", "delete"):
            reject("object_edit.operation", "unsupported operation")
        target = edit["target_id"]
        if not isinstance(target, str) or not 1 <= len(target) <= MAX_OBJECT_ID_LEN or target != target.strip():
            reject("object_edit.target_id", "invalid target id")
        revision = edit["expected_revision"]
        if (isinstance(revision, bool) or not isinstance(revision, (int, float))
                or not 0 <= revision <= MAX_REVISION or not math.isfinite(revision)
                or int(revision) != revision):
            reject("object_edit.expected_revision", "must be an integer in range")
        obj = self.objects.get(target)
        if obj is None:
            reject("object_edit.target_id", "unknown target", status="rejected_target")
        if revision != obj.revision:
            reject("object_edit.expected_revision", "stale object revision",
                   status="rejected_revision", current_revision=obj.revision)
        if self.interaction.held_object_id == target:
            reject("object_edit.target_id", "held object cannot be edited", status="rejected_target")
        if operation == "duplicate":
            if not self._free_slots[obj.shape]:
                reject("object_edit.operation", "no free shape slots", status="rejected_capacity",
                       shape=obj.shape, capacity=int(self.slot_counts[obj.shape]))
            # No authored-data coercion here: the source is already an owner object.
            result = self.spawn_object(shape=obj.shape, position_mm=list(obj.position_mm),
                                       size_mm=list(obj.size_mm), yaw_deg=obj.yaw_deg,
                                       variant=obj.variant,
                                       pitch_deg=obj.pitch_deg if obj.shape == "ramp" else None)
            actual = result["id"]
        else:
            self.remove_object(target)
            actual = target
        return {"ok": True, "status": "applied", "property_id": "object." + operation,
                "target_id": target, "actual_value": actual, "revision": self.revision}

    def apply_command(self, command, *, fly_position_mm=(0.0, 0.0, 0.0)):
        """Apply one parsed LabCommand on the simulation-owner thread."""
        op = command.op
        a = command.args
        if op == "edit_object":
            return self.edit_object(a.get("object_edit"))
        if op == "drive_object":
            object_id = _tool_id(a)
            speed = _tool_number(a.get("speed_mm_s", 20), "speed_mm_s", 0, 60)
            distance = _tool_number(a.get("distance_mm", 80), "distance_mm", 0, 300)
            obj = self._require_object(object_id)
            if obj.shape != "car":
                raise LabError("drive_object requires a car")
            if self.interaction.held_object_id == object_id:
                raise LabError("cannot drive held car")
            self.approaches.pop(object_id, None)
            self.drives[object_id] = DriveMotion(object_id, speed, distance)
            return obj.state()
        if op == "arm_trap":
            obj = self._require_object(_tool_id(a))
            if obj.shape != "trap":
                raise LabError("arm_trap requires a trap")
            target = 0.5 * obj.size_mm[2] + TRAP_LIFT_MM
            target_pose = [obj.position_mm[0], obj.position_mm[1], target]
            if (not self._tool_path_clear(obj, target_pose, TRAP_FLOOR_GAP_MM) or
                    not self._try_tool_pose(obj, target_pose, margin=TRAP_FLOOR_GAP_MM)):
                self._interaction_event("trap_blocked", id=obj.object_id)
                return obj.state()
            obj.trap_state = "armed"
            self._trap_blocked.discard(obj.object_id)
            self._interaction_event("trap_armed", id=obj.object_id)
            return obj.state()
        if op == "equip_gun":
            actor = _tool_actor(a)
            equipped = a.get("equipped")
            if not isinstance(equipped, bool):
                raise LabError("equipped must be boolean")
            if actor != self.player.actor_id or not self.player.active:
                raise LabError("active participant required")
            self.player.set_gun_visible(equipped)
            self._bump_revision(structural=True)
            return {"actor_id": actor, "equipped": equipped}
        if op == "fire_bb":
            actor = _tool_actor(a)
            direction = _tool_direction(a.get("direction"))
            return self._fire_bb(actor, direction)
        if op == "interaction":
            return self.apply_interaction(command)
        if op == "edit_property":
            return self.apply_edit(a.get("edit"))
        if op in ("spawn_object", "spawn_box", "spawn_sphere", "spawn_wall", "spawn_ramp"):
            shape = a.get("shape", "box")
            if op.startswith("spawn_") and op != "spawn_object":
                shape = op.removeprefix("spawn_")
            if isinstance(shape, str):
                shape = shape.strip().lower()
            if shape in ("car", "trap"):
                raw_size = a.get("size_mm", 14 if shape == "car" else 20)
                if isinstance(raw_size, (tuple, list)):
                    if len(raw_size) != 1:
                        raise LabError("toy size_mm must be scalar length")
                    raw_size = raw_size[0]
                lower = 4 if shape == "car" else 8
                raw_size = _tool_number(raw_size, "size_mm", lower - 1, 60)
                if raw_size < lower:
                    raise LabError("size_mm out of range")
                pos = a.get("position_mm")
                if pos is not None:
                    if not isinstance(pos, (tuple, list)) or len(pos) != 3:
                        raise LabError("position_mm must be a 3-vector")
                    if any(isinstance(v, bool) or not isinstance(v, (int, float)) or
                           not math.isfinite(v) or abs(v) > 1000 for v in pos):
                        raise LabError("position_mm must contain finite coordinates")
                    pos = [float(v) for v in pos]
                yaw = a.get("yaw_deg", 0)
                if isinstance(yaw, bool) or not isinstance(yaw, (int, float)) or not math.isfinite(yaw):
                    raise LabError("yaw_deg must be finite")
                return self.spawn_object(shape=shape, object_id=a.get("id"),
                                         position_mm=pos, size_mm=raw_size, yaw_deg=yaw)
            return self.spawn_object(
                shape=shape, object_id=a.get("id"),
                position_mm=a.get("position_mm"), size_mm=a.get("size_mm"),
                yaw_deg=a.get("yaw_deg", 0.0), pitch_deg=a.get("pitch_deg"))
        if op in ("spawn_food", "spawn_food_marker"):
            return self.spawn_object(
                shape="food", object_id=a.get("id"), position_mm=a.get("position_mm"),
                size_mm=a.get("size_mm", 3.0), yaw_deg=a.get("yaw_deg", 0.0),
                variant=a.get("variant"))
        if op == "move_object":
            return self.move_object(a.get("id"), position_mm=a.get("position_mm"),
                                    yaw_deg=a.get("yaw_deg"))
        if op == "resize_object":
            return self.resize_object(a.get("id"), size_mm=a.get("size_mm"))
        if op in ("delete_object", "remove_object"):
            return self.remove_object(a.get("id"))
        if op == "reset_world":
            self.reset()
            return {"reset": True}
        if op in ("approach_object", "approach"):
            return self.start_approach(
                a.get("id"), fly_position_mm=fly_position_mm,
                end_distance_mm=a.get("end_distance_mm", 8.0),
                speed_mm_s=a.get("speed_mm_s", 80.0))
        if op in ("wind", "wind_puff"):
            kwargs = dict(
                direction_deg=a.get("direction_deg", 0.0),
                strength=a.get("strength", 0.0),
                duration_ms=a.get("duration_ms"),
                continuous=a.get("continuous"),
                physical=a.get("physical", True),
                sensory=a.get("sensory", True),
            )
            if op == "wind_puff" and "continuous" not in a:
                kwargs["continuous"] = False
            return self.set_wind(**kwargs)
        if op == "stop_wind":
            self.stop_wind()
            return self._wind_state()
        if op == "touch":
            return self.apply_touch(
                target=a.get("target", "thorax"), strength=a.get("strength", 0.5),
                duration_ms=a.get("duration_ms", 20.0),
                direction_world=a.get("direction_world"), sensory=a.get("sensory", True))
        if op in ("set_eye_state", "eye_state"):
            return self.set_eye_state(
                left_enabled=a.get("left_enabled"), right_enabled=a.get("right_enabled"),
                left_mask=a.get("left_mask"), right_mask=a.get("right_mask"))
        if op == "cover_eye":
            eye = str(a.get("eye", "left")).lower()
            if eye == "left":
                return self.set_eye_state(left_mask=1.0)
            if eye == "right":
                return self.set_eye_state(right_mask=1.0)
            if eye == "both":
                return self.set_eye_state(left_mask=1.0, right_mask=1.0)
            raise LabError("eye must be left, right, or both")
        if op == "restore_eyes":
            return self.set_eye_state(left_enabled=True, right_enabled=True,
                                      left_mask=0.0, right_mask=0.0)
        if op == "flash_eye":
            return self.flash_eye(
                eye=a.get("eye", a.get("target", "both")),
                intensity=a.get("intensity", a.get("strength", a.get("value", 1.0))),
                duration_ms=a.get("duration_ms", 100.0))
        if op in ("temperature", "set_temperature"):
            return self.set_temperature(celsius=a.get("celsius", 25.0),
                                        mode=a.get("mode", "environment_only"))
        raise LabError(f"unknown lab op: {op}")

    # ------------------------------------------------------------------
    # Per-MuJoCo-substep update
    # ------------------------------------------------------------------
    def pre_step(self, dt):
        """Advance animations/timers and apply external forces for one sim step."""
        dt = max(0.0, min(0.1, _finite(dt, 0.0)))
        self._sim_time_s += dt
        self._advance_drives(dt)
        self._advance_approaches(dt)
        self.interaction_pre_step(dt)
        self._advance_traps(dt)
        self._advance_bbs(dt)
        if self._bound:
            self._apply_forces()
        self._advance_timers(dt)

    def _tool_obstacles(self, obj):
        """Solid geoms from other lab objects and the active participant."""
        for other in self.objects.values():
            if other.object_id != obj.object_id:
                for gid in self._object_solid_geoms(other):
                    yield gid, "lab_object"
        if self.player.active:
            for gid in self.player.solid_geom_ids():
                yield gid, "player"

    def _tool_clearance(self, obj, margin):
        if not self._bound:
            return math.inf, None
        self._mujoco.mj_forward(self.model, self.data)
        best, kind = math.inf, None
        for own in self._object_solid_geoms(obj):
            for other, other_kind in self._tool_obstacles(obj):
                d = float(self._mujoco.mj_geomDistance(
                    self.model, self.data, own, other, margin + 2.0, None))
                gap = d - (CARRY_GAP_MM if other_kind == "player" else margin)
                if gap < best:
                    best, kind = gap, other_kind
        return best, kind

    def _try_tool_pose(self, obj, target, *, margin=CARRY_CONTACT_SKIN_MM):
        previous = list(obj.position_mm)
        if not self._bound:
            obj.position_mm = list(target)
            self._bump_revision(obj)
            return True
        baseline, _ = self._tool_clearance(obj, margin)
        obj.position_mm = list(target)
        self._sync_object(obj)
        clearance, _ = self._tool_clearance(obj, margin)
        if clearance < -1e-6 and clearance < baseline - 1e-6:
            obj.position_mm = previous
            self._sync_object(obj)
            self._mujoco.mj_forward(self.model, self.data)
            return False
        self._bump_revision(obj)
        self.interaction.previous_distances = None
        return True

    def _tool_path_clear(self, obj, target, margin):
        """Check a raised trap's entire vertical path before committing its pose."""
        if not self._bound:
            return True
        origin = list(obj.position_mm)
        previous, _ = self._tool_clearance(obj, margin)
        steps = max(1, math.ceil(math.dist(origin, target) / 0.25))
        clear = True
        try:
            for index in range(1, steps + 1):
                fraction = index / steps
                obj.position_mm = [a + (b - a) * fraction for a, b in zip(origin, target)]
                self._sync_object(obj)
                clearance, _ = self._tool_clearance(obj, margin)
                if clearance < -1e-6 and clearance < previous - 1e-6:
                    clear = False
                    break
                previous = clearance
        finally:
            obj.position_mm = origin
            self._sync_object(obj)
            self._mujoco.mj_forward(self.model, self.data)
        return clear

    def _advance_drives(self, dt):
        if not self.drives:
            return
        for object_id, motion in list(self.drives.items()):
            obj = self.objects.get(object_id)
            if obj is None or object_id == self.interaction.held_object_id:
                self.drives.pop(object_id, None)
                continue
            yaw = math.radians(obj.yaw_deg)
            direction = (math.cos(yaw), math.sin(yaw))
            travel = min(motion.remaining_mm, motion.speed_mm_s * dt)
            # Conservative rotated footprint so every body part stays on lawn.
            radius_x = 0.5 * (obj.size_mm[0] * abs(direction[0]) +
                              obj.size_mm[1] * abs(direction[1]))
            radius_y = 0.5 * (obj.size_mm[0] * abs(direction[1]) +
                              obj.size_mm[1] * abs(direction[0]))
            edge = math.inf
            for axis, radius in enumerate((radius_x, radius_y)):
                component = direction[axis]
                if abs(component) > 1e-12:
                    limit = (sm.ARENA_HALF_SIZE_MM - radius) * (1 if component > 0 else -1)
                    edge = min(edge, max(0.0, (limit - obj.position_mm[axis]) / component))
            edge_block = edge < travel - 1e-9
            travel = min(travel, edge)
            origin = list(obj.position_mm)
            def target(frac):
                return [origin[0] + direction[0] * travel * frac,
                        origin[1] + direction[1] * travel * frac, origin[2]]
            if travel > 0 and not self._try_tool_pose(obj, target(1.0)):
                low, high = 0.0, 1.0
                for _ in range(12):
                    mid = (low + high) * 0.5
                    if self._try_tool_pose(obj, target(mid)):
                        low = mid
                    else:
                        high = mid
                self.drives.pop(object_id, None)
                self._interaction_event("car_blocked", id=object_id,
                                        blocking_geom_kind="player_or_lab_object")
                continue
            motion.remaining_mm -= travel
            if edge_block or travel <= 0:
                self.drives.pop(object_id, None)
                self._interaction_event("car_blocked", id=object_id,
                                        blocking_geom_kind="lawn_edge")
            elif motion.remaining_mm <= 1e-6:
                self.drives.pop(object_id, None)
                self._interaction_event("drive_complete", id=object_id)

    def _advance_traps(self, dt):
        traps = [obj for obj in self.objects.values()
                 if obj.shape == "trap" and obj.object_id != self.interaction.held_object_id]
        if not traps:
            return
        fly = getattr(self, "fly_position_mm", None)
        for obj in traps:
            if obj.trap_state == "armed" and fly is not None:
                yaw = math.radians(obj.yaw_deg)
                dx, dy = fly[0] - obj.position_mm[0], fly[1] - obj.position_mm[1]
                local_x = math.cos(yaw) * dx + math.sin(yaw) * dy
                local_y = -math.sin(yaw) * dx + math.cos(yaw) * dy
                inner = obj.size_mm[0] * (0.5 - sm.TRAP_WALL_RATIO) - 2.0
                if abs(local_x) <= inner and abs(local_y) <= inner:
                    obj.trap_state = "dropping"
                    self._interaction_event("trap_triggered", id=obj.object_id)
            if obj.trap_state != "dropping":
                continue
            floor_z = 0.5 * obj.size_mm[2] + TRAP_FLOOR_GAP_MM
            target_z = max(floor_z, obj.position_mm[2] - TRAP_DROP_SPEED_MM_S * dt)
            if not self._try_tool_pose(obj, [*obj.position_mm[:2], target_z],
                                       margin=TRAP_FLOOR_GAP_MM):
                if obj.object_id not in self._trap_blocked:
                    self._interaction_event("trap_blocked", id=obj.object_id)
                    self._trap_blocked.add(obj.object_id)
                continue
            self._trap_blocked.discard(obj.object_id)
            if target_z <= floor_z + 1e-8:
                obj.trap_state = "closed"
                self._interaction_event("trap_closed", id=obj.object_id)

    def _park_bb(self, projectile):
        if self._bound:
            bid, gid, qadr, dadr = self._bb_ids[projectile.index]
            self.data.qpos[qadr:qadr + 3] = FAR_POS
            self.data.qpos[qadr + 3:qadr + 7] = [1, 0, 0, 0]
            self.data.qvel[dadr:dadr + 6] = 0
            self.model.body_gravcomp[bid] = 1.0
            self.model.geom_rgba[gid, 3] = 0.0
            sm.set_geom_collidable(self.model, gid, False)
            self._hide_tracer(projectile.index)
        self.projectiles.pop(projectile.id, None)

    def _park_all_bbs(self):
        for projectile in list(self.projectiles.values()):
            self._park_bb(projectile)
        if self._bound:
            for bid, gid, qadr, dadr in self._bb_ids:
                self.data.qpos[qadr:qadr + 3] = FAR_POS
                self.data.qpos[qadr + 3:qadr + 7] = [1, 0, 0, 0]
                self.data.qvel[dadr:dadr + 6] = 0
                self.model.body_gravcomp[bid] = 1.0
                self.model.geom_rgba[gid, 3] = 0.0
                sm.set_geom_collidable(self.model, gid, False)

    def _fire_bb(self, actor, direction):
        if actor != self.player.actor_id or not self.player.active or not self.player.gun_visible:
            raise LabError("active participant with equipped gun required")
        if self._sim_time_s - self._last_bb_fire_s < BB_RATE_LIMIT_S - 1e-9:
            raise LabError("BB rate limit")
        occupied = {p.index for p in self.projectiles.values()}
        index = next((i for i in range(BB_POOL_SIZE) if i not in occupied), None)
        if index is None:
            raise LabError("BB pool full")
        yaw_q = self.player._body_quat_wxyz()
        yaw = 2.0 * math.atan2(yaw_q[3], yaw_q[0])
        x, y, z = sm.BB_MUZZLE_OFFSET_MM
        position = [self.player.position_mm[0] + math.cos(yaw) * x - math.sin(yaw) * y,
                    self.player.position_mm[1] + math.sin(yaw) * x + math.cos(yaw) * y,
                    self.player.position_mm[2] + z]
        target = self._bb_aim_point(direction)
        velocity = _ballistic_velocity(position, target, BB_SPEED_MM_S, self._gravity_mm_s2())
        self._bb_counter += 1
        projectile = Projectile(f"bb_{self._bb_counter}", index, position, velocity,
                                self._sim_time_s)
        projectile.trail.append((self._sim_time_s, list(position)))
        if self._bound:
            bid, gid, qadr, dadr = self._bb_ids[index]
            self.data.qpos[qadr:qadr + 3] = position
            self.data.qpos[qadr + 3:qadr + 7] = [1, 0, 0, 0]
            self.data.qvel[dadr:dadr + 3] = projectile.velocity_mm_s
            self.data.qvel[dadr + 3:dadr + 6] = 0
            self.model.body_gravcomp[bid] = 0.0
            self.model.geom_rgba[gid] = sm.BB_RGBA
            sm.set_geom_collidable(self.model, gid, True)
        self.projectiles[projectile.id] = projectile
        self._last_bb_fire_s = self._sim_time_s
        self._interaction_event("bb_fired", id=projectile.id, actor_id=actor,
                                position_mm=list(position))
        return {"id": projectile.id, "position_mm": list(position)}

    def _gravity_mm_s2(self):
        return abs(float(self.model.opt.gravity[2])) if self._bound else 9810.0

    def _bb_aim_point(self, direction):
        """Point under the crosshair: the look ray from the eye (as the camera)."""
        center = participant_center(self.player)
        x, y, z, w = self.player.orientation_quat_xyzw
        look = [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)]
        eye = [center[i] + look[i] * self.player.radius_mm * 0.6 for i in range(3)]
        reach = BB_AIM_RANGE_MM
        if self._bound:
            import numpy as np
            hit = np.array([-1], dtype=np.int32)
            groups = np.array([1, 1, 1, 0, 0, 0], dtype=np.uint8)  # skip view-only tracers
            self._mujoco.mj_forward(self.model, self.data)
            distance = float(self._mujoco.mj_ray(
                self.model, self.data, np.array(eye), np.array(direction), groups, 1,
                self.player.body_id, hit))
            if 0.0 <= distance < reach:
                reach = distance
        return [eye[i] + direction[i] * reach for i in range(3)]

    def _hide_tracer(self, index):
        mocap, gid = self._bb_tracers[index]
        self.data.mocap_pos[mocap] = FAR_POS
        self.model.geom_rgba[gid, 3] = 0.0

    def _update_tracer(self, projectile):
        """Stretch the view-only streak over the last BB_TRACER_TRAIL_S of flight."""
        now = self._sim_time_s
        trail = projectile.trail
        if not trail or now - trail[-1][0] >= 0.002:
            trail.append((now, list(projectile.position_mm)))
        while len(trail) > 2 and now - trail[1][0] > sm.BB_TRACER_TRAIL_S:
            trail.pop(0)
        start, end = trail[0][1], projectile.position_mm
        length = math.dist(start, end)
        if length < 0.3:
            self._hide_tracer(projectile.index)
            return
        mocap, gid = self._bb_tracers[projectile.index]
        self.data.mocap_pos[mocap] = [(a + b) * 0.5 for a, b in zip(start, end)]
        self.data.mocap_quat[mocap] = sm.quat_z_to([b - a for a, b in zip(start, end)])
        self.model.geom_size[gid] = [sm.BB_TRACER_RADIUS_MM, length * 0.5, 0.0]
        self.model.geom_rgba[gid] = sm.BB_TRACER_RGBA

    def _advance_bbs(self, dt):
        if not self.projectiles:
            return
        for projectile in list(self.projectiles.values()):
            if self._bound:
                _, _, qadr, _ = self._bb_ids[projectile.index]
                projectile.position_mm = [float(v) for v in self.data.qpos[qadr:qadr + 3]]
            else:
                projectile.velocity_mm_s[2] -= 9810.0 * dt
                projectile.position_mm = [p + v * dt for p, v in zip(
                    projectile.position_mm, projectile.velocity_mm_s)]
            if self._bound:
                self._update_tracer(projectile)
            x, y, z = projectile.position_mm
            if (self._sim_time_s - projectile.fired_s >= BB_LIFETIME_S or
                    abs(x) > sm.ARENA_HALF_SIZE_MM or abs(y) > sm.ARENA_HALF_SIZE_MM or z < -5):
                self._park_bb(projectile)
                self._interaction_event("bb_expired", id=projectile.id)

    def projectile_state(self):
        if self._bound:
            return [{"id": p.id, "position_mm": [float(v) for v in
                     self.data.qpos[self._bb_ids[p.index][2]:self._bb_ids[p.index][2] + 3]]}
                    for p in self.projectiles.values()]
        return [{"id": p.id, "position_mm": list(p.position_mm)}
                for p in self.projectiles.values()]

    def _advance_approaches(self, dt):
        finished = []
        for object_id, motion in list(self.approaches.items()):
            if object_id == self.interaction.held_object_id:
                finished.append(object_id)
                continue
            obj = self.objects.get(object_id)
            if obj is None:
                finished.append(object_id)
                continue
            dx = motion.target_xy_mm[0] - obj.position_mm[0]
            dy = motion.target_xy_mm[1] - obj.position_mm[1]
            distance = math.hypot(dx, dy)
            if distance <= motion.end_distance_mm + 1e-6:
                finished.append(object_id)
                continue
            step = min(max(0.0, distance - motion.end_distance_mm), motion.speed_mm_s * dt)
            if distance > 1e-9 and step > 0.0:
                obj.position_mm[0] += dx / distance * step
                obj.position_mm[1] += dy / distance * step
                self._bump_revision(obj)
                self._sync_object(obj)
                self.interaction.previous_distances = None
            if distance - step <= motion.end_distance_mm + 1e-6:
                finished.append(object_id)
        for object_id in finished:
            motion = self.approaches.pop(object_id, None)
            if motion is not None:
                self._append_event({
                    "event": "approach_complete",
                    "classification": PHYSICAL,
                    "id": object_id,
                })

    def _advance_timers(self, dt):
        if self.wind["strength"] > 0.0 and not self.wind["continuous"]:
            self.wind["remaining_s"] = max(0.0, self.wind["remaining_s"] - dt)
            if self.wind["remaining_s"] <= 0.0:
                self.stop_wind()
                self._append_event({"event": "wind_complete", "classification": PHYSICAL})
        if self.touch is not None:
            self.touch["remaining_s"] = max(0.0, self.touch["remaining_s"] - dt)
            if self.touch["remaining_s"] <= 0.0:
                target = self.touch["target"]
                self.touch = None
                self._append_event({
                    "event": "touch_complete", "classification": PHYSICAL, "target": target})
        if self.flash["remaining_s"] > 0.0:
            self.flash["remaining_s"] = max(0.0, self.flash["remaining_s"] - dt)
            if self.flash["remaining_s"] <= 0.0:
                eye = self.flash["eye"]
                intensity = self.flash["intensity"]
                self.flash.update(intensity=0.0, remaining_s=0.0)
                if intensity > 0.0:
                    self._append_event({
                        "event": "flash_complete", "classification": SENSORY_MODEL, "eye": eye})

    def _body_speed_along(self, bid, direction):
        """World horizontal speed of a free-jointed body along a unit XY direction."""
        jnt = int(self.model.body_jntadr[bid])
        if jnt < 0 or int(self.model.jnt_type[jnt]) != 0:  # 0 = mjJNT_FREE
            return 0.0
        dof = int(self.model.jnt_dofadr[jnt])
        return float(self.data.qvel[dof]) * direction[0] + float(self.data.qvel[dof + 1]) * direction[1]

    def _apply_forces(self):
        # Remove only the force vectors previously contributed by this module so
        # another subsystem using xfrc_applied is not clobbered.
        for bid, vec in self._previous_forces.items():
            self.data.xfrc_applied[bid, :3] -= vec
        forces = {}

        if (self.wind["strength"] > 0.0 and self.wind["physical_enabled"] and
                "thorax" in self.force_body_ids):
            bid = self.force_body_ids["thorax"]
            mass = max(0.0, float(self.model.body_mass[bid]))
            angle = math.radians(self.wind["direction_deg"])
            direction = (math.cos(angle), math.sin(angle))
            mag = mass * WIND_ACCEL_MAX_MM_S2 * self.wind["strength"]
            # The push fades as the thorax approaches the wind's own speed, so a
            # fly that loses its footing drifts with the wind instead of being
            # accelerated without bound (a constant force tumbled it away).
            wind_speed = WIND_SPEED_MAX_MM_S * self.wind["strength"]
            mag *= _clamp(1.0 - self._body_speed_along(bid, direction) / wind_speed, 0.0, 1.0, 0.0)
            forces[bid] = [direction[0] * mag, direction[1] * mag, 0.0]

        if self.touch is not None and self.touch["strength"] > 0.0:
            bid = self.force_body_ids.get(self.touch["target"])
            if bid is not None:
                mass = max(0.0, float(self.model.body_mass[bid]))
                mag = mass * TOUCH_ACCEL_MAX_MM_S2 * self.touch["strength"]
                vec = [v * mag for v in self.touch["direction_world"]]
                if bid in forces:
                    forces[bid] = [a + b for a, b in zip(forces[bid], vec)]
                else:
                    forces[bid] = vec

        for bid, vec in forces.items():
            self.data.xfrc_applied[bid, :3] += vec
        self._previous_forces = forces

    # ------------------------------------------------------------------
    # V5.6.2 feeding: haustellum contact consumes food
    # ------------------------------------------------------------------
    def _mouth_food_distance(self, obj, mouth_position_mm):
        """Surface distance from the fly's mouth to one food model, or None if far."""
        radius = obj.size_mm[0] * 0.5
        if not self._bound or not self._mouth_geom_ids:
            if mouth_position_mm is None:
                return None
            return math.dist(mouth_position_mm, obj.position_mm) - radius
        mouth = self._mouth_geom_ids[0]
        center = [float(v) for v in self.data.geom_xpos[mouth]]
        if math.dist(center, obj.position_mm) > radius + 2.0:
            return None  # cheap reject: the haustellum is well under 1 mm across
        best = None
        for gid in self._food_palettes[obj.slot].all_gids():
            if self.model.geom_rgba[gid, 3] <= 0.0:
                continue
            d = float(self._mujoco.mj_geomDistance(
                self.model, self.data, mouth, gid, FEED_CONTACT_MM + 1.0, None))
            best = d if best is None else min(best, d)
        return best

    def feeding_update(self, dt, *, mouth_position_mm=None):
        """Advance feeding by one physics quantum; return the modeled taste signal.

        Called after the quantum's substeps (poses current). Only the nearest
        food within FEED_CONTACT_MM of the haustellum is eaten.
        """
        dt = max(0.0, _finite(dt, 0.0))
        eating, nearest = None, FEED_CONTACT_MM
        for obj in self.objects.values():
            if obj.shape != "food":
                continue
            distance = self._mouth_food_distance(obj, mouth_position_mm)
            if distance is not None and distance <= nearest:
                eating, nearest = obj, distance
        previous = self._eating_id
        if previous is not None and (eating is None or eating.object_id != previous):
            self._append_event({"event": "feeding_end", "classification": PHYSICAL,
                                "id": previous, "contact_s": self.feeding.pop(previous, 0.0)})
        if eating is None:
            self._eating_id = None
            return {"taste_sugar": 0.0, "eating_food_id": None}
        food_id, sugar = eating.object_id, sm.FOOD_SUGAR.get(eating.variant, 0.0)
        if previous != food_id:
            self._append_event({"event": "feeding_begin", "classification": PHYSICAL,
                                "id": food_id, "food_variant": eating.variant})
        self._eating_id = food_id
        self.feeding[food_id] = self.feeding.get(food_id, 0.0) + dt
        diameter = eating.size_mm[0] - FEED_SHRINK_MM_S * dt
        if diameter < FEED_MIN_DIAMETER_MM:
            contact_s = self.feeding.pop(food_id, 0.0)
            # Depletion owns the end event below; do not also close it in removal.
            self._eating_id = None
            self.remove_object(food_id)
            # Close the contact interval opened by feeding_begin before the food
            # disappears, so every begin has exactly one end.
            self._append_event({"event": "feeding_end", "classification": PHYSICAL,
                                "id": food_id, "contact_s": contact_s, "reason": "eaten"})
            self._append_event({"event": "food_eaten", "classification": PHYSICAL,
                                "id": food_id, "food_variant": eating.variant,
                                "contact_s": contact_s})
        else:
            bite = eating.size_mm[0] - diameter
            eating.size_mm = [diameter] * 3
            # Eaten from the mouth side: the centre moves toward the mouth by the
            # bite radius, so the surface the fly is touching stays put, and the
            # food keeps resting on the floor.
            mouth = (mouth_position_mm if mouth_position_mm is not None or not self._mouth_geom_ids
                     else [float(v) for v in self.data.geom_xpos[self._mouth_geom_ids[0]]])
            if mouth is not None:
                dx, dy = mouth[0] - eating.position_mm[0], mouth[1] - eating.position_mm[1]
                reach = math.hypot(dx, dy)
                if reach > 1e-9:
                    step = min(reach, bite * 0.5)
                    eating.position_mm[0] += dx / reach * step
                    eating.position_mm[1] += dy / reach * step
            eating.position_mm[2] = max(diameter * 0.5, eating.position_mm[2] - bite * 0.5)
            self._bump_revision(eating)
            self._sync_object(eating)
        return {"taste_sugar": sugar, "eating_food_id": food_id}

    # ------------------------------------------------------------------
    # Vision and telemetry
    # ------------------------------------------------------------------
    def food_odor(self, *, fly_position_mm=(0.0, 0.0, 0.0), fly_heading_rad=0.0):
        """Return a bounded, purely modeled bilateral food-odor signal.

        This is deliberately only a sensory telemetry model. It does not move
        the fly, trigger feeding, produce reward, or inject neural activity.

        Each food source contributes an isotropic exponential concentration
        based on distance from the marker surface. Contributions saturate in
        [0, 1]. The horizontal source bearing relative to ``fly_heading_rad``
        splits that concentration between left/right channels; it does not
        implement a plume, wind advection, antennal biomechanics, or behavior.
        """
        fly = _vec3(fly_position_mm, [0.0, 0.0, 0.0])
        heading = _finite(fly_heading_rad, 0.0)
        left_survival = 1.0
        right_survival = 1.0
        nearest = None

        for obj in self.objects.values():
            if obj.shape != "food":
                continue
            dx = obj.position_mm[0] - fly[0]
            dy = obj.position_mm[1] - fly[1]
            dz = obj.position_mm[2] - fly[2]
            center_distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            nearest = center_distance if nearest is None else min(nearest, center_distance)

            radius = max(0.0, obj.size_mm[0] * 0.5)
            surface_distance = max(0.0, center_distance - radius)
            concentration = math.exp(-surface_distance / FOOD_ODOR_DECAY_MM)
            concentration = _clamp(concentration, 0.0, 1.0, 0.0)

            bearing = math.atan2(dy, dx)
            lateral = math.sin(bearing - heading)  # +1 is fly-left, -1 fly-right.
            left_contribution = concentration * (0.5 + 0.5 * lateral)
            right_contribution = concentration * (0.5 - 0.5 * lateral)
            # Saturating union: preserves bounds even with several food sources.
            left_survival *= 1.0 - _clamp(left_contribution, 0.0, 1.0, 0.0)
            right_survival *= 1.0 - _clamp(right_contribution, 0.0, 1.0, 0.0)

        return {
            "odor_left": _clamp(1.0 - left_survival, 0.0, 1.0, 0.0),
            "odor_right": _clamp(1.0 - right_survival, 0.0, 1.0, 0.0),
            "nearest_food_distance_mm": None if nearest is None else float(nearest),
            "classification": SENSORY_MODEL,
            "backend_direct_neural": False,
            "integrated_neural_target": "ORN_DM1/VA2 via Swift",
            "taste_modeled": False,
            "reward_modeled": False,
            "feeding_modeled": False,
            "behavior_scripted": False,
        }

    def apply_eye_mask(self, frames):
        """Apply V1 SENSORY_MODEL eye enable/mask state to a stereo frame copy."""
        # RealFlyBody owns numpy; avoid importing it for mock/tests.
        arr = frames.copy()
        for idx, side in enumerate(("left", "right")):
            enabled = self.eyes[f"{side}_enabled"]
            mask = self.eyes[f"{side}_mask"]
            if not enabled or mask >= 1.0:
                arr[idx, ...] = 0
            elif mask > 0.0:
                arr[idx, ...] = arr[idx, ...] * (1.0 - mask)
        return arr

    def augment_vision_state(self, vision_state):
        """Add flash brightness telemetry without altering looming.

        The V1 connectome has a looming input but no full photoreceptor pathway.
        Flash therefore changes brightness telemetry only; `loom_left/right` are
        preserved exactly from the unflashed eye frames.
        """
        out = dict(vision_state)
        left = _clamp(out.get("brightness_left", out.get("brightness", 0.0)), 0.0, 1.0)
        right = _clamp(out.get("brightness_right", out.get("brightness", 0.0)), 0.0, 1.0)
        intensity = self.flash["intensity"]
        if intensity > 0.0:
            if self.flash["eye"] in ("left", "both"):
                left = max(left, intensity)
            if self.flash["eye"] in ("right", "both"):
                right = max(right, intensity)
        out["brightness_left"] = left
        out["brightness_right"] = right
        out["brightness"] = (left + right) * 0.5
        out["flash_left"] = intensity if self.flash["eye"] in ("left", "both") else 0.0
        out["flash_right"] = intensity if self.flash["eye"] in ("right", "both") else 0.0
        return out

    def _wind_state(self):
        return {
            "strength": float(self.wind["strength"]),
            "direction_deg": float(self.wind["direction_deg"]),
            "continuous": bool(self.wind["continuous"]),
            "remaining_ms": None if self.wind["continuous"] else float(self.wind["remaining_s"] * 1000.0),
            "physical_enabled": bool(self.wind["physical_enabled"]),
            "sensory_enabled": bool(self.wind["sensory_enabled"]),
            "classification": PHYSICAL,
            "sensory_classification": SENSORY_MODEL,
        }

    def _touch_state(self):
        if self.touch is None:
            return None
        return {
            "target": self.touch["target"],
            "strength": float(self.touch["strength"]),
            "remaining_ms": float(self.touch["remaining_s"] * 1000.0),
            "sensory_enabled": bool(self.touch["sensory_enabled"]),
            "classification": PHYSICAL,
            "sensory_classification": SENSORY_MODEL,
        }

    def _flash_state(self):
        return {
            "eye": self.flash["eye"],
            "intensity": float(self.flash["intensity"]),
            "remaining_ms": float(self.flash["remaining_s"] * 1000.0),
            "classification": SENSORY_MODEL,
            "neural_connected": False,
        }

    def render_objects(self):
        """Return the authoritative render geometry visible to V5 clients.

        Bound mode reads pose/size back from the live MuJoCo model/data so the
        viewport snapshot describes the same geometry used for rendering and
        collision. Mock mode emits the equivalent semantic state.
        """
        rendered = []
        for object_id in sorted(self.objects):
            obj = self.objects[object_id]
            if self._bound:
                _, gid, mocap_id = self._slot_ids[obj.slot]
                if mocap_id >= 0:
                    pos = [float(v) for v in self.data.mocap_pos[mocap_id]]
                    quat_wxyz = [float(v) for v in self.data.mocap_quat[mocap_id]]
                else:
                    bid, _, _ = self._slot_ids[obj.slot]
                    pos = [float(v) for v in self.model.body_pos[bid]]
                    quat_wxyz = [float(v) for v in self.model.body_quat[bid]]
                if obj.shape in ("car", "trap", "food"):
                    size = [float(v) for v in obj.size_mm]
                elif obj.shape in ("box", "wall", "ramp"):
                    size = [float(v) * 2.0 for v in self.model.geom_size[gid][:3]]
                else:
                    diameter = float(self.model.geom_size[gid][0]) * 2.0
                    size = [diameter, diameter, diameter]
                quat = [quat_wxyz[1], quat_wxyz[2], quat_wxyz[3], quat_wxyz[0]]
            else:
                pos = [float(v) for v in obj.position_mm]
                w, x, y, z = obj.quat_wxyz()
                quat = [x, y, z, w]
                size = [float(v) for v in obj.size_mm]
            rendered.append({
                "id": obj.object_id,
                "shape": obj.shape,
                "position_mm": pos,
                "orientation_quat_xyzw": quat,
                "size_mm": size,
                "revision": int(obj.revision),
                "classification": PHYSICAL,
                "collidable": obj.shape != "food",
                **({"food_variant": obj.variant} if obj.shape == "food" else {}),
                **({"trap_state": obj.trap_state} if obj.shape == "trap" else {}),
            })
        return rendered

    def semantic_target_for_geom(self, geom_id):
        """Map one compiled MuJoCo geom id back to a stable lab object id."""
        player = self.player.semantic_target_for_geom(geom_id)
        if player is not None:
            return player
        if not self._bound:
            return None
        try:
            geom_id = int(geom_id)
        except (TypeError, ValueError, OverflowError):
            return None
        food_slot = self._food_part_owner.get(geom_id)
        toy_slot = self._toy_part_owner.get(geom_id)
        for obj in self.objects.values():
            ids = self._slot_ids.get(obj.slot)
            if ((ids is not None and int(ids[1]) == geom_id) or
                    obj.slot == food_slot or obj.slot == toy_slot):
                return {"target_id": obj.object_id, "target_kind": "lab_object"}
        return None

    def state(self):
        return {
            "physical_backend": bool(self._bound),
            "environment_capabilities": environment_capabilities(
                self.force_body_ids if self._bound else None),
            "world_revision": int(self.revision),
            "environment_revision": int(self.environment_revision),
            "objects": [self.objects[k].state() for k in sorted(self.objects)],
            "projectiles": self.projectile_state(),
            "player": self.player.render_pose(),
            "interaction": self.interaction.state(),
            "slot_capacity": {shape: int(count) for shape, count in self.slot_counts.items()},
            "slot_free": {shape: len(slots) for shape, slots in self._free_slots.items()},
            "terrain_contact_pairs": int(self._terrain_pair_count),
            "approaches": [
                {
                    "id": m.object_id,
                    "target_xy_mm": list(m.target_xy_mm),
                    "end_distance_mm": float(m.end_distance_mm),
                    "speed_mm_s": float(m.speed_mm_s),
                }
                for _, m in sorted(self.approaches.items())
            ],
            "wind": self._wind_state(),
            "touch": self._touch_state(),
            "flash": self._flash_state(),
            "eyes": {
                **dict(self.eyes),
                "classification": SENSORY_MODEL,
            },
            "temperature": {
                **dict(self.temperature),
                "classification": SENSORY_MODEL,
                "note": (
                    "flywire_sensory targets identified TRN cell types; scalar-to-current transduction is modeled"
                    if self.temperature.get("mode") == "flywire_sensory"
                    else (
                        "Controller tempo is carried by BrainPacket.tempo; no direct thermosensory neural input"
                        if self.temperature.get("mode") == "modeled_physiology"
                        else "No direct thermosensory neural input in this mode"
                    )
                ),
            },
        }

    def drain_events(self):
        out = list(self.events)
        self.events.clear()
        return out

    # ------------------------------------------------------------------
    # Compiled-slot synchronization
    # ------------------------------------------------------------------
    def _sync_all(self):
        if not self._bound:
            return
        active = {obj.slot: obj for obj in self.objects.values()}
        for slot in self._slot_shape:
            obj = active.get(slot)
            if obj is None:
                self._deactivate_slot(slot)
            else:
                self._sync_object(obj)

    def _sync_object(self, obj):
        if not self._bound:
            return
        bid, gid, mocap_id = self._slot_ids[obj.slot]
        quat = obj.quat_wxyz()
        if mocap_id >= 0:
            self.data.mocap_pos[mocap_id] = obj.position_mm
            self.data.mocap_quat[mocap_id] = quat
        else:
            self.model.body_pos[bid] = obj.position_mm
            self.model.body_quat[bid] = quat
        if obj.shape in ("box", "wall", "ramp"):
            self.model.geom_size[gid] = [max(0.1, v * 0.5) for v in obj.size_mm]
            if obj.shape == "ramp":
                # Every ramp/fly pair is explicit, and explicit pairs are culled
                # only by these bounds. Left at the compiled maximum (rbound
                # ~173 mm), every leg pair would reach narrow phase whenever
                # the fly is anywhere near a ramp, not just on it.
                half = self.model.geom_size[gid]
                self.model.geom_aabb[gid] = [0.0, 0.0, 0.0, *half]
                self.model.geom_rbound[gid] = math.sqrt(float(half @ half))
        else:
            radius = max(0.1, obj.size_mm[0] * 0.5)
            self.model.geom_size[gid] = [radius, 0.0, 0.0]
        self.model.geom_rgba[gid] = DEFAULT_COLORS[obj.shape]
        if obj.shape in ("food", "car", "trap"):
            sm.set_geom_collidable(self.model, gid, False)
            self.model.geom_rgba[gid, 3] = 0.0
            if obj.shape == "food":
                self._food_palettes[obj.slot].fill(
                    self.model, sm.FOOD_VARIANTS[obj.variant], scale=obj.size_mm[0], collidable=False)
            else:
                palette = self._toy_palettes[obj.slot]
                parts = sm.CAR_PARTS if obj.shape == "car" else sm.TRAP_PARTS
                self._solid_by_slot[obj.slot] = palette.fill(
                    self.model, parts, scale=obj.size_mm[0], collidable=True)
        else:
            sm.set_geom_collidable(self.model, gid, True)

    def _deactivate_slot(self, slot):
        if not self._bound:
            return
        bid, gid, mocap_id = self._slot_ids[slot]
        if mocap_id >= 0:
            self.data.mocap_pos[mocap_id] = FAR_POS
        else:
            self.model.body_pos[bid] = FAR_POS
        self.model.geom_rgba[gid, 3] = 0.0
        sm.set_geom_collidable(self.model, gid, False)
        if slot in self._food_palettes:
            self._food_palettes[slot].fill(self.model, (), visible=False)
        if slot in self._toy_palettes:
            self._toy_palettes[slot].fill(self.model, (), visible=False)
            self._solid_by_slot[slot] = []
