# Works both under unittest discovery and as a directly invoked test file.
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tests._support import ROOT, REPO
import unittest

class FeatureTests(unittest.TestCase):
    def test_contract(self):
        """V5.6.2 sandbox toy mechanics: mock contract, real contacts and idle cost."""
        import math
        import json
        import statistics
        import time

        import mujoco

        import sandbox_models as sm
        from fly_body import MockBody, RealFlyBody
        from lab_world import LabError, BB_POOL_SIZE, CARRY_GAP_MM
        from neural_decoder import LocomotorCommand
        from protocol import LabCommand
        from bridge import Bridge

        failures = []
        idle = LocomotorCommand(forward=0)


        def check(name, cond, detail=""):
            with self.subTest(check=name):
                self.assertTrue(cond, str(detail))


        def command(body, op, **args):
            return body.apply_lab_command(LabCommand(op=op, args=args))


        def event_names(world):
            return [event["event"] for event in world.drain_events()]


        real = RealFlyBody(config={}, show_viewer=False)
        self.addCleanup(real.close)
        w = real.lab_world
        model, data = real.sim.mj_model, real.sim.mj_data


        def advance(n):
            while n:
                chunk = min(n, real.max_physics_substeps)
                real.step_exact(idle, chunk)
                n -= chunk


        def reset():
            w.reset()
            w.set_player_active(False)
            w.drain_events()


        reset()
        o = command(real, "spawn_object", shape="car", id="roadster", position_mm=[30, 0, 2.87])
        gids = w._toy_palettes[w.objects["roadster"].slot].all_gids()
        check("real car part semantic map", all(w.semantic_target_for_geom(g)["target_id"] == "roadster"
              for g in gids) and len(w._solid_by_slot[w.objects["roadster"].slot]) == 7)
        command(real, "drive_object", id="roadster", speed_mm_s=40, distance_mm=4)
        advance(2200)
        check("real car drive distance and completion", abs(w.objects["roadster"].position_mm[0] - 34) < 0.02 and
              "drive_complete" in event_names(w), f"x={w.objects['roadster'].position_mm[0]:.4f}")

        reset()
        w.set_player_active(True)
        w.set_player_pose(position_mm=[40, 0, 2.5])
        w.spawn_object(shape="car", object_id="blocked", position_mm=[20, 0, 2.87])
        command(real, "drive_object", id="blocked", speed_mm_s=60, distance_mm=30)
        advance(3500)
        blocked = w.objects["blocked"]
        events = event_names(w)
        clearance, _ = w._tool_clearance(blocked, CARRY_GAP_MM)
        check("real car stops at participant", "car_blocked" in events and
              blocked.position_mm[0] < 40 and clearance >= -0.02,
              f"x={blocked.position_mm[0]:.3f} clearance={clearance:.3f} events={events}")

        # Negative control: bypass the pre-move check on a fresh blocked trajectory.
        reset()
        w.set_player_active(True)
        w.set_player_pose(position_mm=[40, 0, 2.5])
        w.spawn_object(shape="car", object_id="unsafe", position_mm=[20, 0, 2.87])
        original_try = w._try_tool_pose


        def unchecked(obj, target, *, margin=0):
            obj.position_mm = list(target)
            w._sync_object(obj)
            w._bump_revision(obj)
            return True


        w._try_tool_pose = unchecked
        try:
            command(real, "drive_object", id="unsafe", speed_mm_s=60, distance_mm=30)
            advance(3500)
        finally:
            w._try_tool_pose = original_try
        unsafe_clearance, _ = w._tool_clearance(w.objects["unsafe"], CARRY_GAP_MM)
        check("negative control: disabled pre-move check breaks blocked-car gate",
              unsafe_clearance < -0.02 and "car_blocked" not in event_names(w),
              f"clearance={unsafe_clearance:.3f}")

        reset()
        w.spawn_object(shape="car", object_id="edge", position_mm=[140, 0, 2.87])
        command(real, "drive_object", id="edge", speed_mm_s=60, distance_mm=30)
        advance(600)
        check("real car lawn edge stop", w.objects["edge"].position_mm[0] <= 143.001 and
              "car_blocked" in event_names(w), f"x={w.objects['edge'].position_mm[0]:.3f}")

        reset()
        fly_x, fly_y, _ = real._thorax_position()
        w.spawn_object(shape="car", object_id="fly_car",
                       position_mm=[fly_x - 12, fly_y, 2.87])
        command(real, "drive_object", id="fly_car", speed_mm_s=60, distance_mm=20)
        advance(2000)
        car_hits = [e for e in w.drain_events() if e["event"] == "car_hit_fly"]
        check("real car stops on fly contact with force", bool(car_hits) and
              car_hits[0]["peak_normal_force"] > 0 and "fly_car" not in w.drives,
              f"x={w.objects['fly_car'].position_mm[0]:.3f} hits={car_hits}")

        reset()
        w.set_player_active(True)
        w.set_player_pose(position_mm=[12, 0, 2.87])
        w.spawn_object(shape="car", object_id="held_car", position_mm=[20, 0, 2.87])
        command(real, "drive_object", id="held_car", distance_mm=20)
        hit = real.ray_pick([12, 0, 2.87], [1, 0, 0], exclude_player=True)
        if hit.get("target_id") == "held_car":
            command(real, "interaction", tool_id="grab", actor_id="player",
                    ray_origin_mm=[12, 0, 2.87], ray_direction=[1, 0, 0], id="held_car")
        check("grab cancels car drive", hit.get("target_id") == "held_car" and
              "held_car" not in w.drives and w.interaction.held_object_id == "held_car")
        held_gids, _ = w._carry_candidates()
        check("held car uses all solid parts in carry", len(held_gids) == 7)
        w.spawn_object(shape="wall", object_id="carry_wall", position_mm=[29.2, 0, 2.87],
                       size_mm=[2, 20, 10])
        advance(1000)
        wall_gid = w._slot_ids[w.objects["carry_wall"].slot][1]
        car_wall_gap = min(mujoco.mj_geomDistance(model, data, gid, wall_gid, 10, None)
                          for gid in w._object_solid_geoms(w.objects["held_car"]))
        check("held car respects carry wall", car_wall_gap >= -0.05 and
              "carry_blocked" in event_names(w),
              f"gap={car_wall_gap:.3f} x={w.objects['held_car'].position_mm[0]:.3f}")

        reset()
        w.spawn_object(shape="trap", object_id="cage", position_mm=[0, 0, 10])
        advance(750)
        check("real trap triggers and closes", w.objects["cage"].trap_state == "closed" and
              {"trap_triggered", "trap_closed"} <= set(event_names(w)),
              f"z={w.objects['cage'].position_mm[2]:.3f}")
        command(real, "arm_trap", id="cage")
        check("real trap re-arm", w.objects["cage"].trap_state == "armed" and
              "trap_armed" in event_names(w))

        reset()
        fly_x, fly_y, _ = real._thorax_position()
        w.spawn_object(shape="trap", object_id="near_wall", position_mm=[fly_x + 9, fly_y, 10])
        real.step_exact(idle, 100)
        check("trap near-wall margin prevents trigger", w.objects["near_wall"].trap_state == "armed",
              f"fly={real._thorax_position()[:2]} trap={w.objects['near_wall'].position_mm[:2]}")

        reset()
        fly_x, fly_y, _ = real._thorax_position()
        w.spawn_object(shape="trap", object_id="blocked_trap", position_mm=[fly_x, fly_y, 10])
        w.set_player_active(True)
        w.set_player_pose(position_mm=[fly_x, fly_y, 12])
        advance(400)
        check("trap dropping blocked by participant", w.objects["blocked_trap"].trap_state == "dropping" and
              "trap_blocked" in event_names(w), f"z={w.objects['blocked_trap'].position_mm[2]:.3f}")
        w.set_player_active(False)
        command(real, "arm_trap", id="blocked_trap")
        check("blocked trap re-arms after participant leaves",
              w.objects["blocked_trap"].trap_state == "armed" and
              "trap_armed" in event_names(w))

        reset()
        w.set_player_active(True)
        w.set_player_pose(position_mm=[24, 0, sm.FIGURE_HEAD_HEIGHT_MM])
        command(real, "equip_gun", actor_id="player", equipped=True)
        shot = command(real, "fire_bb", actor_id="player", direction=[1, 0, 0])
        p = next(iter(w.projectiles.values()))
        pellet_gid = w._bb_ids[p.index][1]
        mujoco.mj_forward(model, data)
        self_distance = min(mujoco.mj_geomDistance(model, data, pellet_gid, gid, 20, None)
                            for gid in w.player.solid_geom_ids())
        check("BB muzzle outside participant", self_distance > 0,
              f"minimum gap={self_distance:.3f}mm")
        try:
            command(real, "fire_bb", actor_id="player", direction=[1, 0, 0])
            limited = False
        except LabError:
            limited = True
        check("BB rate limit", limited and len(w.projectiles) == 1)
        real.step_exact(idle, 10)
        check("BB does not self-hit at spawn", all(
            not ((c.geom1 == pellet_gid and c.geom2 in w.player.solid_geom_ids()) or
                 (c.geom2 == pellet_gid and c.geom1 in w.player.solid_geom_ids()))
            for c in data.contact[:data.ncon]))
        advance(1000)
        advance(400)
        bb_events = event_names(w)
        check("BB expires and parks", not w.projectiles and
              "bb_expired" in bb_events and model.body_gravcomp[w._bb_ids[p.index][0]] == 1,
              f"live={w.projectile_state()} events={bb_events}")

        reset()
        w.set_player_active(True)
        w.set_player_pose(position_mm=[24, 0, sm.FIGURE_HEAD_HEIGHT_MM])
        w.spawn_object(shape="box", object_id="bb_target", position_mm=[35, -0.95, 7.07],
                       size_mm=[4, 4, 4])
        command(real, "equip_gun", actor_id="player", equipped=True)
        # Crosshair on the box: look ray from the eye (head centre + 0.6 r forward).
        eye = [24 + 0.6 * w.player.radius_mm, 0.0, sm.FIGURE_HEAD_HEIGHT_MM]
        aim = [t - s for s, t in zip(eye, [35, -0.95, 7.07])]
        aim_norm = math.sqrt(sum(v * v for v in aim))
        command(real, "fire_bb", actor_id="player", direction=[v / aim_norm for v in aim])
        advance(150)
        check("real BB hits a lab object", "bb_hit_object" in event_names(w))

        reset()
        w.set_player_active(True)
        w.set_player_pose(position_mm=[-12, 0, sm.FIGURE_HEAD_HEIGHT_MM])
        command(real, "equip_gun", actor_id="player", equipped=True)
        # Aim like the user: the look ray from the eye (head centre + 0.6 r forward)
        # through the thorax; the backend solves the muzzle launch for that point.
        eye = [-12 + 0.6 * w.player.radius_mm, 0.0, sm.FIGURE_HEAD_HEIGHT_MM]
        thorax = real._thorax_position()
        direction = [t - s for s, t in zip(eye, thorax)]
        norm = math.sqrt(sum(v * v for v in direction))
        direction = [v / norm for v in direction]
        command(real, "fire_bb", actor_id="player", direction=direction)
        real.step_exact(idle, 100)
        hit_events = [e for e in w.drain_events() if e["event"] == "bb_hit_fly"]
        check("real BB aimed at thorax emits force hit", bool(hit_events) and
              hit_events[0]["peak_normal_force"] > 0, repr(hit_events))

        real.close()

if __name__ == "__main__":
    unittest.main()
