# 브리지 리팩토링 — 2026-09-22

기준 commit: `c86593b` (`Fix V5.5 Participate capture flow`). 기존 미추적 전체 감사 보고서와 `notes/validation/overall-2026-09-22/`는 수정하지 않았다. 이번 범위는 현재 V5.5 브리지의 동작 보존 리팩토링이며 새 버전 기능이나 물리/신경 모델 변경은 없다.

## 변경 내용

- `FlyGymBridge.swift`: 3,242 → 1,264줄. TCP 송수신, 큐, 연결 수명 관리에 집중하도록 패킷/진단을 분리했다. 이는 파일 분리 수치이며 전체 코드가 그만큼 삭제됐다는 뜻은 아니다.
- `FlyGymPackets.swift`: wire packet 선언, 엄격한 타입별 디코더, body feedback 및 감각 매핑. 기존 packet 선언과 feedback/mapping 본문은 원본과 byte 단위로 동일함을 확인했다.
- `BridgeDiagnostics.swift`: 기존 `--bridgetest`, `--bridgeloop`, `--v4loop`, `--labloop` 진단을 그대로 이동했다. 테스트 접근점만 모듈 내부 접근으로 변경하고, 잘못된 수신 패킷/이스케이프된 type에 대한 회귀 2개를 추가했다.
- `build.sh`: 두 새 Swift 파일을 명시적인 컴파일 목록에 등록했다. 기존 런처의 `*.swift` 변경 감지는 새 파일도 포함한다.
- `flygym_bridge/bridge.py`: atomic snapshot 생성, ray pick 응답, 세션 검증/예외 변환, 캐시/송신 흐름을 별도 메서드로 분리했다. 성공/오류 응답의 캐시 저장과 큐 삽입을 한곳으로 모으고, 네 곳의 queue drain과 두 revision 조회의 중복을 제거했다.

## 최적화와 유지한 계약

Swift 수신부의 순차적인 `parseHelloLine` → … → `parseBodyLine` 재파싱을 `FlyGymInboundPacket`의 type switch로 대체했다. 하나의 `JSONDecoder`가 type과 해당 payload를 함께 읽는다. 독립 parser 함수도 같은 payload decoder를 사용한다.

- body 수신: top-level JSON decode 호출 **8 → 1회**.
- lab_event 수신: top-level JSON decode 호출 **11 → 1회**.
- 타입별 payload 검증, legacy body 기본값/clamp는 유지한다.
- JSON decode는 lock 밖에서 수행한다. 연결 generation 검증과 unlock은 공통 진입점/`defer`로 관리한다.
- body 통계/수신 시간 갱신은 `acceptBodyLocked`에서 처리해 일반 telemetry와 deterministic step result의 중복을 제거했다.
- session/epoch/seq 검증, snapshot 순서, bounded queue, reconnect 캐시 무효화, physics tick 권한은 유지한다.

## 검증

모든 로그는 `notes/validation/refactor-2026-09-22/`에 있다. 테스트 명령은 저장소 루트에서 실행한다.

| 검사 | 결과 | 근거 |
|---|---|---|
| 수정 전 build, Swift bridgetest | exit 0 | `baseline-build.log`, `baseline-bridgetest.log` |
| 수정 전 Python bridge/lab/V4/V5 | 모두 exit 0 | `baseline-test_*.log` |
| 수정 후 `./build.sh` | exit 0 | `build.log` |
| Swift `--bridgetest` | 92 PASS, exit 0 | `bridgetest.log` |
| Swift `--labtest` | 37 PASS, exit 0 | `labtest.log` |
| Swift `--v4test` / `--v4timingtest` | 18 / 5 PASS, exit 0 | `v4test.log`, `v4timingtest.log` |
| Python `test_bridge.py`, `test_lab.py`, `test_v4.py`, `test_v5.py` | 44 / 54 / 47 / 31 PASS, exit 0 | 각 `test_*.log` |
| 실제 MuJoCo `test_lab_real.py`, 실제 눈 `test_vision_real.py` | 63 / 13 PASS, exit 0 | 각 `test_*_real.log` |
| `validate_experiment_presets.py` | 11 presets, exit 0 | `validate_experiment_presets.log` |
| 실제 TCP mock: bridgeloop, labloop, v4loop | 모두 exit 0 | `fresh-mock-*.log` |
| 실제 TCP real-headless: labloop, v4loop | 모두 exit 0 | `fresh-flygym-headless-*.log` |
| Swift `--simtest`, `--behaviortest` | 모두 exit 0 | `simtest.log`, `behaviortest.log` |
| Swift `--gpucheck` | GPUCHECK PASS, exit 0 | `gpucheck.log` |
| `git diff --check` | 통과 | whitespace 검사 |

TCP 검사는 각 모드/검사마다 새 backend를 사용했다. 시작 전 기존 listener가 없는지 확인하고, `finally`에서 이 검사에서 생성한 PID만 종료했다. 재실행:

```sh
./flygym-venv/bin/python notes/validation/refactor-2026-09-22/fresh_transport_probe.py
```

## 디코딩 벤치마크

기준 commit의 parser 함수와 기존 수신부의 타입 검사 순서를 독립 harness에 복사해, 현재 `FlyGymInboundPacket`과 같은 입력으로 비교했다. `swiftc -O -swift-version 5`, warmup 100회, 3,000개 입력 × 7라운드의 중앙값이며 매 라운드 실행 순서를 바꿨다. 양쪽 모두 각 fixture에서 42,200회의 성공 수를 확인했다. TCP/GPU 검사가 끝난 후 측정했다.

측정 환경: Apple M2, macOS 26.6.2, Apple Swift 6.3.3 (arm64).

| 입력 | 기존 3,000회 | 변경 후 3,000회 | 처리 속도 비율 |
|---|---:|---:|---:|
| body telemetry | 134.259 ms | 40.182 ms | 3.34× |
| lab_event | 50.045 ms | 7.112 ms | 7.04× |

근거: `decode-benchmark.log`. 비교 대상은 JSON dispatch/payload decode이며 socket I/O, lock 경합, rendering, physics는 측정에 포함하지 않는다. 비교 harness의 main은 앱 실행을 건너뛰므로 `benchmark-build.log`에 unreachable-code 경고가 있다. 제품 `build.log`에는 경고가 없다.

재실행:

```sh
python3 notes/validation/refactor-2026-09-22/build_decode_benchmark.py
notes/validation/refactor-2026-09-22/decode-benchmark/benchmark
```

이번에 새 GUI 조작 검증은 수행하지 않았다. 화면/입력 UX, 이전 감사 항목들의 해결 여부, V5 전체 인수 완료를 이 리팩토링 결과만으로 판단하지 않는다. 성능 측정도 패킷 디코딩에 한정하며 앱 전체 FPS/실시간 물리 성능 향상을 의미하지 않는다.
