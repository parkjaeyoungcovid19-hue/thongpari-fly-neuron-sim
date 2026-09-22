"""Focused V5 backend tests for atomic snapshots, participant and read-only picking."""
from __future__ import annotations

import copy
import math
import os
import socket
import sys
import threading
import time
from types import SimpleNamespace

import mujoco
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bridge import Bridge
from fly_body import RealFlyBody
from protocol import (
    HelloPacket,
    LabCommand,
    RayPickRequestPacket,
    RayPickResultPacket,
    SessionControlPacket,
    V4_CAPABILITIES,
    V5_VIEW_CAPABILITIES,
    V5_PLAYER_CAPABILITIES,
    WorldRenderRequestPacket,
    WorldRenderSnapshotPacket,
    decode_line,
    encode,
)


fails = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f"  {name}" + (f": {detail}" if detail else ""))
    if not cond:
        fails.append(name)


class PacketReader:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def until(self, packet_type, timeout=2.0):
        deadline = time.monotonic() + timeout
        self.sock.settimeout(0.05)
        while time.monotonic() < deadline:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                packet = decode_line(line + b"\n")
                if isinstance(packet, packet_type):
                    return packet
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            self.buf += chunk
        return None


def start_transport(bridge):
    server_sock, client_sock = socket.socketpair()
    bridge.running = True
    thread = threading.Thread(target=bridge.serve_once, args=(server_sock,), daemon=True)
    thread.start()
    reader = PacketReader(client_sock)
    hello_packet = reader.until(HelloPacket)
    return client_sock, reader, thread, hello_packet


def stop_transport(client_sock, thread):
    try:
        client_sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    client_sock.close()
    thread.join(timeout=2.0)


# Wire contract: V5 capabilities are optional additions to the V4 handshake.
hello = HelloPacket()
check(
    "V5 view capabilities advertised without changing V4 required set",
    V5_VIEW_CAPABILITIES.issubset(hello.capabilities)
    and V5_PLAYER_CAPABILITIES.issubset(hello.capabilities)
    and hello.supports_v4_deterministic(require_physics_timestep=False)
    and V4_CAPABILITIES.isdisjoint(V5_VIEW_CAPABILITIES | V5_PLAYER_CAPABILITIES),
    repr(hello.capabilities),
)

render_req = WorldRenderRequestPacket(session_id="", epoch=0, seq=7)
render_req_rt = decode_line(encode(render_req))
check(
    "sessionless world render request round-trip",
    isinstance(render_req_rt, WorldRenderRequestPacket)
    and render_req_rt.session_id == ""
    and render_req_rt.epoch == 0
    and render_req_rt.seq == 7,
    repr(render_req_rt),
)

ray_req = RayPickRequestPacket(
    session_id="", epoch=0, seq=8,
    source_snapshot_seq=3, source_world_revision=4, source_sim_tick=25,
    ray_origin_mm=[1.0, 2.0, 3.0], ray_direction=[10.0, 0.0, 0.0],
)
ray_req_rt = decode_line(encode(ray_req))
check(
    "ray request normalizes direction on strict decode",
    isinstance(ray_req_rt, RayPickRequestPacket)
    and ray_req_rt.ray_direction == [1.0, 0.0, 0.0]
    and ray_req_rt.source_snapshot_seq == 3
    and ray_req_rt.source_world_revision == 4
    and ray_req_rt.source_sim_tick == 25,
    repr(ray_req_rt),
)

