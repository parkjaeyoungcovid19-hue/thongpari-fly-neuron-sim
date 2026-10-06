# 2026-10-06 실제 GUI 검증

판정: **V6 전체 미완료. V6.3 GUI 부분 통과, V6.4 GUI 실패, V6.5 GUI 실패(먹이 감각 위치·오류 안내).** 자동 검사 통과를 GUI 통과로 대체하지 않는다.

사용자 요청에 따라 Codex Computer Use로 실제 패키지 앱을 열고 마우스·키보드·접근성 액션으로 조작했다. 실제 창의 스크린샷과 조작 후 AX 상태를 확인했다. 제품 Swift/Python 소스는 수정하지 않았다. 기존 dirty 변경을 보존하고 패키지와 이 검증 자료만 갱신했다.

## 검증 대상과 조건

- 저장소 HEAD: `a21ca71` + 기존 V6.4/V6.5 dirty 작업. 현재 빌드의 `./package_app.sh` 실행 exit 0.
- 패키지 실행 파일과 실제 AppTranslocation 실행 파일 SHA-256이 동일: `f46988b96bc6fd5112b164d0289cf3bda1a07d6b05dc6c8e979052a4377085e2`.
- 실앱 PID 17517, 앱이 실행한 `bridge.py --flygym-headless` PID 17534. bridge 59916, viewer 59917. 실제 MuJoCo 파리·잔디·물체 영상, 연결 상태 및 몸 데이터 시각 증가 확인. mock 아님.
- 실행 약 20:25–20:50 KST. 배터리 전원 55% 부근에서 시작, 종료 직전 45%. 다크 테마. 최소 창 약 980×640 pt까지 축소해 확인.
- 시작 전 17841 기존 listener 없음. 종료 후 이번 PID 및 59916/59917/17841 listener 없음. 다른 프로세스를 종료하지 않았다.
- 일부 조작 사이 사용자 입력 변화가 감지되어 최신 상태를 다시 읽었다. 관찰하지 않은 중간 입력은 검증 실적으로 세지 않았다.

## 확인한 기능

