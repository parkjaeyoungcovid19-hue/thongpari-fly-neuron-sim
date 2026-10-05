# V5 마감 결함 수정·재검증 — 2026-10-05

## 판정

**A-1~A-4 수정·자동 재검증 완료. V5 전체 완료는 아님; V6 구현은 시작하지 않음.**

기준 HEAD: 799067408bc7be23733d24768fd8276c267a43b0 + 미커밋 변경. 기존 사용자의 음식 용량 테스트·README 변경을 보존하며 필요한 상태 정정만 적용했다. 설치·커밋·푸시 없음.

## 수정과 독립 검증

- **A-1 음식 용량:** 기존 사용자 수정 유지. 승인 기본 용량은 정확히 8개. mock/real에서 8개 사용, 9번째 거절 시 상태 불변, 삭제·슬롯 재사용·reset 및 real geometry 비활성화를 확인. [실제 용량 테스트](../../../flygym_bridge/test_lab_real.py), [샌드박스 테스트](../../../flygym_bridge/test_v5_6_2.py).
- **A-2 섭식 삭제:** [삭제 경로](../../../flygym_bridge/lab_world.py#L738-L756)가 누적 contact_s를 보존하고 feeding_end(reason=object_removed)를 즉시 한 번 발행. 활성 ID를 비워 같은 ID 재사용에 이전 구간이 섞이지 않음. 고갈은 기존 feeding_end(reason=eaten) → food_eaten 순서·시간을 유지.
- **A-2 독립 회귀:** [새 테스트](../../../flygym_bridge/test_feeding_events.py) **9개 PASS**. 원래 코드에서는 초기 7개 중 6개 실패(고갈 control만 PASS). 접촉 합산, 즉시 삭제, 중복 종료 방지, ID 재사용, 비활성 삭제, 대상 전환, 고갈, world/body reset, MockBody 명령·다음 packet 검증.
- **A-3 pause 도움말:** [한·영 안내](../../../ActivityCards.swift#L285-L288)를 실제 정책에 맞춤: 모델 지표/GF 사건은 —, 유한 발화율은 마지막 표본 유지(실시간 측정 아님). [labtest 회귀](../../../LabDiagnostics.swift) PASS.
- **A-4 진행 문서:** [프로젝트 상태](../../../README.md), [진행표](../../../docs/reports/V5_PROGRESS.md), [로드맵](../../../docs/plans/VIRTUAL_FLY_LAB_ROADMAP.md), [샌드박스 명세](../../../docs/plans/VIRTUAL_FLY_LAB_V5_6_2_SANDBOX_SPEC.md)를 최신 증거와 정합화. 과거 개별 완료를 V5 전체 완료로 확대하지 않음.

별도 read-only 리뷰: **No findings**. 최종 변경·9개 테스트 재독해 및 lightweight 회귀 PASS. 리뷰는 real/Swift/GUI 검증을 대신하지 않으며 아래 실행은 별도로 수행했다.

## 최종 실행 — 모두 exit 0

실행 위치: 저장소 루트. Python은 PYTHONDONTWRITEBYTECODE=1로 실행. 중량 검사는 순차 실행.

| 검사 | 증거 |
|---|---|
| ./build.sh | [build-final](build-final.log) |
| --labtest | [labtest-final](labtest-final.log) |
| --bridgetest | [bridgetest-final](bridgetest-final.log) |
| --v4test | [v4test-final](v4test-final.log) |
| --v4timingtest | [v4timingtest-final](v4timingtest-final.log) |
| --simtest | [simtest-final](simtest-final.log) |
| --behaviortest | [behaviortest-final](behaviortest-final.log) — 재실행 없이 PASS |
| --gpucheck | [gpucheck-final](gpucheck-final.log) |
| Python test_feeding_events | [9 tests / OK](test_feeding_events-final.log) |
| Python test_bridge | [PASS](test_bridge-final.log) |
| Python test_lab | [PASS](test_lab-final.log) |
| Python test_v4 | [PASS](test_v4-final.log) |
| Python test_v5 | [PASS](test_v5-final.log) |
| Python test_v5_6 | [PASS](test_v5_6-final.log) |
| Python test_lab_real | [PASS](test_lab_real-final.log) |
| Python test_interaction_real | [PASS](test_interaction_real-final.log) |
| Python test_player_collision_real | [PASS](test_player_collision_real-final.log) |
| Python test_vision_real | [PASS](test_vision_real-final.log) |
| Python test_v5_6_2 | [mock + real PASS](test_v5_6_2-final.log) — 실제 haustellum 섭식 begin → end → eaten 및 슬롯 비활성화 |
| Python test_v5_6_2_tools | [mock + real PASS](test_v5_6_2_tools-final.log) — 자동차·함정·BB 및 idle overhead |
| fresh real-headless --bridgeloop | [PASS](bridgeloop-real.log), [실행·정리 기록](performance-result.json) |

신경 지표: rest GF **0**, abrupt loom 첫 발화 **3 ms**, walk duty **34%**(20~50%), siesta walk **48%**(>3%), air-puff GF **1**(≤2), 16-step **102 µs/step**(<1000). GPU는 **15,091,983 weights 불일치 0**, 주요 reference 시나리오 max|Δv|=0. overlap/gait의 문서화된 ulp 차이 및 의도적인 arithmetic negative-control FAIL은 전체 GPUCHECK 실패가 아니다.

도구 overhead: 30쌍 paired median ratio **0.9521**(상한 1.05) PASS. 상대 idle-slot 비용이지 GUI/live 성능 증거가 아니다.

## Fresh TCP 성능

[재현 스크립트](run_real_gate.py) 실행 명령:

    ./flygym-venv/bin/python notes/validation/v5-next-2026-10-05/run_real_gate.py

새 real-headless backend만 시작하고 포트 **17841** listener PID가 자신의 backend인지 확인. sent **200**, recv **158**, **4.2 s**, brain **47.6 Hz**, body **38.1 Hz**, max body gap **34 ms**, sim/wall **0.807**, peak |vx| **4.14 mm/s** → 현재 TCP gate PASS. backend 종료(-15) 및 포트 재사용 가능 확인. [backend 로그](performance-backend.log).

최초 래퍼는 문자열 escape 오류로 실행 전 실패. 다음 시도는 Python만 19805를 사용했으나 Swift diagnostic은 기본 17841을 사용해 no connection. 둘 다 유효한 성능 측정이 아니며 위 최종 실행만 판정에 사용했다. [2026-09-29의 14.1 Hz 실패](../v5-independent-2026-09-29/README.md)는 역사적 증거로 유지한다. 이번에 성능 코드를 수정하지 않았으므로 개선 원인이나 장시간 안정성을 증명했다고 주장하지 않는다.

## GUI 한계·다음 단계

최신 binary --lab --mock로 별도 프로세스·창을 띄웠지만 호스트 **Accessibility=false / Screen Recording=false**. 정확한 창 snapshot은 AX 미해결·TCC 캡처 거절로 증거를 제공하지 못했다. **GUI 수용 검사 미실행**. 클릭·입력·권한 우회·foreground 재시도 없음. [GUI 시작 로그](gui.log)는 수용 증거가 아니다.

1. 권한이 준비된 호스트에서 fresh **real** Lab GUI 검증(또는 사용자 수동 수용 확인).
2. 음식 8개/9번째 거절·삭제/재사용, 섭식 중 삭제·종료 시간, 자연 고갈, reset 동선.
3. 자동차·함정·BB, Data 카드 실행/일시정지/재개 및 도움말.
4. World → Brain → Data → Experiment → Settings, input focus·look/pick ACK latency, 렌더링 중 body ≥30 Hz·viewport FPS·feedback gap 확인.
5. 모든 필수 V5 gate를 기록한 뒤에만 V6 착수.

새 삭제 구간의 GUI 표시는 실제 UI에서 확인하지 않았다. 기존 reset은 기록을 지우는 정책을 그대로 유지한다.

## 정리

GUI job SIGTERM 종료, parent watchdog backend도 종료. 모든 실제 테스트 종료. 최종 ps에서 bridge.py/ThongpariFlyNeuronSim 프로세스 없음; git diff --check PASS. 새 reason/timing은 의도적 가산 계약 변경이며 소비 경로 리뷰·회귀 통과. 기존 무관한 dirty/untracked 파일은 삭제하지 않았다.
