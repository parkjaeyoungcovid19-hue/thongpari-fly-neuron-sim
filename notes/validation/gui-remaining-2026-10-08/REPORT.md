# 남은 GUI 검증 실행 결과 — 2026-10-08

실제 서명된 앱과 real FlyGym/MuJoCo headless 백엔드를 새 프로세스로 실행하고 Computer Use로 조작·화면 확인했다. 먹이 용량·재사용·소진·섭식 중 삭제, 자동차·덫, Data 카드 일시정지·재개·출처 안내, 기록 시작·저장·종료는 아래 범위에서 통과했다. **V5 전체 수용 판정은 여전히 미완료**다. 물리 이벤트 기록 누락과 물체 상태 문구 결함이 재현됐고, BB 시각 효과·정량 입력/렌더 지연 및 일부 대조 시나리오는 충분한 증거를 얻지 못했다.

성능 측정 도중 사용자가 컴퓨터 발열 때문에 전원을 분리했다고 확인했다. 따라서 이번 저속 표본만으로 지속 AC 성능 결함이나 회귀를 확정하지 않는다. 추가 성능 구동을 중단하고 앱/백엔드를 종료했다. 전원 설정·시스템 외관·키 매핑 변경, 제품 코드 수정, 빌드·회귀 재실행, 커밋·푸시는 하지 않았다. 기존 dirty 변경을 보존했다.

## 실행 대상과 증거 수준

- 저장소: `siliconfly`, HEAD `7cea100afb9b347f4fd24c354f9523eab6df00d8` + 기존 미커밋 변경. 부모 bridge는 사용하지 않았다.
- 앱: `/Users/apgx/.codex/visualizations/2026/10/07/01a116f3-6bf3-7f13-ac54-ab981b63e47b/Thongpari Virtual Fly Lab.app`. 직전 V6.7/V7.1 검증의 서명된 앱을 실행했다.
- macOS 26.6.2 / Mac14,2 / 메모리 8 GiB. 한국어·현재 다크 외관에서 검증했다.
- 주 실행: 앱 PID 89918, 앱 소유 real 백엔드 PID 89920, bridge `127.0.0.1:54572`, 영상 `:54573`. mock이나 API 주입으로 GUI 입력을 대체하지 않았다.
- 기록 session `C0F49BDB-CE77-478E-90FC-570D73C8D1EA`, epoch 1, interactive, protocol 4, neural tick 1 ms / experiment quantum 20 ms.
- [환경·해시·서명·정리 결과](environment-and-cleanup.json), [실행 전 상태](status-before.txt), [문서 갱신 전 상태](status-after.txt), [현재 실행들만 추출한 backend 로그](bridge-current-runs.log).
- 앱 실행 파일 SHA-256 `066a2895ca3a7f8c33836fdb2e5558544637d286b0ec803f52da331344bfef8a`. checkout 실행 파일은 서명된 파일과 해시가 다르며 `f6f6d5b502052a8532747daf46e2edaa5f578fa63473f816785858f548ca0072`다. 두 파일을 동일 바이트라고 주장하지 않는다.
- PNG는 실제 창 캡처, 같은 이름의 AX 파일은 해당 순간의 화면 문구다. AX만으로 색·기하·움직임의 시각 수용을 대신하지 않았다. 파일명에 `attempt` 또는 `small`이 있어도 창 축소가 성공했다는 뜻은 아니다.

## 실제 GUI 결과

