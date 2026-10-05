# Thongpari Fly Neuron Sim — Virtual Fly Lab 사용 가이드

현재 Virtual Fly Lab의 권장 실행 방법은 [저장소 루트 런처](<../../../Thongpari Fly Neuron Sim.command>) 또는 [Virtual Fly Lab 런처](<../../Virtual Fly Lab.command>)를 Finder에서 더블클릭하는 것이다. 최신 소스는 필요할 때 자동 빌드되며 실제 FlyGym/MuJoCo bridge와 하나의 Lab 창을 시작한다.

Lab은 개입을 세 종류로 구분한다.

| 분류 | 현재 가능한 것 | 의미 |
|---|---|---|
| `PHYSICAL` | box/sphere/wall/food marker, object approach, MuJoCo wind force, body/leg touch | FlyGym/MuJoCo 월드 또는 몸에 실제 geometry/force를 적용 |
| `SENSORY-MODEL` | eye cover/flash, food odor, JO-C/E wind, TRN temperature, touch input | 실제 렌더/geometry/환경값을 명시적인 공학적 transduction으로 기존 FlyWire 뉴런에 연결. 감각 gain/transfer function은 측정된 생리값이 아니라 modeling assumption |
| `DIRECT-NEURAL` | GF, DNa, MDN, DNp09, DNg11, escW, 좌/우 LC4/LPLC2, ORN/TRN/JO/HRN 등 | 감각 변환을 건너뛰고 MetalSim의 기존 뉴런 집단에 직접 전류 주입 |

물체 좌표·크기·접근 정지거리는 **mm**, 접근 속도는 **mm/s**, 자극 시간은 **ms**다.

## 실행

가장 먼저 쓸 런처:

```text
Thongpari Fly Neuron Sim.command
```

더블클릭하면 실제 FlyGym/MuJoCo body, whole-brain Metal simulation, Lab UI/telemetry/recording이 함께 시작된다. 열린 Terminal 창은 실험이 끝날 때까지 유지한다. 첫 실제 viewer 실행은 JIT/그래픽 준비 때문에 bridge 연결이 늦을 수 있으며 앱은 연결을 재시도한다.

CLI로 같은 구성을 띄우려면:

```sh
./run_flygym.sh
```

## World 탭

### 물체

shape 메뉴에서 다음 여섯 종류를 만들 수 있다.

| shape | 동작 |
|---|---|
| `box` | 충돌 가능한 상자 |
| `sphere` | 충돌 가능한 공 |
| `wall` | 충돌 가능한 벽 |
| `food` | variant별 물리 형상·냄새·먹이 상태를 backend가 표시 |
| `car` | 주행 가능한 장난감 자동차 |
| `trap` | 다시 설치 가능한 함정 |

기존 **물체 놓기**의 이름·XYZ·크기 및 만들기/옮기기/크기 바꾸기/지우기는 legacy 경로다. 이 경로의 기존 보정(clamping)은 유지되며 아래 V6.3 strict inspector와 구분한다. 현재 기본 precompiled pool은 box/sphere/wall 각각 64, food 8, car 4, trap 2개다.

### V6.3 선택 물체 편집

현재 구현·검증 단계다. [진행 상태](../reports/V6_PROGRESS.md)와 [직접 GUI 체크리스트](../../notes/validation/v6-3-2026-10-05/GUI_CHECKLIST.md)를 구분해 읽는다. 화면 캡처 또는 자동 테스트 통과만으로 클릭·드래그 수용 완료를 주장하지 않는다.

