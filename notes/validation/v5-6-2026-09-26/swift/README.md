# V5.6 Swift UI 검증 — 2026-09-26

실행 위치: 저장소 루트. GUI와 TCP listener를 실행하지 않았다. Python backend 통합은 이 기록의 범위 밖이다.

| 명령 | exit | 로그 | 핵심 결과 |
|---|---:|---|---|
| `./build.sh` | 0 | `build.log` | `Built ./ThongpariFlyNeuronSim` |
| `./ThongpariFlyNeuronSim --bridgetest` | 0 | `bridgetest.log` | 92 PASS, `ALL BRIDGE TESTS PASS` |
| `./ThongpariFlyNeuronSim --labtest` | 0 | `labtest.log` | 61 PASS, `ALL LAB TESTS PASS`; V5.6 flat wire, 실제 bridge lab 큐와 interactive V4 envelope, 기존 명령 필드 부재, interaction 엄격 decode/옛 backend, E repeat/focus/pending, ACK 10개 거절 코드, 이벤트 버퍼, 참여체 눈 ray |
| `./ThongpariFlyNeuronSim --v4test` | 0 | `v4test.log` | 18 PASS, `ALL V4 SESSION TESTS PASS` |
| `./ThongpariFlyNeuronSim --v4timingtest` | 0 | `v4timingtest.log` | 5 PASS, `ALL V4 TIMING TESTS PASS` |
| `./ThongpariFlyNeuronSim --simtest` | 0 | `simtest.log` | 시뮬레이션 불변식 PASS, 16-step 207 µs/step (1000 µs 예산) |
| `./ThongpariFlyNeuronSim --behaviortest` | 0 | `behaviortest.log` | 17 PASS, `ALL BEHAVIOR TESTS PASS`; 알려진 ledge flake는 이번에 발생하지 않음 |
| `./ThongpariFlyNeuronSim --gpucheck` | 0 | `gpucheck.log` | `GPUCHECK PASS`, 538 comparison points |

`git diff --check` exit 0. 빌드 중 파일 변경으로 실패한 두 초기 시도는 최종 소스의 빌드가 아니며, 위 `build.log`는 편집을 마친 뒤 성공한 최종 실행이다. 테스트 로그도 최종 빌드로 다시 실행한 결과다.

설계 메모: `coordinator.labCommandSchedule()`은 결정론 세션만 반환한다. 일반 참여 세션의 interaction 명령은 기존 `playerInputEnvelope()`가 검증한 session/epoch/렌더 snapshot tick을 동일한 V4 LabCommand 필드에 넣는다. `WorldViewer.participantAimRay(player:)`는 최신 backend pose의 중심에서 정면으로 반경의 0.6배 이동한 눈을 원점으로 한다. 표시 카메라를 3인칭으로 바꾸어도 이 ray는 변하지 않는다.

남은 게이트: 부모의 실제 backend TCP/GUI 집기→운반→놓기→접촉 사건 수동 인수. 이 headless 검사는 화면 중앙 조준점의 실제 시인성과 물체 접촉의 물리 정확성을 증명하지 않는다.

프로세스 확인: `pgrep -fl 'ThongpariFlyNeuronSim|bridge.py'`의 원문은 `process-check.log`에, 같은 PID의 실제 실행 파일(`ps -o comm`)은 `process-commands.log`에 저장했다. 검색어를 명령 인수에 포함한 다른 Codex 작업 프로세스 4개만 매칭되었고, `ThongpariFlyNeuronSim` 또는 `bridge.py` 실행 파일은 남지 않았다.
