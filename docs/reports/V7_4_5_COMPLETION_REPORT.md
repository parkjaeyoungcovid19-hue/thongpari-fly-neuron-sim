# Virtual Fly Lab V7.4–7.5 완료 보고서

2026-10-09 · 브랜치 `v7.4-7.5`(기준 `dfb05fb`, [V7.2–7.3](V7_2_3_COMPLETION_REPORT.md)) · **V7.4와 V7.5만 완료했고, V7 전체는 아직 완료되지 않았다.** V7.6–7.7은 착수하지 않았다.

## V7.4 기능 그룹 registry

- [`NeuralGroupRegistry.swift`](../../Sources/Brain/NeuralGroupRegistry.swift)의 계약은 `neural_group.v1`이다. 그룹마다 담는 정보는 다음과 같다.
  - FlyWire root ID 목록. JSON에서는 문자열로 쓴다.
  - 범주. arousal, threat_related, motor, sensory, unclassified 다섯 가지뿐이고, 욕구·정서 범주는 decode 단계에서 거절한다.
  - 근거 등급. `annotated_cell_type`, `model_selected`, `residual` 중 하나다.
  - 출처 문장, 구성 규칙, 상위 그룹(`parent_ids`), 기준선 정책.
  - 결속된 dataset hash. 매니페스트의 `neurons.bin` sha256이다.
- 그룹은 22개다. 위협 관련 4, 운동 7, 감각 10, 분류되지 않음 1이다.
  - 위협 관련: `threat.looming`(314, 좌 162 / 우 152), `threat.gf`(2)
  - 운동: `motor.command_dns`(24), DNa 좌우, MDN, DNp09, DNg11, escape wings
  - 감각: ascending, wind/touch, 냄새·먹이 좌우, 온도 warm/cool, JO-C(56), JO-E(363), 습도 dry/moist
  - 분류되지 않음: `unclassified.other` = role=other에서 수용기 615개(ORN/TRN/JO/HRN)를 뺀 138,262개
- **각성은 "등록된 그룹 없음"이다.** 시뮬레이터의 `BrainSignals.arousal`은 분류되지 않은 뉴런 전체의 발화율로 계산한 값이다. 확인된 각성 회로가 아니므로 그룹으로 등록하지 않았다. UI와 `emptyCategoryNote`가 이 사실을 그대로 말한다.
- 다음 경우에는 그룹을 비활성화하고 이유를 함께 표시한다. 비활성 그룹은 관측값이 없으며, 0 Hz로 표시하지도 않는다.
  - dataset hash가 다르다.
  - 불러온 데이터에 없는 root ID가 있다.
  - 구성원이 없다.
- 상위·하위 그룹 관계는 root ID 집합 기준으로 child ⊆ parent를 검사한다. 순환하는 관계는 거절한다.
- **정확 관측은 그룹 전체가 256개 이하일 때만 가능하다.** 256개를 넘는 그룹(looming 314, JO-E 363, unclassified)은 "정확 관측 불가"로 표시하고, 일부만 골라 대신 관측하지 않는다.
- Lab Brain 페이지에 기능 그룹 패널([`LabWindow+Groups.swift`](../../Sources/Lab/LabWindow+Groups.swift))을 추가했다.
  - 범주 요약과 범주별 팝업이 있다. 범주 머리글은 선택할 수 없다.
  - 상세 정보에는 출처, 구성 규칙, dataset 일치 여부, 상위·하위 그룹, root ID 목록과 전체 복사가 있다.
  - "정확 관측 시작"은 [`Coordinator+Groups.swift`](../../Sources/App/Coordinator+Groups.swift)의 `observeGroup`을 부른다. 뇌 클릭 선택과 같은 대기열을 쓰며, `stimulate`를 호출하지 않는다.

## V7.5 사건 전후 buffer

- [`InteractionWindow.swift`](../../Sources/Brain/InteractionWindow.swift)의 계약은 `interaction_window.v1`이다. 시간은 **simulation tick(1 ms)만** 쓰고, wall time은 어디에도 쓰지 않는다.
  - `applied_tick`은 사건이 동역학에 반영되는 첫 tick이다. sim 스레드에서 적용하면 `simMs + 1`이다.
  - baseline 구간은 `applied − 500 … applied − 1`, response 구간은 `applied … applied + 999`이고, 둘 다 닫힌 구간이다. pre + post는 2,048 tick ring에서 batch 64 tick을 뺀 범위 안에서만 설정할 수 있다.
  - 관측값은 구간의 모든 tick을 관측했을 때만 넣는다. 일부만 관측했으면 null과 빠진 tick 수를 쓴다. `delta_hz_per_neuron`은 baseline과 response가 모두 있을 때만 계산한다.
  - `motor_output`, `observed_body_action`은 V7.6 범위이므로 `not_collected`로 둔다.
  - `selection_omitted`는 정확 관측 한도를 넘어 선택에서 빠진 뉴런 수다. 뇌 클릭 선택은 최대 400개까지 집지만 관측은 256개까지만 한다.
  - strict decode는 필드 누락, 구간 길이·위치 오류, 근거 없는 delta, status와 flag의 불일치, `sufficient` 불일치를 거절한다.
