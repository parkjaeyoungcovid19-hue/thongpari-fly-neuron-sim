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
from dataclasses import dataclass
from player_body import PlayerBody


PHYSICAL = "PHYSICAL"
SENSORY_MODEL = "SENSORY-MODEL"
DIRECT_NEURAL = "DIRECT-NEURAL"

FAR_POS = (0.0, 0.0, -500.0)
MAX_OBJECT_ID_LEN = 64
MAX_EVENTS = 64
# Calibrated after restoring near-realtime MuJoCo throughput. 2500 mm/s² produced
# only ~0.035 mm extra thorax displacement over a 0.5 s strength-0.7 puff on the
# shipped NeuroMechFly, effectively invisible next to normal passive drift.
# 10000 mm/s² yields ~0.18 mm extra displacement in the same smoke test: clearly
# measurable but still well below the destabilizing regime seen at much larger
# forces. This remains an engineering lab-force scale, not a biological wind law.
WIND_ACCEL_MAX_MM_S2 = 10000.0
TOUCH_ACCEL_MAX_MM_S2 = 16000.0
FOOD_ODOR_DECAY_MM = 30.0

# Fixed topology, bounded memory. Food uses non-colliding sphere slots. Its
# odor field is a bounded sensory model only; taste/reward/feeding and direct
# neural wiring remain intentionally absent.
DEFAULT_SLOT_COUNTS = {
    # Runtime MuJoCo topology is fixed after compilation, so keep a generous
    # preallocated pool. These mocap geoms are hidden/inactive until used and
    # are cheap compared with the fly model itself.
    "box": 64,
    "sphere": 64,
    "wall": 64,
    "food": 32,
}

MAX_SLOT_COUNT_PER_SHAPE = 256

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
}


class LabError(ValueError):
    pass


def _finite(value, default=0.0):
    try:
        out = float(value)
    except (TypeError, ValueError):
        return float(default)
    return out if math.isfinite(out) else float(default)


def _clamp(value, lo, hi, default=0.0):
    return max(lo, min(hi, _finite(value, default)))


def _vec3(value, default):
    if not isinstance(value, (list, tuple)) or len(value) < 3:
        value = default
    return [_finite(value[i], default[i]) for i in range(3)]


def _normalize3(value, default=(0.0, 1.0, 0.0)):
    vec = _vec3(value, default)
    mag = math.sqrt(sum(v * v for v in vec))
    if mag < 1e-9:
        vec = list(default)
        mag = math.sqrt(sum(v * v for v in vec))
    return [v / mag for v in vec]


@dataclass
class LabObject:
    object_id: str
    shape: str
    slot: str
    position_mm: list
    size_mm: list
    yaw_deg: float = 0.0
    revision: int = 0

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
                taste_modeled=False,
                reward_modeled=False,
                feeding_modeled=False,
                behavior_scripted=False,
                note="Odor source modeled; taste/reward/feeding absent; no scripted seeking",
            )
        return out


