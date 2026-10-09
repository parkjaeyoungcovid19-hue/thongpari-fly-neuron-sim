# Virtual Fly Lab V7.2–7.3 완료 보고서

2026-10-09 · 브랜치 `v7.2-7.3`(기준 `1def395`, [V7.2 전 리팩토링](PRE_V7_2_REFACTOR.md)) · **V7.2와 V7.3만 완료했고 V7 전체는 미완료다.** V7.4–7.7은 착수하지 않았다.

## V7.2 정확 관측 primitive

- `LIF.metal`에 버퍼 2개를 추가했다. `observeSlot`(17)은 뉴런별 선택 슬롯으로, 0xFFFF는 선택하지 않은 뉴런이다. `observed`(18)는 step별 256바이트 행이다. 발화한 선택 뉴런만 자기 바이트에 1을 쓴다. 동역학 쪽에서는 이 값을 읽지 않으므로 계산 결과는 비트 단위로 같다.
- `MetalSim`은 batch가 끝난 뒤 k×256바이트 행만 읽어 `NeuralObserver`에 넣는다. GPU 상태 배열 전체는 복사하지 않는다. `setObservation`은 simulation owner 스레드에서만 호출하며, 256개를 넘는 요청은 통째로 거절한다. `truncate`를 주면 가까운 순서로 256개만 남기고 나머지는 `omitted`로 보고한다. reset 뒤에도 선택은 유지되고 `brain_epoch`가 증가한다.
- [`NeuralObservation.swift`](../../Sources/Brain/NeuralObservation.swift)의 계약(`neural_observation.v1`)은 다음과 같다.
  - window는 1-based tick 닫힌 구간이다.
  - 중복 membership은 한 번만 센다. 중첩 그룹은 그룹마다 따로 센다.
  - `rate_hz_per_neuron` = spikes×1000/(observed_ticks×members)이고, 분모가 0이면 null이다.
  - 선택 전, 2,048 tick 보관 한도를 넘은 구간, 아직 계산하지 않은 구간은 `dropped_samples`로 기록하고 `validity`를 `partial`로 둔다.
  - root ID는 JSON 문자열이다.
  - strict decode는 필드 누락, 비정규 root ID, window 합 불일치, counts와 다른 rate·validity를 거절한다.
  - `ObservationCapability`가 한도 256과 보관 2,048 tick을 노출한다.

## V7.3 읽기/자극 분리

- 뇌 화면을 클릭하면 기본으로 **읽기 전용 선택**이 된다. cyan 표시가 뜨고 정확 관측이 시작되며 전류는 넣지 않는다. 뇌 화면 안의 **⚡ 클릭하면 자극** 스위치를 켰을 때만 기존과 같은 직접 자극(0.25, 400 ms)을 한다.
- 뇌 화면 안의 노란 줄이 sim의 실제 직접 자극 상태를 보여 준다. 클릭·그룹 버튼·프리셋 모두 포함하며 뉴런 수와 종료 tick을 표시한다.
- Lab Brain 페이지에 "선택한 뉴런 — 정확 관측" 섹션을 추가했다. 최근 1초와 보관 전체의 spikes, Hz/뉴런, tick 범위, missing ms, exact/validity, epoch, 선택 번호를 보여 준다. 일시 정지 중 선택은 "대기 중"으로 표시한다.
- 연결은 `BrainWindowController.connect(to:)` 하나로 통일했다. Lab과 오버레이가 같은 경로를 쓴다. 기존 그룹 자극과 실험 프리셋은 그대로 유지했다.

## 검사

헤드리스 검사 로그는 `notes/validation/v7-2-3-2026-10-09/`(로컬)에 있다.

