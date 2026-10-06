"""Negative control: with the running-puff guard removed from apply_edit, the
V6.5 busy test must fail (the edit silently overwrites the puff). Source is
patched in memory only. Run from repo root:
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/negative_control.py
"""
import sys, types, unittest
from pathlib import Path
root = Path(__file__).resolve().parents[3] / "flygym_bridge"
sys.path.insert(0, str(root))
import lab_world
src = (root / "lab_world.py").read_text()
guard = '''            if self.wind["strength"] > 0.0 and not self.wind["continuous"]:
                raise EditError("edit.property_id",
                                "a timed wind puff is running; wait for it to end or stop it",
                                status="rejected_busy")
'''
assert guard in src, "guard text not found"
patched = types.ModuleType("lab_world")
patched.__file__ = str(root / "lab_world.py")
exec(compile(src.replace(guard, ""), "lab_world_no_busy_guard", "exec"), patched.__dict__)
sys.modules["lab_world"] = patched
import test_environment_edits as t
t.LabWorld = patched.LabWorld
suite = unittest.TestSuite([t.EnvironmentEditTests("test_wind_edit_never_overwrites_running_puff")])
result = unittest.TextTestRunner(verbosity=0).run(suite)
ok = not result.wasSuccessful()
print("NEGATIVE CONTROL", "PASS (test detects the missing guard)" if ok else "FAIL (test passed without the guard)")
sys.exit(0 if ok else 1)
