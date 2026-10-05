# V6.1 기존 제어 inventory·descriptor 계약 — 2026-10-05

## 판정

**V6.1 자동 검증 통과. 실제 headless TCP 성능 게이트는 이번 측정 환경에서 FAIL(22.8 Hz < 30 Hz)이며, manifest와 무관함을 A/B로 확인했다. 전원 연결 상태에서 재측정이 필요하다.** V5 GUI·live 수용은 사용자 요청으로 계속 보류 중이며, V5와 V6 전체는 미완료다.

기준 HEAD: 799067408bc7be23733d24768fd8276c267a43b0 + 미커밋 변경. 설치·커밋·푸시 없음.

## 인수 경위

DeepSeek Harness(dsh)의 GPT-6.1 Sol high 세션이 V6.1을 구현하다가 18:02 KST에 ChatGPT 사용 한도로 중단됐다. 같은 세션의 Python 하위 에이전트와 리뷰 하위 에이전트도 함께 멈췄다. Claude(Opus 5.5)가 세션 기록을 읽고 남은 작업을 이어받았다.

중단 시점 상태는 다음과 같았다.
- 1536개 객체 대용량 상태 fixture를 요청만 하고 만들지 못했다.
- 리뷰어가 지적한 유니코드 비교 불일치(P3)가 수정되지 않았다.
- 마지막 빌드는 편집 중 파일 변경으로 실패했다.
- 최종 회귀를 실행하지 않았다.

## 산출물

- [descriptor 계약(Swift)](../../../EnvironmentProperty.swift): strict decode를 수행한다. 외곽 `lab_state` decode는 잘못된 manifest를 통째로 버리지만, 나머지 telemetry는 보존한다.
- [registry·strict validator(Python)](../../../flygym_bridge/environment_properties.py): descriptor 39개. [state export](../../../flygym_bridge/lab_world.py)에 가산 필드로 추가했다.
- [현재 제어 inventory](../../../docs/reports/V6_CONTROL_INVENTORY.md): 지원 속성과 descriptor의 대응, 숨김·제외 목록, UI와 backend 범위 차이(온도 10~40 vs 0~50°C, 바람 정규화 0~1)를 정리했다.
- [공유 fixture 14개](../../../fixtures/environment_capabilities/): `valid*`는 수락, 나머지는 거절해야 한다. Swift와 Python이 같은 디렉터리를 모두 검사한다.

## 인수 후 수정

1. **전송 한도 회귀(P2, 리뷰어 발견을 재현):** 지원되는 최대 구성(형태별 256 슬롯, 1536개 객체, ID 64자)의 frame은 manifest 없이 516,714 B, manifest 포함 시 538,225 B다. 기존 Swift 512 KiB 한도에서는 이 줄 전체(state, ACK, telemetry)가 버려진다.
   - GPT가 한도를 1 MiB로 올려 두었고, 내가 [fixture 생성기](make_large_state_fixture.py)로 [실제 encode fixture](../../../fixtures/bridge/v6-large-state.ndjson)를 만들었다.
   - `--bridgetest`가 이 fixture를 4 KiB 조각으로 실제 수신 경로에 넣어 state 1536개, descriptor 39개, ACK 101 보존을 확인한다. 1 MiB를 넘는 줄의 거절도 확인한다.
   - Python 테스트도 같은 구성이 1 MiB 미만인지 확인한다.
2. **유니코드 일치(P3):** Swift `String`의 `==`/`Set`은 정규 등가를 쓰므로 `é == é`로 판정한다. Python은 코드포인트로 비교한다. 수정 내용은 다음과 같다.
   - Swift를 scalar 비교로 바꿨다.
   - 공백 판정을 Python `str.strip()`과 같은 집합으로 맞췄다. Foundation 공백 집합에 U+001C~U+001F를 더하고 U+200B를 뺐으며, 모든 scalar를 Python 3.12와 대조해 일치를 확인했다.
   - fixture 3개를 추가했다: `valid-unicode-identity`, `bad-unicode-choice`, `bad-control-whitespace`.
   - **음성 대조:** 수정 전 Swift는 세 fixture를 모두 Python과 반대로 판정했다(수락→거절, 거절→수락, 거절→수락). 수정 후에는 일치한다.
