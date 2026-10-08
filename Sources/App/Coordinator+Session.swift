import Cocoa
import SceneKit

extension Coordinator {
    @discardableResult
    func sendSessionControl(_ bridge: FlyGymBridge, action: String, snapshot: LabSessionSnapshot,
                            tick: Int? = nil, mode: LabSessionMode? = nil, resetScope: [String]? = nil) -> Int? {
        bridge.sendSessionControl(action: action, sessionID: snapshot.sessionID, epoch: snapshot.epoch,
                                  simTick: tick ?? snapshot.simTick, mode: mode ?? snapshot.mode,
                                  resetScope: resetScope)
    }

    func sessionSnapshot() -> LabSessionSnapshot {
        var snapshot = labSession.snapshot()
        guard snapshot.mode == .interactive else { return snapshot }
        // Read the bridge before taking our lock so the two locks never nest.
        let body = flyGym?.latestBody(maxAge: .greatestFiniteMagnitude)
        lock.lock(); defer { lock.unlock() }
        if let body, body.simTime.isFinite, body.simTime >= 0 {
            lastInteractiveWorldTick = Int((body.simTime * 1000.0).rounded())
        }
        // Right after a session begin the bridge has no body packet yet; keep
        // the last world time rather than falling back to the begin tick.
        if let tick = lastInteractiveWorldTick { snapshot.simTick = tick }
        return snapshot
    }

    func labCommandSchedule() -> LabCommandSchedule? { labSession.commandSchedule() }

    /// V5.5 game input uses an explicit V4 interactive session when available so
    /// session/epoch rejection remains meaningful outside deterministic runs. The
    /// actual requested tick still comes from the latest atomic backend snapshot.
    @discardableResult
    func ensureInteractivePlayerInputSession() -> Bool {
        interactiveStartLock.lock(); defer { interactiveStartLock.unlock() }
        let current = labSession.snapshot()
        if current.mode == .deterministic { return current.phase != .failed }
        guard let bridge = flyGym, bridge.playerInputV5_5Available else { return false }

        let generation = bridge.connectionGeneration
        lock.lock()
        let alreadyStarted = interactiveSessionStarted && interactiveSessionGeneration == generation
        if interactiveSessionStarted && interactiveSessionGeneration != generation {
            interactiveSessionStarted = false
            interactiveSessionGeneration = nil
        }
        lock.unlock()
        if alreadyStarted { return true }

        simulationLock.lock()
        let tick = sim?.simMs ?? 0
        simulationLock.unlock()
        let start = labSession.beginNew(mode: .interactive, initialTick: tick)
        labSession.markInteractiveRunning(at: tick)
        guard sendSessionControl(bridge, action: "begin", snapshot: start, tick: tick, mode: .interactive) != nil else {
            labSession.fail("failed to queue interactive player-input session begin")
            return false
        }
        lock.lock()
        interactiveSessionStarted = true
        interactiveSessionGeneration = generation
        lock.unlock()
        ensureDeterministicDriver()
        return true
    }

    func noteLabAck(_ ack: LabAck?) {
        guard let ack, ack.ok else { return }
        labSession.noteAppliedCommand(epoch: ack.appliedEpoch, tick: ack.appliedTick)
    }

    func deterministicCapabilityDescription() -> String {
        guard sim != nil else { return "brain simulation unavailable" }
        guard let flyGym else { return "FlyGym bridge disabled" }
        guard flyGym.connected else { return "FlyGym bridge disconnected" }
        guard let hello = flyGym.serverHello() else { return "waiting for V4 capability handshake" }
        guard hello.supportsDeterministicV4 else { return "backend lacks V4 deterministic capability" }
        return String(format: "ready · %.3f ms physics · %d ms quantum",
                      (hello.physicsTimestepS ?? 0) * 1000,
                      FlyGymProtocolV4.experimentQuantumTicks)
    }

