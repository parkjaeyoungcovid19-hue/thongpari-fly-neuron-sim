import Foundation

/// Render-owner snapshot copied under Coordinator's lock. It contains only
/// scalars/short strings so the AppKit timer never reaches into Metal buffers.
struct LabTelemetry {
    var wallTime: TimeInterval = Date().timeIntervalSince1970
    var simMs: Int = 0
    // V4 authoritative experiment-time/session fields. Wall time remains useful
    // for diagnostics but is not the deterministic experiment clock.
    var sessionID: String = ""
    var sessionEpoch: Int = 0
    var sessionSimTick: Int = 0
    var sessionMode: String = "interactive"
    var sessionPhase: String = "running"
    var sessionPaused: Bool = false
    var bodyResultTick: Int = -1
    var ratePop: Double = 0
    var rateLoom: Double = 0
    var rateDNaL: Double = 0
    var rateDNaR: Double = 0
    var rateMDN: Double = 0
    var rateFwd: Double = 0
    var rateGroom: Double = 0
    var rateEscW: Double = 0
    // Receptor-group EMA spike rates from the real FlyWire cell-type groups.
    var rateFoodOdorL: Double = 0
    var rateFoodOdorR: Double = 0
    var rateThermoWarm: Double = 0
    var rateThermoCool: Double = 0
    var rateWindC: Double = 0
    var rateWindE: Double = 0
    // V5.6.2 identified sugar GRNs (input) and MN9 (read-only), root-ID groups.
    var rateSugarGRN: Double = 0
    var rateMN9: Double = 0
    var loomL: Double = 0
    var loomR: Double = 0
    var airPuff: Double = 0
    var gaitDrive: Double = 0
    var odorDriveL: Double = 0
    var odorDriveR: Double = 0
    var thermoWarmDrive: Double = 0
    var thermoCoolDrive: Double = 0
    var windCDrive: Double = 0
    var windEDrive: Double = 0
    var temperatureC: Double = 25
    /// Mode the brain side is actually using (V6.5 backend reconciliation).
    var temperatureMode: String = "environment_only"
    var bodyVX: Double = 0
    var bodyYawRate: Double = 0
    var bodyContactMean: Double = 0
    var bodyLoomL: Double = 0
    var bodyLoomR: Double = 0
    var bodyBrightnessL: Double = 0
    var bodyBrightnessR: Double = 0
    var bodyOccupancyL: Double = 0
    var bodyOccupancyR: Double = 0
    var bodyOpticExpansionL: Double = 0
    var bodyOpticExpansionR: Double = 0
    /// Protocol-ms simulation tick of the latest successful raw FlyGym stereo-eye
    /// render. -1 means no rendered sample yet. This is provenance for the raw
    /// frame, not a claim that every decayed/modeled vision scalar has this age.
    var bodyEyeSampleSimTick: Int = -1
    var bodyFlashL: Double = 0
    var bodyFlashR: Double = 0
    var bodyOdorL: Double = 0
    var bodyOdorR: Double = 0
    /// -1 means no active food source / no fresh distance telemetry.
    var bodyNearestFoodDistanceMm: Double = -1
    var bodyTasteSugar: Double = 0
    /// MuJoCo/FlyGym simulation time carried by the exact body packet used for
    /// this telemetry sample. -1 means no fresh body packet was available.
    var bodySimTime: Double = -1
    var bodySimDt: Double = 0
    var bodyWallDt: Double = 0
    var bodySimWallRatio: Double = 0
    var bodyControllerLeft: Double = 0
    var bodyControllerRight: Double = 0
    var bodyWindStrength: Double = 0
    var bodyWindDirectionDeg: Double = 0
    var bodyWindSensory: Bool = false
    var bodyTouchStrength: Double = 0
    var bodyTouchSensory: Bool = false
    /// Wall-clock receive age of that body packet at snapshot time.
    var bodyPacketAgeS: Double = -1
    var bodyConnectionGeneration: UInt64 = 0
    // Exact decoded BrainSignals that were sent to FlyGym for this render step.
    var brainSignalsAvailable: Bool = false
    var brainWalkDrive: Double = 0
    var brainTurnBias: Double = 0
    var brainEscape: Bool = false
    var brainBackward: Bool = false
    var brainGroomDrive: Double = 0
    var brainWingDrive: Double = 0
    var brainArousal: Double = 0
    var brainTempo: Double = 1
    var brainSleep: Bool = false
    var brainNervous: Double = 0
    var flyState: String = "unknown"
}

