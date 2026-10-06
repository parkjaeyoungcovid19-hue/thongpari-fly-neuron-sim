"""V6.5 environment edits over a real socket. From repo root:
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/tcp_environment_probe.py {mock|real}

Starts its own backend on a free private port (never 17841), speaks the NDJSON
the Swift panel sends (edit_property with expected_revision), reads the applied
state from lab_state and the sample at the fly from body packets, and always
terminates the backend.
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
        self.body = None

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
                if msg.get("type") == "body":
                    self.body = msg
                if until(msg):
                    return msg
            self.buf += self.sock.recv(65536)
        raise TimeoutError("no matching packet")

    def wait_sim(self, seconds):
        start = self.pump(lambda m: m.get("type") == "body")["t"]
        return self.pump(lambda m: m.get("type") == "body" and m["t"] - start >= seconds, timeout=120)


seq = 100


def command(action, **fields):
    global seq
    seq += 1
    client.send({"type": "lab_command", "id": seq, "action": action, "protocol_version": 4,
                 "session_id": "v65probe", "epoch": 1, "requested_tick": 0, **fields})
    return client.pump(lambda m: m.get("type") == "lab_state" and m.get("ack") == seq)


UNITS = {"temperature.celsius": "degC", "wind.strength": "normalized", "wind.direction_deg": "deg",
         "eyes.left_mask": "normalized"}


def edit(prop, value, revision=None):
    return command("edit_property", edit={
        "schema_version": 1, "property_id": prop, "target_id": None,
        "expected_revision": client.state["environment_revision"] if revision is None else revision,
        "unit": UNITS.get(prop, "none"), "value": value})


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
    client.send({"type": "session_control", "protocol_version": 4, "session_id": "v65probe", "epoch": 1,
                 "seq": 1, "sim_tick": 0, "action": "begin", "mode": "interactive"})
    client.pump(lambda m: m.get("type") == "session_state")
    command("reset_world")
    s0 = client.state
    check("applied environment blocks present in lab_state",
          all(k in s0 for k in ("wind", "temperature", "eyes", "environment_revision")),
          f"revision {s0.get('environment_revision')}")

    # Temperature: strict edit, applied tick, then the stale replay changes nothing.
    rev = client.state["environment_revision"]
    ack = edit("temperature.celsius", 31.5)
    check("temperature edit applied through the real serve loop",
          applied(ack, 31.5) and client.state["temperature"]["celsius"] == 31.5
          and client.state["environment_revision"] > rev, f"tick {ack.get('applied_tick')}")
    before = dict(client.state["temperature"])
    ack = edit("temperature.celsius", 20, revision=rev)
    check("stale temperature edit rejected, value unchanged",
          not ack["ok"] and ack["edit"]["status"] == "rejected_stale_revision"
          and client.state["temperature"] == before)

    # Wind: direction while off, then strength turns on a continuous wind.
    ack = edit("wind.direction_deg", 90)
    check("wind direction edit while off keeps it off", applied(ack, 90.0)
          and client.state["wind"]["strength"] == 0 and client.state["wind"]["direction_deg"] == 90)
    ack = edit("wind.physical", False)
    check("physical push switched off by edit", applied(ack, False) and not client.state["wind"]["physical_enabled"])
    ack = edit("wind.strength", 1.0)
    w = client.state["wind"]
    check("wind strength edit starts a continuous wind",
          applied(ack, 1.0) and w["continuous"] and w["remaining_ms"] is None and w["strength"] == 1.0)
    body = client.wait_sim(0.2)
    check("body packet carries the applied wind (sample at the fly)",
          body["wind_strength"] == 1.0 and body["wind_direction_deg"] == 90.0 and body["wind_sensory"],
          f"t={body['t']:.3f}")
    # Physical effect: sensory-only wind (control) vs pushing wind toward +Y.
    y0 = client.wait_sim(0.05)["position_y_mm"]
    y_control = client.wait_sim(1.0)["position_y_mm"] - y0
    ack = edit("wind.physical", True)
    y1 = client.wait_sim(0.05)["position_y_mm"]
    y_push = client.wait_sim(1.0)["position_y_mm"] - y1
    if mode == "real":
        # V6.5 strengthened wind (60000 mm/s^2 with a 30 mm/s speed fade); the old
        # 10000 mm/s^2 law moved a standing fly only ~0.08 mm in this second.
        check("physical wind pushes the fly toward +Y by millimetres; sensory-only control does not",
              applied(ack, True) and y_push > 2.0 and abs(y_control) < 0.2,
              f"dy push {y_push:.2f} mm vs control {y_control:.2f} mm over 1 s sim")
    w = client.state["wind"]
    check("wind survives simulated time while continuous", w["strength"] == 1.0 and w["continuous"])

    # A timed puff is an action; an edit never overwrites it.
    ack = command("wind", strength=0.6, duration_ms=3000, direction_deg=0, physical=True, sensory=True,
                  continuous=False)
    puff = dict(client.state["wind"])
    ack = edit("wind.strength", 0.2)
    check("edit during a timed puff rejected as rejected_busy, puff untouched",
          not ack["ok"] and ack["edit"]["status"] == "rejected_busy"
          and client.state["wind"]["strength"] == 0.6 and not client.state["wind"]["continuous"],
          f"puff {puff['remaining_ms']} ms left")
    ack = command("stop_wind")
    ack = edit("wind.strength", 0)
    check("after stop, strength 0 edit applies and wind is off",
          applied(ack, 0.0) and client.state["wind"]["strength"] == 0 and not client.state["wind"]["continuous"])

    # Light: fractional eye cover via edit.
    ack = edit("eyes.left_mask", 0.5)
    check("left eye half covered by edit", applied(ack, 0.5) and client.state["eyes"]["left_mask"] == 0.5)
    if mode == "real":
        b0 = client.wait_sim(0.6)
        ack = edit("eyes.left_mask", 1.0)
        b1 = client.wait_sim(0.6)
        check("fully covered left eye goes dark in the rendered eye sample",
              applied(ack, 1.0) and b1["brightness_left"] < 0.02 < b0["brightness_left"]
              and b1["eye_sample_sim_tick"] > b0["eye_sample_sim_tick"],
              f"brightness L {b0['brightness_left']:.3f} -> {b1['brightness_left']:.3f}")

    # Food: variant chosen by the panel's spawn_food, sample reports odor.
    ack = command("spawn_food", target="probe_food", x=20, y=0, z=1.5, variant="cheese")
    food = next((o for o in client.state["objects"] if o["id"] == "probe_food"), None)
    body = client.wait_sim(0.1)
    check("spawn_food keeps the chosen variant; odor sampled at the fly",
          ack["ok"] and food is not None and food.get("food_variant") == "cheese"
          and body["nearest_food_distance_mm"] is not None and body["odor_left"] + body["odor_right"] > 0,
          f"nearest {body['nearest_food_distance_mm']}")
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
