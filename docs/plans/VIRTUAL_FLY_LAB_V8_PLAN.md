# Virtual Fly Lab V8 — 외부 입출력 모듈 장착 기반

작성: 2026-09-13 · 상태: **V8.1–8.3 구현 / V8.4–8.7 PLANNED** (갱신 2026-10-12)

선행: **V7 완료 후에만 착수**. 병렬로 다음 버전 기능을 구현하거나 버전 순서를 바꾸지 않는다.

[전체 순서](VIRTUAL_FLY_LAB_ROADMAP.md) · [공통 사용자 경험·계약](INTERACTIVE_FLY_SANDBOX_PLAN.md) · [공통 실행·검증 규칙](IMPLEMENTATION_PLAYBOOK.md)

## 1. 이번 버전의 단 하나의 결과

나중에 오버워치·레이싱·비행기게임 같은 외부 환경의 입력/출력을 연결할 수 있는 확장 호스트를 만든다. 실제 게임 모듈은 만들지 않는다.

## 2. 시작 전 반드시 확인할 것

V7 관측 API 및 V4 clock/epoch 계약이 안정적이어야 한다.

1. 저장소 루트에서 git status와 이전 버전 완료 보고서를 읽는다. 미커밋 사용자 변경을 보존한다.
2. 이전 보고서의 자동 검증/real backend/GUI 검증을 따로 확인한다. 실패를 무시하고 진행하지 않는다.
3. 아래 신규 파일은 설계 후보다. 같은 책임의 파일이 이미 있으면 그것을 확장하고 중복 구현하지 않는다.
4. API는 현재 설치 source로 확인한다. 아래 타입명은 새 계약 제안이며 이미 존재하는 심볼로 가정하지 않는다.

## 3. 수정할 파일과 책임

| 파일 | 책임 |
|---|---|
| `ModuleRegistry.swift (신규)` | descriptor 등록/버전·capability 검증 |
| `ExternalIOProtocol.swift (신규)` | ObservationFrame/ActionFrame/schema |
| `ExternalIOSession.swift (신규)` | attach/detach/timeout 상태와 output ownership |
| `LabWindow.swift` | 모듈 목록/상태/채널 mapping/test/disconnect |
| `schemas/external-io.schema.json (신규)` | 언어 공통 계약 |
| `fixtures/external-io/ (신규)` | 테스트 전용 loopback/불량 frame; 게임 구현 없음 |

## 4. 데이터 계약 — UI보다 먼저 정의

공통 envelope의 session/epoch/seq/tick과 simulation-owner 규칙을 유지한다. 필수 값 누락/NaN/잘못된 배열 길이는 실패해야 한다. optional telemetry와 필수 control 필드의 허용 정책을 구분한다.

### ModuleDescriptor

module_id/version/api_version, capabilities, observations/actions schema, unit/axis, rates, clock_mode, restore_support, resource budgets.

### ObservationFrame

session/epoch/seq, source_tick/timebase, receive_monotonic_time, typed channels, valid_until, frame reference와 bounded dimensions/format.

### ActionFrame

neural_tick, target_endpoint, decoder_version, continuous/discrete actions, range/unit, expiry, action_id.

### Lifecycle

discovered→validated→attached→ready→running→draining→detached; failure 별도. auxiliary/external_environment mode와 단일 output owner.

## 5. 구현 순서 — 위에서 아래로 실행

각 단계는 해당 출력과 검사 증거를 만든 후 다음 단계로 넘어간다. 전체 파일을 한 번에 새로 쓰는 방식은 피한다.

### 8.1. 채널 계약 먼저 작성

**할 일:** 현재 neural 출력이 제공하는 범위를 열거한다. forward/turn을 FPS aim/fire 등으로 자동 변환하지 않는다. 미래 action 종류는 descriptor의 typed schema로 확장한다.

**완료 출력:** 유효/미지원 schema fixture.

**2026-10-12 구현:** [V8.1–8.3 보고서](../reports/V8_1_3_COMPLETION_REPORT.md). `ExternalIOProtocol.swift`(`external_io.v1`), `schemas/external-io.schema.json`, `fixtures/external-io/`, `--externaliotest`.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.1` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 8.2. 호스트 registry

**할 일:** 설치된 endpoint만 등록하고 descriptor를 런타임 조회한다. 게임 이름별 하드코딩을 추가하지 않는다. 선언형 scene import가 코드를 실행하지 않도록 경계를 유지한다.

**완료 출력:** descriptor에 따른 UI 생성.

**2026-10-12 구현:** 같은 보고서. `ModuleRegistry.swift`, World 페이지 "외부 모듈" 섹션.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.2` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 8.3. 권한 및 제어권 경계

**할 일:** 기본 world와 external_environment 중 출력 대상 한 곳을 선택한다. auxiliary는 관측/자극 채널만 선언대로 연결한다.

**완료 출력:** 동일 몸에 두 controller가 쓰지 않음.

