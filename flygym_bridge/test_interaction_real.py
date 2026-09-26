"""V5.6 MuJoCo interaction acceptance; local process, no TCP listener.

Run: NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_interaction_real.py
"""
import math
import os
import statistics
import sys
import time

import mujoco

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand
from protocol import LabCommand, PlayerInputPacket

failures = []


def check(name, condition, detail=""):
    print(("PASS" if condition else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""), flush=True)
    if not condition:
        failures.append(name)


body = RealFlyBody(config={}, show_viewer=False)
world = body.lab_world
model, data = body.sim.mj_model, body.sim.mj_data
idle = LocomotorCommand(forward=0)
sequence = 0


def cmd(tool, **args):
    global sequence
    sequence += 1
    return LabCommand(seq=sequence, op="interaction", args={
        "tool_id": tool, "actor_id": "player", **args})


def player_at(x, y=0, z=2.5):
    world.set_player_pose(position_mm=[x, y, z])
    mujoco.mj_forward(model, data)


def fresh_player(x=12, y=0, z=2.5):
    world.reset()
    world.set_player_active(True)
    player_at(x, y, z)


def expect_error(prefix, command):
    before = world.interaction.held_object_id
    try:
        body.apply_lab_command(command)
        error = "no rejection"
    except ValueError as exc:
        error = str(exc)
    check(prefix, error.startswith(prefix) and world.interaction.held_object_id == before, error)


# The backend ray excludes the participant body, so a ray originating inside it
# can hit the actual nearby object and the measured surface distance is used.
fresh_player()
world.spawn_object(shape="sphere", object_id="grabbed", position_mm=[20, 0, 2.5], size_mm=2)
ray = body.ray_pick([12, 0, 2.5], [1, 0, 0], exclude_player=True)
grab = body.apply_lab_command(cmd("grab", ray_origin_mm=[12, 0, 2.5],
                                  ray_direction=[1, 0, 0], id="grabbed"))
check("real backend ray grab", ray["hit"] and ray["target_id"] == "grabbed" and
      grab["held_object_id"] == "grabbed" and abs(grab["last"]["hit_distance_mm"] - 7) < 0.05,
      f"ray={ray['distance_mm']:.3f}mm")
check("grab event has simulation tick", any(
    e["event"] == "object_grabbed" and isinstance(e.get("sim_tick_ms"), int)
    for e in world.drain_events()))

# Track the actual per-native-step mocap displacement, independent of the
# command's requested distance and without reading the speed constant.
movement = []
original_step = body.sim.step
previous_position = tuple(world.objects["grabbed"].position_mm)


def sampled_step(*args, **kwargs):
    global previous_position
    out = original_step(*args, **kwargs)
    after = tuple(world.objects["grabbed"].position_mm)
    movement.append(math.dist(previous_position, after))
    previous_position = after
    return out


body.sim.step = sampled_step
body.step_exact(idle, 100)
body.sim.step = original_step
check("native substep carry speed <= 40 mm/s", movement and max(movement) > 0 and
      max(movement) <= 40.0 * body.physics_timestep_s + 1e-6 and
      abs(world.objects["grabbed"].position_mm[2] - 2.5) < 1e-9,
      f"max={max(movement) if movement else float('nan'):.6f}mm/substep")

body.apply_lab_command(cmd("place"))
placed_at = tuple(world.objects["grabbed"].position_mm)
body.step_exact(idle, 200)
check("placed object stays still", math.dist(placed_at, world.objects["grabbed"].position_mm) < 1e-9)

world.reset()
world.reset_player_pose(preserve_active=False)
world.set_player_active(True)
world.set_player_pose(position_mm=[-12, 0, 2.5])  # deliberately no mj_forward
stale_xpos = tuple(float(v) for v in data.xpos[world.player.body_id])
world.spawn_object(shape="sphere", object_id="same_boundary",
                   position_mm=[-6, 0, 2.5], size_mm=2)
same_boundary = body.apply_lab_command(cmd("grab", ray_origin_mm=[-12, 0, 2.5],
                                           ray_direction=[1, 0, 0], id="same_boundary"))
check("same-boundary activation/grab reads fresh qpos", math.dist(stale_xpos, [-12, 0, 2.5]) > 1 and
      same_boundary["held_object_id"] == "same_boundary",
      f"stale_xpos={stale_xpos}")

