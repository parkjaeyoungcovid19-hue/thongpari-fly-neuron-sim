import Cocoa
import SceneKit

extension Coordinator {
    func resetNeuralState(seed: UInt32? = nil) {
        sim?.reset(seed: seed)
        signalBuilder.reset()
        msAccumulator = 0
    }

    func clearLabSensoryReadouts() {
        labOdorDriveL = 0; labOdorDriveR = 0; labTasteSugarDrive = 0
        labThermoWarmDrive = 0; labThermoCoolDrive = 0
        labWindCDrive = 0; labWindEDrive = 0
    }

    func injectWindowLoom(strength: CGFloat, at p: CGPoint) {
        enqueue { c in
            guard let fly = c.flies.first else { return }
            let rel = CGPoint(x: p.x - fly.pos.x, y: p.y - fly.pos.y)
            let dist = max(1, hypot(rel.x, rel.y))
            let f = CGPoint(x: cos(fly.heading), y: sin(fly.heading))
            let crossZ = (f.x * rel.y - f.y * rel.x) / dist
            c.windowLoomL = max(c.windowLoomL, Float(strength * clampf(0.5 + 0.5 * crossZ, 0.12, 1)))
            c.windowLoomR = max(c.windowLoomR, Float(strength * clampf(0.5 - 0.5 * crossZ, 0.12, 1)))
        }
    }

    // a global mouse click: a tap on the fly's substrate -> sensory pathway
    func injectTap(at p: CGPoint) {
        enqueue { c in
            guard let sim = c.sim, let fly = c.flies.first else { return }
            let d = hypot(p.x - fly.pos.x, p.y - fly.pos.y)
            let strength = Float(clampf(1 - d / 520, 0, 1))
            if strength > 0.05 {
                // This is a sensory event, not a direct-neural probe, so apply
                // the same sleep/sensory gate used by the other modeled senses.
                sim.stimulate(sim.sens,
                              strength: (0.15 + strength * 0.35) * sim.sensoryGate,
                              durationMs: 130)
            }
        }
    }

    // Cursor kinematics -> looming drive for each eye of fly #1 + air puff.
    // This is the sensory transduction step; everything downstream of the
    // LC4/LPLC2 population is the real connectome.
    private func computeLoom(fly: Fly, mouse: CGPoint?, dt: CGFloat) -> (l: Float, r: Float, puff: Float) {
        guard let m = mouse else { return (0, 0, 0) }
        if let pm = prevMouse, dt > 0 {
            let v = CGPoint(x: (m.x - pm.x) / dt, y: (m.y - pm.y) / dt)
            mouseVel.x += (v.x - mouseVel.x) * 0.4
            mouseVel.y += (v.y - mouseVel.y) * 0.4
        }
        prevMouse = m
        let rel = CGPoint(x: m.x - fly.pos.x, y: m.y - fly.pos.y)
        let dist = max(20, hypot(rel.x, rel.y))
        // radial approach speed (positive = cursor closing in)
        let approach = -(rel.x * mouseVel.x + rel.y * mouseVel.y) / dist
        // loom ~ rate of angular expansion, attenuated with distance
        var loom = clampf(approach / dist * 6, 0, 1) * clampf(1 - dist / 800, 0, 1)
        loom += clampf((130 - dist) / 130, 0, 1) * 0.5          // hovering close = big object
        loom = clampf(loom + loomOverride, 0, 1)
        // split between eyes by bearing relative to heading
        let f = CGPoint(x: cos(fly.heading), y: sin(fly.heading))
        let rd = CGPoint(x: rel.x / dist, y: rel.y / dist)
        let crossZ = f.x * rd.y - f.y * rd.x                     // >0: threat on the left
        let lw = clampf(0.5 + 0.5 * crossZ, 0.12, 1)
        let rw = clampf(0.5 - 0.5 * crossZ, 0.12, 1)
        let puff = clampf(hypot(mouseVel.x, mouseVel.y) / 1500, 0, 1) * clampf(1 - dist / 500, 0, 1)
        return (Float(loom * lw), Float(loom * rw), Float(puff))
    }

