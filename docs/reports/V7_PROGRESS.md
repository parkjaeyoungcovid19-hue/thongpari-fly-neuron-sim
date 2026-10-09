# Virtual Fly Lab V7 진행표

2026-10-09 갱신 · 사용자 요청 범위 **V7.3까지**. 선행 [V6 완료](V6_COMPLETION_REPORT.md), [V7.2 전 리팩토링](PRE_V7_2_REFACTOR.md). 전체 V7은 미완료이며 V7.4 이후는 시작하지 않는다.

| 단계 | 상태 | 출력·검사 |
|---|---|---|
| V7.1 기존 관측 audit | **완료** | [audit](V7_OBSERVATION_AUDIT.md), BrainSignals 10개와 모든 기존 rate 단위/EMA/분모, exact count vs lossy sampled 시각화 분리. [완료 보고서](V7_1_COMPLETION_REPORT.md), observation audit·CPU/GPU·최종 local real GUI exit0/확인. Finder startup 제약은 별도 기록 |
| V7.2 정확 관측 primitive | **구현·headless 검증** | 선택 ≤256 뉴런의 tick별 정확 spike stream(LIF.metal `observeSlot`), 한도 capability, JSON 계약. `--observetest`: 600 tick 독립 CPU 참조와 전 tick 일치, 무부작용, fixture/결측/overflow. [보고서](V7_2_3_COMPLETION_REPORT.md) |
| V7.3 읽기/자극 분리 | **구현·headless 검증** | 기본 클릭 = 읽기 전용 선택, ⚡ 스위치 = 직접 자극, 주입 표시. `--observetest` V7-02: 선택 100회+실제 클릭 경로 10회 후 자극 요청·extInput 불변. 실제 GUI는 보고서 참조 |
| V7.4 기능 그룹 registry | 미착수 | 현재 role/type/root ID 목록 audit만 수행 |
| V7.5 사건 전후 buffer | 미착수 | 새 buffer 없음 |
| V7.6 통합 timeline | 미착수 | 기존 command/event timeline 보존 |
| V7.7 관측 기반 설명 | 미착수 | 새로운 생각/감정 추론 없음 |

원본 [V7 계획](../plans/VIRTUAL_FLY_LAB_V7_PLAN.md)의 V7-01–06 전체 검증과 완료 체크리스트는 V7 전체에 해당한다. V7.1 완료를 전체 V7 완료로 바꾸지 않는다. 동적 runtime state를 새로 추가하지 않았으며 시각화의 SpikeBus는 [V6 future state inventory](V6_FUTURE_STATE_INVENTORY.md)에 추가한다.
