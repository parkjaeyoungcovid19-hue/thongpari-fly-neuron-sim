# 전체 점검 결과와 후속 수정 계획 — 2026-09-22

## 판정

**현재 V5.5까지의 핵심 자동 회귀 검사는 통과한다. 그러나 입력 해제 경로, 참여체 충돌 응답, 마우스 입력량, 배포 안내에 수정할 사항이 있어 전체 기능 완료로 판정하지 않는다.** V5.6 이후 기능 개발 전에 아래 결함과 미완료 GUI gate를 먼저 처리한다.

이번 작업은 점검과 후속 작업 문서화다. 제품 소스는 수정하지 않았고 커밋하지 않았다. 실행 파일은 현재 소스로 재빌드했으며, 점검용 코드와 로그를 별도 디렉터리에 남겼다.

### 기준과 범위

- 저장소: `siliconfly/` — 상위 `flygym_bridge/`는 legacy 복사본이며 현재 구현 기준이 아니다. 상위 `run_flygym.sh`는 저장소 런처로 위임한다.
- HEAD: `98647a4428d06a2a8cbeb47c1d630cc73bd18942` (`Update README for Virtual Fly Lab V5.5`). 시작 시 작업 트리 clean.
- macOS 26.6.2 / arm64, Python 3.12.14, FlyGym 2.1.0, MuJoCo 3.9.0, NumPy 2.5.3.
- V2/V3 뇌·감각·기록 회귀, V4 session/tick/transport, V5.1~V5.5 viewer/state/player/input 구현과 문서의 일치 여부를 검토했다.
- 증거: [`../../notes/validation/overall-2026-09-22/`](../../notes/validation/overall-2026-09-22/).
- **실행 재현**, **코드 경로 확인**, **미검증/인수조건 미충족**을 구분한다. 모든 코드를 형식적으로 증명하거나 모든 사용자 동작을 검증한 것은 아니다.

## 1. 지금까지 구현된 범위

| 영역 | 현재 상태 | 이번 점검 결과 |
|---|---|---|
| 전체 뇌 Metal 시뮬레이션·행동 | 기존 기능 구현 | sim/behavior/GPU 회귀 통과 |
| 세계 객체·감각 자극·기록 | V2/V3 기능 유지 | mock/real lab 및 Swift recorder 관련 fixture 통과 |
| 결정론적 세션 | V4 구현 | session/timing 및 mock/real TCP lockstep 통과 |
| atomic snapshot·ray picking | V5.1 구현 | moving/reconnect 등 Python V5 fixture 통과; 실제 GUI 대응은 미검증 |
| 공통 view state | V5.2 구현 | Swift fixture 통과 |
| 관찰 카메라·eye sample tick | V5.3 구현 | Swift 및 real eye provenance 회귀 통과 |
| 물리 참여체 | V5.4 구현 | real contact/eye visibility 통과; 지속 이동 중 충돌 결함 별도 발견 |
| WASD/look/E/Esc·재매핑 | V5.5 구현 | 기본 fixture 통과; 키 해제·look 입력 경계 결함 별도 발견 |
| grab/place, activity card | V5.6/V5.7 계획 | 아직 구현되지 않은 계획 범위이며 이번에 회귀 오류로 세지 않음 |
| V6~V14 | 후속 계획 | 구현 완료로 간주하지 않음 |

## 2. 실행한 검증

아래 명령의 작업 디렉터리는 저장소 루트다. 개별 결과는 `python-results.json`, `runtime-results.json`, `clean-build-result.json`, `transport-results.json`, `fresh-transport-results.json`과 각 로그에 있다.

