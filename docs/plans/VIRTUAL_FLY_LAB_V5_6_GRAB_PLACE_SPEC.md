# V5.6 집기·놓기 — 결정과 계약 (2026-09-26, 완료 · GUI 사용자 확인 · 조작감 개선 과제 남음)

상위 계획: [V5 §5.6](VIRTUAL_FLY_LAB_V5_PLAN.md#56-집기놓기-구현) · 준비 메모: [V5_PROGRESS “V5.6 착수 준비”](../reports/V5_PROGRESS.md#v56-착수-준비--2026-09-26)

이 문서는 Python backend와 Swift UI를 따로 구현해도 맞물리도록 **먼저 고정한 계약**이다. 구현하면서 계약을 바꿔야 하면 코드에서 임의로 바꾸지 말고 보고서에 "계약 변경 제안"으로 적는다.

## 1. 결정

| 항목 | 결정 | 이유 |
|---|---|---|
| 운반 방식 | **(a) kinematic 운반.** 잡힌 mocap 물체를 native substep마다 **제한 속도**로 목표점에 옮긴다. 순간이동 금지. | 물체는 컴파일 때 만든 mocap 슬롯이다. free body+weld로 바꾸면 슬롯 구조와 V4 결정론이 크게 흔들린다. F-02와 같은 원칙(substep마다 제한된 변화). |
| 운반 높이 | 잡을 때의 물체 z를 유지하고 **XY만** 움직인다. 놓기는 그 자리에서 해제한다(낙하 없음). | 바닥에 놓인 물체는 계속 바닥에 있다. 중력 없는 kinematic 물체를 떨어뜨리는 흉내를 내지 않는다. |
| 목표점 | 참여체 중심 + 수평 look 방향 × (참여체 반경 + 물체 수평 반폭 + `CARRY_GAP_MM`) | 물체가 참여체 앞에 있고 참여체와 겹치지 않는다. |
| 관통 방지 | mocap은 solver가 밀어내지 못한다. MuJoCo는 mocap↔mocap, mocap↔고정 평면 사이 contact를 **만들지 않는다**(2026-09-26 real 재현). **V5.6.1부터 이동 전 제약:** 매 substep 이동 **전에** 운반 물체와 가까운 LabObject·참여체 사이 `mj_geomDistance`(witness 점 포함)로 수평 법선과 남은 간격을 구하고, 목표점 방향 이동 중 그 표면으로 다가가는 성분을 남은 간격까지만 허용한다(참여체는 `CARRY_GAP_MM`, LabObject는 `CARRY_CONTACT_SKIN_MM`까지). 그래서 물체는 벽을 따라 미끄러지고 참여체 둘레로 돌아가며, 참여체를 밀지 않는다. 목표가 참여체 정반대라 정면으로 막히면 look이 도는 쪽으로 참여체 접선을 따라 돈다. 제약이 한 substep 이동을 절반 미만으로 줄이면 `blocked`(해당 표면 kind)다. 바닥은 수평 이동으로 깊어지지 않으므로 제약에서 뺀다. **안전망(기존 유지):** 이동 뒤 거리 < `-CARRY_PENETRATION_TOL_MM` **이면서 이동 전보다 더 깊어졌을 때만** 그 substep 이동을 되돌리고(`blocked`) 멈춘다. 처음부터 겹쳐 있던 물체는 겹침을 줄이거나 유지하는 방향으로 움직일 수 있다. | 한 substep 최대 이동은 속도×0.1 ms다. 막힌 뒤 방향을 추측하는 방식(직선 추적, 극좌표, 고정 접선 미끄럼)은 각각 참여체를 밀거나(최대 32.5 mm) 벽에 고착됐다(2026-09-26 Codex 리뷰·real 재현). 파리 접촉 사건은 계속 실제 contact(`mj_contactForce`)에서만 만든다. |
| 파리와 접촉 | 파리는 동적 물체라 solver가 밀어낸다(막지 않음). 그러나 FlyGym 파리 geom은 `contype=conaffinity=0`이고 **명시 contact pair만** 쓴다. 따라서 운반 가능한 충돌 슬롯(box/sphere/wall) geom과 파리 몸통 geom(thorax, 가능하면 head/abdomen) 사이 **명시 pair를 컴파일 전에 추가**한다. | V5.4 참여체와 같은 방식. 없으면 운반 물체가 파리를 그냥 통과한다(현재 LabObject 전부가 그렇다). |
| 성능 확인 | pair 추가 전후 real body의 sim_per_wall(또는 quantum 처리 시간)을 같은 조건에서 측정해 보고한다. 20% 넘게 느려지면 thorax 전용으로 줄이고 그 사실을 보고한다. | 8 GB M2, body Hz가 이미 빠듯하다. |
| 허용 거리 | `INTERACTION_REACH_MM = 12.0` (참여체 중심 → backend ray hit 지점). 잠정값이며 real 측정 뒤 조정 가능. | 참여체 반경 2.5 mm의 약 5배. |
| ray 출발점 검증 | ray 원점이 참여체 중심에서 `2 × 참여체 반경` 이내여야 한다. | 3인칭/관찰 카메라에서 먼 물체를 잡는 우회를 막는다. |
| 대상 | `lab_object`(box/sphere/wall/food)만. `fly`·`world`·`player`·miss는 거절. food는 옮길 수 있으나 충돌하지 않으므로 접촉 기록이 없다. | 준비 메모 2항. |
| 한 번에 하나 | 참여체당 최대 1개. 잡고 있으면 grab 거절, 없으면 place 거절. | |

## 2. 상수 (Python `flygym_bridge/interaction.py`에 정의, Swift는 표시용으로만 사용)

```
INTERACTION_REACH_MM = 12.0
INTERACTION_RAY_ORIGIN_TOL_FACTOR = 2.0   # × player radius
CARRY_SPEED_MM_S = 40.0                   # > PLAYER_MOVE_SPEED_MM_S(30) so the object keeps up
CARRY_GAP_MM = 0.5
CARRY_PENETRATION_TOL_MM = 0.05
CARRY_CONTACT_SKIN_MM = 0.005             # V5.6.1: stop short of LabObjects (normal undefined at 0)
```

## 3. Wire 계약 — InteractionCommand (Swift → Python)

기존 **LabCommand 파이프라인**을 그대로 쓴다. 새 큐를 만들지 않는다. 그래서 session/epoch/requested_tick/idempotency(`(session_id, epoch, seq)` 캐시)/pause 장벽/ACK는 기존 규칙을 그대로 따른다. `event_id`는 LabCommand `id`(Python `seq`)다.

평평한(flat) Swift `LabCommand` 필드:

| 필드 | 타입 | 규칙 |
|---|---|---|
| `action` | `"interaction"` | 고정 |
| `id` | Int | event_id. 기존 단조 증가 lab id |
| `tool_id` | `"grab"` \| `"place"` | 필수. 다른 값 거절 |
| `actor_id` | String | 필수. backend 참여체 id(`"player"`)와 같아야 함 |
| `target` | String 또는 생략 | grab: 클라이언트가 본 대상 id 힌트(없으면 생략). 있으면 backend hit와 같아야 함. place: 생략하거나 잡고 있는 id와 같아야 함 |
| `ray_origin_mm` | [Double;3] | grab 필수, 유한값. place에서는 **없어야** 함 |
| `ray_direction` | [Double;3] | grab 필수, 유한·비영(0 아님). backend가 정규화. place에서는 **없어야** 함 |
| `protocol_version`,`session_id`,`epoch`,`requested_tick` | | 기존 lab 명령과 동일한 V4 envelope (`coordinator.labCommandSchedule()`) |

Python `LabCommand.from_dict`는 알 수 없는 top-level 필드를 `args`로 합치고 `target`을 `args["id"]`로 옮긴다. `interaction.py`의 **엄격 파서**가 `args`에서 위 규칙을 검사한다. 누락·NaN·Inf·길이 오류·알 수 없는 tool·place에 ray 포함은 모두 `ValueError` → 기존 경로로 `ok:false` lab_state ACK.

## 4. 결과 ACK와 상태

결과는 기존 `lab_state` ACK(`ack`=event_id, `ok`, `error`, `status`, `applied_tick`, `applied_epoch`)다. 실패 시 `error`는 아래 **코드 문자열로 시작**한다(뒤에 `: 상세` 가능).

| 코드 | 의미 |
|---|---|
| `invalid_interaction` | 스키마 위반 |
| `not_participating` | 참여체 비활성 |
| `wrong_actor` | actor_id 불일치 |
| `ray_origin_not_at_participant` | 원점이 참여체에서 너무 멂 |
| `ray_miss` | backend ray가 아무것도 맞히지 않음 |
| `unsupported_target` | hit가 lab_object가 아님 (`: fly` 등 kind 부기) |
| `out_of_reach` | 거리 > REACH (`: 17.3mm` 부기) |
| `target_mismatch` | 클라이언트 target 힌트 ≠ backend hit / 잡은 물체 |
| `already_holding` | grab인데 이미 잡고 있음 |
| `not_holding` | place인데 잡은 게 없음 |

`lab_state.state["interaction"]` (항상 존재; Python `LabStatePacket.to_dict`는 이것을 top-level `interaction`에도 복사):

```json
{
  "held_object_id": "box_1" | null,
  "actor_id": "player",
  "carry_blocked": false,
  "reach_mm": 12.0,
  "carry_speed_mm_s": 40.0,
  "mode": "kinematic_carry",
  "last": {"event_id": 7, "tool_id": "grab", "ok": true, "code": null,
           "target_id": "box_1", "hit_distance_mm": 6.2} | null
}
```

Swift는 top-level `interaction`을 **선택적(optional)** 으로 엄격 decode한다: 있으면 `held_object_id`(String|null), `carry_blocked`(Bool), `reach_mm`(유한 >0) 필수. 없으면(옛 backend) 집기 UI를 비활성화한다.

## 5. 사건(lab_event)

`LabWorld.events`로 내보내며 bridge의 기존 `lab_event` 경로를 탄다. 모든 사건에 `classification: "PHYSICAL"`과 **`sim_tick_ms`**(사건이 생긴 substep의 protocol-ms 시뮬레이션 시각, 정수)를 붙인다.

| event | data |
|---|---|
| `object_grabbed` | `id`, `actor_id`, `hit_distance_mm` |
| `object_placed` | `id`, `actor_id`, `position_mm`, `reason`(`"place"`,`"participant_inactive"`,`"object_removed"`,`"world_reset"`,`"body_reset"`,`"disconnect"`) |
| `carry_blocked` / `carry_unblocked` | `id`, `blocking_geom_kind`(`"ground"`,`"lab_object"`,`"player"`) — 상태가 바뀔 때만 1회 |
| `object_contact_begin` | `id`, `fly_segment`(예 `"thorax"`), `sim_tick_ms`, `normal_force` |
| `object_contact_end` | `id`, `fly_segment`, `sim_tick_ms`, `peak_normal_force`, `duration_ms` |

- 접촉은 **실제 MuJoCo contact**(명시 pair)에서만 생긴다. 힘은 `mujoco.mj_contactForce`의 법선 성분이며 단위는 MuJoCo 모델 단위(`force_units: "mujoco_model"`)로 표시한다. N으로 환산했다고 주장하지 않는다.
- begin/end만 보낸다(substep마다 보내지 않음). 사건 큐는 기존대로 `MAX_EVENTS`로 제한된다.
- 운반하지 않는 물체의 접촉도 같은 pair로 생기면 똑같이 기록한다(단순 클릭이 접촉이 되는 경로는 없다).

## 6. 수명 주기

자동 해제(`object_placed` + reason): 참여체 비활성화, 잡은 물체 삭제, `reset_world`, `reset_body`/sim reset, 전송 끊김(bridge가 참여체를 비활성화하는 기존 경로). resize/move_object로 잡은 물체를 바꾸는 명령은 **거절**하지 않고 적용하되 운반은 새 위치에서 이어간다(기존 lab 명령 의미 보존). pause 중에는 physics가 멈추므로 운반도 멈춘다.

## 7. Mock body

MockBody는 MuJoCo가 없다. 계약·UI 시험용으로만 **해석적 ray–경계구**(물체 중심, 반경 = 크기 최대값/2) 교차를 쓰고, 운반은 같은 제한 속도로 XY 이동, 관통 검사·파리 접촉은 **하지 않는다**(state에 `"mode": "mock_kinematic_carry"`). 이것을 실제 물리 검증으로 보고하지 않는다.

## 8. 파일 소유 (병렬 구현)

| 담당 | 파일 |
|---|---|
| Python backend | `flygym_bridge/interaction.py`(신규), `lab_world.py`, `fly_body.py`, `protocol.py`(LabStatePacket interaction 복사만), `bridge.py`(필요 최소), `player_body.py`(읽기 위주), `test_v5_6.py`(신규, mock/계약), `test_interaction_real.py`(신규, real MuJoCo) |
| Swift UI | `LabProtocol.swift`, `FlyGymBridge.swift`, `FlyGymPackets.swift`, `PlayerController.swift`, `WorldViewer.swift`, `LabWindow.swift`, `LabViewState.swift`, `LabLocalization.swift`, `BridgeDiagnostics.swift`, `main.swift`(테스트 진입만), `build.sh`(새 파일일 때만) |
| 통합(부모) | 문서, TCP 통합 시험, GUI 인수 |

## 9. 합격 기준 (V5.6 행)

- Python mock/계약: 스키마 거절 fixture 전부, 거절 코드별 1건 이상, 중복 event_id 재전송이 한 번만 적용.
- Real MuJoCo: 잡기 성공 / 거리 초과 거절 / fly·world 대상 거절 / 운반 중 벽 관통 ≤ `CARRY_PENETRATION_TOL_MM` + 1 substep 이동 / 운반 속도 ≤ `CARRY_SPEED_MM_S`(+수치오차) / 운반 물체가 파리에 닿으면 `object_contact_begin`(실제 contact) / **대조군**: 파리 바로 옆까지만 옮기면 접촉 사건 없음 / 놓은 뒤 물체 정지 / 참여체 비활성 시 자동 해제 / pair 추가 전후 성능 수치.
- Swift: InteractionCommand 인코딩(grab/place), interaction 상태 엄격 decode + 옛 backend(필드 없음) 대조, E 한 번 = 명령 한 번(key repeat 무시), 텍스트 필드 포커스에서 E 무시, 비참여 상태 E 무시, pending→ACK 표시.
- 기존 회귀: `--bridgetest --labtest --v4test --v4timingtest --simtest --behaviortest --gpucheck`, Python `test_v5 test_v4 test_lab test_bridge test_player_collision_real test_lab_real`.
- GUI 인수(부모, 사용자 확인 후): 참여 → 물체 잡기 → 파리 쪽 운반 → 놓기 → 접촉 사건 확인.