| 항목 | 판정 | 관찰과 증거 |
|---|---|---|
| 서명된 native 앱 실행·실제 백엔드 연결 | PASS | [01](01-native-launch.png), [AX](01-native-launch.ax.txt). prewarm 뒤 실제 잔디·파리·물체와 연결 상태 확인. 직전 기록의 Finder attachment 실패는 이 실행에서 재현되지 않음 |
| 자동차 생성·주행 | PASS: 조작/실물/이벤트 | `gui_car` 생성 #1, speed 20 mm/s·distance 10 mm 주행 #2, drive_complete 표시. [02](02-car-drive.png), [03 AX](03-trap-trigger.ax.txt). 정확한 이동 거리·접촉력 측정은 별도 |
| 덫 trigger→closed→rearm | PASS: 조작/실물/이벤트 | `gui_trap` 원점 배치 뒤 trigger t20, closed t86; #5 arm_trap, armed t9585. [03](03-trap-trigger.png), [04](04-trap-rearm.png) |
| BB 장비·발사 | PARTIAL | G #7 equip 적용, F #8 fire 적용, bb_fired t32405→bb_expired t32467. [06 AX](06-bb-fire.ax.txt). 짧은 발사 궤적·실제 명중 장면을 직접 포착하지 못했으므로 시각 수용 PASS 아님 |
| 음식 8개·9번째 거절 | PASS | 일시정지 중 #13–#20 생성 요청 후 재개. 실제 8/8, 9번째 #20 `no free food slots` 거절. [13](13-food-capacity-rejected.png), [AX](13-food-capacity-rejected.ax.txt) |
| 삭제 뒤 슬롯 재사용 | PASS | #21 capacity8 삭제 후 7/8, #22 capacity9 생성 후 8/8. [14](14-food-slot-reused.png). 상태 라벨 오류는 F-02 |
| 자연 소진·슬롯 반환 | PASS: 화면 이벤트/목록 | 크기 0.6 mm sugar를 입 앞에 배치, begin t40→end t80(contact .06 s)→food_eaten t80. food 6/8, 해당 ID 목록에서 제거. [18](18-food-eaten.png), [AX](18-food-eaten.ax.txt) |
| 섭식 중 삭제·같은 ID 재사용 | PASS: 화면 이벤트/목록 | 소진된 `gui_capacity6` ID로 grape 재생성 #31. body reset #32 후 pause t20에서 feeding_begin 확인, 삭제 #33 뒤 재개: ACK와 feeding_end t20, contact .02 s. [19](19-feeding-before-delete.png), [20](20-feeding-deleted.png). recorder에는 이 사건이 누락됨 |
| body reset 동선 | PASS: 제어·시각 초기화 | 반복된 reset_body ACK, world 시각이 t20 근처로 초기화. world/all reset 때 모든 풀 반환·신경 상태 재현은 이번에 미검증 |
| Data 실행→pause→resume | PASS: 카드 표시 정책 | 모델 지표/GF는 pause 때 —, 유한 발화율은 마지막 값 유지, 재개 후 값 갱신. [09](09-data-paused.png), [11](11-data-resumed.png), [16](16-paused-during-feeding.png) |
| 읽기 전용 카드 출처 안내 | PASS: 관찰된 카드 | Sugar GRN 클릭으로 출처·창 범위·EMA 설명 표시, lab command ID 증가 없음. 배고픔 미지원 표시. [10](10-card-source.png), [29](29-flow-data.png). 모든 카드의 내부 무변이는 과거 자동 검증과 별도 |
| Brain 샘플 표시 | PASS: 문구·화면 | 일시정지 상태에서 sampled spike·시뮬레이션 집계의 의미를 표시. [17](17-brain-paused.png). 정확한 스파이크 시각/횟수를 시각 반짝임으로 검증한 것은 아님 |
| 같은 창 내 World/Stimulus/Brain/Data/Experiment | PASS: 화면 이동 | Inspector가 바뀌고 Viewer는 같은 창에 유지. [27](27-experiment-panel.png), [29](29-flow-data.png). 현재 별도 Settings 페이지는 없고 언어·참여 키·감도 제어가 toolbar/World에 있음 |
| 구간 표시·직접 신경 자극 구분 | PASS: UI 요청·기록 | baseline marker, GF preset 직접 자극 표시, recorder에 marker/preset/direct_neural 각각 1개. [28 AX](28-experiment-marker-stim.ax.txt). 특정 도피 행동이나 순간 GF spike 포착을 성공 조건으로 삼지 않음 |
| pause 중 카메라 탐색 | PASS: 관찰 카메라 | world t233481·유한 카드값 유지, drag 뒤 실제 시점 변경. [30](30-pause-before-camera.png), [31](31-pause-camera-drag.png). 이동 중 player/brain 전체 tick 동결은 별도 시나리오 |
| Esc·textfield·창 전환 입력 해제 | PARTIAL | 활성 capture 화면 확보 후 W 유지와 textfield 클릭, 필드에서 W가 `ㅈ`로 입력됨. Cmd-Tab 뒤 capture 해제·복귀 화면 확보. [36 AX](36-capture-with-visible-form.ax.txt), [37](37-held-w-visible-text-focus.png), [38](38-text-focus-key.png), [39 AX](39-capture-before-window-switch.ax.txt), [40 AX](40-window-switch-release.ax.txt), [41 AX](41-window-reactivated.ax.txt). player pose/각 seq의 중립 ACK·재진입 이동 불변은 기록 형식상 증명 못함 |
| 집기·놓기·운반 막힘 | PARTIAL: 명령/이벤트 통과 | E #38 grab, primary click #39 place, E #40 재집기, #45 grab 후 W에 carry_blocked 표시, Observe #42/#46에서 inactive place. [23 AX](23-flow-grab-attempt.ax.txt), [24 AX](24-flow-placed.ax.txt), [37 AX](37-held-w-visible-text-focus.ax.txt), [26](26-flow-observe.png). 1인칭에서 분홍 면이 뷰를 가리는 장면이 있어 이동 궤적/배치의 시각적 정확성은 미수용 |
| 다가가기 | PARTIAL | #41 approach_object ACK와 approach_complete 이벤트 확인. [25 AX](25-flow-approach.ax.txt). 시작 직후 완료되어 실제 연속 이동 궤적·감각 반응의 인과 관계는 이 실행으로 확인 못함 |
| 기록 시작→저장→종료 | PASS: 파일 flush | [43](43-recording-stopped.png) `recording saved`. metadata/CSV/JSONL 재독해 성공, 끝에 recording_stopped. 이벤트 완전성은 F-01로 FAIL |
| 창 확대/축소·스크롤 | PARTIAL | zoom/restore 및 Inspector 스크롤 확인. [44](44-window-zoom.png). edge drag가 카메라 조작으로 해석되어 최소 창 크기를 확보 못함. `42`/`45` 캡처는 최소 크기 PASS 근거가 아님 |
| 지속 AC body≥30 Hz | INCONCLUSIVE | 6표본 34/34/35/31/26/20 Hz, 전원 분리·사용자 발열 확인. 조건 통제가 없어 앱 고유 성능 결함으로 단정하지 않음. 아래 조건 기록 참조 |
| viewport FPS·최대 feedback gap·look/pick 지연 | NOT VERIFIED | stream 설정 24 fps는 측정 FPS가 아님. GUI에 정량 계측이 없고 이번 record에 player-input/pick별 원자료가 없음 |
| 정상 종료와 backend 정리 | PASS | ⌘Q 종료. 뒤 UI 관찰 호출이 앱을 다시 실행한 도구 동작이 있어 추가 실행도 즉시 ⌘Q로 종료. 마지막 `ps`에 앱/bridge 없음, 54572/54573/55389/55390 listener 없음 |

