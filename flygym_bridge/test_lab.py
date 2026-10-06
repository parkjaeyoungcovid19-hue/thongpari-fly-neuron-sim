"""Virtual Fly Lab backend tests. No MuJoCo/FlyGym process required."""
import json
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bridge import Bridge
from lab_world import LabError, LabWorld
from protocol import (
    BodyPacket, LabCommand, LabCommandQueue, LabEventPacket, LabStatePacket, decode_line, encode,
)


fails = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not cond:
        fails.append(name)


# 1. Exact flat Swift V1 command shape -> normalized LabCommand.
flat = decode_line(
    b'{"type":"lab_command","id":7,"action":"spawn_object","target":"stimulus",'
    b'"x":60,"y":2,"z":5,"size":6}\n')
check("flat Swift command parse", isinstance(flat, LabCommand) and flat.seq == 7 and
      flat.op == "spawn_object" and flat.args.get("id") == "stimulus" and
      flat.args.get("position_mm") == [60, 2, 5] and flat.args.get("size_mm") == [6, 6, 6],
      repr(flat))

eye = decode_line(
    b'{"type":"lab_command","id":8,"action":"set_eye_state","target":"left","value":1}\n')
check("flat eye cover normalization", eye.args.get("left_mask") == 1 and eye.seq == 8, repr(eye.args))

touch = decode_line(
    b'{"type":"lab_command","id":9,"action":"touch","target":"left_front_leg",'
    b'"strength":0.4,"duration_ms":25}\n')
check("flat touch target normalization", touch.args.get("target") == "left_front_leg", repr(touch.args))

flash = decode_line(
    b'{"type":"lab_command","id":11,"action":"flash_eye","target":"right",'
    b'"strength":0.75,"duration_ms":80}\n')
check("flat flash normalization", flash.args.get("eye") == "right" and
      flash.args.get("intensity") == 0.75 and flash.args.get("duration_ms") == 80,
      repr(flash.args))

temp = decode_line(
    b'{"type":"lab_command","id":10,"action":"temperature","value":31.5}\n')
check("flat temperature normalization", temp.args.get("celsius") == 31.5, repr(temp.args))


# 2. Discrete FIFO + latest-wins continuous controls are independently bounded.
q = LabCommandQueue(max_discrete=2, max_continuous=2)
check("queue discrete 1", q.push(LabCommand(1, "spawn_box", {"id": "a"})))
check("queue discrete 2", q.push(LabCommand(2, "delete_object", {"id": "a"})))
check("queue discrete overflow rejects newest", not q.push(LabCommand(3, "touch", {})))
check("queue continuous first", q.push(LabCommand(4, "wind", {"strength": 0.2})))
check("queue continuous replacement", q.push(LabCommand(5, "wind", {"strength": 0.8})))
first = q.drain(max_discrete=1)
check("partial drain keeps continuous behind FIFO", [c.seq for c in first] == [1], str([c.seq for c in first]))
second = q.drain(max_discrete=2)
check("FIFO then latest continuous", [c.seq for c in second] == [2, 5], str([c.seq for c in second]))
check("queue drop count", q.stats()["dropped"] == 1, repr(q.stats()))

ordered = LabCommandQueue()
ordered.push(LabCommand(10, "wind", {"strength": 0.8}))
ordered.push(LabCommand(11, "reset_world", {}))
check("mixed controls preserve sequence order",
      [c.seq for c in ordered.drain()] == [10, 11])

eyes_q = LabCommandQueue()
eyes_q.push(LabCommand(12, "set_eye_state", {"left_mask": 1.0}))
eyes_q.push(LabCommand(13, "set_eye_state", {"right_mask": 1.0}))
check("left/right eye updates keep separate continuous slots",
      [c.seq for c in eyes_q.drain()] == [12, 13])
eyes_q.push(LabCommand(14, "set_eye_state", {"left_mask": 0.2}))
eyes_q.push(LabCommand(15, "set_eye_state", {"left_mask": 0.8}))
check("same-eye continuous update remains latest-wins",
      [c.seq for c in eyes_q.drain()] == [15])


