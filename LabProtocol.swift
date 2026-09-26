// LabProtocol.swift — compact protocol and telemetry types for Virtual Fly Lab V2.
//
// Classification used by the UI is deliberately explicit:
//   physical       = a MuJoCo/FlyGym world mutation handled by the Python owner thread
//   sensory-model  = an engineered sensory/environment transform into existing inputs
//   direct-neural  = electrical stimulation of an existing MetalSim population

import Foundation
import Cocoa

/// Local receive metadata attached by FlyGymBridge after a packet is accepted
/// on the current TCP connection. `connectionGeneration` lets callers reject a
/// packet from a previous reconnect epoch even when its payload is otherwise
/// valid; `receivedAt` provides a directly displayable packet age.
protocol FlyGymStampedPacket {
    var receivedAt: Date { get set }
    var connectionGeneration: UInt64 { get set }
}

extension FlyGymStampedPacket {
    func ageSeconds(at now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(receivedAt))
    }
}

enum LabInterventionKind: String {
    case physical = "PHYSICAL"
    case sensoryModel = "SENSORY-MODEL"
    case directNeural = "DIRECT-NEURAL"
}

/// Swift -> Python. Kept flat so both sides can tolerate new optional fields.
/// Commands are queued in a small bounded FIFO by FlyGymBridge and never touch
/// the socket from AppKit or the SceneKit render callback.
struct LabCommand: Codable {
    var type = "lab_command"
    var id: Int
    var action: String
    var target: String?
    var x: Double?
    var y: Double?
    var z: Double?
    var size: Double?
    var speed: Double?
    var strength: Double?
    var durationMs: Int?
    var value: Double?
    var directionDeg: Double? = nil
    var endDistance: Double? = nil
    var physical: Bool? = nil
    var sensory: Bool? = nil
    var continuous: Bool? = nil
    var mode: String? = nil
    // V5.6 interaction fields. Optional encoding preserves legacy commands.
    var toolID: String? = nil
    var actorID: String? = nil
    var rayOriginMM: [Double]? = nil
    var rayDirection: [Double]? = nil
    // V4 deterministic-session envelope. Nil preserves the V3/legacy wire shape.
    var protocolVersion: Int? = nil
    var sessionID: String? = nil
    var epoch: Int? = nil
    var requestedTick: Int? = nil

    enum CodingKeys: String, CodingKey {
        case type, id, action, target, x, y, z, size, speed, strength, value
        case durationMs = "duration_ms"
        case directionDeg = "direction_deg"
        case endDistance = "end_distance_mm"
        case physical, sensory, continuous, mode
        case toolID = "tool_id"
        case actorID = "actor_id"
        case rayOriginMM = "ray_origin_mm"
        case rayDirection = "ray_direction"
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case epoch
        case requestedTick = "requested_tick"
    }
}

extension LabCommand {
    static func interaction(id: Int, toolID: String, actorID: String,
                            target: String? = nil, rayOriginMM: [Double]? = nil,
                            rayDirection: [Double]? = nil,
                            protocolVersion: Int? = nil, sessionID: String? = nil,
                            epoch: Int? = nil, requestedTick: Int? = nil) -> LabCommand? {
        guard toolID == "grab" || toolID == "place", !actorID.isEmpty else { return nil }
        if toolID == "grab" {
            guard let rayOriginMM, let rayDirection,
                  rayOriginMM.count == 3, rayDirection.count == 3,
                  rayOriginMM.allSatisfy(\.isFinite), rayDirection.allSatisfy(\.isFinite),
                  rayDirection.contains(where: { $0 != 0 }) else { return nil }
        } else if rayOriginMM != nil || rayDirection != nil {
            return nil
        }
        return LabCommand(id: id, action: "interaction", target: target,
                          toolID: toolID, actorID: actorID,
                          rayOriginMM: rayOriginMM, rayDirection: rayDirection,
                          protocolVersion: protocolVersion, sessionID: sessionID,
                          epoch: epoch, requestedTick: requestedTick)
    }
}

