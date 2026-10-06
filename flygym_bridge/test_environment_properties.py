"""V6.1 descriptor tests; no real simulation, sockets, listeners or GPU.

Run: PYTHONDONTWRITEBYTECODE=1 flygym-venv/bin/python flygym_bridge/test_environment_properties.py
"""
from copy import deepcopy
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

from environment_properties import (environment_capabilities, validate_manifest, REQUIRED,
                                    NOMINAL_TOUCH_TARGETS, _cached_manifest)
from lab_world import LabError, LabWorld
from protocol import LabStatePacket, encode

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures" / "environment_capabilities"


class EnvironmentPropertiesTests(unittest.TestCase):
    def setUp(self):
        self.manifest = environment_capabilities()
        self.by_id = {d["property_id"]: d for d in self.manifest["descriptors"]}

    def invalid(self, selected_id, **fields):
        manifest = deepcopy(self.manifest)
        descriptor = next(d for d in manifest["descriptors"] if d["property_id"] == selected_id)
        descriptor.update(fields)
        with self.assertRaises(ValueError):
            validate_manifest(manifest)

    def test_shared_fixtures(self):
        paths = sorted(FIXTURES.glob("*.json"))
        self.assertGreaterEqual(len(paths), 9)
        for path in paths:
            with self.subTest(fixture=path.name):
                manifest = json.loads(path.read_text())
                if path.name.startswith("valid"):
                    validate_manifest(manifest)
                else:
                    with self.assertRaises(ValueError):
                        validate_manifest(manifest)

    def test_nominal_fixture_exactly_matches_unbound_state(self):
        fixture = json.loads((FIXTURES / "valid.json").read_text())
        self.assertEqual(LabWorld().state()["environment_capabilities"], fixture)
        self.assertEqual(len(fixture["descriptors"]), 42)

    def test_version_and_manifest_structure(self):
        for version in (True, False, 0, 2, 1.1, "1", None, [], float("nan")):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_manifest({**self.manifest, "schema_version": version})
        self.assertEqual(validate_manifest({**self.manifest, "schema_version": 1.0}), self.manifest)
        for manifest in (None, [], {}, {"schema_version": 1, "descriptors": []},
                         {"schema_version": 1, "descriptors": self.manifest["descriptors"] * 4}):
            with self.subTest(manifest=type(manifest)), self.assertRaises(ValueError):
                validate_manifest(manifest)

    def test_every_required_key_is_required(self):
        for key in REQUIRED:
            m = deepcopy(self.manifest)
            del m["descriptors"][0][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_manifest(m)

    def test_unknown_fields_ignored_and_output_isolated(self):
        m = deepcopy(self.manifest)
        m["future"] = {"anything": 1}
        m["descriptors"][0]["future"] = True
        decoded = validate_manifest(m)
        self.assertEqual(decoded, self.manifest)
        decoded["descriptors"][0]["choices"].clear()
        self.assertTrue(m["descriptors"][0]["choices"])

    def test_identity_limits_and_enum_contracts(self):
        for key, value in (("property_id", " x"), ("label", "x "), ("legacy_field", ""),
                           ("property_id", "x" * 97), ("label", "x" * 201),
                           ("notes", "x" * 2001), ("scope", "object"),
                           ("apply_mode", "read_only"), ("persistence", "saved"),
                           ("value_type", []), ("unit", {})):
            with self.subTest(key=key):
                self.invalid("object.shape", **{key: value})
        m = deepcopy(self.manifest)
        m["descriptors"][1]["property_id"] = m["descriptors"][0]["property_id"]
        with self.assertRaises(ValueError):
            validate_manifest(m)
        for fields in (dict(choices=[]), dict(choices=["box", "box"]),
                       dict(choices=[" box"]), dict(default="unknown"), dict(min=0),
                       dict(choices=[str(i) for i in range(65)])):
            self.invalid("object.shape", **fields)

    def test_command_and_effect_arrays(self):
        for fields in (dict(legacy_commands=[]), dict(legacy_commands=["x"] * 2),
                       dict(legacy_commands=[str(i) for i in range(17)]),
                       dict(legacy_commands=[False]), dict(supported_effects=["fiction"]),
                       dict(supported_effects=["PHYSICAL"] * 2), dict(supported_effects=None)):
            self.invalid("object.shape", **fields)
        m = deepcopy(self.manifest)
        m["descriptors"][0]["supported_effects"] = []
        validate_manifest(m)  # Metadata-only / contextual effective effects allowed.

    def test_numbers_reject_boolean_string_nonfinite_and_bad_bounds(self):
        for value in (True, "25", float("nan"), float("inf"), 10 ** 1000, []):
            for field in ("min", "max", "default"):
                with self.subTest(field=field, value=type(value)):
                    self.invalid("temperature.celsius", **{field: value})
        for fields in (dict(min=51), dict(default=51), dict(unit="none"), dict(choices=["x"])):
            self.invalid("temperature.celsius", **fields)

    def test_vector_contracts(self):
        for fields in (dict(min=[0]), dict(max=[1000, 1000]), dict(default=[0, 0]),
                       dict(default=[False, 0, 0]), dict(default=[1001, 0, 0]),
                       dict(min=[float("inf"), 0, 0]), dict(unit="normalized"),
                       dict(choices=["x"])):
            self.invalid("object.box.position_mm", **fields)
        self.invalid("touch.direction_world", min=[-1, -1], max=[1, 1], default=[0, 1])
        self.invalid("object.box.position_mm", unit="rgba")

    def test_boolean_and_contextual_default_contracts(self):
        for fields in (dict(default=1), dict(default="true"), dict(min=0),
                       dict(unit="normalized"), dict(choices=["true"])):
            self.invalid("eyes.left_enabled", **fields)
        for property_id in ("temperature.celsius", "object.box.position_mm",
                            "eyes.left_enabled", "object.shape"):
            self.invalid(property_id, default=None, notes="")
            m = deepcopy(self.manifest)
            d = next(d for d in m["descriptors"] if d["property_id"] == property_id)
            d.update(default=None, notes="Context-dependent request default.")
            validate_manifest(m)

    def test_manifest_export_isolation(self):
        first = environment_capabilities()
        first["descriptors"][1]["default"][0] = 999
        first["descriptors"][0]["choices"].append("fiction")
        first["descriptors"].clear()
        self.assertEqual(environment_capabilities(), self.manifest)

    def test_bounded_cache_isolation_and_changed_targets(self):
        _cached_manifest.cache_clear()
        first = environment_capabilities({"thorax": 1})
        first["descriptors"][0]["choices"].clear()
        second = environment_capabilities({"thorax": 9})
        self.assertEqual(second, environment_capabilities({"thorax": 1}))
        self.assertTrue(second["descriptors"][0]["choices"])
        self.assertGreaterEqual(_cached_manifest.cache_info().hits, 2)
        changed = environment_capabilities({"head": 2})
        target = next(d for d in changed["descriptors"] if d["property_id"] == "touch.target")
        self.assertEqual(target["choices"], ["head"])
        for bits in range(40):
            names = {name for i, name in enumerate(NOMINAL_TOUCH_TARGETS) if bits & (1 << i)}
            environment_capabilities(names)
        self.assertEqual(_cached_manifest.cache_info().maxsize, 32)
        self.assertLessEqual(_cached_manifest.cache_info().currsize, 32)
        self.assertEqual(environment_capabilities(), self.manifest)

    def test_resolved_touch_targets_and_nominal_aliases(self):
        nominal = self.by_id["touch.target"]["choices"]
        self.assertTrue(set(("thorax", "lf", "rh")) <= set(nominal))
        bound = environment_capabilities({"head": 2, "lf": 4})
        target = next(d for d in bound["descriptors"] if d["property_id"] == "touch.target")
        self.assertEqual(target["choices"], ["head", "lf"])
        self.assertIsNone(target["default"])
        self.assertNotIn("touch.target", {d["property_id"] for d in environment_capabilities({})["descriptors"]})
        world = LabWorld()
        world._bound = True  # Metadata branch only; no compiled model/GPU operation.
        world.force_body_ids = {"thorax": 1, "rf": 2}
        state = world.state()
        target = next(d for d in state["environment_capabilities"]["descriptors"] if d["property_id"] == "touch.target")
        self.assertEqual(target["choices"], ["thorax", "rf"])
        self.assertTrue(state["physical_backend"])

    def test_state_observation_has_no_side_effects(self):
        world = LabWorld()
        world.spawn_object(shape="food", object_id="snack")
        world.set_wind(strength=.7, direction_deg=90, duration_ms=400)
        world.apply_touch(strength=.3)
        world.set_temperature(celsius=32, mode="flywire_sensory")
        world.flash_eye(eye="left")
        snapshot = deepcopy(world.__dict__)
        before = world.state()
        exported = world.state()
        exported["environment_capabilities"]["descriptors"][0]["choices"].clear()
        self.assertEqual(world.state(), before)
        for field in ("objects", "revision", "structure_revision", "wind", "touch", "temperature",
                      "eyes", "flash", "events", "approaches", "drives", "feeding", "_free_slots"):
            self.assertEqual(world.__dict__[field], snapshot[field], field)

    def test_existing_ndjson_export_path(self):
        world = LabWorld()
        state = world.state()
        wire = encode(LabStatePacket(ack=9, ok=True, state=state))
        self.assertTrue(wire.endswith(b"\n"))
        decoded = json.loads(wire)
        self.assertEqual(decoded["state"]["environment_capabilities"], self.manifest)
        self.assertEqual(decoded["ack"], 9)
        self.assertEqual(decoded["temperature"], 25)
        self.assertFalse(decoded["left_eye_covered"])

    def test_configured_max_pool_frame_fits_swift_receive_cap(self):
        # Swift FlyGymBridge.maxInboundLineBytes drops whole lines above 1 MiB.
        # The manifest pushed this supported 1536-object frame past the old 512 KiB.
        shapes = ("box", "sphere", "wall", "food", "car", "trap")
        world = LabWorld(slot_counts={shape: 256 for shape in shapes})
        for shape in shapes:
            for i in range(256):
                prefix = f"{shape}-{i:03d}-"
                world.spawn_object(shape=shape, object_id=prefix + "x" * (64 - len(prefix)),
                                   position_mm=[float(i), -float(i), 5.0])
        state = world.state()
        line = len(encode(LabStatePacket(ack=101, ok=True, state=state, session_id="v6-large-fixture",
                                         epoch=1, sim_tick=40))) - 1
        self.assertEqual(len(state["objects"]), 1536)
        self.assertGreater(line, 512 * 1024)
        self.assertLess(line, 1024 * 1024)

    def test_geometry_defaults_and_bounds_match_existing_functions(self):
        world = LabWorld()
        for shape in ("box", "sphere", "wall", "food", "car", "trap"):
            with self.subTest(shape=shape):
                d = self.by_id[f"object.{shape}.size_mm"]
                actual = world.spawn_object(shape=shape)
                expected = d["default"]
                if d["value_type"] == "vector":
                    self.assertEqual(actual["size_mm"], expected)
                    self.assertEqual(world._sanitize_size(shape, [-9999] * 3), d["min"])
                    self.assertEqual(world._sanitize_size(shape, [9999] * 3), d["max"])
                else:
                    self.assertEqual(actual["size_mm"][0], expected)
                    self.assertEqual(world._sanitize_size(shape, -9999)[0], d["min"])
                    self.assertEqual(world._sanitize_size(shape, 9999)[0], d["max"])
                pose = self.by_id[f"object.{shape}.position_mm"]["default"]
                if pose is not None:
                    self.assertEqual(actual["position_mm"], pose)
                elif shape == "car":
                    self.assertAlmostEqual(actual["position_mm"][2], .205 * expected)
                else:
                    self.assertAlmostEqual(actual["position_mm"][2], .3 * expected + 4)
        world.move_object(actual["id"], position_mm=[-9999, 0, 9999], yaw_deg=-1)
        self.assertEqual(world.objects[actual["id"]].position_mm, [-1000, 0, 1000])
        self.assertEqual(world.objects[actual["id"]].yaw_deg, 359)

    def test_environment_defaults_and_ranges_match_legacy_setters(self):
        world = LabWorld()
        self.assertEqual(world.set_temperature()["celsius"], self.by_id["temperature.celsius"]["default"])
        self.assertEqual(world.set_temperature(celsius="999")["celsius"], 50)
        self.assertEqual(world.set_temperature(celsius=-999)["celsius"], 0)
        self.assertEqual(world.set_wind(strength="2", direction_deg=-1, continuous=False)["remaining_ms"], 500)
        self.assertEqual(world.wind["direction_deg"], 359)
        world.set_wind(strength=1, duration_ms=99999)
        self.assertEqual(world._wind_state()["remaining_ms"], self.by_id["wind.duration_ms"]["max"])
        world.apply_touch()
        self.assertEqual(world.touch["strength"], self.by_id["touch.strength"]["default"])
        self.assertEqual(world.touch["direction_world"], self.by_id["touch.direction_world"]["default"])
        self.assertEqual(world._touch_state()["remaining_ms"], self.by_id["touch.duration_ms"]["default"])
        world.apply_touch(duration_ms=99999, direction_world=[0, 50, 0])
        self.assertEqual(world._touch_state()["remaining_ms"], 1000)
        self.assertEqual(world.touch["direction_world"], [0, 1, 0])
        world.flash_eye()
        self.assertEqual(world.flash["intensity"], self.by_id["flash.intensity"]["default"])
        self.assertEqual(world._flash_state()["remaining_ms"], self.by_id["flash.duration_ms"]["default"])
        world.flash_eye(duration_ms=99999)
        self.assertEqual(world._flash_state()["remaining_ms"], 5000)
        world.set_eye_state(left_mask=999, right_mask=-999)
        self.assertEqual((world.eyes["left_mask"], world.eyes["right_mask"]), (1, 0))
        # Descriptor strictness must not tighten legacy coercion/clamping.
        self.invalid("temperature.celsius", default="25")

    def test_food_variant_rotation_and_spawn_only_wire_path(self):
        world = LabWorld()
        choices = self.by_id["object.food.variant"]["choices"]
        for variant in choices:
            self.assertEqual(world.spawn_object(shape="food")["food_variant"], variant)
        generic = world.apply_command(SimpleNamespace(op="spawn_object", args={"shape": "food", "variant": "cookie"}))
        self.assertEqual(generic["food_variant"], "apple")  # Generic op ignores variant.
        explicit = world.apply_command(SimpleNamespace(op="spawn_food", args={"variant": "cookie"}))
        self.assertEqual(explicit["food_variant"], "cookie")

    def test_action_defaults_and_strict_drive_domain_unchanged(self):
        world = LabWorld()
        ball = world.spawn_object(shape="sphere", object_id="ball")
        world.start_approach(ball["id"], fly_position_mm=[0, 0, 0])
        motion = world.approaches[ball["id"]]
        self.assertEqual(motion.speed_mm_s, self.by_id["approach.speed_mm_s"]["default"])
        self.assertEqual(motion.end_distance_mm, self.by_id["approach.end_distance_mm"]["default"])
        world.spawn_object(shape="car", object_id="car")
        world.apply_command(SimpleNamespace(op="drive_object", args={"id": "car"}))
        self.assertEqual(world.drives["car"].speed_mm_s, self.by_id["drive.speed_mm_s"]["default"])
        self.assertEqual(world.drives["car"].remaining_mm, self.by_id["drive.distance_mm"]["default"])
        with self.assertRaises(LabError):
            world.apply_command(SimpleNamespace(op="drive_object", args={"id": "car", "speed_mm_s": 0}))

    def test_no_unsupported_or_read_only_properties_advertised(self):
        ids = set(self.by_id)
        self.assertFalse(any(term in prop for prop in ids
                             for term in ("lighting", "humidity", "sugar", "slot", "player", "gun", "revision")))
        self.assertTrue(all("DIRECT-NEURAL" not in d["supported_effects"] for d in self.by_id.values()))
        self.assertEqual(self.by_id["object.food.variant"]["apply_mode"], "spawn_only")
        for prop in ids:
            if prop.startswith(("touch.", "flash.", "approach.", "drive.")) or prop == "wind.duration_ms":
                self.assertEqual(self.by_id[prop]["persistence"], "transient")


if __name__ == "__main__":
    unittest.main(verbosity=2)
