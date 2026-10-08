#if DIAGNOSTICS
import Cocoa
func runV4SessionTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check(name, ok, detail) }

    let s = LabSession()
    let start = s.beginNew(mode: .deterministic, initialTick: 0, sessionID: "session-test")
    check("session starts epoch 1 tick 0", start.epoch == 1 && start.simTick == 0 && start.phase == .starting)

    var running = FlyGymSessionStatePacket()
    running.sessionID = "session-test"; running.epoch = 1; running.simTick = 0
    running.seq = 1
    running.mode = .deterministic; running.state = "running"; running.ok = true
    check("begin confirmation enters running", s.acceptSessionState(running) && s.snapshot().phase == .running)

    let first = s.reserveStep()
    check("one outstanding quantum reserved", first?.seq == 1 && first?.startTick == 0 && s.reserveStep() == nil)
    check("command during in-flight quantum targets next boundary", s.commandSchedule()?.requestedTick == 20)

    var body = FlyGymBodyPacket(); body.t = 0.020; body.simDt = 0.020
    var result = FlyGymExperimentStepResultPacket()
    result.sessionID = "session-test"; result.epoch = 1; result.seq = 1
    result.simTick = 0; result.endSimTick = 20; result.ok = true; result.body = body
    check("matching result advances exact 20 ticks", s.acceptStepResult(result) && s.snapshot().simTick == 20)
    check("duplicate result ignored", !s.acceptStepResult(result) && s.snapshot().simTick == 20)
    check("stale begin confirmation is idempotent after tick advances",
          !s.acceptSessionState(running) && s.snapshot().phase == .running
          && s.snapshot().simTick == 20 && s.snapshot().lastError == nil)
    check("command at idle boundary targets current tick", s.commandSchedule()?.requestedTick == 20)

    _ = s.reserveStep()
    check("pause waits for outstanding step", !s.requestPause() && s.snapshot().phase == .pausing)
    result.seq = 2; result.simTick = 20; result.endSimTick = 40; result.body.t = 0.040
    check("in-flight result still completes while pausing", s.acceptStepResult(result) && s.snapshot().simTick == 40)
    check("pause control becomes ready exactly at boundary", s.pauseControlReady())
    s.markPauseControlSent()
    var paused = running
    paused.seq = 2; paused.simTick = 40; paused.state = "paused"
    check("matching pause confirmation seals barrier", s.acceptSessionState(paused) && s.snapshot().phase == .paused)
    check("paused session cannot reserve step", s.reserveStep() == nil)

    check("resume enters resuming", s.requestResume() && s.snapshot().phase == .resuming)
    running.seq = 3; running.simTick = 40
    check("resume confirmation returns running", s.acceptSessionState(running) && s.snapshot().phase == .running)

    check("logical reset increments epoch once", s.beginReset()?.epoch == 2 && s.snapshot().simTick == 0)
    s.finishReset(paused: false)
    check("reset finishes at tick zero", s.snapshot().epoch == 2 && s.snapshot().simTick == 0 && s.snapshot().phase == .running)

    var stale = result
    stale.epoch = 1; stale.seq = 1; stale.simTick = 0; stale.endSimTick = 20
    _ = s.reserveStep()
    check("old epoch result rejected without advancing", !s.acceptStepResult(stale) && s.snapshot().simTick == 0)

    print(suite.failures == 0 ? "ALL V4 SESSION TESTS PASS" : "\(suite.failures) V4 SESSION FAILURES")
    suite.finish()
}

#endif