/// V5.5 Swift -> Python participant control state. Movement is stateful and
/// tick-scheduled; the backend integrates distance from simulation time. Look is
/// an incremental yaw/pitch delta in radians and is coalesced by the bridge.
struct PlayerInputPacket: Codable, Equatable {
    static let maxSeq = 2_147_483_647
    static let maxTick = 1_000_000_000_000_000
    static let maxProtocolVersion = 1_000_000
    static let maxLookDelta = Double.pi / 4.0

    var type: String = "player_input"
    var protocolVersion: Int = FlyGymProtocolV4.version
    var actorID: String = "player"
    var sessionID: String
    var epoch: Int
    var seq: Int
    var requestedTick: Int
    var moveAxes: [Double]
    var lookDelta: [Double]
    var heldActions: [String]

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case actorID = "actor_id"
        case sessionID = "session_id"
        case epoch, seq
        case requestedTick = "requested_tick"
        case moveAxes = "move_axes"
        case lookDelta = "look_delta"
        case heldActions = "held_actions"
    }

    init(protocolVersion: Int = FlyGymProtocolV4.version,
         actorID: String = "player", sessionID: String, epoch: Int, seq: Int,
         requestedTick: Int, moveAxes: [Double], lookDelta: [Double],
         heldActions: [String]) {
        self.protocolVersion = min(Self.maxProtocolVersion,
                                   max(FlyGymProtocolV4.version, protocolVersion))
        let trimmedActor = actorID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.actorID = trimmedActor.isEmpty ? "player" : String(trimmedActor.prefix(64))
        self.sessionID = String(sessionID.prefix(128))
        self.epoch = max(0, epoch)
        self.seq = min(Self.maxSeq, max(0, seq))
        self.requestedTick = min(Self.maxTick, max(0, requestedTick))
        self.moveAxes = Self.boundedPair(moveAxes, limit: 1.0)
        self.lookDelta = Self.boundedPair(lookDelta, limit: Self.maxLookDelta)
        var seen = Set<String>()
        self.heldActions = heldActions.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value == "interact", seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func boundedPair(_ values: [Double], limit: Double) -> [Double] {
        guard values.count == 2 else { return [0.0, 0.0] }
        return values.map { value in
            guard value.isFinite else { return 0.0 }
            return max(-limit, min(limit, value))
        }
    }
}

/// Python -> Swift authoritative result for one PlayerInput packet. This ACK is
/// diagnostic/scheduling evidence only; player pose and Participate mode remain
/// owned by WorldRenderSnapshot.
struct PlayerInputResult: Decodable, FlyGymStampedPacket {
    var type: String = "player_input_result"
    var protocolVersion: Int
    var actorID: String
    var sessionID: String
    var epoch: Int
    var seq: Int
    var requestedTick: Int
    var appliedTick: Int?
    var ok: Bool
    var status: String
    var error: String?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq, ok, status, error
        case protocolVersion = "protocol_version"
        case actorID = "actor_id"
        case sessionID = "session_id"
        case requestedTick = "requested_tick"
        case appliedTick = "applied_tick"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "player_input_result" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "wrong player input result type")
        }
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        actorID = try c.decode(String.self, forKey: .actorID).trimmingCharacters(in: .whitespacesAndNewlines)
        sessionID = try c.decode(String.self, forKey: .sessionID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        epoch = try c.decode(Int.self, forKey: .epoch)
        seq = try c.decode(Int.self, forKey: .seq)
        requestedTick = try c.decode(Int.self, forKey: .requestedTick)
        let hasAppliedTick = c.contains(.appliedTick)
        appliedTick = try c.decodeIfPresent(Int.self, forKey: .appliedTick)
        ok = try c.decode(Bool.self, forKey: .ok)
        let rawStatus = try c.decode(String.self, forKey: .status)
        status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasError = c.contains(.error)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        guard protocolVersion >= FlyGymProtocolV4.version,
              protocolVersion <= PlayerInputPacket.maxProtocolVersion,
              !actorID.isEmpty, actorID.count <= 64,
              sessionID.count <= 128,
              ((sessionID.isEmpty && epoch == 0) || (!sessionID.isEmpty && epoch >= 1)),
              seq >= 0, seq <= PlayerInputPacket.maxSeq,
              requestedTick >= 0, requestedTick <= PlayerInputPacket.maxTick,
              !status.isEmpty, rawStatus.count <= 64 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "invalid player input result fields"))
        }
        if ok {
            guard status == "applied", hasAppliedTick,
                  let appliedTick, appliedTick >= 0,
                  appliedTick <= PlayerInputPacket.maxTick,
                  !hasError, error == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                        debugDescription: "successful player input result requires applied_tick and no error"))
            }
        } else {
            guard !hasAppliedTick, appliedTick == nil, status != "applied", hasError,
                  let error,
                  !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  error.count <= 512 else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                        debugDescription: "failed player input result requires rejection status/error and no applied_tick"))
            }
        }
    }
}

