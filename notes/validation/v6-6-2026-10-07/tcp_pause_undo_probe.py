"""V6.6 pause edit transaction and undo semantics over a real socket. From repo root:
flygym-venv/bin/python notes/validation/v6-6-2026-10-07/tcp_pause_undo_probe.py {mock|real}

Starts its own backend on a free private port (never 17841), speaks the NDJSON
the Swift app sends, and always terminates the backend. An "undo" here is what
WorldEditHistory sends: the ACK's previous_value as an edit at the current
revision. Checks:
  * paused edits apply at the frozen owner tick, tagged transaction "paused",
    with no body packet (no physics step) during the pause;
  * a stimulus queued while paused is a barrier: an edit behind it waits;
  * V6-04: temperature edit, time runs, undo restores it, ticks never go back;
  * a stale undo is rejected and changes nothing.
"""
import json
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
SESSION = "v66probe"


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""), flush=True)
    if not ok:
        fails.append(name)


class Client:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buf = b""
        self.state = None
        self.body = None
        self.bodies = 0
        self.acks = {}

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
                    if msg.get("ack") is not None:
                        self.acks.setdefault(msg["ack"], msg)
                if msg.get("type") == "body":
                    self.body = msg
                    self.bodies += 1
                if until(msg):
                    return msg
            self.sock.settimeout(max(0.01, timeout - (time.monotonic() - t0)))
            try:
                self.buf += self.sock.recv(65536)
            except socket.timeout:
                break
        raise TimeoutError("no matching packet")

    def idle(self, seconds):
        """Read everything for `seconds` of wall time."""
        try:
            self.pump(lambda m: False, timeout=seconds)
        except TimeoutError:
            pass

    def wait_sim(self, seconds):
        start = self.pump(lambda m: m.get("type") == "body")["t"]
        return self.pump(lambda m: m.get("type") == "body" and m["t"] - start >= seconds, timeout=120)


seq = 100
control_seq = 1


def send_command(action, **fields):
    global seq
    seq += 1
    client.send({"type": "lab_command", "id": seq, "action": action, "protocol_version": 4,
                 "session_id": SESSION, "epoch": 1, "requested_tick": 0, **fields})
    return seq


def command(action, **fields):
    sent = send_command(action, **fields)
    return client.pump(lambda m: m.get("type") == "lab_state" and m.get("ack") == sent)


def session(action):
    global control_seq
    control_seq += 1
    client.send({"type": "session_control", "protocol_version": 4, "session_id": SESSION, "epoch": 1,
                 "seq": control_seq, "sim_tick": 0, "action": action})
    return client.pump(lambda m: m.get("type") == "session_state" and m.get("seq") == control_seq)


UNITS = {"temperature.celsius": "degC", "object.box.position_mm": "mm", "object.yaw_deg": "deg"}


def edit_fields(prop, value, revision, target=None):
    return {"edit": {"schema_version": 1, "property_id": prop, "target_id": target,
                     "expected_revision": revision, "unit": UNITS[prop], "value": value}}


def box():
    return next(o for o in client.state["objects"] if o["id"] == "ubox")


