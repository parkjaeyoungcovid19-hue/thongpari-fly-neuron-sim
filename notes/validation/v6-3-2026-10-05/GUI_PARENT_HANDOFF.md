# V6.3 GUI 검증 인계 — 후보 빌드 구분

2026-10-05 23:49 KST. V6.3 전체 GUI 수용은 **미완료**. 다른 세션의 최신 구현을 덮어쓰거나 이전 빌드의 테스트 결과를 최신 빌드에 전용하지 않는다.

## 직접 확인한 범위 — 23:08 후보

- 소유한 Lab PID 73777 / 창 49952에서 최신 AX snapshot을 근거로 백그라운드 AXPress를 전달했다. 다음 fresh snapshot에서 편집 모드와 편집 radio selected=true를 확인했다. [편집 화면](<gui-candidate-edit.png>).
- 실제 물체 popup을 열고 `obstacle_box · box` 메뉴에 AXPick를 전달했다. 다음 fresh snapshot s00000009에서 선택 대상 obstacle_box, 이동 X/Y/Z=60/0/5 mm, 적용·복제·삭제 enabled=true를 확인했다. 숫자 적용/드래그/복제/삭제 자체를 검증했다는 뜻은 아니다.
- 닫힌 popup의 set_value는 AX children 없음으로 거절됐다. native popup AXPress/AXPick 경로만 사용했으며 foreground retry, TCC 변경 또는 backend mutation 주입은 하지 않았다.
- [권한 preflight](<permissions-final.json>)의 false는 당시 기록이다. 이후 exact-window AX route가 available이고 위 두 실제 전환이 확인됐으므로 모든 GUI 입력이 계속 차단됐다는 결론으로 사용하면 안 된다.

## 자동 검사와 최신 변경의 경계

- [최종 editor 로그](<world-editor-final.txt>)를 직접 읽어 40 PASS / 0 failures를 확인했다. [build 로그](<build-schedule-fix.txt>)의 완료도 확인했다. [전체 자동 결과](<RESULTS.md>)는 구현 담당의 **23:08 후보**에 대한 보고서다. hidden AppKit 진단은 live GUI 수용이 아니다.
- 소스의 23:38 이후 Focus/placeholder/현지화/현재값 변경 및 23:41:57 binary는 다른 세션의 작업이다. 구현 담당은 후속 수정·jobs가 자기 작업이 아님을 확인했다. 파일 시각만으로 build provenance/새 테스트 통과를 증명하지 않는다.
- [별도 Claude 점검](<CLAUDE_AUDIT.md>)은 realtime ACK boundary 누락/물체 camera focus/UI 문제를 보고했다. 현재 backend에 realtime boundary 처리 helper가 추가된 것은 검색으로 확인했지만, 해당 최신 수정의 serve-loop 회귀 및 live 수치 적용 성공은 이 세션에서 아직 검증하지 않았다.

## 소유한 프로세스 정리

- bash-123은 종료 code 0을 수집했다. PID 73777 및 private ports 59621/59622의 listener가 없는 것을 확인했다. 종료 원인은 이 세션에서 확인하지 못했다. [수집 runtime 출력](<gui-final-runtime.log>)은 마지막 수집 구간이며 전체 startup 기록을 보장하지 않는다.
- 이어 실행한 bash-125도 code 0을 수집했다. backend PID 75274와 private ports 63621/63622 listener가 없는 것을 확인했다. 다른 세션의 새 프로세스나 기본 17841 listener는 건드리지 않았다.
- 두 실행 모두 이 세션이 Quit를 보내기 전에 종료됐다. 현재 소스/앱 공유에 대한 조율 없이 반복 실행하거나 최신 소스를 임의로 되돌리지 않는다.

## 남은 수용 항목

최신 빌드 provenance와 regression 재확인, realtime 정상 ACK, numeric Apply/Return/Escape, move/yaw/size drag, 여섯 shape duplicate/delete, participant→Edit, stale/held/capacity/late ACK 무변경, reset/reconnect, draft/caret/source 보존, camera/Retina/end-on/passthrough 및 지속 성능. [GUI checklist](<GUI_CHECKLIST.md>)의 전체 통과 또는 V6.4 진행을 아직 선언하지 않는다.
