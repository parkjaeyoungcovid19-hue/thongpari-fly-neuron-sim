"""Stream MuJoCo's own rendering of the live FlyGym scene to the Lab window.

The passive viewer (`bridge.py --flygym`) opens a separate GLFW window that
macOS cannot embed in an AppKit window. This module renders the *same*
MjModel/MjData with MuJoCo's offscreen renderer (the NeuroMechFly meshes,
arena and lab objects exactly as the viewer draws them) and serves the frames
on a private loopback port. It is presentation only: it never steps physics
and never writes MjData.

Threading: the simulation-owner thread only runs `mjv_updateScene` (a few
microseconds) into one of two MjvScene buffers. A render thread owns the GL
context and does the expensive part — `mjr_render`, pixel readback, encoding —
with the GIL released inside MuJoCo, so physics keeps its core. A send thread
per client ships the latest frame and drops older ones.

Wire format (one client at a time, the app that launched this bridge):
  client -> server: newline-delimited JSON
      {"type": "view", "width": W, "height": H,
       "position_mm": [x, y, z], "forward": [fx, fy, fz],
       "distance_mm": d, "fovy_deg": f,
       "anchor": "fly" | "participant_first" | "participant_third" (optional),
       "offset_mm": [dx, dy, dz] (camera position minus fly, for "fly")}
      An anchored camera is resolved against the live pose at render time, so
      following views move at the frame rate, not the snapshot rate.
  server -> client: 24-byte little-endian header + raw RGB rows (top first)
      b"MJF1", u32 width, u32 height, u64 frame_seq, u32 payload_len
"""

import json
import math
import socket
import struct
import threading
import time

HEADER = struct.Struct("<4sIIQI")
MAGIC = b"MJF1"
MAX_PIXELS = 1200 * 800          # keeps GPU readback modest on an 8 GB M2 Air
MIN_SIDE = 64
FIRST_PERSON_EYE_FRACTION = 0.6   # eye offset from the participant centre, x radius
FAR_PLANE_MM = 5000.0            # matches WorldViewer's SceneKit zFar
MAX_GEOMS = 10000


