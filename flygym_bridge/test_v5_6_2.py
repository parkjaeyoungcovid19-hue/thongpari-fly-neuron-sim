"""V5.6.2 sandbox models and feeding: mock contract checks, then real MuJoCo.

Run: flygym-venv/bin/python flygym_bridge/test_v5_6_2.py [--mock-only]
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sandbox_models as sm
from fly_body import MockBody
from lab_world import LabError, LabWorld, FEED_MIN_DIAMETER_MM
from neural_decoder import LocomotorCommand
from protocol import BodyPacket

fails = []


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not ok:
        fails.append(name)


# ---------------------------------------------------------------- mock ----
# Assert the supported default independently of DEFAULT_SLOT_COUNTS: importing
# that constant here would let an accidental capacity change pass unnoticed.
world = LabWorld()
check("default runtime slot capacity contract",
      world.state()["slot_capacity"] ==
      {"box": 64, "sphere": 64, "wall": 64, "food": 8, "car": 4, "trap": 2, "ramp": 4},
      repr(world.state()["slot_capacity"]))
order = [world.spawn_object(shape="food", position_mm=[40 + 5 * i, 0, 1.5])["food_variant"]
         for i in range(7)]
check("food variants rotate in fixed order",
      order == list(sm.FOOD_VARIANT_ORDER) + [sm.FOOD_VARIANT_ORDER[0]], repr(order))
free_before = world.state()["slot_free"]["food"]
try:
    world.spawn_object(shape="food", variant="pizza")
    rejected = False
except LabError:
    rejected = True
check("unknown food variant rejected without leaking a slot",
      rejected and world.state()["slot_free"]["food"] == free_before)
try:
    world.spawn_object(shape="box", variant="apple")
    rejected = False
except LabError:
    rejected = True
check("variant on a non-food object rejected", rejected)
chosen = world.spawn_object(shape="food", object_id="chosen", variant="cheese")
check("explicit variant honoured and reported",
      chosen["food_variant"] == "cheese" and chosen["sugar_content"] == sm.FOOD_SUGAR["cheese"])
check("all eight default food slots are distinct and occupied",
      world.state()["slot_free"]["food"] == 0 and
      len({obj.slot for obj in world.objects.values() if obj.shape == "food"}) == 8)
full_state = world.state()
try:
    world.spawn_object(shape="food", object_id="overflow")
    overflow_error = None
except LabError as exc:
    overflow_error = str(exc)
check("ninth food rejected without changing world state",
      overflow_error == "no free food slots" and world.state() == full_state,
      repr(overflow_error))
released_slot = world.objects["chosen"].slot
world.remove_object("chosen")
check("deleting food releases exactly one slot",
      world.state()["slot_free"]["food"] == 1 and "chosen" not in world.objects)
world.spawn_object(shape="food", object_id="replacement", variant="banana")
check("new food reuses the released slot without growing capacity",
      world.objects["replacement"].slot == released_slot and
      world.state()["slot_free"]["food"] == 0 and
      world.state()["slot_capacity"]["food"] == 8 and
      len(world.objects) == 8)
world.reset()
check("reset restores all eight food slots",
      world.state()["slot_free"]["food"] == 8 and not world.objects)
check("reset restarts the rotation",
      world.spawn_object(shape="food")["food_variant"] == sm.FOOD_VARIANT_ORDER[0])

body = MockBody()
w = body.lab_world
idle = LocomotorCommand(forward=0.0)
w.spawn_object(shape="food", object_id="odor_only", position_mm=[8.0, 0.0, 1.5], variant="cookie")
pkt = body.step(idle, 0.02)
check("odor alone gives no taste signal",
      pkt.odor_left > 0.0 and pkt.taste_sugar == 0.0 and pkt.eating_food_id is None,
      f"odor={pkt.odor_left:.3f} taste={pkt.taste_sugar}")
w.remove_object("odor_only")
w.spawn_object(shape="food", object_id="snack", position_mm=[1.2, 0.0, 0.4],
               size_mm=1.0, variant="sugar_cube")
pkt = body.step(idle, 0.02)
events = [e["event"] for e in w.drain_events()]
check("mouth contact reports the food's sugar content",
      pkt.taste_sugar == 1.0 and pkt.eating_food_id == "snack" and "feeding_begin" in events,
      f"taste={pkt.taste_sugar} eating={pkt.eating_food_id} events={events}")
shrunk = w.objects["snack"].size_mm[0]
check("eating shrinks the food", shrunk < 1.0, f"diameter={shrunk:.3f}")
for _ in range(40):
    pkt = body.step(idle, 0.02)
drained = [e for e in w.drain_events() if e["event"] in ("feeding_end", "food_eaten")]
events = [e for e in drained if e["event"] == "food_eaten"]
check("food disappears once eaten",
      "snack" not in w.objects and len(events) == 1 and events[0]["food_variant"] == "sugar_cube"
      and pkt.taste_sugar == 0.0,
      f"events={events} taste={pkt.taste_sugar}")
check("eating closes the contact interval before the food disappears",
      [e["event"] for e in drained] == ["feeding_end", "food_eaten"]
      and drained[0]["id"] == "snack" and drained[0]["reason"] == "eaten"
      and drained[0]["contact_s"] == drained[1]["contact_s"] > 0,
      f"drained={drained}")
wire = BodyPacket.from_dict({**BodyPacket(taste_sugar=0.7, eating_food_id="x").to_dict()})
check("body packet round-trips the taste fields",
      wire.taste_sugar == 0.7 and wire.eating_food_id == "x")
check("body packet clamps taste and ignores bad ids",
      BodyPacket.from_dict({"taste_sugar": 7, "eating_food_id": 3}).taste_sugar == 1.0
      and BodyPacket.from_dict({"eating_food_id": 3}).eating_food_id is None)

if "--mock-only" in sys.argv:
    print("V5.6.2 MOCK: " + ("0 FAIL" if not fails else f"{len(fails)} FAIL {fails}"))
    raise SystemExit(0 if not fails else 1)

# ---------------------------------------------------------------- real ----
import mujoco
import numpy as np
from fly_body import RealFlyBody

body = RealFlyBody()
try:
    w = body.lab_world
    m, d = body.sim.mj_model, body.sim.mj_data
    player = w.player

    ground = w._ground_geom_ids[0]
    check("ground is the square lawn",
          mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_MATERIAL, int(m.geom_matid[ground])) == "v562_lawn"
          and np.allclose(m.geom_size[ground][:2], sm.ARENA_HALF_SIZE_MM))
    fly_geoms = [g for g in range(m.ngeom) if (mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_GEOM, g) or "")
                 .startswith("fly/")]
    # FlyGym's own eye-camera marker spheres are not body segments.
    fly_geoms = [g for g in fly_geoms if not mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_GEOM, g)
                 .endswith("_cam_marker")]
    coloured = sum(1 for g in fly_geoms if int(m.geom_matid[g]) >= 0)
    check("fly geoms carry NeuroMechFly materials", fly_geoms and coloured == len(fly_geoms),
          f"{coloured}/{len(fly_geoms)}")

    # Stick figure: limbs solid only while active; face decorative.
    limbs = player.limb_geom_ids
    check("inactive figure is hidden and non-colliding",
          all(m.geom_rgba[g, 3] == 0.0 and m.geom_contype[g] == 0 for g in player.figure.all_gids()))
    w.set_player_active(True)
    visible = [g for g in player.figure.all_gids() if m.geom_rgba[g, 3] > 0.0]
    solid = [g for g in player.figure.all_gids() if m.geom_contype[g] == 1]
    check("active figure shows limbs and face, only limbs collide",
          sorted(solid) == sorted(limbs) and len(visible) == len(sm.figure_parts(2.5)),
          f"visible={len(visible)} solid={len(solid)}")
    player.set_gun_visible(True)
    gun_visible = [g for g in player.figure.all_gids() if m.geom_rgba[g, 3] > 0.0]
    check("toy gun adds decorative parts only",
          len(gun_visible) == len(sm.figure_parts(2.5, gun=True)) and
          sorted(g for g in player.figure.all_gids() if m.geom_contype[g] == 1) == sorted(limbs))
    player.set_gun_visible(False)

    idle = LocomotorCommand(forward=0.0)
    player.set_input_state(move_axes=[0.0, 0.0], look_delta=[math.radians(40), math.radians(-60)],
                           held_actions=[])
    body.step_exact(idle, 20)
    mujoco.mj_forward(m, d)
    up = d.xmat[player.body_id].reshape(3, 3)[:, 2]
    pose = w.render_player()
    fwd_z = 2 * (pose["orientation_quat_xyzw"][0] * pose["orientation_quat_xyzw"][2]
                 - pose["orientation_quat_xyzw"][3] * pose["orientation_quat_xyzw"][1])
    check("looking down pitches the camera, not the body",
          up[2] > 1.0 - 1e-9 and abs(fwd_z) > 0.8, f"body_up={up.round(6).tolist()} look_fwd_z={fwd_z:.3f}")

    # A leg capsule through the fly thorax makes a real contact.
    thorax = w.force_body_ids.get("thorax")
    t = d.xpos[thorax].copy()
    player.clear_input_state(reset_look=True)
    player.orientation_quat_xyzw = [0.0, 0.0, 0.0, 1.0]
    head_z = sm.FIGURE_HEAD_HEIGHT_MM
    f = ((head_z - t[2]) - 6.6) / 3.3
    leg = np.array([0.15 * f, -1.5 * f, 0.0])
    w.set_player_pose(position_mm=[float(t[0] - leg[0]), float(t[1] - leg[1]), head_z])
    mujoco.mj_forward(m, d)
    mujoco.mj_collision(m, d)
    hits = {int(c.geom1) if int(c.geom1) in limbs else int(c.geom2)
            for c in d.contact[:d.ncon] if int(c.geom1) in limbs or int(c.geom2) in limbs}
    check("stick-figure leg collides with the fly", bool(hits), f"limb contacts={len(hits)}")
    w.set_player_active(False)

    # Food model palettes and picking.
    w.spawn_object(shape="food", object_id="apple", position_mm=[40, 20, 1.5], variant="apple")
    mujoco.mj_forward(m, d)
    pal = w._food_palettes[w.objects["apple"].slot]
    shown = sum(1 for g in pal.all_gids() if m.geom_rgba[g, 3] > 0.0)
    hit = body.ray_pick([30, 20, 1.4], [1, 0, 0], exclude_player=True)
    check("food model shows every part and ray-picks to the food id",
          shown == len(sm.FOOD_VARIANTS["apple"]) and hit.get("target_id") == "apple",
          f"shown={shown} hit={hit}")
    w.remove_object("apple")
    check("removed food hides its model",
          all(m.geom_rgba[g, 3] == 0.0 for g in pal.all_gids()))

    # Feeding through the real haustellum geometry.
    body.step_exact(idle, 50)
    mujoco.mj_forward(m, d)
    mouth = d.geom_xpos[w._mouth_geom_ids[0]].copy()
    w.spawn_object(shape="food", object_id="far", position_mm=[float(mouth[0]) + 6.0, float(mouth[1]), 1.5],
                   variant="banana")
    far_size = list(w.objects["far"].size_mm)
    pkt = body.step_exact(idle, 50)
    check("food 6 mm away: odor but no taste", pkt.taste_sugar == 0.0 and pkt.odor_left > 0.0,
          f"taste={pkt.taste_sugar} odor={pkt.odor_left:.3f}")
    w.spawn_object(shape="food", object_id="snack",
                   position_mm=[float(mouth[0]) + 0.6, float(mouth[1]), 1.0],
                   size_mm=1.2, variant="sugar_cube")
    tastes = []
    for _ in range(200):  # 1.2 mm at 1.2 mm/s needs ~0.7 s of contact
        pkt = body.step_exact(idle, 50)
        tastes.append(pkt.taste_sugar)
        if "snack" not in w.objects:
            break
    pkt = body.step_exact(idle, 50)  # the quantum after the last bite
    events = [e["event"] for e in w.drain_events()]
    check("haustellum contact eats the food until it disappears",
          max(tastes) == 1.0 and "snack" not in w.objects and "feeding_begin" in events
          and "food_eaten" in events and pkt.taste_sugar == 0.0,
          f"steps={len(tastes)} events={events}")
    check("distant food untouched", w.objects["far"].size_mm == far_size)
    check("eaten food slot hidden again",
          all(m.geom_rgba[g, 3] == 0.0 for g in w._food_palettes[
              next(s for s, sh in w._slot_shape.items() if sh == "food" and s in w._free_slots["food"])
          ].all_gids()))

    # BB gun: the pellet lands where the crosshair points, and its tracer is
    # visible to the user but never to the fly's eye renderer.
    from protocol import LabCommand
    w.reset()
    w.set_player_active(True)
    w.set_player_pose(position_mm=[-40.0, 30.0, sm.FIGURE_HEAD_HEIGHT_MM])
    body.apply_lab_command(LabCommand(seq=901, op="equip_gun",
                                      args={"actor_id": "player", "equipped": True}))
    eye = [-40.0 + 0.6 * player.radius_mm, 30.0, sm.FIGURE_HEAD_HEIGHT_MM]
    ground = [20.0, 30.0, 0.0]   # crosshair on the lawn 60 mm ahead
    aim = [g - e for e, g in zip(eye, ground)]
    norm = math.sqrt(sum(v * v for v in aim))
    body.apply_lab_command(LabCommand(seq=902, op="fire_bb", args={
        "actor_id": "player", "direction": [v / norm for v in aim]}))
    pellet = next(iter(w.projectiles.values()))
    bid, gid, qadr, _ = w._bb_ids[pellet.index]
    tracer_seen, landing = False, None
    for _ in range(40):
        body.step_exact(idle, 20)
        mocap, tgid = w._bb_tracers[pellet.index]
        tracer_seen |= bool(m.geom_rgba[tgid, 3] > 0 and m.geom_size[tgid][1] > 0.5)
        pos = d.qpos[qadr:qadr + 3].copy()
        if landing is None and pos[2] <= sm.BB_RADIUS_MM + 0.05:
            landing = pos
    miss = math.dist(landing[:2], ground[:2]) if landing is not None else float("inf")
    check("BB lands under the crosshair (aim point converges, gravity solved)",
          miss < 1.5, f"landing={None if landing is None else landing.round(2).tolist()} miss={miss:.2f}mm")
    check("BB tracer shows while in flight", tracer_seen)
    eye_option = body.sim.eye_renderer_scene_option
    check("BB tracer group is hidden from the fly's eye renderer",
          int(m.geom_group[w._bb_tracers[0][1]]) == sm.VIEW_ONLY_GROUP and
          eye_option.geomgroup[sm.VIEW_ONLY_GROUP] == 0 and eye_option.geomgroup[0] == 1)

    # 2026-09-29 performance pass: every shortcut must leave the physics as is.
    def masks_consistent():
        bad = []
        for bid in range(m.nbody):
            start, count = int(m.body_geomadr[bid]), int(m.body_geomnum[bid])
            if start < 0:
                continue
            want = (int(np.bitwise_or.reduce(m.geom_contype[start:start + count])),
                    int(np.bitwise_or.reduce(m.geom_conaffinity[start:start + count])))
            if (int(m.body_contype[bid]), int(m.body_conaffinity[bid])) != want:
                bad.append(bid)
        return bad
    parked = sum(1 for b in range(m.nbody) if int(m.body_mocapid[b]) >= 0 and
                 not m.body_contype[b] and not m.body_conaffinity[b])
    w.spawn_object(shape="car", object_id="perf_car", position_mm=[-30.0, 20.0, 3.0], size_mm=[14.0])
    bad_live = masks_consistent()
    w.remove_object("perf_car")
    bad_after = masks_consistent()
    check("body collision masks track geom masks (parked slots leave the broadphase)",
          not bad_live and not bad_after and parked > 100,
          f"parked={parked} bad_live={bad_live[:5]} bad_after={bad_after[:5]}")
    check("MuJoCo energy bookkeeping is off (never read)",
          not m.opt.enableflags & int(mujoco.mjtEnableBit.mjENBL_ENERGY))
    # The shipped links (tibia, tarsus1-2) rarely touch the floor while walking,
    # so the force path is also compared on tarsus5, which always does.
    from fly_body import ControllerObservationReader
    feet = ControllerObservationReader(body.sim, "fly", body.HybridControllerObservation,
                                       stumbling_links=("tarsus5",))
    walk = LocomotorCommand(forward=0.9, steering=0.3, moving=True)
    mismatches = loaded = 0
    for _ in range(30):
        body.step_exact(walk, 20)
        for reader, kwargs in ((body.controller_obs, {}), (feet, {"stumbling_links": ("tarsus5",)})):
            ours = reader.read()
            ref = body.HybridControllerObservation.from_sim(body.sim, "fly", **kwargs)
            same = (ours.thorax_z == ref.thorax_z and
                    all(np.array_equal(getattr(ours, f), getattr(ref, f))
                        for f in ("tarsus5_z", "stumbling_contact_forces", "fly_heading")))
            mismatches += 0 if same else 1
            loaded += bool(np.any(ref.stumbling_contact_forces))
    check("controller observation reader is bit-identical to FlyGym from_sim",
          mismatches == 0 and loaded >= 25, f"mismatches={mismatches}/60 with-contact-force={loaded}")
finally:
    body.close()

print("V5.6.2 REAL: " + ("0 FAIL" if not fails else f"{len(fails)} FAIL {fails}"))
raise SystemExit(0 if not fails else 1)