bad_packets = [
    b'{"type":"world_render_request","protocol_version":4,"session_id":"","epoch":0}\n',
    b'{"type":"ray_pick_request","protocol_version":4,"session_id":"","epoch":0,"seq":1,"ray_origin_mm":[0,0,0],"ray_direction":[1,0,0]}\n',
    b'{"type":"ray_pick_request","protocol_version":4,"session_id":"","epoch":0,"seq":1,"source_snapshot_seq":0,"source_world_revision":0,"source_sim_tick":0,"ray_origin_mm":[0,0,0],"ray_direction":[1,0,0]}\n',
    b'{"type":"ray_pick_request","protocol_version":4,"session_id":"","epoch":0,"seq":1,"source_snapshot_seq":1,"source_world_revision":0,"source_sim_tick":0,"ray_origin_mm":[0,0],"ray_direction":[1,0,0]}\n',
    b'{"type":"ray_pick_request","protocol_version":4,"session_id":"","epoch":0,"seq":1,"source_snapshot_seq":1,"source_world_revision":0,"source_sim_tick":0,"ray_origin_mm":[NaN,0,0],"ray_direction":[1,0,0]}\n',
    b'{"type":"ray_pick_request","protocol_version":4,"session_id":"","epoch":0,"seq":1,"source_snapshot_seq":1,"source_world_revision":0,"source_sim_tick":0,"ray_origin_mm":[0,0,0],"ray_direction":[0,0,0]}\n',
    b'{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":1,"sim_tick":0,"world_revision":0,"ok":true,"hit":false}\n',
    b'{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":0,"ok":true,"snapshot_seq":1,"world_revision":0,"fly":{"id":"fly","position_mm":[0,0,0],"orientation_quat_xyzw":[0,0,0,2]},"objects":[]}\n',
    b'{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":0,"ok":true,"snapshot_seq":1,"world_revision":0,"fly":{"id":"fly","position_mm":[0,0,0],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"id":"player","position_mm":[1,2,3],"orientation_quat_xyzw":[0,0,0,1],"collision_radius_mm":-1,"mode":"participate"}}\n',
    b'{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":0,"ok":true,"snapshot_seq":1,"world_revision":0,"fly":{"id":"fly","position_mm":[0,0,0],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"id":"player","position_mm":[1,2,3],"orientation_quat_xyzw":[0,0,0,1],"collision_radius_mm":2.5}}\n',
]
check(
    "strict V5 packets reject missing fields, NaN, bad lengths and invalid quaternion",
    all(decode_line(packet) is None for packet in bad_packets),
)


# Owner-boundary snapshot behavior in mock mode. No unsolicited packets are emitted;
# a receive-side request is inert until the owner-side query drain runs.
bridge = Bridge(mode="mock")
bridge.body.lab_world.spawn_object(
    shape="box", object_id="box-a", position_mm=[12.0, 3.0, 4.0],
    size_mm=[6.0, 8.0, 10.0], yaw_deg=90.0,
)
bridge.body.x = 0.004
bridge.body.y = -0.002
bridge.body.heading = math.pi / 3.0

bridge.handle_line(encode(WorldRenderRequestPacket(session_id="", epoch=0, seq=1)))
check(
    "render request receive path queues without producing snapshot",
    len(bridge.pending_view_queries) == 1 and bridge._drain_lab_responses() == [],
)
bridge._process_view_queries()
responses = bridge._drain_lab_responses()
snapshot1 = responses[0] if responses else None
box1 = snapshot1.objects[0] if isinstance(snapshot1, WorldRenderSnapshotPacket) and snapshot1.objects else None
check(
    "owner boundary emits strict atomic world render snapshot",
    isinstance(snapshot1, WorldRenderSnapshotPacket)
    and snapshot1.ok
    and snapshot1.session_id == ""
    and snapshot1.epoch == 0
    and snapshot1.sim_tick == 0
    and snapshot1.snapshot_seq == 1
    and snapshot1.world_revision == bridge.body.lab_world.revision
    and snapshot1.fly["position_mm"] == [4.0, -2.0, 0.7]
    and len(snapshot1.fly["orientation_quat_xyzw"]) == 4
    and abs(sum(v * v for v in snapshot1.fly["orientation_quat_xyzw"]) - 1.0) < 1e-9
    and box1 is not None
    and box1["id"] == "box-a"
    and box1["position_mm"] == [12.0, 3.0, 4.0]
    and box1["size_mm"] == [6.0, 8.0, 10.0]
    and box1["revision"] > 0,
    repr(snapshot1),
)

first_snapshot_wire = decode_line(encode(snapshot1)) if snapshot1 is not None else None
check(
    "generated world snapshot round-trips through strict decoder",
    isinstance(first_snapshot_wire, WorldRenderSnapshotPacket)
    and first_snapshot_wire.snapshot_seq == snapshot1.snapshot_seq,
    repr(first_snapshot_wire),
)

