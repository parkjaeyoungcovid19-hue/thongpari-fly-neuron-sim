# Virtual Fly Lab V8.1–8.3 완료 보고서

2026-10-12 · 브랜치 `v8.1-8.3` · [진행표](V8_PROGRESS.md) · [V7 완료 보고서](V7_COMPLETION_REPORT.md)

**이번에 끝낸 것은 V8.1–8.3뿐이다.** V8.4–8.7은 시작하지 않았으므로 V8 전체는 아직 완료가 아니다. 실제 게임 모듈, 게임 API, 화면 인식, 키 입력 자동화는 만들지 않았다. 모듈은 시험용 fixture만 있다.

## V8.1 채널 계약 (`1af8289`)

[`ExternalIOProtocol.swift`](../../Sources/Bridge/ExternalIOProtocol.swift), [`schemas/external-io.schema.json`](../../schemas/external-io.schema.json), [`fixtures/external-io/`](../../fixtures/external-io/)

- **신경 출력 표.** `BrainSignals`, `SignalBuilder`, FlyGym `brain` packet이 실제로 내보내는 값을 정리한 표가 `ExternalIONeuralOutput.fields`다. 값마다 이름, 단위, 범위, continuous/discrete 여부, 갱신 주기(렌더 프레임 기준 60 Hz, 측정값이 아닌 명목값)를 적었다. forward/turn 같은 값을 게임 동작으로 자동 변환하지 않는다.
- **`external_io.v1` 계약.**
  - `ModuleDescriptor`: id, version, api_version, attach_mode(auxiliary/external_environment), clock_mode(lockstep/wall_clock), restore_support, capabilities와 required_capabilities, observation/action 채널, budgets.
  - 채널 정의: kind, unit, axis, rate_hz, range/length/choices/formats.
  - budgets: 프레임 최대 16 MiB, 해상도 최대 4096×4096, 큐 깊이 최대 64.
  - `ObservationFrame`: session/epoch/seq, source_tick, timebase, valid_until, 채널, 크기 제한이 있는 frame 참조. `receive_monotonic_time`은 호스트가 따로 찍는다.
  - `ActionFrame`: neural_tick, target_endpoint, decoder_version, expires_tick, action_id, continuous/discrete 동작.
  - lifecycle: discovered → validated → attached → ready → running → draining → detached, 그리고 별도 상태 failed.
- **엄격한 decode.** 아래 경우 reject 코드와 함께 거절한다.
  - 필수 필드 누락, NaN/Inf, 배열 길이 오류
  - 모르는 단위·축, 지원하지 않는 api_version, 범위 밖 값
  - 모르는 필수 capability, 과대 프레임
  - auxiliary 모듈의 action 선언
  - lockstep 모듈인데 timebase가 sim_tick이 아님
- **허용 규칙.** optional로 표시한 관측 채널과, 계약에 없는 추가 키는 허용한다.
- **fixture.** 유효한 descriptor 2개(`fixture.sensor_loopback`, `fixture.loopback`), 유효한 frame들, 그리고 거절 코드가 정해진 `mutations.json` 36건이다.

## V8.2 호스트 registry (`3fcb58b`)

[`ModuleRegistry.swift`](../../Sources/Bridge/ModuleRegistry.swift), [`LabWindow+Modules.swift`](../../Sources/Lab/LabWindow+Modules.swift)

- **설치된 모듈만 등록한다.** `~/Library/Application Support/ThongpariFlyNeuronSim/modules/*.json`에 있는 파일만 읽고, 폴더가 없으면 빈 목록이다. 폴더는 만들지도 쓰지도 않는다.
- **거절과 제한.** 잘못된 descriptor는 이유와 함께 "거절됨" 목록에 남기고 버리지 않는다.
  - 같은 module_id가 두 번 나오면 나중 것을 `duplicate_id`로 거절한다.
  - 256 KB를 넘는 파일, symlink, 일반 파일이 아닌 것은 읽지 않는다.
  - 한 폴더에서 최대 256개만 읽는다.
- **데이터로만 다룬다.** dlopen, Process, script를 쓰지 않는다. descriptor 안에 `command`/`script` 같은 키가 있어도 실행하지 않고, 결과 descriptor에 옮기지도 않는다.
- **World 페이지 "외부 모듈" 섹션.** 내용은 descriptor로 만든 view model에서 나온다. 모듈별로 lifecycle 상태와 채널(방향, 종류, 단위, 축, 범위, Hz)을 보여 주고, 거절된 descriptor는 이유와 함께 보여 준다. 게임 이름을 코드에 박아 둔 곳은 없다.

## V8.3 권한·제어권 경계 (`deb83d3`, 검증 수정 `3788bd3`)

[`ExternalIOSession.swift`](../../Sources/Bridge/ExternalIOSession.swift)

- **몸 출력 소유자는 하나뿐이다.** 기본 world이거나, external_environment 모듈 하나다.
  - auxiliary 모듈은 출력을 요구하면 `mode_violation`으로 거절된다. 자기가 선언한 관측 채널만 쓸 수 있다.
  - 두 번째 controller는 `output_owned`로 거절되고, 상태는 바뀌지 않는다.
  - 소유자를 바꿀 때는 기존 소유자를 release한 뒤 새 소유자가 acquire한다.
  - release가 실패하면 세션은 failed로 고정되고 소유자를 다시 배정하지 않는다. `acknowledgeFailure`를 거쳐야만 기본 world로 돌아간다.
