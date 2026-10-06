# 2026-10-06 GUI 결함 수정 (F01–F04)

대상: [Codex 실제 GUI 보고서](../gui-2026-10-06/REPORT.md)의 결함 4건. Claude가 보고서의 원인 주장을 코드에서 확인한 뒤 수정했다. **수정된 앱으로 실제 창을 다시 확인하지는 않았다**(이 환경에서는 Computer Use를 쓸 수 없음). 아래 "남은 GUI 확인" 목록은 사용자 확인 대상이다.

## 수정

| 결함 | 원인(확인함) | 수정 |
|---|---|---|
| F01 P1 경사로 기울기가 편집기에 전달되지 않음 | `updateArenaFromAtomicSnapshot`이 render quaternion에서 yaw만 뽑고 `pitchDeg`를 버림 | `LabWorldObjectRemote(render:lab:)`(LabProtocol.swift) 하나가 같은 quaternion에서 yaw와 경사로 pitch를 함께 계산(`lab_world.quat_wxyz` = Rz(yaw)·Ry(−pitch)의 역). 외곽선·필드·∠ 드래그 기준이 실제 각도를 받음 |
| F04 P1 후각 계산이 실제 파리 대신 원점 사용 | `_vec3`가 list/tuple만 받아 MuJoCo의 NumPy `xpos`를 원점으로 바꿈 | `_vec3`가 길이 3 이상인 모든 sequence(NumPy 포함)를 받고, 문자열·mapping은 기존처럼 기본값 |
| F02 P2 숫자 오류가 이전 ACK/거절 문구로 덮임 | 매 refresh마다 큐의 마지막 메시지를 "마지막으로 만진 그룹"에 다시 칠함 | 큐 메시지에 대상 속성(`messagePropertyID`)을 붙여 그 섹션에만 표시. 로컬 거절(범위 오류·시뮬레이터 없음)은 따로 보관해 같은 섹션을 다시 쓸 때까지 유지. 세션 변경·세계/전체 초기화 때 끝난 응답과 로컬 거절을 지움(보내는 중인 편집은 유지) |
| F03 P2 언어 변경 후 편집기 영문 잔존 | 편집기 정적 문구를 생성 때 한 번만 설정 | `WorldEditorInspector.relabel()`: 버튼·도구 탭·안내문·물체 목록·현재값 줄을 다시 씀. `languageChanged`에서 호출. 입력 중인 초안은 유지, 이전 언어로 된 끝난 응답은 지움 |

## 검증 (2026-10-06, AC 전원)

| 검사 | 결과 |
|---|---|
| `--worldeditortest` | 0 failures. 새 검사: render snapshot → 편집기 tilt 25°/yaw 40° 유지(상자는 pitch 없음), 언어 변경 시 탭 문구 한국어·초안 "33" 유지, 바람 busy 뒤 온도 50 입력 시 범위 오류는 온도 아래·busy는 바람 아래 유지(refresh 후에도), 초기화 시 세 상태줄 모두 숨김. [로그](swift--worldeditortest.log) |
| `--labtest`, `--bridgetest`, `--v4test` | 모두 PASS |
| Python mock 10종 (`test_lab` 등) | 모두 exit 0. `test_lab`에 NumPy 위치 = list 위치(14.7 mm), 원점(>100 mm)과 다름, 비벡터는 원점 fallback 검사 추가 |
| Python real 3종 (`test_lab_real`, `test_world_editor_real`, `test_v6_4_terrain_real`) | 모두 exit 0 |
| 실물 후각 probe ([스크립트](real_odor_probe.py)) | 실제 FlyGym 몸에서 body packet 거리 22.8602 mm = 흉부 기준 22.8602 mm, 원점 기준 23.3343 mm와 구분됨. PASS. [로그](real-odor-probe.log) |
| F04 음성 대조 | 같은 위치에 예전 `_vec3`를 넣으면 141.30 mm(원점 거리)로 돌아감 — 새 테스트가 예전 코드를 잡음 |
| `./package_app.sh` | exit 0 |

## 남은 GUI 확인 (사용자)

1. 경사로 생성 → 기울기 필드 15, 노란 외곽선이 판과 같이 기울어짐 → 30 입력 후 필드 30 → ∠ 핸들 드래그가 30에서 시작 → 복제본도 같은 각도.
2. 파리를 원점에서 먼 곳으로 걷게 한 뒤 '파리 앞 15mm' 먹이 → 환경 패널의 가장 가까운 먹이 거리가 약 15 mm, 접근/이탈 시 냄새 값 변화.
3. 온도 35 적용 → 50 Return: 온도 아래 10–40 범위 오류가 계속 보임. puff 중 세기 변경(busy) 뒤 온도 50: busy 문구는 바람 아래에만. 전체 초기화 뒤 이전 문구 없음.
4. English → 한국어 → English: 편집기 버튼·탭·안내문·물체 목록이 따라 바뀌고 선택·적용값 유지.

성능(30 Hz 기준)은 이번 수정과 무관하며 AC 재측정은 아직 하지 않았다.