# Duplicate query identity is idempotent even if the world has since changed.
first_revision = snapshot1.world_revision
bridge.body.lab_world.move_object("box-a", position_mm=[20.0, 3.0, 4.0])
bridge.handle_line(encode(WorldRenderRequestPacket(session_id="", epoch=0, seq=1)))
bridge._process_view_queries()
duplicate = bridge._drain_lab_responses()[0]
bridge.handle_line(encode(WorldRenderRequestPacket(session_id="", epoch=0, seq=2)))
bridge._process_view_queries()
snapshot2 = bridge._drain_lab_responses()[0]
check(
    "snapshot sequence and world revision are monotonic while duplicate is idempotent",
    duplicate.snapshot_seq == snapshot1.snapshot_seq
    and duplicate.world_revision == first_revision
    and duplicate.objects[0]["position_mm"] == [12.0, 3.0, 4.0]
    and snapshot2.snapshot_seq > snapshot1.snapshot_seq
    and snapshot2.world_revision > first_revision
    and snapshot2.objects[0]["position_mm"] == [20.0, 3.0, 4.0],
    f"first={snapshot1.snapshot_seq}/{first_revision} duplicate={duplicate.snapshot_seq}/{duplicate.world_revision} "
    f"next={snapshot2.snapshot_seq}/{snapshot2.world_revision}",
)

# V5.4 participant presence is an owner-side world mutation, not camera state.
# The inactive probe contributes no geometry. Activating it advances structural
# provenance, then the same backend-owned pose appears in the atomic snapshot.
inactive_player_revision = bridge.body.lab_world.revision
inactive_structure_revision = bridge.body.lab_world.structure_revision
player_result = bridge.body.apply_lab_command(
    LabCommand(seq=90, op="set_player_active", args={"value": 1.0}))
bridge.handle_line(encode(WorldRenderRequestPacket(session_id="", epoch=0, seq=3)))
bridge._process_view_queries()
player_snapshot = bridge._drain_lab_responses()[0]
check(
    "V5.4 activating participant mutates authoritative world structure",
    player_result.get("player_active") is True
    and bridge.body.lab_world.revision == inactive_player_revision + 1
    and bridge.body.lab_world.structure_revision == inactive_structure_revision + 1,
    repr(player_result),
)
check(
    "V5.4 atomic snapshot carries strict backend-owned player pose",
    isinstance(player_snapshot, WorldRenderSnapshotPacket)
    and player_snapshot.ok
    and player_snapshot.player is not None
    and player_snapshot.player["actor_id"] == "player"
    and player_snapshot.player["position_mm"] == [24.0, 0.0, 2.5]
    and player_snapshot.player["orientation_quat_xyzw"] == [0.0, 0.0, 0.0, 1.0]
    and player_snapshot.player["collision_radius_mm"] == 2.5
    and player_snapshot.player["mode"] == "participate",
    repr(player_snapshot),
)
player_roundtrip = decode_line(encode(player_snapshot))
check(
    "V5.4 player collision radius/mode survive strict wire round-trip",
    isinstance(player_roundtrip, WorldRenderSnapshotPacket)
    and player_roundtrip.player == player_snapshot.player,
    repr(player_roundtrip),
)


# Once a V4 session exists, stale epoch/session view queries fail closed.
bridge.handle_line(encode(SessionControlPacket(
    session_id="v5-session", epoch=1, seq=1, sim_tick=0,
    action="begin", mode="interactive",
)))
bridge._process_session_controls()
bridge._drain_lab_responses()
bridge.handle_line(encode(WorldRenderRequestPacket(session_id="v5-session", epoch=0, seq=10)))
bridge._process_view_queries()
stale_snapshot = bridge._drain_lab_responses()[0]
check(
    "old epoch world snapshot request is rejected",
    isinstance(stale_snapshot, WorldRenderSnapshotPacket)
    and not stale_snapshot.ok
    and stale_snapshot.error == "wrong epoch",
    repr(stale_snapshot),
)

bridge.handle_line(encode(WorldRenderRequestPacket(session_id="v5-session", epoch=1, seq=20)))
bridge._process_view_queries()
session_snapshot = bridge._drain_lab_responses()[0]
check(
    "active session snapshot becomes canonical ray source",
    isinstance(session_snapshot, WorldRenderSnapshotPacket)
    and session_snapshot.ok
    and session_snapshot.session_id == "v5-session"
    and session_snapshot.epoch == 1
    and session_snapshot.snapshot_seq in bridge.snapshot_sources,
    repr(session_snapshot),
)

