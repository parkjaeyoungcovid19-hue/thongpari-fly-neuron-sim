# V6 저장·정리·향후 checkpoint 상태 목록

2026-10-08. `.flyworld` schema 1은 **scene_settings**이며 실행 상태 snapshot이 아니다.

| 소유자 | 상태 | 장면 파일 | 세션 교체·종료 / 향후 V9 checkpoint |
|---|---|---|---|
| LabWorld | 객체 ID·shape·variant·position mm·size mm·yaw/pitch deg | 저장 | load 전에 candidate 생성·검사; 실패 시 기존 world 보존 |
| LabWorld | temperature celsius/mode, 지속 wind strength/direction/physical/sensory, 눈 enabled/mask | 저장 | 시간 제한 puff는 지속 바람으로 저장하지 않음 |
| LabWorld | participant spawn 설정 | 저장 | 현재 참여자 qpos/velocity는 불러오지 않음 |
| LabWorld / real body | qpos/qvel, neural/body tick, forces, 렌더·눈 samples, timers, feeding, carry, drive, BB, trap runtime | 저장 안 함 | 장면 교체는 carry·drive·projectile 등 임시 도구 해제. fly DOF/time 유지. 전체 재현은 V9 상태 목록에 포함 |
| MetalSim / SignalBuilder | membrane/refractory, synapse buffers, seed/random streams, EMA, GF latch, DNa baseline, stim queues | 저장 안 함 | scene load에서 reset/rewind하지 않음. V9에서 owner 경계로 snapshot 필요 |
| LabSession / bridge | session ID/epoch/tick, outstanding ACK, command queues, socket generation | 저장 안 함 | load는 일시정지 장벽에서만 적용. wrong session/epoch/future tick/자극 장벽을 우회하지 않음. 새 세션·연결에 이전 요청 전달 안 함 |
| WorldEditHistory | undo/redo 단계·1.5 s coalesce·pending edit | 저장 안 함 | load 성공·세션/epoch/connection 변경에 비움. 실패한 load는 유지. 삭제는 undo 미지원이며 UI에 표시 |
| LabWindow | pendingScene(command ID, URL, generation, session, epoch, wall timeout) | 저장 안 함 | ACK 일치 후 saved 표시. 10 s timeout/세션 교체/재연결 시 취소 표시; 자동 무한 재시도 없음 |
| SceneFile | 임시 sibling `.flyworld-UUID` | 저장 대상 아님 | 내용·hash 검증 후 atomic rename. 실패/취소에 defer로 임시 파일 제거, 이전 정상 파일 보존 |
| SpikeBus / BrainRenderDriver | 최대256 sampled display events, wall-time halo actions, 재사용 pool96 | 저장 안 함 | exact 측정이 아님. 향후 replay는 sampled 표현과 exact 관측 stream을 분리; display queue를 checkpoint에 넣어 neural state로 오인하지 않음 |
| ExperimentRecorder | scene_saved/scene_loaded command ID·applied tick 및 기존 CSV | scene에 포함 안 함 | 기존 stop/finalize를 유지. 장면 기록은 시뮬레이션 snapshot을 의미하지 않음 |

load는 기존 primitive 슬롯만 사용하므로 MJCF topology 재compile은 하지 않는다. `sandbox_models.py` 형상 계약은 import-only로 유지한다. authored solid끼리 겹치는 배치는 편집기 기존 정책에 따라 허용하고, fly·participant spawn을 관통하는 solid는 거부한다.
