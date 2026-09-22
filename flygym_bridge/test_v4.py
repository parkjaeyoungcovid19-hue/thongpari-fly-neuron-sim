"""Focused Virtual Fly Lab V4 protocol/time tests (no real MuJoCo required)."""
from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fly_body import MockBody
from bridge import Bridge
from lab_world import LabWorld
from neural_decoder import LocomotorCommand
from protocol import (
    BrainPacket,
    ExperimentStepPacket,
    ExperimentStepResultPacket,
    HelloPacket,
    LabCommand,
    LabStatePacket,
    SessionControlPacket,
    SessionStatePacket,
    V4_EXPERIMENT_QUANTUM_TICKS,
    V4_PROTOCOL_VERSION,
    decode_line,
    encode,
)


fails = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not cond:
        fails.append(name)


# Phase A: wire contract and capability gating.
hello = HelloPacket(physics_timestep_s=0.0001)
hello_rt = decode_line(encode(hello))
check("V4 hello round-trip",
      isinstance(hello_rt, HelloPacket) and hello_rt.protocol_version == V4_PROTOCOL_VERSION and
      hello_rt.supports_v4_deterministic() and abs(hello_rt.physics_timestep_s - 0.0001) < 1e-15,
      repr(hello_rt))

legacy = HelloPacket(protocol_version=3, physics_timestep_s=0.0001)
missing = HelloPacket(physics_timestep_s=0.0001, capabilities={"epoch"})
wrong_quantum = HelloPacket(physics_timestep_s=0.0001, supported_quantum_ticks=[10])
check("unsupported deterministic capability fails closed",
      not legacy.supports_v4_deterministic() and
      not missing.supports_v4_deterministic() and
      not wrong_quantum.supports_v4_deterministic())

control = SessionControlPacket(session_id="session-A", epoch=3, seq=8, sim_tick=120, action="pause")
control_rt = decode_line(encode(control))
check("V4 session control round-trip",
      isinstance(control_rt, SessionControlPacket) and control_rt.session_id == "session-A" and
      control_rt.epoch == 3 and control_rt.seq == 8 and control_rt.sim_tick == 120 and
      control_rt.action == "pause")

step = ExperimentStepPacket(session_id="session-A", epoch=3, seq=9, sim_tick=120,
                            quantum_ticks=V4_EXPERIMENT_QUANTUM_TICKS,
                            brain=BrainPacket(t=0.120, walk=0.6, turn=-0.2, tempo=1.1))
step_rt = decode_line(encode(step))
check("V4 experiment step round-trip",
      isinstance(step_rt, ExperimentStepPacket) and step_rt.session_id == "session-A" and
      step_rt.epoch == 3 and step_rt.seq == 9 and step_rt.sim_tick == 120 and
      step_rt.quantum_ticks == 20 and abs(step_rt.brain.walk - 0.6) < 1e-12 and
      abs(step_rt.brain.turn + 0.2) < 1e-12)

result = ExperimentStepResultPacket(session_id="session-A", epoch=3, seq=9,
                                    sim_tick=120, end_sim_tick=140)
result.body.t = 0.140
result.body.sim_dt = 0.020
result_rt = decode_line(encode(result))
check("V4 experiment result round-trip",
      isinstance(result_rt, ExperimentStepResultPacket) and result_rt.end_sim_tick == 140 and
      abs(result_rt.body.t - 0.140) < 1e-12 and abs(result_rt.body.sim_dt - 0.020) < 1e-12)

cmd = LabCommand(seq=17, op="touch", args={"target": "thorax"},
                 session_id="session-A", epoch=3, requested_tick=140,
                 protocol_version=V4_PROTOCOL_VERSION)
cmd_rt = decode_line(encode(cmd))
check("V4 lab command metadata round-trip",
      isinstance(cmd_rt, LabCommand) and cmd_rt.seq == 17 and
      cmd_rt.session_id == "session-A" and cmd_rt.epoch == 3 and
      cmd_rt.requested_tick == 140 and cmd_rt.protocol_version == V4_PROTOCOL_VERSION and
      "session_id" not in cmd_rt.args)

