"""Own a private backend and drive its existing deterministic TCP protocol."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

from .platform_support import backend_environment, cache_directory


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Session:
    def __init__(self, root: Path, mock=False, render=True):
        self.root = Path(root)
        self.mock = mock
        self.port = free_port()
        self.render_port = free_port() if render and not mock else None
        while self.render_port == self.port:
            self.render_port = free_port()
        self.process = None
        self.socket = None
        self.buffer = b""
        self.world, self.body, self.snapshot = {}, {}, {}
        self.events, self.acks = [], []
        self.session_id = str(uuid.uuid4())
        self.seq, self.tick = 0, 0
        self.epoch = 1
        self.paused = False
        self.log_path = cache_directory() / (self.session_id + ".log")

    def start(self, timeout=90, stop_event=None):
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log = self.log_path.open("w", encoding="utf-8")
        env = dict(
            backend_environment(),
            THONGPARI_BRIDGE_PORT=str(self.port),
            THONGPARI_PARENT_PID=str(os.getpid()),
        )
        env.pop("THONGPARI_RENDER_PORT", None)
        if self.render_port:
            env["THONGPARI_RENDER_PORT"] = str(self.render_port)
        try:
            self.process = subprocess.Popen(
                [
                    sys.executable,
                    "-u",
                    "flygym_bridge/bridge.py",
                    "--mock" if self.mock else "--flygym-headless",
                ],
                cwd=self.root,
                env=env,
                stdout=self.log,
                stderr=subprocess.STDOUT,
                creationflags=(subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0),
            )
            deadline = time.monotonic() + timeout
            while self.socket is None:
                if stop_event is not None and stop_event.is_set():
                    raise InterruptedError("backend startup cancelled")
                if self.process.poll() is not None:
                    raise RuntimeError(f"backend exited; see {self.log_path}")
                try:
                    self.socket = socket.create_connection(
                        ("127.0.0.1", self.port), timeout=0.5
                    )
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"backend startup; see {self.log_path}")
                    time.sleep(0.1)
            self.socket.settimeout(20)
            hello = self.wait_for("hello")
            required = {
                "deterministic_experiment",
                "pause_barrier",
                "epoch",
                "applied_tick",
            }
            if not required.issubset(
                hello.get("capabilities", [])
            ) or 20 not in hello.get("supported_quantum_ticks", []):
                raise RuntimeError("backend lacks deterministic 20 ms stepping")
            self.send(
                {
                    "type": "hello",
                    "protocol_version": 4,
                    "role": "desktop",
                    "capabilities": sorted(required),
                    "supported_quantum_ticks": [20],
                }
            )
            self.control("begin")
            return self
        except BaseException:
            self.close()
            raise

    def next_seq(self):
        self.seq += 1
        return self.seq

    def identity(self):
        return {
            "protocol_version": 4,
            "session_id": self.session_id,
            "epoch": self.epoch,
        }

    def send(self, packet):
        self.socket.sendall(
            (json.dumps(packet, allow_nan=False, separators=(",", ":")) + "\n").encode()
        )

    def receive(self):
        while b"\n" not in self.buffer:
            data = self.socket.recv(65536)
            if not data:
                raise ConnectionError("backend disconnected")
            self.buffer += data
            if len(self.buffer) > 8 * 1024 * 1024:
                raise ValueError("backend packet exceeds size limit")
        line, self.buffer = self.buffer.split(b"\n", 1)
        packet = json.loads(line)
        if packet["type"] == "lab_state":
            self.world = packet.get("state", {})
            if packet.get("ack") is not None:
                self.acks.append(packet)
                self.acks = self.acks[-128:]
        elif packet["type"] == "body":
            self.body = packet
        elif packet["type"] == "lab_event":
            self.events.append(packet)
            self.events = self.events[-128:]
        elif packet["type"] == "world_render_snapshot" and packet.get("ok"):
            self.snapshot = packet
        return packet

    def wait_for(self, kind, seq=None, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            packet = self.receive()
            if packet.get("type") == kind and (
                seq is None or packet.get("seq", packet.get("request_seq")) == seq
            ):
                if packet.get("ok") is False:
                    raise RuntimeError(packet.get("error", "backend rejected request"))
                return packet
        raise TimeoutError(f"no {kind} reply")

    def control(self, action):
        seq = self.next_seq()
        self.send(
            {
                "type": "session_control",
                **self.identity(),
                "seq": seq,
                "sim_tick": self.tick,
                "action": action,
                "mode": "deterministic",
            }
        )
        reply = self.wait_for("session_state", seq)
        self.paused = reply["state"] == "paused"
        return reply

    def command(self, op, args):
        seq = self.next_seq()
        self.send(
            {
                "type": "lab_command",
                **self.identity(),
                "seq": seq,
                "op": op,
                "args": args,
                "requested_tick": self.tick,
            }
        )
        return seq

    def player_input(self, axes, look):
        self.send(
            {
                "type": "player_input",
                **self.identity(),
                "actor_id": "player",
                "seq": self.next_seq(),
                "requested_tick": self.tick,
                "move_axes": axes,
                "look_delta": look,
                "held_actions": [],
            }
        )

    def step(self, brain):
        if self.paused:
            raise RuntimeError("cannot step a paused session")
        seq = self.next_seq()
        self.send(
            {
                "type": "experiment_step",
                **self.identity(),
                "seq": seq,
                "sim_tick": self.tick,
                "quantum_ticks": 20,
                "brain": brain,
            }
        )
        reply = self.wait_for("experiment_step_result", seq)
        if reply["sim_tick"] != self.tick or reply["end_sim_tick"] != self.tick + 20:
            raise RuntimeError("backend violated exact 20 ms quantum")
        self.tick = reply["end_sim_tick"]
        self.body = reply["body"]
        return self.body

    def view_snapshot(self):
        seq = self.next_seq()
        self.send({"type": "world_render_request", **self.identity(), "seq": seq})
        return self.wait_for("world_render_snapshot", seq)

    def close(self):
        if self.socket is not None:
            try:
                self.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.socket.close()
            self.socket = None
        if self.process is not None and self.process.poll() is None:
            # Windows has no POSIX SIGINT for a console-less child. Closing the
            # socket releases participation first; terminate owns only this PID.
            try:
                if sys.platform == "win32":
                    self.process.terminate()
                else:
                    self.process.send_signal(signal.SIGINT)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if hasattr(self, "log"):
            self.log.close()

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.close()