# 3. Bounded LabWorld object lifecycle and food honesty.
world = LabWorld(slot_counts={"box": 1, "sphere": 1, "wall": 1, "food": 1})
box = world.spawn_object(shape="box", object_id="b", position_mm=[20, 0, 5], size_mm=[10, 8, 6])
sphere = world.spawn_object(shape="sphere", object_id="s", position_mm=[10, 4, 3], size_mm=4)
wall = world.spawn_object(shape="wall", object_id="w", position_mm=[30, 0, 8], size_mm=[2, 20, 16])
food = world.spawn_object(shape="food", object_id="food", position_mm=[5, 5, 1], size_mm=3)
check("all V1 shapes spawn", {o["shape"] for o in world.state()["objects"]} == {"box", "sphere", "wall", "food"})
check("food odor source is honest sensory model",
      food["odor_source_modeled"] and food["odor_classification"] == "SENSORY-MODEL" and
      not food["backend_direct_neural"] and food["integrated_neural_target"] == "ORN_DM1/VA2 via Swift" and
      food["taste_modeled"] and food["taste_classification"] == "SENSORY-MODEL" and
      food["feeding_modeled"] and food["food_variant"] in ("apple", "banana", "cheese",
                                                           "grapes", "cookie", "sugar_cube") and
      not food["reward_modeled"] and
      not food["behavior_scripted"] and not food["visual_marker_only"], repr(food))
try:
    world.spawn_object(shape="box", object_id="overflow")
    cap_ok = False
except LabError:
    cap_ok = True
check("object slots bounded", cap_ok)
world.move_object("b", position_mm=[18, 1, 5])
world.resize_object("b", size_mm=[12, 12, 12])
check("move/resize object", world.objects["b"].position_mm == [18.0, 1.0, 5.0] and
      world.objects["b"].size_mm == [12.0, 12.0, 12.0])
world.remove_object("b")
world.spawn_object(shape="box", object_id="b2")
check("delete frees fixed slot", "b2" in world.objects and "b" not in world.objects)

# Food odor is pure sensory telemetry: bounded, directional, and behavior-free.
odor_world = LabWorld(slot_counts={"food": 2})
empty_odor = odor_world.food_odor(fly_position_mm=[0, 0, 0], fly_heading_rad=0.0)
check("food odor defaults to zero without source",
      empty_odor["odor_left"] == 0.0 and empty_odor["odor_right"] == 0.0 and
      empty_odor["nearest_food_distance_mm"] is None, repr(empty_odor))
odor_world.spawn_object(shape="food", object_id="left_food", position_mm=[0, 10, 0], size_mm=2)
left_odor = odor_world.food_odor(fly_position_mm=[0, 0, 0], fly_heading_rad=0.0)
check("food odor splits toward fly-left",
      0.0 <= left_odor["odor_right"] <= left_odor["odor_left"] <= 1.0 and
      left_odor["odor_left"] > left_odor["odor_right"] and
      abs(left_odor["nearest_food_distance_mm"] - 10.0) < 1e-9,
      repr(left_odor))
odor_world.spawn_object(shape="food", object_id="right_food", position_mm=[0, -10, 0], size_mm=2)
bilateral_odor = odor_world.food_odor(fly_position_mm=[0, 0, 0], fly_heading_rad=0.0)
check("multiple food odor remains bounded", 0.0 <= bilateral_odor["odor_left"] <= 1.0 and
      0.0 <= bilateral_odor["odor_right"] <= 1.0 and
      bilateral_odor["classification"] == "SENSORY-MODEL" and
      not bilateral_odor["backend_direct_neural"] and
      bilateral_odor["integrated_neural_target"] == "ORN_DM1/VA2 via Swift" and
      not bilateral_odor["behavior_scripted"],
      repr(bilateral_odor))

