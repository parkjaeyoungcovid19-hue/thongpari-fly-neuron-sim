"""V6.4 negative controls: undo one piece of the change in-process and confirm
the mock suite notices. From repo root:
flygym-venv/bin/python notes/validation/v6-4-2026-10-06/negative_control.py
"""
import io
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "flygym_bridge"))
sys.dont_write_bytecode = True

import lab_world  # noqa: E402
import test_v6_4_terrain  # noqa: E402


def failures():
    suite = unittest.defaultTestLoader.loadTestsFromModule(test_v6_4_terrain)
    result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    return sorted(t.id().rsplit(".", 1)[-1] for t, _ in result.failures + result.errors)


def mutate(name, target, attr, value):
    # The raw class attribute, so a staticmethod is restored as one.
    original = vars(target)[attr] if attr in vars(target) else getattr(target, attr)
    setattr(target, attr, value)
    try:
        failed = failures()
    finally:
        setattr(target, attr, original)
    print(f"{'DETECTED' if failed else 'MISSED  '}  {name}: {len(failed)} failing {failed}")
    return bool(failed)


baseline = failures()
print(f"baseline: {len(baseline)} failing {baseline}")
detected = [
    mutate("no low-edge pivot on tilt/resize", lab_world.LabWorld, "_pin_ramp_anchor",
           staticmethod(lambda obj, anchor: None)),
    mutate("capacity raised as plain LabError", lab_world, "CapacityError",
           type("CapacityError", (lab_world.LabError,), {})),
    mutate("render ignores tilt (yaw-only quaternion)", lab_world.LabObject, "quat_wxyz",
           lambda self: [math.cos(math.radians(self.yaw_deg) / 2), 0.0, 0.0,
                         math.sin(math.radians(self.yaw_deg) / 2)]),
    mutate("ramps grabbable / approachable", lab_world.LabWorld, "start_approach",
           lambda self, object_id, **kw: {"id": object_id}),
]
ok = not baseline and all(detected)
print("NEGATIVE CONTROLS: " + ("all detected" if ok else "GAP"))
sys.exit(0 if ok else 1)
