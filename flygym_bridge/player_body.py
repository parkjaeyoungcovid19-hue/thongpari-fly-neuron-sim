"""Backend-owned V5 participant probe living in the same MuJoCo world as the fly.

V5.4 intentionally stops before game input. This actor is a small collidable
free-joint sphere whose pose is owned by the simulation process. V5.5 can later
move the exact same body from tick-scheduled PlayerInput without changing the
render/collision contract established here.
"""
from __future__ import annotations

import math


PLAYER_ACTOR_ID = "player"
PLAYER_BODY_NAME = "v5_player_body"
PLAYER_GEOM_NAME = "v5_player_geom"
PLAYER_JOINT_NAME = "v5_player_freejoint"
PLAYER_RADIUS_MM = 2.5
# Keep the participant in the same inertial scale as the physical fly. FlyGym's
# shipped thorax body uses 0.00034 mass units; leaving this sphere unspecified
# makes MuJoCo apply its default density and yields a ~65,000-unit body.
PLAYER_MASS = 0.00034
PLAYER_SPAWN_MM = (24.0, 0.0, 2.5)
PLAYER_FAR_POS = (0.0, 0.0, -500.0)
PLAYER_RGBA = (0.58, 0.22, 0.86, 1.0)


def _finite_vec3(value, fallback):
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        value = fallback
    out = []
    for i, item in enumerate(value):
        try:
            v = float(item)
        except (TypeError, ValueError, OverflowError):
            v = float(fallback[i])
        out.append(v if math.isfinite(v) else float(fallback[i]))
    return out


def _unit_quat_xyzw(value):
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        return [0.0, 0.0, 0.0, 1.0]
    try:
        q = [float(v) for v in value]
    except (TypeError, ValueError, OverflowError):
        return [0.0, 0.0, 0.0, 1.0]
    if not all(math.isfinite(v) for v in q):
        return [0.0, 0.0, 0.0, 1.0]
    mag = math.sqrt(sum(v * v for v in q))
    if mag < 1e-12:
        return [0.0, 0.0, 0.0, 1.0]
    return [v / mag for v in q]