ack = LabStatePacket(ack=17, ok=True, state={}, applied_tick=140,
                     applied_epoch=3, status="applied")
ack_rt = decode_line(encode(ack))
check("V4 applied tick ack round-trip",
      isinstance(ack_rt, LabStatePacket) and ack_rt.applied_tick == 140 and
      ack_rt.applied_epoch == 3 and ack_rt.status == "applied")


# Phase B: exact mock stepping is simulation-time-only and preserves LabWorld timers.
body = MockBody()
body.lab_world.set_wind(strength=0.7, direction_deg=90, duration_ms=40, continuous=False)
idle = LocomotorCommand()
first = body.step_exact(idle, 20)
wind_after_20 = body.lab_world.state()["wind"]
second = body.step_exact(idle, 20)
wind_after_40 = body.lab_world.state()["wind"]
check("20 ms quantum maps to exact mock substeps",
      abs(first.sim_dt - 0.020) < 1e-12 and abs(first.t - 0.020) < 1e-12 and
      first.wall_dt == 0.0 and first.sim_wall_ratio == 0.0,
      f"t={first.t} dt={first.sim_dt} wall={first.wall_dt}")
check("LabWorld timed source advances only exact simulation duration",
      19.9 <= wind_after_20["remaining_ms"] <= 20.1 and
      wind_after_40["strength"] == 0.0 and abs(second.t - 0.040) < 1e-12,
      f"remaining20={wind_after_20['remaining_ms']} final={wind_after_40}")

try:
    body.step_exact(idle, 0)
    invalid_rejected = False
except ValueError:
    invalid_rejected = True
check("exact stepping rejects non-positive substeps", invalid_rejected)


# Phase C/D/F backend: negotiated session, one-quantum request stepping,
# pause barrier, epoch rejection, applied tick, and duplicate idempotency.
bridge = Bridge(mode="mock")
server_hello = bridge._hello_packet()
check("mock bridge advertises exact 20 ms V4 capability",
      server_hello.supports_v4_deterministic() and
      abs(server_hello.physics_timestep_s - 0.001) < 1e-15 and
      server_hello.supported_quantum_ticks == [20], repr(server_hello))
bridge.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
bridge.handle_line(encode(SessionControlPacket(
    session_id="lockstep-A", epoch=1, seq=1, sim_tick=0,
    action="begin", mode="deterministic")))
bridge._process_session_controls()
begin_responses = bridge._drain_lab_responses()
check("deterministic begin requires negotiated capability and starts at tick 0",
      len(begin_responses) == 1 and isinstance(begin_responses[0], SessionStatePacket) and
      begin_responses[0].ok and begin_responses[0].state == "running" and
      bridge.session_mode == "deterministic" and bridge.session_tick == 0,
      repr(begin_responses))

# A discrete command scheduled for the current boundary is applied exactly once
# before the matching body quantum.
spawn = LabCommand(seq=10, op="spawn_sphere",
                   args={"id": "once", "position_mm": [10, 0, 2], "size_mm": 3},
                   session_id="lockstep-A", epoch=1, requested_tick=0,
                   protocol_version=V4_PROTOCOL_VERSION)
bridge.handle_line(encode(spawn))
request0 = ExperimentStepPacket(
    session_id="lockstep-A", epoch=1, seq=100, sim_tick=0,
    quantum_ticks=20, brain=BrainPacket(t=0.0, walk=0.2))
bridge.handle_line(encode(request0))
result0 = bridge._process_experiment_step(bridge._pop_experiment_step())
step0_responses = bridge._drain_lab_responses()
spawn_acks = [p for p in step0_responses if isinstance(p, LabStatePacket) and p.ack == 10]
check("lockstep request advances exactly one 20 ms quantum",
      result0.ok and result0.sim_tick == 0 and result0.end_sim_tick == 20 and
      bridge.session_tick == 20 and abs(bridge.body.t - 0.020) < 1e-12,
      repr(result0))
