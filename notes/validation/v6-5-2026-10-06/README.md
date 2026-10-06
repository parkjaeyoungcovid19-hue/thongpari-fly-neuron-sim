# V6.5 환경 패널 — 검증 기록 (2026-10-06)

상태: **자동·실물 TCP 통과 / GUI는 사용자가 확인 / AC 전원 성능 재측정 필요**. 바람 강화(D-1) 포함. 사용자 “다음단계 개시”로 V6.4 GUI 확인을 보류하고 진행했다([진행표](../../../docs/reports/V6_PROGRESS.md)). 설계 결정은 [V6 계획 6.5](../../../docs/plans/VIRTUAL_FLY_LAB_V6_PLAN.md)에 있다.

## 바뀐 것

| 영역 | 내용 |
|---|---|
| 백엔드 `lab_world.apply_edit` | `wind.strength/direction_deg/physical/sensory` edit 적용기. 계속 부는 바람만 설정한다(세기 > 0이면 켬, 0이면 끔, 나머지는 세기 유지). 시간 제한 바람이 부는 중이면 `rejected_busy`로 거절하고 덮어쓰지 않는다. `wind.continuous`는 `rejected_unsupported`, `wind.duration_ms`는 기존대로 transient 거절 |
| fixture | `valid-wind-validator-only.json` → `valid-wind-strength.json`(이제 백엔드가 실제 적용) |
| Swift `LabProtocol` | `state.wind/temperature/eyes` 적용값 디코딩(블록별 독립, 잘못된 블록만 버림). `LabCommand.variant`. 텔레메트리 `temperatureMode` |
| 새 `EnvironmentPanel.swift` | `EnvironmentSettingQueue`: 한 번에 하나만 보내고, 기다리는 동안 속성마다 최신값 1개만 유지하며, 다음 edit는 직전 ACK의 revision으로 만든다. stale·busy·응답 없음(8 s)·세션 변경은 오류로 표시하고 다시 보내지 않는다. 패널 컨트롤: 온도 슬라이더·칸·방식, 바람 세기·원형 방향 다이얼(위=+Y, 오른쪽=+X)·두 스위치, 눈별 가림 슬라이더(%), 먹이 개수, ‘지금 파리 위치의 값’ |
| `LabWindow` ‘감각’ 페이지 | 지금 파리 위치의 값 / 온도 / 바람(계속 불기·끄기·한 번 불기) / 빛(가림·번쩍임, 장면 조명은 편집 불가 명시) / 먹이(종류 골라 파리 앞 15 mm에 놓기) / 건드리기. 바람 도움말의 잘못된 ‘파리 기준’ 설명을 세계 좌표로 고침 |
| 온도 권한 | 물리 백엔드가 연결돼 있으면 뇌 쪽 온도는 backend lab_state의 적용값을 따른다(`adoptBackendTemperature`). ACK 전 로컬 적용을 없앴다. 백엔드가 없을 때만 로컬 |
| 진단 | `--worldeditortest`에 V6.5 검사 27개(`EnvironmentPanelDiagnostics.swift`). `--envpanelshot DIR`: 실제 `sensesPage()`를 화면 밖에서 PNG로 그림(배치 증거일 뿐 GUI 수용 아님) |

## 결과

| 검사 | 결과 |
|---|---|
| Python `test_environment_edits` | 13개 PASS(새 2개: 계속 부는 바람 의미, puff 보호) |
| [음성 대조](negative_control.py) ([log](negative-control.log)) | puff 보호 줄을 메모리에서 빼면 busy 테스트가 실패 4건 → 테스트가 결함을 잡는다 |
| Swift `--worldeditortest` ([log](swift--worldeditortest.log)) | 78 PASS, 0 failures. V6-03: 슬라이더 100단계 → edit 3개, 대기열 ≤ 1, 마지막 값으로 끝남, revision 5→6→7 연쇄. 엉뚱한 ACK 무시, 확인 못 하는 ACK 4종 오류, stale·busy·시간 초과·세션 변경, 범위 밖 미전송, 다이얼 각도, 파리 기준 방향, AppKit 패널(드래그 중 적용값 불변, ACK 후 최신값 전송, 적용값으로 복귀, 백엔드 변경 따라감, 백엔드 없을 때 온도만 로컬) |
| [TCP 탐침](tcp_environment_probe.py) mock ([log](tcp-probe-mock.log)) | 13/13 PASS |
| TCP 탐침 real FlyGym ([log](tcp-probe-real.log)) | 15/15 PASS: 실제 serve loop에서 온도·바람·눈 edit 적용(applied_tick 포함), stale 거절 시 불변, body packet에 적용된 바람, puff 중 `rejected_busy`, 왼쪽 눈 100% 가림 → 실제 렌더 밝기 0.276→0.000, 치즈 variant 유지·냄새 측정 |
| Python 회귀 20종 ([요약](python-regression.log)) | 19 PASS. `test_v5`의 재연결 소켓 검사 1건이 동시 빌드 중 첫 화면 미도착(`first=None`)으로 실패 → 부하 없이 2회 재실행 모두 PASS(타이밍 민감, 이번 변경과 무관한 serve loop 경로) |
| Swift `--labtest` / `--v4test` / `--bridgetest` | 모두 exit 0 |
| [TCP 루프](run_loops.py) ([log](loops.log)) | labloop/interactionloop/v4loop mock, labloop real exit 0. **bridgeloop real FAIL**(body 21.7 Hz, sim/wall 0.40) |
| [배터리 A/B](ab_bridgeloop.py) ([log](ab-bridgeloop.log)) | 현재 22.2–22.3 Hz vs V6.5 백엔드 변경 제거본 22.2 Hz(번갈아 2회씩) — 차이 없음. V6.1과 같은 배터리 원인. **AC 전원에서 재측정해야 PASS 판정 가능** |
| `git diff --check` | 통과 |
| 화면 밖 렌더 | [ko 밝게](environment-ko-light.png) · [ko 어둡게](environment-ko-dark.png) · [en 밝게](environment-en-light.png) · [en 어둡게](environment-en-dark.png). 문구 줄바꿈·배치 정상. 렌더에서 슬라이더 손잡이 위치가 틀리게 그려지지만 값은 맞다(`slider values: … left-mask 1.00`) — 실제 창은 GUI 목록에서 확인 |

