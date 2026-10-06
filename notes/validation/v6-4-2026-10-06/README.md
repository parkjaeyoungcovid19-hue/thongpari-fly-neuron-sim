# V6.4 primitive 지형 편집 — 검증 (2026-10-06, Claude)

판정: **자동·실물 물리·실제 TCP 통과, GUI 미확인.** 사용자 요청 “다음단계 개시”로 V6.3 편집기 GUI 수용을 보류한 채 진행했다([진행표](../../../docs/reports/V6_PROGRESS.md)). GUI 항목은 [GUI_CHECKLIST.md](GUI_CHECKLIST.md)에 있고 사용자가 확인한다.

## 무엇을 만들었나

- **새 모양 `ramp`(경사로).** MuJoCo box에 기울기 `pitch_deg`(0–45°, 자기 Y축 기준, +X 끝이 올라감)를 더했다. yaw → pitch 순서. 기본값 40×20×1 mm, 15°, 낮은 윗모서리가 잔디(z=0)에 닿는 높이.
- **기울기·크기 편집은 낮은 윗모서리 중앙을 축으로** 돈다. 잔디에 붙여 놓은 경사로는 계속 붙어 있다. 이동은 중심을 옮기고, yaw는 중심 기준이다.
- **파리가 실제로 올라선다.** FlyGym 파리 geom은 contype 0이라 명시 접촉쌍이 없으면 아무 지형이든 통과한다(기존 box/wall/sphere는 몸통·머리·배하고만 쌍이 있다). 경사로 슬롯마다 파리의 경골·부절·몸통 43개 geom과 쌍을 만들고, 마찰·solref·solimp·margin은 FlyGym이 잔디에 쓴 값을 그대로 복사한다. 다리 접착은 tarsus5 접촉 상대를 가리지 않으므로 경사로에도 작동한다.
- **고정 지형.** 잡기(`fixed_terrain`)와 접근(approach)을 거절한다. 색은 갈색(시각 looming 표적인 마젠타가 아님).
- **슬롯 예산.** 경사로 4개. 초과하면 `CapacityError` → v4 ACK `status: rejected_capacity`, 오류 문자열은 기존과 같은 `no free ramp slots`. 복제 초과는 `edit.detail`에 `shape`, `capacity`. Swift는 보내기 전에 남은 자리가 0이면 막고, 거절되면 “경사로 자리를 모두 쓰고 있습니다 (4/4개) — …”로 보여 준다.
- **UI.** 물체 놓기 종류에 “경사로 (파리가 오를 수 있음)”. 편집기에 **기울기** 탭(경사로만 활성), ∠ 드래그 핸들(1°/pt, 0–45° 안), 외곽선·크기 핸들이 기울어진 자기 축을 따른다. 지도에는 기울기만큼 줄어든 발자국으로 그린다.
- descriptor 39 → 42개(`object.ramp.position_mm`, `object.ramp.size_mm`, `object.ramp.pitch_deg`). 공유 fixture에 경사로 edit 5개를 추가했다(accept 2, reject 3).

## 결과

