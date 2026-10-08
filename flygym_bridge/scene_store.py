"""V6.7 `.flyworld` scene settings: export, strict validation, and the staged
document a LabWorld swaps in.

A scene file holds the authored world settings only — objects, temperature,
continuous wind, eye covers and the participant spawn. It is not a checkpoint:
neuron, body, controller and timer state are never written or restored.

Every value is checked against the same V6.1 descriptors `edit_property` uses
(`check_value`): nothing is clamped or coerced, and the first failing field is
reported by its JSON path (e.g. `scene.objects[2].size_mm[1]`). Validation
runs to completion before the owner world is touched; LabWorld.load_scene
then swaps the staged scene in one owner-thread step.
"""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from environment_properties import EDIT_DESCRIPTORS, EditError, _NOMINAL, check_value

SCENE_FORMAT = "thongpari.flyworld"
SCENE_SCHEMA_VERSION = 1
SCENE_KIND = "scene_settings"
SCENE_NOTE = ("World settings only (objects, temperature, continuous wind, eye covers, "
              "participant spawn). Not a checkpoint: neuron, body and timer state are not saved.")
COORDINATE_SYSTEM = ("MuJoCo world frame: Z up, origin at the lawn centre on the floor, "
                     "+X the fly's initial heading, +Y to its left")
UNITS = {"length": "mm", "angle": "deg", "temperature": "degC", "wind_strength": "normalized",
         "eye_mask": "normalized"}
MAX_DOCUMENT_BYTES = 1 << 20
DOCUMENT_FIELDS = ("format", "schema_version", "kind", "note", "coordinate_system", "units",
                   "scene", "assets", "content_sha256")
SCENE_FIELDS = ("objects", "environment", "player_spawn")
SHAPE_FIELDS = {"ramp": ("pitch_deg",), "food": ("variant",)}
ENVIRONMENT_FIELDS = {
    "temperature": ("celsius", "mode"),
    "wind": ("strength", "direction_deg", "physical", "sensory"),
    "eyes": ("left_enabled", "right_enabled", "left_mask", "right_mask"),
}
# Fly thorax and participant spawn clearances for the overlap check. A standing
# fly's thorax is ~1 mm above whatever it stands on, so 0.5 mm only rejects a
# solid that would actually be placed through it.
FLY_CLEARANCE_MM = 0.5


class SceneError(ValueError):
    """Rejected scene with the JSON location of the first failing field."""

    def __init__(self, path, reason, status="rejected_invalid", **detail):
        super().__init__(f"{path}: {reason}")
        self.path, self.reason, self.status, self.detail = path, reason, status, detail


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def content_hash(scene):
    return hashlib.sha256(canonical_bytes(scene)).hexdigest()


def asset_hashes():
    """What the saved values were authored against. Informational: a mismatch
    is reported on load, never silently treated as the same world."""
    models = Path(__file__).with_name("sandbox_models.py")
    return {
        "descriptor_manifest_sha256": hashlib.sha256(canonical_bytes(_NOMINAL)).hexdigest(),
        "sandbox_models_sha256": hashlib.sha256(models.read_bytes()).hexdigest(),
    }


def object_size_value(obj):
    """Owner size in its descriptor form (scalar for sphere/food/car/trap)."""
    size = [float(v) for v in obj.size_mm]
    kind = EDIT_DESCRIPTORS[f"object.{obj.shape}.size_mm"]["value_type"]
    return size if kind == "vector" else size[0]


def build_document(scene):
    return {
        "format": SCENE_FORMAT,
        "schema_version": SCENE_SCHEMA_VERSION,
        "kind": SCENE_KIND,
        "note": SCENE_NOTE,
        "coordinate_system": COORDINATE_SYSTEM,
        "units": dict(UNITS),
        "scene": scene,
        "assets": asset_hashes(),
        "content_sha256": content_hash(scene),
    }


def document_text(document):
    """The exact file bytes Swift writes (UTF-8, stable key order, newline)."""
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False,
                      allow_nan=False) + "\n"


def _reject(path, reason, status="rejected_invalid", **detail):
    raise SceneError(path, reason, status=status, **detail)


