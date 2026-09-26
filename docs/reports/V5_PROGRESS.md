# Virtual Fly Lab V5 — implementation progress

Prepared: **2026-09-13** · updated **2026-09-26**
V4 baseline: `e900b272e1df4131edba51476f0d213a8d166ca1` (`Complete Virtual Fly Lab V4 deterministic sessions`)
V5 preparation commit: `3faf942` (`Prepare Virtual Fly Lab V5 implementation`)
Status: **V5.5.1 implemented; F-02 코드 수정·자동/실제 backend 회귀 통과, 실제 GUI 참여 동선은 미확인. V5.5.1 인수 미완료이며 V5.6은 시작 전이다.**

Current next step (2026-09-26): complete V5.5.1 acceptance under [the unified-app plan](../plans/VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md) §7. The F-02 working-tree fix passed the new 18/18 real MuJoCo collision checks (per-substep penetration, look ownership, reset/deactivate, determinism, workspace bound), existing Python mock/real regressions, and five fresh-backend TCP loops; the same new test failed eight checks against HEAD `dc768e4` ([evidence](../../notes/validation/f02-fix-2026-09-26/README.md)). This is code and backend verification, not GUI acceptance. GUI flows 2–7 and integrated performance remain pending, and `V5_5_1_COMPLETION_REPORT.md` does not yet exist. Do not start V5.6 until those gates pass and the completion report records the result.

| Level | Current V5.5.1 judgment |
|---|---|
| Implemented | One-window Lab and the uncommitted F-02 code fix exist in the current working tree. |
| Automated verified | Existing automated regression and the new F-02 collision test passed in the recorded run. |
| Real backend verified | Real MuJoCo collision/legacy tests and fresh mock/real-headless TCP loops passed in the recorded run. |
| GUI accepted | **No** — real participation flow, GUI flows 2–7, and integrated performance are pending. |

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
| V5.2 | 공통 화면 상태 소유권 | implemented | `LabViewState.swift`, `LabWindow.swift`, `FlyGymBridge.swift`, `build.sh` | build + Swift bridge/lab/V4 PASS; V5.2 state fixtures PASS | common state ownership is implemented; broader fresh GUI acceptance remains part of the V5 integrated UI gate |
| V5.3 | 관찰 camera + eye sample provenance | automated_verified | `WorldViewer.swift`, `LabWindow.swift`, `FlyGymBridge.swift`, `LabProtocol.swift`, `flygym_bridge/{protocol,fly_body,test_bridge,test_lab_real}.py` | build, Swift bridge/lab/V4/timing/sim/behavior/GPU, Python V5/V4/lab/bridge PASS; fresh real lab/vision now PASS under V5.4 verification | integrated GUI acceptance remains separate |
| V5.4 | 실제 사용자 참여체 | automated_real_verified | `FlyGymBridge.swift`, `LabWindow.swift`, `flygym_bridge/{player_body,lab_world,fly_body,protocol,bridge,test_v5,test_lab_real,test_vision_real}.py` | strict player wire/capability tests, real eye pixel delta, real semantic ray, real MuJoCo fly contact, reset/disconnect lifecycle, full V4/neural regression PASS | fresh integrated GUI click-through remains before whole-V5 completion; movement input intentionally deferred to V5.5 |
| V5.5 | WASD/look/E/Esc 및 focus handling | automated_real_verified | `PlayerController.swift`, `LabProtocol.swift`, `LabWindow.swift`, `WorldViewer.swift`, `FlyGymBridge.swift`, `main.swift`, `build.sh`, `flygym_bridge/{protocol,bridge,player_body,fly_body,test_v5,test_v4,test_lab_real}.py` | strict PlayerInput/result wire tests, pre-Begin/session-generation ordering, requested_tick/idempotency/pause regressions, focus/Esc/reconnect stale-key release, remap persistence, real simulation-time movement and same-boundary free-joint pose proof, full V4/neural regression PASS | fresh integrated GUI click-through remains before whole-V5 completion; V5.6 grab/place intentionally not started |
| V5.5.1 | 한 창 Lab 및 F-02 충돌 수정 | implemented; automated + real-backend verified; GUI pending | `main.swift`, `FlyGymService.swift`, `LabWindow.swift`, `MuJoCoCanvas.swift`, `flygym_bridge/{player_body,lab_world,fly_body,test_player_collision_real}.py` | [2026-09-26 independent check](../../notes/validation/v5-5-1-independent-2026-09-26/README.md); [F-02 fix logs](../../notes/validation/f02-fix-2026-09-26/README.md): 18/18 collision PASS, HEAD negative control 8 FAIL; F-01 held-input reconcile in `LabWindow.swift` (GUI unverified), Python real/mock + fresh TCP PASS | GUI flows 2–7, integrated performance and completion report pending; V5.6 blocked |
| V5.6 | 집기/놓기 | planned | 미정 | 미실행 | authoritative backend ray/hit/contact required |
| V5.7 | 기존 activity card 연결 | planned | 미정 | 미실행 | reuse existing telemetry only; no new state model |

