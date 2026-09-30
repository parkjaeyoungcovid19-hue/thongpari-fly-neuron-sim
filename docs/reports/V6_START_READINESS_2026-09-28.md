# SiliconFly Virtual Fly Lab V6 착수 준비도 보고서

작성: 2026-09-28 · 범위: 읽기 전용 코드·문서 조사 · 판정: **V6 착수 보류**

## 요약 및 결정

V6 계획서 자체가 V5 완료 후 착수를 조건으로 한다. 현재 V5 진행표는 V5.6.2와 V5.7의 GUI 인수 확인을 대기 중으로 기록하므로 선행 gate가 통과했다고 볼 근거가 없다. V6 구현, 빌드, 소켓 통신 또는 무거운 시험은 이 조사에서 수행하지 않았다. 다음 결정은 V5 GUI acceptance를 완료하고 실제 증거를 진행표/완료 보고서에 남기는 것이다. (근거: `docs/plans/VIRTUAL_FLY_LAB_V6_PLAN.md:5,13-19`; `docs/reports/V5_PROGRESS.md:32-45`.)

V6는 현재의 객체 조작·바람·온도 명령을 새로 만드는 버전이라기보다, 이들을 capability/descriptor로 노출하고 revision-aware 편집·일관된 ACK·저장 가능한 scene 설정으로 묶는 버전이어야 한다. V5.6.2가 이미 제공하는 잔디밭 외관, 파리 색, 6종 음식, 섭식/당 감각, 자동차·함정·비비탄총은 재구현 대상이 아니라 기존 source와의 통합 대상으로 재정의해야 한다. 설치된 MuJoCo가 heightfield 및 recompile API를 제공한다는 사실만으로 현재 FlyGym Simulation의 실시간 topology 변경이 안전하다고 결론내릴 수는 없다.

## 현재 제어 경로와 권위 경계

| 구간 | 확인된 현행 동작 |
|---|---|
| UI | `LabWindow.swift:1447-1567`에서 객체 생성·이동·크기·삭제, 온도, 바람, 감각/물리 옵션을 입력한다. `:1976-1995,2128-2173`에서 명령 payload를 구성한다. |
| 전송/스케줄 | `LabWindow.swift:1836-1875`가 V4 session/epoch/requested tick envelope를 붙여 bridge로 보낸다. `FlyGymBridge.swift:690-727`는 단조 ID와 bounded queue를 쓰며 V4 queue-full을 명시적으로 ACK한다. |
| Python decode/queue | `flygym_bridge/protocol.py:43-55,1110-1205,1219-1239,1348-1404`에서 검증·정규화 후 discrete bounded FIFO와 continuous latest-wins 슬롯으로 분리한다. |
| owner 적용/ACK | `flygym_bridge/bridge.py:446-517`가 simulation-owner 경계에서 drain하고 session/epoch/future tick/dedupe를 검증한다. 성공 ACK는 applied tick/epoch, 실패는 rejected를 남긴다. `:972-979,1012-1014`의 주기적 state heartbeat는 약 0.5초다. |
| 세계/물리 상태 | `flygym_bridge/lab_world.py:259-414`에서 고정 mocap 슬롯을 compile 전에 설치한다. `:607-739,1211-1354`가 기존 객체 명령을 적용하고, `:2011-2050`에서 world state를 노출한다. |
| 확인 화면 | `LabWindow.swift:2541-2573,2661-2703`가 ACK 상태와 render snapshot을 UI에 반영한다. `LabProtocol.swift:411-434,559-579`에는 ACK tick 필드와 object 중심 remote world state가 있으나 generic 환경 descriptor/property 모델은 없다. |

따라서 V6 계약은 이 소유권·스케줄·ACK 경계를 보존해야 한다. UI preview를 applied 상태로 표시하지 말고, 실제 적용값/revision/tick을 backend 권위로 돌려줘야 한다. 연속 명령의 최신값 우선 동작도 discrete 명령의 무손실 FIFO 의미와 섞지 않아야 한다.

## V6 단계별 현황 및 착수 기준

