# V6.3 독립 점검 — Claude (2026-10-05 23:3x)

대상: dsh 세션 `session-ba2dfeca…`(GPT-6.1 Sol, 22:12–23:20)이 만든 미커밋 V6.3 작업.
코드는 수정하지 않았다. 근거는 실행 중인 앱 창 캡처(pid 73777, 창 49952), dsh 세션 첨부 스크린샷, 그리고 소스 코드다.

## 판정

**V6.3 미완료. 핵심 경로(수치 편집 → 적용 확인)가 실제 앱에서 동작하지 않는다.** 자동 테스트 206개가 PASS지만, 테스트가 실제 실시간 경로를 거치지 않아 이 결함을 잡지 못했다.

## 발견사항 (우선순위 순)

### P0-1. 실시간 모드에서는 모든 편집이 "적용 확인 불가" 오류로 끝난다
- 현상(실제 창): 타임라인에는 `#1 edit_property — 적용됨`, 편집기에는 `시뮬레이터 r2 · XYZ 60, 0, 5`로 표시되는데, 빨간 글씨로 **"응답 시각 불일치 — 적용 확인 불가"**가 함께 뜬다.
- 원인: 실시간 serve loop가 `flygym_bridge/bridge.py:1062`에서 `self._apply_lab_commands()`를 **인자 없이** 호출한다. V4 envelope 명령인데도 ACK가 `status="applied"`, `applied_tick=None`, `applied_epoch=None`으로 나간다(`bridge.py:501-506`). 그런데 Swift `WorldEditorState.accept`(`WorldEditor.swift:84-88`)는 `appliedEpoch == epoch`와 `appliedTick != nil`을 필수로 요구한다.
- 파급: 복제·삭제도 같은 경로로 실패 처리된다. 따라서 복제한 물체로 선택이 옮겨지지 않고, 삭제 뒤 선택이 정리되지 않는다.
- 테스트가 놓친 이유: `test_world_editor.py:99`는 `applied_tick=0`을 직접 넘긴다. Swift 진단(`WorldEditorDiagnostics.swift:23`, `WorldEditorAppKitDiagnostics.swift:38`)은 `appliedTick:40`을 넣은 합성 ACK를 쓴다. 실시간 serve loop 호출부는 어떤 테스트도 지나가지 않는다.
- 수정 방향: 실시간 loop에서도 `_apply_lab_commands(applied_tick=self._current_owner_tick(), applied_epoch=self.session_epoch)`로 호출한다. 이 envelope는 편집기 명령에만 붙으므로(`labCommandSchedule()`는 deterministic 전용이다), 영향 범위가 기존 legacy 명령의 지연 처리로 번지는지 확인해야 한다. 그다음 serve-loop 경로를 거치는 회귀 테스트를 추가한다(mock backend + 실시간 세션 + `edit_property` → ACK에 `applied_tick`이 있는지 확인).

### P1-2. 편집 모드에서 선택한 물체가 화면에 보이지 않아 핸들을 쓸 수 없다
- 시점이 "파리 따라가기"로 고정돼 있다. 물체가 (60,0,5)이고 파리가 (127,588)에 있으면 outline과 핸들이 화면 밖으로 projection된다(실제 창에서 둘 다 보이지 않음).
- 선택한 물체로 시점을 옮기는 기능("선택 물체 보기")이 없다. 계약상 "드래그 핸들"이 주 입력인데, 현재 상태로는 수치 입력만 쓸 수 있다.

### P1-3. 편집기 UI 품질
- 선택이 없으면 X/Y/Z 라벨이 비어서, 라벨 없는 빈 칸 3개만 보인다. 라벨은 `populate()`가 물체가 있을 때만 설정한다(`WorldEditor.swift:301-310`).
- 관찰 모드에서도 비활성 편집기 전체와 "편집 모드 필요" 문구가 항상 펼쳐져 있다.
- 도움말이 개발자 용어 위주다("시뮬레이터 r2", "S는 지름/길이", "월드 축", "실행 취소 없음"). 오류 문구는 `edit.value[1]: …` 같은 내부 경로를 그대로 보여준다.
- 지도 라벨이 겹친다("고루 위치 60,0,0 mm"와 "obstacle_box · 상자"). V6.3 이전부터 있던 문제가 편집 화면에서 더 눈에 띈다.

