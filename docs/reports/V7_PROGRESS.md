# Virtual Fly Lab V7 진행표

2026-10-12 갱신. 선행 문서는 [V6 완료](V6_COMPLETION_REPORT.md)와 [V7.2 전 리팩토링](PRE_V7_2_REFACTOR.md)이다. **V7.1–V7.7의 구현과 headless 검증을 마쳤다.** V7.6–7.7의 실제 GUI 검사는 부분 확인이다. 상세는 [V7 완료 보고서](V7_COMPLETION_REPORT.md)를 본다.

| 단계 | 상태 | 출력·검사 |
|---|---|---|
| V7.1 기존 관측 audit | **완료** | [audit](V7_OBSERVATION_AUDIT.md), BrainSignals 10개와 모든 기존 rate 단위/EMA/분모, exact count vs lossy sampled 시각화 분리. [완료 보고서](V7_1_COMPLETION_REPORT.md), observation audit·CPU/GPU·최종 local real GUI exit0/확인. Finder startup 제약은 별도 기록 |
| V7.2 정확 관측 primitive | **구현·headless 검증** | 선택 ≤256 뉴런의 tick별 정확 spike stream(LIF.metal `observeSlot`), 한도 capability, JSON 계약. `--observetest`: 600 tick 독립 CPU 참조와 전 tick 일치, 무부작용, fixture/결측/overflow. [보고서](V7_2_3_COMPLETION_REPORT.md) |
| V7.3 읽기/자극 분리 | **구현·headless 검증** | 기본 클릭 = 읽기 전용 선택, ⚡ 스위치 = 직접 자극, 주입 표시. `--observetest` V7-02: 선택 100회+실제 클릭 경로 10회 후 자극 요청·extInput 불변. 실제 GUI는 보고서 참조 |
| V7.4 기능 그룹 registry | **구현·headless·GUI 검증** | `neural_group.v1` 22개 그룹(위협 4·운동 7·감각 10·분류되지 않음 1, 각성은 등록 그룹 없음), dataset hash 결속, 256 초과 그룹은 부분 집합 대체 없이 관측 불가. Lab Brain 기능 그룹 패널. `--registrytest` 70/70. [보고서](V7_4_5_COMPLETION_REPORT.md) |
| V7.5 사건 전후 buffer | **구현·headless·GUI 검증** | `interaction_window.v1`, sim tick 기준 전 500/후 1000 tick, 수집 ≤16·보관 ≤64, 넘침·겹침·손실을 validity로 기록, 일시 정지 중 미완성. `--eventwindowtest` 82/82. 실제 GUI 검사(G8 N/A, 온도 모드 미확인). 같은 보고서 |
| V7.6 통합 timeline | **구현·headless 검증, GUI 부분 확인** | `InteractionTimeline`: 눈·감각·운동·몸 lane, tick 출처 `sampled_at`/`received_at`, 보간 없음. `interaction_window.v2`, 사건 전후 timeline 패널, `timeline.csv`. `--timelinetest` 73/73. GUI T1·T3·T5·T7 PASS, T4는 고친 뒤 GUI 재확인 안 함. [보고서](V7_COMPLETION_REPORT.md) |
| V7.7 관측 기반 설명 | **구현·headless 검증, GUI 부분 확인** | `interaction_explanation.v1`: 순수 규칙으로 verdict 8개, 한국어·영어 문장, 물리적 힘과 신경 출력 구분, 감정·의도 어휘 없음. 설명 카드. `--explaintest` 44/44. GUI에서는 interactive 바람 사건이 applied_tick_unknown이라 물리력·감각 대조를 확인하지 못함(headless로만 확인). 같은 보고서 |

원본 [V7 계획](../plans/VIRTUAL_FLY_LAB_V7_PLAN.md)의 V7-01–06과 완료 체크리스트는 [V7 완료 보고서](V7_COMPLETION_REPORT.md) §3·§5에서 대응시켰다. GUI 사용자 동선 항목은 아직 미완료다. 동적 runtime state를 새로 추가하지 않았으며 시각화의 SpikeBus는 [V6 future state inventory](V6_FUTURE_STATE_INVENTORY.md)에 추가한다.