check("V4 command records exact applied boundary tick",
      len(spawn_acks) == 1 and spawn_acks[0].ok and spawn_acks[0].status == "applied" and
      spawn_acks[0].applied_tick == 0 and spawn_acks[0].applied_epoch == 1 and
      "once" in bridge.body.lab_world.objects, repr(spawn_acks))

body_t_before_duplicate = bridge.body.t
duplicate_result = bridge._process_experiment_step(request0)
check("duplicate experiment step is idempotent",
      duplicate_result is result0 and bridge.body.t == body_t_before_duplicate and
      bridge.session_tick == 20)

# Duplicate command identity must return its cached success rather than invoke
# spawn twice (which would otherwise fail with an existing object id).
bridge.handle_line(encode(spawn))
bridge._apply_lab_commands(applied_tick=20, applied_epoch=1)
duplicate_command_responses = bridge._drain_lab_responses()
duplicate_spawn_acks = [p for p in duplicate_command_responses
                        if isinstance(p, LabStatePacket) and p.ack == 10]
check("duplicate V4 command does not mutate twice",
      len(duplicate_spawn_acks) == 1 and duplicate_spawn_acks[0].ok and
      duplicate_spawn_acks[0].applied_tick == 0 and
      list(bridge.body.lab_world.objects).count("once") == 1,
      repr(duplicate_spawn_acks))

old_epoch = LabCommand(seq=11, op="spawn_sphere",
                       args={"id": "stale", "position_mm": [2, 2, 2], "size_mm": 2},
                       session_id="lockstep-A", epoch=2, requested_tick=20,
                       protocol_version=V4_PROTOCOL_VERSION)
bridge.handle_line(encode(old_epoch))
bridge._apply_lab_commands(applied_tick=20, applied_epoch=1)
old_epoch_responses = bridge._drain_lab_responses()
old_epoch_acks = [p for p in old_epoch_responses
                  if isinstance(p, LabStatePacket) and p.ack == 11]
check("wrong epoch command is rejected without mutation",
      len(old_epoch_acks) == 1 and not old_epoch_acks[0].ok and
      old_epoch_acks[0].status == "rejected_old_epoch" and
      "stale" not in bridge.body.lab_world.objects, repr(old_epoch_acks))

# Pausing after a completed quantum freezes body/session time. A command received
# while paused remains bounded in the queue and applies at the first resumed
# boundary, never during wall-time pause.
bridge.handle_line(encode(SessionControlPacket(
    session_id="lockstep-A", epoch=1, seq=2, sim_tick=20,
    action="pause", mode="deterministic")))
bridge._process_session_controls()
pause_state = bridge._drain_lab_responses()
paused_t = bridge.body.t
paused_cmd = LabCommand(seq=12, op="touch",
                        args={"target": "thorax", "strength": 0.4, "duration_ms": 30},
                        session_id="lockstep-A", epoch=1, requested_tick=20,
                        protocol_version=V4_PROTOCOL_VERSION)
bridge.handle_line(encode(paused_cmd))
paused_step = ExperimentStepPacket(
    session_id="lockstep-A", epoch=1, seq=101, sim_tick=20,
    quantum_ticks=20, brain=BrainPacket(t=0.020))
paused_result = bridge._process_experiment_step(paused_step)
check("pause barrier rejects stepping and freezes body time",
      not paused_result.ok and bridge.session_paused and
      bridge.session_tick == 20 and bridge.body.t == paused_t and
      bridge.body.lab_world.touch is None and
      any(isinstance(p, SessionStatePacket) and p.state == "paused" for p in pause_state),
      repr(paused_result))

bridge.handle_line(encode(SessionControlPacket(
    session_id="lockstep-A", epoch=1, seq=3, sim_tick=20,
    action="resume", mode="deterministic")))