# Interactive owner time may advance after the displayed snapshot. The source
# tick still identifies that exact frame, but it is intentionally not a barrier
# against evaluating the ray on current owner state.
bridge.body.t = 0.125
world_before_pick = copy.deepcopy(bridge.body.lab_world.state())
bridge.handle_line(encode(RayPickRequestPacket(
    session_id="v5-session", epoch=1, seq=11,
    source_snapshot_seq=session_snapshot.snapshot_seq,
    source_world_revision=session_snapshot.world_revision,
    source_sim_tick=session_snapshot.sim_tick,
    ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
)))
bridge._process_view_queries()
mock_pick = bridge._drain_lab_responses()[0]
world_after_pick = bridge.body.lab_world.state()
check(
    "mock ray pick is compatible, reports miss, and does not mutate world",
    isinstance(mock_pick, RayPickResultPacket)
    and mock_pick.ok and not mock_pick.hit
    and mock_pick.sim_tick == 125
    and mock_pick.source_snapshot_seq == session_snapshot.snapshot_seq
    and mock_pick.source_world_revision == session_snapshot.world_revision
    and mock_pick.source_sim_tick == session_snapshot.sim_tick
    and mock_pick.source_sim_tick != mock_pick.sim_tick
    and world_after_pick == world_before_pick,
    repr(mock_pick),
)

bridge.handle_line(encode(RayPickRequestPacket(
    session_id="v5-session", epoch=1, seq=12,
    source_snapshot_seq=bridge.snapshot_seq + 100,
    source_world_revision=session_snapshot.world_revision,
    source_sim_tick=session_snapshot.sim_tick,
    ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
)))
bridge._process_view_queries()
future_pick = bridge._drain_lab_responses()[0]
check(
    "future source snapshot is rejected without mutation",
    isinstance(future_pick, RayPickResultPacket)
    and not future_pick.ok and not future_pick.hit
    and future_pick.error == "unknown source snapshot"
    and future_pick.source_snapshot_seq == bridge.snapshot_seq + 100
    and bridge.body.lab_world.state() == world_before_pick,
    repr(future_pick),
)

bridge.handle_line(encode(RayPickRequestPacket(
    session_id="v5-session", epoch=1, seq=13,
    source_snapshot_seq=1,
    source_world_revision=session_snapshot.world_revision,
    source_sim_tick=session_snapshot.sim_tick,
    ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
)))
bridge._process_view_queries()
unknown_pick = bridge._drain_lab_responses()[0]
check(
    "cleared pre-session source snapshot is unknown even below last sequence",
    not unknown_pick.ok and not unknown_pick.hit
    and unknown_pick.error == "unknown source snapshot"
    and bridge.body.lab_world.state() == world_before_pick,
    repr(unknown_pick),
)

bridge.body.lab_world.move_object("box-a", position_mm=[21.0, 3.0, 4.0])
world_after_intentional_move = copy.deepcopy(bridge.body.lab_world.state())
bridge.handle_line(encode(RayPickRequestPacket(
    session_id="v5-session", epoch=1, seq=14,
    source_snapshot_seq=session_snapshot.snapshot_seq,
    source_world_revision=session_snapshot.world_revision,
    source_sim_tick=session_snapshot.sim_tick,
    ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
)))
bridge._process_view_queries()
pose_advanced_pick = bridge._drain_lab_responses()[0]
check(
    "pose-only world revision advance still allows current-owner ray evaluation",
    pose_advanced_pick.ok and not pose_advanced_pick.hit
    and pose_advanced_pick.source_world_revision == session_snapshot.world_revision
    and pose_advanced_pick.world_revision == bridge.body.lab_world.revision
    and pose_advanced_pick.world_revision > pose_advanced_pick.source_world_revision
    and bridge.body.lab_world.state() == world_after_intentional_move,
    repr(pose_advanced_pick),
)

