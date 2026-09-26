"""fly_body.py - mock body (no MuJoCo) + real FlyGym 2.x body behind one interface."""
from __future__ import annotations
import math
from protocol import BodyPacket
from lab_world import LabWorld
from vision_decoder import VisionLoomDetector

try:
    from neural_decoder import LocomotorCommand
except Exception:
    LocomotorCommand = None


def _set_player_input_state(lab_world, player_input):
    player = lab_world.player
    if player_input.actor_id != player.actor_id:
        raise ValueError("wrong player actor")
    if not player.active:
        raise RuntimeError("participant is not active")
    return player.set_input_state(
        move_axes=player_input.move_axes,
        look_delta=player_input.look_delta,
        held_actions=player_input.held_actions,
    )


def _advance_player_input_motion(lab_world, sim_dt):
    player = lab_world.player
    pose = player.input_motion_pose(sim_dt)
    if pose is None:
        return False
    lab_world.set_player_pose(
        position_mm=pose["position_mm"],
        orientation_quat_xyzw=pose["orientation_quat_xyzw"],
    )
    player.mark_input_pose_applied()
    return True


def _clear_player_input_state(lab_world):
    lab_world.player.clear_input_state(reset_look=False)


class MockBody:
    """Kinematic mock: no physics, deterministic-ish, bounded state."""
    def __init__(self):
        self.physics_timestep_s = 0.001
        self.x = 0.0
        self.y = 0.0
        self.heading = 0.0
        self.vx = 0.0
        self.yaw_rate = 0.0
        self.phase = 0.0
        self.t = 0.0
        self.wall_elapsed_s = 0.0
        self.last_step_sim_dt = 0.0
        self.last_step_wall_dt = 0.0
        self.last_tempo = 1.0
        self.controller_left = 0.0
        self.controller_right = 0.0
        self.lab_world = LabWorld()

    def _step_duration(self, cmd, sim_dt, wall_dt, tempo=1.0):
        sim_dt = max(self.physics_timestep_s, min(0.1, float(sim_dt)))
        wall_dt = max(0.0, float(wall_dt))
        try:
            tempo = float(tempo)
        except (TypeError, ValueError):
            tempo = 1.0
        self.last_tempo = max(0.2, min(2.0, tempo if math.isfinite(tempo) else 1.0))
        self.controller_left, self.controller_right = brain_to_descending(cmd)
        self.advance_player_input(sim_dt)
        self.lab_world.pre_step(sim_dt)
        target_v = 0.03 * cmd.forward  # 0.03 m/s ~= brisk FlyGym walk
        if cmd.reverse:
            target_v = -0.5 * target_v
        if not cmd.moving:
            target_v = 0.0
        if cmd.urgent:
            target_v *= 1.5
        self.vx += (target_v - self.vx) * min(1.0, sim_dt * 6.0)
        yaw_target = 2.5 * cmd.steering * (0.4 + 0.6 * min(1.0, abs(self.vx) / 0.02 + 0.2))
        if not cmd.moving:
            yaw_target = 0.0
        self.yaw_rate += (yaw_target - self.yaw_rate) * min(1.0, sim_dt * 5.0)
        self.heading += self.yaw_rate * sim_dt
        self.x += math.cos(self.heading) * self.vx * sim_dt
        self.y += math.sin(self.heading) * self.vx * sim_dt
        stride = 8.0  # Hz tripod-ish alternation
        self.phase = (self.phase + sim_dt * stride) % 2.0
        self.t += sim_dt
        self.wall_elapsed_s += wall_dt
        self.last_step_sim_dt = sim_dt
        self.last_step_wall_dt = wall_dt
        return self.observe()

    def step(self, cmd, dt, tempo=1.0):
        dt = max(1e-4, min(0.1, dt))
        return self._step_duration(cmd, dt, dt, tempo=tempo)

    def step_exact(self, cmd, substeps, tempo=1.0):
        if isinstance(substeps, bool) or not isinstance(substeps, int) or substeps <= 0:
            raise ValueError("substeps must be a positive integer")
        sim_dt = substeps * self.physics_timestep_s
        if sim_dt > 0.1 + 1e-12:
            raise ValueError("exact step exceeds mock body maximum chunk")
        # Deterministic stepping has no wall-derived duration.  Keep wall_dt at
        # zero so telemetry cannot mistake experiment time for elapsed real time.
        return self._step_duration(cmd, sim_dt, 0.0, tempo=tempo)

    def observe(self):
        tripod_a = 1.0 if self.phase < 1.0 else 0.0
        tripod_b = 1.0 - tripod_a
        moving = 1.0 if abs(self.vx) > 0.003 else 0.0
        contacts = [
            tripod_a * moving, tripod_b * moving, tripod_a * moving,
            tripod_b * moving, tripod_a * moving, tripod_b * moving,
        ]
        left = (contacts[0] + contacts[1] + contacts[2]) / 3.0
        right = (contacts[3] + contacts[4] + contacts[5]) / 3.0
        odor = self.lab_world.food_odor(
            fly_position_mm=(self.x * 1000.0, self.y * 1000.0, 0.7),
            fly_heading_rad=self.heading)
        ratio = self.last_step_sim_dt / self.last_step_wall_dt if self.last_step_wall_dt > 0.0 else 0.0
        touch = self.lab_world.touch
        return BodyPacket(t=self.t, sim_dt=self.last_step_sim_dt,
                          wall_dt=self.last_step_wall_dt, sim_wall_ratio=ratio,
                          controller_left=self.controller_left,
                          controller_right=self.controller_right,
                          wind_strength=float(self.lab_world.wind["strength"]),
                          wind_direction_deg=float(self.lab_world.wind["direction_deg"]),
                          wind_sensory=bool(self.lab_world.wind["sensory_enabled"]),
                          touch_strength=(0.0 if touch is None else float(touch["strength"])),
                          touch_sensory=(False if touch is None else bool(touch["sensory_enabled"])),
                          vx=self.vx, yaw_rate=self.yaw_rate,
                          contacts=contacts, left_contact=left, right_contact=right,
                          gait_phase=(self.phase / 2.0),
                          odor_left=odor["odor_left"], odor_right=odor["odor_right"],
                          nearest_food_distance_mm=odor["nearest_food_distance_mm"],
                          position_x_mm=self.x * 1000.0, position_y_mm=self.y * 1000.0,
                          heading_rad=math.atan2(math.sin(self.heading), math.cos(self.heading)))

    def apply_lab_command(self, command):
        if command.op == "reset_body":
            self.reset_body()
            return {"reset_body": True}
        if command.op == "set_player_active":
            active = bool(float(command.args.get("value", command.args.get("active", 0.0))) >= 0.5)
            return self.lab_world.set_player_active(active)
        return self.lab_world.apply_command(
            command, fly_position_mm=(self.x * 1000.0, self.y * 1000.0, 0.7))

    def set_player_input(self, player_input):
        return _set_player_input_state(self.lab_world, player_input)

    def advance_player_input(self, sim_dt):
        return _advance_player_input_motion(self.lab_world, sim_dt)

    def clear_player_input(self):
        _clear_player_input_state(self.lab_world)

    def reset_body(self):
        self.x = 0.0
        self.y = 0.0
        self.heading = 0.0
        self.vx = 0.0
        self.yaw_rate = 0.0
        self.phase = 0.0
        self.t = 0.0
        self.wall_elapsed_s = 0.0
        self.last_step_sim_dt = 0.0
        self.last_step_wall_dt = 0.0
        self.last_tempo = 1.0
        self.controller_left = 0.0
        self.controller_right = 0.0
        self.lab_world.reset_player_pose(preserve_active=True)

    def lab_state(self):
        state = self.lab_world.state()
        state["t"] = self.t
        state["body_timing"] = {
            "sim_time_s": self.t,
            "wall_input_time_s": self.wall_elapsed_s,
            "last_sim_dt_s": self.last_step_sim_dt,
            "last_wall_dt_s": self.last_step_wall_dt,
            "sim_per_wall": (self.t / self.wall_elapsed_s if self.wall_elapsed_s > 0.0 else 0.0),
        }
        return state

    def world_render_state(self):
        half = self.heading * 0.5
        render_player = getattr(self.lab_world, "render_player", None)
        return {
            "world_revision": int(self.lab_world.revision),
            "fly": {
                "id": "fly",
                "position_mm": [float(self.x * 1000.0), float(self.y * 1000.0), 0.7],
                "orientation_quat_xyzw": [0.0, 0.0, math.sin(half), math.cos(half)],
            },
            "objects": self.lab_world.render_objects(),
            "player": None if render_player is None else render_player(),
        }

    def ray_pick(self, ray_origin_mm, ray_direction):
        """Mock compatibility path: read-only query with no synthetic hit claim."""
        return {"hit": False}

    def drain_lab_events(self):
        return self.lab_world.drain_events()