- [`EventWindowBuffer.swift`](../../Sources/Brain/EventWindowBuffer.swift)의 동작은 다음과 같다.
  - **수집과 보관 한도.** 동시에 수집하는 창은 16개, 끝난 창을 메모리에 보관하는 것은 64개까지다. 17번째 사건이 오면 가장 오래된 수집 창을 invalid(buffer_overflow)로 끝내고 history에 남긴다. 조용히 버리는 창은 없다.
  - **진행.** `MetalSim.step()`이 batch를 끝낼 때마다 `advance()`를 부른다. 그래서 **일시 정지 중에는 창이 완성되지 않는다.**
  - **무효가 되는 경우.** 뇌를 reset하면 brain_reset, 선택이 바뀌거나 해제되면 selection_changed, 선택이 없으면 no_selection으로 무효 처리한다.
  - **겹침.** 두 사건의 분석 구간이 겹치면 양쪽 창 모두에 `overlapping_events`를 기록하고, 두 창 모두 `sufficient`를 false로 둔다. 이미 끝난 창에도 같이 적용한다.
- 사건이 들어오는 경로와 `applied_tick` 결정 방식:
  - 직접 신경 자극(⚡ 클릭, 뉴런 그룹 버튼, 프리셋)은 sim 스레드에서 기록한다(`Coordinator+EventWindows.swift`).
  - backend 없이 로컬에서 준 바람·건드리기도 sim 스레드에서 기록한다.
  - backend 명령은 ACK로 기록한다. **결정론 세션에서 현재 epoch의 ACK만** `applied_tick + 1`을 기준으로 삼는다. 나머지는 invalid(applied_tick_unknown)로 남긴다.
  - 온도는 `flywire_sensory` 모드일 때만 신경 사건이다. `modeled_physiology`는 몸의 tempo만 바꾼다.
- 창은 다음 두 곳에 나타난다.
  - **기록**: 녹화 중에는 `events.jsonl`에 `interaction_window` 줄로 남는다. 녹화를 멈출 때 수집 중이던 창은 status `collecting`으로 기록한다.
  - **UI**: Lab Brain 페이지의 "사건 전후" 섹션에 최근 4개 사건이 나온다. 그룹별 이전 → 이후 Hz/뉴런과 Δ, 무효 사유, 겹침, 일시 정지 안내, 수집·보관·넘침 수를 보여 준다.
- 그룹 연결(`a2c73e4`): 각 창에는 현재 선택 전체(`selection`)와, 선택이 **완전히 포함하는** registry 그룹만 들어간다. 일부만 포함된 그룹은 넣지 않는다.

## 리뷰와 수정

리뷰 에이전트 1개(Sonnet, high)가 `dfb05fb..a2c73e4`를 검토했다. high 등급 결함은 없었고, 다음 7건을 고쳤다(`0a5824e`).
1. `modeled_physiology` 온도를 신경 사건(sensory_model)으로 기록했다. 실제로는 tempo만 바꾸므로 잡음으로 만든 Δ가 인과 기록처럼 남을 수 있었다.
2. 녹화를 멈출 때 수집 중이던 창이 기록되지 않고 사라졌다.
3. 400개를 집었다가 256개로 잘린 선택이 표시 없이 기록됐다. `selection_omitted` 필드와 UI 문구를 추가했다.
4. 사건이 겹쳐도 `sufficient`가 true로 남았다. 완료 문구도 이유별로 나눴다.
5. 이전 세션의 늦은 ACK가 현재 세션 id로 기록됐다.
6. 그룹 팝업의 머리글을 선택할 수 있었다(`autoenablesItems`).
7. 0.5초마다 13만 개 원소의 Set을 두 번 만들었다. 이제 registry를 만들 때 한 번만 센다.

## 검사

| 검사 | 결과 |
|---|---|
| `--registrytest` | 70/70 PASS. 22개 그룹, 범주·근거, hash·root ID 불일치와 빈 그룹 비활성, 중첩 검사, 256 초과 관측 불가, 실제 연결 경로로 관측 시작 시 omitted 0과 extInput 불변 |
| `--eventwindowtest` | 82/82 PASS. 손으로 계산한 fixture의 baseline·response·Δ, tick 1 근처의 부족한 baseline, 겹침(끝난 창 포함), 넘침, reset·선택 변경, ring eviction, strict decode의 실패 사례, recorder 줄, 실제 MetalSim에서 1000 tick 뒤 완료, 일시 정지 중 미완성 |
| `--observetest` | 43/43 PASS |
| `--simtest`, `--behaviortest`, `--gpucheck`, `--labtest`(191/191), `--bridgetest`, `--v4test`, `--v4timingtest`, `--worldeditortest`, `--observationaudittest` | 모두 exit 0. 수정 전과 수정 후 두 번 실행 |
| Python unit | 95 tests OK |

