# V5.5.1 독립 점검 — 2026-09-26

기준 commit: `ce1105c` (`Refactor bridge, add V5.5.1 unified app work in progress`). 점검 시작 시 미추적 파일은 `notes/validation/refactor-2026-09-22/decode-benchmark/benchmark`(빌드 산출물) 하나뿐이었다. 기준은 [V5.5.1 계획](../../../docs/plans/VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md) §7과 [2026-09-22 전체 감사](../../../docs/reports/OVERALL_AUDIT_AND_FIX_PLAN_2026-09-22.md)의 F-01~F-06/G-01이다. 이 점검은 제품 코드를 수정하지 않았다.

## 판정

**V5.5.1은 구현되어 있고 자동·실제 backend 검사는 모두 통과한다. 그러나 계획의 완료 기준은 충족하지 못한다.**

- **출시 차단:** F-02(참여체 벽 침투·해제 후 튕김)가 09-22와 같은 수치로 재현된다. UI에서 참여 모드 안전 제한도 없다. 계획은 "F-02를 남긴 채 참여 이동을 정상 제품 경험이라고 표시하지 않는다"고 정한다.
- **보류:** GUI 인수 동선 2~7번과 통합 GUI 성능 측정. 사용자가 이번 세션의 화면 조작 권한을 거절했으므로 창 개수·프로세스 수명만 비조작 방식으로 확인했다.
- **없음:** `docs/reports/V5_5_1_COMPLETION_REPORT.md`.

## 자동 검사

| 검사 | 결과 |
|---|---|
| `./build.sh` | exit 0 (45 s) |
| Swift `--bridgetest` `--labtest` `--v4test` `--v4timingtest` `--simtest` `--behaviortest` `--gpucheck` | 모두 exit 0, 각 `ALL … PASS` / `GPUCHECK PASS`. gpucheck의 `FAIL` 두 줄은 비-FMA 대조 변형이며 최종 판정은 PASS |
| `--simtest` realtime | 16-step batch 100 µs/step (예산 1,000) |
| Python `test_bridge` / `test_lab` / `test_v4` / `test_v5` (mock) | 모두 `ALL … PASS` |
| Python `test_lab_real` / `test_vision_real` (실제 MuJoCo, `NUMBA_DISABLE_JIT=1`) | `ALL REAL LAB TESTS PASS` / `ALL REAL VISION TESTS PASS` |
| 새 backend별 TCP loop (`fresh_transport_probe.py` 복사본) | mock bridgeloop/labloop/v4loop, real-headless labloop/v4loop 5개 모두 exit 0. 17841 기존 listener 없음을 확인 후 실행, 종료 후 잔존 listener/프로세스 없음 |
| `git diff --check HEAD~1 HEAD` | `FlyGymPackets.swift:587` EOF 빈 줄 1건(무해) |

## 감사 항목 재판정

| 항목 | 판정 | 근거 |
|---|---|---|
| F-01 key-up 유실 | **수정됨(코드)**, 일부 잔여 | `LabWindow.swift:441` key-up이 `allowStaleSnapshotForRelease: true` 경로 사용, stale 시 tick 0 provenance로 중립 전송. 잔여: 큐 거절 시 로컬 상태만 소비되고 재전송 없음. snapshot 지연 fault fixture는 이번에 새로 만들지 않음 |
| F-02 벽 침투·튕김 | **미해결 — 재현** | `f02-collision-probe.txt`: max_x **28.1575 mm**(한계 26.5), contact distance **-1.6575 mm**, 해제 후 x=**-54.96 mm**. 09-22 값과 동일. `player_body.py`/`fly_body.py`는 V5.5 commit `f6c4c92` 이후 변경 없음 |
| F-03 look delta 잘림 | **수정됨** | `f03-input-probe.txt`: 100 pt 한 번 = -0.4, 10 pt×10 = -0.4, partition invariant true (09-22: -0.35 vs -0.40) |
| F-04 런처 부재 | **런처 추가됨, 안내 문서 불일치** | `Virtual Fly Lab.command`가 추적됨. 그러나 `docs/guides/LAUNCHERS.md`는 여전히 없는 `Thongpari Fly Neuron Sim 실험실.command`와 `--flygym`(현재는 외부 17841 bridge 모드)을 안내 |
| F-05 파리 geometry | **표현 경로 구현, 시각 검증 보류** | `view_stream.py` → `MuJoCoCanvas.swift`로 MuJoCo offscreen 렌더를 캔버스에 표시. 화면-pick 일치 대조는 GUI 보류 |
| F-06 진행 문서 모순 | **미해결** | `V5_PROGRESS.md:7`은 "V5.6 next", `:293`은 "finish V5.1". `CLAUDE.md` 비보호 구역에 `./SiliconFly` 8회 |
| G-01 통합 GUI 인수 | **부분** | 아래 참조 |

