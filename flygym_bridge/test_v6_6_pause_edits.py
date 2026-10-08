"""V6.6 pause edit transaction on the interactive owner loop; mock body, no listeners.

While an interactive session is paused, only stamped edits at the head of the
lab queue apply, at the frozen owner tick, tagged transaction="paused". Every
other command is a barrier that keeps queue order until resume.
"""
import json
import math
import unittest
from bridge import Bridge
from environment_properties import EDIT_DESCRIPTORS
from lab_world import LabWorld
from protocol import HelloPacket, SessionControlPacket, encode


def stamped(seq, action, tick=0, **fields):
    return json.dumps({"type": "lab_command", "id": seq, "action": action,
                       "protocol_version": 4, "session_id": "live", "epoch": 1,
                       "requested_tick": tick, **fields}).encode() + b"\n"


def edit(seq, pid, value, revision, target=None, unit=None, tick=0):
    unit = unit or {"temperature.celsius": "degC", "wind.strength": "normalized"}.get(pid, "mm")
    return stamped(seq, "edit_property", tick, edit=dict(
        schema_version=1, property_id=pid, target_id=target,
        expected_revision=revision, unit=unit, value=value))


class PauseEditTransactionTests(unittest.TestCase):
    def setUp(self):
        b = self.b = Bridge(mode="mock")
        b.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
        b.handle_line(encode(SessionControlPacket(session_id="live", epoch=1, seq=1, sim_tick=0,
                                                  action="begin", mode="interactive")))
        b._process_session_controls(); b._drain_lab_responses()
        self.w = b.body.lab_world
        self.w.spawn_object(shape="box", object_id="box", position_mm=[60, 0, 5], size_mm=[10, 10, 10])
        b.handle_line(encode(SessionControlPacket(session_id="live", epoch=1, seq=2, sim_tick=0, action="pause")))
        b._process_session_controls(); b._drain_lab_responses()
        self.assertTrue(b.session_paused)

    def acks(self):
        return {p.ack: json.loads(encode(p)) for p in self.b._drain_lab_responses()
                if getattr(p, "ack", None) is not None}

    def test_paused_edit_applies_at_frozen_tick_without_stepping(self):
        b, w = self.b, self.w
        t0, tick = b.body.t, b._current_owner_tick()
        b.handle_line(edit(10, "temperature.celsius", 31.5, w.environment_revision))
        b.handle_line(edit(11, "object.box.position_mm", [70, 5, 5], w.objects["box"].revision, "box"))
        self.assertEqual(b._apply_paused_edit_transaction(), 2)
        acks = self.acks()
        for seq in (10, 11):
            a = acks[seq]
            self.assertTrue(a["ok"]); self.assertEqual(a["status"], "applied")
            self.assertEqual((a["applied_tick"], a["applied_epoch"]), (tick, 1))
            self.assertEqual(a["edit"]["transaction"], "paused")
        self.assertEqual(w.temperature["celsius"], 31.5)
        self.assertEqual(w.objects["box"].position_mm, [70.0, 5.0, 5.0])
        self.assertEqual(b.body.t, t0)
        self.assertEqual(b._current_owner_tick(), tick)

    def test_stimulus_is_a_barrier_and_order_survives_resume(self):
        b, w = self.b, self.w
        rev = w.environment_revision
        b.handle_line(edit(20, "temperature.celsius", 30.0, rev))
        b.handle_line(stamped(21, "touch", target="thorax", strength=0.5, duration_ms=20))
        b.handle_line(edit(22, "temperature.celsius", 20.0, rev + 1))
        self.assertEqual(b._apply_paused_edit_transaction(), 1)
        self.assertEqual(list(self.acks()), [20])
        self.assertEqual(w.temperature["celsius"], 30.0)
        self.assertIsNone(w.touch)
        # Repeating the transaction does not let edit 22 overtake the touch.
        self.assertEqual(b._apply_paused_edit_transaction(), 0)
        self.assertEqual(self.acks(), {})
        b.handle_line(encode(SessionControlPacket(session_id="live", epoch=1, seq=3, sim_tick=0, action="resume")))
        b._process_session_controls(); b._drain_lab_responses()
        b._apply_interactive_owner_inputs()
        acks = self.acks()
        self.assertEqual(sorted(acks), [21, 22])
        self.assertTrue(acks[21]["ok"]); self.assertTrue(acks[22]["ok"])
        self.assertNotIn("transaction", acks[22]["edit"])
        self.assertEqual(w.temperature["celsius"], 20.0)
        self.assertIsNotNone(w.touch)

    def test_older_continuous_slot_blocks_later_edit(self):
        b, w = self.b, self.w
        b.handle_line(stamped(30, "temperature", celsius=12.0))
        b.handle_line(edit(31, "temperature.celsius", 33.0, w.environment_revision))
        self.assertEqual(b._apply_paused_edit_transaction(), 0)
        self.assertEqual(self.acks(), {})
        self.assertEqual(w.temperature["celsius"], 25.0)

    def test_unstamped_edit_waits_for_resume(self):
        b, w = self.b, self.w
        b.handle_line(json.dumps({"type": "lab_command", "id": 40, "action": "edit_property", "edit": dict(
            schema_version=1, property_id="temperature.celsius", target_id=None,
            expected_revision=w.environment_revision, unit="degC", value=33.0)}).encode() + b"\n")
        self.assertEqual(b._apply_paused_edit_transaction(), 0)
        self.assertEqual(w.temperature["celsius"], 25.0)

    def test_rejected_paused_edit_is_tagged_and_mutates_nothing(self):
        b, w = self.b, self.w
        before = json.dumps(w.state(), sort_keys=True)
        b.handle_line(edit(50, "temperature.celsius", 33.0, w.environment_revision + 9))
        b.handle_line(edit(51, "object.box.position_mm", [1, 2], w.objects["box"].revision, "box"))
        self.assertEqual(b._apply_paused_edit_transaction(), 0)
        acks = self.acks()
        self.assertEqual(acks[50]["edit"]["status"], "rejected_stale_revision")
        self.assertEqual(acks[51]["edit"]["path"], "edit.value")
        for a in acks.values():
            self.assertFalse(a["ok"]); self.assertEqual(a["edit"]["transaction"], "paused")
        self.assertEqual(json.dumps(w.state(), sort_keys=True), before)

    def test_future_edit_waits_for_its_tick_like_the_running_loop(self):
        # Same rule as the running loop: each stamped command applies at its own
        # requested tick, so a frozen tick keeps a future edit deferred while a
        # later, already-due edit applies.
        b, w = self.b, self.w
        tick = b._current_owner_tick()
        b.handle_line(edit(60, "temperature.celsius", 30.0, w.environment_revision, tick=tick + 50))
        b.handle_line(edit(61, "temperature.celsius", 22.0, w.environment_revision))
        self.assertEqual(b._apply_paused_edit_transaction(), 1)
        self.assertEqual([c.seq for c in b.deferred_lab_commands], [60])
        self.assertEqual(list(self.acks()), [61])
        self.assertEqual(w.temperature["celsius"], 22.0)
        self.assertEqual(b._apply_paused_edit_transaction(), 0)
        self.assertEqual([c.seq for c in b.deferred_lab_commands], [60])

    def test_duplicate_and_delete_apply_while_paused(self):
        b, w = self.b, self.w
        b.handle_line(stamped(70, "edit_object", object_edit=dict(
            schema_version=1, operation="duplicate", target_id="box", expected_revision=w.objects["box"].revision)))
        b._apply_paused_edit_transaction()
        copy = self.acks()[70]["edit"]["actual_value"]
        self.assertIn(copy, w.objects)
        b.handle_line(stamped(71, "edit_object", object_edit=dict(
            schema_version=1, operation="delete", target_id=copy, expected_revision=w.objects[copy].revision)))
        b._apply_paused_edit_transaction()
        self.assertTrue(self.acks()[71]["ok"])
        self.assertNotIn(copy, w.objects)


