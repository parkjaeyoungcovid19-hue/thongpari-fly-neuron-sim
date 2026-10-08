"""Shared test setup; importing it never starts a body, thread or listener."""
import sys
from pathlib import Path
from contextlib import contextmanager
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
REPO = ROOT.parent
from bridge import Bridge
from protocol import HelloPacket, SessionControlPacket, LabCommand, encode


def mock_bridge(session_id="test", mode="deterministic", epoch=1):
    bridge = Bridge(mode="mock")
    begin(bridge, session_id, mode, epoch)
    return bridge


def begin(bridge, session_id="test", mode="deterministic", epoch=1, seq=1, tick=0):
    bridge.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
    bridge.handle_line(encode(SessionControlPacket(session_id=session_id, mode=mode,
                                                  epoch=epoch, seq=seq, sim_tick=tick, action="begin")))
    bridge._process_session_controls()
    return bridge._drain_lab_responses()


def command(body, op, **args):
    return body.apply_lab_command(LabCommand(op=op, args=args))


@contextmanager
def real_body(**kwargs):
    from fly_body import RealFlyBody
    body = RealFlyBody(**kwargs)
    try:
        yield body
    finally:
        body.close()


def decode_test_line(line):
    """Strict bidirectional roundtrip decoder; production reads inbound only."""
    import json
    import protocol as p
    packet = p.decode_line(line)
    if packet is not None:
        return packet
    types = {
        p.BODY_TYPE: p.BodyPacket, p.LAB_STATE_TYPE: p.LabStatePacket,
        p.LAB_EVENT_TYPE: p.LabEventPacket, p.SESSION_STATE_TYPE: p.SessionStatePacket,
        p.EXPERIMENT_STEP_RESULT_TYPE: p.ExperimentStepResultPacket,
        p.PLAYER_INPUT_RESULT_TYPE: p.PlayerInputResultPacket,
        p.WORLD_RENDER_SNAPSHOT_TYPE: p.WorldRenderSnapshotPacket,
        p.RAY_PICK_RESULT_TYPE: p.RayPickResultPacket,
    }
    try:
        data = json.loads(line.decode("utf-8", errors="strict").strip())
        cls = types.get(data.get("type"))
        return cls.from_dict(data) if cls else None
    except Exception:
        return None
