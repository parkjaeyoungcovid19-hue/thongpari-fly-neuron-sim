# V5.6 TCP 통합 재실행 (부모 Claude) — 2026-09-26

`../tcp-loop/`의 Codex 실행은 기능 동선은 통과했지만 **FAIL 2건**이었다. Swift가 `lab_state.interaction.carry_speed_mm_s`와 `lab_event.data`(id·reason·sim_tick_ms·접촉 힘)를 버렸기 때문이다. 이 폴더는 그 결함을 고친 뒤의 재실행이다.

## 부모가 고친 것

- `LabProtocol.swift`: `LabEventDetail`(모든 필드 선택, 잘못된 data는 상세만 버리고 사건은 유지), `LabEventNotice.detail`; `LabInteractionState.carrySpeedMMs`(선택, 있으면 유한 >0).
- `LabWindow.swift`: 타임라인 사건 줄에 상세 요약(대상, 파리 부위, 힘 — MuJoCo 모델 단위로 표시, 지속시간, `@sim_tick_ms`)과 사건 tick을 기록.
- `BridgeDiagnostics.swift` `--interactionloop`: 두 FAIL 자리를 실제 검사로 교체. 속도는 **live backend 값**과 비교하고, 인접 snapshot의 ms 양자화로 부풀려지는 것을 피해 **≥100 ms 창**에서만 잰다(mock 첫 실행에서 인접 쌍 최대 41.94 mm/s가 +2 여유 경계에 붙어 흔들릴 수 있었다).
- `--labtest`: 사건 상세 decode·잘못된 상세 대조, carry_speed 선택 엄격 decode 검사 추가.

## 결과 (저장소 루트, backend는 모두 시험이 직접 띄운 fresh 인스턴스, 실행 전 17841 비어 있음 확인, 끝난 뒤 그 PID만 종료)

| 실행 | exit | 결과 | 로그 |
|---|---:|---|---|
| mock `--interactionloop` | 0 | `INTERACTIONLOOP PASS` | `mock--interactionloop.log` |
| mock `--labloop` (기존) | 0 | `LABLOOP PASS` | `mock-lab--labloop.log` |
| FlyGym headless `--interactionloop` | 0 | `INTERACTIONLOOP PASS` | `headless--interactionloop.log` |
| `--bridgetest --labtest --v4test --v4timingtest --simtest --behaviortest --gpucheck` | 모두 0 | 전부 PASS, simtest 121 µs/step | `regress--*.log` |
| `git diff --check` | 0 | | |

headless 관측: 상자 11.1536 mm / 400 ms 운반, ≥100 ms 창 최대 32.69 mm/s ≤ backend 40.0 (+2), 놓은 뒤 0.000000 mm (tick 825..1425), 거절 `not_holding` / `ray_miss` / `out_of_reach: 25.500mm` 뒤 상태·위치 불변, `object_grabbed @225 ms` → `object_placed(place) @785 ms`.

종료 후 17841 리스너 없음, comm이 python/ThongpariFlyNeuronSim인 잔존 프로세스 0.

## 범위

TCP 경로에서 **파리 접촉**은 시험하지 않았다(접촉 물리는 `../python-fix/` real MuJoCo 시험 담당). GUI 게이트 보류.
