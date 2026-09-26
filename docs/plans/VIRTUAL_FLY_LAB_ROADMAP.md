# Virtual Fly Lab — V4부터 V14까지 순차 구현 로드맵

수정: 2026-09-13 · 정본: 이 파일과 같은 폴더의 버전별 구현 계획.

**반드시 V4 → V5 → V6 → V7 → V8 → V9 → V10 → V11 → V12 → V13 → V14 순서로 구현한다.** 궁극적 목표를 한 번에 구현하거나 별도의 P 단계로 재배열하지 않는다. 각 버전 안의 세부 작업도 상세 문서에 적힌 순서를 따른다.

**2026-09-23 현재 순서 추가:** V5 안에서 V5.5 다음에 [V5.5.1 한 창 사용 경험](VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md)을 완료하고 V5.6 → V5.7로 진행한다. 최신 미완료 결함은 [전체 감사](../reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md)를 따른다.

## 1. 궁극적 목표

사용자가 Viewer에서 시뮬레이션 세계 안에 들어가 게임처럼 파리와 상호작용한다. 환경·지형지물·온도·습도·날씨·바람 등을 같은 Viewer에서 직관적으로 통제한다. 상호작용마다 뉴런 활동을 감각·행동·욕구·정서 관련·각성으로 탐색하고, 측정과 모델 해석을 구분해서 이해한다.

향후 오버워치·레이싱·비행기게임 같은 외부 환경의 입출력을 장착할 수 있도록 **범용 모듈 계약과 호스트 기반만 만든다. 실제 게임 모듈은 만들지 않는다.** 첫 사용자 참여는 데스크톱 1인칭이며 카메라뿐 아니라 세계 안의 참여체가 파리의 눈과 접촉에 실제 반영되어야 한다.

신경 활동을 실제 동물의 주관적인 생각이나 인간 감정으로 확정하지 않는다. 욕구/정서 모델은 근거·불확실성·미지원 상태를 표시한다. 모르는 값을 예쁜 숫자로 채우지 않는다. 미지원 범주가 남으면 궁극적 목표의 잔여 사항으로 기록한다.

## 2. 현재 진도와 다음 작업

- V4 완료 기준은 `e900b27` (`Complete Virtual Fly Lab V4 deterministic sessions`), V5 준비 문서는 `3faf942` (`Prepare Virtual Fly Lab V5 implementation`)에 커밋됐다.
- V3: 기존 완료/독립 검증 보고서에서 수정 및 회귀 증거를 확인했다. 기록 중 실제 메뉴 Quit 수동 확인은 별도 사용자 검증 항목이다.
- V4: **COMPLETE in the current local working tree.** fixed tick/lockstep, 양쪽 pause barrier, session/epoch, authoritative applied tick, stale/duplicate safety를 fresh 자동·real TCP·real MuJoCo·real Viewer GUI로 검증했다. 완료 근거는 [V4 완료 보고서](../reports/V4_COMPLETION_REPORT.md)에 있다.
- V4 최종 GUI smoke에서 persistent `session_state` 중복 처리 결함을 발견해 `LabSession`의 lifecycle control sequence 소비를 idempotent하게 수정했고, 회귀를 추가한 뒤 전체 suite와 real Viewer를 다시 통과했다.
- V5: **V5.1~V5.5 기능 구현, 자동·실제 backend 검증 진행; 통합 GUI 인수 미완료.** 다음 세부 버전은 V5.5.1이다. 기존 입력·충돌·표현·실행 경로 결함과 GUI/성능 gate는 [전체 감사](../reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md) 및 [V5 진행표](../reports/V5_PROGRESS.md)를 따른다.
- V6–V14: 계획. V5 완료 전에는 앞당겨 구현하지 않는다.

**현재 다음 실행은 V5.5.1 단일 창 사용 경험 계획의 선행 결함과 GUI gate 확인이다.** V5.6 이후의 기능은 V5.5.1 인수 뒤 시작한다.

## 3. 순차 버전 표