| 검사 | 결과 | 주요 근거 |
|---|---|---|
| `./build.sh` | PASS | 현재 전체 Swift 소스 빌드 성공 |
| `git archive HEAD` → 독립 임시 디렉터리 `./build.sh` | PASS | 기존 실행 파일 및 부모 venv를 상속하지 않은 소스 빌드 |
| `--bridgetest` | PASS | 88 PASS 항목 |
| `--labtest` | PASS | 37 PASS 항목 |
| `--v4test` | PASS | 18 PASS 항목 |
| `--v4timingtest` | PASS | 5 PASS 항목 |
| `--simtest` | PASS | 16-step batch 165 µs/step, 1000 µs budget 이내 |
| `--behaviortest` | PASS | 17 PASS 항목 |
| `--gpucheck` | PASS | 538 comparison points, `GPUCHECK PASS` |
| Python `test_bridge.py` | PASS | 44 PASS 항목 |
| Python `test_lab.py` | PASS | 54 PASS 항목 |
| Python `test_v4.py` | PASS | 47 PASS 항목 |
| Python `test_v5.py` | PASS | 31 PASS 항목; moving pick/transport reconnect 포함 |
| `NUMBA_DISABLE_JIT=1` Python `test_lab_real.py` | PASS | 63 PASS 항목; 실제 20 ms 이동 0.6 mm 및 same-boundary qpos 검증 |
| Python `test_vision_real.py` | PASS | 13 PASS 항목; 실제 eye render/참여체 시각 영향 |
| Python `tools/verify_data.py --no-parquet` | PASS | 배포 바이너리 데이터/manifest 검사; 원본 parquet 재대조는 제외 |
| Python `flygym_bridge/validate_experiment_presets.py` | PASS | 11 presets |
| mock / real-headless 각각 `--v4loop` | PASS / PASS | 실제 localhost TCP 세션·pause·epoch·반복성 |
| 새 mock / 새 real-headless 각각 `--labloop` | PASS / PASS | 실제 TCP object/ACK/event 및 simulation-time 자극 만료 |
| `git diff --check` | PASS | 제품 코드 변경 없음 |
| 독립 look 입력 분할 검사 | **불일치 재현** | 아래 F-03 |
| 독립 real held-input 벽 접근 검사 | **과침투·해제 후 큰 이동 재현** | 아래 F-02 |
| 실제 통합 GUI click-through / FPS / ACK latency | **미검증** | 아래 G-01 |

PASS 항목 수는 각 로그의 `PASS` 행 수다. 독립된 테스트 함수 개수 또는 완전한 기능 커버리지를 의미하지 않는다. 성능 수치는 이 기계의 이번 실행 관측이며 보장값이 아니다.

### TCP 검사 순서에 따른 초기 실패

처음에는 같은 backend에서 `--v4loop` 다음 `--labloop`를 실행했다. V4 검사 종료 뒤 논리적 deterministic session이 유지되어, autonomous interactive 실행을 전제로 한 labloop가 mock/real 모두 9개 실패했다. 이 로그도 보존했다.

각 labloop를 **새 backend**에서 다시 실행하자 둘 다 통과했다. 따라서 이 초기 실패를 새 제품 회귀로 분류하지 않는다. `fresh_transport_probe.py`가 재현 가능한 격리 실행기다. 이후 회귀 실행기는 테스트별 backend를 격리하거나 명시적으로 세션 종료/초기화해야 한다. 기존 사용자 backend에는 진단 명령을 무작정 연속 실행하지 않는다.

## 3. 후속 수정 목록

모든 항목은 아직 미수정이다. P2는 다음 기능 개발 전 처리할 기능/정확성 문제, P3는 문서·작업 흐름 정리다.

### F-01 · P2 · 일반 key-up이 stale snapshot 때문에 유실될 수 있음

**증거 수준: 코드 경로 확인 + 로컬 입력 상태 재현. 실제 GUI/transport fault 주입 재현은 후속 검증 필요.**

- 위치: `LabWindow.swift:391-395`, `679-712`, `715-749`; `PlayerController.swift:190-193`.
- interactive Participate에서 W-down이 backend에 적용된 뒤 render snapshot만 1초 이상 지연되는 경우를 생각한다. 연결·capability·session·focus는 유지된다.
- key-up은 먼저 `heldKeyCodes`에서 키를 제거한 다음 `sendPlayerInput(intent, reason: "key up")`를 호출한다. 이 호출에는 `allowStaleSnapshotForRelease`가 없어 기본값 false다.
- `playerInputEnvelope`는 1초 미만의 snapshot이 없으면 nil을 반환한다. 따라서 key-up의 중립 상태가 큐에 들어가지 않는다. 로컬 키는 이미 지워졌고, 상태 재전송/보류 큐도 이 경로에 없다.
- `input-probe.log`에서도 첫 key-up 후 로컬 상태는 neutral이고 두 번째 key-up은 재전송할 intent를 만들지 않는다. backend는 다른 입력/안전 해제/연결 종료가 오기 전까지 이전 held input을 유지할 수 있다.
- Esc/focus loss에는 이미 stale snapshot을 허용하는 별도 release 경로가 있다. 일반 key-up도 같은 생명주기 보장을 받아야 한다.

