# Virtual Fly Lab V7 완료 보고서

2026-10-12 · 브랜치 `v8.1-8.3`. 이 브랜치는 V7.6–7.7을 포함한다. 선행 문서는 [V7.1](V7_1_COMPLETION_REPORT.md), [V7.2–7.3](V7_2_3_COMPLETION_REPORT.md), [V7.4–7.5](V7_4_5_COMPLETION_REPORT.md), [진행표](V7_PROGRESS.md)다.

**V7.1–V7.7의 구현과 headless 검증은 모두 끝났다.** V7.6–7.7의 실제 GUI 검사는 일부 항목만 확인했다. 확인하지 못한 항목은 아래 §4에 적었다. V7.6–7.7은 V8.1–8.3과 함께 구현했고, 사용자 요청에 따라 단계마다 하던 검증을 생략한 뒤 마지막에 한 번 몰아서 검증했다.

## 1. V7.6 통합 timeline

[`InteractionTimeline.swift`](../../Sources/Brain/InteractionTimeline.swift)는 사건, 감각 표본, 발화, 운동 출력, 몸 데이터를 **simulation tick(1 ms) 한 시간축**에 놓는다.

- **lane 4개.** 원시 표본만 담고 보간하지 않는다.
  - 눈: FlyGym `eye_sample_sim_tick`, 약 5 Hz.
  - 감각: FlyGym이 보고한 바람·건드리기, 또는 백엔드가 없을 때 로컬 모델이 준 자극.
  - 운동: 계산된 tick의 `BrainSignals`. quantum마다 한 번 남는다.
  - 몸: FlyGym 몸 packet, 또는 로컬 파리의 위치·상태.
- **발화는 이 store에 복사하지 않는다.** 정확 관측 ring([`NeuralObservation.swift`](../../Sources/Brain/NeuralObservation.swift))에서 직접 읽는다.
- **tick 출처.** 표본마다 `tick_origin`이 붙는다.
  - `sampled_at`: 실제로 측정한 tick이다. lockstep quantum의 끝 tick, 결정론 세션의 눈 tick, 운동 계산 tick, 로컬 자극 tick이 여기에 해당한다.
  - `received_at`: interactive 세션에서 packet을 소비한 뇌 tick이다. 실제 측정 시각은 모른다.
  - `received_at` 표본은 `sampled_at`으로 바꾸지 않는다. `sensory_sample_tick`과 지연(latency)도 여기서 만들지 않는다.
- **ring 크기와 초기화.** 눈 512, 감각 8,192, 운동 2,048, 몸 2,048이다. 밀려난 표본은 lane별로 센다(`evicted`, `evictedThrough`). 뇌를 초기화하면 모든 lane을 비운다.
- **`interaction_window.v2`.** 엄격한 decoder는 v1 기록도 계속 받는다.
  - `motor_output`, `observed_body_action`: baseline/response 각각에 status(`collected`/`partial`/`unavailable`), 표본 수, tick 범위, 측정 주기, 평균값, 사건 수를 담는다. 값이 없으면 0이 아니라 null이다.
  - `sensory_sample_tick`과 `sensory_sample_unavailable_reason`: 사건 채널의 첫 `sampled_at` 표본이다. decoder는 이 값이 `applied_tick`보다 작으면 거절한다.
  - `force_applied`, `sensory_applied`: 사건 출처가 정하는 값과 모순되면 decoder가 거절한다.
  - baseline이 tick 1에서 잘리면 `partial`(`window_truncated_at_tick_1`)이다.
- **Lab Brain "사건 전후" 패널** ([`LabWindow+Timeline.swift`](../../Sources/Lab/LabWindow+Timeline.swift)). 사건을 고르면 5개 lane이 나온다.
  - 눈 표본은 따로 떨어진 점, 운동은 계산과 계산 사이를 유지하는 계단, `received_at`은 속이 빈 점선 원으로 그린다.
  - lane 라벨에 측정 주기를 적는다. 감각 주기는 채널별로 잰다.
  - 보관 기간이 지나 사라진 구간은 회색 빗금으로 표시한다.
  - 뇌를 초기화하기 전의 사건이면 lane을 그리지 않고 "다른 뇌 세션" 안내만 보인다.
  - 사건 뒤에 선택을 바꿨으면 발화 raster를 그리지 않는다.
  - `timeline.csv` 내보내기는 화면에 그린 snapshot을 그대로 쓴다.
- **훅 위치.** `advanceNeuralQuantum` 한 곳(`simulationLock` 안)에 있다. 표본 하나에 lock 한 번, 구조체 쓰기 한 번만 든다.

## 2. V7.7 관측 기반 설명

[`InteractionExplanation.swift`](../../Sources/Brain/InteractionExplanation.swift)의 `explain(window:)`은 순수 함수이고, 계약은 `interaction_explanation.v1`이다.

