"""Optional real FlyGym/MuJoCo Virtual Fly Lab smoke test.

Run with the project venv, for example:
    ../flygym-venv/bin/python test_lab_real.py

This is intentionally separate from test_lab.py because constructing the real
NeuroMechFly + retina is substantially more expensive than the stdlib/mock test.
"""
import copy
import math
import os
import sys
from unittest import mock

import mujoco
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from environment import ArenaConfig
from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
from player_body import PLAYER_MOVE_SPEED_MM_S
from protocol import LabCommand, PlayerInputPacket


fails = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not cond:
        fails.append(name)


body = RealFlyBody(config=ArenaConfig(), show_viewer=False)
try:
    world = body.lab_world
    check("real LabWorld bound", world.state()["physical_backend"] is True)

    # V4 deterministic quantum contract: the real backend must declare its
    # native physics timestep, 20 ms must be an exact integer number of those
    # substeps, and step_exact must advance only simulation time (not fake wall
    # time). This is the primitive the request-driven lockstep scheduler uses.
    native_dt = body.physics_timestep_s
    quantum_s = 0.020
    exact_substeps = int(round(quantum_s / native_dt))
    check("real backend declares exact native physics timestep",
          native_dt > 0.0 and abs(native_dt - float(body.sim.timestep)) < 1e-15 and
          abs(exact_substeps * native_dt - quantum_s) < 1e-12,
          f"dt={native_dt:.9f}s substeps={exact_substeps}")
    exact_start = body.t
    exact_obs = body.step_exact(LocomotorCommand(forward=0.0), exact_substeps)
    check("real V4 20 ms exact step has no wall-derived duration",
          abs((exact_obs.t - exact_start) - quantum_s) < 1e-12 and
          abs(exact_obs.sim_dt - quantum_s) < 1e-12 and exact_obs.wall_dt == 0.0 and
          exact_obs.sim_wall_ratio == 0.0,
          f"advance={exact_obs.t-exact_start:.9f}s sim_dt={exact_obs.sim_dt:.9f} "
          f"wall_dt={exact_obs.wall_dt:.9f}")

    capacity = world.state()["slot_capacity"]
    check("expanded runtime object capacity",
          capacity.get("box", 0) >= 64 and capacity.get("sphere", 0) >= 64 and
          capacity.get("wall", 0) >= 64 and capacity.get("food", 0) >= 32,
          repr(capacity))

    # The old real topology exhausted at 8 box/sphere/wall and 4 food objects.
    # Activate more than those old limits for every shape against the compiled
    # MuJoCo model, then release them again so later vision/odor tests stay clean.
    stress_ids = []
    stress_shapes = (("box", 12), ("sphere", 12), ("wall", 12), ("food", 8))
    for shape, count in stress_shapes:
        for i in range(count):
            object_id = f"capacity_{shape}_{i}"
            x = -350.0 - 40.0 * (0 if shape == "box" else 1 if shape == "sphere" else 2 if shape == "wall" else 3)
            y = -120.0 + i * 12.0
            z = 5.0 if shape in ("box", "sphere") else (7.5 if shape == "wall" else 1.5)
            size = ([4.0, 4.0, 4.0] if shape == "box" else
                    [4.0, 4.0, 4.0] if shape == "sphere" else
                    [2.0, 12.0, 10.0] if shape == "wall" else
                    [2.0, 2.0, 2.0])
            world.spawn_object(shape=shape, object_id=object_id,
                               position_mm=[x, y, z], size_mm=size)
            stress_ids.append(object_id)
    stress_state = world.state()
    check("real slots exceed former per-shape limits",
          sum(1 for o in stress_state["objects"] if o["id"].startswith("capacity_box_")) == 12 and
          sum(1 for o in stress_state["objects"] if o["id"].startswith("capacity_sphere_")) == 12 and
          sum(1 for o in stress_state["objects"] if o["id"].startswith("capacity_wall_")) == 12 and
          sum(1 for o in stress_state["objects"] if o["id"].startswith("capacity_food_")) == 8,
          f"objects={len(stress_state['objects'])} free={stress_state['slot_free']}")
    last_stress = world.objects[stress_ids[-1]]
    _, stress_gid, stress_mocap = world._slot_ids[last_stress.slot]
    check("expanded slot is physically active in MuJoCo",
          float(body.sim.mj_model.geom_rgba[stress_gid, 3]) > 0.9 and
          np.allclose(body.sim.mj_data.mocap_pos[stress_mocap], last_stress.position_mm),
          f"slot={last_stress.slot}")
    for object_id in stress_ids:
        world.remove_object(object_id)

    initial = world.objects.get("obstacle_box")
    check("initial ArenaConfig obstacle exists", initial is not None)
    if initial is not None:
        _, gid, mocap_id = world._slot_ids[initial.slot]
        actual = list(body.sim.mj_data.mocap_pos[mocap_id])
        check("initial obstacle survives Simulation.reset",
              all(abs(a - b) < 1e-9 for a, b in zip(actual, initial.position_mm)),
              f"actual={actual} state={initial.position_mm}")
        old_rbound = float(body.sim.mj_model.geom_rbound[gid])
        world.resize_object("obstacle_box", size_mm=[20, 20, 20])
        new_rbound = float(body.sim.mj_model.geom_rbound[gid])
        required_rbound = math.sqrt(10 * 10 * 3)
        check("precompiled collision bound covers resize",
              old_rbound >= required_rbound and new_rbound >= required_rbound,
              f"{old_rbound}->{new_rbound}")

    body.apply_lab_command(LabCommand(
        1, "spawn_sphere", {"id": "ball", "position_mm": [20, 5, 3], "size_mm": 4}))
    check("runtime sphere spawn", any(o["id"] == "ball" for o in body.lab_state()["objects"]))
    body.apply_lab_command(LabCommand(
        101, "spawn_box", {"id": "runtime_box", "position_mm": [24, -8, 4], "size_mm": [6, 6, 6]}))
    body.apply_lab_command(LabCommand(
        102, "spawn_wall", {"id": "runtime_wall", "position_mm": [30, 10, 7.5], "size_mm": [2, 18, 15]}))
    spawned = {o["id"]: o for o in body.lab_state()["objects"]}
    check("runtime box spawn", spawned.get("runtime_box", {}).get("shape") == "box")
    check("runtime wall spawn", spawned.get("runtime_wall", {}).get("shape") == "wall")
    for object_id in ("runtime_box", "runtime_wall"):
        obj = world.objects[object_id]
        _, gid, mocap_id = world._slot_ids[obj.slot]
        actual_pos = list(body.sim.mj_data.mocap_pos[mocap_id])
        check(f"{object_id} physical geom active",
              float(body.sim.mj_model.geom_rgba[gid, 3]) > 0.9 and
              all(abs(a - b) < 1e-9 for a, b in zip(actual_pos, obj.position_mm)),
              f"rgba={body.sim.mj_model.geom_rgba[gid].tolist()} pos={actual_pos}")

    # V5.1 real-backend proof: the render snapshot is read from the same live
    # MuJoCo owner state, and ray picking is semantic/read-only even though it
    # calls mj_forward before mj_ray to refresh derived transforms.
    v5_qpos_before = body.sim.mj_data.qpos.copy()
    v5_qvel_before = body.sim.mj_data.qvel.copy()
    v5_mocap_pos_before = body.sim.mj_data.mocap_pos.copy()
    v5_mocap_quat_before = body.sim.mj_data.mocap_quat.copy()
    v5_time_before = float(body.sim.mj_data.time)
    v5_revision_before = int(world.revision)
    v5_structure_revision_before = int(world.structure_revision)
    v5_state_before = copy.deepcopy(world.state())
    v5_events_before = copy.deepcopy(list(world.events))
    render_state = body.world_render_state()
    thorax_bid = world.force_body_ids["thorax"]
    live_thorax_pos = np.asarray(body.sim.mj_data.xpos[thorax_bid], dtype=float)
    live_thorax_wxyz = np.asarray(body.sim.mj_data.xquat[thorax_bid], dtype=float)
    live_thorax_xyzw = live_thorax_wxyz[[1, 2, 3, 0]]
    render_fly = render_state["fly"]
    render_objects = {obj["id"]: obj for obj in render_state["objects"]}
    runtime_box = world.objects["runtime_box"]
    _, runtime_box_gid, runtime_box_mocap = world._slot_ids[runtime_box.slot]
    live_box_pos = np.asarray(body.sim.mj_data.mocap_pos[runtime_box_mocap], dtype=float)
    live_box_wxyz = np.asarray(body.sim.mj_data.mocap_quat[runtime_box_mocap], dtype=float)
    live_box_xyzw = live_box_wxyz[[1, 2, 3, 0]]
    live_box_size = np.asarray(body.sim.mj_model.geom_size[runtime_box_gid, :3], dtype=float) * 2.0
    rendered_box = render_objects.get("runtime_box", {})
    check("V5 real snapshot uses live thorax full pose",
          render_state["world_revision"] == world.revision and
          np.allclose(render_fly["position_mm"], live_thorax_pos, atol=1e-12) and
          np.allclose(render_fly["orientation_quat_xyzw"], live_thorax_xyzw, atol=1e-12),
          f"snapshot={render_fly} live_pos={live_thorax_pos.tolist()} "
          f"live_quat={live_thorax_xyzw.tolist()}")
    check("V5 real snapshot object pose/size comes from live mocap/model",
          rendered_box.get("revision") == runtime_box.revision and
          np.allclose(rendered_box.get("position_mm", []), live_box_pos, atol=1e-12) and
          np.allclose(rendered_box.get("orientation_quat_xyzw", []), live_box_xyzw, atol=1e-12) and
          np.allclose(rendered_box.get("size_mm", []), live_box_size, atol=1e-12),
          f"snapshot={rendered_box} live_pos={live_box_pos.tolist()} "
          f"live_size={live_box_size.tolist()}")

    # V5.4 participant is a dedicated fly-scale free-joint sphere in this exact
    # compiled MuJoCo world. Inactive means hidden/non-colliding; activation is a
    # structural world change and snapshot visual pose comes from the live body.
    player = world.player
    player_gid = player.geom_id
    player_mass = float(body.sim.mj_model.body_mass[player.body_id])
    thorax_mass = float(body.sim.mj_model.body_mass[thorax_bid])
    player_mass_ratio = player_mass / thorax_mass
    check("V5.4 participant compiled mass stays fly-scale",
          math.isfinite(player_mass) and player_mass > 0.0
          and math.isfinite(thorax_mass) and thorax_mass > 0.0
          and 0.25 <= player_mass_ratio <= 4.0,
          f"player_mass={player_mass:.9g} thorax_mass={thorax_mass:.9g} ratio={player_mass_ratio:.3f}")
    check("V5.4 participant starts physically inactive",
          not player.active
          and float(body.sim.mj_model.geom_rgba[player_gid, 3]) == 0.0
          and int(body.sim.mj_model.geom_contype[player_gid]) == 0
          and render_state.get("player") is None)
    player_revision_before = world.revision
    player_structure_before = world.structure_revision
    player_result = world.set_player_active(True)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    player_render_state = body.world_render_state()
    player_pose = player_render_state.get("player") or {}
    live_player_pos = np.asarray(body.sim.mj_data.xpos[player.body_id], dtype=float)
    check("V5.4 active participant snapshot uses live collision pose/radius",
          player_result.get("player_active") is True
          and world.revision == player_revision_before + 1
          and world.structure_revision == player_structure_before + 1
          and player_pose.get("actor_id") == "player"
          and np.allclose(player_pose.get("position_mm", []), live_player_pos, atol=1e-12)
          and abs(player_pose.get("collision_radius_mm", -1) -
                  float(body.sim.mj_model.geom_size[player_gid, 0])) < 1e-12
          and player_pose.get("mode") == "participate",
          repr(player_pose))

    # Ray-picking the active participant must not fall through to generic world.
    player_ray_origin = live_player_pos + np.array([0.0, 0.0, 20.0])
    player_pick = body.ray_pick(player_ray_origin.tolist(), [0.0, 0.0, -1.0])
    check("V5.4 authoritative ray identifies participant geom",
          player_pick.get("hit") is True
          and player_pick.get("target_id") == "player"
          and player_pick.get("target_kind") == "player"
          and player_pick.get("geom_id") == player_gid,
          repr(player_pick))

    # Generic collidable LabObjects use the ordinary 1/1 collision masks rather
    # than an explicit pair. Put the active free-joint sphere just inside the
    # runtime box surface and verify MuJoCo generates that mask-based contact.
    object_contact_qpos = body.sim.mj_data.qpos.copy()
    object_contact_qvel = body.sim.mj_data.qvel.copy()
    object_contact_time = float(body.sim.mj_data.time)
    player_qpos = player.qpos_adr
    box_halfsize = np.asarray(body.sim.mj_model.geom_size[runtime_box_gid, :3], dtype=float)
    body.sim.mj_data.qpos[player_qpos:player_qpos + 3] = (
        live_box_pos + np.array([0.0, 0.0, box_halfsize[2] + player.radius_mm - 0.05])
    )
    body.sim.mj_data.qvel[player.dof_adr:player.dof_adr + 6] = 0.0
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    object_contact_pairs = {
        (int(body.sim.mj_data.contact[i].geom1), int(body.sim.mj_data.contact[i].geom2))
        for i in range(int(body.sim.mj_data.ncon))
    }
    player_contacts_runtime_box = any(
        {g1, g2} == {player_gid, runtime_box_gid}
        for g1, g2 in object_contact_pairs
    )
    check("V5.4 active participant collides with generic LabObject via masks",
          int(body.sim.mj_model.geom_contype[player_gid]) == 1
          and int(body.sim.mj_model.geom_conaffinity[player_gid]) == 1
          and int(body.sim.mj_model.geom_contype[runtime_box_gid]) == 1
          and int(body.sim.mj_model.geom_conaffinity[runtime_box_gid]) == 1
          and player_contacts_runtime_box,
          f"player_gid={player_gid} box_gid={runtime_box_gid} contacts={sorted(object_contact_pairs)}")
    body.sim.mj_data.qpos[:] = object_contact_qpos
    body.sim.mj_data.qvel[:] = object_contact_qvel
    body.sim.mj_data.time = object_contact_time
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)

    # Controlled contact proof: FlyGym normally disables generic fly-geom contact
    # and uses explicit pairs. V5.4 adds one explicit player<->thorax pair; move
    # the probe inward from just outside the thorax until the first shallow contact.
    compiled_player_pairs = [
        (int(body.sim.mj_model.pair_geom1[i]), int(body.sim.mj_model.pair_geom2[i]))
        for i in range(int(body.sim.mj_model.npair))
        if player_gid in (int(body.sim.mj_model.pair_geom1[i]),
                          int(body.sim.mj_model.pair_geom2[i]))
    ]
    thorax_collision_gid = -1
    for g1, g2 in compiled_player_pairs:
        other = g2 if g1 == player_gid else g1
        if int(body.sim.mj_model.geom_bodyid[other]) == thorax_bid:
            thorax_collision_gid = other
            break
    thorax_geom_pos = np.asarray(
        body.sim.mj_data.geom_xpos[thorax_collision_gid]
        if thorax_collision_gid >= 0 else live_thorax_pos, dtype=float).copy()
    contact_pairs = set()
    player_contacts_fly = False
    contact_offset = None
    contact_distance = None
    # Find the first contact while approaching along +Z so the response check
    # exercises a near-surface collision instead of an artificial deep overlap.
    for z_offset in np.arange(3.2, 1.95, -0.05):
        offset = [0.0, 0.0, float(z_offset)]
        world.set_player_pose(position_mm=(thorax_geom_pos + np.asarray(offset, dtype=float)).tolist())
        mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
        contact_pairs = {
            (int(body.sim.mj_data.contact[i].geom1), int(body.sim.mj_data.contact[i].geom2))
            for i in range(int(body.sim.mj_data.ncon))
        }
        player_contacts_fly = any(
            (g1 == player_gid and g2 == thorax_collision_gid) or
            (g2 == player_gid and g1 == thorax_collision_gid)
            for g1, g2 in contact_pairs
        )
        if player_contacts_fly:
            contact_offset = offset
            contact_distance = min(
                float(body.sim.mj_data.contact[i].dist)
                for i in range(int(body.sim.mj_data.ncon))
                if {int(body.sim.mj_data.contact[i].geom1), int(body.sim.mj_data.contact[i].geom2)}
                == {player_gid, thorax_collision_gid}
            )
            break
    check("V5.4 participant participates in real MuJoCo fly collision",
          thorax_collision_gid >= 0 and player_contacts_fly,
          f"ncon={body.sim.mj_data.ncon} player_gid={player_gid} thorax_gid={thorax_collision_gid} "
          f"compiled_pairs={compiled_player_pairs} offset={contact_offset} dist={contact_distance} "
          f"contacts={sorted(contact_pairs)}")

    # A free-joint participant must exchange a real impulse without behaving like
    # an effectively infinite-mass wall. Step only a few native ticks from the
    # shallow contact and require both bodies to stay finite and locally bounded.
    response_qpos = body.sim.mj_data.qpos.copy()
    response_qvel = body.sim.mj_data.qvel.copy()
    response_time = float(body.sim.mj_data.time)
    response_player_start = np.asarray(body.sim.mj_data.xpos[player.body_id], dtype=float).copy()
    response_thorax_start = np.asarray(body.sim.mj_data.xpos[thorax_bid], dtype=float).copy()
    for _ in range(10):
        mujoco.mj_step(body.sim.mj_model, body.sim.mj_data)
    response_player_end = np.asarray(body.sim.mj_data.xpos[player.body_id], dtype=float).copy()
    response_thorax_end = np.asarray(body.sim.mj_data.xpos[thorax_bid], dtype=float).copy()
    player_response_mm = float(np.linalg.norm(response_player_end - response_player_start))
    thorax_response_mm = float(np.linalg.norm(response_thorax_end - response_thorax_start))
    response_finite = (
        np.all(np.isfinite(body.sim.mj_data.qpos))
        and np.all(np.isfinite(body.sim.mj_data.qvel))
    )
    check("V5.4 calibrated participant contact response stays bounded",
          player_contacts_fly and response_finite
          and player_response_mm < 1.0 and thorax_response_mm < 1.0,
          f"player_delta={player_response_mm:.6f}mm thorax_delta={thorax_response_mm:.6f}mm")
    body.sim.mj_data.qpos[:] = response_qpos
    body.sim.mj_data.qvel[:] = response_qvel
    body.sim.mj_data.time = response_time
    world.reset_player_pose(preserve_active=True)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)

    # V5.5 real-backend proof: held movement is converted to mm/s and integrated
    # by the same exact simulation quantum as the fly, not by render callbacks.
    v55_player_start = np.asarray(world.render_player()["position_mm"], dtype=float)
    body.set_player_input(PlayerInputPacket(
        actor_id="player", session_id="real-v55", epoch=1, seq=1,
        requested_tick=0, move_axes=[1.0, 0.0], look_delta=[0.0, 0.0],
        held_actions=["interact"],
    ))
    v55_obs = body.step_exact(LocomotorCommand(forward=0.0), exact_substeps)
    v55_player_end = np.asarray(world.render_player()["position_mm"], dtype=float)
    v55_planar = float(np.linalg.norm((v55_player_end - v55_player_start)[:2]))
    v55_expected = PLAYER_MOVE_SPEED_MM_S * v55_obs.sim_dt
    check("V5.5 real participant movement uses simulation-time mm/s integration",
          abs(v55_obs.sim_dt - quantum_s) < 1e-12
          and abs(v55_planar - v55_expected) < 0.05
          and world.player.input_held_actions == ["interact"],
          f"moved={v55_planar:.6f}mm expected={v55_expected:.6f}mm sim_dt={v55_obs.sim_dt:.6f}")
    body.clear_player_input()
    world.reset_player_pose(preserve_active=True)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)

    # Same-owner-boundary regression: set_player_active() writes the free-joint
    # qpos immediately but does not call mj_forward. PlayerInput must therefore
    # base motion on qpos/internal owner state, not stale derived data.xpos.
    world.set_player_active(False)
    # Materialize the inactive far pose into derived xpos first. The following
    # activation intentionally does *not* forward, recreating the old stale-xpos
    # state exactly: qpos.x=24 while xpos.x=0.
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    world.reset_player_pose(preserve_active=False)
    world.set_player_active(True)
    stale_xpos_before = float(body.sim.mj_data.xpos[player.body_id, 0])
    authoritative_spawn_x = float(body.sim.mj_data.qpos[player.qpos_adr])
    body.set_player_input(PlayerInputPacket(
        actor_id="player", session_id="real-v55-boundary", epoch=1, seq=2,
        requested_tick=0, move_axes=[1.0, 0.0], look_delta=[0.0, 0.0],
        held_actions=[],
    ))
    same_boundary_obs = body.step_exact(LocomotorCommand(forward=0.0), exact_substeps)
    same_boundary_x = float(world.render_player()["position_mm"][0])
    check("V5.5 same-boundary activation+input uses free-joint qpos, not stale xpos",
          abs(stale_xpos_before) < 1e-12
          and abs(authoritative_spawn_x - 24.0) < 1e-12
          and abs(same_boundary_obs.sim_dt - quantum_s) < 1e-12
          and abs(same_boundary_x - 24.6) < 0.05
          and abs(same_boundary_x - (authoritative_spawn_x +
                                     PLAYER_MOVE_SPEED_MM_S * quantum_s)) < 0.05,
          f"stale_xpos={stale_xpos_before:.6f} spawn_qpos={authoritative_spawn_x:.6f} "
          f"end_x={same_boundary_x:.6f}")
    body.clear_player_input()
    world.reset_player_pose(preserve_active=True)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)

    # The legacy V5.1 read-only snapshot/pick invariant below should compare
    # against the stable world *after* the intentional V5.4 participant mutation.
    v5_qpos_before = body.sim.mj_data.qpos.copy()
    v5_qvel_before = body.sim.mj_data.qvel.copy()
    v5_mocap_pos_before = body.sim.mj_data.mocap_pos.copy()
    v5_mocap_quat_before = body.sim.mj_data.mocap_quat.copy()
    v5_time_before = float(body.sim.mj_data.time)
    v5_revision_before = int(world.revision)
    v5_structure_revision_before = int(world.structure_revision)
    v5_state_before = copy.deepcopy(world.state())
    v5_events_before = copy.deepcopy(list(world.events))
    render_state = body.world_render_state()

    pick_qpos_before = body.sim.mj_data.qpos.copy()
    pick_qvel_before = body.sim.mj_data.qvel.copy()
    pick_mocap_pos_before = body.sim.mj_data.mocap_pos.copy()
    pick_mocap_quat_before = body.sim.mj_data.mocap_quat.copy()
    pick_time_before = float(body.sim.mj_data.time)
    pick_revision_before = int(world.revision)
    pick_state_before = copy.deepcopy(world.state())
    pick_events_before = copy.deepcopy(list(world.events))
    ray_origin = live_box_pos + np.array([0.0, 0.0, 40.0])
    real_pick_hit = body.ray_pick(ray_origin.tolist(), [0.0, 0.0, -1.0])
    real_pick_miss = body.ray_pick(ray_origin.tolist(), [0.0, 0.0, 1.0])
    render_state_after_pick = body.world_render_state()
    pick_state_after = world.state()
    check("V5 real semantic ray hit/miss uses authoritative MuJoCo geometry",
          real_pick_hit.get("hit") is True and
          real_pick_hit.get("target_id") == "runtime_box" and
          real_pick_hit.get("target_kind") == "lab_object" and
          real_pick_hit.get("geom_id") == runtime_box_gid and
          math.isfinite(real_pick_hit.get("distance_mm", math.nan)) and
          len(real_pick_hit.get("point_mm", [])) == 3 and
          len(real_pick_hit.get("normal_world", [])) == 3 and
          real_pick_miss == {"hit": False},
          f"hit={real_pick_hit} miss={real_pick_miss}")
    check("V5 real ray hit/miss does not mutate owner physics/world state",
          np.array_equal(body.sim.mj_data.qpos, pick_qpos_before) and
          np.array_equal(body.sim.mj_data.qvel, pick_qvel_before) and
          np.array_equal(body.sim.mj_data.mocap_pos, pick_mocap_pos_before) and
          np.array_equal(body.sim.mj_data.mocap_quat, pick_mocap_quat_before) and
          float(body.sim.mj_data.time) == pick_time_before and
          int(world.revision) == pick_revision_before and
          pick_state_after == pick_state_before and
          list(world.events) == pick_events_before,
          f"revision={pick_revision_before}->{world.revision} time={pick_time_before}->{body.sim.mj_data.time}")
    check("V5 snapshot/pick same-tick refresh is stable and trajectory/world read-only",
          render_state_after_pick == render_state and
          np.array_equal(body.sim.mj_data.qpos, v5_qpos_before) and
          np.array_equal(body.sim.mj_data.qvel, v5_qvel_before) and
          np.array_equal(body.sim.mj_data.mocap_pos, v5_mocap_pos_before) and
          np.array_equal(body.sim.mj_data.mocap_quat, v5_mocap_quat_before) and
          float(body.sim.mj_data.time) == v5_time_before and
          int(world.revision) == v5_revision_before and
          int(world.structure_revision) == v5_structure_revision_before and
          world.state() == v5_state_before and
          list(world.events) == v5_events_before,
          f"time={v5_time_before}->{body.sim.mj_data.time} "
          f"revision={v5_revision_before}->{world.revision} "
          f"structure={v5_structure_revision_before}->{world.structure_revision}")

    # Place food relative to the *actual* current thorax pose rather than the
    # nominal spawn origin. This exercises the complete RealFlyBody -> LabWorld
    # odor observation path even if warmup has shifted/rotated the fly slightly.
    food_origin = np.asarray(body._thorax_position(), dtype=float)
    food_heading_vec = np.asarray(body._heading()[:2], dtype=float)
    food_heading_vec /= max(1e-12, np.linalg.norm(food_heading_vec))
    food_left_vec = np.array([-food_heading_vec[1], food_heading_vec[0]])
    food_position = food_origin.copy()
    food_position[:2] += 10.0 * food_left_vec
    body.apply_lab_command(LabCommand(
        11, "spawn_food", {"id": "food", "position_mm": food_position.tolist(), "size_mm": 2}))

    body.apply_lab_command(LabCommand(
        2, "wind", {"strength": 0.2, "direction_deg": 90, "duration_ms": 20}))
    body.apply_lab_command(LabCommand(
        3, "touch", {"target": "thorax", "strength": 0.1, "duration_ms": 5}))
    obs = body.step(LocomotorCommand(forward=0.0), 0.01)
    thorax_id = world.force_body_ids["thorax"]
    force = body.sim.mj_data.xfrc_applied[thorax_id, :3]
    check("physical wind/touch reaches xfrc_applied", float(abs(force).sum()) > 0.0, repr(force))
    check("real body packet remains finite", math.isfinite(obs.vx) and math.isfinite(obs.yaw_rate))
    check("real body packet exposes sim/wall timing",
          obs.sim_dt > 0.0 and abs(obs.wall_dt - 0.01) < 1e-12 and
          abs(obs.sim_wall_ratio - obs.sim_dt / obs.wall_dt) < 1e-12,
          f"sim_dt={obs.sim_dt:.6f} wall_dt={obs.wall_dt:.6f} ratio={obs.sim_wall_ratio:.3f}")
    check("real food reaches finite bounded body odor telemetry",
          math.isfinite(obs.odor_left) and math.isfinite(obs.odor_right) and
          0.0 <= obs.odor_left <= 1.0 and 0.0 <= obs.odor_right <= 1.0 and
          max(obs.odor_left, obs.odor_right) > 0.0 and
          obs.nearest_food_distance_mm is not None and
          math.isfinite(obs.nearest_food_distance_mm) and
          0.0 < obs.nearest_food_distance_mm < 25.0,
          f"odor=({obs.odor_left:.3f},{obs.odor_right:.3f}) d={obs.nearest_food_distance_mm}")
    check("real left-relative food produces left-dominant odor",
          obs.odor_left > obs.odor_right,
          f"odor=({obs.odor_left:.3f},{obs.odor_right:.3f})")
    check("real body heading telemetry is finite",
          math.isfinite(obs.heading_rad) and -math.pi <= obs.heading_rad <= math.pi,
          f"heading={obs.heading_rad}")
    thorax_now = np.asarray(body._thorax_position(), dtype=float)
    check("real body packet exposes absolute fly X/Y for arena map",
          math.isfinite(obs.position_x_mm) and math.isfinite(obs.position_y_mm) and
          abs(obs.position_x_mm - thorax_now[0]) < 1e-9 and
          abs(obs.position_y_mm - thorax_now[1]) < 1e-9,
          f"packet=({obs.position_x_mm:.3f},{obs.position_y_mm:.3f}) "
          f"thorax=({thorax_now[0]:.3f},{thorax_now[1]:.3f})")
    body.apply_lab_command(LabCommand(12, "delete_object", {"id": "food"}))
    no_food_obs = body.step(LocomotorCommand(forward=0.0), 0.01)
    check("removing real food clears odor telemetry",
          no_food_obs.odor_left == 0.0 and no_food_obs.odor_right == 0.0 and
          no_food_obs.nearest_food_distance_mm is None,
          f"odor=({no_food_obs.odor_left:.3f},{no_food_obs.odor_right:.3f}) d={no_food_obs.nearest_food_distance_mm}")

    loom_before = (body.vision_state["loom_left"], body.vision_state["loom_right"])
    body.apply_lab_command(LabCommand(
        4, "flash_eye", {"eye": "left", "intensity": 0.8, "duration_ms": 100}))
    flash_obs = body.step(LocomotorCommand(forward=0.0), 0.01)
    check("flash reports left-eye brightness",
          body.vision_state["brightness_left"] >= 0.8 and body.vision_state["flash_left"] == 0.8,
          repr(body.vision_state))
    check("flash reaches body telemetry packet",
          flash_obs.flash_left == 0.8 and flash_obs.flash_right == 0.0 and
          flash_obs.brightness_left >= 0.8,
          f"flash=({flash_obs.flash_left},{flash_obs.flash_right}) brightness={flash_obs.brightness_left}")
    # The unit test proves augment_vision_state preserves exact input looming;
    # here ensure the real path did not synthesize an out-of-range flash loom.
    check("flash keeps loom bounded", 0.0 <= body.vision_state["loom_left"] <= 1.0 and
          0.0 <= body.vision_state["loom_right"] <= 1.0,
          f"before={loom_before} after={(body.vision_state['loom_left'], body.vision_state['loom_right'])}")

    ball = world.objects["ball"]
    before_reset = list(ball.position_mm)
    player_spawn = np.asarray(world.player.spawn_position_mm, dtype=float)
    player_away = player_spawn + np.array([7.0, -4.0, 3.0])
    world.set_player_pose(position_mm=player_away.tolist())
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    active_player_before_reset = np.asarray(
        world.player.render_pose()["position_mm"], dtype=float)
    player_reset_revision_before = int(world.revision)
    player_reset_structure_before = int(world.structure_revision)
    body.apply_lab_command(LabCommand(5, "reset_body", {}))
    _, _, ball_mocap = world._slot_ids[ball.slot]
    actual_after_reset = list(body.sim.mj_data.mocap_pos[ball_mocap])
    check("reset_body resets protocol time", body.t == 0.0)
    check("reset_body preserves world object",
          "ball" in world.objects and all(abs(a - b) < 1e-9 for a, b in zip(actual_after_reset, before_reset)),
          f"actual={actual_after_reset} expected={before_reset}")
    check("V5.4 reset_body keeps active participant authoritative and resynced",
          world.player.active
          and world.player.render_pose() is not None
          and not np.allclose(active_player_before_reset, player_spawn, atol=1e-12)
          and np.allclose(world.player.render_pose()["position_mm"], player_spawn, atol=1e-12)
          and int(world.revision) > player_reset_revision_before
          and int(world.structure_revision) == player_reset_structure_before
          and float(body.sim.mj_model.geom_rgba[world.player.geom_id, 3]) > 0.9,
          f"before={active_player_before_reset.tolist()} after={world.player.render_pose()} "
          f"spawn={player_spawn.tolist()} revision={player_reset_revision_before}->{world.revision} "
          f"structure={player_reset_structure_before}->{world.structure_revision}")

    # Hidden reset settling must not consume the experiment's timed physical
    # stimuli. Those durations advance only with normal protocol-visible MuJoCo
    # simulation time.
    body.apply_lab_command(LabCommand(
        20, "wind", {"strength": 0.25, "direction_deg": 0,
                     "duration_ms": 40, "continuous": False}))
    body.apply_lab_command(LabCommand(
        21, "touch", {"target": "thorax", "strength": 0.1, "duration_ms": 40}))
    source_obs = body.step(LocomotorCommand(forward=0.0), 0.0001)
    check("real body packet exposes active LabWorld wind/touch source state",
          abs(source_obs.wind_strength - 0.25) < 1e-12 and source_obs.wind_sensory and
          abs(source_obs.touch_strength - 0.1) < 1e-12 and source_obs.touch_sensory,
          f"wind=({source_obs.wind_strength},{source_obs.wind_sensory}) "
          f"touch=({source_obs.touch_strength},{source_obs.touch_sensory})")
    wind_before_reset = world.state()["wind"]["remaining_ms"]
    touch_before_reset = world.state()["touch"]["remaining_ms"]
    body.apply_lab_command(LabCommand(22, "reset_body", {}))
    wind_after_reset = world.state()["wind"]["remaining_ms"]
    touch_after_reset = world.state()["touch"]["remaining_ms"]
    check("reset_body settle preserves timed wind",
          abs(wind_after_reset - wind_before_reset) < 1e-9,
          f"before={wind_before_reset:.3f}ms after={wind_after_reset:.3f}ms")
    check("reset_body settle preserves timed touch",
          abs(touch_after_reset - touch_before_reset) < 1e-9,
          f"before={touch_before_reset:.3f}ms after={touch_after_reset:.3f}ms")

    body.vision_period = 999.0
    body.vision_elapsed = 0.0
    timed_start = body.t
    timed_end = None
    for _ in range(100):
        timed_obs = body.step(LocomotorCommand(forward=0.0), 1.0 / 60.0)
        timed_state = world.state()
        if timed_state["wind"]["strength"] == 0.0 and timed_state["touch"] is None:
            timed_end = timed_obs.t
            break
    timed_elapsed = None if timed_end is None else timed_end - timed_start
    # The physical timers advance every 0.1 ms MuJoCo substep. Their completion
    # is only observable to the caller at the end of a body-feedback chunk, so
    # packet-level observation may overshoot by at most one final sim_dt but must
    # never report completion before the requested 40 ms.
    check("timed wind/touch do not expire early and packet overshoot is bounded",
          timed_elapsed is not None and timed_elapsed >= 0.040 and
          (timed_elapsed - 0.040) <= timed_obs.sim_dt + 1e-9,
          f"elapsed={timed_elapsed} final_sim_dt={timed_obs.sim_dt}")
    check("real body packet clears expired LabWorld wind/touch source state",
          timed_obs.wind_strength == 0.0 and timed_obs.touch_strength == 0.0
          and not timed_obs.touch_sensory,
          f"wind={timed_obs.wind_strength} touch=({timed_obs.touch_strength},{timed_obs.touch_sensory})")

    # modeled_physiology reaches the real controller through BrainPacket.tempo.
    # HybridTurningController rewrites live CPG frequencies from its base array
    # each substep, so checking both values proves the tempo is not desktop-only.
    tempo_cmd = LocomotorCommand(forward=0.5, moving=True)
    body.step(tempo_cmd, 1.0 / 60.0, tempo=1.4)
    controller_state = body.lab_state()["controller"]
    if body.controller_tempo_supported:
        baseline_freq = float(np.mean(np.abs(body._base_cpg_freqs)))
        live_freq = float(np.mean(np.abs(body.ctl.cpg_network.intrinsic_freqs)))
        tempo_ratio = live_freq / max(1e-12, baseline_freq)
    else:
        tempo_ratio = 0.0
    check("real controller applies modeled physiology tempo",
          body.controller_tempo_supported and abs(tempo_ratio - 1.4) < 1e-9 and
          controller_state["tempo_supported"] and abs(controller_state["tempo_applied"] - 1.4) < 1e-12,
          f"ratio={tempo_ratio:.3f} state={controller_state}")

    # Performance decimation may hold actuator targets, but the oscillator clock
    # itself must still tick exactly once per native MuJoCo physics substep.
    original_cpg_step = body.ctl.cpg_network.step
    cpg_step_count = [0]
    def counted_cpg_step():
        cpg_step_count[0] += 1
        return original_cpg_step()
    body.ctl.cpg_network.step = counted_cpg_step
    try:
        cpg_obs = body.step(LocomotorCommand(forward=0.4), 0.005)
    finally:
        body.ctl.cpg_network.step = original_cpg_step
    expected_cpg_steps = int(round(cpg_obs.sim_dt / body.sim.timestep))
    check("CPG advances once per MuJoCo substep under action decimation",
          cpg_step_count[0] == expected_cpg_steps,
          f"cpg_steps={cpg_step_count[0]} physics_steps={expected_cpg_steps} "
          f"action_stride={body.controller_action_stride}")

    # V5.3 raw-eye provenance: only a successful actual FlyGym stereo render
    # advances eye_sample_sim_tick. Later body packets may carry decayed vision
    # values but must keep the exact last raw-frame tick.
    body.vision_elapsed = body.vision_period
    body.eye_sample_sim_tick = None
    eye_sample_obs = body.step(LocomotorCommand(forward=0.0), 1.0 / 60.0)
    first_eye_tick = eye_sample_obs.eye_sample_sim_tick
    check("V5.3 actual eye render carries exact protocol simulation tick",
          first_eye_tick == int(round(eye_sample_obs.t * 1000.0)),
          f"eye_tick={first_eye_tick} body_t={eye_sample_obs.t}")
    body.vision_elapsed = 0.0
    held_eye_obs = body.step(LocomotorCommand(forward=0.0), 1.0 / 60.0)
    check("V5.3 body packet holds raw-eye sample tick between renders",
          held_eye_obs.eye_sample_sim_tick == first_eye_tick
          and body.vision_elapsed < body.vision_period,
          f"eye_tick={held_eye_obs.eye_sample_sim_tick} elapsed={body.vision_elapsed:.6f}")

    # A failed scheduled render must not claim the current body tick as a new raw
    # frame. Keep provenance pointed at the last successful sample instead.
    body.vision_elapsed = body.vision_period
    with mock.patch.object(body.sim, "get_raw_vision",
                           side_effect=RuntimeError("forced V5.3 eye render failure")):
        failed_eye_obs = body.step(LocomotorCommand(forward=0.0), 1.0 / 60.0)
    check("V5.3 failed eye render preserves last successful sample tick",
          failed_eye_obs.eye_sample_sim_tick == first_eye_tick
          and failed_eye_obs.eye_sample_sim_tick != int(round(failed_eye_obs.t * 1000.0)),
          f"eye_tick={failed_eye_obs.eye_sample_sim_tick} body_t={failed_eye_obs.t}")

    body.reset_body()
    check("V5.3 reset clears raw-eye sample provenance",
          body.eye_sample_sim_tick is None,
          f"eye_tick={body.eye_sample_sim_tick}")

    # Approach motion and vision cadence must share actual MuJoCo simulation time
    # even when the caller/wall interval is much larger than the capped sim chunk.
    world.reset()
    approach_origin = np.asarray(body._thorax_position(), dtype=float)
    approach_heading = np.asarray(body._heading()[:2], dtype=float)
    approach_heading /= max(1e-12, np.linalg.norm(approach_heading))
    approach_pos = approach_origin.copy()
    approach_pos[:2] += 20.0 * approach_heading
    world.spawn_object(shape="food", object_id="timing_food",
                       position_mm=approach_pos.tolist(), size_mm=2)
    world.start_approach("timing_food", fly_position_mm=approach_origin,
                         end_distance_mm=5.0, speed_mm_s=50.0)
    position_before = np.asarray(world.objects["timing_food"].position_mm[:2], dtype=float)
    body.vision_period = 999.0
    body.vision_elapsed = 0.0
    approach_obs = body.step(LocomotorCommand(forward=0.0), 0.05)
    position_after = np.asarray(world.objects["timing_food"].position_mm[:2], dtype=float)
    approach_moved = float(np.linalg.norm(position_after - position_before))
    expected_moved = 50.0 * approach_obs.sim_dt
    check("approach advances by actual body sim time",
          abs(approach_moved - expected_moved) < 1e-6,
          f"moved={approach_moved:.6f} expected={expected_moved:.6f} sim_dt={approach_obs.sim_dt:.6f}")
    check("vision cadence accumulates actual body sim time",
          abs(body.vision_elapsed - approach_obs.sim_dt) < 1e-12 and approach_obs.sim_dt < approach_obs.wall_dt,
          f"vision_elapsed={body.vision_elapsed:.6f} sim_dt={approach_obs.sim_dt:.6f} wall_dt={approach_obs.wall_dt:.6f}")

    # Reset-world removes any force that this backend had already contributed,
    # and discards pre-reset events so the next state generation is clean.
    world.set_wind(strength=0.4, direction_deg=0, continuous=True)
    world.apply_touch(target="thorax", strength=0.15, duration_ms=50)
    body.step(LocomotorCommand(forward=0.0), 1.0 / 60.0)
    force_before_world_reset = np.asarray(body.sim.mj_data.xfrc_applied[thorax_id, :3], dtype=float).copy()
    world.reset()
    force_after_world_reset = np.asarray(body.sim.mj_data.xfrc_applied[thorax_id, :3], dtype=float).copy()
    check("reset_world immediately clears backend-applied forces",
          float(np.linalg.norm(force_before_world_reset)) > 0.0 and
          float(np.linalg.norm(force_after_world_reset)) < 1e-12,
          f"before={force_before_world_reset.tolist()} after={force_after_world_reset.tolist()}")
    check("reset_world drops pre-reset real events", world.drain_events() == [])

    # World reset must remove every odor source and the next real observation
    # must immediately return the protocol's no-source values.
    reset_food_origin = np.asarray(body._thorax_position(), dtype=float)
    body.apply_lab_command(LabCommand(
        13, "spawn_food", {"id": "reset_food",
                            "position_mm": (reset_food_origin + np.array([5.0, 0.0, 0.0])).tolist(),
                            "size_mm": 2}))
    pre_reset_food_obs = body.step(LocomotorCommand(forward=0.0), 0.01)
    check("food exists before reset_world smoke",
          max(pre_reset_food_obs.odor_left, pre_reset_food_obs.odor_right) > 0.0 and
          pre_reset_food_obs.nearest_food_distance_mm is not None)
    body.apply_lab_command(LabCommand(14, "reset_world", {}))
    reset_world_obs = body.step(LocomotorCommand(forward=0.0), 0.01)
    check("reset_world clears real food odor telemetry",
          reset_world_obs.odor_left == 0.0 and reset_world_obs.odor_right == 0.0 and
          reset_world_obs.nearest_food_distance_mm is None,
          f"odor=({reset_world_obs.odor_left:.3f},{reset_world_obs.odor_right:.3f}) "
          f"d={reset_world_obs.nearest_food_distance_mm}")
    check("reset_world clears real wind/touch source telemetry",
          reset_world_obs.wind_strength == 0.0 and reset_world_obs.touch_strength == 0.0
          and not reset_world_obs.touch_sensory,
          f"wind={reset_world_obs.wind_strength} touch={reset_world_obs.touch_strength}")

    # Physical wind calibration: after the timebase/throughput repair, a normal
    # strength-0.7 puff should produce body-scale-measurable displacement rather
    # than disappearing into passive drift. Compare deterministic reset trials;
    # this asserts physics response only, never a neural/behavioral command.
    def wind_trial(enabled):
        body.reset_body()
        body.vision_period = 999.0
        p0 = np.asarray(body._thorax_position()[:2], dtype=float).copy()
        if enabled:
            world.set_wind(strength=0.7, direction_deg=0, continuous=True,
                           physical=True, sensory=False)
        else:
            world.stop_wind()
        for _ in range(30):
            body.step(LocomotorCommand(forward=0.0, moving=False), 1.0 / 60.0)
        p1 = np.asarray(body._thorax_position()[:2], dtype=float).copy()
        world.stop_wind()
        return p1 - p0

    baseline_wind_delta = wind_trial(False)
    physical_wind_delta = wind_trial(True)
    extra_wind = physical_wind_delta - baseline_wind_delta
    check("calibrated physical wind exceeds passive drift",
          float(np.linalg.norm(extra_wind)) > 0.10 and extra_wind[0] > 0.08,
          f"baseline={baseline_wind_delta.tolist()} wind={physical_wind_delta.tolist()} "
          f"extra={extra_wind.tolist()}")

    # Regression for the real locomotor adapter.  Observation extraction may be
    # decimated for performance, but the CPG itself must advance every MuJoCo
    # substep.  Otherwise a strong forward command barely moves the fly.
    body.vision_period = 999.0  # this test is locomotion-only; avoid eye-render cost
    start_xy = np.asarray(body._thorax_position()[:2], dtype=float).copy()
    start_heading = np.asarray(body._heading()[:2], dtype=float).copy()
    start_heading /= max(1e-12, np.linalg.norm(start_heading))
    forward_cmd = LocomotorCommand(forward=0.7, moving=True)
    forward_vx = []
    forward_obs = None
    for _ in range(300):
        forward_obs = body.step(forward_cmd, 1.0 / 60.0)
        forward_vx.append(forward_obs.vx)
    delta_xy = np.asarray(body._thorax_position()[:2], dtype=float) - start_xy
    forward_mm = float(np.dot(delta_xy, start_heading))
    check("real forward command produces locomotion",
          forward_mm > 0.5 and max(abs(v) for v in forward_vx) > 0.0005,
          f"forward_mm={forward_mm:.3f} peak_vx={1000*max(abs(v) for v in forward_vx):.3f} mm/s")
    expected_controller = body.last_cmd
    check("real body packet exposes exact controller L/R",
          forward_obs is not None and
          abs(forward_obs.controller_left - expected_controller[0]) < 1e-12 and
          abs(forward_obs.controller_right - expected_controller[1]) < 1e-12,
          f"packet=({forward_obs.controller_left if forward_obs else None},"
          f"{forward_obs.controller_right if forward_obs else None}) expected={expected_controller}")
finally:
    body.close()

print("ALL REAL LAB TESTS PASS" if not fails else f"{len(fails)} FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
