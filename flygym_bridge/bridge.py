"""bridge.py - TCP server (Swift is the client). Modes:
  python bridge.py --mock    kinematic body, no MuJoCo, for loop tests
  python bridge.py --flygym  real FlyGym 2.x NeuroMechFly body
"""
from __future__ import annotations
import argparse
import math
import socket
import sys
import threading
import time
import os
from collections import OrderedDict, deque
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from protocol import (
    decode_line, encode, BrainPacket, BodyPacket, LabCommand, LabStatePacket, LabEventPacket,
    LabCommandQueue, HelloPacket, SessionControlPacket, SessionStatePacket,
    ExperimentStepPacket, ExperimentStepResultPacket,
    WorldRenderRequestPacket, WorldRenderSnapshotPacket,
    RayPickRequestPacket, RayPickResultPacket,
    V4_EXPERIMENT_QUANTUM_TICKS, V4_PROTOCOL_VERSION,
)
from neural_decoder import decode, LocomotorCommand

HOST = "127.0.0.1"
PORT = 17841

class Bridge:
    def __init__(self, mode="mock", config=None, show_viewer=False):
        self.mode = mode
        if mode == "flygym":
            from fly_body import RealFlyBody
            self.body = RealFlyBody(config=config, show_viewer=show_viewer)
        else:
            from fly_body import MockBody
            self.body = MockBody()
        self.latest_brain = BrainPacket()
        self.lock = threading.Lock()
        self.lab_commands = LabCommandQueue()
        self.pending_lab_responses = deque(maxlen=128)
        self.pending_session_controls = deque()
        self.pending_experiment_steps = deque()
        self.pending_view_queries = deque()
        self.session_control_cap = 32
        self.experiment_step_cap = 1
        self.view_query_cap = 64
        self.client_hello = None
        self.session_id = ""
        self.session_epoch = 0
        self.session_tick = 0
        self.session_mode = "interactive"
        self.session_paused = False
        self.last_step_seq = -1
        self.recent_step_results = OrderedDict()
        self.recent_command_results = OrderedDict()
        self.recent_view_results = OrderedDict()
        self.snapshot_sources = OrderedDict()
        self.deferred_lab_commands = []
        self.recent_result_cap = 128
        self.snapshot_seq = 0
        self.brain_count = 0
        self.body_count = 0
        self.lab_count = 0
        self.lab_applied = 0
        self.lab_rejected = 0
        self.malformed = 0
        self.running = False
        self.last_cmd = LocomotorCommand()
        self.last_brain_mono = time.monotonic()
        self.last_behavior_log = 0.0
        self.last_lab_action = ""
        self.smoke_log = os.environ.get("SILICONFLY_SMOKE_LOG") == "1"

    def handle_line(self, line: bytes):
        pkt = decode_line(line)
        if pkt is None:
            self.malformed += 1
            return
        if isinstance(pkt, BrainPacket):
            with self.lock:
                self.latest_brain = pkt
                self.brain_count += 1
                self.last_cmd = decode(pkt)
                self.last_brain_mono = time.monotonic()
        elif isinstance(pkt, HelloPacket):
            with self.lock:
                self.client_hello = pkt
        elif isinstance(pkt, SessionControlPacket):
            with self.lock:
                if len(self.pending_session_controls) >= self.session_control_cap:
                    response = self._session_state_packet(
                        pkt, ok=False, state="error", error="session control queue full")
                    self.pending_lab_responses.append(response)
                else:
                    self.pending_session_controls.append(pkt)
        elif isinstance(pkt, ExperimentStepPacket):
            with self.lock:
                if len(self.pending_experiment_steps) >= self.experiment_step_cap:
                    self.pending_lab_responses.append(ExperimentStepResultPacket(
                        session_id=pkt.session_id, epoch=pkt.epoch, seq=pkt.seq,
                        sim_tick=pkt.sim_tick, end_sim_tick=pkt.sim_tick,
                        ok=False, error="experiment step queue full"))
                else:
                    self.pending_experiment_steps.append(pkt)
        elif isinstance(pkt, (WorldRenderRequestPacket, RayPickRequestPacket)):
            with self.lock:
                if len(self.pending_view_queries) >= self.view_query_cap:
                    response = self._view_query_error(
                        pkt, "view query queue full",
                        tick=(self.session_tick if self.session_mode == "deterministic" else 0),
                        revision=0)
                    self.pending_lab_responses.append(response)
                else:
                    self.pending_view_queries.append(pkt)
        elif isinstance(pkt, LabCommand):
            self.lab_count += 1
            if not self.lab_commands.push(pkt):
                self.lab_rejected += 1
                self._queue_lab_response(LabStatePacket(
                    ack=pkt.seq, ok=False, error="lab command queue full",
                    state={"last_action": pkt.op}, status="queue_full"))

    def _body_physics_timestep(self):
        try:
            dt = float(getattr(self.body, "physics_timestep_s"))
        except (AttributeError, TypeError, ValueError, OverflowError):
            return None
        return dt if math.isfinite(dt) and dt > 0.0 else None

    def _exact_substeps_for_ticks(self, ticks):
        dt = self._body_physics_timestep()
        if dt is None:
            return None
        duration = int(ticks) / 1000.0
        raw = duration / dt
        n = int(round(raw))
        if n <= 0 or abs(n * dt - duration) > max(1e-12, dt * 1e-9):
            return None
        max_steps = getattr(self.body, "max_physics_substeps", None)
        if max_steps is not None and n > int(max_steps):
            return None
        return n

    def _hello_packet(self):
        quantum_ok = self._exact_substeps_for_ticks(V4_EXPERIMENT_QUANTUM_TICKS) is not None
        return HelloPacket(
            role="python",
            physics_timestep_s=self._body_physics_timestep(),
            supported_quantum_ticks=([V4_EXPERIMENT_QUANTUM_TICKS] if quantum_ok else []),
        )

    def _session_state_packet(self, request=None, *, ok=True, state=None, error=None):
        return SessionStatePacket(
            session_id=(request.session_id if request is not None else self.session_id),
            epoch=(request.epoch if request is not None else max(1, self.session_epoch)),
            seq=(request.seq if request is not None else 0),
            sim_tick=self.session_tick,
            mode=self.session_mode,
            state=state or ("paused" if self.session_paused else "running"),
            ok=ok, error=error,
        )

    def _remember(self, cache, key, value):
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > self.recent_result_cap:
            cache.popitem(last=False)

    def _queue_lab_response(self, packet):
        with self.lock:
            self.pending_lab_responses.append(packet)

    def _drain_lab_responses(self):
        with self.lock:
            out = list(self.pending_lab_responses)
            self.pending_lab_responses.clear()
        return out

    def _brain_snapshot(self, now_mono=None):
        """Return the current decoded command, tempo and monotonic packet age."""
        if now_mono is None:
            now_mono = time.monotonic()
        with self.lock:
            cmd = self.last_cmd
            tempo = self.latest_brain.tempo
            age_s = max(0.0, float(now_mono) - self.last_brain_mono)
        stale = age_s > 1.0
        if stale:
            return LocomotorCommand(), 1.0, age_s, True
        return cmd, tempo, age_s, False

    def _current_owner_tick(self):
        if self.session_mode == "deterministic" and self.session_id:
            return int(self.session_tick)
        try:
            body_t = float(getattr(self.body, "t", 0.0))
        except (TypeError, ValueError, OverflowError):
            body_t = 0.0
        if not math.isfinite(body_t) or body_t < 0.0:
            body_t = 0.0
        return int(round(body_t * 1000.0))

    def _world_revision(self):
        world = getattr(self.body, "lab_world", None)
        try:
            revision = int(getattr(world, "revision", 0))
        except (TypeError, ValueError, OverflowError):
            revision = 0
        return max(0, revision)

    def _world_structure_revision(self):
        world = getattr(self.body, "lab_world", None)
        try:
            revision = int(getattr(world, "structure_revision", 0))
        except (TypeError, ValueError, OverflowError):
            revision = 0
        return max(0, revision)

    def _view_query_error(self, request, message, *, tick=None, revision=None):
        if tick is None:
            tick = self._current_owner_tick()
        if revision is None:
            revision = self._world_revision()
        if isinstance(request, WorldRenderRequestPacket):
            return WorldRenderSnapshotPacket(
                session_id=request.session_id, epoch=request.epoch,
                request_seq=request.seq, sim_tick=tick,
                ok=False, error=str(message)[:512])
        return RayPickResultPacket(
            session_id=request.session_id, epoch=request.epoch,
            seq=request.seq, sim_tick=tick, world_revision=revision,
            source_snapshot_seq=request.source_snapshot_seq,
            source_world_revision=request.source_world_revision,
            source_sim_tick=request.source_sim_tick,
            ok=False, hit=False, error=str(message)[:512])

    def _validate_view_query_session(self, request):
        if request.protocol_version < V4_PROTOCOL_VERSION:
            return "unsupported protocol version"
        if self.session_id:
            if request.session_id != self.session_id:
                return "wrong session"
            if request.epoch != self.session_epoch:
                return "wrong epoch"
        elif request.session_id != "" or request.epoch != 0:
            return "session not active"
        return None

    def _pop_view_queries(self):
        with self.lock:
            out = list(self.pending_view_queries)
            self.pending_view_queries.clear()
        return out

    def _validate_ray_source(self, request):
        """Validate the visible snapshot reference without pinning interactive time."""
        if request.source_snapshot_seq > self.snapshot_seq:
            return "unknown source snapshot"
        source = self.snapshot_sources.get(request.source_snapshot_seq)
        if source is None:
            return "unknown source snapshot"
        if source["session_id"] != request.session_id or source["epoch"] != request.epoch:
            return "unknown source snapshot"
        if (source["world_revision"] != request.source_world_revision or
                source["sim_tick"] != request.source_sim_tick):
            return "source snapshot metadata mismatch"
        if source["structure_revision"] != self._world_structure_revision():
            return "stale source world revision"
        # Deliberately do not compare source_sim_tick to the current owner tick.
        # In interactive mode the body and movable object poses may advance after
        # the frame was displayed; the authoritative ray is still evaluated
        # against current owner state. Structural scene changes still fail closed.
        return None

    def _reset_view_transport_state_locked(self):
        """Drop only connection-local V5 query identity/provenance/queued replies."""
        self.pending_view_queries.clear()
        self.recent_view_results.clear()
        self.snapshot_sources.clear()
        retained = [
            packet for packet in self.pending_lab_responses
            if not isinstance(packet, (WorldRenderSnapshotPacket, RayPickResultPacket))
        ]
        self.pending_lab_responses.clear()
        self.pending_lab_responses.extend(retained)

    def _process_view_queries(self):
        """Serve read-only V5 queries on the simulation-owner thread."""
        for request in self._pop_view_queries():
            kind = "snapshot" if isinstance(request, WorldRenderRequestPacket) else "ray"
            key = (kind, request.session_id, request.epoch, request.seq)
            cached = self.recent_view_results.get(key)
            if cached is not None:
                self._queue_lab_response(cached)
                continue
            error = self._validate_view_query_session(request)
            if error is not None:
                response = self._view_query_error(request, error)
                self._remember(self.recent_view_results, key, response)
                self._queue_lab_response(response)
                continue
            try:
                if isinstance(request, WorldRenderRequestPacket):
                    state_fn = getattr(self.body, "world_render_state", None)
                    if state_fn is None:
                        raise RuntimeError("backend has no world render state")
                    state = state_fn()
                    self.snapshot_seq += 1
                    response = WorldRenderSnapshotPacket(
                        session_id=request.session_id, epoch=request.epoch,
                        request_seq=request.seq, sim_tick=self._current_owner_tick(),
                        ok=True, snapshot_seq=self.snapshot_seq,
                        world_revision=int(state["world_revision"]),
                        fly=state["fly"], objects=state["objects"],
                        player=state.get("player"))
                    # Force strict output validation before caching/sending.
                    response = WorldRenderSnapshotPacket.from_dict(response.to_dict())
                    self._remember(self.snapshot_sources, response.snapshot_seq, {
                        "session_id": response.session_id,
                        "epoch": response.epoch,
                        "world_revision": response.world_revision,
                        "sim_tick": response.sim_tick,
                        "structure_revision": self._world_structure_revision(),
                    })
                else:
                    source_error = self._validate_ray_source(request)
                    if source_error is not None:
                        response = self._view_query_error(request, source_error)
                        self._remember(self.recent_view_results, key, response)
                        self._queue_lab_response(response)
                        continue
                    ray_fn = getattr(self.body, "ray_pick", None)
                    if ray_fn is None:
                        raise RuntimeError("backend cannot ray pick")
                    hit = ray_fn(request.ray_origin_mm, request.ray_direction)
                    response = RayPickResultPacket(
                        session_id=request.session_id, epoch=request.epoch,
                        seq=request.seq, sim_tick=self._current_owner_tick(),
                        world_revision=self._world_revision(),
                        source_snapshot_seq=request.source_snapshot_seq,
                        source_world_revision=request.source_world_revision,
                        source_sim_tick=request.source_sim_tick,
                        ok=True, hit=bool(hit.get("hit", False)),
                        target_id=hit.get("target_id"), target_kind=hit.get("target_kind"),
                        distance_mm=hit.get("distance_mm"), point_mm=hit.get("point_mm"),
                        normal_world=hit.get("normal_world"), geom_id=hit.get("geom_id"))
                    response = RayPickResultPacket.from_dict(response.to_dict())
            except Exception as exc:
                response = self._view_query_error(request, str(exc))
            self._remember(self.recent_view_results, key, response)
            self._queue_lab_response(response)

    def _lab_state(self, *, ack=None, ok=True, error=None, last_action=None,
                   applied_tick=None, applied_epoch=None, status=None):
        state_fn = getattr(self.body, "lab_state", None)
        state = state_fn() if state_fn is not None else {}
        state = dict(state or {})
        state["queue"] = self.lab_commands.stats()
        state["commands_received"] = self.lab_count
        state["commands_applied"] = self.lab_applied
        state["commands_rejected"] = self.lab_rejected
        _, _, brain_age_s, brain_stale = self._brain_snapshot()
        state["bridge_timing"] = {
            "brain_age_ms": brain_age_s * 1000.0,
            "brain_stale": brain_stale,
        }
        if last_action is not None:
            state["last_action"] = last_action
        elif self.last_lab_action:
            state["last_action"] = self.last_lab_action
        return LabStatePacket(ack=ack, ok=ok, error=error, state=state,
                              applied_tick=applied_tick, applied_epoch=applied_epoch,
                              status=status,
                              session_id=(self.session_id or None),
                              epoch=(self.session_epoch if self.session_epoch > 0 else None),
                              sim_tick=(self.session_tick if self.session_id else None))

    def _apply_lab_commands(self, *, applied_tick=None, applied_epoch=None):
        apply_fn = getattr(self.body, "apply_lab_command", None)
        if apply_fn is None:
            return
        # Limit discrete work per body tick; continuous slots are always drained
        # as latest state. Remaining discrete FIFO entries stay bounded in queue.
        commands = self.deferred_lab_commands + self.lab_commands.drain(max_discrete=32)
        self.deferred_lab_commands = []
        commands.sort(key=lambda command: command.seq)
        for command in commands:
            v4 = command.session_id is not None or command.epoch is not None or command.protocol_version is not None
            if v4 and applied_tick is not None and command.requested_tick is not None and command.requested_tick > applied_tick:
                if len(self.deferred_lab_commands) < 128:
                    self.deferred_lab_commands.append(command)
                else:
                    self.lab_rejected += 1
                    self._queue_lab_response(self._lab_state(
                        ack=command.seq, ok=False, error="future command queue full",
                        last_action=command.op, status="queue_full"))
                continue
            key = None
            if v4:
                key = (command.session_id or "", int(command.epoch or 0), int(command.seq))
                cached = self.recent_command_results.get(key)
                if cached is not None:
                    self._queue_lab_response(cached)
                    continue
                if command.protocol_version is not None and command.protocol_version < V4_PROTOCOL_VERSION:
                    response = self._lab_state(
                        ack=command.seq, ok=False, error="unsupported protocol version",
                        last_action=command.op, status="rejected_protocol")
                    self.lab_rejected += 1
                    self._remember(self.recent_command_results, key, response)
                    self._queue_lab_response(response)
                    continue
                if not self.session_id or command.session_id != self.session_id:
                    response = self._lab_state(
                        ack=command.seq, ok=False, error="wrong session",
                        last_action=command.op, status="rejected_session")
                    self.lab_rejected += 1
                    self._remember(self.recent_command_results, key, response)
                    self._queue_lab_response(response)
                    continue
                if command.epoch != self.session_epoch:
                    response = self._lab_state(
                        ack=command.seq, ok=False, error="wrong epoch",
                        last_action=command.op, status="rejected_old_epoch")
                    self.lab_rejected += 1
                    self._remember(self.recent_command_results, key, response)
                    self._queue_lab_response(response)
                    continue
            try:
                apply_fn(command)
                self.lab_applied += 1
                self.last_lab_action = command.op
                response = self._lab_state(
                    ack=command.seq, ok=True, last_action=command.op,
                    applied_tick=(applied_tick if v4 else None),
                    applied_epoch=(applied_epoch if v4 else None),
                    status=("applied" if v4 else None))
                if key is not None:
                    self._remember(self.recent_command_results, key, response)
                self._queue_lab_response(response)
            except Exception as exc:
                self.lab_rejected += 1
                self.last_lab_action = command.op
                response = self._lab_state(
                    ack=command.seq, ok=False, error=str(exc)[:512],
                    last_action=command.op, status=("rejected" if v4 else None))
                if key is not None:
                    self._remember(self.recent_command_results, key, response)
                self._queue_lab_response(response)

    def _drain_session_controls(self):
        with self.lock:
            out = list(self.pending_session_controls)
            self.pending_session_controls.clear()
        return out

    def _pop_experiment_step(self):
        with self.lock:
            return self.pending_experiment_steps.popleft() if self.pending_experiment_steps else None

    def _process_session_controls(self):
        for request in self._drain_session_controls():
            if request.protocol_version < V4_PROTOCOL_VERSION:
                self._queue_lab_response(self._session_state_packet(
                    request, ok=False, state="error", error="unsupported protocol version"))
                continue
            if request.action == "begin":
                if not request.session_id:
                    self._queue_lab_response(self._session_state_packet(
                        request, ok=False, state="error", error="missing session_id"))
                    continue
                with self.lock:
                    client_hello = self.client_hello
                if request.mode == "deterministic":
                    if client_hello is None or not client_hello.supports_v4_deterministic(
                            require_physics_timestep=False):
                        self._queue_lab_response(self._session_state_packet(
                            request, ok=False, state="error",
                            error="deterministic capability not negotiated"))
                        continue
                    if self._exact_substeps_for_ticks(V4_EXPERIMENT_QUANTUM_TICKS) is None:
                        self._queue_lab_response(self._session_state_packet(
                            request, ok=False, state="error",
                            error="20 ms quantum is not exact on this backend"))
                        continue
                    # A new deterministic session owns a fresh body timeline.
                    # Reset body/controller time to tick zero while preserving
                    # the current LabWorld contents; the new session id means
                    # this is not an epoch increment inside an existing run.
                    reset_body = getattr(self.body, "reset_body", None)
                    if reset_body is None:
                        self._queue_lab_response(self._session_state_packet(
                            request, ok=False, state="error",
                            error="backend cannot reset body for deterministic session"))
                        continue
                    reset_body()
                    body_tick = int(round(float(getattr(self.body, "t", 0.0)) * 1000.0))
                    if abs(body_tick - request.sim_tick) > 0:
                        self._queue_lab_response(self._session_state_packet(
                            request, ok=False, state="error",
                            error=f"body tick {body_tick} does not match requested tick {request.sim_tick}"))
                        continue
                self.session_id = request.session_id
                self.session_epoch = request.epoch
                self.session_tick = request.sim_tick
                self.session_mode = request.mode
                self.session_paused = False
                self.last_step_seq = -1
                self.recent_step_results.clear()
                self.recent_command_results.clear()
                self.recent_view_results.clear()
                self.snapshot_sources.clear()
                self.deferred_lab_commands = []
                self._queue_lab_response(self._session_state_packet(request, state="running"))
                continue

            if request.session_id != self.session_id:
                self._queue_lab_response(self._session_state_packet(
                    request, ok=False, state="error", error="wrong session"))
                continue
            if request.action == "reset":
                if request.epoch != self.session_epoch + 1:
                    self._queue_lab_response(self._session_state_packet(
                        request, ok=False, state="error",
                        error=f"reset epoch {request.epoch} must follow {self.session_epoch}"))
                    continue
                if self.session_mode == "deterministic" and not self.session_paused:
                    self._queue_lab_response(self._session_state_packet(
                        request, ok=False, state="error",
                        error="deterministic reset requires paused barrier"))
                    continue
                scopes = {str(v).lower() for v in request.reset_scope}
                try:
                    if "body" in scopes:
                        reset_body = getattr(self.body, "reset_body", None)
                        if reset_body is None:
                            raise RuntimeError("backend cannot reset body")
                        reset_body()
                    if "world" in scopes:
                        world = getattr(self.body, "lab_world", None)
                        if world is None:
                            raise RuntimeError("backend has no lab world")
                        world.reset()
                except Exception as exc:
                    self._queue_lab_response(self._session_state_packet(
                        request, ok=False, state="error",
                        error=f"reset failed: {str(exc)[:400]}"))
                    continue
                self.session_epoch = request.epoch
                self.session_tick = request.sim_tick
                self.last_step_seq = -1
                self.recent_step_results.clear()
                self.recent_command_results.clear()
                self.recent_view_results.clear()
                self.snapshot_sources.clear()
                self.deferred_lab_commands = []
                with self.lock:
                    self.pending_experiment_steps.clear()
                # A reset is itself a pause-boundary transaction. It does not
                # implicitly resume; Swift resumes explicitly after both sides
                # agree on the new epoch/tick.
                self.session_paused = True
                self._queue_lab_response(self._session_state_packet(request, state="paused"))
                continue
            if request.epoch != self.session_epoch:
                self._queue_lab_response(self._session_state_packet(
                    request, ok=False, state="error", error="wrong epoch"))
                continue
            if request.action == "pause":
                self.session_paused = True
                self._queue_lab_response(self._session_state_packet(request, state="paused"))
            elif request.action == "resume":
                self.session_paused = False
                self._queue_lab_response(self._session_state_packet(request, state="running"))
            else:
                self._queue_lab_response(self._session_state_packet(
                    request, ok=False, state="error", error="unsupported session action"))

    def _process_experiment_step(self, request):
        key = (request.session_id, request.epoch, request.seq)
        cached = self.recent_step_results.get(key)
        if cached is not None:
            return cached
        def reject(message):
            result = ExperimentStepResultPacket(
                session_id=request.session_id, epoch=request.epoch, seq=request.seq,
                sim_tick=request.sim_tick, end_sim_tick=request.sim_tick,
                ok=False, error=message)
            self._remember(self.recent_step_results, key, result)
            return result
        if request.protocol_version < V4_PROTOCOL_VERSION:
            return reject("unsupported protocol version")
        if self.session_mode != "deterministic":
            return reject("deterministic session not active")
        if request.session_id != self.session_id:
            return reject("wrong session")
        if request.epoch != self.session_epoch:
            return reject("wrong epoch")
        if self.session_paused:
            return reject("session paused")
        if request.seq <= self.last_step_seq:
            return reject("out-of-order step sequence")
        if request.sim_tick != self.session_tick:
            return reject(f"wrong sim_tick {request.sim_tick}, expected {self.session_tick}")
        if request.quantum_ticks != V4_EXPERIMENT_QUANTUM_TICKS:
            return reject("unsupported experiment quantum")
        substeps = self._exact_substeps_for_ticks(request.quantum_ticks)
        if substeps is None:
            return reject("experiment quantum is not exact on backend timestep")
        self._apply_lab_commands(applied_tick=request.sim_tick, applied_epoch=request.epoch)
        cmd = decode(request.brain)
        try:
            obs = self.body.step_exact(cmd, substeps, tempo=request.brain.tempo)
            self._collect_lab_events()
        except Exception as exc:
            return reject(f"body exact step failed: {str(exc)[:400]}")
        end_tick = request.sim_tick + request.quantum_ticks
        self.session_tick = end_tick
        self.last_step_seq = request.seq
        result = ExperimentStepResultPacket(
            session_id=request.session_id, epoch=request.epoch, seq=request.seq,
            sim_tick=request.sim_tick, end_sim_tick=end_tick, ok=True, body=obs)
        self._remember(self.recent_step_results, key, result)
        return result

    def _collect_lab_events(self):
        drain_fn = getattr(self.body, "drain_lab_events", None)
        if drain_fn is None:
            return
        for item in drain_fn():
            if not isinstance(item, dict):
                continue
            data = dict(item)
            event = str(data.pop("event", "lab_event"))[:64]
            self._queue_lab_response(LabEventPacket(event=event, data=data))

    def serve_once(self, conn):
        # Receive on its own thread: a slow MuJoCo/viewer tick must never stop
        # the 50-100 Hz BrainSignals stream from reaching the bounded latest
        # packet slot.
        alive = threading.Event()
        alive.set()
        # Capability negotiation is connection-local even though a logical V4
        # session may outlive a transport reconnect. Never inherit a previous
        # client's hello or an unprocessed transport packet.
        with self.lock:
            self.client_hello = None
            self.pending_session_controls.clear()
            self.pending_experiment_steps.clear()
            self._reset_view_transport_state_locked()
        try:
            conn.sendall(encode(self._hello_packet()))
        except OSError:
            alive.clear()
            return
        # Keep receive waits well below the 15 ms feedback period. A 50 ms
        # timeout capped feedback near 40 Hz whenever the client was quiet
        # between packets; 5 ms keeps the loop in the requested 50-100 Hz
        # range without busy-spinning.
        conn.settimeout(0.005)
        def receive():
            buf = b""
            first_brain_at = None
            last_brain_at = None
            while self.running and alive.is_set():
                try:
                    chunk = conn.recv(4096)
                    if chunk == b"":
                        break
                except socket.timeout:
                    continue
                except OSError:
                    break
                buf += chunk
                if len(buf) > 65536:
                    buf = b""
                    self.malformed += 1
                    continue
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        before = self.brain_count
                        self.handle_line(line + b"\n")
                        if self.brain_count != before:
                            last_brain_at = time.monotonic()
                            if first_brain_at is None:
                                first_brain_at = last_brain_at
            if first_brain_at is not None and last_brain_at is not None:
                count = self.brain_count - brain_at_connect
                span = max(1e-6, last_brain_at - first_brain_at)
                self.last_session_brain_hz = max(0.0, count - 1) / span
            alive.clear()

        brain_at_connect = self.brain_count
        body_at_connect = self.body_count
        self.last_session_brain_hz = 0.0
        receiver = threading.Thread(target=receive, daemon=True)
        receiver.start()
        period = 1.0 / 60.0
        # Full LabWorld state is intentionally much heavier than a body packet.
        # Commands already get an immediate state ack, so a low-rate heartbeat
        # is enough for passive UI freshness without stealing closed-loop socket
        # throughput from the 60 Hz body stream.
        lab_state_period = 0.50
        last = time.monotonic()
        next_tick = last
        next_lab_state = last
        smoke_window_start = last
        smoke_body_start = self.body_count
        smoke_brain_start = self.brain_count
        smoke_last_body = None
        smoke_max_gap = 0.0
        smoke_sim_s = 0.0
        smoke_wall_s = 0.0
        while self.running and alive.is_set():
            now_mono = time.monotonic()
            # Session control always runs on the simulation-owner thread. In
            # particular, resume must remain processable while body stepping is
            # paused; pausing the receiver/owner thread itself would deadlock.
            self._process_session_controls()
            self._process_view_queries()

            if self.session_mode == "deterministic":
                step_request = None if self.session_paused else self._pop_experiment_step()
                if step_request is not None:
                    result = self._process_experiment_step(step_request)
                    self._queue_lab_response(result)
                    if result.ok:
                        self.body_count += 1
                        smoke_sim_s += float(getattr(result.body, "sim_dt", 0.0))
                try:
                    for response in self._drain_lab_responses():
                        conn.sendall(encode(response))
                    if now_mono >= next_lab_state:
                        conn.sendall(encode(self._lab_state()))
                        next_lab_state = now_mono + lab_state_period
                except OSError:
                    break
                # One request advances exactly one quantum. No wall clock is
                # accumulated and there is never more than one queued request.
                time.sleep(0.001)
                continue

            if self.session_paused:
                # Interactive pause is a real body-time barrier. Keep the owner
                # responsive to resume and status traffic, but do not apply lab
                # commands, tick LabWorld timers, render eyes, or advance MuJoCo.
                last = now_mono
                next_tick = now_mono
                try:
                    for response in self._drain_lab_responses():
                        conn.sendall(encode(response))
                    if now_mono >= next_lab_state:
                        conn.sendall(encode(self._lab_state()))
                        next_lab_state = now_mono + lab_state_period
                except OSError:
                    break
                time.sleep(0.001)
                continue

            if now_mono < next_tick:
                time.sleep(min(0.002, next_tick - now_mono))
                continue
            dt = min(0.05, max(0.005, now_mono - last))
            last = now_mono
            next_tick = max(next_tick + period, now_mono)
            cmd, tempo, _, brain_stale = self._brain_snapshot(now_mono)
            if not brain_stale and (cmd.groom_state > 0.01 or cmd.wing_state > 0.01) and now_mono - self.last_behavior_log >= 2.0:
                # The selected locomotion controller has no grooming/flight
                # action. Expose these neural readouts honestly without faking
                # unsupported joint behavior.
                print(f"bridge: unsupported-state display groom={cmd.groom_state:.2f} "
                      f"wing={cmd.wing_state:.2f}", flush=True)
                self.last_behavior_log = now_mono
            try:
                # Only this serve loop advances MuJoCo, so all LabWorld model/data
                # mutations happen here on the simulation-owner thread.
                self._apply_lab_commands()
                obs = self.body.step(cmd, dt, tempo=tempo)
                self._collect_lab_events()
            except Exception as e:
                print(f"bridge: body step failed: {e}", flush=True)
                break
            try:
                conn.sendall(encode(obs))
                self.body_count += 1
                sent_at = time.monotonic()
                if smoke_last_body is not None:
                    smoke_max_gap = max(smoke_max_gap, sent_at - smoke_last_body)
                smoke_last_body = sent_at
                smoke_sim_s += float(getattr(obs, "sim_dt", 0.0))
                smoke_wall_s += float(getattr(obs, "wall_dt", 0.0))
                for response in self._drain_lab_responses():
                    conn.sendall(encode(response))
                if now_mono >= next_lab_state:
                    conn.sendall(encode(self._lab_state()))
                    next_lab_state = now_mono + lab_state_period
            except OSError:
                break
            if self.smoke_log and now_mono - smoke_window_start >= 5.0:
                span = max(1e-6, now_mono - smoke_window_start)
                body_hz = (self.body_count - smoke_body_start) / span
                brain_hz = (self.brain_count - smoke_brain_start) / span
                ratio = smoke_sim_s / smoke_wall_s if smoke_wall_s > 0.0 else 0.0
                print(
                    f"bridge-smoke: body_hz={body_hz:.1f} brain_hz={brain_hz:.1f} "
                    f"max_body_gap_ms={smoke_max_gap * 1000.0:.1f} sim_wall={ratio:.3f}",
                    flush=True,
                )
                smoke_window_start = now_mono
                smoke_body_start = self.body_count
                smoke_brain_start = self.brain_count
                smoke_max_gap = 0.0
                smoke_sim_s = 0.0
                smoke_wall_s = 0.0
        alive.clear()
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass
        receiver.join(timeout=0.1)
        # Participation is connection-owned in V5.4. A vanished UI must not
        # leave an invisible user's collidable body behind in the fly's world.
        # If participation was active, that connection also owned the V4 session
        # which admitted its physical commands. Retire that session together with
        # the participant so a reconnect cannot silently continue the old owner
        # timeline. Passive Observe reconnects keep the existing V4 persistence.
        world = getattr(self.body, "lab_world", None)
        participant_was_active = (
            world is not None
            and getattr(getattr(world, "player", None), "active", False)
        )
        if participant_was_active:
            world.set_player_active(False)
            self.session_id = ""
            self.session_epoch = 0
            self.session_tick = 0
            self.session_mode = "interactive"
            self.session_paused = False
            self.last_step_seq = -1
            self.recent_step_results.clear()
            self.recent_command_results.clear()
            self.deferred_lab_commands = []
            self.lab_commands.drain()
            with self.lock:
                self.pending_session_controls.clear()
                self.pending_experiment_steps.clear()
                self.pending_lab_responses.clear()
                self._reset_view_transport_state_locked()
        # Connection-local counts make arrival/drop behavior visible.
        print(f"bridge: session brain={self.brain_count-brain_at_connect} "
              f"body={self.body_count-body_at_connect} "
              f"lab={self.lab_count} applied={self.lab_applied} rejected={self.lab_rejected} "
              f"brain_hz={self.last_session_brain_hz:.1f}", flush=True)

    def serve(self):
        self.running = True
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT))
        srv.listen(1)
        srv.settimeout(0.2)
        print(f"bridge listening on {HOST}:{PORT} mode={self.mode}", flush=True)
        try:
            while self.running:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                print("bridge: client connected", flush=True)
                self.serve_once(conn)
                print("bridge: client disconnected", flush=True)
        except KeyboardInterrupt:
            print("bridge: stopping", flush=True)
        finally:
            srv.close()
            close = getattr(self.body, "close", None)
            if close is not None:
                close()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mock", action="store_true")
    ap.add_argument("--flygym", action="store_true")
    ap.add_argument("--flygym-headless", action="store_true")
    args = ap.parse_args()
    if args.flygym or args.flygym_headless:
        from environment import ArenaConfig
        Bridge(mode="flygym", config=ArenaConfig(), show_viewer=args.flygym).serve()
    else:
        Bridge(mode="mock").serve()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # mjpython delivers Ctrl-C from its Cocoa trampoline differently from
        # ordinary CPython; keep interactive shutdown clean in either case.
        pass