1. **Edit(편집)** 모드로 바꾸고 3D 화면의 backend ray pick 또는 **선택 물체 편집** 목록에서 물체를 선택한다.
2. **이동 / Z 회전 / 크기**를 고른다. XYZ는 mm, X/Y 바닥·Z 위쪽이다. 회전은 Z yaw만 지원한다. box/wall 크기는 물체 local 축 전체 길이 XYZ, sphere/food/car/trap은 descriptor의 scalar S(지름 또는 길이)다.
3. 색과 X/Y/Z/S 라벨이 있는 핸들을 드래그하거나 수치 칸을 입력하고 **적용 / Return**을 누른다. 두 경로는 동일한 descriptor와 captured object revision을 사용한다. 드래그 중에는 초안만 보여 주고 놓을 때 한 번 요청한다.
4. 대기 중에는 mutation control이 비활성화된다. **시뮬레이터** 값과 revision·applied tick 응답이 실제 적용의 근거다. 범위 밖·NaN/inf·held·stale 오류는 적용하지 않으며 오류 위치를 표시한다.
5. **복제**는 원본과 같은 위치에 새 ID를 만든다. 겹치므로 이후 이동한다. pose/shape/size/yaw/food variant만 복사하며 주행·feeding 등 실행 상태는 초기화한다. **삭제**도 revision 검사를 거친다. 실행 취소와 scene 저장은 후속 단계다.

카메라/outline은 최신 snapshot과 requested camera에 기반한다. JPEG stream에는 frame stamp와 depth mask가 없어 순간적인 이미지 불일치나 가림 없는 outline이 있을 수 있다.

### Move an object toward the fly

`Speed (mm/s)`와 `Stop distance (mm)`를 지정한다. `Start approach`는 선택한 물체를 **명령을 받은 시점의 FlyGym fly 위치** 쪽으로 움직이고, 설정한 거리에서 멈춘다. 현재 UI 기본값은 speed `12 mm/s`, stop `8 mm`; Python 허용 범위는 speed `0.1...2000 mm/s`, stop distance `0.5...500 mm`다.

내장 loom preset은 별도 고정값으로 speed `80 mm/s`, stop `8 mm`를 사용한다. 이 접근은 물체를 움직일 뿐 fly의 행동을 직접 명령하지 않는다.

### Reset 4종

| 버튼 | 실제로 초기화하는 것 |
|---|---|
| `Reset world` | LabWorld 물체/approach/wind/touch/flash/eye mask/temperature를 초기화. brain과 body reset은 별도 |
| `Reset body` | FlyGym body/controller pose를 reset. 현재 LabWorld 물체는 보존 |
| `Reset brain` | MetalSim, SignalBuilder, loom override, modeled lab wind 상태를 reset |
| `Reset everything` | brain + modeled stimuli + world + body + 양쪽 eye restore + 다섯 Live Data graph clear |

## Stimuli 탭

### Eye cover

`Cover left eye`, `Cover right eye`와 각각의 restore 버튼이 있다. eye cover는 rendered eye image를 mask하는 `SENSORY-MODEL` 개입이며 LC4/LPLC2에 직접 전류를 주입하지 않는다.

### Eye flash

flash eye는 `left`, `right`, `both` 중 선택하고 intensity `0...1`, duration을 지정한다. full-field flash는 **brightness/flash telemetry만 변화**시키며 `loom_left/right`를 인위적으로 만들지 않는다. 즉 photoreceptor→LC4/GF 경로를 꾸며내지 않는다. Python flash duration은 `1...5000 ms` 범위로 제한된다.

일반 looming은 색상 전용 경로에만 의존하지 않는다. FlyGym의 실제 양안 raw frame에서 작은 전역 translation을 보정한 뒤 outward edge motion을 측정하는 generic optic-expansion 경로가 함께 동작한다. pooling, translation search, edge-motion statistic, threshold/gain, temporal smoothing은 모두 **engineering/modeling approximation**이며 생물학적 retinotopy, 개별 ommatidium/motion-neuron 모델, measured LC4/LPLC2 회로 재구성이라고 주장하지 않는다. contraction, camera pan, full-field flash의 false loom을 억제하는 회귀 테스트가 있다.

### Wind

wind에는 다음을 각각 설정할 수 있다.

- strength `0...1`
- `direction °`
- duration ms
- `physical force`: MuJoCo thorax force 적용
- `sensory input`: Swift brain의 modeled wind input 적용
- `continuous`: duration 종료 대신 계속 유지