**실제 GUI**: Sonnet 에이전트 1개가 패키지 앱(`0a5824e`)을 실제 창에서 검사했다. 상세 결과는 [GUI 보고서](../../notes/validation/v7-4-5-gui-2026-10-09/REPORT.md)에 있다.
- G1–G5, G7, G10, G11은 PASS다. 범주 요약, 선택할 수 없는 머리글, ≤256 그룹 관측 시작(자극 없음), 256 초과 그룹 불가 표시, 수집 → 완료와 Δ, 겹침 표시, 무효 사유, 언어 전환, 정리를 확인했다.
- G6(일시 정지 중 미완성)은 백엔드가 있을 때 PASS다(12초 이상 정지 후 재개로 완료). 백엔드가 없을 때는 재개가 불가능한 기존 결함 때문에 FAIL이었다.
- G9(녹화)는 PARTIAL이다. 중지할 때 collecting 줄과 complete 줄이 기록되는 것은 확인했다. 온도 모드는 설정이 적용되지 않아 확인하지 못했다.
- G8(잘린 뇌 클릭 선택)은 N/A다. 3D 뇌를 클릭하려면 좌표 클릭이 필요해서 하지 못했다. headless 검사로만 확인했다.

GUI에서 나온 결함과 처리(`5165ada`):
1. **기존 결함**: 백엔드가 없거나 V4를 지원하지 않는 백엔드에서는 일시 정지 뒤 재개할 수 없었다. 버튼이 로컬 일시 정지 상태도 보도록 고쳤다.
2. **V7.4에서 생긴 결함**: 언어를 바꾸면 그룹 선택기가 초기화되고 선택 이름이 이전 언어로 남았다. 선택기 선택을 유지하고 이름을 현재 언어로 다시 표시하도록 고쳤다.
3. 사건 목록이 최근 4개만 보인다는 사실을 통계 줄에 표시했다.
4. **미해결·원인 미확인**: 온도 "예전 방식" 설정이 백엔드 DEGRADED 상태에서 "아직 미적용"에 머물렀다. 이번 브랜치는 온도 경로를 바꾸지 않았다.

수정 뒤 패키지(`5165ada`)로 1·2·3을 실제 창에서 다시 확인했고 모두 PASS였다. 남은 사소한 점이 하나 있다. 로컬 일시 정지 중에도 상단 부제와 phase 배지가 "실행 중"으로 나온다.

## 알려진 위험·남은 것

- `sensory_sample_tick`은 실제 사건에서 항상 null이다. V7.6에서 연결한다.
- 비결정론 세션 ACK, 데스크톱 tap, 오버레이 loom은 창을 만들지 않거나 applied_tick_unknown으로 남는다.
- `MetalSim.stimulate`의 pending 큐가 8개를 넘으면 조용히 버린다. 기존 결함이다.
- dataset 결속은 매니페스트에 적힌 `neurons.bin` hash로만 검사한다. 실제로 읽은 파일의 바이트를 해시하지 않으므로, 오래된 매니페스트 옆의 바뀐 `neurons.bin`은 잡아내지 못한다. 기본 그룹은 그 hash를 그대로 복사해 쓰므로 불일치가 생기지 않는다.
- 녹화 sink는 sim 스레드에서 JSON을 인코딩한다. 그룹이 많은 256개 선택이면 창 하나에 수십 KB가 되어 그 프레임이 잠깐 느려질 수 있다.
- `interaction_window` 줄의 `wall_time`은 창이 끝난 시각이다. 사건 시각과 최대 1초 차이가 난다. 정렬에는 `applied_tick`을 쓴다.
- 이미 끝난 창에 나중에 겹침이 추가되면 메모리 안의 창만 바뀐다. 이미 기록한 줄은 그대로 남는다.
- 그룹 evidence 문구 안의 개수는 하드코딩돼 있다. registry를 만들다 실패했을 때 나오는 오류 문구는 영어뿐이다.
- 재실행: `./build.sh && ./ThongpariFlyNeuronSim --registrytest`, `--eventwindowtest`, 그리고 위 회귀 검사 목록.
- rollback: 이 브랜치의 기능·수정 커밋(`a2b7897`, `aa46050`, `a2c73e4`, `0a5824e`, `5165ada`)을 `git revert`한다.
- 스키마 버전: `neural_group.v1`, `interaction_window.v1`.
