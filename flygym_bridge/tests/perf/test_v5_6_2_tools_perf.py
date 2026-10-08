# Works both under unittest discovery and as a directly invoked test file.
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tests._support import ROOT, REPO
"""V5.6.2 sandbox toy mechanics: mock contract, real contacts and idle cost."""
import math
import json
import statistics
import time

import mujoco

import sandbox_models as sm
from fly_body import MockBody, RealFlyBody
from lab_world import LabError, BB_POOL_SIZE, CARRY_GAP_MM
from neural_decoder import LocomotorCommand
from protocol import LabCommand
from bridge import Bridge

failures = []
idle = LocomotorCommand(forward=0)


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""), flush=True)
    if not ok:
        failures.append(name)


def command(body, op, **args):
    return body.apply_lab_command(LabCommand(op=op, args=args))


def event_names(world):
    return [event["event"] for event in world.drain_events()]


real = RealFlyBody(config={}, show_viewer=False)
def reset():
    real.reset_body()
# Paired ratios compare the compiled idle toy topology with a body that has no
# car/trap slots. Warm each first; use alternating native-step samples.
reset()
baseline = RealFlyBody(config={"slot_counts": {"car": 0, "trap": 0}}, show_viewer=False)
for body in (real, baseline):
    body.vision_period = 1e9
    body.vision_elapsed = 0.0
for _ in range(10):
    real.step_exact(idle, 200)
    baseline.step_exact(idle, 200)
ratios = []
base_ms = []
toy_ms = []
for repeat in range(30):
    pair = {}
    order = (("base", baseline), ("toy", real))
    if repeat % 2:
        order = tuple(reversed(order))
    for label, body in order:
        start = time.perf_counter()
        body.step_exact(idle, 200)
        pair[label] = (time.perf_counter() - start) * 1000
    base, toy = pair["base"], pair["toy"]
    base_ms.append(base)
    toy_ms.append(toy)
    ratios.append(toy / base)
print(f"TOY_PERF baseline_median_ms={statistics.median(base_ms):.3f} "
      f"idle_toys_median_ms={statistics.median(toy_ms):.3f} "
      f"paired_ratio_median={statistics.median(ratios):.4f} "
      f"paired_ratios={[round(r, 3) for r in ratios]}")
check("idle toy overhead <= 5%", statistics.median(ratios) <= 1.05)
baseline.close()
real.close()
print(f"V5.6.2 TOOLS: {len(failures)} FAIL")
if failures:
    raise SystemExit(1)