bridge._process_session_controls()
resume_state = bridge._drain_lab_responses()
# Use a new sequence: the rejected paused sequence is cached by identity.
request1 = ExperimentStepPacket(
    session_id="lockstep-A", epoch=1, seq=102, sim_tick=20,
    quantum_ticks=20, brain=BrainPacket(t=0.020))
result1 = bridge._process_experiment_step(request1)
resume_responses = bridge._drain_lab_responses()
touch_acks = [p for p in resume_responses if isinstance(p, LabStatePacket) and p.ack == 12]
check("resume applies paused command at first boundary",
      result1.ok and bridge.session_tick == 40 and abs(bridge.body.t - 0.040) < 1e-12 and
      len(touch_acks) == 1 and touch_acks[0].applied_tick == 20 and
      any(isinstance(p, SessionStatePacket) and p.state == "running" for p in resume_state),
      repr(touch_acks))

# A future command must remain deferred until its requested deterministic boundary.
future = LabCommand(seq=13, op="wind",
                    args={"strength": 0.5, "direction_deg": 0, "duration_ms": 20},
                    session_id="lockstep-A", epoch=1, requested_tick=60,
                    protocol_version=V4_PROTOCOL_VERSION)
bridge.handle_line(encode(future))
request2 = ExperimentStepPacket(
    session_id="lockstep-A", epoch=1, seq=103, sim_tick=40,
    quantum_ticks=20, brain=BrainPacket(t=0.040))
result2 = bridge._process_experiment_step(request2)
early = bridge._drain_lab_responses()
request3 = ExperimentStepPacket(
    session_id="lockstep-A", epoch=1, seq=104, sim_tick=60,
    quantum_ticks=20, brain=BrainPacket(t=0.060))
result3 = bridge._process_experiment_step(request3)
on_time = bridge._drain_lab_responses()
future_acks = [p for p in on_time if isinstance(p, LabStatePacket) and p.ack == 13]
check("future V4 command waits for requested boundary",
      result2.ok and result3.ok and
      not any(isinstance(p, LabStatePacket) and p.ack == 13 for p in early) and
      len(future_acks) == 1 and future_acks[0].applied_tick == 60,
      repr(future_acks))

# V5.4 participant activation is still a V4 LabCommand and must obey the exact
# same deterministic boundary, idempotence, epoch and pause contracts as every
# other physical world mutation. Keep this on a separate bridge so the legacy
# V4 fixture above remains unchanged.
player_bridge = Bridge(mode="mock")
player_bridge.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
player_bridge.handle_line(encode(SessionControlPacket(
    session_id="player-v4", epoch=1, seq=1, sim_tick=0,
    action="begin", mode="deterministic")))
player_bridge._process_session_controls(); player_bridge._drain_lab_responses()
player_enable = LabCommand(
    seq=70, op="set_player_active", args={"value": 1.0},
    session_id="player-v4", epoch=1, requested_tick=40,
    protocol_version=V4_PROTOCOL_VERSION)
player_bridge.handle_line(encode(player_enable))
for seq, tick in ((200, 0), (201, 20)):
    player_bridge._process_experiment_step(ExperimentStepPacket(
        session_id="player-v4", epoch=1, seq=seq, sim_tick=tick,
        quantum_ticks=20, brain=BrainPacket(t=tick / 1000.0)))
    player_bridge._drain_lab_responses()
check("V5.4 player command waits for requested deterministic boundary",
      not player_bridge.body.lab_world.player.active and player_bridge.session_tick == 40)
player_bridge._process_experiment_step(ExperimentStepPacket(
    session_id="player-v4", epoch=1, seq=202, sim_tick=40,
    quantum_ticks=20, brain=BrainPacket(t=0.040)))
player_apply_responses = player_bridge._drain_lab_responses()
player_enable_acks = [p for p in player_apply_responses
                      if isinstance(p, LabStatePacket) and p.ack == 70]
check("V5.4 player activation records exact applied tick",
      player_bridge.body.lab_world.player.active
      and len(player_enable_acks) == 1 and player_enable_acks[0].ok
      and player_enable_acks[0].applied_tick == 40,
      repr(player_enable_acks))