/// Python -> Swift acknowledgement for one LabCommand.
struct LabAck: Decodable, FlyGymStampedPacket {
    var type: String = "lab_ack"
    var id: Int = 0
    var ok: Bool = false
    var action: String = ""
    var message: String = ""
    var appliedTick: Int?
    var appliedEpoch: Int?
    var status: String?
    var sessionID: String?
    var epoch: Int?
    var simTick: Int?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, id, ok, action, message, status, epoch
        case appliedTick = "applied_tick"
        case appliedEpoch = "applied_epoch"
        case sessionID = "session_id"
        case simTick = "sim_tick"
    }
}

/// V5.6 `lab_event.data` fields. Every field is optional and a malformed payload
/// only drops the detail, never the event itself.
struct LabEventDetail: Decodable, Equatable {
    var id: String?
    var reason: String?
    var simTickMS: Int?
    var flySegment: String?
    var normalForce: Double?
    var peakNormalForce: Double?
    var durationMS: Int?
    var blockingGeomKind: String?
    var forceUnits: String?

    enum CodingKeys: String, CodingKey {
        case id, reason
        case simTickMS = "sim_tick_ms"
        case flySegment = "fly_segment"
        case normalForce = "normal_force"
        case peakNormalForce = "peak_normal_force"
        case durationMS = "duration_ms"
        case blockingGeomKind = "blocking_geom_kind"
        case forceUnits = "force_units"
    }

    /// One timeline line; force stays in backend model units, never converted.
    var summary: String {
        var parts: [String] = []
        if let id { parts.append(id) }
        if let flySegment { parts.append(L("fly \(flySegment)", "파리 \(flySegment)")) }
        if let reason { parts.append(reason) }
        if let blockingGeomKind { parts.append(L("by \(blockingGeomKind)", "\(blockingGeomKind)에 막힘")) }
        let units = forceUnits == "mujoco_model" ? L(" (model units)", " (모델 단위)") : ""
        if let normalForce, normalForce.isFinite {
            parts.append(L("force ", "힘 ") + String(format: "%.4g", normalForce) + units)
        }
        if let peakNormalForce, peakNormalForce.isFinite {
            parts.append(L("peak ", "최대 ") + String(format: "%.4g", peakNormalForce) + units)
        }
        if let durationMS { parts.append("\(durationMS) ms") }
        if let simTickMS { parts.append("@\(simTickMS) ms") }
        return parts.joined(separator: " · ")
    }
}

/// Python -> Swift lifecycle marker (approach/wind/touch/flash, V5.6
/// grab/place/contact). Unknown payload fields remain forward-compatible.
struct LabEventNotice: Decodable, FlyGymStampedPacket {
    var type: String = "lab_event"
    var event: String = ""
    var detail: LabEventDetail?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, event
        case detail = "data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "lab_event"
        event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
        detail = try? c.decodeIfPresent(LabEventDetail.self, forKey: .detail)
    }

    init(type: String = "lab_event", event: String = "", detail: LabEventDetail? = nil) {
        self.type = type
        self.event = event
        self.detail = detail
    }
}

struct LabWorldObjectRemote: Decodable {
    var id: String
    var shape: String
    var positionMM: [Double]
    var sizeMM: [Double]
    var yawDeg: Double

    enum CodingKeys: String, CodingKey {
        case id, shape
        case positionMM = "position_mm"
        case sizeMM = "size_mm"
        case yawDeg = "yaw_deg"
    }
}

struct LabRemoteWorldState: Decodable {
    var objects: [LabWorldObjectRemote]?
    var slotCapacity: [String: Int]?
    var slotFree: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case objects
        case slotCapacity = "slot_capacity"
        case slotFree = "slot_free"
    }
}