- **verdict는 8개이고, 아래 순서로 평가한다.**
  1. `observing`: 아직 수집 중이다.
  2. `insufficient`: 데이터가 부족하다. 무효, 겹침, baseline 부족, 그룹 없음, 운동·몸 없음 같은 이유를 그대로 나열한다.
  3. `mixed`: 힘이 가해졌고 운동 출력도 바뀌었다. 몸의 움직임을 어느 한쪽 탓으로 돌리지 않는다.
  4. `neural_response`, `neural_activity_only`, `physical_only`, `no_response`, `unclear`.
  - `physical_only`는 "몸의 움직임은 가해진 힘 때문"이라고만 쓴다. 신경의 결정으로 쓰지 않는다.
- **문장.** 사실(`facts`)을 고정 템플릿에 넣어 한국어·영어로 만든다. 문장 속 숫자는 모두 `facts`에 있다. 감정·의도·욕구·생각을 뜻하는 단어는 쓰지 않는다. 몸 lane이 `received_at`이면 "수신 시각"이라고 밝힌다.
- **문턱값** (`ExplanationThresholds`):
  - 그룹: |Δ| > max(1.0 Hz/뉴런, 3 × Poisson 표준편차). 표준편차는 그룹의 rate, 구성원 수, 창 길이로 계산한다.
  - 운동: 신호 평균 변화 0.1. 문서화한 상수다.
  - 몸: 순이동 속도 변화 1 mm/s(FlyGym), 10 pt/s(로컬 파리). 문서화한 상수다.
  - 비교는 strictly greater(>)다. 문턱값과 같은 값은 "넘지 않음"이다.
- **UI**: 설명 카드([`LabWindow+Explanation.swift`](../../Sources/Lab/LabWindow+Explanation.swift)). verdict 배지는 상태와 상관없이 항상 보인다(관측 중 / 데이터 부족 / 무반응 / 신경 반응 / 신경 활동만 / 물리적 힘 / 혼합 / 불명확). 그 아래에 문장과 사실 목록을 펼쳐 볼 수 있다.
- **기록**: `events.jsonl`의 사건 줄에서 `interaction_window` 옆에 `interaction_explanation`이 함께 기록된다.

## 3. V7 검증 시나리오 대응

| ID | 검사 | 결과 |
|---|---|---|
| V7-01 정확 집계 | `--observetest`, `--eventwindowtest` (손으로 계산한 fixture, 중복 membership) | PASS |
| V7-02 관찰 부작용 | `--observetest` (선택 100회와 클릭 경로 후 `extInput` 불변), `--registrytest`, `--timelinetest`, `--explaintest` (조회·설명 후 `simMs`/`extInput` 불변) | PASS |
| V7-03 사건 시간 | `--timelinetest`: 일시 정지를 끼운 사건과 느린 눈 표본(applied 701 / sample 900). 지연 필드를 만들지 않음. `received_at`만 있는 lane은 sample tick을 정하지 않음 | PASS |
| V7-04 결측 | `--eventwindowtest`, `--timelinetest`: overflow, ring eviction, tick 1 근처의 사건, 겹침 → partial/unavailable/insufficient. 없는 baseline은 만들지 않음 | PASS |
| V7-05 해석 경계 | `--explaintest`: 힘만 → `physical_only`, 감각만 → 신경 판정, 둘 다 → `mixed`. 금지 어휘 검사 | PASS (headless). GUI에서는 interactive 바람 사건의 applied_tick을 알 수 없어 확인 못 함 (§4) |
| V7-06 GUI | 사건 선택 → 활동 카드 → root ID → raster → CSV | PARTIAL: 사건 선택, timeline, raster, CSV(root ID 문자열), 설명 카드 확인. B 실행의 CSV 행 누락 결함은 고쳤지만 GUI에서 다시 확인하지는 않음 |

headless 회귀(`deb83d3` 바이너리)는 15개 flag와 Python unit이 모두 exit 0이었다. 이후 수정마다 영향을 받는 flag를 다시 돌렸고 모두 exit 0이었다.

| flag | 검사 수 |
|---|---|
| `--timelinetest` | 73 |
| `--explaintest` | 44 |
| `--eventwindowtest` | 82 |
| `--registrytest` | 70 |
| `--observetest` | 43 |
| `--observationaudittest` | 23 |
| `--labtest` | 191 |
| `--bridgetest` | 102 |
| `--v4test` | 18 |
| `--v4timingtest` | 5 |
| `--worldeditortest` | 117 |

`--simtest`, `--behaviortest`, `--gpucheck`도 통과했다.

## 4. 리뷰·GUI와 처리

- **V7.6 리뷰**: Sonnet 1개가 검토했다. high 등급은 없었고 medium 4건과 low 6건을 모두 고쳤다(`556a0d1`).
  - 다른 epoch의 lane 표시
  - 채널을 섞은 감각 주기
  - 보관 기간이 지난 구간을 발화 없음처럼 그림
  - 뉴런 수 오표시
  - 미래·이전 눈 tick
  - 같은 tick에서 자극이 꺼지는 시점의 손실
  - decoder 교차 검사 누락
  - 갱신되지 않는 선택기
  - tick 1에서 잘린 창
  - raster 재스캔
