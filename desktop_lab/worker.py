"""Qt worker: all brain calculation and protocol I/O stay off the UI thread."""

from __future__ import annotations

import csv
import json
import math
import queue
import socket
import struct
import threading
import time

from PySide6.QtCore import QThread, Signal
from PySide6.QtGui import QImage

from .brain import GROUP_NAMES, Brain, Connectome
from .session import Session


class FrameReader(threading.Thread):
    def __init__(self, port, emit, stop):
        super().__init__(daemon=True, name="desktop-mujoco-frame")
        self.port, self.emit, self.stop = port, emit, stop
        self.socket = None
        self.lock = threading.Lock()
        self.camera = {
            "type": "view",
            "width": 800,
            "height": 600,
            "position_mm": [35, -45, 32],
            "forward": [-0.55, 0.7, -0.45],
            "distance_mm": 60,
            "fovy_deg": 45,
            "anchor": "fly",
            "offset_mm": [35, -45, 32],
        }
        self.error = None

    def set_camera(self, camera):
        with self.lock:
            self.camera = camera
            if self.socket:
                try:
                    self.socket.sendall((json.dumps(camera) + "\n").encode())
                except OSError:
                    pass

    def exact(self, length):
        parts = bytearray()
        while len(parts) < length and not self.stop.is_set():
            try:
                data = self.socket.recv(length - len(parts))
            except TimeoutError:
                continue
            if not data:
                raise ConnectionError("render stream disconnected")
            parts.extend(data)
        if len(parts) != length:
            raise ConnectionError("render stopped")
        return bytes(parts)

    def run(self):
        try:
            self.socket = socket.create_connection(("127.0.0.1", self.port), timeout=3)
            self.socket.settimeout(0.5)
            self.set_camera(self.camera)
            while not self.stop.is_set():
                magic, width, height, _seq, length = struct.unpack(
                    "<4sIIQI", self.exact(24)
                )
                if (
                    magic != b"MJF1"
                    or not (64 <= width <= 1200 and 64 <= height <= 1200)
                    or length != width * height * 3
                ):
                    raise ValueError("invalid MuJoCo frame header")
                rgb = self.exact(length)
                self.emit(
                    QImage(
                        rgb, width, height, width * 3, QImage.Format.Format_RGB888
                    ).copy()
                )
        except Exception as exc:
            if not self.stop.is_set():
                self.error = str(exc)
        finally:
            if self.socket:
                self.socket.close()


