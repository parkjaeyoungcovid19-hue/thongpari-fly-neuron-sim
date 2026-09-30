# V5 마감 검증 — 2026-09-28

기준은 HEAD `58ce8cd`와 미커밋 V5.6.2/V5.7 worktree다. 오케스트레이터는 Opus 5.5이고, 서브에이전트는 GPT-6 Luna Max 4개를 썼다.
에이전트 보고는 1차 자료로만 쓰고, 판정에 쓴 수치는 오케스트레이터가 직접 다시 실행해 얻었다.

## 1. 1차 전체 회귀 (에이전트, 수정 전 트리)

로그: `regression-agent/`. 실행 스크립트 `run_tcp.py`는 백엔드 stdout을 파이프로 받고 읽지 않는 결함이 있다. 오케스트레이터 재측정은 파일 출력(`perf/hl.sh`)으로 했다.

| 명령 | exit |
|---|---|
| `./build.sh` | 0 |
| Swift `--bridgetest --labtest --v4test --v4sessiontest --v4timingtest --simtest --behaviortest --gpucheck` | 모두 0 |
| Python `test_*.py` 11종 | 모두 0 |
| mock `--bridgeloop --labloop --interactionloop` | 모두 0 |
| headless `--labloop --interactionloop` | 0 |
| headless `--bridgeloop` | **1** (body 14–19 Hz, 기준 ≥30 Hz) |
| `git diff --check` | 0 |

## 2. headless `--bridgeloop` 실패 판정 (오케스트레이터 직접)

- 기존 검증 기록(`refactor-2026-09-22`, `f02-fix-2026-09-26`, `v5-6-2-2026-09-27/tcp`)은 모두 **mock**으로 `--bridgeloop`을 돌렸다(body 60 Hz). 실제 물리 백엔드로 이 게이트를 돌린 기록은 없다.
- HEAD `58ce8cd`을 별도 worktree에 빌드해 같은 시험을 돌렸고, 이것도 FAIL이었다(body 22.4–23.5 Hz, 4회). 따라서 **30 Hz 미달은 V5.6.2 이전부터 있던 실제 물리 처리량 한계다.** 이번 릴리스의 결함은 아니다.
- 다만 같은 비교에서 현재 트리가 HEAD보다 낮았다(18.6–20.8 Hz). 이 차이는 **실제 성능 저하**였다 → 3절.

## 3. 성능 저하 원인과 수정

- in-process 물리 1 quantum(20 ms, 200 substep): HEAD 36.5–37.9 ms, 현재 44.9–45.1 ms(+20%). cProfile로 보면 증가분은 거의 모두 `mj_step` 안에 있다.
- MuJoCo 타이머로 보면 COL_BROAD와 POS_KINEMATICS가 늘었다. 모든 geom이 contype 0(명시 pair만 사용)인데도 geom 수(297→1068)에 비례해 늘었다. pair를 56개로 줄여도 COL_BROAD는 줄지 않았다(pair 가설 기각).
- 같은 프로세스에서 번갈아 잰 쌍 비교(`perf/paired.py`):
  - 슬롯 0: 22.5 ms
  - 기본: 43.8 ms
  - 자동차·함정 0: 41.3 ms
  - **음식 0: 37.2 ms**
- 결론: 음식 슬롯 32개가 각각 음식 6종 palette 전체(숨은 geom 약 17개)를 가져 544 geom을 만든다. 이 geom들은 매 substep 자세 계산을 거친다.
- 사용자 결정(2026-09-28): 음식 슬롯을 **8개**로 줄인다.
- 음식 8개 기준으로 자동차 8·함정 4 슬롯의 유휴 비용을 다시 재니 10%였다(기준 5%). 같은 방침에 따라 **자동차 4, 함정 2**로 줄였다(3.3%).
  - 참고: 음식 32개일 때 이 비용은 3.22%로 보고됐었다. 분모가 컸기 때문이다.