    /// Starts a new epoch-1 deterministic session. A new session intentionally
    /// resets brain + body dynamics to tick zero while preserving LabWorld
    /// objects/environment; later resets are epoch transitions inside it.
    @discardableResult
    func startDeterministicSession() -> String? {
        guard let sim, let flyGym else { return "brain/FlyGym unavailable" }
        guard flyGym.deterministicV4Available else { return deterministicCapabilityDescription() }

        lock.lock()
        deterministicEnabled = true
        localNeuralPaused = false
        deterministicSleepy = sleepy
        deterministicTempo = tempo
        deterministicActivity = activity
        lock.unlock()

        let start = labSession.beginNew(mode: .deterministic, initialTick: 0)
        simulationLock.lock()
        resetNeuralState()
        loomOverride = 0
        windowLoomL = 0; windowLoomR = 0
        clearLabSensoryReadouts()
        var initial = signalBuilder.make(sim, dt: 0)
        initial.tempo = labTempoOverride ?? deterministicTempo
        initial.sleep = deterministicSleepy
        deterministicLatestSignals = initial
        simulationLock.unlock()

        guard sendSessionControl(flyGym, action: "begin", snapshot: start, tick: 0, mode: .deterministic) != nil else {
            labSession.fail("failed to queue deterministic begin")
            return "failed to queue deterministic begin"
        }
        ensureDeterministicDriver()
        return nil
    }

