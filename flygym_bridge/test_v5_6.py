"""V5.6 wire/state machine checks. No sockets or MuJoCo."""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bridge import Bridge
from fly_body import MockBody
from interaction import parse_interaction_args
from protocol import LabCommand, LabStatePacket, decode_line, encode

failures = []


def check(name, condition, detail=""):
    print(("PASS" if condition else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not condition:
        failures.append(name)


valid = {"tool_id": "grab", "actor_id": "player",
         "ray_origin_mm": [24, 0, 2.5], "ray_direction": [2, 0, 0]}
fixtures = {
    "missing tool": {k: v for k, v in valid.items() if k != "tool_id"},
    "missing actor": {k: v for k, v in valid.items() if k != "actor_id"},
    "missing origin": {k: v for k, v in valid.items() if k != "ray_origin_mm"},
    "missing direction": {k: v for k, v in valid.items() if k != "ray_direction"},
    "NaN origin": {**valid, "ray_origin_mm": [math.nan, 0, 0]},
    "Inf direction": {**valid, "ray_direction": [math.inf, 0, 0]},
    "short origin": {**valid, "ray_origin_mm": [0, 0]},
    "long direction": {**valid, "ray_direction": [1, 0, 0, 0]},
    "zero direction": {**valid, "ray_direction": [0, 0, 0]},
    "unknown tool": {**valid, "tool_id": "throw"},
    "place ray origin": {"tool_id": "place", "actor_id": "player", "ray_origin_mm": [0, 0, 0]},
    "place ray direction": {"tool_id": "place", "actor_id": "player", "ray_direction": [1, 0, 0]},
    "empty actor": {**valid, "actor_id": " "},
    "unknown field": {**valid, "secret": 1},
}
for name, args in fixtures.items():
    try:
        parse_interaction_args(args)
        rejected = False
    except ValueError:
        rejected = True
    check("schema rejects " + name, rejected)

check("direction normalized", parse_interaction_args(valid).ray_direction == (1.0, 0.0, 0.0))

body = MockBody()
world = body.lab_world


def command(seq, args):
    return LabCommand(seq=seq, op="interaction", args=args)


def rejected(code, args, ray=None):
    old = world.interaction.held_object_id
    try:
        world.apply_interaction(command(100, args), ray_pick=ray or body._interaction_ray_pick)
        result = False
    except ValueError as exc:
        result = str(exc).startswith(code) and world.interaction.held_object_id == old
    check("reject " + code, result)


rejected("not_participating", valid)
world.set_player_active(True)
world.spawn_object(shape="sphere", object_id="near", position_mm=[31, 0, 2.5], size_mm=2)
world.spawn_object(shape="sphere", object_id="far", position_mm=[50, 0, 2.5], size_mm=2)
rejected("invalid_interaction", fixtures["missing origin"])
rejected("wrong_actor", {**valid, "actor_id": "other"})
rejected("ray_origin_not_at_participant", {**valid, "ray_origin_mm": [100, 0, 2.5]})
rejected("ray_miss", {**valid, "ray_direction": [0, 1, 0]})
for kind in ("fly", "world", "player"):
    rejected("unsupported_target", valid,
             ray=lambda origin, direction, kind=kind: {
                 "hit": True, "target_kind": kind, "target_id": kind,
                 "point_mm": [25, 0, 2.5]})
rejected("out_of_reach", valid, ray=lambda *_: {
    "hit": True, "target_kind": "lab_object", "target_id": "far",
    "point_mm": [49, 0, 2.5]})
rejected("target_mismatch", {**valid, "id": "wrong"})
rejected("not_holding", {"tool_id": "place", "actor_id": "player"})

grab = body.apply_lab_command(command(1, valid))
check("mock analytic grab", grab["held_object_id"] == "near" and
      grab["mode"] == "mock_kinematic_carry" and
      grab["last"]["hit_distance_mm"] > 0)
before_move = tuple(world.objects["near"].position_mm)
body.step_exact(type("Idle", (), {"forward": 0.0, "reverse": False, "moving": False,
                                "urgent": False, "steering": 0.0})(), 20)
check("mock carry uses bounded XY motion", 0 < math.dist(before_move, world.objects["near"].position_mm) <= 0.8 + 1e-9 and
      world.objects["near"].position_mm[2] == before_move[2])
rejected("already_holding", valid)
rejected("target_mismatch", {"tool_id": "place", "actor_id": "player", "id": "wrong"})
placed = body.apply_lab_command(command(2, {"tool_id": "place", "actor_id": "player"}))
check("mock place", placed["held_object_id"] is None)
body.apply_lab_command(command(3, valid))
world.remove_object("near")
check("delete automatically places held object", world.interaction.held_object_id is None and
      any(e["event"] == "object_placed" and e["reason"] == "object_removed"
          for e in world.drain_events()))
world.spawn_object(shape="sphere", object_id="near", position_mm=[31, 0, 2.5], size_mm=2)
body.apply_lab_command(command(4, valid))
world.reset()
check("world reset automatically places held object", world.interaction.held_object_id is None and
      any(e["event"] == "object_placed" and e["reason"] == "world_reset"
          for e in world.drain_events()))
world.spawn_object(shape="sphere", object_id="near", position_mm=[31, 0, 2.5], size_mm=2)
body.apply_lab_command(command(5, valid))
body.reset_body()
check("body reset automatically places held object", world.interaction.held_object_id is None and
      any(e["event"] == "object_placed" and e["reason"] == "body_reset"
          for e in world.drain_events()))

flat = LabCommand.from_dict({"type": "lab_command", "id": 4, "action": "interaction",
                             "tool_id": "grab", "actor_id": "player", "target": "near",
                             "ray_origin_mm": [24, 0, 2.5], "ray_direction": [1, 0, 0]})
check("flat target parsed", parse_interaction_args(flat.args).target_id == "near")
state = LabStatePacket(ack=4, state=body.lab_state())
wire = state.to_dict()
roundtrip = decode_line(encode(state))
check("lab_state interaction top-level and nested", wire["interaction"] == wire["state"]["interaction"]
      and roundtrip.state["interaction"] == wire["interaction"])
check("legacy lab_state omits optional interaction", "interaction" not in LabStatePacket(state={}).to_dict())
for bad in ({"held_object_id": 3, "carry_blocked": False, "reach_mm": 12},
            {"held_object_id": None, "carry_blocked": "false", "reach_mm": 12},
            {"held_object_id": None, "carry_blocked": False, "reach_mm": math.nan}):
    try:
        LabStatePacket(state={"interaction": bad}).to_dict()
        invalid = False
    except ValueError:
        invalid = True
    check("invalid interaction state rejected", invalid)

bridge = Bridge(mode="mock")
bridge.session_id = "interaction-test"
bridge.session_epoch = 1
bridge.body.lab_world.set_player_active(True)
bridge.body.lab_world.spawn_object(shape="sphere", object_id="once",
                                   position_mm=[31, 0, 2.5], size_mm=2)
packet = LabCommand(seq=7, op="interaction", args=dict(valid),
                    session_id="interaction-test", epoch=1, requested_tick=0,
                    protocol_version=4)
bridge.lab_commands.push(packet)
bridge._apply_lab_commands(applied_tick=0, applied_epoch=1)
first = bridge._drain_lab_responses()
bridge.lab_commands.push(packet)
bridge._apply_lab_commands(applied_tick=0, applied_epoch=1)
second = bridge._drain_lab_responses()
events = bridge.body.drain_lab_events()
check("same session epoch seq applies once", len(first) == len(second) == 1 and
      first[0].ok and second[0].ok and bridge.lab_applied == 1 and
      len([e for e in events if e["event"] == "object_grabbed"]) == 1)
bad_packet = LabCommand(seq=8, op="interaction",
                        args={"tool_id": "place", "actor_id": "player", "ray_direction": [1, 0, 0]},
                        session_id="interaction-test", epoch=1, requested_tick=0,
                        protocol_version=4)
bridge.lab_commands.push(bad_packet)
bridge._apply_lab_commands(applied_tick=0, applied_epoch=1)
bad_ack = bridge._drain_lab_responses()
check("schema error travels through lab_state ACK", len(bad_ack) == 1 and
      isinstance(bad_ack[0], LabStatePacket) and not bad_ack[0].ok and
      bad_ack[0].error.startswith("invalid_interaction") and
      bad_ack[0].ack == 8)

print(f"V5.6 MOCK: {len(failures)} FAIL")
if failures:
    sys.exit(1)