struct LabInteractionState: Decodable {
    let heldObjectID: String?
    let carryBlocked: Bool
    let reachMM: Double
    /// Optional backend carry-speed bound; nil from a backend that omits it.
    let carrySpeedMMs: Double?

    enum CodingKeys: String, CodingKey {
        case heldObjectID = "held_object_id"
        case carryBlocked = "carry_blocked"
        case reachMM = "reach_mm"
        case carrySpeedMMs = "carry_speed_mm_s"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.heldObjectID) else {
            throw DecodingError.keyNotFound(CodingKeys.heldObjectID, .init(codingPath: c.codingPath,
                                                                            debugDescription: "held_object_id required"))
        }
        heldObjectID = try c.decodeIfPresent(String.self, forKey: .heldObjectID)
        carryBlocked = try c.decode(Bool.self, forKey: .carryBlocked)
        reachMM = try c.decode(Double.self, forKey: .reachMM)
        guard reachMM.isFinite, reachMM > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .reachMM, in: c,
                                                   debugDescription: "reach_mm must be finite and positive")
        }
        carrySpeedMMs = try c.decodeIfPresent(Double.self, forKey: .carrySpeedMMs)
        if let speed = carrySpeedMMs, !(speed.isFinite && speed > 0) {
            throw DecodingError.dataCorruptedError(forKey: .carrySpeedMMs, in: c,
                                                   debugDescription: "carry_speed_mm_s must be finite and positive")
        }
    }
}

/// Python -> Swift compact lab state. Every field except `type` is optional so
/// older/newer bridge versions remain displayable instead of becoming malformed.
struct LabRemoteState: Decodable, FlyGymStampedPacket {
    var type: String = "lab_state"
    var t: Double = 0
    var ack: Int?
    var ok: Bool?
    var error: String?
    var objectCount: Int?
    // `worldState` is the authoritative nested backend state. The optional
    // flat fields remain decode-compatible with short-lived V4 development builds.
    var objects: [LabWorldObjectRemote]?
    var slotCapacity: [String: Int]?
    var slotFree: [String: Int]?
    var worldState: LabRemoteWorldState?
    var temperature: Double?
    var wind: Double?
    var leftEyeCovered: Bool?
    var rightEyeCovered: Bool?
    var lastAction: String?
    var appliedTick: Int?
    var appliedEpoch: Int?
    var status: String?
    var sessionID: String?
    var epoch: Int?
    var simTick: Int?
    var interaction: LabInteractionState?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, t, ack, ok, error, temperature, wind, status, epoch
        case objectCount = "object_count"
        case objects
        case slotCapacity = "slot_capacity"
        case slotFree = "slot_free"
        case worldState = "state"
        case leftEyeCovered = "left_eye_covered"
        case rightEyeCovered = "right_eye_covered"
        case lastAction = "last_action"
        case appliedTick = "applied_tick"
        case appliedEpoch = "applied_epoch"
        case sessionID = "session_id"
        case simTick = "sim_tick"
        case interaction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        ack = try c.decodeIfPresent(Int.self, forKey: .ack)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        objectCount = try c.decodeIfPresent(Int.self, forKey: .objectCount)
        objects = try c.decodeIfPresent([LabWorldObjectRemote].self, forKey: .objects)
        slotCapacity = try c.decodeIfPresent([String: Int].self, forKey: .slotCapacity)
        slotFree = try c.decodeIfPresent([String: Int].self, forKey: .slotFree)
        worldState = try c.decodeIfPresent(LabRemoteWorldState.self, forKey: .worldState)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        wind = try c.decodeIfPresent(Double.self, forKey: .wind)
        leftEyeCovered = try c.decodeIfPresent(Bool.self, forKey: .leftEyeCovered)
        rightEyeCovered = try c.decodeIfPresent(Bool.self, forKey: .rightEyeCovered)
        lastAction = try c.decodeIfPresent(String.self, forKey: .lastAction)
        appliedTick = try c.decodeIfPresent(Int.self, forKey: .appliedTick)
        appliedEpoch = try c.decodeIfPresent(Int.self, forKey: .appliedEpoch)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch)
        simTick = try c.decodeIfPresent(Int.self, forKey: .simTick)
        // A malformed interaction block must not discard otherwise valid lab_state.
        interaction = try? c.decode(LabInteractionState.self, forKey: .interaction)
    }

    var authoritativeObjects: [LabWorldObjectRemote]? { objects ?? worldState?.objects }
    var authoritativeSlotCapacity: [String: Int]? { slotCapacity ?? worldState?.slotCapacity }
    var authoritativeSlotFree: [String: Int]? { slotFree ?? worldState?.slotFree }
}

