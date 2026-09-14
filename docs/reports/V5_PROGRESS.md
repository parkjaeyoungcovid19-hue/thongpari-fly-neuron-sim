# Virtual Fly Lab V5 — implementation progress

Prepared: **2026-09-13**
V4 baseline: `e900b272e1df4131edba51476f0d213a8d166ca1` (`Complete Virtual Fly Lab V4 deterministic sessions`)
V5 preparation commit: `3faf942` (`Prepare Virtual Fly Lab V5 implementation`)
Status: **V5.1 AUTOMATED_VERIFIED — atomic snapshot/picking + integrated SceneKit prototype are implemented; fresh GUI/focus/latency acceptance is still pending**

## Start gate

V4 is committed and the V5 prerequisite is satisfied. The repository was clean when this V5 preparation pass began. The active repository is `siliconfly/`; the workspace-level legacy bridge copy is not an implementation source.

Fresh preflight checks on the V5 baseline:

| Check | Result |
|---|---|
| `./build.sh` | PASS |
| `./ThongpariFlyNeuronSim --v4test` | PASS — `ALL V4 SESSION TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | PASS — `ALL V4 TESTS PASS` |
| `git diff --check` | PASS |

These checks confirm the committed V4 scheduling/session baseline before V5 work. They are not a substitute for the full V5 completion suite or the V4 completion report's real-backend/GUI evidence.

## Progress table

| 단계 ID | 요구 | 상태 | 변경 파일 | 실행 검사/로그 | 실패/다음 조치 |
|---|---|---|---|---|---|
| V5.1 | 현재 API 조사 및 viewport prototype | automated_verified | `LabProtocol.swift`, `FlyGymBridge.swift`, `WorldViewer.swift`, `LabWindow.swift`, `build.sh`, `flygym_bridge/{protocol,bridge,fly_body,lab_world}.py`, `flygym_bridge/test_v5.py` | focused V5 + Swift bridge/lab/V4 + Python V4/lab/bridge + real lab/vision PASS; real MuJoCo snapshot/pick probe PASS | fresh integrated GUI, keyboard-focus suitability, viewport FPS + pick ACK latency remain before `complete` |
| V5.2 | 공통 화면 상태 소유권 | implementing | `LabViewState.swift`, `LabWindow.swift`, `FlyGymBridge.swift`, `build.sh` | build + Swift bridge/lab/V4 PASS; V5.2 state fixtures PASS | first slice owns mode/selection/timeline/pause/snapshot presentation in one state; central world + collapsible tool/activity panel composition and fresh GUI acceptance remain |
| V5.3 | 관찰 camera | planned | 미정 | 미실행 | camera must stay read-only to simulation |
| V5.4 | 실제 사용자 참여체 | planned | 미정 | 미실행 | backend geometry + eye visibility required |
| V5.5 | WASD/look/E/Esc 및 focus handling | planned | 미정 | 미실행 | backend player contract required |
| V5.6 | 집기/놓기 | planned | 미정 | 미실행 | authoritative backend ray/hit/contact required |
| V5.7 | 기존 activity card 연결 | planned | 미정 | 미실행 | reuse existing telemetry only; no new state model |

No V6 terrain/environment editor, V7 neuron inspector, V8 module host, V9 checkpoint, or V11 desire/emotion model is pulled forward into this version.

## V5.2 implementation start — common screen state

The first V5.2 slice is now in the working tree. It deliberately does **not** create player physics or V5.3 camera behavior:

- `LabViewState.swift` is the single presentation-state model for Lab mode, selected fly/object, timeline tick, pause/session phase and the currently displayed atomic snapshot identity. `LabSession` remains the authoritative owner of session/epoch/tick/pause ordering; V5.2 only mirrors that state for UI consistency.
- `LabWindow` renders the common state bar and the existing Experiments session status from the same `LabViewState`, so pause/tick cannot be independently inferred by separate panels.
- Authoritative `ray_pick_result` selection updates the shared object/fly selection. New atomic snapshots reconcile object selection if the selected object no longer exists.
- The mode shell visibly owns `Observe / Participate / Edit`, but only **Observe** is enabled. Participate remains owned by V5.4/V5.5 and Edit by the later editor work; V5.2 does not pretend those contracts already exist.
- The common state keeps the `LabSession` timeline tick authoritative even when the displayed render snapshot has a different source tick.

Fresh focused checks after this first V5.2 slice: `./build.sh`, `--bridgetest`, `--labtest`, `--v4test`, and `git diff --check` all PASS. `--bridgetest` now includes V5.2 fixtures for pause/timeline consistency, shared authoritative object selection, and selection reconciliation after a newer snapshot.

## V5.1 implementation evidence — current working tree

The first runtime slice now exists. It deliberately stops before player movement/input:

- Python emits a strict, simulation-owner-produced `world_render_snapshot` with session/epoch/tick, monotonic snapshot/world revisions, full live thorax pose and authoritative lab-object 3D poses/sizes.
- Snapshot and pick queries use separate optional `world_render_snapshot` / `ray_pick` capabilities; a V4-only peer keeps deterministic V4 behavior but does not silently enable the V5 viewport.
- Sessionless observation before a V4 experiment is explicit as `session_id="", epoch=0`; once a session exists, wrong-session/old-epoch queries fail closed.
- `ray_pick_request` is read-only. The real backend uses `mujoco.mj_ray`; the result carries semantic target ID/kind, distance, hit point, world normal and geom ID. Hit and miss queries do not advance or mutate MuJoCo state.
- `WorldViewer.swift` is an AppKit-native SceneKit mirror that consumes only the atomic snapshot. It uses the right-handed basis `MuJoCo (x,y,z) -> SceneKit (x,z,-y)`, transforms orientation by the same basis and inverse-transforms click rays before sending them to MuJoCo.
- `LabWindow` hosts the new 3D view above the existing 2D arena. With V5 capability the 3D view and minimap both use the same atomic snapshot; a V4-only backend leaves the 3D view visibly unavailable instead of mixing `body` and `lab_state` into a fake snapshot.

Fresh verification after the implementation slice:

| Check | Result |
|---|---|
| `./build.sh` | PASS |
| `./ThongpariFlyNeuronSim --bridgetest` | PASS — V5 strict schema/capability/session/stale filtering + coordinate/quaternion/ray basis fixtures |
| `./ThongpariFlyNeuronSim --labtest` | PASS |
| `./ThongpariFlyNeuronSim --v4test` | PASS |
| `./ThongpariFlyNeuronSim --v4timingtest` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | PASS — `ALL V5.1 TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_bridge.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_lab_real.py` | PASS — `ALL REAL LAB TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_vision_real.py` | PASS — real LabWorld geometry changes real eye pixels and generic optic expansion |
| focused real `RealFlyBody` snapshot + `mj_ray` probe | PASS — `v5_probe` snapshot pose/size matched live MuJoCo and ray hit semantic ID `v5_probe` at 17.0 mm |
| `git diff --check` | PASS |

This is **automated verification, not V5.1 completion**. The remaining V5.1 gate is a fresh app + real backend run proving the integrated `WorldViewer` itself renders correctly, can take keyboard focus for the later V5.5 input layer, and has measured viewport FPS/snapshot rate/pick ACK latency without degrading the body/eye loop beyond the accepted budget.

## Astra independent review follow-up — 2026-09-14

The independent review in `notes/validation/v5-1-independent-2026-09-13/REVIEW.md` found three P2 defects. The review file is preserved as the original audit record; the current working tree fixes all three and adds regressions for the exact failure modes:

1. **Moving-object picks no longer fail just because pose revision advanced.** `LabWorld` now tracks an internal structural revision separately from the existing full render/world revision. Pose-only movement, including `approach`, may advance `world_revision` without invalidating a displayed snapshot as a ray source. Spawn/delete/resize/reset still invalidate structurally stale ray sources. The new `test_v5.py` transport regression reproduces the former `serve_once` ordering and verifies a just-delivered moving-object snapshot remains pickable.
2. **Reconnect cannot reuse the previous client's V5 query cache.** Each transport connection clears only V5 pending view queries, cached view results, snapshot provenance and queued V5 replies while preserving the logical V4 session/epoch/tick and V4 idempotence caches. A reconnect regression reuses request `seq=1` after moving an object and verifies the second client receives a newly generated snapshot with the live pose.
3. **Snapshot and pick observe the same derived MuJoCo pose at one owner boundary.** `RealFlyBody.world_render_state()` now runs `mj_forward` before copying `xpos/xquat`, matching the existing ray path. The full real-backend test verifies snapshot → ray hit/miss → snapshot is identical at unchanged simulation time while qpos/qvel/mocap/time/world state/events stay unchanged.

The review also identified a Swift presentation consequence of item 1: a matching backend error or successful pick could be hidden by requiring the currently displayed `world_revision` to equal the pick result revision. `worldViewerPickDisposition` now owns that decision using latest request sequence plus exact echoed source snapshot metadata. Matching error ACKs are always surfaced; pose-advanced successful hit/miss results remain usable after backend structural validation; older-request results are ignored.

Fresh post-review checks on the hardened tree:

| Check | Result |
|---|---|
| `./build.sh` | PASS |
| `./ThongpariFlyNeuronSim --bridgetest` | PASS — includes pose-advanced pick ACK, visible error ACK and stale-request rejection |
| `./ThongpariFlyNeuronSim --labtest` | PASS |
| `./ThongpariFlyNeuronSim --v4test` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | PASS — includes moving `serve_once` pick + reconnect cache regression |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_bridge.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_lab_real.py` | PASS — same-tick snapshot/pick stability on full `RealFlyBody` |
| Python `py_compile` + `git diff --check` | PASS |

