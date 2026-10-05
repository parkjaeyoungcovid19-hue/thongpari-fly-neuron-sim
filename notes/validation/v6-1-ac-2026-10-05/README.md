# V6.1 TCP 성능 AC 전원 재측정 — 2026-10-05 21:43 KST

## 판정

**PASS.** 이전 FAIL(22.8 Hz)은 배터리·저전력 모드 측정 때문이었다는 추정을 확인했다. 코드는 V6.1 측정 때와 같다(HEAD 7990674 + 같은 미커밋 변경, 바이너리 18:17 빌드). 이전 증거는 [v6-1-2026-10-05](../v6-1-2026-10-05/README.md)에 그대로 남겼다.

## 조건

- `pmset -g batt`: AC 전원, 82%, 충전 안 함(AlDente 충전 제한). `lowpowermode 0`. 기록: [측정 전](env-before.txt), [측정 후](env-after.txt)
- 부하 평균 약 3.3(Claude 앱과 WindowServer). 열 경고 없음.

## 결과

| 검사 | 결과 |
|---|---|
| fresh real-headless `--bridgeloop` ([실행기](run_real_gate.py)) | **[PASS](bridgeloop-real.log)**: body 38.3 Hz, max gap 35 ms, sim/wall 0.773 ([기록](performance-result.json)) |
| manifest A/B 3회씩 ([실행기](ab_gate.py)) | [기록](ab-manifest-tcp.txt) — 아래 표 |

| 회차 | manifest 포함 | manifest 제거 |
|---|---|---|
| 0 | 38.1 Hz · gap 35 ms · 0.781 | 38.1 Hz · gap 35 ms · 0.797 |
| 1 | 38.1 Hz · gap 35 ms · 0.793 | 38.1 Hz · gap 35 ms · 0.780 |
| 2 | 37.5 Hz · gap 55 ms · 0.696 | 37.6 Hz · gap 36 ms · 0.791 |

V5 측정(AC, 38.1 Hz)과 같은 수준이고 manifest 유무 차이는 잡음 범위다. 회차 2의 manifest 쪽 gap 55 ms는 1회뿐이며 Hz는 같다.

## 정리

모든 백엔드는 SIGTERM으로 종료했다. 이후 `pgrep`에서 bridge.py와 ThongpariFlyNeuronSim은 없었고 17841 포트에도 listener가 없었다.

## 범위

headless TCP만 측정했다. GUI 렌더링 중 live 성능(이전 배터리 상태에서 9–12 Hz)은 AC 전원에서 다시 측정하지 않았다. 이 측정에는 사용자 확인이 필요하다.