// MARK: - V5.1 atomic world render / picking protocol

private enum WorldRenderDecode {
    static func finiteVector(_ value: [Double], count: Int, name: String) throws -> [Double] {
        guard value.count == count, value.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "\(name) must contain \(count) finite values"))
        }
        return value
    }

    static func unitQuaternion(_ value: [Double], name: String) throws -> [Double] {
        let q = try finiteVector(value, count: 4, name: name)
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard norm >= 1e-12, abs(norm - 1) <= 1e-3 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "\(name) must be normalized"))
        }
        return q
    }
}

/// One pose copied from the Python simulation owner. This is deliberately
/// independent from the desktop-overlay Fly in `main.swift`.
struct WorldRenderPose: Decodable {
    var id: String
    var positionMM: [Double]
    var orientationQuatXYZW: [Double]
    // Forward-compatible optional player metadata. V5.1 renders it if supplied
    // but does not create, move, or otherwise control a player body.
    var collisionRadiusMM: Double?
    var mode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case actorID = "actor_id"
        case positionMM = "position_mm"
        case orientationQuatXYZW = "orientation_quat_xyzw"
        case collisionRadiusMM = "collision_radius_mm"
        case mode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .actorID)
        guard let rawID else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                                            .init(codingPath: decoder.codingPath,
                                                  debugDescription: "pose requires id or actor_id"))
        }
        let trimmedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.count <= 128 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                                                   debugDescription: "pose id is invalid")
        }
        id = trimmedID
        positionMM = try WorldRenderDecode.finiteVector(
            c.decode([Double].self, forKey: .positionMM), count: 3, name: "position_mm")
        orientationQuatXYZW = try WorldRenderDecode.unitQuaternion(
            c.decode([Double].self, forKey: .orientationQuatXYZW), name: "orientation_quat_xyzw")
        if let radius = try c.decodeIfPresent(Double.self, forKey: .collisionRadiusMM) {
            guard radius.isFinite, radius >= 0, radius <= 1000 else {
                throw DecodingError.dataCorruptedError(forKey: .collisionRadiusMM, in: c,
                                                       debugDescription: "collision_radius_mm must be finite and in 0...1000")
            }
            collisionRadiusMM = radius
        } else {
            collisionRadiusMM = nil
        }
        if let rawMode = try c.decodeIfPresent(String.self, forKey: .mode) {
            let trimmedMode = rawMode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMode.isEmpty, trimmedMode.count <= 32 else {
                throw DecodingError.dataCorruptedError(forKey: .mode, in: c,
                                                       debugDescription: "pose mode is invalid")
            }
            mode = trimmedMode
        } else {
            mode = nil
        }
    }
}

struct WorldRenderObject: Decodable {
    var id: String
    var shape: String
    var positionMM: [Double]
    var orientationQuatXYZW: [Double]
    var sizeMM: [Double]
    var revision: Int
    var collidable: Bool
    var classification: String?