| 기능 | 실제 결과 | 증거와 범위 |
|---|---|---|
| 실제 세계 표시 | PASS | [01-world.png](01-world.png), 실물 파리와 경기장 표시 |
| 편집 모드·목록 선택·카메라 이동 | PASS | 상자 선택 때 자동으로 화면 중앙으로 이동, 외곽선·핸들 표시. [07-box-selected.png](07-box-selected.png) |
| 캔버스 picking | PASS | 생성한 공을 실제 3D 화면에서 클릭, 선택 ID `gui_sphere`, 거리 27.7 mm. [14-canvas-pick.png](14-canvas-pick.png) |
| 이동 숫자·드래그 | PASS | 상자 X 60→70 Return 적용 #25; X 핸들 드래그로 66.6077 적용 #26. 이후 같은 표시값 Tab/Apply 모두 적용. 내부 전체 정밀도 동등성까지 직접 측정한 것은 아님 |
| 회전 숫자·드래그 | PASS | Z 45° 입력 #38, 핸들 드래그로 85° #39, 실제 영상 회전 |
| 크기 숫자·드래그 | PASS | X 크기 12 #40, 핸들 드래그로 16.6×10×10 #41. [08-box-size-drag.png](08-box-size-drag.png) |
| 상자·공·벽·자동차·함정·먹이 복제/삭제 | PASS | 복제 후 새 ID 선택과 수량 +1, 복제본 삭제 후 수량 -1. #42/43, #57–71. [공](sphere-clone-delete.ax.txt), [벽](gui_wall.ax.txt), [자동차](gui_car.ax.txt), [함정](gui_trap.ax.txt), [먹이](gui_food.ax.txt) |
| 편집 숫자 오류·Escape | PASS | X `abc` 초안이 polling 중 유지, Return에서 숫자 오류·명령 미전송, Escape로 원래 60 복귀 |
| 모드 전환 | 부분 PASS | 관찰/참여/편집 전환, 참여에서 E의 거리 초과 거절, Escape 후 편집 재진입. 실제 held-key 이동·잡은 물체 상태·마우스 잠금 전체 수용은 미확인 |
| 적용 전 pending | PASS | 상자 X 입력 시 적용 전 장면 60 유지 및 조작 비활성, ACK 이후 70으로 이동. 온도 입력 시 현재 25와 보내는 중 35가 분리되고 이후 적용 35·따뜻함 전류 증가 |
| 온도 감각 모드 | PASS | thermosensory 선택 #1, 35°C #2 적용, 따뜻함 전류 약 0.060·TRN 약 25 Hz. [적용 후 AX](temp-applied.ax.txt). `03-temp-pending.png`는 저장 시점상 ACK 전 증거로 사용하지 않음 |
| 바람 세기·방향 | 부분 PASS | 0.60 입력 #3, C/E 전류 표시. 방향 다이얼의 AX 값 변경으로 90°(+Y) #16. 실제 마우스 세기 드래그 및 반복 드래그 마지막 .61 적용. 다이얼의 원형 마우스 궤적은 미확인 |
| puff 중 edit 거절 | PASS | 3000ms 한 번 불기 #22, 세기 변경 #23 `rejected_busy`, 적용값 .61 유지. [05-wind-busy.png](05-wind-busy.png). 끄기 #24 적용, 다만 natural expiry와 겹쳐 puff 도중 즉시 중단 지연은 판정하지 않음 |
| 왼눈 가림 | 부분 PASS | 100% #6 적용, 몸 밝기 L 0.00 / R 약 .54 확인. [초기 환경](02-environment-initial.png). 1초 이내라는 정확한 지연 기준은 미측정 |
| 치즈 놓기·용량 | 부분 PASS | 버튼 #7로 치즈 표시·냄새 증가, 8/8까지 생성 후 9번째 #15 capacity 거절·물체 수 불변. [04-food-capacity.png](04-food-capacity.png). 파리 앞 정확한 15mm 거리까지 독립 측정하지 않음 |
| 전체 초기화 | 부분 PASS | 정지 중 reset_world/reset_body/eyes #54–56 queued, 재개 후 온도25 기록만·바람0 꺼짐·눈0·세계 비움·선택 해제. [13-reset-environment.png](13-reset-environment.png). 이전 오류/ACK 문구 잔존은 아래 F02 |
| 언어 전환 | 부분 FAIL | 온도35·눈가림·바람90 상태 유지, 환경 패널 번역됨. 편집기 일부는 영어로 남음(F03) |
| 좁은 창 | PASS 범위 제한 | 약 980×640 pt에서 캔버스·필드·버튼 조작 가능, 긴 상태줄은 생략 표시. [15](15-window-narrow.png), [16](16-window-minimum.png). 모든 화면·모든 표시 배율 검사 아님 |
| 기록·종료 저장 | PASS | 추가 도구 메뉴의 기록 클릭, 실제 기록 중 표시, 15.66초 뒤 ⌘Q. `metadata.json`, `telemetry.csv` 157행×76열, `events.jsonl` 시작/`application quit` 종료 이벤트. 몸 시각182.145→188.365. [기록 화면](17-recording.png), [AX](17-recording.ax.txt) |

기록 파일: `/Users/apgx/Documents/ThongpariFlyNeuronSimExperiments/experiment-20261006-205010/`. 종료 후 앱/백엔드 PID가 사라지고 listener가 없음을 확인했다. 기록 파일을 삭제하지 않았다.

## F01 — P1: 경사로 실제 기울기가 편집기에 전달되지 않음

**증거 수준: 실제 GUI 재현 + 생산 코드 경로 확인.**

1. 경사로 생성 #44: 갈색 실제 판은 기본 15°로 경사지지만 기울기 필드가 `0`, 현재값 줄에 기울기 없음, 노란 외곽선은 수평이다. [09-ramp-initial-mismatch.png](09-ramp-initial-mismatch.png).
2. 기울기 `30` Return #45 → 적용됨 30 @t77445. 실제 판은 더 서고 위치가 58.1,0,9.6mm로 변한다. 입력 필드는 다시 0, 외곽선은 여전히 수평이다. [10-ramp-30-mismatch.png](10-ramp-30-mismatch.png), [AX](ramp-30.ax.txt).
3. ∠ 핸들 드래그 #46 → 적용됨 40. 편집기는 이전 30 대신 0을 기준으로 드래그 계산한다. 현재 실제 각도에 상대적인 조작이 아니다.

원인: `LabWindow.swift:2630–2634`의 `updateArenaFromAtomicSnapshot`이 snapshot quaternion에서 yaw만 계산하고 `LabWorldObjectRemote.pitchDeg`를 생략한다. 이 객체 배열이 실제 편집기에 전달된다. `WorldEditor.swift:40` 외곽선/축, `:466` 기울기 필드, `:648` 드래그가 nil pitch를 0으로 처리한다.

영향: 사용자는 실제 각도를 읽지 못하며 gizmo와 판이 어긋난다. 기울기 핸들을 잡았을 때 이미 설정한 각도를 잘못 기준 삼아 변경한다. V6.4 목록 3 실패, 4·5 부분 실패다.

나머지 경사로 검사: 50° 입력은 로컬 `[0,45]` 오류 및 미적용(PASS, [11](11-ramp-invalid.png)); 복제로 4/4 후 추가 복제 `rejected_capacity`·수량 불변(PASS, [12](12-ramp-capacity.png)). 복제 판은 겹쳐 보이며 현재 pitch 읽기 자체가 실패하므로 복제본 각도 보존 전체 GUI PASS로 세지 않는다. 참여 E는 거리가 28.827mm로 reach16을 넘은 거절이라 고정 지형 거절의 증거가 아니다. 파리의 경사로 오르기는 이번 GUI에서 관찰하지 않았다.

수정 후 완료 기준: 같은 atomic quaternion에서 pitch를 정확히 전달하고, 생산 경로의 mapping 회귀 검사 및 기본15→숫자30→상대 드래그→복제→선택 재진입을 실제 창에서 재검증한다. 기존 backend 실물 접촉 검사와 GUI gate를 구분한다.

## F02 — P2: 환경 숫자 오류 안내가 이전 ACK/거절 메시지로 덮임

**증거 수준: 실제 GUI 재현 + 생산 코드 확인.**

온도 35 적용 뒤 `50` Return을 입력하면 10–40 범위 오류가 지속해서 보이지 않는다. 바람 puff busy 거절 뒤 같은 입력을 하면 온도 아래에 이전 바람 거절 영어 문구가 나타난다. 온도는35 유지·새 명령은 전송되지 않았다. [06-invalid-temperature.png](06-invalid-temperature.png).

원인: `EnvironmentPanel.swift:356–363`의 로컬 validation은 올바른 range 오류를 `setStatus`한다. 하지만 매 refresh마다 `:505`가 남아 있는 `queue.message`를 재적용하고, `:509–513`은 현재 `activeGroup`에 그 이전 메시지를 표시한다. 오류 내용을 잘못된 입력 그룹으로 옮긴다.

초기화 뒤에도 이전 오류 또는 초기화 전 ACK tick이 남아 있어 현재 상태와 다른 피드백이 보였다. 실제 적용값 초기화는 성공했으므로 값 reset 실패로 분류하지 않는다.

수정 후 완료 기준: 로컬 오류와 command 상태를 구분하고 command의 대상 그룹/세션에 연결한다. 35 적용→50 오류, wind busy→온도50 오류, 초기화/epoch 변경에서 메시지를 직접 확인한다. V6.5 목록4 FAIL.

## F03 — P2: 언어 전환 후 편집기 정적 문구가 갱신되지 않음

**증거 수준: 실제 화면 + 초기화 코드 확인.**

한국어로 바꾼 뒤 편집기에 `Move`, `Rotate Z`, `Size`, `Tilt`, `Show in view`, `Apply`, `Duplicate`, `Delete`와 영어 안내문이 남는다. [10-ramp-30-mismatch.png](10-ramp-30-mismatch.png)에서 같은 창의 한국어 사이드바와 비교 가능하다. 이전 영문 거절 메시지도 남는다.

`WorldEditor.swift:270–295` 등에서 정적 문구를 생성 시 설정한다. `LabWindow.swift:682–692`의 languageChanged는 UI를 다시 배치하지만 기존 편집기 인스턴스의 문구는 갱신되지 않는다. 새 객체의 번역만 검사하는 테스트는 언어 변경 후 기존 창 경로를 검증하지 못한다.

수정 후 완료 기준: 앱을 재시작하지 않고 English→한국어→English 변경, 선택 및 적용값 유지, 정적 버튼·탭·안내·동적 오류 문구 모두 확인.

## 보완 검증에서 발견한 결함

### F04 — P1: 실제 파리 위치가 후각 계산에서 원점으로 바뀜

**증거 수준: 재실행 실제 GUI + 생산 코드 경로 + 원점 음성 대조.**

재실행에서 파리 x75.4/y−101.3mm 근처, 방향316°에서 ‘파리 앞15mm’로 먹이 생성 #18. 실제 먹이는 x87.315/y−111.141mm에 있다([좌표](25-food-coordinate.ax.txt)). 몸 샘플 x76.0/y−101.7mm에서 표시한 가장 가까운 먹이는 약141.2mm이며, 이후 파리가 x80.6/y−106.2mm로 움직여도 같은 거리다. [생성 직후 AX](24-food-in-front.ax.txt). 이번 재실행에는 먹이가 하나뿐이다. 먹이 배치 자체가 원점으로 간 것이 아니다.

`flygym_bridge/fly_body.py:626–630`의 `_thorax_position()`은 NumPy 배열을 반환한다. `:889–891`에서 그 배열을 `food_odor`에 넘긴다. `flygym_bridge/lab_world.py:154–157`의 `_vec3`는 list/tuple만 허용해 배열을 기본 원점으로 치환하고, `:2134` 후각 계산은 그 치환값을 사용한다. 따라서 실제 파리가 움직여도 원점→먹이 거리를 표시하고 후각 전류/뉴런 입력에도 잘못된 위치를 쓴다.

동일한 위치와 먹이를 사용한 읽기 전용 함수 probe: list 위치의 거리14.7385mm·후각 .314/.324, NumPy 위치의 거리141.3428mm·후각 .00365/.00573. NumPy 결과는 명시적 원점 결과와 정확히 같다. [probe 로그](food-position-probe.log), exit0. 테스트 backend나 앱의 world state를 건드리지 않았다. GUI 좌표와 body 시점의 움직임/반올림 때문에 화면 거리와 probe의 마지막 소수점까지 같다고 주장하지 않는다.

영향: ‘지금 파리 위치의 값’이라는 설명과 실제 감각·뇌 입력이 불일치한다. V6.5 먹이 기능 전체 PASS를 취소한다. 기존 자동 감각 fixture는 Python list를 써서 이 실제 배열 경로를 놓친다. 수정 후 list와 NumPy 실제 위치를 함께 검증하고, 파리가 원점에서 먼 위치에서 먹이 생성→접근/이탈 시 거리·냄새·후각 뉴런의 변화를 실제 창으로 다시 확인해야 한다.

### 사용자 요청 후 재실행 보완 검사

처음 종료는 기록 저장/정상 종료 검증이었다. 사용자 요청 후 Finder로 같은 최신 패키지를 다시 실행해 보완 검사를 수행했다. 그 뒤 agent는 추가 종료 명령을 보내지 않았다(최종 실행 상태는 아래 참조). 새 앱 PID19163, 자식 backend19169, bridge63243/view63244. 첫 실행 종료 확인과 재실행의 활성 프로세스를 혼동하지 않는다.

- 실제 온도 마우스 드래그 왕복: #1–6, 36.5→13.5→34.0 최종 적용. [18-temperature-drag.ax.txt](18-temperature-drag.ax.txt). 빠른 세 번 조작의 응답은 확인했으나 영상 FPS 수치 측정은 아니다.
- 실제 원형 다이얼 오른쪽→위쪽 드래그: #9/10 방향90° 적용, 이후0°로 복구. 입력칸·ACK 확인. 첫 드래그 시도는 레이아웃이 바뀐 위치여서 동작하지 않았으며 성공으로 세지 않았다.
- 바람 세기1/방향0°/더듬이 감각 켬에서 물리 끔→켬→끔. 켬 #13 applied@37805, 파리 x−8.3/y−85.7→x27.0/y−89.3(몸 시각37.805→43.105s), 실제 영상 이동. 끔 #14 applied@44625 뒤에도 뇌가 내리는 걷기 명령으로 움직임은 계속된다. 전체 이동 정지라고 주장하지 않는다. [켜기 전](20-before-physical-on.ax.txt), [켜기 후](21-after-physical-on.ax.txt), [다시 끄기 후](22-after-physical-off.ax.txt). 이 관찰은 독립적으로 걷기 입력을 고정한 1초9mm 정량 검사가 아니다. `21-after-physical-on.png`는 저장 타이밍이 다시 끈 직후이므로 켬 상태 스크린샷 증거로 쓰지 않는다.
- 5초 puff #16 적용@t48685 → #17 stop_wind@t51205 → ‘파리 위치에 없음’, 전류0. 자연 만료보다 약2.5초 먼저 중단 확인. [23-puff-stop.ax.txt](23-puff-stop.ax.txt). 정확한 wall-time 중단 지연은 미측정.
- 두 번째 기록은 GUI ‘멈춤’ 클릭으로 저장됨 확인(CSV554행×76열). `/Users/apgx/Documents/ThongpariFlyNeuronSimExperiments/experiment-20261006-205547/`의 명령13/14 applied 이벤트가 저장됨.
- #19–21 전체 초기화 applied, 온도25 기록만·바람0 꺼짐·눈0·물체0으로 복귀하고 관찰/파리 따라가기 화면으로 돌렸다.
- 최종 관찰 도중 실행 세션 교체를 감지했다. 이전 PID19163/19169 대신 새 PID19679/19680, bridge64169/view64170, 기본 상자1개·먹이0개로 연결 완료됨을 확인했다. [마지막 실행 상태](26-final-running.ax.txt), [화면](26-final-running.png). 이 새 세션의 GUI를 앞선 명령 번호/기록 결과와 합치지 않는다. 이 스크린샷 이후 agent는 종료 명령을 보내지 않았다. 다만 최종 프로세스 재확인에는 PID19679/19680이 사라졌고 CUA 앱 목록도 isRunning=false였다. 같은 시각의 Thongpari crash report는 없었으며 종료 주체/원인은 판정하지 않는다. 화면 저장 시점의 실행과 최종 프로세스 상태를 구분한다.

## 성능과 아직 통과하지 않은 범위

- **이번 배터리 GUI 성능 기준 FAIL:** 시작 이후 body 갱신 약 0–23Hz, 종료 직전 주로19–23Hz, 실시간 배율 약0.40–0.51. GUI 상태줄 자체가 30Hz 미만 경고. 종료 전 한 번의 프로세스 표본은 앱 CPU47.7%, backend112.3%. CPU는 지속 평균이 아니다.
- AC 전원 재측정은 미실행. 기존 README의 배터리 A/B 결과를 현재 GUI의 AC 통과로 쓰지 않는다. 이번 낮은 Hz의 원인을 V6.5 변경으로 단정하지 않는다.
- 실제 영상 refresh FPS, 장시간 안정성·CPU 평균, 저전력/AC 비교, 경사로 위/밖 성능 차이는 미측정.
- stale/revision 충돌/재접속/session 교체/held-object/드래그 중 Escape는 이번 실제 GUI에서 강제로 재현하지 않았다. 자동 검사와 같은 판정으로 합치지 않는다.
- 보완 재실행에서 온도 반복·다이얼 마우스 드래그·puff 만료 전 중단은 확인했다. 바람 물리 on/off의 걷기 입력을 고정한 정량 변위 비교, 정확한 wall-time puff 중단 지연, 눈1초 latency, backend 없는 창, 라이트 테마는 남아 있다.
- 캔버스 일부 기본 물체의 자홍색 및 겹친 객체 목록은 관찰했으나 이번 검증에서 모델 색 계약 위반이나 렌더 버그로 판정하지 않았다. `sandbox_models.py`는 수정하지 않았다.

## 재현 가능한 명령 및 증거

| 명령/검사 | 종료/결과 |
|---|---|
| `./package_app.sh` | exit0, 현재 루트 실행 파일을 패키징 |
| `./ThongpariFlyNeuronSim --worldeditortest` | exit0, 78 PASS, 0 failures. [저장 로그](worldeditortest.log) |
| 패키지 vs 실제 실행 파일 `shasum -a 256` | exit0, 동일한 해시 |
| 실행 중 `ps -p 17517,17534 ...` | 소유 앱과 자식 backend 확인 |
| 종료 후 `ps -p 17517,17534 ...` | 해당 PID 없음 |
| 종료 후 `lsof -nP -iTCP:59916 -iTCP:59917 -iTCP:17841` | listener 없음 |
| CSV/JSON 파일 읽기 | 157 data rows, 76 columns, 시작·종료 이벤트와 메타데이터 정상 파싱 |

[이번 실행 backend 로그](backend-launch.log)는 2026-10-06 11:25:24 UTC, port59916 시작 이후 구간만 추출했다. 기존 전체 bridge.log를 현재 실행 증거로 섞지 않았다. 별도 자동 검사 서버는 실행하지 않았다.

수정 우선순위: **F01 pitch 생산 경로 + F04 실제 후각 위치 → F02 오류·상태 수명 → F03 언어 갱신 → 영향받은 GUI 재검증 → AC/나머지 수용 항목.** 이번 보고서는 결함 수정 완료나 V6 전체 완료를 선언하지 않는다.
