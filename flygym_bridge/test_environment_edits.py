"""V6.2 strict edit tests; no real simulation, sockets, listeners or GPU.

Run: PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_environment_edits.py
"""
from copy import deepcopy
import json
from pathlib import Path
import unittest

from bridge import Bridge
from environment_properties import EDIT_DESCRIPTORS, EditError, validate_edit, validate_manifest
from lab_world import LabWorld
from protocol import LabCommand, LabStatePacket, decode_line, encode

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "environment_edits"


def fixtures():
    out = []
    for path in sorted(FIXTURES.glob("*.json")):
        doc = json.loads(path.read_text())
        manifest = validate_manifest(json.loads((FIXTURES / doc["manifest"]).read_text()))
        out.append((path.name, doc, {d["property_id"]: d for d in manifest["descriptors"]}))
    return out


def world_with_targets():
    world = LabWorld()
    world.spawn_object(shape="box", object_id="box_1", position_mm=[40, 0, 5])
    world.spawn_object(shape="wall", object_id="wall_1", position_mm=[-40, 0, 7.5])
    world.spawn_object(shape="sphere", object_id="sphere_1", position_mm=[0, 40, 5])
    world.spawn_object(shape="car", object_id="car_1", position_mm=[0, -40, 3])
    world.spawn_object(shape="ramp", object_id="ramp_1", position_mm=[-40, 40, 4])
    world.drain_events()
    return world


def edit_line(seq, edit):
    return LabCommand.from_dict({"type": "lab_command", "id": seq, "action": "edit_property",
                                 "edit": edit})


def current_revision(world, edit):
    if edit["property_id"].startswith("object."):
        return world.objects[edit["target_id"]].revision
    return world.environment_revision


