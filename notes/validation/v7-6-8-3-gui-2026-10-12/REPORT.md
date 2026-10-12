# V7.6, V7.7, V8.1–8.3 실제 창 GUI 점검 (2026-10-12)

대상: /Users/apgx/Documents/Codex Projects/초파리/siliconfly/.claude/worktrees/v8.1-8.3, branch v8.1-8.3, commit 3788bd3a7ff9b63e58dd719d0cfdfa2127f0aaa2.

패키지: /private/tmp/claude-501/-Users-apgx/15bdfe32-9cc1-47a0-a875-7fe0011e431e/scratchpad/gui-v8/Thongpari Virtual Fly Lab.app. 실행 파일 SHA-256 bfaa14a4cd300ef63f3ec4c43c1a1af951341ad1c0507e458972a9a101a2a110.

Run A는 open -n으로 실행한 백엔드 없는 실제 창(PID 44093)이었다. Run B는 같은 패키지 실행 파일을 bridgeroot 작업 디렉터리에서 직접 시작했다(PID 45728); 실제 FlyGym headless 백엔드 PID 45733이 :61290에서 연결됐다. 처음 잘못된 CWD로 띄운 PID 45662는 종료했고, 짧게 끝난 시도 PID 45704도 기록했다. 실행 내역과 패키지 SHA는 run-a-start.log, run-b-start.log, binary.sha256에 있다.

| 흐름 | 판정 | 실제 화면·기록 | 증거 |
|---|---|---|---|
| T1 | PASS | 두 실행에서 사건 수집 중→완료를 확인했다. B Brain 페이지에 눈/감각/발화/운동/몸 5개 lane, 적용 사건 tick 표시, 정확 선택한 7개 뉴런의 발화 raster가 나타났다. lane 주기는 눈 567 ms, 몸 50 ms로 표시됐다. A는 백엔드가 없어 눈/감각/몸 표본이 비었지만 lane은 유지됐다. | a-t1-collecting.*, a-t1-complete.*, b-t1-complete.png, b-t1-complete.ax.txt |
| T2 | FAIL | B에서 왼쪽 눈 flash/시각 입력 후 eye lane은 이어진 선이 아닌 개별 hollow dot이며 수신 시각으로 표시됐다. 실제 label은 “눈 567 ms 간격 · 수신 시각”이었다(약 1.76 Hz, GUI 상태 실시간 대비 0.40배). 기대한 약 200 ms 간격은 충족하지 못했다. 이벤트 목록의 flash_eye와 approach_object는 “시각 모름 — 무효 — 적용 시각을 알 수 없음”이었다. | b-t1-complete.png, b-t1-complete.ax.txt, b-t6-wind-picker-invalid.png |
| T3 | PASS | A에서 GF 사건을 만든 뒤 World 페이지에서 뇌 초기화를 하고 이전 사건을 다시 선택했다. 화면은 “다른 뇌 세션 (사건 이후 리셋됨)”을 표시했고 새 epoch lane은 비었다. CSV 내보내기는 “내보내기 거부: 다른 뇌 세션 (사건 이후 리셋됨)”으로 막혔다. | a-t3-epoch-mismatch.png, a-t3-epoch-mismatch.ax.txt |
| T4 | PARTIAL | A의 사건 t433980 CSV는 header와 motor 39행, spike 54행을 포함했다. 행 tick은 사건 범위 433480–434979 안이고 spike의 root ID는 문자열이다. B에서 t121884 사건 CSV는 30행(header 포함), eye 2행과 body 27행만 포함했다. 화면에는 motor lane과 정확 spike raster가 있었지만 B CSV에 motor/spike 행은 없었다. | a-t5-timeline.csv, b-t1-timeline.csv, b-t1-complete.png, b-t1-complete.ax.txt |
| T5 | PASS | A는 GF 사건 수집 중 일시정지 후 3초 동안 134/1000 ms와 brain tick이 고정됐고, 재개 후 완료됐다. B도 117/1000 ms에서 멈췄으며 3초 후 동일 progress/world tick을 확인한 뒤 재개해 완료했다. | a-t5-paused.*, a-t5-timeline.csv, b-t5-paused.png |
| T6 | PARTIAL | 유효한 B GF complete 카드는 “불명확” verdict와 수치를 제시했다: selection 14.00→15.14 Hz/neuron(Δ+1.14, 기준 ±7.4), turnBias −0.39→0.36, groomDrive 0.20→0.41, wingDrive 1.30→0.51, 몸 순이동 0.61→1.23 mm, 속도 1.35→1.30 mm/s. 설명은 감정/의도 표현 없이 신경 변화가 기준 이내이고 몸 변화가 기준을 넘지 않았다고 설명했다. force-only wind #6와 sensory-on wind #8은 각각 적용되고 완료 callback이 왔지만 사건 목록에서 둘 다 applied tick unknown으로 무효였다. wind를 선택기에 강조해도 카드 선택은 이전 GF에 남아 “데이터 부족”(applied_tick_unknown, 관측 그룹 없음, 앞/뒤 운동 표본 무효)을 표시했다. force-only를 신경 결정으로 표현한 카드는 보지 않았다. 고유 선택 카드 기준 “데이터 부족”은 이 무효 선택 1건에서 확인했다. | b-t1-complete.ax.txt, b-t6-wind-picker-invalid.png, b-t6-wind-picker-invalid.ax.txt, b-t5-paused.png |
| T7 | PASS | B에서 기록 시작→GF 사건→정지를 수행했다. 보존한 events.jsonl은 4줄이며 사건 줄에 interaction_window.v2, motor_output, observed_body_action, 같은 줄의 interaction_explanation.v1이 있었다. 임시 원본 recording 폴더는 정리했다. | b-recording-events.jsonl |
| T8 | PASS | Run A에서 module 폴더가 없는 상태의 World 페이지는 빈 registry 안내를 표시했고 오류 없이 실행됐다. | a-world-empty.png, a-world-empty.ax.txt, baseline.log |
| T9 | PASS | 네 descriptor를 넣고 Rescan했다. valid auxiliary와 external-environment module이 unit/axis/range/rate/direction을 포함해 표시됐다. bad-unit은 “unknown_unit at actions[0].unit: unknown 'furlongs'”, duplicate는 “module_id already registered from descriptor-external-environment.json”으로 거부됐다. Take body output 전에는 owner가 default_world, 허용 입출력이 빈 상태라 실행되지 않았다. 테스트 descriptor 네 개와 새 modules 폴더는 끝에 제거했다. | module-setup.log, a-t9-module-registry.png, a-t9-module-registry.ax.txt, b-t10-modules-before.* |
| T10 | PARTIAL | B에서 기본 owner default_world→Attach(fixture.loopback, ready)→Take body output(fixture.loopback, out[move, mode_switch])→Detach(default_world)를 확인했다. 소유 중 4초 관찰에서 새 Brain 명령은 없었고 body speed는 약 0.0018→0.0000 m/s였다. 분리 뒤 default world에서 GF 자극이 새 event로 완료됐고, Rescan 후 Attach가 다시 ready가 됐다. Run A는 backend/renderer가 없어 overlay fly가 그려지지 않아 “멈춰 있는 overlay fly”를 눈으로 확인할 수 없었다. auxiliary refusal와 two-controller refusal는 UI 경로가 없어 하위 항목 N/A다. | a-t10-owner-window.png, a-t10-owner-desktop.png, b-t10-owner-loopback.*, b-t10-owner-after-wait.*, b-t10-detached-default-world.*, b-t10-reattached-ready.* |
| T11 | PARTIAL | A에서 Brain/World 각각 ko→en→ko로 바꿨다. 창 frame은 195,103,1320,820 그대로이고 겹침/잘림은 보이지 않았다. 영어 상태에서도 Brain의 “다른 뇌 세션 (사건 이후 리셋됨)”, World의 “물체 상태 — 준비됨”은 한국어로 남았다. | a-t11-brain-en.png, a-t11-brain-ko-return.png, a-t11-world-en.png, a-t11-world-ko.png |
| T12 | PASS | 테스트 app/backend PIDs 44093, 45728, 45733 종료; B wrapper/실패 시도도 종료됐다. :61290/:61291 listener 없음. modules 폴더와 이번 recording 폴더가 없다. defaults를 시작 전 snapshot으로 복원하고 final export diff가 비었다. 사용자 설치 앱은 전/후 mtime 1791526206, size 96, inode 38913602로 동일했다. | run-a-stop.log, run-b-stop.log, cleanup.log, defaults-before.plist, defaults-after.plist, defaults-restore.log, baseline.log |

