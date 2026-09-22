"""protocol.py - newline-delimited JSON protocol (mirror of FlyGymBridge.swift)."""
from __future__ import annotations
import json
import math
import threading
from collections import OrderedDict, deque
from dataclasses import dataclass, field

BRAIN_TYPE = "brain"
BODY_TYPE = "body"
LAB_COMMAND_TYPE = "lab_command"
LAB_STATE_TYPE = "lab_state"
LAB_EVENT_TYPE = "lab_event"
HELLO_TYPE = "hello"
SESSION_CONTROL_TYPE = "session_control"
SESSION_STATE_TYPE = "session_state"
EXPERIMENT_STEP_TYPE = "experiment_step"
EXPERIMENT_STEP_RESULT_TYPE = "experiment_step_result"
WORLD_RENDER_REQUEST_TYPE = "world_render_request"
WORLD_RENDER_SNAPSHOT_TYPE = "world_render_snapshot"
RAY_PICK_REQUEST_TYPE = "ray_pick_request"
RAY_PICK_RESULT_TYPE = "ray_pick_result"

V4_PROTOCOL_VERSION = 4
V4_EXPERIMENT_QUANTUM_TICKS = 20
V4_CAPABILITIES = {
    "deterministic_experiment",
    "pause_barrier",
    "epoch",
    "applied_tick",
}
V5_VIEW_CAPABILITIES = {
    "world_render_snapshot",
    "ray_pick",
}

MAX_DISCRETE_LAB_COMMANDS = 128
MAX_CONTINUOUS_LAB_SLOTS = 64
CONTINUOUS_LAB_OPS = {
    "move_object", "resize_object", "wind", "set_eye_state", "eye_state",
    "temperature", "set_temperature",
}

def clamp(x, lo, hi):
    try:
        v = float(x)
    except (TypeError, ValueError):
        v = 0.0
    if not math.isfinite(v):
        v = 0.0
    return max(lo, min(hi, v))


def _bounded_int(value, lo=0, hi=9_223_372_036_854_775_807, default=0):
    try:
        out = int(value)
    except (TypeError, ValueError, OverflowError):
        return int(default)
    return max(int(lo), min(int(hi), out))


def _session_id(value):
    text = str(value or "").strip()
    if len(text) > 128:
        raise ValueError("session_id too long")
    return text


def _strict_required_int(d, key, lo=0, hi=9_223_372_036_854_775_807):
    if key not in d:
        raise ValueError(f"missing required field: {key}")
    value = d[key]
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{key} must be an integer")
    if value < lo or value > hi:
        raise ValueError(f"{key} out of range")
    return int(value)


def _strict_render_session_id(d):
    """Require the field while allowing the explicit sessionless V4 value."""
    if "session_id" not in d:
        raise ValueError("missing required field: session_id")
    value = d["session_id"]
    if not isinstance(value, str):
        raise ValueError("session_id must be a string")
    text = value.strip()
    if len(text) > 128:
        raise ValueError("session_id too long")
    return text


def _strict_number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be numeric")
    out = float(value)
    if not math.isfinite(out):
        raise ValueError(f"{name} must be finite")
    return out


def _strict_vec(value, length, name):
    if not isinstance(value, (list, tuple)) or len(value) != length:
        raise ValueError(f"{name} must have length {length}")
    return [_strict_number(v, f"{name}[{i}]") for i, v in enumerate(value)]


def _strict_unit_quat_xyzw(value, name):
    quat = _strict_vec(value, 4, name)
    norm = math.sqrt(sum(v * v for v in quat))
    if norm < 1e-12 or abs(norm - 1.0) > 1e-3:
        raise ValueError(f"{name} must be normalized")
    return quat


def _strict_render_pose(value, name):
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    object_id = value.get("id")
    if not isinstance(object_id, str) or not object_id.strip() or len(object_id) > 64:
        raise ValueError(f"{name}.id is invalid")
    return {
        "id": object_id.strip(),
        "position_mm": _strict_vec(value.get("position_mm"), 3, f"{name}.position_mm"),
        "orientation_quat_xyzw": _strict_unit_quat_xyzw(
            value.get("orientation_quat_xyzw"), f"{name}.orientation_quat_xyzw"),
    }


def _strict_render_object(value, index):
    name = f"objects[{index}]"
    pose = _strict_render_pose(value, name)
    shape = value.get("shape")
    if not isinstance(shape, str) or not shape.strip() or len(shape) > 32:
        raise ValueError(f"{name}.shape is invalid")
    size = _strict_vec(value.get("size_mm"), 3, f"{name}.size_mm")
    if any(v <= 0.0 for v in size):
        raise ValueError(f"{name}.size_mm must be positive")
    revision = _strict_required_int(value, "revision", 0)
    out = {
        **pose,
        "shape": shape.strip().lower(),
        "size_mm": size,
        "revision": revision,
        "collidable": bool(value.get("collidable", True)),
    }
    classification = value.get("classification")
    if classification is not None:
        if not isinstance(classification, str) or len(classification) > 64:
            raise ValueError(f"{name}.classification is invalid")
        out["classification"] = classification
    return out

@dataclass
class BrainPacket:
    t: float = 0.0
    walk: float = 0.0
    turn: float = 0.0
    escape: bool = False
    backward: bool = False
    groom: float = 0.0
    wing: float = 0.0
    arousal: float = 0.0
    tempo: float = 1.0
    sleep: bool = False
    nervous: float = 0.0

    @staticmethod
    def from_dict(d: dict) -> "BrainPacket":
        if not isinstance(d, dict):
            raise ValueError("brain packet must be an object")
        b = BrainPacket()
        b.t = clamp(d.get("t", 0.0), 0.0, 1e12)
        b.walk = clamp(d.get("walk", 0.0), 0.0, 1.5)
        b.turn = clamp(d.get("turn", 0.0), -1.0, 1.0)
        b.escape = bool(d.get("escape", False))
        b.backward = bool(d.get("backward", False))
        b.groom = clamp(d.get("groom", 0.0), 0.0, 1.5)
        b.wing = clamp(d.get("wing", 0.0), 0.0, 1.5)
        b.arousal = clamp(d.get("arousal", 0.0), 0.0, 1.0)
        b.tempo = clamp(d.get("tempo", 1.0), 0.2, 2.0)
        b.sleep = bool(d.get("sleep", False))
        b.nervous = clamp(d.get("nervous", 0.0), 0.0, 1.0)
        return b

    def to_dict(self) -> dict:
        return {"type": BRAIN_TYPE, "t": self.t, "walk": self.walk, "turn": self.turn,
                "escape": self.escape, "backward": self.backward, "groom": self.groom,
                "wing": self.wing, "arousal": self.arousal, "tempo": self.tempo,
                "sleep": self.sleep, "nervous": self.nervous}

