# V5.6 Python backend 검증 — 2026-09-26

범위: Python 집기·놓기 계약, mock, 설치된 FlyGym/MuJoCo real body, 기존 Python 회귀. TCP 리스너와 GUI를 띄우지 않았다. `environment.log`의 실행 환경은 Python 3.12 / FlyGym 2.1.0 / MuJoCo 3.9.0이다.

## 실행 명령과 결과

아래 경로는 저장소 루트 기준이며, 각 명령의 stdout/stderr는 같은 이름의 `.log`에 저장했다. 모든 종료 코드는 **0**이다.

| 명령 | PASS | FAIL | 로그 |
|---|---:|---:|---|
| `./flygym-venv/bin/python flygym_bridge/test_v5_6.py` | 42 | 0 | `test_v5_6.log` |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_interaction_real.py` | 18 | 0 | `test_interaction_real.log` |
| `./flygym-venv/bin/python flygym_bridge/test_v5.py` | 31 | 0 | `test_v5.log` |
| `./flygym-venv/bin/python flygym_bridge/test_v4.py` | 47 | 0 | `test_v4.log` |
| `./flygym-venv/bin/python flygym_bridge/test_lab.py` | 54 | 0 | `test_lab.log` |
| `./flygym-venv/bin/python flygym_bridge/test_bridge.py` | 44 | 0 | `test_bridge.log` |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_player_collision_real.py` | 18 | 0 | `test_player_collision_real.log` |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_lab_real.py` | 63 | 0 | `test_lab_real.log` |
| `NUMBA_DISABLE_JIT=1 ./flygym-venv/bin/python flygym_bridge/test_vision_real.py` | 13 | 0 | `test_vision_real.log` |

합계 **330 PASS / 0 FAIL**. 추가로 `./flygym-venv/bin/python -m py_compile`(변경 Python 파일 7개)과 `git diff --check -- flygym_bridge/bridge.py flygym_bridge/fly_body.py flygym_bridge/lab_world.py flygym_bridge/protocol.py`가 각각 exit 0이었다. 출력은 `py_compile.log`, `diff_check.log`에 있다.

## 핵심 측정과 판정

- 기존 명시 pair 56개에 물체 슬롯 192개 × 파리 geom 3개 = **576 pair**를 추가했다. 선택 geom: `fly/c_thorax`, `fly/c_head`, `fly/c_abdomen4`. food 슬롯은 충돌 pair에서 제외했다.
- 같은 idle 20 ms quantum에서 각 body 15회 예열 후, baseline/추가 pair 실행 순서를 교차하며 12회씩 측정했다. 중앙값 **62.158 ms → 62.720 ms**, **0.9% 느려짐**. 20% 축소 기준 아래라 3개 segment를 유지했다. 단일 실행값에 큰 이상치가 있어 중앙값을 사용했다(`test_interaction_real.log`의 전 샘플 기록). 이는 idle body 처리 시간 비교이며 전체 앱 FPS 주장은 아니다.
- `INTERACTION_REACH_MM`은 **12.0 mm 유지**. backend ray의 7.000 mm grab 성공과 17.000 mm hit 거절을 real geometry로 확인했다.
- 운반 최대 관측 이동은 **0.004000 mm/native substep**(40 mm/s × 0.1 ms), z는 고정. 벽 접촉 직전 후보의 최대 기하 관통은 **0.052000 mm**로 허용치 0.05 mm + 한 substep 이동 0.004 mm 이내였다. 되돌린 물체 중심 x는 23.048 mm였다.
- 파리 옆 y=2.8 mm 경로는 접촉 사건 0건. y=0 경로에서는 실제 MuJoCo contact에서 `abdomen`과 `thorax`의 `object_contact_begin` 및 양의 법선 힘을 관측했고, 물체를 옮긴 뒤 `object_contact_end`의 peak force와 duration을 확인했다. 놓은 물체를 다시 실제로 닿게 해 비운반 상태에서도 begin이 기록됨을 확인했다. 힘 단위는 `mujoco_model`로 표시한다.
- 같은 boundary의 참여체 활성화 직후 `xpos`가 이전 위치에 남은 상태에서도 grab은 현재 free-joint `qpos`를 사용해 성공했다.
- mock은 해석적 ray–경계구와 제한 속도 XY 운반만 사용했다. mock의 결과는 real 물리 증거로 세지 않았다.

## 계약 변경 제안과 남은 검증

**계약 변경 제안:** 계약 §1의 “`mj_step`이 만든 contact 중 운반 물체 ↔ 바닥·다른 LabObject·참여체”라는 관통 판정 설명은 mocap↔mocap 및 mocap↔fixed-plane에서 성립하지 않는다. MuJoCo가 이 고정 geom 쌍의 contact를 생성하지 않아 벽 통과가 재현됐다. 현재 코드는 **임시** 보완으로 `mj_step` 직후 설치된 geom의 `mj_geomDistance`를 조회해 관통 시 substep 이동을 되돌린다. 계약에는 이 기하 거리 fallback을 명시하는 편이 정확하다. 파리 접촉 사건은 계속 실제 `mj_contactForce`가 있는 contact에서만 발생한다.

Swift 명령 인코딩, TCP 통합, 실제 GUI 경로는 Python 담당 범위 밖이라 여기서 판정하지 않았다. `pgrep -fl 'bridge.py|test_.*real'`의 원문은 `pgrep.log`에 있다. 그 검색에 걸린 4개 PID는 다른 작업의 Codex CLI 인수에 들어 있는 문자열이다. `ps`의 실행 파일명이 Python이고 명령이 bridge/real-test인 프로세스만 다시 거른 `python_process_check.log`는 **0행**이므로, 이 작업이 띄운 backend/test 프로세스는 남지 않았다.