fresh_player()
world.spawn_object(shape="sphere", object_id="far", position_mm=[30, 0, 2.5], size_mm=2)
expect_error("out_of_reach", cmd("grab", ray_origin_mm=[12, 0, 2.5],
                                  ray_direction=[1, 0, 0]))

fresh_player()
world.spawn_object(shape="food", object_id="food_payload", position_mm=[20, 0, 2.5], size_mm=2)
food_hit = body.ray_pick([12, 0, 2.5], [1, 0, 0], exclude_player=True)
food_grab = body.apply_lab_command(cmd("grab", ray_origin_mm=[12, 0, 2.5],
                                       ray_direction=[1, 0, 0], id="food_payload"))
check("noncolliding food remains grabbable", food_hit.get("target_id") == "food_payload" and
      food_grab["held_object_id"] == "food_payload" and
      model.geom_contype[world._slot_ids[world.objects["food_payload"].slot][1]] == 0)
body.apply_lab_command(cmd("place"))

fresh_player(20, 20)
world_ray = body.ray_pick([20, 20, 2.5], [0, 0, -1], exclude_player=True)
expect_error("unsupported_target", cmd("grab", ray_origin_mm=[20, 20, 2.5],
                                         ray_direction=[0, 0, -1]))
check("world ray classified from real geom", world_ray.get("target_kind") == "world",
      str(world_ray.get("target_kind")))

fresh_player(0.5, 0, 3.5)
fly_ray = body.ray_pick([0.5, 0, 3.5], [0, 0, -1], exclude_player=True)
expect_error("unsupported_target", cmd("grab", ray_origin_mm=[0.5, 0, 3.5],
                                         ray_direction=[0, 0, -1]))
check("fly ray classified from real geom", fly_ray.get("target_kind") == "fly",
      str(fly_ray.get("target_kind")))

# Wall: move the player in small geometric increments while the carried sphere
# follows. Sample the real wall contact before the carry rollback is applied.
fresh_player(12)
world.spawn_object(shape="sphere", object_id="wall_payload",
                   position_mm=[20, 0, 2.5], size_mm=2)
world.spawn_object(shape="wall", object_id="barrier",
                   position_mm=[24.5, 0, 5], size_mm=[1, 20, 10])
body.apply_lab_command(cmd("grab", ray_origin_mm=[12, 0, 2.5],
                           ray_direction=[1, 0, 0], id="wall_payload"))
wall_gid = world._slot_ids[world.objects["barrier"].slot][1]
payload_gid = world._slot_ids[world.objects["wall_payload"].slot][1]
penetrations = []


def wall_sample_step(*args, **kwargs):
    out = original_step(*args, **kwargs)
    signed_distance = mujoco.mj_geomDistance(model, data, wall_gid, payload_gid, 1e6, None)
    if signed_distance < 0:
        penetrations.append(-float(signed_distance))
    return out


body.sim.step = wall_sample_step
body.step_exact(idle, 200)
for x in [12 + 0.5 * i for i in range(1, 17)]:
    player_at(x)
    body.step_exact(idle, 200)
body.sim.step = original_step
wall_events = world.drain_events()
worst = max(penetrations, default=0.0)
# Pre-step constraints stop the payload CARRY_CONTACT_SKIN_MM short of the wall;
# the post-step guard bound (tolerance + one step) is the ceiling either way.
check("wall blocks carried sphere with <= tolerance + one step",
      worst <= 0.05 + 40.0 * body.physics_timestep_s + 0.005 and
      world.objects["wall_payload"].position_mm[0] < 23.1 and
      any(e["event"] == "carry_blocked" and e["blocking_geom_kind"] == "lab_object"
          for e in wall_events), f"worst={worst:.6f}mm, x={world.objects['wall_payload'].position_mm[0]:.3f}")

# An already buried box may slide along the floor. The previous overlap is
# measured on grab; a horizontal move must not be rejected for that overlap.
fresh_player(4)
world.spawn_object(shape="box", object_id="buried", position_mm=[16, 0, 4.5],
                   size_mm=[10, 10, 10])
body.apply_lab_command(cmd("grab", ray_origin_mm=[4, 0, 2.5],
                           ray_direction=[1, 0, 0], id="buried"))
buried_gid = world._slot_ids[world.objects["buried"].slot][1]
ground_gid = world._ground_geom_ids[0]
initial_ground = mujoco.mj_geomDistance(model, data, buried_gid, ground_gid, 1e6, None)
for _ in range(10):
    body.step_exact(idle, 200)
