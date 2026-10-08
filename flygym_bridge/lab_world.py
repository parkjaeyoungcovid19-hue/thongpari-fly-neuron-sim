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
import copy
from collections import deque
from dataclasses import dataclass, field
import sandbox_models as sm
from player_body import PlayerBody
from player_body import PLAYER_WORKSPACE_LIMIT_MM
import scene_store as scenes
from environment_properties import EDIT_DESCRIPTORS, MAX_REVISION, EditError, environment_capabilities, validate_edit
from interaction import (InteractionState, InteractionError, parse_interaction_args,
                         participant_center,
                         INTERACTION_REACH_MM, INTERACTION_RAY_ORIGIN_TOL_FACTOR,
                         CARRY_SPEED_MM_S, CARRY_PENETRATION_TOL_MM, CARRY_GAP_MM,
                         CARRY_CONTACT_SKIN_MM)


from lab_types import *
from lab_tools import LabTools
from interaction import WorldInteraction

class LabWorld(LabTools, WorldInteraction):
    """Bounded dynamic lab state; optionally backed by a compiled MuJoCo model."""

    def __init__(self, world=None, slot_counts=None):
        self.fly_position_mm = None
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
            "neural_target": None,
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
        previous = self._edit_value(d, obj if pid.startswith("object.") else None)
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
                "actual_value": actual, "previous_value": previous, "revision": int(revision)}

    def _edit_value(self, d, obj):
        """Owner value of an editable property, in its edit wire form. The V6.6
        undo inverse is built from this, never from a client-side guess."""
        pid, field = d["property_id"], d["legacy_field"]
        if obj is not None:
            value = getattr(obj, field)
            if field in ("position_mm", "size_mm"):
                value = [float(v) for v in value]
                return value if d["value_type"] == "vector" else value[0]
            return float(value)
        if pid.startswith("temperature."):
            return self.temperature[field]
        if pid in WIND_EDIT_FIELDS:
            return self.wind[WIND_EDIT_FIELDS[pid]]
        return self.eyes[field]

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

    def export_scene(self):
        # Only persistent settings: a timed puff cannot become continuous wind.
        objects = []
        for key in sorted(self.objects):
            obj = self.objects[key]
            item = dict(id=key, shape=obj.shape, position_mm=list(obj.position_mm),
                        size_mm=scenes.object_size_value(obj), yaw_deg=obj.yaw_deg)
            if obj.shape == "ramp": item["pitch_deg"] = obj.pitch_deg
            if obj.shape == "food": item["variant"] = obj.variant
            objects.append(item)
        scene = dict(objects=objects, environment=dict(
            temperature=dict(celsius=float(self.temperature["celsius"]), mode=self.temperature["mode"]),
            wind=dict(strength=float(self.wind["strength"]) if self.wind["continuous"] else 0.0,
                      direction_deg=float(self.wind["direction_deg"]),
                      physical=self.wind["physical_enabled"], sensory=self.wind["sensory_enabled"]),
            eyes=dict(self.eyes)), player_spawn=dict(position_mm=list(self.player.spawn_position_mm)))
        return scenes.build_document(scene)

    def load_scene(self, text, *, fly_position_mm):
        document = scenes.parse_document(text)
        staged, mismatches = scenes.validate_document(document, slot_counts=self.slot_counts,
            max_object_id_len=MAX_OBJECT_ID_LEN, player_limit_mm=PLAYER_WORKSPACE_LIMIT_MM)
        if mismatches:
            raise scenes.SceneError("document.assets", "asset hashes differ: " + ", ".join(mismatches),
                                    status="rejected_assets")
        overlap = scenes.first_overlap(staged, fly_point_mm=fly_position_mm,
            player_spawn_mm=staged["player_spawn"], player_radius_mm=self.player.radius_mm,
            toy_size=self._sanitize_size)
        if overlap: raise scenes.SceneError(*overlap, status="rejected_overlap")
        # Build every authored object in an unbound world before touching the owner.
        candidate = LabWorld(slot_counts=self.slot_counts)
        for item in staged["objects"]:
            candidate.spawn_object(shape=item["shape"], object_id=item["id"],
                position_mm=item["position_mm"], size_mm=item["size_mm"], yaw_deg=item["yaw_deg"],
                variant=item.get("variant"), pitch_deg=item.get("pitch_deg"))
        # Retain both owner state and compiled arrays until the swap completes.
        fields = ("objects", "_free_slots", "_counter", "_food_spawn_count", "interaction", "events",
                  "drives", "_trap_blocked", "projectiles", "_last_bb_fire_s", "_sim_time_s",
                  "_previous_forces", "approaches", "feeding", "_eating_id", "touch", "flash",
                  "temperature", "eyes", "wind", "revision", "structure_revision", "environment_revision",
                  "_solid_by_slot")
        backup = {key: copy.deepcopy(getattr(self, key)) for key in fields}
        spawn_before = list(self.player.spawn_position_mm)
        arrays = []
        if self._bound:
            for owner, names in ((self.model, ("body_pos", "body_quat", "body_gravcomp", "body_contype", "body_conaffinity", "geom_size",
                   "geom_pos", "geom_quat", "geom_type", "geom_rgba", "geom_contype", "geom_conaffinity",
                   "geom_aabb", "geom_rbound")),
                   (self.data, ("mocap_pos", "mocap_quat", "qpos", "qvel", "xfrc_applied"))):
                arrays.extend((getattr(owner, name), getattr(owner, name).copy()) for name in names)
        try:
            # Single owner boundary. Preserve body/neural tick and live participant pose.
            self.release_interaction("scene_load")
            owner_time = self._sim_time_s
            self.reset_runtime_tools()
            self._sim_time_s = owner_time
            self._clear_applied_forces()
            self.approaches.clear()
            self.feeding.clear()
            self._eating_id = None
            self.touch = None
            self.flash.update(intensity=0.0, remaining_s=0.0)
            for obj in self.objects.values(): self._deactivate_slot(obj.slot)
            self.objects, self._free_slots = candidate.objects, candidate._free_slots
            self._counter, self._food_spawn_count = candidate._counter, candidate._food_spawn_count
            for obj in self.objects.values():
                self._bump_revision(obj, structural=True)
                self._sync_object(obj)
            env = staged["environment"]
            self.temperature.update(env["temperature"])
            self.eyes.update(env["eyes"])
            wind = env["wind"]
            self.wind.update(strength=wind["strength"], direction_deg=wind["direction_deg"],
                physical_enabled=wind["physical"], sensory_enabled=wind["sensory"],
                continuous=wind["strength"] > 0, remaining_s=0.0)
            self.player.spawn_position_mm = staged["player_spawn"]
            self.environment_revision += 1
            self._bump_revision(structural=True)
            self.refresh_poses()
            self._append_event(dict(event="scene_loaded", classification=PHYSICAL,
                                    content_sha256=document["content_sha256"]))
        except Exception:
            for key, value in backup.items(): setattr(self, key, value)
            self.player.spawn_position_mm = spawn_before
            for live, saved in arrays: live[:] = saved
            self.refresh_poses()
            raise
        return dict(kind=scenes.SCENE_KIND, content_sha256=document["content_sha256"],
                    world_revision=self.revision, environment_revision=self.environment_revision)

    _command_handlers = {'export_scene': '_command_export_scene', 'load_scene': '_command_load_scene', 'edit_object': '_command_edit_object', 'drive_object': '_command_drive_object', 'arm_trap': '_command_arm_trap', 'equip_gun': '_command_equip_gun', 'fire_bb': '_command_fire_bb', 'interaction': '_command_interaction', 'edit_property': '_command_edit_property', 'spawn_object': '_command_spawn_object', 'spawn_box': '_command_spawn_object', 'spawn_sphere': '_command_spawn_object', 'spawn_wall': '_command_spawn_object', 'spawn_ramp': '_command_spawn_object', 'spawn_food': '_command_spawn_food', 'spawn_food_marker': '_command_spawn_food', 'move_object': '_command_move_object', 'resize_object': '_command_resize_object', 'delete_object': '_command_delete_object', 'remove_object': '_command_delete_object', 'reset_world': '_command_reset_world', 'approach_object': '_command_approach_object', 'approach': '_command_approach_object', 'wind': '_command_wind', 'wind_puff': '_command_wind', 'stop_wind': '_command_stop_wind', 'touch': '_command_touch', 'set_eye_state': '_command_set_eye_state', 'eye_state': '_command_set_eye_state', 'restore_eyes': '_command_restore_eyes', 'flash_eye': '_command_flash_eye', 'temperature': '_command_temperature', 'set_temperature': '_command_temperature'}
    def apply_command(self, command, *, fly_position_mm=(0.0, 0.0, 0.0)):
        handler = self._command_handlers.get(command.op)
        if handler is None:
            raise LabError(f"unknown lab op: {command.op}")
        return getattr(self, handler)(command, fly_position_mm)

    def _command_export_scene(self, command, fly_position_mm):
        op, a = command.op, command.args
        document = self.export_scene()
        return {"document_text": scenes.document_text(document), "kind": scenes.SCENE_KIND,
                "canonical_scene": scenes.canonical_bytes(document["scene"]).decode("utf-8")}

    def _command_load_scene(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.load_scene(a.get("scene_document"), fly_position_mm=fly_position_mm)

    def _command_edit_object(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.edit_object(a.get("object_edit"))

    def _command_drive_object(self, command, fly_position_mm):
        op, a = command.op, command.args
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

    def _command_arm_trap(self, command, fly_position_mm):
        op, a = command.op, command.args
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

    def _command_equip_gun(self, command, fly_position_mm):
        op, a = command.op, command.args
        actor = _tool_actor(a)
        equipped = a.get("equipped")
        if not isinstance(equipped, bool):
            raise LabError("equipped must be boolean")
        if actor != self.player.actor_id or not self.player.active:
            raise LabError("active participant required")
        self.player.set_gun_visible(equipped)
        self._bump_revision(structural=True)
        return {"actor_id": actor, "equipped": equipped}

    def _command_fire_bb(self, command, fly_position_mm):
        op, a = command.op, command.args
        actor = _tool_actor(a)
        direction = _tool_direction(a.get("direction"))
        return self._fire_bb(actor, direction)

    def _command_interaction(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.apply_interaction(command)

    def _command_edit_property(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.apply_edit(a.get("edit"))

    def _command_spawn_object(self, command, fly_position_mm):
        op, a = command.op, command.args
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

    def _command_spawn_food(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.spawn_object(
            shape="food", object_id=a.get("id"), position_mm=a.get("position_mm"),
            size_mm=a.get("size_mm", 3.0), yaw_deg=a.get("yaw_deg", 0.0),
            variant=a.get("variant"))

    def _command_move_object(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.move_object(a.get("id"), position_mm=a.get("position_mm"),
                                yaw_deg=a.get("yaw_deg"))

    def _command_resize_object(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.resize_object(a.get("id"), size_mm=a.get("size_mm"))

    def _command_delete_object(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.remove_object(a.get("id"))

    def _command_reset_world(self, command, fly_position_mm):
        op, a = command.op, command.args
        self.reset()
        return {"reset": True}

    def _command_approach_object(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.start_approach(
            a.get("id"), fly_position_mm=fly_position_mm,
            end_distance_mm=a.get("end_distance_mm", 8.0),
            speed_mm_s=a.get("speed_mm_s", 80.0))

    def _command_wind(self, command, fly_position_mm):
        op, a = command.op, command.args
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

    def _command_stop_wind(self, command, fly_position_mm):
        op, a = command.op, command.args
        self.stop_wind()
        return self._wind_state()

    def _command_touch(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.apply_touch(
            target=a.get("target", "thorax"), strength=a.get("strength", 0.5),
            duration_ms=a.get("duration_ms", 20.0),
            direction_world=a.get("direction_world"), sensory=a.get("sensory", True))

    def _command_set_eye_state(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.set_eye_state(
            left_enabled=a.get("left_enabled"), right_enabled=a.get("right_enabled"),
            left_mask=a.get("left_mask"), right_mask=a.get("right_mask"))

    def _command_restore_eyes(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.set_eye_state(left_enabled=True, right_enabled=True,
                                  left_mask=0.0, right_mask=0.0)

    def _command_flash_eye(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.flash_eye(
            eye=a.get("eye", a.get("target", "both")),
            intensity=a.get("intensity", a.get("strength", a.get("value", 1.0))),
            duration_ms=a.get("duration_ms", 100.0))

    def _command_temperature(self, command, fly_position_mm):
        op, a = command.op, command.args
        return self.set_temperature(celsius=a.get("celsius", 25.0),
                                    mode=a.get("mode", "environment_only"))


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
            "scene_capabilities": {"schema_version": 1, "kind": scenes.SCENE_KIND, "max_document_bytes": scenes.MAX_DOCUMENT_BYTES, "load_requires_pause": True},
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

    def refresh_poses(self):
        """Recompute world poses after an edit applied while paused (V6.6), so
        the view stream and ray picks see it. Kinematics only: no time step,
        no contact or force computation."""
        if self._bound:
            self._mujoco.mj_kinematics(self.model, self.data)

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