def _fields(value, path, required, optional=()):
    if not isinstance(value, dict):
        _reject(path, "must be an object")
    for key in sorted(value):
        if key not in required and key not in optional:
            _reject(f"{path}.{key}", "unknown field")
    for key in required:
        if key not in value:
            _reject(f"{path}.{key}", "required")


def _descriptor_value(property_id, value, path):
    try:
        return check_value(EDIT_DESCRIPTORS[property_id], value, path)
    except EditError as exc:
        raise SceneError(exc.path, exc.reason) from None


def parse_document(text):
    """Decode the wire/file text. Corrupt JSON and NaN/Infinity are rejected."""
    if not isinstance(text, str):
        _reject("scene_document", "must be a JSON text")
    if len(text.encode("utf-8")) > MAX_DOCUMENT_BYTES:
        _reject("scene_document", f"larger than {MAX_DOCUMENT_BYTES} bytes")

    def no_constants(name):
        raise ValueError(f"non-finite number {name}")
    try:
        def unique_keys(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError(f"duplicate JSON key {key}")
                result[key] = value
            return result
        return json.loads(text, parse_constant=no_constants, object_pairs_hook=unique_keys)
    except (ValueError, RecursionError) as exc:
        _reject("scene_document", f"not valid JSON ({str(exc)[:120]})", status="rejected_corrupt")


def validate_document(document, *, slot_counts, max_object_id_len, player_limit_mm):
    """Fully check a decoded document. Returns (staged scene, asset mismatches)."""
    _fields(document, "document", DOCUMENT_FIELDS)
    if document["format"] != SCENE_FORMAT:
        _reject("document.format", f"must be {SCENE_FORMAT}")
    version = document["schema_version"]
    if type(version) is not int or version != SCENE_SCHEMA_VERSION:
        _reject("document.schema_version", f"unsupported schema_version (this build reads {SCENE_SCHEMA_VERSION})",
                status="rejected_schema")
    if document["kind"] != SCENE_KIND:
        _reject("document.kind", f"must be {SCENE_KIND} (a scene file is not a checkpoint)")
    if document["units"] != UNITS:
        _reject("document.units", "unit set differs from this build")
    if document["coordinate_system"] != COORDINATE_SYSTEM:
        _reject("document.coordinate_system", "coordinate system differs from this build")
    scene = document["scene"]
    _fields(scene, "scene", SCENE_FIELDS)
    digest = document["content_sha256"]
    if not isinstance(digest, str) or digest != content_hash(scene):
        _reject("document.content_sha256", "does not match the scene content (file changed or damaged)",
                status="rejected_corrupt")
    assets = document["assets"]
    _fields(assets, "document.assets", tuple(asset_hashes()))
    mismatched = sorted(k for k, v in asset_hashes().items() if assets[k] != v)

    objects = scene["objects"]
    if not isinstance(objects, list):
        _reject("scene.objects", "must be a list")
    staged, seen, per_shape = [], set(), {}
    shapes = EDIT_DESCRIPTORS["object.shape"]["choices"]
    for i, raw in enumerate(objects):
        path = f"scene.objects[{i}]"
        if not isinstance(raw, dict):
            _reject(path, "must be an object")
        shape = raw.get("shape")
        if not isinstance(shape, str) or shape not in shapes:
            _reject(f"{path}.shape", "must be one of " + ", ".join(shapes))
        _fields(raw, path, ("id", "shape", "position_mm", "size_mm", "yaw_deg") + SHAPE_FIELDS.get(shape, ()))
        object_id = raw["id"]
        if (not isinstance(object_id, str) or not 1 <= len(object_id) <= max_object_id_len
                or object_id != object_id.strip()):
            _reject(f"{path}.id", f"must be 1-{max_object_id_len} characters without surrounding spaces")
        if object_id in seen:
            _reject(f"{path}.id", f"duplicate id {object_id}", status="rejected_duplicate")
        seen.add(object_id)
        per_shape[shape] = per_shape.get(shape, 0) + 1
        if per_shape[shape] > int(slot_counts.get(shape, 0)):
            _reject(path, f"more {shape} objects than this build has slots ({slot_counts.get(shape, 0)})",
                    status="rejected_capacity", shape=shape, capacity=int(slot_counts.get(shape, 0)))
        item = {
            "id": object_id, "shape": shape,
            "position_mm": _descriptor_value(f"object.{shape}.position_mm", raw["position_mm"], f"{path}.position_mm"),
            "size_mm": _descriptor_value(f"object.{shape}.size_mm", raw["size_mm"], f"{path}.size_mm"),
            "yaw_deg": _descriptor_value("object.yaw_deg", raw["yaw_deg"], f"{path}.yaw_deg"),
        }
        if shape == "ramp":
            item["pitch_deg"] = _descriptor_value("object.ramp.pitch_deg", raw["pitch_deg"], f"{path}.pitch_deg")
        if shape == "food":
            item["variant"] = _descriptor_value("object.food.variant", raw["variant"], f"{path}.variant")
        staged.append(item)

    env = scene["environment"]
    _fields(env, "scene.environment", tuple(ENVIRONMENT_FIELDS))
    environment = {}
    for group, keys in ENVIRONMENT_FIELDS.items():
        block = env[group]
        _fields(block, f"scene.environment.{group}", keys)
        environment[group] = {key: _descriptor_value(f"{group}.{key}", block[key],
                                                     f"scene.environment.{group}.{key}")
                              for key in keys}

    spawn = scene["player_spawn"]
    _fields(spawn, "scene.player_spawn", ("position_mm",))
    position = spawn["position_mm"]
    if not isinstance(position, list) or len(position) != 3:
        _reject("scene.player_spawn.position_mm", "must be a 3-vector")
    for i, v in enumerate(position):
        bad = isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v)
        limit = player_limit_mm if i < 2 else 1000.0
        if bad or abs(v) > limit:
            _reject(f"scene.player_spawn.position_mm[{i}]", f"must be a finite number in [-{limit}, {limit}]")
    return {"objects": staged, "environment": environment,
            "player_spawn": [float(v) for v in position]}, mismatched