buried_x = world.objects["buried"].position_mm[0]
check("buried box carries horizontally without deeper ground penetration",
      initial_ground < -0.05 and buried_x < 15.5 and not world.interaction.carry_blocked,
      f"ground={initial_ground:.3f}mm, x=16.000->{buried_x:.3f}, "
      f"blocked={world.interaction.carry_blocked}")

# The same initial ground overlap must not exempt a new wall penetration.
fresh_player(4)
world.spawn_object(shape="box", object_id="buried_wall", position_mm=[16, 0, 4.5],
                   size_mm=[10, 10, 10])
body.apply_lab_command(cmd("grab", ray_origin_mm=[4, 0, 2.5],
                           ray_direction=[1, 0, 0], id="buried_wall"))
# The carry pulls the box from x=16 toward the participant's hold radius
# (x~14.07); a wall with faces at x=9.5..10.5 crosses that path clear of the
# participant, so the box's back face must stop at x~10.5 (centre ~15.5).
world.spawn_object(shape="wall", object_id="buried_barrier",
                   position_mm=[10, 0, 5], size_mm=[1, 20, 10])
for _ in range(10):
    body.step_exact(idle, 200)
buried_wall_x = world.objects["buried_wall"].position_mm[0]
buried_wall_distance = mujoco.mj_geomDistance(
    model, data, world._slot_ids[world.objects["buried_wall"].slot][1],
    world._slot_ids[world.objects["buried_barrier"].slot][1], 1e6, None)
check("buried box still stops at wall",
      15.44 <= buried_wall_x < 15.51 and buried_wall_distance >= -0.055 and
      world.interaction.carry_blocked and
      world.interaction.blocking_geom_kind == "lab_object",
      f"x={buried_wall_x:.3f}, wall_distance={buried_wall_distance:.4f}, "
      f"blocked={world.interaction.carry_blocked}")

# Start inside another LabObject, move outward, then reverse while still
# overlapping. Only the reverse motion should be blocked.
fresh_player(12)
world.spawn_object(shape="sphere", object_id="overlap_payload",
                   position_mm=[20, 0, 2.5], size_mm=4)
body.apply_lab_command(cmd("grab", ray_origin_mm=[12, 0, 2.5],
                           ray_direction=[1, 0, 0], id="overlap_payload"))
world.spawn_object(shape="sphere", object_id="overlap_neighbor",
                   position_mm=[22, 0, 2.5], size_mm=4)
body.step_exact(idle, 200)
outward_x = world.objects["overlap_payload"].position_mm[0]
outward_blocked = world.interaction.carry_blocked
player_at(16)
body.step_exact(idle, 200)
reverse_x = world.objects["overlap_payload"].position_mm[0]
check("initial object overlap can decrease but cannot deepen",
      outward_x < 20 and not outward_blocked and
      abs(reverse_x - outward_x) < 1e-6 and
      world.interaction.carry_blocked and
      world.interaction.blocking_geom_kind == "lab_object",
      f"outward_x={outward_x:.3f}, reverse_x={reverse_x:.3f}, "
      f"blocked={world.interaction.carry_blocked}")

# Negative control: the same sphere travels immediately beside the fly but
# with a visible lateral gap. Contact must be absent in actual mjData/events.
def carry_past_fly(y, name):
    fresh_player(-12, y)
    world.spawn_object(shape="sphere", object_id=name,
                       position_mm=[-6, y, 2.5], size_mm=4)
    body.apply_lab_command(cmd("grab", ray_origin_mm=[-12, y, 2.5],
                               ray_direction=[1, 0, 0], id=name))
    body.step_exact(idle, 200)
    for x in [-11.5 + 0.5 * i for i in range(12)]:
        player_at(x, y)
        body.step_exact(idle, 200)
    events = world.drain_events()
    return events, world.objects[name].position_mm[:]


control_events, control_pos = carry_past_fly(2.8, "near_fly_control")
check("near-fly negative control has no contact", control_pos[0] > -1.1 and
      not any(e["event"].startswith("object_contact") for e in control_events),
      f"position={control_pos}")
contact_events, contact_pos = carry_past_fly(0, "fly_payload")
begins = [e for e in contact_events if e["event"] == "object_contact_begin" and
          e["id"] == "fly_payload"]
