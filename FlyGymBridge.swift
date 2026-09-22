// FlyGymBridge.swift — localhost TCP bridge between the Metal brain and a
// Python FlyGym body. Swift is the CLIENT, Python `bridge.py` is the SERVER.
//
// Design constraints (see docs/plans/PLAN_FLYGYM.md):
// - The Metal brain stays authoritative at 1 kHz. Only compact population
//   signals cross the process boundary (~50-100 Hz BrainSignals).
// - Socket I/O NEVER runs on the render thread. A sender thread ships the
//   latest BrainSignals; a receiver thread parses body feedback. Bounded
//   buffers everywhere (latest-packet-wins); disconnect never crashes the sim.
// - Body->brain mapping is a MODELING ASSUMPTION, centralized in
//   FlyGymSensoryMap, reusing the existing ascend/sens input paths.

import Foundation
import Cocoa
import Darwin

// MARK: - Packets (mirror flygym_bridge/protocol.py)

/// Brain -> body. Compact population readout, ~50-100 Hz.
struct FlyGymBrainPacket: Codable {
    var type: String = "brain"
    var t: Double = 0            // sim seconds
    var walk: Double = 0         // walkDrive 0..1.3
    var turn: Double = 0         // turnBias -1..1
    var escape: Bool = false
    var backward: Bool = false
    var groom: Double = 0
    var wing: Double = 0
    var arousal: Double = 0
    var tempo: Double = 1
    var sleep: Bool = false
    var nervous: Double = 0

    init(signals: BrainSignals, simMs: Int) {
        t = Double(simMs) / 1000.0
        walk = Double(signals.walkDrive)
        turn = Double(signals.turnBias)
        escape = signals.escape
        backward = signals.backward
        groom = Double(signals.groomDrive)
        wing = Double(signals.wingDrive)
        arousal = Double(signals.arousal)
        tempo = Double(signals.tempo)
        sleep = signals.sleep
        nervous = Double(signals.nervous)
    }
    init() {}
}

enum FlyGymProtocolV4 {
    static let version = 4
    static let experimentQuantumTicks = 20
    static let capabilities = ["applied_tick", "deterministic_experiment", "epoch", "pause_barrier"]
}

enum FlyGymViewerProtocolV5_1 {
    static let capabilities = ["world_render_snapshot", "ray_pick"]
}

enum FlyGymPlayerProtocolV5_4 {
    static let capabilities = ["player_body"]
}

enum FlyGymPlayerInputProtocolV5_5 {
    static let capabilities = ["player_input"]
}

struct FlyGymHelloPacket: Codable, FlyGymStampedPacket {
    var type: String = "hello"
    var protocolVersion: Int = FlyGymProtocolV4.version
    var role: String = "swift"
    var capabilities: [String] = FlyGymProtocolV4.capabilities
        + FlyGymViewerProtocolV5_1.capabilities + FlyGymPlayerProtocolV5_4.capabilities
        + FlyGymPlayerInputProtocolV5_5.capabilities
    var physicsTimestepS: Double?
    var supportedQuantumTicks: [Int] = [FlyGymProtocolV4.experimentQuantumTicks]
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, role, capabilities
        case protocolVersion = "protocol_version"
        case physicsTimestepS = "physics_timestep_s"
        case supportedQuantumTicks = "supported_quantum_ticks"
    }

    var supportsDeterministicV4: Bool {
        guard protocolVersion >= FlyGymProtocolV4.version,
              supportedQuantumTicks.contains(FlyGymProtocolV4.experimentQuantumTicks),
              let physicsTimestepS, physicsTimestepS.isFinite, physicsTimestepS > 0 else { return false }
        return Set(FlyGymProtocolV4.capabilities).isSubset(of: Set(capabilities))
    }

    var supportsWorldViewerV5_1: Bool {
        guard protocolVersion >= FlyGymProtocolV4.version else { return false }
        return Set(FlyGymViewerProtocolV5_1.capabilities).isSubset(of: Set(capabilities))
    }

    var supportsPlayerV5_4: Bool {
        guard supportsWorldViewerV5_1 else { return false }
        return Set(FlyGymPlayerProtocolV5_4.capabilities).isSubset(of: Set(capabilities))
    }

    var supportsPlayerInputV5_5: Bool {
        guard supportsPlayerV5_4 else { return false }
        return Set(FlyGymPlayerInputProtocolV5_5.capabilities).isSubset(of: Set(capabilities))
    }
}

enum LabSessionMode: String, Codable {
    case interactive
    case deterministic
}

struct FlyGymSessionControlPacket: Codable {
    var type: String = "session_control"
    var protocolVersion: Int = FlyGymProtocolV4.version
    var sessionID: String
    var epoch: Int
    var seq: Int
    var simTick: Int
    var action: String
    var mode: LabSessionMode
    var resetScope: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq, action, mode
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case simTick = "sim_tick"
        case resetScope = "reset_scope"
    }
}

struct FlyGymSessionStatePacket: Decodable, FlyGymStampedPacket {
    var type: String = "session_state"
    var protocolVersion: Int = 0
    var sessionID: String = ""
    var epoch: Int = 0
    var seq: Int = 0
    var simTick: Int = 0
    var mode: LabSessionMode = .interactive
    var state: String = ""
    var ok: Bool = false
    var error: String?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq, mode, state, ok, error
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case simTick = "sim_tick"
    }
}

struct FlyGymExperimentStepPacket: Codable {
    var type: String = "experiment_step"
    var protocolVersion: Int = FlyGymProtocolV4.version
    var sessionID: String
    var epoch: Int
    var seq: Int
    var simTick: Int
    var quantumTicks: Int = FlyGymProtocolV4.experimentQuantumTicks
    var brain: FlyGymBrainPacket

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq, brain
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case simTick = "sim_tick"
        case quantumTicks = "quantum_ticks"
    }
}

struct FlyGymExperimentStepResultPacket: Decodable, FlyGymStampedPacket {
    var type: String = "experiment_step_result"
    var protocolVersion: Int = 0
    var sessionID: String = ""
    var epoch: Int = 0
    var seq: Int = 0
    var simTick: Int = 0
    var endSimTick: Int = 0
    var ok: Bool = false
    var error: String?
    var body: FlyGymBodyPacket = FlyGymBodyPacket()
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq, ok, error, body
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case simTick = "sim_tick"
        case endSimTick = "end_sim_tick"
    }
}

/// Body -> brain. Tolerant parse: unknown fields ignored, missing fields get
/// defaults, out-of-range values clamped. Never throws out of the bridge.
struct FlyGymBodyPacket: Decodable {
    var t: Double = 0
    var simDt: Double = 0
    var wallDt: Double = 0
    var simWallRatio: Double = 0
    var controllerLeft: Double = 0
    var controllerRight: Double = 0
    var windStrength: Double = 0
    var windDirectionDeg: Double = 0
    var windSensory: Bool = false
    var touchStrength: Double = 0
    var touchSensory: Bool = false
    var vx: Double = 0           // forward velocity m/s
    var yawRate: Double = 0      // rad/s
    var contacts: [Double] = [0, 0, 0, 0, 0, 0]
    var leftContact: Double = 0
    var rightContact: Double = 0
    var gaitPhase: Double?       // optional 0..1
    var loomLeft: Double = 0
    var loomRight: Double = 0
    var brightness: Double = 0
    var brightnessLeft: Double = 0
    var brightnessRight: Double = 0
    var occupancyLeft: Double = 0
    var occupancyRight: Double = 0
    var opticExpansionLeft: Double = 0
    var opticExpansionRight: Double = 0
    var eyeSampleSimTick: Int?
    var flashLeft: Double = 0
    var flashRight: Double = 0
    var odorLeft: Double = 0
    var odorRight: Double = 0
    var nearestFoodDistanceMm: Double?
    var positionXmm: Double = 0
    var positionYmm: Double = 0
    var headingRad: Double = 0
    var bearing: Double = 0

    enum Keys: String, CodingKey {
        case type, t, vx, yawRate = "yaw_rate", contacts
        case simDt = "sim_dt", wallDt = "wall_dt", simWallRatio = "sim_wall_ratio"
        case controllerLeft = "controller_left", controllerRight = "controller_right"
        case windStrength = "wind_strength", windDirectionDeg = "wind_direction_deg"
        case windSensory = "wind_sensory", touchStrength = "touch_strength", touchSensory = "touch_sensory"
        case leftContact = "left_contact", rightContact = "right_contact"
        case gaitPhase = "gait_phase"
        case loomLeft = "loom_left", loomRight = "loom_right", brightness, bearing
        case brightnessLeft = "brightness_left", brightnessRight = "brightness_right"
        case occupancyLeft = "occupancy_left", occupancyRight = "occupancy_right"
        case opticExpansionLeft = "optic_expansion_left", opticExpansionRight = "optic_expansion_right"
        case eyeSampleSimTick = "eye_sample_sim_tick"
        case flashLeft = "flash_left", flashRight = "flash_right"
        case odorLeft = "odor_left", odorRight = "odor_right"
        case nearestFoodDistanceMm = "nearest_food_distance_mm"
        case positionXmm = "position_x_mm", positionYmm = "position_y_mm"
        case headingRad = "heading_rad"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let tRaw = (try? c.decodeIfPresent(Double.self, forKey: .t)) ?? 0
        t = tRaw.isFinite ? max(0, tRaw) : 0
        let simDtRaw = (try? c.decodeIfPresent(Double.self, forKey: .simDt)) ?? 0
        simDt = simDtRaw.isFinite ? max(0, min(10, simDtRaw)) : 0
        let wallDtRaw = (try? c.decodeIfPresent(Double.self, forKey: .wallDt)) ?? 0
        wallDt = wallDtRaw.isFinite ? max(0, min(10, wallDtRaw)) : 0
        let ratioRaw = (try? c.decodeIfPresent(Double.self, forKey: .simWallRatio)) ?? 0
        simWallRatio = ratioRaw.isFinite ? max(0, min(1000, ratioRaw)) : 0
        let ctlLRaw = (try? c.decodeIfPresent(Double.self, forKey: .controllerLeft)) ?? 0
        controllerLeft = ctlLRaw.isFinite ? max(-2, min(2, ctlLRaw)) : 0
        let ctlRRaw = (try? c.decodeIfPresent(Double.self, forKey: .controllerRight)) ?? 0
        controllerRight = ctlRRaw.isFinite ? max(-2, min(2, ctlRRaw)) : 0
        let windRaw = (try? c.decodeIfPresent(Double.self, forKey: .windStrength)) ?? 0
        windStrength = windRaw.isFinite ? max(0, min(1, windRaw)) : 0
        let windDirRaw = (try? c.decodeIfPresent(Double.self, forKey: .windDirectionDeg)) ?? 0
        windDirectionDeg = windDirRaw.isFinite ? windDirRaw.truncatingRemainder(dividingBy: 360) : 0
        windSensory = (try? c.decodeIfPresent(Bool.self, forKey: .windSensory)) ?? false
        let touchRaw = (try? c.decodeIfPresent(Double.self, forKey: .touchStrength)) ?? 0
        touchStrength = touchRaw.isFinite ? max(0, min(1, touchRaw)) : 0
        touchSensory = (try? c.decodeIfPresent(Bool.self, forKey: .touchSensory)) ?? false
        let vxRaw = (try? c.decodeIfPresent(Double.self, forKey: .vx)) ?? 0
        vx = min(2.0, max(-2.0, vxRaw))
        let yawRaw = (try? c.decodeIfPresent(Double.self, forKey: .yawRate)) ?? 0
        yawRate = min(20.0, max(-20.0, yawRaw))
        var cc = (try? c.decodeIfPresent([Double].self, forKey: .contacts)) ?? []
        cc = cc.map { min(1.0, max(0.0, $0)) }
        while cc.count < 6 { cc.append(0) }
        contacts = Array(cc.prefix(6))
        let l = (try? c.decodeIfPresent(Double.self, forKey: .leftContact)) ?? 0
        leftContact = min(1.0, max(0.0, l))
        let rr = (try? c.decodeIfPresent(Double.self, forKey: .rightContact)) ?? 0
        rightContact = min(1.0, max(0.0, rr))
        if let g = (try? c.decodeIfPresent(Double.self, forKey: .gaitPhase)) ?? nil {
            gaitPhase = min(1.0, max(0.0, g))
        } else { gaitPhase = nil }
        loomLeft = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .loomLeft)) ?? 0))
        loomRight = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .loomRight)) ?? 0))
        brightness = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .brightness)) ?? 0))
        brightnessLeft = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .brightnessLeft)) ?? brightness))
        brightnessRight = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .brightnessRight)) ?? brightness))
        occupancyLeft = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .occupancyLeft)) ?? 0))
        occupancyRight = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .occupancyRight)) ?? 0))
        opticExpansionLeft = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .opticExpansionLeft)) ?? 0))
        opticExpansionRight = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .opticExpansionRight)) ?? 0))
        if let sample = (try? c.decodeIfPresent(Int.self, forKey: .eyeSampleSimTick)) ?? nil {
            eyeSampleSimTick = max(0, sample)
        } else {
            eyeSampleSimTick = nil
        }
        flashLeft = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .flashLeft)) ?? 0))
        flashRight = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .flashRight)) ?? 0))
        odorLeft = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .odorLeft)) ?? 0))
        odorRight = min(1.0, max(0.0, (try? c.decodeIfPresent(Double.self, forKey: .odorRight)) ?? 0))
        if let d = (try? c.decodeIfPresent(Double.self, forKey: .nearestFoodDistanceMm)) ?? nil,
           d.isFinite {
            nearestFoodDistanceMm = min(1_000_000.0, max(0.0, d))
        } else { nearestFoodDistanceMm = nil }
        let xRaw = (try? c.decodeIfPresent(Double.self, forKey: .positionXmm)) ?? 0
        positionXmm = xRaw.isFinite ? min(1_000_000.0, max(-1_000_000.0, xRaw)) : 0
        let yRaw = (try? c.decodeIfPresent(Double.self, forKey: .positionYmm)) ?? 0
        positionYmm = yRaw.isFinite ? min(1_000_000.0, max(-1_000_000.0, yRaw)) : 0
        let headingRaw = (try? c.decodeIfPresent(Double.self, forKey: .headingRad)) ?? 0
        headingRad = headingRaw.isFinite ? min(Double.pi, max(-Double.pi, headingRaw)) : 0
        bearing = min(1.0, max(-1.0, (try? c.decodeIfPresent(Double.self, forKey: .bearing)) ?? 0))
    }
}

private struct FlyGymTaggedLine: Decodable { var type: String = "" }

/// Type-gated body parser: rejects malformed JSON AND wrong-type lines.
/// Single choke point used by recvLoop and --bridgetest.
func parseBodyLine(_ line: Data) -> FlyGymBodyPacket? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "body",
          let pkt = try? JSONDecoder().decode(FlyGymBodyPacket.self, from: line) else { return nil }
    return pkt
}

func parseLabStateLine(_ line: Data) -> LabRemoteState? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "lab_state" else { return nil }
    return try? JSONDecoder().decode(LabRemoteState.self, from: line)
}

func parseLabAckLine(_ line: Data) -> LabAck? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "lab_ack" else { return nil }
    return try? JSONDecoder().decode(LabAck.self, from: line)
}

func parseLabEventLine(_ line: Data) -> LabEventNotice? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "lab_event" else { return nil }
    return try? JSONDecoder().decode(LabEventNotice.self, from: line)
}

private func decodePlayerInputLine(_ line: Data) -> PlayerInputPacket? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "player_input" else { return nil }
    return try? JSONDecoder().decode(PlayerInputPacket.self, from: line)
}

func parsePlayerInputResultLine(_ line: Data) -> PlayerInputResult? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "player_input_result" else { return nil }
    return try? JSONDecoder().decode(PlayerInputResult.self, from: line)
}

func parseHelloLine(_ line: Data) -> FlyGymHelloPacket? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "hello" else { return nil }
    return try? JSONDecoder().decode(FlyGymHelloPacket.self, from: line)
}

func parseSessionStateLine(_ line: Data) -> FlyGymSessionStatePacket? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "session_state" else { return nil }
    return try? JSONDecoder().decode(FlyGymSessionStatePacket.self, from: line)
}

func parseExperimentStepResultLine(_ line: Data) -> FlyGymExperimentStepResultPacket? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "experiment_step_result" else { return nil }
    return try? JSONDecoder().decode(FlyGymExperimentStepResultPacket.self, from: line)
}

func parseWorldRenderSnapshotLine(_ line: Data) -> WorldRenderSnapshot? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "world_render_snapshot" else { return nil }
    return try? JSONDecoder().decode(WorldRenderSnapshot.self, from: line)
}

func parseRayPickResultLine(_ line: Data) -> RayPickResult? {
    guard let tag = try? JSONDecoder().decode(FlyGymTaggedLine.self, from: line),
          tag.type == "ray_pick_result" else { return nil }
    return try? JSONDecoder().decode(RayPickResult.self, from: line)
}

struct FlyGymBodyFeedback: FlyGymStampedPacket {
    /// MuJoCo/FlyGym simulation time in seconds from the body packet.
    var simTime: Double = 0
    /// MuJoCo simulation seconds advanced since the previous body packet.
    var simDt: Double = 0
    var wallDt: Double = 0
    /// `simDt / wallDt`, reported by Python. Values below 1 mean time dilation.
    var simWallRatio: Double = 0
    var controllerLeft: Double = 0
    var controllerRight: Double = 0
    var windStrength: Double = 0
    var windDirectionDeg: Double = 0
    var windSensory: Bool = false
    var touchStrength: Double = 0
    var touchSensory: Bool = false
    var vx: Double = 0
    var yawRate: Double = 0
    var contacts: [Double] = [0, 0, 0, 0, 0, 0]
    var leftContact: Double = 0
    var rightContact: Double = 0
    var gaitPhase: Double?
    var loomLeft: Double = 0
    var loomRight: Double = 0
    var brightness: Double = 0
    var brightnessLeft: Double = 0
    var brightnessRight: Double = 0
    var occupancyLeft: Double = 0
    var occupancyRight: Double = 0
    var opticExpansionLeft: Double = 0
    var opticExpansionRight: Double = 0
    var eyeSampleSimTick: Int?
    var flashLeft: Double = 0
    var flashRight: Double = 0
    var odorLeft: Double = 0
    var odorRight: Double = 0
    var nearestFoodDistanceMm: Double?
    var positionXmm: Double = 0
    var positionYmm: Double = 0
    var headingRad: Double = 0
    var bearing: Double = 0
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0
    var contactMean: Double { contacts.reduce(0, +) / 6.0 }
    init(_ p: FlyGymBodyPacket) {
        simTime = p.t
        simDt = p.simDt; wallDt = p.wallDt; simWallRatio = p.simWallRatio
        controllerLeft = p.controllerLeft; controllerRight = p.controllerRight
        windStrength = p.windStrength; windDirectionDeg = p.windDirectionDeg
        windSensory = p.windSensory
        touchStrength = p.touchStrength; touchSensory = p.touchSensory
        vx = p.vx; yawRate = p.yawRate; contacts = p.contacts
        leftContact = p.leftContact; rightContact = p.rightContact
        gaitPhase = p.gaitPhase
        loomLeft = p.loomLeft; loomRight = p.loomRight
        brightness = p.brightness; brightnessLeft = p.brightnessLeft; brightnessRight = p.brightnessRight
        occupancyLeft = p.occupancyLeft; occupancyRight = p.occupancyRight
        opticExpansionLeft = p.opticExpansionLeft; opticExpansionRight = p.opticExpansionRight
        eyeSampleSimTick = p.eyeSampleSimTick
        flashLeft = p.flashLeft; flashRight = p.flashRight
        odorLeft = p.odorLeft; odorRight = p.odorRight
        nearestFoodDistanceMm = p.nearestFoodDistanceMm
        positionXmm = p.positionXmm; positionYmm = p.positionYmm
        headingRad = p.headingRad; bearing = p.bearing
    }
    init() {}
}