후속 작업:

- [ ] key-up, 특히 마지막 이동/상호작용 키 해제는 render snapshot 신선도와 독립적으로 전달한다. session/epoch 검증은 유지한다.
- [ ] 전송 거절 시 로컬 상태만 소비하고 끝내지 않도록 최신 held state의 재조정 또는 명시적 neutralization을 설계한다. W+D 중 W만 해제하는 경우도 다룬다.
- [ ] backend body/세션은 유지하고 snapshot 응답만 지연시키는 fault fixture를 만든다.
- [ ] W/E key-up 후 backend axes/held actions가 다음 허용 경계에서 해제되고 snapshot 복구 뒤에도 stale 입력이 재개되지 않는지 확인한다.

### F-02 · P2 · 참여체 이동이 충돌 중 큰 침투와 해제 후 튕김을 만듦

**증거 수준: 실제 production `RealFlyBody` + MuJoCo 실행 재현.**

- 위치: `flygym_bridge/fly_body.py:27-36`, `675-679`; `flygym_bridge/player_body.py:153-164`, `246-278`.
- 매 quantum 시작 시 `advance_player_input(sim_dt)`가 전체 이동량을 qpos에 한 번에 더하고 `_sync()`가 qvel을 0으로 덮어쓴다. 이후에야 native physics substep을 수행한다.
- 재현: x=30 mm, 두께 2 mm의 벽; radius=2.5 mm인 참여체를 `[24, 0, 8]`에서 +X 방향 30 mm/s로 20 ms씩 100회 전진.
- 충돌 없는 최대 중심 위치는 x=26.5 mm지만, 실제 중심은 **x=28.1575418778 mm**, 참여체 contact distance는 **-1.6575418778 mm**로 유지됐다.
- 벽 완전 통과는 이 조건에서 발생하지 않았다. 이를 tunneling 재현이라고 부르지 않는다.
- 이동 입력 해제 후 2초 더 적분하면 x=**-54.9624448489 mm**까지 이동했다. 입력 해제 직전 위치 대비 약 **83.12 mm**의 반대 방향 이동이다.
- 기존 real tests는 접촉 생성 및 짧은 shallow-contact 응답과 자유 공간 직선 이동을 각각 검사한다. 지속 held-input으로 벽을 누른 뒤 해제하는 조합은 놓치고 있다.

후속 작업:

- [ ] quantum 전체를 순간 위치 변경하는 방식 대신 native substep에서 solver와 일관된 제어를 적용한다. 속도/힘 기반 또는 contact-aware 제한 방식 중 기존 결정론 계약에 맞는 방식을 선택한다.
- [ ] 입력 해제와 관성/감쇠 정책을 명시하고 과도한 반발을 막는다. collision을 끄거나 geometry를 축소해 숨기지 않는다.
- [ ] 벽 정면/비스듬한 접근, 모서리, 여러 quantum 길이, fly 접촉, 해제 후 응답을 회귀에 추가한다.
- [ ] 접촉 허용 침투량·최대 속도·해제 후 정지 오차를 물리 단위로 먼저 정한 뒤 검사한다.
- [ ] 기존 자유 공간 20 ms = 0.6 mm, same-boundary spawn, V4 재현성 검사를 함께 유지한다.

재현 명령:

```sh
NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python notes/validation/overall-2026-09-22/collision_probe.py
```

로그: `collision-probe.log`. probe는 자체 body를 생성하고 닫으며 서버 포트나 기존 사용자 세션을 사용하지 않는다.

### F-03 · P2 · 마우스 look delta가 큐에 도달하기 전에 잘림

**증거 수준: 실제 `PlayerController.swift`를 컴파일한 독립 실행 재현.**

- 위치: `PlayerController.swift:196-202`.
- 이벤트마다 yaw/pitch를 ±0.35 rad로 clamp한다. 이후 bridge의 lossless packet split이 있어도 여기서 버린 양은 복구할 수 없다.
- 동일한 총 100 pt 이동: 한 이벤트는 **-0.35 rad**, 10 pt씩 10개 이벤트는 **-0.40 rad**. 기본 감도에서 12.5% 차이다.
- OS 이벤트 병합/전달 빈도에 따라 동일 물리적 마우스 이동의 결과가 달라진다. README의 누적 입력 보존 설명도 전체 입력 경로에는 성립하지 않는다.

후속 작업:

