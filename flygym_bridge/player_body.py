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
# V5.5 movement is simulation-time-owned. A full-scale move axis produces this
# bounded planar speed regardless of render/input packet frequency.
PLAYER_MOVE_SPEED_MM_S = 30.0
PLAYER_MAX_PITCH_DEG = 85.0


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
        self.input_move_axes = [0.0, 0.0]
        self.input_held_actions = []
        self.look_yaw_rad = 0.0
        self.look_pitch_rad = 0.0
        self._look_dirty = False
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
            self.clear_input_state(reset_look=False)
        self._sync()
        return changed, self.render_pose()

    def clear_input_state(self, *, reset_look=False):
        self.input_move_axes = [0.0, 0.0]
        self.input_held_actions = []
        self._look_dirty = False
        if reset_look:
            self.look_yaw_rad = 0.0
            self.look_pitch_rad = 0.0

    def set_input_state(self, *, move_axes, look_delta, held_actions):
        """Accept one already-validated V5.5 input state on the owner thread.

        move_axes is [forward, right]. look_delta is radians and is
        discrete: duplicate packet IDs must be filtered by Bridge before this
        method is called, otherwise yaw/pitch would be applied twice.
        """
        if not self.active:
            raise RuntimeError("participant is not active")
        if not isinstance(move_axes, (list, tuple)) or len(move_axes) != 2:
            raise ValueError("move_axes must have length 2")
        forward = max(-1.0, min(1.0, float(move_axes[0])))
        right = max(-1.0, min(1.0, float(move_axes[1])))
        mag = math.hypot(forward, right)
        if mag > 1.0:
            forward /= mag
            right /= mag
        self.input_move_axes = [forward, right]
        self.input_held_actions = [str(v) for v in held_actions]

        yaw_delta = float(look_delta[0])
        pitch_delta = float(look_delta[1])
        if abs(yaw_delta) > 0.0 or abs(pitch_delta) > 0.0:
            self.look_yaw_rad = (self.look_yaw_rad + yaw_delta + math.pi) % (2.0 * math.pi) - math.pi
            max_pitch = math.radians(PLAYER_MAX_PITCH_DEG)
            self.look_pitch_rad = max(-max_pitch, min(max_pitch, self.look_pitch_rad + pitch_delta))
            self.orientation_quat_xyzw = self._look_quaternion()
            self._look_dirty = True
        return self.input_state()

    def _look_quaternion(self):
        """Return yaw(Z) * pitch(Y), XYZW, with zero roll."""
        hy = self.look_yaw_rad * 0.5
        hp = self.look_pitch_rad * 0.5
        sy, cy = math.sin(hy), math.cos(hy)
        sp, cp = math.sin(hp), math.cos(hp)
        return [-sy * sp, cy * sp, sy * cp, cy * cp]

    def input_motion_pose(self, sim_dt):
        """Plan one simulation-time movement update without render-FPS coupling."""
        if not self.active:
            return None
        try:
            dt = float(sim_dt)
        except (TypeError, ValueError, OverflowError):
            return None
        if not math.isfinite(dt) or dt <= 0.0:
            return None
        forward, right = self.input_move_axes
        moving = abs(forward) > 1e-12 or abs(right) > 1e-12
        if not moving and not self._look_dirty:
            return None
        if self._bound:
            # qpos is the authoritative free-joint owner state. _sync() writes it
            # immediately on activation/pose changes, whereas xpos is derived and
            # remains stale until mj_forward/mj_step. Reading xpos here can turn a
            # same-boundary activate+input from spawn X=24 mm into X=0.6 mm.
            base = [float(v) for v in self.data.qpos[self.qpos_adr:self.qpos_adr + 3]]
        else:
            base = list(self.position_mm)
        if moving:
            yaw = self.look_yaw_rad
            fx, fy = math.cos(yaw), math.sin(yaw)
            # World +Y is left, so local +right points toward -Y at yaw=0.
            rx, ry = math.sin(yaw), -math.cos(yaw)
            distance = PLAYER_MOVE_SPEED_MM_S * dt
            base[0] += (forward * fx + right * rx) * distance
            base[1] += (forward * fy + right * ry) * distance
        return {
            "position_mm": base,
            "orientation_quat_xyzw": list(self.orientation_quat_xyzw),
        }

    def mark_input_pose_applied(self):
        self._look_dirty = False

    def input_state(self):
        return {
            "move_axes": list(self.input_move_axes),
            "look_yaw_rad": self.look_yaw_rad,
            "look_pitch_rad": self.look_pitch_rad,
            "held_actions": list(self.input_held_actions),
            "move_speed_mm_s": PLAYER_MOVE_SPEED_MM_S,
        }

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
        self.clear_input_state(reset_look=True)
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