- 수정: `flygym_bridge/lab_world.py` `DEFAULT_SLOT_COUNTS`.
- 수정 후 headless `--bridgeloop`을 HEAD와 번갈아 3회씩 돌렸다: HEAD 20.4 / 21.9 / 23.1 Hz, 현재 23.4 / 21.3 / 23.2 Hz → **HEAD와 동등**. 30 Hz 게이트는 여전히 둘 다 미달이다(2절의 원래 한계).
- 수정 후 시험: `test_v5_6_2_tools`(TOY_PERF 비율 중앙값 0.993), `test_v5_6_2`, `test_lab`, `test_v5_6`, `test_bridge` 모두 exit 0.

## 4. 감사 결함 수정

- S-1(`../v5-7-swift-independent-2026-09-28/README.md`): 섭식 사건 `feeding_begin`/`feeding_end`/`food_eaten`의 한·영 문구를 `LabToy.eventLine`에 추가했다. `LabEventDetail`에 `food_variant`와 `contact_s`를 추가했다. `--labtest`에 검사를 추가해 통과했다. 수정 전에는 `eventLine`이 nil을 돌려주므로 이 검사가 실패한다.
- P-1(Python 감사, CONFIRMED): 음식이 다 먹혀 사라질 때 `food_eaten`만 나오고 `feeding_end`가 없어 `feeding_begin` 구간이 닫히지 않았다. `lab_world.feeding_update`의 소진 분기에서 `feeding_end {reason:"eaten", contact_s}`를 `food_eaten` 앞에 내도록 고쳤다. `test_v5_6_2.py`에 순서·짝 검사를 추가했다. 수정 후에는 PASS, 수정을 뺀 음성 대조에서는 FAIL이다(`fixes/`).
- P-2(CONFIRMED, 수정): world render snapshot을 strict parser(`protocol._strict_render_object`)로 다시 검증하는 과정에서 `food_variant`가 버려졌다(계약 §4 위반). 이제 짧은 문자열로 검증한 뒤 보존한다. `test_v5_6_2_tools.py`에 스냅샷 보존 검사를 추가했다.
- P-3(CONFIRMED, 수정): world reset이 물체 번호(`_counter`)와 음식 순환 번호는 0으로 돌리면서 비비탄 번호(`_bb_counter`)는 이어 갔다(reset 뒤 첫 발 `bb_10`). 이제 world reset에서 0으로 돌린다. 물체를 남기는 body reset(`reset_runtime_tools`)은 물체 번호도 유지하므로 비비탄 번호도 그대로 둔다. 검사를 추가했다.
- P-2와 P-3을 함께 빼고 음성 대조를 돌리면 2 FAIL, 수정 후에는 0 FAIL이다(`fixes/test_v5_6_2_tools-*.log`).
- 감사 주장 “파리가 함정 안에 있어도 함정이 닫힘”은 **기각**했다. 계약은 벽이 파리 *위로* 떨어지지 않는 것을 요구하고, 파리가 안쪽에 있을 때 닫혀 가두는 것은 의도된 포획 동작이다. 프로브(`fixes/trapfly2.py`)로 확인했다. 1000 substep 동안 함정 solid↔파리 접촉은 0건이었다. 파리 body는 모두 함정 중심에서 2.28 mm 안에 있고 벽 반폭은 10 mm다. 상태는 dropping → closed(z 6.02)였다.
- 테스트 공백(수용): 음식 순환 검사는 `FOOD_VARIANT_ORDER`를, 비비탄 풀 검사는 `BB_POOL_SIZE`를 구현 상수로 가져다 쓴다. 두 값은 계약에 적힌 설계값이고 동작(순환, 한도 초과 거절)은 실제로 실행해 검사하므로 이번에는 수용한다.
- 감사에서 OK로 본 항목: 자동차 주행 차단과 취소(이동, 크기 변경, 삭제, reset), 함정 상태 전이와 막힘, 비비탄 풀·간격·수명·gravcomp·궤적 그룹 3, reset 초기화, 새 명령 검증(NaN, 누락, 범위, 단위벡터), solid 부품에만 건 명시 pair(자동차 7, 함정 5), alpha-0 geom의 ray 배제.

## 5. 남은 게이트

- 수정 후 전체 회귀 재실행 (오케스트레이터)
- GUI 인수: V5.6.2 도구·섭식, V5.7 카드, V5-06 전체 동선
- `docs/reports/V5_COMPLETION_REPORT.md`
