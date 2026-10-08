# Virtual Fly Lab V6 — 진행표

시작: 2026-10-05 · **2026-10-08 V6.1–V6.7 완료**

Claude의 중단된 V6.6 변경·V6.7 초안을 Codex가 이어받았다. 경사로 pitch·후각 위치·오류 안내·언어 수정 후 실제 GUI를 재검증했고, scene settings 저장→새 프로세스 load와 실패 시 기존 world 보존을 완성했다. [최종 완료 보고서](V6_COMPLETION_REPORT.md), [상태 목록](V6_FUTURE_STATE_INVENTORY.md), [최신 증거](../../notes/validation/v7-1-2026-10-08/README.md)가 현재 판정이다. 아래 과거 사용자 예외와 단계별 초기 증거는 이력으로 보존한다.

## 선행과 사용자 예외

사용자 요청: “일단 그거는 미루고 다음단계 ㄱㄱ”(2026-10-05 17:31 KST). [V5 마감 자동 재검증](../../notes/validation/v5-next-2026-10-05/README.md)은 통과했지만 통합 GUI·live 성능은 미검증이다. 이번 요청에 따라 이 게이트를 보류하고 V6.1부터 진행한다. V5 완료나 GUI 통과로 표시하지 않는다. 기존 dirty 변경을 보존한다.

두 번째 사용자 예외: “다음단계 개시”(2026-10-06). V6.3 편집기의 전체 GUI 수용([인계](../../notes/validation/v6-3-2026-10-05/GUI_PARENT_HANDOFF.md))이 끝나지 않은 상태에서 V6.4로 넘어간다. V6.3은 GUI 통과로 표시하지 않는다.

세 번째 사용자 예외: “다음단계 개시”(2026-10-06 오후). V6.4 경사로 GUI 확인([목록](../../notes/validation/v6-4-2026-10-06/GUI_CHECKLIST.md))이 끝나지 않은 상태에서 V6.5로 넘어간다. V6.4는 GUI 통과로 표시하지 않는다.

[버전 계획](../plans/VIRTUAL_FLY_LAB_V6_PLAN.md) · [로드맵](../plans/VIRTUAL_FLY_LAB_ROADMAP.md)