// MARK: - Body -> brain mapping (MODELING ASSUMPTION)

/// Centralized mapping from compact MuJoCo body state into the sim's existing
/// ascending/sensory drive inputs. The connectome wiring downstream is real;
/// THIS mapping (contact/vx -> gaitDrive) is an engineering assumption.
/// Reuses the existing gait/proprioception path (`ascendDrive`), never invents
/// new neuron populations.
enum FlyGymSensoryMap {
    /// Movement-derived walking drive 0..1. Ground-contact occupancy is kept as
    /// telemetry only: a fly standing on six feet must not look like it is walking.
    static func bodyDrive(_ fb: FlyGymBodyFeedback) -> Float {
        let speedTerm = min(1.0, abs(fb.vx) / 0.03)       // 0.03 m/s ~= brisk walk
        let turnTerm = min(1.0, abs(fb.yawRate) / 4.0)    // turning in place is still locomotion
        let d = max(speedTerm, turnTerm)
        return Float(min(1.0, max(0.0, d)))
    }
    /// Fresh real-body data is authoritative. The procedural desktop fly is only
    /// a fallback when body feedback is absent/stale; it is never blended into a
    /// live FlyGym experiment.
    static func gaitDrive(procedural: Float, body: FlyGymBodyFeedback?, maxAge: TimeInterval = 0.5) -> Float {
        guard let b = body, Date().timeIntervalSince(b.receivedAt) < maxAge else { return procedural }
        return bodyDrive(b)
    }
    static func gaitPhase(procedural: Float, body: FlyGymBodyFeedback?, maxAge: TimeInterval = 0.5) -> Float {
        guard let b = body, let g = b.gaitPhase,
              Date().timeIntervalSince(b.receivedAt) < maxAge else { return procedural }
        return Float(g)
    }
    /// FlyGym visual looming feeds ONLY the existing LC4/LPLC2 external input.
    /// The visual decoder on the Python side is a modeling assumption; escape
    /// still requires the real downstream connectome/GF to spike.
    static func looming(body: FlyGymBodyFeedback?, maxAge: TimeInterval = 0.5) -> (l: Float, r: Float) {
        guard let b = body, Date().timeIntervalSince(b.receivedAt) < maxAge else { return (0, 0) }
        return (Float(b.loomLeft), Float(b.loomRight))
    }

    /// Modeled food odor from Python LabWorld.  These values are geometry-derived
    /// sensory-model scalars, not behavior commands.  The Coordinator maps them
    /// into real ORN_DM1/ORN_VA2 neurons; stale packets must clear the drive.
    static func foodOdor(body: FlyGymBodyFeedback?, maxAge: TimeInterval = 0.5) -> (l: Float, r: Float) {
        guard let b = body, Date().timeIntervalSince(b.receivedAt) < maxAge else { return (0, 0) }
        return (Float(b.odorLeft), Float(b.odorRight))
    }

    /// Body heading is world-frame yaw from the real MuJoCo thorax. It is kept
    /// separate from `bearing`, which is strictly the visual occupancy bearing.
    static func heading(body: FlyGymBodyFeedback?, maxAge: TimeInterval = 0.5) -> Double? {
        guard let b = body, Date().timeIntervalSince(b.receivedAt) < maxAge else { return nil }
        return b.headingRad
    }
}

/// Public packet-health snapshot for LabUI/diagnostics. The packet generation is
/// separate from the current connection generation so stale cross-reconnect data
/// is visible instead of silently looking current.
struct FlyGymPacketFreshness {
    var connected: Bool
    var currentGeneration: UInt64
    var packetGeneration: UInt64?
    var ageSeconds: TimeInterval?
    var isFresh: Bool
}

fileprivate enum FlyGymSendLane: Int {
    case brain = 0
    case escape = 1
    case lab = 2
    case control = 3
    case experimentStep = 4
    case worldRender = 5
    case rayPick = 6
    case playerInput = 7
}

fileprivate struct FlyGymPendingSend {
    var lane: FlyGymSendLane
    var data: Data
}

// MARK: - TCP client (POSIX, background threads only)

final class FlyGymBridge {
    /// Maximum bytes allowed for one unterminated inbound JSON line. V4 lab
    /// state can legitimately be much larger than the old 64 KiB assumption
    /// because it carries the authoritative object list for the preallocated
    /// world. Keep a hard bound so a malformed peer still cannot grow memory
    /// without limit.
    private let maxInboundLineBytes = 512 * 1024
    let host: String
    let port: UInt16
    /// Minimum interval between brain packets on the wire (~66 Hz cap).
    var minSendInterval: TimeInterval = 0.0125
    /// A queued lab burst may use the shared wire between brain packets, but a
    /// normal latest-state brain packet becomes mandatory before this age.
    var maxNormalBrainGap: TimeInterval = 0.075

    static let bodyFreshMaxAge: TimeInterval = 0.5
    static let labStateFreshMaxAge: TimeInterval = 1.5
    static let labDiscreteFreshMaxAge: TimeInterval = 5.0

    private let lock = NSLock()
    private var running = false
    private var sock: Int32 = -1
    private var _connected = false
    private var _connectionGeneration: UInt64 = 0
    private var pending: Data?          // latest unsent brain line (bounded: 1)
    private var pendingEscape: Data?    // bounded pulse lane: escape cannot be coalesced away
    private var pendingLab: [Data] = [] // ordered lab commands (bounded FIFO, cap 32)
    private var pendingControl: [Data] = []
    private var pendingExperimentStep: Data?
    private var pendingWorldRenderRequest: Data?
    private var pendingRayPicks: [Data] = []
    private var pendingPlayerInput: Data?
    private var pendingPlayerLookRemainder = [0.0, 0.0]
    private let labQueueCap = 32
    private let controlQueueCap = 16
    private let rayPickQueueCap = 8
    private var pendingCount = 0        // packets coalesced since last send
    private var droppedCoalesced: Int = 0
    private var droppedLab: Int = 0
    private var _latestBody: FlyGymBodyFeedback?
    private var _latestLabState: LabRemoteState?
    private var _latestLabAck: LabAck?
    private var _latestLabEvent: LabEventNotice?
    private var _serverHello: FlyGymHelloPacket?
    private var _latestSessionState: FlyGymSessionStatePacket?
    private var _latestExperimentStepResult: FlyGymExperimentStepResultPacket?
    private var _latestWorldRenderSnapshot: WorldRenderSnapshot?
    private var _latestRayPickResult: RayPickResult?
    private var _latestPlayerInputResult: PlayerInputResult?
    private var requestedSessionID: String?
    private var requestedEpoch: Int?
    private var requestedSessionMode: LabSessionMode?
    private var outstandingExperimentStepSeq: Int?
    private var nextSessionControlSeq = 1
    private var nextLabID = 1
    private var nextViewerSeq = 1
    private var nextPlayerInputSeq = 1
    private var lastSend = Date.distantPast
    private var lastNormalBrainSendAt = Date.distantPast
    private var lastBodyAt: Date?
    private var bodyIntervals: [TimeInterval] = []   // bounded ring (cap 120)
    private(set) var sentCount = 0
    private(set) var recvCount = 0
    private(set) var malformedCount = 0
    private(set) var connectAttempts = 0
    private(set) var labSentCount = 0
    private(set) var labRecvCount = 0
    private(set) var controlSentCount = 0
    private(set) var experimentStepSentCount = 0
    private(set) var experimentStepRecvCount = 0
    private(set) var staleSessionPacketCount = 0

