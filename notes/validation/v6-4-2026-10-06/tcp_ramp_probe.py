"""V6.4 ramp over a real socket. From repo root:
flygym-venv/bin/python notes/validation/v6-4-2026-10-06/tcp_ramp_probe.py {mock|real}

Starts its own backend on a free private port (never 17841), speaks the same
NDJSON a Swift client sends, and always terminates the backend.
"""
import json
import math
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
mode = sys.argv[1]
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
env = {**os.environ, "THONGPARI_BRIDGE_PORT": str(port), "PYTHONDONTWRITEBYTECODE": "1"}
flag = "--mock" if mode == "mock" else "--flygym-headless"
log = open(out / f"tcp-probe-{mode}-backend.log", "w")
backend = subprocess.Popen([str(root / "flygym-venv/bin/python"), str(root / "flygym_bridge/bridge.py"), flag],
                           cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
fails = []


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""), flush=True)
    if not ok:
        fails.append(name)


class Client:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buf = b""
        self.state = None
        self.snapshots = []

    def send(self, obj):
        self.sock.sendall(json.dumps(obj).encode() + b"\n")

    def pump(self, until, timeout=30):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                msg = json.loads(line)
                if msg.get("type") == "lab_state" and isinstance(msg.get("state"), dict):
                    self.state = msg["state"]
                if msg.get("type") == "world_render_snapshot":
                    self.snapshots.append(msg)
                hit = until(msg)
                if hit:
                    return msg
            self.buf += self.sock.recv(65536)
        raise TimeoutError("no matching packet")


seq = 100


def command(action, **fields):
    global seq
    seq += 1
    client.send({"type": "lab_command", "id": seq, "action": action, "protocol_version": 4,
                 "session_id": "v64probe", "epoch": 1, "requested_tick": 0, **fields})
    return client.pump(lambda m: m.get("type") == "lab_state" and m.get("ack") == seq)


def obj(object_id):
    return next((o for o in client.state["objects"] if o["id"] == object_id), None)


def anchor(o):
    """Middle of the low top edge, from the reported pose (no lab_world import)."""
    y, p = math.radians(o["yaw_deg"]), math.radians(o.get("pitch_deg", 0.0))
    lx, lz = -o["size_mm"][0] / 2, o["size_mm"][2] / 2
    x, z = math.cos(p) * lx - math.sin(p) * lz, math.sin(p) * lx + math.cos(p) * lz
    c = o["position_mm"]
    return [c[0] + math.cos(y) * x, c[1] + math.sin(y) * x, c[2] + z]