## 실패·부분 통과 재현과 원인 추정

### T2 — eye dot 주기

1. Run B를 지정한 bridgeroot CWD에서 직접 실행하고 Brain/Stimuli에서 왼쪽 eye flash를 적용한다. 사건 전후 패널의 eye samples를 본다.
2. 실제 UI label: “눈 567 ms 간격 · 수신 시각”; legend는 “○ 점선 = 수신 시각뿐(실제 측정 시각은 모름)”이었다. 점은 개별 hollow dots였지만 요구한 약 200 ms 간격은 아니었다.
3. 기대: eye samples가 약 200 ms 간격으로 점으로 그려지고 interactive 수신 시각 lane이 명확히 표시된다.
4. 원인 추정: B의 실시간 대비 0.40배 상태에서 backend eye snapshot cadence가 낮아진 것으로 보인다. 눈 샘플 주기는 flygym_bridge/bridge.py, 표시/주기 label은 Sources/Lab/LabWindow+Timeline.swift:122 경로가 유력하다. 화면에는 몸 데이터 초당 5–15회 및 “30회 미만” 경고도 있었다.

### T4 — B CSV가 화면 lane을 모두 내보내지 않음

1. B에서 정확 뉴런을 선택하고 t121884 GF 사건을 완료한 후 timeline.csv를 증거 폴더에 저장했다.
2. 기대: 사건 tick 범위의 eye/sensory/spike/motor/body raw samples와 spike root ID가 내보내져야 한다. 실제 화면은 motor와 spike raster를 보여줬지만 b-t1-timeline.csv에는 eye 2행, body 27행만 있고 motor/spike가 0행이었다. 반면 A a-t5-timeline.csv는 motor/spike를 기록했고 spike ID는 문자열이었다.
3. 원인 추정: 이벤트 범위/selection이 exporter로 전달되는 Sources/Lab/LabWindow+Timeline.swift:167-175 또는 lane sample을 CSV로 합치는 Sources/Brain/InteractionTimeline.swift:710-739. 화면 snapshot과 export 결과가 달랐으므로 어느 단계에서 행이 빠졌는지는 이번 점검만으로 특정할 수 없다.