    init(host: String = "127.0.0.1", port: UInt16 = 17841) {
        self.host = host; self.port = port
    }

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var connectionGeneration: UInt64 { lock.lock(); defer { lock.unlock() }; return _connectionGeneration }
    var coalescedDropped: Int { lock.lock(); defer { lock.unlock() }; return droppedCoalesced }
    var labDropped: Int { lock.lock(); defer { lock.unlock() }; return droppedLab }
    var deterministicV4Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsDeterministicV4
    }

    var worldViewerV5_1Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsWorldViewerV5_1
    }

    var playerV5_4Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsPlayerV5_4
    }

    var playerInputV5_5Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsPlayerInputV5_5
    }

    func serverHello() -> FlyGymHelloPacket? {
        lock.lock(); defer { lock.unlock() }
        guard let hello = _serverHello, _connected,
              hello.connectionGeneration == _connectionGeneration else { return nil }
        return hello
    }

    func latestSessionState() -> FlyGymSessionStatePacket? {
        lock.lock(); defer { lock.unlock() }
        guard let state = _latestSessionState, _connected,
              state.connectionGeneration == _connectionGeneration else { return nil }
        return state
    }

    func latestExperimentStepResult() -> FlyGymExperimentStepResultPacket? {
        lock.lock(); defer { lock.unlock() }
        guard let result = _latestExperimentStepResult, _connected,
              result.connectionGeneration == _connectionGeneration else { return nil }
        return result
    }

    func latestWorldRenderSnapshot(maxAge: TimeInterval = 1.0) -> WorldRenderSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = _latestWorldRenderSnapshot,
              _connected, snapshot.connectionGeneration == _connectionGeneration,
              max(0, Date().timeIntervalSince(snapshot.receivedAt)) < maxAge else { return nil }
        return snapshot
    }

    func latestRayPickResult(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> RayPickResult? {
        lock.lock(); defer { lock.unlock() }
        guard let result = _latestRayPickResult,
              _connected, result.connectionGeneration == _connectionGeneration,
              max(0, Date().timeIntervalSince(result.receivedAt)) < maxAge else { return nil }
        return result
    }

    func latestPlayerInputResult(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> PlayerInputResult? {
        lock.lock(); defer { lock.unlock() }
        guard let result = _latestPlayerInputResult,
              _connected, result.connectionGeneration == _connectionGeneration,
              max(0, Date().timeIntervalSince(result.receivedAt)) < maxAge else { return nil }
        return result
    }

    private func freshnessLocked(receivedAt: Date?, packetGeneration: UInt64?,
                                 maxAge: TimeInterval, now: Date = Date()) -> FlyGymPacketFreshness {
        let age = receivedAt.map { max(0, now.timeIntervalSince($0)) }
        let sameGeneration = packetGeneration == _connectionGeneration
        let fresh = _connected && sameGeneration && (age.map { $0 < maxAge } ?? false)
        return FlyGymPacketFreshness(connected: _connected,
                                     currentGeneration: _connectionGeneration,
                                     packetGeneration: packetGeneration,
                                     ageSeconds: age,
                                     isFresh: fresh)
    }

    func bodyFreshness(maxAge: TimeInterval = FlyGymBridge.bodyFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestBody?.receivedAt,
                               packetGeneration: _latestBody?.connectionGeneration,
                               maxAge: maxAge)
    }

    func labStateFreshness(maxAge: TimeInterval = FlyGymBridge.labStateFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestLabState?.receivedAt,
                               packetGeneration: _latestLabState?.connectionGeneration,
                               maxAge: maxAge)
    }

    func labAckFreshness(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestLabAck?.receivedAt,
                               packetGeneration: _latestLabAck?.connectionGeneration,
                               maxAge: maxAge)
    }

    func labEventFreshness(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestLabEvent?.receivedAt,
                               packetGeneration: _latestLabEvent?.connectionGeneration,
                               maxAge: maxAge)
    }

    func latestBody(maxAge: TimeInterval = FlyGymBridge.bodyFreshMaxAge) -> FlyGymBodyFeedback? {
        lock.lock(); defer { lock.unlock() }
        guard let b = _latestBody,
              freshnessLocked(receivedAt: b.receivedAt,
                              packetGeneration: b.connectionGeneration,
                              maxAge: maxAge).isFresh else { return nil }
        return b
    }

    func latestLabState(maxAge: TimeInterval? = nil) -> LabRemoteState? {
        lock.lock(); defer { lock.unlock() }
        guard let state = _latestLabState,
              _connected, state.connectionGeneration == _connectionGeneration else { return nil }
        if let maxAge, state.ageSeconds() >= maxAge { return nil }
        return state
    }

    func latestLabAck(maxAge: TimeInterval? = nil) -> LabAck? {
        lock.lock(); defer { lock.unlock() }
        guard let ack = _latestLabAck,
              _connected, ack.connectionGeneration == _connectionGeneration else { return nil }
        if let maxAge, ack.ageSeconds() >= maxAge { return nil }
        return ack
    }

    func latestLabEvent(maxAge: TimeInterval? = nil) -> LabEventNotice? {
        lock.lock(); defer { lock.unlock() }
        guard let event = _latestLabEvent,
              _connected, event.connectionGeneration == _connectionGeneration else { return nil }
        if let maxAge, event.ageSeconds() >= maxAge { return nil }
        return event
    }

    var bodyHz: Double {
        lock.lock(); defer { lock.unlock() }
        guard let body = _latestBody,
              freshnessLocked(receivedAt: body.receivedAt,
                              packetGeneration: body.connectionGeneration,
                              maxAge: FlyGymBridge.bodyFreshMaxAge).isFresh,
              bodyIntervals.count >= 4 else { return 0 }
        let span = bodyIntervals.reduce(0, +)
        return span > 0 ? Double(bodyIntervals.count) / span : 0
    }

    /// Largest receive-to-receive gap in the recent body-feedback window. A live
    /// average Hz can hide stalls, so regression/smoke tests assert this too.
    var maxRecentBodyGap: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let body = _latestBody,
              freshnessLocked(receivedAt: body.receivedAt,
                              packetGeneration: body.connectionGeneration,
                              maxAge: FlyGymBridge.bodyFreshMaxAge).isFresh else { return .infinity }
        return bodyIntervals.max() ?? .infinity
    }

    var statusLine: String {
        lock.lock()
        let c = _connected
        let sent = sentCount, recv = recvCount, mal = malformedCount
        let labSent = labSentCount, labRecv = labRecvCount
        let bodyAge = _latestBody.map { max(0, Date().timeIntervalSince($0.receivedAt)) }
        let bodyFresh = _latestBody.map {
            _connected && $0.connectionGeneration == _connectionGeneration
            && max(0, Date().timeIntervalSince($0.receivedAt)) < FlyGymBridge.bodyFreshMaxAge
        } ?? false
        let hz = { () -> Double in
            guard bodyFresh, self.bodyIntervals.count >= 4 else { return 0 }
            let span = self.bodyIntervals.reduce(0, +)
            return span > 0 ? Double(self.bodyIntervals.count) / span : 0
        }()
        lock.unlock()
        if c {
            let bodyStatus: String
            if bodyFresh, let age = bodyAge {
                bodyStatus = String(format: "%.0f Hz, %.0f ms old", hz, age * 1000)
            } else if let age = bodyAge {
                bodyStatus = String(format: "STALE, %.2f s old", age)
            } else {
                bodyStatus = "waiting"
            }
            return "FlyGym connected - brain \(sent), body \(recv) (\(bodyStatus)), lab \(labSent)/\(labRecv), malformed \(mal)"
        }
        return "FlyGym disconnected (brain continues locally)"
    }

    var labStatusLine: String {
        lock.lock()
        let connected = _connected
        let q = pendingLab.count
        let dropped = droppedLab
        let ack = _latestLabAck
        lock.unlock()
        let a = ack.map { "ack #\($0.id) \($0.ok ? "OK" : "ERR") \($0.message)" } ?? "no ack yet"
        return "\(connected ? "connected" : "disconnected") · queue \(q)/\(labQueueCap) · dropped \(dropped) · \(a)"
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        Thread { [weak self] in self?.sendLoop() }.start()
        Thread { [weak self] in self?.recvLoop() }.start()
    }

    func stop() {
        lock.lock()
        running = false
        let s = sock
        sock = -1
        _connected = false
        clearRemoteStateLocked()
        lock.unlock()
        if s >= 0 { Darwin.shutdown(s, Int32(SHUT_RDWR)); Darwin.close(s) }
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Called from the render thread: only encodes JSON + stores one Data.
    /// Never touches the socket. Latest-packet-wins, so bursts coalesce.
    func sendBrain(_ s: BrainSignals, simMs: Int) {
        let pkt = FlyGymBrainPacket(signals: s, simMs: simMs)
        guard let line = try? JSONEncoder().encode(pkt) else { return }
        var data = line; data.append(0x0A)
        lock.lock()
        if s.escape {
            if pendingEscape != nil { droppedCoalesced += 1 }
            pendingEscape = data
        } else {
            if pending != nil { droppedCoalesced += 1 }
            pending = data
        }
        pendingCount += 1
        lock.unlock()
    }

    private func encodeLine<T: Encodable>(_ packet: T) -> Data? {
        guard var data = try? JSONEncoder().encode(packet) else { return nil }
        data.append(0x0A)
        return data
    }

    /// V4 session control shares the background sender but has its own bounded
    /// ordered lane so pause/resume/handshake traffic cannot be coalesced with
    /// ordinary brain state.
    @discardableResult
    func sendSessionControl(action: String, sessionID: String, epoch: Int,
                            simTick: Int, mode: LabSessionMode,
                            resetScope: [String]? = nil) -> Int? {
        lock.lock()
        let seq = nextSessionControlSeq
        nextSessionControlSeq = nextSessionControlSeq == Int.max ? 1 : nextSessionControlSeq + 1
        lock.unlock()
        let packet = FlyGymSessionControlPacket(sessionID: sessionID,
                                               epoch: max(1, epoch), seq: seq,
                                               simTick: max(0, simTick),
                                               action: action, mode: mode,
                                               resetScope: resetScope)
        guard let data = encodeLine(packet) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard pendingControl.count < controlQueueCap else { return nil }
        if action == "begin" {
            requestedSessionID = sessionID
            requestedEpoch = max(1, epoch)
            requestedSessionMode = mode
            _latestSessionState = nil
            _latestExperimentStepResult = nil
            _latestBody = nil
            _latestLabState = nil
            _latestLabAck = nil
            _latestLabEvent = nil
            _latestWorldRenderSnapshot = nil
            _latestRayPickResult = nil
            _latestPlayerInputResult = nil
            lastBodyAt = nil
            bodyIntervals.removeAll(keepingCapacity: true)
            outstandingExperimentStepSeq = nil
            pendingExperimentStep = nil
            pendingWorldRenderRequest = nil
            pendingRayPicks.removeAll(keepingCapacity: true)
            pendingPlayerInput = nil
            pendingPlayerLookRemainder = [0.0, 0.0]
            nextPlayerInputSeq = 1
        } else if action == "reset", requestedSessionID == sessionID {
            // Reset is the one lifecycle control that intentionally changes the
            // simulation epoch. Promote the expected epoch before the packet is
            // sent so the matching reset confirmation can never be mistaken for
            // delayed old-epoch traffic on the same TCP generation.
            requestedEpoch = max(1, epoch)
            _latestSessionState = nil
            _latestExperimentStepResult = nil
            _latestBody = nil
            _latestLabState = nil
            _latestLabAck = nil
            _latestLabEvent = nil
            _latestWorldRenderSnapshot = nil
            _latestRayPickResult = nil
            _latestPlayerInputResult = nil
            lastBodyAt = nil
            bodyIntervals.removeAll(keepingCapacity: true)
            outstandingExperimentStepSeq = nil
            pendingExperimentStep = nil
            pendingWorldRenderRequest = nil
            pendingRayPicks.removeAll(keepingCapacity: true)
            pendingPlayerInput = nil
            pendingPlayerLookRemainder = [0.0, 0.0]
            nextPlayerInputSeq = 1
        }
        pendingControl.append(data)
        return seq
    }

    /// Queue exactly one deterministic body quantum. `false` means an earlier
    /// request is still pending/outstanding; callers must wait for its result.
    func sendExperimentStep(sessionID: String, epoch: Int, seq: Int,
                            simTick: Int, signals: BrainSignals) -> Bool {
        let packet = FlyGymExperimentStepPacket(
            sessionID: sessionID, epoch: max(1, epoch), seq: seq,
            simTick: max(0, simTick),
            brain: FlyGymBrainPacket(signals: signals, simMs: max(0, simTick)))
        guard let data = encodeLine(packet) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard _connected,
              requestedSessionID == sessionID, requestedEpoch == max(1, epoch),
              pendingExperimentStep == nil, outstandingExperimentStepSeq == nil else { return false }
        pendingExperimentStep = data
        outstandingExperimentStepSeq = seq
        return true
    }

    /// Request one immutable backend-originated render snapshot. Requests are
    /// latest-wins because they are observation only; no simulation mutation is
    /// represented by this lane.
    @discardableResult
    func requestWorldRenderSnapshot() -> Int? {
        lock.lock()
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration,
              hello.supportsWorldViewerV5_1 else { lock.unlock(); return nil }
        let seq = nextViewerSeq
        nextViewerSeq = nextViewerSeq == Int.max ? 1 : nextViewerSeq + 1
        let sessionID = requestedSessionID ?? ""
        let epoch = requestedEpoch ?? 0
        let protocolVersion = max(FlyGymProtocolV4.version, hello.protocolVersion)
        lock.unlock()

        var packet = WorldRenderRequest(sessionID: sessionID, epoch: epoch, seq: seq)
        packet.protocolVersion = protocolVersion
        guard let data = encodeLine(packet) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard _connected else { return nil }
        pendingWorldRenderRequest = data
        return seq
    }

    /// Send a read-only ray query. SceneKit only computes the ray; Python/MuJoCo
    /// decides the authoritative hit against the current simulation-owner state.
    @discardableResult
    func sendRayPick(rayOriginMM: [Double], rayDirection: [Double],
                     sourceSnapshotSeq: Int, sourceWorldRevision: Int,
                     sourceSimTick: Int) -> Int? {
        guard rayOriginMM.count == 3, rayOriginMM.allSatisfy(\.isFinite),
              rayDirection.count == 3, rayDirection.allSatisfy(\.isFinite) else { return nil }
        guard sourceSnapshotSeq > 0, sourceWorldRevision >= 0, sourceSimTick >= 0 else { return nil }
        let norm = sqrt(rayDirection.reduce(0) { $0 + $1 * $1 })
        guard norm >= 1e-12 else { return nil }
        let direction = rayDirection.map { $0 / norm }

        lock.lock()
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration,
              hello.supportsWorldViewerV5_1,
              pendingRayPicks.count < rayPickQueueCap else { lock.unlock(); return nil }
        let seq = nextViewerSeq
        nextViewerSeq = nextViewerSeq == Int.max ? 1 : nextViewerSeq + 1
        let sessionID = requestedSessionID ?? ""
        let epoch = requestedEpoch ?? 0
        let protocolVersion = max(FlyGymProtocolV4.version, hello.protocolVersion)
        lock.unlock()

        var packet = RayPickRequest(sessionID: sessionID, epoch: epoch, seq: seq,
                                    sourceSnapshotSeq: sourceSnapshotSeq,
                                    sourceWorldRevision: sourceWorldRevision,
                                    sourceSimTick: sourceSimTick,
                                    rayOriginMM: rayOriginMM, rayDirection: direction)
        packet.protocolVersion = protocolVersion
        guard let data = encodeLine(packet) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard _connected, pendingRayPicks.count < rayPickQueueCap else { return nil }
        pendingRayPicks.append(data)
        return seq
    }

    /// V5.5 continuous participant state. Axes/held state are latest-wins while
    /// unsent look deltas are accumulated so sender throttling cannot silently
    /// discard mouse motion. Deterministic experiment steps never overtake this
    /// lane when the input targets their boundary.
    private func splitPlayerLook(_ total: [Double]) -> (chunk: [Double], remainder: [Double]) {
        let limit = PlayerInputPacket.maxLookDelta
        let chunk = total.map { max(-limit, min(limit, $0)) }
        return (chunk, [total[0] - chunk[0], total[1] - chunk[1]])
    }

    private func allocatePlayerInputSeqLocked() -> Int? {
        guard nextPlayerInputSeq >= 0,
              nextPlayerInputSeq <= PlayerInputPacket.maxSeq else { return nil }
        let seq = nextPlayerInputSeq
        nextPlayerInputSeq = seq == PlayerInputPacket.maxSeq ? PlayerInputPacket.maxSeq + 1 : seq + 1
        return seq
    }

    private func promotePlayerLookRemainderLocked(afterSent data: Data) {
        guard pendingPlayerInput == nil,
              pendingPlayerLookRemainder.count == 2,
              (pendingPlayerLookRemainder[0] != 0 || pendingPlayerLookRemainder[1] != 0),
              let prior = decodePlayerInputLine(data),
              let seq = allocatePlayerInputSeqLocked() else { return }
        let split = splitPlayerLook(pendingPlayerLookRemainder)
        let packet = PlayerInputPacket(
            protocolVersion: prior.protocolVersion,
            actorID: prior.actorID,
            sessionID: prior.sessionID,
            epoch: prior.epoch,
            seq: seq,
            requestedTick: prior.requestedTick,
            moveAxes: prior.moveAxes,
            lookDelta: split.chunk,
            heldActions: prior.heldActions)
        guard let encoded = encodeLine(packet) else { return }
        pendingPlayerInput = encoded
        pendingPlayerLookRemainder = split.remainder
    }

    @discardableResult
    func sendPlayerInput(actorID: String = "player", sessionID: String, epoch: Int,
                         requestedTick: Int, moveAxes: [Double], lookDelta: [Double],
                         heldActions: [String], discardPendingLook: Bool = false) -> Int? {
        guard moveAxes.count == 2, moveAxes.allSatisfy(\.isFinite),
              lookDelta.count == 2, lookDelta.allSatisfy(\.isFinite),
              sessionID.count <= 128, epoch >= 0,
              requestedTick >= 0, requestedTick <= PlayerInputPacket.maxTick else { return nil }

        lock.lock()
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration,
              hello.supportsPlayerInputV5_5 else { lock.unlock(); return nil }
        if let expectedSession = requestedSessionID {
            guard sessionID == expectedSession, epoch == requestedEpoch else {
                lock.unlock(); return nil
            }
        } else {
            guard sessionID.isEmpty, epoch == 0 else { lock.unlock(); return nil }
        }
        let protocolVersion = max(FlyGymProtocolV4.version, hello.protocolVersion)

        if discardPendingLook {
            // Safety release (Esc/focus/mode loss) supersedes any unsent mouse
            // motion. A neutral packet must not inherit a stale look delta or
            // remainder that was captured before release.
            pendingPlayerInput = nil
            pendingPlayerLookRemainder = [0.0, 0.0]
        }
        var mergedLook = [
            lookDelta[0] + pendingPlayerLookRemainder[0],
            lookDelta[1] + pendingPlayerLookRemainder[1],
        ]
        if let pendingPlayerInput,
           let previous = decodePlayerInputLine(pendingPlayerInput),
           previous.actorID == actorID,
           previous.sessionID == sessionID,
           previous.epoch == max(0, epoch) {
            mergedLook[0] += previous.lookDelta[0]
            mergedLook[1] += previous.lookDelta[1]
        }
        guard mergedLook.allSatisfy(\.isFinite),
              let seq = allocatePlayerInputSeqLocked() else {
            lock.unlock(); return nil
        }
        let split = splitPlayerLook(mergedLook)
        let packet = PlayerInputPacket(protocolVersion: protocolVersion,
                                       actorID: actorID,
                                       sessionID: sessionID,
                                       epoch: epoch,
                                       seq: seq,
                                       requestedTick: requestedTick,
                                       moveAxes: moveAxes,
                                       lookDelta: split.chunk,
                                       heldActions: heldActions)
        guard let data = encodeLine(packet) else { lock.unlock(); return nil }
        pendingPlayerInput = data
        pendingPlayerLookRemainder = split.remainder
        lock.unlock()
        return seq
    }

    /// Enqueue one ordered experiment command. AppKit calls this directly; it
    /// performs only JSON encoding and a bounded in-memory append.
    @discardableResult
    func sendLab(action: String, target: String? = nil,
                 x: Double? = nil, y: Double? = nil, z: Double? = nil,
                 size: Double? = nil, speed: Double? = nil,
                 strength: Double? = nil, durationMs: Int? = nil,
                 value: Double? = nil, directionDeg: Double? = nil,
                 endDistance: Double? = nil, physical: Bool? = nil,
                 sensory: Bool? = nil, continuous: Bool? = nil,
                 mode: String? = nil,
                 protocolVersion: Int? = nil, sessionID: String? = nil,
                 epoch: Int? = nil, requestedTick: Int? = nil) -> Int {
        lock.lock()
        let id = nextLabID
        nextLabID = nextLabID == Int.max ? 1 : nextLabID + 1
        lock.unlock()
        let cmd = LabCommand(id: id, action: action, target: target,
                             x: x, y: y, z: z, size: size, speed: speed,
                             strength: strength, durationMs: durationMs, value: value,
                             directionDeg: directionDeg, endDistance: endDistance,
                             physical: physical, sensory: sensory,
                             continuous: continuous, mode: mode,
                             protocolVersion: protocolVersion, sessionID: sessionID,
                             epoch: epoch, requestedTick: requestedTick)
        guard let line = try? JSONEncoder().encode(cmd) else { return id }
        var data = line; data.append(0x0A)
        lock.lock()
        if pendingLab.count >= labQueueCap {
            if protocolVersion ?? 0 >= FlyGymProtocolV4.version {
                // V4 discrete experiment mutations fail closed. Never evict an
                // older command and later make the new one look successfully
                // queued; surface a local explicit failure ACK instead.
                droppedLab += 1
                _latestLabAck = LabAck(type: "lab_ack", id: id, ok: false,
                                       action: action, message: "local lab command queue full",
                                       appliedTick: nil, appliedEpoch: nil,
                                       status: "queue_full", sessionID: sessionID,
                                       epoch: epoch, simTick: requestedTick,
                                       receivedAt: Date(),
                                       connectionGeneration: _connectionGeneration)
                lock.unlock()
                return id
            } else {
                pendingLab.removeFirst()
                droppedLab += 1
            }
        }
        pendingLab.append(data)
        lock.unlock()
        return id
    }

    // -- test hook: one latest-state slot + one escape-pulse slot.
    func pendingDepth() -> Int {
        lock.lock(); defer { lock.unlock() }
        return (pending == nil ? 0 : 1) + (pendingEscape == nil ? 0 : 1)
            + pendingLab.count + pendingControl.count + (pendingExperimentStep == nil ? 0 : 1)
            + (pendingWorldRenderRequest == nil ? 0 : 1) + pendingRayPicks.count
            + (pendingPlayerInput == nil ? 0 : 1)
    }


    func pendingLabDepth() -> Int { lock.lock(); defer { lock.unlock() }; return pendingLab.count }

    private func clearRemoteStateLocked() {
        _latestBody = nil
        _latestLabState = nil
        _latestLabAck = nil
        _latestLabEvent = nil
        _serverHello = nil
        _latestSessionState = nil
        _latestExperimentStepResult = nil
        _latestWorldRenderSnapshot = nil
        _latestRayPickResult = nil
        _latestPlayerInputResult = nil
        outstandingExperimentStepSeq = nil
        pendingExperimentStep = nil
        pendingPlayerInput = nil
        pendingPlayerLookRemainder = [0.0, 0.0]
        lastBodyAt = nil
        bodyIntervals.removeAll(keepingCapacity: true)
    }

    /// V4 deterministic packets must carry the complete simulation identity.
    /// Interactive sessions keep tolerant legacy parsing so a V3-compatible peer
    /// can still acknowledge ordinary UI commands without V4 envelope fields.
    private func matchesRequestedSessionLocked(sessionID: String?, epoch: Int?) -> Bool {
        guard let expectedSession = requestedSessionID else { return true }
        let expectedEpoch = requestedEpoch
        if requestedSessionMode == .deterministic {
            return sessionID == expectedSession && epoch == expectedEpoch
        }
        if let sessionID, sessionID != expectedSession { return false }
        if let epoch, epoch != expectedEpoch { return false }
        return true
    }

    private func matchesViewerSessionLocked(sessionID: String, epoch: Int) -> Bool {
        if let expectedSession = requestedSessionID {
            return sessionID == expectedSession && epoch == requestedEpoch
        }
        // The backend uses this explicit identity before a V4 session begins.
        return sessionID.isEmpty && epoch == 0
    }

    private func recordDroppedLabLocked(_ data: Data, reason: String) {
        guard let command = try? JSONDecoder().decode(LabCommand.self, from: data),
              command.protocolVersion ?? 0 >= FlyGymProtocolV4.version else { return }
        _latestLabAck = LabAck(type: "lab_ack", id: command.id, ok: false,
                               action: command.action, message: reason,
                               appliedTick: nil, appliedEpoch: nil,
                               status: "queue_full", sessionID: command.sessionID,
                               epoch: command.epoch, simTick: command.requestedTick,
                               receivedAt: Date(),
                               connectionGeneration: _connectionGeneration)
    }

    private func beginConnectionLocked(_ fd: Int32) {
        sock = fd
        _connected = true
        _connectionGeneration &+= 1
        if _connectionGeneration == 0 { _connectionGeneration = 1 }
        clearRemoteStateLocked()
        pendingControl.removeAll(keepingCapacity: true)
        pendingWorldRenderRequest = nil
        pendingRayPicks.removeAll(keepingCapacity: true)
        pendingPlayerInput = nil
        pendingPlayerLookRemainder = [0.0, 0.0]
        if let hello = encodeLine(FlyGymHelloPacket()) {
            pendingControl.append(hello)
        }
        lastSend = .distantPast
        lastNormalBrainSendAt = .distantPast
    }

    private func currentConnectionLocked(fd: Int32, generation: UInt64) -> Bool {
        _connected && sock == fd && _connectionGeneration == generation
    }

    private func dequeueNextLocked(now: Date) -> FlyGymPendingSend? {
        if !pendingControl.isEmpty {
            return FlyGymPendingSend(lane: .control, data: pendingControl.removeFirst())
        }
        // A deterministic step defines an application boundary. Any lab command
        // already queued by Swift before that step reservation must reach Python
        // first; otherwise the step lane could overtake a requested-tick command
        // and force it to apply one quantum late. Wall time may slow down here —
        // deterministic experiment order must not.
        if pendingExperimentStep != nil, let input = pendingPlayerInput {
            pendingPlayerInput = nil
            return FlyGymPendingSend(lane: .playerInput, data: input)
        }
        if pendingExperimentStep != nil, !pendingLab.isEmpty {
            return FlyGymPendingSend(lane: .lab, data: pendingLab.removeFirst())
        }
        if let step = pendingExperimentStep {
            pendingExperimentStep = nil
            return FlyGymPendingSend(lane: .experimentStep, data: step)
        }
        if let urgent = pendingEscape {
            pendingEscape = nil
            return FlyGymPendingSend(lane: .escape, data: urgent)
        }
        if let brain = pending,
           pendingLab.isEmpty || now.timeIntervalSince(lastNormalBrainSendAt) >= maxNormalBrainGap {
            pending = nil
            return FlyGymPendingSend(lane: .brain, data: brain)
        }
        if let input = pendingPlayerInput {
            pendingPlayerInput = nil
            return FlyGymPendingSend(lane: .playerInput, data: input)
        }
        if !pendingLab.isEmpty {
            return FlyGymPendingSend(lane: .lab, data: pendingLab.removeFirst())
        }
        if !pendingRayPicks.isEmpty {
            return FlyGymPendingSend(lane: .rayPick, data: pendingRayPicks.removeFirst())
        }
        if let request = pendingWorldRenderRequest {
            pendingWorldRenderRequest = nil
            return FlyGymPendingSend(lane: .worldRender, data: request)
        }
        if let brain = pending {
            pending = nil
            return FlyGymPendingSend(lane: .brain, data: brain)
        }
        return nil
    }

    private func requeueLocked(_ item: FlyGymPendingSend) {
        switch item.lane {
        case .escape:
            if pendingEscape == nil { pendingEscape = item.data }
        case .lab:
            pendingLab.insert(item.data, at: 0)
            if pendingLab.count > labQueueCap {
                let dropped = pendingLab.removeLast()
                droppedLab += 1
                recordDroppedLabLocked(dropped, reason: "local lab command queue full while retrying send")
            }
        case .brain:
            // If a newer latest-state packet arrived while send() was running,
            // keep the newer packet rather than restoring an obsolete snapshot.
            if pending == nil { pending = item.data }
        case .control:
            pendingControl.insert(item.data, at: 0)
            if pendingControl.count > controlQueueCap { pendingControl.removeLast() }
        case .experimentStep:
            if pendingExperimentStep == nil { pendingExperimentStep = item.data }
        case .worldRender:
            // Observation requests are latest-wins. If a newer request arrived
            // during send(), keep the newer one.
            if pendingWorldRenderRequest == nil { pendingWorldRenderRequest = item.data }
        case .rayPick:
            pendingRayPicks.insert(item.data, at: 0)
            if pendingRayPicks.count > rayPickQueueCap { pendingRayPicks.removeLast() }
        case .playerInput:
            // Continuous state is latest-wins. Never restore an older packet over
            // a newer key/focus transition that arrived during send().
            if pendingPlayerInput == nil { pendingPlayerInput = item.data }
        }
    }

    private func acceptInboundLine(_ line: Data, fd: Int32, generation: UInt64,
                                   receivedAt: Date = Date()) -> Bool {
        if var hello = parseHelloLine(line) {
            hello.receivedAt = receivedAt
            hello.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            _serverHello = hello
            if !hello.supportsPlayerInputV5_5 {
                pendingPlayerInput = nil
                pendingPlayerLookRemainder = [0.0, 0.0]
            }
            lock.unlock()
            return true
        }
        if var result = parsePlayerInputResultLine(line) {
            result.receivedAt = receivedAt
            result.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            if !matchesViewerSessionLocked(sessionID: result.sessionID, epoch: result.epoch) {
                staleSessionPacketCount += 1
                lock.unlock(); return true
            }
            _latestPlayerInputResult = result
            lock.unlock()
            return true
        }
        if var session = parseSessionStateLine(line) {
            session.receivedAt = receivedAt
            session.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            if let expected = requestedSessionID {
                let wrongSession = session.sessionID != expected
                let wrongEpoch = requestedEpoch.map { session.epoch != $0 } ?? false
                if wrongSession || wrongEpoch {
                    staleSessionPacketCount += 1
                    lock.unlock(); return true
                }
            }
            _latestSessionState = session
            lock.unlock()
            return true
        }
        if var result = parseExperimentStepResultLine(line) {
            result.receivedAt = receivedAt
            result.connectionGeneration = generation
            var fb: FlyGymBodyFeedback?
            if result.ok {
                var value = FlyGymBodyFeedback(result.body)
                value.receivedAt = receivedAt
                value.connectionGeneration = generation
                fb = value
            }
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            let expectedSession = requestedSessionID
            let expectedEpoch = requestedEpoch
            let expectedSeq = outstandingExperimentStepSeq
            guard expectedSession == result.sessionID,
                  expectedEpoch == result.epoch,
                  expectedSeq == result.seq else {
                staleSessionPacketCount += 1
                lock.unlock(); return true
            }
            _latestExperimentStepResult = result
            outstandingExperimentStepSeq = nil
            experimentStepRecvCount += 1
            if let fb {
                if let prev = lastBodyAt {
                    let interval = receivedAt.timeIntervalSince(prev)
                    if interval > 0 {
                        bodyIntervals.append(interval)
                        if bodyIntervals.count > 120 { bodyIntervals.removeFirst(bodyIntervals.count - 120) }
                    }
                }
                lastBodyAt = receivedAt
                _latestBody = fb
                recvCount += 1
            }
            lock.unlock()
            return true
        }
        if var snapshot = parseWorldRenderSnapshotLine(line) {
            snapshot.receivedAt = receivedAt
            snapshot.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            guard _serverHello?.supportsWorldViewerV5_1 == true,
                  matchesViewerSessionLocked(sessionID: snapshot.sessionID, epoch: snapshot.epoch) else {
                staleSessionPacketCount += 1
                lock.unlock(); return true
            }
            if snapshot.ok, let incomingID = snapshot.snapshotID,
               let previous = _latestWorldRenderSnapshot,
               previous.ok, previous.sessionID == snapshot.sessionID,
               previous.epoch == snapshot.epoch,
               let previousID = previous.snapshotID, incomingID <= previousID {
                lock.unlock(); return true
            }
            _latestWorldRenderSnapshot = snapshot
            lock.unlock()
            return true
        }
        if var pick = parseRayPickResultLine(line) {
            pick.receivedAt = receivedAt
            pick.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            guard _serverHello?.supportsWorldViewerV5_1 == true,
                  matchesViewerSessionLocked(sessionID: pick.sessionID, epoch: pick.epoch) else {
                staleSessionPacketCount += 1
                lock.unlock(); return true
            }
            if let previous = _latestRayPickResult,
               previous.sessionID == pick.sessionID, previous.epoch == pick.epoch,
               pick.seq < previous.seq {
                lock.unlock(); return true
            }
            _latestRayPickResult = pick
            lock.unlock()
            return true
        }
        if let pkt = parseBodyLine(line) {
            var fb = FlyGymBodyFeedback(pkt)
            fb.receivedAt = receivedAt
            fb.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            if let prev = lastBodyAt {
                let interval = receivedAt.timeIntervalSince(prev)
                if interval > 0 {
                    bodyIntervals.append(interval)
                    if bodyIntervals.count > 120 { bodyIntervals.removeFirst(bodyIntervals.count - 120) }
                }
            }
            lastBodyAt = receivedAt
            _latestBody = fb
            recvCount += 1
            lock.unlock()
            return true
        }
        if var state = parseLabStateLine(line) {
            state.receivedAt = receivedAt
            state.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            if !matchesRequestedSessionLocked(sessionID: state.sessionID, epoch: state.epoch) {
                staleSessionPacketCount += 1
                lock.unlock(); return true
            }
            _latestLabState = state
            labRecvCount += 1
            if let ackID = state.ack {
                _latestLabAck = LabAck(type: "lab_ack", id: ackID,
                                       ok: state.ok ?? (state.error == nil),
                                       action: state.lastAction ?? "",
                                       message: state.error ?? "ok",
                                       appliedTick: state.appliedTick,
                                       appliedEpoch: state.appliedEpoch,
                                       status: state.status,
                                       sessionID: state.sessionID,
                                       epoch: state.epoch,
                                       simTick: state.simTick,
                                       receivedAt: receivedAt,
                                       connectionGeneration: generation)
            }
            lock.unlock()
            return true
        }
        if var ack = parseLabAckLine(line) {
            ack.receivedAt = receivedAt
            ack.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            if !matchesRequestedSessionLocked(sessionID: ack.sessionID, epoch: ack.epoch) {
                staleSessionPacketCount += 1
                lock.unlock(); return true
            }
            _latestLabAck = ack
            labRecvCount += 1
            lock.unlock()
            return true
        }
        if var event = parseLabEventLine(line) {
            event.receivedAt = receivedAt
            event.connectionGeneration = generation
            lock.lock()
            guard currentConnectionLocked(fd: fd, generation: generation) else {
                lock.unlock(); return true
            }
            _latestLabEvent = event
            labRecvCount += 1
            lock.unlock()
            return true
        }
        return false
    }

    // MARK: test hooks (same production lifecycle/arbitration paths, no sockets)

    fileprivate func beginConnectionForTesting() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        beginConnectionLocked(-2)
        return _connectionGeneration
    }

    fileprivate func receiveLineForTesting(_ line: Data, at receivedAt: Date = Date()) -> Bool {
        lock.lock()
        let fd = sock
        let generation = _connectionGeneration
        lock.unlock()
        return acceptInboundLine(line, fd: fd, generation: generation, receivedAt: receivedAt)
    }

    /// Test hook for the exact production line-framing path. The caller owns
    /// `buffer`, which lets tests feed the same JSON line in recv()-sized chunks.
    fileprivate func receiveBytesForTesting(_ chunk: Data, buffer: inout Data,
                                             at receivedAt: Date = Date()) {
        lock.lock()
        let fd = sock
        let generation = _connectionGeneration
        lock.unlock()
        buffer.append(chunk)
        drainInboundBuffer(&buffer, fd: fd, generation: generation, receivedAt: receivedAt)
    }

    fileprivate func disconnectForTesting() {
        lock.lock()
        let fd = sock
        let generation = _connectionGeneration
        lock.unlock()
        markDown(fd, generation: generation)
    }

    fileprivate func setNextPlayerInputSeqForTesting(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        nextPlayerInputSeq = value
    }

    fileprivate func dequeueLaneForTesting(at now: Date) -> FlyGymSendLane? {
        lock.lock(); defer { lock.unlock() }
        guard let item = dequeueNextLocked(now: now) else { return nil }
        if item.lane == .brain { lastNormalBrainSendAt = now }
        if item.lane == .playerInput {
            // Test dequeue models a successful production send so any bounded
            // look remainder is promoted exactly as sendLoop would do.
            promotePlayerLookRemainderLocked(afterSent: item.data)
        }
        return item.lane
    }

    fileprivate func dequeueSendForTesting(at now: Date) -> (FlyGymSendLane, Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let item = dequeueNextLocked(now: now) else { return nil }
        if item.lane == .brain { lastNormalBrainSendAt = now }
        if item.lane == .playerInput {
            promotePlayerLookRemainderLocked(afterSent: item.data)
        }
        return (item.lane, item.data)
    }

    // MARK: threads

    private func openConnection() -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &tv) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { q in
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, q, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, q, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = host.withCString { Darwin.inet_addr($0) }
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
                Darwin.connect(fd, q, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    private func sendLoop() {
        while isRunning() {
            lock.lock()
            let fd = sock
            let ok = _connected
            let generation = _connectionGeneration
            lock.unlock()
            if !ok || fd < 0 {
                lock.lock(); connectAttempts += 1; lock.unlock()
                let fd2 = openConnection()
                var closeUnused = false
                lock.lock()
                if fd2 >= 0 && running && !_connected && sock < 0 {
                    beginConnectionLocked(fd2)
                } else if fd2 >= 0 {
                    closeUnused = true
                }
                lock.unlock()
                if closeUnused { Darwin.shutdown(fd2, Int32(SHUT_RDWR)); Darwin.close(fd2) }
                if fd2 < 0 { Thread.sleep(forTimeInterval: 0.5); continue }
                continue
            }
            lock.lock()
            let now = Date()
            let sendWait = minSendInterval - now.timeIntervalSince(lastSend)
            let item = sendWait <= 0 ? dequeueNextLocked(now: now) : nil
            lock.unlock()
            if sendWait > 0 {
                Thread.sleep(forTimeInterval: min(0.005, max(0.001, sendWait)))
                continue
            }
            if let item {
                let d = item.data
                var sent = 0
                d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                    var cur = p.baseAddress!
                    var left = d.count
                    while left > 0 {
                        let n = Darwin.send(fd, cur, left, 0)
                        if n <= 0 { break }
                        sent += n; cur = cur.advanced(by: n); left -= n
                    }
                }
                lock.lock()
                if sent == d.count {
                    let sentAt = Date()
                    switch item.lane {
                    case .brain:
                        sentCount += 1
                        lastNormalBrainSendAt = sentAt
                    case .escape:
                        sentCount += 1
                    case .lab:
                        labSentCount += 1
                    case .control:
                        controlSentCount += 1
                    case .experimentStep:
                        experimentStepSentCount += 1
                    case .worldRender, .rayPick:
                        break
                    case .playerInput:
                        promotePlayerLookRemainderLocked(afterSent: d)
                    }
                    lastSend = sentAt
                }
                else {
                    requeueLocked(item)
                }
                lock.unlock()
                if sent != d.count { markDown(fd, generation: generation) }
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private func markDown(_ fd: Int32, generation: UInt64) {
        lock.lock()
        let shouldClose = sock == fd && _connectionGeneration == generation
        if shouldClose {
            sock = -1
            _connected = false
            clearRemoteStateLocked()
        }
        lock.unlock()
        // sendLoop and recvLoop can discover the same failure concurrently.
        // Only the first thread that still owns this descriptor may close it;
        // otherwise a reused descriptor for a new connection could be closed.
        if shouldClose && fd >= 0 {
            Darwin.shutdown(fd, Int32(SHUT_RDWR)); Darwin.close(fd)
        }
    }

    /// Split newline-delimited protocol frames, route complete lines through the
    /// production parser/arbitration path, and bound malformed partial input.
    private func drainInboundBuffer(_ buf: inout Data, fd: Int32, generation: UInt64,
                                    receivedAt: Date = Date()) {
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineLength = buf.distance(from: buf.startIndex, to: nl)
            if lineLength > maxInboundLineBytes {
                buf.removeSubrange(buf.startIndex...nl)
                lock.lock()
                if currentConnectionLocked(fd: fd, generation: generation) {
                    malformedCount += 1
                }
                lock.unlock()
                continue
            }
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if line.isEmpty { continue }
            if !acceptInboundLine(line, fd: fd, generation: generation, receivedAt: receivedAt) {
                lock.lock()
                if currentConnectionLocked(fd: fd, generation: generation) {
                    malformedCount += 1
                }
                lock.unlock()
            }
        }
        if buf.count > maxInboundLineBytes {
            buf.removeAll(keepingCapacity: true)
            lock.lock()
            if currentConnectionLocked(fd: fd, generation: generation) {
                malformedCount += 1
            }
            lock.unlock()
        }
    }

    private func recvLoop() {
        var buf = Data()
        var bufferFD: Int32 = -1
        var bufferGeneration: UInt64 = 0
        let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { tmp.deallocate() }
        while isRunning() {
            lock.lock()
            let fd = sock
            let ok = _connected
            let generation = _connectionGeneration
            lock.unlock()
            if !ok || fd < 0 {
                buf.removeAll(keepingCapacity: true)
                bufferFD = -1
                bufferGeneration = 0
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if fd != bufferFD || generation != bufferGeneration {
                buf.removeAll(keepingCapacity: true)
                bufferFD = fd
                bufferGeneration = generation
            }
            let n = Darwin.recv(fd, tmp, 4096, 0)
            if n > 0 {
                buf.append(tmp, count: n)
                drainInboundBuffer(&buf, fd: fd, generation: generation)
            } else if n == 0 {
                markDown(fd, generation: generation); buf.removeAll() // orderly close -> reconnect
                bufferFD = -1; bufferGeneration = 0
            } else {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    markDown(fd, generation: generation); buf.removeAll()
                    bufferFD = -1; bufferGeneration = 0
                }
                // else: timeout tick, socket still alive
            }
        }
    }
}

// MARK: - Headless self-test (--bridgetest, no sim, no sockets)

func runBridgeTest() {
    var failures = 0
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        print((cond ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !cond { failures += 1 }
    }
    // 1. BrainSignals serialization: all keys present, escape pulse preserved.
    var s = BrainSignals()
    s.escape = true; s.walkDrive = 0.52; s.turnBias = -0.18; s.sleep = false
    s.backward = true; s.groomDrive = 0.02; s.wingDrive = 0.1; s.arousal = 0.31
    let pkt = FlyGymBrainPacket(signals: s, simMs: 1234)
    let data = (try? JSONEncoder().encode(pkt)) ?? Data()
    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    check("brain keys", (obj["type"] as? String) == "brain"
        && (obj["walk"] as? Double ?? -1) == 0.52
        && (obj["turn"] as? Double ?? 9) == -0.18
        && (obj["escape"] as? Bool) == true
        && (obj["backward"] as? Bool) == true
        && abs((obj["t"] as? Double ?? -1) - 1.234) < 1e-9)
    // 2/6. body parse of a well-formed line.
    let line = #"{"type":"body","t":1.238,"sim_dt":0.002,"wall_dt":0.020,"sim_wall_ratio":0.1,"controller_left":0.21,"controller_right":0.43,"wind_strength":0.7,"wind_direction_deg":-30,"wind_sensory":true,"touch_strength":0.55,"touch_sensory":true,"vx":0.013,"yaw_rate":-0.12,"contacts":[1,1,0,0,1,0],"left_contact":0.67,"right_contact":0.33,"loom_left":0.7,"loom_right":0.2,"brightness":0.4,"eye_sample_sim_tick":1200,"odor_left":0.75,"odor_right":0.2,"nearest_food_distance_mm":12.5,"position_x_mm":14.5,"position_y_mm":-3.25,"heading_rad":1.25,"bearing":0.5}"#
    let body = parseBodyLine(Data(line.utf8))
    check("body parse", body != nil && abs((body?.vx ?? 9) - 0.013) < 1e-9
        && abs((body?.t ?? -1) - 1.238) < 1e-9
        && abs((body?.simDt ?? -1) - 0.002) < 1e-9
        && abs((body?.wallDt ?? -1) - 0.020) < 1e-9
        && abs((body?.simWallRatio ?? -1) - 0.1) < 1e-9
        && abs((body?.controllerLeft ?? -9) - 0.21) < 1e-9
        && abs((body?.controllerRight ?? -9) - 0.43) < 1e-9
        && abs((body?.windStrength ?? -9) - 0.7) < 1e-9
        && abs((body?.windDirectionDeg ?? 9) + 30) < 1e-9
        && body?.windSensory == true
        && abs((body?.touchStrength ?? -9) - 0.55) < 1e-9
        && body?.touchSensory == true
        && (body?.contacts ?? []) == [1, 1, 0, 0, 1, 0]
        && abs((body?.leftContact ?? -1) - 0.67) < 1e-9
        && abs((body?.loomLeft ?? -1) - 0.7) < 1e-9
        && body?.eyeSampleSimTick == 1200
        && abs((body?.odorLeft ?? -1) - 0.75) < 1e-9
        && abs((body?.odorRight ?? -1) - 0.2) < 1e-9
        && abs((body?.nearestFoodDistanceMm ?? -1) - 12.5) < 1e-9
        && abs((body?.positionXmm ?? -999) - 14.5) < 1e-9
        && abs((body?.positionYmm ?? 999) + 3.25) < 1e-9
        && abs((body?.headingRad ?? -9) - 1.25) < 1e-9)
    // 7. clamping.
    let wild = #"{"type":"body","sim_dt":99,"wall_dt":-3,"sim_wall_ratio":9999,"vx":99,"yaw_rate":-99,"contacts":[9,-9,2,2,2,2,2,2],"left_contact":5,"right_contact":-5,"loom_left":9,"loom_right":-2,"brightness":7,"odor_left":9,"odor_right":-2,"nearest_food_distance_mm":-4,"heading_rad":99,"bearing":-9}"#
    let c = parseBodyLine(Data(wild.utf8))
    check("feedback clamps", c?.vx == 2.0 && c?.yawRate == -20.0
        && c?.simDt == 10.0 && c?.wallDt == 0.0 && c?.simWallRatio == 1000.0
        && (c?.contacts ?? []) == [1, 0, 1, 1, 1, 1]
        && c?.leftContact == 1.0 && c?.rightContact == 0.0
        && c?.loomLeft == 1.0 && c?.loomRight == 0.0 && c?.brightness == 1.0
        && c?.odorLeft == 1.0 && c?.odorRight == 0.0 && c?.nearestFoodDistanceMm == 0.0
        && c?.headingRad == Double.pi
        && c?.bearing == -1.0)
    // 2. malformed lines throw (recvLoop counts and skips them).
    var malformed = 0
    for bad in ["not json", "[1,2]", #"{"type":"nope"}"#, "", "{\"type\":\"body\",\"vx\":}"] {
        if parseBodyLine(Data(bad.utf8)) == nil {
            malformed += 1
        }
    }
    check("malformed rejected", malformed == 5, "\(malformed)/5")

    // V5.1 atomic render protocol. The viewport may only consume this packet;
    // malformed/mixed payloads never fall back to joining body + lab_state.
    let snapshotLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":2,"world_revision":3,"fly":{"id":"fly","position_mm":[1.0,2.0,0.7],"orientation_quat_xyzw":[0.0,0.0,0.0,1.0]},"objects":[{"id":"box_1","shape":"box","position_mm":[12.0,-3.0,4.0],"orientation_quat_xyzw":[0.0,0.0,0.0,1.0],"size_mm":[6.0,8.0,8.0],"revision":2,"collidable":true}]}"#
    let snapshotParsed = parseWorldRenderSnapshotLine(Data(snapshotLine.utf8))
    check("V5 atomic world snapshot strict parse",
          snapshotParsed?.snapshotID == 2 && snapshotParsed?.revision == 3
          && snapshotParsed?.simTick == 40 && snapshotParsed?.objects.first?.id == "box_1"
          && snapshotParsed?.fly?.positionMM == [1.0, 2.0, 0.7])
    let badSnapshotVector = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":2,"world_revision":3,"fly":{"id":"fly","position_mm":[1.0,2.0],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#
    let badSnapshotQuat = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":2,"world_revision":3,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,0]},"objects":[]}"#
    let aliasSnapshot = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_id":2,"revision":3,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#
    check("V5 snapshot rejects invalid vector/quaternion",
          parseWorldRenderSnapshotLine(Data(badSnapshotVector.utf8)) == nil
          && parseWorldRenderSnapshotLine(Data(badSnapshotQuat.utf8)) == nil)
    check("V5 snapshot wire names are canonical",
          parseWorldRenderSnapshotLine(Data(aliasSnapshot.utf8)) == nil)

    let playerSnapshotLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":4,"sim_tick":40,"ok":true,"snapshot_seq":4,"world_revision":6,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"actor_id":"player","position_mm":[24,0,2.5],"orientation_quat_xyzw":[0,0,0,1],"collision_radius_mm":2.5,"mode":"participate"}}"#
    let playerSnapshot = parseWorldRenderSnapshotLine(Data(playerSnapshotLine.utf8))
    check("V5.4 player pose preserves collision/display contract",
          playerSnapshot?.player?.id == "player"
          && playerSnapshot?.player?.positionMM == [24, 0, 2.5]
          && playerSnapshot?.player?.collisionRadiusMM == 2.5
          && playerSnapshot?.player?.mode == "participate")

    let v5Bridge = FlyGymBridge()
    let v5Generation = v5Bridge.beginConnectionForTesting()
    // Drain Swift's hello, then install a server hello that explicitly advertises
    // V5.1. A V4-only peer must leave the viewport disabled.
    _ = v5Bridge.dequeueLaneForTesting(at: Date())
    let v5Hello = #"{"type":"hello","protocol_version":4,"role":"python","capabilities":["applied_tick","deterministic_experiment","epoch","pause_barrier","world_render_snapshot","ray_pick","player_body"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#
    _ = v5Bridge.receiveLineForTesting(Data(v5Hello.utf8))
    check("V5 viewer requires explicit server capabilities", v5Bridge.worldViewerV5_1Available)
    check("V5.4 participant requires explicit player capability", v5Bridge.playerV5_4Available)
    let renderRequestSeq = v5Bridge.requestWorldRenderSnapshot()
    let renderLane = v5Bridge.dequeueLaneForTesting(at: Date().addingTimeInterval(0.02))
    check("V5 render request has bounded observation lane",
          renderRequestSeq != nil && renderLane == .worldRender)
    _ = v5Bridge.receiveLineForTesting(Data(snapshotLine.utf8))
    let acceptedSnapshot = v5Bridge.latestWorldRenderSnapshot()
    check("V5 sessionless snapshot accepted + generation stamped",
          acceptedSnapshot?.snapshotID == 2
          && acceptedSnapshot?.connectionGeneration == v5Generation)
    let olderSnapshot = snapshotLine.replacingOccurrences(of: #""snapshot_seq":2"#,
                                                           with: #""snapshot_seq":1"#)
    _ = v5Bridge.receiveLineForTesting(Data(olderSnapshot.utf8))
    check("V5 stale snapshot cannot replace newer snapshot",
          v5Bridge.latestWorldRenderSnapshot()?.snapshotID == 2)

    let pickSeq = v5Bridge.sendRayPick(rayOriginMM: [0, -20, 10], rayDirection: [0, 2, -1],
                                          sourceSnapshotSeq: 2, sourceWorldRevision: 3,
                                          sourceSimTick: 40)
    let pickLane = v5Bridge.dequeueLaneForTesting(at: Date().addingTimeInterval(0.04))
    check("V5 ray pick uses separate bounded read-only lane", pickSeq != nil && pickLane == .rayPick)
    if let pickSeq {
        let pickLine = "{\"type\":\"ray_pick_result\",\"protocol_version\":4,\"session_id\":\"\",\"epoch\":0,\"seq\":\(pickSeq),\"sim_tick\":40,\"world_revision\":3,\"source_snapshot_seq\":2,\"source_world_revision\":3,\"source_sim_tick\":40,\"ok\":true,\"hit\":true,\"target_id\":\"box_1\",\"target_kind\":\"lab_object\",\"distance_mm\":12.5,\"point_mm\":[1,2,3],\"normal_world\":[0,0,2],\"geom_id\":7}"
        _ = v5Bridge.receiveLineForTesting(Data(pickLine.utf8))
        let pick = v5Bridge.latestRayPickResult()
        check("V5 authoritative pick result echoes source + carries hit point/normal",
              pick?.seq == pickSeq && pick?.targetID == "box_1"
              && pick?.sourceSnapshotSeq == 2 && pick?.sourceWorldRevision == 3
              && pick?.sourceSimTick == 40
              && pick?.pointMM == [1, 2, 3] && pick?.normalWorld == [0, 0, 1])

        let source = WorldViewerSnapshotSource(snapshotSeq: 2, worldRevision: 3, simTick: 40)
        let poseAdvancedLine = pickLine
            .replacingOccurrences(of: #""sim_tick":40,"world_revision":3"#,
                                  with: #""sim_tick":41,"world_revision":4"#)
        let poseAdvancedPick = parseRayPickResultLine(Data(poseAdvancedLine.utf8))
        check("V5 pick UI accepts pose-advanced successful ACK after source validation",
              poseAdvancedPick.map {
                  worldViewerPickDisposition($0, latestRequestSeq: pickSeq,
                                             consumedSeq: nil, expectedSource: source) == .applySuccess
              } == true)

        let errorLine = "{\"type\":\"ray_pick_result\",\"protocol_version\":4,\"session_id\":\"\",\"epoch\":0,\"seq\":\(pickSeq),\"sim_tick\":42,\"world_revision\":5,\"source_snapshot_seq\":2,\"source_world_revision\":3,\"source_sim_tick\":40,\"ok\":false,\"hit\":false,\"error\":\"stale source world revision\"}"
        let errorPick = parseRayPickResultLine(Data(errorLine.utf8))
        check("V5 pick UI always consumes matching backend error ACK",
              errorPick.map {
                  worldViewerPickDisposition($0, latestRequestSeq: pickSeq,
                                             consumedSeq: nil, expectedSource: source) == .showError
              } == true)
        check("V5 pick UI ignores stale successful ACK from older request",
              poseAdvancedPick.map {
                  worldViewerPickDisposition($0, latestRequestSeq: pickSeq + 1,
                                             consumedSeq: nil, expectedSource: source) == .ignore
              } == true)
    } else {
        check("V5 authoritative pick result echoes source + carries hit point/normal", false)
        check("V5 pick UI accepts pose-advanced successful ACK after source validation", false)
        check("V5 pick UI always consumes matching backend error ACK", false)
        check("V5 pick UI ignores stale successful ACK from older request", false)
    }

    let missingPickSource = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":9,"sim_tick":40,"world_revision":3,"ok":true,"hit":false}"#
    check("V5 pick result requires source snapshot metadata",
          parseRayPickResultLine(Data(missingPickSource.utf8)) == nil)

    // Active V4 session identity is also authoritative for V5 observation traffic.
    // Delayed old-epoch render/pick responses must never refill the cache after a
    // reset promoted the bridge to a newer epoch.
    let v5EpochFilter = FlyGymBridge()
    _ = v5EpochFilter.beginConnectionForTesting()
    _ = v5EpochFilter.dequeueLaneForTesting(at: Date()) // Swift hello
    _ = v5EpochFilter.receiveLineForTesting(Data(v5Hello.utf8))
    _ = v5EpochFilter.sendSessionControl(action: "begin", sessionID: "v5-epoch",
                                         epoch: 2, simTick: 0, mode: .deterministic)
    let oldEpochSnapshot = snapshotLine
        .replacingOccurrences(of: #""session_id":"""#, with: #""session_id":"v5-epoch""#)
        .replacingOccurrences(of: #""epoch":0"#, with: #""epoch":1"#)
    let staleV5Before = v5EpochFilter.staleSessionPacketCount
    _ = v5EpochFilter.receiveLineForTesting(Data(oldEpochSnapshot.utf8))
    let oldEpochPick = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"v5-epoch","epoch":1,"seq":77,"sim_tick":40,"world_revision":3,"source_snapshot_seq":2,"source_world_revision":3,"source_sim_tick":40,"ok":true,"hit":false}"#
    _ = v5EpochFilter.receiveLineForTesting(Data(oldEpochPick.utf8))
    check("V5 active-session old-epoch responses rejected",
          v5EpochFilter.latestWorldRenderSnapshot() == nil
          && v5EpochFilter.latestRayPickResult() == nil
          && v5EpochFilter.staleSessionPacketCount == staleV5Before + 2)

    let v4Only = FlyGymBridge()
    _ = v4Only.beginConnectionForTesting()
    _ = v4Only.receiveLineForTesting(Data(#"{"type":"hello","protocol_version":4,"role":"python","capabilities":["applied_tick","deterministic_experiment","epoch","pause_barrier"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#.utf8))
    check("V4-only peer does not silently enable V5 viewport",
          !v4Only.worldViewerV5_1Available && v4Only.requestWorldRenderSnapshot() == nil)
    let v51Only = FlyGymBridge()
    _ = v51Only.beginConnectionForTesting()
    _ = v51Only.receiveLineForTesting(Data(#"{"type":"hello","protocol_version":4,"role":"python","capabilities":["world_render_snapshot","ray_pick"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#.utf8))
    check("V5.1-only peer does not silently enable V5.4 participant",
          v51Only.worldViewerV5_1Available && !v51Only.playerV5_4Available)

    // MuJoCo z-up <-> SceneKit y-up basis must be exact or the displayed pose
    // and the authoritative backend pick ray refer to different geometry.
    let sceneAxis = WorldViewerCoordinates.sceneComponents(fromMuJoCo: [1, 2, 3])
    let axisRoundTrip = WorldViewerCoordinates.mujocoComponents(fromScene: sceneAxis)
    check("V5 viewport coordinate basis round-trip",
          sceneAxis == [1, 3, -2] && axisRoundTrip == [1, 2, 3])
    let half = Double.pi / 4
    let yaw90Scene = WorldViewerCoordinates.sceneQuaternionXYZW(
        fromMuJoCo: [0, 0, sin(half), cos(half)])
    check("V5 MuJoCo +Z yaw maps to SceneKit +Y yaw",
          abs(yaw90Scene[0]) < 1e-12 && abs(yaw90Scene[1] - sin(half)) < 1e-12
          && abs(yaw90Scene[2]) < 1e-12 && abs(yaw90Scene[3] - cos(half)) < 1e-12)
    let rayScene = WorldViewerCoordinates.sceneComponents(fromMuJoCo: [0.25, -0.5, 0.75])
    let rayBack = WorldViewerCoordinates.mujocoComponents(fromScene: rayScene)
    check("V5 pick ray uses inverse viewport basis", zip(rayBack, [0.25, -0.5, 0.75]).allSatisfy { abs($0 - $1) < 1e-12 })

    // V5.2 presentation-state ownership. LabSession remains authoritative for
    // pause/timeline; the screen state mirrors that once and every panel renders
    // from the same value instead of independently inferring phase/tick.
    var v52State = LabViewState()
    let v52Session = LabSessionSnapshot(
        mode: .deterministic, phase: .paused, sessionID: "v52-state", epoch: 3,
        simTick: 120, quantumTicks: FlyGymProtocolV4.experimentQuantumTicks,
        outstandingStepSeq: nil, pauseControlSent: true,
        lastBodyResultTick: 120, lastAppliedCommandTick: 100, lastError: nil)
    v52State.sync(session: v52Session)
    if let snapshotParsed { v52State.accept(snapshot: snapshotParsed, connectionGeneration: 9) }
    check("V5.2 common state keeps session timeline authoritative",
          v52State.timelineTick == 120 && v52State.snapshotTick == 40
          && v52State.phaseBadge == "PAUSED"
          && v52State.commonStatusLine.contains("tick 120 ms · PAUSED")
          && v52State.sessionStatusLine.contains("paused · epoch 3 · tick 120 ms"))

    let v52PickLine = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":90,"sim_tick":41,"world_revision":4,"source_snapshot_seq":2,"source_world_revision":3,"source_sim_tick":40,"ok":true,"hit":true,"target_id":"box_1","target_kind":"lab_object","distance_mm":1.0,"point_mm":[0,0,0],"normal_world":[0,0,1],"geom_id":1}"#
    if let v52Pick = parseRayPickResultLine(Data(v52PickLine.utf8)) {
        v52State.apply(pick: v52Pick)
    }
    check("V5.2 authoritative pick updates one shared object selection",
          v52State.selectedObjectID == "box_1" && v52State.selectionSummary.contains("object box_1"))

    let v52EmptySnapshotLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":2,"sim_tick":42,"ok":true,"snapshot_seq":3,"world_revision":5,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#
    if let v52Empty = parseWorldRenderSnapshotLine(Data(v52EmptySnapshotLine.utf8)) {
        v52State.accept(snapshot: v52Empty, connectionGeneration: 9)
    }
    check("V5.2 shared selection is reconciled by authoritative snapshot",
          v52State.selectedObjectID == nil && v52State.timelineTick == 120
          && v52State.snapshotSeq == 3 && v52State.worldRevision == 5)

    // V5.4 mode presentation is snapshot-authoritative. A UI request stays
    // pending until the backend world actually contains/removes the participant;
    // rejection leaves the prior mode intact.
    var v54State = LabViewState()
    v54State.setViewerAvailable(true)
    v54State.beginModeTransition(to: .participate)
    check("V5.4 participate request does not claim mode before backend snapshot",
          v54State.mode == .observe && v54State.pendingMode == .participate)
    var v54Rejected = v54State
    v54Rejected.rejectModeTransition()
    check("V5.4 rejected participate request preserves prior mode",
          v54Rejected.mode == .observe && v54Rejected.pendingMode == nil)
    if let playerSnapshot {
        v54State.accept(snapshot: playerSnapshot, connectionGeneration: 12)
    }
    check("V5.4 player snapshot confirms Participate mode",
          v54State.mode == .participate && v54State.pendingMode == nil)

    let v54PlayerPickLine = #"{"type":"ray_pick_result","protocol_version":4,"session_id":"","epoch":0,"seq":91,"sim_tick":41,"world_revision":6,"source_snapshot_seq":4,"source_world_revision":6,"source_sim_tick":40,"ok":true,"hit":true,"target_id":"player","target_kind":"player","distance_mm":2.0,"point_mm":[24,0,5],"normal_world":[0,0,1],"geom_id":9}"#
    if let v54PlayerPick = parseRayPickResultLine(Data(v54PlayerPickLine.utf8)) {
        v54State.apply(pick: v54PlayerPick)
    }
    check("V5.4 authoritative player pick reaches common selection state",
          v54State.selectedPlayerID == "player" && v54State.selectionSummary.contains("player player"))

    v54State.beginModeTransition(to: .observe)
    if let playerSnapshot {
        v54State.accept(snapshot: playerSnapshot, connectionGeneration: 12)
    }
    check("V5.4 disable request stays Participate while player still exists",
          v54State.mode == .participate && v54State.pendingMode == .observe)
    if let v54Empty = parseWorldRenderSnapshotLine(Data(v52EmptySnapshotLine.utf8)) {
        v54State.accept(snapshot: v54Empty, connectionGeneration: 12)
    }
    check("V5.4 player-free snapshot confirms Observe mode",
          v54State.mode == .observe && v54State.pendingMode == nil
          && v54State.selectedPlayerID == nil)

    // Pending participant commands are transport-generation scoped. Losing the
    // viewer/capability must clear the command gate even when the current mode is
    // still Observe (enable pending) or still Participate (disable pending).
    var pendingEnable = ParticipantCommandPendingState()
    var pendingEnableState = LabViewState()
    pendingEnableState.setViewerAvailable(true)
    pendingEnableState.beginModeTransition(to: .participate)
    pendingEnable.begin(commandID: 701, connectionGeneration: 21)
    let enableCleared = pendingEnable.clearIfViewerLifecycleInvalid(
        playerAvailable: false, connectionGeneration: 21)
    if enableCleared { pendingEnableState.rejectModeTransition() }
    pendingEnableState.setViewerAvailable(false)
    check("V5.4 disconnect during enable clears pending participant command",
          enableCleared && !pendingEnable.isPending
          && pendingEnableState.mode == .observe
          && pendingEnableState.pendingMode == nil)

    var pendingDisable = ParticipantCommandPendingState()
    var pendingDisableState = LabViewState()
    pendingDisableState.setViewerAvailable(true)
    if let playerSnapshot {
        pendingDisableState.accept(snapshot: playerSnapshot, connectionGeneration: 31)
    }
    pendingDisableState.beginModeTransition(to: .observe)
    pendingDisable.begin(commandID: 702, connectionGeneration: 31)
    let disableCleared = pendingDisable.clearIfViewerLifecycleInvalid(
        playerAvailable: false, connectionGeneration: 31)
    if disableCleared { pendingDisableState.rejectModeTransition() }
    pendingDisableState.setViewerAvailable(false)
    check("V5.4 disconnect during disable clears pending participant command",
          disableCleared && !pendingDisable.isPending
          && pendingDisableState.mode == .observe
          && pendingDisableState.pendingMode == nil)

    var pendingGeneration = ParticipantCommandPendingState()
    pendingGeneration.begin(commandID: 703, connectionGeneration: 41)
    check("V5.4 connection-generation rollover clears stale participant command",
          pendingGeneration.clearIfViewerLifecycleInvalid(
              playerAvailable: true, connectionGeneration: 42)
          && !pendingGeneration.isPending)

    // V5.5 PlayerInput wire/capability + continuous latest-state semantics.
    let v55Hello = #"{"type":"hello","protocol_version":4,"role":"python","capabilities":["applied_tick","deterministic_experiment","epoch","pause_barrier","world_render_snapshot","ray_pick","player_body","player_input"],"physics_timestep_s":0.001,"supported_quantum_ticks":[20]}"#
    let v55Bridge = FlyGymBridge()
    _ = v55Bridge.beginConnectionForTesting()
    _ = v55Bridge.dequeueLaneForTesting(at: Date()) // Swift hello
    _ = v55Bridge.receiveLineForTesting(Data(v55Hello.utf8))
    check("V5.5 player input requires explicit layered capability",
          v55Bridge.playerV5_4Available && v55Bridge.playerInputV5_5Available)

    let v55Seq1 = v55Bridge.sendPlayerInput(sessionID: "", epoch: 0,
                                            requestedTick: 95,
                                            moveAxes: [1, 0], lookDelta: [0.10, 0.05],
                                            heldActions: ["interact"])
    let v55Seq2 = v55Bridge.sendPlayerInput(sessionID: "", epoch: 0,
                                            requestedTick: 100,
                                            moveAxes: [0, -1], lookDelta: [-0.03, 0.02],
                                            heldActions: [])
    let coalescedSend = v55Bridge.dequeueSendForTesting(at: Date().addingTimeInterval(0.02))
    let coalescedInput = coalescedSend.flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 PlayerInput coalesces axes/held latest-wins and accumulates look once",
          v55Seq1 != nil && v55Seq2 != nil
          && coalescedSend?.0 == .playerInput
          && coalescedInput?.seq == v55Seq2
          && coalescedInput?.requestedTick == 100
          && coalescedInput?.moveAxes == [0, -1]
          && abs((coalescedInput?.lookDelta[0] ?? 9) - 0.07) < 1e-12
          && abs((coalescedInput?.lookDelta[1] ?? 9) - 0.07) < 1e-12
          && coalescedInput?.heldActions.isEmpty == true)

    let v55LargeLook = FlyGymBridge()
    _ = v55LargeLook.beginConnectionForTesting()
    _ = v55LargeLook.dequeueLaneForTesting(at: Date())
    _ = v55LargeLook.receiveLineForTesting(Data(v55Hello.utf8))
    _ = v55LargeLook.sendPlayerInput(sessionID: "", epoch: 0,
                                     requestedTick: 0, moveAxes: [0, 0],
                                     lookDelta: [0.7, -0.7], heldActions: [])
    _ = v55LargeLook.sendPlayerInput(sessionID: "", epoch: 0,
                                     requestedTick: 0, moveAxes: [0, 0],
                                     lookDelta: [0.7, -0.7], heldActions: [])
    let largeLookSend1 = v55LargeLook.dequeueSendForTesting(at: Date().addingTimeInterval(0.01))
    let largeLookSend2 = v55LargeLook.dequeueSendForTesting(at: Date().addingTimeInterval(0.02))
    let largeLook1 = largeLookSend1.flatMap { decodePlayerInputLine($0.1) }
    let largeLook2 = largeLookSend2.flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 coalesced look above per-packet bound is split without loss",
          largeLookSend1?.0 == .playerInput && largeLookSend2?.0 == .playerInput
          && largeLook1 != nil && largeLook2 != nil
          && abs((largeLook1!.lookDelta[0] + largeLook2!.lookDelta[0]) - 1.4) < 1e-12
          && abs((largeLook1!.lookDelta[1] + largeLook2!.lookDelta[1]) + 1.4) < 1e-12
          && abs(largeLook1!.lookDelta[0]) <= PlayerInputPacket.maxLookDelta
          && abs(largeLook2!.lookDelta[0]) <= PlayerInputPacket.maxLookDelta
          && largeLook2!.seq > largeLook1!.seq
          && v55LargeLook.dequeueSendForTesting(at: Date().addingTimeInterval(0.03)) == nil)

    let v55ReleaseLook = FlyGymBridge()
    _ = v55ReleaseLook.beginConnectionForTesting()
    _ = v55ReleaseLook.dequeueLaneForTesting(at: Date())
    _ = v55ReleaseLook.receiveLineForTesting(Data(v55Hello.utf8))
    _ = v55ReleaseLook.sendPlayerInput(sessionID: "", epoch: 0,
                                       requestedTick: 0, moveAxes: [0, 0],
                                       lookDelta: [0.7, -0.7], heldActions: [])
    let releaseSeq = v55ReleaseLook.sendPlayerInput(
        sessionID: "", epoch: 0, requestedTick: 0,
        moveAxes: [0, 0], lookDelta: [0, 0], heldActions: [],
        discardPendingLook: true)
    let releaseSend = v55ReleaseLook.dequeueSendForTesting(
        at: Date().addingTimeInterval(0.01))
    let releasePacket = releaseSend.flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 safety release discards pending mouse look and remainder",
          releaseSeq != nil
          && releaseSend?.0 == .playerInput
          && releasePacket?.lookDelta == [0, 0]
          && releasePacket?.moveAxes == [0, 0]
          && releasePacket?.heldActions.isEmpty == true
          && v55ReleaseLook.dequeueSendForTesting(
              at: Date().addingTimeInterval(0.02)) == nil)

    let v55AckLine = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55BadSuccess = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"ok":true,"status":"applied"}"#
    let v55BadFailure = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"ok":false,"status":"rejected"}"#
    let v55BadSuccessStatus = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"queue_full"}"#
    let v55BadFailureApplied = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":false,"status":"rejected","error":"no"}"#
    let v55BadFailureStatus = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"ok":false,"status":"applied","error":"no"}"#
    let v55BadSuccessNullError = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied","error":null}"#
    let v55BadFailureNullTick = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":null,"ok":false,"status":"rejected","error":"no"}"#
    let v55BadSeqBound = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2147483648,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55BadTickBound = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":1000000000000001,"applied_tick":1000000000000001,"ok":true,"status":"applied"}"#
    let v55BadProtocol = #"{"type":"player_input_result","protocol_version":0,"actor_id":"player","session_id":"","epoch":0,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55BadBlankSession = #"{"type":"player_input_result","protocol_version":4,"actor_id":"player","session_id":"   ","epoch":1,"seq":2,"requested_tick":100,"applied_tick":101,"ok":true,"status":"applied"}"#
    let v55PaddedStatus = String(repeating: " ", count: 65) + "applied"
    let v55BadStatusBound = "{\"type\":\"player_input_result\",\"protocol_version\":4,\"actor_id\":\"player\",\"session_id\":\"\",\"epoch\":0,\"seq\":2,\"requested_tick\":100,\"applied_tick\":101,\"ok\":true,\"status\":\"\(v55PaddedStatus)\"}"
    let v55LongError = String(repeating: "x", count: 513)
    let v55BadErrorBound = "{\"type\":\"player_input_result\",\"protocol_version\":4,\"actor_id\":\"player\",\"session_id\":\"\",\"epoch\":0,\"seq\":2,\"requested_tick\":100,\"ok\":false,\"status\":\"rejected\",\"error\":\"\(v55LongError)\"}"
    let parsedV55Ack = parsePlayerInputResultLine(Data(v55AckLine.utf8))
    check("V5.5 PlayerInput result strict schema carries applied tick",
          parsedV55Ack?.ok == true && parsedV55Ack?.seq == 2
          && parsedV55Ack?.requestedTick == 100 && parsedV55Ack?.appliedTick == 101
          && parsePlayerInputResultLine(Data(v55BadSuccess.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailure.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadSuccessStatus.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailureApplied.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailureStatus.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadSuccessNullError.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadFailureNullTick.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadSeqBound.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadTickBound.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadProtocol.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadBlankSession.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadStatusBound.utf8)) == nil
          && parsePlayerInputResultLine(Data(v55BadErrorBound.utf8)) == nil)
    _ = v55Bridge.receiveLineForTesting(Data(v55AckLine.utf8))
    check("V5.5 accepted result is generation stamped",
          v55Bridge.latestPlayerInputResult()?.appliedTick == 101
          && v55Bridge.latestPlayerInputResult()?.connectionGeneration == v55Bridge.connectionGeneration)

    let v55SeqBounds = FlyGymBridge()
    _ = v55SeqBounds.beginConnectionForTesting()
    _ = v55SeqBounds.dequeueLaneForTesting(at: Date())
    _ = v55SeqBounds.receiveLineForTesting(Data(v55Hello.utf8))
    v55SeqBounds.setNextPlayerInputSeqForTesting(PlayerInputPacket.maxSeq)
    let maxWireSeq = v55SeqBounds.sendPlayerInput(
        sessionID: "", epoch: 0, requestedTick: 0,
        moveAxes: [0, 0], lookDelta: [0, 0], heldActions: [])
    let exhaustedWireSeq = v55SeqBounds.sendPlayerInput(
        sessionID: "", epoch: 0, requestedTick: 0,
        moveAxes: [0, 0], lookDelta: [0, 0], heldActions: [])
    let maxWirePacket = v55SeqBounds.dequeueSendForTesting(
        at: Date().addingTimeInterval(0.01)).flatMap { decodePlayerInputLine($0.1) }
    check("V5.5 outbound PlayerInput never exceeds Python seq bound",
          maxWireSeq == PlayerInputPacket.maxSeq
          && exhaustedWireSeq == nil
          && maxWirePacket?.seq == PlayerInputPacket.maxSeq)

    // Deterministic boundary ordering: queued PlayerInput must reach Python before
    // the body quantum it targets, exactly like tick-scheduled LabCommands.
    let v55Order = FlyGymBridge()
    _ = v55Order.beginConnectionForTesting()
    _ = v55Order.dequeueLaneForTesting(at: Date())
    _ = v55Order.receiveLineForTesting(Data(v55Hello.utf8))
    _ = v55Order.sendSessionControl(action: "begin", sessionID: "v55-order",
                                    epoch: 1, simTick: 0, mode: .deterministic)
    _ = v55Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.01))
    let orderedInput = v55Order.sendPlayerInput(sessionID: "v55-order", epoch: 1,
                                                requestedTick: 0, moveAxes: [1, 0],
                                                lookDelta: [0, 0], heldActions: [])
    let orderedStep = v55Order.sendExperimentStep(sessionID: "v55-order", epoch: 1,
                                                  seq: 1, simTick: 0, signals: BrainSignals())
    let firstV55Lane = v55Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.02))
    let secondV55Lane = v55Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.03))
    check("V5.5 deterministic PlayerInput cannot be overtaken by experiment step",
          orderedInput != nil && orderedStep
          && firstV55Lane == .playerInput && secondV55Lane == .experimentStep)

    // PlayerController focus safety and stale-key suppression are independent of
    // render FPS/window-server event repetition.
    let playerDefaultsName = "SiliconFly.PlayerInput.bridgetest.\(UUID().uuidString)"
    let playerDefaults = UserDefaults(suiteName: playerDefaultsName)!
    playerDefaults.removePersistentDomain(forName: playerDefaultsName)
    let controller = PlayerController(defaults: playerDefaults, lookRadiansPerPoint: 0.01)
    _ = controller.setCaptureEnabled(true)
    let forwardCode = controller.bindings.keyCode(for: .forward)
    let rightCode = controller.bindings.keyCode(for: .right)
    let interactCode = controller.bindings.keyCode(for: .interact)
    let forwardDown = controller.handleKeyDown(keyCode: forwardCode, isRepeat: false)
    let diagonalDown = controller.handleKeyDown(keyCode: rightCode, isRepeat: false)
    let interactDown = controller.handleKeyDown(keyCode: interactCode, isRepeat: false)
    let localEscNeutral = controller.handleKeyDown(keyCode: PlayerController.escapeKeyCode,
                                                   isRepeat: false)
    let staleRepeat = controller.handleKeyDown(keyCode: forwardCode, isRepeat: true)
    _ = controller.handleKeyUp(keyCode: forwardCode)
    let freshForward = controller.handleKeyDown(keyCode: forwardCode, isRepeat: false)
    check("V5.5 WASD/E state is bounded and Esc is local neutral safety release",
          forwardDown?.moveAxes == [1, 0]
          && diagonalDown?.moveAxes == [1, 1]
          && interactDown?.heldActions == ["interact"]
          && localEscNeutral?.isNeutral == true
          && localEscNeutral?.heldActions.isEmpty == true
          && staleRepeat == nil && freshForward?.moveAxes == [1, 0])

    let focusNeutral = controller.releaseHeldInput(blockUntilFreshPress: true)
    _ = controller.setCaptureEnabled(false)
    _ = controller.setCaptureEnabled(true)
    let focusStaleRepeat = controller.handleKeyDown(keyCode: forwardCode, isRepeat: true)
    _ = controller.handleKeyUp(keyCode: forwardCode)
    let focusFreshPress = controller.handleKeyDown(keyCode: forwardCode, isRepeat: false)
    check("V5.5 focus loss neutralizes held state and never revives stale repeats",
          focusNeutral?.isNeutral == true && focusStaleRepeat == nil
          && focusFreshPress?.moveAxes == [1, 0])

    let lookIntent = controller.handleLook(deltaX: 10, deltaY: -5)
    check("V5.5 mouse look follows +Y-left world basis and bounded radians",
          abs((lookIntent?.lookDelta[0] ?? 9) + 0.10) < 1e-12
          && abs((lookIntent?.lookDelta[1] ?? 9) - 0.05) < 1e-12)

    let originalForward = controller.bindings.keyCode(for: .forward)
    let originalRight = controller.bindings.keyCode(for: .right)
    _ = controller.rebind(.forward, to: originalRight, defaults: playerDefaults)
    let reloadedBindings = PlayerKeyBindings(defaults: playerDefaults)
    let swappedPersisted = reloadedBindings.keyCode(for: .forward) == originalRight
        && reloadedBindings.keyCode(for: .right) == originalForward
    _ = controller.rebind(.forward, to: PlayerController.escapeKeyCode, defaults: playerDefaults)
    check("V5.5 remap persists unique swaps while Esc stays reserved",
          swappedPersisted && controller.bindings.keyCode(for: .forward) == originalRight)
    playerDefaults.set(Int(PlayerController.escapeKeyCode),
                       forKey: PlayerKeyBindings.preferencePrefix + PlayerControlAction.forward.rawValue)
    let escapedStoredBinding = PlayerKeyBindings(defaults: playerDefaults)
    check("V5.5 corrupt persisted Esc binding fails safely to non-Esc mapping",
          escapedStoredBinding.keyCode(for: .forward) != PlayerController.escapeKeyCode)
    playerDefaults.removePersistentDomain(forName: playerDefaultsName)

    let focusViewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let focusField = NSTextField(string: "W should type, not walk")
    let focusButton = NSButton(title: "Control", target: nil, action: nil)
    let focusWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                               styleMask: [.titled], backing: .buffered, defer: false)
    PlayerInputFocusPolicy.prepareWindowForCapture(focusWindow)
    check("V5.5 Participate window enables ordinary mouse-move delivery",
          focusWindow.acceptsMouseMovedEvents)
    check("V5.5 text/control focus suppresses capture",
          PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                               firstResponder: focusViewer,
                                               viewer: focusViewer)
          && !PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                                   firstResponder: focusField,
                                                   viewer: focusViewer)
          && !PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                                   firstResponder: focusButton,
                                                   viewer: focusViewer)
          && !PlayerInputFocusPolicy.allowsCapture(windowIsKey: false,
                                                   firstResponder: focusViewer,
                                                   viewer: focusViewer))

    var participateLookCallbacks = 0
    focusViewer.onPlayerLookDelta = { _, _ in participateLookCallbacks += 1 }
    focusViewer.participateModeEnabled = true
    focusViewer.participateInputEnabled = true
    let captureCameraBefore = focusViewer.cameraState
    focusViewer.routePointerDelta(deltaX: 12, deltaY: -4, shift: false)
    focusViewer.routeScroll(delta: 9)
    let captureCameraAfter = focusViewer.cameraState
    focusViewer.participateInputEnabled = false
    focusViewer.routePointerDelta(deltaX: 5, deltaY: 2, shift: false)
    let releasedCameraChanged = focusViewer.cameraState != captureCameraAfter
    check("V5.5 Participate capture is exclusive from pick/Observe camera gestures",
          participateLookCallbacks == 1
          && captureCameraAfter == captureCameraBefore
          && !focusViewer.pickEnabledForCurrentMode
          && releasedCameraChanged)

    // Reconnect invalidates both pending input/result state and the Coordinator's
    // interactive owner identity. A fresh transport generation must begin a fresh
    // V4 interactive session before accepting new input.
    let reconnectBridge = FlyGymBridge()
    _ = reconnectBridge.beginConnectionForTesting()
    _ = reconnectBridge.dequeueLaneForTesting(at: Date())
    _ = reconnectBridge.receiveLineForTesting(Data(v55Hello.utf8))
    let reconnectCoordinator = Coordinator(bounds: CGSize(width: 100, height: 100), sim: nil)
    reconnectCoordinator.flyGym = reconnectBridge
    let firstInteractiveReady = reconnectCoordinator.ensureInteractivePlayerInputSession()
    let firstInteractiveID = reconnectCoordinator.sessionSnapshot().sessionID
    reconnectBridge.disconnectForTesting()
    let clearedAfterDisconnect = reconnectBridge.latestPlayerInputResult() == nil
        && !reconnectBridge.playerInputV5_5Available
    _ = reconnectBridge.beginConnectionForTesting()
    _ = reconnectBridge.dequeueLaneForTesting(at: Date())
    _ = reconnectBridge.receiveLineForTesting(Data(v55Hello.utf8))
    let secondInteractiveReady = reconnectCoordinator.ensureInteractivePlayerInputSession()
    let secondInteractiveID = reconnectCoordinator.sessionSnapshot().sessionID
    check("V5.5 reconnect starts fresh interactive owner session and clears stale input state",
          firstInteractiveReady && secondInteractiveReady && clearedAfterDisconnect
          && firstInteractiveID != secondInteractiveID)

    // V5.3 observation camera is strictly presentation-only. Exercise the same
    // camera APIs used by right-drag/Shift-right-drag/scroll while wiring the
    // existing pick callback to a real V5-capable bridge. Any accidental pick,
    // neural, lab, session, render, or experiment send would increase bridge
    // pendingDepth and fail this test.
    let v53Bridge = FlyGymBridge()
    _ = v53Bridge.beginConnectionForTesting()
    _ = v53Bridge.dequeueLaneForTesting(at: Date()) // drain Swift hello
    _ = v53Bridge.receiveLineForTesting(Data(v5Hello.utf8))
    let v53Viewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var v53PickCallbacks = 0
    v53Viewer.onPickRay = { ray in
        v53PickCallbacks += 1
        guard let source = v53Viewer.currentSnapshotSource else { return }
        _ = v53Bridge.sendRayPick(rayOriginMM: ray.originMM,
                                  rayDirection: ray.direction,
                                  sourceSnapshotSeq: source.snapshotSeq,
                                  sourceWorldRevision: source.worldRevision,
                                  sourceSimTick: source.simTick)
    }
    // Reset before any backend snapshot must not consume the one-shot initial
    // authoritative framing gate.
    v53Viewer.resetObservationCamera()
    if let snapshotParsed { v53Viewer.apply(snapshot: snapshotParsed) }
    let v53SharedBefore = v52State
    let v53InitialCamera = v53Viewer.cameraState
    let expectedInitialCenter = [6.5, 2.35, 0.5]
    let initialFrameOK = zip(v53InitialCamera.targetScene, expectedInitialCenter)
        .allSatisfy { abs($0 - $1) < 1e-5 }
    v53Viewer.rotateObservationCamera(deltaX: 24, deltaY: -9)
    v53Viewer.panObservationCamera(deltaX: 12, deltaY: 6)
    v53Viewer.zoomObservationCamera(delta: -3)
    let v53OrbitChanged = v53Viewer.cameraState != v53InitialCamera
    v53Viewer.setObservationCameraMode(.followFly)
    let followBeforePan = v53Viewer.cameraState
    v53Viewer.panObservationCamera(deltaX: 99, deltaY: 99)
    let followPanNoOp = v53Viewer.cameraState == followBeforePan
    v53Viewer.rotateObservationCamera(deltaX: -11, deltaY: 4)
    v53Viewer.zoomObservationCamera(delta: 2)
    v53Viewer.setObservationCameraMode(.free)
    let freeStart = v53Viewer.cameraState
    let expectedFreePosition = zip(freeStart.targetScene, freeStart.forwardVector).map {
        $0.0 - $0.1 * freeStart.distance
    }
    let freeContinuity = zip(freeStart.freePositionScene, expectedFreePosition)
        .allSatisfy { abs($0 - $1) < 1e-3 }
    let freeZoomForward = freeStart.forwardVector
    v53Viewer.zoomObservationCamera(delta: 4)
    let freeAfterPositiveZoom = v53Viewer.cameraState
    let freePositiveZoomProjection = zip(zip(freeAfterPositiveZoom.freePositionScene,
                                             freeStart.freePositionScene), freeZoomForward)
        .reduce(0.0) { partial, pair in
            partial + (pair.0.0 - pair.0.1) * pair.1
        }
    var orbitZoomProbe = WorldViewerCameraState()
    let orbitDistanceBeforePositiveZoom = orbitZoomProbe.distance
    orbitZoomProbe.zoom(delta: 4)
    let scrollDirectionConsistent = orbitZoomProbe.distance > orbitDistanceBeforePositiveZoom
        && freePositiveZoomProjection < 0
    v53Viewer.rotateObservationCamera(deltaX: 7, deltaY: 3)
    v53Viewer.panObservationCamera(deltaX: 5, deltaY: -2)
    v53Viewer.resetObservationCamera()
    check("V5.3 first snapshot frames authoritative scene",
          initialFrameOK && v53Viewer.currentSnapshotSource?.snapshotSeq == 2)
    check("V5.3 orbit/follow/free camera inputs are presentation-only",
          v53OrbitChanged && followPanNoOp && freeContinuity
          && scrollDirectionConsistent
          && v53PickCallbacks == 0 && v53Bridge.pendingDepth() == 0
          && v53Bridge.pendingLabDepth() == 0 && v52State == v53SharedBefore)

    // sensory map: standing contact is not gait; fresh real body is authoritative;
    // stale/missing real body falls back to the desktop procedural fly.
    var still = FlyGymBodyFeedback()
    still.contacts = [1, 1, 1, 1, 1, 1]
    still.leftContact = 1; still.rightContact = 1
    check("standing contact -> 0 gait", FlyGymSensoryMap.bodyDrive(still) == 0)
    check("fresh real ignores procedural gait",
          FlyGymSensoryMap.gaitDrive(procedural: 0.8, body: still) == 0)
    var brisk = FlyGymBodyFeedback()
    brisk.vx = 0.03; brisk.contacts = [1, 1, 1, 1, 1, 1]
    brisk.leftContact = 1; brisk.rightContact = 1
    check("brisk body -> ~1", abs(FlyGymSensoryMap.bodyDrive(brisk) - 1.0) < 1e-9)
    check("stale falls back", FlyGymSensoryMap.gaitDrive(procedural: 0.4, body: nil) == 0.4)
    var old = brisk; old.receivedAt = Date(timeIntervalSinceNow: -10)
    check("old packet falls back", FlyGymSensoryMap.gaitDrive(procedural: 0.4, body: old) == 0.4)
    if let body {
        var freshOdor = FlyGymBodyFeedback(body)
        check("body sim time/dt reach feedback",
              abs(freshOdor.simTime - 1.238) < 1e-9
              && abs(freshOdor.simDt - 0.002) < 1e-9
              && abs(freshOdor.simWallRatio - 0.1) < 1e-9
              && abs(freshOdor.controllerLeft - 0.21) < 1e-9
              && abs(freshOdor.controllerRight - 0.43) < 1e-9
              && abs(freshOdor.windStrength - 0.7) < 1e-9
              && freshOdor.windSensory
              && abs(freshOdor.touchStrength - 0.55) < 1e-9
              && freshOdor.touchSensory
              && abs(freshOdor.positionXmm - 14.5) < 1e-9
              && abs(freshOdor.positionYmm + 3.25) < 1e-9)
        freshOdor.receivedAt = Date()
        let o = FlyGymSensoryMap.foodOdor(body: freshOdor)
        check("fresh food odor maps", abs(o.l - 0.75) < 1e-6 && abs(o.r - 0.2) < 1e-6)
        freshOdor.receivedAt = Date(timeIntervalSinceNow: -10)
        let staleOdor = FlyGymSensoryMap.foodOdor(body: freshOdor)
        check("stale food odor clears", staleOdor.l == 0 && staleOdor.r == 0)
        check("fresh body heading maps", abs((FlyGymSensoryMap.heading(body: FlyGymBodyFeedback(body)) ?? -9) - 1.25) < 1e-9)
        check("stale body heading clears", FlyGymSensoryMap.heading(body: freshOdor) == nil)
    } else {
        check("food odor mapping", false, "body packet missing")
    }
    // 9. bounded queue: one normal latest slot + one protected escape slot.
    let b = FlyGymBridge()
    for _ in 0..<100 { b.sendBrain(s, simMs: 1) }
    check("bounded queue", b.pendingDepth() <= 2, "depth=\(b.pendingDepth())")
    s.escape = false
    b.sendBrain(s, simMs: 2)
    s.escape = true
    b.sendBrain(s, simMs: 3)
    check("escape pulse gets protected lane", b.pendingDepth() == 2,
          "depth=\(b.pendingDepth())")

    // Connection generation + freshness. Test hooks reuse the exact production
    // lifecycle/inbound paths but never open a socket.
    let freshBridge = FlyGymBridge()
    let gen1 = freshBridge.beginConnectionForTesting()
    let recvNow = Date()
    for i in 0..<5 {
        let at = recvNow.addingTimeInterval(Double(i - 4) * 0.02)
        _ = freshBridge.receiveLineForTesting(Data(line.utf8), at: at)
    }
    let liveBody = freshBridge.latestBody()
    let bodyFresh = freshBridge.bodyFreshness()
    check("body generation + simTime stamped",
          gen1 == 1 && liveBody?.connectionGeneration == gen1
          && abs((liveBody?.simTime ?? -1) - 1.238) < 1e-9)
    check("body freshness exposes age/generation",
          bodyFresh.connected && bodyFresh.isFresh
          && bodyFresh.packetGeneration == gen1
          && (bodyFresh.ageSeconds ?? 9) < 0.2)
    check("fresh bodyHz reports live cadence",
          freshBridge.bodyHz > 40 && freshBridge.bodyHz < 60,
          String(format: "%.1f Hz", freshBridge.bodyHz))

    let stateLine = #"{"type":"lab_state","t":1.25,"ack":7,"ok":true,"object_count":1,"last_action":"spawn_sphere"}"#
    let ackLine = #"{"type":"lab_ack","id":8,"ok":true,"action":"wind","message":"ok"}"#
    let eventLine = #"{"type":"lab_event","event":"wind_started"}"#
    _ = freshBridge.receiveLineForTesting(Data(stateLine.utf8), at: recvNow)
    _ = freshBridge.receiveLineForTesting(Data(ackLine.utf8), at: recvNow)
    _ = freshBridge.receiveLineForTesting(Data(eventLine.utf8), at: recvNow)
    let stateFresh = freshBridge.labStateFreshness()
    let ackFresh = freshBridge.labAckFreshness()
    let eventFresh = freshBridge.labEventFreshness()
    check("lab state/ack/event generation stamped",
          freshBridge.latestLabState()?.connectionGeneration == gen1
          && freshBridge.latestLabAck()?.connectionGeneration == gen1
          && freshBridge.latestLabEvent()?.connectionGeneration == gen1)
    check("lab state/ack/event freshness exposes age",
          stateFresh.isFresh && ackFresh.isFresh && eventFresh.isFresh
          && (stateFresh.ageSeconds ?? 9) < 0.2
          && (ackFresh.ageSeconds ?? 9) < 0.2
          && (eventFresh.ageSeconds ?? 9) < 0.2)

    // Large V4 world states used to be at risk of being discarded by the old
    // 64 KiB recv buffer guard. Exercise the exact production line-framing +
    // inbound arbitration path with all 224 default object slots and long IDs,
    // split into recv()-sized chunks.
    let largeStateBridge = FlyGymBridge()
    _ = largeStateBridge.beginConnectionForTesting()
    var largeObjects: [[String: Any]] = []
    let shapeCounts: [(String, Int)] = [("box", 64), ("sphere", 64), ("wall", 64), ("food", 32)]
    for (shape, count) in shapeCounts {
        for i in 0..<count {
            let longID = "\(shape)_\(i)_" + String(repeating: "object-id-padding-", count: 12)
            let size: [Double]
            switch shape {
            case "wall": size = [2.0, 30.0, 15.0]
            case "sphere", "food": size = [5.0, 5.0, 5.0]
            default: size = [10.0, 12.0, 8.0]
            }
            largeObjects.append([
                "id": longID,
                "shape": shape,
                "position_mm": [Double(i), Double(-i), size[2] * 0.5],
                "size_mm": size,
                "yaw_deg": Double(i % 36) * 10.0,
            ])
        }
    }
    let largeStateJSON: [String: Any] = [
        "type": "lab_state",
        "t": 12.5,
        "object_count": largeObjects.count,
        "state": [
            "objects": largeObjects,
            "slot_capacity": ["box": 64, "sphere": 64, "wall": 64, "food": 32],
            "slot_free": ["box": 0, "sphere": 0, "wall": 0, "food": 0],
        ] as [String: Any],
    ]
    var largeFrame = (try? JSONSerialization.data(withJSONObject: largeStateJSON)) ?? Data()
    let largePayloadBytes = largeFrame.count
    largeFrame.append(0x0A)
    var largeRecvBuffer = Data()
    var offset = 0
    while offset < largeFrame.count {
        let end = min(offset + 4096, largeFrame.count)
        largeStateBridge.receiveBytesForTesting(largeFrame.subdata(in: offset..<end),
                                                buffer: &largeRecvBuffer,
                                                at: recvNow)
        offset = end
    }
    let receivedLargeState = largeStateBridge.latestLabState()
    check("large lab_state exceeds historical 64 KiB guard",
          largePayloadBytes > 65_536 && largePayloadBytes < 512 * 1024,
          "bytes=\(largePayloadBytes)")
    check("224-object lab_state survives recv framing",
          largeRecvBuffer.isEmpty
          && receivedLargeState?.authoritativeObjects?.count == 224
          && receivedLargeState?.authoritativeSlotCapacity?["food"] == 32
          && receivedLargeState?.authoritativeSlotFree?["box"] == 0,
          "bytes=\(largePayloadBytes) objects=\(receivedLargeState?.authoritativeObjects?.count ?? -1)")

    // The larger legitimate limit must still be a real bound. An unterminated
    // line over 512 KiB is discarded and counted instead of growing forever.
    let malformedBeforeFlood = largeStateBridge.malformedCount
    var floodOffset = 0
    let flood = Data(repeating: 0x78, count: 512 * 1024 + 1)
    while floodOffset < flood.count {
        let end = min(floodOffset + 4096, flood.count)
        largeStateBridge.receiveBytesForTesting(flood.subdata(in: floodOffset..<end),
                                                buffer: &largeRecvBuffer,
                                                at: recvNow)
        floodOffset = end
    }
    check("recv flood guard remains bounded",
          largeRecvBuffer.isEmpty && largeStateBridge.malformedCount == malformedBeforeFlood + 1,
          "buffer=\(largeRecvBuffer.count) malformed=\(largeStateBridge.malformedCount - malformedBeforeFlood)")

    freshBridge.disconnectForTesting()
    check("disconnect clears remote state",
          !freshBridge.connected && freshBridge.latestBody() == nil
          && freshBridge.latestLabState() == nil && freshBridge.latestLabAck() == nil
          && freshBridge.latestLabEvent() == nil && freshBridge.bodyHz == 0)
    let gen2 = freshBridge.beginConnectionForTesting()
    check("reconnect advances generation and stays empty",
          gen2 == gen1 + 1 && freshBridge.latestBody() == nil
          && freshBridge.latestLabState() == nil)

    let oldAt = Date(timeIntervalSinceNow: -2)
    for i in 0..<5 {
        let at = oldAt.addingTimeInterval(Double(i) * 0.02)
        _ = freshBridge.receiveLineForTesting(Data(line.utf8), at: at)
    }
    _ = freshBridge.receiveLineForTesting(Data(stateLine.utf8), at: oldAt)
    _ = freshBridge.receiveLineForTesting(Data(ackLine.utf8), at: oldAt)
    _ = freshBridge.receiveLineForTesting(Data(eventLine.utf8), at: oldAt)
    check("stale bodyHz drops to zero",
          freshBridge.bodyHz == 0 && !freshBridge.bodyFreshness().isFresh
          && freshBridge.latestBody() == nil)
    check("stale lab age is queryable",
          !freshBridge.labStateFreshness(maxAge: 1).isFresh
          && !freshBridge.labAckFreshness(maxAge: 1).isFresh
          && !freshBridge.labEventFreshness(maxAge: 1).isFresh
          && (freshBridge.labStateFreshness(maxAge: 1).ageSeconds ?? 0) > 1.5
          && freshBridge.latestLabState(maxAge: 1) == nil
          && freshBridge.latestLabAck(maxAge: 1) == nil
          && freshBridge.latestLabEvent(maxAge: 1) == nil)

    // V4 deterministic session identity is mandatory on state/ACK packets. A
    // legacy untagged ACK or delayed old-epoch ACK must never replace the current
    // authoritative result merely because it arrived on the current TCP socket.
    let v4Filter = FlyGymBridge()
    let v4Gen1 = v4Filter.beginConnectionForTesting()
    _ = v4Filter.sendSessionControl(action: "begin", sessionID: "strict-v4",
                                    epoch: 2, simTick: 0, mode: .deterministic)
    let staleBefore = v4Filter.staleSessionPacketCount
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":31,"ok":true,"action":"touch","message":"legacy"}"#.utf8))
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":32,"ok":true,"action":"touch","message":"old","session_id":"strict-v4","epoch":1,"applied_epoch":1,"applied_tick":0}"#.utf8))
    check("deterministic ACK requires current session + epoch",
          v4Filter.latestLabAck() == nil
          && v4Filter.staleSessionPacketCount == staleBefore + 2)
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":33,"ok":true,"action":"touch","message":"ok","status":"applied","session_id":"strict-v4","epoch":2,"applied_epoch":2,"applied_tick":0,"sim_tick":0}"#.utf8))
    check("current-epoch deterministic ACK accepted",
          v4Filter.latestLabAck()?.id == 33 && v4Filter.latestLabAck()?.appliedEpoch == 2)
    _ = v4Filter.sendSessionControl(action: "reset", sessionID: "strict-v4",
                                    epoch: 3, simTick: 0, mode: .deterministic,
                                    resetScope: ["body"])
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"session_state","protocol_version":4,"session_id":"strict-v4","epoch":3,"seq":4,"sim_tick":0,"mode":"deterministic","state":"paused","ok":true}"#.utf8))
    check("reset promotes expected epoch before confirmation",
          v4Filter.latestSessionState()?.epoch == 3
          && v4Filter.latestSessionState()?.state == "paused")
    let staleAfterReset = v4Filter.staleSessionPacketCount
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":35,"ok":true,"action":"touch","message":"late epoch 2","session_id":"strict-v4","epoch":2,"applied_epoch":2,"applied_tick":20}"#.utf8))
    check("old epoch ACK rejected after reset epoch promotion",
          v4Filter.latestLabAck() == nil
          && v4Filter.staleSessionPacketCount == staleAfterReset + 1)
    v4Filter.disconnectForTesting()
    let v4Gen2 = v4Filter.beginConnectionForTesting()
    _ = v4Filter.receiveLineForTesting(Data(#"{"type":"lab_ack","id":34,"ok":true,"action":"touch","message":"after reconnect","status":"applied","session_id":"strict-v4","epoch":3,"applied_epoch":3,"applied_tick":0,"sim_tick":0}"#.utf8))
    check("reconnect generation does not become simulation epoch",
          v4Gen2 == v4Gen1 + 1 && v4Filter.latestLabAck()?.id == 34
          && v4Filter.latestLabAck()?.epoch == 3)

    let v4Overflow = FlyGymBridge()
    _ = v4Overflow.beginConnectionForTesting()
    for i in 0..<32 {
        _ = v4Overflow.sendLab(action: "spawn_sphere", target: "v4q_\(i)",
                               protocolVersion: FlyGymProtocolV4.version,
                               sessionID: "queue-v4", epoch: 1, requestedTick: 0)
    }
    let rejectedID = v4Overflow.sendLab(action: "spawn_sphere", target: "v4q_overflow",
                                        protocolVersion: FlyGymProtocolV4.version,
                                        sessionID: "queue-v4", epoch: 1, requestedTick: 0)
    check("V4 discrete queue overflow fails closed visibly",
          v4Overflow.pendingLabDepth() == 32 && v4Overflow.labDropped == 1
          && v4Overflow.latestLabAck()?.id == rejectedID
          && v4Overflow.latestLabAck()?.ok == false
          && v4Overflow.latestLabAck()?.status == "queue_full")

    let v4Order = FlyGymBridge()
    _ = v4Order.beginConnectionForTesting()
    _ = v4Order.sendSessionControl(action: "begin", sessionID: "order-v4",
                                   epoch: 1, simTick: 0, mode: .deterministic)
    // Remove hello + begin control packets from the synthetic sender lane.
    _ = v4Order.dequeueLaneForTesting(at: Date())
    _ = v4Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.02))
    _ = v4Order.sendLab(action: "touch", target: "thorax", strength: 0.3,
                        durationMs: 50,
                        protocolVersion: FlyGymProtocolV4.version,
                        sessionID: "order-v4", epoch: 1, requestedTick: 0)
    var orderSignals = BrainSignals(); orderSignals.walkDrive = 0.2
    let orderStepQueued = v4Order.sendExperimentStep(sessionID: "order-v4", epoch: 1,
                                                     seq: 1, simTick: 0,
                                                     signals: orderSignals)
    let firstBoundaryLane = v4Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.04))
    let secondBoundaryLane = v4Order.dequeueLaneForTesting(at: Date().addingTimeInterval(0.06))
    check("V4 command wire order cannot be overtaken by boundary step",
          orderStepQueued && firstBoundaryLane == .lab && secondBoundaryLane == .experimentStep)

    // Fair sender arbitration: a full 32-command lab burst must drain while a
    // normal latest-state brain packet gets the wire at least every ~75 ms.
    let fair = FlyGymBridge()
    fair.maxNormalBrainGap = 0.075
    var normal = BrainSignals()
    normal.escape = false
    fair.sendBrain(normal, simMs: 0)
    for i in 0..<32 { _ = fair.sendLab(action: "move_object", target: "fair_\(i)", x: Double(i)) }
    let fairStart = Date()
    var fairNow = fairStart
    var lastBrain = fairStart
    var maxBrainGap = 0.0
    var normalBrainSends = 0
    var labSends = 0
    var fairnessSteps = 0
    while fair.pendingLabDepth() > 0 && fairnessSteps < 100 {
        if let lane = fair.dequeueLaneForTesting(at: fairNow) {
            switch lane {
            case .brain:
                if normalBrainSends > 0 {
                    maxBrainGap = max(maxBrainGap, fairNow.timeIntervalSince(lastBrain))
                }
                lastBrain = fairNow
                normalBrainSends += 1
                fair.sendBrain(normal, simMs: fairnessSteps + 1)
            case .lab:
                labSends += 1
            case .escape:
                break
            case .control, .experimentStep, .worldRender, .rayPick, .playerInput:
                break
            }
        }
        fairNow = fairNow.addingTimeInterval(fair.minSendInterval)
        fairnessSteps += 1
    }
    maxBrainGap = max(maxBrainGap, fairNow.timeIntervalSince(lastBrain))
    check("32-lab burst preserves <=100ms brain gap",
          labSends == 32 && fair.pendingLabDepth() == 0
          && normalBrainSends > 1 && maxBrainGap <= 0.100,
          String(format: "lab=%d brain=%d maxGap=%.1fms", labSends, normalBrainSends, maxBrainGap * 1000))
    print(failures == 0 ? "ALL BRIDGE TESTS PASS" : "\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Headless loop test (--bridgeloop, needs bridge.py --mock running)

/// Sends synthetic BrainSignals at ~60 Hz through the real TCP client and
/// counts body packets coming back. Verifies the full Swift<->Python loop.
func runBridgeLoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var waited = 0
    while !fg.connected && waited < 50 {
        Thread.sleep(forTimeInterval: 0.1); waited += 1
    }
    guard fg.connected else {
        print("FAIL  bridgeloop: no connection (is bridge.py --mock running?)")
        exit(1)
    }
    print("bridgeloop: connected, sending 200 packets @ ~75 Hz")
    let t0 = Date()
    var peakBodySpeed = 0.0
    for i in 0..<200 {
        var s = BrainSignals()
        s.walkDrive = 0.6; s.turnBias = 0.2
        s.arousal = 0.3; s.sleep = false
        fg.sendBrain(s, simMs: i * 13)
        if let b = fg.latestBody() { peakBodySpeed = max(peakBodySpeed, abs(b.vx)) }
        Thread.sleep(forTimeInterval: 1.0 / 75.0)
    }
    Thread.sleep(forTimeInterval: 1.0)   // let stragglers arrive
    if let b = fg.latestBody() { peakBodySpeed = max(peakBodySpeed, abs(b.vx)) }
    let dt = Date().timeIntervalSince(t0)
    let sent = fg.sentCount
    let recv = fg.recvCount
    let hz = fg.bodyHz
    let maxGap = fg.maxRecentBodyGap
    let finalBody = fg.latestBody()
    let simWall = finalBody?.simWallRatio ?? 0
    let brainHz = dt > 0 ? Double(sent) / dt : 0
    fg.stop()
    print(String(format: "bridgeloop: sent %d brain, recv %d body in %.1f s (brain %.1f Hz, body %.1f Hz, max body gap %.0f ms, sim/wall %.3f, peak |vx| %.2f mm/s)",
                 sent, recv, dt, brainHz, hz, maxGap * 1000, simWall, peakBodySpeed * 1000))
    // This synthetic packet intentionally asks the body to walk.  The loop is
    // not healthy if packets flow but the real body remains effectively static.
    let pass = sent >= 180 && recv >= 50 && hz >= 30
        && maxGap <= 0.250 && simWall > 0.25 && peakBodySpeed > 0.0005
    print(pass ? "BRIDGELOOP PASS" : "BRIDGELOOP FAIL")
    exit(pass ? 0 : 1)
}