class ViewStream:
    def __init__(self, port, host="127.0.0.1", fps=24.0):
        self.host = host
        self.port = int(port)
        self.period = 1.0 / float(fps)
        self._lock = threading.Condition()
        self._camera = None          # latest camera request from the client
        self._camera_rev = 0
        self._client = None
        self._running = True
        # Owner thread -> render thread: two scenes, latest ready one wins.
        self._scenes = None
        self._ready = None           # (index, width, height) waiting to render
        self._busy = None            # index the render thread is reading
        self._model = None
        # Render thread -> send thread.
        self._frame = None           # (w, h, seq, bytes)
        self._seq = 0
        self._rendered_rev = -1
        self._rendered_physics = None
        self._next_render = 0.0
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind((self.host, self.port))
        self._server.listen(1)
        self._server.settimeout(0.2)
        threading.Thread(target=self._accept_loop, name="view-accept", daemon=True).start()
        self._render_thread = threading.Thread(target=self._render_loop, name="view-render", daemon=True)
        self._render_thread.start()
        print(f"view-stream: listening on {self.host}:{self.port}", flush=True)

    # ---- network threads -------------------------------------------------

    def _accept_loop(self):
        while self._running:
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self._lock:
                old = self._client
                self._client = conn
                self._frame = None
                self._rendered_rev = -1
            if old is not None:
                _close(old)
            print("view-stream: client connected", flush=True)
            threading.Thread(target=self._read_loop, args=(conn,), daemon=True).start()
            threading.Thread(target=self._send_loop, args=(conn,), daemon=True).start()

    def _read_loop(self, conn):
        buf = b""
        while self._running:
            try:
                chunk = conn.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                camera = _parse_camera(msg)
                if camera is not None:
                    with self._lock:
                        self._camera = camera
                        self._camera_rev += 1
        self._drop(conn)

    def _send_loop(self, conn):
        sent = -1
        while self._running:
            with self._lock:
                while self._running and self._client is conn and (
                        self._frame is None or self._frame[2] == sent):
                    self._lock.wait(0.5)
                if not self._running or self._client is not conn:
                    return
                w, h, seq, payload = self._frame
            try:
                conn.sendall(HEADER.pack(MAGIC, w, h, seq, len(payload)))
                conn.sendall(payload)
            except OSError:
                self._drop(conn)
                return
            sent = seq

    def _drop(self, conn):
        with self._lock:
            if self._client is conn:
                self._client = None
                self._lock.notify_all()
        _close(conn)

    # ---- simulation-owner thread -----------------------------------------

    def render_if_due(self, model, data, physics_tick, anchors=None):
        """Snapshot the scene for the render thread if a client is watching
        and the camera or physics changed since the last frame.

        Call only from the thread that owns MjData. Camera changes still
        produce frames while the session is paused; the rate is capped at fps.
        `anchors()` returns {"fly": xyz, "participant": {position_mm,
        orientation_quat_xyzw, collision_radius_mm} or None}; it is called
        only when a frame is actually due.
        """
        import mujoco
        now = time.monotonic()
        if now < self._next_render:
            return
        with self._lock:
            if self._client is None or self._camera is None:
                return
            camera, rev = self._camera, self._camera_rev
            if rev == self._rendered_rev and physics_tick == self._rendered_physics:
                return
            if self._scenes is None:
                self._model = model
                self._scenes = [mujoco.MjvScene(model, maxgeom=MAX_GEOMS) for _ in range(2)]
                self._option = mujoco.MjvOption()
                self._free_camera = mujoco.MjvCamera()
                self._free_camera.type = mujoco.mjtCamera.mjCAMERA_FREE
            index = 1 if self._busy == 0 else 0
            if self._ready is not None and self._ready[0] == index:
                self._ready = None
        self._next_render = now + self.period
        scene = self._scenes[index]
        cam = self._free_camera
        (px, py, pz), (fx, fy, fz) = _resolve_anchor(
            camera, anchors() if anchors is not None and camera["anchor"] else {})
        d = camera["distance_mm"]
        cam.distance = d
        cam.azimuth = math.degrees(math.atan2(fy, fx))
        cam.elevation = math.degrees(math.asin(max(-1.0, min(1.0, fz))))
        cam.lookat[:] = (px + fx * d, py + fy * d, pz + fz * d)
        try:
            mujoco.mjv_updateScene(model, data, self._option, None, cam,
                                   mujoco.mjtCatBit.mjCAT_ALL, scene)
        except Exception as e:  # never take the physics loop down for a picture
            print(f"view-stream: scene update failed ({e})", flush=True)
            self._next_render = now + 2.0
            return
        if camera["anchor"] == "participant_first":
            _hide_participant_geom(model, scene)
        # Same cosmetic passes the passive viewer disabled on this machine.
        for flag in (mujoco.mjtRndFlag.mjRND_SHADOW,
                     mujoco.mjtRndFlag.mjRND_REFLECTION,
                     mujoco.mjtRndFlag.mjRND_SKYBOX,
                     mujoco.mjtRndFlag.mjRND_FOG,
                     mujoco.mjtRndFlag.mjRND_HAZE):
            scene.flags[flag] = 0
        # Vertical FOV and far plane are set on this scene's camera, never on
        # the model: the model's far plane (vis.map.zfar x extent) would clip
        # the arena, but the fly's eye cameras must keep seeing exactly what
        # they did.
        half = math.tan(math.radians(camera["fovy_deg"]) / 2.0)
        for glcam in scene.camera:
            glcam.frustum_far = max(glcam.frustum_far, FAR_PLANE_MM)
            glcam.frustum_top = glcam.frustum_near * half
            glcam.frustum_bottom = -glcam.frustum_near * half
        with self._lock:
            self._rendered_rev = rev
            self._rendered_physics = physics_tick
            self._ready = (index, camera["width"], camera["height"])
            self._lock.notify_all()

    # ---- render thread ---------------------------------------------------

    def _render_loop(self):
        import mujoco
        import numpy as np
        gl = context = None
        size = None
        while self._running:
            with self._lock:
                while self._running and self._ready is None:
                    self._lock.wait(0.5)
                if not self._running:
                    break
                index, w, h = self._ready
                self._ready = None
                self._busy = index
                model = self._model
            try:
                if size != (w, h):
                    if context is not None:
                        context.free()
                        gl.free()
                    # The offscreen buffer must be at least as large as the frame.
                    model.vis.global_.offwidth = max(int(model.vis.global_.offwidth), w)
                    model.vis.global_.offheight = max(int(model.vis.global_.offheight), h)
                    gl = mujoco.GLContext(w, h)
                    gl.make_current()
                    context = mujoco.MjrContext(model, mujoco.mjtFontScale.mjFONTSCALE_150)
                    mujoco.mjr_setBuffer(mujoco.mjtFramebuffer.mjFB_OFFSCREEN, context)
                    rect = mujoco.MjrRect(0, 0, w, h)
                    pixels = np.empty((h, w, 3), dtype=np.uint8)
                    size = (w, h)
                mujoco.mjr_render(rect, self._scenes[index], context)
                mujoco.mjr_readPixels(pixels, None, rect, context)
                payload = np.flipud(pixels).tobytes()
            except Exception as e:
                print(f"view-stream: render failed ({e})", flush=True)
                size = None
                context = gl = None
                with self._lock:
                    self._busy = None
                time.sleep(2.0)
                continue
            with self._lock:
                self._busy = None
                self._seq += 1
                self._frame = (w, h, self._seq, payload)
                self._lock.notify_all()
        if context is not None:
            context.free()
            gl.free()

    def close(self):
        with self._lock:
            self._running = False
            client = self._client
            self._client = None
            self._lock.notify_all()
        if client is not None:
            _close(client)
        _close(self._server)
        self._render_thread.join(timeout=2.0)