    private func ensureDeterministicDriver() {
        let session = labSession.snapshot()
        guard session.mode == .deterministic || [.starting, .pausing, .resuming, .resetting].contains(session.phase) else { return }
        lock.lock()
        if deterministicTimer != nil { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: deterministicQueue)
        deterministicTimer = timer
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.driveDeterministicSession() }
        timer.resume()
    }

    func requestSessionPause() {
        deterministicQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.labSession.snapshot()
            if snap.mode == .deterministic {
                _ = self.labSession.requestPause()
                self.sendPauseControlIfReady()
            } else {
                self.lock.lock(); self.localNeuralPaused = true; self.lock.unlock()
                if self.hasInteractiveSession {
                    _ = self.labSession.requestPause()
                    self.sendPauseControlIfReady()
                    self.ensureDeterministicDriver()
                } else {
                    self.beginOrPauseInteractiveSession()
                }
            }
        }
    }

    func requestSessionResume() {
        deterministicQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.labSession.snapshot()
            if snap.mode == .deterministic {
                guard self.labSession.requestResume(), let bridge = self.flyGym else { return }
                let s = self.labSession.snapshot()
                _ = self.sendSessionControl(bridge, action: "resume", snapshot: s, mode: .deterministic)
            } else {
                guard self.hasInteractiveSession,
                      self.labSession.requestResume(), let bridge = self.flyGym else {
                    // Legacy peers cannot provide the V4 body pause barrier. Keep
                    // the old local-only behavior rather than pretending an ACK
                    // exists, but never use this path for a negotiated V4 session.
                    self.lock.lock(); self.localNeuralPaused = false; self.lock.unlock()
                    return
                }
                let s = self.labSession.snapshot()
                _ = self.sendSessionControl(bridge, action: "resume", snapshot: s, mode: .interactive)
                // Neural time stays frozen until the matching backend running
                // confirmation is accepted in driveDeterministicSession().
                self.ensureDeterministicDriver()
            }
        }
    }

    /// Schedules one logical V4 reset transaction. Body resets are paired with
    /// brain reset because MetalSim.reset() returns neural time to zero; keeping
    /// body time nonzero would immediately violate the lockstep tick invariant.
    /// World-only resets may preserve the current synchronized tick.
    @discardableResult
    func requestDeterministicReset(scopes requested: Set<String>,
                                   after completion: (() -> Void)? = nil) -> Bool {
        let snap = labSession.snapshot()
        guard snap.mode == .deterministic else { return false }
        var scopes = requested
        if scopes.contains("brain") || scopes.contains("body") {
            scopes.insert("brain"); scopes.insert("body")
        }
        deterministicQueue.async { [weak self] in
            guard let self else { return }
            self.pendingDeterministicResetScopes.formUnion(scopes)
            if let completion { self.deterministicResetCompletions.append(completion) }
            let before = self.labSession.snapshot()
            self.resumeAfterDeterministicReset = before.phase != .paused
            _ = self.labSession.requestPause()
            self.sendPauseControlIfReady()
            self.ensureDeterministicDriver()
        }
        return true
    }

    private func performDeterministicResetIfReady() {
        guard !pendingDeterministicResetScopes.isEmpty,
              !deterministicResetControlInFlight,
              labSession.snapshot().phase == .paused,
              let bridge = flyGym else { return }
        let scopes = pendingDeterministicResetScopes
        let resetClock = scopes.contains("brain") || scopes.contains("body")
        let targetTick = resetClock ? 0 : labSession.snapshot().simTick

        simulationLock.lock()
        if let sim {
            if scopes.contains("brain") {
                resetNeuralState()
                loomOverride = 0
                windowLoomL = 0; windowLoomR = 0
                deterministicLatestSignals = BrainSignals()
            }
            if scopes.contains("modeled") || scopes.contains("world") {
                labWind = 0; labWindContinuous = false; labWindRemainingS = 0
                labWindDirectionDeg = 0
                labTemperatureC = 25; labTempoOverride = nil
                labThermosensoryEnabled = false
                clearLabSensoryReadouts()
                labTouchDrive = 0; labTouchRemainingS = 0
                sim.clearModeledSensoryDrives()
            }
        }
        simulationLock.unlock()

        guard let reset = labSession.beginReset(resetTick: targetTick) else { return }
        let backendScopes = scopes.filter { $0 == "body" || $0 == "world" }.sorted()
        guard sendSessionControl(bridge, action: "reset", snapshot: reset, mode: .deterministic, resetScope: backendScopes) != nil else {
            labSession.fail("failed to queue coordinated reset")
            return
        }
        deterministicResetControlInFlight = true
    }

    private func beginOrPauseInteractiveSession() {
        interactiveStartLock.lock(); defer { interactiveStartLock.unlock() }
        guard let bridge = flyGym, bridge.deterministicV4Available else { return }
        lock.lock()
        let started = interactiveSessionStarted && interactiveSessionGeneration == bridge.connectionGeneration
        lock.unlock()
        if started {
            _ = labSession.requestPause()
            sendPauseControlIfReady()
            ensureDeterministicDriver()
            return
        }
        simulationLock.lock()
        let tick = sim?.simMs ?? 0
        simulationLock.unlock()
        let start = labSession.beginNew(mode: .interactive, initialTick: tick)
        labSession.markInteractiveRunning(at: tick)
        guard sendSessionControl(bridge, action: "begin", snapshot: start, tick: tick, mode: .interactive) != nil else {
            labSession.fail("failed to queue interactive pause session begin")
            return
        }
        lock.lock()
        interactiveSessionStarted = true
        interactiveSessionGeneration = bridge.connectionGeneration
        lock.unlock()
        _ = labSession.requestPause()
        if let seq = sendSessionControl(bridge, action: "pause", snapshot: start, tick: tick, mode: .interactive) {
            _ = seq
            labSession.markPauseControlSent()
        }
        ensureDeterministicDriver()
    }

    private func sendPauseControlIfReady() {
        guard labSession.pauseControlReady(), let bridge = flyGym else { return }
        let s = labSession.snapshot()
        if sendSessionControl(bridge, action: "pause", snapshot: s) != nil {
            labSession.markPauseControlSent()
        }
    }

    func driveDeterministicSession() {
        guard let bridge = flyGym else { return }

        if let state = bridge.latestSessionState() {
            _ = labSession.acceptSessionState(state)
        }
        var snap = labSession.snapshot()
        if snap.mode == .interactive {
            lock.lock()
            localNeuralPaused = snap.phase != .running
            if [.running, .paused, .failed].contains(snap.phase) {
                deterministicTimer?.cancel()
                deterministicTimer = nil
            }
            lock.unlock()
            return
        }

        if deterministicResetControlInFlight && snap.phase == .paused {
            deterministicResetControlInFlight = false
            pendingDeterministicResetScopes.removeAll()
            let completions = deterministicResetCompletions
            deterministicResetCompletions.removeAll()
            let shouldResume = resumeAfterDeterministicReset
            resumeAfterDeterministicReset = false
            if shouldResume, labSession.requestResume() {
                let resumed = labSession.snapshot()
                _ = self.sendSessionControl(bridge, action: "resume", snapshot: resumed, mode: .deterministic)
            }
            if !completions.isEmpty {
                DispatchQueue.main.async {
                    for completion in completions { completion() }
                }
            }
            return
        }
        if !pendingDeterministicResetScopes.isEmpty && snap.phase == .running {
            _ = labSession.requestPause()
            sendPauseControlIfReady()
            snap = labSession.snapshot()
        }
        if !pendingDeterministicResetScopes.isEmpty && snap.phase == .paused {
            performDeterministicResetIfReady()
            return
        }

        if let expectedSeq = snap.outstandingStepSeq,
           let result = bridge.latestExperimentStepResult(), result.seq == expectedSeq {
            let startTick = snap.simTick
            if labSession.acceptStepResult(result) {
                var feedback = FlyGymBodyFeedback(result.body)
                feedback.receivedAt = result.receivedAt
                feedback.connectionGeneration = result.connectionGeneration

                simulationLock.lock()
                guard let sim else { simulationLock.unlock(); labSession.fail("brain simulation unavailable"); return }
                if sim.simMs != startTick {
                    simulationLock.unlock()
                    labSession.fail("neural tick \(sim.simMs) != body step start \(startTick)")
                    return
                }
                let fixedDt = CGFloat(LabSession.quantumSeconds)
                let signals = advanceNeuralQuantum(first: nil, bodyFeedback: feedback,
                                                   mouse: nil, dt: fixedDt,
                                                   exactSteps: LabSession.quantumTicks,
                                                   desktopInputs: false,
                                                   ambientSleepy: deterministicSleepy,
                                                   ambientTempo: deterministicTempo,
                                                   ambientActivity: deterministicActivity,
                                                   bodyMaxAge: .infinity)
                deterministicLatestSignals = signals ?? BrainSignals()
                let neuralEnd = sim.simMs
                simulationLock.unlock()

                let accepted = labSession.snapshot()
                if neuralEnd != accepted.simTick {
                    labSession.fail("neural end tick \(neuralEnd) != body end tick \(accepted.simTick)")
                    return
                }
                publishLabTelemetry(first: nil, bodyFeedback: feedback, signals: signals)
            }
        }

        snap = labSession.snapshot()
        if snap.phase == .pausing {
            sendPauseControlIfReady()
            return
        }
        guard snap.phase == .running, snap.outstandingStepSeq == nil else { return }
        // Local neural/sensory mutations are simulation-time commands. Apply
        // them only at a deterministic boundary before reserving the next body
        // quantum, never on a SceneKit/render callback and never after that body
        // quantum has already executed.
        simulationLock.lock()
        let boundaryActions = drainSimulationActions()
        for action in boundaryActions { action(self) }
        simulationLock.unlock()
        guard let reservation = labSession.reserveStep() else { return }
        if !bridge.sendExperimentStep(sessionID: reservation.sessionID,
                                      epoch: reservation.epoch,
                                      seq: reservation.seq,
                                      simTick: reservation.startTick,
                                      signals: deterministicLatestSignals) {
            labSession.cancelStepReservation(seq: reservation.seq)
        }
    }
}