No V6 terrain/environment editor, V7 neuron inspector, V8 module host, V9 checkpoint, or V11 desire/emotion model is pulled forward into this version.

The implementation notes below record work from **2026-09-13 to 2026-09-22**. Their then-current wording and stage-specific next steps are historical; the 2026-09-26 status above controls the next work.

## V5.3 automated verification — observation camera + raw-eye provenance

The V5.3 implementation is now in the working tree. It remains observation-only: none of the camera controls are allowed to become a neural, lab-world, session, experiment-step or player command.

- `WorldViewer` now owns explicit **Orbit / Follow fly / Free** presentation camera modes. Right-drag rotates, Shift+right-drag pans in Orbit/Free, and scroll zooms/dollies. Follow pan is deliberately a no-op so the target remains the authoritative fly pose.
- Entering Free preserves the effective current target, camera position and forward direction. Positive scroll means zoom/dolly out in all three modes; negative scroll means in.
- The first authoritative backend snapshot still reframes the real scene even if the user pressed Reset before that snapshot arrived, or during a cleared session identity gap. `clearSnapshot()` removes old geometry/provenance and re-arms that initial frame.
- The `--bridgetest` V5.3 fixture drives the same camera APIs as the UI and proves that camera input causes **zero pick callbacks, zero pending bridge commands, zero pending lab commands, and zero mutation of the shared `LabViewState`**. Only the existing left-click path can emit an authoritative MuJoCo pick ray.
- Python `RealFlyBody` now tracks `eye_sample_sim_tick`, the exact protocol-ms simulation tick of the **latest successful** raw FlyGym stereo-eye render. It advances only after `get_raw_vision` + eye mask + vision analysis succeed; body packets between frames keep the previous tick. A failed scheduled render decays the vision signal but keeps provenance pointed at the last successful raw frame rather than falsely claiming the current body tick. `reset_body` clears the provenance.
- The optional field is strict-round-tripped through Python `BodyPacket`, Swift `FlyGymBodyPacket` / feedback, and `LabTelemetry`. The Vision UI reports `raw-eye sample tick N ms · M ms old` using the simulation time from the same body packet, or explicitly says that no raw-eye sample has rendered yet.
- Experiment CSV now records `body_eye_sample_sim_tick` so the raw-frame provenance is not lost during offline analysis.

Fresh 2026-09-22 verification on the current tree:

