import Foundation

// V7.5 event funnel, simulation-thread side. Both helpers run inside an
// `enqueueSimulation` action: the simulation owner holds `simulationLock` and
// no step runs until the action returns, so `sim.simMs` (ticks completed) is
// exact and the first tick the intervention can touch is `simMs + 1`
// (`MetalSim.step` merges a pending stim at the top of its next step with
// `untilMs = simMs + durationMs`). The UI click's wall time is never used.
extension Coordinator {
    /// Direct neural stimulation plus its event. Only call on the simulation thread.
    func applyDirectStimulation(_ indices: [Int], strength: Float, durationMs: Int, kind: String) {
        guard let sim, !indices.isEmpty else { return }
        sim.stimulate(indices, strength: strength, durationMs: durationMs)
        sim.eventWindows.noteEvent(kind: kind, source: .directNeural, appliedTick: sim.simMs + 1,
                                   appliedTickOrigin: "sim_thread: simMs \(sim.simMs) + 1 at application")
    }

    /// A modeled sensory intervention applied locally (no FlyGym bridge): the
    /// drive reaches the sim in the next `advanceNeuralQuantum`, i.e. from
    /// tick `simMs + 1`. With a bridge the backend owns the stimulus and the
    /// event comes from its ACK instead (LabWindow+EventWindows.swift).
    func noteLocalSensoryEvent(kind: String) {
        guard let sim, flyGym == nil else { return }
        sim.eventWindows.noteEvent(kind: kind, source: .sensoryModel, appliedTick: sim.simMs + 1,
                                   appliedTickOrigin: "sim_thread: local modeled drive from simMs \(sim.simMs) + 1")
    }

    /// V7.6 timeline producers. Called from `advanceNeuralQuantum` (the one place
    /// every neural quantum passes, under `simulationLock`) just before the step.
    /// A lockstep session (`exactSteps`) has body clock == brain tick, so its
    /// packet is the body at tick `simMs + exactSteps` and its eye tick is true;
    /// every other packet is `received_at`. Without a backend packet the local
    /// modeled drives are recorded at the first tick they can affect.
    func recordTimelineInputs(_ sim: MetalSim, body: FlyGymBodyFeedback?, exactSteps: Int?,
                              localLoom: (l: Float, r: Float)) {
        if let body {
            sim.timeline.ingestBody(body, tickNow: sim.simMs, lockstepEndTick: exactSteps.map { sim.simMs + $0 })
        } else {
            sim.timeline.recordLocalDrives(tick: sim.simMs + 1, loomL: Double(localLoom.l), loomR: Double(localLoom.r),
                                           windStrength: Double(labWind), windDirectionDeg: labWindDirectionDeg,
                                           touch: Double(labTouchDrive))
        }
    }

    /// The local procedural fly (no backend) after its update for this frame.
    func recordLocalBodyTimeline(_ sim: MetalSim, fly: Fly) {
        let state: Int8
        switch fly.state {
        case .walking: state = 0
        case .idle: state = 1
        case .grooming: state = 2
        case .flying: state = 3
        case .sleeping: state = 4
        }
        sim.timeline.recordLocalBody(tick: sim.simMs, x: Double(fly.pos.x), y: Double(fly.pos.y),
                                     heading: Double(fly.heading), state: state)
    }
}
