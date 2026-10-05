# Virtual Fly Lab V6 — 진행표

시작: 2026-10-05 · **V6.3 구현 중 / V6 전체 미완료**

## 선행과 사용자 예외

사용자 요청: “일단 그거는 미루고 다음단계 ㄱㄱ”(2026-10-05 17:31 KST). [V5 마감 자동 재검증](../../notes/validation/v5-next-2026-10-05/README.md)은 통과했지만 통합 GUI·live 성능은 미검증이다. 이번 요청에 따라 이 게이트를 보류하고 V6.1부터 진행한다. V5 완료나 GUI 통과로 표시하지 않는다. 기존 dirty 변경을 보존한다.

[버전 계획](../plans/VIRTUAL_FLY_LAB_V6_PLAN.md) · [로드맵](../plans/VIRTUAL_FLY_LAB_ROADMAP.md)

| 단계 | 요구 | 상태 | 증거·다음 조치 |
|---|---|---|---|
| V6.1 | 현재 제어 inventory·backend-authoritative descriptor | **자동 검증 통과 / headless TCP PASS** | [inventory](V6_CONTROL_INVENTORY.md), descriptor 39개, 공유 fixture 14개(정상·경계·실패) Swift·Python 일치, 1536객체 frame 전송 회귀 수정. Swift 7종·Python 13종 PASS. [증거](../../notes/validation/v6-1-2026-10-05/README.md). 배터리·저전력에서 22.8 Hz FAIL → AC 전원 재측정 38.3 Hz PASS, manifest A/B 차이 없음([재측정](../../notes/validation/v6-1-ac-2026-10-05/README.md)). GUI live 성능은 미측정 |
| V6.2 | descriptor 기반 edit 검증·Swift/Python fixture 일치 | **자동 검증 통과 / UI 없음** | 새 `edit_property`(clamp 없음, 오류 경로 `edit.value[1]` 등, 객체 revision·`environment_revision` stale 거절, ACK에 actual_value/revision). 공유 fixture 35개 Swift·Python 동일 판정·경로. 거절 시 world state 완전 불변. mock·real TCP labloop PASS, 회귀 22종 PASS, real TCP 36.3 Hz, 음성 대조 확인. 바람 edit는 V6.5로 보류. [증거](../../notes/validation/v6-2-2026-10-05/README.md) |
| V6.3 | 객체 선택·gizmo·수치 입력 동등성 | implementing | 2026-10-05 구현·자동 검증 진행 중. 실제 Lab/MuJoCo 창 관찰 성공. 현재 도구 호스트 macOS 접근성 권한 없음(`accessibility=false`, AX window unresolved)으로 GUI 입력 검증은 아직 수행하지 못함 |
| V6.4 | primitive 지형 편집 | planned | V6.3 이후 |
| V6.5 | 환경 패널 | planned | 온도·바람·빛·먹이의 실제 지원 범위 표시 |
| V6.6 | transaction·undo/redo | planned | simulation rewind 아님 |
| V6.7 | .flyworld scene 저장·reload | planned | 뉴런 snapshot 아님; 최종 real·GUI·성능 수용도 필요 |

## 확인된 기존 제약

- 기본 food 용량은 8이다(과거 준비 보고서의 32는 현재 정본 아님).
- 온도 backend 범위는 0~50°C, UI·Coordinator는 10~40°C. 임의로 확대·축소하지 않고 backend capability와 UI presentation 범위를 구분한다.
- V6.2의 strict revision edit은 자동 검증됨. V6.3 gizmo·수치 inspector는 구현 중이며 GUI 입력 수용은 미확인. 환경 설정 저장·undo는 후속 단계다.
- 2026-10-05 18:02 dsh GPT-6.1 Sol 세션이 사용 한도로 중단되어 Claude가 인수했다(대용량 fixture, 유니코드 일치, export 비용, 최종 회귀).
