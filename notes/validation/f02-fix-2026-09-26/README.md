# F-02 참여체 충돌 수정 검증 — 2026-09-26

기준 commit: `dc768e4`. 대상: [전체 감사 F-02](../../../docs/reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md)(held input으로 벽을 누르면 1.66 mm 침투, 해제 후 83 mm 반대 방향 이동).

## 원인

`RealFlyBody._step_substeps`가 quantum 시작 때 20 ms 이동량(0.6 mm)을 참여체 qpos에 한 번에 더하고 `_sync()`로 qvel을 0으로 덮은 뒤에야 native substep 200회를 돌렸다. solver는 매 quantum마다 순간이동한 침투를 받았고, 누적 침투의 반발 impulse는 damping 없는 free-joint(중력 보상) 참여체를 입력 해제 후 계속 밀어냈다.

## 수정

| 파일 | 변경 |
|---|---|
| `flygym_bridge/player_body.py` | real body 전용 servo: 매 native substep마다 `xfrc_applied`에 `m·clamp((v_cmd − v)/τ, a_max)`를 쓴다. τ = 1 ms, a_max = 30 mm/s ÷ τ. 입력이 없으면 v_cmd = 0이라 해제 후 정지한다. 방향은 look 입력이 소유하며 substep마다 쿼터니언을 다시 쓰고 각속도를 0으로 둔다. quantum 끝에는 servo 힘을 0으로 되돌리고 solver pose를 owner 상태로 받아들인다. 참여체 geom `solref=(0.002, 1)`, `solmix=100`(기본 0.02 s에서는 정상 push 침투가 0.6 mm, 0.002 s도 0.1 ms timestep의 20배) |
| `flygym_bridge/lab_world.py` | `begin_player_quantum` / `player_substep` / `end_player_quantum` — 이동·회전이 있었을 때만 비구조적 revision을 올린다 |
| `flygym_bridge/fly_body.py` | real body의 quantum-앞 `advance_player_input`(qpos 순간이동) 제거, substep 루프에 servo 연결. MockBody(물리 없음)는 기존 kinematic 경로 유지 |
| `flygym_bridge/test_player_collision_real.py` | 새 real MuJoCo 회귀(아래 기준) |

collision을 끄거나 geometry를 줄이지 않았다. fly와의 explicit contact pair는 자체 solref(기본값)를 유지하므로 V5.4 fly 접촉 응답 계약은 바뀌지 않는다.

**동작 변화(의도됨):** real body에서 정지 상태의 첫 20 ms quantum 이동량은 0.600 → 0.573 mm다(τ = 1 ms 가속 구간). 이후 정상 속도는 정확히 30 mm/s다. 기존 real 테스트의 허용 오차(±0.05 mm) 안이다. mock body의 0.6 mm(1e-9) 계약은 그대로다.

## 수용 기준 (측정 전에 정함)

- 정적 LabObject: full-speed held push 중 침투 ≤ 0.1 mm
- fly thorax pair(FlyGym 기본 pair 강성 유지): 침투 ≤ 1.0 mm
- 해제: 정지 표면에서 되튀는 거리 ≤ 0.1 mm, 0.5 s 뒤 잔여 속도 ≤ 0.5 mm/s
- 자유 공간: 첫 20 ms 0.6 ± 0.05 mm, 정상 속도 30 ± 0.3 mm/s

## 결과

| 검사 | 수정 후 | HEAD `dc768e4` (음성 대조) |
|---|---|---|
| `test_player_collision_real.py` | **18/18 PASS** (`test_player_collision_real.txt`) | **8 FAIL** (`negative-control-HEAD-dc768e4.txt`) |
| 정면 벽 1/5/20 ms quantum, substep 단위 최대 침투 | 0.0245 mm (세 경우 모두) | 4.50 / 4.50 / 2.26 mm (1·5 ms는 벽 통과) |
| 정면 벽 해제 후 | 표면 x = 26.500 mm에서 정지, 속도 0 | 20.8 mm 되튐, 41.6 mm/s |
| 30° 비스듬 접근 | 침투 0.021 mm, 벽을 따라 16.6 mm 미끄러짐, look 방향 오차 0 | 침투 1.96 mm, 해제 후 16.6 mm 되튐 |
| 상자 모서리 | 침투 0.025 mm | 침투 2.26 mm, 상자 반대편 x = 44.6 mm |
| fly thorax 밀기 | 침투 0.80 mm, thorax 이동 0.86 mm, 해제 후 정지 | 침투 2.09 mm |
| 비활성화·`reset_body`·결정론·±1000 mm 작업공간 | 모두 PASS (두 번 실행한 궤적 차이 0) | PASS (기존 경로도 만족) |
| 원 감사 probe `collision_probe.py` | max_x 26.5074, 접촉 −0.0071 mm, 해제 후 26.500 mm (`f02-collision-probe.txt`) | max_x 28.1575, −1.6575 mm, 해제 후 −54.96 mm |

음성 대조는 scratch 복사본에서 세 제품 파일만 HEAD로 되돌려 같은 테스트를 실행했다.

### 기존 회귀 (수정 후)

