// LabSession.swift — Virtual Fly Lab V4 fixed-tick/session state ownership.
//
// This is intentionally narrow: it owns protocol identity, epoch/tick ordering,
// one-outstanding-step lockstep, pause barriers, and next-boundary command timing.
// It does not serialize checkpoints or own future world/plugin state.

import Foundation

enum LabSessionPhase: String, Codable {
    case starting
    case running
    case pausing
    case paused
    case resuming
    case resetting
    case failed
}

struct LabSessionSnapshot: Equatable {
    var mode: LabSessionMode
    var phase: LabSessionPhase
    var sessionID: String
    var epoch: Int
    var simTick: Int
    var quantumTicks: Int
    var outstandingStepSeq: Int?
    var pauseControlSent: Bool
    var lastBodyResultTick: Int?
    var lastAppliedCommandTick: Int?
    var lastError: String?

    var isDeterministic: Bool { mode == .deterministic }
    var isPaused: Bool { phase == .paused }
}

struct LabStepReservation: Equatable {
    let sessionID: String
    let epoch: Int
    let seq: Int
    let startTick: Int
    let quantumTicks: Int
}

struct LabCommandSchedule: Equatable {
    /// Preserve a captured owner boundary; do not rederive/retag after reset.
    static func choose(explicit: LabCommandSchedule?, fallback: @autoclosure () -> LabCommandSchedule?) -> LabCommandSchedule? {
        explicit ?? fallback()
    }
    let sessionID: String
    let epoch: Int
    let requestedTick: Int
}

final class LabSession {
    static let neuralTickSeconds = 0.001
    static let quantumTicks = FlyGymProtocolV4.experimentQuantumTicks
    static let quantumSeconds = Double(quantumTicks) * neuralTickSeconds

    private let lock = NSLock()
    private var mode: LabSessionMode = .interactive
    private var phase: LabSessionPhase = .running
    private var sessionID = UUID().uuidString
    private var epoch = 1
    private var simTick = 0
    private var nextStepSeq = 1
    private var outstandingStepSeq: Int?
    private var outstandingStartTick: Int?
    private var pauseControlSent = false
    private var lastBodyResultTick: Int?
    private var lastAppliedCommandTick: Int?
    private var lastError: String?
    // Session-state packets are exposed by FlyGymBridge as the latest snapshot,
    // so the deterministic driver can observe the same begin/pause/resume ACK on
    // many 1 ms timer callbacks. Treat an already-consumed control sequence as a
    // duplicate instead of re-validating its old tick against newer local time.
    private var lastSessionStateSeq: Int?

    func snapshot() -> LabSessionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    @discardableResult
    func beginNew(mode newMode: LabSessionMode, initialTick: Int = 0,
                  sessionID explicitID: String? = nil) -> LabSessionSnapshot {
        lock.lock(); defer { lock.unlock() }
        mode = newMode
        phase = .starting
        sessionID = explicitID ?? UUID().uuidString
        epoch = 1
        simTick = max(0, initialTick)
        nextStepSeq = 1
        outstandingStepSeq = nil
        outstandingStartTick = nil
        pauseControlSent = false
        lastBodyResultTick = nil
        lastAppliedCommandTick = nil
        lastError = nil
        lastSessionStateSeq = nil
        return snapshotLocked()
    }

    func markInteractiveRunning(at tick: Int) {
        lock.lock(); defer { lock.unlock() }
        guard mode == .interactive else { return }
        simTick = max(0, tick)
        phase = .running
        lastError = nil
    }

    /// Accepts a backend begin/resume/pause confirmation only for this session
    /// and epoch. Tick equality is required for a pause barrier.
    @discardableResult
    func acceptSessionState(_ state: FlyGymSessionStatePacket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.sessionID == sessionID, state.epoch == epoch else { return false }
        if let last = lastSessionStateSeq {
            guard state.seq > last else { return false }
        }
        lastSessionStateSeq = state.seq
        guard state.ok else {
            phase = .failed
            lastError = state.error ?? "backend session error"
            return false
        }
        switch state.state {
        case "running":
            guard phase == .starting || phase == .resuming || phase == .running else { return false }
            guard state.simTick == simTick else {
                phase = .failed
                lastError = "backend running tick \(state.simTick) != local \(simTick)"
                return false
            }
            phase = .running
            pauseControlSent = false
            lastError = nil
            return true
        case "paused":
            guard phase == .pausing || phase == .paused || phase == .resetting else { return false }
            guard outstandingStepSeq == nil, state.simTick == simTick else {
                phase = .failed
                lastError = "pause barrier mismatch backend=\(state.simTick) local=\(simTick)"
                return false
            }
            phase = .paused
            pauseControlSent = true
            lastError = nil
            return true
        default:
            return false
        }
    }