extension LabTelemetry {
    mutating func applyReceptorRates(_ sim: MetalSim) {
        rateFoodOdorL = Double(sim.rateFoodOdorL)
        rateFoodOdorR = Double(sim.rateFoodOdorR)
        rateThermoWarm = Double(sim.rateThermoWarm)
        rateThermoCool = Double(sim.rateThermoCool)
        rateWindC = Double(sim.rateWindC)
        rateWindE = Double(sim.rateWindE)
        rateSugarGRN = Double(sim.rateSugarGRN)
        rateMN9 = Double(sim.rateMN9)
    }

    mutating func applyBrainSignals(_ signals: BrainSignals?) {
        guard let signals else {
            brainSignalsAvailable = false
            brainWalkDrive = 0; brainTurnBias = 0
            brainEscape = false; brainBackward = false
            brainGroomDrive = 0; brainWingDrive = 0; brainArousal = 0
            brainTempo = 1; brainSleep = false; brainNervous = 0
            return
        }
        brainSignalsAvailable = true
        brainWalkDrive = Double(signals.walkDrive)
        brainTurnBias = Double(signals.turnBias)
        brainEscape = signals.escape
        brainBackward = signals.backward
        brainGroomDrive = Double(signals.groomDrive)
        brainWingDrive = Double(signals.wingDrive)
        brainArousal = Double(signals.arousal)
        brainTempo = Double(signals.tempo)
        brainSleep = signals.sleep
        brainNervous = Double(signals.nervous)
    }

    /// Copies one body packet as a unit so telemetry cannot accidentally mix a
    /// newer packet's diagnostics with an older packet's neural input.
    mutating func applyBodyFeedback(_ fb: FlyGymBodyFeedback?, now: Date = Date()) {
        guard let fb else {
            bodyVX = 0; bodyYawRate = 0; bodyContactMean = 0
            bodyLoomL = 0; bodyLoomR = 0
            bodyBrightnessL = 0; bodyBrightnessR = 0
            bodyOccupancyL = 0; bodyOccupancyR = 0
            bodyOpticExpansionL = 0; bodyOpticExpansionR = 0
            bodyEyeSampleSimTick = -1
            bodyFlashL = 0; bodyFlashR = 0
            bodyOdorL = 0; bodyOdorR = 0
            bodyNearestFoodDistanceMm = -1
            bodyTasteSugar = 0
            bodySimTime = -1; bodySimDt = 0; bodyWallDt = 0; bodySimWallRatio = 0
            bodyControllerLeft = 0; bodyControllerRight = 0
            bodyWindStrength = 0; bodyWindDirectionDeg = 0; bodyWindSensory = false
            bodyTouchStrength = 0; bodyTouchSensory = false
            bodyPacketAgeS = -1; bodyConnectionGeneration = 0
            return
        }
        bodyVX = fb.vx; bodyYawRate = fb.yawRate; bodyContactMean = fb.contactMean
        bodyLoomL = fb.loomLeft; bodyLoomR = fb.loomRight
        bodyBrightnessL = fb.brightnessLeft; bodyBrightnessR = fb.brightnessRight
        bodyOccupancyL = fb.occupancyLeft; bodyOccupancyR = fb.occupancyRight
        bodyOpticExpansionL = fb.opticExpansionLeft; bodyOpticExpansionR = fb.opticExpansionRight
        bodyEyeSampleSimTick = fb.eyeSampleSimTick ?? -1
        bodyFlashL = fb.flashLeft; bodyFlashR = fb.flashRight
        bodyOdorL = fb.odorLeft; bodyOdorR = fb.odorRight
        bodyNearestFoodDistanceMm = fb.nearestFoodDistanceMm ?? -1
        bodyTasteSugar = fb.tasteSugar
        bodySimTime = fb.simTime
        bodySimDt = fb.simDt
        bodyWallDt = fb.wallDt
        bodySimWallRatio = fb.simWallRatio
        bodyControllerLeft = fb.controllerLeft
        bodyControllerRight = fb.controllerRight
        bodyWindStrength = fb.windStrength
        bodyWindDirectionDeg = fb.windDirectionDeg
        bodyWindSensory = fb.windSensory
        bodyTouchStrength = fb.touchStrength
        bodyTouchSensory = fb.touchSensory
        bodyPacketAgeS = fb.ageSeconds(at: now)
        bodyConnectionGeneration = fb.connectionGeneration
    }