# The real body hands MuJoCo's thorax xpos over as a NumPy array.
import numpy as np
far_world = LabWorld(slot_counts={"food": 1})
far_world.spawn_object(shape="food", object_id="far_food", position_mm=[87.3, -111.1, 0], size_mm=2)
as_list = far_world.food_odor(fly_position_mm=[76.0, -101.7, 0.7], fly_heading_rad=-0.77)
as_array = far_world.food_odor(fly_position_mm=np.array([76.0, -101.7, 0.7]), fly_heading_rad=-0.77)
at_origin = far_world.food_odor(fly_position_mm=[0, 0, 0], fly_heading_rad=-0.77)
check("food odor uses a NumPy fly position, not the origin",
      as_array == as_list and as_list["nearest_food_distance_mm"] < 20 and
      at_origin["nearest_food_distance_mm"] > 100, repr((as_list, as_array)))
check("non-vector fly position still falls back to the origin",
      far_world.food_odor(fly_position_mm="abc") == far_world.food_odor(fly_position_mm={"x": 1}) ==
      far_world.food_odor(fly_position_mm=[0, 0, 0]))

body_default = BodyPacket.from_dict({"type": "body"})
check("BodyPacket odor fields are backward-compatible defaults",
      body_default.odor_left == 0.0 and body_default.odor_right == 0.0 and
      body_default.nearest_food_distance_mm is None and body_default.heading_rad == 0.0,
      repr(body_default))
body_odor = BodyPacket.from_dict({
    "type": "body", "odor_left": 2.0, "odor_right": -1.0,
    "nearest_food_distance_mm": 12.5, "position_x_mm": 123.4,
    "position_y_mm": -56.7, "heading_rad": 9.0,
})
body_odor_wire = body_odor.to_dict()
check("BodyPacket odor telemetry clamps and round-trips",
      body_odor.odor_left == 1.0 and body_odor.odor_right == 0.0 and
      body_odor.nearest_food_distance_mm == 12.5 and
      body_odor.position_x_mm == 123.4 and body_odor.position_y_mm == -56.7 and
      abs(body_odor.heading_rad - math.pi) < 1e-12 and
      body_odor_wire["odor_left"] == 1.0 and body_odor_wire["odor_right"] == 0.0 and
      body_odor_wire["nearest_food_distance_mm"] == 12.5 and
      body_odor_wire["position_x_mm"] == 123.4 and body_odor_wire["position_y_mm"] == -56.7 and
      abs(body_odor_wire["heading_rad"] - math.pi) < 1e-12, repr(body_odor_wire))


# 4. Approach is an actual object animation, not a scripted fly behavior.
world.reset()
world.spawn_object(shape="box", object_id="loom", position_mm=[20, 0, 5], size_mm=[6, 6, 6])
world.start_approach("loom", fly_position_mm=[0, 0, 0.7], end_distance_mm=8, speed_mm_s=10)
for _ in range(12):
    world.pre_step(0.1)
loom_x = world.objects["loom"].position_mm[0]
events = world.drain_events()
check("approach reaches stop distance", abs(loom_x - 8.0) < 1e-8, str(loom_x))
check("approach completion event", any(e.get("event") == "approach_complete" for e in events), repr(events))


# 5. Eye masking / temperature / timed wind and touch state are explicit models.
world.set_eye_state(left_mask=1.0, right_enabled=False)
eyes = world.state()["eyes"]
check("eye state", eyes["left_mask"] == 1.0 and not eyes["right_enabled"] and
      eyes["classification"] == "SENSORY-MODEL", repr(eyes))
try:
    import numpy as np
    frames = np.ones((2, 3, 4, 3), dtype=float)
    masked = world.apply_eye_mask(frames)
    check("eye mask zeros covered/disabled eyes", float(masked.sum()) == 0.0)
except Exception as exc:
    check("eye mask array", False, repr(exc))

temperature = world.set_temperature(celsius=32, mode="modeled_physiology")
check("modeled temperature stays neural-disconnected", temperature["celsius"] == 32.0 and
      temperature["mode"] == "modeled_physiology" and not temperature["neural_connected"] and
      temperature["controller_tempo_via_brain_packet"], repr(temperature))
