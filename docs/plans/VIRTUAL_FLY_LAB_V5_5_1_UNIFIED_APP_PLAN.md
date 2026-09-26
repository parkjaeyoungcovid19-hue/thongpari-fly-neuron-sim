# Virtual Fly Lab V5.5.1 — 한 창에서 이어지는 실험 경험

작성: 2026-09-23 · 상태: **설계 / 미구현 / 미검증**

순서: **V5.5 → V5.5.1 → V5.6 → V5.7 → V6**. V5.5.1은 새 물리·신경 기능 버전이 아니라, 이미 있는 세계 관찰·자극·뇌 상태·실험 기록을 하나의 macOS 작업 공간으로 묶는 사용 경험 릴리스다. V5.6 집기·놓기를 앞당겨 구현하지 않는다. 기존 [V5 계획](VIRTUAL_FLY_LAB_V5_PLAN.md), [공통 실행 규칙](IMPLEMENTATION_PLAYBOOK.md), [2026-09-22 전체 감사](../reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md)의 미완료 인수 조건은 그대로 적용한다.

## 1. 사용자가 얻게 될 결과

앱을 열면 **하나의 주 창**에서 실제 FlyGym 세계를 보고, 같은 장면을 보면서 자극을 조절하고, 결과 그래프와 기록 상태를 확인한다. 파리·객체·눈·뇌 집단 중 하나를 선택하면 오른쪽에 해당 대상의 조작과 관찰값이 나타난다. 자극을 보낸 뒤 다른 창을 찾거나 World/Stimuli/Live Data 페이지를 왕복하지 않아도 적용 결과와 반응을 같은 시야에서 확인한다.

여기서 “한 창”은 단순한 창 병합이 아니다. 기본 실행에서 사용자에게 보이는 주 창이 하나여야 하고, **선택 대상·실험 시각·명령 상태·기록 상태가 모든 영역에서 같은 상태를 가리켜야 한다.** 내부의 Swift 전뇌 시뮬레이션과 Python MuJoCo 프로세스는 유지할 수 있지만 별도 MuJoCo/뇌/데스크톱 오버레이 창을 기본 동선에 띄우지 않는다. 오류 시에도 새 상태 창을 연달아 만들지 않고 주 창에서 원인과 복구 행동을 보여준다. macOS 표준 저장/오류 sheet는 주 창에 붙는 보조 UI로 허용한다.

### 현재 코드에서 확인한 불편의 원인

| 현재 경로 | 사용자에게 나타나는 문제 | V5.5.1의 처리 |
|---|---|---|
| `main.swift`가 투명 데스크톱 파리 창, `BrainWindowController`, `LabWindowController`를 시작 | 어떤 창이 실제 실험인지 모호하고 포커스가 흩어짐 | Lab을 주 창으로 승격; 오버레이/별도 뇌 창 자동 표시 중단; 기존 기능은 주 창의 뇌/데이터 영역에서 접근 |
| `run_flygym.sh --flygym` → `bridge.py --flygym` → `launch_passive` | 물리 viewer가 독립 창을 띄움 | 실험 기본 경로는 **real FlyGym headless** + 주 창의 `WorldViewer`; 별도 viewer는 명시적 개발 진단 경로로만 분리 |
| `LabWindow.swift`가 사이드바 선택마다 전체 `NSTabViewController` 페이지를 교체 | Stimuli/Brain/기록을 보는 동안 세계가 사라짐 | 세계 캔버스는 계속 보이고 사이드바는 작업 도구와 결과 영역만 변경 |
| 현재 `WorldViewer`는 SceneKit snapshot mirror이고 파리는 단순 pose marker | 화면 윤곽과 MuJoCo의 실제 부위 선택이 다를 수 있음 | V5.5.1에서 표현 한계를 표시하고 선택은 backend ray ACK만 확정; 상세 geometry 정확성은 별도 인수 항목으로 검증 |
| 자극/객체/기록 조작과 상태 문구가 각 페이지에 흩어짐 | 클릭 뒤 실제 적용 여부와 결과를 찾기 어려움 | 같은 실험 시간축에 요청→대기→적용/거절을 연결하고 관련 관찰값을 바로 옆에 제시 |