# ----------------------------------------------------------------------
# Overlap check (V6-05 "overlapping spawn")
# ----------------------------------------------------------------------
def _local_point(item, point):
    """`point` in the object's own frame (yaw about Z, then ramp pitch about Y)."""
    yaw = math.radians(item["yaw_deg"])
    pitch = math.radians(item.get("pitch_deg", 0.0))
    dx, dy, dz = (p - c for p, c in zip(point, item["position_mm"]))
    x = math.cos(yaw) * dx + math.sin(yaw) * dy
    y = -math.sin(yaw) * dx + math.cos(yaw) * dy
    return (math.cos(pitch) * x + math.sin(pitch) * dz, y,
            -math.sin(pitch) * x + math.cos(pitch) * dz)


def solid_extent(item, toy_size):
    """Full lengths of the solid's box, or None for a sphere/non-solid."""
    shape, size = item["shape"], item["size_mm"]
    if shape in ("box", "wall", "ramp"):
        return list(size)
    if shape in ("car", "trap"):
        return toy_size(shape, size)
    return None


def surface_distance(item, point, toy_size):
    """Distance from `point` to the solid; negative inside. None for food."""
    if item["shape"] == "food":
        return None
    if item["shape"] == "sphere":
        return math.dist(point, item["position_mm"]) - 0.5 * item["size_mm"]
    half = [0.5 * v for v in solid_extent(item, toy_size)]
    local = _local_point(item, point)
    q = [abs(c) - h for c, h in zip(local, half)]
    outside = math.sqrt(sum(max(v, 0.0) ** 2 for v in q))
    return outside + min(max(q), 0.0)


def first_overlap(staged, *, fly_point_mm, player_spawn_mm, player_radius_mm, toy_size):
    """(path, reason) of the first solid placed through the fly or the
    participant spawn, or None."""
    for i, item in enumerate(staged["objects"]):
        for point, clearance, who in ((fly_point_mm, FLY_CLEARANCE_MM, "the fly's current position"),
                                      (player_spawn_mm, player_radius_mm, "the participant spawn")):
            if point is None:
                continue
            d = surface_distance(item, point, toy_size)
            if d is not None and d < clearance:
                return (f"scene.objects[{i}].position_mm",
                        f"{item['id']} would overlap {who} ({d:.2f} mm < {clearance:g} mm clearance)")
    return None
