# Virtual Fly Lab V6 — 진행표

시작: 2026-10-05 · **2026-10-06 실제 GUI 확인: V6.3 부분 통과, V6.4 실패, V6.5 실패(먹이 감각 위치·오류 안내) / V6 전체 미완료**

Codex가 사용자 요청으로 Computer Use를 통해 현재 패키지와 실제 MuJoCo 백엔드의 GUI를 직접 조작했다. [실제 GUI 보고서](../../notes/validation/gui-2026-10-06/REPORT.md): 기본 객체 편집·복제/삭제·캔버스 선택·환경 자극·기록 종료 저장 확인. 경사로 pitch 누락(P1), 실제 후각 위치의 NumPy 배열이 원점으로 치환됨(P1), 환경 숫자 오류가 이전 ACK로 덮임(P2), 언어 변경 후 편집기 영문 잔존(P2). 배터리 GUI body 갱신은 30Hz 기준 미달, AC 및 남은 GUI 항목은 미완료. 아래 이전 단계별 증거는 당시 기록이며 이번 GUI 판정은 이 보고서를 따른다.

같은 날 Claude가 네 결함을 코드에서 확인하고 수정했다([수정 기록](../../notes/validation/gui-fixes-2026-10-06/README.md)): F01 render quaternion에서 경사로 pitch 전달, F04 NumPy 흉부 위치 수용, F02 상태 문구를 해당 섹션에만 표시·초기화 때 지움, F03 언어 변경 시 편집기 문구 갱신. Swift·Python mock/real 회귀와 실물 후각 probe PASS. **수정 후 실제 창 재확인은 아직 하지 않았다** — V6.4/V6.5 GUI 판정은 사용자 재확인 전까지 FAIL로 유지한다.

## 선행과 사용자 예외

사용자 요청: “일단 그거는 미루고 다음단계 ㄱㄱ”(2026-10-05 17:31 KST). [V5 마감 자동 재검증](../../notes/validation/v5-next-2026-10-05/README.md)은 통과했지만 통합 GUI·live 성능은 미검증이다. 이번 요청에 따라 이 게이트를 보류하고 V6.1부터 진행한다. V5 완료나 GUI 통과로 표시하지 않는다. 기존 dirty 변경을 보존한다.

두 번째 사용자 예외: “다음단계 개시”(2026-10-06). V6.3 편집기의 전체 GUI 수용([인계](../../notes/validation/v6-3-2026-10-05/GUI_PARENT_HANDOFF.md))이 끝나지 않은 상태에서 V6.4로 넘어간다. V6.3은 GUI 통과로 표시하지 않는다.

세 번째 사용자 예외: “다음단계 개시”(2026-10-06 오후). V6.4 경사로 GUI 확인([목록](../../notes/validation/v6-4-2026-10-06/GUI_CHECKLIST.md))이 끝나지 않은 상태에서 V6.5로 넘어간다. V6.4는 GUI 통과로 표시하지 않는다.

[버전 계획](../plans/VIRTUAL_FLY_LAB_V6_PLAN.md) · [로드맵](../plans/VIRTUAL_FLY_LAB_ROADMAP.md)