### P2-4. 코드 품질
- `WorldEditor.swift` 전반이 압축된 스타일이다(`;`로 여러 문장을 한 줄에 몰아 씀, 공백 없는 인자). 주변 코드 스타일과 맞지 않는다.
- `LabWindow.swift:2755-2757` 들여쓰기가 깨졌다.
- `WorldEditor.swift:70`의 오류 문자열이 `L()` 현지화 없이 영어로만 들어가 있다.
- `WorldEditorState.accept`의 `if let s = p.schedule` 분기가 앞의 `guard let schedule`과 중복된다.

### 참고 (V6.3 이전부터 있던 문제 — Codex 책임 아님)
- 잔디는 ±150 mm만 그려지고, 바닥 평면은 무한 충돌한다(`sandbox_models.py:255-275`). 파리가 밖으로 걸어 나가면(실제 창 y=588 mm) 배경이 검게 빈 공간이 된다. 경계 벽이나 텍스처 확장이 필요한지는 별도로 정해야 한다.

## GUI 검증 상태
- Codex 호스트는 손쉬운 사용 권한이 false라서 클릭·키 입력이 거절됐다(`permissions-final.json`). `GUI_CHECKLIST.md`의 14개 항목은 전부 미실행이다.
- 세션은 23:20 GUI 확인 도중에 끊겼다. 앱 `73777`과 backend `73780`이 아직 실행 중이다.

## 수정 순서 제안
1. P0-1 backend ACK tick 수정 + serve-loop 회귀 테스트, 실제 앱에서 수치 이동 → 오류 없이 "적용 완료" 확인
2. P1-2 "선택 물체로 시점 이동"(편집 모드 진입이나 선택 시)
3. P1-3 라벨, 관찰 모드에서 접기, 문구 정리
4. P2-4 스타일 정리
5. 사용자 GUI 체크리스트 수행

---

## 수정 결과 (2026-10-05 23:55, Claude)

| 항목 | 변경 | 증거 |
|---|---|---|
| P0-1 | `bridge.py`: 실시간 tick 처리를 `_apply_interactive_owner_inputs()`로 분리. lab 명령과 player 입력을 같은 owner tick/epoch로 ACK | 새 테스트 `test_interactive_serve_loop_ack_carries_owner_boundary` PASS. 이 테스트는 수정 전 호출 방식에서 FAIL(`KeyError: 'applied_epoch'`)한다. 실제 TCP probe 결과: mock PASS(`applied_tick` 39), **수정 전 코드 mock FAIL(`applied_tick: null`)**, real FlyGym headless PASS(`applied_tick` 65 ≥ requested 45, epoch 1) |
| P1-2 | `WorldViewer.focusObservationCamera`, `LabWindow.focusCamera(onObject:)` 추가. 목록에서 선택하거나 "선택 물체 보기" 버튼을 누르면 그 물체를 중심으로 Orbit하고 시점 팝업도 함께 바뀐다. 편집 모드에 들어갈 때 선택 물체가 화면 밖이면 자동으로 이동한다 | 빌드·진단 PASS. **실제 클릭 동선은 사용자 확인 필요** |
| P1-3 | 관찰 모드에서는 편집기를 안내 한 줄로 접는다. 라벨은 항상 표시한다(회전 (°), 크기 (mm)). 목록에 "물체 선택…"/"물체 없음" 항목을 넣었다. 현재 값·상태·오류 문구를 사용자 말로 바꿨다(stale은 "그사이 물체가 바뀌었습니다") | 새 앱 관찰 모드 화면 캡처로 접힘 확인. 편집 모드 화면은 사용자 확인 필요 |
| P2-4 | `WorldEditorInspector`를 주변 스타일로 다시 썼다(로직 동일). 중복 schedule 검사 제거, 영어로만 된 문자열 현지화, `LabWindow` 들여쓰기 수정 | `--worldeditortest` 0 failures |

회귀 결과: Python `test_world_editor`, `test_environment_edits`, `test_environment_properties`, `test_bridge`, `test_lab`, `test_v4`, `test_v5`, `test_v5_6`, `test_feeding_events`, `test_v5_6_2 --mock-only`, `test_v5_6_2_tools --mock-only`, `test_world_editor_real`가 모두 PASS다. Swift `--worldeditortest`, `--labtest`, `--v4test`, `--bridgetest`도 PASS다. 새 mock 백엔드로 돌린 TCP `--labloop`, `--interactionloop`, `--v4loop`도 PASS다.

미실행: `--simtest`/`--behaviortest`/`--gpucheck`. sim·shader는 바꾸지 않았다. 실행 중 앱의 상태줄 body는 22 Hz였는데, 배터리 전원 상태였으므로 성능 판정에는 쓰지 않는다.

남은 것: 잔디 밖 검은 공간(기존 V5.6.2 문제), 사용자 GUI 체크리스트.