flywire_temperature = world.set_temperature(celsius=32, mode="flywire_sensory")
check("flywire temperature declares identified neural target",
      flywire_temperature["mode"] == "flywire_sensory" and
      flywire_temperature["neural_connected"] and
      flywire_temperature["neural_target"] == "TRN_VP2 / TRN_VP3a+VP3b",
      repr(flywire_temperature))

world.flash_eye(eye="left", intensity=0.8, duration_ms=100)
visual = world.augment_vision_state({
    "loom_left": 0.21, "loom_right": 0.13,
    "brightness_left": 0.2, "brightness_right": 0.3, "brightness": 0.25,
})
check("flash changes brightness only", visual["loom_left"] == 0.21 and
      visual["loom_right"] == 0.13 and visual["brightness_left"] == 0.8 and
      visual["brightness_right"] == 0.3 and visual["flash_left"] == 0.8 and
      visual["flash_right"] == 0.0, repr(visual))
world.pre_step(0.1)
check("flash expires", world.state()["flash"]["intensity"] == 0.0)

zero_flash_world = LabWorld()
zero_flash = zero_flash_world.flash_eye(eye="right", intensity=0.0, duration_ms=500)
check("zero-intensity flash has no live timer",
      zero_flash["intensity"] == 0.0 and zero_flash["remaining_ms"] == 0.0,
      repr(zero_flash))
check("zero-intensity flash emits no stale event", zero_flash_world.drain_events() == [])

world.set_wind(strength=0.7, direction_deg=90, duration_ms=100, continuous=False)
wind_before_wall_wait = world.state()["wind"]["remaining_ms"]
time.sleep(0.12)
wind_after_wall_wait = world.state()["wind"]["remaining_ms"]
check("timed wind is simulation-time based, not wall-clock based",
      world.state()["wind"]["strength"] == 0.7 and
      abs(wind_after_wall_wait - wind_before_wall_wait) < 1e-9,
      f"before={wind_before_wall_wait:.3f}ms after={wind_after_wall_wait:.3f}ms")
world.pre_step(0.05)
check("timed wind active", 45 <= world.state()["wind"]["remaining_ms"] <= 55)
world.pre_step(0.05)
check("timed wind expires", world.state()["wind"]["strength"] == 0.0)

world.apply_touch(target="thorax", strength=0.5, duration_ms=20)
world.pre_step(0.01)
check("touch pulse active", world.state()["touch"] is not None)
world.pre_step(0.01)
check("touch pulse expires", world.state()["touch"] is None)

reset_world = LabWorld()
reset_world.set_wind(strength=0.8, direction_deg=123, continuous=True,
                     physical=False, sensory=False)
reset_world.apply_touch(target="thorax", strength=0.5, duration_ms=40)
reset_world.flash_eye(eye="left", intensity=0.7, duration_ms=200)
reset_world.set_eye_state(left_mask=1.0, right_enabled=False)
reset_world.set_temperature(celsius=34, mode="flywire_sensory")
reset_world.reset()
reset_state = reset_world.state()
check("reset_world clears queued stimulus events", reset_world.drain_events() == [])
check("reset_world restores wind option flags",
      reset_state["wind"]["strength"] == 0.0 and
      reset_state["wind"]["physical_enabled"] and reset_state["wind"]["sensory_enabled"],
      repr(reset_state["wind"]))
check("reset_world restores eye/flash/temperature flags",
      reset_state["touch"] is None and reset_state["flash"]["intensity"] == 0.0 and
      reset_state["flash"]["remaining_ms"] == 0.0 and
      reset_state["eyes"]["left_mask"] == 0.0 and reset_state["eyes"]["right_enabled"] and
      reset_state["temperature"]["mode"] == "environment_only" and
      reset_state["temperature"].get("neural_target") is None and
      not reset_state["temperature"]["controller_tempo_via_brain_packet"],
      repr(reset_state))


