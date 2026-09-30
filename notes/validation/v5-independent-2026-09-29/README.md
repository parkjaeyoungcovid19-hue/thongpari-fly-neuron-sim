# V5 마감 재점검 — 2026-09-29

## 판정

**V5 완료 승인 보류.** 수정 후 전체 회귀가 완료됐다는 증거는 없었으며, 재실행에서 테스트 실패와 섭식 사건 기록 결함을 확인했다. 제품·테스트 코드는 수정하지 않았다. 커밋/푸시 및 GUI 조작도 하지 않았다.

기준: `58ce8cd816ae84f1bb3d2ceb6ad1b2541873e35f` + 기존 미커밋 V5.6.2/V5.7. 이번 점검은 부모 에이전트가 직접 수행했다. 이전 기록의 모델명은 실행 증거가 아니므로 재인용하지 않는다.

## 이전 실행 상태 정정

- `../v5-close-2026-09-28/final/summary.txt`: build + Swift 7종(bridgetest, labtest, v4test, v4sessiontest, v4timingtest, simtest, behaviortest) exit 0.
- gpucheck는 Metal 초기화 한 줄만 있고 종료 상태가 없다. 이후 Python 11종/TCP 6종/diff-check/DONE 기록도 없다. **중단이지 PASS가 아니다.**
- 이번 시작 시 해당 검증 프로세스 및 17841/17842 listener는 없었다.
- HEAD도 실제 body 30 Hz에 미달했다는 기존 비교 결과는 원인 구분 자료다. 현재 실패 게이트를 통과 또는 면제 처리하는 근거는 아니다.
- 음식 8개 축소만 사용자 선택으로 확인된다. 자동차 4·함정 2는 이전 부모가 추가로 결정했으며 별도 사용자 승인을 받은 것으로 쓰면 안 된다.
- 중앙에 있는 파리를 함정이 가두는 특정 시나리오에서 접촉이 없었다는 프로브는 벽/지붕 가장자리의 모든 침투 가능성을 부정하지 않는다.

## 확인된 발견사항

### A-1 / P1 — 음식 슬롯 축소와 실제 회귀 기대값이 충돌

- 위치: `flygym_bridge/test_lab_real.py:61–65`, `flygym_bridge/lab_world.py:82`.
- 재현: venv Python으로 `flygym_bridge/test_lab_real.py` 실행.
- 실제 출력: `FAIL expanded runtime object capacity: {'box': 64, 'sphere': 64, 'wall': 64, 'food': 8, 'car': 4, 'trap': 2}`. exit 1.
- 원인: 구현은 승인된 음식 8개지만 검사는 여전히 `food >= 32`를 요구한다.
- 수정 방향: 승인된 용량 계약과 독립 기대값을 일치시키고 8개 성공/9번째 거절/삭제 후 재사용을 검사한다. 단순히 구현 상수를 가져와 비교하지 않는다.
- 완료 조건: 원래 실패를 보존한 뒤 수정 후 실제 MuJoCo 검사가 exit 0이고 한도 경계 검사가 통과할 것.
- 증거: `test_lab_real.log`, `results.json`.

### A-2 / P2 — 먹는 중 삭제한 음식의 누적 접촉 시간이 0으로 손실

- 위치: `flygym_bridge/lab_world.py:737` (`remove_object`의 `feeding.pop`), `:1784–1787` (다음 업데이트의 종료 사건).
- 재현: `LabWorld`에 지름 3 mm 음식 `snack`을 [0,0,1]에 생성 → 입 [1.5,0,1]로 `feeding_update(.1)` → 삭제 → 다음 `feeding_update(.02)`.
- 삭제 전 `feeding={'snack':0.1}`, 삭제 직후 사건 없음, 다음 종료 사건은 `contact_s:0.0`.
- 원인: 삭제가 누적 시간을 먼저 버린다. 소진 경로의 P-1 수정은 이 수동 삭제 경로를 덮지 않는다.
- 수정 방향: 삭제 경계에서 접촉 구간을 정확히 한 번 닫거나 누적 시간을 다음 종료까지 보존한다. 소진 분기와 중복 종료가 생기지 않도록 함께 검사한다.
- 완료 조건: 삭제 후 종료 사건이 한 번이고 누적 0.1초를 보존하며, 소진 경로는 `feeding_end` → `food_eaten` 순서를 유지할 것.
- 증거: `feeding-remove-probe.log`. mock 상태/사건 경로를 직접 실행한 증거이며 실제 GUI 삭제 실험은 아니다.

### A-3 / P3 — 일시정지 카드 도움말이 실제 동작과 불일치

- 위치: `ActivityCards.swift:79–80,287–288`, `main.swift:802–808`, `LabDiagnostics.swift:1006–1017`.
- 도움말은 일시정지를 값 부재(—)의 예로 안내하지만 발화율 카드는 brain sim만 있으면 마지막 값을 계속 표시한다.
- 기존 labtest도 `pausedRates=true`를 확인한다. 추측이 아니라 구현 및 검사 계약으로 확인한 문구 불일치다. GUI 화면 확인은 별도다.
- 수정 방향: 기존 의도대로 모델 지표/사건은 —, 발화율은 마지막 표본 유지임을 도움말에 구분하고 정지 표본임을 명시한다.
- 완료 조건: 한국어/영어 도움말과 실제 일시정지 화면을 일치시킬 것.

