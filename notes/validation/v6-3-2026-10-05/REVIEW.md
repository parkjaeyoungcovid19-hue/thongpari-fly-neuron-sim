# V6.3 독립 read-only review

2026-10-05. 구현 담당과 별도 reviewer가 source/contract를 검토했다. reviewer는 파일 수정, 프로세스/테스트 실행, GUI 입력을 하지 않았다. 아래는 구현 중 snapshot에 대한 finding이며 최종 상태는 후속 증거로 갱신한다.

| Finding | 초기 상태·조치 | 최종 disposition |
|---|---|---|
| Swift interpolation escaping 누락 | 생성 과정에서 발견, String.raw 기반 수정; reviewer가 원문 확인 | 수정 확인, build/test는 별도 |
| interactive schedule=nil에서 session/epoch/tick ACK 검사 누락 | 모든 V6.3 mutation은 tagged boundary 필수로 owner에게 전달 | 수정/회귀 증거 대기 |
| huge integer revision에서 OverflowError | bounds 선검사 또는 기존 safe numeric helper, structured EditError와 무변경 검사 요청 | 수정/회귀 증거 대기 |
| duplicate actual ID=source 및 descriptor 범위 밖 ACK를 applied로 인정 | distinct valid ID와 captured descriptor 검증 요청; yaw modulo만 허용 | 수정/회귀 증거 대기 |
| 삭제 snapshot이 ACK보다 먼저 선택을 지우고 늦은 ACK가 새 선택을 바꿀 위험 | pending target/selection token 보존; snapshot/ACK 양쪽 순서 검사 요청 | 수정/회귀 증거 대기 |
| 렌더 snapshot→객체 변환에서 object revision 손실 | 표시된 pose와 같은 snapshot의 revision 보존, 제출 시 최신 revision 재캡처 금지 | 수정/회귀 증거 대기 |
| P1: 실제 toolbar에서 Edit 진입 불가 | Observe/Participate만 노출, .edit action은 mode를 설정하지 않음; reachable Edit와 참여 종료 계약 요청 | 수정/회귀 증거 대기 |
| Participate→Edit의 snapshot 확인이 Observe로 종료 | participant exit snapshot은 backend Observe이지만 presentation은 요청한 Edit여야 함; pending target 보존 회귀 요청 | 수정/회귀 증거 대기 |
| P1: numeric Escape의 private(set) 직접 쓰기 | state 내부 mutating presentation reset 메서드 요청 | 수정/build 증거 대기 |
| P1: focused field-editor의 canceled/stale text를 새 revision으로 제출 | 명시적 invalidation/Escape 시 shared NSTextView 종료/복원; 동일 revision의 일반 refresh만 caret 보존 | active field-editor 회귀 증거 대기 |
| refresh와 submit 사이 epoch reset race | captured identity와 현재 coordinator/viewer session·epoch가 일치할 때만 전송; 신규 epoch 암묵 재태깅 금지 | 수정/회귀 증거 대기 |

## 명시적으로 수용한 한계

- 기존 JPEG stream은 frame stamps/depth mask가 없어 camera/overlay와 순간적인 불일치 및 가림 없는 outline이 가능하다. V6.3은 backend snapshot 기반 geometry 편집이며 시각 픽셀 depth 일치를 보장하지 않는다. UI/evidence에 기록하고 후속 렌더 계약으로 넘긴다.
- authored object revision은 기존처럼 사용자 속성 변경을 추적한다. 매 tick dynamic pose 이동은 전부 새 authored revision을 만들지 않는다. V6.3의 captured authored revision 계약을 바꾸지 않는다.
- 현재 tool host Accessibility=false이고 input routes가 거부된다. 화면 capture는 GUI 상호작용 검증을 대체하지 않는다. 권한 우회나 foreground retry를 하지 않는다.
