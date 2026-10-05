"""Negative controls: break apply_edit/validate_edit on purpose and confirm the
V6.2 tests fail. Run from repo root with flygym-venv python."""
import subprocess, sys, unittest
sys.path.insert(0, "flygym_bridge")
import environment_properties as ep
import lab_world
import test_environment_edits as t

def run(label):
    suite = unittest.defaultTestLoader.loadTestsFromModule(t)
    r = unittest.TextTestRunner(stream=open("/dev/null", "w")).run(suite)
    print(f"{label}: ran={r.testsRun} failures={len(r.failures)} errors={len(r.errors)}")
    return len(r.failures) + len(r.errors)

assert run("baseline") == 0

# 1. Mutate before the revision check (classic partial-apply bug).
orig = lab_world.LabWorld.apply_edit
def mutate_first(self, edit):
    if isinstance(edit, dict) and edit.get("property_id") == "temperature.celsius" and isinstance(edit.get("value"), (int, float)):
        self.temperature["celsius"] = float(edit["value"]) if 0 <= edit["value"] <= 50 else self.temperature["celsius"]
    return orig(self, edit)
lab_world.LabWorld.apply_edit = mutate_first
assert run("mutate-before-revision-check") > 0
lab_world.LabWorld.apply_edit = orig

# 2. Clamp instead of rejecting out-of-range numbers (legacy behaviour).
orig_v = ep.validate_edit
def clamping(edit, descriptors):
    if isinstance(edit, dict) and isinstance(edit.get("value"), (int, float)) and not isinstance(edit.get("value"), bool):
        d = descriptors.get(edit.get("property_id"))
        if d and d["value_type"] == "number":
            edit = {**edit, "value": min(max(edit["value"], d["min"]), d["max"])}
    return orig_v(edit, descriptors)
t.validate_edit = lab_world.validate_edit = clamping
assert run("clamp-instead-of-reject") > 0
t.validate_edit = lab_world.validate_edit = orig_v

# 3. Accept booleans as numbers (Python bool is an int subclass).
orig_n = ep._number
ep._number = lambda v: isinstance(v, (int, float)) and v == v and abs(v) != float("inf")
assert run("bool-as-number") > 0
ep._number = orig_n
assert run("restored") == 0
print("NEGATIVE CONTROLS PASS")