# Leg order everywhere: legs_order == ('lf','lm','lh','rf','rm','rh')
# contacts[0..2] = left legs, contacts[3..5] = right legs.
LEFT_IDX = (0, 1, 2)
RIGHT_IDX = (3, 4, 5)

# ENGINEERING APPROXIMATION (see neural_decoder.py): brain walk/turn drives map
# to the turning controller's 2-channel descending signal as:
#   left  = clamp(drive - turn)
#   right = clamp(drive + turn)   (turn>0 = CCW/left body turn)
# drive here is the CPG amplitude signal (~0..0.5 cruise; 0.35 ~= 4.8 mm/s).
# Measured on the installed FlyGym 2.1.0 (M2 Air): sig 0.35 -> ~4.8 mm/s cruise.
DRIVE_GAIN = 0.5     # walk 0..1 -> CPG amplitude 0..0.5
DRIVE_REST = 0.0     # walk=0 must not create locomotor drive
TURN_GAIN = 0.35     # turn -1..1 -> left/right differential
ESCAPE_DRIVE = 0.5   # escape pulse pushes both channels to cruise (urgency)


def brain_to_descending(cmd) -> tuple:
    """LocomotorCommand -> (left, right) descending signal."""
    if not cmd.moving:
        return (0.0, 0.0)
    drive = DRIVE_REST + DRIVE_GAIN * max(0.0, min(1.0, cmd.forward))
    if cmd.urgent:
        drive = max(drive, ESCAPE_DRIVE)
    diff = TURN_GAIN * max(-1.0, min(1.0, cmd.steering))
    if cmd.reverse:
        # Backwards: controller reverses on negative signal (verified).
        return (-drive, -drive)
    left = max(0.0, min(0.6, drive - diff))
    right = max(0.0, min(0.6, drive + diff))
    return (left, right)


