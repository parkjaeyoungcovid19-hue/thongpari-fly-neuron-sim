# V5.6 Swift UI 후속 수정 검증 — 2026-09-26

저장소 루트에서 실행했다. 앱 GUI와 TCP listener는 실행하지 않았고 포트 17841 및 기존 프로세스를 건드리지 않았다. Python 파일은 다른 세션의 작업 범위이므로 수정하지 않았다.

## 수정

- `WorldViewer.swift`: 중앙 조준점은 1인칭 시점에서 참여 입력이 캡처된 동안에만 보인다. 카메라 전환과 캡처 변경 양쪽에서 표시를 갱신한다. 1인칭 카메라와 집기 ray가 공통 `participantAimRay` 계산을 사용하도록 묶었다.
- `LabWindow.swift`: 3인칭 참여 시 상호작용 상태 줄에 참여체 정면 기준 안내를 영어/한국어로 표시한다. 캡처 중 새 E 입력이 세션·상태·snapshot·조준·큐 준비 부족 또는 이전 응답 대기로 무시되면 이유를 즉시 표시하고 interaction 명령을 보내지 않는다. 비참여·미캡처·텍스트 포커스 입력은 기존처럼 조용히 무시한다.
- `LabViewState.swift`: 무시 이유 문구와 이전 interaction 응답을 기다리는 동안의 중복 명령 차단/상태 표시를 추가했다.
- `LabProtocol.swift`: `--labtest`에 조준점 3조건, 1인칭 카메라와 집기 ray 일치, 대기 중 두 번째 E의 명령 0개/이유 표시, 상태·세션 대기 이유 표시를 검사한다.

카메라/ray 근거: `WorldViewer.participantCameraPose()`의 1인칭 분기는 `participantAimRay(positionMM:quatXYZW:radiusMM:)`에서 원점과 방향을 받는다. 공통 함수는 quaternion `(x,y,z,w)`에서 `forward = [1−2(y²+z²), 2(xy+wz), 2(xz−wy)]`, `origin = participant_position + forward × radius × 0.6`을 계산한다. 1인칭 카메라는 이 원점을 눈으로 쓰고 `eye + forward × 10`을 본다. 집기 명령도 backend snapshot의 참여체 pose로 같은 함수를 호출한다. 검사 fixture에서 둘 다 원점 `[24, 1.5, 2.5]`, 방향 `[0, 1, 0]`이다. 3인칭 카메라 위치는 `[24, -12.5, 8]`로 ray 원점과 다르므로 조준점을 숨긴다.

## 명령과 결과

| 명령 | exit | 로그 | 결과 |
|---|---:|---|---|
| `./build.sh` | 0 | `build.log` | `Built ./ThongpariFlyNeuronSim` |
| `./ThongpariFlyNeuronSim --bridgetest` | 0 | `bridgetest.log` | 92 PASS, `ALL BRIDGE TESTS PASS` |
| `./ThongpariFlyNeuronSim --labtest` | 0 | `labtest.log` | 65 PASS, 새 조준점/무시 이유 검사 포함, `ALL LAB TESTS PASS` |
| `./ThongpariFlyNeuronSim --v4test` | 0 | `v4test.log` | 18 PASS, `ALL V4 SESSION TESTS PASS` |
| `./ThongpariFlyNeuronSim --v4timingtest` | 0 | `v4timingtest.log` | 5 PASS, `ALL V4 TIMING TESTS PASS` |
| `./ThongpariFlyNeuronSim --simtest` | 0 | `simtest.log` | 시뮬레이션 불변식 PASS, 16-step 113 µs/step (1000 µs 예산) |
| `./ThongpariFlyNeuronSim --behaviortest` | 0 | `behaviortest.log` | 17 PASS, `ALL BEHAVIOR TESTS PASS`; `ledge follow window edge` 통과, 재실행 불필요 |
| `./ThongpariFlyNeuronSim --gpucheck` | 0 | `gpucheck.log` | `GPUCHECK PASS`, 538 comparison points |
| `git diff --check` | 0 | 명령 출력 없음 | 공백 오류 없음 |

`gpucheck.log`의 산술 후보 탐색 중 두 후보에 `FAIL`이 표시되지만 선택된 기준 산술과 최종 전체 검사는 통과했다. 이는 최종 `GPUCHECK PASS`와 구분해 읽어야 한다.

## 남은 게이트와 위험

- **GUI 게이트 보류**: 부모가 사용자 확인 후 실제 화면에서 조준점 시인성, 3인칭 안내, 참여→집기→운반→놓기→접촉 사건을 확인해야 한다.
- 이 기록은 Swift 빌드·진입점 회귀 증거다. 동시 진행 중인 Python 변경과의 실제 TCP 통합 또는 MuJoCo 접촉 정확성을 검증한 결과는 아니다.
- 조준점은 UI의 캡처와 시점 조건을 반영한다. backend snapshot이 오래되어 실제 집기 명령이 준비되지 않았을 때는 E를 누르면 상태 줄에 무시 이유가 표시된다.