미실행: `--simtest`/`--behaviortest`/`--gpucheck` — 뇌 시뮬레이션·셰이더는 바꾸지 않았다.

## 결함·한계

- **D-1 바람 힘이 매우 약했다 → 사용자 승인(“바람은 강화해”, “뒤집혀도 됨”)으로 수정.** 원래 세기 1에서 서 있는 파리가 1초에 0.08 mm만 밀렸다(가슴 질량 × 10 m/s², 다리 접착이 버팀). 상수만 키우면 접착이 풀리는 순간 일정한 힘에 계속 가속돼 1 m 넘게 굴러갔다. 수정: 가슴 힘 60,000 mm/s² × 세기, 가슴이 바람 방향으로 30 mm/s × 세기에 가까워질수록 0으로 줄어든다(`WIND_SPEED_MAX_MM_S`). 측정([스크립트·로그](wind/)):

  | 조건(서 있는 파리, 2 s) | 세기 .25 | .5 | 1 |
  |---|---|---|---|
  | 옆바람 밀린 거리 | 0.8 mm | 5.0 mm | 18 mm |

  5 s 견고성 시험(세기 1): 뒤·옆바람은 기울기 ≤ 29°로 서 있음. 정면 바람은 서 있는 파리가 세기 0.6까지 버티고 0.7에서 뒤로 넘어간다(걷는 파리는 0.7에서도 서 있음). 사용자가 허용했다. 모든 실행에서 MuJoCo `BADQACC` 경고 0건. real TCP 탐침: 1초 8.85 mm(대조군 0.00 mm), 기준을 0.02에서 2 mm로 올림. 바꾼 뒤 Python 18종(`--mock-only` 2종은 재실행 안 함, [요약](python-regression-wind.log)), Swift `--worldeditortest`/`--bridgetest`/`--labtest`/`--v4test`, TCP 탐침 real 15/15 모두 통과. descriptor notes 문구가 공유 fixture 15개에 복사돼 있어 같이 고쳤다.
- **D-2 bridgeloop real 성능 게이트**: 배터리에서 FAIL, A/B로 이번 변경과 무관함을 보였지만 AC 재측정 전까지 미통과다.
- 온도 패널 범위는 10–40 °C이다. backend는 0–50 °C를 받는다. 신경 전류는 15–35 °C 밖에서 포화한다.
- 바람 세기 슬라이더를 끄는 것만으로도 바람이 켜진다(설계상 즉시 적용). 도움말에 적었다.
- `--envpanelshot`은 배치만 확인할 수 있다. 조작감·실제 손잡이 위치·온도 채택의 실시간 동작은 [GUI 목록](GUI_CHECKLIST.md)으로 사용자가 확인해야 한다.
- 앱 번들은 `./package_app.sh`로 다시 만들었다(`dist/Thongpari Virtual Fly Lab.app`). 런처 배너는 V6.5로 바꿨다.

## 재실행

```sh
flygym-venv/bin/python flygym_bridge/test_environment_edits.py
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/negative_control.py
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/tcp_environment_probe.py real
flygym-venv/bin/python notes/validation/v6-5-2026-10-06/run_loops.py        # AC 전원에서
./ThongpariFlyNeuronSim --worldeditortest
./ThongpariFlyNeuronSim --envpanelshot "$PWD/notes/validation/v6-5-2026-10-06"
```