@dataclass
class BodyPacket:
    t: float = 0.0
    sim_dt: float = 0.0
    wall_dt: float = 0.0
    sim_wall_ratio: float = 0.0
    controller_left: float = 0.0
    controller_right: float = 0.0
    wind_strength: float = 0.0
    wind_direction_deg: float = 0.0
    wind_sensory: bool = False
    touch_strength: float = 0.0
    touch_sensory: bool = False
    vx: float = 0.0
    yaw_rate: float = 0.0
    contacts: list = field(default_factory=lambda: [0, 0, 0, 0, 0, 0])
    left_contact: float = 0.0
    right_contact: float = 0.0
    gait_phase: float | None = None
    loom_left: float = 0.0
    loom_right: float = 0.0
    brightness: float = 0.0
    brightness_left: float = 0.0
    brightness_right: float = 0.0
    occupancy_left: float = 0.0
    occupancy_right: float = 0.0
    optic_expansion_left: float = 0.0
    optic_expansion_right: float = 0.0
    eye_sample_sim_tick: int | None = None
    flash_left: float = 0.0
    flash_right: float = 0.0
    odor_left: float = 0.0
    odor_right: float = 0.0
    nearest_food_distance_mm: float | None = None
    position_x_mm: float = 0.0
    position_y_mm: float = 0.0
    heading_rad: float = 0.0
    bearing: float = 0.0

    @staticmethod
    def from_dict(d: dict) -> "BodyPacket":
        if not isinstance(d, dict):
            raise ValueError("body packet must be an object")
        p = BodyPacket()
        p.t = clamp(d.get("t", 0.0), 0.0, 1e12)
        p.sim_dt = clamp(d.get("sim_dt", 0.0), 0.0, 1.0)
        p.wall_dt = clamp(d.get("wall_dt", 0.0), 0.0, 1.0)
        p.sim_wall_ratio = clamp(d.get("sim_wall_ratio", 0.0), 0.0, 100.0)
        p.controller_left = clamp(d.get("controller_left", 0.0), -2.0, 2.0)
        p.controller_right = clamp(d.get("controller_right", 0.0), -2.0, 2.0)
        p.wind_strength = clamp(d.get("wind_strength", 0.0), 0.0, 1.0)
        p.wind_direction_deg = clamp(d.get("wind_direction_deg", 0.0), -36000.0, 36000.0) % 360.0
        p.wind_sensory = bool(d.get("wind_sensory", False))
        p.touch_strength = clamp(d.get("touch_strength", 0.0), 0.0, 1.0)
        p.touch_sensory = bool(d.get("touch_sensory", False))
        p.vx = clamp(d.get("vx", 0.0), -2.0, 2.0)
        p.yaw_rate = clamp(d.get("yaw_rate", 0.0), -20.0, 20.0)
        raw = d.get("contacts", []) or []
        cc = [clamp(v, 0.0, 1.0) for v in list(raw)[:6]]
        while len(cc) < 6:
            cc.append(0.0)
        p.contacts = cc
        p.left_contact = clamp(d.get("left_contact", 0.0), 0.0, 1.0)
        p.right_contact = clamp(d.get("right_contact", 0.0), 0.0, 1.0)
        g = d.get("gait_phase", None)
        p.gait_phase = clamp(g, 0.0, 1.0) if g is not None else None
        p.loom_left = clamp(d.get("loom_left", 0.0), 0.0, 1.0)
        p.loom_right = clamp(d.get("loom_right", 0.0), 0.0, 1.0)
        p.brightness = clamp(d.get("brightness", 0.0), 0.0, 1.0)
        p.brightness_left = clamp(d.get("brightness_left", p.brightness), 0.0, 1.0)
        p.brightness_right = clamp(d.get("brightness_right", p.brightness), 0.0, 1.0)
        p.occupancy_left = clamp(d.get("occupancy_left", 0.0), 0.0, 1.0)
        p.occupancy_right = clamp(d.get("occupancy_right", 0.0), 0.0, 1.0)
        p.optic_expansion_left = clamp(d.get("optic_expansion_left", 0.0), 0.0, 1.0)
        p.optic_expansion_right = clamp(d.get("optic_expansion_right", 0.0), 0.0, 1.0)
        if "eye_sample_sim_tick" in d and d.get("eye_sample_sim_tick") is not None:
            p.eye_sample_sim_tick = _strict_required_int(
                d, "eye_sample_sim_tick", 0, 10**15)
        else:
            p.eye_sample_sim_tick = None
        p.flash_left = clamp(d.get("flash_left", 0.0), 0.0, 1.0)
        p.flash_right = clamp(d.get("flash_right", 0.0), 0.0, 1.0)
        p.odor_left = clamp(d.get("odor_left", 0.0), 0.0, 1.0)
        p.odor_right = clamp(d.get("odor_right", 0.0), 0.0, 1.0)
        nearest_food = d.get("nearest_food_distance_mm", None)
        p.nearest_food_distance_mm = (
            clamp(nearest_food, 0.0, 1e6) if nearest_food is not None else None)
        p.position_x_mm = clamp(d.get("position_x_mm", 0.0), -1e6, 1e6)
        p.position_y_mm = clamp(d.get("position_y_mm", 0.0), -1e6, 1e6)
        p.heading_rad = clamp(d.get("heading_rad", 0.0), -math.pi, math.pi)
        p.bearing = clamp(d.get("bearing", 0.0), -1.0, 1.0)
        return p

    def to_dict(self) -> dict:
        d = {"type": BODY_TYPE, "t": self.t, "sim_dt": self.sim_dt,
             "wall_dt": self.wall_dt, "sim_wall_ratio": self.sim_wall_ratio,
             "controller_left": self.controller_left,
             "controller_right": self.controller_right,
             "wind_strength": self.wind_strength,
             "wind_direction_deg": self.wind_direction_deg,
             "wind_sensory": self.wind_sensory,
             "touch_strength": self.touch_strength,
             "touch_sensory": self.touch_sensory,
             "vx": self.vx, "yaw_rate": self.yaw_rate,
             "contacts": self.contacts, "left_contact": self.left_contact,
             "right_contact": self.right_contact, "loom_left": self.loom_left,
             "loom_right": self.loom_right, "brightness": self.brightness,
             "brightness_left": self.brightness_left,
             "brightness_right": self.brightness_right,
             "occupancy_left": self.occupancy_left,
             "occupancy_right": self.occupancy_right,
             "optic_expansion_left": self.optic_expansion_left,
             "optic_expansion_right": self.optic_expansion_right,
             "flash_left": self.flash_left, "flash_right": self.flash_right,
             "odor_left": self.odor_left, "odor_right": self.odor_right,
             "position_x_mm": self.position_x_mm, "position_y_mm": self.position_y_mm,
             "heading_rad": self.heading_rad, "bearing": self.bearing}
        if self.nearest_food_distance_mm is not None:
            d["nearest_food_distance_mm"] = self.nearest_food_distance_mm
        if self.eye_sample_sim_tick is not None:
            d["eye_sample_sim_tick"] = int(self.eye_sample_sim_tick)
        if self.gait_phase is not None:
            d["gait_phase"] = self.gait_phase
        return d