이 표는 **소스 및 기존 감사에 근거한 현상**이다. 오늘 실제 제품 GUI는 실행 중이지 않아 화면 배치의 시각적 품질을 직접 확인한 결과로 쓰지 않는다. 구현 전 현재 앱 화면 캡처와 클릭 동선을 기준선으로 남긴다.

## 2. 정보 구조와 화면 명세

```
┌──────────────────────── macOS 표준 제목 막대 / 도구 막대 ────────────────────────┐
│ Virtual Fly Lab    연결·세션 상태   [관찰 | 참여]   [일시 정지/재개]   ● 기록 │
├───────────────┬───────────────────────────────┬─────────────────────────────┤
│ 작업 사이드바 │ 항상 보이는 실제 세계 캔버스     │ 맥락 검사 영역               │
│ 세계          │ 파리 / 객체 / 참여체 / 선택 표시 │ 선택한 대상의 상태와 조작    │
│ 자극          │ 카메라·선택·참여 포커스          │ 자극 입력과 적용 결과        │
│ 뇌            │                               │ 상세 설명은 접기             │
│ 데이터        ├───────────────────────────────┤                             │
│ 실험          │ 접을 수 있는 반응/사건 시간축    │                             │
├───────────────┴───────────────────────────────┴─────────────────────────────┤
│ 얇은 상태 영역: sim tick / 눈 영상 시각 / 몸 패킷 신선도 / 마지막 명령 결과     │
└───────────────────────────────────────────────────────────────────────────────┘
```

- **도구 막대:** 현재 세션, 연결, 관찰/참여, 일시 정지/재개, 기록을 창 전체의 단일 상태로 표시한다. `Pause`와 `Resume` 버튼을 동시에 활성화하지 않는다. 기록 중에는 빨간 점과 저장 대상/경과 시간을 보여주며 종료 직전 flush 상태를 알린다.
- **왼쪽 source list:** `세계`, `자극`, `뇌`, `데이터`, `실험`은 각기 다른 창이 아니라 오른쪽 검사 영역의 작업 맥락이다. 선택 강조를 유지하고 아이콘만으로 의미를 전달하지 않는다. 실험 중에는 사이드바를 접어 캔버스를 넓힐 수 있다.
- **중앙 캔버스:** `WorldViewer`를 한번 생성해 유지한다. 도구 전환, 기록 시작, 패널 접기 중 카메라·선택·snapshot이 초기화되지 않는다. 관찰 카메라와 참여체 이동의 차이를 화면에서 분명히 나타낸다. 장면의 파리 표시는 실제 부위 geometry가 아니라면 `위치 표시`라고 쓴다.
- **오른쪽 검사 영역:** 선택 대상이 없으면 현재 도구의 핵심 조작을 보여준다. 파리 선택 시 위치·눈·몸·뇌 관찰, 객체 선택 시 객체 값·자극/접근 관련 조작, 자극 도구 선택 시 눈 가림·flash·바람·접촉·온도를 표시한다. `물리 효과`, `감각 모델`, `직접 신경 자극`, `관측치`를 같은 색/라벨로 섞지 않는다. 상세 수치·원리 설명은 disclosure 안에 둔다.
- **아래 시간축:** 최근 명령, marker, 몸/뇌의 읽기 전용 지표를 같은 `session_id / epoch / sim_tick` 기준으로 정렬한다. `요청`, `적용`, `거절`, `시간 초과`를 구분한다. 기록하지 않는 상태에도 최근 사건은 보여주되 파일 저장을 암시하지 않는다. 가로 폭이 좁으면 접히고 상태·오류는 계속 보인다.
- **상태/오류:** 연결 준비 중·연결됨·오래된 데이터·끊김, 세션 running/paused, 기록 저장 중/실패를 서로 독립적으로 보여준다. 색만으로 구분하지 않고 텍스트와 접근성 값도 제공한다. 원인·재시도·현재 유효한 마지막 snapshot을 명시한다.

### 기존 시각 기능의 이동과 실제 화면의 정확성