3. **export 비용:** 검증된 manifest는 스칼라와 평평한 리스트로만 이뤄져 있으므로, 범용 `deepcopy` 대신 리스트만 복사해도 완전한 격리가 유지된다. 출력은 동일하고 격리 테스트도 통과했다.
   - `state()` p50: 462 → **55 µs**
   - state+NDJSON p50: 641 → **231 µs**

GPT 단계에서 이미 고친 것: 최초 `--labtest`가 실패했는데, 원인은 테스트 상태 fixture에 필수 `yaw_deg`가 빠진 것이었다. 또한 `start_approach` 테스트 인자 누락, empty effects 허용, 길이 계산의 unicodeScalars 통일, cache 격리를 처리했다.

## 최종 실행

실행 위치는 저장소 루트다. Python은 `PYTHONDONTWRITEBYTECODE=1`로, 중량 검사는 순차로 실행했다.

| 검사 | 결과 |
|---|---|
| ./build.sh | [exit 0](build-final.log) |
| --labtest | [exit 0, PASS 128](labtest-final.log) — V6.1 fixture 14개 strict 및 외곽 state 보존 |
| --bridgetest | [exit 0, PASS 97](bridgetest-final.log) — 538,226 B fixture 수신 및 1 MiB 초과 거절 |
| --v4test / --v4timingtest | [exit 0](v4test-final.log) / [exit 0](v4timingtest-final.log) |
| --simtest | [exit 0](simtest-final.log) — 휴지 시 GF 0, abrupt loom 첫 발화 3 ms, 16-step 159 µs/step |
| --behaviortest | [exit 0](behaviortest-final.log) — 재실행 없음 |
| --gpucheck | [exit 0](gpucheck-final.log) — 15,091,983개 가중치 중 불일치 0 |
| Python test_environment_properties | [21 tests OK](test_environment_properties-final.log) |
| Python test_feeding_events, test_bridge, test_lab, test_v4, test_v5, test_v5_6 | 모두 exit 0, 최적화 후 재실행 |
| Python test_lab_real, test_v5_6_2 | exit 0, 최적화 후 재실행 |
| Python test_interaction_real, test_player_collision_real, test_vision_real, test_v5_6_2_tools | 모두 exit 0 |
| fresh real-headless --bridgeloop | **[FAIL](bridgeloop-real.log)**: body 22.7 Hz, max gap 56 ms, sim/wall 0.460 ([기록](performance-result.json)) |

## TCP 성능 FAIL 분석

[A/B 기록](ab-manifest-tcp.txt): [실행기](ab_gate.py)는 같은 조건에서 실제 백엔드와 [manifest 제거 래퍼](nomanifest_bridge.py)를 번갈아 3회씩 실행한다.

| 회차 | manifest 포함 | manifest 제거 |
|---|---|---|
| 0 | 22.8 Hz · gap 56 ms · 0.437 | 22.8 Hz · gap 56 ms · 0.437 |
| 1 | 22.9 Hz · gap 54 ms · 0.475 | 22.8 Hz · gap 56 ms · 0.446 |
| 2 | 22.8 Hz · gap 55 ms · 0.472 | 22.8 Hz · gap 56 ms · 0.450 |

manifest 유무에 따른 차이는 없다. 같은 날 17:21 V5 측정의 38.1 Hz와 다른 점은 측정 환경이다.
- V5 측정: 16:08부터 AC 전원(충전 64→80%)이었다.
- 이번 측정: 17:54부터 배터리 전원이고 `pmset` lowpowermode가 1이었다. 부하 평균은 약 3.5였다.