@dataclass
class HelloPacket:
    """V4 capability declaration.

    Legacy peers simply never send this packet.  The deterministic path must not
    be enabled unless all required capabilities are explicitly present.
    """
    protocol_version: int = V4_PROTOCOL_VERSION
    role: str = "python"
    capabilities: set[str] = field(
        default_factory=lambda: set(V4_CAPABILITIES | V5_VIEW_CAPABILITIES))
    physics_timestep_s: float | None = None
    supported_quantum_ticks: list[int] = field(
        default_factory=lambda: [V4_EXPERIMENT_QUANTUM_TICKS])

    @staticmethod
    def from_dict(d: dict) -> "HelloPacket":
        if not isinstance(d, dict):
            raise ValueError("hello packet must be an object")
        version = _bounded_int(d.get("protocol_version", 0), 0, 1_000_000)
        role = str(d.get("role", ""))[:32]
        raw_caps = d.get("capabilities", [])
        if isinstance(raw_caps, dict):
            caps = {str(k) for k, enabled in raw_caps.items() if bool(enabled)}
        elif isinstance(raw_caps, (list, tuple, set)):
            caps = {str(v) for v in raw_caps}
        else:
            caps = set()
        raw_dt = d.get("physics_timestep_s")
        physics_dt = None
        if raw_dt is not None:
            try:
                candidate = float(raw_dt)
            except (TypeError, ValueError, OverflowError):
                candidate = math.nan
            if math.isfinite(candidate) and candidate > 0:
                physics_dt = min(1.0, candidate)
        raw_quanta = d.get("supported_quantum_ticks", [])
        quanta = []
        if isinstance(raw_quanta, (list, tuple)):
            for value in raw_quanta[:32]:
                q = _bounded_int(value, 1, 1_000_000, default=0)
                if q > 0 and q not in quanta:
                    quanta.append(q)
        return HelloPacket(protocol_version=version, role=role,
                           capabilities=caps, physics_timestep_s=physics_dt,
                           supported_quantum_ticks=quanta)

    def supports_v4_deterministic(self, quantum_ticks=V4_EXPERIMENT_QUANTUM_TICKS,
                                  require_physics_timestep=True) -> bool:
        return (self.protocol_version >= V4_PROTOCOL_VERSION and
                V4_CAPABILITIES.issubset(self.capabilities) and
                int(quantum_ticks) in self.supported_quantum_ticks and
                (self.physics_timestep_s is not None or not require_physics_timestep))

    def to_dict(self) -> dict:
        out = {
            "type": HELLO_TYPE,
            "protocol_version": int(self.protocol_version),
            "role": self.role,
            "capabilities": sorted(self.capabilities),
            "supported_quantum_ticks": [int(v) for v in self.supported_quantum_ticks],
        }
        if self.physics_timestep_s is not None:
            out["physics_timestep_s"] = float(self.physics_timestep_s)
        return out


@dataclass
class SessionControlPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 1
    seq: int = 0
    sim_tick: int = 0
    action: str = "pause"
    mode: str = "interactive"
    reset_scope: list[str] = field(default_factory=list)

    @staticmethod
    def from_dict(d: dict) -> "SessionControlPacket":
        if not isinstance(d, dict):
            raise ValueError("session control must be an object")
        action = str(d.get("action", "")).strip().lower()
        if action not in {"pause", "resume", "reset", "begin"}:
            raise ValueError("invalid session control action")
        mode = str(d.get("mode", "interactive")).strip().lower()
        if mode not in {"interactive", "deterministic"}:
            raise ValueError("invalid session mode")
        return SessionControlPacket(
            protocol_version=_bounded_int(d.get("protocol_version", 0), 0, 1_000_000),
            session_id=_session_id(d.get("session_id", "")),
            epoch=_bounded_int(d.get("epoch", 1), 1),
            seq=_bounded_int(d.get("seq", 0)),
            sim_tick=_bounded_int(d.get("sim_tick", 0)),
            action=action,
            mode=mode,
            reset_scope=[str(v) for v in d.get("reset_scope", [])[:16]]
            if isinstance(d.get("reset_scope", []), (list, tuple)) else [],
        )

    def to_dict(self) -> dict:
        out = {"type": SESSION_CONTROL_TYPE,
                "protocol_version": self.protocol_version,
                "session_id": self.session_id, "epoch": self.epoch,
                "seq": self.seq, "sim_tick": self.sim_tick,
                "action": self.action, "mode": self.mode}
        if self.reset_scope:
            out["reset_scope"] = list(self.reset_scope)
        return out