def applied(ack, value):
    e = ack.get("edit") or {}
    return (ack["ok"] and ack.get("status") == "applied" and ack.get("applied_tick") is not None
            and e.get("status") == "applied" and e.get("actual_value") == value)


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
    time.sleep(0.5)
    client = Client()
    client.send({"type": "hello", "protocol_version": 4, "role": "swift",
                 "capabilities": ["deterministic_session", "experiment_step", "lab_v4_envelope",
                                  "world_render_snapshot", "ray_pick", "player_input"],
                 "supported_quantum_ticks": [20]})
    client.send({"type": "session_control", "protocol_version": 4, "session_id": SESSION, "epoch": 1,
                 "seq": 1, "sim_tick": 0, "action": "begin", "mode": "interactive"})
    client.pump(lambda m: m.get("type") == "session_state")
    command("reset_world")
    ack = command("spawn_box", target="ubox", x=60, y=30, z=5, size=8)
    check("box spawned while running", ack["ok"] and box()["position_mm"] == [60.0, 30.0, 5.0])
    client.wait_sim(0.2)

    # --- Pause transaction -------------------------------------------------
    paused = session("pause")
    check("pause acknowledged", paused.get("state") == "paused")
    client.idle(0.3)
    frozen_t = client.body["t"]
    bodies = client.bodies
    rev = box()["revision"]
    ack = command("edit_property", **edit_fields("object.box.position_mm", [75, -10, 5], rev, "ubox"))
    e = ack.get("edit") or {}
    check("paused edit applies and is tagged as a pause transaction",
          applied(ack, [75.0, -10.0, 5.0]) and e.get("transaction") == "paused"
          and e.get("previous_value") == [60.0, 30.0, 5.0], json.dumps(e))
    check("paused edit ACK carries the frozen owner tick",
          ack["applied_tick"] == round(frozen_t * 1000), f"tick {ack['applied_tick']} vs body t {frozen_t}")
    check("owner state shows the edit while paused", box()["position_mm"] == [75.0, -10.0, 5.0])
    # Undo while paused: previous_value back at the new revision.
    undo = command("edit_property", **edit_fields("object.box.position_mm", e["previous_value"], box()["revision"], "ubox"))
    check("paused undo restores the position at the same frozen tick",
          applied(undo, [60.0, 30.0, 5.0]) and undo["applied_tick"] == ack["applied_tick"]
          and (undo.get("edit") or {}).get("transaction") == "paused")
    # A stimulus queued while paused is a barrier for a later edit.
    touch = send_command("touch", target="thorax", strength=0.4, duration_ms=20)
    temp_rev = client.state["environment_revision"]
    behind = send_command("edit_property", **edit_fields("temperature.celsius", 30.0, temp_rev))
    client.idle(1.0)
    check("no physics step while paused", client.bodies == bodies, f"{client.bodies - bodies} body packets")
    check("stimulus and the edit behind it wait for resume",
          touch not in client.acks and behind not in client.acks and client.state["temperature"]["celsius"] == 25.0)

    # --- Resume: barrier order -------------------------------------------
    session("resume")
    client.pump(lambda m: m.get("type") == "lab_state" and m.get("ack") == behind, timeout=10)
    t_ack, b_ack = client.acks.get(touch), client.acks[behind]
    check("after resume the stimulus applies first, then the edit (no pause tag)",
          t_ack is not None and t_ack["ok"] and applied(b_ack, 30.0)
          and "transaction" not in (b_ack.get("edit") or {})
          and t_ack["applied_tick"] <= b_ack["applied_tick"], f"touch {t_ack and t_ack['applied_tick']} edit {b_ack['applied_tick']}")
    check("body steps again after resume", client.wait_sim(0.1)["t"] > frozen_t)

    # --- V6-04: temperature undo while running ------------------------------
    fwd = command("edit_property", **edit_fields("temperature.celsius", 33.0, client.state["environment_revision"]))
    prev = (fwd.get("edit") or {}).get("previous_value")
    check("forward temperature edit reports the value it replaced", applied(fwd, 33.0) and prev == 30.0)
    mid = client.wait_sim(0.3)
    check("temperature holds while time runs", client.state["temperature"]["celsius"] == 33.0)
    back = command("edit_property", **edit_fields("temperature.celsius", prev, client.state["environment_revision"]))
    after = client.wait_sim(0.1)
    check("V6-04 undo restores temperature; ticks only move forward",
          applied(back, 30.0) and client.state["temperature"]["celsius"] == 30.0
          and back["applied_tick"] > fwd["applied_tick"] and after["t"] > mid["t"] >= fwd["applied_tick"] / 1000,
          f"fwd {fwd['applied_tick']} undo {back['applied_tick']} body t {mid['t']:.3f}->{after['t']:.3f}")

    # --- Stale undo is rejected, nothing changes ---------------------------
    stale_rev = client.state["environment_revision"]
    command("edit_property", **edit_fields("temperature.celsius", 28.0, stale_rev))
    stale = command("edit_property", **edit_fields("temperature.celsius", 30.0, stale_rev))
    check("undo built on an old revision is rejected and changes nothing",
          not stale["ok"] and (stale.get("edit") or {}).get("status") == "rejected_stale_revision"
          and client.state["temperature"]["celsius"] == 28.0)
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