No V5.2+ functionality was pulled into this repair pass. The remaining V5.1 gate is still the integrated GUI/focus/FPS/snapshot-rate/pick-ACK-latency acceptance described above.

## V5.1 API preflight — verified installed surface

The installed environment inspected for this preparation pass reports **MuJoCo 3.9.0**. The current real body already runs FlyGym 2.1 with the same compiled `MjModel`/`MjData` used by the stereo eye renderer and the passive MuJoCo viewer.

Verified public Python APIs/symbols:

- `mujoco.viewer.launch_passive(model, data, key_callback=..., show_left_ui=..., show_right_ui=...)` exists. On macOS its installed source explicitly requires running under `mjpython` and launches the Simulate GUI on the Python UI thread. The public function does not accept an AppKit host view/window handle, so embedding that existing Simulate window directly inside `LabWindow` must not be assumed.
- `mujoco.Renderer(model, height, width, ...)` exists with `update_scene(...)`, `render()`, and depth-rendering enable/disable methods. This is a viable offscreen-render comparison path, but transporting continuous frames over the current newline-JSON control protocol would require a new bounded frame transport and performance budget.
- `mujoco.mj_ray(...)` exists and returns the nearest visible-geometry intersection distance/geom ID.
- `mujoco.mjv_select(...)` exists for view-relative selection when a MuJoCo scene/camera is available.
- The existing Swift app already links **SceneKit** and uses `SCNScene`/`SCNRenderer`, so an AppKit-native `SCNView` mirror does not add a new framework dependency.

