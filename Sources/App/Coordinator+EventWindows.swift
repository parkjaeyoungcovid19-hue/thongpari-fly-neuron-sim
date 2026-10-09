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
}