@dataclass
class SessionStatePacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 1
    seq: int = 0
    sim_tick: int = 0
    mode: str = "interactive"
    state: str = "running"
    ok: bool = True
    error: str | None = None

    @staticmethod
    def from_dict(d: dict) -> "SessionStatePacket":
        if not isinstance(d, dict):
            raise ValueError("session state must be an object")
        mode = str(d.get("mode", "interactive")).strip().lower()
        if mode not in {"interactive", "deterministic"}:
            mode = "interactive"
        state = str(d.get("state", "running")).strip().lower()[:32]
        return SessionStatePacket(
            protocol_version=_bounded_int(d.get("protocol_version", 0), 0, 1_000_000),
            session_id=_session_id(d.get("session_id", "")),
            epoch=_bounded_int(d.get("epoch", 1), 1),
            seq=_bounded_int(d.get("seq", 0)),
            sim_tick=_bounded_int(d.get("sim_tick", 0)),
            mode=mode, state=state, ok=bool(d.get("ok", True)),
            error=None if d.get("error") is None else str(d.get("error"))[:512],
        )

    def to_dict(self) -> dict:
        out = {"type": SESSION_STATE_TYPE,
               "protocol_version": self.protocol_version,
               "session_id": self.session_id, "epoch": self.epoch,
               "seq": self.seq, "sim_tick": self.sim_tick,
               "mode": self.mode, "state": self.state, "ok": self.ok}
        if self.error is not None:
            out["error"] = self.error
        return out


@dataclass
class ExperimentStepPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 1
    seq: int = 0
    sim_tick: int = 0
    quantum_ticks: int = V4_EXPERIMENT_QUANTUM_TICKS
    brain: BrainPacket = field(default_factory=BrainPacket)

    @staticmethod
    def from_dict(d: dict) -> "ExperimentStepPacket":
        if not isinstance(d, dict):
            raise ValueError("experiment step must be an object")
        raw_brain = d.get("brain", {})
        if not isinstance(raw_brain, dict):
            raise ValueError("experiment step brain must be an object")
        brain_dict = dict(raw_brain)
        brain_dict.setdefault("type", BRAIN_TYPE)
        return ExperimentStepPacket(
            protocol_version=_bounded_int(d.get("protocol_version", 0), 0, 1_000_000),
            session_id=_session_id(d.get("session_id", "")),
            epoch=_bounded_int(d.get("epoch", 1), 1),
            seq=_bounded_int(d.get("seq", 0)),
            sim_tick=_bounded_int(d.get("sim_tick", 0)),
            quantum_ticks=_bounded_int(d.get("quantum_ticks", 0), 1, 1_000_000),
            brain=BrainPacket.from_dict(brain_dict),
        )

    def to_dict(self) -> dict:
        brain = self.brain.to_dict()
        brain.pop("type", None)
        return {"type": EXPERIMENT_STEP_TYPE,
                "protocol_version": self.protocol_version,
                "session_id": self.session_id, "epoch": self.epoch,
                "seq": self.seq, "sim_tick": self.sim_tick,
                "quantum_ticks": self.quantum_ticks, "brain": brain}


@dataclass
class ExperimentStepResultPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 1
    seq: int = 0
    sim_tick: int = 0
    end_sim_tick: int = 0
    ok: bool = True
    error: str | None = None
    body: BodyPacket = field(default_factory=BodyPacket)

    @staticmethod
    def from_dict(d: dict) -> "ExperimentStepResultPacket":
        if not isinstance(d, dict):
            raise ValueError("experiment step result must be an object")
        raw_body = d.get("body", {})
        if not isinstance(raw_body, dict):
            raise ValueError("experiment result body must be an object")
        body_dict = dict(raw_body)
        body_dict.setdefault("type", BODY_TYPE)
        return ExperimentStepResultPacket(
            protocol_version=_bounded_int(d.get("protocol_version", 0), 0, 1_000_000),
            session_id=_session_id(d.get("session_id", "")),
            epoch=_bounded_int(d.get("epoch", 1), 1),
            seq=_bounded_int(d.get("seq", 0)),
            sim_tick=_bounded_int(d.get("sim_tick", 0)),
            end_sim_tick=_bounded_int(d.get("end_sim_tick", 0)),
            ok=bool(d.get("ok", True)),
            error=None if d.get("error") is None else str(d.get("error"))[:512],
            body=BodyPacket.from_dict(body_dict),
        )

    def to_dict(self) -> dict:
        body = self.body.to_dict()
        body.pop("type", None)
        out = {"type": EXPERIMENT_STEP_RESULT_TYPE,
               "protocol_version": self.protocol_version,
               "session_id": self.session_id, "epoch": self.epoch,
               "seq": self.seq, "sim_tick": self.sim_tick,
               "end_sim_tick": self.end_sim_tick, "ok": self.ok,
               "body": body}
        if self.error is not None:
            out["error"] = self.error
        return out


@dataclass
class WorldRenderRequestPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 0
    seq: int = 0

    @staticmethod
    def from_dict(d: dict) -> "WorldRenderRequestPacket":
        if not isinstance(d, dict):
            raise ValueError("world render request must be an object")
        return WorldRenderRequestPacket(
            protocol_version=_strict_required_int(d, "protocol_version", 0, 1_000_000),
            session_id=_strict_render_session_id(d),
            epoch=_strict_required_int(d, "epoch", 0),
            seq=_strict_required_int(d, "seq", 0),
        )

    def to_dict(self) -> dict:
        return {
            "type": WORLD_RENDER_REQUEST_TYPE,
            "protocol_version": int(self.protocol_version),
            "session_id": self.session_id,
            "epoch": int(self.epoch),
            "seq": int(self.seq),
        }