bridge.body.lab_world.resize_object("box-a", size_mm=[8.0, 8.0, 10.0])
world_after_structural_change = copy.deepcopy(bridge.body.lab_world.state())
bridge.handle_line(encode(RayPickRequestPacket(
    session_id="v5-session", epoch=1, seq=15,
    source_snapshot_seq=session_snapshot.snapshot_seq,
    source_world_revision=session_snapshot.world_revision,
    source_sim_tick=session_snapshot.sim_tick,
    ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
)))
bridge._process_view_queries()
stale_world_pick = bridge._drain_lab_responses()[0]
check(
    "structurally stale source snapshot is rejected before ray evaluation",
    not stale_world_pick.ok and not stale_world_pick.hit
    and stale_world_pick.error == "stale source world revision"
    and stale_world_pick.world_revision == bridge.body.lab_world.revision
    and bridge.body.lab_world.state() == world_after_structural_change,
    repr(stale_world_pick),
)

bridge.handle_line(encode(RayPickRequestPacket(
    session_id="v5-session", epoch=0, seq=16,
    source_snapshot_seq=session_snapshot.snapshot_seq,
    source_world_revision=session_snapshot.world_revision,
    source_sim_tick=session_snapshot.sim_tick,
    ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
)))
bridge._process_view_queries()
stale_epoch_pick = bridge._drain_lab_responses()[0]
check(
    "old epoch ray pick is rejected without mutation",
    isinstance(stale_epoch_pick, RayPickResultPacket)
    and not stale_epoch_pick.ok and not stale_epoch_pick.hit
    and stale_epoch_pick.error == "wrong epoch"
    and bridge.body.lab_world.state() == world_after_structural_change,
    repr(stale_epoch_pick),
)


# Transport-order regression: serve_once snapshots are processed before the
# interactive body step but flushed after it. An approach therefore advances the
# object's pose/world revision between snapshot creation and client receipt. That
# must not make the just-delivered source unusable for a current-owner pick.
moving_bridge = Bridge(mode="mock")
moving_bridge.body.lab_world.spawn_object(
    shape="sphere", object_id="moving", position_mm=[80.0, 0.0, 3.0], size_mm=4.0)
moving_bridge.body.lab_world.start_approach(
    "moving", fly_position_mm=[0.0, 0.0, 0.7], end_distance_mm=5.0, speed_mm_s=200.0)
moving_client, moving_reader, moving_thread, moving_hello = start_transport(moving_bridge)
moving_client.sendall(encode(WorldRenderRequestPacket(session_id="", epoch=0, seq=1)))
moving_snapshot = moving_reader.until(WorldRenderSnapshotPacket)
moving_revision_after_delivery = moving_bridge.body.lab_world.revision
if moving_snapshot is not None:
    moving_client.sendall(encode(RayPickRequestPacket(
        session_id="", epoch=0, seq=2,
        source_snapshot_seq=moving_snapshot.snapshot_seq,
        source_world_revision=moving_snapshot.world_revision,
        source_sim_tick=moving_snapshot.sim_tick,
        ray_origin_mm=[0.0, 0.0, 10.0], ray_direction=[0.0, 0.0, -1.0],
    )))
moving_pick = moving_reader.until(RayPickResultPacket)
stop_transport(moving_client, moving_thread)
moving_bridge.running = False
check(
    "serve_once moving approach keeps just-delivered snapshot pickable",
    isinstance(moving_hello, HelloPacket)
    and isinstance(moving_snapshot, WorldRenderSnapshotPacket) and moving_snapshot.ok
    and moving_revision_after_delivery > moving_snapshot.world_revision
    and isinstance(moving_pick, RayPickResultPacket) and moving_pick.ok
    and moving_pick.source_snapshot_seq == moving_snapshot.snapshot_seq
    and moving_pick.source_world_revision == moving_snapshot.world_revision
    and moving_pick.world_revision >= moving_revision_after_delivery,
    f"snapshot={moving_snapshot!r} delivered_revision={moving_revision_after_delivery} pick={moving_pick!r}",
)


