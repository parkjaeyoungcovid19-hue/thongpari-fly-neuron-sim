"""Independent feeding-event lifecycle regressions; no MuJoCo or sockets.

Run: PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_feeding_events.py
"""
import unittest

from lab_world import LabError, LabWorld


class FeedingEventsTests(unittest.TestCase):
    def setUp(self):
        self.world = LabWorld(slot_counts={"food": 2})
        self.mouth = [1.5, 0.0, 1.0]

    def spawn(self, food_id="snack", position=None, diameter=3.0):
        return self.world.spawn_object(
            shape="food", object_id=food_id, position_mm=position or [0, 0, 1],
            size_mm=diameter, variant="sugar_cube")

    def feed(self, dt, mouth=None):
        return self.world.feeding_update(
            dt, mouth_position_mm=self.mouth if mouth is None else mouth)

    def assert_events(self, events, names):
        self.assertEqual([event["event"] for event in events], names)
        for event in events:
            self.assertEqual(event["classification"], "PHYSICAL")

    def test_active_deletion_preserves_cumulative_time_and_ends_once(self):
        self.spawn()
        self.feed(0.04)
        self.feed(0.06)
        self.assert_events(self.world.drain_events(), ["feeding_begin"])
        self.assertAlmostEqual(self.world.feeding["snack"], 0.1)

        self.world.remove_object("snack")
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_end"])
        self.assertEqual(events[0]["id"], "snack")
        self.assertEqual(events[0]["reason"], "object_removed")
        self.assertAlmostEqual(events[0]["contact_s"], 0.1)
        self.assertNotIn("snack", self.world.objects)
        self.assertEqual(self.world.feeding, {})
        self.assertIsNone(self.world._eating_id)
        with self.assertRaises(LabError):
            self.world.remove_object("snack")
        for _ in range(3):
            self.assertEqual(self.feed(0.02),
                             {"taste_sugar": 0.0, "eating_food_id": None})
        self.assertEqual(self.world.drain_events(), [])

    def test_same_id_reused_before_next_update_starts_new_interval(self):
        self.spawn()
        self.feed(0.1)
        self.world.remove_object("snack")
        self.spawn()  # Reuse the identity before any feeding_update can close it.
        self.feed(0.02)
        self.world.remove_object("snack")
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_begin", "feeding_end",
                                    "feeding_begin", "feeding_end"])
        self.assertAlmostEqual(events[1]["contact_s"], 0.1)
        self.assertAlmostEqual(events[3]["contact_s"], 0.02)
        self.feed(0.02)
        self.assertEqual(self.world.drain_events(), [])

    def test_inactive_deletions_do_not_close_active_contact(self):
        self.spawn()
        self.spawn("far", position=[30, 0, 1])
        self.world.spawn_object(shape="box", object_id="box")
        self.feed(0.1)
        self.world.drain_events()
        self.world.remove_object("far")
        self.world.remove_object("box")
        self.assertEqual(self.world.drain_events(), [])
        self.assertEqual(self.world._eating_id, "snack")
        self.feed(0.02)
        self.world.remove_object("snack")
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_end"])
        self.assertAlmostEqual(events[0]["contact_s"], 0.12)

    def test_contact_switch_closes_old_interval_before_new_begin(self):
        self.spawn()
        self.spawn("other", position=[10, 0, 1])
        self.feed(0.1)
        self.feed(0.05, mouth=[11.5, 0, 1])
        self.world.remove_object("snack")  # Old interval already ended.
        self.world.remove_object("other")
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_begin", "feeding_end",
                                    "feeding_begin", "feeding_end"])
        self.assertEqual([event["id"] for event in events],
                         ["snack", "snack", "other", "other"])
        self.assertAlmostEqual(events[1]["contact_s"], 0.1)
        self.assertAlmostEqual(events[3]["contact_s"], 0.05)

    def test_depletion_preserves_duration_order_and_single_end(self):
        self.spawn(diameter=1.0)
        # At the centre, contact survives shrinking until the final bite.
        for dt in (0.1, 0.2, 0.3):
            self.feed(dt, mouth=[0, 0, 1])
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_begin", "feeding_end", "food_eaten"])
        self.assertEqual(events[1]["reason"], "eaten")
        self.assertEqual(events[2]["food_variant"], "sugar_cube")
        for event in events[1:]:
            self.assertEqual(event["id"], "snack")
            self.assertAlmostEqual(event["contact_s"], 0.6)
        self.assertEqual(self.world.feeding, {})
        self.assertIsNone(self.world._eating_id)
        self.assertNotIn("snack", self.world.objects)
        for _ in range(3):
            self.feed(0.02)
        self.assertEqual(self.world.drain_events(), [])

    def test_reset_during_contact_clears_history_and_rearms_same_id(self):
        self.spawn()
        self.feed(0.1)
        self.world.reset()
        self.assertEqual(self.world.drain_events(), [])
        self.assertEqual(self.world.feeding, {})
        self.assertIsNone(self.world._eating_id)
        self.assertEqual(self.world.objects, {})
        self.assertEqual(self.world.state()["slot_free"]["food"], 2)
        self.feed(0.02)
        self.assertEqual(self.world.drain_events(), [])
        self.spawn()
        self.feed(0.02)
        self.world.remove_object("snack")
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_begin", "feeding_end"])
        self.assertAlmostEqual(events[1]["contact_s"], 0.02)

    def test_reset_after_deletion_discards_pending_end_without_ghost_events(self):
        self.spawn()
        self.feed(0.1)
        self.world.remove_object("snack")
        self.world.reset()
        self.world.reset()
        self.feed(0.02)
        self.assertEqual(self.world.drain_events(), [])
        self.assertEqual(self.world.feeding, {})
        self.assertIsNone(self.world._eating_id)
        self.spawn()
        self.feed(0.03)
        self.world.remove_object("snack")
        events = self.world.drain_events()
        self.assert_events(events, ["feeding_begin", "feeding_end"])
        self.assertAlmostEqual(events[1]["contact_s"], 0.03)

    def test_mock_delete_command_closes_at_current_tick_not_next_quantum(self):
        from fly_body import MockBody
        from neural_decoder import LocomotorCommand
        from protocol import LabCommand

        body = MockBody()
        idle = LocomotorCommand(forward=0.0)
        body.lab_world.spawn_object(
            shape="food", object_id="snack", position_mm=[1.2, 0, 0.4],
            size_mm=1.0, variant="sugar_cube")
        body.step(idle, 0.04)
        body.step(idle, 0.06)
        self.assert_events(body.drain_lab_events(), ["feeding_begin"])
        body.apply_lab_command(LabCommand(op="delete_object", args={"id": "snack"}))
        events = body.drain_lab_events()
        self.assert_events(events, ["feeding_end"])
        self.assertAlmostEqual(events[0]["contact_s"], 0.1)
        self.assertEqual(events[0]["sim_tick_ms"], 100)
        packet = body.step(idle, 0.02)
        self.assertEqual(packet.taste_sugar, 0.0)
        self.assertIsNone(packet.eating_food_id)
        self.assertEqual(body.drain_lab_events(), [])

    def test_mock_reset_commands_after_deletion_do_not_resurrect_contact(self):
        from fly_body import MockBody
        from neural_decoder import LocomotorCommand
        from protocol import LabCommand

        for reset_op in ("reset_body", "reset_world"):
            with self.subTest(reset_op=reset_op):
                body = MockBody()
                idle = LocomotorCommand(forward=0.0)
                body.lab_world.spawn_object(
                    shape="food", object_id="snack", position_mm=[1.2, 0, 0.4],
                    size_mm=1.0, variant="sugar_cube")
                body.step(idle, 0.1)
                body.apply_lab_command(LabCommand(
                    op="delete_object", args={"id": "snack"}))
                self.assert_events(body.drain_lab_events(), ["feeding_begin", "feeding_end"])
                body.apply_lab_command(LabCommand(op=reset_op))
                packet = body.step(idle, 0.02)
                self.assertEqual(packet.taste_sugar, 0.0)
                self.assertIsNone(packet.eating_food_id)
                self.assertEqual(body.drain_lab_events(), [])
                self.assertEqual(body.lab_world.feeding, {})
                self.assertIsNone(body.lab_world._eating_id)


if __name__ == "__main__":
    unittest.main(verbosity=2)