@dataclass
class WorldRenderSnapshotPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 0
    request_seq: int = 0
    sim_tick: int = 0
    ok: bool = True
    error: str | None = None
    snapshot_seq: int | None = None
    world_revision: int | None = None
    fly: dict | None = None
    objects: list[dict] | None = None

    @staticmethod
    def from_dict(d: dict) -> "WorldRenderSnapshotPacket":
        if not isinstance(d, dict):
            raise ValueError("world render snapshot must be an object")
        protocol_version = _strict_required_int(d, "protocol_version", 0, 1_000_000)
        session_id = _strict_render_session_id(d)
        epoch = _strict_required_int(d, "epoch", 0)
        request_seq = _strict_required_int(d, "request_seq", 0)
        sim_tick = _strict_required_int(d, "sim_tick", 0)
        if "ok" not in d or not isinstance(d["ok"], bool):
            raise ValueError("ok must be a boolean")
        ok = d["ok"]
        error = None if d.get("error") is None else str(d.get("error"))[:512]
        if not ok:
            if not error:
                raise ValueError("failed world render snapshot requires error")
            return WorldRenderSnapshotPacket(
                protocol_version=protocol_version, session_id=session_id, epoch=epoch,
                request_seq=request_seq, sim_tick=sim_tick, ok=False, error=error)

        snapshot_seq = _strict_required_int(d, "snapshot_seq", 1)
        world_revision = _strict_required_int(d, "world_revision", 0)
        fly = _strict_render_pose(d.get("fly"), "fly")
        raw_objects = d.get("objects")
        if not isinstance(raw_objects, list):
            raise ValueError("objects must be an array")
        objects = [_strict_render_object(obj, i) for i, obj in enumerate(raw_objects)]
        if len({obj["id"] for obj in objects}) != len(objects):
            raise ValueError("objects contain duplicate ids")
        return WorldRenderSnapshotPacket(
            protocol_version=protocol_version, session_id=session_id, epoch=epoch,
            request_seq=request_seq, sim_tick=sim_tick, ok=True,
            snapshot_seq=snapshot_seq, world_revision=world_revision,
            fly=fly, objects=objects)

    def to_dict(self) -> dict:
        out = {
            "type": WORLD_RENDER_SNAPSHOT_TYPE,
            "protocol_version": int(self.protocol_version),
            "session_id": self.session_id,
            "epoch": int(self.epoch),
            "request_seq": int(self.request_seq),
            "sim_tick": int(self.sim_tick),
            "ok": bool(self.ok),
        }
        if not self.ok:
            if not self.error:
                raise ValueError("failed world render snapshot requires error")
            out["error"] = str(self.error)[:512]
            WorldRenderSnapshotPacket.from_dict(out)
            return out
        out.update(
            snapshot_seq=self.snapshot_seq,
            world_revision=self.world_revision,
            fly=self.fly,
            objects=self.objects,
        )
        # Validate every required success field before it reaches json.dumps.
        validated = WorldRenderSnapshotPacket.from_dict(out)
        out["snapshot_seq"] = validated.snapshot_seq
        out["world_revision"] = validated.world_revision
        out["fly"] = validated.fly
        out["objects"] = validated.objects
        return out


@dataclass
class RayPickRequestPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 0
    seq: int = 0
    source_snapshot_seq: int = 0
    source_world_revision: int = 0
    source_sim_tick: int = 0
    ray_origin_mm: list[float] = field(default_factory=lambda: [0.0, 0.0, 0.0])
    ray_direction: list[float] = field(default_factory=lambda: [1.0, 0.0, 0.0])

    @staticmethod
    def from_dict(d: dict) -> "RayPickRequestPacket":
        if not isinstance(d, dict):
            raise ValueError("ray pick request must be an object")
        origin = _strict_vec(d.get("ray_origin_mm"), 3, "ray_origin_mm")
        direction = _strict_vec(d.get("ray_direction"), 3, "ray_direction")
        norm = math.sqrt(sum(v * v for v in direction))
        if norm < 1e-12:
            raise ValueError("ray_direction must be non-zero")
        direction = [v / norm for v in direction]
        return RayPickRequestPacket(
            protocol_version=_strict_required_int(d, "protocol_version", 0, 1_000_000),
            session_id=_strict_render_session_id(d),
            epoch=_strict_required_int(d, "epoch", 0),
            seq=_strict_required_int(d, "seq", 0),
            source_snapshot_seq=_strict_required_int(d, "source_snapshot_seq", 1),
            source_world_revision=_strict_required_int(d, "source_world_revision", 0),
            source_sim_tick=_strict_required_int(d, "source_sim_tick", 0),
            ray_origin_mm=origin, ray_direction=direction,
        )

    def to_dict(self) -> dict:
        raw = {
            "type": RAY_PICK_REQUEST_TYPE,
            "protocol_version": int(self.protocol_version),
            "session_id": self.session_id,
            "epoch": int(self.epoch),
            "seq": int(self.seq),
            "source_snapshot_seq": int(self.source_snapshot_seq),
            "source_world_revision": int(self.source_world_revision),
            "source_sim_tick": int(self.source_sim_tick),
            "ray_origin_mm": self.ray_origin_mm,
            "ray_direction": self.ray_direction,
        }
        validated = RayPickRequestPacket.from_dict(raw)
        raw["ray_origin_mm"] = validated.ray_origin_mm
        raw["ray_direction"] = validated.ray_direction
        return raw