// MARK: - V4 live lockstep test (--v4loop, needs bridge.py running)

/// Exercises the actual TCP V4 lifecycle without AppKit. This is intentionally
/// backend-agnostic: run it once against --mock and once against real headless
/// FlyGym to prove capability negotiation, exact 20 ms stepping, pause barriers,
/// command applied ticks, epoch reset, and true interactive body pause.
func runV4LoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }
    func waitUntil(_ seconds: Double, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }
    func waitSession(_ sessionID: String, epoch: Int, state: String,
                     seconds: Double = 8.0) -> FlyGymSessionStatePacket? {
        var found: FlyGymSessionStatePacket?
        _ = waitUntil(seconds) {
            guard let s = fg.latestSessionState(), s.sessionID == sessionID,
                  s.epoch == epoch, s.state == state else { return false }
            found = s; return true
        }
        return found
    }
    func waitStep(_ seq: Int, seconds: Double = 12.0) -> FlyGymExperimentStepResultPacket? {
        var found: FlyGymExperimentStepResultPacket?
        _ = waitUntil(seconds) {
            guard let r = fg.latestExperimentStepResult(), r.seq == seq else { return false }
            found = r; return true
        }
        return found
    }
    func waitAck(_ id: Int, seconds: Double = 8.0) -> LabAck? {
        var found: LabAck?
        _ = waitUntil(seconds) {
            guard let a = fg.latestLabAck(), a.id == id else { return false }
            found = a; return true
        }
        return found
    }

    let connected = waitUntil(10) { fg.connected && fg.serverHello() != nil }
    check("V4 live bridge connects and receives hello", connected)
    guard connected, let hello = fg.serverHello() else {
        fg.stop(); print("V4LOOP FAIL (\(max(1, failures)))"); exit(1)
    }
    check("backend advertises deterministic V4 + exact 20ms quantum",
          hello.supportsDeterministicV4,
          String(format: "protocol=%d physics=%.6fms quanta=%@",
                 hello.protocolVersion, (hello.physicsTimestepS ?? 0) * 1000,
                 String(describing: hello.supportedQuantumTicks)))

    let session = "v4loop-\(UUID().uuidString)"
    let beginQueued = fg.sendSessionControl(action: "begin", sessionID: session,
                                            epoch: 1, simTick: 0,
                                            mode: .deterministic) != nil
    let began = waitSession(session, epoch: 1, state: "running")
    check("deterministic session begins at epoch1 tick0",
          beginQueued && began?.ok == true && began?.simTick == 0)

    let commandID = fg.sendLab(action: "wind", strength: 0.35, durationMs: 80,
                               directionDeg: 45, physical: true, sensory: true,
                               continuous: false,
                               protocolVersion: FlyGymProtocolV4.version,
                               sessionID: session, epoch: 1, requestedTick: 0)
    var signals = BrainSignals(); signals.walkDrive = 0.25; signals.turnBias = 0.05
    let step0Queued = fg.sendExperimentStep(sessionID: session, epoch: 1, seq: 1,
                                            simTick: 0, signals: signals)
    let result0 = waitStep(1)
    let commandAck = waitAck(commandID)
    check("live lockstep advances exactly 20ms",
          step0Queued && result0?.ok == true && result0?.simTick == 0
          && result0?.endSimTick == 20
          && abs((result0?.body.t ?? -1) - 0.020) < 1e-8,
          "end=\(result0?.endSimTick ?? -1) body_t=\(result0?.body.t ?? -1)")
    check("live command applies at requested boundary before step",
          commandAck?.ok == true && commandAck?.appliedEpoch == 1
          && commandAck?.appliedTick == 0 && commandAck?.status == "applied",
          "ack_tick=\(commandAck?.appliedTick ?? -1) status=\(commandAck?.status ?? "nil")")

    let pauseQueued = fg.sendSessionControl(action: "pause", sessionID: session,
                                            epoch: 1, simTick: 20,
                                            mode: .deterministic) != nil
    let paused = waitSession(session, epoch: 1, state: "paused")
    let resultCountBeforeWall = fg.experimentStepRecvCount
    let bodyTimeBeforeWall = result0?.body.t ?? -1
    let pausedCommandID = fg.sendLab(action: "touch", target: "thorax",
                                     strength: 0.25, durationMs: 100,
                                     protocolVersion: FlyGymProtocolV4.version,
                                     sessionID: session, epoch: 1, requestedTick: 20)
    Thread.sleep(forTimeInterval: 1.05)
    let resultAfterWall = fg.latestExperimentStepResult()
    let pauseFrozen = pauseQueued && paused?.ok == true
        && fg.experimentStepRecvCount == resultCountBeforeWall
        && abs((resultAfterWall?.body.t ?? bodyTimeBeforeWall) - bodyTimeBeforeWall) < 1e-12
        && fg.latestLabAck()?.id != pausedCommandID
    check("live deterministic pause freezes for >1 wall second", pauseFrozen,
          "step_results=\(resultCountBeforeWall)->\(fg.experimentStepRecvCount)")

    let resumeQueued = fg.sendSessionControl(action: "resume", sessionID: session,
                                             epoch: 1, simTick: 20,
                                             mode: .deterministic) != nil
    let resumed = waitSession(session, epoch: 1, state: "running")
    let step1Queued = fg.sendExperimentStep(sessionID: session, epoch: 1, seq: 2,
                                            simTick: 20, signals: signals)
    let result1 = waitStep(2)
    let pausedAck = waitAck(pausedCommandID)
    check("resume advances one quantum without wall catch-up",
          resumeQueued && resumed?.ok == true && step1Queued
          && result1?.ok == true && result1?.endSimTick == 40
          && abs((result1?.body.t ?? -1) - 0.040) < 1e-8)
    check("paused command applies at first resumed boundary",
          pausedAck?.ok == true && pausedAck?.appliedTick == 20
          && pausedAck?.appliedEpoch == 1)

    _ = fg.sendSessionControl(action: "pause", sessionID: session,
                              epoch: 1, simTick: 40, mode: .deterministic)
    let pausedForReset = waitSession(session, epoch: 1, state: "paused")
    let resetQueued = fg.sendSessionControl(action: "reset", sessionID: session,
                                            epoch: 2, simTick: 0,
                                            mode: .deterministic,
                                            resetScope: ["body", "world"]) != nil
    let resetState = waitSession(session, epoch: 2, state: "paused")
    check("live logical reset advances epoch exactly once",
          pausedForReset?.ok == true && resetQueued && resetState?.ok == true
          && resetState?.epoch == 2 && resetState?.simTick == 0)

    // Start a fresh interactive session and prove its autonomous body loop also
    // stops at a real pause barrier. Interactive mode remains wall-paced, but
    // pause is no longer a SceneKit-only display state.
    let interactive = "v4loop-interactive-\(UUID().uuidString)"
    let interactiveBegin = fg.sendSessionControl(action: "begin", sessionID: interactive,
                                                  epoch: 1, simTick: 0,
                                                  mode: .interactive) != nil
    let interactiveRunning = waitSession(interactive, epoch: 1, state: "running")
    let gotInteractiveBody = waitUntil(12) { (fg.latestBody(maxAge: 2.0)?.simTime ?? 0) > 0 }
    let bodyBeforePauseRequest = fg.latestBody(maxAge: 2.0)?.simTime ?? -1
    let interactivePause = fg.sendSessionControl(action: "pause", sessionID: interactive,
                                                  epoch: 1, simTick: 0,
                                                  mode: .interactive) != nil
    let interactivePaused = waitSession(interactive, epoch: 1, state: "paused")
    // The backend may already be inside one autonomous physics chunk when the
    // control packet arrives. The pause barrier is the confirmed boundary after
    // that in-flight chunk, not the earlier wall instant when Swift queued it.
    let bodyAtPauseBarrier = fg.latestBody(maxAge: 2.0)?.simTime ?? -1
    Thread.sleep(forTimeInterval: 1.05)
    let bodyDuringPause = fg.latestBody(maxAge: 5.0)?.simTime ?? -2
    check("interactive V4 pause stops autonomous body physics",
          interactiveBegin && interactiveRunning?.ok == true && gotInteractiveBody
          && interactivePause && interactivePaused?.ok == true
          && bodyAtPauseBarrier >= bodyBeforePauseRequest
          && abs(bodyDuringPause - bodyAtPauseBarrier) < 1e-12,
          String(format: "request_t %.6f barrier_t %.6f -> %.6f",
                 bodyBeforePauseRequest, bodyAtPauseBarrier, bodyDuringPause))
    _ = fg.sendSessionControl(action: "resume", sessionID: interactive,
                              epoch: 1, simTick: 0, mode: .interactive)
    _ = waitSession(interactive, epoch: 1, state: "running")
    let interactiveAdvanced = waitUntil(12) {
        (fg.latestBody(maxAge: 2.0)?.simTime ?? bodyAtPauseBarrier) > bodyAtPauseBarrier + 1e-6
    }
    check("interactive resume advances again without paused-wall catch-up", interactiveAdvanced)

    // Same-machine repeatability: begin a fresh deterministic session, which
    // resets body/controller state, then replay the identical first-boundary
    // wind command and neural command used above. Protocol/controller fields are
    // exact; real MuJoCo observables use a tight numeric tolerance rather than a
    // cross-hardware bit-identity claim.
    let repeatSession = "v4loop-repeat-\(UUID().uuidString)"
    _ = fg.sendSessionControl(action: "begin", sessionID: repeatSession,
                              epoch: 1, simTick: 0, mode: .deterministic)
    let repeatBegan = waitSession(repeatSession, epoch: 1, state: "running")
    let repeatCommandID = fg.sendLab(action: "wind", strength: 0.35, durationMs: 80,
                                     directionDeg: 45, physical: true, sensory: true,
                                     continuous: false,
                                     protocolVersion: FlyGymProtocolV4.version,
                                     sessionID: repeatSession, epoch: 1, requestedTick: 0)
    let repeatQueued = fg.sendExperimentStep(sessionID: repeatSession, epoch: 1,
                                             seq: 1, simTick: 0, signals: signals)
    let repeatResult = waitStep(1)
    let repeatAck = waitAck(repeatCommandID)
    let reference = result0?.body
    let repeated = repeatResult?.body
    let exactRepeat = repeatBegan?.ok == true && repeatQueued
        && repeatResult?.ok == true && repeatResult?.endSimTick == result0?.endSimTick
        && repeatAck?.appliedTick == commandAck?.appliedTick
        && repeated?.t == reference?.t && repeated?.simDt == reference?.simDt
        && repeated?.controllerLeft == reference?.controllerLeft
        && repeated?.controllerRight == reference?.controllerRight
        && repeated?.contacts == reference?.contacts
    let physicalTolerance = 1e-9
    let numericRepeat = abs((repeated?.vx ?? .infinity) - (reference?.vx ?? 0)) <= physicalTolerance
        && abs((repeated?.yawRate ?? .infinity) - (reference?.yawRate ?? 0)) <= physicalTolerance
        && abs((repeated?.headingRad ?? .infinity) - (reference?.headingRad ?? 0)) <= physicalTolerance
    check("same-machine repeated deterministic real/mock quantum is reproducible",
          exactRepeat && numericRepeat,
          String(format: "Δvx=%.3g Δyaw=%.3g Δheading=%.3g",
                 abs((repeated?.vx ?? .infinity) - (reference?.vx ?? 0)),
                 abs((repeated?.yawRate ?? .infinity) - (reference?.yawRate ?? 0)),
                 abs((repeated?.headingRad ?? .infinity) - (reference?.headingRad ?? 0))))

    fg.stop()
    print(failures == 0 ? "V4LOOP PASS" : "V4LOOP FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Live lab protocol test (--labloop, needs bridge.py running)

/// Exercises the actual TCP lab lane and acknowledgement/state/event path.
/// Works against both `bridge.py --mock` and real FlyGym.
func runLabLoopTest() {
    let fg = FlyGymBridge()
    fg.start()
    var waited = 0
    while !fg.connected && waited < 80 {
        Thread.sleep(forTimeInterval: 0.1); waited += 1
    }
    guard fg.connected else {
        print("FAIL  labloop: no connection (start bridge.py --mock or --flygym-headless)")
        exit(1)
    }

    func waitAck(_ id: Int, seconds: Double = 3.0) -> LabAck? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let ack = fg.latestLabAck(), ack.id == id { return ack }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    var failures = 0
    func command(_ name: String, _ id: Int) {
        let ack = waitAck(id)
        let ok = ack?.ok == true
        let fresh = fg.labAckFreshness()
        let ageMs = fresh.ageSeconds.map { String(format: "%.0f", $0 * 1000) } ?? "n/a"
        print("\(ok ? "PASS" : "FAIL")  labloop \(name) ack=\(ack?.id ?? -1) \(ack?.message ?? "timeout")"
              + " gen=\(fresh.packetGeneration.map(String.init) ?? "n/a")/\(fresh.currentGeneration) age=\(ageMs)ms")
        if !ok { failures += 1 }
    }

    func bodyDiagnostic(_ body: FlyGymBodyFeedback?) -> String {
        let fresh = fg.bodyFreshness()
        let ageMs = fresh.ageSeconds.map { String(format: "%.0f", $0 * 1000) } ?? "n/a"
        guard let body else {
            return "body=nil gen=\(fresh.packetGeneration.map(String.init) ?? "n/a")/\(fresh.currentGeneration) age=\(ageMs)ms fresh=\(fresh.isFresh)"
        }
        return String(format: "t=%.4fs dt=%.4fs wind=%.3f touch=%.3f gen=%@/%llu age=%@ms fresh=%@",
                      body.simTime, body.simDt, body.windStrength, body.touchStrength,
                      fresh.packetGeneration.map(String.init) ?? "n/a", fresh.currentGeneration,
                      ageMs, fresh.isFresh ? "yes" : "no")
    }

    let objectID = "labloop_ball_\(ProcessInfo.processInfo.processIdentifier)"
    let spawn = fg.sendLab(action: "spawn_sphere", target: objectID,
                           x: 20, y: 5, z: 3, size: 4)
    command("spawn", spawn)
    if (fg.latestLabState()?.objectCount ?? 0) < 1 {
        Thread.sleep(forTimeInterval: 0.15)
    }
    let stateOK = (fg.latestLabState()?.objectCount ?? 0) >= 1
    print("\(stateOK ? "PASS" : "FAIL")  labloop state object_count=\(fg.latestLabState()?.objectCount ?? -1)")
    if !stateOK { failures += 1 }

    let wind = fg.sendLab(action: "wind", strength: 0.2, durationMs: 300,
                          directionDeg: 90, physical: true, sensory: true, continuous: false)
    command("wind", wind)
    let flash = fg.sendLab(action: "flash_eye", target: "left", strength: 0.8, durationMs: 80)
    command("flash", flash)
    let touch = fg.sendLab(action: "touch", target: "thorax", strength: 0.2, durationMs: 300)
    command("touch", touch)
    let sourceDeadline = Date().addingTimeInterval(0.25)
    var sourceOK = false
    var sourceBody: FlyGymBodyFeedback?
    while Date() < sourceDeadline {
        if let body = fg.latestBody(), body.windStrength > 0.19, body.windSensory,
           body.touchStrength > 0.19, body.touchSensory {
            sourceOK = true
            sourceBody = body
            break
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    print("\(sourceOK ? "PASS" : "FAIL")  labloop body packet is wind/touch source-of-truth — \(bodyDiagnostic(sourceBody ?? fg.latestBody()))")
    if !sourceOK { failures += 1 }

    // The backend timer is expressed in MuJoCo simulation time, not wall time.
    // A slow real backend may need much more than 300 ms of wall time to advance
    // 300 ms of simulation. Accept only a bounded simulation-time expiry window:
    // too-early clear, frozen timers and excessively late clear are all failures.
    // The tolerance covers one observed body packet plus a few physics/telemetry
    // steps; wall time remains only a hang guard.
    let sourceSimTime = sourceBody?.simTime ?? fg.latestBody()?.simTime ?? 0
    let requestedDurationS = 0.300
    let sourceDt = max(0.001, sourceBody?.simDt ?? fg.latestBody()?.simDt ?? 0.001)
    let expiryToleranceS = max(0.060, min(0.120, sourceDt * 4 + 0.020))
    let expiryTargetSimTime = sourceSimTime + requestedDurationS
    let expiryEarliestSimTime = expiryTargetSimTime - expiryToleranceS
    let expiryLatestSimTime = expiryTargetSimTime + expiryToleranceS
    let expiryWallDeadline = Date().addingTimeInterval(12.0)
    var expired: FlyGymBodyFeedback?
    var expiredTooEarly = false
    var expiredTooLate = false
    var expiredInWindow = false
    while Date() < expiryWallDeadline {
        if let body = fg.latestBody() {
            expired = body
            let cleared = body.windStrength == 0 && body.touchStrength == 0
            if cleared {
                if body.simTime < expiryEarliestSimTime {
                    expiredTooEarly = true
                } else if body.simTime <= expiryLatestSimTime {
                    expiredInWindow = true
                } else {
                    expiredTooLate = true
                }
                break
            }
            if body.simTime > expiryLatestSimTime {
                expiredTooLate = true
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let expiredOK = expiredInWindow && !expiredTooEarly && !expiredTooLate
    print("\(expiredOK ? "PASS" : "FAIL")  labloop body source clears on simulation-time timer expiry"
          + " target_t=\(String(format: "%.4f", expiryTargetSimTime))s"
          + " window=[\(String(format: "%.4f", expiryEarliestSimTime)),\(String(format: "%.4f", expiryLatestSimTime))]s"
          + " — \(bodyDiagnostic(expired))")
    if !expiredOK { failures += 1 }
    if let event = fg.latestLabEvent() {
        print("PASS  labloop event \(event.event)")
    } else {
        print("FAIL  labloop event missing"); failures += 1
    }
    // Clean up only the object this test created. Never reset an already-running
    // user's body/world merely because --labloop connected to that listener.
    let cleanup = fg.sendLab(action: "delete_object", target: objectID)
    command("delete_object", cleanup)

    fg.stop()
    print(failures == 0 ? "LABLOOP PASS" : "LABLOOP FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}