# 6. lab_state keeps the complete nested state plus Swift's flat summary fields.
state_packet = LabStatePacket(ack=44, ok=True, state={
    "t": 1.25,
    "objects": [{"id": "x"}],
    "wind": {"strength": 0.6},
    "temperature": {"celsius": 28.0},
    "eyes": {"left_enabled": True, "right_enabled": True, "left_mask": 1.0, "right_mask": 0.0},
    "last_action": "wind",
})
wire = json.loads(encode(state_packet))
check("lab_state Swift flat summary", wire["ack"] == 44 and wire["object_count"] == 1 and
      wire["wind"] == 0.6 and wire["temperature"] == 28.0 and
      wire["left_eye_covered"] is True and wire["right_eye_covered"] is False and
      wire["last_action"] == "wind", repr(wire))


# 7. Bridge mock path proves receive-thread enqueue -> owner-loop apply -> ack.
bridge = Bridge(mode="mock")
bridge.handle_line(
    b'{"type":"lab_command","id":91,"action":"spawn_sphere","target":"ball",'
    b'"x":15,"y":0,"z":3,"size":4}\n')
check("bridge receive only queues lab command", bridge.lab_commands.stats()["discrete_pending"] == 1 and
      "ball" not in bridge.body.lab_world.objects)
bridge._apply_lab_commands()
responses = bridge._drain_lab_responses()
check("owner loop applies lab command", "ball" in bridge.body.lab_world.objects)
check("owner loop emits ack lab_state", len(responses) == 1 and isinstance(responses[0], LabStatePacket) and
      responses[0].ack == 91 and responses[0].ok, repr(responses))

eye_bridge = Bridge(mode="mock")
eye_bridge.handle_line(
    b'{"type":"lab_command","id":101,"action":"set_eye_state","target":"left","value":1}\n')
eye_bridge.handle_line(
    b'{"type":"lab_command","id":102,"action":"set_eye_state","target":"right","value":1}\n')
eye_bridge._apply_lab_commands()
eye_state = eye_bridge.body.lab_world.state()["eyes"]
check("same-tick bridge left/right eye commands both apply",
      eye_state["left_mask"] == 1.0 and eye_state["right_mask"] == 1.0,
      repr(eye_state))

bridge.handle_line(
    b'{"type":"lab_command","id":92,"action":"touch","strength":0.4,"duration_ms":10}\n')
bridge._apply_lab_commands()
bridge.body.step(type("C", (), {"forward": 0.0, "reverse": False, "moving": True,
                                  "urgent": False, "steering": 0.0})(), 0.02)
bridge._collect_lab_events()
responses = bridge._drain_lab_responses()
check("bridge emits lab_event", any(isinstance(p, LabEventPacket) for p in responses), repr(responses))

# 8. Body reset is discrete and preserves the experiment world.
bridge.body.x = 0.012
bridge.body.y = -0.004
bridge.handle_line(b'{"type":"lab_command","id":93,"action":"reset_body"}\n')
bridge._apply_lab_commands()
check("reset_body resets mock pose", bridge.body.x == 0.0 and bridge.body.y == 0.0 and bridge.body.t == 0.0)
check("reset_body preserves lab objects", "ball" in bridge.body.lab_world.objects)

# 9. Mock body packets populate modeled food odor + body heading without any
# scripted movement/reward coupling.
bridge.body.lab_world.spawn_object(
    shape="food", object_id="mock_food", position_mm=[0, 10, 0.7], size_mm=2)
mock_obs = bridge.body.observe()
check("mock body emits food odor telemetry",
      max(mock_obs.odor_left, mock_obs.odor_right) > 0.0 and
      mock_obs.nearest_food_distance_mm is not None,
      repr(mock_obs))
check("mock body emits separate heading telemetry", abs(mock_obs.heading_rad) < 1e-12,
      repr(mock_obs.heading_rad))


print("ALL LAB TESTS PASS" if not fails else f"{len(fails)} FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