    /// Advances the neural model from one authoritative sensory snapshot. The
    /// caller owns `simulationLock`. Interactive mode passes a render-derived
    /// step count; V4 deterministic mode passes exactly 20 ticks and disables
    /// unscheduled desktop/window input so wall/render timing cannot enter the
    /// experiment timeline.
    func advanceNeuralQuantum(first: Fly?, bodyFeedback: FlyGymBodyFeedback?,
                                      mouse: CGPoint?, dt: CGFloat,
                                      exactSteps: Int?, desktopInputs: Bool,
                                      ambientSleepy: Bool, ambientTempo: CGFloat,
                                      ambientActivity: Float,
                                      bodyMaxAge: TimeInterval = FlyGymBridge.bodyFreshMaxAge) -> BrainSignals? {
        guard let sim else { return nil }

        sim.sensoryGate = ambientSleepy ? 0.55 : 1
        if let fb = bodyFeedback {
            let backend = SensoryModel.backendState(fb)
            labWind = backend.wind
            labWindDirectionDeg = backend.windDirectionDeg
            labWindContinuous = false
            labWindRemainingS = 0
            labTouchDrive = backend.touchDrive
            labTouchRemainingS = 0
        } else if flyGym != nil {
            labWind = 0; labWindContinuous = false; labWindRemainingS = 0
            labTouchDrive = 0; labTouchRemainingS = 0
        } else {
            let localAdvance = Double(dt)
            if !labWindContinuous && labWind > 0 && localAdvance > 0 {
                labWindRemainingS = max(0, labWindRemainingS - localAdvance)
                if labWindRemainingS <= 0 { labWind = 0 }
            }
            if labTouchDrive > 0 && localAdvance > 0 {
                labTouchRemainingS = max(0, labTouchRemainingS - localAdvance)
                if labTouchRemainingS <= 0 { labTouchDrive = 0 }
            }
        }

        let sensory: (l: Float, r: Float, puff: Float)
        if desktopInputs, let first {
            sensory = computeLoom(fly: first, mouse: mouse, dt: dt)
            let decayF = Float(exp(-4 * Double(dt)))
            windowLoomL *= decayF
            windowLoomR *= decayF
        } else {
            sensory = (0, 0, 0)
            // Window/cursor events are wall-time desktop inputs and therefore do
            // not participate in deterministic experiment mode.
            windowLoomL = 0; windowLoomR = 0
        }

        let flyGymLoom = FlyGymSensoryMap.looming(body: bodyFeedback, maxAge: bodyMaxAge)
        sim.loomL = max(sensory.l, windowLoomL, flyGymLoom.l)
        sim.loomR = max(sensory.r, windowLoomR, flyGymLoom.r)
        sim.airPuff = max(sensory.puff, desktopInputs ? Float(typingLevel * 0.30) : 0)

        let odor = FlyGymSensoryMap.foodOdor(body: bodyFeedback, maxAge: bodyMaxAge)
        labOdorDriveL = SensoryModel.odorCurrent(odor.l, sensoryGate: sim.sensoryGate)
        labOdorDriveR = SensoryModel.odorCurrent(odor.r, sensoryGate: sim.sensoryGate)
        sim.batchModeledSensoryDrives {
        sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: labOdorDriveL)
        sim.setModeledSensoryDrive(.foodOdorRight, indices: sim.foodOdorRight, strength: labOdorDriveR)

        // Taste: only the body's labellar contact scalar reaches the root-ID-identified
        // sugar GRNs; odor has no path here. The readout tags the spare histogram
        // slot (sugar GRN / MN9 rates) without touching the dynamics.
        sim.tasteReadout = true
        let sugar = FlyGymSensoryMap.sugarTaste(body: bodyFeedback, maxAge: bodyMaxAge)
        labTasteSugarDrive = SensoryModel.sugarTasteCurrent(sugar, sensoryGate: sim.sensoryGate)
        sim.setModeledSensoryDrive(.tasteSugar, indices: sim.sugarGRN, strength: labTasteSugarDrive)

        let thermal = SensoryModel.thermal(celsius: labTemperatureC,
                                           enabled: labThermosensoryEnabled,
                                           sensoryGate: sim.sensoryGate)
        labThermoWarmDrive = thermal.warm
        labThermoCoolDrive = thermal.cool
        sim.setModeledSensoryDrive(.thermoWarm, indices: sim.thermoWarm, strength: labThermoWarmDrive)
        sim.setModeledSensoryDrive(.thermoCool, indices: sim.thermoCool, strength: labThermoCoolDrive)

        let fallbackHeading = first.map { Double($0.heading) } ?? 0
        let bodyHeading = FlyGymSensoryMap.heading(body: bodyFeedback, maxAge: bodyMaxAge) ?? fallbackHeading
        let windDrive = SensoryModel.wind(strength: labWind,
                                          directionDeg: labWindDirectionDeg,
                                          bodyHeading: bodyHeading,
                                          sensoryGate: sim.sensoryGate)
        labWindCDrive = windDrive.c
        labWindEDrive = windDrive.e
        sim.setModeledSensoryDrive(.windC, indices: sim.windC, strength: labWindCDrive)
        sim.setModeledSensoryDrive(.windE, indices: sim.windE, strength: labWindEDrive)

        let touchDrive = SensoryModel.touch(sourceDrive: labTouchDrive,
                                            sensoryGate: sim.sensoryGate)
        sim.setModeledSensoryDrive(.touchGeneric, indices: sim.sens, strength: touchDrive)

        }

        if let fb = bodyFeedback {
            let fallbackDrive = first.map { Float($0.walkingIntensity) } ?? 0
            let fallbackPhase = first.map { Float($0.gaitPhasePublic) } ?? 0
            sim.gaitDrive = FlyGymSensoryMap.gaitDrive(procedural: fallbackDrive, body: fb,
                                                       maxAge: bodyMaxAge)
            sim.gaitPhase = FlyGymSensoryMap.gaitPhase(procedural: fallbackPhase, body: fb,
                                                       maxAge: bodyMaxAge)
        } else if let first {
            sim.gaitDrive = Float(first.walkingIntensity)
            sim.gaitPhase = Float(first.gaitPhasePublic)
        } else {
            sim.gaitDrive = 0; sim.gaitPhase = 0
        }

        sim.activityScale = (1 - (1 - ambientActivity) * 0.35) * (ambientSleepy ? 0.75 : 1)
        loomOverride = max(0, loomOverride - dt * 1.2)

        recordTimelineInputs(sim, body: bodyFeedback, exactSteps: exactSteps,
                             localLoom: (max(sensory.l, windowLoomL), max(sensory.r, windowLoomR)))
        if let exactSteps {
            sim.step(exactSteps)
        } else {
            msAccumulator += Double(dt) * 1000
            let steps = min(50, Int(msAccumulator))
            msAccumulator -= Double(steps)
            sim.step(steps)
        }

        var s = signalBuilder.make(sim, dt: dt)
        sim.timeline.recordMotor(tick: sim.simMs, s)
        s.tempo = labTempoOverride ?? ambientTempo
        s.sleep = ambientSleepy
        return s
    }
}
