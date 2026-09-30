// SensoryModel.swift — V3 boundary for engineered source -> neural-drive transforms.
//
// These transforms intentionally preserve the V2 constants and arithmetic. They
// are modeling assumptions layered in front of the unchanged FlyWire/MetalSim
// network; moving them here must not be interpreted as new biological evidence.

import Cocoa

struct LabBackendSensoryState {
    var wind: Float = 0
    var windDirectionDeg: Double = 0
    var touchDrive: Float = 0
}

struct ThermalSensoryDrive {
    var warm: Float = 0
    var cool: Float = 0
}

struct WindSensoryDrive {
    var c: Float = 0
    var e: Float = 0
}

enum SensoryModel {
    /// Translate only the backend's currently active stimulus state into modeled
    /// source scalars. Physical body-part specificity remains in MuJoCo; the
    /// neural touch path is deliberately generic.
    static func backendState(_ fb: FlyGymBodyFeedback?) -> LabBackendSensoryState {
        guard let fb else { return LabBackendSensoryState() }
        let wind = fb.windSensory ? Float(min(1, max(0, fb.windStrength))) : 0
        let touchStrength = min(1, max(0, fb.touchStrength))
        let touch = (fb.touchSensory && touchStrength > 0)
            ? (0.02 + 0.18 * Float(touchStrength)) : 0
        return LabBackendSensoryState(wind: wind,
                                      windDirectionDeg: fb.windDirectionDeg,
                                      touchDrive: touch)
    }

    /// Food concentration -> ORN current. Bounded compressive V2 transform.
    static func odorCurrent(_ concentration: Float, sensoryGate: Float) -> Float {
        let bounded = min(1, max(0, concentration))
        return 0.060 * sqrt(sqrt(bounded)) * sensoryGate
    }

    /// Labellar sugar contact (0..1 from the body model) -> current into the
    /// root-ID-identified sugar GRNs (`MetalSim.sugarGRN`). MODELING ASSUMPTION:
    /// same bounded compressive form as the ORN transform at twice its gain; full
    /// contact drives the GRNs at ~85 Hz in this LIF (0.3 -> ~58 Hz; measured by
    /// --simtest). It is receptor current into
    /// identified neurons, not a claim about what the fly perceives. Odor never
    /// enters here: taste drive exists only when the body reports contact.
    static func sugarTasteCurrent(_ sugar: Float, sensoryGate: Float) -> Float {
        let bounded = min(1, max(0, sugar))
        return 0.120 * sqrt(sqrt(bounded)) * sensoryGate
    }

    /// Temperature -> identified warm/cool receptor current. Neutral at 25 C.
    static func thermal(celsius: Double, enabled: Bool,
                        sensoryGate: Float) -> ThermalSensoryDrive {
        guard enabled else { return ThermalSensoryDrive() }
        let warm = Float(max(0, min(1, (celsius - 25) / 10)))
        let cool = Float(max(0, min(1, (25 - celsius) / 10)))
        let gain: Float = 0.060
        return ThermalSensoryDrive(warm: warm * gain * sensoryGate,
                                   cool: cool * gain * sensoryGate)
    }

    /// World wind -> body-relative opponent JO-C/E current.
    static func wind(strength: Float, directionDeg: Double, bodyHeading: Double,
                     sensoryGate: Float) -> WindSensoryDrive {
        guard strength > 0 else { return WindSensoryDrive() }
        let windRad = directionDeg * .pi / 180
        let relative = windRad - bodyHeading
        let opponent = Float(cos(relative))
        let gain: Float = 0.055
        return WindSensoryDrive(
            c: strength * (0.5 + 0.5 * opponent) * gain * sensoryGate,
            e: strength * (0.5 - 0.5 * opponent) * gain * sensoryGate)
    }

    static func touch(sourceDrive: Float, sensoryGate: Float) -> Float {
        sourceDrive * sensoryGate
    }

    /// V2 modeled-physiology temperature -> locomotor tempo mapping.
    static func locomotorTempo(celsius: Double) -> CGFloat {
        let temp = min(40, max(10, celsius))
        return clampf(CGFloat(1 + (temp - 25) * 0.03), 0.55, 1.45)
    }
}