| 단계 | 요구 | 상태 | 증거·다음 조치 |
|---|---|---|---|
| V6.1 | 현재 제어 inventory·backend-authoritative descriptor | **완료 — 자동·real TCP·GUI** | [inventory](V6_CONTROL_INVENTORY.md), descriptor 39개, 공유 fixture 14개(정상·경계·실패) Swift·Python 일치, 1536객체 frame 전송 회귀 수정. Swift 7종·Python 13종 PASS. [증거](../../notes/validation/v6-1-2026-10-05/README.md). 배터리·저전력에서 22.8 Hz FAIL → AC 전원 재측정 38.3 Hz PASS, manifest A/B 차이 없음([재측정](../../notes/validation/v6-1-ac-2026-10-05/README.md)). GUI live 성능은 미측정 |
| V6.2 | descriptor 기반 edit 검증·Swift/Python fixture 일치 | **완료 — 검증/무변경/GUI** | 새 `edit_property`(clamp 없음, 오류 경로 `edit.value[1]` 등, 객체 revision·`environment_revision` stale 거절, ACK에 actual_value/revision). 공유 fixture 35개 Swift·Python 동일 판정·경로. 거절 시 world state 완전 불변. mock·real TCP labloop PASS, 회귀 22종 PASS, real TCP 36.3 Hz, 음성 대조 확인. 바람 edit는 V6.5로 보류. [증거](../../notes/validation/v6-2-2026-10-05/README.md) |
| V6.3 | 객체 선택·gizmo·수치 입력 동등성 | **완료 — 자동·real·실제 GUI 재확인** | 23:08 후보 자동 검사 로그 수집 및 실제 편집 모드 전환·물체 선택 확인. 이후 다른 세션이 소스와 binary를 변경했으므로 이전 결과를 최신 빌드 통과 근거로 쓰지 않음. 수치 적용·드래그·복제/삭제·negative·지속 성능 수용은 미완료. [후보별 GUI 인계](../../notes/validation/v6-3-2026-10-05/GUI_PARENT_HANDOFF.md) |
| V6.4 | primitive 지형 편집 | **완료 — pitch GUI 수정 재확인** | 새 모양 `ramp`(경사로): box + 기울기(pitch 0–45°, 자기 Y축), 기울기·크기 편집은 낮은 쪽 윗모서리를 축으로 회전, 고정 지형(잡기·접근 거절). 다리 접촉쌍(경골·부절·몸통 43개 × 슬롯 4개, FlyGym 바닥과 같은 마찰·solver 값). 슬롯 초과는 `rejected_capacity`와 사람이 읽는 사유로 표시. 실물: 렌더↔충돌 pose/size 최대 차 1.1e-16, 면 안팎 탐침 전부 일치, 파리가 자기 다리로 경사로를 오름(흉부 z 1.00→7.41 mm), 다리 쌍을 뺀 대조군은 1.15 mm. TCP mock·real 9/9. 비용: 경사로가 멀 때 ~+2%, 파리가 경사로 위일 때 ~+45%(메시–상자 GJK). [증거](../../notes/validation/v6-4-2026-10-06/README.md) |
| V6.5 | 환경 패널 | **완료 — 후각·오류 GUI 및 AC 재측정** | ‘감각’ 페이지를 환경 패널로 교체: 지금 파리 위치의 값(실제 body packet + 뇌에 넣은 전류), 온도·바람(원형 방향 다이얼)·눈별 가림·먹이 종류 놓기. 적용값과 ‘보내는 중’ 분리, 슬라이더 100단계 → edit 3개(V6-03). 바람 edit = 계속 부는 바람 설정, puff 중엔 `rejected_busy`. 온도는 backend 적용값을 뇌 쪽이 따름(ACK 전 로컬 적용 제거). real TCP 15/15, Swift 78 PASS, 음성 대조 확인. bridgeloop real은 배터리에서 22 Hz FAIL — A/B로 변경 무관 확인, AC 재측정 필요. 바람 강화(사용자 승인): 가슴 힘 60,000 mm/s² + 바람 속도(30 mm/s×세기)에 가까워지면 힘 감소 → 세기 1에서 1초 8.85 mm(이전 0.08 mm), 정면 0.7 이상이면 넘어짐(허용), 불안정 경고 0건. [증거](../../notes/validation/v6-5-2026-10-06/README.md), [GUI 목록](../../notes/validation/v6-5-2026-10-06/GUI_CHECKLIST.md) |
| V6.6 | transaction·undo/redo | **완료 — 재빌드·정지 Undo/Redo GUI** | 일시정지 중 편집 트랜잭션(자극은 장벽), `previous_value` 역연산, Swift `WorldEditHistory`(⌘Z/⇧⌘Z). simulation rewind 아님. [증거](../../notes/validation/v6-6-2026-10-07/README.md) |
| V6.7 | .flyworld scene 저장·reload | **완료 — schema1·새 프로세스 GUI roundtrip·실패 보존** | [최종 보고서](V6_COMPLETION_REPORT.md), GUI 작성→저장→재시작→load→paused export hash 일치; mock/real TCP·강제 runtime rollback; AC GUI 31.6–33.6Hz |

## 2026-10-08 최종 수용

기존 표의 “미완료/FAIL/미확인” 문장은 초기 단계 이력이다. 최종 GUI는 최신 후보의 수치·drag pitch·복제/undo·food 감각 위치·오류 지속·환경 편집/undo·scene 새 프로세스 저장/복원·손상 거부와 연결 capability를 확인했다. 자세한 증거와 실행/성능 한계는 최종 완료 보고서를 따른다. iCloud 관리 `dist` 실행 정지는 별도 환경 제약으로 공개하고, 같은 signed bundle의 비-iCloud 복사본을 실제 실행하여 검증했다.

## 확인된 기존 제약

- 기본 food 용량은 8이다(과거 준비 보고서의 32는 현재 정본 아님).
- 온도 backend 범위는 0~50°C, UI·Coordinator는 10~40°C. 임의로 확대·축소하지 않고 backend capability와 UI presentation 범위를 구분한다.
- 온도 권한 불일치는 V6.5에서 수정(백엔드 연결 시 뇌 쪽은 backend 적용값을 따름).
- V6.2의 strict revision edit은 자동 검증됨. V6.3 gizmo·수치 inspector는 구현 중이며 GUI 입력 수용은 미확인. 환경 설정 저장·undo는 후속 단계다.
- 2026-10-05 18:02 dsh GPT-6.1 Sol 세션이 사용 한도로 중단되어 Claude가 인수했다(대용량 fixture, 유니코드 일치, export 비용, 최종 회귀).
