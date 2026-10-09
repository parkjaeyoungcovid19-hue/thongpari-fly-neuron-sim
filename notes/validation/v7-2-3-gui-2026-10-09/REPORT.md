# V7.2 / V7.3 실제 GUI 검증 — 2026-10-09

판정: 전체 GUI 승인은 보류. 선택과 자극의 분리는 확인했으나, V7.2 한국어 한도 표기가 잘못되었으며 기존 그래프 정지/조준점 대비 문제와 언어 변경 시 창 크기 변경을 확인했다. 아래 PASS는 해당 GUI 관찰 범위의 판정이며 GPU 내부 집계의 독립 검증이나 성능 판정이 아니다.

## 실행·환경

- branch `v7.2-7.3`, HEAD `4848ee90b9b4d8acd10e715f32cc7e17124f2226` (시작/종료 동일).
- 패키지 `dist/Thongpari Virtual Fly Lab.app`; 실행 파일 SHA-256 `e8785ad38575e3a8cdf441317227347ac974482ce31d26bc365f83e063a6a198` (디스크 및 실행 중 translocation 복사본 확인).
- 실제 패키지 PID 45552 → 자식 45575, command/render 포트 62742/62743. 두 번째 패키지 PID 46447 → 자식 46449, 64065/64066.
- dev overlay PID 45593, 46188, 최종 단독 재실행 46307. overlay는 backend 없이 실행. 46188은 화면에 표시된 다른 에이전트의 작업으로 종료되어, 46307에서 V9/M을 재검증했다.
- `./run_flygym.sh --mock`: 앱 47289, bridge 47297 → 47412 → 47429 → 47440 → 47450, command 포트 50477. script의 rebuild 조건이 성립하지 않는 것을 확인한 뒤 실행했고 mock.log에 build가 없다.
- Computer Use로 패키지 실화면/AX/좌표 클릭. dev CLI 앱은 CUA의 getApp에서 Invalid app이어서 사용자가 허용한 AppleScript/CGEvent/screencapture로 검증했다. 뇌 선택은 실제 마우스 이벤트였다. API/TCP 명령 주입은 하지 않았다.
- 제품 코드/문서 수정, 빌드/패키징, commit/push/git 상태 변경, 설치, 시스템 설정 변경, 서브에이전트 생성 없음. 증거만 본 폴더에 작성.
- 초기 직접 실행은 AMFI 종료 및 CUA 경로 연결 실패가 있었으나 이후 실제 dist 패키지의 실행 중 translocation 경로에 연결했다. 별도 다른 에이전트가 /Applications 복사본을 준비한 내용이 데스크톱에 보였으며 그 복사본은 이 검증 대상으로 사용하지 않았다. 최종 dist hash는 동일.

## 흐름별 결과

