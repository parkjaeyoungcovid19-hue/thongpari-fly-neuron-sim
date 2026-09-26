# V5.6 Swift↔Python TCP 통합 시험 — 2026-09-26

## 판정

| backend | `--interactionloop` exit | 기능 동선 | 전체 판정 | 별도 `--labloop` |
|---|---:|---|---|---|
| mock | 1 | 연결, 참여, 집기, 운반, 놓기, 거절 3종, 기존 명령 ACK 통과 | **FAIL (2)**: 공개 API에서 계약의 상태 속도값과 사건 상세를 읽을 수 없음 | fresh mock에서 exit 0, PASS |
| FlyGym headless | 1 | 위와 동일하게 통과 | **FAIL (2)**: 같은 공개 API 관측 결함 | 해당 없음 |

`--interactionloop`의 실패 2개는 backend가 해당 값을 보내지 않는다는 판정이 아니다. Python은 `lab_state.interaction`과 `lab_event.data`에 값을 넣지만 현재 `FlyGymBridge` 공개 결과 타입이 이를 버리므로, 요청한 **실제 TCP 경로의 Swift 쪽에서** 값·형식을 검증할 수 없다. 성공한 기능 동선을 전체 PASS로 바꾸지 않았다. mock에는 MuJoCo contact/관통 계산이 없으므로 real 물리 증거로 세지 않는다.

## 실행 명령과 로그

저장소 루트에서 실행했다. 두 backend 모두 실행 직전 `lsof -nP -iTCP:17841 -sTCP:LISTEN` 결과가 비어 있음을 확인했다. backend는 이 시험이 띄운 실행 세션에서만 유지했고 `bridge listening` 출력 후 연결했다. PID는 동명 `.pid`에 기록했으며 종료 때 기록한 PID만 `kill`했다. `--interactionloop`는 앱 GUI를 띄우지 않고 `FlyGymBridge` 공개 메서드로 interactive session/랩 명령/입력/상호작용/렌더 요청을 보낸다.