Fresh 320×240 MuJoCo offscreen probe on the V5 development machine, using the real compiled FlyGym `MjModel`/`MjData`: the first render cost **111.71 ms** (graphics warm-up), followed by **18.13, 6.16, 3.74, 2.99, 3.07, 3.06, 3.46 ms**. The steady samples are therefore only a few milliseconds, so offscreen MuJoCo rendering remains a credible comparison candidate; this is not yet an end-to-end frame-transport or integrated-viewer FPS result.

Baseline project facts that constrained the prototype:

- Before this slice, `LabWindow.swift` rendered the world only through the custom 2D `LabArenaPlacementView`; the V5.1 working tree now adds `WorldViewer.swift` while retaining the arena as a helper/minimap.
- Real MuJoCo rendering is a separate passive viewer window owned by the Python process.
- lab object state already exposes ID, shape, `position_mm`, `size_mm`, and `yaw_deg`.
- body packets already expose the fly's X/Y position and heading, but not a complete 3D pose/quaternion suitable for the V5 `WorldRenderSnapshot` contract.
- objects and fly pose currently arrive through different packet streams/cadences. A V5 renderer must not pretend those independently sampled values form one authoritative simulation-tick snapshot.

## Prototype direction for V5.1

The V5.1 implementation compares these paths with a minimal real scene, then records the measured result before V5.2:

1. **AppKit-native SceneKit viewport fed by immutable backend snapshots — current implementation candidate.** `WorldViewer.swift` owns only presentation camera, selection preview and rendering. It mirrors backend object/fly geometry but never mutates MuJoCo directly. Pick rays are sent to the backend, where MuJoCo `mj_ray` is authoritative. Fresh GUI/focus/performance acceptance is still required before declaring this production-selected.
2. **MuJoCo offscreen `Renderer` frames — comparison candidate.** Prove whether acceptable frame rate/latency is possible without starving the existing body/eye renderer. Do not send unbounded/base64 frame traffic through the current NDJSON command lane as the production design.
3. **Existing passive Simulate viewer — control/baseline only.** Keep it for visual parity and debugging. Because the installed macOS API launches a separate Python-owned window, it is not the default integrated-viewer implementation unless the prototype discovers a supported host/embedding API that was not visible in the installed public surface.

