# Virtual Fly Lab V6 — Viewer 환경·지형 편집 기본판

작성: 2026-09-13 · 갱신: 2026-10-05 · 상태: **V6.1 착수, 전체 V6 미완료**

기본 선행: **V5 완료 후에 착수**. **2026-10-05 사용자 예외:** “일단 그거는 미루고 다음단계 ㄱㄱ” 요청으로 V5 GUI·live 성능 수용 검증을 보류하고 V6.1부터 진행한다. V5 완료·GUI PASS로 해석하지 않으며 미검증 게이트를 유지한다. 세부 구현 순서는 그대로 지킨다. [V6 진행표](../reports/V6_PROGRESS.md).

[전체 순서](VIRTUAL_FLY_LAB_ROADMAP.md) · [공통 사용자 경험·계약](INTERACTIVE_FLY_SANDBOX_PLAN.md) · [공통 실행·검증 규칙](IMPLEMENTATION_PLAYBOOK.md)

## 1. 이번 버전의 단 하나의 결과

숫자 파일이나 터미널 없이 기본 지형지물·온도·바람·빛·먹이를 편집하고 세계 설정을 저장한다.

## 2. 시작 전 반드시 확인할 것

기본 진입 조건은 V5 참여/관찰/편집 동선과 실제 collision/eye 가시성 검증 완료다. 2026-10-05 사용자 예외로 V5 GUI/live 수용을 보류하고 V6.1만 선행한다(위 기록). 이 예외는 V5나 전체 V6 완료를 뜻하지 않는다.

1. 저장소 루트에서 git status와 이전 버전 완료 보고서를 읽는다. 미커밋 사용자 변경을 보존한다.
2. 이전 보고서의 자동 검증/real backend/GUI 검증을 따로 확인한다. 실패를 무시하고 진행하지 않는다.
3. 아래 신규 파일은 설계 후보다. 같은 책임의 파일이 이미 있으면 그것을 확장하고 중복 구현하지 않는다.
4. API는 현재 설치 source로 확인한다. 아래 타입명은 새 계약 제안이며 이미 존재하는 심볼로 가정하지 않는다.

## 3. 수정할 파일과 책임

| 파일 | 책임 |
|---|---|
| `EnvironmentProperty.swift (신규)` | 지원 속성 descriptor와 validation |
| `WorldEditor.swift (신규)` | gizmo/수치 입력/undo command 관리 |
| `LabWindow.swift, WorldViewer.swift` | 객체 tree, 속성 inspector, 적용 상태, minimap |
| `LabProtocol.swift, flygym_bridge/protocol.py` | object revision, requested/applied 값과 tick |
| `flygym_bridge/lab_world.py` | primitive 조작 및 기존 온도/바람/빛 source 재사용 |
| `WorldSceneStore.swift (신규)` | scene 설정 atomic export/import; neural state 저장 아님 |

## 4. 데이터 계약 — UI보다 먼저 정의

공통 envelope의 session/epoch/seq/tick과 simulation-owner 규칙을 유지한다. 필수 값 누락/NaN/잘못된 배열 길이는 실패해야 한다. optional telemetry와 필수 control 필드의 허용 정책을 구분한다.

### EnvironmentPropertyDescriptor

property_id, label, value_type, unit, min/max, default, scope(global/local), apply_mode(live/recompile), supported_effects, persistence. bounds는 backend capability로 전달.

### EditCommand

command_id, target_id, expected_revision, property, proposed_value, session/epoch/requested_tick. ACK에 actual_value/revision/applied_tick 또는 오류.

### SceneSettings

schema_version, coordinate_system, units, object/source IDs, properties, player spawn, asset hashes. extension은 .flyworld로 정하고 설정 저장임을 UI에 명시.

### UndoEntry

forward edit, inverse edit, expected_revision. simulation rewind가 아니며 진행된 뉴런 상태는 되돌리지 않음.

## 5. 구현 순서 — 위에서 아래로 실행

각 단계는 해당 출력과 검사 증거를 만든 후 다음 단계로 넘어간다. 전체 파일을 한 번에 새로 쓰는 방식은 피한다.

### 6.1. 기존 제어 inventory

**할 일:** lab_world의 현재 op와 UI 필드를 표로 대조한다. 온도 세 모드와 wind normalized strength를 그대로 명시하고 숨겨진 값 목록을 만든다.

**완료 출력:** 모든 현재 지원 속성이 descriptor에 대응.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.1` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 6.2. descriptor 검증

**할 일:** 유효/경계/NaN/단위 오류 fixture부터 만들고 Swift/Python decode가 일치하도록 한다. 정의되지 않은 속성은 backend가 거부한다.

**완료 출력:** invalid 값으로 world mutation이 일어나지 않음.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.2` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 6.3. 객체 선택과 gizmo

**할 일:** 선택 outline, 이동/회전/크기 handle, 수치 입력, 복제/삭제 버튼을 만든다. raycast 좌표를 현재 world mm/축 규칙으로 변환한다.