- 현재 `BrainWindowController`는 그래프만이 아니라 **139,255개 뉴런의 3D 점군·발화 표시·뉴런 선택**을 제공한다. 자동으로 뜨는 별도 창을 없애기 전에 이 화면을 주 창의 `뇌` 작업 공간 안의 접을 수 있는 보조 뷰로 옮기고, 넓혀 볼 때도 세계 캔버스를 축소해 함께 남긴다. 그래프만 넣고 3D 뇌를 잃는 것은 인수 실패다. 기존 뉴런 선택/읽기/직접 자극의 구별도 보존한다.
- 현재 World의 2D `LabArenaPlacementView`는 좌표 입력·객체 생성 도구다. 중앙 3D 뷰의 대체 화면으로 두지 않고 오른쪽 `세계` 검사 영역의 작은 평면도/좌표 도구로 옮긴다. 클릭 한 번에 객체를 생성하는 옵션은 오발동 가능성이 있으므로 기본값을 확인하고 사용자에게 현재 동작을 표시한다.
- 첫 구현 단계에서 **두 렌더 경로를 같은 장면으로 비교**한다: (A) 현재 SceneKit snapshot mirror에 실제 MuJoCo geometry/revision을 충분히 전달하는 방식, (B) MuJoCo authoritative offscreen frame을 AppKit view에 표시하는 방식. fly 몸통/다리, 객체 윤곽, camera, ray hit/miss, 눈 sample 시각, 패널 전환 성능을 비교해 한 경로를 선택한다. 현재 SceneKit의 파리 타원체를 실제 형상이라고 부르지 않는다. 화면과 authoritative pick이 일치하지 않으면 해당 객체의 정밀 선택을 제한하고 이유를 보여주며, 완료 보고서에 잔여 정확도 범위를 쓴다.

### 기본 Apple 앱 스타일

`NSWindow`의 표준 프레임/제목 막대와 `NSToolbar`, `NSSplitViewController` 또는 동등한 AppKit split view, `.sourceList` 사이드바, 시스템 색·서체·SF Symbols·표준 버튼/팝업/sheet를 우선 사용한다. 창 크기를 바꿀 수 있고 사이드바/검사 영역 폭을 조절한다. 밝게/어둡게, 큰 글자, VoiceOver, 전체 키보드 접근, Reduce Motion에서 상태와 조작이 유지되어야 한다. 별도 브랜드 폰트, 과한 카드 테두리/그림자, 장식 애니메이션은 넣지 않는다. 색의 의미는 macOS semantic color로 관리한다.