- [ ] 유한한 raw look delta를 보존하고 wire bound는 transport 단계에서 분할한다. 큰 입력 상한이 필요하다면 잔여량/정책을 명시한다.
- [ ] 같은 총 delta의 이벤트 분할 수를 바꿔 최종 yaw/pitch가 같은지 검사한다.
- [ ] bounded queue, Esc/focus loss 시 남은 look 제거, packet bounds 회귀를 함께 유지한다.

재현 명령:

```sh
swiftc PlayerController.swift notes/validation/overall-2026-09-22/input-probe/main.swift -o /tmp/siliconfly-input-audit-20260922 -framework Cocoa
/tmp/siliconfly-input-audit-20260922
```

로그: `input-probe.log`.

### F-04 · P2 · 문서의 기본 Finder 런처가 저장소에 없음

**증거 수준: 파일 목록 및 clean source 확인.**

- 위치: `README.md:165-176`, `docs/guides/LAUNCHERS.md:3-16`.
- 문서는 저장소 루트의 `Thongpari Fly Neuron Sim 실험실.command`와 `Thongpari Fly Neuron Sim 바로 실행.command`를 안내하지만 현재 저장소에 `.command` 파일이 하나도 없고 `git ls-files '*.command'`도 비어 있다.
- 상위 workspace의 `Thongpari Fly Neuron Sim.command`는 별도 파일이다. README의 clone 사용자에게 전달되지 않는다.
- CLI `./run_flygym.sh --flygym`은 존재한다. CLI 경로 전체가 없다는 뜻은 아니다.

후속 작업:

- [ ] 안내한 런처를 저장소에 포함하고 실행 권한을 관리하거나, README와 guide의 기본 시작 경로를 실제 제공 경로로 통일한다.
- [ ] 공백·한글 경로의 새 checkout에서 문서 순서대로 실행되는지 검증한다.
- [ ] 런처의 `V5.1 Preview` 출력도 현재 상태 표기와 통일한다.

### F-05 · P2 / 인수조건 · native viewer의 파리 geometry는 실제 MuJoCo geometry가 아님

**증거 수준: 코드 확인. 화면에서 발생하는 정확한 pick 오차는 이번에 측정하지 않음.**

- 위치: `WorldViewer.swift:369-379`; `flygym_bridge/fly_body.py:522-532`.
- native view의 파리는 `SCNSphere(radius: 1.0)`에 고정 scale `(2.5, 1.35, 1.0)`을 적용한 타원체다. backend snapshot의 파리에는 root pose만 있고 NeuroMechFly의 articulated body/leg collision meshes는 전달하지 않는다.
- ray picking은 실제 MuJoCo geometry를 사용한다. 따라서 이 타원체와 실제 파리의 화면 윤곽/부위 hit가 일치한다고 볼 수 없다. 일반 LabObject와 참여체의 shape/pose 대응 검증을 파리 전체 geometry 검증으로 확대하면 안 된다.
- `V5_PROGRESS.md`의 “mirrors backend object/fly geometry” 및 같은 geometry 인수조건과 현 구현의 차이를 명확히 해야 한다.

후속 작업:

- [ ] backend geometry를 전달하는 mirror 또는 authoritative offscreen rendering 중 표현 경로를 확정한다.
- [ ] 당장 marker를 유지한다면 UI·문서에 pose marker임을 명시하고 exact geometry acceptance를 미완료로 둔다.
- [ ] 같은 카메라/ray에서 native view와 MuJoCo를 대조하고, fly/leg/빈 공간의 hit/miss와 접촉 위치를 검증한다.

### F-06 · P3 · 진행 문서가 서로 다른 시점의 다음 작업을 동시에 지시함

**증거 수준: 문서 확인.**

- `V5_PROGRESS.md:7`은 V5.5 검증 완료 및 V5.6 다음 진행을 안내한다.
- 같은 파일 `:293`은 “finish V5.1 ... not V5.2”를 현재 다음 작업으로 안내한다.
- V5 계획은 단계별 출력과 gate 확인 후 진행하도록 되어 있지만 V5.1 GUI gate는 열린 채 V5.5까지 구현되어 있다. 구현 존재와 단계 인수 완료를 구분해야 한다.
- `CLAUDE.md`의 실행 예시는 이전 `./SiliconFly` 이름을 여전히 사용한다. 현재 빌드 출력은 `ThongpariFlyNeuronSim`이다.

후속 작업:

