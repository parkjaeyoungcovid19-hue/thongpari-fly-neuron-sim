"""V6.4 terrain on real MuJoCo: render/collision agreement and a walkable ramp.

Builds RealFlyBody twice (with and without the ramp leg pairs); no listener,
window or viewer. Run:
PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_v6_4_terrain_real.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mujoco
import numpy as np

from fly_body import RealFlyBody
from neural_decoder import LocomotorCommand

fails = []


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not ok:
        fails.append(name)


def quat_matrix(q_xyzw):
    x, y, z, w = q_xyzw
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
                     [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
                     [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]])


def render_vs_collision(body):
    """Each primitive's reported render pose/size is the collision geom's, and
    probe spheres just inside/outside each face confirm the colliding extent."""
    w = body.lab_world
    model, data = w.model, w.data
    cases = (("box", dict(size_mm=[12, 6, 4], yaw_deg=35)),
             ("wall", dict(size_mm=[2, 30, 15], yaw_deg=120)),
             ("sphere", dict(size_mm=6)),
             ("ramp", dict(size_mm=[30, 12, 2], yaw_deg=60, pitch_deg=25)))
    probe = w.spawn_object(shape="sphere", object_id="probe", position_mm=[0, 0, -100], size_mm=0.4)
    probe_gid = w._slot_ids[w.objects["probe"].slot][1]
    worst_pose = worst_probe = 0.0
    sign_errors = []
    for index, (shape, kwargs) in enumerate(cases):
        oid = f"rc_{shape}"
        w.spawn_object(shape=shape, object_id=oid, position_mm=[-60 + 40 * index, 60, 20], **kwargs)
        mujoco.mj_forward(model, data)
        gid = w._slot_ids[w.objects[oid].slot][1]
        rendered = next(o for o in w.render_objects() if o["id"] == oid)
        rot = quat_matrix(rendered["orientation_quat_xyzw"])
        if shape != "sphere":
            worst_pose = max(worst_pose, float(np.abs(rot - data.geom_xmat[gid].reshape(3, 3)).max()))
        worst_pose = max(worst_pose,
                         float(np.abs(np.array(rendered["position_mm"]) - data.geom_xpos[gid]).max()))
        half = np.array(rendered["size_mm"]) * 0.5
        if shape == "sphere":
            worst_pose = max(worst_pose, abs(half[0] - model.geom_size[gid][0]))
            axes = [np.array(v, float) for v in ((1, 0, 0), (0, 1, 0), (0, 0, 1))]
            extents = [half[0]] * 3
        else:
            worst_pose = max(worst_pose, float(np.abs(half - model.geom_size[gid][:3]).max()))
            axes = [rot[:, i] for i in range(3)]
            extents = list(half)
        for axis, extent in zip(axes, extents):
            for sign in (1, -1):
                for offset, want_inside in ((-0.3, True), (0.5, False)):
                    point = np.array(rendered["position_mm"]) + sign * axis * (extent + offset)
                    w.move_object("probe", position_mm=point.tolist())
                    mujoco.mj_forward(model, data)
                    distance = mujoco.mj_geomDistance(model, data, gid, probe_gid, 50, np.zeros(6))
                    # Probe radius 0.2: outside by 0.5 -> +0.3, inside by 0.3 -> < 0.
                    expected = offset - 0.2 if not want_inside else None
                    if (distance < 0) != want_inside:
                        sign_errors.append((shape, round(offset, 2), round(float(distance), 3)))
                    elif expected is not None:
                        worst_probe = max(worst_probe, abs(distance - expected))
        w.remove_object(oid)
    w.remove_object("probe")
    check("render pose/size equals the collision geom (box, wall, sphere, tilted ramp)",
          worst_pose < 1e-9, f"max deviation {worst_pose:.2e}")
    check("probes inside every face collide, probes outside do not",
          not sign_errors, f"errors={sign_errors[:4]}")
    check("outside clearance matches the rendered extent", worst_probe < 1e-6,
          f"max error {worst_probe:.2e} mm")


def climb(body, seconds=4.0):
    """Walk straight at a flush 15 degree ramp whose low edge is 4 mm ahead."""
    w = body.lab_world
    w.spawn_object(shape="ramp", object_id="climb")
    ramp = w.objects["climb"]
    anchor = ramp.ramp_anchor()
    w.move_object("climb", position_mm=[c + d for c, d in zip(ramp.position_mm, (4.0 - anchor[0], -anchor[1], 0.0))])
    model, data = w.model, w.data
    ramp_gid = w._slot_ids[ramp.slot][1]
    thorax = body.controller_obs.thorax_body
    tarsus_geoms = {g for g in range(model.ngeom)
                    if "tarsus" in (mujoco.mj_id2name(model, mujoco.mjtObj.mjOBJ_GEOM, g) or "")}
    walk = LocomotorCommand(forward=1.0, moving=True)
    max_z = start_z = float(data.xpos[thorax, 2])
    feet_on_ramp = set()
    for _ in range(int(seconds / 0.002)):
        body.step_exact(walk, 20)
        max_z = max(max_z, float(data.xpos[thorax, 2]))
        for c in data.contact[:data.ncon]:
            pair = {int(c.geom1), int(c.geom2)}
            if ramp_gid in pair and c.dist <= 0:
                feet_on_ramp |= pair & tarsus_geoms
    x = float(data.xpos[thorax, 0])
    surface = (x - 4.0) * math.tan(math.radians(15.0))
    w.remove_object("climb")
    return start_z, max_z, x, surface, len(feet_on_ramp)


body = RealFlyBody(config={}, show_viewer=False)
try:
    w = body.lab_world
    st = w.state()
    pairs, templates = st["terrain_contact_pairs"], w._terrain_template_count
    names = {p.geomname1.split("/")[-1] for p in body.world.mjcf_root.pairs
             if p.name.startswith("v64-lab_ramp_0-")}
    check("each ramp slot pairs with the fly's tibiae, tarsi and body (not BB pellets)",
          pairs == 4 * templates and templates == 43 and
          all(n.startswith("c_") or "_tibia" in n or "_tarsus" in n for n in names),
          f"{pairs} pairs = 4 slots x {templates} fly geoms")
    ground_pair = next(p for p in body.world.mjcf_root.pairs if p.geomname2 in w._ground_geom_names)
    ramp_pair = next(p for p in body.world.mjcf_root.pairs if p.name.startswith("v64-"))
    check("ramp contact uses FlyGym's ground friction and solver parameters",
          np.allclose(ground_pair.friction, ramp_pair.friction) and
          np.allclose(ground_pair.solref, ramp_pair.solref) and
          np.allclose(ground_pair.solimp, ramp_pair.solimp))
    render_vs_collision(body)
    start_z, max_z, x, surface, feet = climb(body)
    check("the fly climbs the ramp on its own legs",
          max_z > start_z + 2.0 and feet >= 3,
          f"thorax z {start_z:.2f} -> max {max_z:.2f} mm, x {x:.1f} mm "
          f"(ramp top there {surface:.2f} mm), tarsus geoms touching ramp {feet}")
finally:
    body.close()

# Negative control: identical ramp without the leg pairs (body pairs remain).
control = RealFlyBody(config={"terrain_leg_contact": False}, show_viewer=False)
try:
    c_start, c_max, c_x, c_surface, c_feet = climb(control)
    check("control: without leg pairs the legs pass through and the fly stays low",
          c_feet == 0 and c_max < start_z + 2.0,
          f"thorax z {c_start:.2f} -> max {c_max:.2f} mm, x {c_x:.1f} mm, tarsus on ramp {c_feet}")
finally:
    control.close()

print("V6.4 TERRAIN REAL: " + ("0 FAIL" if not fails else f"{len(fails)} FAIL {fails}"))
raise SystemExit(0 if not fails else 1)
