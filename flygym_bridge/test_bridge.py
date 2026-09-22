"""Deterministic bridge tests (no MuJoCo, no sockets):
1. BrainSignals serialization round-trip
2. malformed packet handling
3. walkDrive mapping
4. turnBias sign
5. escape pulse preservation
6. sensory packet parsing
7. feedback clamping
8. bounded state (mock body has fixed-size state; bridge coalesces)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from protocol import BrainPacket, BodyPacket, LabCommand, decode_line, encode
from bridge import Bridge
from neural_decoder import decode
from fly_body import MockBody, brain_to_descending
from vision_decoder import VisionLoomDetector

fails = []
def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not cond:
        fails.append(name)

# 1. serialization round-trip
b = BrainPacket(t=1.234, walk=0.52, turn=-0.18, escape=True, backward=False,
                groom=0.02, wing=0.0, arousal=0.31, tempo=1.0, sleep=False, nervous=0.4)
rt = decode_line(encode(b))
check("serialization round-trip", isinstance(rt, BrainPacket) and abs(rt.walk-0.52)<1e-9 and rt.turn==-0.18 and rt.escape and abs(rt.t-1.234)<1e-9)

# 2. malformed handling
check("malformed: garbage", decode_line(b"not json\n") is None)
check("malformed: array", decode_line(b"[1,2]\n") is None)
check("malformed: unknown type", decode_line(b'{"type":"nope"}\n') is None)
check("malformed: empty", decode_line(b"\n") is None)
check("malformed: binary", decode_line(bytes([255, 254, 10])) is None)

# 3. walkDrive mapping
cmd = decode(BrainPacket(walk=0.0))
check("walk 0 -> forward 0", cmd.forward == 0.0, str(cmd.forward))
cmd = decode(BrainPacket(walk=0.52))
check("walk 0.52 -> forward ~0.52", abs(cmd.forward-0.52)<1e-9, str(cmd.forward))
cmd = decode(BrainPacket(walk=5.0))
check("walk clamps to 1", cmd.forward == 1.0, str(cmd.forward))

# 4. turnBias sign
check("turn -0.18 stays negative", decode(BrainPacket(turn=-0.18)).steering < 0)
check("turn +0.4 stays positive", decode(BrainPacket(turn=0.4)).steering > 0)
check("turn 0 -> 0", decode(BrainPacket(turn=0.0)).steering == 0.0)

# 5. escape pulse
c0 = decode(BrainPacket(walk=0.1, escape=False))
c1 = decode(BrainPacket(walk=0.1, escape=True))
check("escape boosts forward", c1.forward > c0.forward and c1.urgent and not c0.urgent, f"{c0.forward}->{c1.forward}")
check("escape gated by sleep", decode(BrainPacket(walk=0.5, escape=True, sleep=True)).moving == False)

# sleep gates locomotion
cs = decode(BrainPacket(walk=0.6, turn=0.5, sleep=True))
check("sleep stops motion", cs.forward == 0.0 and cs.steering == 0.0 and not cs.moving)

# backward only a flag (controller decides)
check("backward flag", decode(BrainPacket(backward=True)).reverse == True)
check("backward gated by sleep", decode(BrainPacket(backward=True, sleep=True)).reverse == False)

# groom/wing exposed, not faked
cg = decode(BrainPacket(groom=0.8, wing=0.5))
check("groom/wing exposed", abs(cg.groom_state-0.8)<1e-9 and abs(cg.wing_state-0.5)<1e-9)
check("zero walk has zero descending drive",
      brain_to_descending(decode(BrainPacket(walk=0.0))) == (0.0, 0.0))
left_turn = brain_to_descending(decode(BrainPacket(walk=0.7, turn=0.2)))
check("positive turn speeds right side for CCW body turn", left_turn[1] > left_turn[0], str(left_turn))
check("sleep zeros descending drive",
      brain_to_descending(decode(BrainPacket(walk=1.0, turn=1.0, sleep=True))) == (0.0, 0.0))

# 6. sensory packet parsing
s = decode_line(b'{"type":"body","t":1.238,"controller_left":0.21,"controller_right":0.43,"wind_strength":0.7,"wind_direction_deg":330,"wind_sensory":true,"touch_strength":0.55,"touch_sensory":true,"vx":0.013,"yaw_rate":-0.12,"contacts":[1,1,0,0,1,0],"left_contact":0.67,"right_contact":0.33,"loom_left":0.7,"loom_right":0.2,"brightness":0.4,"brightness_left":0.3,"brightness_right":0.5,"occupancy_left":0.2,"occupancy_right":0.1,"optic_expansion_left":0.8,"optic_expansion_right":0.25,"eye_sample_sim_tick":1200,"flash_left":0.6,"flash_right":0.0,"bearing":0.5}\n')
check("body parse", isinstance(s, BodyPacket) and abs(s.vx-0.013)<1e-9 and s.contacts==[1,1,0,0,1,0]
      and abs(s.left_contact-0.67)<1e-9 and abs(s.loom_left-0.7)<1e-9
      and abs(s.loom_right-0.2)<1e-9 and abs(s.bearing-0.5)<1e-9
      and abs(s.brightness_left-0.3)<1e-9 and abs(s.brightness_right-0.5)<1e-9
      and abs(s.occupancy_left-0.2)<1e-9 and abs(s.occupancy_right-0.1)<1e-9
      and abs(s.optic_expansion_left-0.8)<1e-9 and abs(s.optic_expansion_right-0.25)<1e-9
      and s.eye_sample_sim_tick == 1200
      and abs(s.flash_left-0.6)<1e-9 and s.flash_right == 0.0
      and abs(s.controller_left-0.21)<1e-9 and abs(s.controller_right-0.43)<1e-9
      and abs(s.wind_strength-0.7)<1e-9 and abs(s.wind_direction_deg-330)<1e-9
      and s.wind_sensory and abs(s.touch_strength-0.55)<1e-9 and s.touch_sensory)

# 7. clamping
c = decode_line(b'{"type":"body","vx":99,"yaw_rate":-99,"contacts":[9,-9,2,2,2,2,2,2],"left_contact":5,"right_contact":-5,"loom_left":9,"loom_right":-2,"brightness":7,"bearing":-9}\n')
check("body clamps", c is not None and c.vx==2.0 and c.yaw_rate==-20.0 and c.contacts==[1.0,0.0,1.0,1.0,1.0,1.0]
      and c.left_contact==1.0 and c.right_contact==0.0 and c.loom_left==1.0
      and c.loom_right==0.0 and c.brightness==1.0 and c.brightness_left == 1.0
      and c.brightness_right == 1.0 and c.bearing==-1.0)
cb = decode_line(b'{"type":"brain","walk":99,"turn":-99}\n')
check("brain clamps", cb is not None and cb.walk==1.5 and cb.turn==-1.0)
cn = decode_line(b'{"type":"brain","walk":"NaN","t":"Infinity"}\n')
check("non-finite values rejected to safe zero", cn is not None and cn.walk == 0.0 and cn.t == 0.0)

timed = BodyPacket(t=2.0, sim_dt=0.002, wall_dt=0.016, sim_wall_ratio=0.125,
                   eye_sample_sim_tick=1800)
timed_rt = decode_line(encode(timed))
check("body sim/wall timing round-trip",
      isinstance(timed_rt, BodyPacket) and abs(timed_rt.sim_dt - 0.002) < 1e-12 and
      abs(timed_rt.wall_dt - 0.016) < 1e-12 and abs(timed_rt.sim_wall_ratio - 0.125) < 1e-12 and
      timed_rt.eye_sample_sim_tick == 1800,
      repr(timed_rt))

# Stale-brain safety is based only on a monotonic timestamp. Wall-clock jumps
# therefore cannot accidentally keep an old motor command alive or kill a fresh one.
clock_bridge = Bridge(mode="mock")
clock_bridge.handle_line(b'{"type":"brain","walk":0.6,"tempo":1.35}\n')
received_mono = clock_bridge.last_brain_mono
fresh_cmd, fresh_tempo, fresh_age, fresh_stale = clock_bridge._brain_snapshot(received_mono + 0.5)
stale_cmd, stale_tempo, stale_age, stale_flag = clock_bridge._brain_snapshot(received_mono + 1.01)
check("fresh brain snapshot uses monotonic age",
      not fresh_stale and fresh_cmd.forward > 0.5 and abs(fresh_tempo - 1.35) < 1e-12 and
      abs(fresh_age - 0.5) < 1e-9)
check("stale brain snapshot rests body and tempo",
      stale_flag and stale_cmd.forward == 0.0 and stale_tempo == 1.0 and stale_age > 1.0)

# 8. mock body bounded + responsive
m = MockBody()
from neural_decoder import LocomotorCommand
still = m.step(LocomotorCommand(forward=0.0), 0.02)
check("mock still when no drive", abs(still.vx) < 1e-9 and sum(still.contacts) == 0.0)
for _ in range(100):
    moving = m.step(LocomotorCommand(forward=0.6, steering=0.3), 0.02)
check("mock walks and yaws", moving.vx > 0.005 and moving.yaw_rate > 0.1, f"vx={moving.vx:.4f} yaw={moving.yaw_rate:.3f}")
ml = m.step(LocomotorCommand(forward=0.6, steering=-0.5), 0.02)
check("mock steering sign flips", ml.yaw_rate < moving.yaw_rate, f"{moving.yaw_rate:.3f}->{ml.yaw_rate:.3f}")
check("mock body exposes sim/wall timing",
      ml.sim_dt > 0.0 and ml.wall_dt > 0.0 and abs(ml.sim_wall_ratio - 1.0) < 1e-12,
      f"sim_dt={ml.sim_dt} wall_dt={ml.wall_dt} ratio={ml.sim_wall_ratio}")
check("mock body exposes exact descending controller L/R",
      abs(ml.controller_left - brain_to_descending(LocomotorCommand(forward=0.6, steering=-0.5))[0]) < 1e-12 and
      abs(ml.controller_right - brain_to_descending(LocomotorCommand(forward=0.6, steering=-0.5))[1]) < 1e-12,
      f"controller=({ml.controller_left:.3f},{ml.controller_right:.3f})")
m.apply_lab_command(LabCommand(1, "wind", {
    "strength": 0.7, "direction_deg": 90, "duration_ms": 40,
    "physical": False, "sensory": True, "continuous": False}))
m.apply_lab_command(LabCommand(2, "touch", {
    "target": "thorax", "strength": 0.55, "duration_ms": 40, "sensory": True}))
stim_obs = m.step(LocomotorCommand(forward=0.0), 0.02)
check("mock body packet exposes active LabWorld wind/touch source state",
      abs(stim_obs.wind_strength - 0.7) < 1e-12 and stim_obs.wind_direction_deg == 90.0
      and stim_obs.wind_sensory and abs(stim_obs.touch_strength - 0.55) < 1e-12
      and stim_obs.touch_sensory,
      f"wind=({stim_obs.wind_strength},{stim_obs.wind_direction_deg},{stim_obs.wind_sensory}) "
      f"touch=({stim_obs.touch_strength},{stim_obs.touch_sensory})")
expired_obs = m.step(LocomotorCommand(forward=0.0), 0.02)
check("mock body packet clears expired LabWorld wind/touch source state",
      expired_obs.wind_strength == 0.0 and expired_obs.touch_strength == 0.0
      and not expired_obs.touch_sensory,
      f"wind={expired_obs.wind_strength} touch=({expired_obs.touch_strength},{expired_obs.touch_sensory})")
m.lab_world.spawn_object(shape="food", object_id="mock_food", position_mm=[0, 10, 0.7], size_mm=2)
odor_obs = m.step(LocomotorCommand(forward=0.0), 0.02)
check("mock food reaches body odor telemetry",
      max(odor_obs.odor_left, odor_obs.odor_right) > 0.0 and
      odor_obs.nearest_food_distance_mm is not None,
      f"odor=({odor_obs.odor_left:.3f},{odor_obs.odor_right:.3f}) d={odor_obs.nearest_food_distance_mm}")

# 9. vision decoder: looming is derived from image expansion, not coordinates.
try:
    import numpy as np

    def stereo(left, right=None):
        if right is None:
            right = np.zeros_like(left)
        return np.stack([left, right])

    def square(size, color=(160, 160, 160), center=(40, 50)):
        frame = np.zeros((80, 100, 3), dtype=np.uint8)
        half = size // 2
        y, x = center
        frame[y-half:y-half+size, x-half:x-half+size] = color
        return frame

    expected_state_keys = {
        "loom_left", "loom_right", "brightness", "brightness_left", "brightness_right",
        "occupancy_left", "occupancy_right", "optic_expansion_left",
        "optic_expansion_right", "bearing",
    }

    # Legacy target-color experiment remains compatible.
    vd = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    f0 = np.zeros((2, 80, 100, 3), dtype=np.uint8)
    f1 = f0.copy(); f1[0, 36:44, 46:54] = [235, 20, 184]
    f2 = f0.copy(); f2[0, 30:50, 40:60] = [235, 20, 184]
    vd.analyze(f0, 0.1)
    vd.analyze(f1, 0.1)
    vis = vd.analyze(f2, 0.1)
    check("vision expansion -> left loom", vis["loom_left"] > 0.2 and vis["loom_right"] < 0.05,
          str(vis))
    check("vision bearing follows eye occupancy", vis["bearing"] > 0.8, str(vis["bearing"]))

    # Generic path: neutral gray is far from the configured magenta chromaticity,
    # so this response must come from image motion rather than the legacy mask.
    generic = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    generic.analyze(stereo(square(8)), 0.1)
    grow = generic.analyze(stereo(square(20)), 0.1)
    check("generic gray expansion -> positive loom",
          grow["optic_expansion_left"] > 0.15 and grow["loom_left"] > 0.1,
          str(grow))
    check("vision public state keys preserved", set(grow) == expected_state_keys, str(sorted(grow)))
    decayed = generic.decay(0.20)
    check("raw optic expansion decays between render samples",
          decayed["optic_expansion_left"] < grow["optic_expansion_left"] * 0.25 and
          decayed["loom_left"] < grow["loom_left"],
          f"raw {grow['optic_expansion_left']:.3f}->{decayed['optic_expansion_left']:.3f} "
          f"loom {grow['loom_left']:.3f}->{decayed['loom_left']:.3f}")

    # The same edge motion in reverse is contraction and must not create a
    # positive looming event.
    shrinker = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    shrinker.analyze(stereo(square(20)), 0.1)
    shrink = shrinker.analyze(stereo(square(8)), 0.1)
    check("generic contraction -> near-zero loom",
          shrink["optic_expansion_left"] < 0.03 and shrink["loom_left"] < 0.03,
          str(shrink))

    # Whole-field pan should be explained by global translation rather than
    # radial expansion.  Use a deterministic textured image and a translation
    # exactly representable on the 4x pooled grid.
    rng = np.random.default_rng(7)
    texture = rng.integers(0, 256, size=(80, 100, 3), dtype=np.uint8)
    panner = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    panner.analyze(stereo(texture), 0.1)
    pan = panner.analyze(stereo(np.roll(texture, shift=(4, 8), axis=(0, 1))), 0.1)
    check("global pan suppresses false loom",
          pan["optic_expansion_left"] < 0.05 and pan["loom_left"] < 0.05,
          str(pan))

    # A full-field brightness step is a flash/illumination transient; it has no
    # coherent outward edge motion and should not masquerade as looming.
    flasher = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    dark = np.full((80, 100, 3), 25, dtype=np.uint8)
    bright = np.full((80, 100, 3), 225, dtype=np.uint8)
    flasher.analyze(stereo(dark), 0.1)
    flash = flasher.analyze(stereo(bright), 0.1)
    check("full-field flash suppresses false loom",
          flash["optic_expansion_left"] < 0.03 and flash["loom_left"] < 0.03,
          str(flash))
except Exception as e:
    check("vision decoder", False, repr(e))

print("ALL BRIDGE TESTS PASS" if not fails else f"{len(fails)} FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