## 실행·창 수명 (계획 §5, GUI 동선 1)

- `./ThongpariFlyNeuronSim --lab`: 앱 소유 headless bridge가 private port(55786)와 render port(55787)에서 시작, 17841 미사용. 앱에 SIGTERM → bridge 자식이 약 1 s 안에 자체 종료, 두 포트 해제(`THONGPARI_PARENT_PID` 감시).
- `package_app.sh` → `dist/Thongpari Virtual Fly Lab.app`, `codesign --verify --deep --strict` 통과. `open`으로 실행 후 CGWindowList(`gui-window-list.txt`): **화면에 보이는 창은 `Virtual Fly Lab` 1320×820 하나**. bridge 프로세스 창 없음(MuJoCo viewer 없음). 숨김 상태의 `Fly Brain` NSPanel 객체가 하나 존재하나 `onscreen=false` — 3D 뇌 view를 Brain 페이지에 임베드하기 위한 보관 객체(`LabWindow.swift:375`, `:1285`).
- 일반 Quit(Apple Event quit) → 앱과 bridge 모두 약 1 s 안에 종료, 포트 해제.
- 코드 확인: `NSSplitViewController`(source-list 사이드바 / 영구 캔버스 / inspector) + `NSToolbar`. 사이드바 선택은 inspector 탭만 바꾸고 캔버스 인스턴스를 재생성하지 않음. 통합 모드에서 오버레이·전역 클릭 monitor·창 감지 타이머를 만들지 않음.

## 보류된 게이트

화면 조작 권한 없이 확인할 수 없어 **통과로 세지 않는다**:

1. 동선 2 — 자극 적용 중 세계 유지, pending→ACK→반응
2. 동선 3 — 뇌/데이터/실험 전환 중 캔버스·세션·tick 유지, 3D 뉴런 점군/2D 좌표 도구 사용
3. 동선 4 — 참여 capture → W/E/look → 텍스트 입력/사이드바/Esc/창 비활성화 해제 (backend 기준)
4. 동선 5 — pause 중 카메라만 이동, tick 정지, resume
5. 동선 6 — backend 종료·재연결, 명령 거절, 기록 저장 실패 sheet
6. 동선 7 — 창 크기/전체 화면/다크 모드/키보드/VoiceOver/Reduce Motion
7. 성능 — viewport FPS, snapshot Hz, body Hz, sim/wall, 클릭→ACK p50/p95, V5.5 기준선 대비

## 재검증 권고

1. F-02를 `player_body.py`에서 native substep·contact-aware 이동으로 고치고 `collision_probe.py`(정면/비스듬/모서리/파리 접촉/해제 후)를 회귀에 편입. 또는 명시적 안전 제한(참여 이동 비활성화 + 이유 표시)을 먼저 적용.
2. `docs/guides/LAUNCHERS.md`와 `V5_PROGRESS.md`의 현재 상태/다음 작업 정리.
3. 위 GUI 동선 2~7과 성능을 실제 화면으로 수행한 뒤 `docs/reports/V5_5_1_COMPLETION_REPORT.md` 작성. 그 전까지 V5.6 시작 금지.