player_revision_after_enable = player_bridge.body.lab_world.revision
player_bridge.handle_line(encode(player_enable))
player_bridge._apply_lab_commands(applied_tick=60, applied_epoch=1)
player_duplicate = [p for p in player_bridge._drain_lab_responses()
                    if isinstance(p, LabStatePacket) and p.ack == 70]
check("V5.4 duplicate player activation is idempotent",
      len(player_duplicate) == 1 and player_duplicate[0].ok
      and player_duplicate[0].applied_tick == 40
      and player_bridge.body.lab_world.revision == player_revision_after_enable,
      repr(player_duplicate))

player_bridge.handle_line(encode(LabCommand(
    seq=71, op="set_player_active", args={"value": 0.0},
    session_id="player-v4", epoch=2, requested_tick=60,
    protocol_version=V4_PROTOCOL_VERSION)))
player_bridge._apply_lab_commands(applied_tick=60, applied_epoch=1)
player_wrong_epoch = [p for p in player_bridge._drain_lab_responses()
                      if isinstance(p, LabStatePacket) and p.ack == 71]
check("V5.4 wrong-epoch player command is rejected without mutation",
      player_bridge.body.lab_world.player.active
      and len(player_wrong_epoch) == 1 and not player_wrong_epoch[0].ok
      and player_wrong_epoch[0].status == "rejected_old_epoch",
      repr(player_wrong_epoch))

player_bridge.handle_line(encode(SessionControlPacket(
    session_id="player-v4", epoch=1, seq=2, sim_tick=60,
    action="pause", mode="deterministic")))
player_bridge._process_session_controls(); player_bridge._drain_lab_responses()
player_bridge.handle_line(encode(LabCommand(
    seq=72, op="set_player_active", args={"value": 0.0},
    session_id="player-v4", epoch=1, requested_tick=60,
    protocol_version=V4_PROTOCOL_VERSION)))
time.sleep(0.02)
check("V5.4 paused player command does not mutate world",
      player_bridge.session_paused and player_bridge.body.lab_world.player.active)
player_bridge.handle_line(encode(SessionControlPacket(
    session_id="player-v4", epoch=1, seq=3, sim_tick=60,
    action="resume", mode="deterministic")))
player_bridge._process_session_controls(); player_bridge._drain_lab_responses()
player_bridge._process_experiment_step(ExperimentStepPacket(
    session_id="player-v4", epoch=1, seq=203, sim_tick=60,
    quantum_ticks=20, brain=BrainPacket(t=0.060)))
player_resume_responses = player_bridge._drain_lab_responses()
player_disable_acks = [p for p in player_resume_responses
                       if isinstance(p, LabStatePacket) and p.ack == 72]
check("V5.4 resumed boundary applies deferred player disable",
      not player_bridge.body.lab_world.player.active
      and len(player_disable_acks) == 1 and player_disable_acks[0].applied_tick == 60,
      repr(player_disable_acks))

# One logical reset advances one epoch. It is accepted only behind a pause
# barrier; body/world reset happens on the owner thread and stale epoch traffic
# cannot mutate the new timeline.
bridge.handle_line(encode(SessionControlPacket(
    session_id="lockstep-A", epoch=1, seq=4, sim_tick=80,
    action="pause", mode="deterministic")))
bridge._process_session_controls()
_ = bridge._drain_lab_responses()
bridge.handle_line(encode(SessionControlPacket(
    session_id="lockstep-A", epoch=2, seq=5, sim_tick=0,
    action="reset", mode="deterministic", reset_scope=["body", "world"])))
bridge._process_session_controls()
reset_responses = bridge._drain_lab_responses()
check("coordinated reset increments epoch exactly once and resets tick",
      bridge.session_epoch == 2 and bridge.session_tick == 0 and
      bridge.session_paused and abs(bridge.body.t) < 1e-12 and
      not bridge.body.lab_world.objects and
      any(isinstance(p, SessionStatePacket) and p.ok and p.epoch == 2 and
          p.sim_tick == 0 and p.state == "paused" for p in reset_responses),
      repr(reset_responses))

