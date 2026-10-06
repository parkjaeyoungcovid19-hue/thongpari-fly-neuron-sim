"""V6.1 capability metadata and the V6.2 strict EditCommand validator.

Legacy operations remain authoritative for their own mutation/coercion; only
`edit_property` uses validate_edit. Constants are intentionally not refactored
here; focused tests detect metadata/source drift.
"""
from __future__ import annotations

from copy import deepcopy
from functools import lru_cache
import math

SCHEMA_VERSION = 1
VALUE_TYPES = {"number", "vector", "boolean", "enum"}
NUMBER_UNITS = {"mm", "mm/s", "deg", "degC", "ms", "normalized"}
VECTOR_UNITS = {"mm", "unit_vector", "rgba"}
EFFECTS = {"PHYSICAL", "SENSORY-MODEL", "DIRECT-NEURAL", "VISUAL"}
REQUIRED = {
    "property_id", "label", "value_type", "unit", "min", "max", "default",
    "choices", "scope", "apply_mode", "supported_effects", "persistence",
    "legacy_commands", "legacy_field", "notes",
}
NOMINAL_TOUCH_TARGETS = (
    "thorax", "head", "abdomen", "left_front_leg", "left_middle_leg",
    "left_hind_leg", "right_front_leg", "right_middle_leg", "right_hind_leg",
    "lf", "lm", "lh", "rf", "rm", "rh",
)


def _text(value, limit=96):
    return (isinstance(value, str) and 1 <= len(value) <= limit
            and value == value.strip())


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _strings(value, limit, item_limit=96, allow_empty=False):
    return (isinstance(value, list) and (0 if allow_empty else 1) <= len(value) <= limit
            and all(_text(item, item_limit) for item in value)
            and len(set(value)) == len(value))


def validate_manifest(manifest):
    """Strictly decode v1 descriptors; ignore unknown fields, return isolated data.

    This does not validate, authorize or apply a legacy LabCommand. An enclosing
    optional consumer may discard a malformed manifest without discarding state.
    """
    if not isinstance(manifest, dict):
        raise ValueError("environment capabilities must be an object")
    version = manifest.get("schema_version")
    if not _number(version) or version != SCHEMA_VERSION:
        raise ValueError("unsupported environment schema_version")
    descriptors = manifest.get("descriptors")
    if not isinstance(descriptors, list) or not 1 <= len(descriptors) <= 128:
        raise ValueError("descriptors must contain 1..128 entries")
    decoded, ids = [], set()
    for index, d in enumerate(descriptors):
        def reject(reason):
            raise ValueError(f"descriptor {index}: {reason}")

        if not isinstance(d, dict) or not REQUIRED.issubset(d):
            reject("missing required fields")
        if not _text(d["property_id"]) or d["property_id"] in ids:
            reject("invalid or duplicate property_id")
        ids.add(d["property_id"])
        if not _text(d["label"], 200) or not _text(d["legacy_field"]):
            reject("invalid label or legacy_field")
        if not isinstance(d["notes"], str) or len(d["notes"]) > 2000:
            reject("invalid notes")
        # Validate strings before set membership, including hostile JSON arrays.
        enums = {"value_type": VALUE_TYPES, "scope": {"global", "local"},
                 "apply_mode": {"live", "spawn_only", "recompile"},
                 "persistence": {"scene_candidate", "transient"}}
        for key, allowed in enums.items():
            if not isinstance(d[key], str) or d[key] not in allowed:
                reject(f"invalid {key}")
        if not _strings(d["legacy_commands"], 16):
            reject("invalid legacy_commands")
        effects = d["supported_effects"]
        if not _strings(effects, 4, allow_empty=True) or not set(effects) <= EFFECTS:
            reject("invalid supported_effects")
        choices = d["choices"]
        if not _strings(choices, 64, allow_empty=True):
            reject("invalid choices")
        kind, unit = d["value_type"], d["unit"]
        if not isinstance(unit, str):
            reject("invalid unit")
        lo, hi, default = d["min"], d["max"], d["default"]
        if default is None and not d["notes"].strip():
            reject("contextual default requires notes")
        if kind == "number":
            if unit not in NUMBER_UNITS or choices:
                reject("number unit/choices mismatch")
            if not _number(lo) or not _number(hi) or lo > hi:
                reject("invalid number bounds")
            if default is not None and (not _number(default) or not lo <= default <= hi):
                reject("invalid number default")
        elif kind == "vector":
            if (unit not in VECTOR_UNITS or choices or not isinstance(lo, list)
                    or not isinstance(hi, list) or not 2 <= len(lo) <= 4
                    or len(hi) != len(lo)):
                reject("invalid vector bounds/unit/choices")
            if (unit == "unit_vector" and len(lo) != 3) or (unit == "rgba" and len(lo) != 4):
                reject("vector unit arity mismatch")
            if any(not _number(a) or not _number(b) or a > b for a, b in zip(lo, hi)):
                reject("invalid vector bounds")
            if default is not None and (
                    not isinstance(default, list) or len(default) != len(lo)
                    or any(not _number(v) or not a <= v <= b
                           for v, a, b in zip(default, lo, hi))):
                reject("invalid vector default")
        else:
            if unit != "none" or lo is not None or hi is not None:
                reject("nonnumeric bounds/unit mismatch")
            if kind == "boolean":
                if choices or (default is not None and not isinstance(default, bool)):
                    reject("invalid boolean choices/default")
            elif not choices or (default is not None and
                                 (not isinstance(default, str) or default not in choices)):
                reject("invalid enum choices/default")
        decoded.append({key: deepcopy(d[key]) for key in d if key in REQUIRED})
    result = {"schema_version": SCHEMA_VERSION, "descriptors": decoded}
    if "object_operations" in manifest:
        ops = manifest["object_operations"]
        if not isinstance(ops, list) or any(not isinstance(op, str) or op not in ("duplicate", "delete") for op in ops) or len(set(ops)) != len(ops):
            raise ValueError("invalid object_operations")
        result["object_operations"] = list(ops)
    return result