| 계획 단계 | 기준 문서의 목표 | 현황 판단 | 다음 단계로 넘어가기 전 증거 |
|---|---|---|---|
| V6.1 inventory | 현 op/UI 필드/숨은 값과 descriptor 대응 | 현황 조사 자료는 확보했으나 descriptor 결과물·정상/실패 대조 증거는 없음 | 모든 지원 속성의 ID·타입·단위·범위·scope·apply mode·effect·persistence 표, 경계 및 무변경 사례 |
| V6.2 validation | Swift/Python decode 일치, NaN·단위·unknown 거부 | generic descriptor/EditCommand contract 확인 안 됨 | 유효/경계/NaN/단위/unknown fixture, 실패 시 world revision 불변 |
| V6.3 selection/gizmo | 선택·이동/회전/크기 handle, 수치 편집 | 숫자 입력 기반 create/move/resize/delete는 존재. 선택 outline/gizmo 대조 검증은 미확인 | 같은 목표 pose에 대한 수치 입력 대 gizmo와 world mm/축 규칙 일치 |
| V6.4 primitives | box/wall/sphere/경사, 슬롯 초과 설명 | 고정 슬롯과 일부 primitive 조작은 존재. 회전 경사와 재사용 가능한 descriptor는 미확인 | 슬롯 예산·실패 메시지, render/collision pose·size 일치 |
| V6.5 environment | 온도/바람/light/source, 적용값과 preview 구분 | 온도와 바람의 기존 backend 경로 존재. 일반 property 패널/적용값 분리는 없음. Viewer 광원은 정적 SceneKit 조명 | 실제 backend sample·감각 경로 및 pending/applied UI를 분리 검증 |
| V6.6 transaction/undo | coalesce, pause 중 step 없는 edit, 설정 undo | revision-aware transaction/undo 확인 안 됨 | stale revision 거부, pause edit가 neural tick을 진행시키지 않음, undo는 설정만 복원 |
| V6.7 scene 저장/reload | schema/hash, staging, barrier, atomic swap | `.flyworld` schema와 staging/load 경로 확인 안 됨 | 손상 import 무변경, 새 프로세스 roundtrip, 정상 world 보존 |

단계의 완료 증거는 계획서에 정의된 대로 각 단계에서 정상·실패/무변경 사례를 실제 수행해 기록해야 한다. 단계 간 동시 구현보다 순차 gate를 따른다. (계획 근거: `docs/plans/VIRTUAL_FLY_LAB_V6_PLAN.md:57-111,123-145`.)

## 기존 기능과 낡거나 중복된 계획 문구

- V6 목표의 “먹이”는 신규 음식·먹이 상호작용 구현을 뜻하지 않도록 해야 한다. V5.6.2 사양에 음식 6종, 섭식, 당 감각 경로 및 관련 장난감이 포함되어 있으므로 V6의 범위는 기존 값·상태를 descriptor/property inspector와 scene 설정에 통합하는 것으로 좁히는 것이 적절하다. (근거: `docs/plans/VIRTUAL_FLY_LAB_V5_6_2_SANDBOX_SPEC.md:1-13,37-60,62-85`.)
- 계획의 “잔디밭/빛/먹이”를 한데 묶으면 이미 있는 renderer 외관, 실제 collision, 관찰용 조명, backend 환경 제어가 같은 기능처럼 읽힌다. V5.6.2의 잔디밭은 plane collision을 바꾸지 않는 외관이며, `WorldViewer.swift:303-316`의 SceneKit directional/ambient light는 backend/MuJoCo 광원 제어와 별개다. 계획은 각각의 소유자와 효과를 분리해야 한다.
- V6 계획은 “기존 온도/바람/빛 source 재사용”이라고 하지만 현재 확인된 광원은 Viewer의 정적 조명이다. 검색으로 사용자가 바꿀 MuJoCo light API 연결 경로는 확인되지 않았다. 따라서 light 편집을 기존 source 재사용으로 단정하지 말고, V6에서 어떤 렌더러/효과를 조작하는지 먼저 결정해야 한다.
- 공통 sandbox 계획의 일부 inventory 문구는 V5.6.2 이후 상태를 반영하지 않을 수 있다. 특히 섭식/감각·바람 관련 항목은 현재 코드와 재대조한 뒤 중복 설명을 정리해야 한다.
- `lab_world.py:69-71`에는 섭식/미각 부재 취지의 오래된 주석이 있으나 실제 구현은 `:1743-1818`에서 섭식과 관련 event를 처리한다. 문서·주석을 근거로 구현 부재를 추정하지 말고 현행 동작을 기준으로 inventory해야 한다.
- 계획의 descriptor, `EditCommand`, `SceneSettings`, `UndoEntry`는 제안 계약이며 현재 실행 코드에서 구현된 심볼로 간주할 수 없다. 계획서도 새 계약 후보라고 명시한다. (근거: `docs/plans/VIRTUAL_FLY_LAB_V6_PLAN.md:19,33-51`.)

## 현재 환경 값·고정 예산