| Check | Result |
|---|---|
| `./build.sh` | PASS |
| `./ThongpariFlyNeuronSim --bridgetest` | PASS — includes first-snapshot framing + Orbit/Follow/Free presentation-only V5.3 regressions |
| `./ThongpariFlyNeuronSim --labtest` | PASS — includes Swift eye-tick propagation and CSV provenance |
| `./ThongpariFlyNeuronSim --v4test` | PASS — `ALL V4 SESSION TESTS PASS` |
| `./ThongpariFlyNeuronSim --v4timingtest` | PASS — 60/120 FPS and stall timing invariance preserved |
| `./ThongpariFlyNeuronSim --simtest` | PASS |
| `./ThongpariFlyNeuronSim --behaviortest` | PASS — `ALL BEHAVIOR TESTS PASS` |
| `./ThongpariFlyNeuronSim --gpucheck` | PASS — `GPUCHECK PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | PASS — `ALL V5 TESTS PASS` on the fresh V5.4 rerun |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | PASS — `ALL V4 TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` | PASS — `ALL LAB TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_bridge.py` | PASS — includes `eye_sample_sim_tick` parse/round-trip |
| Python `py_compile` + `git diff --check` | PASS |
| fresh `test_lab_real.py` / `test_vision_real.py` | PASS on the V5.4 rerun — includes V5.3 successful-sample/hold/failure/reset provenance cases |

The previous local Retina/Numba import stall did not recur during V5.4 verification. Fresh `test_vision_real.py` and `test_lab_real.py` both completed successfully, including the V5.3 eye-sample success/hold/failure/reset cases.

## V5.4 automated + real-backend verification — participant body

V5.4 now creates a **real participant body**, not a camera surrogate. The body is inactive by default so Observe/V4 behavior is unchanged, and it is activated only when a peer explicitly negotiates the new `player_body` capability and the UI enters Participate mode.

- `flygym_bridge/player_body.py` owns the bounded fly-scale participant mechanics while `LabWorld` remains the single world/revision authority. The participant is a dedicated **free-joint MuJoCo sphere**, not a generic LabObject and not a mocap/world-welded fake body.
- The participant is compiled into the same `FlatGroundWorld` as NeuroMechFly before `Simulation` construction. FlyGym's fly geometry uses explicit contact pairs, so V5.4 compiles an explicit player↔fly thorax pair instead of globally changing fly collision masks. The participant also uses the ordinary physical LabObject collision mask while active.
- Inactive state moves the free body to the hidden far position and disables its normal collision mask/visibility. Activation is a structural world change. Observe mode deactivates it normally; if a transport disappears while participation is active, the backend also retires that connection's owning V4 session so a reconnect cannot silently continue a timeline after an out-of-band physical cleanup. Passive Observe reconnects still preserve the logical V4 session.
- `WorldRenderSnapshotPacket` now strictly preserves optional `player` pose, normalized XYZW orientation, required `collision_radius_mm`, and `mode`. Swift already had the matching `WorldRenderPose`/SceneKit player path; `WorldViewer` therefore renders the exact backend collision pose/radius rather than inventing a UI-only avatar.
- V5.4 adds an explicit `player_body` negotiated capability. A V5.1-only peer may still use the viewport/picking but **cannot enable Participate**. V5.5 WASD/look/E/Esc input is intentionally not implemented here.
- `RealFlyBody.ray_pick()` maps the live player geom to semantic target `player` instead of falling through to generic `world`.
- `reset_body` resynchronizes an active participant to its authoritative spawn pose, and transport disconnect deactivates it. The participant is not inserted into the LabObject slot registry, so there is still one object registry and one LabWorld revision clock.
- Physics-driven fly/player pose changes are identified by snapshot sequence and simulation tick; they do not bump `LabWorld.world_revision` every physics step. `world_revision` advances for explicit LabWorld mutations such as a participant pose/reset command, while `structure_revision` advances only when topology/query structure changes.

Fresh 2026-09-22 V5.4 evidence:

| Check | Result |
|---|---|
| `./build.sh` | PASS |
| `./ThongpariFlyNeuronSim --bridgetest` | PASS — strict player pose, capability gate, V5.1-only negative control |
| `./ThongpariFlyNeuronSim --labtest` | PASS |
| `./ThongpariFlyNeuronSim --v4test` | PASS — `ALL V4 SESSION TESTS PASS` |
| `./ThongpariFlyNeuronSim --v4timingtest` | PASS |
| `./ThongpariFlyNeuronSim --simtest` | PASS — realtime neural simulation remains within budget |
| `./ThongpariFlyNeuronSim --behaviortest` | PASS — `ALL BEHAVIOR TESTS PASS` |
| `./ThongpariFlyNeuronSim --gpucheck` | PASS — `GPUCHECK PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | PASS — `ALL V5 TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | PASS — `ALL V4 TESTS PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_bridge.py` | PASS |
| `./flygym-venv/bin/python flygym_bridge/test_vision_real.py` | PASS — active participant changes actual FlyGym stereo-eye pixels; mean absolute delta `1.088` |
| `./flygym-venv/bin/python flygym_bridge/test_lab_real.py` | PASS — live snapshot/radius, semantic ray, calibrated player mass `0.00034` vs thorax `0.0004016` (ratio `0.847`), generic LabObject contact `(225, 14)`, explicit player↔thorax contact `(225, 226)`, bounded contact response, reset lifecycle, V5.3 eye provenance |
| `git diff --check` | PASS |

The initial V5.4 prototype used a mocap body. Real contact testing correctly rejected that design: the mocap actor remained world-welded and produced no fly contact even with matching collision masks. V5.4 therefore switched to the free-joint body above. The final real test observes an actual MuJoCo contact, so the completion evidence is physical rather than inferred from coordinates or the SceneKit mirror.

## V5.5 automated + real-backend verification — participant input

V5.5 now drives the existing V5.4 backend-owned participant through a strict `PlayerInput` contract rather than moving SceneKit geometry locally.

- Swift captures WASD, mouse look, E and Esc only while Participate mode owns keyboard focus. Selecting Participate now remains visibly selected while backend authority is pending and acts as an explicit capture intent: the 3D viewer receives focus immediately, but player input is not enabled until an authoritative snapshot confirms the backend participant. If the user moves focus to a text field/control before confirmation, capture fails closed instead of stealing focus back. Esc or later focus loss releases capture and a 3D-view click re-arms it. While Participate is pending/active but uncaptured, keyboard events are consumed by the viewer instead of leaking into SceneKit/AppKit controls. The Lab window explicitly enables ordinary AppKit `mouseMoved` delivery. Mode exit, capability loss, disconnect and connection-generation rollover also release held input. Safety release can fall back to interactive tick 0 when the matching render snapshot is stale or temporarily absent, and it replaces any unsent mouse-look packet/remainder with an explicit zero-look neutral packet, so neither movement nor stale rotation can leak past release. Released keys are blocked until a fresh physical press, so stale key-repeat cannot resume movement after focus returns.
- Key bindings persist through the existing `UserDefaults` preference pattern. Conflicting remaps swap keys, corrupt/duplicate stored mappings fail back to the known-unique defaults, and Esc remains a fixed local safety release.
- `FlyGymBridge` keeps a bounded latest-state PlayerInput lane: axes/held actions are latest-wins while unsent look deltas accumulate exactly once. If coalesced look exceeds the per-packet `pi/4` bound it is split across monotonically sequenced packets instead of being clipped; every chunk drains before a deterministic experiment step can cross the same authoritative boundary.
- Python and Swift enforce matching strict PlayerInput/result bounds and success/failure presence rules. Successful results are `status=applied` with a non-null authoritative `applied_tick` and no `error` key; failures have no `applied_tick` key, cannot claim `applied`, and carry a non-empty error. Swift never emits a PlayerInput sequence above Python's `2_147_483_647` wire limit.
- Sessionful input received before the owning Begin/reset is terminally rejected even if SessionControl is drained first from its separate queue. SessionControl receive phases also distinguish `pause -> input -> resume` from `pause -> resume -> input`, so only the former is rejected by the pause barrier. Disconnect always drops transport-owned deferred input and queued activation, while a passive reconnect that intentionally preserves the logical V4 session also preserves the consumed-input sequence watermark; an evicted old seq therefore cannot become authoritative again.
- Movement integrates at `PLAYER_MOVE_SPEED_MM_S` from simulation time, not render/input packet frequency. Local forward is MuJoCo +X and local right maps to world -Y when yaw is zero. Real free-joint motion uses authoritative qpos after same-boundary activation, avoiding stale derived `xpos` jumps.
- V5.6 grab/place is not included. E is carried only as the V5.5 `interact` held action contract for the later interaction layer.

Fresh 2026-09-22 V5.5 evidence:

| Check | Result |
|---|---|
| `./build.sh` | PASS |
| `./ThongpariFlyNeuronSim --bridgetest` | PASS — capability layering, strict result bounds/presence, lossless bounded look splitting, pending-look cancellation on safety release, pending-Participate key ownership, remap persistence, and explicit Follow-fly authoritative-motion tracking |
| `./ThongpariFlyNeuronSim --labtest` | PASS |
| `./ThongpariFlyNeuronSim --v4test` | PASS — `ALL V4 SESSION TESTS PASS` |
| `./ThongpariFlyNeuronSim --v4timingtest` | PASS — 60/120 FPS and stall invariance preserved |
| `./ThongpariFlyNeuronSim --simtest` | PASS — whole-brain realtime regression remains within budget |
| `./ThongpariFlyNeuronSim --behaviortest` | PASS — `ALL BEHAVIOR TESTS PASS` |
| `./ThongpariFlyNeuronSim --gpucheck` | PASS — `GPUCHECK PASS` |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | PASS — strict V5.5 wire/result cases plus sessionless interactive input |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | PASS — pre-Begin/pre-reset rejection, pause/resume receive ordering, exact requested tick, idempotency, wrong session/epoch, pause neutralization, +Y basis, render-frame independence |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_lab_real.py` | PASS — real 20 ms movement = 0.600000 mm and same-boundary activation+input starts from qpos spawn 24.0 mm |
| `./flygym-venv/bin/python flygym_bridge/test_vision_real.py` | PASS — V5.4 eye visibility remains intact |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` / `test_bridge.py` | PASS |
| Python `py_compile` + `git diff --check` | PASS |

A fresh integrated GUI smoke on 2026-09-22 used the real parent `.command`/FlyGym path. Accessibility UI automation pressed the live Participate segment and observed the segment values change to `0/1/0`, then the status reached `Participant controls — CAPTURED · WASD move · mouse look · E interact · Esc release`. Sending a real W key through the focused app produced `Participant controls — input #2 applied at tick 4365`, proving the live UI reached the backend PlayerInput lane. The live camera popup also changed from Orbit to Follow fly, while the strengthened bridge regression independently proves that a moved authoritative fly snapshot translates the Follow camera by the exact corresponding scene-space delta. Whole-V5 GUI completion still needs broader live text-focus/focus-loss, disconnect recovery and performance/latency acceptance.