@dataclass
class RayPickResultPacket:
    protocol_version: int = V4_PROTOCOL_VERSION
    session_id: str = ""
    epoch: int = 0
    seq: int = 0
    sim_tick: int = 0
    world_revision: int = 0
    source_snapshot_seq: int = 0
    source_world_revision: int = 0
    source_sim_tick: int = 0
    ok: bool = True
    hit: bool = False
    error: str | None = None
    target_id: str | None = None
    target_kind: str | None = None
    distance_mm: float | None = None
    point_mm: list[float] | None = None
    normal_world: list[float] | None = None
    geom_id: int | None = None

    @staticmethod
    def from_dict(d: dict) -> "RayPickResultPacket":
        if not isinstance(d, dict):
            raise ValueError("ray pick result must be an object")
        protocol_version = _strict_required_int(d, "protocol_version", 0, 1_000_000)
        session_id = _strict_render_session_id(d)
        epoch = _strict_required_int(d, "epoch", 0)
        seq = _strict_required_int(d, "seq", 0)
        sim_tick = _strict_required_int(d, "sim_tick", 0)
        world_revision = _strict_required_int(d, "world_revision", 0)
        source_snapshot_seq = _strict_required_int(d, "source_snapshot_seq", 1)
        source_world_revision = _strict_required_int(d, "source_world_revision", 0)
        source_sim_tick = _strict_required_int(d, "source_sim_tick", 0)
        if "ok" not in d or not isinstance(d["ok"], bool):
            raise ValueError("ok must be a boolean")
        if "hit" not in d or not isinstance(d["hit"], bool):
            raise ValueError("hit must be a boolean")
        ok = d["ok"]
        hit = d["hit"]
        error = None if d.get("error") is None else str(d.get("error"))[:512]
        if not ok:
            if not error or hit:
                raise ValueError("failed ray pick requires error and hit=false")
            return RayPickResultPacket(
                protocol_version=protocol_version, session_id=session_id, epoch=epoch,
                seq=seq, sim_tick=sim_tick, world_revision=world_revision,
                source_snapshot_seq=source_snapshot_seq,
                source_world_revision=source_world_revision,
                source_sim_tick=source_sim_tick,
                ok=False, hit=False, error=error)
        if not hit:
            return RayPickResultPacket(
                protocol_version=protocol_version, session_id=session_id, epoch=epoch,
                seq=seq, sim_tick=sim_tick, world_revision=world_revision,
                source_snapshot_seq=source_snapshot_seq,
                source_world_revision=source_world_revision,
                source_sim_tick=source_sim_tick,
                ok=True, hit=False)

        target_id = d.get("target_id")
        target_kind = d.get("target_kind")
        if not isinstance(target_id, str) or not target_id.strip() or len(target_id) > 128:
            raise ValueError("target_id is invalid")
        if not isinstance(target_kind, str) or not target_kind.strip() or len(target_kind) > 32:
            raise ValueError("target_kind is invalid")
        distance = _strict_number(d.get("distance_mm"), "distance_mm")
        if distance < 0.0:
            raise ValueError("distance_mm must be non-negative")
        point = _strict_vec(d.get("point_mm"), 3, "point_mm")
        normal = _strict_vec(d.get("normal_world"), 3, "normal_world")
        normal_norm = math.sqrt(sum(v * v for v in normal))
        if normal_norm < 1e-12:
            raise ValueError("normal_world must be non-zero")
        normal = [v / normal_norm for v in normal]
        geom_id = _strict_required_int(d, "geom_id", 0, 2_147_483_647)
        return RayPickResultPacket(
            protocol_version=protocol_version, session_id=session_id, epoch=epoch,
            seq=seq, sim_tick=sim_tick, world_revision=world_revision,
            source_snapshot_seq=source_snapshot_seq,
            source_world_revision=source_world_revision,
            source_sim_tick=source_sim_tick,
            ok=True, hit=True, target_id=target_id.strip(), target_kind=target_kind.strip(),
            distance_mm=distance, point_mm=point, normal_world=normal, geom_id=geom_id)

    def to_dict(self) -> dict:
        out = {
            "type": RAY_PICK_RESULT_TYPE,
            "protocol_version": int(self.protocol_version),
            "session_id": self.session_id,
            "epoch": int(self.epoch),
            "seq": int(self.seq),
            "sim_tick": int(self.sim_tick),
            "world_revision": int(self.world_revision),
            "source_snapshot_seq": int(self.source_snapshot_seq),
            "source_world_revision": int(self.source_world_revision),
            "source_sim_tick": int(self.source_sim_tick),
            "ok": bool(self.ok),
            "hit": bool(self.hit),
        }
        if self.error is not None:
            out["error"] = str(self.error)[:512]
        if self.hit:
            out.update(
                target_id=self.target_id,
                target_kind=self.target_kind,
                distance_mm=self.distance_mm,
                point_mm=self.point_mm,
                normal_world=self.normal_world,
                geom_id=self.geom_id,
            )
        validated = RayPickResultPacket.from_dict(out)
        if validated.hit:
            out["target_id"] = validated.target_id
            out["target_kind"] = validated.target_kind
            out["distance_mm"] = validated.distance_mm
            out["point_mm"] = validated.point_mm
            out["normal_world"] = validated.normal_world
            out["geom_id"] = validated.geom_id
        return out