stale_step = ExperimentStepPacket(
    session_id="lockstep-A", epoch=1, seq=105, sim_tick=80,
    quantum_ticks=20, brain=BrainPacket(t=0.080))
stale_result = bridge._process_experiment_step(stale_step)
check("old epoch step rejected after reset without advancing",
      not stale_result.ok and bridge.session_epoch == 2 and
      bridge.session_tick == 0 and abs(bridge.body.t) < 1e-12,
      repr(stale_result))


# Pause acceptance: make every simulation-time-sensitive LabWorld subsystem
# active, seal a deterministic pause boundary, then spend >1 second in wall time.
# Nothing may age or move and a command received during that wall pause must stay
# unapplied until a resumed experiment boundary.
pause_bridge = Bridge(mode="mock")
pause_bridge.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
pause_bridge.handle_line(encode(SessionControlPacket(
    session_id="pause-wall", epoch=1, seq=1, sim_tick=0,
    action="begin", mode="deterministic")))
pause_bridge._process_session_controls(); pause_bridge._drain_lab_responses()
for command in (
    LabCommand(seq=1, op="spawn_sphere",
               args={"id": "approacher", "position_mm": [80, 0, 3], "size_mm": 4},
               session_id="pause-wall", epoch=1, requested_tick=0,
               protocol_version=V4_PROTOCOL_VERSION),
    LabCommand(seq=2, op="approach_object",
               args={"id": "approacher", "speed_mm_s": 20, "end_distance_mm": 8},
               session_id="pause-wall", epoch=1, requested_tick=0,
               protocol_version=V4_PROTOCOL_VERSION),
    LabCommand(seq=3, op="wind",
               args={"strength": 0.5, "duration_ms": 500, "continuous": False},
               session_id="pause-wall", epoch=1, requested_tick=0,
               protocol_version=V4_PROTOCOL_VERSION),
    LabCommand(seq=4, op="touch",
               args={"target": "thorax", "strength": 0.4, "duration_ms": 400},
               session_id="pause-wall", epoch=1, requested_tick=0,
               protocol_version=V4_PROTOCOL_VERSION),
    LabCommand(seq=5, op="flash_eye",
               args={"eye": "both", "intensity": 0.8, "duration_ms": 300},
               session_id="pause-wall", epoch=1, requested_tick=0,
               protocol_version=V4_PROTOCOL_VERSION),
):
    pause_bridge.handle_line(encode(command))
pause_step0 = ExperimentStepPacket(
    session_id="pause-wall", epoch=1, seq=10, sim_tick=0,
    quantum_ticks=20, brain=BrainPacket(t=0.0, walk=0.2))
pause_result0 = pause_bridge._process_experiment_step(pause_step0)
pause_bridge._drain_lab_responses()
pause_bridge.handle_line(encode(SessionControlPacket(
    session_id="pause-wall", epoch=1, seq=2, sim_tick=20,
    action="pause", mode="deterministic")))
pause_bridge._process_session_controls(); pause_bridge._drain_lab_responses()
paused_world_before = pause_bridge.body.lab_world.state()
paused_t_before = pause_bridge.body.t
paused_applied_before = pause_bridge.lab_applied
paused_position_before = list(pause_bridge.body.lab_world.objects["approacher"].position_mm)
pause_bridge.handle_line(encode(LabCommand(
    seq=6, op="spawn_sphere",
    args={"id": "queued_during_pause", "position_mm": [20, 0, 2], "size_mm": 2},
    session_id="pause-wall", epoch=1, requested_tick=20,
    protocol_version=V4_PROTOCOL_VERSION)))
