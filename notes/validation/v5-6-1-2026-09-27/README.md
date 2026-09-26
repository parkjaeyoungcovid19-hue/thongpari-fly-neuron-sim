# V5.6.1 조작감·운반 수정 및 리팩토링 검증 — 2026-09-27

범위: V5.6.1 조작감 수정(최신 프레임만 표시, 시점 감도, 커서 잠금), 코드베이스 리팩토링, Codex(`gpt-6-astra` medium, read-only) 리뷰 2회에서 나온 지적 수정.

## 리팩토링 (동작 보존)
- `runLabTest` → `LabDiagnostics.swift`, `runSimtest`/`runBehaviorTest`/`runV4TimingTest` → `SimDiagnostics.swift` (본문 이동만, `build.sh` 등록).
- 진단 대기 루프 → `pollValue`/`pollUntil`. `bridge.py` begin/reset 중복 → `_reset_session_caches()`. 죽은 코드 3개·미사용 import 2개 제거.
- Codex 1차 리뷰: 리팩토링으로 생긴 회귀 없음(본문 동일성 확인).

## 운반: 이동 전 제약 (Codex P2 해결)
막힌 뒤 방향을 추측하는 방식은 모두 실패했다: 직선 추적(참여체 31.6 mm 밀림), 극좌표(벽에 막히면 회전 불가, 방향 오차 90°), 매 스텝 접선(1.68 mm 밀림), 고정 접선(대각선 반례 −0.052 mm 관통, 재차 막히면 고착, 이벤트 1,323회 반복).

현재: 매 substep 이동 **전** `mj_geomDistance` witness 점으로 법선(`(from−to)/d`, 운반 geom이 첫 번째면 관통 여부와 무관하게 장애물→물체)과 남은 간격을 구해, 다가가는 성분을 남은 간격까지만 허용(참여체 `CARRY_GAP_MM`, LabObject `CARRY_CONTACT_SKIN_MM`). 기존 이동 후 되돌림은 안전망으로 유지. 계약: `docs/plans/VIRTUAL_FLY_LAB_V5_6_GRAB_PLACE_SPEC.md` 관통 방지 항목.

real MuJoCo (`test_interaction_real.py`, 경로 전체 추적):

| 시나리오 | 참여체 최대 이탈 | 최소 간격 |
|---|---:|---:|
| 45° / 180° / −135° 회전 | 0.0000 mm | 0.500 mm |
| 벽에 끼인 채 90° 회전 (풀림 이벤트 1회) | 0.0000 mm | 0.500 mm |
| 대각선 모서리, 시작 간격 0.1 mm | 0.0000 mm | 0.1002 mm |
| 두 번째 벽에 막힌 뒤 제거 → 복구 | 0.0000 mm | 0.500 mm |
| 벽 앞 10° 회전: 막힘/풀림 전환 | 1쌍 | — |

음성 대조: 제약을 끄면 새 시험 7개 중 6개 FAIL(최대 이탈 32.5 mm, 간격 −0.05 mm). 작은 회전 시험은 고정 접선 방식 고유의 깜빡임을 막는 회귀 시험이라 제약 없이도 통과한다.

주의: 원점 근처는 파리와 부딪혀 참여체가 입력 없이 1.39 mm 움직인다(물체 없이도 재현). 시험 배치는 (60, 20) 부근을 쓴다.

## 성능 게이트
`20 distant objects carry overhead <= 5%`: 두 중앙값을 따로 비교하던 측정이 ±3% 흔들려(5.77/9.86/4.91%) 인접 쌍 비율의 중앙값으로 바꿨다(기준 5% 유지). 그러자 실제 비용 ≈5.1%가 드러나, 제약을 이동할 거리가 있을 때만 계산하게 했다 → **3.19/3.18/3.70/3.62%** 4회 PASS. 음성 대조: 운반 중 substep당 2 µs 지연 주입 → 5.55% FAIL.

## `--inputprobe`
실패 전제조건이면 exit 1: 세션 시작, 활성화 ACK 거절·시간초과, 입력 큐잉 실패, 누적 거절(`FlyGymBridge.playerInputResultCounts()`), 마지막 seq 미확인, 구간별 스냅샷 없음. 음성 대조 3종(활성화 거절 / 7번째마다 입력 거절 — 최신 결과가 이미 성공(seq 8)으로 덮인 상태에서 검출 / look 구간 스냅샷 중단) 모두 exit 1, 정상 mock·headless exit 0.

## 회귀 (최종)
- Python 10종 exit 0: bridge 45, lab 55, v4 48, v5 32, v5_6 42, presets, lab_real 64, vision_real 14, player_collision_real 19, interaction_real 29.
- Swift 7종 exit 0: labtest, bridgetest, v4test, v4timingtest, simtest, behaviortest 17, gpucheck.
- TCP (검사마다 새 backend, 17841 사전 비어 있음 확인, 종료 후 잔여 리스너 없음): mock bridgeloop/labloop/v4loop/interactionloop/inputprobe, headless interactionloop/inputprobe 모두 exit 0.
- GUI: 사용자가 앱에서 운반·벽 미끄럼·시점 감도를 확인함(2026-09-27, 수치 기록 없음).
