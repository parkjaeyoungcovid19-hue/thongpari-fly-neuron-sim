# V7.1 기존 뉴런 관측 경로 감사

2026-10-08 · 범위: 기존 SpikeBus/MetalSim/BrainSignals의 출처·단위·EMA·분모. V7 전체 완료 또는 V7.2 정확 선택 stream 구현이 아니다. [V6 완료](V6_COMPLETION_REPORT.md)를 확인한 뒤 이 단계에 착수했다.

## 출처 계약

```
LIF threshold
 ├─ spikeCount + full spikeList + atomic groupCounts → MotorReadout / rate EMA / telemetry
 └─ 32 sample slots (last writer wins) → 최대 12/ms → SpikeBus(256) → frame 최대 6 + surviving GF → wall-time halos
```

**반짝임은 sampled presentation, 발화율은 exact simulated counts에서 계산한 추정 rate**다. 시뮬레이션 모델을 측정한 것이며 실물 파리의 신경 기록·감정·생각 측정이 아니다. “exact”는 count 출처를 뜻하며 EMA가 timestamped spike trace라는 뜻이 아니다.

## 실제 집계와 rate

정본: [LIF.metal](../../LIF.metal), [MetalSim.swift](../../MetalSim.swift). 각 neural step은 simulation time 1 ms. threshold를 넘은 뉴런은 전체 `spikeList`에 들어가고 `spikeCount`/자기 nonzero group tag의 atomic histogram에 정확히 1회 포함된다. 전파는 이 전체 목록을 사용한다. GPU 종료 후 각 step의 histogram을 순서대로 접는다.

- `x_t = spike_count_t × 1000 / member_count`: **Hz/neuron**, 전체 합계 Hz가 아니다.
- `r_t = r_(t-1) + (x_t − r_(t-1)) / 120`. `alpha=1/120`, 초기값 0, simulation step마다 갱신. EMA 유효 tau는 `−1 ms/log(119/120) ≈ 119.50 ms`; 고정 120 ms 직사각 창이 아니다.
- pause에서 step이 없으면 rate도 유지. wall frame/CSV 행 간격을 집계 창으로 해석하지 않는다. reset은 EMA와 누적 count를 초기화. 시작 직후 0은 warm-up 영향을 받는다.
- 각 분모는 runtime membership 수이며 실제 구현은 `max(1,N)`을 쓴다. **N=0일 때 출력 0은 지원되는 측정 0의 증거가 아니다.** 현재 shipped data 그룹은 독립 CPU membership과 일치하고 전부 비어 있지 않음을 audit test에서 확인했다. future registry는 빈 그룹/ID mismatch를 unsupported로 표시해야 한다.

| 현재 readout | 정확 histogram membership / 분모 | 단위·평활·특징 |
|---|---|---|
| `ratePop` | 전체 N=139255 | Hz/neuron, 공통 EMA |
| `rateLoom` | role LC4+LPLC2 양측 합계, 314개 | Hz/neuron, 공통 EMA |
| `rateDNaL / R` | role DNa01+DNa02, side==1 왼쪽 2개 / 그 외 오른쪽 2개 | Hz/neuron, 공통 EMA |
| `rateMDN` | role MDN, 4개 | Hz/neuron, 공통 EMA |
| `rateFwd` | role DNp09, 2개 | Hz/neuron, 공통 EMA |
| `rateGroom` | role DNg11, 6개 | Hz/neuron, 공통 EMA |
| `rateEscW` | role escw 6개 (기존 annotation DNp02/04/11) | Hz/neuron, 공통 EMA |
| `rateFoodOdorL / R` | type ORN_DM1+ORN_VA2, 왼쪽69 / 오른쪽66개 | Hz/neuron, 공통 EMA |
| `rateThermoWarm` | type TRN_VP2, 7개 | Hz/neuron, 공통 EMA |
| `rateThermoCool` | type TRN_VP3a+TRN_VP3b, 9개 | Hz/neuron, 공통 EMA |
| `rateWindC / E` | type prefix JO-C/JO-E + outgoing CSR row 존재, 56/363개 | Hz/neuron, 공통 EMA |
| `rateSugarGRN / rateMN9` | 기존 identified root IDs, role/receptor tag와 중복되지 않는 `tasteTagSugar/MN9` | 아래 multiplex 계약 |
| `GF` | role GF 2개 histogram >0을 latch | Boolean 사건, rate/EMA 아님 |

