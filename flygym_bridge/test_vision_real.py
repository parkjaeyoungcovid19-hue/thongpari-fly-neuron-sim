"""Real FlyGym eye-render smoke tests for the V2 generic looming decoder.

Run from ``flygym_bridge`` with::

    ../flygym-venv/bin/python test_vision_real.py

This intentionally lives apart from ``test_lab_real.py``.  The approach test
uses real FlyGym eye-camera renders and the production ``VisionLoomDetector``.
The object is LabWorld's default green food marker, so any positive looming
response with zero legacy target-color occupancy comes from the generic image
motion path rather than the magenta compatibility mask.

Image-space pan is a deterministic transform of a real rendered frame; it is a
decoder invariant test, not a claim that ``np.roll`` models fly eye motion.
LabWorld flash is tested through its real production semantics: it augments
brightness telemetry and does not alter rendered pixels or looming.
"""

from __future__ import annotations

import math
import time

import mujoco
import numpy as np

from fly_body import RealFlyBody
from vision_decoder import VisionLoomDetector


fails = []


def check(name, condition, detail=""):
    print(("PASS" if condition else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not condition:
        fails.append(name)


def render(body):
    """Render both production eye cameras and report wall-clock render cost."""
    start = time.perf_counter()
    frame = body.sim.get_raw_vision("fly")
    return frame, time.perf_counter() - start


body = RealFlyBody(config={}, show_viewer=False)
try:
    world = body.lab_world

    # V5.4 participant proof (V5-02): keep the same *active* backend geometry,
    # first outside the eye field and then inside it. The world snapshot must
    # report the exact pose used for both renders, and the actual FlyGym stereo
    # frames must change. This is not an inactive-vs-active rendering shortcut.
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    world.set_player_active(True)
    outside_pos = [24.0, 120.0, 2.5]
    world.set_player_pose(position_mm=outside_pos)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    player_outside, _ = render(body)
    outside_pose = body.world_render_state().get("player") or {}
    outside_revision = world.revision
    inside_pos = [24.0, 0.0, 2.5]
    world.set_player_pose(position_mm=inside_pos)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    player_inside, _ = render(body)
    inside_pose = body.world_render_state().get("player") or {}
    inside_revision = world.revision
    player_eye_delta = float(np.mean(np.abs(
        player_inside.astype(float) - player_outside.astype(float))))
    check(
        "V5.4 participant outside->inside changes actual FlyGym eye pixels with pose provenance",
        player_inside.shape == player_outside.shape and player_eye_delta > 0.05
        and outside_pose.get("actor_id") == "player"
        and np.allclose(outside_pose.get("position_mm", []), outside_pos, atol=1e-12)
        and np.allclose(inside_pose.get("position_mm", []), inside_pos, atol=1e-12)
        and inside_revision == outside_revision + 1,
        f"mean_abs_delta={player_eye_delta:.3f} outside={outside_pose} inside={inside_pose}",
    )
    world.set_player_active(False)
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)

    # Default food is green in LabWorld and deliberately outside the historical
    # magenta target mask. Keep it on the fly's forward axis so both broad-FOV
    # eyes see a clean angular expansion as it approaches.
    world.spawn_object(
        shape="food", object_id="vision_food", position_mm=[24.0, 0.0, 2.0], size_mm=6.0)
    food = world.objects["vision_food"]
    _, food_gid, _ = world._slot_ids[food.slot]
    food_rgba = np.asarray(body.sim.mj_model.geom_rgba[food_gid], dtype=float)
    check(
        "approach object uses default non-magenta color",
        food_rgba[1] > food_rgba[0] and food_rgba[1] > food_rgba[2],
        f"rgba={food_rgba.tolist()}",
    )

    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    far, far_render_s = render(body)
    world.move_object("vision_food", position_mm=[10.0, 0.0, 2.0])
    mujoco.mj_forward(body.sim.mj_model, body.sim.mj_data)
    near, near_render_s = render(body)

    check("real eye render shape", far.shape == (2, 96, 84, 3) and near.shape == far.shape, str(far.shape))
    check(
        "real approach changes rendered eye pixels",
        float(np.mean(np.abs(near.astype(float) - far.astype(float)))) > 1.0,
        f"mean_abs_delta={float(np.mean(np.abs(near.astype(float) - far.astype(float)))):.3f}",
    )

    detector = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    detector.analyze(far, 0.20)
    approach = detector.analyze(near, 0.20)
    peak_expansion = max(approach["optic_expansion_left"], approach["optic_expansion_right"])
    peak_loom = max(approach["loom_left"], approach["loom_right"])
    check(
        "green real-render approach drives generic optic expansion",
        peak_expansion > 0.10 and peak_loom > 0.05,
        f"expansion={peak_expansion:.3f} loom={peak_loom:.3f}",
    )
    check(
        "green approach bypasses legacy target-color occupancy",
        max(approach["occupancy_left"], approach["occupancy_right"]) < 1e-6,
        f"occupancy=({approach['occupancy_left']:.6f},{approach['occupancy_right']:.6f})",
    )

    # Reverse the same two real renders with fresh state. Positive looming should
    # remain near zero for contraction.
    contraction_detector = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    contraction_detector.analyze(near, 0.20)
    contraction = contraction_detector.analyze(far, 0.20)
    contraction_peak = max(contraction["optic_expansion_left"], contraction["optic_expansion_right"])
    check(
        "real-render contraction suppresses positive looming",
        contraction_peak < 0.05 and max(contraction["loom_left"], contraction["loom_right"]) < 0.05,
        f"expansion={contraction_peak:.3f} loom=({contraction['loom_left']:.3f},{contraction['loom_right']:.3f})",
    )

    # Deterministic whole-image translation of an actual FlyGym render. The shift
    # is exactly representable on the decoder's 4x pooled grid.
    pan_detector = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    pan_detector.analyze(far, 0.20)
    panned = np.roll(far, shift=(4, 8), axis=(1, 2))
    pan = pan_detector.analyze(panned, 0.20)
    pan_peak = max(pan["optic_expansion_left"], pan["optic_expansion_right"])
    check(
        "real-frame global pan suppresses false looming",
        pan_peak < 0.05 and max(pan["loom_left"], pan["loom_right"]) < 0.05,
        f"expansion={pan_peak:.3f} loom=({pan['loom_left']:.3f},{pan['loom_right']:.3f})",
    )

    # Production flash semantics are a brightness telemetry overlay. It never
    # rewrites the eye image, so it must preserve decoder looming exactly.
    flash_detector = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    flash_detector.analyze(far, 0.20)
    stable = flash_detector.analyze(far, 0.20)
    world.flash_eye(eye="both", intensity=0.85, duration_ms=100)
    flashed = world.augment_vision_state(stable)
    check(
        "production flash preserves looming",
        flashed["loom_left"] == stable["loom_left"]
        and flashed["loom_right"] == stable["loom_right"]
        and flashed["optic_expansion_left"] == stable["optic_expansion_left"]
        and flashed["optic_expansion_right"] == stable["optic_expansion_right"],
        f"before=({stable['loom_left']:.3f},{stable['loom_right']:.3f}) "
        f"after=({flashed['loom_left']:.3f},{flashed['loom_right']:.3f})",
    )
    check(
        "production flash raises brightness telemetry",
        flashed["flash_left"] == 0.85
        and flashed["flash_right"] == 0.85
        and flashed["brightness_left"] >= 0.85
        and flashed["brightness_right"] >= 0.85,
        f"brightness=({flashed['brightness_left']:.3f},{flashed['brightness_right']:.3f})",
    )

    # Cover/open uses the exact production eye-mask transform on a real render.
    # A cover is expected to remove that eye's brightness; reopening the identical
    # scene should recover it without manufacturing a looming event.
    eye_detector = VisionLoomDetector(target_rgb=(0.92, 0.08, 0.72))
    eye_detector.analyze(far, 0.20)
    world.set_eye_state(left_mask=1.0)
    covered = eye_detector.analyze(world.apply_eye_mask(far), 0.20)
    world.set_eye_state(left_mask=0.0)
    reopened = eye_detector.analyze(world.apply_eye_mask(far), 0.20)
    check(
        "left eye cover zeros rendered brightness without false loom",
        covered["brightness_left"] == 0.0
        and covered["optic_expansion_left"] < 0.05
        and covered["loom_left"] < 0.05,
        f"brightness={covered['brightness_left']:.3f} expansion={covered['optic_expansion_left']:.3f}",
    )
    check(
        "left eye reopen restores input without false loom",
        reopened["brightness_left"] > 0.1
        and reopened["optic_expansion_left"] < 0.05
        and reopened["loom_left"] < 0.05,
        f"brightness={reopened['brightness_left']:.3f} expansion={reopened['optic_expansion_left']:.3f}",
    )

    check("vision cadence remains 5 Hz", math.isclose(body.vision_period, 0.20), f"period={body.vision_period}")
    print(
        "INFO  real eye render timing: "
        f"far={far_render_s * 1000:.1f} ms near={near_render_s * 1000:.1f} ms "
        f"mean={(far_render_s + near_render_s) * 500:.1f} ms/stereo-pair"
    )
finally:
    body.close()


print("ALL REAL VISION TESTS PASS" if not fails else f"{len(fails)} REAL VISION FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
