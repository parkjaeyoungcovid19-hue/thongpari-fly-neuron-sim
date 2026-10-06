"""V6.4 ramp terrain semantics and slot-budget rejection; mock only, no listeners.

Run: PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_v6_4_terrain.py
"""
from copy import deepcopy
import json
import math
import unittest

from bridge import Bridge
from environment_properties import EditError
from interaction import InteractionError, participant_center
from lab_world import CapacityError, LabError, LabWorld, ramp_flush_center_z
from protocol import HelloPacket, LabCommand, SessionControlPacket, encode


def quat_rotate(q_wxyz, v):
    """Rotate v by a unit quaternion, independent of LabObject.local_to_world."""
    w, x, y, z = q_wxyz
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
         [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
         [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]]
    return [sum(r[i][j] * v[j] for j in range(3)) for i in range(3)]


def edit(world, prop, target, value, unit):
    return world.apply_edit(dict(schema_version=1, property_id=prop, target_id=target,
                                 expected_revision=world.objects[target].revision,
                                 unit=unit, value=value))


class RampTests(unittest.TestCase):
    def assert_close(self, a, b, tol=1e-9):
        self.assertEqual(len(a), len(b))
        for x, y in zip(a, b):
            self.assertAlmostEqual(x, y, delta=tol)

    def test_default_spawn_is_flush_with_lawn(self):
        w = LabWorld()
        state = w.spawn_object(shape="ramp", object_id="r")
        r = w.objects["r"]
        self.assertEqual((r.size_mm, r.pitch_deg), ([40.0, 20.0, 1.0], 15.0))
        self.assertAlmostEqual(r.ramp_anchor()[2], 0.0, delta=1e-12)
        self.assertAlmostEqual(r.position_mm[2], ramp_flush_center_z(r.size_mm, 15.0))
        self.assertTrue(state["fixed_terrain"] and state["fly_leg_contact"])
        self.assertEqual(state["pitch_deg"], 15.0)
        # The raised +X end is above the lawn by L*sin(pitch) at the top surface.
        high = r.local_to_world((20.0, 0.0, 0.5))
        self.assertAlmostEqual(high[2], 40.0 * math.sin(math.radians(15.0)), delta=1e-9)

    def test_spawn_command_and_pitch_bounds(self):
        w = LabWorld()
        w.apply_command(LabCommand(seq=1, op="spawn_ramp",
                                   args={"id": "r", "size_mm": [30, 10, 2], "pitch_deg": 30}))
        self.assertEqual(w.objects["r"].pitch_deg, 30.0)
        self.assertEqual(w.objects["r"].size_mm, [30.0, 10.0, 2.0])
        w.apply_command(LabCommand(seq=2, op="spawn_object",
                                   args={"id": "r2", "shape": "ramp", "pitch_deg": 0}))
        self.assertEqual(w.objects["r2"].pitch_deg, 0.0)
        with self.assertRaises(LabError):
            w.spawn_object(shape="box", object_id="b", pitch_deg=10)
        self.assertNotIn("b", w.objects)

    def test_render_quaternion_matches_local_frame(self):
        w = LabWorld()
        w.spawn_object(shape="ramp", object_id="r", position_mm=[10, -5, 3],
                       size_mm=[30, 12, 2], yaw_deg=40, pitch_deg=25)
        r = w.objects["r"]
        rendered = next(o for o in w.render_objects() if o["id"] == "r")
        x, y, z, qw = rendered["orientation_quat_xyzw"]
        self.assertAlmostEqual(qw * qw + x * x + y * y + z * z, 1.0, delta=1e-12)
        for local in ((15, 6, 1), (-15, 6, -1), (15, -6, 1), (0, 0, 0)):
            moved = quat_rotate((qw, x, y, z), local)
            expected = [c + m for c, m in zip(rendered["position_mm"], moved)]
            self.assert_close(r.local_to_world(local), expected)

    def test_pitch_and_size_edits_pivot_on_low_edge(self):
        w = LabWorld()
        w.spawn_object(shape="ramp", object_id="r", position_mm=[20, 10, 0],
                       size_mm=[40, 20, 1], yaw_deg=30, pitch_deg=10)
        r = w.objects["r"]
        anchor = r.ramp_anchor()
        result = edit(w, "object.ramp.pitch_deg", "r", 35, "deg")
        self.assertEqual(result["actual_value"], 35.0)
        self.assert_close(r.ramp_anchor(), anchor, 1e-9)
        result = edit(w, "object.ramp.size_mm", "r", [60, 25, 3], "mm")
        self.assertEqual(result["actual_value"], [60.0, 25.0, 3.0])
        self.assert_close(r.ramp_anchor(), anchor, 1e-9)
        # Yaw turns about the center; a flush ramp stays flush.
        w.spawn_object(shape="ramp", object_id="flush")
        edit(w, "object.yaw_deg", "flush", 90, "deg")
        self.assertAlmostEqual(w.objects["flush"].ramp_anchor()[2], 0.0, delta=1e-9)

    def test_pitch_edit_rejected_for_other_shapes_without_mutation(self):
        w = LabWorld()
        w.spawn_object(shape="box", object_id="b")
        before = deepcopy(w.state())
        with self.assertRaises(EditError) as caught:
            edit(w, "object.ramp.pitch_deg", "b", 10, "deg")
        self.assertEqual((caught.exception.path, caught.exception.status),
                         ("edit.target_id", "rejected_target"))
        self.assertEqual(w.state(), before)

    def test_duplicate_keeps_tilt(self):
        w = LabWorld()
        w.spawn_object(shape="ramp", object_id="r", yaw_deg=70, pitch_deg=22)
        r = w.objects["r"]
        clone_id = w.edit_object(dict(schema_version=1, operation="duplicate", target_id="r",
                                      expected_revision=r.revision))["actual_value"]
        clone = w.objects[clone_id]
        self.assertEqual((clone.position_mm, clone.size_mm, clone.yaw_deg, clone.pitch_deg),
                         (r.position_mm, r.size_mm, r.yaw_deg, r.pitch_deg))

    def test_slot_budget_is_explicit_and_leaves_world_unchanged(self):
        w = LabWorld()
        capacity = w.state()["slot_capacity"]["ramp"]
        self.assertEqual(capacity, 4)
        for i in range(capacity):
            w.spawn_object(shape="ramp", object_id=f"r{i}")
        self.assertEqual(w.state()["slot_free"]["ramp"], 0)
        before = deepcopy(w.state())
        with self.assertRaises(CapacityError) as caught:
            w.spawn_object(shape="ramp", object_id="overflow")
        self.assertEqual(str(caught.exception), "no free ramp slots")
        self.assertEqual(caught.exception.status, "rejected_capacity")
        self.assertEqual(w.state(), before)
        with self.assertRaises(EditError) as caught:
            w.edit_object(dict(schema_version=1, operation="duplicate", target_id="r0",
                               expected_revision=w.objects["r0"].revision))
        self.assertEqual(caught.exception.status, "rejected_capacity")
        self.assertEqual(caught.exception.detail, {"shape": "ramp", "capacity": 4})
        self.assertEqual(w.state(), before)
        # Deleting one frees exactly one slot for reuse.
        w.remove_object("r1")
        w.spawn_object(shape="ramp", object_id="again")
        self.assertEqual(w.state()["slot_free"]["ramp"], 0)

    def test_capacity_ack_status_over_v4(self):
        b = Bridge(mode="mock")
        b.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
        b.handle_line(encode(SessionControlPacket(session_id="live", epoch=1, seq=1, sim_tick=0,
                                                  action="begin", mode="interactive")))
        b._process_session_controls(); b._drain_lab_responses()
        w = b.body.lab_world
        for i in range(w.slot_counts["ramp"]):
            w.spawn_object(shape="ramp", object_id=f"r{i}")
        tick = b._current_owner_tick()
        b.handle_line(json.dumps({"type": "lab_command", "id": 9, "action": "spawn_ramp",
                                  "target": "overflow", "protocol_version": 4,
                                  "session_id": "live", "epoch": 1,
                                  "requested_tick": tick}).encode() + b"\n")
        b._apply_interactive_owner_inputs()
        ack = next(json.loads(encode(p)) for p in b._drain_lab_responses()
                   if getattr(p, "ack", None) == 9)
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["status"], "rejected_capacity")
        self.assertEqual(ack["error"], "no free ramp slots")
        self.assertNotIn("overflow", w.objects)

    def test_ramp_is_fixed_terrain(self):
        w = LabWorld()
        w.spawn_object(shape="ramp", object_id="r", position_mm=[30, 0, 0])
        with self.assertRaises(LabError):
            w.start_approach("r", fly_position_mm=[0, 0, 0])
        self.assertNotIn("r", w.approaches)
        w.set_player_active(True)
        origin = list(participant_center(w.player))
        args = {"tool_id": "grab", "actor_id": w.player.actor_id,
                "ray_origin_mm": origin, "ray_direction": [1, 0, 0]}
        hit = lambda o, d: {"hit": True, "target_kind": "lab_object", "target_id": "r",
                            "point_mm": [origin[0] + 5, origin[1], origin[2]]}
        with self.assertRaises(InteractionError) as caught:
            w.apply_interaction(LabCommand(seq=1, op="interaction", args=args), ray_pick=hit)
        self.assertEqual(str(caught.exception), "fixed_terrain")
        self.assertIsNone(w.interaction.held_object_id)


if __name__ == "__main__":
    unittest.main(verbosity=2)
