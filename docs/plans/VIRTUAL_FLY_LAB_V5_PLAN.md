# Virtual Fly Lab V5 — 통합 Viewer와 세계 안의 사용자

작성: 2026-09-13 · 상태: **V5.1–V5.5 구현 / V5.5.1 완료(2026-09-26) / V5.6 착수 준비 완료, 구현 전**

2026-09-23 추가: V5.6 전에 [V5.5.1 단일 창 사용 경험 계획](VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md)을 수행한다. 기존 V5.5의 미완료 결함과 GUI 인수 항목도 이 계획의 선행 조건이다.

착수 기준: V4 completion commit `e900b27` (`Complete Virtual Fly Lab V4 deterministic sessions`). V5 준비는 `3faf942` (`Prepare Virtual Fly Lab V5 implementation`)에 커밋됐다. 구현 진행표와 V5.1 검증 상태는 [`../reports/V5_PROGRESS.md`](../reports/V5_PROGRESS.md)에 기록한다.

선행: **V4 완료 후에만 착수**. 병렬로 다음 버전 기능을 구현하거나 버전 순서를 바꾸지 않는다.

[전체 순서](VIRTUAL_FLY_LAB_ROADMAP.md) · [공통 사용자 경험·계약](INTERACTIVE_FLY_SANDBOX_PLAN.md) · [공통 실행·검증 규칙](IMPLEMENTATION_PLAYBOOK.md)

## 1. 이번 버전의 단 하나의 결과

사용자가 1인칭으로 시뮬레이션 공간 안에 들어가 파리와 같은 물리 세계에서 상호작용한다.

## 2. 시작 전 반드시 확인할 것

V4 시간·pause·epoch 검증과 완료 보고서가 있어야 한다. 이 조건은 `e900b27`에서 충족됐다. 현재 LabWindow 2D 배치 화면과 MuJoCo viewer가 별개라는 기준을 확인한다.

1. 저장소 루트에서 git status와 이전 버전 완료 보고서를 읽는다. 미커밋 사용자 변경을 보존한다.
2. 이전 보고서의 자동 검증/real backend/GUI 검증을 따로 확인한다. 실패를 무시하고 진행하지 않는다.
3. 아래 신규 파일은 설계 후보다. 같은 책임의 파일이 이미 있으면 그것을 확장하고 중복 구현하지 않는다.
4. API는 현재 설치 source로 확인한다. 아래 타입명은 새 계약 제안이며 이미 존재하는 심볼로 가정하지 않는다.

## 3. 수정할 파일과 책임

| 파일 | 책임 |
|---|---|
| `LabWindow.swift` | 기존 컨트롤을 재사용한 통합 shell, 모드 전환 및 선택 상태 |
| `WorldViewer.swift (신규)` | 권위 world snapshot 렌더, picking, 카메라; physics 상태를 직접 변경하지 않음 |
| `PlayerController.swift (신규)` | 키 입력·포커스·avatar 이동 command 생성 |
| `WorldInteraction.swift (신규)` | 선택/집기/놓기/접근 도구의 상태 머신 |
| `flygym_bridge/player_body.py (신규)` | 참여체 geometry와 physics-owner 측 이동 적용 |
| `flygym_bridge/fly_body.py, LabProtocol.swift` | player pose/interaction ACK, 동일 world의 eye 가시성 |
| `build.sh` | 실제 추가한 Swift 파일만 빌드 목록에 등록 |

## 4. 데이터 계약 — UI보다 먼저 정의

공통 envelope의 session/epoch/seq/tick과 simulation-owner 규칙을 유지한다. 필수 값 누락/NaN/잘못된 배열 길이는 실패해야 한다. optional telemetry와 필수 control 필드의 허용 정책을 구분한다.

### PlayerPose

actor_id 문자열, position_mm[3], orientation_quat_xyzw[4], collision_radius_mm, mode. quaternion은 유한값과 정규화 검사. 카메라 pose와 별도 저장.

### PlayerInput

actor_id, session_id, epoch, seq, requested_tick, move_axes[-1,1], look_delta, held_actions. 이동속도는 mm/s로 변환; render FPS로 거리를 누적하지 않음.

### InteractionCommand