check("carried object physically contacts fly", begins and
      any(e["normal_force"] > 0 for e in begins) and
      all(e["force_units"] == "mujoco_model" and isinstance(e["sim_tick_ms"], int)
          for e in begins),
      f"segments={[e['fly_segment'] for e in begins]}, position={contact_pos}")

world.set_player_active(False)
inactive_events = world.drain_events()
check("inactive participant automatically places held object",
      world.interaction.held_object_id is None and any(
          e["event"] == "object_placed" and e["reason"] == "participant_inactive"
          for e in inactive_events))
world.move_object("fly_payload", position_mm=[-20, 0, 2.5])
body.step_exact(idle, 20)
end_events = world.drain_events()
check("contact end records peak and duration", any(
    e["event"] == "object_contact_end" and e["id"] == "fly_payload" and
    e["peak_normal_force"] > 0 and e["duration_ms"] >= 0 and
    e["force_units"] == "mujoco_model" for e in end_events))
world.move_object("fly_payload", position_mm=contact_pos)
body.step_exact(idle, 20)
unheld_events = world.drain_events()
check("unheld physical object also records fly contact", world.interaction.held_object_id is None and
      any(e["event"] == "object_contact_begin" and e["id"] == "fly_payload"
          for e in unheld_events))

# Cost of carry geometry checks with 20 distant candidates. Alternate the
# order of baseline/held quanta; transitions are outside the timed sections.
fresh_player(12)
world.spawn_object(shape="sphere", object_id="perf_payload",
                   position_mm=[20, 0, 2.5], size_mm=2)
for i in range(20):
    world.spawn_object(shape="box", object_id=f"perf_far_{i}",
                       position_mm=[200 + 20 * i, 100, 5], size_mm=[4, 4, 10])


def perf_grab():
    body.apply_lab_command(cmd("grab", ray_origin_mm=[12, 0, 2.5],
                               ray_direction=[1, 0, 0], id="perf_payload"))


def perf_quantum(held):
    if held and world.interaction.held_object_id is None:
        perf_grab()
    elif not held and world.interaction.held_object_id is not None:
        body.apply_lab_command(cmd("place"))
    start = time.perf_counter()
    body.step_exact(idle, 200)
    return (time.perf_counter() - start) * 1000


for _ in range(5):
    perf_quantum(False)
    perf_quantum(True)
# Each repeat times a held and a not-held quantum back to back and keeps their
# ratio; the median ratio cancels machine-load drift that two separate
# medians did not (the real overhead is ~3-5%, drift moved it by +-3%).
before_samples, after_samples, pair_ratios = [], [], []
for repeat in range(40):
    order = (False, True) if repeat % 2 == 0 else (True, False)
    pair = {held: perf_quantum(held) for held in order}
    before_samples.append(pair[False])
    after_samples.append(pair[True])
    pair_ratios.append(pair[True] / pair[False])
before_ms, after_ms = statistics.median(before_samples), statistics.median(after_samples)
carry_cost_pct = (statistics.median(pair_ratios) - 1) * 100
print(f"CARRY_PERF before_median_ms={before_ms:.3f} after_median_ms={after_ms:.3f} "
      f"overhead_pct={carry_cost_pct:.2f} "
      f"before_samples_ms={[round(x, 3) for x in before_samples]} "
      f"after_samples_ms={[round(x, 3) for x in after_samples]}", flush=True)
check("20 distant objects carry overhead <= 5%", carry_cost_pct <= 5.0,
      f"before={before_ms:.3f}ms, after={after_ms:.3f}ms, overhead={carry_cost_pct:.2f}%")

# V5.6.1 regression: turning while holding must not let the kinematic object
# shove the participant. 2026-09-26 repro before the fix: one 45 deg turn with
# no further input drifted the participant 31.6 mm in 3 s of simulation.
look_seq = 10_000


def wrapped(angle):
    return math.atan2(math.sin(angle), math.cos(angle))


def turn_look(turn_deg):
    global look_seq
    packets = math.ceil(abs(turn_deg) / 45.0)  # look deltas are bounded to pi/4 per packet
    for _ in range(packets):
        look_seq += 1
        body.set_player_input(PlayerInputPacket(actor_id="player", seq=look_seq, move_axes=[0, 0],
                                                look_delta=[math.radians(turn_deg) / packets, 0],
                                                held_actions=[]))


