// LabProtocol.swift — compact protocol and telemetry types for Virtual Fly Lab V2.
//
// Classification used by the UI is deliberately explicit:
//   physical       = a MuJoCo/FlyGym world mutation handled by the Python owner thread
//   sensory-model  = an engineered sensory/environment transform into existing inputs
//   direct-neural  = electrical stimulation of an existing MetalSim population

import Foundation

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
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case epoch
        case requestedTick = "requested_tick"
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

/// Python -> Swift lifecycle marker (approach/wind/touch/flash start/complete).
/// `data` is intentionally ignored here; the event name is sufficient for the
/// V1 status/recording UI and unknown payload fields remain forward-compatible.
struct LabEventNotice: Decodable, FlyGymStampedPacket {
    var type: String = "lab_event"
    var event: String = ""
    var receivedAt: Date = Date()
    var connectionGeneration: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case type, event
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

/// Headless lab protocol test. No socket is opened; queue behavior, tolerant
/// state parsing and direct-neural population selection are exercised directly.
func runLabTest() {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }

    let bridge = FlyGymBridge()
    for i in 0..<100 {
        _ = bridge.sendLab(action: "move_object", target: "box", x: Double(i), y: 0, z: 5)
    }
    check("lab command queue bounded", bridge.pendingLabDepth() == 32,
          "depth=\(bridge.pendingLabDepth()) dropped=\(bridge.labDropped)")
    check("lab queue drops oldest", bridge.labDropped == 68, "dropped=\(bridge.labDropped)")