def _parse_camera(msg):
    if not isinstance(msg, dict) or msg.get("type") != "view":
        return None
    try:
        w = int(msg["width"])
        h = int(msg["height"])
        pos = [float(v) for v in msg["position_mm"]][:3]
        fwd = [float(v) for v in msg["forward"]][:3]
        dist = float(msg.get("distance_mm", 100.0))
        fovy = float(msg.get("fovy_deg", 45.0))
    except (KeyError, TypeError, ValueError):
        return None
    if len(pos) != 3 or len(fwd) != 3:
        return None
    if not all(math.isfinite(v) for v in pos + fwd + [dist, fovy]):
        return None
    norm = math.sqrt(sum(v * v for v in fwd))
    if norm < 1e-9:
        return None
    fwd = [v / norm for v in fwd]
    w, h = max(MIN_SIDE, w), max(MIN_SIDE, h)
    if w * h > MAX_PIXELS:
        s = math.sqrt(MAX_PIXELS / float(w * h))
        w, h = max(MIN_SIDE, int(w * s)), max(MIN_SIDE, int(h * s))
    anchor = msg.get("anchor")
    if anchor not in ("fly", "participant_first", "participant_third"):
        anchor = None
    try:
        offset = [float(v) for v in msg.get("offset_mm") or [0.0, 0.0, 0.0]][:3]
    except (TypeError, ValueError):
        offset = [0.0, 0.0, 0.0]
    if len(offset) != 3 or not all(math.isfinite(v) for v in offset):
        offset = [0.0, 0.0, 0.0]
    return {"width": w, "height": h, "position_mm": pos, "forward": fwd,
            "distance_mm": max(1.0, dist), "fovy_deg": max(5.0, min(120.0, fovy)),
            "anchor": anchor, "offset_mm": offset}


def _resolve_anchor(camera, anchors):
    """Camera position and unit forward (MuJoCo mm) for this render.

    Mirrors WorldViewer.participantCameraPose so the app's pick camera and
    this picture agree; falls back to the client's own camera whenever the
    anchor is unavailable (e.g. participant not active).
    """
    pos, fwd = list(camera["position_mm"]), list(camera["forward"])
    anchor = camera["anchor"]
    if anchor == "fly" and anchors.get("fly") is not None:
        fly = anchors["fly"]
        return [float(fly[i]) + camera["offset_mm"][i] for i in range(3)], fwd
    player = anchors.get("participant")
    if anchor in ("participant_first", "participant_third") and player:
        x, y, z, w = player["orientation_quat_xyzw"]
        forward = [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)]
        n = math.sqrt(sum(v * v for v in forward)) or 1.0
        forward = [v / n for v in forward]
        p = player["position_mm"]
        r = max(0.2, float(player.get("collision_radius_mm") or 2.5))
        if anchor == "participant_first":
            # Inside the collision sphere (whose own geom is hidden from this
            # view): an eye outside it enters a wall the body is pressed against,
            # and the wall vanishes as if the participant had passed through.
            return [p[i] + forward[i] * r * FIRST_PERSON_EYE_FRACTION for i in range(3)], forward
        h = math.hypot(forward[0], forward[1])
        flat = [forward[0] / h, forward[1] / h, 0.0] if h > 1e-6 else [1.0, 0.0, 0.0]
        eye = [p[0] - flat[0] * r * 5, p[1] - flat[1] * r * 5, p[2] + r * 2.2]
        target = [p[i] + forward[i] * r * 3 for i in range(3)]
        look = [target[i] - eye[i] for i in range(3)]
        n = math.sqrt(sum(v * v for v in look)) or 1.0
        return eye, [v / n for v in look]
    return pos, fwd


def _hide_participant_geom(model, scene):
    """Drop the participant's own sphere from a first-person frame."""
    import mujoco
    from player_body import PLAYER_GEOM_NAME
    gid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_GEOM, PLAYER_GEOM_NAME)
    if gid < 0:
        return
    for i in range(scene.ngeom):
        g = scene.geoms[i]
        if g.objtype == mujoco.mjtObj.mjOBJ_GEOM and g.objid == gid:
            g.rgba[3] = 0.0
            g.size[:] = 0.0


def _close(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass
