# V6.3 실제 GUI 수용 체크리스트

현재 **입력 검증 미실행**. macOS 도구 호스트 접근성 권한이 없어 정확한 창의 AX tree와 background input 경로가 거절된다. screenshot 관찰만으로 아래 항목을 PASS 처리하지 않는다.

## 실행

저장소 루트에서 `./build.sh` 후 `./ThongpariFlyNeuronSim --lab`. 새 real backend 프로세스를 사용하고, mock이나 offscreen render를 실제 GUI 수용으로 대체하지 않는다.

## 필수 사용자 동선 (모두 pending)

- [ ] 한국어/영어 Inspector가 적절한 단위(mm, deg)를 표시한다.
- [ ] 실제 MuJoCo canvas에서 객체를 선택하고 outline과 Inspector의 ID/형상/값이 일치한다.
- [ ] 객체 선택 해제/삭제/세션 reset에서 이전 outline·pending state가 남지 않는다.
- [ ] 이동 핸들과 수치 입력으로 같은 위치를 요청하면 backend applied 값이 같고 실제 geometry가 옮겨진다.
- [ ] yaw 회전 핸들과 수치 입력이 같은 값으로 적용되며 geometry·접촉 방향이 바뀐다.
- [ ] 크기 핸들과 수치 입력의 결과가 일치하고 실제 collision geometry가 함께 바뀐다.
- [ ] Enter·Tab 기반 수치 편집이 가능하고 드래그만으로 입력을 강제하지 않는다.
- [ ] pending/applied/error를 구분하며 ACK 전에 scene geometry를 applied로 선반영하지 않는다.
- [ ] 잘못된 숫자/범위 밖/단위·형상 오류를 field 경로와 함께 표시하고 scene을 바꾸지 않는다.
- [ ] Escape·선택 변경·pause/reset/disconnect가 drag와 pending lifecycle을 안전하게 정리한다.
- [ ] 복제/삭제 버튼을 실행하고 실제 객체 수·ID·선택 상태가 authoritative world와 일치한다.
- [ ] 잡고 있는 객체·revision 충돌·지원 불가 속성은 명확히 거절/비활성화된다.
- [ ] Participate mode에서 객체 편집과 참여 입력이 충돌하지 않는다.
- [ ] fresh body data 30 Hz 이상, gap·CPU/RSS·UI thread stall·render frame rate·포인터 lock 상태를 기록한다. 실측 없이 성능 gate 완료 표시를 하지 않는다.

## 정리

앱 정상 Quit 후 앱이 소유한 private bridge/view listener와 자식 프로세스가 사라지는지 확인한다. 기존 사용자의 다른 listener나 process는 종료하지 않는다.