Apple의 [macOS 설계 지침](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [split view](https://developer.apple.com/design/human-interface-guidelines/split-views), [창](https://developer.apple.com/design/human-interface-guidelines/windows)을 참고한다. 이 앱의 세 영역 배치와 너비 값은 위 지침에서 그대로 나온 수치가 아니라 현재 실험 동선에 맞춘 **설계 제안**이다. 구현 때 실제 창 크기/스크린샷으로 조정한다.

## 3. 주요 사용자 동선

| 동선 | 한 창에서의 행동 | 보여야 할 결과 |
|---|---|---|
| 첫 실행 | 앱 아이콘/런처 1회 → 주 창 오픈 → backend 준비 | 캔버스 skeleton, 진행 단계, 연결 상태. backend 준비 후 세계가 자동 갱신. 별도 물리/뇌/오버레이 창 없음 |
| 기본 자극 | 세계의 파리 관찰 → `자극` → 왼눈 가림/바람/접촉/온도 값 설정 → 적용 | 세계는 계속 보임. 도구에는 단위·지속 시간·효과 종류, 시간축에는 요청과 실제 ACK, 아래 그래프에는 해당 관측치 변화. 자극으로 행동이 반드시 바뀐다는 문구 없음 |
| 객체 관찰/조작 | 캔버스의 객체 선택 → 검사 영역에서 값 확인/기존 지원 명령 실행 | 선택 하이라이트와 검사 대상 ID 일치. ray miss는 무변경. 실제 backend ACK 전에는 반영 완료로 표시하지 않음 |
| 뇌 관찰 | 같은 장면에서 `뇌` 선택 → 현재 집단/그래프 관찰 | 세계·세션 시각·선택이 유지. 읽기 전용 관찰과 직접 신경 자극 버튼을 시각적으로 분리하고 후자를 명확히 표시 |
| 참여 | `참여` 선택 → 3D 캔버스 클릭으로 capture → WASD/look/E → Esc | capture 상태/키 안내가 캔버스에 보임. 검사 영역 텍스트 입력 시 이동 해제. Esc/도구 전환/창 비활성화 시 held input 해제 |
| 실험 | `실험` → 기록 시작 → baseline marker → 자극 → 관찰 marker → 일시 정지/재개 → 저장 | 기록 상태가 도구 막대에 계속 보임. 모든 marker와 자극이 같은 시간축에 남고 파일 저장은 flush 완료 후 확정 표시 |
| 장애 복구/종료 | backend 끊김 또는 기록 저장 실패 | 캔버스는 마지막 snapshot을 `오래된 화면`으로 표시; 참여 입력 차단. 재연결 후 새 session/epoch 확인. 기록 실패 시 기존 파일 경로와 `다시 시도/열어두기/종료` 경로 보존 |

## 4. 상태·명령 계약

새 UI 소유자는 **표시 상태만** 관리한다. Python MuJoCo는 물리/세계, Swift `Coordinator`/`LabSession`은 neural/session, `ExperimentRecorder`는 기록의 권위 상태를 유지한다. `LabViewState`는 선택 대상·모드·패널 열림·카메라 같은 presentation 상태의 단일 소스가 된다. `LabWindow`의 여러 레이블이 각자 `connected`를 추측하지 않도록 하나의 읽기 전용 `WorkspaceSnapshot`을 조합해 렌더한다. 이름은 설계상 가칭이며 기존 타입이 같은 책임을 갖고 있으면 확장한다.

| UI 행동 | 기존 계약/소유자 | 화면 처리 |
|---|---|---|
| 눈 가림·바람·접촉·온도·객체 명령 | `LabCommand`, Python backend 적용, `LabEvent`/ACK | 입력 검증 → pending → `applied_tick/actual_value` 또는 명시적 실패. preview는 확정값과 구별 |
| 세션 시작·pause·resume | `LabSession`과 V4 양쪽 barrier | 요청 중 중복 버튼 잠금; 양쪽 barrier ACK 후 `paused/running` 확정 |
| 참여 입력 | `PlayerController` → `PlayerInput` → backend ACK | 주 캔버스 포커스에서만 전송. key-up/모드 전환/포커스 상실의 neutral 전송 보장 |
| 세계 선택 | immutable world snapshot + backend ray pick | 화면 표시만으로 선택 확정 금지; `session/epoch/snapshot_seq`와 실제 hit를 검사 |
| 관찰 카메라·패널 위치 | 로컬 UI 상태 | simulation/신경 입력/기록 사건을 새로 만들지 않음 |
| 기록·marker | `ExperimentRecorder` | 시작/중지/저장 실패 상태와 실제 경로를 전체 창에 전파 |

`requested_tick`, 적용 tick, body/eye sample tick, wall-clock freshness를 혼동하지 않는다. 데이터 지연 중 과거 그래프와 live 값을 같은 시각으로 묶지 않는다. 큐가 찼거나 연결이 끊기면 실패를 숨기지 않고 기존 명령 정책대로 무변경 처리한다. 새 protocol 필드는 **정말 필요한 경우에만** 추가하고 Swift/Python 양쪽 schema 및 recorder를 함께 갱신한다.

## 5. 실행 및 창 수명 구조

1. **기본 실행 경로 결정:** Finder에서 열리는 앱 bundle/실제 런처를 하나로 정한다. 현재 문서가 안내하는 `.command` 파일은 저장소에 없다는 감사 F-04를 먼저 해결한다. bundle과 CLI가 동일한 서비스 수명·오류 UI를 사용해야 한다.
2. **real backend의 화면 분리:** 기본 실험은 `RealFlyBody(show_viewer=False)`로 실행해 물리/눈 렌더링은 유지하면서 `launch_passive` 창만 열지 않는다. 현재 `bridge.py --flygym-headless` 경로가 있으나 런처·패키지 경로와의 연결을 실제 소스로 검증하고 명확한 실행 모드로 정리한다. macOS MuJoCo passive viewer를 AppKit 창 안에 억지로 reparent하는 구현은 계획에 넣지 않는다.
3. **기존 외부 창:** `main.swift`의 데스크톱 오버레이와 `BrainWindowController` 자동 표시를 통합 모드에서 끈다. 기존 단독 데스크톱 파리 기능은 별도 명시 실행 모드로 유지할 수 있으나 실험 기본 진입과 섞지 않는다. 전역 mouse/keyboard/창 감지 자극도 통합 모드에서 정책을 명시한다. 특히 실험 UI 클릭이 전역 tap 자극으로 중복 유입되지 않는지 검사한다.
4. **주 창 생명주기:** 주 창 닫기, 앱 종료, backend 종료, 기록 중지·flush, 연결 재시도를 하나의 경로로 정의한다. 단순히 창을 닫았는데 기록/시뮬레이션이 보이지 않게 계속되는 현재 의미는 주 창에서 명확하게 결정하고 문구화한다. 저장 실패의 `Keep Open / Quit Anyway` 보호 동작을 유지한다.
5. **개발용 viewer:** 실제 MuJoCo viewer 대조가 필요하면 명시적 진단 옵션에서만 별도 실행한다. 그 모드의 존재를 기본 한 창 인수 결과와 섞어 보고하지 않는다.

## 6. 파일별 구현 책임과 순서

| 순서 | 수정 후보 | 해야 할 일과 해당 단계의 통과 조건 |
|---|---|---|
| 0. 기준선 | `docs/reports/V5_PROGRESS.md`, 감사 보고서, 실제 앱 화면/로그 | 미커밋 변경 보존. 현재 세 창/자극 흐름을 캡처. F-01~F-06과 G-01의 적용 범위·선행 여부 결정. 새 기능 전 실패 회귀를 먼저 재현 |
| 1. 단일 진입 | `main.swift`, `run_flygym.sh`, `package_app.sh`, `bridge.py`, `fly_body.py`, 실행 가이드 | 기본 실행에서 real backend·주 창만 뜨고 오버레이/뇌/MuJoCo 창이 뜨지 않음. 사용자 소유 localhost listener를 몰래 종료하지 않음. 종료 뒤 자식 프로세스 잔존 없음 |
| 2. 영구 캔버스 | `LabWindow.swift`, `LabChrome.swift`, `WorldViewer.swift`, `BrainView.swift`, 필요 시 backend render adapter | 같은 장면으로 SceneKit mirror와 MuJoCo offscreen 경로를 비교해 표현 경로 결정. 표준 split view로 개편. 좌측 도구 전환/창 크기 변경/다크모드에도 중앙 viewer 인스턴스·camera·선택·focus 정책 유지. 기존 3D 뇌와 2D 좌표 도구를 주 창에 옮김 |
| 3. 공통 상태 | `LabViewState.swift`, `LabSession.swift`, 필요 시 별도 presentation adapter | 선택 대상, 모드, 세션, 연결, 기록을 한 번 취합. viewer와 검사 영역·시간축의 ID/tick이 일치. stale/epoch 전환 시 이전 상태를 live로 오표시하지 않음 |
| 4. 맥락 조작 | `LabWindow.swift`, `ExperimentRecorder.swift` | 기존 자극/객체/뇌/기록 selector 재사용. 명령 ACK와 실제 관측치를 같은 장면에서 확인. direct neural 경로·물리 효과·관측치를 구별. recording flush와 Quit sheet 유지 |
| 5. 입력/표현 결함 | `PlayerController.swift`, `LabWindow.swift`, `WorldViewer.swift`, 필요 시 기존 backend | 감사 F-01(key-up), F-03(look delta), F-05(파리 geometry 표시)의 사용자 영향 해결. F-02 충돌 결함은 V5.5.1 출시 전 해결·회귀 또는 명시적 안전 제한이 필요하며 단순 UI로 가리지 않음 |
| 6. 문서·인수 | `README.md`, `docs/guides/*`, `docs/reports/V5_5_1_PROGRESS.md`, 완료 보고서 | 사용자가 실제 열 수 있는 경로와 화면 문구 일치. 아래 검증을 완료한 뒤 V5.6으로 이동 |

각 단계는 하나씩 구현하고 해당 회귀와 실제 창 확인 후 다음 단계로 간다. 파일 목록은 책임 지도로서 새 타입/파일을 반드시 만든다는 지시가 아니다. 사용자 변경이 있는 파일은 시작 당시 diff를 보존해 통합한다.

## 7. 검증과 출시 판정

### 자동·실제 backend

- 현재 `build.sh`, Swift `--bridgetest --labtest --v4test --v4timingtest --simtest --behaviortest --gpucheck`, Python bridge/lab/V4/V5/real lab/real vision 검사를 영향 범위에 맞춰 재실행한다. GPU와 timing-sensitive 검사는 동시 실행하지 않는다.
- 새 검사: 기본 런처의 창 생성 수와 프로세스 수명, headless real backend의 world/eye/body parity, 도구 전환 중 viewer 상태 유지, UI 클릭의 전역 tap 중복 방지, 명령 pending→ACK/실패, 기록 중 Quit 실패 경로.
- F-01/F-03 재현 fixture와 F-02 실제 벽 충돌/입력 해제 fixture를 선행 수정 기준으로 둔다. mock TCP와 real-headless TCP는 **각각 새 backend**로 검사하고 기존 17841 listener를 건드리지 않는다.
- 성능은 통합 GUI에서 viewport FPS, snapshot Hz, body packet Hz, sim/wall ratio, 자극 클릭→ACK p50/p95, 메모리와 창 전환/패널 펼침 지연을 측정해 V5.5 기준선과 비교한다. 목표 수치는 기준선 측정 후 명시한다. 예쁜 화면 때문에 실제 물리/신경 tick이 악화되면 출시하지 않는다.

### 실제 macOS GUI 인수 동선

새 앱 프로세스에서 실물 backend로 다음을 **실제 화면·접근성 트리·로그**로 확인한다. 빌드 성공이나 headless 테스트는 이를 대체하지 않는다.

1. 처음 실행: 표준 제목 막대가 있는 주 창 한 개, real backend 연결, 별도 MuJoCo/뇌/오버레이 창 없음.
2. 세계 관찰 중 사이드바 `자극` 선택: 세계가 계속 움직이고 카메라/선택/현재 tick 유지. 바람과 눈 가림을 적용해 pending/ACK/실제 반응 확인.
3. `뇌`/`데이터`/`실험` 전환: 캔버스 유지, 같은 session/tick, marker/그래프/기록 상태 일치. 기존 3D 뉴런 점군·발화·선택과 2D 좌표 도구도 주 창에서 사용 가능.
4. 참여 capture → W/E/look → 텍스트 입력/사이드바/Esc/창 비활성화: held input이 backend에서 해제되고 다시 클릭하기 전 재개되지 않음.
5. pause 중 카메라 이동은 가능하지만 world/brain/player tick 정지. resume 후 같은 세션으로 정상 재개.
6. backend 종료·재연결, 오래된 snapshot, 명령 거절, 기록 저장 실패/종료 sheet: 거짓 live/applied/saved 표시 없음.
7. 창 크기 축소·확대, 전체 화면, 밝게/어둡게, 키보드만으로 이동, VoiceOver 이름/값, Reduce Motion, 스크롤/패널 접기: 겹침·잘림·포커스 소실 없음.

### 완료 기준

**V5.5.1 완료**는 위 단일 창 동선과 자동/real backend/GUI/성능 gate가 모두 통과하고, 미해결 F-01~F-06/G-01을 완료 또는 정확한 잔여 제한으로 판정하고, 결과를 `docs/reports/V5_5_1_COMPLETION_REPORT.md`에 증거 경로와 함께 남겼을 때만 선언한다. 특히 F-02를 남긴 채 참여 이동을 정상 제품 경험이라고 표시하지 않는다. 완료 전 V5.6 구현을 시작하지 않는다.