### A-4 / P2 — 검증 문서가 현재 완료 상태를 과장하거나 서로 충돌

- `docs/plans/VIRTUAL_FLY_LAB_V5_6_2_SANDBOX_SPEC.md:3`의 “자동 검증 완료”와 `:79`의 과거 3.22% 값은 현재 코드의 최종 마감 판정과 구분해야 한다.
- `docs/reports/V5_PROGRESS.md:6–8`은 다음 단계가 V5.7인 문장과 V5.6 착수라는 문장이 함께 남아 있다.
- 수정 방향: 날짜/코드 기준/과거 측정과 현재 실패·미검증 항목을 분리한다. 30 Hz 미달을 기존 문제라고만 적고 종료 처리하지 않는다.
- 완료 조건: 진행표·계약·최종 검증 기록이 같은 현재 상태를 가리키고, GUI 대기와 성능 실패가 명시될 것.

## 재검사 방법과 현재 기록

- 이전 완료 로그는 보존하고 중단 이후 검사를 이 폴더에 새로 실행한다.
- gpucheck → Python 11종 → fresh mock TCP 3종 → fresh headless TCP 3종 → diff-check 순서. 무거운 검사는 순차 실행.
- 각 TCP는 기존 포트 점유 여부를 먼저 확인하고 자체 생성 PID가 listener인지 확인한다. 자체 백엔드만 종료한다.
- 명령별 종료코드와 시간은 `results.json`, 최종 포트 상태는 `cleanup.json`에 기록한다.
- `gpucheck.log`의 산술 후보 탐색 중 FAIL 문자열은 최종 실패가 아니다. 선택된 기준으로 최종 `GPUCHECK PASS`, exit 0을 확인했다.
- 모든 재검사가 끝나기 전에는 전체 완료로 해석하지 않는다.

## 남은 게이트 및 순서

1. 재검사 결과를 모두 수집하고 실패를 개별 판정한다.
2. A-1/A-2 수정 및 독립 경계 회귀(별도 수정 작업).
3. A-3/A-4 문구·문서 정합성 정리.
4. 실제 30 Hz 성능 게이트 해결 또는 명시적 수용 결정. 기존 코드도 실패한다는 이유만으로 면제하지 않는다.
5. V5.6.2 도구/섭식, V5.7 카드, V5 통합 동선의 새 GUI 증거. 이번에는 수행하지 않았다.
6. 위 게이트 후 완료 보고서를 작성한다. 그 전 V6 구현 착수는 보류한다.

## 최종 자동 검사 결과 (2026-09-29)

재개 실행 종료: **19개 명령 중 17 PASS / 2 FAIL**, TIMEOUT·BLOCKED 없음. 실행기 자체 exit 0은 개별 검사 전체 통과를 뜻하지 않는다.

| 검사 | 결과 |
|---|---|
| GPU 독립 CPU 대조 | PASS, exit 0 |
| Python 11종 | 10 PASS / 1 FAIL (`test_lab_real`, A-1) |
| fresh mock TCP 3종 | 모두 PASS |
| fresh real-headless TCP `labloop`, `interactionloop` | 모두 PASS |
| fresh real-headless TCP `bridgeloop` | **FAIL, exit 1 — body 14.1 Hz < 30 Hz** |
| `git diff --check` | PASS |

실제 bridgeloop: brain 송신 200, body 수신 60, 4.2초, body 14.1 Hz, 최대 body 간격 82 ms, sim/wall 0.400. 기준 코드 `BridgeDiagnostics.swift:1109`는 sent ≥180, recv ≥50, Hz ≥30을 요구하므로 Hz 조건에서 실패한다. 이번에는 HEAD를 동시에 재측정하지 않아 이전 20–23 Hz 대비 하락의 원인을 새 회귀로 단정하지 않는다. 다만 **현재 성능 게이트 실패는 확정**이다.

추가 통과 증거: 도구 비용 paired ratio 0.9991 (기준 ≤1.05), 실제 물체 pair 성능 측정 slowdown 4.2%, 실제 눈 렌더 mean 6.0 ms/stereo-pair. 이 값들은 서로 다른 검사이며 전체 body 30 Hz 달성의 대체 증거가 아니다.

`cleanup.json` 및 종료 후 lsof 직접 확인: 17841/17842 listener 없음. 테스트 소유 백엔드는 종료했다. 제품·테스트 소스 무수정, GUI 미수행 상태를 유지한다.

최종 권고: **A-1/A-2 및 문구·기록 정합성 수정 → 실패 항목 재검증 → 실제 성능 게이트 처리 → GUI 인수**. 그 전 V5 완료 및 V6 착수로 판정하지 않는다.
