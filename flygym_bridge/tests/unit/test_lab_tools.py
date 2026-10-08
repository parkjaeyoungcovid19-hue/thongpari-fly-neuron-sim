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


        mock = MockBody()
        wm = mock.lab_world
        car = command(mock, "spawn_object", shape="car", id="car", position_mm=[20, 0, 2.87])
        trap = command(mock, "spawn_object", shape="trap", id="trap", position_mm=[0, 0, 10])
        check("mock car and trap sizes", car["size_mm"] == [14, 6.16, 5.739999999999999] and
              trap["size_mm"] == [20, 20, 12] and trap["trap_state"] == "armed")
        command(mock, "drive_object", id="car", speed_mm_s=20, distance_mm=4)
        for _ in range(2):
            mock.step(idle, 0.1)
        first_events = event_names(wm)
        check("mock car drive completes", abs(wm.objects["car"].position_mm[0] - 24) < 1e-7 and
              "drive_complete" in first_events)
        mock.step(idle, 0.1)
        check("mock trap triggers from fly XY", wm.objects["trap"].trap_state == "closed" and
              "trap_triggered" in first_events)
        command(mock, "arm_trap", id="trap")
        check("mock trap re-arms", wm.objects["trap"].trap_state == "armed" and
              "trap_armed" in event_names(wm))
        wm.set_player_active(True)
        command(mock, "equip_gun", actor_id="player", equipped=True)
        first = command(mock, "fire_bb", actor_id="player", direction=[1, 0, 0])
        check("mock BB appears in state and render", len(wm.projectile_state()) == 1 and
              mock.world_render_state()["projectiles"][0]["id"] == first["id"])
        mock.step(idle, 0.01)
        check("mock BB moves ballistically without fly hit", wm.projectile_state()[0]["position_mm"][0] >
              first["position_mm"][0] and "bb_hit_fly" not in event_names(wm))
        for _ in range(20):
            mock.step(idle, 0.1)
        check("mock BB expires", not wm.projectile_state() and "bb_expired" in event_names(wm))

        invalid = [
            ("drive_object", {"speed_mm_s": 20}),
            ("drive_object", {"id": "car", "speed_mm_s": float("nan")}),
            ("drive_object", {"id": "car", "distance_mm": 301}),
            ("arm_trap", {"id": False}),
            ("equip_gun", {"actor_id": "player", "equipped": 1}),
            ("fire_bb", {"actor_id": "player"}),
            ("fire_bb", {"actor_id": "player", "direction": [1, 0, float("nan")]}),
            ("fire_bb", {"actor_id": "player", "direction": [2, 0, 0]}),
            ("spawn_object", {"shape": "car", "size_mm": 61}),
        ]
        for op, args in invalid:
            before = (wm.revision, len(wm.projectiles), len(wm.drives), len(wm.objects))
            try:
                command(mock, op, **args)
                rejected = False
            except LabError:
                rejected = True
            check(f"strict apply rejection {op} {args}", rejected and before ==
                  (wm.revision, len(wm.projectiles), len(wm.drives), len(wm.objects)))
            try:
                LabCommand.from_dict({"type": "lab_command", "op": op, "args": args})
                parsed_rejected = False
            except ValueError:
                parsed_rejected = True
            check(f"strict parser rejection {op} {args}", parsed_rejected)

        wm.reset()
        wm.set_player_active(True)
        command(mock, "equip_gun", actor_id="player", equipped=True)
        for _ in range(BB_POOL_SIZE):
            wm._sim_time_s += 0.15
            command(mock, "fire_bb", actor_id="player", direction=[0, 0, 1])
        wm._sim_time_s += 0.15
        try:
            command(mock, "fire_bb", actor_id="player", direction=[0, 0, 1])
            full = False
        except LabError:
            full = True
        check("BB pool limits eight live pellets", full and len(wm.projectiles) == BB_POOL_SIZE)
        wm.reset()
        wm.set_player_active(True)
        command(mock, "equip_gun", actor_id="player", equipped=True)
        wm._sim_time_s += 0.15
        command(mock, "fire_bb", actor_id="player", direction=[0, 0, 1])
        check("world reset restarts pellet ids like object ids", list(wm.projectiles) == ["bb_1"],
              repr(list(wm.projectiles)))

        bridge = Bridge(mode="mock")
        for seq, op, args in (
                (1, "spawn_object", {"shape": "car", "id": "tcp_car"}),
                (2, "drive_object", {"id": "tcp_car", "distance_mm": 2}),
                (3, "set_player_active", {"active": 1}),
                (4, "equip_gun", {"actor_id": "player", "equipped": True}),
                (5, "fire_bb", {"actor_id": "player", "direction": [1, 0, 0]})):
            bridge.handle_line((json.dumps({"type": "lab_command", "seq": seq,
                                            "op": op, "args": args}) + "\n").encode())
        bridge._apply_lab_commands()
        responses = bridge._drain_lab_responses()
        check("mock wire queue applies toy ops and ACKs", len(responses) == 5 and
              all(response.ok for response in responses) and
              "tcp_car" in bridge.body.lab_world.drives and
              len(bridge.body.lab_world.projectiles) == 1)

        # The snapshot is re-parsed strictly before it is sent; toy/food fields survive.
        bridge.body.lab_world.spawn_object(shape="food", object_id="snap_food", position_mm=[40, 0, 1],
                                           size_mm=1.0, variant="grapes")
        bridge.body.lab_world.spawn_object(shape="trap", object_id="snap_trap", position_mm=[-40, 0, 10])
        snap = bridge._world_snapshot_response(type("Req", (), {"session_id": "", "epoch": 0, "seq": 1})())
        by_id = {obj["id"]: obj for obj in snap.objects}
        check("strict snapshot keeps food_variant and trap_state",
              by_id["snap_food"].get("food_variant") == "grapes"
              and by_id["snap_trap"].get("trap_state") == "armed"
              and "food_variant" not in by_id["snap_trap"], repr(by_id.get("snap_food")))



if __name__ == "__main__":
    unittest.main()