| 흐름 | 판정 | 실제 화면·기록 | 주요 증거 |
|---|---|---|---|
| V1 | PASS | embedded switch OFF, 선택/비자극 설명. floating title 읽기 전용도 V9에서 확인 | [01](01-v1-default.png), [AX](01-v1-default.ax.txt), [11](11-overlay-select.png) |
| V2 | PASS | cyan 선택 표시, 이름·관측 수·root/type/class·last 1 s/retained spikes/Hz/ticks. 선택 직후 partial/missing ms, 이후 complete 및 tick/count 진행 | [02](02-v2-selected.png), [AX](02-v2-selected.ax.txt) |
| V3 | PASS | recording을 켜고 서로 다른 지점 19회 선택. injecting 없음, DIRECT-NEURAL 없음, JSONL direct_neural 0. CSV 315행 모두78열 | [03](03-v3-no-stimulation.png), [events](recording-select/events.jsonl), [검사](recording-checks.json) |
| V4 | FAIL | 328개 pick: 256 관측/72 제외. en은 정확, ko는 한도72/제외256으로 역전 | [28](28-v4-limit-ko-defect.png), [AX](28-v4-limit-ko-defect.ax.txt), [29](29-v4-limit-en.png) |
| V5 | PASS | ON 실제 click → injecting/자극 ring/brain click 400ms timeline. OFF로 돌아와 실제 click → 선택만 | [04](04-v5-injecting-paused.png), [AX](04-v5-injecting-paused.ax.txt), [13](13-overlay-injecting.png) |
| V6 | PASS | OFF 상태 GF population button 및 MDN direct neural preset이 주입. preset+direct_neural 기록 | [08](08-v6-preset-off-injection.png), [AX](08-v6-preset-off-injection.ax.txt), [events](recording-preset/events.jsonl) |
| V7 | PASS | pause end tick 동일, resume 증가. Brain reset neural epoch 0→1, tick1부터, selection 유지. Clear selection 비움 | [05](05-v7-paused.png), [06](06-v7-reset-epoch.png), [AX](06-v7-reset-epoch.ax.txt) |
| V8 | FAIL | ko/en/ko relabel은 동작. V4 한국어 숫자 오류와 언어 변경 창 크기 변경(D). 텍스트 자체 중첩은 관찰하지 않음 | [07](07-v8-brain-en.png), [28](28-v4-limit-ko-defect.png), [29](29-v4-limit-en.png) |
| V9 | PASS | dev no flags, menu Show/Hide Brain으로 재개방. OFF/read-only 실제 click 선택, ON 실제 click injecting379 확인, menu Quit | [11](11-overlay-select.png), [AX](11-overlay-select.ax.txt), [13](13-overlay-injecting.png), [AX](13-overlay-injecting.ax.txt) |
| C | PASS | 5개 page와 긴 inspector 끝까지 방문. World/Stimuli/Brain/Data/Experiment controls 유지. docs/images/ui-*와 비교. 지정된 이전 validation PNG는 로컬에 없어 그 비교는 미수행 | [16](16-c-world-first.png), [17](17-c-stimuli-first.png), [18](18-c-stimuli-bottom.png), [19](19-c-data-first.png), [24](24-c-experiment-first.png) |
| D | FAIL | ko/en/ko/en/ko 후 5페이지 재방문: control pile-up은 없으나 창이1320×820→약1380×640으로 바뀜. 독립 mock ko→en도1117×640 및 toolbar overflow | [25](25-d-experiment-after.png), [26](26-d-world-after.png), [27](27-d-stimuli-after.png), [30](30-d-data-after.png), [51](51-d-mock-language.png) |
| F | FAIL | 6 graphs 존재, running 파형/값 변화, 카드 click source 설명 표시. pause 후 tick 고정인데 몸·눈 history가 0선으로 소실. 전체 freeze 기준 불통과 | [20](20-f-graphs-bottom-running.png), [21](21-f-graphs-top-running.png), [22 AX](22-f-graphs-paused.ax.txt), [42](42-f-middle-paused-a.png), [44](44-f-body-eye-paused.png), [source](graph-source.txt) |
| G | PASS |11 presets/4 markers 및7 key popup 존재. marker+MDN preset 실행·기록, start/stop. 세 recording CSV header sugar_grn_hz/mn9_hz 포함, 모든행78열 | [24](24-c-experiment-first.png), [AX](24-c-experiment-first.ax.txt), [events](recording-preset/events.jsonl), [검사](recording-checks.json) |
| H | PARTIAL |7종 생성, car drive_complete, trap trigger/closed/rearm 및 화면 상태. World/Body/Brain/Everything reset 모두 실행. interactive reset은 backend session epoch1 유지: 새 backend epoch에서 지연된 old-epoch event 차단은 이 실행으로 입증 못함 | [31](31-h-trap-triggered.png), [35](35-h-resets.png), [events](recording-world/events.jsonl) |
| I | PASS | ramp Move80→90, Z30°, SizeX12, Tilt15→25 적용; Move/Tilt Undo/Redo 성공, 거절 오류 없음. Duplicate/Delete/Show in view. paused save→load 성공, 설정-only 안내 | [32](32-i-ramp-edited.png), [AX](32-i-ramp-edited.ax.txt), [33](33-i-duplicate.png), [34](34-i-scene-loaded.png), [Scene](Scene.flyworld), [events](recording-world/events.jsonl) |
| K | FAIL | 실제 W/S 입력, 참여 카메라, G/F equip/fire, E grab/place, held 상태 및 Esc capture 해제 확인. 검은 하늘에서 aim mark 식별 불가. 이동거리/운반 변위를 수치나 비교 화면으로 확정하지 못함 | [36](36-k-bb-fired.png), [37](37-k-grabbed.png), [38](38-k-placed-esc.png), [AX](38-k-placed-esc.ax.txt), [events](recording-world/events.jsonl) |
| L | PASS | Orbit/Follow/Free/Participant 전환, arena/파리/참여자 렌더. 관찰 Free 실제 drag로 시점 변화, 실행 중 fly/body 계속 변화. black sky는 장면 배경이며 전체 검은 화면 아님 | [39](39-l-orbit.png), [40](40-l-follow.png), [41](41-l-free.png), [37](37-k-grabbed.png) |
| M | PARTIAL | overlay fly 실화면 렌더·위치 변화, menu로 Lab/Brain 개방 및 Quit. crowded menu bar에서 🪰 glyph 자체를 PNG로 명확히 입증하지 못함; AX menu 항목으로 조작 | [10](10-overlay-current.png), [14](14-overlay-lab.png), [15](15-overlay-moving-screen.png), [10 AX](10-overlay-default.ax.txt) |
| N | PASS | mock window 실행. owned bridge SIGTERM 후 실제 restart button4회, 모두 복구. lsof 줄수 baseline/매회68. 실제 UI 클릭 뒤 AX 스크립트 return 변환만 -1700 발생, 새 PID/화면으로 성공 확인 | [45](45-n-mock.png), [46](46-n-restart-offered.png), [47](47-n-restart-1.png), [50](50-n-restart-4.png), [기록](mock-restarts.txt) |
| O | PASS | 모든 owned PID/bridge 없음, defaults 모든키값 백업과 같음, HEAD/hash 및 git status 동일 | [PID](cleanup-final.txt), [pgrep](owned-pgrep-final.txt), [settings](settings-restored.txt), [defaults](defaults-after.txt), [git](git-after.txt) |