# V5.4 lifecycle safety: participation belongs to one live client connection.
# If that client vanishes, remove its collider and retire the V4 owner session so
# reconnect cannot keep issuing traffic against the abandoned participant timeline.
disconnect_bridge = Bridge(mode="mock")
disconnect_bridge.handle_line(encode(HelloPacket(role="swift", physics_timestep_s=None)))
disconnect_bridge.handle_line(encode(SessionControlPacket(
    session_id="participant-session", epoch=3, seq=1, sim_tick=0,
    action="begin", mode="deterministic",
)))
disconnect_bridge._process_session_controls()
disconnect_bridge._drain_lab_responses()
disconnect_bridge.body.lab_world.set_player_active(True)
disconnect_revision = disconnect_bridge.body.lab_world.revision
disconnect_client, disconnect_reader, disconnect_thread, disconnect_hello = start_transport(disconnect_bridge)
stop_transport(disconnect_client, disconnect_thread)
reconnect_after_participant, reconnect_after_participant_reader, reconnect_after_participant_thread, reconnect_after_participant_hello = start_transport(disconnect_bridge)
reconnect_after_participant.sendall(encode(WorldRenderRequestPacket(
    session_id="participant-session", epoch=3, seq=1)))
stale_participant_session = reconnect_after_participant_reader.until(WorldRenderSnapshotPacket)
stop_transport(reconnect_after_participant, reconnect_after_participant_thread)
disconnect_bridge.running = False
check(
    "V5.4 participant disconnect removes body and retires old V4 session",
    isinstance(disconnect_hello, HelloPacket)
    and isinstance(reconnect_after_participant_hello, HelloPacket)
    and not disconnect_bridge.body.lab_world.player.active
    and disconnect_bridge.body.lab_world.render_player() is None
    and disconnect_bridge.body.lab_world.revision == disconnect_revision + 1
    and disconnect_bridge.session_id == ""
    and disconnect_bridge.session_epoch == 0
    and disconnect_bridge.session_tick == 0
    and disconnect_bridge.session_mode == "interactive"
    and not disconnect_bridge.session_paused
    and isinstance(stale_participant_session, WorldRenderSnapshotPacket)
    and not stale_participant_session.ok
    and stale_participant_session.error == "session not active",
    f"session={disconnect_bridge.session_id!r}/{disconnect_bridge.session_epoch} "
    f"mode={disconnect_bridge.session_mode} player={disconnect_bridge.body.lab_world.state().get('player')!r} "
    f"stale={stale_participant_session!r}",
)


# Reconnect regression: view request sequence numbers are connection-local. A
# second client reusing seq=1 must get a newly generated snapshot, not the first
# connection's cached result/source, while the logical V4 session survives.
reconnect_bridge = Bridge(mode="mock")
reconnect_bridge.handle_line(encode(SessionControlPacket(
    session_id="persist-session", epoch=4, seq=1, sim_tick=0,
    action="begin", mode="interactive",
)))
reconnect_bridge._process_session_controls()
reconnect_bridge._drain_lab_responses()
reconnect_bridge.body.lab_world.spawn_object(
    shape="box", object_id="reconnect-box", position_mm=[10.0, 0.0, 3.0], size_mm=4.0)
client1, reader1, thread1, hello1 = start_transport(reconnect_bridge)
client1.sendall(encode(WorldRenderRequestPacket(
    session_id="persist-session", epoch=4, seq=1)))
reconnect_snapshot1 = reader1.until(WorldRenderSnapshotPacket)
stop_transport(client1, thread1)
reconnect_bridge.body.lab_world.move_object("reconnect-box", position_mm=[30.0, 0.0, 3.0])
client2, reader2, thread2, hello2 = start_transport(reconnect_bridge)
sources_cleared_on_reconnect = not reconnect_bridge.snapshot_sources
client2.sendall(encode(WorldRenderRequestPacket(
    session_id="persist-session", epoch=4, seq=1)))
reconnect_snapshot2 = reader2.until(WorldRenderSnapshotPacket)
stop_transport(client2, thread2)
reconnect_bridge.running = False
check(
    "reconnect seq=1 produces fresh snapshot without clearing logical V4 session",
    isinstance(hello1, HelloPacket) and isinstance(hello2, HelloPacket)
    and sources_cleared_on_reconnect
    and reconnect_bridge.session_id == "persist-session" and reconnect_bridge.session_epoch == 4
    and isinstance(reconnect_snapshot1, WorldRenderSnapshotPacket) and reconnect_snapshot1.ok
    and isinstance(reconnect_snapshot2, WorldRenderSnapshotPacket) and reconnect_snapshot2.ok
    and reconnect_snapshot2.snapshot_seq > reconnect_snapshot1.snapshot_seq
    and reconnect_snapshot1.objects[0]["position_mm"] == [10.0, 0.0, 3.0]
    and reconnect_snapshot2.objects[0]["position_mm"] == [30.0, 0.0, 3.0],
    f"first={reconnect_snapshot1!r} second={reconnect_snapshot2!r}",
)