def fresh_facing_forward(x, y):
    """fresh_player with look yaw 0; world.reset() keeps the participant's look."""
    fresh_player(x=x, y=y)
    world.reset_player_pose()
    player_at(x, y)


def hold_box(object_id, x, y, box_xy, walls=()):
    fresh_facing_forward(x, y)
    world.spawn_object(shape="box", object_id=object_id, position_mm=[box_xy[0], box_xy[1], 5],
                       size_mm=[10, 10, 10])
    for index, (position, size) in enumerate(walls):
        world.spawn_object(shape="wall", object_id=f"{object_id}_wall{index}",
                           position_mm=position, size_mm=size)
    mujoco.mj_forward(model, data)
    body.apply_lab_command(cmd("grab", ray_origin_mm=[x + 1.5, y, 2.5], ray_direction=[1, 0, 0]))
    assert world.interaction.held_object_id == object_id, world.interaction.last
    world.drain_events()


def carry_turn(object_id, turn_deg, chunks=150):
    """Turn the look while holding; returns what happened along the whole path."""
    gid = world._slot_ids[world.objects[object_id].slot][1]
    start = list(world.player.position_mm)
    yaw_start = world.player.look_yaw_rad
    turn_look(turn_deg)
    max_drift, min_clearance, carry_events = 0.0, math.inf, []
    for _ in range(chunks):
        body.step_exact(idle, 200)
        max_drift = max(max_drift, math.dist(world.player.position_mm, start))
        min_clearance = min(min_clearance, mujoco.mj_geomDistance(
            model, data, gid, world.player.geom_id, 1e6, None))
        carry_events += [e["event"] for e in world.drain_events() if e["event"].startswith("carry_")]
    box = world.objects[object_id].position_mm
    center = world.player.position_mm
    bearing = math.atan2(box[1] - center[1], box[0] - center[0])
    return {
        "yaw_err": abs(wrapped(world.player.look_yaw_rad - yaw_start - math.radians(turn_deg))),
        "bearing_err": abs(wrapped(bearing - world.player.look_yaw_rad)),
        "rho": math.hypot(box[0] - center[0], box[1] - center[1]),
        "hold": world.interaction.hold_radius_mm(world.player, world.objects[object_id]),
        "max_drift": max_drift, "min_clearance": min_clearance, "events": carry_events,
    }


def turn_detail(r):
    return (f"yaw_err={math.degrees(r['yaw_err']):.4f}deg bearing_err={math.degrees(r['bearing_err']):.2f}deg "
            f"rho={r['rho']:.3f}/{r['hold']:.3f}mm max_drift={r['max_drift']:.4f}mm "
            f"min_clearance={r['min_clearance']:.4f}mm events={r['events']}")


def followed(r):
    return (r["yaw_err"] < 1e-6 and r["bearing_err"] < math.radians(1) and
            abs(r["rho"] - r["hold"]) < 0.01 and r["max_drift"] < 0.05)


for turn_deg in (45.0, 180.0, -135.0):
    hold_box("turn_box", 60, 20, (70, 20))
    for _ in range(25):
        body.step_exact(idle, 200)
    r = carry_turn("turn_box", turn_deg)
    check(f"turn {turn_deg:.0f} deg while holding: box goes around, participant never pushed",
          followed(r) and r["min_clearance"] >= 0.5 - 1e-3 and not r["events"], turn_detail(r))
    body.apply_lab_command(cmd("place"))

# A wall on the radial path: the box slides along it and around the
# participant. Before the constrained carry the box stayed at bearing 0.
wedge = [([73.5, 20, 5], [1, 20, 10])]
hold_box("wedged_box", 60, 20, (68, 20), wedge)
for _ in range(10):
    body.step_exact(idle, 200)
wedged_first = world.interaction.carry_blocked
world.drain_events()
r = carry_turn("wedged_box", 90.0)
check("wall-wedged box follows a 90 deg turn; one unblock, participant never pushed",
      wedged_first and followed(r) and r["min_clearance"] >= 0.5 - 1e-3 and
      r["events"] == ["carry_unblocked"] and not world.interaction.carry_blocked,
      f"initially_blocked={wedged_first} {turn_detail(r)}")
body.apply_lab_command(cmd("place"))

# Codex re-review P3: a small turn against the same wall used to toggle
# blocked/unblocked about every other step. Now at most one state change pair.
hold_box("small_turn_box", 60, 20, (68, 20), wedge)
for _ in range(10):
    body.step_exact(idle, 200)