@dataclass
class ApproachMotion:
    object_id: str
    target_xy_mm: tuple
    end_distance_mm: float
    speed_mm_s: float


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
        self.revision = 0
        # Render revision advances for every visible pose/size/topology change.
        # Structural revision advances only when the ray-query scene contract is
        # invalidated (objects added/removed/resized/reset). Pure pose motion is
        # intentionally excluded so a just-rendered frame may still be used as
        # provenance for a current-owner ray while an approach is moving.
        self.structure_revision = 0
        self._bound = False
        self._mujoco = None
        self.model = None
        self.data = None
        self.force_body_ids = {}
        self._previous_forces = {}
        self.approaches = {}
        self.events = deque(maxlen=MAX_EVENTS)
        # V5.4 participant is one dedicated actor, not part of the generic
        # LabObject pool. LabWorld still owns its lifecycle/revision semantics.
        self.player = PlayerBody()
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

        for slot, shape in self._slot_shape.items():
            # Mocap bodies are kinematic runtime objects: MuJoCo keeps them in
            # the compiled model and exposes data.mocap_pos/quat for safe motion.
            body = world.mjcf_root.worldbody.add_body(name=slot, pos=FAR_POS, mocap=True)
            if shape in ("box", "wall"):
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
        self.player.install(world)

    def bind(self, sim, force_body_ids=None):
        """Resolve slot/body ids after Simulation construction."""
        import mujoco

        self._mujoco = mujoco
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
        self._bound = True
        self._sync_all()

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

    def set_force_body_ids(self, mapping):
        self.force_body_ids = dict(mapping or {})

    def resync_after_sim_reset(self):
        """Restore active LabObject slots and the free-joint participant after reset."""
        self._previous_forces = {}
        self._sync_all()
        self.player.resync_after_sim_reset()

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
        changed, pose = self.player.set_active(active)
        if changed:
            self._bump_revision(structural=True)
        return {"player": pose, "player_active": self.player.active}

    def set_player_pose(self, *, position_mm=None, orientation_quat_xyzw=None, mode=None):
        """Owner-thread participant pose update; no input/wire policy lives here."""
        self.player.set_pose(position_mm=position_mm,
                             orientation_quat_xyzw=orientation_quat_xyzw,
                             mode=mode)
        if self.player.active:
            self._bump_revision(structural=False)
        return self.player.render_pose()

    def reset_player_pose(self, *, preserve_active=True):
        was_active = self.player.active
        self.player.reset_pose(preserve_active=preserve_active)
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
        if shape in ("sphere", "food"):
            if isinstance(size_mm, (int, float)):
                diameter = _clamp(size_mm, 0.2, 100.0, 3.0)
            elif isinstance(size_mm, (list, tuple)) and size_mm:
                diameter = _clamp(size_mm[0], 0.2, 100.0, 3.0)
            else:
                diameter = 3.0 if shape == "food" else 5.0
            return [diameter, diameter, diameter]
        default = [10.0, 10.0, 10.0] if shape == "box" else [2.0, 30.0, 15.0]
        raw = _vec3(size_mm, default)
        return [_clamp(v, 0.2, 200.0, default[i]) for i, v in enumerate(raw)]

    def spawn_object(self, *, shape="box", object_id=None, position_mm=None,
                     size_mm=None, yaw_deg=0.0):
        shape = self._shape(shape)
        if not self._free_slots[shape]:
            raise LabError(f"no free {shape} slots")
        object_id = self._object_id(object_id, shape)
        slot = self._free_slots[shape].popleft()
        pos_default = [40.0, 0.0, 5.0]
        if shape == "wall":
            pos_default = [40.0, 0.0, 7.5]
        elif shape == "food":
            pos_default = [20.0, 0.0, 1.5]
        pos = [_clamp(v, -1000.0, 1000.0, pos_default[i])
               for i, v in enumerate(_vec3(position_mm, pos_default))]
        size = self._sanitize_size(shape, size_mm)
        obj = LabObject(
            object_id=object_id,
            shape=shape,
            slot=slot,
            position_mm=pos,
            size_mm=size,
            yaw_deg=_clamp(yaw_deg, -36000.0, 36000.0, 0.0) % 360.0,
        )
        self.objects[object_id] = obj
        self._bump_revision(obj, structural=True)
        self._sync_object(obj)
        return obj.state()

    def move_object(self, object_id, *, position_mm=None, yaw_deg=None):
        obj = self._require_object(object_id)
        if position_mm is not None:
            raw = _vec3(position_mm, obj.position_mm)
            obj.position_mm = [_clamp(v, -1000.0, 1000.0, obj.position_mm[i])
                               for i, v in enumerate(raw)]
        if yaw_deg is not None:
            obj.yaw_deg = _clamp(yaw_deg, -36000.0, 36000.0, obj.yaw_deg) % 360.0
        self._bump_revision(obj)
        self._sync_object(obj)
        return obj.state()

    def resize_object(self, object_id, *, size_mm):
        obj = self._require_object(object_id)
        obj.size_mm = self._sanitize_size(obj.shape, size_mm)
        self._bump_revision(obj, structural=True)
        self._sync_object(obj)
        return obj.state()

    def remove_object(self, object_id):
        obj = self._require_object(object_id)
        self.approaches.pop(obj.object_id, None)
        self._deactivate_slot(obj.slot)
        del self.objects[obj.object_id]
        self._free_slots[obj.shape].append(obj.slot)
        self._bump_revision(structural=True)
        return obj.state()

    def reset(self):
        self._clear_applied_forces()
        for obj in list(self.objects.values()):
            self._deactivate_slot(obj.slot)
        self.objects.clear()
        self.approaches.clear()
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
        self.events.clear()
        self._bump_revision(structural=True)

    def _require_object(self, object_id):
        object_id = str(object_id or "")
        try:
            return self.objects[object_id]
        except KeyError as exc:
            raise LabError(f"unknown object: {object_id}") from exc

    # ------------------------------------------------------------------
    # Motion / stimuli
    # ------------------------------------------------------------------
    def start_approach(self, object_id, *, fly_position_mm, end_distance_mm=8.0,
                       speed_mm_s=80.0):
        obj = self._require_object(object_id)
        target = _vec3(fly_position_mm, [0.0, 0.0, 0.0])
        motion = ApproachMotion(
            object_id=obj.object_id,
            target_xy_mm=(target[0], target[1]),
            end_distance_mm=_clamp(end_distance_mm, 0.5, 500.0, 8.0),
            speed_mm_s=_clamp(speed_mm_s, 0.1, 2000.0, 80.0),
        )
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
        if strength <= 0.0:
            self.stop_wind()
        return self._wind_state()

    def stop_wind(self):
        self.wind.update(strength=0.0, continuous=False, remaining_s=0.0)

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
        self.events.append({
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
            self.events.append({
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
        return dict(self.temperature)

    def apply_command(self, command, *, fly_position_mm=(0.0, 0.0, 0.0)):
        """Apply one parsed LabCommand on the simulation-owner thread."""
        op = command.op
        a = command.args
        if op in ("spawn_object", "spawn_box", "spawn_sphere", "spawn_wall"):
            shape = a.get("shape", "box")
            if op.startswith("spawn_") and op != "spawn_object":
                shape = op.removeprefix("spawn_")
            return self.spawn_object(
                shape=shape, object_id=a.get("id"),
                position_mm=a.get("position_mm"), size_mm=a.get("size_mm"),
                yaw_deg=a.get("yaw_deg", 0.0))
        if op in ("spawn_food", "spawn_food_marker"):
            return self.spawn_object(
                shape="food", object_id=a.get("id"), position_mm=a.get("position_mm"),
                size_mm=a.get("size_mm", 3.0), yaw_deg=a.get("yaw_deg", 0.0))
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
        self._advance_approaches(dt)
        if self._bound:
            self._apply_forces()
        self._advance_timers(dt)

    def _advance_approaches(self, dt):
        finished = []
        for object_id, motion in list(self.approaches.items()):
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
            if distance - step <= motion.end_distance_mm + 1e-6:
                finished.append(object_id)
        for object_id in finished:
            motion = self.approaches.pop(object_id, None)
            if motion is not None:
                self.events.append({
                    "event": "approach_complete",
                    "classification": PHYSICAL,
                    "id": object_id,
                })

    def _advance_timers(self, dt):
        if self.wind["strength"] > 0.0 and not self.wind["continuous"]:
            self.wind["remaining_s"] = max(0.0, self.wind["remaining_s"] - dt)
            if self.wind["remaining_s"] <= 0.0:
                self.stop_wind()
                self.events.append({"event": "wind_complete", "classification": PHYSICAL})
        if self.touch is not None:
            self.touch["remaining_s"] = max(0.0, self.touch["remaining_s"] - dt)
            if self.touch["remaining_s"] <= 0.0:
                target = self.touch["target"]
                self.touch = None
                self.events.append({
                    "event": "touch_complete", "classification": PHYSICAL, "target": target})
        if self.flash["remaining_s"] > 0.0:
            self.flash["remaining_s"] = max(0.0, self.flash["remaining_s"] - dt)
            if self.flash["remaining_s"] <= 0.0:
                eye = self.flash["eye"]
                intensity = self.flash["intensity"]
                self.flash.update(intensity=0.0, remaining_s=0.0)
                if intensity > 0.0:
                    self.events.append({
                        "event": "flash_complete", "classification": SENSORY_MODEL, "eye": eye})

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
            mag = mass * WIND_ACCEL_MAX_MM_S2 * self.wind["strength"]
            forces[bid] = [math.cos(angle) * mag, math.sin(angle) * mag, 0.0]

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
                if obj.shape in ("box", "wall"):
                    size = [float(v) * 2.0 for v in self.model.geom_size[gid][:3]]
                else:
                    diameter = float(self.model.geom_size[gid][0]) * 2.0
                    size = [diameter, diameter, diameter]
                quat = [quat_wxyz[1], quat_wxyz[2], quat_wxyz[3], quat_wxyz[0]]
            else:
                pos = [float(v) for v in obj.position_mm]
                half_yaw = math.radians(obj.yaw_deg) * 0.5
                quat = [0.0, 0.0, math.sin(half_yaw), math.cos(half_yaw)]
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
        for obj in self.objects.values():
            ids = self._slot_ids.get(obj.slot)
            if ids is not None and int(ids[1]) == geom_id:
                return {"target_id": obj.object_id, "target_kind": "lab_object"}
        return None

    def state(self):
        return {
            "physical_backend": bool(self._bound),
            "world_revision": int(self.revision),
            "objects": [self.objects[k].state() for k in sorted(self.objects)],
            "player": self.player.render_pose(),
            "slot_capacity": {shape: int(count) for shape, count in self.slot_counts.items()},
            "slot_free": {shape: len(slots) for shape, slots in self._free_slots.items()},
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
        half_yaw = math.radians(obj.yaw_deg) * 0.5
        quat = [math.cos(half_yaw), 0.0, 0.0, math.sin(half_yaw)]
        if mocap_id >= 0:
            self.data.mocap_pos[mocap_id] = obj.position_mm
            self.data.mocap_quat[mocap_id] = quat
        else:
            self.model.body_pos[bid] = obj.position_mm
            self.model.body_quat[bid] = quat
        if obj.shape in ("box", "wall"):
            self.model.geom_size[gid] = [max(0.1, v * 0.5) for v in obj.size_mm]
        else:
            radius = max(0.1, obj.size_mm[0] * 0.5)
            self.model.geom_size[gid] = [radius, 0.0, 0.0]
        self.model.geom_rgba[gid] = DEFAULT_COLORS[obj.shape]
        if obj.shape == "food":
            self.model.geom_contype[gid] = 0
            self.model.geom_conaffinity[gid] = 0
        else:
            self.model.geom_contype[gid] = 1
            self.model.geom_conaffinity[gid] = 1

    def _deactivate_slot(self, slot):
        if not self._bound:
            return
        bid, gid, mocap_id = self._slot_ids[slot]
        if mocap_id >= 0:
            self.data.mocap_pos[mocap_id] = FAR_POS
        else:
            self.model.body_pos[bid] = FAR_POS
        self.model.geom_rgba[gid, 3] = 0.0
        self.model.geom_contype[gid] = 0
        self.model.geom_conaffinity[gid] = 0
