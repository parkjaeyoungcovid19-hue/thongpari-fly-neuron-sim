# Works both under unittest discovery and as a directly invoked test file.
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tests._support import ROOT, REPO
import unittest

class FeatureTests(unittest.TestCase):
    def test_contract(self):
        """V5.6.2 sandbox models and feeding: mock contract checks, then real MuJoCo.

        Run from flygym_bridge: ../flygym-venv/bin/python -m unittest discover -s tests/unit
        """
        import math
        import os
        import sys


        import sandbox_models as sm
        from fly_body import MockBody
        from lab_world import LabError, LabWorld, FEED_MIN_DIAMETER_MM
        from neural_decoder import LocomotorCommand
        from protocol import BodyPacket

        fails = []


        def check(name, cond, detail=""):
            with self.subTest(check=name):
                self.assertTrue(cond, str(detail))


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


if __name__ == "__main__":
    unittest.main()
