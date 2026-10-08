# Claude 인계 → V6.7 / V7.1 최종 검증 (2026-10-08)

**요청된 V7.1까지 구현·검증 완료.** V6.1–V6.7은 닫고 V7.1 기존 관측 audit만 완료했다. V7.2 이후는 미착수. 기존 V5의 사용자 보류 게이트를 소급 PASS로 바꾸지 않는다.

- [V6 완료 보고서](../../../docs/reports/V6_COMPLETION_REPORT.md)
- [V7.1 완료 보고서](../../../docs/reports/V7_1_COMPLETION_REPORT.md)
- [관측 단위·EMA·분모·출처 audit](../../../docs/reports/V7_OBSERVATION_AUDIT.md)
- [인계 당시 backup](handoff-backup) — 기존 dirty 변경을 보존. commit/일괄 restore 없음.

## 재현 명령과 최종 결과

| 묶음 | 실제 명령 / 결과 |
|---|---|
| build | `./build.sh` exit0, `build-release-final.log` (기존 Selector warning만) |
| package | `THONGPARI_APP_OUTPUT=/absolute/local/path/App.app ./package_app.sh` exit0, `package-local-release-final.log`; 최종 `codesign --verify --deep --strict` exit0 `final-codesign.log` |
| Swift 회귀 | `--worldeditortest --labtest --v4test --bridgetest` 각각 exit0; `checks.json`, `v7-final-checks.json`. 마지막 service/legend 수정 후 `--labtest` exit0 `labtest-release-final.log` |
| 신경 | `--observationaudittest --simtest --behaviortest --gpucheck` 각각 exit0, `v7-final-checks.json`. 최종 service/label 수정은 neural equations/kernel에 추가 변화 없음 |
| 데이터 | `./flygym-venv/bin/python tools/verify_data.py --no-parquet` exit0 `verify-data.log` (binary hashes/CSR 검증, parquet 비교 제외) |
| Python | `checks.json` 11종 + `v6-final-checks.json` terrain/editor mock/real4종 exit0. `test_scene_store-final.log` 31 tests, scene real2 tests |
| TCP | `python3 notes/validation/v7-1-2026-10-08/run_transport.py` exit0, `transport-results.json`: fresh own backend의 sceneloop mock/real, v4loop mock/real, labloop real 모두0 |
| real 성능 | `run_performance.py` → bridgeloop real exit0 body36.5Hz maxgap36ms sim/wall.597, `performance-results.json` |
| GUI 성능 | AC, 새 프로세스 authored scene, resume 후 연속 5초×6 body31.6–33.6Hz 평균32.93Hz. `gui-ac-summary.json`, `gui-ac-steady-windows.log`, `gui-ac-steady.ax.txt/png`. 전체 backend log는 이전 launch가 append되어 있으므로 모든 행을 이 런으로 해석하지 않음 |

## 실제 GUI 증거

- `gui-ramp30.png`, `gui-ramp-drag.ax.txt/png`: 수치30° → handle45°, inclined surface와 선택 윤곽; 복제 후 Undo.
- `gui-food-error-fixed.ax.txt/png`: 원점 밖 실제 fly 위치의 food/ORN/거리; 50°C 거부 안내가 후속 ACK에 유지.
- `GUI-roundtrip.flyworld` → 새 프로세스 `gui-newprocess-load.ax.txt` → `GUI-paused-fixed.flyworld`: objects·환경·hash 동일. load/export 모두 paused @t3405.
- `GUI-corrupt.flyworld`, `gui-corrupt-rejected.ax.txt/png`: hash 오류로 거부, 4 objects/rev6/tick3405 불변.
- `gui-paused-undo-redo.ax.txt`: 온도33→28→33→28, 같은tick3405. `gui-scene-status-korean.ax.txt`: 현재 장면 오류 상태도 언어 전환.
- `gui-scene-cap-disabled.ax.txt` / `gui-scene-cap-enabled.ax.txt`: 미연결 비활성 / 호환 연결 활성.
- `gui-v7-1-final-brain-ko.ax.txt/png`, `gui-v7-1-final-brain-en.ax.txt`: permanent sampled 안내·범례, 클릭=직접 자극.
- `gui-v7-1-final-data-ko.ax.txt`, `gui-v7-1-final-data-en.ax.txt`, `gui-v7-1-final-card-source.ax.txt`: Hz/뉴런·EMA·미각 coverage, source card selection은 명령 없음.
- `gui-final-release-world.ax.txt/png` / `gui-final-release.log`: 최종 signed bundle 실제 real 연결 :61757, scene buttons 활성; 정상 Cmd-Q 종료와 child 정리.

## 수정 전 실패와 전달 환경 제약

중간 실패 로그를 지우지 않았다. `build-scene-final.log`는 컴파일 중 source 수정 실패이며 후속 frozen build exit0으로 대체했다. 최초 paused scene GUI 요청은 stamp 누락 때문에 timeout; session/epoch/tick 추가 후 actual GUI @t3405 성공했다. capability 테스트의 초기 즉시 조회 race는 실제 manifest 도착을 기다리는 test로 수정하여 TCP 최종0.

iCloud `dist`의 metadata 재부착으로 마지막 `package-release-final.log`는 exit1 (`resource fork/FinderInfo`)이었다. 새 출력 override로 비-iCloud 디렉터리에 직접 stage/sign/package한 `package-local-release-final.log`와 최종 signature 검증은0. 임의 기존 bundle을 덮어쓰지 않고 generated marker를 확인한다. 최종 executable hashes는 `final-binary-sha256.txt`; bare와 bundle executable은 codesign 때문에 digest가 다를 수 있다.

Finder-style launch의 UI가 runtime directory open에 막힌 증거 `final-native-startup-sample.txt`; file probe를 background로 수정했다. semaphore로 의도적으로 probe를 막아도 UI getter는 즉시 반환하고 나중에 결과를 읽는 test 2개 PASS. 이후 native 창은 반응하나 Python startup getpath file open에 대기하는 환경 제약이 남았다(`final-native-backend-sample.txt`). 원인을 권한이나 File Provider 하나로 단정하지 않고 보안 설정을 바꾸지 않았다.

**검증된 실행:** [Run Verified App.command](Run%20Verified%20App.command)는 비-iCloud signed bundle executable을 checkout working directory에서 실행한다. project `Virtual Fly Lab.command`도 기존 `run_flygym.sh --lab` 경로다. Finder에서 `.app`만 직접 여는 경로의 backend startup은 PASS로 주장하지 않는다. 로컬 bundle은 이 checkout의 `flygym-venv`에 의존하는 artifact이며 standalone installer가 아니다.

## 정리

시험 backend마다 port17841 preflight·실제 listener PID 확인·finally 종료·bind 가능을 검사했다. GUI는 앱 소유 private port와 child만 사용했다. `cleanup.json`에 최종 실제 실행파일/프로세스와 포트 정리 확인을 기록한다. 기존 무관 listener/사용자 변경/옛 pid 파일을 삭제하지 않는다. `sandbox_models.py` diff 없음. `handoff-backup`은 rollback 검토용이며 전체 checkout restore를 권하지 않는다.