time.sleep(1.05)
paused_world_after = pause_bridge.body.lab_world.state()
paused_position_after = list(pause_bridge.body.lab_world.objects["approacher"].position_mm)
check("1s wall pause freezes body/timers/approach/command application",
      pause_result0.ok and pause_bridge.session_paused and
      pause_bridge.body.t == paused_t_before and
      pause_bridge.lab_applied == paused_applied_before and
      "queued_during_pause" not in pause_bridge.body.lab_world.objects and
      paused_position_after == paused_position_before and
      paused_world_after["wind"]["remaining_ms"] == paused_world_before["wind"]["remaining_ms"] and
      paused_world_after["touch"]["remaining_ms"] == paused_world_before["touch"]["remaining_ms"] and
      paused_world_after["flash"]["remaining_ms"] == paused_world_before["flash"]["remaining_ms"],
      f"t={paused_t_before}->{pause_bridge.body.t} applied={paused_applied_before}->{pause_bridge.lab_applied} "
      f"pos={paused_position_before}->{paused_position_after}")
pause_bridge.handle_line(encode(SessionControlPacket(
    session_id="pause-wall", epoch=1, seq=3, sim_tick=20,
    action="resume", mode="deterministic")))
pause_bridge._process_session_controls(); pause_bridge._drain_lab_responses()
pause_result1 = pause_bridge._process_experiment_step(ExperimentStepPacket(
    session_id="pause-wall", epoch=1, seq=11, sim_tick=20,
    quantum_ticks=20, brain=BrainPacket(t=0.020, walk=0.2)))
pause_resume_acks = pause_bridge._drain_lab_responses()
queued_ack = [p for p in pause_resume_acks
              if isinstance(p, LabStatePacket) and p.ack == 6]
check("wall pause resume has no catch-up and applies queued command at next boundary",
      pause_result1.ok and pause_bridge.session_tick == 40 and
      abs(pause_bridge.body.t - 0.040) < 1e-12 and
      len(queued_ack) == 1 and queued_ack[0].applied_tick == 20 and
      "queued_during_pause" in pause_bridge.body.lab_world.objects,
      repr(queued_ack))


# Wall scheduling must be irrelevant in deterministic request mode. Run the same
# command/tick sequence with radically different sleeps (standing in for render
# callback cadence/UI stalls) and compare the complete deterministic mock state.
def deterministic_trial(sleeps):
    b = Bridge(mode="mock")
    b.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
    b.handle_line(encode(SessionControlPacket(
        session_id="wall-independent", epoch=1, seq=1, sim_tick=0,
        action="begin", mode="deterministic")))
    b._process_session_controls(); b._drain_lab_responses()
    b.handle_line(encode(LabCommand(
        seq=50, op="wind", args={"strength": 0.35, "duration_ms": 60},
        session_id="wall-independent", epoch=1, requested_tick=40,
        protocol_version=V4_PROTOCOL_VERSION)))
    trace = []
    for i in range(6):
        if i < len(sleeps) and sleeps[i] > 0:
            time.sleep(sleeps[i])
        start = i * 20
        result = b._process_experiment_step(ExperimentStepPacket(
            session_id="wall-independent", epoch=1, seq=100 + i,
            sim_tick=start, quantum_ticks=20,
            brain=BrainPacket(t=start / 1000.0, walk=0.55, turn=-0.15, tempo=1.1)))
        trace.append((result.ok, result.end_sim_tick, result.body.t, result.body.vx,
                      result.body.yaw_rate, result.body.heading_rad,
                      result.body.wind_strength, b.lab_applied))
        b._drain_lab_responses()
    return (trace, b.session_tick, b.body.t, b.body.x, b.body.y, b.body.heading,
            b.body.vx, b.body.yaw_rate, b.body.phase, b.lab_applied,
            b.body.lab_world.state()["wind"])

trial_fast = deterministic_trial([0, 0, 0, 0, 0, 0])
trial_stalled = deterministic_trial([0.010, 0.001, 0.030, 0.002, 0.015, 0.004])
check("deterministic mock state is invariant to wall sleeps/render-stall surrogate",
      trial_fast == trial_stalled,
      f"fast={trial_fast}\nstalled={trial_stalled}")


print("ALL V4 TESTS PASS" if not fails else f"{len(fails)} V4 FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