**완료 출력:** 마우스 없이 수치 편집으로 같은 결과 가능.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.3` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 6.4. primitive 지형 편집

**할 일:** box/wall/sphere 및 기존 source를 재사용한다. 경사는 rotation을 지원하는 고정 primitive로 시작한다. 슬롯 예산 초과 시 이유를 표시한다.

**완료 출력:** 렌더링과 충돌 pose/size 일치.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.4` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 6.5. 환경 패널

**할 일:** 온도 slider와 mode, 바람 방향 화살표/강도/duration, light/source 설정을 연결한다. 적용값과 pending preview를 분리한다.

**완료 출력:** 파리 위치에서 실제 현재 sample 확인 가능.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.5` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 6.6. transaction과 undo

**할 일:** 연속 drag는 coalesce하되 최종 edit을 기록한다. pause 중 edit 적용은 명시적 편집 transaction으로 하고 simulation step을 진행시키지 않는다. 기존 자극 큐 규칙을 우회하지 않는다.

**완료 출력:** edit 허용 정책/ACK가 기록되고 undo는 설정만 복구.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.6` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 6.7. scene 저장과 reload

**할 일:** 임시 파일→schema/hash 검사→atomic rename 순서. load는 staging→검사→session barrier→swap이며 정상 world를 먼저 삭제하지 않는다.

**완료 출력:** 새 프로세스에서 scene 설정 roundtrip.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V6.7` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

## 6. 실패·취소·복구

충돌 구조 변경이 재compile을 요구하면 pause→staging→검증 후 적용한다. stale revision은 재조회 후 사용자에게 재적용 가능 상태를 제공하며 조용히 덮어쓰지 않는다.

공통 규칙: 실패한 명령은 applied로 표시하지 않는다. 이전 정상 파일/세션을 먼저 삭제하지 않는다. timeout은 무한 재시도로 숨기지 않는다. UI는 오류 원인과 재시도 가능한 작업을 보여준다. queue drain/ACK가 완료되지 않으면 saved/paused/detached 성공을 추정하지 않는다.

## 7. 이번 버전에서 만들지 않는 것

mesh/heightfield, 공간 날씨 field, full session restore는 후속 버전이다.

## 8. 검증 시나리오 — 실행과 예상 결과

| ID | 실행 방법 | 합격 조건 |
|---|---|
| V6-01 descriptor | NaN, 범위 초과, 단위 틀림, unknown property 입력. | 거부+오류 위치, world revision 불변. |
| V6-02 geometry | 이동/회전/크기 수치 편집과 gizmo 편집을 같은 목표값으로 수행. | 동일 pose/size, 실제 collision 확인. |
| V6-03 연속 입력 | 빠른 slider 100회 후 마지막 값을 기다린다. | 최종 ACK값이 UI와 같고 queue bounded. |
| V6-04 undo | 온도를 변경하고 몇 tick 진행 후 undo. | 온도 복원, neural tick이 과거로 돌아가지 않음. |
| V6-05 import 실패 | 손상 scene/중복 ID/겹치는 spawn을 load. | 부분 교체 없음, 기존 session 유지. |
| V6-06 GUI roundtrip | GUI만으로 벽/경사/먹이/온도/바람 설정 후 저장·재시작·load. | 속성/단위/IDs 보존, checkpoint로 표시하지 않음. |

검사 코드는 이 표의 동작과 실패 조건을 검증해야 한다. 구현의 상수를 복사하여 항상 통과하는 테스트를 만들지 않는다. 실행 명령은 공통 playbook에 따라 구현 후 실제 존재하는 test entry를 기록한다. 아직 만들지 않은 테스트 명령을 이미 실행 가능한 것으로 보고하지 않는다.

## 9. 완료 체크리스트

- [ ] 위 구현 단계와 각 출력이 모두 존재한다.
- [ ] schema/단위/상태 소유권과 실제 코드가 일치한다.
- [ ] 버전별 정상·실패 검사와 필요한 기존 회귀가 실제 exit 0이다.
- [ ] 실제 backend와 새 GUI 프로세스의 사용자 동선을 확인했다. headless를 GUI 검증으로 표시하지 않았다.
- [ ] 저장/기록/큐/모듈 상태를 추가했다면 snapshot/cleanup inventory도 갱신했다.
- [ ] 성능 기준 및 실제 측정, unsupported/제약이 Viewer와 문서에 일치한다.
- [ ] 기존 사용자 변경을 보존했고 실행한 프로세스/시험 자원을 정리했다.
- [ ] `docs/reports/V6_COMPLETION_REPORT.md`에 명령/exit/로그/파일/한계/rollback을 남겼다.

## 10. 다음 버전에 넘길 내용

V7에 event ID와 applied tick을 가진 편집 사건 stream, descriptor manifest, scene fixture를 전달한다.

보고서의 마지막에는 완료한 세부 단계 ID, 남은 결함, 재실행 명령, schema 버전, fixture 경로, 실제 GUI 검증 여부를 적는다. V6의 실패가 있으면 다음 버전은 시작하지 않는다. 연구 근거 부족과 코드 결함을 구별하되, 사용자 목표의 미완료를 숨기지 않는다.