| 검사 | 결과 |
|---|---|
| [mock 단위 9개](../../../flygym_bridge/test_v6_4_terrain.py) ([log](py-test_v6_4_terrain.log)) | PASS: 잔디에 붙는 기본 생성, `spawn_ramp`, 렌더 쿼터니언이 독립 회전 계산과 일치, 기울기·크기 편집 시 축 고정, 다른 모양의 pitch 편집 거절·무변경, 복제가 기울기 유지, 용량 초과 무변경, v4 ACK `rejected_capacity`, 잡기·접근 거절 |
| [실물 MuJoCo](../../../flygym_bridge/test_v6_4_terrain_real.py) ([log](py-test_v6_4_terrain_real.log)) | PASS 7/7: 쌍 172 = 4 × 43(BB탄 쌍 없음), 잔디와 같은 접촉 파라미터. **렌더↔충돌**: box/wall/sphere/기울어진 ramp의 render_objects pose·size와 collision geom의 xpos·xmat·size 최대 차 1.1e-16, 각 면 안쪽 0.3 mm 탐침은 충돌·바깥 0.5 mm는 비충돌, 바깥 간격 오차 5.3e-15 mm. **오르기**: 15° 경사로를 향해 걸린 파리의 흉부 z 1.00 → 최대 7.41 mm(x 27.1 mm, 그 지점 경사면 6.20 mm), 경사로에 닿은 부절 geom 8개 |
| 음성 대조 — 물리 | 다리 쌍만 뺀 같은 장면(`terrain_leg_contact: False`): 흉부 z 최대 1.15 mm, 부절 접촉 0 → 다리가 통과. 즉 오르기는 새 접촉쌍 때문이다 |
| [음성 대조 — 코드](negative_control.py) ([log](negative-control.log)) | 축 고정 제거, 용량 오류를 일반 LabError로, 렌더를 yaw만으로, 접근 허용 — 네 가지 모두 해당 테스트 하나씩이 잡았다 |
| [TCP 프로브](tcp_ramp_probe.py) mock ([log](tcp-probe-mock.log)) / real headless ([log](tcp-probe-real.log)) | 각 9/9 PASS. 전용 빈 포트(55617/55627)의 새 백엔드, 실제 소켓: 생성 ACK applied+tick, 렌더 스냅샷 쿼터니언 오차 0, 기울기 편집 후 모서리 고정, stale 재전송 거절·무변경, 46° 백엔드 거절(clamp 없음), 5번째 `rejected_capacity`·무변경, 삭제 후 재생성. 종료 후 포트 해제 확인 |
| Python 회귀 ([요약](python-regression.log)) | 20종 PASS. 처음 실행에서 `test_lab_real`·`test_v5_6_2`의 기본 슬롯 표 기대값에 `ramp: 4`가 없어 실패 → 기대값 갱신 후 통과. `--mock-only` 2종은 실행 스크립트의 인자 분리 실수로 처음엔 안 돌았고 재실행 통과 |
| Swift `--worldeditortest` ([log](swift--worldeditortest.log)) | 0 failures. 새 10개: pitch 디코딩, 외곽선 축 = 백엔드 쿼터니언(오차 < 1e-12), 기울기 descriptor는 ramp만, 45° 허용·45.0001° 전송 전 거절, box에서 기울기 탭 비활성, ramp에서 활성·값 표시·Return 1회 전송, flush 높이 4.69342 mm(Python과 같음), `spawn_ramp` 전송 형식, 범위 밖 생성 거절, 용량 초과 문구 |
| Swift `--labtest` / `--v4test` / `--bridgetest` | 모두 exit 0. `--bridgetest`의 1536객체 fixture는 descriptor 42개로 [생성기](../v6-1-2026-10-05/make_large_state_fixture.py)를 다시 돌려 갱신(539,975 B, 여전히 512 KiB < frame < 1 MiB) |
| [TCP 루프](run_loops.py) ([log](loops.log)) | `--labloop`·`--interactionloop`·`--v4loop` mock, `--labloop` real, `--bridgeloop` real 모두 exit 0 |
| 성능 회귀 (AC 전원) | `--bridgeloop` real: body 36.2 Hz, gap 43 ms, sim/wall 0.762. V6.2 때 36.3 Hz / 0.773과 같은 수준(경사로 없음) |
| `git diff --check` | 통과 |

미실행: `--simtest`/`--behaviortest`/`--gpucheck` — 뇌 시뮬레이션·셰이더는 바꾸지 않았다.

## 경사로 비용 (측정, AC 전원, 쌍 비율 중앙값)

| 상황 | body step |
|---|---|
| 경사로 슬롯 4개만 있고 놓인 것 없음 | +0.0% |
| 경사로가 파리에서 약 50 mm | +1.6% |
| 파리가 넓은 경사로 위 | **+45%** (범위 +38…+89%) |

원인은 메시–상자 충돌이다. 잔디는 평면이라 메시와의 충돌이 닫힌 식으로 싸지만, 상자는 GJK다. `mj_collision`이 10 → 47 µs/substep으로 늘었다. 접촉쌍을 63개(전체 FlyGym 접촉 세트)에서 43개로 줄였을 때 +55% → +45%였다. 경사로 bound를 실제 크기로 갱신(`geom_rbound`/`geom_aabb`)하는 것은 정확성·멀리 있을 때 비용에는 맞지만 위에 올라섰을 때 비용은 줄이지 못했다.
더 줄이려면 다리 끝에 단순 캡슐 대리 geom을 두고 그것만 경사로와 닿게 하는 방법이 있다. 접촉 형상이 바뀌는 모델링 변경이라 사용자 승인 없이 넣지 않았다.

## 한계

- 경사로는 얇은 판이다. 기본 두께 1 mm라 옆이나 높은 쪽 밑으로는 파리가 지나갈 수 있다(대조군에서도 판 아래로 걸어감). 두께는 20 mm까지 바꿀 수 있다.
- 기울기는 경사로만. box/wall/sphere는 수직축 회전만 한다.
- 파리의 FlyGym `stumbling` 힘 관측과 다리 접촉 센서는 잔디만 본다(FlyGym이 `ground_only`로 정의). 경사로 위에서도 걷기 제어기는 그대로 돌지만, 그 관측에는 경사로 접촉이 들어가지 않는다.
- 자동차 등 운반·주행 물체는 경사로를 장애물로 보고 오르지 않는다(kinematic).

## 재실행

```sh
./build.sh
flygym-venv/bin/python flygym_bridge/test_v6_4_terrain.py
flygym-venv/bin/python flygym_bridge/test_v6_4_terrain_real.py
flygym-venv/bin/python notes/validation/v6-4-2026-10-06/negative_control.py
flygym-venv/bin/python notes/validation/v6-4-2026-10-06/tcp_ramp_probe.py real
flygym-venv/bin/python notes/validation/v6-4-2026-10-06/run_loops.py
./ThongpariFlyNeuronSim --worldeditortest
```

앱 번들(`dist/Thongpari Virtual Fly Lab.app`)과 런처 배너를 V6.4로 갱신했다. 커밋하지 않았다.
