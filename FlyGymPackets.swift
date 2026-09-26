// FlyGymPackets.swift — wire types, decoding and body feedback mapping.
import Foundation

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

// A single JSONDecoder traversal validates the tag and payload together.
// Both the receive loop and focused parsers use the payload's existing decoder,
// preserving strict V5 validation and tolerant legacy telemetry defaults.
private protocol FlyGymWirePacket: Decodable {
    static var wireType: String { get }
}

private enum FlyGymWireKey: String, CodingKey { case type }

private struct FlyGymTaggedPacket<Packet: FlyGymWirePacket>: Decodable {
    let packet: Packet

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlyGymWireKey.self)
        guard try container.decode(String.self, forKey: .type) == Packet.wireType else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                  debugDescription: "Unexpected packet type")
        }
        packet = try Packet(from: decoder)
    }
}

extension FlyGymBodyPacket: FlyGymWirePacket {
    fileprivate static var wireType: String { "body" }
}

func parseBodyLine(_ line: Data) -> FlyGymBodyPacket? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<FlyGymBodyPacket>.self, from: line))?.packet
}

extension LabRemoteState: FlyGymWirePacket {
    fileprivate static var wireType: String { "lab_state" }
}

func parseLabStateLine(_ line: Data) -> LabRemoteState? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<LabRemoteState>.self, from: line))?.packet
}

extension LabAck: FlyGymWirePacket {
    fileprivate static var wireType: String { "lab_ack" }
}

func parseLabAckLine(_ line: Data) -> LabAck? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<LabAck>.self, from: line))?.packet
}

extension LabEventNotice: FlyGymWirePacket {
    fileprivate static var wireType: String { "lab_event" }
}

func parseLabEventLine(_ line: Data) -> LabEventNotice? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<LabEventNotice>.self, from: line))?.packet
}

extension PlayerInputPacket: FlyGymWirePacket {
    fileprivate static var wireType: String { "player_input" }
}

func decodePlayerInputLine(_ line: Data) -> PlayerInputPacket? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<PlayerInputPacket>.self, from: line))?.packet
}

extension PlayerInputResult: FlyGymWirePacket {
    fileprivate static var wireType: String { "player_input_result" }
}

func parsePlayerInputResultLine(_ line: Data) -> PlayerInputResult? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<PlayerInputResult>.self, from: line))?.packet
}

extension FlyGymHelloPacket: FlyGymWirePacket {
    fileprivate static var wireType: String { "hello" }
}

func parseHelloLine(_ line: Data) -> FlyGymHelloPacket? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<FlyGymHelloPacket>.self, from: line))?.packet
}

extension FlyGymSessionStatePacket: FlyGymWirePacket {
    fileprivate static var wireType: String { "session_state" }
}

func parseSessionStateLine(_ line: Data) -> FlyGymSessionStatePacket? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<FlyGymSessionStatePacket>.self, from: line))?.packet
}

extension FlyGymExperimentStepResultPacket: FlyGymWirePacket {
    fileprivate static var wireType: String { "experiment_step_result" }
}

func parseExperimentStepResultLine(_ line: Data) -> FlyGymExperimentStepResultPacket? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<FlyGymExperimentStepResultPacket>.self, from: line))?.packet
}

extension WorldRenderSnapshot: FlyGymWirePacket {
    fileprivate static var wireType: String { "world_render_snapshot" }
}

func parseWorldRenderSnapshotLine(_ line: Data) -> WorldRenderSnapshot? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<WorldRenderSnapshot>.self, from: line))?.packet
}

extension RayPickResult: FlyGymWirePacket {
    fileprivate static var wireType: String { "ray_pick_result" }
}

func parseRayPickResultLine(_ line: Data) -> RayPickResult? {
    (try? JSONDecoder().decode(FlyGymTaggedPacket<RayPickResult>.self, from: line))?.packet
}

/// Only Python -> Swift packets belong here. Outbound-only input is rejected.
enum FlyGymInboundPacket: Decodable {
    case body(FlyGymBodyPacket)
    case labState(LabRemoteState)
    case labAck(LabAck)
    case labEvent(LabEventNotice)
    case playerInputResult(PlayerInputResult)
    case hello(FlyGymHelloPacket)
    case sessionState(FlyGymSessionStatePacket)
    case experimentStepResult(FlyGymExperimentStepResultPacket)
    case worldRenderSnapshot(WorldRenderSnapshot)
    case rayPickResult(RayPickResult)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlyGymWireKey.self)
        switch try container.decode(String.self, forKey: .type) {
        case FlyGymBodyPacket.wireType: self = .body(try FlyGymBodyPacket(from: decoder))
        case LabRemoteState.wireType: self = .labState(try LabRemoteState(from: decoder))
        case LabAck.wireType: self = .labAck(try LabAck(from: decoder))
        case LabEventNotice.wireType: self = .labEvent(try LabEventNotice(from: decoder))
        case PlayerInputResult.wireType: self = .playerInputResult(try PlayerInputResult(from: decoder))
        case FlyGymHelloPacket.wireType: self = .hello(try FlyGymHelloPacket(from: decoder))
        case FlyGymSessionStatePacket.wireType: self = .sessionState(try FlyGymSessionStatePacket(from: decoder))
        case FlyGymExperimentStepResultPacket.wireType: self = .experimentStepResult(try FlyGymExperimentStepResultPacket(from: decoder))
        case WorldRenderSnapshot.wireType: self = .worldRenderSnapshot(try WorldRenderSnapshot(from: decoder))
        case RayPickResult.wireType: self = .rayPickResult(try RayPickResult(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                  debugDescription: "Unknown inbound packet type")
        }
    }
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