V5.1 is complete only after a real runtime prototype proves that one selected path can show the same backend geometry used for collision/eye visibility, accept keyboard focus, support authoritative picking, and meet a measured viewport budget. The automated/runtime-backend half of that gate is now green; the fresh integrated GUI/focus/latency half is still pending.

## Contract work to do before UI construction

The first code change should define/validate the world/player wire contract before creating the full Lab shell.

### Atomic render snapshot

Create one immutable backend-originated snapshot at a declared simulation boundary containing at least:

- session ID, epoch, simulation tick and monotonically increasing snapshot/revision ID;
- object IDs, shape/geometry revision and 3D poses;
- full fly body pose needed by the viewer;
- optional player pose when participation is enabled;
- enough revision information to reject stale/out-of-order snapshots.

Do not synthesize an authoritative snapshot by joining an arbitrary `lab_state` object list with a differently timed `body` packet on the Swift side.

### Player input

Player movement is a simulation command, not camera motion. Continuous axes may be latest-wins/coalesced, but discrete interaction events must remain bounded and non-dropping. Movement distance is integrated from simulation time on the backend, never from render FPS. Focus loss, Esc, disconnect and mode exit must send/establish a neutral held-input state so a stale W/A/S/D press cannot continue moving the participant.

### Picking/interactions

The viewport may calculate a local ray for hover/preview, but the backend decides the actual hit against current MuJoCo geometry. A miss is a no-op. The response should include target ID plus applied tick and, when available, hit point/normal. A UI click by itself must never be converted into a fly touch event.

### Player body

The V5 participant begins as a small fly-scale probe/avatar, not a human-scale body. Its visual and collision pose must come from one backend-owned state. It must exist in the same compiled MuJoCo world used by collisions and the fly's real eye cameras. Merely moving the observer camera is not participation.

## Existing code to reuse

- `LabSession` remains the owner of session/epoch/tick/pause ordering.
- `FlyGymBridge` already provides bounded lanes, connection generation filtering, V4 lifecycle/session control and requested/applied tick semantics; extend these instead of creating a second socket/session owner.
- `LabWorld` remains the authority for existing world objects; V5 participant state should not silently become a second object registry.
- current `LabTelemetry` already carries arousal, decoded `BrainSignals`, receptor rates and controller output needed for V5.7 read-only cards. V5 must not invent hunger/desire/emotion values.
- `LabArenaPlacementView` can survive as a minimap/coordinate helper while the 3D viewport becomes the primary interaction surface.

## First implementation slice

The current first slice is intentionally small:

1. **DONE (runtime fields used by V5.1):** focused V5 schema/validation fixtures cover render snapshot/pose and backend pick result, including missing field, NaN/invalid length, invalid quaternion and old-epoch negatives. Player movement/input schema remains deliberately deferred to its owning later step rather than becoming dead V5.1 code.
2. **DONE:** one atomic backend snapshot is produced from the simulation-owner path.
3. **DONE / GUI acceptance pending:** the minimal `WorldViewer.swift` renders backend objects + fly from that snapshot with a read-only presentation camera.
4. **DONE:** backend `mj_ray` hit + miss are verified without world mutation.
5. **BACKEND/eye evidence DONE; integrated visual acceptance pending:** real LabWorld geometry is verified in MuJoCo and the real eye renderer; the new SceneKit view still needs a fresh GUI visual comparison.
6. **PARTIAL:** offscreen render cost is measured; integrated viewport FPS, snapshot rate and click-to-pick ACK latency remain to record before V5.2.

Do not create `PlayerController.swift`, `WorldInteraction.swift` and `player_body.py` as empty stubs before their owning step starts; the common playbook explicitly avoids bulk stub creation.

## V5 completion target retained from the roadmap

The final V5 user path remains: enter participation mode → move a real participant body near the fly → place/move an object → verify the participant/object can appear through the actual eye path and contact is physical → inspect existing neural/activity telemetry → pause without advancing world/brain/player tick → return to observation mode, all from one integrated Lab viewer.

The next work is **finish V5.1 GUI/focus/performance acceptance**, not V5.2 or V6 work.