event_id, tool_id, actor_id, target_id 또는 null, ray_origin/direction, requested_tick. 실제 hit와 접촉 결과는 backend가 결정.

### WorldRenderSnapshot

session/epoch/tick, object IDs/pose/geometry revision, player pose, fly pose. immutable snapshot과 version/hash로 update.

## 5. 구현 순서 — 위에서 아래로 실행

각 단계는 해당 출력과 검사 증거를 만든 후 다음 단계로 넘어간다. 전체 파일을 한 번에 새로 쓰는 방식은 피한다.

### 5.1. 현재 API 조사 및 viewport 실험

**할 일:** 설치된 MuJoCo/FlyGym source에서 렌더·depth/picking·eye scene 연결을 확인한다. 기존 viewer 확장과 native viewport를 최소 장면으로 비교하고 선택 근거를 남긴다. 지원하지 않는 embedding API를 추측해 쓰지 않는다.

**준비 단계 확인:** 설치된 MuJoCo 3.9.0에는 offscreen `Renderer`, depth rendering, `mj_ray`, `mjv_select`가 있다. macOS `launch_passive`는 설치 source상 `mjpython` UI thread의 별도 Simulate GUI이며 AppKit host view/window를 받는 공개 embedding 인자는 확인되지 않았다. 따라서 첫 prototype은 AppKit-native SceneKit snapshot mirror와 MuJoCo offscreen renderer를 실제 scene으로 비교하고, passive viewer는 동일 backend 시각 대조로 유지한다. 상세 근거는 `V5_PROGRESS.md`에 있다.

**완료 출력:** 렌더 선택 문서: 같은 geometry가 화면/충돌/눈에 반영되고 키보드 입력을 받을 수 있다는 실행 증거.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.1` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 5.2. 공통 화면 상태 소유권

**할 일:** LabWindow에 선택 파리·객체·모드·timeline tick을 하나의 view state로 둔다. 중앙 world, 접이식 도구/활동 패널을 조합한다. 기존 진단 창은 유지해 회귀 비교한다.

**완료 출력:** 여러 패널의 선택과 pause 표시가 동일하다.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.2` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 5.3. 관찰 카메라 먼저 구현

**할 일:** orbit/추적/free camera를 만들고 카메라 입력이 neural/world command를 생성하지 않음을 테스트한다. actual eye 영상에는 sample tick을 붙인다.

**완료 출력:** 관찰 이동 전후 simulation 입력 로그가 동일하다.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.3` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 5.4. 사용자 참여체 구현

**할 일:** 작은 avatar/probe geometry를 실제 world에 등록한다. V5.4의 실제 구현은 backend-owned **free-joint MuJoCo sphere**이며, FlyGym의 explicit-pair contact 모델에 맞춰 **participant↔fly thorax explicit contact pair**를 compile한다. collision pose와 시각 pose를 같은 physical body source로 업데이트한다. 참여체가 파리 눈 시야에 들어왔는지 actual eye frame으로 확인한다.

**완료 출력:** 단순 camera 이동이 아닌 몸체가 world에 존재한다.

**revision 계약:** 물리 적분으로 계속 변하는 fly/player pose는 `snapshot_seq`와 `sim_tick`으로 식별하며 매 physics step마다 `world_revision`을 올리지 않는다. `world_revision`은 명시적 LabWorld mutation, `structure_revision`은 topology/ray-query 구조 변경을 나타낸다.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.4` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 5.5. 게임 입력 연결

**할 일:** WASD·시선·E·Esc를 명령으로 변환하고 session tick에 적용한다. text field focus에서 키 입력을 이동으로 쓰지 않는다. 키 재매핑을 설정에 저장한다.

**완료 출력:** 포커스 상실/취소 때 held input이 즉시 해제된다.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.5` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 5.6. 집기·놓기 구현

**할 일:** pick ray로 선택 후 backend의 허용 거리/대상 검증을 거친다. grab constraint 또는 kinematic tool의 선택을 명시하고 놓기 시 충돌 관통을 해결한다. 단순 클릭을 감각 접촉으로 변환하지 않는다.

**완료 출력:** 물체가 실제 world에서 움직이고 접촉 tick과 force가 기록된다.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.6` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 5.7. 기존 활동 표시 연결