일시정지 중 legacy spawn/move/delete는 재개까지 대기한 경우가 있다. Edit의 `transaction: paused` 정책과 혼동하지 않았고, 이러한 대기 시간을 일반 running ACK latency로 계산하지 않았다. 초기 `08`은 capture 전제가 충분히 확인되지 않아 최종 입력 검증 근거에서 제외했다. `16`은 파일명과 달리 활성 섭식 순간을 포착하지 못했다. live Sugar GRN 양성 반응의 인과 검증도 미완료다.

## 재현된 결함

### F-01 · P2 · 화면 물리 이벤트가 실험 기록에 저장되지 않음

**실행 증거 + 코드 확인.** recording 중 화면 타임라인에서 feeding_begin/end, food_eaten, trap_triggered/closed/armed, drive_complete, bb_fired/expired, object_grabbed/placed, carry_blocked를 확인했다. 저장을 끝낸 [events.jsonl](recording/events.jsonl)은 총 116행이며 종류는 recording_started 1, lab_command 46, lab_command_result 46, reset 7, pause_requested 6, resume_requested 6, marker 1, preset 1, direct_neural 1, recording_stopped 1이다. **물리 사건 기록은 0개**다. [재독해 요약](recording-summary.json).

`LabWindow.swift:3105–3111`의 backend event 소비는 `noteLocal(... kind: .physical ...)`로 화면 타임라인에만 추가한다. `LabWindow.swift:2108–2116`의 noteLocal에는 recorder.mark가 없다. command/result는 각각 `LabWindow.swift:2097` 부근과 `2822`에서 별도로 기록한다. 따라서 저장 버튼 성공과 명령 ACK 보존만으로 섭식 구간·덫·BB·접촉 사건을 사후 재구성할 수 없다.