class RealFlyBody:
    """Actual FlyGym 2.x NeuroMechFly + HybridTurningController + MuJoCo.

    Units are mm/s-era FlyGym (positions in mm). forward velocity is reported
    in m/s to match the protocol. Uses installed API only:
    make_locomotion_fly / FlatGroundWorld / Simulation /
    HybridTurningController / HybridControllerObservation / apply_locomotion_action.
    """
    def __init__(self, config=None, drive_gain=None, show_viewer=False):
        import numpy as np
        self.np = np
        from flygym import Simulation
        from flygym.compose import FlatGroundWorld
        from flygym.utils.math import Rotation3D
        from flygym_demo.complex_terrain import (
            HybridTurningController, HybridControllerObservation,
            apply_locomotion_action, make_locomotion_fly,
            make_tripod_cpg_network, LocomotionAction, PreprogrammedSteps,
        )
        self.HybridControllerObservation = HybridControllerObservation
        self.apply_locomotion_action = apply_locomotion_action
        self.LocomotionAction = LocomotionAction
        cfg = config or {}
        self.fly = make_locomotion_fly(name='fly', add_adhesion=True, colorize=False)
        # Real stereo eye cameras. Vision is read from rendered eye frames below;
        # obstacle coordinates are never used to generate looming.
        self.fly.add_vision()
        self.world = FlatGroundWorld()
        # Runtime lab topology is preallocated before Simulation compilation.
        # Spawn/delete later only toggles/moves fixed slots on the owner thread.
        self.lab_world = LabWorld(self.world)
        # Optional initial box obstacle (ArenaConfig.box_obstacle), now occupying
        # one of the bounded lab slots instead of being a special-case MJCF geom.
        box = (cfg.get('box_obstacle') or None) if isinstance(cfg, dict) else getattr(cfg, 'box_obstacle', None)
        self.world.add_fly(
            self.fly,
            spawn_position=np.array([0.0, 0.0, 0.7]),
            spawn_rotation=Rotation3D('quat', (1, 0, 0, 0)),
        )
        self.lab_world.player.install_fly_contact_pairs(self.world, self.fly)
        self.sim = Simulation(self.world)
        self.physics_timestep_s = float(self.sim.timestep)
        self.lab_world.bind(self.sim, self._lab_force_body_ids())
        if box is not None:
            try:
                pos = list(getattr(box, 'pos', [60.0, 0.0, 5.0]))
                # ArenaConfig historically stores MuJoCo box half-extents.  The
                # lab protocol exposes full dimensions, so preserve the old
                # 10 mm cube by doubling that initial config value here.
                half = list(getattr(box, 'size', [5.0, 5.0, 5.0]))
                self.lab_world.spawn_object(
                    shape='box', object_id='obstacle_box', position_mm=pos,
                    size_mm=[2.0 * float(v) for v in half])
            except Exception as e:
                print(f'realbody: initial obstacle skipped ({e})', flush=True)
        # We only need angular occupancy/expansion, not a display-quality eye
        # image. FlyGym's default retina is 512x450; a smaller Retina keeps the
        # exact same eye cameras/FOV while making the closed loop affordable on
        # the target M2 Air. `get_raw_vision` consumes this public Retina object.
        from flygym.vision.retina import Retina
        self.sim.retina = Retina(nrows=96, ncols=84)
        self.viewer = None
        self.viewer_tick = 0
        self.order = self.fly.get_actuated_jointdofs_order('position')
        cpg = make_tripod_cpg_network(timestep=self.sim.timestep)
        self.ctl = HybridTurningController(
            timestep=self.sim.timestep, cpg_network=cpg, output_dof_order=self.order)
        base_freqs = getattr(self.ctl, '_base_intrinsic_freqs', None)
        self._base_cpg_freqs = (None if base_freqs is None else
                                np.asarray(base_freqs, dtype=float).copy())
        self.controller_tempo_supported = self._base_cpg_freqs is not None
        self.last_tempo = 1.0
        # Full HybridTurningController.step() spends most of the real-body CPU
        # budget rebuilding joint targets/correction state.  The underlying CPG
        # itself is tiny and must advance once per MuJoCo substep.  Hold each
        # computed actuator target for a short 2 ms window (500 Hz action update)
        # while integrating the CPG at the native 0.1 ms physics rate.  This is
        # an engineering performance approximation; it never moves the body
        # directly and every body displacement still comes from MuJoCo dynamics.
        self.controller_action_stride = max(1, int(round(0.002 / self.sim.timestep)))
        self.max_sim_chunk_s = 0.020
        self.max_physics_substeps = max(1, int(round(self.max_sim_chunk_s / self.sim.timestep)))
        self._base_retraction_persistence_steps = int(self.ctl.retraction_persistence_steps)
        self._controller_action = None
        self._controller_steps_since_action = 0
        self.sim.reset()
        # Simulation.reset() restores mocap data to the compiled hidden slot
        # positions. Re-apply any initial LabWorld objects (for example the
        # ArenaConfig obstacle) before warmup/vision starts.
        self.lab_world.resync_after_sim_reset()
        self.sim.warmup()
        steps = PreprogrammedSteps()
        self.default_joint_angles = np.asarray(steps.default_pose_by_dof_order(self.order))
        self.default_adhesion = np.ones(6, dtype=bool)
        self.apply_locomotion_action(
            self.sim, 'fly',
            self.LocomotionAction(
                joint_angles=self.default_joint_angles,
                adhesion_onoff=self.default_adhesion))
        # warm the controller so legs hold a pose before brain drives arrive
        for _ in range(200):
            obs = self.HybridControllerObservation.from_sim(self.sim, 'fly')
            act = self.ctl.step(np.array([0.1, 0.1]), obs)
            self.apply_locomotion_action(self.sim, 'fly', act)
            self.sim.step()
        if show_viewer:
            # MuJoCo's passive viewer gives the requested free camera while
            # this process continues to own and advance the live MjData.
            # On macOS bridge.py must be launched through `mjpython`.
            import mujoco.viewer
            self.viewer = mujoco.viewer.launch_passive(
                self.sim.mj_model, self.sim.mj_data,
                show_left_ui=False, show_right_ui=False)
            # Modest rendering for the 8 GB M2 target. Geometry/body/camera
            # remain fully viewable; expensive cosmetic passes are disabled.
            for flag in (
                mujoco.mjtRndFlag.mjRND_SHADOW,
                mujoco.mjtRndFlag.mjRND_REFLECTION,
                mujoco.mjtRndFlag.mjRND_SKYBOX,
                mujoco.mjtRndFlag.mjRND_FOG,
                mujoco.mjtRndFlag.mjRND_HAZE,
            ):
                self.viewer.user_scn.flags[flag] = 0
        self.t = 0.0
        self.wall_elapsed_s = 0.0
        self.last_step_sim_dt = 0.0
        self.last_step_wall_dt = 0.0
        self.vx_smooth = 0.0
        self.yaw_smooth = 0.0
        self.prev_xy = None
        self.prev_heading = None
        self.last_cmd = (0.0, 0.0)
        self.vision = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
        self.vision_period = 0.20   # 5 Hz stereo render; body feedback stays 60 Hz
        self.vision_elapsed = self.vision_period
        self.vision_state = self.vision.state()
        self.eye_sample_sim_tick = None
        # Force lazy observation/contact/render paths to initialize before the
        # TCP server starts listening. Otherwise the first connected brain can
        # be stalled for seconds by one-time JIT/graphics work.
        print('realbody: prewarming full body pipeline', flush=True)
        idle = LocomotorCommand(forward=0.0, moving=True)
        for _ in range(8 if show_viewer else 2):
            self.step(idle, 1.0 / 60.0)
        self.t = 0.0
        self.wall_elapsed_s = 0.0
        self.last_step_sim_dt = 0.0
        self.last_step_wall_dt = 0.0
        self.vx_smooth = 0.0
        self.yaw_smooth = 0.0
        self.prev_xy = None
        self.prev_heading = None
        self.vision_elapsed = self.vision_period
        self.vision_state = self.vision.state()
        self.eye_sample_sim_tick = None
        print('realbody: ready', flush=True)

    def _apply_controller_tempo(self, tempo):
        try:
            requested = float(tempo)
        except (TypeError, ValueError):
            requested = 1.0
        if not math.isfinite(requested):
            requested = 1.0
        requested = max(0.2, min(2.0, requested))
        if not self.controller_tempo_supported:
            self.last_tempo = 1.0
            return 1.0
        self.ctl._base_intrinsic_freqs = self._base_cpg_freqs * requested
        self.last_tempo = requested
        return requested

    def _configure_cpg_drive(self, sig):
        """Apply the current two-channel drive without advancing the CPG clock."""
        np = self.np
        signal = np.asarray(sig, dtype=float)
        self.ctl.cpg_network.intrinsic_amps = np.repeat(
            np.abs(signal[:, np.newaxis]), 3, axis=1).ravel()
        freqs = self.ctl._base_intrinsic_freqs.copy()
        freqs[:3] *= 1 if signal[0] >= 0 else -1
        freqs[3:] *= 1 if signal[1] >= 0 else -1
        self.ctl.cpg_network.intrinsic_freqs = freqs

    def _controller_substep(self, sig):
        """Advance one native CPG tick and refresh actuator targets when due.

        HybridTurningController correction rates are expressed per controller
        timestep.  When target construction is decimated, temporarily scale that
        correction timestep by the exact number of physics ticks since the last
        target refresh.  The CPGNetwork keeps its native timestep and advances
        exactly once here, either inside ``ctl.step`` or directly on held-action
        substeps.
        """
        stride = max(1, int(self.controller_action_stride))
        due = (self._controller_action is None or
               self._controller_steps_since_action >= stride - 1)
        if not due:
            self.ctl.cpg_network.step()
            self._controller_steps_since_action += 1
            return

        interval_steps = max(1, self._controller_steps_since_action + 1)
        obs = self.HybridControllerObservation.from_sim(self.sim, 'fly')
        original_timestep = self.ctl.timestep
        original_persistence = self.ctl.retraction_persistence_steps
        self.ctl.timestep = self.sim.timestep * interval_steps
        # The upstream counter is incremented in the same call that initiates
        # persistence, so a threshold of at least 2 preserves one full refresh
        # interval instead of cancelling immediately.
        self.ctl.retraction_persistence_steps = max(
            2,
            int(math.ceil(self._base_retraction_persistence_steps / interval_steps)),
        )
        try:
            self._controller_action = self.ctl.step(self.np.asarray(sig, dtype=float), obs)
        finally:
            self.ctl.timestep = original_timestep
            self.ctl.retraction_persistence_steps = original_persistence
        self.apply_locomotion_action(self.sim, 'fly', self._controller_action)
        self._controller_steps_since_action = 0

    def _lab_force_body_ids(self):
        fly_o = self.sim.world.fly_lookup['fly']
        order = fly_o.get_bodysegs_order()
        cls = type(fly_o).BODY_SEGMENT_CLASS
        internal = self.sim._internal_bodyids_by_fly['fly']

        def body_id(name):
            try:
                return internal[order.index(cls(name))]
            except (ValueError, KeyError, IndexError):
                return None

        mapping = {
            'thorax': body_id('c_thorax'),
            'head': body_id('c_head'),
            'abdomen': body_id('c_abdomen4') or body_id('c_abdomen5'),
            'left_front_leg': body_id('lf_tibia'),
            'left_middle_leg': body_id('lm_tibia'),
            'left_hind_leg': body_id('lh_tibia'),
            'right_front_leg': body_id('rf_tibia'),
            'right_middle_leg': body_id('rm_tibia'),
            'right_hind_leg': body_id('rh_tibia'),
            'lf': body_id('lf_tibia'), 'lm': body_id('lm_tibia'), 'lh': body_id('lh_tibia'),
            'rf': body_id('rf_tibia'), 'rm': body_id('rm_tibia'), 'rh': body_id('rh_tibia'),
        }
        return {k: v for k, v in mapping.items() if v is not None}

    def _heading(self):
        fly_o = self.sim.world.fly_lookup['fly']
        order = fly_o.get_bodysegs_order()
        cls = type(fly_o).BODY_SEGMENT_CLASS
        idx = order.index(cls('c_thorax'))
        bid = self.sim._internal_bodyids_by_fly['fly'][idx]
        return self.sim.mj_data.xmat[bid].reshape(3, 3)[:, 0].copy()

    def _thorax_position(self):
        bid = self.lab_world.force_body_ids.get('thorax')
        if bid is None:
            return [0.0, 0.0, 0.7]
        return self.sim.mj_data.xpos[bid].copy()

    def world_render_state(self):
        # Refresh derived body/geom transforms at the same owner boundary used by
        # ray_pick. This is especially important after an owner-thread LabObject
        # or free-joint participant pose write that has not yet been followed by
        # a physics step. mj_forward does not
        # advance qpos/qvel/time or mutate LabWorld semantic state.
        import mujoco
        mujoco.mj_forward(self.sim.mj_model, self.sim.mj_data)
        bid = self.lab_world.force_body_ids.get('thorax')
        if bid is None:
            raise RuntimeError("thorax body id unavailable")
        pos = [float(v) for v in self.sim.mj_data.xpos[bid]]
        # MuJoCo stores global body quaternion as wxyz; V5 wire contract is xyzw.
        quat_wxyz = [float(v) for v in self.sim.mj_data.xquat[bid]]
        quat = [quat_wxyz[1], quat_wxyz[2], quat_wxyz[3], quat_wxyz[0]]
        render_player = getattr(self.lab_world, "render_player", None)
        return {
            "world_revision": int(self.lab_world.revision),
            "fly": {
                "id": "fly",
                "position_mm": pos,
                "orientation_quat_xyzw": quat,
            },
            "objects": self.lab_world.render_objects(),
            "player": None if render_player is None else render_player(),
        }

    def ray_pick(self, ray_origin_mm, ray_direction):
        """Intersect the live MuJoCo scene and return a stable semantic target."""
        import mujoco

        np = self.np
        origin = np.asarray(ray_origin_mm, dtype=float)
        direction = np.asarray(ray_direction, dtype=float)
        norm = float(np.linalg.norm(direction))
        if origin.shape != (3,) or direction.shape != (3,) or not np.all(np.isfinite(origin)):
            raise ValueError("invalid ray origin/direction")
        if not np.all(np.isfinite(direction)) or norm < 1e-12:
            raise ValueError("invalid ray direction")
        direction = direction / norm
        geom_id = np.array([-1], dtype=np.int32)
        normal = np.zeros(3, dtype=float)
        # Keep derived geom transforms coherent with any owner-thread LabObject
        # or free-joint participant pose update since the previous physics step.
        # mj_forward does not advance simulation time or mutate semantic world state.
        mujoco.mj_forward(self.sim.mj_model, self.sim.mj_data)
        distance = float(mujoco.mj_ray(
            self.sim.mj_model, self.sim.mj_data,
            origin, direction, None, True, -1, geom_id, normal))
        if distance < 0.0 or int(geom_id[0]) < 0:
            return {"hit": False}

        gid = int(geom_id[0])
        semantic = self.lab_world.semantic_target_for_geom(gid)
        if semantic is None:
            body_id = int(self.sim.mj_model.geom_bodyid[gid])
            fly_body_ids = {int(v) for v in self.sim._internal_bodyids_by_fly.get('fly', [])}
            if body_id in fly_body_ids:
                semantic = {"target_id": "fly", "target_kind": "fly"}
            else:
                semantic = {"target_id": "world", "target_kind": "world"}
        point = origin + direction * distance
        normal_norm = float(np.linalg.norm(normal))
        if normal_norm > 1e-12:
            normal = normal / normal_norm
        return {
            "hit": True,
            "target_id": semantic["target_id"],
            "target_kind": semantic["target_kind"],
            "distance_mm": distance,
            "point_mm": [float(v) for v in point],
            "normal_world": [float(v) for v in normal],
            "geom_id": gid,
        }

    def apply_lab_command(self, command):
        if command.op == "reset_body":
            self.reset_body()
            return {"reset_body": True}
        if command.op == "set_player_active":
            active = bool(float(command.args.get("value", command.args.get("active", 0.0))) >= 0.5)
            return self.lab_world.set_player_active(active)
        return self.lab_world.apply_command(command, fly_position_mm=self._thorax_position())

    def set_player_input(self, player_input):
        return _set_player_input_state(self.lab_world, player_input)

    def clear_player_input(self):
        _clear_player_input_state(self.lab_world)

    def reset_body(self):
        """Reset fly/controller and participant pose while preserving the lab world.

        An active participant remains active but returns to its authoritative
        spawn pose. That pose reset is a non-structural LabWorld mutation: it
        advances world revision without changing structure revision.
        """
        self.sim.reset()
        self.lab_world.resync_after_sim_reset()
        self.lab_world.reset_player_pose(preserve_active=True)
        self.sim.warmup()
        try:
            self.ctl.reset(seed=0)
        except TypeError:
            self.ctl.reset()
        self._apply_controller_tempo(1.0)
        self._controller_action = None
        self._controller_steps_since_action = 0
        self.apply_locomotion_action(
            self.sim, 'fly',
            self.LocomotionAction(
                joint_angles=self.default_joint_angles.copy(),
                adhesion_onoff=self.default_adhesion.copy()))
        # A short deterministic settle keeps the reset pose valid without the
        # long one-time graphics/controller prewarm from __init__.
        for _ in range(20):
            self.sim.step()
        self.t = 0.0
        self.wall_elapsed_s = 0.0
        self.last_step_sim_dt = 0.0
        self.last_step_wall_dt = 0.0
        self.vx_smooth = 0.0
        self.yaw_smooth = 0.0
        self.prev_xy = None
        self.prev_heading = None
        self.last_cmd = (0.0, 0.0)
        self.vision = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
        self.vision_elapsed = self.vision_period
        self.vision_state = self.lab_world.augment_vision_state(self.vision.state())
        self.eye_sample_sim_tick = None

    def lab_state(self):
        state = self.lab_world.state()
        state["t"] = self.t
        state["vision"] = dict(self.vision_state)
        state["body_timing"] = {
            "sim_time_s": self.t,
            "wall_input_time_s": self.wall_elapsed_s,
            "last_sim_dt_s": self.last_step_sim_dt,
            "last_wall_dt_s": self.last_step_wall_dt,
            "sim_per_wall": (self.t / self.wall_elapsed_s if self.wall_elapsed_s > 0.0 else 0.0),
        }
        state["controller"] = {
            "tempo_supported": bool(self.controller_tempo_supported),
            "tempo_applied": float(self.last_tempo),
            "action_stride_substeps": int(self.controller_action_stride),
            "action_period_ms": float(self.controller_action_stride * self.sim.timestep * 1000.0),
        }
        return state

    def drain_lab_events(self):
        return self.lab_world.drain_events()

    def _step_substeps(self, cmd, n, wall_dt, tempo=1.0):
        np = self.np
        if isinstance(n, bool) or not isinstance(n, int) or n <= 0:
            raise ValueError("physics substeps must be a positive integer")
        if n > self.max_physics_substeps:
            raise ValueError("physics substeps exceed maximum simulation chunk")
        wall_dt = max(0.0, float(wall_dt))
        sim_dt = max(1e-6, n * self.sim.timestep)
        self._apply_controller_tempo(tempo)
        sig = brain_to_descending(cmd)
        self.last_cmd = sig
        self._configure_cpg_drive(sig)
        # F-02: the participant is moved by a bounded force servo on every
        # native substep, never by a quantum-sized qpos write before physics.
        player_start = self.lab_world.begin_player_quantum()
        try:
            for _ in range(n):
                self._controller_substep(sig)
                self.lab_world.pre_step(self.sim.timestep)
                self.lab_world.player_substep()
                self.sim.step()
        finally:
            self.lab_world.end_player_quantum(player_start)
        # --- observe: velocity from thorax displacement (mm -> m/s) ---
        pos = self.sim.get_body_positions('fly')
        xy_mm = pos.mean(axis=0)[:2]
        xy = xy_mm / 1000.0
        h = self._heading()
        yaw_now = float(np.arctan2(h[1], h[0]))
        # Sim-time displacement: n substeps x timestep (wall clock lies when
        # ticks queue, e.g. under load or headless backlog).
        if self.prev_xy is None:
            vx_raw, yaw_raw = 0.0, 0.0
        else:
            dxy = (xy - self.prev_xy) / sim_dt
            fwd = np.array([math.cos(yaw_now), math.sin(yaw_now)])
            vx_raw = float(np.dot(dxy, fwd))
            # mm/s -> m/s already via /1000 above; FlyGym cruise is ~mm/s scale
            dyaw = (yaw_now - self.prev_heading + math.pi) % (2 * math.pi) - math.pi
            yaw_raw = float(dyaw / sim_dt)
        self.prev_xy = xy
        self.prev_heading = yaw_now
        a = min(1.0, sim_dt * 4.0)
        self.vx_smooth += (vx_raw - self.vx_smooth) * a
        self.yaw_smooth += (yaw_raw - self.yaw_smooth) * a
        # --- contacts: 6 leg flags -> 0/1 ---
        try:
            found = np.asarray(self.sim.get_ground_contact_info('fly')[0]).ravel()
        except Exception:
            found = np.zeros(6)
        contacts = [1.0 if f > 0.5 else 0.0 for f in list(found[:6])]
        while len(contacts) < 6:
            contacts.append(0.0)
        left = sum(contacts[i] for i in LEFT_IDX) / 3.0
        right = sum(contacts[i] for i in RIGHT_IDX) / 3.0
        # --- gait phase from CPG (MODELING: coherent phase proxy) ---
        try:
            ph = float(np.mean(self.ctl.cpg_network.curr_phases)) % (2 * math.pi)
            gait_phase = ph / (2 * math.pi)
        except Exception:
            gait_phase = None
        # Protocol time is actual MuJoCo simulation time, not wall time.
        self.t += sim_dt
        self.wall_elapsed_s += wall_dt
        self.last_step_sim_dt = sim_dt
        self.last_step_wall_dt = wall_dt
        # --- actual FlyGym eye-camera vision -> looming proxy ---
        # Stereo rendering is much more expensive than one body/control tick on
        # the target M2, so render at 5 Hz
        # and decay the signal between frames while preserving the 60 Hz body loop.
        self.vision_elapsed += sim_dt
        if self.vision_elapsed >= self.vision_period:
            vision_dt = self.vision_elapsed
            self.vision_elapsed = 0.0
            try:
                frames = self.sim.get_raw_vision('fly')
                frames = self.lab_world.apply_eye_mask(frames)
                self.vision_state = self.vision.analyze(frames, vision_dt)
                # Exact simulation time of the latest successful raw stereo-eye
                # sample. Values in later body packets may be decayed from this
                # frame, so clients must not pretend the current body tick was a
                # fresh camera render.
                self.eye_sample_sim_tick = int(round(self.t * 1000.0))
            except Exception as e:
                print(f'realbody: vision sample failed ({e})', flush=True)
                self.vision_state = self.vision.decay(vision_dt)
        else:
            self.vision_state = self.vision.decay(sim_dt)
        self.vision_state = self.lab_world.augment_vision_state(self.vision_state)
        thorax_position_mm = self._thorax_position()
        odor = self.lab_world.food_odor(
            fly_position_mm=thorax_position_mm, fly_heading_rad=yaw_now)
        if self.viewer is not None:
            if self.viewer.is_running():
                # The passive viewer can contend with MuJoCo data access on an
                # 8 GB M2 Air. Render at a modest ~15 FPS while physics and TCP
                # feedback continue at 50-100 Hz.
                self.viewer_tick += 1
                if self.viewer_tick % 6 == 0:
                    self.viewer.sync()
            else:
                self.viewer.close()
                self.viewer = None
        sim_wall_ratio = sim_dt / wall_dt if wall_dt > 0.0 else 0.0
        touch = self.lab_world.touch
        return BodyPacket(t=self.t, sim_dt=sim_dt, wall_dt=wall_dt,
                          sim_wall_ratio=sim_wall_ratio,
                          controller_left=float(self.last_cmd[0]),
                          controller_right=float(self.last_cmd[1]),
                          wind_strength=float(self.lab_world.wind["strength"]),
                          wind_direction_deg=float(self.lab_world.wind["direction_deg"]),
                          wind_sensory=bool(self.lab_world.wind["sensory_enabled"]),
                          touch_strength=(0.0 if touch is None else float(touch["strength"])),
                          touch_sensory=(False if touch is None else bool(touch["sensory_enabled"])),
                          vx=self.vx_smooth, yaw_rate=self.yaw_smooth,
                          contacts=contacts, left_contact=left, right_contact=right,
                          gait_phase=gait_phase,
                          loom_left=self.vision_state['loom_left'],
                          loom_right=self.vision_state['loom_right'],
                          brightness=self.vision_state['brightness'],
                          brightness_left=self.vision_state.get('brightness_left', self.vision_state['brightness']),
                          brightness_right=self.vision_state.get('brightness_right', self.vision_state['brightness']),
                          occupancy_left=self.vision_state.get('occupancy_left', 0.0),
                          occupancy_right=self.vision_state.get('occupancy_right', 0.0),
                          optic_expansion_left=self.vision_state.get('optic_expansion_left', 0.0),
                          optic_expansion_right=self.vision_state.get('optic_expansion_right', 0.0),
                          eye_sample_sim_tick=self.eye_sample_sim_tick,
                          flash_left=self.vision_state.get('flash_left', 0.0),
                          flash_right=self.vision_state.get('flash_right', 0.0),
                          odor_left=odor["odor_left"], odor_right=odor["odor_right"],
                          nearest_food_distance_mm=odor["nearest_food_distance_mm"],
                          position_x_mm=float(thorax_position_mm[0]),
                          position_y_mm=float(thorax_position_mm[1]),
                          heading_rad=yaw_now,
                          bearing=self.vision_state['bearing'])

    def step(self, cmd, dt, tempo=1.0):
        dt = max(1e-4, min(0.1, dt))
        # Interactive/V3 path: caller wall duration is rounded to native physics
        # and catch-up remains capped exactly as before V4.
        n = max(1, min(
            self.max_physics_substeps,
            int(round(min(dt, self.max_sim_chunk_s) / self.sim.timestep)),
        ))
        return self._step_substeps(cmd, n, dt, tempo=tempo)

    def step_exact(self, cmd, substeps, tempo=1.0):
        """Advance an exact integer count of native MuJoCo substeps.

        This is the V4 lockstep primitive.  It never derives duration from wall
        time and never rounds a requested duration to another number of steps.
        """
        return self._step_substeps(cmd, substeps, 0.0, tempo=tempo)

    def close(self):
        if self.viewer is not None:
            self.viewer.close()
            self.viewer = None
        self.sim.close()