1 neuron에 histogram tag는 하나다. role이 receptor tag보다 우선한다. receptor 입력 목록과 histogram denominator 목록은 별도로 만들기 때문에 향후 데이터에서 role/type 중복이 생기면 분모가 달라질 수 있다. shipped neuron binary hash `c48bd4a0ab61dc912b82832720d456854b11b6b12f872b25c769b4e11fe48e6a`, synapse binary hash `8989e0b9b231654046c5726c92f5c825df1b0002aca4ed84b18dcaa76ed8c14b`. 이번 데이터에서는 independent `RefSim.groupOf`와 실제 denominator 목록의 set equality를 검사했다. 중첩 group registry를 구현한 것은 아니다.

미각은 기본 MetalSim에서 opt-in off, Lab owner는 on으로 설정한다. simulation time 32 ms씩 sugar GRN/MN9를 번갈아 slot15에 태그한다. 자기 창에서만 count와 EMA가 갱신되고 다른 창에서는 rate가 그대로 유지된다. tau는 **집계한 step 약119.5 ms**, 전체 simulation time으로는 약239 ms에 해당하며 연속 1 kHz trace가 아니다. `tasteSpikes`와 `tasteSampledMs`는 마지막 reset 이후 **covered ticks만**의 정확 누적값이다. covered mean=`spikes×1000/covered_ms/tagged_members`; 전체 시간으로 나누거나 측정하지 않은 창을 0으로 채우면 안 된다. Lab sugar 입력은 별도의 modeled contact/current 경로이며 readout tag는 신경 dynamics를 바꾸지 않는다.

## BrainSignals 모든 지표

정본: [Sim.swift](../../Sim.swift), [MotorReadout.swift](../../MotorReadout.swift), [main.swift](../../main.swift). 추가 EMA는 아래 DNa baseline뿐이다. 각 입력 rate의 분모·평활은 위 표를 따른다.

| 필드 | 단위 / 현재 계산 | 출처와 해석 한계 |
|---|---|---|
| `escape` | Boolean, `consumeGF()` | 마지막 consume 이후 1개 이상 GF exact spike latch. consume는 latch를 지우므로 read-only 조회로 부르면 안 됨 |
| `nervous` | dimensionless 0–1, clamp(rateLoom/115) | 모델 위협 관련 지표; 공포 측정 아님 |
| `turnBias` | dimensionless −1…1, clamp((rateDNaL−rateDNaR−baseline)×.04) | rad/s가 아님. Python controller가 자신의 gain/limit으로 body 회전 명령으로 변환 |
| `backward` | Boolean, rateMDN>60 Hz/neuron | 운동 명령 threshold, 실제 뒤로 움직였다는 관측 아님 |
| `walkDrive` | dimensionless 0–1.3, clamp((rateFwd−10)/33) | DNp09에서 계산한 controller input |
| `groomDrive` | dimensionless 0–1.5, clamp(rateGroom/5) | DNg11에서 계산한 controller input |
| `wingDrive` | dimensionless 0–1.3, clamp(rateEscW/10) | escape/wing controller input; 현재 body unsupported 부분 있음 |
| `arousal` | dimensionless 0–1, clamp(ratePop/10) | 전체 평균 rate의 모델 지표; 실제 정서/각성 직접 측정 아님 |
| `tempo` | dimensionless multiplier, labTempoOverride ?? ambientTempo | 온도 모델 또는 Mac thermal state 기반 기본 tempo. spike-derived measurement가 아님 |
| `sleep` | Boolean ambientSleepy | clock/idleness rule, deterministic session은 시작 값 고정. 신경에서 수면 상태를 추론한 값 아님 |