- **V7.7**: 사용자 요청에 따라 리뷰를 생략했다. Claude가 직접 검증하다가 실제 경로 테스트가 앱 경로를 우회해 항상 `insufficient`가 되던 문제를 발견해 고쳤다(`3788bd3`). 고친 뒤 실제 경로의 verdict는 데이터에 근거한 `unclear`다.
- **실제 GUI**: Codex CLI(`gpt-6-luna`, max)로 `3788bd3` 패키지를 검사했다. 보고서는 [GUI 보고서](../../notes/validation/v7-6-8-3-gui-2026-10-12/REPORT.md)다. 백엔드가 없는 실행과 FlyGym 백엔드에 연결한 실행을 모두 했다.
  - T1(timeline), T3(epoch), T5(일시 정지), T7(녹화 v2와 explanation): PASS.
  - T4 CSV: 화면에 보이는 운동·발화 행이 B 실행에서 빠졌다. 내보내기가 ring을 다시 읽어서 그 사이 밀려난 행이 사라진 탓이다. 화면에 그린 snapshot을 내보내도록 고쳤다(`131c522`). 이 수정은 GUI에서 다시 확인하지 않았다.
  - T2: 눈 간격이 567 ms로 표시됐다. 몸이 실시간의 0.40배로 돌아 수신 간격이 길어진 것이다. 화면은 "수신 시각"으로 정직하게 표시했고, 보간하지 않았다. 처음 기대한 200 ms는 실시간 몸을 가정한 값이라 결함이 아니다.
  - T6: interactive 세션의 바람 사건은 V7.5 설계대로 applied_tick_unknown이라 "데이터 부족"으로 나온다. 물리력·감각 대조 verdict는 결정론 세션에서만 나오며, GUI에서는 확인하지 못했다.
  - T11: epoch 안내가 언어를 바꿔도 남았다. 고쳤다(`131c522`). World의 "물체 상태 — 준비됨"은 기존 문구로, 이번에는 고치지 않았다.

## 5. 완료 체크리스트 (계획 §9)

- [x] 7.1–7.7의 구현 단계와 출력이 모두 존재한다.
- [x] schema·단위·상태 소유권이 코드와 일치한다: `neural_observation.v1`, `neural_group.v1`, `interaction_window.v2`, `interaction_explanation.v1`.
- [x] 정상·실패 검사와 기존 회귀가 exit 0이다.
- [ ] 실제 backend와 새 GUI 프로세스의 사용자 동선 확인: 부분. 위 T4 재확인, T6, V7-05 GUI가 남았다.
- [x] 큐·모듈 상태: timeline ring은 bounded이고 eviction을 센다. 뇌를 초기화하면 비운다. 저장 상태는 추가하지 않았다.
- [x] unsupported·제약이 UI와 문서에 일치한다: `received_at`, 보관 안 됨, 다른 epoch, applied_tick_unknown.
- [x] 실행한 프로세스와 시험 자원을 정리했다(GUI 보고서 T12).
- [x] 이 보고서.

## 6. 한계·재실행·rollback

- interactive FlyGym 세션의 표본은 모두 `received_at`이다. 그래서 그 세션에서는 `sensory_sample_tick`, 지연, tick 기반 속도를 만들지 않는다.
- 창을 마무리하는 batch에서 나온 마지막 운동 표본은 기록에 다시 채우지 않는다.
- 몸 packet은 position·velocity가 빠지면 0으로 채운다. timeline은 이 0을 실제 0과 구별하지 못한다.
- 로컬 파리는 속도와 yaw를 보고하지 않는다(null).
- 설명 문턱값 중 운동·몸 값은 데이터에서 얻은 값이 아니라 문서화한 상수다. 그룹 문턱값의 Poisson 항은 하한이다.
- 완료된 사건의 snapshot은 캐시된다. 같은 선택·epoch에서는 그 뒤에 들어온 표본이 화면에 반영되지 않는다.
- 재실행: `./build.sh && ./ThongpariFlyNeuronSim --timelinetest`, `--explaintest`, 그리고 `CLAUDE.md`의 회귀 flag 목록.
- rollback: `git revert` 131c522 3788bd3 556a0d1 1f0b41c 2714a12 (V7 부분만. V8 커밋은 [V8.1–8.3 보고서](V8_1_3_COMPLETION_REPORT.md) 참고).
- fixture: `Sources/Diagnostics/TimelineDiagnostics.swift`, `ExplanationDiagnostics.swift`. 코드 안에 손으로 계산한 fixture가 있다.

## 7. V8에 넘기는 것

- typed observation API: `NeuralObserver`, `InteractionTimeline` 조회.
- event schema: `interaction_window.v2`, `interaction_explanation.v1`.
- bounded telemetry budget: ring 크기와 eviction 카운터.
- 정확성 fixture: 위 diagnostics.
- V8.1의 신경 출력 표(`ExternalIONeuralOutput`)는 `BrainSignals`에서 만들었다.