전원 조건이 원인이라는 판단은 추정이며, 전원 연결 상태에서 재측정해야 확정된다. 시스템 전원 설정은 바꾸지 않았다. 재측정 명령은 다음과 같다.

    ./flygym-venv/bin/python notes/validation/v6-1-2026-10-05/run_real_gate.py
    ./flygym-venv/bin/python notes/validation/v6-1-2026-10-05/ab_gate.py

## 남은 위험과 처분

- **Swift decode 비용:** pretty-printed 29.6 KB 기준 standalone p50은 0.85 ms다. 수신 스레드에서 lab_state마다 발생한다(2 Hz 및 명령 ACK마다). 수용한다. V6.3 gizmo 드래그처럼 명령 빈도가 높아지면 다시 측정하고, 필요하면 manifest를 revision이 바뀔 때만 보내도록 바꾼다.
- **Swift 온도 처리:** Swift는 온도를 backend ACK 전에 로컬로 반영하고 backend 값과 맞추지 않는다. 기록만 하고 V6.1에서는 고치지 않는다(기존 동작이며 V6.5 환경 패널에서 다룬다).
- **source와 descriptor 상수 이중화:** drift 위험이 있다. 실제 함수 기본값·clamp 대조 테스트로 완화했다.
- **GUI 미검증:** 이번 단계는 UI 변경이 없는 read-only 계약이다. V5 GUI 보류는 그대로 유지한다.

## 정리

실행한 백엔드는 모두 종료(-15)했고 17841 포트는 다시 bind할 수 있다. 최종 `pgrep`에서 bridge.py와 ThongpariFlyNeuronSim 프로세스는 없었다. `git diff --check`는 통과했다. 기존 무관한 dirty·untracked 파일은 건드리지 않았다. 중간 산출물(`build-initial.log`, 최초 실패 `labtest.log`)은 이 폴더에서 정리했고, 최초 실패 원인은 위에 기록했다.

## GUI 관찰 검증 (19:10 KST, 입력 없음)

- **조건:** 이 세션에는 전용 Computer Use 도구가 연결돼 있지 않았다. 화면 기록은 허용돼 있었지만 손쉬운 사용 권한이 없었다(`System Events UI elements enabled = false`). 따라서 클릭·키 입력 없이 창 캡처만 했다. 전원은 배터리, lowpowermode=1이었다.
- **실행:** `./ThongpariFlyNeuronSim --lab`(실제 headless backend)을 띄우고 `screencapture -l`로 창만 캡처했다.
- **관찰 결과 — 정상:** 실제 NeuroMechFly 폴리곤 파리가 렌더링됐다. 세계 탭, 지도, 기본 장애물 1개가 보였다. 용량은 `box 1/64 · sphere 0/64 · wall 0/64 · food 0/8 · car 0/4 · trap 0/2`로 food 8이 맞았다. 타임라인의 몸 데이터 나이는 52 ms였다. 캡처: [world](gui/world-1-small.png).
- **관찰 결과 — 렌더링 중 live 성능 FAIL:** 상태줄에 "몸 데이터 초당 12회 → 9회 · 실시간 대비 0.40배 · 느림: 몸 데이터가 초당 30회 미만"이 표시됐다. 캡처: [상태줄](gui/world-2-status.png). headless TCP(22.8 Hz)보다 낮은 이유는 렌더 스트림이 함께 돌기 때문이다. 다만 측정 환경이 배터리·저전력 모드라서 이 수치를 코드 회귀로 판정하지 않는다.
- **미실행:** 음식 8개와 9번째 거절, 삭제·재사용, 섭식 중 삭제, 장난감, 카드 일시정지, 탭 이동. 모두 입력이 필요하다.
- **정리:** 앱을 SIGTERM으로 종료했다. 남은 프로세스 없음, 렌더 포트 해제를 확인했다.
