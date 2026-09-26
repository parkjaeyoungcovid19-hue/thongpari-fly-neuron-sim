# V5.5.1 실제 GUI 인수 — 2026-09-26

**최종:** 동선 4–7과 성능은 결함 수정 빌드에서 사용자가 직접 확인했다(2026-09-26, 캡처·수치 없음). 판정은 [V5.5.1 완료 보고서](../../../docs/reports/V5_5_1_COMPLETION_REPORT.md)에 있다. 아래는 Claude가 화면으로 확인한 범위와 발견 기록이다.

대상: [V5.5.1 계획](../../../docs/plans/VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md) §7의 GUI 동선 1–7. `./package_app.sh`로 만든 `dist/Thongpari Virtual Fly Lab.app`을 `open`으로 실행했다. 앱이 소유한 실제 headless backend를 쓴다. 조작은 Computer Use로 했다. 대부분은 백그라운드 app 도구를 썼고, 키를 누르고 있는 동작(W/S)만 사용자 승인 뒤 전체 화면 제어로 했다.

**주의:** 첫 실행 중 `참여` 전환, `지도를 클릭하면 바로 만들기` 체크, 먹이·벽 생성은 사용자가 직접 한 조작이었다(사용자 확인). 이후 앱을 종료하고 깨끗한 상태에서 다시 시작해 아래 결과를 얻었다.

## 결과 요약

| 동선 | 판정 | 근거 |
|---|---|---|
| 1 첫 실행 | **PASS** | 화면에 보이는 창은 `Virtual Fly Lab` 1320×820 하나다. 숨긴 `Fly Brain` 패널이 있으나 onscreen=false다(`01-window-list.txt`). 앱 자식 bridge가 비공개 포트(bridge·render 각 1개)를 연다. MuJoCo 창과 오버레이는 없다(`01-processes.txt`, `01-first-launch.png`). 메뉴 `Virtual Fly Lab 종료` 뒤 앱·bridge·포트가 모두 정리됐다(3회) |
| 2 자극 | **PASS (수정 후)** | 바람 → `#1 wind — 적용됨`, 왼눈 가림 → `#2 set_eye_state left — 적용됨`, `event wind_complete` 표시. 세계·카메라(파리 따라가기)는 유지됐고 GF 반응 표시(“겁남”)가 나왔다(`02-stimuli-wind-eye.png`). pending 상태는 ACK가 100 ms 갱신 주기보다 빨라 화면에서 관찰하지 못했다 |
| 3 뇌·데이터·실험 | **PASS (수정 후)** | 세 페이지를 오가도 캔버스 인스턴스와 타임라인이 유지되고 세션 시각이 이어진다. 3D 뉴런 점군 클릭으로 직접 자극하면 기록이 남는다(`03-brain-click-recorded.png`). 2D 좌표 도구는 `세계` 페이지에 있다 |
| 4 참여·충돌 | **재확인 필요** | 결함 C·D·E를 수정했다. 새 빌드에서 벽 밀기/해제/Esc를 GUI로 다시 확인해야 한다. Esc 뒤 상태 문구가 남은 현상은 D(자동 capture)와 관련됐을 수 있으나 확인하지 않았다 |
| 5 pause | 미실행 | |
| 6 장애·복구 | 부분 | 정상 종료 정리만 확인했다. backend 종료·재연결, 명령 거절, 기록 실패 sheet는 미실행 |
| 7 창·접근성 | 미실행 | |
| 성능 | 부분 관측 | 상태줄 기준 몸 데이터 초당 21–26회, 실시간 대비 0.40–0.53배(“느림: 초당 30회 미만”). V5.5 기준선 비교는 미실행 |

## GUI에서 발견해 고친 결함

### A. interactive 세션 시각이 시작 순간 값에 멈춤 (동선 2·3)

- 현상: 타임라인의 모든 명령이 `t23129`로 찍혔다. 이 값은 세션을 시작한 순간의 **뇌** 시각이다. 그동안 3D 라벨은 36625 ms까지 진행했다. inspector와 세션 라벨도 같은 멈춘 값을 보여줬다.
- 원인: `LabSession`은 deterministic step 결과로만 `simTick`을 올린다. interactive 세션은 `beginNew(initialTick: sim.simMs)` 뒤 갱신되지 않는다. backend는 interactive 세계 시각을 몸 시각(`body.t`)으로 쓴다(`bridge.py::_current_owner_tick`).
- 수정: `Coordinator.sessionSnapshot()`이 interactive일 때 최신 몸 패킷 시각을 보고한다. 이는 render snapshot과 참여 입력이 쓰는 것과 같은 시계다. `handle(ack:)`의 recorder도 interactive에서는 ACK의 멈춘 `sim_tick` 대신 이 값을 쓴다.
- 확인: 재실행 뒤 `t28045 #1 wind`, `t28125 #2 set_eye_state`, 눈 샘플 `t28165`, 세션 라벨 `시각 85925 ms`가 3D 라벨과 같은 시계로 움직였다. Swift bridge/lab/v4/v4timing 모두 통과했다.

### B. 뇌 점군 클릭 직접 자극이 기록되지 않음 (동선 3)

