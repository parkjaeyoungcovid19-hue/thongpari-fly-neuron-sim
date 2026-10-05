# V6.3 편집 상태 inventory — V9 전달

[구현 계약](CONTRACT.md)에 따른 상태 소유·정리 목록. V6.3은 checkpoint나 scene 저장 구현이 아니다. 구현/테스트 보고서에서 실제 연결을 확인한 후 증거를 추가한다.

| 상태 | 소유/보존 원칙 | 정리/후속 처리 |
|---|---|---|
| 객체 ID·형상·pose/size/yaw·revision·food variant | Python LabWorld가 정본. Swift snapshot mirror만 보유 | V9 continuation 대상. shape별 geometry와 revision을 함께 보존해야 함 |
| 복제된 객체와 슬롯 배정 | LabWorld에서 mutation 경계에 한 번 적용, 새 ID로 static 속성 복사 | dynamic toy/feeding/approach 상태는 복제하지 않음. V9는 각각 명시적 상태로 다뤄야 함 |
| 현재 선택 ID·도구 모드 | AppKit editor presentation 상태 | 객체 제거/세션 전환에서 유효성 재확인. 일반 scene 속성이 아님 |
| 드래그 draft·수치 입력 draft·공유 NSTextView field editor | UI-only; authoritative applied geometry와 분리 | Escape/선택·모드·identity·authored revision 전환에서 실제 focused editor text도 취소/복원. 동일 revision의 일반 polling은 caret/text 보존. 저장/replay에 applied로 넣지 않음 |
| pending-delete 선택 보존·confirmedDuplicate·selection serial | UI-only ACK/snapshot 순서 중재, 새 사용자 선택보다 우선하지 않음 | ACK 이전 snapshot만으로 삭제 선택을 확정하지 않음. duplicate ACK/첫 snapshot 순서·timeout·세션 전환·사용자 선택 변경에서 정리; 자동 회귀 결과 확인 필요 |
| pending edit (command ID, target/revision, session/epoch, generation, time) | 기존 owner command/ACK lifecycle + UI presentation 추적 | 이미 보낸 명령은 로컬 draft 취소로 철회되지 않음. timeout은 unknown/rejected 표시, 무한 자동 재시도 없음 |
| applied ACK actual_value/tick | backend 확인 응답·snapshot을 근거로 UI 표시 | mismatched ACK 무시. V7 사건 stream에는 ID/tick/value/revision을 함께 전달 |
| inline error/path | UI presentation | 세계 상태 불변과 별개로 오류 원인 유지; 재시도는 사용자 요청 |
| camera/outline | current requested camera와 최신 snapshot 기반 UI-only overlay | JPEG에는 frame stamps/depth mask가 없어 일시적 lag 가능; physics snapshot으로 오해 금지 |

## Quit/cleanup

앱은 자신이 소유한 private bridge와 view stream을 정리해야 한다. 이번 baseline 관리 job 종료 후 listeners 부재와 owned backend exit를 확인했다. 이는 GUI 정상 Quit lifecycle 수용을 대체하지 않는다. V9 checkpoint에는 UI draft/pending 명령을 applied world로 섞지 않아야 한다.