@dataclass
class LabCommand:
    """One UI->Python lab command.

    Stable wire shape is `{type, seq, op, args}`.  For compatibility with the
    original plan/examples, unknown top-level fields are merged into `args` when
    an explicit args object is absent/present.
    """
    seq: int = 0
    op: str = ""
    args: dict = field(default_factory=dict)
    session_id: str | None = None
    epoch: int | None = None
    requested_tick: int | None = None
    protocol_version: int | None = None

    @staticmethod
    def from_dict(d: dict) -> "LabCommand":
        if not isinstance(d, dict):
            raise ValueError("lab command must be an object")
        try:
            # Swift V1 uses `id`/`action`; the nested `seq`/`op` form remains
            # accepted for tools/tests and older plan examples.
            seq = int(d.get("seq", d.get("id", 0)))
        except (TypeError, ValueError, OverflowError):
            seq = 0
        seq = max(0, min(2_147_483_647, seq))
        op = str(d.get("op", d.get("action", ""))).strip().lower()
        if not op or len(op) > 64:
            raise ValueError("invalid lab op")
        raw_args = d.get("args", {})
        args = dict(raw_args) if isinstance(raw_args, dict) else {}
        for key, value in d.items():
            if key not in ("type", "seq", "op", "id", "action", "args",
                           "session_id", "epoch", "requested_tick", "protocol_version") and key not in args:
                args[key] = value

        # Normalize the flat Swift V1 command into the internal argument names.
        target = d.get("target")
        if target is not None and "id" not in args:
            args["id"] = str(target)
        if op == "touch" and target is not None:
            args.setdefault("target", str(target))
        if op == "flash_eye" and target is not None:
            args.setdefault("eye", str(target))
        if any(k in d for k in ("x", "y", "z")) and "position_mm" not in args:
            args["position_mm"] = [
                d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0)]
        if "size" in d and "size_mm" not in args:
            size = d.get("size")
            args["size_mm"] = [size, size, size]
        if "speed" in d and "speed_mm_s" not in args:
            args["speed_mm_s"] = d.get("speed")
        if "strength" in d:
            args.setdefault("strength", d.get("strength"))
        if "duration_ms" in d:
            args.setdefault("duration_ms", d.get("duration_ms"))
        if op in ("temperature", "set_temperature") and "value" in d:
            args.setdefault("celsius", d.get("value"))
        if op == "flash_eye":
            if "strength" in d:
                args.setdefault("intensity", d.get("strength"))
            elif "value" in d:
                args.setdefault("intensity", d.get("value"))
        if op in ("set_eye_state", "eye_state") and target in ("left", "right") and "value" in d:
            # Swift value=1 means covered; value=0 means restored.
            args[f"{target}_mask"] = d.get("value")
        session_id = None if d.get("session_id") is None else _session_id(d.get("session_id"))
        epoch = None if d.get("epoch") is None else _bounded_int(d.get("epoch"), 1)
        requested_tick = (None if d.get("requested_tick") is None else
                          _bounded_int(d.get("requested_tick"), 0))
        protocol_version = (None if d.get("protocol_version") is None else
                            _bounded_int(d.get("protocol_version"), 0, 1_000_000))
        return LabCommand(seq=seq, op=op, args=args, session_id=session_id,
                          epoch=epoch, requested_tick=requested_tick,
                          protocol_version=protocol_version)

    def to_dict(self) -> dict:
        out = {"type": LAB_COMMAND_TYPE, "seq": self.seq, "op": self.op, "args": self.args}
        if self.session_id is not None:
            out["session_id"] = self.session_id
        if self.epoch is not None:
            out["epoch"] = self.epoch
        if self.requested_tick is not None:
            out["requested_tick"] = self.requested_tick
        if self.protocol_version is not None:
            out["protocol_version"] = self.protocol_version
        return out

    def continuous_key(self):
        if self.op not in CONTINUOUS_LAB_OPS:
            return None
        if self.op in ("move_object", "resize_object"):
            return f"{self.op}:{self.args.get('id', '')}"
        if self.op in ("set_eye_state", "eye_state"):
            left_keys = ("left_enabled", "left_mask")
            right_keys = ("right_enabled", "right_mask")
            touches_left = any(key in self.args for key in left_keys)
            touches_right = any(key in self.args for key in right_keys)
            eye = str(self.args.get("eye", "")).strip().lower()
            touches_left = touches_left or eye == "left"
            touches_right = touches_right or eye == "right"
            if touches_left and not touches_right:
                return "eyes:left"
            if touches_right and not touches_left:
                return "eyes:right"
            return "eyes:both"
        if self.op in ("temperature", "set_temperature"):
            return "temperature"
        return self.op


@dataclass
class LabStatePacket:
    ack: int | None = None
    ok: bool = True
    error: str | None = None
    state: dict = field(default_factory=dict)
    applied_tick: int | None = None
    applied_epoch: int | None = None
    status: str | None = None
    session_id: str | None = None
    epoch: int | None = None
    sim_tick: int | None = None

    @staticmethod
    def from_dict(d: dict) -> "LabStatePacket":
        if not isinstance(d, dict):
            raise ValueError("lab state must be an object")
        ack = d.get("ack")
        if ack is not None:
            try:
                ack = max(0, min(2_147_483_647, int(ack)))
            except (TypeError, ValueError, OverflowError):
                ack = None
        state = d.get("state", {})
        return LabStatePacket(
            ack=ack,
            ok=bool(d.get("ok", True)),
            error=None if d.get("error") is None else str(d.get("error"))[:512],
            state=dict(state) if isinstance(state, dict) else {},
            applied_tick=(None if d.get("applied_tick") is None else
                          _bounded_int(d.get("applied_tick"), 0)),
            applied_epoch=(None if d.get("applied_epoch") is None else
                           _bounded_int(d.get("applied_epoch"), 1)),
            status=None if d.get("status") is None else str(d.get("status"))[:64],
            session_id=(None if d.get("session_id") is None else _session_id(d.get("session_id"))),
            epoch=(None if d.get("epoch") is None else _bounded_int(d.get("epoch"), 1)),
            sim_tick=(None if d.get("sim_tick") is None else _bounded_int(d.get("sim_tick"), 0)),
        )

    def to_dict(self) -> dict:
        d = {"type": LAB_STATE_TYPE, "ack": self.ack, "ok": self.ok, "state": self.state}
        if self.error is not None:
            d["error"] = self.error
        if self.applied_tick is not None:
            d["applied_tick"] = self.applied_tick
        if self.applied_epoch is not None:
            d["applied_epoch"] = self.applied_epoch
        if self.status is not None:
            d["status"] = self.status
        if self.session_id is not None:
            d["session_id"] = self.session_id
        if self.epoch is not None:
            d["epoch"] = self.epoch
        if self.sim_tick is not None:
            d["sim_tick"] = self.sim_tick
        # Swift V1 deliberately decodes a small flat summary while the nested
        # state object retains the complete backend state for future clients.
        if isinstance(self.state, dict):
            d["t"] = clamp(self.state.get("t", 0.0), 0.0, 1e12)
            objects = self.state.get("objects")
            if isinstance(objects, list):
                d["object_count"] = len(objects)
            temperature = self.state.get("temperature")
            if isinstance(temperature, dict):
                d["temperature"] = clamp(temperature.get("celsius", 25.0), 0.0, 50.0)
            wind = self.state.get("wind")
            if isinstance(wind, dict):
                d["wind"] = clamp(wind.get("strength", 0.0), 0.0, 1.0)
            eyes = self.state.get("eyes")
            if isinstance(eyes, dict):
                d["left_eye_covered"] = (not bool(eyes.get("left_enabled", True)) or
                                         clamp(eyes.get("left_mask", 0.0), 0.0, 1.0) >= 0.999)
                d["right_eye_covered"] = (not bool(eyes.get("right_enabled", True)) or
                                          clamp(eyes.get("right_mask", 0.0), 0.0, 1.0) >= 0.999)
            if self.state.get("last_action") is not None:
                d["last_action"] = str(self.state.get("last_action"))[:64]
        return d