후속 수정은 원래 event 이름·대상·detail·reason·backend tick 및 session/epoch를 원형대로 기록하고, 한 번 받은 사건을 한 번만 저장하는 회귀 검증이 필요하다. 이번에는 구현하지 않았다. 별도 관찰: `LabProtocol.swift:1398` CSV header에는 GUI에 있는 Sugar GRN/MN9/taste/eating ID 컬럼도 없다. 이는 새 관측값의 export 범위 한계이며 물리 이벤트 누락과 구분한다.

### F-02 · P2 · 이동·크기 변경·삭제 뒤 물체 상태 라벨이 갱신되지 않음

**실행 재현 + 코드 확인.** 9번째 food 거절 #20 뒤 #21 삭제가 적용돼 7/8로 바뀌어도 이전 8/8 오류가 남았다. 재생성 #22 뒤 #23 move/#25 resize/#24 delete 및 #33 delete 후에도 이전 “만들기 완료”가 계속 표시됐다. `gui_flow`에서도 #36 move/#37 resize가 적용됐지만 상태 라벨은 #35 만들기 완료였다. [14](14-food-slot-reused.png), [20](20-feeding-deleted.png), [22](22-flow-object-moved.png). 타임라인과 실제 물체 목록은 후속 ACK/상태를 표시한다.

`LabWindow.swift:2184–2203` move/resize/delete는 lastObjectCommandID/description을 바꾸지 않는다. `2833–2836` ACK 처리는 그 ID가 일치할 때만 상태 라벨을 갱신한다. 결과적으로 사용자는 이전 오류 또는 다른 명령의 성공을 현재 조작 결과로 읽게 된다. 후속 수정은 create/toy뿐 아니라 관련 물체 명령 전체에 sending/applied/rejected 상태를 연결하고, old ACK가 최신 문구를 덮지 않는지 검증해야 한다.

### 추가 시각 관찰 · 원인 미확정

1인칭 조작 시 `22`–`25`, `32`–`41` 일부 화면이 분홍 면으로 거의 채워졌다. E/클릭 명령과 backend event는 처리되고 Observe 복귀 후 잔디·차·먹이·상자가 보였다. 현재 증거는 객체 근접/가림 또는 카메라 문제의 원인을 확정하지 못하므로 제품 코드의 특정 실패로 지정하지 않았다. 이 상태에서 운반/BB의 시각 수용을 PASS로 처리하지 않았다. 깨끗한 장면의 participant camera·object pose·depth를 함께 기록한 후 재현 여부를 확인해야 한다.