class PlayerBody:
    """One bounded participant actor with a single visual/collision pose source."""

    def __init__(self, world=None, *, actor_id=PLAYER_ACTOR_ID,
                 radius_mm=PLAYER_RADIUS_MM, spawn_position_mm=PLAYER_SPAWN_MM):
        actor_id = str(actor_id or PLAYER_ACTOR_ID).strip()
        if not actor_id or len(actor_id) > 64:
            raise ValueError("invalid player actor id")
        self.actor_id = actor_id
        self.radius_mm = max(0.2, min(20.0, float(radius_mm)))
        self.spawn_position_mm = _finite_vec3(spawn_position_mm, PLAYER_SPAWN_MM)
        self.position_mm = list(self.spawn_position_mm)
        self.orientation_quat_xyzw = [0.0, 0.0, 0.0, 1.0]
        self.active = False
        self.mode = "inactive"
        self._bound = False
        self.model = None
        self.data = None
        self.body_id = -1
        self.geom_id = -1
        self.joint_id = -1
        self.qpos_adr = -1
        self.dof_adr = -1
        self._mjcf_geom = None
        if world is not None:
            self.install(world)

    def install(self, world):
        """Precompile the participant body before FlyGym Simulation creation."""
        import mujoco

        body = world.mjcf_root.worldbody.add_body(
            name=PLAYER_BODY_NAME, pos=PLAYER_FAR_POS)
        # A real free-joint body participates in MuJoCo's contact solver. The
        # earlier world-welded prototype could render but could not exchange a
        # physical contact impulse with the fly.
        body.gravcomp = 1.0
        body.add_freejoint(name=PLAYER_JOINT_NAME)
        self._mjcf_geom = body.add_geom(
            name=PLAYER_GEOM_NAME,
            type=mujoco.mjtGeom.mjGEOM_SPHERE,
            size=[self.radius_mm],
            mass=PLAYER_MASS,
            rgba=[PLAYER_RGBA[0], PLAYER_RGBA[1], PLAYER_RGBA[2], 0.0],
            # Compile ordinary collision eligibility now; inactive state masks
            # this geom back to 0/0 in `_sync`. Runtime 0/0 -> 1/1 alone is not
            # sufficient to add a geom to MuJoCo's generic collision candidates.
            contype=1,
            conaffinity=1,
        )

    def install_fly_contact_pairs(self, world, fly):
        """Add explicit player<->thorax contact before Simulation compilation.

        FlyGym's fly visual/collision meshes use contype=conaffinity=0 and rely on
        explicit contact pairs (including ground). Reuse that model contract for
        the participant rather than globally changing the fly's collision masks.
        """
        if self._mjcf_geom is None:
            raise RuntimeError("player MJCF geom is not installed")
        root_geoms = list(fly.bodyseg_to_mjcfgeom.get(fly.root_segment, []))
        if not root_geoms:
            raise RuntimeError("fly thorax contact geom unavailable")
        for index, fly_geom in enumerate(root_geoms):
            world.mjcf_root.add_pair(
                geomname1=self._mjcf_geom.name,
                geomname2=fly_geom.name,
                name=f"v5-player-thorax-{index}",
            )

    def bind(self, sim):
        import mujoco

        self.model = sim.mj_model
        self.data = sim.mj_data
        self.body_id = int(mujoco.mj_name2id(
            self.model, mujoco.mjtObj.mjOBJ_BODY, PLAYER_BODY_NAME))
        self.geom_id = int(mujoco.mj_name2id(
            self.model, mujoco.mjtObj.mjOBJ_GEOM, PLAYER_GEOM_NAME))
        self.joint_id = int(mujoco.mj_name2id(
            self.model, mujoco.mjtObj.mjOBJ_JOINT, PLAYER_JOINT_NAME))
        if self.body_id < 0 or self.geom_id < 0 or self.joint_id < 0:
            raise RuntimeError("compiled V5 player body missing")
        self.qpos_adr = int(self.model.jnt_qposadr[self.joint_id])
        self.dof_adr = int(self.model.jnt_dofadr[self.joint_id])
        self._bound = True
        self._sync()

    def _sync(self):
        if not self._bound:
            return
        qpos = self.data.qpos
        qvel = self.data.qvel
        start = self.qpos_adr
        dstart = self.dof_adr
        if self.active:
            q = self.orientation_quat_xyzw
            qpos[start:start + 3] = self.position_mm
            qpos[start + 3:start + 7] = [q[3], q[0], q[1], q[2]]
            qvel[dstart:dstart + 6] = 0.0
            self.model.geom_size[self.geom_id] = [self.radius_mm, 0.0, 0.0]
            self.model.geom_rgba[self.geom_id] = PLAYER_RGBA
            # Generic LabObjects use mask 1/1, so the participant collides with
            # the physical lab world. Fly contact is handled by the explicit pair
            # installed above because FlyGym's fly geoms use mask 0/0.
            self.model.geom_contype[self.geom_id] = 1
            self.model.geom_conaffinity[self.geom_id] = 1
        else:
            qpos[start:start + 3] = PLAYER_FAR_POS
            qpos[start + 3:start + 7] = [1.0, 0.0, 0.0, 0.0]
            qvel[dstart:dstart + 6] = 0.0
            self.model.geom_rgba[self.geom_id, 3] = 0.0
            self.model.geom_contype[self.geom_id] = 0
            self.model.geom_conaffinity[self.geom_id] = 0

    def set_active(self, active, *, mode=None):
        active = bool(active)
        changed = active != self.active
        self.active = active
        if active:
            self.mode = str(mode or "participate")[:32]
        else:
            self.mode = "inactive"
        self._sync()
        return changed, self.render_pose()

    def set_pose(self, *, position_mm=None, orientation_quat_xyzw=None, mode=None):
        """Owner-thread pose setter reserved for V5.5 tick-scheduled input."""
        if position_mm is not None:
            raw = _finite_vec3(position_mm, self.position_mm)
            self.position_mm = [max(-1000.0, min(1000.0, v)) for v in raw]
        if orientation_quat_xyzw is not None:
            self.orientation_quat_xyzw = _unit_quat_xyzw(orientation_quat_xyzw)
        if mode is not None and self.active:
            self.mode = str(mode)[:32]
        self._sync()

    def reset_pose(self, *, preserve_active=True):
        was_active = self.active if preserve_active else False
        self.position_mm = list(self.spawn_position_mm)
        self.orientation_quat_xyzw = [0.0, 0.0, 0.0, 1.0]
        self.active = bool(was_active)
        self.mode = "participate" if self.active else "inactive"
        self._sync()

    def resync_after_sim_reset(self):
        self._sync()

    def render_pose(self):
        if not self.active:
            return None
        if self._bound:
            # body xpos/xquat is the collision pose after mj_forward/step and is
            # therefore the exact same source the renderer and contact solver use.
            pos = [float(v) for v in self.data.xpos[self.body_id]]
            wxyz = [float(v) for v in self.data.xquat[self.body_id]]
            quat = [wxyz[1], wxyz[2], wxyz[3], wxyz[0]]
            radius = float(self.model.geom_size[self.geom_id][0])
        else:
            pos = [float(v) for v in self.position_mm]
            quat = [float(v) for v in self.orientation_quat_xyzw]
            radius = float(self.radius_mm)
        return {
            "actor_id": self.actor_id,
            "position_mm": pos,
            "orientation_quat_xyzw": quat,
            "collision_radius_mm": radius,
            "mode": self.mode,
        }

    def semantic_target_for_geom(self, geom_id):
        if not self.active or not self._bound:
            return None
        try:
            matches = int(geom_id) == self.geom_id
        except (TypeError, ValueError, OverflowError):
            matches = False
        if not matches:
            return None
        return {"target_id": self.actor_id, "target_kind": "player"}