    let stateLine = #"{"type":"lab_state","t":1.25,"ack":7,"ok":false,"error":"bad target","object_count":1,"state":{"objects":[{"id":"wall_1","shape":"wall","position_mm":[12.0,-3.0,7.5],"size_mm":[2.0,30.0,15.0],"yaw_deg":15.0}],"slot_capacity":{"box":64,"sphere":64,"wall":64,"food":32},"slot_free":{"box":64,"sphere":64,"wall":63,"food":32}},"temperature":27.0,"wind":0.4,"left_eye_covered":true,"right_eye_covered":false}"#
    let state = parseLabStateLine(Data(stateLine.utf8))
    let wallState = state?.authoritativeObjects?.first
    check("lab_state parse", state?.ack == 7 && state?.ok == false && state?.error == "bad target"
          && state?.objectCount == 1 && state?.leftEyeCovered == true && state?.rightEyeCovered == false
          && wallState?.id == "wall_1" && wallState?.shape == "wall"
          && wallState?.positionMM == [12.0, -3.0, 7.5]
          && wallState?.sizeMM == [2.0, 30.0, 15.0]
          && abs((wallState?.yawDeg ?? -999) - 15.0) < 1e-9
          && state?.authoritativeSlotCapacity?["wall"] == 64
          && state?.authoritativeSlotFree?["wall"] == 63)
    check("lab_state type gate", parseLabStateLine(Data(#"{"type":"body","ack":7}"#.utf8)) == nil)
    let event = parseLabEventLine(Data(#"{"type":"lab_event","event":"approach_complete","data":{"id":"x"}}"#.utf8))
    check("lab_event parse", event?.event == "approach_complete")

    var backendStim = FlyGymBodyFeedback()
    backendStim.windStrength = 0.7
    backendStim.windDirectionDeg = -30
    backendStim.windSensory = true
    backendStim.touchStrength = 0.55
    backendStim.touchSensory = true
    let activeBackend = SensoryModel.backendState(backendStim)
    backendStim.windSensory = false
    backendStim.touchSensory = false
    let disabledBackend = SensoryModel.backendState(backendStim)
    let missingBackend = SensoryModel.backendState(nil)
    check("backend body state is authoritative for wind/touch neural source",
          abs(activeBackend.wind - 0.7) < 1e-6
          && abs(activeBackend.windDirectionDeg + 30) < 1e-9
          && abs(activeBackend.touchDrive - 0.119) < 1e-6
          && disabledBackend.wind == 0 && disabledBackend.touchDrive == 0
          && missingBackend.wind == 0 && missingBackend.touchDrive == 0)

    // V3 module extraction parity. These local equations are the frozen V2
    // pre-extraction formulas, not calls back into SensoryModel. Any future
    // model change must therefore be deliberate rather than hidden in a refactor.
    func legacyOdor(_ x: Float, _ gate: Float) -> Float {
        let bounded = min(1, max(0, x))
        return 0.060 * sqrt(sqrt(bounded)) * gate
    }
    func legacyThermal(_ celsius: Double, _ enabled: Bool, _ gate: Float) -> (Float, Float) {
        guard enabled else { return (0, 0) }
        let warm = Float(max(0, min(1, (celsius - 25) / 10)))
        let cool = Float(max(0, min(1, (25 - celsius) / 10)))
        return (warm * 0.060 * gate, cool * 0.060 * gate)
    }
    func legacyWind(_ strength: Float, _ direction: Double, _ heading: Double,
                    _ gate: Float) -> (Float, Float) {
        guard strength > 0 else { return (0, 0) }
        let opponent = Float(cos(direction * .pi / 180 - heading))
        return (strength * (0.5 + 0.5 * opponent) * 0.055 * gate,
                strength * (0.5 - 0.5 * opponent) * 0.055 * gate)
    }
    var sensoryParity = true
    for gate: Float in [0.0, 0.55, 1.0] {
        for x: Float in [-0.2, 0, 0.0732, 0.5, 1, 1.4] {
            sensoryParity = sensoryParity
                && SensoryModel.odorCurrent(x, sensoryGate: gate) == legacyOdor(x, gate)
        }
        for temp in [10.0, 20.0, 25.0, 32.0, 40.0] {
            for enabled in [false, true] {
                let got = SensoryModel.thermal(celsius: temp, enabled: enabled, sensoryGate: gate)
                let old = legacyThermal(temp, enabled, gate)
                sensoryParity = sensoryParity && got.warm == old.0 && got.cool == old.1
            }
        }
        for (strength, direction, heading): (Float, Double, Double) in [
            (0, 0, 0), (0.2, 90, 0), (0.7, -30, 0.3), (1, 360, -.pi / 2)
        ] {
            let got = SensoryModel.wind(strength: strength, directionDeg: direction,
                                        bodyHeading: heading, sensoryGate: gate)
            let old = legacyWind(strength, direction, heading, gate)
            sensoryParity = sensoryParity && got.c == old.0 && got.e == old.1
        }
        for source: Float in [0, 0.02, 0.119, 0.2] {
            sensoryParity = sensoryParity
                && SensoryModel.touch(sourceDrive: source, sensoryGate: gate) == source * gate
        }
    }
    let tempoParity = [10.0, 20.0, 25.0, 32.0, 40.0].allSatisfy { temp in
        let old = clampf(CGFloat(1 + (min(40, max(10, temp)) - 25) * 0.03), 0.55, 1.45)
        return SensoryModel.locomotorTempo(celsius: temp) == old
    }
    check("V3 SensoryModel preserves V2 source→drive equations", sensoryParity && tempoParity)

    // SignalBuilder was also moved out of main.swift. Compare its stateful DNa
    // adaptation and all command channels against the exact frozen V2 equations.
    let motorBuilder = SignalBuilder()
    var legacyDNaBaseline: Float = 0
    var motorParity = true
    let motorInputs = [
        MotorReadoutInput(giantFiberSpiked: false, rateLoom: 0, rateDNaL: 45, rateDNaR: 38,
                          rateMDN: 20, rateFwd: 8, rateGroom: 1, rateEscW: 0, ratePop: 1.8),
        MotorReadoutInput(giantFiberSpiked: true, rateLoom: 80, rateDNaL: 70, rateDNaR: 20,
                          rateMDN: 90, rateFwd: 43, rateGroom: 12, rateEscW: 15, ratePop: 7),
        MotorReadoutInput(giantFiberSpiked: false, rateLoom: 12, rateDNaL: 25, rateDNaR: 60,
                          rateMDN: 59.9, rateFwd: 20, rateGroom: 3, rateEscW: 4, ratePop: 3),
    ]
    let motorDt: CGFloat = 1.0 / 60.0
    for input in motorInputs {
        let diff = input.rateDNaL - input.rateDNaR
        legacyDNaBaseline += (diff - legacyDNaBaseline) * Float(min(1, motorDt / 8))
        var old = BrainSignals()
        old.escape = input.giantFiberSpiked
        old.nervous = clampf(CGFloat(input.rateLoom) / 115, 0, 1)
        old.turnBias = clampf(CGFloat(diff - legacyDNaBaseline) * 0.04, -1, 1)
        old.backward = input.rateMDN > 60
        old.walkDrive = clampf((CGFloat(input.rateFwd) - 10) / 33, 0, 1.3)
        old.groomDrive = clampf(CGFloat(input.rateGroom) / 5, 0, 1.5)
        old.wingDrive = clampf(CGFloat(input.rateEscW) / 10, 0, 1.3)
        old.arousal = clampf(CGFloat(input.ratePop) / 10, 0, 1)
        let got = motorBuilder.make(input, dt: motorDt)
        motorParity = motorParity
            && got.escape == old.escape && got.nervous == old.nervous
            && got.turnBias == old.turnBias && got.backward == old.backward
            && got.walkDrive == old.walkDrive && got.groomDrive == old.groomDrive
            && got.wingDrive == old.wingDrive && got.arousal == old.arousal
    }
    motorBuilder.reset(); legacyDNaBaseline = 0
    let resetInput = motorInputs[1]
    let resetDiff = resetInput.rateDNaL - resetInput.rateDNaR
    legacyDNaBaseline += (resetDiff - legacyDNaBaseline) * Float(min(1, motorDt / 8))
    let resetExpectedTurn = clampf(CGFloat(resetDiff - legacyDNaBaseline) * 0.04, -1, 1)
    motorParity = motorParity && motorBuilder.make(resetInput, dt: motorDt).turnBias == resetExpectedTurn
    check("V3 MotorReadout preserves V2 rate→command sequence/reset", motorParity)

    var decodedSignals = BrainSignals()
    decodedSignals.walkDrive = 0.42
    decodedSignals.turnBias = -0.17
    decodedSignals.escape = true
    decodedSignals.backward = true
    decodedSignals.groomDrive = 0.23
    decodedSignals.wingDrive = 0.31
    decodedSignals.arousal = 0.44
    decodedSignals.tempo = 1.25
    decodedSignals.sleep = true
    decodedSignals.nervous = 0.66
    var decodedTelemetry = LabTelemetry()
    decodedTelemetry.applyBrainSignals(decodedSignals)
    check("decoded BrainSignals reach telemetry",
          decodedTelemetry.brainSignalsAvailable
          && abs(decodedTelemetry.brainWalkDrive - 0.42) < 1e-9
          && abs(decodedTelemetry.brainTurnBias + 0.17) < 1e-9
          && decodedTelemetry.brainEscape && decodedTelemetry.brainBackward
          && abs(decodedTelemetry.brainGroomDrive - 0.23) < 1e-9
          && abs(decodedTelemetry.brainWingDrive - 0.31) < 1e-9
          && abs(decodedTelemetry.brainArousal - 0.44) < 1e-9
          && abs(decodedTelemetry.brainTempo - 1.25) < 1e-9
          && decodedTelemetry.brainSleep
          && abs(decodedTelemetry.brainNervous - 0.66) < 1e-9)
    decodedTelemetry.applyBrainSignals(nil)
    check("missing BrainSignals clear telemetry",
          !decodedTelemetry.brainSignalsAvailable
          && decodedTelemetry.brainWalkDrive == 0 && decodedTelemetry.brainTurnBias == 0
          && !decodedTelemetry.brainEscape && !decodedTelemetry.brainBackward
          && decodedTelemetry.brainTempo == 1 && !decodedTelemetry.brainSleep)

    let telemetryBodyLine = #"{"type":"body","t":2.5,"sim_dt":0.003,"wall_dt":0.030,"sim_wall_ratio":0.1,"controller_left":0.22,"controller_right":0.44,"wind_strength":0.7,"wind_direction_deg":45,"wind_sensory":true,"touch_strength":0.55,"touch_sensory":true,"vx":0.004,"yaw_rate":0.2,"contacts":[1,1,1,1,1,1],"eye_sample_sim_tick":2300,"odor_left":0.3,"odor_right":0.4}"#
    if let bodyPacket = parseBodyLine(Data(telemetryBodyLine.utf8)) {
        let now = Date()
        var feedback = FlyGymBodyFeedback(bodyPacket)
        feedback.receivedAt = now.addingTimeInterval(-0.125)
        feedback.connectionGeneration = 9
        var bodyTelemetry = LabTelemetry()
        bodyTelemetry.applyBodyFeedback(feedback, now: now)
        check("body timing reaches lab telemetry",
              abs(bodyTelemetry.bodySimTime - 2.5) < 1e-9
              && abs(bodyTelemetry.bodySimDt - 0.003) < 1e-9
              && abs(bodyTelemetry.bodyWallDt - 0.030) < 1e-9
              && abs(bodyTelemetry.bodySimWallRatio - 0.1) < 1e-9
              && abs(bodyTelemetry.bodyControllerLeft - 0.22) < 1e-9
              && abs(bodyTelemetry.bodyControllerRight - 0.44) < 1e-9
              && abs(bodyTelemetry.bodyWindStrength - 0.7) < 1e-9
              && abs(bodyTelemetry.bodyWindDirectionDeg - 45) < 1e-9
              && bodyTelemetry.bodyWindSensory
              && abs(bodyTelemetry.bodyTouchStrength - 0.55) < 1e-9
              && bodyTelemetry.bodyTouchSensory
              && bodyTelemetry.bodyEyeSampleSimTick == 2300
              && abs(bodyTelemetry.bodyPacketAgeS - 0.125) < 1e-6
              && bodyTelemetry.bodyConnectionGeneration == 9)
        check("body timing columns recorded",
              LabTelemetry.csvHeader.contains("body_sim_s")
              && LabTelemetry.csvHeader.contains("body_sim_dt")
              && LabTelemetry.csvHeader.contains("body_sim_wall_ratio")
              && LabTelemetry.csvHeader.contains("controller_left")
              && LabTelemetry.csvHeader.contains("controller_right")
              && LabTelemetry.csvHeader.contains("body_wind_strength")
              && LabTelemetry.csvHeader.contains("body_touch_strength")
              && LabTelemetry.csvHeader.contains("body_generation,body_eye_sample_sim_tick,receptor_odor_l_hz")
              && bodyTelemetry.csvLine.contains(",9,2300,")
              && bodyTelemetry.csvLine.contains(",2.500000,0.003000,0.030000,0.100000,"))
    } else {
        check("body timing reaches lab telemetry", false, "body packet did not parse")
    }

    if let c = loadConnectome(), let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) {
        sim.perfLogIntervalMs = 0
        let roles = ["GF", "DNa-left", "DNa-right", "MDN", "DNp09", "DNg11", "escW",
                     "LC4/LPLC2-left", "LC4/LPLC2-right", "LC4/LPLC2", "ascend", "sens",
                     "ORN-food-left", "ORN-food-right", "TRN-warm", "TRN-cool",
                     "JO-C-wind", "JO-E-wind", "HRN-dry", "HRN-moist"]
        check("direct-neural roles map to existing neurons",
              roles.allSatisfy { !labPopulationIndices(sim, role: $0).isEmpty })
        check("FlyWire sensory group counts",
              sim.foodOdorLeft.count == 69 && sim.foodOdorRight.count == 66
              && sim.thermoWarm.count == 7 && sim.thermoCool.count == 9
              && sim.windC.count == 56 && sim.windE.count == 363,
              "odor=\(sim.foodOdorLeft.count)/\(sim.foodOdorRight.count) thermo=\(sim.thermoWarm.count)/\(sim.thermoCool.count) wind=\(sim.windC.count)/\(sim.windE.count)")
        sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: 0.05)
        let odorCurrent = sim.debugExternalInput(sim.foodOdorLeft)
        check("persistent sensory current reaches ORN group",
              odorCurrent.count == sim.foodOdorLeft.count
              && odorCurrent.allSatisfy { abs($0 - 0.05) < 1e-6 })
        sim.clearModeledSensoryDrives()
        check("modeled sensory clear zeros ORN current",
              sim.debugExternalInput(sim.foodOdorLeft).allSatisfy { abs($0) < 1e-8 })
        sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: 0.05)
        sim.reset(seed: SIM_SEED)
        check("brain reset clears persistent sensory current",
              sim.debugExternalInput(sim.foodOdorLeft).allSatisfy { abs($0) < 1e-8 })

        // Gain sanity: a modeled odor current should make its receptor group
        // more active than the same seeded baseline. This deliberately tests a
        // receptor response only, never a scripted downstream behavior.
        let odorSet = Set(sim.foodOdorLeft)
        func odorSpikes(_ drive: Float) -> Int {
            sim.reset(seed: SIM_SEED)
            sim.perfLogIntervalMs = 0
            sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: drive)
            var count = 0
            for _ in 0..<150 {
                sim.step(1)
                count += sim.lastStepSpikes().reduce(0) { $0 + (odorSet.contains(Int($1)) ? 1 : 0) }
            }
            return count
        }
        let odorBaselineSpikes = odorSpikes(0)
        let odorDrivenSpikes = odorSpikes(0.060)
        check("modeled odor raises ORN receptor spiking",
              odorDrivenSpikes > odorBaselineSpikes,
              "baseline=\(odorBaselineSpikes) driven=\(odorDrivenSpikes)")

        // End-to-end calibration for the shipped UI defaults. A 5 mm food
        // marker at (60, 0, 5) mm relative to a nominal thorax at z=0.7 mm
        // produces the same isotropic LabWorld concentration used by Python;
        // frontal bearing splits it equally across the two antenna channels.
        // The Coordinator's bounded compressive transduction must make that
        // ordinary placement measurable without raising the 0.060 max current.
        let defaultCenterDistance = sqrt(60.0 * 60.0 + 4.3 * 4.3)
        let defaultSurfaceDistance = max(0.0, defaultCenterDistance - 2.5)
        let defaultConcentration = exp(-defaultSurfaceDistance / 30.0)
        let defaultOdorLeft = Float(0.5 * defaultConcentration)
        let defaultFoodDrive: Float = 0.060 * sqrt(sqrt(defaultOdorLeft))
        let defaultFoodSpikes = odorSpikes(defaultFoodDrive)
        check("default UI food geometry raises ORN receptor spiking",
              defaultFoodDrive > 0 && defaultFoodDrive <= 0.060
              && defaultFoodSpikes > odorBaselineSpikes,
              String(format: "odor=%.4f current=%.4f baseline=%d driven=%d",
                     defaultOdorLeft, defaultFoodDrive, odorBaselineSpikes, defaultFoodSpikes))

        func receptorSpikes(_ indices: [Int], channel: MetalSim.ModeledSensoryChannel,
                            drive: Float) -> Int {
            let set = Set(indices)
            sim.reset(seed: SIM_SEED)
            sim.perfLogIntervalMs = 0
            sim.setModeledSensoryDrive(channel, indices: indices, strength: drive)
            var count = 0
            for _ in 0..<150 {
                sim.step(1)
                count += sim.lastStepSpikes().reduce(0) { $0 + (set.contains(Int($1)) ? 1 : 0) }
            }
            return count
        }
        func receptorCheck(_ name: String, indices: [Int],
                           channel: MetalSim.ModeledSensoryChannel, drive: Float) {
            let baseline = receptorSpikes(indices, channel: channel, drive: 0)
            let driven = receptorSpikes(indices, channel: channel, drive: drive)
            check(name, driven > baseline,
                  "baseline=\(baseline) driven=\(driven) current=\(drive)")
        }
        receptorCheck("warm TRN modeled drive raises receptor spiking",
                      indices: sim.thermoWarm, channel: .thermoWarm, drive: 0.060)
        receptorCheck("cool TRN modeled drive raises receptor spiking",
                      indices: sim.thermoCool, channel: .thermoCool, drive: 0.060)
        receptorCheck("JO-C wind modeled drive raises receptor spiking",
                      indices: sim.windC, channel: .windC, drive: 0.055)
        receptorCheck("JO-E wind modeled drive raises receptor spiking",
                      indices: sim.windE, channel: .windE, drive: 0.055)
        var receptorTelemetry = LabTelemetry()
        receptorTelemetry.applyReceptorRates(sim)
        check("receptor EMA rates reach telemetry",
              abs(receptorTelemetry.rateFoodOdorL - Double(sim.rateFoodOdorL)) < 1e-9
              && abs(receptorTelemetry.rateFoodOdorR - Double(sim.rateFoodOdorR)) < 1e-9
              && abs(receptorTelemetry.rateThermoWarm - Double(sim.rateThermoWarm)) < 1e-9
              && abs(receptorTelemetry.rateThermoCool - Double(sim.rateThermoCool)) < 1e-9
              && abs(receptorTelemetry.rateWindC - Double(sim.rateWindC)) < 1e-9
              && abs(receptorTelemetry.rateWindE - Double(sim.rateWindE)) < 1e-9
              && receptorTelemetry.rateWindE > 0,
              String(format: "ORN L/R %.1f/%.1f Hz · JO-E %.1f Hz",
                     receptorTelemetry.rateFoodOdorL, receptorTelemetry.rateFoodOdorR,
                     receptorTelemetry.rateWindE))
        sim.reset(seed: SIM_SEED)
        check("unknown neural role rejected", labPopulationIndices(sim, role: "invented").isEmpty)

        // Same-seed downstream parity: feed one sim through the extracted model
        // and another through the frozen V2 equations, then require identical
        // neural state/spikes. This catches an arithmetic-order change that a
        // source-only comparison could otherwise miss.
        if let legacySim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) {
            legacySim.perfLogIntervalMs = 0
            sim.reset(seed: SIM_SEED); legacySim.reset(seed: SIM_SEED)
            let sequence: [(Float, Double, Bool, Float, Double, Double, Float)] = [
                (0.0732, 32, true, 0.7, 90, 0.2, 0.55),
                (0.4, 20, true, 0.2, -30, -0.4, 1.0),
                (0.0, 25, false, 0.0, 0, 0, 1.0),
            ]
            var neuralParity = true
            var neuralParityDetail = ""
            for (odor, temp, thermoOn, wind, windDeg, heading, gate) in sequence {
                let newThermal = SensoryModel.thermal(celsius: temp, enabled: thermoOn, sensoryGate: gate)
                let oldThermal = legacyThermal(temp, thermoOn, gate)
                let newWind = SensoryModel.wind(strength: wind, directionDeg: windDeg,
                                                bodyHeading: heading, sensoryGate: gate)
                let oldWind = legacyWind(wind, windDeg, heading, gate)
                let newOdor = SensoryModel.odorCurrent(odor, sensoryGate: gate)
                let oldOdor = legacyOdor(odor, gate)
                sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: newOdor)
                sim.setModeledSensoryDrive(.thermoWarm, indices: sim.thermoWarm, strength: newThermal.warm)
                sim.setModeledSensoryDrive(.thermoCool, indices: sim.thermoCool, strength: newThermal.cool)
                sim.setModeledSensoryDrive(.windC, indices: sim.windC, strength: newWind.c)
                sim.setModeledSensoryDrive(.windE, indices: sim.windE, strength: newWind.e)
                legacySim.setModeledSensoryDrive(.foodOdorLeft, indices: legacySim.foodOdorLeft, strength: oldOdor)
                legacySim.setModeledSensoryDrive(.thermoWarm, indices: legacySim.thermoWarm, strength: oldThermal.0)
                legacySim.setModeledSensoryDrive(.thermoCool, indices: legacySim.thermoCool, strength: oldThermal.1)
                legacySim.setModeledSensoryDrive(.windC, indices: legacySim.windC, strength: oldWind.0)
                legacySim.setModeledSensoryDrive(.windE, indices: legacySim.windE, strength: oldWind.1)
                sim.step(40); legacySim.step(40)
                let vA = sim.membrane(), vB = legacySim.membrane()
                let rA = sim.debugRefr(), rB = legacySim.debugRefr()
                // GPU atomics do not promise append order; compare the spike set,
                // exactly as GPUCheck does, while membrane/refractory remain exact.
                let sA = sim.lastStepSpikes().sorted(), sB = legacySim.lastStepSpikes().sorted()
                let gA = sim.lastStepGroupCounts(), gB = legacySim.lastStepGroupCounts()
                let same = vA == vB && rA == rB && sA == sB && gA == gB
                if !same && neuralParityDetail.isEmpty {
                    let firstV = zip(vA, vB).enumerated().first { $0.element.0 != $0.element.1 }
                    neuralParityDetail = "simMs=\(sim.simMs) v=\(firstV?.offset ?? -1) refr=\(rA == rB) spikes=\(sA.count)/\(sB.count) groups=\(gA == gB)"
                }
                neuralParity = neuralParity && same
            }
            check("V3 extraction preserves same-seed downstream neural state", neuralParity,
                  neuralParityDetail)
        } else {
            check("V3 extraction preserves same-seed downstream neural state", false,
                  "could not initialize legacy parity sim")
        }
    } else {
        check("direct-neural role mapping", false, "could not initialize MetalSim")
    }

    // Recording is part of the user-facing lab contract. Exercise the serialized
    // lifecycle in a temporary directory so queued tail data cannot be reported
    // as saved before write/flush/close actually finish.
    let fm = FileManager.default
    let recorderRoot = fm.temporaryDirectory
        .appendingPathComponent("siliconfly-recorder-test-\(UUID().uuidString)", isDirectory: true)
    let recorder = ExperimentRecorder(baseDirectory: recorderRoot)
    if let recordingPath = recorder.start() {
        var sample = LabTelemetry()
        sample.simMs = 42
        sample.odorDriveL = 0.04
        sample.bodyOdorL = 0.7
        sample.bodyNearestFoodDistanceMm = 11.5
        sample.rateFoodOdorL = 23.5
        sample.brainSignalsAvailable = true
        sample.brainWalkDrive = 0.42
        sample.brainTurnBias = -0.17
        sample.flyState = "walking"
        recorder.append(sample)
        recorder.mark(kind: "lab_test_marker", detail: "flush")
        var tail = sample
        tail.simMs = 4242
        recorder.append(tail)

        let stopDone = DispatchSemaphore(value: 0)
        var stopOutcome: ExperimentRecorderStopOutcome?
        recorder.stop { outcome in
            stopOutcome = outcome
            stopDone.signal()
        }
        let completed = stopDone.wait(timeout: .now() + 3) == .success
        recorder.flushForTesting()

        let metadata = (try? String(contentsOfFile: recordingPath + "/metadata.json", encoding: .utf8)) ?? ""
        let telemetry = (try? String(contentsOfFile: recordingPath + "/telemetry.csv", encoding: .utf8)) ?? ""
        let events = (try? String(contentsOfFile: recordingPath + "/events.jsonl", encoding: .utf8)) ?? ""
        check("recorder writes V4 metadata", metadata.contains("Thongpari Fly Neuron Sim Virtual Fly Lab V4"))
        check("recorder stop completes only after saved state",
              completed && stopOutcome?.succeeded == true && recorder.state == .saved,
              "completed=\(completed) state=\(recorder.state.rawValue)")
        check("recorder flushes queued telemetry tail on stop",
              telemetry.contains("odor_drive_l") && telemetry.contains("nearest_food_mm")
              && telemetry.contains("receptor_odor_l_hz")
              && telemetry.contains("brain_signals_available")
              && telemetry.contains("brain_walk")
              && telemetry.contains(",42,") && telemetry.contains(",4242,"))
        check("recorder preserves start/marker/stop events",
              events.contains("recording_started") && events.contains("lab_test_marker")
              && events.contains("recording_stopped"))

        // A rapid stop→start must never reuse/open a second session while the old
        // file handles are still in `stopping`. Once completion lands, restarting
        // is allowed and produces a distinct directory.
        if let secondPath = recorder.start() {
            var secondTail = sample
            secondTail.simMs = 5151
            recorder.append(secondTail)
            let rapidDone = DispatchSemaphore(value: 0)
            recorder.stop { _ in rapidDone.signal() }
            let immediateRestart = recorder.start()
            let rapidStopped = rapidDone.wait(timeout: .now() + 3) == .success
            let restartAfterStop = immediateRestart ?? recorder.start()
            check("rapid stop→start never overlaps recorder sessions",
                  rapidStopped && restartAfterStop != nil && restartAfterStop != secondPath,
                  "immediate=\(immediateRestart ?? "nil") after=\(restartAfterStop ?? "nil")")
            if recorder.isRecording {
                let cleanup = DispatchSemaphore(value: 0)
                recorder.stop { _ in cleanup.signal() }
                _ = cleanup.wait(timeout: .now() + 3)
            }
        } else {
            check("recorder restarts after saved stop", false)
        }
    } else {
        check("recorder starts in temporary directory", false)
    }

    // Deterministic write-failure seam: queued append/final-event errors must
    // surface as `failed`, never as a false saved result.
    let failingRoot = recorderRoot.appendingPathComponent("forced-failure", isDirectory: true)
    let failingRecorder = ExperimentRecorder(baseDirectory: failingRoot, forceWriteFailureForTesting: true)
    if failingRecorder.start() != nil {
        var failingSample = LabTelemetry()
        failingSample.simMs = 7
        failingRecorder.append(failingSample)
        let failureDone = DispatchSemaphore(value: 0)
        var failureOutcome: ExperimentRecorderStopOutcome?
        failingRecorder.stop { outcome in
            failureOutcome = outcome
            failureDone.signal()
        }
        let failureCompleted = failureDone.wait(timeout: .now() + 3) == .success
        let failed: Bool
        if case .failed = failureOutcome { failed = true } else { failed = false }
        check("recorder write failure propagates as failed",
              failureCompleted && failed && failingRecorder.state == .failed
              && failingRecorder.lastErrorMessage != nil,
              failingRecorder.lastErrorMessage ?? "no error")
        if let failureOutcome {
            let policy = applicationQuitAfterRecorderDrain(failureOutcome)
            let requiresConfirmation: Bool
            if case .requireFailureConfirmation = policy { requiresConfirmation = true }
            else { requiresConfirmation = false }
            check("AppKit quit policy blocks automatic termination after save failure",
                  !failureOutcome.succeeded && requiresConfirmation)

            var keepOpenReply: Bool?
            resolveApplicationQuitAfterRecorderDrain(
                failureOutcome,
                confirmFailure: { _, _, decision in decision(false) },
                reply: { keepOpenReply = $0 }
            )
            var explicitQuitReply: Bool?
            resolveApplicationQuitAfterRecorderDrain(
                failureOutcome,
                confirmFailure: { _, _, decision in decision(true) },
                reply: { explicitQuitReply = $0 }
            )
            check("AppKit quit failure requires explicit user override",
                  keepOpenReply == false && explicitQuitReply == true)
        } else {
            check("AppKit quit policy blocks automatic termination after save failure", false,
                  "missing failure outcome")
            check("AppKit quit failure requires explicit user override", false,
                  "missing failure outcome")
        }
    } else {
        check("forced-failure recorder starts before injected write", false)
    }

    // App quit uses the same completion contract; exercise its terminal reason
    // and queued tail independently from AppKit UI event delivery.
    let quitRoot = recorderRoot.appendingPathComponent("quit-drain", isDirectory: true)
    let quitRecorder = ExperimentRecorder(baseDirectory: quitRoot)
    if let quitPath = quitRecorder.start() {
        var quitTail = LabTelemetry()
        quitTail.simMs = 9001
        quitRecorder.append(quitTail)
        let quitDone = DispatchSemaphore(value: 0)
        quitRecorder.stop(reason: "application quit") { _ in quitDone.signal() }
        let quitCompleted = quitDone.wait(timeout: .now() + 3) == .success
        let quitTelemetry = (try? String(contentsOfFile: quitPath + "/telemetry.csv", encoding: .utf8)) ?? ""
        let quitEvents = (try? String(contentsOfFile: quitPath + "/events.jsonl", encoding: .utf8)) ?? ""
        check("application-quit recorder drain keeps tail",
              quitCompleted && quitRecorder.state == .saved && quitTelemetry.contains(",9001,")
              && quitEvents.contains("application quit"))
        let savedOutcome = ExperimentRecorderStopOutcome.saved(path: quitPath)
        check("AppKit quit policy terminates only after successful recorder drain",
              applicationQuitAfterRecorderDrain(savedOutcome) == .terminate)
        var savedReply: Bool?
        var unexpectedPrompt = false
        resolveApplicationQuitAfterRecorderDrain(
            savedOutcome,
            confirmFailure: { _, _, _ in unexpectedPrompt = true },
            reply: { savedReply = $0 }
        )
        check("AppKit quit success replies terminate without failure prompt",
              savedReply == true && !unexpectedPrompt)
    } else {
        check("application-quit recorder starts", false)
    }
    try? fm.removeItem(at: recorderRoot)

    // V5.5.1 one-window state: every ACK reaches the timeline exactly once.
    let ackBridge = FlyGymBridge()
    let ackGeneration = ackBridge.beginConnectionForTesting()
    for line in [#"{"type":"lab_ack","id":1,"ok":true,"action":"spawn_box","message":"ok","applied_tick":20}"#,
                 #"{"type":"lab_ack","id":2,"ok":false,"action":"move_object","message":"unknown target"}"#,
                 #"{"type":"lab_state","t":0.1,"ack":2,"ok":false,"error":"unknown target"}"#,
                 #"{"type":"lab_state","t":0.2,"ack":2,"ok":false,"error":"unknown target"}"#] {
        _ = ackBridge.receiveLineForTesting(Data(line.utf8))
    }
    let firstRead = ackBridge.labAcks(after: 0)
    let secondRead = ackBridge.labAcks(after: firstRead.serial)
    check("bridge keeps every ACK between UI refreshes, repeated lab_state ACK once",
          firstRead.acks.map(\.id) == [1, 2] && secondRead.acks.isEmpty,
          "ids=\(firstRead.acks.map(\.id))")

    let t0 = Date()
    func entry(_ id: Int, generation: UInt64 = ackGeneration, at: Date = t0) -> LabTimelineEntry {
        LabTimelineEntry(commandID: id, action: "spawn_box", detail: "box_\(id)", kind: .physical,
                         sessionID: "s", epoch: 1, requestedTick: 10 * id, requestedAt: at,
                         connectionGeneration: generation, status: .requested)
    }
    var timeline = LabCommandTimeline()
    timeline.append(entry(1)); timeline.append(entry(2)); timeline.append(entry(3))
    timeline.append(entry(4, generation: ackGeneration &- 1))
    let resolved = firstRead.acks.map { timeline.apply(ack: $0) }
    let duplicate = timeline.apply(ack: firstRead.acks[0])
    timeline.expire(now: t0.addingTimeInterval(LabCommandTimeline.ackTimeout + 1),
                    connectionGeneration: ackGeneration)
    let statuses = timeline.entries.map(\.status)
    check("timeline resolves applied/rejected once, then times out and loses stale rows",
          resolved == [true, true] && !duplicate
          && statuses == [.applied, .rejected, .timedOut, .lost]
          && timeline.entries[0].appliedTick == 20 && timeline.pendingCount == 0,
          "\(statuses)")
    var late = LabAck(); late.id = 3; late.ok = true; late.appliedTick = 90
    late.connectionGeneration = ackGeneration
    check("late ACK still resolves a timed-out row with the real applied tick",
          timeline.apply(ack: late) && timeline.entries[2].status == .applied
          && timeline.entries[2].appliedTick == 90)

    let serviceDown = WorkspaceSnapshot.connection(bridgeEnabled: true, service: .exited(1),
                                                  connected: true, bodyFresh: true, bodyAge: 0)
    let stale = WorkspaceSnapshot.connection(bridgeEnabled: true, service: .running,
                                            connected: true, bodyFresh: false, bodyAge: 2.5)
    let live = WorkspaceSnapshot.connection(bridgeEnabled: true, service: nil,
                                           connected: true, bodyFresh: true, bodyAge: 0.01)
    let waiting = WorkspaceSnapshot.connection(bridgeEnabled: true, service: .starting,
                                              connected: false, bodyFresh: false, bodyAge: nil)
    check("workspace connection never reports live for a dead backend or stale body",
          serviceDown == .backendDown("exited with status 1") && stale == .stale(2.5)
          && live == .live && waiting == .connecting
          && WorkspaceSnapshot.connection(bridgeEnabled: false, service: nil, connected: false,
                                          bodyFresh: false, bodyAge: nil) == .disabled)
    check("recording line never implies a save that has not completed",
          WorkspaceRecording.stopping(path: "/r").line.hasPrefix("Saving")
          && WorkspaceRecording.idle.line == "Not recording"
          && WorkspaceRecording.recording(path: "/r", elapsed: 75).line.contains("01:15")
          && WorkspaceRecording.failed(path: "/r", message: "disk full").line.contains("disk full"))

    // App-owned backend lifecycle against a stand-in "python" (/bin/sh) that
    // just sleeps: start → stop leaves no child, and only then offers restart.
    let fakeRoot = fm.temporaryDirectory.appendingPathComponent("thongpari-service-\(UUID().uuidString)")
    try? fm.createDirectory(at: fakeRoot.appendingPathComponent("flygym_bridge"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: fakeRoot.appendingPathComponent("flygym-venv/bin"), withIntermediateDirectories: true)
    try? "exec sleep 30\n".write(to: fakeRoot.appendingPathComponent("flygym_bridge/bridge.py"),
                                 atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(atPath: fakeRoot.appendingPathComponent("flygym-venv/bin/python").path,
                               withDestinationPath: "/bin/sh")
    let service = FlyGymService(mode: .mock, root: fakeRoot)
    service.start()
    let startedRunning = service.state == .running && !service.canRestart && service.port != 0
    service.stop()
    let deadline = Date().addingTimeInterval(2)
    while service.state == .running && Date() < deadline { usleep(10_000) }
    if case .exited = service.state {
        check("app-owned backend stops cleanly and becomes restartable",
              startedRunning && service.canRestart)
    } else {
        check("app-owned backend stops cleanly and becomes restartable", false, "\(service.state)")
    }
    check("backend without a checkout reports unavailable, never restartable",
          { if case .unavailable = FlyGymService(mode: .mock, root: nil).state { return true }; return false }()
          && !FlyGymService(mode: .mock, root: nil).canRestart)
    try? fm.removeItem(at: fakeRoot)

    // Mood readout: fixed, explainable rules with a fading memory of hits.
    let mood = FlyMoodEstimator()
    let moodT0 = Date(timeIntervalSince1970: 1_000)
    var calm = FlyMoodInputs()
    var food = FlyMoodInputs(); food.nearestFoodMM = 8
    var cold = FlyMoodInputs(); cold.temperatureC = 12
    var hot = FlyMoodInputs(); hot.temperatureC = 34
    var looming = FlyMoodInputs(); looming.nervous = 0.8; looming.nearestFoodMM = 8
    let calmMood = mood.update(calm, now: moodT0).mood
    let happyMood = mood.update(food, now: moodT0).mood
    let coldMood = mood.update(cold, now: moodT0).mood
    let hotMood = mood.update(hot, now: moodT0).mood
    let scaredOverFood = mood.update(looming, now: moodT0).mood
    mood.registerHit(strength: 0.5, at: moodT0)
    let angryAfterTap = mood.update(food, now: moodT0.addingTimeInterval(1)).mood
    let fadedAfterTap = mood.update(food, now: moodT0.addingTimeInterval(20)).mood
    mood.registerHit(strength: 0.95, at: moodT0.addingTimeInterval(30))
    let hurtAfterHardHit = mood.update(calm, now: moodT0.addingTimeInterval(31)).mood
    mood.reset()
    calm.sleep = true
    let sleepyMood = mood.update(calm, now: moodT0.addingTimeInterval(32)).mood
    check("mood readout follows its stated rules and hits fade",
          calmMood == .calm && happyMood == .happy && coldMood == .cold && hotMood == .hot
          && scaredOverFood == .scared && angryAfterTap == .angry && fadedAfterTap == .happy
          && hurtAfterHardHit == .hurt && sleepyMood == .sleepy,
          "\(calmMood) \(happyMood) \(coldMood) \(hotMood) \(scaredOverFood) \(angryAfterTap) \(fadedAfterTap) \(hurtAfterHardHit) \(sleepyMood)")

    // Participant views ride the participant's own look quaternion.
    let yawLeft = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":4,"sim_tick":40,"ok":true,"snapshot_seq":4,"world_revision":6,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"actor_id":"player","position_mm":[24,0,2.5],"orientation_quat_xyzw":[0,0,0.7071067811865476,0.7071067811865476],"collision_radius_mm":2.5,"mode":"participate"}}"#
    let viewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    if let snap = parseWorldRenderSnapshotLine(Data(yawLeft.utf8)) { viewer.apply(snapshot: snap) }
    viewer.setObservationCameraMode(.firstPerson)
    let eye = viewer.mujocoCamera
    // Eye at 0.6 x radius, inside the collision sphere (view_stream.py mirrors it).
    let eyeOK = zip(eye.positionMM, [24.0, 1.5, 2.5]).allSatisfy { abs($0 - $1) < 1e-3 }
        && zip(eye.forward, [0.0, 1.0, 0.0]).allSatisfy { abs($0 - $1) < 1e-3 }
        && eye.anchor == "participant_first"
    viewer.rotateObservationCamera(deltaX: 40, deltaY: 10)
    viewer.panObservationCamera(deltaX: 9, deltaY: 3)
    let dragIgnored = viewer.mujocoCamera == eye
    viewer.setObservationCameraMode(.behindParticipant)
    let behind = viewer.mujocoCamera
    let behindOK = behind.anchor == "participant_third"
        && behind.positionMM[1] < 0 && behind.positionMM[2] > 2.5
    viewer.setObservationCameraMode(.followFly)
    check("participant first/third person cameras follow the participant's look",
          eyeOK && behindOK && dragIgnored && viewer.mujocoCamera.anchor == "fly",
          "eye=\(eye.positionMM) fwd=\(eye.forward) behind=\(behind.positionMM)")
    check("interface language is pinned to English for suites",
          LabLanguage.current == .english && L("Observe", "관찰") == "Observe")

    print(failures == 0 ? "ALL LAB TESTS PASS" : "\(failures) LAB TEST FAILURES")
    exit(failures == 0 ? 0 : 1)
}
