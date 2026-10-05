# V6.2 descriptor 기반 strict edit 검증 — 2026-10-05

## 판정

**V6.2 자동 검증 통과.** 잘못된 값의 edit는 세계 상태를 전혀 바꾸지 않고 오류 위치와 함께 거절된다. Swift와 Python이 공유 fixture 35개에서 같은 판정과 같은 첫 실패 경로를 낸다. 이번 단계에는 UI 변경이 없다(편집 UI는 V6.3). V5 GUI 수용과 V6 전체는 아직 미완료다.

기준 HEAD: 7990674 + 미커밋 변경. AC 전원, lowpowermode 0. 설치·커밋·푸시는 하지 않았다.

## 계약

새 LabCommand `edit_property`. Swift는 평평한 `edit` 필드로 보내고, Python은 이를 `args.edit`로 받는다.

    {"type":"lab_command","id":12,"action":"edit_property",
     "edit":{"schema_version":1,"property_id":"eyes.left_enabled","target_id":null,
             "expected_revision":7,"unit":"none","value":false}}

계획서 EditCommand와의 대응: command_id → 기존 `id`/`seq`, property → `property_id`, proposed_value → `value`. session/epoch/requested_tick은 기존 V4 envelope를 그대로 쓰고, 필수로 요구하지는 않는다.

- **검사 순서(양쪽 동일):** object 여부 → 모르는 필드(code point 정렬상 첫 번째) → 필수 필드 → schema_version=1 → property_id(존재, `live`, `scene_candidate`) → unit이 descriptor와 정확히 일치 → target_id(local은 64자 이하의 공백 없는 문자열, global은 null) → expected_revision(0..2^53 정수) → value(타입, 유한값, 포함 범위, 벡터 성분은 `edit.value[i]`). **clamp나 변환은 하지 않는다.** bool은 숫자로 취급하지 않고, 숫자 1도 bool로 취급하지 않는다.
- **backend 전용 검사(Python `LabWorld.apply_edit`):** 대상 객체 존재, 형상 일치(`object.sphere.size_mm`를 box에 적용하면 거절), 잡고 있는 객체 거절, applier 존재, revision 일치. 모든 검사를 마친 뒤에 첫 setter를 호출한다.
- **revision:** 객체 속성은 그 객체의 revision을 쓴다. 온도·눈은 새 `environment_revision`을 쓰며, 기존 명령(temperature/eye/wind/stop_wind/reset)도 이 값을 올린다. 따라서 무관한 객체 이동 때문에 edit가 stale로 판정되지 않는다.
- **V6.2 applier:** `object.*.position_mm`, `object.*.size_mm`, `object.yaw_deg`(요청 범위 ±36000, 적용값은 기존대로 mod 360), `temperature.celsius`/`mode`, `eyes.*`. **바람은 제외했다.** 바람 필드 하나만 바꿀 때 활성 퍼프 타이머와의 의미가 정해지지 않았으므로 `rejected_unsupported`로 거절하고 V6.5 환경 패널에서 정한다. 검증기 자체는 바람 edit를 통과시키며, 이는 fixture `valid-wind-validator-only`로 고정했다.
- **ACK:** 기존 lab_state ACK에 `edit`를 덧붙인다. 성공하면 `{ok, status:"applied", property_id, target_id, actual_value, revision}`, 실패하면 `{ok:false, status, path, reason}`를 보내고, stale이면 `current_revision`도 함께 보낸다(재조회 후 재적용 가능). status 값은 `rejected_invalid`, `rejected_target`, `rejected_unsupported`, `rejected_stale_revision`이다. Swift는 이를 `LabAck.edit`(`EnvironmentEditResult`)로 받는다. 형식이 잘못된 detail은 그 detail만 버리고 ACK는 유지한다.
- 기존 legacy 명령의 clamp 동작은 바뀌지 않았다(온도 80 → 50).

## 구현

