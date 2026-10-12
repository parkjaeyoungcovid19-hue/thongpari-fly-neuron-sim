# Virtual Fly Lab V8 진행표

2026-10-12 갱신. 사용자가 요청한 범위는 **V8.3까지**다. 선행 문서는 [V7 완료 보고서](V7_COMPLETION_REPORT.md)다. V8 전체는 아직 끝나지 않았고, V8.4 이후는 시작하지 않았다.

| 단계 | 상태 | 출력·검사 |
|---|---|---|
| V8.1 채널 계약 | **구현·headless 검증** | `external_io.v1` 계약, JSON schema, fixture를 만들었다. fixture는 유효 2개와 mutation 36건이다. 신경 출력 표는 `BrainSignals`와 대조했다. `--externaliotest`로 검사. [보고서](V8_1_3_COMPLETION_REPORT.md) |
| V8.2 호스트 registry | **구현·headless·GUI 검증** | 설치된 descriptor만 등록하고 데이터로만 읽는다. 거절된 것은 이유와 함께 목록에 남긴다. World 페이지 "외부 모듈" 섹션. GUI T8·T9 PASS |
| V8.3 권한·제어권 경계 | **구현·headless 검증, GUI 부분 확인** | 몸 출력 소유자는 하나다. auxiliary 모듈은 선언한 채널만 쓴다. release 실패 시 failed로 고정된다. 외부 소유 중에는 파리를 hold한다. GUI T10 PARTIAL |
| V8.4 왕복 데이터 경로 | 미착수 | |
| V8.5 clock 협상 | 미착수 | |
| V8.6 queue와 장애 처리 | 미착수 | |
| V8.7 장착 GUI | 미착수 | 외부 소유 중 FlyGym에 남는 마지막 명령(held input)을 여기서 처리 |

실행 명령: `./build.sh && ./ThongpariFlyNeuronSim --externaliotest` (113 checks).