| 버전 | 핵심 결과 | 이번 버전에 포함 | 아직 하지 않는 것 | 상세 계획 |
|---|---|---|---|---|
| V4 | 시간·세션 기반 완성 | fixed tick, lockstep, 양쪽 pause, epoch, applied tick, 현재 구현 검증 | 새 viewer/새 환경/저장 모듈 | [V4](VIRTUAL_FLY_LAB_V4_PLAN.md) |
| V5 | 세계 안의 사용자 + 통합 Viewer | 1인칭 참여체, 카메라/입력, V5.5.1 한 창 사용 경험, 이후 집기·놓기와 기존 활동 카드 | terrain 확장/새 욕구 모델 | [V5](VIRTUAL_FLY_LAB_V5_PLAN.md) · [V5.5.1](VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md) |
| V6 | 직관적인 기본 환경 편집 | primitive 지형·객체·온도·바람·빛·먹이, undo, scene 설정 저장 | 전체 checkpoint/날씨 field | [V6](VIRTUAL_FLY_LAB_V6_PLAN.md) |
| V7 | 정확한 뉴런 관측 | 그룹/root ID/rate/raster, 사건 전후 비교, 근거/unknown | 체내 욕구 모델 | [V7](VIRTUAL_FLY_LAB_V7_PLAN.md) |
| V8 | 외부 입출력 확장 기반 | typed 관측/행동, attach/detach/clock/capability/오류, 시험 fixture | 실제 게임 모듈 제작 | [V8](VIRTUAL_FLY_LAB_V8_PLAN.md) |
| V9 | 같은 상태 보존·재생 | 전체 checkpoint, 개체 ID/복제/이식, 기록 보기/재실행/분기 | 새 기상 모델 | [V9](VIRTUAL_FLY_LAB_V9_PLAN.md) |
| V10 | 전체 환경 제어 확대 | mesh/heightfield, 공간 온습도·바람·냄새, 날씨, 접촉 미각 검증 | 검증 없는 생리/정서 추정 | [V10](VIRTUAL_FLY_LAB_V10_PLAN.md) |
| V11 | 욕구·정서·각성 해석 | 체내 상태와 neural 추정 분리, 근거 있는 분류, 사건별 설명 | 주관적 생각을 읽는다는 주장 | [V11](VIRTUAL_FLY_LAB_V11_PLAN.md) |
| V12 | 해석/행동 근거 검증 | primary 데이터, benchmark, holdout, 제거 대조, uncertainty | 전신 neural backend 교체 | [V12](VIRTUAL_FLY_LAB_V12_PLAN.md) |
| V13 | 성능·안정성·사용성 | 실제 조작 latency, 긴 실행, 오류 복구, 키보드/드래그 대체 | 새 대형 기능 | [V13](VIRTUAL_FLY_LAB_V13_PLAN.md) |
| V14 | 궁극적 목표 통합 인수 | 전체 GUI 동선, 저장 재개, 환경/뇌/모듈 기반 종합 검증·전달 | 미완료를 완료로 포장 | [V14](VIRTUAL_FLY_LAB_V14_PLAN.md) |

V4에서 시간 제어를 고친 후 V5에서 참여체를 붙인다. V6에서 환경 사건을 표준화하므로 V7이 그 사건을 정확하게 분석할 수 있다. V8은 관측과 출력을 모듈 경계로 열고, V9는 이 모든 상태를 저장한다. V10 환경 모델, V11 내부 상태 모델을 추가할 때 V9의 저장 목록도 함께 확장한다. V12로 해석 근거를 검증한 뒤 V13에서 성능/사용성을 다듬고 V14에서 전체 요구를 인수한다.

## 4. 구현자가 읽을 순서

1. 이 로드맵으로 현재 착수 버전을 확인한다.
2. [공통 실행 playbook](IMPLEMENTATION_PLAYBOOK.md)을 읽고 진행표·검증·복구 규칙을 적용한다.
3. 해당 버전의 상세 계획에서 파일/데이터 계약/세부 단계/실패 처리/테스트를 읽는다.
4. [공통 UX·확장 계약](INTERACTIVE_FLY_SANDBOX_PLAN.md)에서 관련 세부 계약을 확인한다.
5. 이전 버전 완료 보고서와 실제 소스/설치 API를 확인한 뒤 구현한다.

옛 로드맵의 V5 checkpoint/V10 inspector 등의 번호는 이번에 변경됐다. 현재는 **V9 checkpoint, V7 inspector, V10 환경/습도/미각**이다. 옛 로드맵은 [이력 파일](../history/VIRTUAL_FLY_LAB_ROADMAP_PRE_INTERACTIVE_2026-09-13.md)에 보존했으며 실행 지시로 사용하지 않는다. V3 이하 문서에 남은 옛 번호는 역사적 기록이다.

## 5. 전 버전 공통 완료 규칙

실제 구현 파일, 자동 검사 명령/exit/log, 실제 backend 증거, fresh GUI 동선, 성능/한계를 각 버전 완료 보고서에 남긴다. 소스 파일 존재나 mock PASS만으로 complete를 선언하지 않는다. 미해결 코드 실패가 있으면 다음 버전으로 가지 않는다. 근거 부족으로 기능을 지원하지 못하면 그 범위와 사용자 목표의 잔여를 명시한다.

현재 전뇌 파리 한 개체를 기본으로 한다. 장식용 추가 파리를 독립 전뇌로 세지 않는다. 모듈 capability/성능은 런타임에서 확인하며 로컬 포트·계정·모델 이름을 범용 제품 기본값으로 하드코딩하지 않는다. 저장/패키지 import는 정상 상태를 보존하는 transaction이다.

원래 모델의 gain/가중치/connectome/shader를 UI 목표를 위해 임의 조율하지 않는다. 해당 계층 변경은 필요한 근거와 회귀를 함께 수행한다. 물리적 외력, 감각 모델, 직접 neural 자극, controller 출력의 출처는 끝까지 기록한다.