class LabWorker(QThread):
    telemetry = Signal(dict)
    frame = Signal(QImage)
    status = Signal(str)
    failure = Signal(str)
    acknowledged = Signal(dict)
    ready = Signal()
    picked = Signal(str)

    def __init__(self, root, mock=False, seed=0x5EED1F1F):
        super().__init__()
        self.root, self.mock, self.seed = root, mock, seed
        self.commands = queue.Queue(maxsize=128)
        self.stopping = threading.Event()
        self.input_lock = threading.Lock()
        self.axes, self.look = [0.0, 0.0], [0.0, 0.0]
        self.participating = False
        self.reader = None
        self.record_file = None
        self.record_writer = None
        self.initialized = False

    def submit(self, action, **args):
        try:
            self.commands.put_nowait((action, args))
        except queue.Full:
            self.failure.emit("Command queue is full / 명령 대기열이 가득 찼습니다")

    def input(self, axes=None, look=None):
        with self.input_lock:
            if axes is not None:
                self.axes = list(axes)
            if look is not None:
                self.look = [
                    max(-math.pi / 4, min(math.pi / 4, a + b))
                    for a, b in zip(self.look, look)
                ]

    def stop(self):
        self.stopping.set()

    def record(self, packet):
        if self.record_writer:
            self.record_writer.writerow(
                [
                    self.session.tick,
                    packet.get("type", "telemetry"),
                    json.dumps(packet, allow_nan=False),
                ]
            )
            self.record_file.flush()

    def handle(self, action, args):
        if action == "pause":
            self.session.control("pause" if args["paused"] else "resume")
            self.input([0.0, 0.0], [0.0, 0.0])
        elif action == "stimulate":
            self.brain.stimulate(**args)
            self.record({"type": "direct_neural", **args})
        elif action == "stimulate_neuron":
            self.brain.stimulate_indices(
                [args["index"]], args["strength"], args["duration_ms"]
            )
            self.record({"type": "direct_neural_neuron", **args})
        elif action == "reset":
            # Begin a fresh identity/timeline, preserving world objects.
            was_paused = self.session.paused
            self.brain.reset()
            self.session.session_id = str(__import__("uuid").uuid4())
            self.session.tick = 0
            self.session.control("begin")
            if was_paused:
                self.session.control("pause")
            self.body = {}
        elif action == "command":
            self.session.command(args["op"], args.get("args", {}))
            self.record({"type": "command", **args})
        elif action == "participate":
            self.participating = args["active"]
            self.session.command("set_player_active", {"active": self.participating})
            self.input([0.0, 0.0], [0.0, 0.0])
        elif action == "record":
            if self.record_file:
                self.record_file.close()
            self.record_file = self.record_writer = None
            if args.get("path"):
                self.record_file = open(args["path"], "x", newline="", encoding="utf-8")
                self.record_writer = csv.writer(self.record_file)
                self.record_writer.writerow(["sim_tick_ms", "kind", "json"])
                self.record(
                    {
                        "type": "session",
                        "seed": int(self.seed),
                        "backend": "mock" if self.mock else "flygym",
                        "neurons": self.brain.c.n,
                        "edges": self.brain.c.e,
                        "arithmetic": "CPU float32 FMA; no Metal bit-equivalence guarantee",
                    }
                )
        elif action == "marker":
            self.record({"type": "marker", **args})
        elif action == "camera":
            if self.reader:
                self.reader.set_camera(args)
        elif action == "pick":
            snap = self.session.view_snapshot()
            seq = self.session.next_seq()
            self.session.send(
                {
                    "type": "ray_pick_request",
                    **self.session.identity(),
                    "seq": seq,
                    "source_snapshot_seq": snap["snapshot_seq"],
                    "source_world_revision": snap["world_revision"],
                    "source_sim_tick": snap["sim_tick"],
                    "ray_origin_mm": args["origin"],
                    "ray_direction": args["direction"],
                }
            )
            reply = self.session.wait_for("ray_pick_result", seq)
            if reply.get("hit") and reply.get("target_kind") == "lab_object":
                self.picked.emit(reply["target_id"])

    def run(self):
        self.session = Session(self.root, mock=self.mock)
        self.body = {}
        start = time.monotonic()
        try:
            self.status.emit("Loading full connectome / 전체 커넥톰 로딩 중…")
            self.brain = Brain(Connectome(self.root / "data"), self.seed)
            # Warm JIT without changing the visible experiment's initial state.
            self.brain.step(1)
            self.brain.reset()
            if self.stopping.is_set():
                return
            self.status.emit("Starting FlyGym backend / FlyGym 백엔드 시작 중…")
            self.session.start(stop_event=self.stopping)
            if self.session.render_port:
                self.reader = FrameReader(
                    self.session.render_port, self.frame.emit, self.stopping
                )
                self.reader.start()
            self.initialized = True
            start = time.monotonic()
            self.ready.emit()
            last_emit, last_view = 0.0, 0.0
            while not self.stopping.is_set():
                while not self.commands.empty():
                    action, args = self.commands.get_nowait()
                    try:
                        self.handle(action, args)
                    except (ValueError, OSError, RuntimeError) as exc:
                        self.failure.emit(str(exc))
                if not self.session.paused:
                    now = time.monotonic()
                    if self.participating:
                        with self.input_lock:
                            axes, look = self.axes[:], self.look[:]
                            self.look = [0.0, 0.0]
                        self.session.player_input(axes, look)
                    packet = self.brain.step(20, self.body, self.session.world)
                    temp = self.session.world.get("temperature", {})
                    if temp.get("mode") == "modeled_physiology":
                        packet["tempo"] = max(
                            0.55, min(1.45, 1 + (temp.get("celsius", 25) - 25) * 0.03)
                        )
                    self.body = self.session.step(packet)
                    self.record(
                        {
                            "type": "telemetry",
                            "brain": packet,
                            "body": self.body,
                            "rates_hz": dict(
                                zip(GROUP_NAMES, self.brain.rates.tolist())
                            ),
                        }
                    )
                    for ack in self.session.acks:
                        self.acknowledged.emit(ack)
                        self.record(ack)
                    self.session.acks.clear()
                    for event in self.session.events:
                        self.record(event)
                    self.session.events.clear()
                    # Pace by actual elapsed wall time; never skip neural ticks.
                    self.stopping.wait(max(0, 0.020 - (time.monotonic() - now)))
                else:
                    self.stopping.wait(0.02)
                now = time.monotonic()
                if now - last_view >= 0.2:
                    self.session.view_snapshot()
                    last_view = now
                if now - last_emit >= 0.1:
                    self.telemetry.emit(
                        {
                            "tick": self.session.tick,
                            "body": self.body,
                            "world": self.session.world,
                            "snapshot": self.session.snapshot,
                            "rates": self.brain.rates.tolist(),
                            "paused": self.session.paused,
                            "recording": self.record_file is not None,
                            "ratio": self.session.tick / 1000 / max(0.001, now - start),
                            "spikes": self.brain.spikes.tolist(),
                            "render_error": self.reader.error if self.reader else None,
                        }
                    )
                    last_emit = now
        except Exception as exc:
            self.failure.emit(f"{exc}\nBackend log: {self.session.log_path}")
        finally:
            self.stopping.set()
            self.session.close()
            if self.reader:
                self.reader.join(timeout=3)
            if self.record_file:
                self.record_file.close()
            self.status.emit("Stopped / 종료됨")