world.drain_events()
r = carry_turn("small_turn_box", 10.0)
check("small turn against a wall does not flicker blocked/unblocked",
      r["yaw_err"] < 1e-6 and r["max_drift"] < 0.05 and len(r["events"]) <= 2 and
      world.interaction.carry_blocked, turn_detail(r))
body.apply_lab_command(cmd("place"))

# Codex re-review P2: a box corner starting 0.1 mm from the participant on a
# diagonal. Any straight/tangent heuristic cut 0.05 mm into it; the constrained
# carry never lets that clearance shrink.
fresh_facing_forward(60, 20)
world.spawn_object(shape="box", object_id="corner_box", position_mm=[65, 27.6, 5],
                   size_mm=[10, 10, 10])
mujoco.mj_forward(model, data)
corner_gid = world._slot_ids[world.objects["corner_box"].slot][1]
corner_start = mujoco.mj_geomDistance(model, data, corner_gid, world.player.geom_id, 1e6, None)
body.apply_lab_command(cmd("grab", ray_origin_mm=[61.5, 21.5, 2.5],
                           ray_direction=[0.55, 0.835, 0.2], id="corner_box"))
world.drain_events()
r = carry_turn("corner_box", 0.0)
check("diagonal corner box reaches the hold point without closing its 0.1 mm clearance",
      abs(corner_start - 0.1) < 1e-6 and followed(r) and r["min_clearance"] >= corner_start - 1e-3,
      f"start_clearance={corner_start:.4f}mm {turn_detail(r)}")
body.apply_lab_command(cmd("place"))

# Codex re-review P2: blocked again by a second wall while going around, the
# carry must re-plan once that wall is gone (no stale slide direction).
hold_box("second_box", 60, 20, (68, 20), wedge + [([68, 26.5, 5], [12, 1, 10])])
for _ in range(10):
    body.step_exact(idle, 200)
stuck = carry_turn("second_box", 90.0, chunks=60)
world.remove_object("second_box_wall1")
r = carry_turn("second_box", -45.0)
check("second wall blocks going around; removing it lets the carry continue",
      world.interaction.carry_blocked is False and stuck["bearing_err"] > math.radians(45) and
      stuck["max_drift"] < 0.05 and followed(r),
      f"stuck_bearing_err={math.degrees(stuck['bearing_err']):.1f}deg then {turn_detail(r)}")
body.apply_lab_command(cmd("place"))

# Same idle physics quantum, same warmup and repeats. Report measured ratio;
# the product's default segment choice is reviewed against the 20% gate.
baseline_probe = RealFlyBody(config={"object_fly_pair_segments": ()}, show_viewer=False)
paired_probe = RealFlyBody(config={"object_fly_pair_segments": ("thorax", "head", "abdomen")},
                           show_viewer=False)
for _ in range(15):
    baseline_probe.step_exact(idle, 200)
    paired_probe.step_exact(idle, 200)
baseline_samples, with_pairs_samples = [], []
for repeat in range(12):
    # Alternate order to reduce drift from other processes and periodic vision.
    probes = ((baseline_probe, baseline_samples), (paired_probe, with_pairs_samples))
    if repeat % 2:
        probes = tuple(reversed(probes))
    for probe, samples in probes:
        start = time.perf_counter()
        probe.step_exact(idle, 200)
        samples.append(time.perf_counter() - start)
baseline_s = statistics.median(baseline_samples)
with_pairs_s = statistics.median(with_pairs_samples)
baseline_pairs = baseline_probe.sim.mj_model.npair
with_pairs_count = paired_probe.sim.mj_model.npair
slowdown = with_pairs_s / baseline_s - 1.0
print(f"PERF baseline_pairs={baseline_pairs} baseline_median_ms={baseline_s*1000:.3f} "
      f"object_pairs={with_pairs_count-baseline_pairs} with_pairs_median_ms={with_pairs_s*1000:.3f} "
      f"slowdown_pct={slowdown*100:.1f} baseline_samples_ms={[round(x*1000,3) for x in baseline_samples]} "
      f"paired_samples_ms={[round(x*1000,3) for x in with_pairs_samples]}", flush=True)
check("pair performance measured on same idle quantum", baseline_s > 0 and
      with_pairs_s > 0 and with_pairs_count > baseline_pairs)

print(f"V5.6 REAL: {len(failures)} FAIL", flush=True)
if failures:
    sys.exit(1)