code = 2
try:
    t0 = time.monotonic()
    while True:
        assert backend.poll() is None, "backend died"
        try:
            socket.create_connection(("127.0.0.1", port), timeout=.2).close()
            break
        except OSError:
            assert time.monotonic() - t0 < 120, "backend readiness"
            time.sleep(.2)
    owner = subprocess.check_output(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], text=True).split()
    check("listener is this probe's backend", owner == [str(backend.pid)], f"port {port} pid {owner}")
    time.sleep(0.5)  # the readiness probe connection must be retired first
    client = Client()
    client.send({"type": "hello", "protocol_version": 4, "role": "swift",
                 "capabilities": ["deterministic_session", "experiment_step", "lab_v4_envelope",
                                  "world_render_snapshot", "ray_pick", "player_input"],
                 "supported_quantum_ticks": [20]})
    client.send({"type": "session_control", "protocol_version": 4, "session_id": "v64probe", "epoch": 1,
                 "seq": 1, "sim_tick": 0, "action": "begin", "mode": "interactive"})
    client.pump(lambda m: m.get("type") == "session_state")

    flush_z = 0.5 * 40 * math.sin(math.radians(15)) - 0.5 * math.cos(math.radians(15))
    ack = command("spawn_ramp", target="probe_ramp", x=60, y=60, z=flush_z, size_mm=[40, 20, 1], pitch_deg=15)
    r = obj("probe_ramp")
    check("spawn_ramp applied with tilt and terrain flags",
          ack["ok"] and ack.get("status") == "applied" and ack.get("applied_tick") is not None
          and r is not None and r["pitch_deg"] == 15 and r["fixed_terrain"] and r["fly_leg_contact"],
          f"ack status={ack.get('status')} tick={ack.get('applied_tick')}")
    check("low edge on the lawn", abs(anchor(r)[2]) < 1e-9, f"anchor z={anchor(r)[2]:.2e}")

    client.send({"type": "world_render_request", "protocol_version": 4, "session_id": "v64probe",
                 "epoch": 1, "seq": 7})
    snap = client.pump(lambda m: m.get("type") == "world_render_snapshot" and m.get("request_seq") == 7)
    rendered = next(o for o in snap["objects"] if o["id"] == "probe_ramp")
    want = [0.0, -math.sin(math.radians(7.5)), 0.0, math.cos(math.radians(7.5))]
    err = max(abs(a - b) for a, b in zip(rendered["orientation_quat_xyzw"], want))
    check("render snapshot carries the tilt quaternion and pose",
          err < 1e-12 and max(abs(a - b) for a, b in zip(rendered["position_mm"], r["position_mm"])) < 1e-9
          and rendered["size_mm"] == [40.0, 20.0, 1.0], f"quat error {err:.1e}")

    before = anchor(r)
    edit = {"schema_version": 1, "property_id": "object.ramp.pitch_deg", "target_id": "probe_ramp",
            "expected_revision": r["revision"], "unit": "deg", "value": 30}
    ack = command("edit_property", edit=edit)
    r2 = obj("probe_ramp")
    check("tilt edit applied; low edge stays put",
          ack["ok"] and ack["edit"]["actual_value"] == 30 and r2["pitch_deg"] == 30
          and max(abs(a - b) for a, b in zip(anchor(r2), before)) < 1e-9 and r2["revision"] > r["revision"],
          f"revision {r['revision']}->{r2['revision']}")
    ack = command("edit_property", edit=edit)
    check("replayed stale tilt edit rejected, nothing changes",
          not ack["ok"] and ack["edit"]["status"] == "rejected_stale_revision" and obj("probe_ramp") == r2)
    ack = command("edit_property", edit={**edit, "expected_revision": r2["revision"], "value": 46})
    check("46° tilt rejected by the backend (no clamp)",
          not ack["ok"] and ack["edit"]["path"] == "edit.value" and obj("probe_ramp") == r2)

    for i in range(3):
        command("spawn_ramp", target=f"fill_{i}", x=-60, y=20 * i, z=flush_z, size_mm=[40, 20, 1], pitch_deg=15)
    before_count = len(client.state["objects"])
    ack = command("spawn_ramp", target="overflow", x=0, y=-60, z=flush_z, size_mm=[40, 20, 1], pitch_deg=15)
    check("fifth ramp rejected as rejected_capacity, world unchanged",
          not ack["ok"] and ack.get("status") == "rejected_capacity" and ack.get("error") == "no free ramp slots"
          and len(client.state["objects"]) == before_count and obj("overflow") is None
          and client.state["slot_free"]["ramp"] == 0,
          f"status={ack.get('status')} error={ack.get('error')!r}")
    ack = command("delete_object", target="fill_0")
    ack = command("spawn_ramp", target="after_delete", x=0, y=-60, z=flush_z, size_mm=[40, 20, 1], pitch_deg=15)
    check("deleting one frees a slot for the next ramp", ack["ok"] and obj("after_delete") is not None)
    client.sock.close()
    code = 1 if fails else 0
finally:
    backend.terminate()
    try:
        backend.wait(15)
    except subprocess.TimeoutExpired:
        backend.kill()
        backend.wait()
    with socket.socket() as s:
        s.bind(("127.0.0.1", port))
    print(f"{mode}: probe {'0 FAIL' if not fails else fails} backend_exit={backend.returncode} port {port} free")
sys.exit(code)