    enum CodingKeys: String, CodingKey {
        case id, shape, revision, collidable, classification
        case positionMM = "position_mm"
        case orientationQuatXYZW = "orientation_quat_xyzw"
        case sizeMM = "size_mm"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawShape = try c.decode(String.self, forKey: .shape).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty, rawID.count <= 128, !rawShape.isEmpty, rawShape.count <= 32 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                                                   debugDescription: "render object id/shape is invalid")
        }
        id = rawID
        shape = rawShape.lowercased()
        positionMM = try WorldRenderDecode.finiteVector(
            c.decode([Double].self, forKey: .positionMM), count: 3, name: "position_mm")
        orientationQuatXYZW = try WorldRenderDecode.unitQuaternion(
            c.decode([Double].self, forKey: .orientationQuatXYZW), name: "orientation_quat_xyzw")
        sizeMM = try WorldRenderDecode.finiteVector(
            c.decode([Double].self, forKey: .sizeMM), count: 3, name: "size_mm")
        guard sizeMM.allSatisfy({ $0 > 0 }) else {
            throw DecodingError.dataCorruptedError(forKey: .sizeMM, in: c,
                                                   debugDescription: "size_mm must be positive")
        }
        revision = try c.decode(Int.self, forKey: .revision)
        guard revision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .revision, in: c,
                                                   debugDescription: "revision must be non-negative")
        }
        collidable = try c.decodeIfPresent(Bool.self, forKey: .collidable) ?? true
        classification = try c.decodeIfPresent(String.self, forKey: .classification)
    }
}

/// Python -> Swift atomic world state. Object and fly poses in this structure
/// share one simulation-owner boundary; the viewer must never join this with a
/// separate body or lab_state packet to create a synthetic snapshot.
struct WorldRenderSnapshot: Decodable, FlyGymStampedPacket {
    var type: String = "world_render_snapshot"
    var protocolVersion: Int = 0
    var sessionID: String = ""
    var epoch: Int = 0
    var requestSeq: Int = 0
    var simTick: Int = 0
    var ok: Bool = false
    var error: String?
    var snapshotID: Int?
    var revision: Int?
    var fly: WorldRenderPose?
    var objects: [WorldRenderObject] = []
    var player: WorldRenderPose?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, epoch, ok, error, objects, fly, player
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case requestSeq = "request_seq"
        case simTick = "sim_tick"
        case snapshotSeq = "snapshot_seq"
        case worldRevision = "world_revision"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        epoch = try c.decode(Int.self, forKey: .epoch)
        requestSeq = try c.decode(Int.self, forKey: .requestSeq)
        simTick = try c.decode(Int.self, forKey: .simTick)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        guard protocolVersion >= 0, sessionID.count <= 128, epoch >= 0,
              requestSeq >= 0, simTick >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid snapshot envelope"))
        }
        if !ok {
            guard let error, !error.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "failed snapshot requires error"))
            }
            return
        }
        snapshotID = try c.decode(Int.self, forKey: .snapshotSeq)
        revision = try c.decode(Int.self, forKey: .worldRevision)
        guard let snapshotID, snapshotID > 0, let revision, revision >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "successful snapshot requires snapshot id and revision"))
        }
        fly = try c.decode(WorldRenderPose.self, forKey: .fly)
        objects = try c.decode([WorldRenderObject].self, forKey: .objects)
        player = try c.decodeIfPresent(WorldRenderPose.self, forKey: .player)
        if let player {
            guard let radius = player.collisionRadiusMM, radius > 0,
                  player.mode != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "player requires positive collision_radius_mm and mode"))
            }
        }
        guard Set(objects.map(\.id)).count == objects.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "snapshot object ids must be unique"))
        }
    }
}

struct WorldRenderRequest: Encodable {
    var type = "world_render_request"
    var protocolVersion = FlyGymProtocolV4.version
    var sessionID: String
    var epoch: Int
    var seq: Int

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
    }
}

struct RayPickRequest: Encodable {
    var type = "ray_pick_request"
    var protocolVersion = FlyGymProtocolV4.version
    var sessionID: String
    var epoch: Int
    var seq: Int
    var sourceSnapshotSeq: Int
    var sourceWorldRevision: Int
    var sourceSimTick: Int
    var rayOriginMM: [Double]
    var rayDirection: [Double]

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case sourceSnapshotSeq = "source_snapshot_seq"
        case sourceWorldRevision = "source_world_revision"
        case sourceSimTick = "source_sim_tick"
        case rayOriginMM = "ray_origin_mm"
        case rayDirection = "ray_direction"
    }
}