| 검사 | 결과 |
|---|---|
| `--observetest` | 43/43 PASS. 손으로 계산한 fixture(V7-01), JSON 계약, 한도·실패 사례, 600 tick 독립 CPU 참조(RefSim)와 불균일 GPU batch의 tick별 완전 일치(1 tick shift 음성 대조 537/600 검출), 관측 유무에 따른 상태 동일, 보관 한도와 reset, 앱 실제 연결 경로로 선택 100회와 클릭 경로 10회 실행 후 자극 요청·extInput 불변(V7-02) |
| `--gpucheck` | PASS. 줄 내용이 이전 기준선과 같다(E 5.96e-08, FMA 탐침 2개 FAIL 포함) |
| `--simtest`, `--behaviortest`, `--labtest`, `--bridgetest`, `--v4test`, `--v4timingtest`, `--worldeditortest`, `--observationaudittest` | 모두 exit 0 |
| Python unit | 95 tests OK |
| 비용 | 256개 관측 88.9 µs/step, 관측 없음 91.7 µs/step(부하 상태, 차이 없음) |

**실제 GUI**: Codex `gpt-6.1-sol`이 서명된 패키지 앱에서 검사했다. 상세 결과는 [GUI 보고서](../../notes/validation/v7-2-3-gui-2026-10-09/REPORT.md)에 있다.
- V7 항목: V1–V3, V5–V7, V9 PASS. V4(한도 문구)와 V8(언어 전환)은 아래 결함 1·4 때문에 FAIL이었고, 둘 다 수정했다.
- 리팩토링 잔여 항목: C, G, I, L, N, O PASS. H, M PARTIAL. D, F, K는 아래 결함 2–4 때문에 FAIL이었다.
- 수정 뒤에는 헤드리스 검사만 다시 돌렸다(`--labtest`, `--observetest`, `--worldeditortest`, `--v4test`, `--bridgetest` exit 0). 수정 사항에 대한 실제 GUI 재확인은 하지 않았다.

GUI에서 나온 결함과 처리:
1. **V7.2에서 생긴 결함**: 한국어 한도 문구에서 한도와 제외 수가 뒤바뀌어 표시됐다. 위치 지정 서식(`%1$d`/`%2$d`)으로 수정했다.
2. **기존 결함**: 일시 정지 중에도 그래프에 값이 계속 추가돼 기록이 0선으로 밀려났다. 이제 뇌 tick이 진행될 때만 값을 추가한다.
3. **기존 결함**: 검은 하늘에서 조준점이 보이지 않았다. 흰 십자에 어두운 외곽선을 넣고 크기를 16 pt로 키웠다.
4. **발생 시점 미확정**: 언어를 바꾸면 Lab 창이 줄어들었다(820→640). `buildUI()` 전 창 frame을 저장해 두었다가 복원하도록 수정했다.

GUI 증거가 부족한 항목: H의 새 backend epoch 경계에서 지연된 old-epoch event, K의 이동·운반 변위, M의 메뉴 막대 glyph.

## 패키징

`package_app.sh`는 이제 키체인의 `Apple Development`/`Developer ID Application` 인증서로 서명한다. 없으면 ad-hoc으로 서명하고, `THONGPARI_SIGN_IDENTITY`로 바꿀 수 있다. ad-hoc 서명은 빌드할 때마다 다른 앱으로 취급돼 개인정보 권한을 매번 다시 묻는다. iCloud `dist/`에 생긴 앱에는 File Provider가 `com.apple.quarantine`을 붙여 App Translocation이 일어났다. 사용자 실행용 앱은 `THONGPARI_APP_OUTPUT="$HOME/Applications/Thongpari Virtual Fly Lab.app"`로 패키징한다.

## 남은 것 / 재실행

- V7.4–7.7은 미착수다. V7-03, V7-05, V7-06(raster, CSV export)은 이후 단계 범위다. 이번에 search/zoom UI는 만들지 않았으므로 V7-02는 선택·클릭 경로만 검사했다.
- 오버레이 모드와 Lab이 각각 BrainWindowController를 가지지만 sim의 선택은 하나다. 다른 창에서 선택을 바꾸거나 해제하면 이 창의 표시도 사라진다.
- 재실행: `./build.sh && ./ThongpariFlyNeuronSim --observetest`, `--gpucheck`, 그리고 위 회귀 검사 목록.
- rollback: `git revert` 대상은 이 브랜치의 커밋 2개다. 관측 버퍼와 커널 바인딩도 함께 되돌아간다.
- 스키마 버전: `neural_observation.v1`. fixture: `--observetest` 내장(손으로 계산한 링 fixture와 RefSim 대조).