# Exercise the production RealFlyBody mj_ray implementation on a tiny standalone
# MuJoCo model. This avoids the expensive full FlyGym constructor while proving the
# exact ray API, semantic mapping, hit normal, miss behavior, and no state mutation.
xml = """
<mujoco>
  <worldbody>
    <geom name="ground" type="plane" size="10 10 0.1"/>
    <body name="fixture" pos="0 0 0.5">
      <geom name="pick_geom" type="box" size="0.5 0.5 0.5"/>
    </body>
  </worldbody>
</mujoco>
"""
model = mujoco.MjModel.from_xml_string(xml)
data = mujoco.MjData(model)
mujoco.mj_forward(model, data)
pick_gid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_GEOM, "pick_geom")
fixture_bid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_BODY, "fixture")


class SemanticStub:
    revision = 17
    force_body_ids = {"thorax": fixture_bid}

    def render_objects(self):
        return [{
            "id": "fixture-box",
            "shape": "box",
            "position_mm": [0.0, 0.0, 0.5],
            "orientation_quat_xyzw": [0.0, 0.0, 0.0, 1.0],
            "size_mm": [1.0, 1.0, 1.0],
            "revision": 17,
            "classification": "PHYSICAL",
            "collidable": True,
        }]

    def semantic_target_for_geom(self, geom_id):
        if int(geom_id) == pick_gid:
            return {"target_id": "fixture-box", "target_kind": "lab_object"}
        return None


real_stub = object.__new__(RealFlyBody)
real_stub.np = np
real_stub.lab_world = SemanticStub()
real_stub.sim = SimpleNamespace(
    mj_model=model,
    mj_data=data,
    _internal_bodyids_by_fly={"fly": []},
)
qpos_before_snapshot = data.qpos.copy()
qvel_before_snapshot = data.qvel.copy()
time_before_snapshot = float(data.time)
real_render_state = real_stub.world_render_state()
check(
    "real world render state exposes full MuJoCo thorax pose as XYZW",
    real_render_state["world_revision"] == 17
    and real_render_state["fly"]["position_mm"] == [0.0, 0.0, 0.5]
    and real_render_state["fly"]["orientation_quat_xyzw"] == [0.0, 0.0, 0.0, 1.0]
    and real_render_state["objects"][0]["id"] == "fixture-box",
    repr(real_render_state),
)
qpos_before = data.qpos.copy()
time_before = float(data.time)
real_hit = real_stub.ray_pick([0.0, 0.0, 3.0], [0.0, 0.0, -1.0])
real_miss = real_stub.ray_pick([0.0, 0.0, 3.0], [0.0, 0.0, 1.0])
real_render_state_after_pick = real_stub.world_render_state()
check(
    "real ray pick uses MuJoCo geometry and semantic target mapping",
    real_hit.get("hit") is True
    and real_hit.get("target_id") == "fixture-box"
    and real_hit.get("target_kind") == "lab_object"
    and real_hit.get("geom_id") == pick_gid
    and abs(real_hit.get("distance_mm", 0.0) - 2.0) < 1e-9
    and len(real_hit.get("point_mm", [])) == 3
    and len(real_hit.get("normal_world", [])) == 3
    and abs(sum(v * v for v in real_hit["normal_world"]) - 1.0) < 1e-9,
    repr(real_hit),
)
check(
    "real snapshot/pick owner refresh is same-tick stable and trajectory read-only",
    real_miss == {"hit": False}
    and real_render_state_after_pick == real_render_state
    and np.array_equal(data.qpos, qpos_before_snapshot)
    and np.array_equal(data.qvel, qvel_before_snapshot)
    and float(data.time) == time_before_snapshot
    and np.array_equal(data.qpos, qpos_before)
    and float(data.time) == time_before,
    repr(real_miss),
)


print("ALL V5 TESTS PASS" if not fails else f"{len(fails)} V5 FAILURES: {fails}")
raise SystemExit(0 if not fails else 1)
