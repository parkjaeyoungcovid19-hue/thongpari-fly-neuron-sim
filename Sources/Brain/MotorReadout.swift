// MotorReadout.swift — V3 boundary for neural population rates -> body commands.
//
// This preserves the V2 SignalBuilder equations and slow DNa adaptation exactly.

import Cocoa

struct MotorReadoutInput {
    var giantFiberSpiked = false
    var rateLoom: Float = 0
    var rateDNaL: Float = 0
    var rateDNaR: Float = 0
    var rateMDN: Float = 0
    var rateFwd: Float = 0
    var rateGroom: Float = 0
    var rateEscW: Float = 0
    var ratePop: Float = 0
}

// Converts sim population rates into body commands. Shared by the app loop and
// tests so both exercise the identical mapping.
final class SignalBuilder {
    private var dnaBaseline: Float = 0

    func reset() { dnaBaseline = 0 }

    static func walkDrive(_ rateFwd: Float) -> CGFloat {
        clampf((CGFloat(rateFwd) - 10) / 33, 0, 1.3)
    }

    static func groomDrive(_ rateGroom: Float) -> CGFloat {
        clampf(CGFloat(rateGroom) / 5, 0, 1.5)
    }

    func make(_ sim: MetalSim, dt: CGFloat) -> BrainSignals {
        make(MotorReadoutInput(
            giantFiberSpiked: sim.consumeGF(),
            rateLoom: sim.rateLoom,
            rateDNaL: sim.rateDNaL,
            rateDNaR: sim.rateDNaR,
            rateMDN: sim.rateMDN,
            rateFwd: sim.rateFwd,
            rateGroom: sim.rateGroom,
            rateEscW: sim.rateEscW,
            ratePop: sim.ratePop), dt: dt)
    }

    func make(_ input: MotorReadoutInput, dt: CGFloat) -> BrainSignals {
        let diff = input.rateDNaL - input.rateDNaR
        // Slow adaptation (tau ~8 s), unchanged from V2.
        dnaBaseline += (diff - dnaBaseline) * Float(min(1, dt / 8))
        var s = BrainSignals()
        s.escape = input.giantFiberSpiked
        s.nervous = clampf(CGFloat(input.rateLoom) / 115, 0, 1)
        s.turnBias = clampf(CGFloat(diff - dnaBaseline) * 0.04, -1.0, 1.0)
        s.backward = input.rateMDN > 60
        s.walkDrive = SignalBuilder.walkDrive(input.rateFwd)
        s.groomDrive = SignalBuilder.groomDrive(input.rateGroom)
        s.wingDrive = clampf(CGFloat(input.rateEscW) / 10, 0, 1.3)
        s.arousal = clampf(CGFloat(input.ratePop) / 10, 0, 1)
        return s
    }
}
