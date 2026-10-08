# Virtual Fly Lab V7 — 정확한 뉴런 관측과 상호작용 타임라인

작성: 2026-09-13 · 갱신: 2026-10-08 · 상태: **V7.1 audit 완료 / V7.2–7.7 PLANNED**

선행: **V6 완료 후에만 착수**. 병렬로 다음 버전 기능을 구현하거나 버전 순서를 바꾸지 않는다.

[전체 순서](VIRTUAL_FLY_LAB_ROADMAP.md) · [공통 사용자 경험·계약](INTERACTIVE_FLY_SANDBOX_PLAN.md) · [공통 실행·검증 규칙](IMPLEMENTATION_PLAYBOOK.md)

## 1. 이번 버전의 단 하나의 결과

모든 상호작용 직후 관련 뉴런 집단의 실제 활동 변화를 같은 시간축에서 설명한다.

## 2. 시작 전 반드시 확인할 것

V6 editor 사건에 event ID/applied tick이 있어야 하고 Viewer가 동일 session 선택을 공유해야 한다.

1. 저장소 루트에서 git status와 이전 버전 완료 보고서를 읽는다. 미커밋 사용자 변경을 보존한다.
2. 이전 보고서의 자동 검증/real backend/GUI 검증을 따로 확인한다. 실패를 무시하고 진행하지 않는다.
3. 아래 신규 파일은 설계 후보다. 같은 책임의 파일이 이미 있으면 그것을 확장하고 중복 구현하지 않는다.
4. API는 현재 설치 source로 확인한다. 아래 타입명은 새 계약 제안이며 이미 존재하는 심볼로 가정하지 않는다.

## 3. 수정할 파일과 책임

| 파일 | 책임 |
|---|---|
| `NeuralObservation.swift (신규)` | 정확 spike/count/rate stream, bounded pre-event buffer |
| `NeuralGroupRegistry.swift (신규)` | dataset/root ID 기반 그룹 정의 |
| `BrainInspector.swift (신규), BrainView.swift` | 관찰 선택과 자극 모드 분리, 검색/raster |
| `InteractionTimeline.swift (신규)` | event 전후 분석과 선택 동기화 |
| `LabProtocol.swift, ExperimentRecorder.swift` | 샘플 시간/손실/event 연결 |
| `MetalSim.swift, GPUCheck.swift (필요 시)` | 정확 집계 경로와 독립 reference 검증 |

## 4. 데이터 계약 — UI보다 먼저 정의

공통 envelope의 session/epoch/seq/tick과 simulation-owner 규칙을 유지한다. 필수 값 누락/NaN/잘못된 배열 길이는 실패해야 한다. optional telemetry와 필수 control 필드의 허용 정책을 구분한다.

### NeuralObservation

session/epoch, start_tick/end_tick, group/root ID, spike_count, member_count, rate_hz_per_neuron, source=exact|sampled, dropped_samples. ID는 JSON string.

### GroupDefinition

group_id, dataset_hash, membership(root IDs/query), labels, evidence_source, evidence_tier, baseline policy, normalization version. 중첩 membership 허용.

### InteractionAnalysis

event_id, applied_tick, sensory_sample_tick, baseline_window, response_window, overlapping_events, neural deltas, motor output, observed body action, validity.

### TraceSelection

individual_id, event_id, selected groups/neurons, time window. 읽기 전용 조회는 stimulation과 별도 API.

## 5. 구현 순서 — 위에서 아래로 실행

각 단계는 해당 출력과 검사 증거를 만든 후 다음 단계로 넘어간다. 전체 파일을 한 번에 새로 쓰는 방식은 피한다.

### 7.1. 기존 관측 audit

**할 일:** SpikeBus 표본 경로와 MetalSim 실제 집계를 추적한다. 모든 현재 BrainSignals 지표의 단위/EMA/분모를 문서화한다.

**완료 출력:** 샘플 시각화와 정확 측정의 출처가 분리됨.

**2026-10-08 완료:** [기존 관측 audit](../reports/V7_OBSERVATION_AUDIT.md), [V7.1 완료 보고서](../reports/V7_1_COMPLETION_REPORT.md). BrainSignals 단위/분모/EMA·GF latch·taste coverage와 sampled loss 경로를 문서화하고 UI 표기를 분리했다. V7.2+는 미착수.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.1` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 7.2. 정확 관측 primitive

**할 일:** 작은 선택 집단으로 실제 spike를 집계하고 CPU 참조와 비교한다. GPU 전체 array를 매 frame 복사하지 않는다. 초기 정확 선택 한도 256을 capability로 노출한다.

**완료 출력:** 한도 안에서 count/rate가 참조와 일치.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.2` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 7.3. 읽기/자극 분리

**할 일:** 기본 BrainView 클릭을 선택으로 바꾸고 명시적 자극 toggle 및 확인 가능한 injection 표시를 만든다. 기존 실험 자극 기능은 유지한다.