- [ ] 현재 상태/다음 작업은 한 곳에서 명확히 관리하고 과거 진행 내용에는 날짜와 historical 표기를 붙인다.
- [ ] 완료 상태를 implemented / automated verified / real backend verified / GUI accepted로 구분한다.
- [ ] 현 결함과 G-01을 정리하기 전 V5.6을 다음 실행 단계로 자동 선택하지 않도록 문서를 맞춘다.
- [ ] 오래된 실행 예시를 실제 binary 이름으로 갱신한다. `CLAUDE.md`의 owner-protected 구역은 수정 대상이 아니다.

## 4. 남은 검증 — 결함 확정과 구분

### G-01 · 통합 GUI 인수 미완료

이번 Computer Use inventory에 앱 bundle이 없었고, 전체 executable 경로로 `cua.getApp`을 호출해도 `Invalid app`으로 반환됐다. 따라서 실제 화면을 조작하거나 screenshot으로 검증하지 못했다. 기존 fixture 통과를 실제 창의 focus 검증으로 대체하지 않는다.

- [ ] Observe → Participate → 뷰 클릭 capture → WASD/look → Esc → 재capture → Observe를 실제 창에서 확인.
- [ ] text field/팝업/다른 창으로 focus 이동, 키를 누른 채 창 닫기, pause/resume, backend disconnect/reconnect 확인.
- [ ] participation의 look이 사용자에게 보이는 방향/시점에 어떻게 반영되는지 확인. 현재 camera는 관찰 camera이고 player는 방향을 알아보기 어려운 sphere이므로 UX 인수 항목으로 남긴다.
- [ ] 동일 장면의 MuJoCo/native viewer geometry 대응과 authoritative pick 확인.
- [ ] viewport FPS, snapshot Hz, click-to-ACK p50/p95, body packet Hz, sim/wall ratio를 실제 부하에서 기록.
- [ ] recording 중 Quit과 기록 실패 시 keep-open / Quit Anyway를 실제 AppKit 경로로 재검증.

권장 실행 경로는 자동화 도구가 인식할 수 있는 앱 패키징 또는 사용자의 실제 앱 조작이다. 이번 점검 때문에 새 배포 구조를 임의로 도입하지 않았다.

### G-02 · 범위 밖 또는 제한된 검증

- 새 venv 의존성 설치는 수행하지 않았다. clean build는 소스의 Swift 빌드 재현성만 입증하며 Python dependency 설치 재현성까지 의미하지 않는다.
- 원본 parquet와 shipped data의 대조는 하지 않았다 (`--no-parquet`).
- 장시간 soak, 모든 random seed, 메모리 누수·최대 객체 수의 GUI 성능, 모든 녹화 I/O 장애는 이번 전체 점검의 실행 범위에 포함하지 않았다.
- V5.6~V14를 구현하거나 검증한 것으로 표시하지 않는다.

## 5. 다음 작업 실행 순서와 완료 조건

1. **F-01 입력 해제 보장**: snapshot-only 지연 fault를 먼저 재현하고 key-up neutral 전달을 수정한다.
2. **F-02 충돌 제어**: 물리적 허용 오차를 정하고 held-input 접촉·해제 회귀를 추가해 해결한다.
3. **F-03 look 보존**: 이벤트 분할 독립성과 transport bounds를 함께 만족시킨다.
4. **F-04/F-06 실행 경로·문서 정리**: 실제 배포 파일과 안내/진행 gate를 일치시킨다.
5. **F-05/G-01 viewer·GUI 인수**: geometry 표현 범위를 확정하고 실제 조작·성능 로그를 남긴다.
6. 위 항목이 통과한 뒤 **V5.6 → V5.7**, 이후 기존 V6~V14 순서로 진행한다.

최종 재검증은 2절의 전체 matrix를 사용한다. TCP 검사는 매 테스트마다 새 backend를 쓴다. 기존 사용자 listener는 중단하지 않는다. 회귀 PASS만으로 F-01/F-02/F-03 또는 GUI gate를 닫지 말고 각 항목의 독립 재현이 해소되었는지 확인한다.

후속 작업자가 사용할 요청 예시:

> 이 보고서의 F-01부터 순서대로 수정하라. 각 항목의 재현/실패 증거를 먼저 확보하고 작은 변경으로 해결한 뒤 해당 회귀 gate를 통과시켜라. 제품 기능을 한 번에 확장하지 말고 GUI 미검증은 별도로 남겨라. 기존 사용자 변경과 세션을 보존하라.