`physical force`와 `sensory input`은 독립적으로 켜고 끌 수 있다. `continuous`를 켜면 `Stop wind`로 종료한다. 방향은 Python 쪽에서 0...360°로 정규화된다. sensory ON에서는 generic `sens`가 아니라 실제 FlyWire cell-type label 중 **outgoing edge가 있는 `JO-C*`/`JO-E*` 집단**을 사용한다. 최신 FlyGym body packet의 실제 MuJoCo thorax heading으로 world-space wind를 body-relative opponent scalar로 투영해 C/E drive를 나눈다. 이 방향→current 변환과 gain은 measured antennal/mechanoreceptor transfer function이 아니라 modeling assumption이다.

### Touch

touch target은 현재 다음 9개를 선택할 수 있다.

`thorax`, `head`, `abdomen`, `left_front_leg`, `left_middle_leg`, `left_hind_leg`, `right_front_leg`, `right_middle_leg`, `right_hind_leg`.

UI는 선택한 body target에 물리 impulse를 보내는 동시에 기존 modeled sensory pathway도 자극한다. strength는 `0...1`, UI duration은 최대 60초 입력을 받지만 Python 물리 touch 자체는 `1...1000 ms`로 clamp된다.

### Temperature

세 mode가 있다.

| mode | 효과 |
|---|---|
| `modeled_physiology` | Swift locomotor tempo override를 온도에 따라 바꿈 |
| `environment_only` | 온도 상태/기록만 유지하고 tempo override를 끔 |
| `flywire_sensory` | locomotor tempo를 직접 바꾸지 않고 실제 FlyWire `TRN_VP2`(warm), `TRN_VP3a`+`TRN_VP3b`(cool)에 modeled current를 입력 |

UI 입력 온도는 `10...40°C`로 clamp된다. `flywire_sensory`의 25°C 기준 온도 편차→TRN current 변환은 measured transfer function이 아니라 **MODELING ASSUMPTION**이다. `environment_only`는 neural current를 만들지 않는다. `modeled_physiology`는 이전 V1 locomotor-tempo 모델을 명시적으로 별도 보존한 mode다.

현재 V2의 modeled sensory current gain도 실험용 설정값이다. 구현상 odor는 bilateral concentration에 `0.060`, warm/cool TRN drive는 정규화된 온도 편차에 `0.060`, JO-C/E wind drive는 body-relative opponent split에 `0.055`를 곱한 뒤 sleep sensory gate를 적용한다. 이 숫자들은 receptor physiology에서 측정한 gain이 아니라 안정적인 폐루프 실험을 위한 모델 파라미터다.

`Reset sensory controls`는 Swift modeled wind/temperature override를 초기화하고 Python wind를 정지시키며 양쪽 eye를 복원하고 temperature를 25°C `environment_only`로 돌린다.

## Brain 탭

이 탭은 `DIRECT-NEURAL` 개입이다. strength `0...2`, duration `1...60000 ms` 범위에서 다음 기존 population을 직접 자극할 수 있다.

| population | 관찰 포인트 |
|---|---|
| `GF` | escape command |
| `DNa-left`, `DNa-right` | 좌우 steering asymmetry |
| `MDN` | backward locomotion drive |
| `DNp09` | forward walking drive |
| `DNg11` | grooming 관련 출력 |
| `escW` | escape maneuver/wing 관련 출력 |
| `LC4/LPLC2-left` | 왼쪽 loom population만 직접 자극 |
| `LC4/LPLC2-right` | 오른쪽 loom population만 직접 자극 |
| `LC4/LPLC2` | 양쪽 loom population 직접 자극 |
| `ascend`, `sens` | 현재 모델의 ascending/sensory groups |
| `ORN-food-left/right` | runtime cell-type selection: 실제 `ORN_DM1` + `ORN_VA2`를 side별로 분리 |
| `TRN-warm`, `TRN-cool` | runtime cell-type selection: 실제 `TRN_VP2` warm, `TRN_VP3a` + `TRN_VP3b` cool |
| `JO-C-wind`, `JO-E-wind` | runtime cell-type selection: 실제 outgoing `JO-C*`, `JO-E*` 집단 |
| `HRN-dry`, `HRN-moist` | 실제 `HRN_VP4`, `HRN_VP5`를 **직접 자극**할 수 있는 집단. V2에는 humidity→HRN sensory transduction/UI가 아직 없음 |