| 검사 | 결과 |
|---|---|
| Python `test_bridge` / `test_lab` / `test_v4` / `test_v5` (mock) | 모두 `ALL … PASS`, FAIL 0 |
| `NUMBA_DISABLE_JIT=1` `test_lab_real` / `test_vision_real` | `ALL REAL LAB TESTS PASS` / `ALL REAL VISION TESTS PASS` — V5.4 fly 접촉 응답, V5.5 이동(0.570 mm), same-boundary(x = 24.570) 포함 |
| 새 backend별 TCP (`fresh_transport_probe.py`) | mock bridgeloop/labloop/v4loop, real-headless labloop/v4loop 5개 exit 0. 17841 기존 listener 없음 확인 후 실행, 종료 후 listener/bridge 프로세스 없음 |

Swift 소스는 바꾸지 않았다. 앱 번들은 checkout의 `flygym_bridge/bridge.py`를 실행하므로(`FlyGymService.swift:149`) 재패키징 없이 반영된다.

## 독립 리뷰 반영 (Codex CLI `gpt-6-sol`, reasoning high, 읽기 전용)

리뷰는 5건을 지적했고 모두 확인·수정했다.

| 지적 | 판정 | 조치 |
|---|---|---|
| 마지막 `mj_step`의 접촉 토크가 다음 quantum 전까지 render 방향을 바꿈 | **실제** — quantum 끝 고정을 뺀 복사본에서 `max|xquat−look| = 2.0e-5`로 FAIL | `end_physics_quantum`에서도 look 방향을 다시 쓰고 각속도를 0으로 만든다. 회귀 추가 |
| 재전송 타이머가 Observe에서 interactive 세션을 만들 수 있음 | 코드 확인상 가능 | Participate가 아니면 플래그를 지우고, 세션이 `running`이 아니면 대기한다(세션을 만들지 않음) |
| 이동 중 재전송이 대기 중인 look delta를 지움(F-03 회귀) | 코드 확인상 가능 | 중립(해제)일 때만 `discardPendingLook`를 쓰고, 이동 상태 재전송은 look을 보존한다 |
| real 경로에서 ±1000 mm 제한이 빠짐 | 코드 확인상 가능 | 경계 밖으로 향하는 servo 목표 속도를 0으로 둔다. 회귀 추가(x = 1000.03 mm에서 정지) |
| 테스트 PASS 조건이 느슨함 | 타당 | substep마다 침투 표본을 잡고 실제 벽/상자 접촉을 필수로 요구한다. 해제 검사는 기하 기준 양방향 판정이다. 비활성화·reset_body·결정론 검사 추가 |

## 같은 작업에서 처리한 F-01 잔여

2026-09-26 독립 점검의 F-01 잔여(“큐 거절 시 로컬 상태만 소비되고 재전송 없음”)를 `LabWindow.swift`에서 처리했다. 참여 입력 전송이 envelope 부재나 bridge 거절로 큐에 들어가지 못하면 `playerInputReconcilePending`을 세운다. 이후 10 Hz 갱신 타이머가 Participate 모드이고 세션이 이미 `running`일 때 `playerController.heldIntent()`를 다시 보낸다. 성공하면 멈춘다. 중립 상태는 기존 release 경로처럼 stale snapshot을 허용하고 대기 중인 look을 버린다. 아직 이동 중인 상태는 key down처럼 신선한 snapshot이 필요하며 look을 보존한다. 연결 세대가 바뀌거나, V5.5 입력을 쓸 수 없거나, Participate를 벗어나면 플래그를 지운다. 이때는 backend가 held input을 이미 해제하거나 참여체를 비활성화한다.

- `./build.sh` 성공, Swift `--bridgetest` `--labtest` `--v4test` `--v4timingtest` `--simtest` `--behaviortest` `--gpucheck` 모두 exit 0 (로컬 `swift-*.log`, 커밋 제외; 리뷰 반영 후 재실행, simtest 16-step 101 µs/step).
- **미검증:** snapshot 지연·전송 거절을 주입하는 fault fixture는 만들지 않았다. 재전송 경로는 UI 타이머 안에 있어 현재 Swift fixture가 직접 실행하지 않는다. 실제 GUI 동선 4에서 확인해야 한다.

## 남은 것

- **GUI 미확인:** 실제 앱에서 Participate → W로 벽 밀기 → 해제 동선(V5.5.1 계획 §7 동선 4)은 아직 화면으로 확인하지 않았다.
- 성능: headless 실측(`servo_cost_probe.py` → `servo-cost.txt`, 20 ms quantum 50회 × 3 중 최소) 결과(리뷰 반영 후 재측정) 참여체 비활성 37.4 ms, 이동 중 39.3 ms, 정지 중 38.2 ms/quantum이었다. 이동 중 최대 +1.9 ms(약 5%)로 측정 잡음과 구분하기 어려운 수준이다. 이 기계에서는 real body가 원래 실시간보다 느리다(20 ms sim당 약 37 ms wall). 통합 GUI 성능 측정(body Hz, sim/wall)은 여전히 V5.5.1 gate로 남는다.
