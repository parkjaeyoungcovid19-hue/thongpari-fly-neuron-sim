"""Real MuJoCo regression for audit F-02: held participant input against contact.

Run with the project venv:
    NUMBA_DISABLE_JIT=1 ../flygym-venv/bin/python test_player_collision_real.py

Acceptance bounds were fixed before measuring (2026-09-26):
- static LabObject contact: penetration <= 0.1 mm while held at full speed
- fly thorax pair (FlyGym default pair stiffness kept): penetration <= 1.0 mm
- release: rebound away from the resting surface <= 0.1 mm, residual speed
  <= 0.5 mm/s after 0.5 s
- free space: first 20 ms quantum 0.6 +/- 0.05 mm, steady speed 30 +/- 0.3 mm/s
The probe never opens a TCP port or touches an existing backend.
"""
import math
import os
import sys

import mujoco
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
from player_body import PLAYER_MOVE_SPEED_MM_S, PLAYER_RADIUS_MM

STATIC_PENETRATION_MAX_MM = 0.1
FLY_PENETRATION_MAX_MM = 1.0
RELEASE_REBOUND_MAX_MM = 0.1
RELEASE_SPEED_MAX_MM_S = 0.5

fails = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not cond:
        fails.append(name)


body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
try:
    m, d = body.sim.mj_model, body.sim.mj_data
    world = body.lab_world
    player = world.player
    idle = LocomotorCommand(forward=0.0)
    q20 = int(round(0.020 / body.physics_timestep_s))

    def reset_player(position, yaw_rad=0.0):
        body.clear_player_input()
        world.reset_player_pose(preserve_active=True)
        world.set_player_active(True)
        world.set_player_pose(position_mm=list(position))
        if yaw_rad:
            player.set_input_state(move_axes=[0.0, 0.0], look_delta=[yaw_rad, 0.0],
                                   held_actions=[])
        mujoco.mj_forward(m, d)

    def hold(forward, right=0.0):
        player.set_input_state(move_axes=[forward, right], look_delta=[0.0, 0.0],
                               held_actions=[])

    def player_pos():
        return np.asarray(d.qpos[player.qpos_adr:player.qpos_adr + 3], dtype=float).copy()

    def player_speed():
        return float(np.linalg.norm(d.qvel[player.dof_adr:player.dof_adr + 3]))

    def min_contact_dist(other_gids=None):
        mujoco.mj_forward(m, d)
        dist = []
        for j in range(int(d.ncon)):
            g1, g2 = int(d.contact[j].geom1), int(d.contact[j].geom2)
            if player.geom_id not in (g1, g2):
                continue
            other = g2 if g1 == player.geom_id else g1
            if other_gids is None or other in other_gids:
                dist.append(float(d.contact[j].dist))
        return min(dist) if dist else None

    # Sample the participant's contact distance after every native mj_step, not
    # only at quantum end, so peak penetration inside a quantum is caught.
    substep_samples = {"worst": 0.0, "touched": set()}
    original_sim_step = body.sim.step

    def sampled_sim_step(*args, **kwargs):
        out = original_sim_step(*args, **kwargs)
        for j in range(int(d.ncon)):
            g1, g2 = int(d.contact[j].geom1), int(d.contact[j].geom2)
            if player.geom_id in (g1, g2):
                other = g2 if g1 == player.geom_id else g1
                substep_samples["touched"].add(other)
                substep_samples["worst"] = min(substep_samples["worst"], float(d.contact[j].dist))
        return out

    body.sim.step = sampled_sim_step

    def run(seconds, substeps):
        """Return (worst per-substep contact distance, geoms touched)."""
        substep_samples["worst"] = 0.0
        substep_samples["touched"] = set()
        for _ in range(int(round(seconds / (substeps * body.physics_timestep_s)))):
            body.step_exact(idle, substeps)
            dist = min_contact_dist()
            if dist is not None:
                substep_samples["worst"] = min(substep_samples["worst"], dist)
        return substep_samples["worst"], set(substep_samples["touched"])

    def look_matches():
        mujoco.mj_forward(m, d)
        q = player.orientation_quat_xyzw
        want = np.array([q[3], q[0], q[1], q[2]])
        got = np.asarray(d.xquat[player.body_id], dtype=float)
        return float(min(np.abs(got - want).max(), np.abs(got + want).max()))

    WALL_NEAR_FACE_X = 29.0
    REST_X = WALL_NEAR_FACE_X - PLAYER_RADIUS_MM

    def release_check(name):
        """Release a held wall push; the centre must settle at the surface.

        Uses geometry (wall face x=29 mm), not contact presence, so a body that
        bounced clear of the wall cannot report a zero gap.
        """
        body.clear_player_input()
        run(0.5, q20)
        x = float(player_pos()[0])
        offset = REST_X - x  # >0: away from wall (rebound), <0: still inside
        check(f"F-02 {name}: release settles at the wall surface",
              -STATIC_PENETRATION_MAX_MM <= offset <= RELEASE_REBOUND_MAX_MM
              and player_speed() <= RELEASE_SPEED_MAX_MM_S,
              f"x={x:.4f}mm rest_x={REST_X:.4f} offset={offset:+.4f}mm "
              f"speed={player_speed():.4f}mm/s")

    world.set_player_active(True)

    # 1. Free space: simulation-time speed contract (existing V5.5 bound).
    reset_player([24.0, 0.0, 8.0])
    start = player_pos()
    hold(1.0)
    body.step_exact(idle, q20)
    first = float(player_pos()[0] - start[0])
    mid = player_pos()
    for _ in range(10):
        body.step_exact(idle, q20)
    steady = float((player_pos()[0] - mid[0]) / 0.200)
    check("F-02 free space keeps 20 ms = 0.6 mm and 30 mm/s",
          abs(first - PLAYER_MOVE_SPEED_MM_S * 0.020) <= 0.05
          and abs(steady - PLAYER_MOVE_SPEED_MM_S) <= 0.3,
          f"first_quantum={first:.4f}mm steady={steady:.4f}mm/s")

    # 2. Look-only input changes orientation, never position.
    reset_player([24.0, 0.0, 8.0])
    before = player_pos()
    player.set_input_state(move_axes=[0.0, 0.0], look_delta=[math.pi / 2, 0.0],
                           held_actions=[])
    body.step_exact(idle, q20)
    moved = float(np.linalg.norm(player_pos() - before))
    check("F-02 look-only input does not translate the participant",
          moved <= 1e-6, f"moved={moved:.3e}mm")

    # 3. Head-on wall, several quantum lengths. Wall spans x=29..31 mm.
    world.spawn_object(shape="wall", object_id="f02-wall",
                       position_mm=[30.0, 0.0, 10.0], size_mm=[2.0, 40.0, 20.0])
    wall_gids = {g for g in range(m.ngeom)
                 if (world.semantic_target_for_geom(g) or {}).get("target_id") == "f02-wall"}
    for substeps in (10, 50, q20):
        reset_player([24.0, 0.0, 8.0])
        hold(1.0)
        worst, touched = run(2.0, substeps)
        x = float(player_pos()[0])
        check(f"F-02 head-on wall bounded at {substeps * body.physics_timestep_s * 1000:.0f} ms quanta",
              bool(wall_gids & touched) and -worst <= STATIC_PENETRATION_MAX_MM
              and x <= REST_X + STATIC_PENETRATION_MAX_MM,
              f"touched_wall={bool(wall_gids & touched)} peak_substep_penetration={-worst:.4f}mm "
              f"center_x={x:.4f}mm limit={REST_X}")
    release_check("head-on wall")

    # 4. Oblique approach (30 deg): bounded penetration while sliding along the wall.
    reset_player([24.0, -8.0, 8.0], yaw_rad=math.radians(30.0))
    hold(1.0)
    y0 = float(player_pos()[1])
    worst, touched = run(1.5, q20)
    pos = player_pos()
    check("F-02 oblique wall approach slides with bounded penetration",
          bool(wall_gids & touched) and -worst <= STATIC_PENETRATION_MAX_MM
          and pos[0] <= REST_X + STATIC_PENETRATION_MAX_MM and pos[1] - y0 > 5.0,
          f"peak_substep_penetration={-worst:.4f}mm center={pos.round(4).tolist()} "
          f"slide_y={pos[1]-y0:.3f}mm")
    look_err = look_matches()
    check("F-02 sliding contact never rotates the participant away from look",
          look_err <= 1e-9, f"max|xquat-look|={look_err:.3e}")
    release_check("oblique wall")
    world.remove_object("f02-wall")

    # 5. Box corner: 4 mm cube centred at (30, 0, 8); corner (28, -2).
    world.spawn_object(shape="box", object_id="f02-box",
                       position_mm=[30.0, 0.0, 8.0], size_mm=[4.0, 4.0, 4.0])
    box_gids = {g for g in range(m.ngeom)
                if (world.semantic_target_for_geom(g) or {}).get("target_id") == "f02-box"}
    reset_player([24.0, -6.0, 8.0], yaw_rad=math.radians(45.0))
    hold(1.0)
    worst, touched = run(1.5, q20)
    pos = player_pos()
    inside = (28.0 < pos[0] < 32.0) and (-2.0 < pos[1] < 2.0)
    check("F-02 box corner approach bounded",
          bool(box_gids & touched) and -worst <= STATIC_PENETRATION_MAX_MM and not inside,
          f"peak_substep_penetration={-worst:.4f}mm center={pos.round(4).tolist()}")
    body.clear_player_input()
    run(0.5, q20)
    check("F-02 box corner release comes to rest",
          player_speed() <= RELEASE_SPEED_MAX_MM_S, f"speed={player_speed():.4f}mm/s")
    world.remove_object("f02-box")

    # 6. Push into the fly thorax through the explicit V5.4 contact pair.
    mujoco.mj_forward(m, d)
    thorax_bid = world.force_body_ids["thorax"]
    thorax = np.asarray(d.xpos[thorax_bid], dtype=float).copy()
    pair_gids = set()
    for i in range(int(m.npair)):
        g1, g2 = int(m.pair_geom1[i]), int(m.pair_geom2[i])
        if player.geom_id in (g1, g2):
            pair_gids.add(g2 if g1 == player.geom_id else g1)
    reset_player([thorax[0] - 6.0, thorax[1], thorax[2]])
    hold(1.0)
    worst, touched_gids = run(0.5, q20)
    touched = bool(pair_gids & touched_gids)
    thorax_after = np.asarray(d.xpos[thorax_bid], dtype=float)
    finite = bool(np.all(np.isfinite(d.qpos)) and np.all(np.isfinite(d.qvel)))
    thorax_shift = float(np.linalg.norm(thorax_after - thorax))
    check("F-02 held push into fly thorax stays bounded",
          touched and finite and -worst <= FLY_PENETRATION_MAX_MM and thorax_shift < 20.0,
          f"touched={touched} peak_substep_penetration={-worst:.4f}mm "
          f"thorax_shift={thorax_shift:.3f}mm")
    body.clear_player_input()
    run(0.5, q20)
    check("F-02 fly contact release comes to rest",
          finite and player_speed() <= RELEASE_SPEED_MAX_MM_S,
          f"speed={player_speed():.4f}mm/s")

    # 7. Servo force never leaks outside a quantum (raw mj_step users see none).
    check("F-02 servo force cleared after each quantum",
          float(np.abs(d.xfrc_applied[player.body_id]).max()) == 0.0,
          f"xfrc={d.xfrc_applied[player.body_id].tolist()}")

    # 8. Deactivating mid-hold parks the participant and leaves no servo force.
    reset_player([24.0, 0.0, 8.0])
    hold(1.0)
    body.step_exact(idle, q20)
    world.set_player_active(False)
    body.step_exact(idle, q20)
    check("F-02 deactivation mid-hold parks participant with no input or force",
          player.input_move_axes == [0.0, 0.0]
          and float(np.abs(d.xfrc_applied[player.body_id]).max()) == 0.0
          and world.render_player() is None,
          f"axes={player.input_move_axes}")
    world.set_player_active(True)

    # 9. reset_body during a held push returns to spawn with no residual motion.
    reset_player([24.0, 0.0, 8.0])
    hold(1.0)
    body.step_exact(idle, q20)
    body.reset_body()
    spawn = np.asarray(player.spawn_position_mm, dtype=float)
    check("F-02 reset_body clears held input and servo state",
          player.input_move_axes == [0.0, 0.0]
          and float(np.linalg.norm(player_pos() - spawn)) < 1e-9
          and player_speed() == 0.0
          and float(np.abs(d.xfrc_applied[player.body_id]).max()) == 0.0,
          f"pos={player_pos().tolist()} spawn={spawn.tolist()} speed={player_speed()}")

    # 10. Determinism: the same reset + input sequence gives identical poses.
    def scripted_run():
        body.reset_body()
        world.spawn_object(shape="wall", object_id="f02-det-wall",
                           position_mm=[30.0, 0.0, 10.0], size_mm=[2.0, 40.0, 20.0])
        reset_player([24.0, -3.0, 8.0], yaw_rad=math.radians(20.0))
        hold(1.0, 0.3)
        trace = []
        for _ in range(40):
            body.step_exact(idle, q20)
            trace.append(player_pos())
        body.clear_player_input()
        for _ in range(10):
            body.step_exact(idle, q20)
            trace.append(player_pos())
        world.remove_object("f02-det-wall")
        return np.asarray(trace)

    first_trace = scripted_run()
    second_trace = scripted_run()
    det_err = float(np.abs(first_trace - second_trace).max())
    check("F-02 servo motion is deterministic for identical input", det_err == 0.0,
          f"max_abs_diff={det_err:.3e}mm")

    # 11. Workspace bound: the servo stops driving past +/-1000 mm like set_pose().
    reset_player([999.5, 0.0, 8.0])
    hold(1.0)
    run(0.5, q20)
    x_edge = float(player_pos()[0])
    check("F-02 servo respects the +/-1000 mm participant workspace",
          x_edge <= 1000.0 + 0.05 and player_speed() <= RELEASE_SPEED_MAX_MM_S,
          f"x={x_edge:.4f}mm speed={player_speed():.4f}mm/s")
finally:
    body.close()

print("ALL PLAYER COLLISION TESTS PASS" if not fails else f"{len(fails)} FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