## 결함과 재현

1. **V7.2 신규 — 한국어 관측 제외 수/한도 역전.** Brain에서 select mode로 LLPC1+LLPC2 optic dense cluster(328)를 실제 클릭한다. 예상: 한도256, 관측256, 미관측72. 실제: 정확 관측256 뒤 `(한도 72개를 넘은 256개는 관측 안 함)`. English 전환하면 `(72 more beyond the 256 limit are NOT observed)`로 정상. 증거28/29 및28 AX. `Sources/Lab/LabWindow+Pages.swift:261–262`에서 인수 omitted, limit 순서가 한국어 placeholder 순서와 반대. 실제 관측 버퍼가72개라는 뜻은 아니며 표시 결함이다.

2. **기존 — pause 중 graph history가 계속 밀려나감.** real backend running Data에서 파형을 확인하고 toolbar Pause, 몸/눈 그래프를 계속 관찰한다. 예상: 시뮬레이션 tick과 모든 그래프가 멈추며 history 유지. 실제: body tick36120은 고정인데 몇십 초 뒤 몸과 눈이0선으로 대체된다. 일시정지 시 몸 readout도0/눈 미렌더로 바뀐다. 증거20,42,44 및graph-source. 현재 `LabWindow.swift:1640–1663`는 window visible 조건만으로 append하며, `973945a`에도 같은 append 구조가 있다. 기존 커밋 GUI를 재실행한 것은 아니지만 동일 원인 코드가 리팩터링 이전부터 존재함은 확인.

3. **기존 — 밝은 appearance에서 aim mark가 검은 하늘과 구분되지 않음.** 현재 시스템 appearance 그대로 World→Participate, Participant1인칭 선택, 3D click capture 후 앞에 물체가 없는 검은 하늘을 본다. 예상: 중앙 조준점이 식별 가능. 실제: 검은 배경에서 식별 불가; 분홍색 상자를 앞으로 놓으면 검은 '+'가 보인다. 증거36(하늘),37(물체 위). `WorldViewer.swift:16`가 NSColor.labelColor를 사용하고 `973945a`의 해당 draw 코드도 동일. 시선 조작 후 조준 추적 전체와 이동·운반 변위는 정밀 확인하지 못했다.

4. **발생 시점 미확정 — 언어 변경이 창 크기를 바꿈.** 시작1320×820인 Lab에서 language ko→en 및 반복 toggle. 예상: 창 geometry/페이지 배치 유지, 번역만 변경. 실제: package에서 height640으로 변하고, mock에서 ko→en 뒤1117×640/toolbar overflow. 증거07,25–30,45(전),51(후). control 복제나 글자 중첩은 보이지 않았다. 다른 로컬 에이전트가 동시에 앱/GUI를 만진 증거가 있어 최초 package geometry 관찰만으로 회귀 시점을 단정할 수 없었다. mock에서도 재현됐고 제품 현상으로 기록하지만, refactor 신규인지 기존인지는 이전 바이너리 GUI 비교 없이 확정하지 않는다.

기존 REPORT의 F-01: 이번 world recording에는 car/trap/BB/grab/place의 lab_event23개가 기록되어 누락 현상은 이 샘플에서 재현되지 않았다. F-02: 생성·편집·복제·삭제 및 trap armed 표시가 갱신되는 것을 확인했다. 별도 legacy move/resize/delete 조합을 전부 재검사하지 않았으므로 완전 해결 선언은 하지 않는다.

## 제한·정리

- H의 delayed old-epoch event 차단, K의 이동거리/운반 변위·aim tracking 전체, M의 메뉴 glyph 실화면 증거가 불충분하다. NOT RUN으로 숨기지 않고 해당 흐름을 PARTIAL/FAIL로 기록했다.
- 지정된 두 이전 validation 폴더 PNG가 없어서 docs/images/ui-*만 시각 비교했다. raster/CSV exact-observation export는 범위 밖이므로 실행하지 않았다.
- 다른 에이전트가 overlay46188을 종료한 데스크톱 기록이 있고 창/화면 geometry도 변했다. V9/M은 단독46307로 다시 진행했으나 외부 조작 영향이 없는 과거-baseline 비교는 확보하지 못했다. 서브에이전트를 생성한 적은 없다.
- 낮은 Hz/DEGRADED는 판정에 사용하지 않았다. 모든 조작은 실제 GUI. recording 파일과 읽기 전용 코드 비교는 GUI 관찰의 보조 증거다.
- app normal Quit 또는 overlay 🪰 Quit; mock owned bridge만 SIGTERM으로 restart 시험. killall/pkill 및 타인 listener 연결/종료 없음. final owned pgrep/ps 결과 없음.
- defaults-before.plist를 import 후 defaults-after.plist와 Python plist dictionary 동등 비교: True, changed keys []. language뿐 아니라 자동 저장 nav/split/window 값도 복원. git-before/after는 동일한 untracked validation 폴더2개뿐이고 tracked diff 없음.