def _descriptor(property_id, label, kind, unit, lo, hi, default, commands, field,
                *, scope="global", mode="live", effects=(), persistence="scene_candidate",
                choices=(), notes=""):
    return dict(property_id=property_id, label=label, value_type=kind, unit=unit,
                min=lo, max=hi, default=default, choices=list(choices), scope=scope,
                apply_mode=mode, supported_effects=list(effects), persistence=persistence,
                legacy_commands=list(commands), legacy_field=field, notes=notes)


def _registry():
    result = []
    add = lambda *args, **kwargs: result.append(_descriptor(*args, **kwargs))
    shapes = ("box", "sphere", "wall", "food", "car", "trap", "ramp")
    add("object.shape", "Object shape", "enum", "none", None, None, "box",
        ("spawn_object",), "shape", scope="local", mode="spawn_only", choices=shapes,
        effects=("PHYSICAL", "VISUAL", "SENSORY-MODEL"),
        notes="Spawn only; existing object shape is immutable. food_marker/food_source alias food. Food has modeled odor/contact, no collision; toys use collidable palettes. Ramp is fixed walkable terrain (fly legs contact it; never grabbed/approached).")
    for shape in shapes:
        commands = (("spawn_object", "spawn_food", "spawn_food_marker") if shape == "food" else
                    ("spawn_object",) if shape in ("car", "trap") else
                    ("spawn_object", "spawn_" + shape))
        effects = ("VISUAL", "SENSORY-MODEL") if shape == "food" else ("PHYSICAL", "VISUAL")
        position = {"box": [40, 0, 5], "sphere": [40, 0, 5], "wall": [40, 0, 7.5],
                    "food": [20, 0, 1.5], "ramp": [40, 0, 4.69]}.get(shape)
        position_notes = ("World XYZ mm, not a floor snap. Supplied pose can intersect ground. Move preserves omitted coordinates; resize does not adjust Z.")
        if shape in ("car", "trap"):
            position_notes += (" Absent spawn pose is [40,0,.205*length] for car; [40,0,.3*side+4] for trap. UI toy spawn computes Z; backend accepts explicit Z.")
        if shape == "ramp":
            position_notes = ("World XYZ mm of the box center. Absent spawn Z puts the low top edge on the lawn (z=.5*L*sin(pitch)-.5*T*cos(pitch)). Size and pitch edits pivot about the middle of the low top edge, so they also move the center.")
        add(f"object.{shape}.position_mm", f"{shape.title()} position", "vector", "mm",
            [-1000] * 3, [1000] * 3, position, commands + ("move_object",), "position_mm",
            scope="local", effects=effects, notes=position_notes)
        if shape in ("box", "wall"):
            kind, lo, hi = "vector", [.2] * 3, [200] * 3
            default = [10, 10, 10] if shape == "box" else [2, 30, 15]
            notes = "Full XYZ lengths; Swift common size form sends equal components, so anisotropy is backend-only. UI min .1 differs from backend .2."
        elif shape == "ramp":
            kind, lo, hi, default = "vector", [5, 2, .2], [200, 200, 20], [40, 20, 1]
            notes = "Full [length X, width Y, thickness Z] in the ramp's own frame. Resize keeps the low top edge fixed."
        else:
            kind = "number"
            lo, hi, default = {"sphere": (.2, 100, 5), "food": (.2, 100, 3),
                               "car": (4, 60, 14), "trap": (8, 60, 20)}[shape]
            notes = ("Scalar diameter; applied size_mm is equal3 vector. Lists use first component; malformed supplied scalar falls back to3 (absent sphere default5)." if shape in ("sphere", "food") else
                     "Scalar length/side. Applied car dimensions [L,.44L,.41L], trap [L,L,.6L]. Spawn is strict scalar or len1; resize legacy clamps/uses first vector component. No Z adjustment on resize.")
        add(f"object.{shape}.size_mm", f"{shape.title()} size", kind, "mm", lo, hi,
            default, commands + ("resize_object",), "size_mm", scope="local",
            effects=effects, notes=notes)
    add("object.yaw_deg", "Object yaw", "number", "deg", -36000, 36000, 0,
        ("spawn_object", "spawn_box", "spawn_sphere", "spawn_wall", "spawn_ramp", "spawn_food", "spawn_food_marker", "move_object"),
        "yaw_deg", scope="local", effects=("PHYSICAL", "VISUAL"),
        notes="REQUEST bounds: clamp to [-36000,36000], then modulo360. APPLIED range [0,360). All shapes; rotation around world Z. Only ramps tilt (object.ramp.pitch_deg). Food rotates visually, is noncollidable.")
    add("object.ramp.pitch_deg", "Ramp tilt", "number", "deg", 0, 45, 15,
        ("spawn_object", "spawn_ramp"), "pitch_deg", scope="local", effects=("PHYSICAL", "VISUAL"),
        notes="Rotation about the ramp's own Y axis after yaw; positive raises the +X end. Pivots about the middle of the low top edge. Ramp only.")
    add("object.food.variant", "Food variant", "enum", "none", None, None, None,
        ("spawn_food", "spawn_food_marker"), "variant", scope="local", mode="spawn_only",
        effects=("VISUAL", "SENSORY-MODEL"),
        choices=("apple", "banana", "cheese", "grapes", "cookie", "sugar_cube"),
        notes="Absent variant rotates deterministically in choices order. Spawn-only; no existing-food variant setter, generic spawn_object ignores variant. State field food_variant; sugar is derived, not editable. UI has no selector.")
    temp_notes = "Backend stores 0..50C; Swift UI/coordinator clamp10..40C and currently activate locally before ACK. environment_only records only; modeled_physiology uses Swift tempo (no TRN); flywire_sensory uses modeled TRN_VP2/VP3a+VP3b current (no legacy temperature tempo override). No Python direct neural input."
    add("temperature.celsius", "Temperature", "number", "degC", 0, 50, 25,
        ("temperature", "set_temperature"), "celsius", effects=("SENSORY-MODEL",), notes=temp_notes)
    add("temperature.mode", "Temperature mode", "enum", "none", None, None, "environment_only",
        ("temperature", "set_temperature"), "mode", effects=("SENSORY-MODEL",),
        choices=("environment_only", "modeled_physiology", "flywire_sensory"), notes=temp_notes)
    wind = ("wind", "wind_puff")
    add("wind.strength", "Wind strength", "number", "normalized", 0, 1, 0, wind, "strength",
        effects=("PHYSICAL", "SENSORY-MODEL"), notes="Dimensionless, not m/s. Flags independently gate thorax mass*60000mm/s2*strength force (fading to 0 as the thorax reaches 30mm/s*strength along the wind) and modeled JO-C/E current. Initial off; UI form .7. Zero stops timer/continuous. Scene candidate only for authored continuous wind, not active puff.")
    add("wind.direction_deg", "Wind direction", "number", "deg", -36000, 36000, 0, wind, "direction_deg",
        effects=("PHYSICAL", "SENSORY-MODEL"), notes="REQUEST clamp [-36000,36000], then modulo360; APPLIED [0,360). 0 points +X,90 +Y; world horizontal force direction, not meteorological wind-from. UI remainder may be negative. Neural model uses body-relative direction; no food odor advection.")
    add("wind.continuous", "Continuous wind", "boolean", "none", None, None, None, wind, "continuous",
        effects=("PHYSICAL", "SENSORY-MODEL"), notes="Contextual request default: wind infers duration_ms absent; wind_puff defaults false. Applied true only if strength>0. Initial false. Scene candidate only for deliberate continuous settings; active timers are not scene settings.")
    add("wind.duration_ms", "Wind puff duration", "number", "ms", 1, 10000, 500, wind, "duration_ms",
        effects=("PHYSICAL", "SENSORY-MODEL"), persistence="transient",
        notes="Finite puff only; absent on wind implies continuous unless overridden. Continuous ignores duration. Active state contains remaining_ms, NOT authored duration. UI generic ms allows60000; backend clamps10000. Timer is simulation-time.")
    for field, effect in (("physical", "PHYSICAL"), ("sensory", "SENSORY-MODEL")):
        add(f"wind.{field}", f"Wind {field} enabled", "boolean", "none", None, None, True,
            wind, field, effects=(effect,), notes="Independent boolean request flag; state uses " + field + "_enabled. Both true initially. stop_wind retains flags/direction; scene candidate only for continuous wind configuration.")
    for side in ("left", "right"):
        for field, kind, unit, lo, hi, default in (("enabled", "boolean", "none", None, None, True),
                                                ("mask", "number", "normalized", 0, 1, 0)):
            add(f"eyes.{side}_{field}", f"{side.title()} eye {field}", kind, unit, lo, hi, default,
                ("set_eye_state", "eye_state"), f"{side}_{field}", effects=("SENSORY-MODEL",),
                notes="Disabled or mask1 blacks actual eye frames; partial mask multiplies by1-mask. No direct neural probe. UI cover/restore sends mask endpoints only; enabled and fractional mask are backend-only. restore_eyes resets both enabled/masks.")
    add("touch.target", "Touch target", "enum", "none", None, None, "thorax", ("touch",), "target",
        scope="local", effects=("PHYSICAL", "SENSORY-MODEL"), persistence="transient",
        choices=NOMINAL_TOUCH_TARGETS,
        notes="Unbound nominal targets include legacy leg aliases. Bound export filters resolved force-body targets. Physical specificity is body-part; neural channel is generic JO-A/B-like, not selected-part mapping. No persistent touch state.")
    add("touch.strength", "Touch strength", "number", "normalized", 0, 1, .5, ("touch",), "strength",
        scope="local", effects=("PHYSICAL", "SENSORY-MODEL"), persistence="transient",
        notes="Physical force always enabled: mass*16000mm/s2*strength. No physical:false switch. UI default .55; sensory flag independently controls generic modeled touch channel.")
    add("touch.duration_ms", "Touch duration", "number", "ms", 1, 1000, 20, ("touch",), "duration_ms",
        scope="local", effects=("PHYSICAL", "SENSORY-MODEL"), persistence="transient",
        notes="Backend default20ms versus UI150ms; UI generic maximum60000, backend clamps1000. Simulation-time active remaining timer is transient, not authored persistent duration.")
    add("touch.direction_world", "Touch direction", "vector", "unit_vector", [-1] * 3, [1] * 3, [0, 1, 0],
        ("touch",), "direction_world", scope="local", effects=("PHYSICAL",), persistence="transient",
        notes="Unit-direction APPLIED component bounds. Legacy REQUEST accepts/coerces a 3-vector then normalizes; zero/invalid falls back [0,1,0], not strict component rejection. Hidden by Swift command/form. This descriptor does not authorize or tighten mutation.")
    add("touch.sensory", "Touch sensory enabled", "boolean", "none", None, None, True,
        ("touch",), "sensory", scope="local", effects=("SENSORY-MODEL",), persistence="transient",
        notes="Backend-only option; physical force remains on. Generic modeled sensory drive, not direct neural stimulation or selected-part neural mapping.")
    flash_notes = "Brightness telemetry only: max(current,intensity) for selected eyes. Preserves looming; no real illumination or photoreceptor neural connection. Simulation-time pulse, never scene lighting."
    add("flash.eye", "Flash eye", "enum", "none", None, None, "both", ("flash_eye",), "eye",
        scope="local", effects=("SENSORY-MODEL",), persistence="transient",
        choices=("left", "right", "both"), notes=flash_notes)
    add("flash.intensity", "Flash intensity", "number", "normalized", 0, 1, 1, ("flash_eye",), "intensity",
        scope="local", effects=("SENSORY-MODEL",), persistence="transient", notes=flash_notes + " Zero stops without live timer.")
    add("flash.duration_ms", "Flash duration", "number", "ms", 1, 5000, 100, ("flash_eye",), "duration_ms",
        scope="local", effects=("SENSORY-MODEL",), persistence="transient", notes=flash_notes + " UI generic maximum60000; backend clamps5000.")
    for prop, label, lo, hi, default in (("speed_mm_s", "Approach speed", .1, 2000, 80),
                                        ("end_distance_mm", "Approach end distance", .5, 500, 8)):
        add("approach." + prop, label, "number", "mm/s" if prop == "speed_mm_s" else "mm", lo, hi, default,
            ("approach_object", "approach"), prop, scope="local", effects=("PHYSICAL", "VISUAL"),
            persistence="transient", notes="Moves object toward snapshotted fly XY, not scripted fly locomotion. UI speed default12mm/s. Task is transient; completed authored object pose is separately a scene candidate.")
    for prop, label, hi, default in (("speed_mm_s", "Car drive speed", 60, 20),
                                   ("distance_mm", "Car drive distance", 300, 80)):
        add("drive." + prop, label, "number", "mm/s" if prop == "speed_mm_s" else "mm", 0, hi, default,
            ("drive_object",), prop, scope="local", effects=("PHYSICAL", "VISUAL"), persistence="transient",
            notes="Car-only transient action; actual strict legacy domain is 0 < value <= max (lower bound exclusive). Held car cannot drive. No active drive/task persistence.")
    return result