만들기 직후 Z/size가 기본값처럼 보인 시도도 있었지만 shape 전환/필드 commit의 영향을 분리하지 못했다. move/resize로 원하는 값을 적용해 후속 검증했고, 이 관찰을 독립 확정 결함으로 올리지 않았다.

## 전원과 성능 조건

전원 연결 요청 후 사용자 “연결했어”와 `pmset -g batt`의 AC charging 76%를 확인했다. [전원 프로파일](power-profiles.txt)은 AC lowpowermode 0 / Battery lowpowermode 1이며, 설정을 바꾸지 않았다. [전원 로그](power-timeline.txt)는 19:01:11/16 AC, 19:19:46 Battery라는 요약만 제공한다. 요약은 전원 전환의 정확한 시각을 보장하지 않는다. 사용자는 후속 메시지에서 발열 때문에 전원을 뺐다고 확인했다. 종료 전 [현재 전원](power-final.txt)은 Battery 79%였다.

| 캡처 저장 시각 KST | 표시 body Hz | sim/wall | 증거 |
|---|---:|---:|---|
| 19:10:00 | 34 | .63 | [표본 0](21-ac-steady-0.ax.txt) |
| 19:10:11 | 34 | .71 | [표본 1](21-ac-steady-1.ax.txt) |
| 19:10:31 | 35 | .71 | [표본 2](21-ac-steady-2.ax.txt) |
| 19:10:49 | 31 | .57 | [표본 3](21-ac-steady-3.ax.txt) |
| 19:11:06 | 26 | .50 | [표본 4](21-ac-steady-4.ax.txt) |
| 19:11:27 | 20 | .41 | [표본 5](21-ac-steady-5.ax.txt) |

첫 표본부터 마지막까지 약 87.4초다. 5초씩 균등한 여섯 창이라고 해석하면 안 된다. 표시 Hz는 `FlyGymBridge.swift:303–312`의 최근 body 수신 간격 평균을 정수로 표시한 값이다. 여섯 정수의 단순 평균 30은 지속 30 Hz 수용 근거가 아니다. 이후 배터리 조건에서 7–20 Hz도 표시됐다. [thermal 조회](thermal-final.txt)의 “No thermal warning”은 사용자가 느낀 발열이나 throttling이 없다는 증명이 아니다. 센서 온도/연속 전원 상태를 계측하지 않았다. **성능 게이트 미확정, 저하 원인 미확정**으로 둔다. 직전 별도 run의 AC 31.6–33.6 Hz PASS 자료는 과거 범위의 증거로 유지하며 이번 조건과 섞지 않는다.

[명령 ACK 관찰](command-ack-observations.json)은 46개 ID가 모두 대응한다. #20만 의도한 capacity rejection이며 나머지는 applied다. running #35–#42는 recorder 요청→화면 ACK 소비 wall time 90.390–229.065 ms다. 이는 transport round trip에 UI refresh가 포함된 값이며 look/pick latency·최대 body gap을 대신하지 않는다. paused 대기 명령은 이 부분집합에서 제외했다.

## 기록과 실행 확인