| 단계 | 요구 | 상태 | 증거·다음 조치 |
|---|---|---|---|
| V6.1 | 현재 제어 inventory·backend-authoritative descriptor | **자동 검증 통과 / headless TCP PASS** | [inventory](V6_CONTROL_INVENTORY.md), descriptor 39개, 공유 fixture 14개(정상·경계·실패) Swift·Python 일치, 1536객체 frame 전송 회귀 수정. Swift 7종·Python 13종 PASS. [증거](../../notes/validation/v6-1-2026-10-05/README.md). 배터리·저전력에서 22.8 Hz FAIL → AC 전원 재측정 38.3 Hz PASS, manifest A/B 차이 없음([재측정](../../notes/validation/v6-1-ac-2026-10-05/README.md)). GUI live 성능은 미측정 |
| V6.2 | descriptor 기반 edit 검증·Swift/Python fixture 일치 | **자동 검증 통과 / UI 없음** | 새 `edit_property`(clamp 없음, 오류 경로 `edit.value[1]` 등, 객체 revision·`environment_revision` stale 거절, ACK에 actual_value/revision). 공유 fixture 35개 Swift·Python 동일 판정·경로. 거절 시 world state 완전 불변. mock·real TCP labloop PASS, 회귀 22종 PASS, real TCP 36.3 Hz, 음성 대조 확인. 바람 edit는 V6.5로 보류. [증거](../../notes/validation/v6-2-2026-10-05/README.md) |
| V6.3 | 객체 선택·gizmo·수치 입력 동등성 | **GUI 기본 편집 부분 통과 / 전체 수용 미완료** | 23:08 후보 자동 검사 로그 수집 및 실제 편집 모드 전환·물체 선택 확인. 이후 다른 세션이 소스와 binary를 변경했으므로 이전 결과를 최신 빌드 통과 근거로 쓰지 않음. 수치 적용·드래그·복제/삭제·negative·지속 성능 수용은 미완료. [후보별 GUI 인계](../../notes/validation/v6-3-2026-10-05/GUI_PARENT_HANDOFF.md) |
| V6.4 | primitive 지형 편집 | **자동·실물·TCP 통과 / 현재 GUI FAIL: pitch 누락** | 새 모양 `ramp`(경사로): box + 기울기(pitch 0–45°, 자기 Y축), 기울기·크기 편집은 낮은 쪽 윗모서리를 축으로 회전, 고정 지형(잡기·접근 거절). 다리 접촉쌍(경골·부절·몸통 43개 × 슬롯 4개, FlyGym 바닥과 같은 마찰·solver 값). 슬롯 초과는 `rejected_capacity`와 사람이 읽는 사유로 표시. 실물: 렌더↔충돌 pose/size 최대 차 1.1e-16, 면 안팎 탐침 전부 일치, 파리가 자기 다리로 경사로를 오름(흉부 z 1.00→7.41 mm), 다리 쌍을 뺀 대조군은 1.15 mm. TCP mock·real 9/9. 비용: 경사로가 멀 때 ~+2%, 파리가 경사로 위일 때 ~+45%(메시–상자 GJK). [증거](../../notes/validation/v6-4-2026-10-06/README.md) |
| V6.5 | 환경 패널 | **자동·실물 TCP 통과 기록 / 현재 GUI FAIL: 후각 위치·오류 안내 / AC 재측정 필요** | ‘감각’ 페이지를 환경 패널로 교체: 지금 파리 위치의 값(실제 body packet + 뇌에 넣은 전류), 온도·바람(원형 방향 다이얼)·눈별 가림·먹이 종류 놓기. 적용값과 ‘보내는 중’ 분리, 슬라이더 100단계 → edit 3개(V6-03). 바람 edit = 계속 부는 바람 설정, puff 중엔 `rejected_busy`. 온도는 backend 적용값을 뇌 쪽이 따름(ACK 전 로컬 적용 제거). real TCP 15/15, Swift 78 PASS, 음성 대조 확인. bridgeloop real은 배터리에서 22 Hz FAIL — A/B로 변경 무관 확인, AC 재측정 필요. 바람 강화(사용자 승인): 가슴 힘 60,000 mm/s² + 바람 속도(30 mm/s×세기)에 가까워지면 힘 감소 → 세기 1에서 1초 8.85 mm(이전 0.08 mm), 정면 0.7 이상이면 넘어짐(허용), 불안정 경고 0건. [증거](../../notes/validation/v6-5-2026-10-06/README.md), [GUI 목록](../../notes/validation/v6-5-2026-10-06/GUI_CHECKLIST.md) |
| V6.6 | transaction·undo/redo | planned | simulation rewind 아님 |
| V6.7 | .flyworld scene 저장·reload | planned | 뉴런 snapshot 아님; 최종 real·GUI·성능 수용도 필요 |

## 확인된 기존 제약

- 기본 food 용량은 8이다(과거 준비 보고서의 32는 현재 정본 아님).
- 온도 backend 범위는 0~50°C, UI·Coordinator는 10~40°C. 임의로 확대·축소하지 않고 backend capability와 UI presentation 범위를 구분한다.
- 온도 권한 불일치는 V6.5에서 수정(백엔드 연결 시 뇌 쪽은 backend 적용값을 따름).
- V6.2의 strict revision edit은 자동 검증됨. V6.3 gizmo·수치 inspector는 구현 중이며 GUI 입력 수용은 미확인. 환경 설정 저장·undo는 후속 단계다.
- 2026-10-05 18:02 dsh GPT-6.1 Sol 세션이 사용 한도로 중단되어 Claude가 인수했다(대용량 fixture, 유니코드 일치, export 비용, 최종 회귀).