_NOMINAL = validate_manifest({"schema_version": SCHEMA_VERSION, "descriptors": _registry()})


# Read-only id->descriptor view for validate_edit. Bound manifests differ only
# in touch.target, a transient parameter that is never editable.
EDIT_DESCRIPTORS = {d["property_id"]: d for d in _NOMINAL["descriptors"]}


@lru_cache(maxsize=32)
def _cached_manifest(targets):
    """Private validated template; only registry/cache misses do schema work."""
    if targets is None:
        return _NOMINAL
    descriptors = list(_NOMINAL["descriptors"])
    if not targets:
        descriptors = [d for d in descriptors if d["property_id"] != "touch.target"]
    else:
        index = next(i for i, d in enumerate(descriptors) if d["property_id"] == "touch.target")
        target = deepcopy(descriptors[index])
        target["choices"] = list(targets)
        target["default"] = "thorax" if "thorax" in targets else None
        target["notes"] = "Resolved bound force-body targets (including available legacy aliases). Default thorax only if resolved; otherwise contextual null. Physical specificity is body-part, neural channel generic. Transient action, not scene configuration."
        descriptors[index] = target
    return validate_manifest({"schema_version": SCHEMA_VERSION, "descriptors": descriptors})


EDIT_SCHEMA_VERSION = 1
EDIT_FIELDS = ("schema_version", "property_id", "target_id", "expected_revision", "unit", "value")
MAX_REVISION = 2 ** 53


