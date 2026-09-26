# Virtual Fly Lab V5.5.1 — 완료 보고서

작성: 2026-09-26 · 기준 commit: `1712eda` (`v5.5.1-f02-gui-fixes` 브랜치) · 계획: [V5.5.1 한 창 사용 경험](../plans/VIRTUAL_FLY_LAB_V5_5_1_UNIFIED_APP_PLAN.md)

## 판정

**V5.5.1 완료.** 한 창 Lab과 앱 소유 headless backend가 동작한다. 선행 결함 F-01~F-06/G-01을 처리했다. 자동 검사, 실제 backend 검사, 새 backend TCP 검사가 통과했다. GUI 동선 1~3은 Claude가 실제 화면과 증거 파일로 확인했다. 동선 4~7과 통합 성능은 **사용자가 2026-09-26 수정 빌드에서 직접 확인했다고 보고했다.** 이 부분은 화면 캡처나 수치 로그로 남기지 않았다. 아래 “검증 근거 수준”에서 구분한다.

다음 단계는 [V5.6 집기·놓기](../plans/VIRTUAL_FLY_LAB_V5_PLAN.md#56-집기놓기-구현)다.

## 선행 결함 처리

| 항목 | 결과 | 근거 |
|---|---|---|
| F-01 key-up 유실 | 수정 | key-up은 stale-snapshot release 경로를 쓴다(`dc768e4` 이전). 큐에 넣지 못한 전송은 Participate이고 세션이 running일 때만 10 Hz로 재전송한다(`LabWindow.reconcilePlayerHeldInputIfNeeded`) |
| F-02 벽 침투·튕김 | 수정 | 매 native substep마다 bounded force servo로 움직인다. 최대 침투는 0.025 mm(수정 전 4.5 mm)이고 해제 뒤 표면에서 멈춘다. `flygym_bridge/test_player_collision_real.py` 18/18이고, HEAD `dc768e4`에서는 8건 실패한다. [f02 검증](../../notes/validation/f02-fix-2026-09-26/README.md) |
| F-03 look delta 잘림 | 수정(이전 작업) | [2026-09-26 독립 점검](../../notes/validation/v5-5-1-independent-2026-09-26/README.md) |
| F-04 런처 안내 | 수정 | `docs/guides/LAUNCHERS.md`를 실제 모드(`run_flygym.sh` 기본/--mock/--viewer/--bridge-only, `--flygym` 외부 17841 연결)에 맞췄다 |
| F-05 파리 geometry | 수정 | MuJoCo offscreen 렌더(`view_stream.py` → `MuJoCoCanvas.swift`). 1인칭 눈 위치 결함(C)도 같이 고쳤다 |
| F-06 진행 문서 모순 | 수정 | `V5_PROGRESS.md` 현재 상태와 과거 기록을 분리했다. `CLAUDE.md` 실행 예시를 `ThongpariFlyNeuronSim`으로 바꿨다(보호 구역 제외) |
| G-01 통합 GUI 인수 | 완료 | 아래 표 |

## GUI 인수 (계획 §7)

| 동선 | 결과 | 근거 수준 |
|---|---|---|
| 1 첫 실행·종료 | PASS | Claude 실제 화면 확인. 창은 1개이고 bridge는 비공개 포트다. 종료 시 자식 bridge가 정리된다. [GUI 기록](../../notes/validation/v5-5-1-gui-2026-09-26/README.md) |
| 2 자극 | PASS | Claude 실제 화면 확인(결함 A 수정 후) |
| 3 뇌·데이터·실험 | PASS | Claude 실제 화면 확인(결함 B 수정 후) |
| 4 참여·충돌·Esc | PASS | 사용자 수동 확인(결함 C·D·E 수정 빌드). 백엔드 동작은 헤드리스 재현으로 별도 확인했다(상자 앞 x = 52.507 정지) |
| 5 pause | PASS | 사용자 수동 확인 |
| 6 장애·복구 | PASS | 사용자 수동 확인. 정상 종료 정리는 Claude도 3회 확인했다 |
| 7 창·접근성 | PASS | 사용자 수동 확인 |
| 성능 | PASS | 사용자 수동 확인. Claude 관측: 몸 데이터 초당 21–26회, 실시간 대비 0.40–0.53배. servo 추가 비용은 헤드리스에서 quantum당 최대 +1.9 ms였다. V5.5 기준선 대비 p50/p95 수치 표는 **없다** |

### GUI 인수에서 고친 결함

- **A.** interactive 세션 시각이 시작 tick에 멈춤 → 세계 시계(몸 시각)를 보고한다. 세션 시작 직후에는 마지막으로 본 값을 유지한다(E).
- **B.** 뇌 점군 클릭 직접 자극이 기록되지 않음 → 타임라인과 recorder에 `direct_neural`로 남긴다.
- **C.** 1인칭 눈이 충돌 구 밖에 있어 벽에 막히면 벽이 사라짐 → 눈을 `r×0.6`에 두고 1인칭 프레임에서 자기 구를 숨긴다. 렌더 probe 결과 상자 픽셀이 0% → 100%가 됐다.
- **D.** `참여` 클릭만으로 capture가 켜져 마우스 이동이 시선을 돌림 → 3D 화면을 클릭해야 capture가 켜진다.

## 자동·실제 backend 검사 (`1712eda` 작업 트리)

| 검사 | 결과 |
|---|---|
| `./build.sh` | exit 0 |
| Swift `--bridgetest` `--labtest` `--v4test` `--v4timingtest` | 모두 `ALL … PASS` (마지막 수정 뒤 재실행) |
| Swift `--simtest` `--behaviortest` `--gpucheck` | PASS (F-01/F-02 수정 뒤, 16-step 101 µs/step) |
| Python `test_bridge` `test_lab` `test_v4` `test_v5` | `ALL … PASS` |
| `NUMBA_DISABLE_JIT=1` `test_lab_real` `test_vision_real` `test_player_collision_real` | PASS / PASS / 18/18 |
| 새 backend TCP (`notes/validation/f02-fix-2026-09-26/fresh_transport_probe.py`) | mock 3 + real-headless 2, 모두 exit 0 |

## 남은 한계 (V5.5.1 완료를 막지 않음)

- 통합 GUI 성능의 V5.5 기준선 대비 수치(클릭→ACK p50/p95, viewport FPS)를 기록하지 않았다. V13 성능 단계나 V5 완료 보고서 전에 측정한다.
- 이 기계의 real body는 실시간보다 느리다(20 ms sim당 약 37 ms wall).
- capture 중에는 창 안의 모든 마우스 이동이 시선으로 들어간다. `경기장 둘러보기` 시점은 바닥이 위쪽으로 보이는 방향이다. inspector의 “참여자 없음”은 선택 요약이라 헷갈린다. 사용성 관찰로만 기록했다.
- 원격 푸시는 하지 않았다.

## 다음 버전 인계 (V5.6)

- 계약: `PlayerPose`, `PlayerInput`(held `interact`는 현재 효과 없음 — `protocol.py`가 E를 부수효과로 합성하지 않음), `WorldRenderSnapshot`, backend `ray_pick`(`fly_body.py`).
- 물체는 kinematic mocap 슬롯(`lab_world.py`)이라 “집기”는 free body 구속이 아니라 kinematic 운반이 된다. 이 선택과 이유를 V5.6 첫 단계에서 명시해야 한다.
- 참여체는 bounded servo로 움직이고 접촉은 solver가 해결한다(F-02). 운반 중인 물체의 관통 방지도 같은 원칙(순간이동 금지)을 따라야 한다.
- 재실행 명령은 위 표와 [공통 playbook](../plans/IMPLEMENTATION_PLAYBOOK.md)을 따른다.