| 실행 | exit | 증거 |
|---|---:|---|
| `./build.sh` | 0 | `build.log` |
| `./ThongpariFlyNeuronSim --bridgetest` | 0 | `bridgetest.log` |
| `./ThongpariFlyNeuronSim --labtest` | 0 | `labtest.log` |
| `./ThongpariFlyNeuronSim --v4test` | 0 | `v4test.log` |
| `./flygym-venv/bin/python flygym_bridge/bridge.py --mock` | 시험 후 SIGTERM | `mock-backend.log` |
| `./ThongpariFlyNeuronSim --interactionloop` (fresh mock) | 1 | `mock-interactionloop.log` |
| `./flygym-venv/bin/python flygym_bridge/bridge.py --mock` (별도 fresh instance) | 시험 후 SIGTERM | `mock-labloop-backend.log` |
| `./ThongpariFlyNeuronSim --labloop` | 0 | `mock-labloop.log` |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/bridge.py --flygym-headless` | 시험 후 SIGTERM | `headless-backend.log` |
| `./ThongpariFlyNeuronSim --interactionloop` (fresh headless) | 1 | `headless-interactionloop.log` |
| `git diff --check -- BridgeDiagnostics.swift main.swift` | 0 | 출력 없음 |

처음 mock backend를 단발 셸의 백그라운드 자식으로 띄운 시도는 셸 종료 때 backend가 함께 종료되어 연결에 실패했다. 포트와 PID가 사라진 것을 확인한 뒤 유지되는 실행 세션에서 fresh backend로 다시 시작했다. 아래 수치와 로그는 그 최종 실행의 것이다.

## TCP 관측값

| 항목 | mock | FlyGym headless |
|---|---:|---:|
| backend hello `player_body`, `player_input` | 둘 다 있음 | 둘 다 있음 |
| interactive session/참여 ACK | 성공 | 성공 |
| 집기 ACK / `held_object_id` | 성공 / 시험 상자 ID | 성공 / 시험 상자 ID |
| 옆 이동 상자 거리 | **12.3985 mm** | **11.1536 mm** |
| 이동 관측 구간 | **416 ms** (snapshot 16개) | **400 ms** (snapshot 10개) |
| 최대 snapshot 구간 평균 속도 | **41.2903 mm/s** | **38.1050 mm/s** |
| 계약 상수 40 mm/s + 2 mm/s 샘플 여유 | 통과 | 통과 |
| 놓은 후 위치 변화 | **0.000000 mm**, tick 755→2839 | **0.000000 mm**, tick 825→1205 |
| 거절 대조군 | `not_holding`, `ray_miss`, `out_of_reach: 25.500mm` | 동일 |
| 거절 뒤 상태 | `held_object_id == nil`, 상자 위치 불변 | 동일 |
| 기존 `spawn_box`/`move_object`/`delete_object` | 모두 ACK `ok`, `action`, `status=applied` | 동일 |
| 사건 이름 | `object_grabbed`, `object_placed` | 동일 |
| 사건 `id`, `reason`, 정수 `sim_tick_ms` | **Swift 공개 API에서 확인 불가** | **Swift 공개 API에서 확인 불가** |

속도는 snapshot의 XY 위치 차이를 `sim_tick` 차이로 나눈 **구간 평균의 최대값**이다. 2 mm/s 여유는 짧은 snapshot 구간과 정수 ms tick 표기의 양자화에 적용했다. 이 수치로 native substep의 순간 속도나 접촉·관통을 검증했다고 주장하지 않는다. mock의 `mode`는 계약상 `mock_kinematic_carry`다.

## 통합 결함과 재현

1. **상태 속도값 소실.** `flygym_bridge/protocol.py:1229-1238`은 `interaction` 전체를 top-level `lab_state`에 복사하고, `flygym_bridge/interaction.py:92`의 상태에는 `carry_speed_mm_s`가 있다. 그러나 `LabProtocol.swift:313-339`의 `LabInteractionState`는 `held_object_id`, `carry_blocked`, `reach_mm`만 decode한다. `FlyGymBridge.swift:241`의 `latestLabState()`로는 계약에서 요구한 **lab_state 값 자체**와 측정 속도를 비교할 수 없다. 재현: fresh backend에서 `--interactionloop` 실행 후 `carry_speed_mm_s observable from public state` FAIL을 본다. 수정 필요 파일은 허용 범위 밖이라 변경하지 않았다.
2. **사건 상세 소실.** `flygym_bridge/lab_world.py:537-542`는 사건에 정수 `sim_tick_ms`를 넣고 `flygym_bridge/bridge.py:916-925`는 이를 `LabEventPacket.data`로 보낸다. 그러나 `LabProtocol.swift:275-283`의 `LabEventNotice`는 `type`, `event`만 decode한다. `FlyGymBridge.swift:283-288`의 `labEvents(after:)`에서 상자 ID, `object_placed.reason=place`, tick을 확인할 수 없다. 재현: 같은 명령에서 `object_grabbed`/`object_placed` 이름은 PASS, `event id/reason/integer sim_tick_ms observable`은 FAIL. 수정 필요 파일은 허용 범위 밖이라 변경하지 않았다.

interactive V4 경로의 기존 명령 ACK에서는 `applied_tick`이 nil로 관측됐다. 기존 `--labloop`는 해당 필드를 필수로 요구하지 않는다. 이 시험은 기존 형식의 `id`, `ok`, `action`, `status`를 검사했다.

## 정리

시험 상자는 `delete_object` ACK 후 제거했고 참여체는 `set_player_active=0` ACK 후 비활성화했다. mock interaction backend PID 43608, 별도 labloop backend PID 43637, headless backend PID 43708만 종료했다. 종료 뒤 포트 17841 listener는 없었다(`port-after.log`). `ps -axo pid=,comm=,args= -ww`에서 실행 파일명이 Python/python 또는 `ThongpariFlyNeuronSim`인 잔존 행은 0개였다(`process-check.log`). GUI, git 쓰기, 패키지 설치는 실행하지 않았다.
