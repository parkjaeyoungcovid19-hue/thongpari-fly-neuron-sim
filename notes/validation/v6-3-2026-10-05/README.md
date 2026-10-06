# V6.3 객체 편집 — 구현·검증 기록

2026-10-05. **구현 중 / 직접 GUI 입력 gate 미검증 / V6 전체 미완료**. 이 보고서의 provisional 상태는 실제 build·suite 결과와 새 프로세스 관찰 후 갱신한다.

## 구현 계약과 검토

- [Contract](CONTRACT.md): authoritative geometry, captured revision, session/epoch/tick 경계, drag/numeric 단일 mutation, 복제/삭제 계약과 범위 제외.
- [State inventory](STATE_INVENTORY.md): 소유자·수명·cleanup과 snapshot/ACK 순서.
- [Independent review](REVIEW.md): 구현 중 발견한 결함, owner 전달 및 후속 회귀 증거 상태.
- [사용 가이드](../../../docs/guides/VIRTUAL_FLY_LAB_GUIDE.md): strict inspector와 기존 legacy control 구분.

## 자동 검사

23:08 후보의 [자동 결과](<RESULTS.md>)는 수집됐다. 23:38 이후 다른 세션의 소스 수정·23:41 binary 재빌드에는 그 결과를 전용하지 않는다. [후보별 GUI 인계](<GUI_PARENT_HANDOFF.md>)에 실제 편집 모드 전환·물체 선택 성공과 미검증 범위를 구분했다. 자동 검증을 실제 GUI 수용으로 대체하지 않는다. 실행 위치는 저장소 디렉터리다.

```sh
./build.sh
./ThongpariFlyNeuronSim --worldeditortest
```

추가 backend/model/renderer/bridge 및 sim regression의 정확한 명령·exit·count는 최종 로그로 기록한다. GPU timing 검사는 다른 live Lab과 겹치지 않게 순차 수행한다. pre-existing behavior flake는 첫 실패와 재실행을 둘 다 보존한다.

## 실제 GUI

- [Baseline screenshot](gui-baseline.png)은 **V6.3 이전 binary**의 read-only 관찰이며 새로운 editor의 검증 증거가 아니다.
- [Baseline observation](gui-observation.json), [runtime log](baseline-runtime.log): 기존 앱 관찰과 owned process/listener cleanup 기록. CPU/RSS는 측정하지 않았으며 처리량 로그를 UI frame rate로 부르지 않는다.
- [권한 재확인](permissions-after-user-grant.json): 사용자가 권한 허용 후 계속을 선택했지만 현재 host의 Accessibility/Screen Recording은 여전히 false였다. 사용자 승인과 OS grant를 구분한다.
- [GUI checklist](GUI_CHECKLIST.md): 입력·geometry·negative/no-mutation·성능 항목 모두 실제 새 프로세스 동선 증거가 필요하다.

23:08 후보의 [실제 편집 화면](<gui-candidate-edit.png>)과 다음 fresh AX snapshot에서 toolbar/선택 전환을 확인했다. 이후 exact-window AX route가 동작했으므로 이전 permission false 기록만으로 모든 입력이 계속 차단됐다고 결론내리지 않는다. 최신 빌드의 전체 GUI 검증은 다른 세션과 소스/앱 소유권 조율 후 필요하다. foreground retry, TCC 우회 또는 backend command 주입을 GUI 수용으로 기록하지 않는다. V6.4로 진행하지 않는다.