- 원본 기록: `/Users/apgx/Documents/ThongpariFlyNeuronSimExperiments/experiment-20261008-190025`. [복사본](recording/metadata.json), [JSONL](recording/events.jsonl), [CSV](recording/telemetry.csv). 원본을 이동·삭제하지 않았다.
- duration 1177.832 s, telemetry 11,762 data rows, JSONL 116 events. 마지막 event recording_stopped(`user stop`), GUI recording saved 확인.
- `codesign --verify --deep --strict <위 앱>` exit 0. source/앱 해시는 환경 JSON에 저장.
- 파일 parse·복사·ACK 대응·환경/정리 스크립트 exit 0. 최종 ps exit 0 + 관련 프로세스 0개. lsof exit 1 + 결과 없음은 검사한 4개 포트에 listener가 없다는 뜻이다.
- 좌표 배치를 돕기 위한 offline RealFlyBody mouth reference만 별도로 실행: 첫 시도는 BrainPacket를 step_exact에 전달해 AttributeError(exit 1), LocomotorCommand로 고친 [후속 조회](offline-mouth-reference.log)는 exit 0. 독립 프로세스이며 TCP/UI 입력을 하지 않았고 GUI acceptance/성능 결과로 사용하지 않았다.
- 기존 build/신경·GPU/real 자동 검증을 이번에 재실행하지 않았다. 제품 코드가 바뀌지 않은 GUI 감사이며 발열 후 부하를 추가하지 않았다.
- ⌘Q 뒤 getAXState가 앱을 다시 실행하는 도구 동작을 한 번 겪었다. 두 번째 backend(:55389/:55390)는 acceptance 측정에 쓰지 않았고 바로 종료했다. 이후 종료 확인은 CLI로만 수행했다.

## 남은 수용 조건

V5-01 동일 seed의 카메라 무자극 대조, V5-02 참여체가 실제 fly-eye 영상에 나타나는 양성/음성 대조, V5-03 실제 접촉/비접촉 대조는 이번 GUI run에서 수행하지 못했다. V5-04는 표시·focus 해제까지, V5-05는 관찰 pause와 카메라까지, V5-06은 명령/이벤트 동선까지 확인했으며 전체 수용으로 올리지 않는다.

다음 검증은 F-01/F-02 수정 후 새 서명 앱에서 같은 GUI 순서를 재실행하고, 1인칭 가림·BB 궤적/명중·live GRN 양성·최소 창 배치 및 per-sequence input 중립 결과를 보완해야 한다. 지속 AC body Hz·viewport FPS·최대 gap은 냉각되고 전원 조건을 연속 기록할 수 있는 별도 실행에서 확인한다. V6.7/V7.1의 기존 수용을 취소하거나 V7.2 이후 구현을 시작하지 않았다.

## 후속 수정 (2026-10-08, Claude)

- **F-01 수정.** `LabWindow.swift` 이벤트 소비 루프가 timeline 행과 함께 `recorder.mark(kind: "lab_event", …)`를 남긴다. detail은 UI 언어와 무관한 `LabEventNotice.recordDetail`(`LabProtocol.swift`)로, backend 이벤트 이름 원형 뒤에 decode된 필드를 wire 키로 붙인다(`id`, `object_id`, `food_variant`, `contact_s`, force·`duration_ms`, `sim_tick_ms`, 마지막에 `reason`). session/epoch/sim_tick은 다른 행과 같은 snapshot에서 채운다. 이벤트는 bridge serial cursor로 한 번만 소비되므로 중복 기록되지 않는다.
- **F-02 수정.** move/resize/delete/approach도 create·drive·re-arm과 같은 `trackObjectCommand`를 거쳐 `lastObjectCommandID`와 "요청 보냄…" 문구를 갱신한다. ACK 처리는 기존대로 최신 ID와 일치할 때만 라벨을 바꾸므로 이전 ACK가 최신 문구를 덮지 않는다.
- 검증: `./build.sh` 성공, `--labtest` ALL PASS(새 검사 `lab_event recorder line keeps the raw event name and wire fields` 포함), `--bridgetest` ALL PASS, `--worldeditortest` 0 failures, `--observationaudittest` 0 failures. 신경·GPU 경로는 바꾸지 않아 `--simtest`/`--gpucheck`는 재실행하지 않았다.
- **미검증:** 새 서명 앱으로 같은 GUI 순서를 다시 실행해 events.jsonl의 `lab_event` 행과 상태 라벨 갱신을 실제 화면에서 확인하는 일은 남아 있다. CSV header의 Sugar GRN/MN9 컬럼 부재는 그대로다.
