# Virtual Fly Lab V7.1 완료 보고서

2026-10-08 · **사용자 요청한 V7.1까지 완료. 전체 V7은 미완료.** [V6 완료](V6_COMPLETION_REPORT.md) 후 기존 관측 audit만 수행했다.

## 결과와 변경

- [관측 audit](V7_OBSERVATION_AUDIT.md)에 BrainSignals 10개·모든 기존 rate의 단위, normalization, EMA, simulation/wall time, 실제 membership/분모를 기록했다. GF latch는 exact 사건이며 읽으면 소비됨; turnBias는 rad/s가 아닌 normalized command. 미각은 alternate32ms coverage라 공통 EMA와 구별한다.
- `LabWindow.swift`, `BrainView.swift`, `NeuronGuide.swift`에서 뇌 반짝임의 sampled 출처와 불완전한 count/timing을 항상 보이는 안내·범례·AX·독립 창 제목에 명시했다. 클릭은 기존 직접 자극이며 변경하지 않았다.
- `ActivityCards.swift`와 Data graph label은 Hz/뉴런, 일반120ms EMA와 미각 covered120ms/elapsed240ms 설명으로 고쳤다. `Sim.swift`/`LIF.metal`의 단위/표본 race 주석만 정정, kernel·신경 방정식·motor mapping은 유지했다.
- 신규 `ObservationAuditDiagnostics.swift`/`--observationaudittest`는 기존 API만 감사한다. V7.2 observation primitive·registry·raster·event buffer를 추가하지 않았다.
- 최종 전달에서 발견한 `FlyGymService` UI blocking file probe를 background로 이동하고 강제로 멈춘 probe 회귀2개를 추가했다. 패키지는 `THONGPARI_APP_OUTPUT`으로 비-iCloud 출력 위치를 지정할 수 있다. 기존 generated marker 보호와 서명 검증은 유지한다.

## 실제 검사

[증거 폴더와 전체 명령/exit](../../notes/validation/v7-1-2026-10-08/README.md).

| 검사 | 결과 |
|---|---|
| `./build.sh`, 비-iCloud output `./package_app.sh`, signature verify | 최종 exit0 |
| `--observationaudittest` | 0 failures. 분모14개 independent CPU membership 일치. 30sim-ms full139 vs sample100. 3,000 display reads/bus drain이 time/extInput/membrane/refractory/spike/count 불변. overflow400→256, GF motor latch 보존·consume의 파괴성 확인 |
| `--gpucheck` | GPUCHECK PASS, independent CPU spike/group/rate comparison 및12.2sim-s burst; exit0 |
| `--simtest`, `--behaviortest` | exit0, 기존 circuit/body invariants 보존 |
| `--worldeditortest`, `--labtest`, `--v4test`, `--bridgetest` | 각각 exit0. service/legend 마지막 UI 수정 후 `--labtest` 최종 재검사 exit0 |
| `tools/verify_data.py --no-parquet` | ALL CHECKS PASSED, binary hashes/CSR 검증; parquet 재대조 제외 |
| 실제 GUI | 최종 local signed bundle 새 실행→real backend :61757 연결→Brain/Data source 안내와 한국어↔English, card source 조회→World scene capability 확인→정상 종료. 최종 AX/PNG와 backend 로그 존재 |

## 남은 제약 / 재실행

V7.2–7.7은 미착수. 현재 sampler는 loss counter/tick 없는 표시용 큐이므로 exact raster/latency를 만들 수 없으며 UI에서 그 출처를 밝힌다. 기본 Brain 클릭이 read-only 선택으로 바뀌었다고 주장하지 않는다. full V7 scenario V7-01–06은 이번 범위에서 전부 구현한 것이 아니다.

Finder-style launch는 창은 반응하지만 이 Mac에서 Python runtime file open 대기가 남았다. 실제 검증된 [Run Verified App.command](../../notes/validation/v7-1-2026-10-08/Run%20Verified%20App.command) / signed executable launch를 사용한다. iCloud dist metadata 때문에 default package 마지막 시도는 실패했고 비-iCloud output/signature 최종0. 원인 단정·시스템 보안 변경 없이 [V6 보고서 한계](V6_COMPLETION_REPORT.md)에 기록했다.

재실행: `./build.sh`, `./ThongpariFlyNeuronSim --observationaudittest`, `--gpucheck`, `--labtest`; scene TCP는 backend isolation을 가진 `run_transport.py`. 코드 rollback은 인계 backup과 diff를 파일별 검토하고 기존 사용자 dirty 작업을 보존한다. 이번 작업은 commit하지 않았다. dynamic runtime observation state 추가 없음; [future state inventory](V6_FUTURE_STATE_INVENTORY.md)에 sampled queue 표시 상태를 기록했다.

완료 단계: V7.1. fixture: shipped FlyWire v783 binary hashes 및 exact/full/sampled 대조 diagnostic. 실제 GUI: yes (위 실행 경로); Finder standalone backend acceptance: no. 다음 단계: V7.2 정확 관측 primitive, 사용자 요청 범위 밖.
