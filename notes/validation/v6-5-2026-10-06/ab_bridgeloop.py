"""Battery-condition A/B for bridgeloop-real: current backend vs the same tree
with the V6.5 wind-edit hunk removed (scratch copy). Alternates A,B,A,B on
port 17841 (asserted free first). From repo root:
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/ab_bridgeloop.py SCRATCH_DIR
"""
import re, shutil, socket, subprocess, sys, time
from pathlib import Path
root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
scratch = Path(sys.argv[1]) / "flygym_bridge_no_v65"
if scratch.exists():
    shutil.rmtree(scratch)
shutil.copytree(root / "flygym_bridge", scratch, ignore=shutil.ignore_patterns("__pycache__"))
src = (scratch / "lab_world.py").read_text()
for block in ['''        elif pid in WIND_EDIT_FIELDS:
            if self.wind["strength"] > 0.0 and not self.wind["continuous"]:
                raise EditError("edit.property_id",
                                "a timed wind puff is running; wait for it to end or stop it",
                                status="rejected_busy")
            current = self.environment_revision
''', '''        elif pid in WIND_EDIT_FIELDS:
            w = self.wind
            settings = {"strength": w["strength"], "direction_deg": w["direction_deg"],
                        "physical": w["physical_enabled"], "sensory": w["sensory_enabled"]}
            state = self.set_wind(**{**settings, field: value}, continuous=True)
            actual = state[WIND_EDIT_FIELDS[pid]]
''']:
    assert block in src
    src = src.replace(block, "")
(scratch / "lab_world.py").write_text(src)
port = 17841
for label, bridge in [("A-current", root / "flygym_bridge/bridge.py"), ("B-no-v65", scratch / "bridge.py")] * 2:
    with socket.socket() as s:
        s.bind(("127.0.0.1", port))
    log = open(out / f"ab-{label}-backend.log", "a")
    backend = subprocess.Popen([str(root / "flygym-venv/bin/python"), str(bridge), "--flygym-headless"],
                               cwd=root, stdout=log, stderr=subprocess.STDOUT)
    try:
        t0 = time.monotonic()
        while True:
            assert backend.poll() is None
            try:
                socket.create_connection(("127.0.0.1", port), timeout=.2).close(); break
            except OSError:
                assert time.monotonic() - t0 < 120; time.sleep(.2)
        time.sleep(0.5)
        r = subprocess.run([str(root / "ThongpariFlyNeuronSim"), "--bridgeloop"], cwd=root,
                           capture_output=True, text=True, timeout=180)
        line = next((l for l in r.stdout.splitlines() + r.stderr.splitlines() if "sent 200 brain" in l), "?")
        print(f"{label}: exit={r.returncode} {line.split(': ',1)[-1]}", flush=True)
    finally:
        backend.terminate()
        try: backend.wait(15)
        except subprocess.TimeoutExpired: backend.kill(); backend.wait()
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port))
shutil.rmtree(scratch)
print("scratch copy removed; port 17841 bindable")