## V5.2 implementation start — common screen state

The first V5.2 slice is now in the working tree. It deliberately does **not** create player physics or V5.3 camera behavior:

- `LabViewState.swift` is the single presentation-state model for Lab mode, selected fly/object, timeline tick, pause/session phase and the currently displayed atomic snapshot identity. `LabSession` remains the authoritative owner of session/epoch/tick/pause ordering; V5.2 only mirrors that state for UI consistency.
- `LabWindow` renders the common state bar and the existing Experiments session status from the same `LabViewState`, so pause/tick cannot be independently inferred by separate panels.
- Authoritative `ray_pick_result` selection updates the shared object/fly selection. New atomic snapshots reconcile object selection if the selected object no longer exists.
- The mode shell visibly owns `Observe / Participate / Edit`, but only **Observe** is enabled. Participate remains owned by V5.4/V5.5 and Edit by the later editor work; V5.2 does not pretend those contracts already exist.
- The common state keeps the `LabSession` timeline tick authoritative even when the displayed render snapshot has a different source tick.

Fresh focused checks after this first V5.2 slice: `./build.sh`, `--bridgetest`, `--labtest`, `--v4test`, and `git diff --check` all PASS. `--bridgetest` now includes V5.2 fixtures for pause/timeline consistency, shared authoritative object selection, and selection reconciliation after a newer snapshot.