class EnvironmentEditTests(unittest.TestCase):
    def assert_rejected_untouched(self, world, command, path, status="rejected_invalid"):
        before, events = deepcopy(world.state()), list(world.events)
        with self.assertRaises(EditError) as caught:
            world.apply_command(command)
        self.assertEqual((caught.exception.path, caught.exception.status), (path, status))
        self.assertEqual(world.state(), before)
        self.assertEqual(list(world.events), events)
        return caught.exception

    def test_shared_fixtures(self):
        cases = fixtures()
        self.assertGreaterEqual(len(cases), 30)
        self.assertTrue(any(doc["expect"] == "accept" for _, doc, _ in cases))
        for name, doc, descriptors in cases:
            with self.subTest(fixture=name):
                if doc["expect"] == "accept":
                    validate_edit(doc["edit"], descriptors)
                else:
                    with self.assertRaises(EditError) as caught:
                        validate_edit(doc["edit"], descriptors)
                    self.assertEqual(caught.exception.path, doc["path"])

    def test_fixture_manifest_is_backend_edit_registry(self):
        for _, _, descriptors in fixtures():
            self.assertEqual(descriptors, EDIT_DESCRIPTORS)

    def test_invalid_fixtures_never_mutate_world(self):
        world = world_with_targets()
        for seq, (name, doc, _) in enumerate(fixtures()):
            if doc["expect"] == "reject":
                with self.subTest(fixture=name):
                    self.assert_rejected_untouched(world, edit_line(seq, doc["edit"]), doc["path"])

    def test_valid_fixtures_apply_exact_value_and_advance_revision(self):
        expected_actual = {"valid-yaw-request-bound.json": 0.0}
        for name, doc, _ in fixtures():
            if doc["expect"] != "accept":
                continue
            with self.subTest(fixture=name):
                world = world_with_targets()
                edit = {**doc["edit"]}
                edit["expected_revision"] = old = current_revision(world, edit)
                result = world.apply_command(edit_line(1, edit))
                self.assertEqual(result["actual_value"], expected_actual.get(name, edit["value"]))
                self.assertGreater(result["revision"], old)
                self.assertEqual(result["revision"], current_revision(world, edit))
                # The same expected revision is now stale and changes nothing.
                error = self.assert_rejected_untouched(
                    world, edit_line(2, edit), "edit.expected_revision", "rejected_stale_revision")
                self.assertEqual(error.detail, {"current_revision": result["revision"]})

    def test_applied_value_is_visible_in_state(self):
        world = world_with_targets()
        edit = dict(schema_version=1, property_id="object.wall.size_mm", target_id="wall_1",
                    expected_revision=world.objects["wall_1"].revision, unit="mm", value=[3, 40, 12])
        world.apply_edit(edit)
        wall = next(o for o in world.state()["objects"] if o["id"] == "wall_1")
        self.assertEqual(wall["size_mm"], [3.0, 40.0, 12.0])
        edit = dict(schema_version=1, property_id="object.car.size_mm", target_id="car_1",
                    expected_revision=world.objects["car_1"].revision, unit="mm", value=20)
        self.assertEqual(world.apply_edit(edit)["actual_value"], 20.0)
        self.assertEqual(world.objects["car_1"].size_mm[0], 20.0)
        edit = dict(schema_version=1, property_id="temperature.mode", target_id=None,
                    expected_revision=world.environment_revision, unit="none", value="flywire_sensory")
        world.apply_edit(edit)
        temperature = world.state()["temperature"]
        self.assertEqual((temperature["mode"], temperature["celsius"], temperature["neural_connected"]),
                         ("flywire_sensory", 25.0, True))

    def test_backend_only_rejections_never_mutate_world(self):
        world = world_with_targets()
        base = dict(schema_version=1, property_id="object.box.position_mm", target_id="box_1",
                    expected_revision=world.objects["box_1"].revision, unit="mm", value=[1, 2, 3])
        for edit, path, status in (
                ({**base, "target_id": "nope"}, "edit.target_id", "rejected_target"),
                ({**base, "target_id": "sphere_1",
                  "expected_revision": world.objects["sphere_1"].revision},
                 "edit.target_id", "rejected_target"),
                ({**base, "property_id": "object.sphere.size_mm", "value": 3},
                 "edit.target_id", "rejected_target"),
                ({**base, "expected_revision": base["expected_revision"] + 1},
                 "edit.expected_revision", "rejected_stale_revision"),
                # Puff timing is an action, not a continuous-wind setting.
                (dict(schema_version=1, property_id="wind.continuous", target_id=None,
                      expected_revision=world.environment_revision, unit="none", value=True),
                 "edit.property_id", "rejected_unsupported")):
            with self.subTest(edit=edit):
                self.assert_rejected_untouched(world, edit_line(5, edit), path, status)
        self.assert_rejected_untouched(world, LabCommand.from_dict(
            {"type": "lab_command", "id": 6, "action": "edit_property"}), "edit")

    def wind_edit(self, world, prop, value):
        unit = {"wind.strength": "normalized", "wind.direction_deg": "deg"}.get(prop, "none")
        return dict(schema_version=1, property_id=prop, target_id=None,
                    expected_revision=world.environment_revision, unit=unit, value=value)

    def test_wind_edits_configure_continuous_wind_only(self):
        world = LabWorld()
        # Direction while off: stays off, direction is kept for the next turn-on.
        self.assertEqual(world.apply_edit(self.wind_edit(world, "wind.direction_deg", -90))["actual_value"], 270.0)
        self.assertEqual((world.wind["strength"], world.wind["continuous"]), (0.0, False))
        on = world.apply_edit(self.wind_edit(world, "wind.strength", 0.4))
        self.assertEqual(on["actual_value"], 0.4)
        wind = world.state()["wind"]
        self.assertEqual((wind["strength"], wind["direction_deg"], wind["continuous"], wind["remaining_ms"]),
                         (0.4, 270.0, True, None))
        # Flags and direction change without touching strength or continuity.
        self.assertIs(world.apply_edit(self.wind_edit(world, "wind.physical", False))["actual_value"], False)
        world.apply_edit(self.wind_edit(world, "wind.direction_deg", 45))
        wind = world.state()["wind"]
        self.assertEqual((wind["strength"], wind["direction_deg"], wind["continuous"],
                          wind["physical_enabled"], wind["sensory_enabled"]), (0.4, 45.0, True, False, True))
        # A continuous wind survives simulated time; strength 0 turns it off.
        for _ in range(100):
            world.pre_step(0.01)
        self.assertEqual(world.wind["strength"], 0.4)
        off = world.apply_edit(self.wind_edit(world, "wind.strength", 0))
        self.assertEqual((off["actual_value"], world.wind["continuous"], world.wind["direction_deg"]), (0.0, False, 45.0))

    def test_wind_edit_never_overwrites_running_puff(self):
        world = LabWorld()
        world.apply_command(LabCommand.from_dict({"type": "lab_command", "id": 1, "action": "wind_puff",
                                                  "strength": .7, "duration_ms": 300}))
        for prop, value in (("wind.strength", .2), ("wind.direction_deg", 90), ("wind.sensory", False)):
            with self.subTest(prop=prop):
                self.assert_rejected_untouched(world, edit_line(2, self.wind_edit(world, prop, value)),
                                               "edit.property_id", "rejected_busy")
        for _ in range(31):
            world.pre_step(0.01)
        self.assertEqual(world.wind["strength"], 0.0)
        self.assertEqual(world.apply_edit(self.wind_edit(world, "wind.strength", .2))["actual_value"], .2)

    def test_held_object_is_not_editable(self):
        world = world_with_targets()
        world.interaction.held_object_id = "box_1"
        edit = dict(schema_version=1, property_id="object.yaw_deg", target_id="box_1",
                    expected_revision=world.objects["box_1"].revision, unit="deg", value=10)
        self.assert_rejected_untouched(world, edit_line(1, edit), "edit.target_id", "rejected_target")

    def test_nonfinite_and_overflowing_wire_numbers_reject_without_mutation(self):
        world = world_with_targets()
        revision = world.environment_revision
        for token in ("NaN", "Infinity", "-Infinity", "1e999", "1" + "0" * 400):
            for value in (token, f"[{token},0,0]"):
                prop, unit, target = (("temperature.celsius", "degC", "null") if "[" not in value else
                                      ("object.box.position_mm", "mm", '"box_1"'))
                rev = revision if "[" not in value else world.objects["box_1"].revision
                line = ('{"type":"lab_command","id":7,"action":"edit_property","edit":'
                        f'{{"schema_version":1,"property_id":"{prop}","target_id":{target},'
                        f'"expected_revision":{rev},"unit":"{unit}","value":{value}}}}}').encode()
                with self.subTest(value=value):
                    command = decode_line(line)
                    self.assertIsInstance(command, LabCommand)
                    path = "edit.value" if "[" not in value else "edit.value[0]"
                    self.assert_rejected_untouched(world, command, path)

    def test_legacy_commands_keep_clamping_and_advance_environment_revision(self):
        world = LabWorld()
        start = world.environment_revision
        world.apply_command(LabCommand.from_dict({"type": "lab_command", "id": 1,
                                                  "action": "temperature", "value": 80}))
        self.assertEqual(world.temperature["celsius"], 50.0)
        world.apply_command(LabCommand.from_dict({"type": "lab_command", "id": 2,
                                                  "action": "set_eye_state", "target": "left", "value": 1}))
        self.assertEqual(world.environment_revision, start + 2)
        world.reset()
        self.assertEqual(world.environment_revision, start + 3)
        # A legacy change makes an edit prepared against the earlier revision stale.
        edit = dict(schema_version=1, property_id="temperature.celsius", target_id=None,
                    expected_revision=start, unit="degC", value=20)
        self.assert_rejected_untouched(world, edit_line(3, edit), "edit.expected_revision",
                                       "rejected_stale_revision")

    def test_bridge_ack_carries_edit_result_and_rejection_path(self):
        bridge = Bridge(mode="mock")
        world = bridge.body.lab_world
        edit = dict(schema_version=1, property_id="temperature.celsius", target_id=None,
                    expected_revision=world.environment_revision, unit="degC", value=31)
        bridge.handle_line(json.dumps({"type": "lab_command", "id": 41, "action": "edit_property",
                                       "edit": edit}).encode() + b"\n")
        bridge.handle_line(json.dumps({"type": "lab_command", "id": 42, "action": "edit_property",
                                       "edit": {**edit, "value": 51}}).encode() + b"\n")
        bridge._apply_lab_commands()
        acks = [p for p in bridge._drain_lab_responses() if isinstance(p, LabStatePacket)]
        self.assertEqual([p.ack for p in acks], [41, 42])
        ok, bad = (json.loads(encode(p)) for p in acks)
        self.assertTrue(ok["ok"])
        self.assertEqual(ok["edit"], {"ok": True, "status": "applied",
                                      "property_id": "temperature.celsius", "target_id": None,
                                      "actual_value": 31.0, "previous_value": 25.0,
                                      "revision": edit["expected_revision"] + 1})
        self.assertEqual(ok["state"]["environment_revision"], edit["expected_revision"] + 1)
        self.assertFalse(bad["ok"])
        self.assertEqual(bad["edit"]["path"], "edit.value")
        self.assertEqual(bad["edit"]["status"], "rejected_invalid")
        self.assertEqual(world.temperature["celsius"], 31.0)
        self.assertEqual(LabStatePacket.from_dict(ok).edit, ok["edit"])

    def test_bridge_stale_ack_reports_current_revision(self):
        bridge = Bridge(mode="mock")
        edit = dict(schema_version=1, property_id="eyes.left_mask", target_id=None,
                    expected_revision=99, unit="normalized", value=.5)
        bridge.handle_line(json.dumps({"type": "lab_command", "id": 43, "action": "edit_property",
                                       "edit": edit}).encode() + b"\n")
        bridge._apply_lab_commands()
        ack = json.loads(encode(bridge._drain_lab_responses()[0]))
        self.assertEqual(ack["edit"], {"ok": False, "status": "rejected_stale_revision",
                                       "path": "edit.expected_revision", "reason": "stale revision",
                                       "current_revision": bridge.body.lab_world.environment_revision})


if __name__ == "__main__":
    unittest.main(verbosity=2)