이 자극은 eye/기계감각 transduction을 우회하지만 이후 139k-neuron connectome dynamics는 계속 정상적으로 진행된다.

## Live Data 탭

UI는 약 10 Hz로 scalar telemetry snapshot을 받아 다섯 graph를 표시한다. 각 graph는 최신 240 samples만 유지하고, 현재 값이 legend에 숫자로 함께 표시된다. 긴 화면은 스크롤할 수 있다.

| graph | 표시 항목 |
|---|---|
| Neural | `pop`, `loom`, `DNp09`, `MDN`, `DNg11` |
| Sensory | `loom L`, `loom R`, `air`, `gait` |
| FlyWire sensory | food ORN L/R, warm/cool TRN, JO-C/E wind modeled drives |
| Body | `vx×20`, `yaw÷5`, `contact`, `eye loom`, body odor L/R, nearest-food distance |
| Vision | `bright L/R`, `occ L/R`, `exp L/R` |

`Clear live graphs`는 화면의 다섯 그래프만 비운다. 기록 중이라면 telemetry CSV 기록 자체는 계속된다.

## Experiments 탭

### Recording

`Start recording`을 누르면 다음 폴더가 생긴다.

```text
~/Documents/ThongpariFlyNeuronSimExperiments/experiment-YYYYMMDD-HHMMSS/
  metadata.json
  events.jsonl
  telemetry.csv
```

`metadata.json`에는 V2 format/생성 시각과 telemetry/events 파일명을 기록한다. `events.jsonl`에는 lab commands, direct-neural/preset/reset/marker 같은 이벤트가 JSON line 단위로 들어간다. `telemetry.csv`에는 brain/body/vision과 함께 modeled odor L/R, warm/cool TRN drive, JO-C/E wind drive, body odor L/R, nearest-food distance, brightness/occupancy/optic-expansion/flash telemetry가 포함된다.

`Baseline`, `Stimulus ON`, `Stimulus OFF`, `Observation` 버튼은 사람이 trial 구간을 나중에 맞춰 보기 위한 marker다.

### Built-in preset buttons

현재 Experiments 탭에 11개 preset 버튼과 `Replay last preset`이 실제로 들어 있다. physical/sensory preset과 direct-neural preset은 별도 섹션으로 나뉘어 있다.

| 버튼 | 현재 구현 값 |
|---|---|
| `Frontal looming object` | brain/modeled/world/body reset → eyes open → box `(60,0,5)`, size 10 → 80 mm/s로 접근, stop 8 mm |
| `Loom from left` | 위와 같고 box y=`+22` |
| `Loom from right` | 위와 같고 box y=`-22` |
| `Loom with left eye covered` | 위와 같지만 left eye covered, right eye open |
| `Wind puff` | strength `0.7`, direction `0°`, `500 ms`, physical+sensory ON, continuous OFF |
| `Thorax touch` | thorax, strength `0.55`, `150 ms` |
| `GF` | brain reset → GF strength `0.5`, `40 ms` |
| `DNa-left` | brain reset → strength `0.3`, `900 ms` |
| `DNa-right` | brain reset → strength `0.3`, `900 ms` |
| `MDN` | brain reset → strength `0.3`, `600 ms` |
| `DNp09` | brain reset → strength `0.25`, `1200 ms` |

`Replay last preset`은 가장 최근에 누른 preset 이름을 저장했다가 같은 preset을 다시 실행한다. 아직 preset을 실행하지 않았다면 `no preset has been run yet`을 표시한다. `Reset everything`은 Experiments 탭에서 바로 전체 초기화를 실행한다.

loom preset은 현재 `preset_loom`이라는 동일 ID를 사용하며 시작할 때 `reset_world`를 먼저 보내므로 이전 loom object를 제거하고 새로 만든다. `Loom with left eye covered`는 preset 실행 자체에서 마지막에 eye를 자동 복원하지 않는다. 다음 loom preset/reset world/reset all/수동 restore가 eye state를 정리한다.

