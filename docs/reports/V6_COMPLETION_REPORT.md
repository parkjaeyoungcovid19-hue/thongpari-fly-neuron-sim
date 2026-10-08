# Virtual Fly Lab V6 완료 보고서

2026-10-08 · V6.1–V6.7 기능·자동 검사·real backend·실제 GUI 수용 완료. 전 버전의 보류된 독립 게이트까지 소급 통과했다는 뜻은 아니다.

Claude가 남긴 V6.6 변경과 V6.7 `scene_store.py` 초안을 인계받아 완성했다. 시작 HEAD는 `7cea100`; 인계 당시 dirty patch·status·신규 핵심 파일은 [backup](../../notes/validation/v7-1-2026-10-08/handoff-backup)에 보존했다. 이번 작업은 commit 없이 checkout에 남긴다.

## 결과

- V6.6 재빌드와 정지 중 edit/Undo/Redo 재확인: 온도 33→28→33→28, ACK와 body tick 3405 고정. 설정만 되돌리고 신경·몸 시간은 되돌리지 않는다.
- V6.7 `.flyworld` schema 1: 객체 7종·ID·position/size/yaw/pitch·variant·온도·지속 바람·눈·participant spawn 설정 저장. 뉴런이나 몸의 checkpoint 아님.
- 저장: backend export ACK의 text+canonical scene을 받음 → Swift SHA-256/내용 검증 → 임시 sibling 파일 재검사 → atomic rename. 잘못된 hash는 이전 파일을 보존.
- 불러오기: 크기·JSON·schema·단위·숫자·용량·ID·asset hash·fly/spawn overlap 검사 → unbound candidate 구성 → stamped paused owner boundary에서 swap. 실행 중·다른 session/epoch는 거부. runtime 예외를 강제한 real 시험에서도 기존 model/data/world를 복구.
- GUI에서 찾은 추가 결함 수정: interactive 장면 요청의 session/epoch/tick 누락 때문에 정지 중 요청이 재개까지 기다렸음. 실제 GUI 재검증에서 export/load가 모두 @t3405 처리됨. Scene capability를 public Swift decoder까지 전달하여 미연결/미지원 버튼을 비활성화.

## 검증 증거

모든 경로는 [이번 검증 폴더](../../notes/validation/v7-1-2026-10-08)에 있다. 자동 검사와 GUI·성능을 분리한다.

| 검사 | 결과 / 증거 |
|---|---|
| `./build.sh`, `./package_app.sh` | exit 0, `build-capability-final.log`, `package-capability.log`; 기존 Selector warning은 남음 |
| Swift `--worldeditortest --labtest --v4test --bridgetest` 각각 | exit 0, `checks.json` |
| Python scene | `test_scene_store.py` 31 tests exit 0, `test_scene_store_real.py` 2 tests exit 0. 새 프로세스 설정 보존·hash/schema/NaN/duplicate/overlap/capacity·session barrier·강제 부분 교체 실패 rollback |
| Python 기존 회귀 | `checks.json` 15종 모두 exit 0; 마지막 terrain/world editor mock/real 4종 `v6-final-checks.json` 모두 exit 0 |
| public Swift TCP | fresh own backend별 `--sceneloop` mock/real, `--v4loop` mock/real, `--labloop` real exit 0, `transport-results.json` |
| real MuJoCo 경사 | `test_v6_4_terrain_real.py.log` render/collision pose·walkable ramp·다리 접촉 없는 음성 대조 통과. 자동 물리 검사를 GUI 자연 보행 확인으로 부르지 않음 |
| 실제 GUI V6.3/4 | 수치 pitch 15→30, 실제 화면 inclined surface와 선택 윤곽 일치; pitch handle drag→45; 복제 후 undo. `gui-ramp30.png`, `gui-ramp-drag.ax.txt/png` |
| 실제 GUI V6.5 | 원점에서 떨어진 fly 앞에 food, nearest distance·ORN 변화; 50°C local 거부 안내가 이후 ACK에 덮이지 않음; English/Korean 편집기 재표시. `gui-food-error-fixed.ax.txt/png`, `gui-language.ax.txt` |
| 실제 GUI V6.6/7 | GUI 작성 wall/ramp/food/온도33/바람.2·90°/left mask.6 저장→앱 종료→새 프로세스 paused load→4 IDs·설정 복원. 다시 paused save한 scene/hash가 원본과 같음. `GUI-roundtrip.flyworld`, `GUI-paused-fixed.flyworld`, `gui-newprocess-load.ax.txt`, `gui-paused-save-fixed.ax.txt` |
| 실패 GUI | `GUI-corrupt.flyworld` content hash를 바꿔 load→rejected, 4 objects/rev6/tick3405 유지. `gui-corrupt-rejected.ax.txt/png` |
| AC real transport | `--bridgeloop`: body36.5Hz, max gap36ms, sim/wall.597, PASS. `performance-results.json`, `bridgeloop-real.log` |
| AC 실제 GUI | compiler/다른 테스트를 멈춘 새 프로세스, authored scene, resume 후 5초×6구간 body31.6–33.6Hz 평균32.93Hz. `gui-ac-steady-windows.log`, `gui-ac-summary.json`, `gui-ac-steady.ax.txt/png` |