| 항목 | 현재 근거와 의미 |
|---|---|
| 객체 수용량 | compile 전 mocap 슬롯: box 64, sphere 64, wall 64, food 32, car 8, trap 4. topology를 실행 중 무제한 추가할 수 있다고 가정하지 말고 capacity와 실패 이유를 노출해야 한다. (`flygym_bridge/lab_world.py:68-84,357-414`.) |
| 온도 | backend 범위 0–50°C, 세 모드 `environment_only`(값 기록, 직접 감각 신호 없음), `modeled_physiology`(기존 physiology 경로), `flywire_sensory`(TRN_VP2 및 TRN_VP3a/b 감각 drive). UI 및 `main.swift` 경로는 10–40°C로 clamp한다. (`lab_world.py:1193-1209`; `LabWindow.swift:2163-2173`; `main.swift:724-737`.) |
| 바람 | normalized strength 0–1; 방향(deg), duration/continuous, physical force와 sensory flag는 별도 제어다. 물리력은 thorax에 질량×가속도 형태로 적용되며, sensory 경로는 body packet과 Swift 측 변환을 거친다. (`lab_world.py:1116-1139,1720-1725`; `fly_body.py:126-145,555-582`; `main.swift:949-966`.) |
| 빛 | Viewer SceneKit에는 정적 directional/ambient light가 있다. 이를 파리의 MuJoCo 눈 렌더 조건이나 scene property로 같은 취급하지 않는다. (`WorldViewer.swift:303-316`.) |
| 외관/먹이 | V5.6.2에 잔디밭 외관, 색상, 음식·섭식·당 감각, toys가 기록되어 있다. collision이나 neural effect가 없는 외관 값을 생물물리 효과로 표현하지 않도록 한다. |

## 설치 API 사전 조사와 한계

설치 환경은 FlyGym 2.1.0, MuJoCo 3.9.0으로 확인했다. FlyGym의 `FlatGroundWorld`는 `mjcf_root.worldbody.add_geom`으로 지면 plane을 추가하며, base world가 `mj.MjSpec()` 및 `mjcf_root`를 제공한다. MuJoCo `MjSpec`에는 `add_hfield`, `mjtGeom.mjGEOM_HFIELD`, `recompile` API가 있다. 확인 근거는 설치 파일 `flygym-venv/lib/python3.12/site-packages/flygym/compose/world/flat_ground.py:9-59`, `.../base_world.py:60-78` 및 설치된 MuJoCo API 문서/enum이다.

**미검증:** 이 조사에서는 MjSpec에 hfield를 추가하거나 `recompile`을 호출하지 않았다. FlyGym Simulation, LabWorld의 고정 mocap 슬롯, 기존 qpos/qvel·접촉·감각 상태 보존, 실패 rollback과 조합했을 때 runtime 재컴파일이 안전한지는 확인되지 않았다. V6.1–6.7의 mesh/heightfield 제외 결정은 유지하고, 사용자가 편집하는 지형 확장이 필요하면 별도 설계 및 isolation된 prototype/rollback 검증을 먼저 gate로 둔다. API가 있다는 사실을 production readiness 증거로 삼지 않는다.

## 순차 검증, 회귀 gate 및 음성 대조

각 단계는 **계약/fixture → 제한된 단위·프로토콜 검사 → fresh test-owned real backend → GUI acceptance** 순으로 증거를 남기고, 실패/timeout은 통과로 해석하지 않는다. 기존 진행 규칙도 자동 검사, 실제 backend, GUI 인수를 서로 대체 불가한 gate로 구분한다. (`docs/plans/IMPLEMENTATION_PLAYBOOK.md:62-73,83-121`; `docs/plans/VIRTUAL_FLY_LAB_ROADMAP.md:58-64`.)