- 현상: 점군을 클릭하면 `⚡ M_IPNm11D + CB1783 · central (140)`가 자극되지만 타임라인과 실험 기록에 남지 않았다. `자극하기` 버튼은 `direct_neural`로 기록된다.
- 수정: `BrainWindowController.onClickStimulus` 콜백을 추가했다. 자극 동작 자체는 바꾸지 않았다. Lab은 이 콜백으로 `noteLocal(... .directNeural)`과 `recorder.mark(kind: "direct_neural")`를 남긴다.
- 확인: 재실행 뒤 `t17365 stimulate brain click ⚡ 다가오는 물체 감지 (LC4/LPLC2) · 왼쪽 (228 neurons) ×0.25 400 ms`가 남았다.

### C. 1인칭 눈이 충돌 구 밖에 있어 벽에 막히면 벽이 사라짐 (동선 4)

- 현상: 참여 1인칭으로 W를 눌러 상자에 닿자 상자가 화면에서 사라졌다. 통과처럼 보였다.
- 백엔드 판정: `app_path_box_probe.py`로 같은 조건을 헤드리스 재현했다(기본 상자, 스폰 (24,0,2.5), interactive `step()`). x = 52.507에서 멈췄고, 떼면 52.500에서 정지했다. 물리 통과는 없다(`app_path_box_probe.txt`).
- 원인: 1인칭 눈이 구 중심에서 앞쪽 `r×1.05`(2.625 mm)에 있다. 막힌 상태에서 눈은 x = 55.13으로, 상자 면(x = 55) 안쪽에 들어간다.
- 수정: `view_stream.py`와 `WorldViewer.participantCameraPose`의 눈을 `r×0.6`(구 안쪽)으로 옮기고, 1인칭 프레임에서만 참여체 자기 geom을 숨긴다. `LabProtocol.swift`의 카메라 fixture도 새 값으로 바꿨다.
- 확인: `first_person_render_probe.py`로 같은 MjData를 렌더했다. 수정 전 공식은 상자 픽셀 0%(`first-person-1.05.png`), 수정 후는 100%(`first-person-0.6.png`)였다. **실제 앱 화면 재확인은 아직이다.**
- 미해결: 첫 시도에서 S로 약 10–20 mm 물러나도 상자가 다시 보이지 않은 이유는 아직 설명하지 못했다. 그 사이 capture 중 마우스 이동이 시선을 돌렸을 수 있다. 재확인 때 조감 시점으로 같이 본다.

### D. `참여` 클릭만으로 capture가 켜져 마우스 이동이 시선을 돌림 (동선 4)

- 현상: `참여`를 누른 뒤 캔버스로 마우스를 옮기면 그 이동이 시선 회전으로 들어갔다. 1인칭 화면은 바닥만 보였다. 3인칭에서도 시선이 크게 숙여진 것을 확인했다.
- 원인: V5.5 설계상 `참여` 클릭이 capture를 켜고 3D 화면을 first responder로 만들었다(README에도 기록됨). V5.5.1 계획 §3은 “3D 캔버스 클릭으로 capture”다.
- 수정: `viewModeChanged`는 capture를 켜지 않는다. 3D 화면 클릭(`onPlayerCaptureRequested`)만 capture를 시작한다. 캡처 전 안내 문구와 README를 바꿨다. **GUI 재확인은 아직이다.**

### E. 참여 시작 첫 명령의 tick이 세션 시작 tick으로 찍힘 (A 보완)

- 현상: `#1 set_player_active`가 `t45532`(뇌 시각)로 찍혔다. 세계 시각은 18525였다. 이후 명령(`#2 wind t64905`, 3D 65185)은 정상이었다.
- 수정: 세션 시작 직후 bridge에 몸 패킷이 없을 때를 대비한다. `Coordinator`가 마지막으로 본 세계 시각을 유지한다. bridge 락과 Coordinator 락은 겹쳐 잡지 않는다. **GUI 재확인은 아직이다.**

### 참고: 이번 작업 중 제가 만든 회귀

1인칭 geom 숨김을 넣다가 `view_stream.py`에서 `except` 블록의 `return`이 1인칭 분기 안으로 들어갔다. 그 결과 1인칭에서 프레임이 갱신되지 않았다. GUI에서 발견해 바로잡았다. 헤드리스 probe는 `render_if_due`를 거치지 않아 이 경로를 잡지 못했다.

## 사용성 관찰 (결함 판정 보류)

- capture 중에는 창 안의 모든 마우스 이동이 시선 회전으로 들어간다. capture 상태에서 시점 팝업을 쓰려고 마우스를 옮기면 시선이 크게 돌아간다. 계획의 해제 조건(텍스트 입력/사이드바/Esc/비활성화)에 “다른 컨트롤 조작”은 없다.
- inspector 요약의 “참여자 없음”은 *선택된* 참여자가 없다는 뜻이다. 참여 중에도 그렇게 표시돼 헷갈린다.
- `경기장 둘러보기` 시점은 바닥이 화면 위쪽으로 보이는 방향으로 렌더된다. 조감으로 쓰기 어렵다.