## 한계와 복구

- AC 수치는 M2의 이 장면/조건에서 측정했다. 경사로에 다리가 많이 닿을 때 기존 GJK 비용 증가(~45%)까지 모든 장면에서 30Hz를 보장하지 않는다. pause 직후 집계 창과 compiler contention은 지속 성능 수치에서 분리했다. body 30Hz는 실시간 속도 1x와 다르며 GUI sim/wall 약 .67x.
- iCloud 관리 `dist/*.app`는 서명 검증은 통과하지만 이 환경에서 일부 실행이 dyld 시작점에 멈췄다. 같은 signed bundle을 비-iCloud 경로에서 checkout working directory의 실행파일 경로로 실행한 실제 GUI로 수용했다. Finder-style 새 실행은 별도의 runtime 파일 open 대기가 남았다(백엔드 Python getpath의 open에서 대기). UI의 synchronous cloud-runtime 검사도 directory open에서 막힘을 발견하여 background probe로 수정했으며, 의도적으로 막힌 probe에서도 UI reads가 즉시 돌아오는 회귀를 추가했다. Finder-style 창은 이제 반응하지만 real backend 연결은 이 경로에서 수용하지 못했다. 원인을 iCloud나 접근 권한 하나로 단정하지 않는다. 시스템 보안/권한 설정은 바꾸지 않았다. 검증된 실행 경로는 프로젝트의 `Virtual Fly Lab.command`/`run_flygym.sh`와 signed bundle executable launch이다.
- full checkpoint, mesh/heightfield, 공간 날씨, 삭제 undo는 V6 범위 밖. `.flyworld`는 환경 설정이며 trap/carry/projectile 런타임을 재현하는 파일이 아니다.
- 이전 실패 로그는 삭제하지 않았다. `build-scene-final.log`는 컴파일 중 소스 수정으로 실패한 중간 로그이며 이후 frozen-source `build-final.log`/후속 빌드 exit0으로 대체. 최초 GUI paused export 실패도 수정 전 증거로 남김.
- rollback은 이번 diff를 파일별 검토하여 되돌리는 방식. 인계 dirty 변경을 포함한 전체 `git restore`를 하지 않는다. 장면 파일 오류는 현재 세계와 이전 파일을 보존하며 오류를 수정해 다시 요청 가능.

## 다음 단계 인계

완료 ID: V6.1–V6.7. scene schema: 1, kind: scene_settings. [상태 inventory](V6_FUTURE_STATE_INVENTORY.md). fixture: `GUI-roundtrip.flyworld` 및 `test_scene_store.py::authored`. 편집/장면 사건에 command ID와 applied tick 존재. V7.1은 기존 관측 audit만 수행한다. V7.2+ 관측 API와 선택 변경은 미구현.