- Python: [validate_edit·EditError·EDIT_DESCRIPTORS](../../../flygym_bridge/environment_properties.py), [apply_edit·environment_revision](../../../flygym_bridge/lab_world.py), [LabStatePacket.edit](../../../flygym_bridge/protocol.py), [ACK 연결](../../../flygym_bridge/bridge.py)
- Swift: [EnvironmentEdit·EnvironmentEditResult](../../../EnvironmentProperty.swift), [LabCommand.editProperty·ACK/revision decode](../../../LabProtocol.swift), [LabAck 전달](../../../FlyGymBridge.swift)
- 공유 fixture: [fixtures/environment_edits](../../../fixtures/environment_edits/), 35개(accept 10, reject 25: 범위 초과/미만, 단위 오류·누락, 미정의·spawn-only·transient 속성, 타입 혼동, 벡터 길이·성분, 대상, revision, 모르는 필드, schema)
- 테스트: [Python 11개](../../../flygym_bridge/test_environment_edits.py), [Swift --labtest](../../../LabDiagnostics.swift), [TCP --labloop](../../../BridgeDiagnostics.swift)

## 실행 결과

| 검사 | 결과 |
|---|---|
| [회귀 요약](regression-summary.txt) | 22개 모두 exit 0 |
| ./build.sh, --labtest(PASS 168, V6.2 항목 40개), --bridgetest(PASS 97), --v4test, --v4timingtest, --simtest, --behaviortest, --gpucheck(불일치 0) | exit 0, `*-final.log` |
| Python test_environment_edits(11), test_environment_properties(21) 외 기존 12종 | exit 0 |
| [--labloop mock](labloop-mock.log) / [--labloop real-headless](labloop-real.log) ([실행기](run_labloop.py)) | PASS. 실제 소켓에서 편집 적용(ACK의 actual_value와 revision이 이후 state와 일치), stale 거절(current_revision, 위치 불변), Swift 검증을 우회한 범위 밖 온도도 backend가 `edit.value`로 거절(온도 불변) |
| [real TCP 성능](bridgeloop-real.log) ([기록](performance-result.json)) | PASS: body 36.3 Hz, gap 35 ms, sim/wall 0.773. 직전 AC 측정 38.3 Hz보다 낮지만 30 Hz 기준은 넘는다. A/B는 반복하지 않았다 |
| [Python 음성 대조](negative-control-python.log) ([스크립트](negative_control_python.py)) | 검증 전 변경 → 4건 실패, clamp 처리 → 9건 실패, bool을 숫자로 처리 → 4건 실패, 복원하면 0건 |
| [Swift 음성 대조](negative-control-swift.log) | NSNumber bool 판별을 제거하면 `bad-number-bool`, `bad-revision-bool` 2건 실패. 원래 코드로 되돌린 뒤 다시 빌드했다 |
| `git diff --check` | 통과 |

## 남은 위험과 처분

- **GUI 미검증:** UI 변경이 없으므로 GUI 검사는 하지 않았다. V5 GUI 수용은 계속 보류 중이다.
- **바람 edit 미지원:** V6.5 이전에 의미를 정해야 한다(위 계약 참고).
- **연속 입력:** `edit_property`는 discrete FIFO 큐를 쓴다. 32개/tick, 대기열이 차면 queue_full ACK를 보낸다. 모든 edit가 ACK를 받으며, 연속 slider 병합은 V6.6에서 다룬다.
- **approach 중인 객체:** 기존 move와 마찬가지로 진행 중인 approach는 유지된다. ACK의 actual_value는 적용 시점의 값이다.
- **Swift 온도 선반영:** 기존 동작이다(V6.1 기록). edit 경로는 backend ACK만 신뢰하며 이 문제는 V6.5에서 다룬다.
- **비정상 숫자:** NaN/Infinity/1e999/400자리 정수가 Python wire에 들어오면 거절된다(Python 테스트). Swift는 NaN/inf를 `make` 단계에서 거절한다. JSON에서 NaN을 표현할 수 없으므로 공유 fixture에는 넣지 않았다.

## 정리

실행한 백엔드는 모두 SIGTERM으로 종료했고 17841 포트는 다시 bind할 수 있다. 최종 `pgrep`에서 프로세스는 없었다. 기존의 무관한 dirty·untracked 파일은 건드리지 않았다.