### T6 — interactive wind 설명 verdict에 도달하지 못함

1. B Stimuli에서 “몸을 실제로 밀기”만 켜고 one-shot wind를 적용한 뒤, sensory toggle을 다시 켜고 같은 동작을 반복했다. wind physical과 physical+sensory_model 두 event callback은 완료됐다.
2. Brain 사건 목록의 AX text는 “wind · physical · 시각 모름 — 무효 — 적용 시각을 알 수 없음” 및 “wind · physical+sensory_model · 시각 모름 — 무효 — 적용 시각을 알 수 없음”이었다. 선택기에서 wind를 강조하면 화면은 “wind · 시각 모름 · invalid” 항목을 보여줬지만 설명 카드는 선택된 이전 사건 “population:GF · t229384 · complete”에서 바뀌지 않았다. AX 카드 text: “데이터 부족 — 이 사건을 설명하기에 관측이 부족하다: 창이 무효임 (applied_tick_unknown); 관측된 그룹이 없음; 이전 구간 운동 표본 없음 (window_invalid); 이후 구간 운동 표본 없음 (window_invalid).”
3. 기대: force-only와 wind+sense 각각의 설명 카드가 실제 event와 결합돼 수치 근거 및 verdict를 보여야 한다. force-only event를 신경 결정으로 묘사하지 않은 점은 확인했지만 두 wind verdict와 수집 중 전용 badge는 직접 확인하지 못했다. Data 부족 카드는 한 고유 invalid 선택에서 확인했으며, 같은 선택 상태가 paused 화면에도 반복 표시됐다.
4. 원인 추정: Sources/Lab/LabWindow+EventWindows.swift:6-14,58-68 주석/anchor 경로는 interactive ACK의 body.t가 neural tick과 다른 clock이어서 applied_tick_unknown으로 처리한다. 이벤트 선택/화면 반영은 Sources/Lab/LabWindow+Timeline.swift:335-347이 유력하다.

### T10 — Run A overlay fly

1. Run A의 backend 없는 패키지 창에서 World→외부 모듈→Attach→Take body output을 수행했다.
2. owner 전환은 확인됐지만 World AX는 “3D 화면 — 물리 시뮬레이터 연결을 기다리는 중”이었고 fly overlay가 렌더링되지 않았다.
3. 기대: overlay fly가 정지하고 idle인지 눈으로 확인한다.
4. 이번 Run A 구성에는 renderer/backend가 없어 관찰 불가다. Run B owner/detach/re-attach 단계는 통과했다.

### T11 — 영어 전환 후 남은 한국어 문자열

1. Run A Brain 페이지에서 English로 바꾼 뒤 old-event card를 선택하고, World 페이지도 English로 바꿔 상태 label을 확인했다.
2. 기대: 새 섹션과 해당 페이지 문자열이 영어로 번역된다. 실제 화면에는 “다른 뇌 세션 (사건 이후 리셋됨)”, “물체 상태 — 준비됨”이 그대로 남았다.
3. 원인 추정: epoch note는 Sources/Lab/LabWindow+Timeline.swift:42에서 static let으로 생성되고, 초기 World status label은 Sources/Lab/LabWindow.swift:40-43에서 초기화된다. 언어 변경 시 재평가되지 않는 문자열 경로가 유력하다.

## 정리 상태

기본 설정 snapshot의 첫 비교에서 NSOSPLastRootDirectory와 NSWindow Frame GoToSheet가 달라 import로 복원했다. 최종 diff -u defaults-before.plist defaults-after.plist는 exit 0, 출력 없음이다. ~/Applications/Thongpari Virtual Fly Lab.app은 열거나 수정하지 않았고, 전/후 mtime이 같다.

AX 앱 이름 조회 중 별도의 같은 이름 앱이 존재해 한 차례 그 World inspector의 scroll offset이 바뀌었다. 초기 inventory에서 이미 실행 중이던 ~/.codex/visualizations/…/Thongpari Virtual Fly Lab.app이며, 관찰한 시작 값 0으로 되돌렸고 이 별도 앱/백엔드는 요청된 테스트 프로세스가 아니어서 종료하지 않았다. 상세는 cleanup.log에 남겼다. 소스 파일은 수정하지 않았고, git 상태를 변경하는 명령과 설치는 하지 않았다.