@dataclass
class LabEventPacket:
    event: str = ""
    data: dict = field(default_factory=dict)

    @staticmethod
    def from_dict(d: dict) -> "LabEventPacket":
        if not isinstance(d, dict):
            raise ValueError("lab event must be an object")
        event = str(d.get("event", ""))[:64]
        data = d.get("data", {})
        return LabEventPacket(event=event, data=dict(data) if isinstance(data, dict) else {})

    def to_dict(self) -> dict:
        return {"type": LAB_EVENT_TYPE, "event": self.event, "data": self.data}


class LabCommandQueue:
    """Thread-safe bounded FIFO for discrete ops + per-control latest slots."""

    def __init__(self, max_discrete=MAX_DISCRETE_LAB_COMMANDS,
                 max_continuous=MAX_CONTINUOUS_LAB_SLOTS):
        self.max_discrete = max(1, int(max_discrete))
        self.max_continuous = max(1, int(max_continuous))
        self._discrete = deque()
        self._continuous = OrderedDict()
        self._lock = threading.Lock()
        self.dropped = 0

    def push(self, command: LabCommand) -> bool:
        key = command.continuous_key()
        with self._lock:
            if key is None:
                if len(self._discrete) >= self.max_discrete:
                    self.dropped += 1
                    return False
                self._discrete.append(command)
                return True
            if key not in self._continuous and len(self._continuous) >= self.max_continuous:
                self.dropped += 1
                return False
            # Replacement is intentional latest-wins behavior.  Move to end so
            # drain order follows the most recent sequence as closely as possible.
            self._continuous.pop(key, None)
            self._continuous[key] = command
            return True

    def drain(self, max_discrete=None):
        with self._lock:
            n = len(self._discrete) if max_discrete is None else min(len(self._discrete), max(0, int(max_discrete)))
            discrete = [self._discrete.popleft() for _ in range(n)]
            # A pending lifecycle command may create/delete an object referenced
            # by a continuous slot. Keep latest-wins controls until the discrete
            # FIFO ahead of them has completely drained.
            if self._discrete:
                continuous = []
            else:
                continuous = list(self._continuous.values())
                self._continuous.clear()
        # Preserve wire intent when lifecycle and latest-state controls share a
        # tick (spawn->move, wind->reset, move->delete). Python's sort is stable,
        # so clients that omit sequence IDs (all seq=0) retain FIFO-then-slot
        # behavior while Swift's monotonic command IDs recover total order.
        return sorted(discrete + continuous, key=lambda command: command.seq)

    def stats(self):
        with self._lock:
            return {
                "discrete_pending": len(self._discrete),
                "continuous_pending": len(self._continuous),
                "dropped": self.dropped,
                "max_discrete": self.max_discrete,
                "max_continuous": self.max_continuous,
            }

def encode(obj) -> bytes:
    return (json.dumps(obj.to_dict(), separators=(",", ":"), allow_nan=False) + "\n").encode()

def decode_line(line: bytes):
    """Parse one newline-delimited line. Unknown/malformed packets return None."""
    try:
        text = line.decode("utf-8", errors="strict").strip()
    except Exception:
        return None
    if not text:
        return None
    try:
        d = json.loads(text)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None
    kind = d.get("type", "")
    try:
        if kind == BRAIN_TYPE:
            return BrainPacket.from_dict(d)
        if kind == BODY_TYPE:
            return BodyPacket.from_dict(d)
        if kind == LAB_COMMAND_TYPE:
            return LabCommand.from_dict(d)
        if kind == LAB_STATE_TYPE:
            return LabStatePacket.from_dict(d)
        if kind == LAB_EVENT_TYPE:
            return LabEventPacket.from_dict(d)
        if kind == HELLO_TYPE:
            return HelloPacket.from_dict(d)
        if kind == SESSION_CONTROL_TYPE:
            return SessionControlPacket.from_dict(d)
        if kind == SESSION_STATE_TYPE:
            return SessionStatePacket.from_dict(d)
        if kind == EXPERIMENT_STEP_TYPE:
            return ExperimentStepPacket.from_dict(d)
        if kind == EXPERIMENT_STEP_RESULT_TYPE:
            return ExperimentStepResultPacket.from_dict(d)
        if kind == WORLD_RENDER_REQUEST_TYPE:
            return WorldRenderRequestPacket.from_dict(d)
        if kind == WORLD_RENDER_SNAPSHOT_TYPE:
            return WorldRenderSnapshotPacket.from_dict(d)
        if kind == RAY_PICK_REQUEST_TYPE:
            return RayPickRequestPacket.from_dict(d)
        if kind == RAY_PICK_RESULT_TYPE:
            return RayPickResultPacket.from_dict(d)
    except Exception:
        return None
    return None
