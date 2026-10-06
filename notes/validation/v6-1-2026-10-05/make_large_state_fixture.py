"""Regenerate fixtures/bridge/v6-large-state.ndjson (V6.1 transport bound).

Unbound LabWorld (no MuJoCo, no socket) with every shape configured to 256
slots, all 1536 filled with MAX_OBJECT_ID_LEN ids, encoded through the real
protocol.encode(LabStatePacket). The frame was under the old 512 KiB Swift
receive cap without the manifest and is over it with the manifest.
Run from siliconfly/: ../flygym-venv/bin/python notes/validation/v6-1-2026-10-05/make_large_state_fixture.py
"""
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "flygym_bridge"))

import protocol  # noqa: E402
from lab_world import LabWorld, MAX_OBJECT_ID_LEN  # noqa: E402

# V6.4 ramps keep their default 4 (empty) slots; the 1536-object load is unchanged.
SHAPES = ("box", "sphere", "wall", "food", "car", "trap")
world = LabWorld(slot_counts={shape: 256 for shape in SHAPES})
for shape in SHAPES:
    for i in range(256):
        prefix = f"{shape}-{i:03d}-"
        world.spawn_object(shape=shape, object_id=prefix + "x" * (MAX_OBJECT_ID_LEN - len(prefix)),
                           position_mm=[float(i), -float(i), 5.0])
state = world.state()
assert len(state["objects"]) == 1536 and len(state["environment_capabilities"]["descriptors"]) == 42

def frame(s):
    return protocol.encode(protocol.LabStatePacket(
        ack=101, ok=True, state=s, applied_tick=40, applied_epoch=1, status="applied",
        session_id="v6-large-fixture", epoch=1, sim_tick=40))

with_manifest = frame(state)
without = frame({k: v for k, v in state.items() if k != "environment_capabilities"})
assert len(without) - 1 < 512 * 1024 < len(with_manifest) - 1 < 1024 * 1024, (len(without), len(with_manifest))
out = os.path.join(ROOT, "fixtures", "bridge", "v6-large-state.ndjson")
with open(out, "wb") as f:
    f.write(with_manifest)
print(f"objects=1536 descriptors=42 line_bytes_with_manifest={len(with_manifest) - 1} "
      f"without_manifest={len(without) - 1} old_cap={512 * 1024} new_cap={1024 * 1024}")