class UndoInverseTests(unittest.TestCase):
    """The V6.6 undo inverse is the ACK's previous_value sent back as an edit.
    It must restore every editable setting, including a ramp whose size/tilt
    edits move its centre to keep the low edge pinned."""

    NEW = {"position_mm": [12.0, -7.0, 9.0], "yaw_deg": 123.0, "pitch_deg": 31.0,
           "celsius": 33.5, "mode": "flywire_sensory", "strength": 0.6, "direction_deg": 200.0,
           "physical": False, "sensory": False, "left_mask": 0.4, "right_mask": 0.7,
           "left_enabled": False, "right_enabled": False}

    def close(self, a, b):
        if isinstance(a, dict):
            return a.keys() == b.keys() and all(self.close(a[k], b[k]) for k in a if k != "revision")
        if isinstance(a, list):
            return len(a) == len(b) and all(self.close(x, y) for x, y in zip(a, b))
        if isinstance(a, float) or isinstance(b, float):
            return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-9)
        return a == b

    def roundtrip(self, w, pid, target, value):
        def apply(v, revision):
            return w.apply_edit(dict(schema_version=1, property_id=pid, target_id=target,
                                     expected_revision=revision, unit=d["unit"], value=v))
        d = EDIT_DESCRIPTORS[pid]
        revision = lambda: w.objects[target].revision if target else w.environment_revision
        before = json.loads(json.dumps(w.state()))
        forward = apply(value, revision())
        self.assertNotEqual(forward["previous_value"], forward["actual_value"], pid)
        apply(forward["previous_value"], revision())
        after = json.loads(json.dumps(w.state()))
        for key in ("objects", "temperature", "wind", "eyes"):
            self.assertTrue(self.close(before[key], after[key]), f"{pid}: {key} not restored")

    def test_every_live_scene_setting_restores_from_previous_value(self):
        w = LabWorld()
        shapes = {"box": [6, 8, 10], "wall": [2, 14, 9], "sphere": 4, "food": 6,
                  "car": 16, "trap": 22, "ramp": [40, 20, 4]}
        for shape, size in shapes.items():
            w.spawn_object(shape=shape, object_id=shape, position_mm=[30, 20, 8], size_mm=size, yaw_deg=10)
        w.set_wind(strength=0.3, direction_deg=40, continuous=True)
        checked = 0
        for pid, d in EDIT_DESCRIPTORS.items():
            if d["apply_mode"] != "live" or d["persistence"] != "scene_candidate" or pid == "wind.continuous":
                continue
            field = d["legacy_field"]
            targets = ([pid.split(".")[1]] if pid.count(".") == 2 and pid.startswith("object.")
                       else list(shapes) if pid.startswith("object.") else [None])
            for target in targets:
                with self.subTest(pid=pid, target=target):
                    value = self.NEW.get(field)
                    if field == "size_mm":
                        value = [9.0, 11.0, 5.0] if d["value_type"] == "vector" else max(9.0, d["min"] + 1)
                    self.roundtrip(w, pid, target, value)
                    checked += 1
        self.assertGreaterEqual(checked, 30)

    def test_ramp_tilt_and_size_inverse_returns_centre(self):
        w = LabWorld()
        w.spawn_object(shape="ramp", object_id="r", position_mm=[50, 0, 3], size_mm=[40, 20, 4], yaw_deg=35)
        for pid, value in (("object.ramp.pitch_deg", 40.0), ("object.ramp.size_mm", [70.0, 25.0, 6.0])):
            start = list(w.objects["r"].position_mm)
            self.roundtrip(w, pid, "r", value)
            self.assertTrue(self.close(start, w.objects["r"].position_mm))


if __name__ == "__main__":
    unittest.main(verbosity=2)
