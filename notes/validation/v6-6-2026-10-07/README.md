# V6.6 transaction·undo/redo — 검증 기록 (2026-10-07)

상태: **구현 완료, 자동·실물 TCP·실제 GUI 통과 (2026-10-08 재빌드 후 재확인, 아래 ‘재빌드 검증’).** 설계 결정은 [V6 계획 6.6](../../../docs/plans/VIRTUAL_FLY_LAB_V6_PLAN.md).

## 바뀐 것

| 영역 | 내용 |
|---|---|
| `protocol.py` | `PAUSE_EDIT_LAB_OPS`, `LabCommandQueue.drain_paused_edits()` — 큐 맨 앞의 스탬프된 편집만, 더 이른 continuous 슬롯 앞에서 멈춤 |
| `bridge.py` | `_apply_paused_edit_transaction()`: interactive 일시정지 중 편집만 멈춘 tick에서 적용, ACK `edit.transaction="paused"`. `_apply_lab_commands`가 명시 명령 목록을 받도록 분리 |
| `lab_world.py` | `apply_edit` 결과에 `previous_value`, `refresh_poses()`(`mj_kinematics`만), 초기 온도 상태에 `neural_target: None`(이후 상태와 키 일치) |
| `WorldEditHistory.swift`(신규) | 기록·합치기(1.5 s)·값 확인 후 되돌리기·복제 undo/redo·삭제 시 정리·`LabMainWindow` 메뉴 연결 |
| `LabWindow.swift` | 창을 `LabMainWindow`로, `sendEdit` 공용화, ACK 기록, 메시지를 해당 패널에 표시, 기록 `edit_history` 마크 |
| `WorldEditor.swift`, `EnvironmentPanel.swift` | 결과 표시 훅, 안내문(⌘Z/⇧⌘Z, 삭제는 되돌릴 수 없음) |

## 결과

| 검사 | 결과 |
|---|---|
| Python `test_v6_6_pause_edits` (mock) | 9 PASS: 멈춘 tick 적용·step 없음, 자극 장벽·재개 후 순서, 이른 continuous 장벽, 스탬프 없는 명령 대기, 거절 불변, 미래 tick, 복제/삭제, 편집 가능한 설정 30+개 전부 `previous_value`로 원상복구(경사로 크기·기울기 포함) |
| Python `test_v6_6_pause_edits_real` | PASS: `refresh_poses`가 geom 위치만 갱신, time·qpos·qvel 불변. 갱신 없으면 옛 위치(대조) |
| Python 회귀 mock 13종·real 4종 | 모두 exit 0 (`py-*.log`). `test_environment_edits`의 정확한 ACK 비교에 `previous_value` 추가 |
| [TCP 탐침](tcp_pause_undo_probe.py) mock / real FlyGym | 15/15, 15/15 ([mock](tcp-probe-mock.log), [real](tcp-probe-real.log)). V6-04 포함: 온도 33→되돌림 30, applied tick 495→855, body t 계속 증가 |
| TCP 음성 대조 | serve loop 호출을 빼면 일시정지 편집 ACK가 오지 않아 실패([log](negative-control-mock.log)) |
| Swift `--worldeditortest` | V6.6 검사 31개 PASS, 0 failures (`swift---worldeditortest.log`). `--labtest`/`--v4test`/`--bridgetest` exit 0 |
| Swift 음성 대조 | 복사본에 결함 3개(단계 고정 제거, 값 확인 제거, 합치기 0 s) → 4개 검사 FAIL([log](swift-negative-control.log)) |
| 실제 앱 GUI (AX 자동화, English) | 편집기 X 60→80 적용 → 편집 ▸ ‘Undo Move obstacle_box’ → 60 → ‘Redo Move obstacle_box’ → 80. 일시정지 중 Y 20 적용, 되돌림 ‘Undid Move obstacle_box (while paused)’, tick 62705 ms 고정. 캡처 `gui-0*.png` |

## GUI에서 찾은 결함 (소스 수정됨, **빌드·검증 안 됨**)