class EditError(ValueError):
    """Rejected edit with the JSON location of the first failing field."""

    def __init__(self, path, reason, status="rejected_invalid", **detail):
        super().__init__(f"{path}: {reason}")
        self.path, self.reason, self.status, self.detail = path, reason, status, detail


def validate_edit(edit, descriptors):
    """Strictly check one V6.2 edit against descriptors; never clamps or coerces.

    `descriptors` maps property_id -> validated descriptor. Checks run in a fixed
    order so Swift (EnvironmentEdit.validate) reports the same first path. This
    does not check the target object, current revision, or whether the backend
    has an applier for the property; LabWorld.apply_edit owns those.
    Returns (descriptor, value) with numbers as float.
    """
    if not isinstance(edit, dict):
        raise EditError("edit", "must be an object")
    unknown = sorted(key for key in edit if key not in EDIT_FIELDS)
    if unknown:
        raise EditError(f"edit.{unknown[0]}", "unknown field")
    for key in EDIT_FIELDS:
        if key not in edit:
            raise EditError(f"edit.{key}", "required")
    version = edit["schema_version"]
    if not _number(version) or version != EDIT_SCHEMA_VERSION:
        raise EditError("edit.schema_version", "unsupported edit schema_version")
    property_id = edit["property_id"]
    d = descriptors.get(property_id) if isinstance(property_id, str) else None
    if d is None:
        raise EditError("edit.property_id", "unknown property")
    if d["apply_mode"] != "live":
        raise EditError("edit.property_id", f"{d['apply_mode']} property is not live-editable")
    if d["persistence"] != "scene_candidate":
        raise EditError("edit.property_id", "transient action parameter is not an editable setting")
    if not isinstance(edit["unit"], str) or edit["unit"] != d["unit"]:
        raise EditError("edit.unit", f"unit must be {d['unit']}")
    target = edit["target_id"]
    if d["scope"] == "local":
        if not _text(target, 64):
            raise EditError("edit.target_id", "local property requires a target_id")
    elif target is not None:
        raise EditError("edit.target_id", "global property takes null target_id")
    revision = edit["expected_revision"]
    if (not _number(revision) or not float(revision).is_integer()
            or not 0 <= revision <= MAX_REVISION):
        raise EditError("edit.expected_revision", "must be a nonnegative integer")
    value, kind = edit["value"], d["value_type"]
    if kind == "number":
        if not _number(value) or not d["min"] <= value <= d["max"]:
            raise EditError("edit.value", f"must be a finite number in [{d['min']}, {d['max']}]")
        value = float(value)
    elif kind == "vector":
        if not isinstance(value, list) or len(value) != len(d["min"]):
            raise EditError("edit.value", f"must be a {len(d['min'])}-vector")
        for i, (v, lo, hi) in enumerate(zip(value, d["min"], d["max"])):
            if not _number(v) or not lo <= v <= hi:
                raise EditError(f"edit.value[{i}]", f"must be a finite number in [{lo}, {hi}]")
        value = [float(v) for v in value]
    elif kind == "boolean":
        if not isinstance(value, bool):
            raise EditError("edit.value", "must be a boolean")
    elif not isinstance(value, str) or value not in d["choices"]:
        raise EditError("edit.value", "must be one of the descriptor choices")
    return d, value


def environment_capabilities(touch_targets=None):
    """Return an isolated nominal/resolved manifest, not cached mutable objects.

    None means unbound nominal targets. Empty resolved set is a distinct cache
    key and omits target choice: there is no supported nonempty enum to advertise.
    """
    key = None if touch_targets is None else tuple(
        name for name in NOMINAL_TOUCH_TARGETS if name in touch_targets)
    # Every validated field is a scalar or a flat list of scalars, so copying
    # the lists is a full deep copy; generic deepcopy was ~0.45 ms per state().
    cached = _cached_manifest(key)
    return {"object_operations": ["duplicate", "delete"],
            "schema_version": cached["schema_version"],
            "descriptors": [{k: (v[:] if type(v) is list else v) for k, v in d.items()}
                            for d in cached["descriptors"]]}