    private static let csvColumns: [(name: String, format: String, value: (LabTelemetry) -> CVarArg)] = [
        ("wall_time", "%.6f", { $0.wallTime }),
        ("sim_ms", "%d", { $0.simMs }),
        ("pop_hz", "%.5f", { $0.ratePop }),
        ("loom_hz", "%.5f", { $0.rateLoom }),
        ("dna_l_hz", "%.5f", { $0.rateDNaL }),
        ("dna_r_hz", "%.5f", { $0.rateDNaR }),
        ("mdn_hz", "%.5f", { $0.rateMDN }),
        ("dnp09_hz", "%.5f", { $0.rateFwd }),
        ("dng11_hz", "%.5f", { $0.rateGroom }),
        ("escw_hz", "%.5f", { $0.rateEscW }),
        ("loom_l", "%.5f", { $0.loomL }),
        ("loom_r", "%.5f", { $0.loomR }),
        ("air_puff", "%.5f", { $0.airPuff }),
        ("gait_drive", "%.5f", { $0.gaitDrive }),
        ("odor_drive_l", "%.5f", { $0.odorDriveL }),
        ("odor_drive_r", "%.5f", { $0.odorDriveR }),
        ("thermo_warm_drive", "%.5f", { $0.thermoWarmDrive }),
        ("thermo_cool_drive", "%.5f", { $0.thermoCoolDrive }),
        ("wind_c_drive", "%.5f", { $0.windCDrive }),
        ("wind_e_drive", "%.5f", { $0.windEDrive }),
        ("temp_c", "%.3f", { $0.temperatureC }),
        ("body_vx", "%.7f", { $0.bodyVX }),
        ("body_yaw_rate", "%.7f", { $0.bodyYawRate }),
        ("body_contact_mean", "%.5f", { $0.bodyContactMean }),
        ("body_loom_l", "%.5f", { $0.bodyLoomL }),
        ("body_loom_r", "%.5f", { $0.bodyLoomR }),
        ("brightness_l", "%.5f", { $0.bodyBrightnessL }),
        ("brightness_r", "%.5f", { $0.bodyBrightnessR }),
        ("occupancy_l", "%.5f", { $0.bodyOccupancyL }),
        ("occupancy_r", "%.5f", { $0.bodyOccupancyR }),
        ("optic_expansion_l", "%.5f", { $0.bodyOpticExpansionL }),
        ("optic_expansion_r", "%.5f", { $0.bodyOpticExpansionR }),
        ("flash_l", "%.5f", { $0.bodyFlashL }),
        ("flash_r", "%.5f", { $0.bodyFlashR }),
        ("odor_l", "%.5f", { $0.bodyOdorL }),
        ("odor_r", "%.5f", { $0.bodyOdorR }),
        ("nearest_food_mm", "%.3f", { $0.bodyNearestFoodDistanceMm }),
        ("fly_state", "%@", { $0.flyState.replacingOccurrences(of: ",", with: "_") }),
        ("body_sim_s", "%.6f", { $0.bodySimTime }),
        ("body_sim_dt", "%.6f", { $0.bodySimDt }),
        ("body_wall_dt", "%.6f", { $0.bodyWallDt }),
        ("body_sim_wall_ratio", "%.6f", { $0.bodySimWallRatio }),
        ("body_packet_age_s", "%.6f", { $0.bodyPacketAgeS }),
        ("body_generation", "%llu", { $0.bodyConnectionGeneration }),
        ("body_eye_sample_sim_tick", "%d", { $0.bodyEyeSampleSimTick }),
        ("receptor_odor_l_hz", "%.5f", { $0.rateFoodOdorL }),
        ("receptor_odor_r_hz", "%.5f", { $0.rateFoodOdorR }),
        ("receptor_warm_hz", "%.5f", { $0.rateThermoWarm }),
        ("receptor_cool_hz", "%.5f", { $0.rateThermoCool }),
        ("receptor_wind_c_hz", "%.5f", { $0.rateWindC }),
        ("receptor_wind_e_hz", "%.5f", { $0.rateWindE }),
        ("brain_signals_available", "%d", { $0.brainSignalsAvailable ? 1 : 0 }),
        ("brain_walk", "%.5f", { $0.brainWalkDrive }),
        ("brain_turn", "%.5f", { $0.brainTurnBias }),
        ("brain_escape", "%d", { $0.brainEscape ? 1 : 0 }),
        ("brain_backward", "%d", { $0.brainBackward ? 1 : 0 }),
        ("brain_groom", "%.5f", { $0.brainGroomDrive }),
        ("brain_wing", "%.5f", { $0.brainWingDrive }),
        ("brain_arousal", "%.5f", { $0.brainArousal }),
        ("brain_tempo", "%.5f", { $0.brainTempo }),
        ("brain_sleep", "%d", { $0.brainSleep ? 1 : 0 }),
        ("brain_nervous", "%.5f", { $0.brainNervous }),
        ("controller_left", "%.5f", { $0.bodyControllerLeft }),
        ("controller_right", "%.5f", { $0.bodyControllerRight }),
        ("body_wind_strength", "%.5f", { $0.bodyWindStrength }),
        ("body_wind_direction_deg", "%.5f", { $0.bodyWindDirectionDeg }),
        ("body_wind_sensory", "%d", { $0.bodyWindSensory ? 1 : 0 }),
        ("body_touch_strength", "%.5f", { $0.bodyTouchStrength }),
        ("body_touch_sensory", "%d", { $0.bodyTouchSensory ? 1 : 0 }),
        ("session_id", "%@", { $0.sessionID.replacingOccurrences(of: ",", with: "_") }),
        ("session_epoch", "%d", { $0.sessionEpoch }),
        ("session_sim_tick", "%d", { $0.sessionSimTick }),
        ("session_mode", "%@", { $0.sessionMode.replacingOccurrences(of: ",", with: "_") }),
        ("session_phase", "%@", { $0.sessionPhase.replacingOccurrences(of: ",", with: "_") }),
        ("session_paused", "%d", { $0.sessionPaused ? 1 : 0 }),
        ("body_result_tick", "%d", { $0.bodyResultTick }),
        ("sugar_grn_hz", "%.5f", { $0.rateSugarGRN }),
        ("mn9_hz", "%.5f", { $0.rateMN9 })
    ]
    static let csvHeader = csvColumns.map(\.name).joined(separator: ",") + "\n"
    var csvLine: String {
        let values = Self.csvColumns.map { $0.value(self) }
        assert(values.count == Self.csvColumns.count)
        return String(format: Self.csvColumns.map(\.format).joined(separator: ",") + "\n", arguments: values)
    }

}