## Preset JSON

`flygym_bridge/experiment_presets.json`은 현재 `LabWindow.runPreset`에 들어 있는 11개 내장 preset과 값이 맞도록 유지하는 **독립 참조 사양**이다. UI가 런타임에 이 JSON을 읽는 구조는 아직 아니다. `baseline_ms`와 `observe_ms`는 기록 비교를 위한 권장 window이며 버튼이 자동으로 기다리는 시간은 아니다.

검증:

```sh
python3 flygym_bridge/validate_experiment_presets.py
```

## 권장 trial 절차

1. 비교 가능한 시작 상태가 필요하면 `Reset everything`을 누른다.
2. `Start recording` 후 `Baseline` marker를 찍고 1~2초 baseline을 둔다.
3. `Stimulus ON` marker 후 수동 자극 또는 preset 버튼을 누른다.
4. 자극 종료/완료 event 뒤 `Stimulus OFF` marker를 찍고 2~3초 관찰한다.
5. 특이 행동은 `Observation`으로 표시하고 `Stop`으로 기록을 끝낸다.
6. 반복 비교에서는 seed, 자극 값, reset 절차를 동일하게 유지한다.

## Lab 진단 CLI

Swift Lab protocol/population mapping만 socket 없이 검사:

```sh
./ThongpariFlyNeuronSim --labtest
```

실제 TCP lab lane, ack/state/event를 bridge와 함께 검사하려면 첫 Terminal에서 bridge를 띄운다.

```sh
./flygym-venv/bin/python flygym_bridge/bridge.py --mock
```

두 번째 Terminal:

```sh
./ThongpariFlyNeuronSim --labloop
```

`--labloop`는 sphere spawn, wind, eye flash, touch, lab_event 수신, body/world reset까지 실제 TCP 경로로 확인하며 mock 또는 real bridge에서 동작한다.

Python 쪽 Lab 자체 검사도 별도로 있다.

```sh
python3 flygym_bridge/test_lab.py
./flygym-venv/bin/python flygym_bridge/test_lab_real.py
./flygym-venv/bin/python flygym_bridge/test_vision_real.py
```

## 해석 범위

- FlyWire는 brain connectome이며 VNC, 실제 말초 감각 전체, 근육 생리를 제공하지 않는다.
- descending-neuron readout을 FlyGym locomotion controller에 연결하는 부분은 engineering mapping이다.
- eye cover는 rendered eye input mask다.
- flash는 telemetry-only brightness intervention이다.
- food odor는 marker geometry + fly pose에서 계산한 isotropic surface-distance decay와 bilateral split 모델이며 실제 `ORN_DM1`/`ORN_VA2`에 연결된다. plume, wind advection, antennal biomechanics를 재현하지 않으며 taste/reward/feeding/scripted seeking은 구현하지 않는다.
- wind sensory는 실제 `JO-C*`/`JO-E*` 집단을 사용하지만 world wind→antennal current 변환은 measured mechanoreceptor model이 아니다. 기존 generic `sens`(JO-A/B 계열)는 lab wind receptor로 사용하지 않는다.
- `flywire_sensory` temperature는 실제 `TRN_VP2` warm / `TRN_VP3a+b` cool 집단을 사용하지만 temperature scalar→current 변환은 modeling assumption이다.
- generic optic expansion은 실제 rendered pixels에서 계산하지만 생물학적 retinotopy 또는 measured LC4/LPLC2 reconstruction이 아니다.
- V2의 odor/temperature/wind scalar→current gain과 sleep gating은 모두 modeling assumptions이다. 실제 receptor transfer function이나 sensory gain을 측정한 값으로 해석하면 안 된다.
- `HRN_VP4`/`HRN_VP5`는 현재 direct-neural 목록에는 있지만 V2 humidity sensor는 구현되지 않았다.
- direct population stimulation은 실험용 전류 주입이며 자연 자극과 등가가 아니다.

따라서 이 Lab은 절대 생리값 주장보다 **같은 모델·같은 seed·같은 reset 조건에서 한 변수씩 바꾼 조건 비교**에 가장 적합하다.