**할 일:** 기존 arousal/role 값을 읽기 전용 카드로 연결한다. 계산 단위와 모델 지표라는 설명을 붙이고 아직 없는 배고픔은 미지원으로 표시한다.

**완료 출력:** 카드 클릭이 신경 자극을 발생시키지 않는다.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V5.7` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

## 6. 실패·취소·복구

ray miss는 무변경; geometry import/등록 실패는 참여 모드 진입을 취소하고 기존 world 유지. backend stale이면 입력 접수를 제한하고 적용되지 않은 preview를 확정값으로 표시하지 않는다.

공통 규칙: 실패한 명령은 applied로 표시하지 않는다. 이전 정상 파일/세션을 먼저 삭제하지 않는다. timeout은 무한 재시도로 숨기지 않는다. UI는 오류 원인과 재시도 가능한 작업을 보여준다. queue drain/ACK가 완료되지 않으면 saved/paused/detached 성공을 추정하지 않는다.

## 7. 이번 버전에서 만들지 않는 것

새 지형 brush, 외부 모듈, 전체 checkpoint, 새로운 욕구 계산은 구현하지 않는다.

## 8. 검증 시나리오 — 실행과 예상 결과

| ID | 실행 방법 | 합격 조건 |
|---|---|
| V5-01 관찰 무자극 | 고정 seed에서 동일 입력을 주고 카메라만 다르게 움직인다. | neural 입력과 world mutation log가 같음. |
| V5-02 참여체 가시성 | 파리 눈 밖에서 안으로 참여체를 이동하고 actual eye sample과 world pose를 기록한다. | 같은 geometry/pose가 눈 영상에 반영; 특정 도피 행동 강요 없음. |
| V5-03 실제 접촉 | 접촉 없이 가까이 이동한 대조와 실제 접촉 실행을 비교한다. | 접촉 event는 실제 collision에서만 발생. |
| V5-04 포커스 해제 | W를 누른 상태로 text field 클릭, Esc, 창 비활성화를 각각 수행한다. | held input 해제, 재진입 시 예전 이동 재개 없음. |
| V5-05 pause | 이동 중 pause 후 wall time 1초 경과. | world/brain/player tick 정지, 카메라 탐색 가능. |
| V5-06 GUI 전체 | 새 프로세스에서 참여→물체 놓기→접근→활동 확인→관찰 복귀. | 하나의 Viewer 안에서 성공; 실제 화면/로그 증거. |

검사 코드는 이 표의 동작과 실패 조건을 검증해야 한다. 구현의 상수를 복사하여 항상 통과하는 테스트를 만들지 않는다. 실행 명령은 공통 playbook에 따라 구현 후 실제 존재하는 test entry를 기록한다. 아직 만들지 않은 테스트 명령을 이미 실행 가능한 것으로 보고하지 않는다.

## 9. 완료 체크리스트

- [ ] 위 구현 단계와 각 출력이 모두 존재한다.
- [ ] schema/단위/상태 소유권과 실제 코드가 일치한다.
- [ ] 버전별 정상·실패 검사와 필요한 기존 회귀가 실제 exit 0이다.
- [ ] 실제 backend와 새 GUI 프로세스의 사용자 동선을 확인했다. headless를 GUI 검증으로 표시하지 않았다.
- [ ] 저장/기록/큐/모듈 상태를 추가했다면 snapshot/cleanup inventory도 갱신했다.
- [ ] 성능 기준 및 실제 측정, unsupported/제약이 Viewer와 문서에 일치한다.
- [ ] 기존 사용자 변경을 보존했고 실행한 프로세스/시험 자원을 정리했다.
- [ ] `docs/reports/V5_COMPLETION_REPORT.md`에 명령/exit/로그/파일/한계/rollback을 남겼다.

## 10. 다음 버전에 넘길 내용

V6에 viewer 좌표계/selection API, player geometry 계약, input 해제 정책, 실제 eye 검증 fixture를 전달한다.

보고서의 마지막에는 완료한 세부 단계 ID, 남은 결함, 재실행 명령, schema 버전, fixture 경로, 실제 GUI 검증 여부를 적는다. V5의 실패가 있으면 다음 버전은 시작하지 않는다. 연구 근거 부족과 코드 결함을 구별하되, 사용자 목표의 미완료를 숨기지 않는다.