1. **값 입력 후 Return 뒤 ⌘Z가 비활성.** Return 후에도 텍스트 칸에 포커스가 남아 ⌘Z가 비어 있는 글자 되돌리기로 감(환경 패널 온도 33 → 메뉴 ‘실행 취소’ 비활성). 수정: 칸에 되돌릴 입력이 있을 때만 글자 되돌리기, 아니면 세계 기록(`LabMainWindow.textUndo`). 진단 3개 추가.
2. **일시정지 중 ‘Stale data’ 경고.** 일시정지면 body 패킷이 일부러 멈추는데 오래된 데이터로 표시됨. 수정: 일시정지가 확인되고 lab_state가 신선하면 연결을 Live로(`WorkspaceSnapshot.connection(pausedOwnerFresh:)`). 진단 1개 추가.

참고: 온도 입력 칸 등 환경 패널 숫자 칸에 접근성 라벨이 없다(일반 ‘텍스트 필드’). 기존 문제, 미수정.

## 재빌드 검증 (2026-10-08)

`./build.sh`(이번에 `-j<코어 수>` 병렬 컴파일로 바꿈, 같은 non-WMO 모드, 126 s → 51–59 s) → `--worldeditortest`·`--labtest`·`--v4test`·`--bridgetest` 모두 exit 0(`rebuild--*.log`), Python `test_v6_6_pause_edits`·`test_environment_edits` exit 0 → `./package_app.sh` → 실제 앱(English, AX 자동화).

**새로 찾은 결함 3 (P1, 수정됨):** 새로 실행한 직후 Edit·Participate 모드에 한 번도 들어가지 않고 환경 패널에서 온도를 바꾸면 `edit_property — rejected · wrong session`(두 번 반복 재현, [캡처](gui-rebuild-02-temp33.png)). 원인: interactive 세션 `begin`은 Participate/Edit 진입 때만 보내고, 그 전까지 Swift `LabSession`은 백엔드가 모르는 로컬 UUID를 들고 있다. 이전 GUI 확인은 편집기를 먼저 써서 놓쳤다. 일시정지도 같은 이유로 로컬에서만 처리됐다. 수정: `LabWindowController.refresh()`가 백엔드가 연결되고 V5.5 입력을 지원하면 `ensureInteractivePlayerInputSession()`을 부른다(interactive `begin`은 몸을 초기화하지 않음 — `bridge.py` `_process_session_controls`).

**결함 4 (P3, 수정됨):** 일시정지 중 환경 패널 ‘파리 위치의 현재 값’이 주황색 ‘새 몸 데이터 없음’. 결함 2와 같은 종류. 수정: 일시정지 확인 + lab_state 신선이면 마지막 body 패킷을 ‘(일시정지)’로 표시. 진단 `V6.6 paused body sample says paused, not missing` PASS.

| GUI 확인 (수정 후 빌드) | 화면에서 본 값 |
|---|---|
| 새 실행 직후 환경 패널 온도 33 + Return | `#1 edit_property — applied @t8485`, `Applied: 33.0 °C` |
| Return 직후 편집 메뉴 (결함 1) | 텍스트 칸에 포커스가 있는데 `Undo Temperature [enabled]` |
| 편집 ▸ Undo Temperature | `Applied: 25.0 °C`, `Undid Temperature`, 메뉴 `Redo Temperature` |
| 일시정지 (결함 2) | 상태줄 `Live — headless backend … body feedback 0 Hz`(Stale 아님), 제목 `Live · Paused` |
| 일시정지 중 Redo | `Applied: 33.0 °C`, `Redid Temperature (while paused)`, ACK `#3 … applied @t19245` |
| 재개 | 파리 위치 값의 온도 33.0 °C, body t 계속 증가 ([캡처](gui-rebuild-06-resumed.png)) |
| 일시정지 중 샘플 (결함 4) | `At the fly  x 2.7 · y 0.4 mm · facing 6° · body t 1.025 s (paused)` ([캡처](gui-rebuild-07-paused-sample.png)) |

참고: 타임라인의 ‘session pause requested — local’은 요청 출처(이 창) 표시다. 자동화 중 body 갱신 14–22 Hz로 DEGRADED가 떴다(배터리, 성능 수치 아님).

## 남은 일 (재빌드 전 기록)

- `./build.sh` → `--worldeditortest`·`--labtest` → `./package_app.sh` → GUI 재확인(위 결함 1·2, 환경 패널 온도 ⌘Z, 일시정지 중 3D 영상 갱신).
- 현재 `ThongpariFlyNeuronSim`와 `dist/` 앱은 위 두 수정 **이전** 빌드다.
- 미실행: `--simtest`/`--behaviortest`/`--gpucheck`(뇌·셰이더 변경 없음), bridgeloop 성능(AC 전원 필요, 현재 배터리).