**완료 출력:** 선택만으로 extInput 변화 없음.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.3` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 7.4. 기능 그룹 registry

**할 일:** 기존 role의 명확한 역할부터 등록한다. 각성/위협 관련/운동/감각으로 보여주고 unclassified를 남긴다. 욕구/정서 unknown에 임의 수치를 넣지 않는다.

**완료 출력:** membership과 source를 상세 패널에서 조회.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.4` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 7.5. 사건 전후 buffer

**할 일:** simulation time 기준 전 0.5초/후 1초를 기본 설정으로 수집한다. window 부족/중첩/손실을 validity로 기록한다.

**완료 출력:** pause 동안 wall time 때문에 window가 완성되지 않음.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.5` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 7.6. 통합 timeline

**할 일:** event→감각 sample→spike→motor→실제 몸 데이터를 같은 tick으로 연결한다. 실제 sensor 주기 그대로 표시한다.

**완료 출력:** 눈 5Hz를 1kHz 측정처럼 보간하지 않음.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.6` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 7.7. 관측 기반 설명

**할 일:** 숫자/관측 상태로 규칙 기반 문장을 만든다. 직접 물리 힘과 신경 출력의 효과를 구분한다. 데이터 없는 원인/감정을 생성하지 않는다.

**완료 출력:** 무반응/불명확/관측 중도 사용자에게 보여줌.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V7.7` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

## 6. 실패·취소·복구

집계 비용 초과 시 한도를 줄여 표시하고 sampled 결과를 exact로 승격하지 않는다. dataset hash mismatch는 그룹을 비활성화하고 unknown 처리한다.

공통 규칙: 실패한 명령은 applied로 표시하지 않는다. 이전 정상 파일/세션을 먼저 삭제하지 않는다. timeout은 무한 재시도로 숨기지 않는다. UI는 오류 원인과 재시도 가능한 작업을 보여준다. queue drain/ACK가 완료되지 않으면 saved/paused/detached 성공을 추정하지 않는다.

## 7. 이번 버전에서 만들지 않는 것

에너지/갈증/보상 상태 모델과 사람의 생각 문장 생성은 구현하지 않는다.

## 8. 검증 시나리오 — 실행과 예상 결과

| ID | 실행 방법 | 합격 조건 |
|---|---|
| V7-01 정확 집계 | 작은 알려진 spike fixture로 개별/집단 rate 계산. | count와 분모/단위가 정확, 중복 membership 처리 명시. |
| V7-02 관찰 부작용 | 100회 선택/검색/zoom 후 injection log 비교. | 새 stimulation 없음. |
| V7-03 사건 시간 | pause를 끼운 환경 event와 저속 eye sample. | applied tick/sample tick 분리, 가짜 latency 없음. |
| V7-04 결측 | buffer overflow/관측 시작 직후/중첩 사건 주입. | 정확/충분함 표시 해제, 없는 baseline 생성 안 함. |
| V7-05 해석 경계 | 바람 force만 켠 대조와 sensory만 켠 대조. | 몸 밀림을 무조건 신경 의사결정으로 설명 안 함. |
| V7-06 GUI | 사건 선택→활동 카드→root ID→raster→CSV export. | 동일 시간/선택, 실제 측정값 일치. |

검사 코드는 이 표의 동작과 실패 조건을 검증해야 한다. 구현의 상수를 복사하여 항상 통과하는 테스트를 만들지 않는다. 실행 명령은 공통 playbook에 따라 구현 후 실제 존재하는 test entry를 기록한다. 아직 만들지 않은 테스트 명령을 이미 실행 가능한 것으로 보고하지 않는다.

## 9. 완료 체크리스트

- [ ] 위 구현 단계와 각 출력이 모두 존재한다.
- [ ] schema/단위/상태 소유권과 실제 코드가 일치한다.
- [ ] 버전별 정상·실패 검사와 필요한 기존 회귀가 실제 exit 0이다.
- [ ] 실제 backend와 새 GUI 프로세스의 사용자 동선을 확인했다. headless를 GUI 검증으로 표시하지 않았다.
- [ ] 저장/기록/큐/모듈 상태를 추가했다면 snapshot/cleanup inventory도 갱신했다.
- [ ] 성능 기준 및 실제 측정, unsupported/제약이 Viewer와 문서에 일치한다.
- [ ] 기존 사용자 변경을 보존했고 실행한 프로세스/시험 자원을 정리했다.
- [ ] `docs/reports/V7_COMPLETION_REPORT.md`에 명령/exit/로그/파일/한계/rollback을 남겼다.

## 10. 다음 버전에 넘길 내용

V8에 typed observation API, event schema, bounded telemetry budget과 정확성 fixture를 전달한다.

보고서의 마지막에는 완료한 세부 단계 ID, 남은 결함, 재실행 명령, schema 버전, fixture 경로, 실제 GUI 검증 여부를 적는다. V7의 실패가 있으면 다음 버전은 시작하지 않는다. 연구 근거 부족과 코드 결함을 구별하되, 사용자 목표의 미완료를 숨기지 않는다.