struct RayPickResult: Decodable, FlyGymStampedPacket {
    var type: String = "ray_pick_result"
    var protocolVersion: Int = 0
    var sessionID: String = ""
    var epoch: Int = 0
    var seq: Int = 0
    var simTick: Int = 0
    var revision: Int = 0
    var sourceSnapshotSeq: Int = 0
    var sourceWorldRevision: Int = 0
    var sourceSimTick: Int = 0
    var ok: Bool = false
    var hit: Bool = false
    var error: String?
    var targetID: String?
    var targetKind: String?
    var distanceMM: Double?
    var pointMM: [Double]?
    var normalWorld: [Double]?
    var geomID: Int?
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, epoch, seq, ok, hit, error
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case simTick = "sim_tick"
        case revision = "world_revision"
        case sourceSnapshotSeq = "source_snapshot_seq"
        case sourceWorldRevision = "source_world_revision"
        case sourceSimTick = "source_sim_tick"
        case targetID = "target_id"
        case targetKind = "target_kind"
        case distanceMM = "distance_mm"
        case pointMM = "point_mm"
        case normalWorld = "normal_world"
        case geomID = "geom_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        epoch = try c.decode(Int.self, forKey: .epoch)
        seq = try c.decode(Int.self, forKey: .seq)
        simTick = try c.decode(Int.self, forKey: .simTick)
        revision = try c.decode(Int.self, forKey: .revision)
        sourceSnapshotSeq = try c.decode(Int.self, forKey: .sourceSnapshotSeq)
        sourceWorldRevision = try c.decode(Int.self, forKey: .sourceWorldRevision)
        sourceSimTick = try c.decode(Int.self, forKey: .sourceSimTick)
        ok = try c.decode(Bool.self, forKey: .ok)
        hit = try c.decode(Bool.self, forKey: .hit)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        guard protocolVersion >= 0, sessionID.count <= 128, epoch >= 0, seq >= 0,
              simTick >= 0, revision >= 0, sourceSnapshotSeq > 0,
              sourceWorldRevision >= 0, sourceSimTick >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid pick result envelope"))
        }
        if !ok {
            guard !hit, let error, !error.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "failed pick requires error and hit=false"))
            }
            return
        }
        guard hit else { return }
        let id = try c.decode(String.self, forKey: .targetID).trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = try c.decode(String.self, forKey: .targetKind).trimmingCharacters(in: .whitespacesAndNewlines)
        let distance = try c.decode(Double.self, forKey: .distanceMM)
        let point = try WorldRenderDecode.finiteVector(
            c.decode([Double].self, forKey: .pointMM), count: 3, name: "point_mm")
        let normal = try WorldRenderDecode.finiteVector(
            c.decode([Double].self, forKey: .normalWorld), count: 3, name: "normal_world")
        let normalNorm = sqrt(normal.reduce(0) { $0 + $1 * $1 })
        let geom = try c.decode(Int.self, forKey: .geomID)
        guard !id.isEmpty, id.count <= 128, !kind.isEmpty, kind.count <= 32,
              distance.isFinite, distance >= 0, normalNorm >= 1e-12, geom >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid pick hit payload"))
        }
        targetID = id; targetKind = kind; distanceMM = distance; pointMM = point
        normalWorld = normal.map { $0 / normalNorm }; geomID = geom
    }
}

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

    static let csvHeader = "wall_time,sim_ms,pop_hz,loom_hz,dna_l_hz,dna_r_hz,mdn_hz,dnp09_hz,dng11_hz,escw_hz,loom_l,loom_r,air_puff,gait_drive,odor_drive_l,odor_drive_r,thermo_warm_drive,thermo_cool_drive,wind_c_drive,wind_e_drive,temp_c,body_vx,body_yaw_rate,body_contact_mean,body_loom_l,body_loom_r,brightness_l,brightness_r,occupancy_l,occupancy_r,optic_expansion_l,optic_expansion_r,flash_l,flash_r,odor_l,odor_r,nearest_food_mm,fly_state,body_sim_s,body_sim_dt,body_wall_dt,body_sim_wall_ratio,body_packet_age_s,body_generation,body_eye_sample_sim_tick,receptor_odor_l_hz,receptor_odor_r_hz,receptor_warm_hz,receptor_cool_hz,receptor_wind_c_hz,receptor_wind_e_hz,brain_signals_available,brain_walk,brain_turn,brain_escape,brain_backward,brain_groom,brain_wing,brain_arousal,brain_tempo,brain_sleep,brain_nervous,controller_left,controller_right,body_wind_strength,body_wind_direction_deg,body_wind_sensory,body_touch_strength,body_touch_sensory,session_id,session_epoch,session_sim_tick,session_mode,session_phase,session_paused,body_result_tick\n"

    var csvLine: String {
        let safeState = flyState.replacingOccurrences(of: ",", with: "_")
        let base = String(format: "%.6f,%d,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.3f,%.7f,%.7f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.3f,%@,%.6f,%.6f,%.6f,%.6f,%.6f,%llu",
                          wallTime, simMs, ratePop, rateLoom, rateDNaL, rateDNaR,
                          rateMDN, rateFwd, rateGroom, rateEscW, loomL, loomR,
                          airPuff, gaitDrive, odorDriveL, odorDriveR,
                          thermoWarmDrive, thermoCoolDrive, windCDrive, windEDrive,
                          temperatureC, bodyVX, bodyYawRate,
                          bodyContactMean, bodyLoomL, bodyLoomR,
                          bodyBrightnessL, bodyBrightnessR, bodyOccupancyL, bodyOccupancyR,
                          bodyOpticExpansionL, bodyOpticExpansionR, bodyFlashL, bodyFlashR,
                          bodyOdorL, bodyOdorR, bodyNearestFoodDistanceMm,
                          safeState, bodySimTime, bodySimDt, bodyWallDt, bodySimWallRatio,
                          bodyPacketAgeS, bodyConnectionGeneration)
        let eyeProvenance = ",\(bodyEyeSampleSimTick)"
        let diagnostic = String(format: ",%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%d,%.5f,%.5f,%d,%d,%.5f,%.5f,%.5f,%.5f,%d,%.5f,%.5f,%.5f,%.5f,%.5f,%d,%.5f,%d",
                                rateFoodOdorL, rateFoodOdorR, rateThermoWarm, rateThermoCool,
                                rateWindC, rateWindE, brainSignalsAvailable ? 1 : 0,
                                brainWalkDrive, brainTurnBias, brainEscape ? 1 : 0,
                                brainBackward ? 1 : 0, brainGroomDrive, brainWingDrive,
                                brainArousal, brainTempo, brainSleep ? 1 : 0, brainNervous,
                                bodyControllerLeft, bodyControllerRight,
                                bodyWindStrength, bodyWindDirectionDeg, bodyWindSensory ? 1 : 0,
                                bodyTouchStrength, bodyTouchSensory ? 1 : 0)
        let safeSession = sessionID.replacingOccurrences(of: ",", with: "_")
        let safeMode = sessionMode.replacingOccurrences(of: ",", with: "_")
        let safePhase = sessionPhase.replacingOccurrences(of: ",", with: "_")
        let session = ",\(safeSession),\(sessionEpoch),\(sessionSimTick),\(safeMode),\(safePhase),\(sessionPaused ? 1 : 0),\(bodyResultTick)\n"
        return base + eyeProvenance + diagnostic + session
    }
}

/// Single mapping table for direct-neural lab stimulation. These are existing
/// populations only; no synthetic neuron group is created for the lab UI.
func labPopulationIndices(_ sim: MetalSim, role: String) -> [Int] {
    switch role {
    case "GF": return sim.gf
    case "DNa-left": return sim.dnaL
    case "DNa-right": return sim.dnaR
    case "MDN": return sim.mdn
    case "DNp09": return sim.fwd
    case "DNg11": return sim.groom
    case "escW": return sim.escw
    case "LC4/LPLC2": return sim.loomLeft + sim.loomRight
    case "LC4/LPLC2-left": return sim.loomLeft
    case "LC4/LPLC2-right": return sim.loomRight
    case "ascend": return sim.ascend
    case "sens": return sim.sens
    case "ORN-food-left": return sim.foodOdorLeft
    case "ORN-food-right": return sim.foodOdorRight
    case "TRN-warm": return sim.thermoWarm
    case "TRN-cool": return sim.thermoCool
    case "JO-C-wind": return sim.windC
    case "JO-E-wind": return sim.windE
    case "HRN-dry": return sim.hygroDry
    case "HRN-moist": return sim.hygroMoist
    default: return []
    }
}