1. **V6.1–6.2 계약 gate:** descriptor 정상·최소/최대·NaN·무한대·범위 초과·단위 불일치·unknown property. 모든 거부 케이스에서 object/environment revision과 simulation tick이 불변인지 확인한다. Swift와 Python decode 결과를 동일 fixture로 비교한다.
2. **V6.3–6.4 geometry gate:** 숫자 입력과 gizmo가 같은 월드 좌표·축·크기/회전을 산출하는지 대조한다. render pose만 보지 말고 실제 collision/접촉을 확인한다. 슬롯 꽉 참, 중복 ID, stale revision은 거부되고 기존 world가 변하지 않아야 한다.
3. **V6.5 environment gate:** temperature 세 모드의 구분, 범위 경계, wind normalized 값·방향·duration/continuous, force/sensory 독립 조합을 각각 확인한다. 마지막 ACK 실제값이 UI에 표시되는지, heartbeat 지연 중 preview가 applied처럼 보이지 않는지 확인한다. 조명은 SceneKit-only 효과와 backend/MuJoCo 효과를 별도 관찰한다.
4. **V6.6 transaction gate:** discrete 명령 FIFO와 continuous latest-wins를 각각 포화시키고 queue-full/ACK ordering을 확인한다. 빠른 연속 입력 후 최종 ACK만 최종 적용 상태로 취급한다. pause 중 편집 전후 neural sim tick이 그대로인지, undo 뒤 tick이 과거로 가지 않는지 검증한다. stale revision 명령이 최신 상태를 조용히 덮지 않는지 확인한다.
5. **V6.7 persistence gate:** 정상 scene 새 프로세스 roundtrip 및 schema/hash mismatch, 손상 파일, 중복 ID, 잘못된 단위, 잘못된 spawn을 음성 대조한다. 실패 import에서 원본 scene·session이 유지되는지 확인하고, 저장은 설정이지 neural checkpoint가 아님을 UI와 파일 형식에서 명확히 한다.
6. **최종 GUI gate:** 계획서 V6-06에 해당하는 GUI-only 벽/경사/먹이/온도/바람 편집·저장·재시작·load를 실제 새 GUI 프로세스에서 수행한다. headless 테스트나 빌드만으로 GUI 인수를 표시하지 않는다.

8GB M2 Air에서는 139k-neuron Metal simulation, FlyGym/MuJoCo whole-body physics, eye/render 작업, SceneKit Viewer가 자원을 공유한다. 한꺼번에 모든 부하를 켜지 말고 V6.3 geometry, V6.5 환경, V6.7 roundtrip 각 gate에서 baseline 대비 FPS, ACK 지연, simulation tick 지연, 메모리 압력을 별도로 측정한다. 결정성은 같은 seed/session 조건에서 입력 순서와 applied tick, 최종 authoritative state를 기록해 비교한다. 이 문서에서는 해당 부하 측정이나 테스트를 실행하지 않았으므로 수치 기준은 기존 코드/계획에서 확정된 값처럼 제시하지 않는다. 기존 V5 자원·회귀 작업과 겹치지 않도록 V5 gate 종료 후 test-owned 프로세스만 사용한다.

## 첫 선행 결정 및 권장 기본값

**첫 결정:** V6 편집 가능한 속성의 권위 상태와 effect scope를 하나의 descriptor manifest로 정하고, “어떤 상태를 편집·저장하는가”를 geometry / environment / renderer appearance로 분리한다. UI보다 이 계약과 inventory를 먼저 승인한다.

**권장 기본값:**
- V6.1 범위는 현재 지원되는 객체·온도·바람 및 실제로 조작 가능한 외관 값만 포함하고, MuJoCo light/heightfield는 효과와 rollback이 입증될 때까지 `unsupported / deferred`로 둔다.
- `apply_mode`는 기존 topology 변경이 없는 값은 live로, compile 영향이 확인된 변경만 별도 재compile 범주로 지정한다. dynamic recompile을 기본 경로로 만들지 않는다.
- 각 변경은 현재 V4 envelope를 유지하고 `expected_revision`이 맞을 때 simulation-owner에서 적용한다. ACK에는 실제 적용값, revision, applied tick을 담고 거부는 world 불변이어야 한다.
- 저장은 geometry/environment/appearance 설정만 담는 `.flyworld` schema version 1 후보로 시작하며, neural state/session checkpoint와 명확히 구분한다. load는 staging·검증을 통과한 뒤 barrier에서 swap한다.
- 선택·수치 입력을 먼저 완성하고 gizmo는 동등성 검증 뒤 붙인다. 편집은 undo 가능한 설정 변경이지 simulation rewind가 아니다.

## 제한 및 출처

코드/계획/설치 API를 읽기 전용으로 조사했으며 코드 수정, 문서 저장, 빌드, socket, 테스트 실행은 하지 않았다. V5.6.2 진행표의 GUI gate 및 dirty worktree 내용은 기준 시점 문서만으로 확인했고, 미확인 GUI 결과를 통과로 추정하지 않는다. 현재 진행 현황은 `docs/reports/V5_PROGRESS.md`와 저장소 roadmap을 다시 확인해 갱신해야 한다.

주요 기준 문서: `docs/plans/VIRTUAL_FLY_LAB_V6_PLAN.md`; `docs/plans/VIRTUAL_FLY_LAB_ROADMAP.md`; `docs/plans/INTERACTIVE_FLY_SANDBOX_PLAN.md`; `docs/plans/IMPLEMENTATION_PLAYBOOK.md`; `docs/reports/V5_PROGRESS.md`; `docs/plans/VIRTUAL_FLY_LAB_V5_6_2_SANDBOX_SPEC.md`.
