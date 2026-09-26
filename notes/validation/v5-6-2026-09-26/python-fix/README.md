# SiliconFly V5.6 Python 집기·놓기 수정 검증 — 2026-09-26

범위: `interaction.py`, `lab_world.py`, `test_interaction_real.py`와 이 증거 폴더. 기존 Swift·프로토콜·브리지 코드는 수정하지 않았다. 포트 17841의 리스너를 띄우지 않았고 패키지를 설치하지 않았다.

## 수정 방식

- 계약 §1의 `mj_geomDistance`를 정식 관통 판정으로 사용한다. 현재 거리 < `-0.05 mm`이면서 직전 **확정된** substep 거리보다 `1e-9 mm` 이상 더 깊어질 때만 그 substep의 운반 위치를 되돌린다. 바닥에 이미 묻힌 물체의 수평 이동은 허용한다.
- 잡은 직후와 외부 move/resize/spawn/remove·참여체 pose 변경·다른 물체의 approach 이후에는 이동 전 거리 기준을 다시 측정한다. 거부한 이동은 `mj_forward` 뒤 **복원된 위치의 거리**로 캐시를 갱신한다. 파리 접촉 사건은 계속 실제 `mj_step` contact와 `mj_contactForce`로만 만든다.
- 거리 조회 한계는 한 substep 최대 이동(0.004 mm) + 허용 깊이(0.05 mm) + 여유(0.01 mm) = **0.064 mm**이다. 먼 LabObject는 실제 크기의 경계구와 운반 물체의 0.5 mm 이동 여유로 먼저 거른다. 중심이 0.5 mm 움직이거나 장면이 바뀌면 후보를 재구성한다.
- 설치된 MuJoCo **3.9.0**의 직접 실험(`geom_distance_distmax.log`, exit 0): 18 mm 떨어진 sphere 쌍은 `distmax=0.064`에서 **0.064**를 반환한다. 1 mm sphere 겹침은 **-1.0**, plane 겹침은 **-0.5**로 작은 `distmax`에서도 음의 실제 거리를 반환한다. 설치된 Python docstring은 “smallest signed distance”라고 설명한다.

## 회귀 실행

저장소 루트에서 실행했다. real 테스트는 `NUMBA_DISABLE_JIT=1`을 붙였다. 각 stdout/stderr는 이 폴더의 동명 `.log`에 있다.

| 명령 | 종료 코드 | PASS | FAIL |
|---|---:|---:|---:|
| `./flygym-venv/bin/python flygym_bridge/test_v5_6.py` | 0 | 42 | 0 |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_interaction_real.py` | 0 | 22 | 0 |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_player_collision_real.py` | 0 | 18 | 0 |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_lab_real.py` | 0 | 63 | 0 |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | 0 | 31 | 0 |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | 0 | 47 | 0 |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` | 0 | 54 | 0 |
| `./flygym-venv/bin/python flygym_bridge/test_bridge.py` | 0 | 44 | 0 |

합계 **321 PASS / 0 FAIL**. `git diff --check --`(수정 허용 Python 파일) exit 0, 5개 Python 파일 `ast.parse` exit 0: `static_checks.log`.

## 핵심 실측

- 바닥 깊이 **-0.500 mm**로 시작한 상자: 20 ms quantum 10회 뒤 x **16.000 → 12.000 mm**, `carry_blocked=False`.
- 같은 상자와 벽: x **11.952 mm**에서 `carry_blocked=True`, `blocking_geom_kind=lab_object`; 벽과 최종 기하 거리 **-0.0480 mm**.
- 다른 구와 겹친 채 잡은 구: 멀어지는 방향 x **20.000 → 19.200 mm** 허용, 반대 방향 이동은 x **19.200 mm**로 복원하고 차단.
- 기존 벽 관통 한도: 되돌림 직전 최악 **0.052000 mm**로 `0.05 mm + 한 substep 이동 0.004 mm + 수치 여유 0.005 mm` 이내.
- 먼 상자 20개와 운반 구 1개: 같은 **20 ms / 200 native substep** quantum을 잡기 전후 20회씩 순서를 교차하여 측정. 중앙값 **67.517 → 69.981 ms**, **+3.65%**로 요청한 **+5% 이하** 통과. 모든 개별 샘플은 `test_interaction_real.log`의 `CARRY_PERF`에 있다. 부모의 수정 전 재현값은 **67.70 → 74.34 ms, +9.8%**였다.
- 별도 기존 pair 비용 확인: **63.844 → 63.813 ms**, 추가 pair 576개, 중앙값 기준 **약 0.0%** (`PERF` 행).

## 범위·잔여 위험·계약

측정치는 이 Mac의 해당 실행에서 얻은 quantum 처리 시간이다. 다른 시스템 부하에서 +5% 경계는 다시 확인해야 한다. Python backend 범위의 real MuJoCo와 mock은 통과했으며 Swift/TCP/GUI 통합은 이 담당 범위에서 실행하지 않았다. **계약 변경 제안: 없음**. §1의 기하 거리와 “더 깊어질 때만” 규칙을 그대로 구현했다.

종료 후 `ps -axo pid=,comm=,args=`에서 **실행 파일명**이 Python인 행만 먼저 고른 뒤 bridge/real-test 인수를 확인했다. `process_check.log`: 남은 대상 프로세스 **0**. `pgrep -fl`의 다른 Codex 인수 문자열 매칭을 판정에 사용하지 않았다.