**2026-10-12 구현:** 같은 보고서. `ExternalIOSession.swift`, Coordinator 출력 훅과 `Fly.hold`.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.3` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 8.4. 왕복 데이터 경로

**할 일:** fixture observation→감각 adapter→기존 neural→출력 decoder→fixture action 수신을 연결한다. raw neural injection은 별도 명시 capability만 허용한다.

**완료 출력:** 단순 host echo가 아닌 neural 경로 검증.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.4` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 8.5. clock 협상

**할 일:** lockstep peer만 deterministic mode 허용. wall clock peer는 interactive 표시 및 source/receive 시간 분리한다.

**완료 출력:** 지원 안 되는 deterministic 시작 거부.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.5` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 8.6. queue와 장애 처리

**할 일:** continuous latest-wins/discrete bounded FIFO, action ID 중복 제거, expiry/old epoch 거부를 구현한다. 영상은 별도 bounded transport로 보내고 NDJSON control과 분리한다.

**완료 출력:** 큰 frame/느린 peer가 제어 큐를 막지 않음.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.6` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

### 8.7. 장착 GUI

**할 일:** attach에서 상태/채널/제어권을 보여주고 시험 왕복 결과를 표시한다. detach는 barrier→neutral/release→ACK 또는 실패→분리 순서다.

**완료 출력:** timeout/종료 시 held action이 남지 않음.

**다음 단계 진입 조건:** 이 출력의 정상 사례와 실패/무변경 사례를 확인하고 진행표의 `V8.7` 행에 증거를 남긴다. 검사 실패 시 같은 단계에서 원인을 수정한다.

## 6. 실패·취소·복구

새 연결 준비 실패는 기존 endpoint를 유지한다. output release ACK가 안 오면 외부 peer의 해제를 성공으로 주장하지 않고 세션을 failed 상태로 고정한다.

공통 규칙: 실패한 명령은 applied로 표시하지 않는다. 이전 정상 파일/세션을 먼저 삭제하지 않는다. timeout은 무한 재시도로 숨기지 않는다. UI는 오류 원인과 재시도 가능한 작업을 보여준다. queue drain/ACK가 완료되지 않으면 saved/paused/detached 성공을 추정하지 않는다.

## 7. 이번 버전에서 만들지 않는 것

실제 게임 API/화면 인식/키 입력 자동화/게임별 reward mapper는 만들지 않는다.

## 8. 검증 시나리오 — 실행과 예상 결과

| ID | 실행 방법 | 합격 조건 |
|---|---|
| V8-01 호환성 | 잘못된 버전/단위/axis/필수 capability fixture. | attach 거부, 기존 경로 보존. |
| V8-02 neural 왕복 | 동일 fixture 입력을 연결/미연결 대조로 실행. | 감각/신경/출력 기록 연결, 기대한 decoder 범위 내. |
| V8-03 old/duplicate | old epoch observation, duplicate discrete action. | 상태 변화 없음 또는 기존 ACK, 중복 실행 안 함. |
| V8-04 held input | 연속 action 중 endpoint crash/timeout/detach. | neutral/release 시도와 결과 기록, UI failed 표시. |
| V8-05 resource | 과대 영상/느린 소비/queue overflow. | budget 준수, 제어/UI가 무한 대기하지 않음. |
| V8-06 범위 확인 | 산출 파일 및 설치 모듈 목록 점검. | 실제 오버워치/레이싱/비행기 모듈 0개, fixture만 있음. |

검사 코드는 이 표의 동작과 실패 조건을 검증해야 한다. 구현의 상수를 복사하여 항상 통과하는 테스트를 만들지 않는다. 실행 명령은 공통 playbook에 따라 구현 후 실제 존재하는 test entry를 기록한다. 아직 만들지 않은 테스트 명령을 이미 실행 가능한 것으로 보고하지 않는다.

## 9. 완료 체크리스트

- [ ] 위 구현 단계와 각 출력이 모두 존재한다.
- [ ] schema/단위/상태 소유권과 실제 코드가 일치한다.
- [ ] 버전별 정상·실패 검사와 필요한 기존 회귀가 실제 exit 0이다.
- [ ] 실제 backend와 새 GUI 프로세스의 사용자 동선을 확인했다. headless를 GUI 검증으로 표시하지 않았다.
- [ ] 저장/기록/큐/모듈 상태를 추가했다면 snapshot/cleanup inventory도 갱신했다.
- [ ] 성능 기준 및 실제 측정, unsupported/제약이 Viewer와 문서에 일치한다.
- [ ] 기존 사용자 변경을 보존했고 실행한 프로세스/시험 자원을 정리했다.
- [ ] `docs/reports/V8_COMPLETION_REPORT.md`에 명령/exit/로그/파일/한계/rollback을 남겼다.

## 10. 다음 버전에 넘길 내용

V9에 snapshot 지원 여부와 모듈 동적 state 목록, clock 지원 등급, 장애/해제 정책을 전달한다.

보고서의 마지막에는 완료한 세부 단계 ID, 남은 결함, 재실행 명령, schema 버전, fixture 경로, 실제 GUI 검증 여부를 적는다. V8의 실패가 있으면 다음 버전은 시작하지 않는다. 연구 근거 부족과 코드 결함을 구별하되, 사용자 목표의 미완료를 숨기지 않는다.