DNa baseline: `b += (diff−b) × min(1, dt/8)` (~8 s adaptation). interactive는 render-derived wall dt(최대 .05s), deterministic은 fixed quantum .02s를 넣는다. 기본 rate EMA의 neural simulation time과 구분한다. `SignalBuilder.make(sim)`은 GF latch를 소비하므로 단순 display getter가 아니다. `brainSignalsAvailable=false`(paused/미실행)일 때 카드의 model index는 결측이고 rate 카드의 마지막 값은 유지 가능하다.

## sampled 시각화가 잃는 정보

정본: [Sim.swift SpikeBus](../../Sim.swift), [MetalSim.swift sample fold](../../MetalSim.swift), [BrainView.swift](../../BrainView.swift).

1. GPU는 noise와 같은 hash의 bits3–7로 32 sample slot을 고른다. 같은 slot의 마지막 writer만 남아서 neuron별 누락과 선택의 실행 순서 의존성이 있다. 일정 비율의 unbiased 표본이라는 보장이 없다.
2. Swift는 slot index 순서로 최대12개/ms만 전달한다. 모든 GF spike를 여기서 확보하지 못한다.
3. SpikeBus는 최대256 events, 넘치면 오래된 이벤트를 조용히 버린다. session/epoch/sequence/neural tick/dropped counter가 없다. `popAll`은 표시 큐만 소비한다.
4. BrainRenderDriver는 frame당 일반 flash 최대6개와 **여기까지 살아남은** GF 이벤트를 표시한다. pool96을 재사용하며 GF가 무조건 보존된다는 보장은 없다.
5. 일반 halo .36s, GF .7s는 wall-time SceneKit fade다. pause 동안 회전/halo가 보이거나 사라지는 것은 새 neural step이 아니다. click ring/`--brainshot` preview의 synthetic flashes 역시 exact 관측이 아니다.

따라서 이 경로로 raster·발화 횟수·정확한 latency·무반응 판정을 만들 수 없다. GF flash가 안 보였다고 escape latch가 없었다고 결론 내리지 않는다. rate graph와 sampled flash 개수를 맞추려 하지 않는다.

## 변경과 확인

- Brain tab에 항상 보이는 “표본 반짝임 — 횟수·시간 불완전” 안내, section/AX label/독립 창 제목에 sampled 출처. 클릭이 직접 자극이라는 기존 행동도 명시. **기본 클릭을 읽기 선택으로 바꾸는 V7.3은 아직 구현하지 않음.**
- Data와 activity cards 단위 Hz/뉴런, 일반 EMA와 미각 coverage 계약을 설명. Sim의 turnBias rad/s 주석과 sampler의 order-independent 주석을 정정. kernel·rate equation·motor mapping 변경 없음.
- `--observationaudittest`: current denominator ↔ independent CPU membership, full spike list에서 그룹 count 재집계, full population EMA 재계산, 같은 seed의 관측/무관측 엔진을 30 ms 비교. 3,000 reads와 display drain 전후 external input·membrane·refractory·spike/count/time 불변. overflow에서 실제 이벤트 손실 재현, display drain 후 exact GF latch 보존·consume는 파괴적임 확인.
- 기존 `--gpucheck`의 독립 CPU 기준과 `--simtest`/`--behaviortest`로 계산 의미 불변 재검증. data 검사는 binary hashes/CSR를 확인(`--no-parquet`: parquet 재대조는 명시적으로 제외).

30 simulated ms 시험은 full count139개, display sample100개로 차이를 실제로 확인했다. 별도400개 표시 fixture는144개가 유실되고 마지막256개만 유지되었다.

실제 명령/exit/log·GUI 캡처는 [V7.1 진행표](V7_PROGRESS.md)와 [검증 기록](../../notes/validation/v7-1-2026-10-08/README.md). 후속 V7.2의 timestamped exact primitive·loss capability·dataset registry·사건 전후 buffer는 아직 없다.