    func reserveStep() -> LabStepReservation? {
        lock.lock(); defer { lock.unlock() }
        guard mode == .deterministic, phase == .running,
              outstandingStepSeq == nil else { return nil }
        let seq = nextStepSeq
        nextStepSeq = nextStepSeq == Int.max ? 1 : nextStepSeq + 1
        outstandingStepSeq = seq
        outstandingStartTick = simTick
        return LabStepReservation(sessionID: sessionID, epoch: epoch,
                                  seq: seq, startTick: simTick,
                                  quantumTicks: Self.quantumTicks)
    }

    func cancelStepReservation(seq: Int) {
        lock.lock(); defer { lock.unlock() }
        guard outstandingStepSeq == seq else { return }
        outstandingStepSeq = nil
        outstandingStartTick = nil
    }

    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        outstandingStepSeq = nil
        outstandingStartTick = nil
        phase = .failed
        lastError = message
    }

    /// Validates identity and exact quantum end before advancing authoritative
    /// session time. A duplicate/stale result is ignored without mutation.
    @discardableResult
    func acceptStepResult(_ result: FlyGymExperimentStepResultPacket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard mode == .deterministic,
              result.sessionID == sessionID, result.epoch == epoch,
              let expectedSeq = outstandingStepSeq,
              let expectedStart = outstandingStartTick,
              result.seq == expectedSeq, result.simTick == expectedStart else { return false }
        guard result.ok else {
            outstandingStepSeq = nil
            outstandingStartTick = nil
            phase = .failed
            lastError = result.error ?? "deterministic step failed"
            return false
        }
        let expectedEnd = expectedStart + Self.quantumTicks
        guard result.endSimTick == expectedEnd else {
            outstandingStepSeq = nil
            outstandingStartTick = nil
            phase = .failed
            lastError = "step end tick \(result.endSimTick) != \(expectedEnd)"
            return false
        }
        simTick = expectedEnd
        lastBodyResultTick = expectedEnd
        outstandingStepSeq = nil
        outstandingStartTick = nil
        lastError = nil
        return true
    }

    /// Returns true when a pause control can be sent now. If one quantum is in
    /// flight, phase becomes `pausing` but the control waits for its result.
    func requestPause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .running || phase == .pausing else { return false }
        phase = .pausing
        return outstandingStepSeq == nil && !pauseControlSent
    }

    func pauseControlReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .pausing && outstandingStepSeq == nil && !pauseControlSent
    }

    func markPauseControlSent() {
        lock.lock(); defer { lock.unlock() }
        if phase == .pausing && outstandingStepSeq == nil { pauseControlSent = true }
    }

    func requestResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .paused else { return false }
        phase = .resuming
        pauseControlSent = false
        return true
    }

    /// A logical reset is one epoch transition. Caller performs the actual local
    /// and backend reset transaction, then confirms the backend at tick zero.
    func beginReset(resetTick: Int = 0) -> LabSessionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard outstandingStepSeq == nil,
              phase == .paused || phase == .running || phase == .failed else { return nil }
        epoch = epoch == Int.max ? 1 : epoch + 1
        simTick = max(0, resetTick)
        nextStepSeq = 1
        outstandingStepSeq = nil
        outstandingStartTick = nil
        pauseControlSent = false
        lastBodyResultTick = nil
        lastAppliedCommandTick = nil
        lastError = nil
        lastSessionStateSeq = nil
        phase = .resetting
        return snapshotLocked()
    }

    func finishReset(paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard phase == .resetting else { return }
        phase = paused ? .paused : .running
        pauseControlSent = paused
    }

    /// Commands issued while a quantum is in flight are scheduled for the next
    /// boundary; otherwise they may apply at the current boundary.
    func commandSchedule() -> LabCommandSchedule? {
        lock.lock(); defer { lock.unlock() }
        guard mode == .deterministic, phase != .failed else { return nil }
        let tick = outstandingStepSeq == nil ? simTick : simTick + Self.quantumTicks
        return LabCommandSchedule(sessionID: sessionID, epoch: epoch, requestedTick: tick)
    }

    func noteAppliedCommand(epoch appliedEpoch: Int?, tick: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard appliedEpoch == epoch, let tick else { return }
        lastAppliedCommandTick = tick
    }

    private func snapshotLocked() -> LabSessionSnapshot {
        LabSessionSnapshot(mode: mode, phase: phase, sessionID: sessionID,
                           epoch: epoch, simTick: simTick,
                           quantumTicks: Self.quantumTicks,
                           outstandingStepSeq: outstandingStepSeq,
                           pauseControlSent: pauseControlSent,
                           lastBodyResultTick: lastBodyResultTick,
                           lastAppliedCommandTick: lastAppliedCommandTick,
                           lastError: lastError)
    }
}

func runV4SessionTest() {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }

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

    print(failures == 0 ? "ALL V4 SESSION TESTS PASS" : "\(failures) V4 SESSION FAILURES")
    exit(failures == 0 ? 0 : 1)
}