## V5.1 implementation evidence — historical 2026-09-13 to 2026-09-22

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
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | PASS — `ALL V5 TESTS PASS` |
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

1. **Moving-object picks no longer fail just because pose revision advanced.** `LabWorld` now tracks an internal structural revision separately from the existing world revision. Explicit LabWorld pose mutations, including `approach`, may advance `world_revision` without invalidating a displayed snapshot as a ray source; ordinary physics-driven fly/player motion is instead identified by `snapshot_seq`/`sim_tick` and does not bump `world_revision` every step. Spawn/delete/resize/reset-world topology changes still invalidate structurally stale ray sources. The new `test_v5.py` transport regression reproduces the former `serve_once` ordering and verifies a just-delivered moving-object snapshot remains pickable.
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

The V5 participant begins as a small fly-scale probe/avatar, not a human-scale body. V5.4 implements it as a backend-owned **free-joint MuJoCo sphere** in the same compiled world as NeuroMechFly, with an **explicit participant↔fly thorax contact pair** matching FlyGym's contact model. Its visual and collision pose come from that one physical body. Merely moving the observer camera is not participation.

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

Historical next step in the **2026-09-13 to 2026-09-22 V5.1 notes**: finish V5.1 GUI/focus/performance acceptance before the next stage. The current next step is the V5.5.1 acceptance stated at the top of this report.
