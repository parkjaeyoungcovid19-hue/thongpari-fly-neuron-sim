import Cocoa
import SceneKit

extension Coordinator {
    func labApplyWind(strength: Float, directionDeg: Double = 0,
                      durationMs: Int, continuous: Bool = false) {
        enqueueSimulation { c in
            guard c.sim != nil else { return }
            // With a live FlyGym bridge, Python LabWorld is authoritative for
            // stimulus onset/expiry. Do not pre-activate the neural model from
            // the UI command before the backend has actually applied it.
            guard c.flyGym == nil else { return }
            c.labWind = min(1, max(0, strength))
            c.labWindDirectionDeg = directionDeg.isFinite ? directionDeg : 0
            c.labWindContinuous = continuous
            let duration = max(1, min(10_000, durationMs))
            c.labWindRemainingS = continuous ? 0 : Double(duration) / 1000.0
        }
    }

    func labStopWind() {
        enqueueSimulation { c in
            c.labWind = 0; c.labWindContinuous = false
            c.labWindRemainingS = 0
            c.labWindCDrive = 0; c.labWindEDrive = 0
            c.sim?.setModeledSensoryDrive(.windC, indices: c.sim?.windC ?? [], strength: 0)
            c.sim?.setModeledSensoryDrive(.windE, indices: c.sim?.windE ?? [], strength: 0)
        }
    }

    func labApplyTouch(strength: Float, durationMs: Int) {
        enqueueSimulation { c in
            guard c.sim != nil else { return }
            // Same rule as wind: when FlyGym is attached, the body packet's
            // active touch state is the single source of truth.
            guard c.flyGym == nil else { return }
            let s = min(1, max(0, strength))
            // This is a generic modeled startle/touch channel, not a claim that
            // the selected physical body part maps to these JO-A/B-like cells.
            // Unlike direct-neural probes it is sensory-gated and maintained as
            // a continuous modeled current for the requested stimulus window.
            c.labTouchDrive = 0.02 + 0.18 * s
            let duration = max(1, min(1_000, durationMs))
            c.labTouchRemainingS = Double(duration) / 1000.0
        }
    }

    func labSetTemperature(celsius: Double, modeledPhysiology: Bool = true,
                           flywireSensory: Bool = false) {
        enqueueSimulation { c in
            let temp = min(40, max(10, celsius))
            c.labTemperatureC = temp
            c.labTempoOverride = modeledPhysiology ? SensoryModel.locomotorTempo(celsius: temp) : nil
            c.labThermosensoryEnabled = flywireSensory
            if !flywireSensory {
                c.labThermoWarmDrive = 0; c.labThermoCoolDrive = 0
                if let sim = c.sim {
                    sim.setModeledSensoryDrive(.thermoWarm, indices: sim.thermoWarm, strength: 0)
                    sim.setModeledSensoryDrive(.thermoCool, indices: sim.thermoCool, strength: 0)
                }
            }
        }
    }

    func labResetBrain() {
        enqueueSimulation { c in
            c.resetNeuralState()
            c.loomOverride = 0
            c.windowLoomL = 0; c.windowLoomR = 0
            // Brain reset clears neural state, not the physical/environmental
            // experiment. Active wind/touch/temperature are re-applied on the
            // next render step from their preserved environment state.
            c.clearLabSensoryReadouts()
        }
    }

    func labResetModeledStimuli() {
        enqueueSimulation { c in
            c.labWind = 0
            c.labWindContinuous = false
            c.labWindRemainingS = 0
            c.labWindDirectionDeg = 0
            c.labTemperatureC = 25
            c.labTempoOverride = nil
            c.labThermosensoryEnabled = false
            c.clearLabSensoryReadouts()
            c.labTouchDrive = 0
            c.labTouchRemainingS = 0
            c.sim?.clearModeledSensoryDrives()
        }
    }

    func labStimulatePopulation(_ role: String, strength: Float, durationMs: Int) {
        enqueueSimulation { c in
            guard let sim = c.sim else { return }
            let indices = labPopulationIndices(sim, role: role)
            guard !indices.isEmpty else { return }
            sim.stimulate(indices, strength: min(2, max(0, strength)),
                          durationMs: max(1, min(60_000, durationMs)))
        }
    }

    func labTelemetry() -> LabTelemetry {
        lock.lock(); defer { lock.unlock() }
        return labSnapshot
    }

    func publishLabTelemetry(first: Fly?, bodyFeedback: FlyGymBodyFeedback?,
                                     signals: BrainSignals?) {
        var t = LabTelemetry()
        let session = labSession.snapshot()
        t.sessionID = session.sessionID
        t.sessionEpoch = session.epoch
        t.sessionSimTick = session.simTick
        t.sessionMode = session.mode.rawValue
        t.sessionPhase = session.phase.rawValue
        t.sessionPaused = session.isPaused
        t.bodyResultTick = session.lastBodyResultTick ?? -1
        t.temperatureC = labTemperatureC
        t.temperatureMode = labThermosensoryEnabled ? "flywire_sensory"
            : (labTempoOverride != nil ? "modeled_physiology" : "environment_only")
        if let sim {
            t.simMs = sim.simMs
            t.ratePop = Double(sim.ratePop); t.rateLoom = Double(sim.rateLoom)
            t.rateDNaL = Double(sim.rateDNaL); t.rateDNaR = Double(sim.rateDNaR)
            t.rateMDN = Double(sim.rateMDN); t.rateFwd = Double(sim.rateFwd)
            t.rateGroom = Double(sim.rateGroom); t.rateEscW = Double(sim.rateEscW)
            t.loomL = Double(sim.loomL); t.loomR = Double(sim.loomR)
            t.airPuff = Double(sim.airPuff); t.gaitDrive = Double(sim.gaitDrive)
            t.odorDriveL = Double(labOdorDriveL); t.odorDriveR = Double(labOdorDriveR)
            t.thermoWarmDrive = Double(labThermoWarmDrive); t.thermoCoolDrive = Double(labThermoCoolDrive)
            t.windCDrive = Double(labWindCDrive); t.windEDrive = Double(labWindEDrive)
            t.applyReceptorRates(sim)
        }
        t.applyBodyFeedback(bodyFeedback)
        t.applyBrainSignals(signals)
        if let first { t.flyState = String(describing: first.state) }
        lock.lock(); labSnapshot = t; lock.unlock()
    }

    // a window appeared near the fly: a real looming object
}