- **Coordinator 훅.** `externalIO.defaultWorldWritesOutput`이 아래 두 곳을 막는다.
  - FlyGym으로 가는 DN 명령 전송.
  - 오버레이 파리 #1의 구동. 외부 모듈이 소유하는 동안 파리 #1은 `Fly.hold`로 제자리에 멈춘다.
- **검증 중 고친 결함 (`3788bd3`).** 처음에는 출력을 넘긴 뒤 파리 #1에 `signals: nil`을 넘겼다. 그러면 파리는 기존 자동 행동(배회, 무작위 이륙, 마우스 회피)으로 넘어가서, 기본 world가 계속 몸을 움직였다. 대조군이 있는 테스트로 이 수정을 확인한다.
- **연결된 모듈이 없을 때.** 기본 경로의 brain packet은 세션 객체가 없는 실행과 바이트 단위로 같다. JSON 키를 정렬해 비교한다.
- **UI.** 출력 소유자, 모듈마다 지금 허용된 입출력 채널, failed 표시를 보여 준다. 버튼은 Rescan, Attach test module, Take body output, Detach다. 버튼은 `fixture.loopback`에만 연결돼 있다.

## 검사

| 검사 | 결과 |
|---|---|
| `--externaliotest` | 113/113 PASS. 내역은 아래와 같다 |
| V8.1 | fixture 왕복, 36개 mutation 거절 코드 일치, 신경 출력 표가 `BrainSignals`와 일치(Mirror)하고 `SignalBuilder` 극단 입력이 선언 범위 안에 있음 |
| V8.2 | 정상·잘못된·중복 descriptor, script 키 무시, 소스에 실행 API 없음, view model |
| V8.3 | 컨트롤러 3개를 거는 12가지 순서, 두 스레드 경쟁 200회에서 소유자 정확히 1명, 잘못된 전이 거절, release 실패 시 failed, 모듈 없을 때 바이트 동일, 소유 중 파리 #1이 제자리이고 대조군은 움직임 |
| V8-06 범위 | fixture, schema, V8 소스에서 실제 게임 이름 deny-list 검사 PASS |
| 기존 회귀 | [V7 보고서](V7_COMPLETION_REPORT.md) §3과 같은 실행에서 15개 flag와 Python unit exit 0 |

**실제 GUI**: Codex CLI(`gpt-6-luna`, max)로 확인했다. 상세 결과는 [GUI 보고서](../../notes/validation/v7-6-8-3-gui-2026-10-12/REPORT.md)에 있다.

| 항목 | 판정 | 확인한 내용 |
|---|---|---|
| T8 | PASS | 모듈 폴더가 없을 때 빈 목록 |
| T9 | PASS | 정상·잘못된 단위·중복 descriptor 표시와 거절 사유. 끝난 뒤 폴더 정리 |
| T10 | PARTIAL | 백엔드 연결 상태에서 default_world → Attach → Take body output → Detach → Rescan 후 재Attach를 확인. 소유 중에는 새 brain 명령이 없었고 몸 속도가 0으로 수렴 |

T10이 PARTIAL인 이유는 두 가지다.
- 백엔드가 없는 실행에서는 오버레이 파리가 그려지지 않아, "멈춤"을 눈으로 확인하지 못했다. 이 동작은 headless 대조 검사로만 확인했다.
- auxiliary 모듈의 출력 거절과 두 번째 controller 거절은 UI로 시험할 경로가 없어 headless로만 확인했다.

## V8-01–06 대응 (이번 범위)

| ID | 상태 |
|---|---|
| V8-01 호환성 | 잘못된 버전·단위·축·필수 capability는 거절되고, 기존 경로는 보존된다. PASS (decode·registry 수준) |
| V8-02 neural 왕복 | V8.4 범위. 미착수 |
| V8-03 old/duplicate | V8.6 범위. 미착수 |
| V8-04 held input | V8.7 범위. 미착수. 아래 한계 참고 |
| V8-05 resource | budget 상한은 계약 단계에서 검사한다. 실제 큐와 영상 전송은 V8.6 범위 |
| V8-06 범위 확인 | 실제 게임 모듈 0개, fixture만 있음. PASS |

## 한계

- **이어서 실행되는 명령.** 외부 모듈이 몸 출력을 가져가면 새 명령은 끊긴다. 하지만 FlyGym 몸이 마지막으로 받은 명령을 계속 실행할 수 있다. neutral/release 순서는 V8.7에서 다룬다.
- **release ACK.** 아직 진짜 ACK가 없고, `releaseHandler`는 기본값 true인 placeholder다.
- **미구현.** action frame 전달·소비, clock 협상, 큐, 영상 전송은 V8.4–8.6 범위다.
- **detached 재연결.** detached는 끝 상태라서, 같은 모듈을 다시 attach하려면 Rescan해야 한다.
- **UI 대상.** UI 버튼은 `fixture.loopback`에만 연결돼 있고, 모듈을 고르는 선택기는 아직 없다.

## 재실행·rollback

- 재실행: `./build.sh && ./ThongpariFlyNeuronSim --externaliotest`. fixture는 바이너리 옆 `fixtures/external-io/`에서 읽는다.
- rollback: `git revert 3788bd3 deb83d3 3fcb58b 1af8289`.
- schema: `external_io.v1`(`schemas/external-io.schema.json`).
