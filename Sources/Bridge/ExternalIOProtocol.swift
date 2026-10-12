// ExternalIOProtocol.swift — V8.1 `external_io.v1` contract: what an external
// input/output module declares (descriptor) and exchanges (observation/action
// frames). Contract first: nothing here attaches, sends or stores anything.
//
// WHAT THE NEURAL OUTPUT ACTUALLY PROVIDES (source: `BrainSignals`, built by
// `SignalBuilder.make` in MotorReadout.swift, sent to FlyGym as the `brain`
// packet `FlyGymBrainPacket`; the Python decoder `neural_decoder.decode` clamps
// to the same ranges). Produced once per render frame (display rate, nominally
// 60 Hz) from the 1 kHz simulation; population rates are EMAs, so they change
// slower than the frame rate. This is ALL the brain offers — no aim, no fire,
// no discrete game verbs. Any mapping from these to a module's action channels
// is a later, explicit, per-descriptor decoder (8.4+); nothing here maps
// forward/turn to a game action automatically.
//
//   field (packet key)     kind        unit / range                         meaning
//   escape                 discrete    bool pulse (true = takeoff NOW)      giant-fiber spike
//   nervous                continuous  normalized 0...1                     looming-detector rate
//   turnBias (turn)        continuous  normalized -1...1 (left +)           adapted DNa L-R rate
//   backward               discrete    bool (state)                         MDN burst
//   walkDrive (walk)       continuous  normalized 0...1.3                   DNp09 forward drive
//   groomDrive (groom)     continuous  normalized 0...1.5                   DNg11 rate
//   wingDrive (wing)       continuous  normalized 0...1.3                   DNp02/04/11 rate
//   arousal                continuous  normalized 0...1                     whole-population rate
//   tempo                  continuous  normalized 0.2...2.0 (1 = neutral)   thermal locomotion scale (body-side, not neural)
//   sleep                  discrete    bool (state)                         circadian/idle gate (body-side, not neural)
//
// STRICT/TOLERANT POLICY (stated once, enforced below):
//   * REQUIRED control fields — every descriptor field, every non-optional
//     channel, every action-frame field — must be present, correctly typed,
//     finite, of the declared array length and inside the declared range.
//     Anything else is rejected with an `ExternalIOError` (code + path).
//   * OPTIONAL telemetry — channels the descriptor marks `optional`, the
//     observation `source_time_s`, unknown extra keys, unknown *offered*
//     capabilities — are tolerated when absent/unknown. A telemetry value that
//     IS present must still be well-formed.
//   * `receive_monotonic_time` is stamped by the host on receipt and is kept
//     separate from the peer's `source_tick`/`timebase`; a peer-supplied value
//     is ignored.
//   * Future action kinds extend through the descriptor's typed channel schema
//     (kind/unit/axis/range/choices), never through new Swift enums per module.
import Foundation

// MARK: - Errors

struct ExternalIOError: Error, Equatable, CustomStringConvertible {
    enum Code: String {
        case missingField = "missing_field", wrongType = "wrong_type", notFinite = "not_finite"
        case wrongLength = "wrong_length", unknownUnit = "unknown_unit", unknownAxis = "unknown_axis"
        case unsupportedAPIVersion = "unsupported_api_version", outOfRange = "out_of_range"
        case unknownCapability = "unknown_capability", missingCapability = "missing_capability"
        case oversizeFrame = "oversize_frame", invalidValue = "invalid_value"
        case duplicateID = "duplicate_id", unknownChannel = "unknown_channel", modeViolation = "mode_violation"
    }
    let code: Code
    let path: String
    let detail: String
    var description: String { "\(code.rawValue) at \(path.isEmpty ? "<root>" : path): \(detail)" }
}

// MARK: - Vocabulary

enum ExternalIOAttachMode: String, CaseIterable { case auxiliary, externalEnvironment = "external_environment" }
enum ExternalIOClockMode: String, CaseIterable { case lockstep, wallClock = "wall_clock" }
enum ExternalIORestoreSupport: String, CaseIterable { case none, snapshot }
enum ExternalIOTimebase: String, CaseIterable { case simTick = "sim_tick", wallClock = "wall_clock" }
enum ExternalIOChannelKind: String, CaseIterable { case continuous, discrete, frame }
enum ExternalIOFrameFormat: String, CaseIterable {
    case gray8, rgba8
    var bytesPerPixel: Int { self == .gray8 ? 1 : 4 }
}

/// Lifecycle of one module (plan §4). Transition policy is enforced by
/// `ExternalIOSession` (8.3); this is the shared, validated graph.
enum ExternalIOLifecycle: String, CaseIterable {
    case discovered, validated, attached, ready, running, draining, detached, failed

    func canTransition(to next: ExternalIOLifecycle) -> Bool {
        switch (self, next) {
        case (.discovered, .validated), (.validated, .attached), (.attached, .ready),
             (.ready, .running), (.attached, .draining), (.ready, .draining),
             (.running, .draining), (.draining, .detached), (.validated, .detached),
             (.failed, .detached):
            return true
        case (.detached, _), (.failed, .failed): return false
        case (_, .failed): return true
        default: return false
        }
    }
}

enum ExternalIOVocabulary {
    static let apiVersion = "external_io.v1"
    static let units = ["none", "normalized", "mm", "mm/s", "deg", "deg/s", "rad", "rad/s", "ms", "s", "hz", "count"]
    static let axes = ["none", "x", "y", "z", "roll", "pitch", "yaw", "forward", "lateral", "vertical"]
    /// Capabilities this host implements. A descriptor requiring anything else is rejected.
    static let hostCapabilities = ["observation_frames", "action_frames", "image_frames",
                                   "continuous_actions", "discrete_actions"]
    /// Offered-capability names the host recognises (superset of host-implemented).
    static let knownCapabilities = hostCapabilities + ["lockstep_clock", "snapshot_restore", "raw_neural_injection"]
    static let descriptorRequiredKeys = ["type", "api_version", "module_id", "version", "display_name", "attach_mode",
                                         "clock_mode", "restore_support", "capabilities", "required_capabilities",
                                         "observations", "actions", "budgets"]
    static let channelRequiredKeys = ["channel_id", "kind", "unit", "axis", "rate_hz"]
    static let budgetKeys = ["max_frame_bytes", "max_frame_width", "max_frame_height", "max_queue_depth"]
    static let observationRequiredKeys = ["type", "api_version", "module_id", "session_id", "epoch", "seq",
                                          "source_tick", "timebase", "valid_until", "channels"]
    static let actionRequiredKeys = ["type", "api_version", "target_endpoint", "session_id", "epoch", "seq",
                                     "action_id", "neural_tick", "decoder_version", "expires_tick", "actions"]
    static let hardMaxFrameBytes = 16 * 1024 * 1024
    static let hardMaxDimension = 4096
    static let hardMaxQueueDepth = 64
    static let maxChannels = 64
}

/// What the neural output really provides, for descriptor authors and the 8.4
/// decoder. `--externaliotest` compares `names` with a Mirror of `BrainSignals`.
struct ExternalIONeuralOutputField: Equatable {
    let name: String
    let kind: ExternalIOChannelKind
    let unit: String
    let min: Double
    let max: Double
    /// Body/ambient-driven rather than read from a neuron population.
    let bodySide: Bool
}

enum ExternalIONeuralOutput {
    static let updateRateHz = 60.0   // once per render frame; sim itself is 1000 Hz
    static let fields: [ExternalIONeuralOutputField] = [
        .init(name: "escape", kind: .discrete, unit: "none", min: 0, max: 1, bodySide: false),
        .init(name: "nervous", kind: .continuous, unit: "normalized", min: 0, max: 1, bodySide: false),
        .init(name: "turnBias", kind: .continuous, unit: "normalized", min: -1, max: 1, bodySide: false),
        .init(name: "backward", kind: .discrete, unit: "none", min: 0, max: 1, bodySide: false),
        .init(name: "walkDrive", kind: .continuous, unit: "normalized", min: 0, max: 1.3, bodySide: false),
        .init(name: "groomDrive", kind: .continuous, unit: "normalized", min: 0, max: 1.5, bodySide: false),
        .init(name: "wingDrive", kind: .continuous, unit: "normalized", min: 0, max: 1.3, bodySide: false),
        .init(name: "arousal", kind: .continuous, unit: "normalized", min: 0, max: 1, bodySide: false),
        .init(name: "tempo", kind: .continuous, unit: "normalized", min: 0.2, max: 2.0, bodySide: true),
        .init(name: "sleep", kind: .discrete, unit: "none", min: 0, max: 1, bodySide: true),
    ]
    static var names: [String] { fields.map { $0.name } }
}

// MARK: - Strict JSON reader

private struct Reader {
    let obj: [String: Any]
    let path: String

    init(_ any: Any?, path: String) throws {
        guard let d = any as? [String: Any] else {
            throw ExternalIOError(code: .wrongType, path: path, detail: "expected object")
        }
        obj = d; self.path = path
    }
    func at(_ k: String) -> String { path.isEmpty ? k : path + "." + k }
    func has(_ k: String) -> Bool { obj[k] != nil && !(obj[k] is NSNull) }
    func raw(_ k: String) throws -> Any {
        guard has(k), let v = obj[k] else { throw ExternalIOError(code: .missingField, path: at(k), detail: "required field") }
        return v
    }
    static func number(_ v: Any, _ p: String) throws -> Double {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            throw ExternalIOError(code: .wrongType, path: p, detail: "expected number")
        }
        let d = n.doubleValue
        guard d.isFinite else { throw ExternalIOError(code: .notFinite, path: p, detail: "NaN/Inf") }
        return d
    }
    func double(_ k: String) throws -> Double { try Reader.number(raw(k), at(k)) }
    func int(_ k: String, min lo: Int = Int.min) throws -> Int {
        let d = try double(k)
        guard d == d.rounded(), abs(d) < 9e15 else { throw ExternalIOError(code: .wrongType, path: at(k), detail: "expected integer") }
        guard Int(d) >= lo else { throw ExternalIOError(code: .outOfRange, path: at(k), detail: "below \(lo)") }
        return Int(d)
    }
    func string(_ k: String, max: Int = 200) throws -> String {
        guard let s = try raw(k) as? String else { throw ExternalIOError(code: .wrongType, path: at(k), detail: "expected string") }
        guard !s.isEmpty, s.unicodeScalars.count <= max, s == s.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ExternalIOError(code: .invalidValue, path: at(k), detail: "empty, too long or padded string")
        }
        return s
    }
    /// Identifier: lowercase, digits, `._-`, ≤ 64 scalars, starts alphanumeric.
    func identifier(_ k: String) throws -> String {
        let s = try string(k, max: 64)
        let ok = s.unicodeScalars.enumerated().allSatisfy { i, u in
            ("a"..."z").contains(u) || ("0"..."9").contains(u) || (i > 0 && "._-".unicodeScalars.contains(u))
        }
        guard ok else { throw ExternalIOError(code: .invalidValue, path: at(k), detail: "invalid identifier") }
        return s
    }
    func array(_ k: String) throws -> [Any] {
        guard let a = try raw(k) as? [Any] else { throw ExternalIOError(code: .wrongType, path: at(k), detail: "expected array") }
        return a
    }
    func numbers(_ k: String) throws -> [Double] {
        try array(k).enumerated().map { try Reader.number($1, at(k) + "[\($0)]") }
    }
    func strings(_ k: String) throws -> [String] {
        try array(k).enumerated().map {
            guard let s = $1 as? String, !s.isEmpty, s.unicodeScalars.count <= 64 else {
                throw ExternalIOError(code: .wrongType, path: at(k) + "[\($0)]", detail: "expected non-empty string")
            }
            return s
        }
    }
    func object(_ k: String) throws -> Reader { try Reader(raw(k), path: at(k)) }
    func requireKeys(_ keys: [String]) throws { for k in keys { _ = try raw(k) } }
    func enumValue<E: RawRepresentable & CaseIterable>(_ k: String, _ type: E.Type, _ code: ExternalIOError.Code = .invalidValue) throws -> E where E.RawValue == String {
        let s = try string(k, max: 64)
        guard let e = E(rawValue: s) else { throw ExternalIOError(code: code, path: at(k), detail: "unsupported value '\(s)'") }
        return e
    }
    func vocabulary(_ k: String, _ allowed: [String], _ code: ExternalIOError.Code) throws -> String {
        let s = try string(k, max: 64)
        guard allowed.contains(s) else { throw ExternalIOError(code: code, path: at(k), detail: "unknown '\(s)'") }
        return s
    }
}

private func distinct(_ items: [String]) -> Bool { Set(items).count == items.count }

// MARK: - Descriptor

struct ExternalIOChannelSchema: Equatable {
    let channelID: String
    let kind: ExternalIOChannelKind
    let unit: String
    let axis: String
    let minimum: Double?
    let maximum: Double?
    let length: Int            // continuous array length; 1 for discrete; 0 for frame
    let choices: [String]      // discrete
    let formats: [ExternalIOFrameFormat]  // frame
    let rateHz: Double
    let optional: Bool

    fileprivate init(_ r: Reader) throws {
        try r.requireKeys(ExternalIOVocabulary.channelRequiredKeys)
        channelID = try r.identifier("channel_id")
        kind = try r.enumValue("kind", ExternalIOChannelKind.self)
        unit = try r.vocabulary("unit", ExternalIOVocabulary.units, .unknownUnit)
        axis = try r.vocabulary("axis", ExternalIOVocabulary.axes, .unknownAxis)
        rateHz = try r.double("rate_hz")
        guard rateHz > 0, rateHz <= 1000 else { throw ExternalIOError(code: .outOfRange, path: r.at("rate_hz"), detail: "0 < rate_hz <= 1000") }
        optional = r.has("optional") ? (r.obj["optional"] as? Bool ?? false) : false
        if r.has("optional"), !(r.obj["optional"] is Bool) { throw ExternalIOError(code: .wrongType, path: r.at("optional"), detail: "expected bool") }
        switch kind {
        case .continuous:
            let lo = try r.double("min"), hi = try r.double("max")
            guard lo <= hi else { throw ExternalIOError(code: .outOfRange, path: r.at("min"), detail: "min > max") }
            minimum = lo; maximum = hi
            length = try r.int("length", min: 1)
            guard length <= 64 else { throw ExternalIOError(code: .wrongLength, path: r.at("length"), detail: "length > 64") }
            choices = []; formats = []
        case .discrete:
            guard unit == "none", !r.has("min"), !r.has("max") else {
                throw ExternalIOError(code: .invalidValue, path: r.path, detail: "discrete channel needs unit none and no min/max")
            }
            choices = try r.strings("choices")
            guard !choices.isEmpty, choices.count <= 64, distinct(choices) else {
                throw ExternalIOError(code: .invalidValue, path: r.at("choices"), detail: "1...64 distinct choices")
            }
            minimum = nil; maximum = nil; length = 1; formats = []
        case .frame:
            guard unit == "none" else { throw ExternalIOError(code: .invalidValue, path: r.at("unit"), detail: "frame channel unit must be none") }
            formats = try r.strings("formats").map {
                guard let f = ExternalIOFrameFormat(rawValue: $0) else {
                    throw ExternalIOError(code: .invalidValue, path: r.at("formats"), detail: "unsupported format '\($0)'")
                }
                return f
            }
            guard !formats.isEmpty else { throw ExternalIOError(code: .invalidValue, path: r.at("formats"), detail: "empty formats") }
            minimum = nil; maximum = nil; length = 0; choices = []
        }
    }

    var jsonObject: [String: Any] {
        var d: [String: Any] = ["channel_id": channelID, "kind": kind.rawValue, "unit": unit, "axis": axis,
                                "rate_hz": rateHz, "optional": optional]
        if let minimum { d["min"] = minimum }
        if let maximum { d["max"] = maximum }
        if kind == .continuous { d["length"] = length }
        if kind == .discrete { d["choices"] = choices }
        if kind == .frame { d["formats"] = formats.map { $0.rawValue } }
        return d
    }
}

struct ExternalIOBudgets: Equatable {
    let maxFrameBytes: Int, maxFrameWidth: Int, maxFrameHeight: Int, maxQueueDepth: Int
    fileprivate init(_ r: Reader) throws {
        try r.requireKeys(ExternalIOVocabulary.budgetKeys)
        func bounded(_ k: String, _ hi: Int, _ code: ExternalIOError.Code) throws -> Int {
            let v = try r.int(k)
            guard (1...hi).contains(v) else { throw ExternalIOError(code: code, path: r.at(k), detail: "must be 1...\(hi)") }
            return v
        }
        maxFrameBytes = try bounded("max_frame_bytes", ExternalIOVocabulary.hardMaxFrameBytes, .oversizeFrame)
        maxFrameWidth = try bounded("max_frame_width", ExternalIOVocabulary.hardMaxDimension, .oversizeFrame)
        maxFrameHeight = try bounded("max_frame_height", ExternalIOVocabulary.hardMaxDimension, .oversizeFrame)
        maxQueueDepth = try bounded("max_queue_depth", ExternalIOVocabulary.hardMaxQueueDepth, .outOfRange)
    }
    var jsonObject: [String: Any] {
        ["max_frame_bytes": maxFrameBytes, "max_frame_width": maxFrameWidth,
         "max_frame_height": maxFrameHeight, "max_queue_depth": maxQueueDepth]
    }
}

struct ExternalIOModuleDescriptor: Equatable {
    let moduleID: String
    let version: String
    let displayName: String
    let attachMode: ExternalIOAttachMode
    let clockMode: ExternalIOClockMode
    let restoreSupport: ExternalIORestoreSupport
    let capabilities: [String]          // offered, recognised names only
    let requiredCapabilities: [String]  // host must implement all of these
    let observations: [ExternalIOChannelSchema]   // module -> host
    let actions: [ExternalIOChannelSchema]        // host -> module (body output)
    let budgets: ExternalIOBudgets

    static func decode(_ data: Data) throws -> ExternalIOModuleDescriptor {
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw ExternalIOError(code: .wrongType, path: "", detail: "not JSON")
        }
        return try decode(any)
    }

    static func decode(_ any: Any) throws -> ExternalIOModuleDescriptor {
        let r = try Reader(any, path: "")
        // Version first: an unsupported contract must be reported as such, not
        // as whichever field the newer schema changed.
        guard let v = r.obj["api_version"] as? String else { throw ExternalIOError(code: .missingField, path: "api_version", detail: "required field") }
        guard v == ExternalIOVocabulary.apiVersion else {
            throw ExternalIOError(code: .unsupportedAPIVersion, path: "api_version", detail: "'\(v)' != \(ExternalIOVocabulary.apiVersion)")
        }
        try r.requireKeys(ExternalIOVocabulary.descriptorRequiredKeys)
        guard try r.string("type", max: 32) == "module_descriptor" else {
            throw ExternalIOError(code: .invalidValue, path: "type", detail: "expected module_descriptor")
        }
        return try ExternalIOModuleDescriptor(r)
    }

    private init(_ r: Reader) throws {
        moduleID = try r.identifier("module_id")
        version = try r.string("version", max: 32)
        displayName = try r.string("display_name", max: 80)
        attachMode = try r.enumValue("attach_mode", ExternalIOAttachMode.self)
        clockMode = try r.enumValue("clock_mode", ExternalIOClockMode.self)
        restoreSupport = try r.enumValue("restore_support", ExternalIORestoreSupport.self)
        let offered = try r.strings("capabilities")
        capabilities = offered.filter { ExternalIOVocabulary.knownCapabilities.contains($0) }  // unknown offered: tolerated
        requiredCapabilities = try r.strings("required_capabilities")
        for c in requiredCapabilities where !ExternalIOVocabulary.hostCapabilities.contains(c) {
            throw ExternalIOError(code: .unknownCapability, path: r.at("required_capabilities"), detail: "host does not implement '\(c)'")
        }
        func schemas(_ k: String) throws -> [ExternalIOChannelSchema] {
            let items = try r.array(k)
            guard items.count <= ExternalIOVocabulary.maxChannels else {
                throw ExternalIOError(code: .wrongLength, path: r.at(k), detail: "more than \(ExternalIOVocabulary.maxChannels) channels")
            }
            let out = try items.enumerated().map { try ExternalIOChannelSchema(Reader($1, path: r.at(k) + "[\($0)]")) }
            guard distinct(out.map { $0.channelID }) else { throw ExternalIOError(code: .duplicateID, path: r.at(k), detail: "duplicate channel_id") }
            return out
        }
        observations = try schemas("observations")
        actions = try schemas("actions")
        budgets = try ExternalIOBudgets(r.object("budgets"))
        // Cross-field consistency: declared channels need the capability that carries them.
        func need(_ cap: String, _ why: String) throws {
            guard capabilities.contains(cap) else { throw ExternalIOError(code: .missingCapability, path: r.at("capabilities"), detail: "\(why) needs '\(cap)'") }
        }
        for c in requiredCapabilities { try need(c, "required capability") }
        if !observations.isEmpty { try need("observation_frames", "observation channels") }
        if !actions.isEmpty { try need("action_frames", "action channels") }
        if observations.contains(where: { $0.kind == .frame }) { try need("image_frames", "frame channel") }
        if actions.contains(where: { $0.kind == .continuous }) { try need("continuous_actions", "continuous action") }
        if actions.contains(where: { $0.kind == .discrete }) { try need("discrete_actions", "discrete action") }
        if actions.contains(where: { $0.kind == .frame }) {
            throw ExternalIOError(code: .invalidValue, path: r.at("actions"), detail: "action channels cannot be frames")
        }
        if clockMode == .lockstep { try need("lockstep_clock", "lockstep clock") }
        if restoreSupport == .snapshot { try need("snapshot_restore", "snapshot restore") }
        // Body output belongs to external_environment only (plan §6).
        if attachMode == .auxiliary, !actions.isEmpty {
            throw ExternalIOError(code: .modeViolation, path: r.at("actions"), detail: "auxiliary modules cannot declare body actions")
        }
    }

    var jsonObject: [String: Any] {
        ["type": "module_descriptor", "api_version": ExternalIOVocabulary.apiVersion, "module_id": moduleID,
         "version": version, "display_name": displayName, "attach_mode": attachMode.rawValue,
         "clock_mode": clockMode.rawValue, "restore_support": restoreSupport.rawValue,
         "capabilities": capabilities, "required_capabilities": requiredCapabilities,
         "observations": observations.map { $0.jsonObject }, "actions": actions.map { $0.jsonObject },
         "budgets": budgets.jsonObject]
    }

    func observation(_ id: String) -> ExternalIOChannelSchema? { observations.first { $0.channelID == id } }
    func action(_ id: String) -> ExternalIOChannelSchema? { actions.first { $0.channelID == id } }
}

// MARK: - Frames

enum ExternalIOValue: Equatable {
    case continuous([Double])
    case discrete(String)
}

struct ExternalIOChannelValue: Equatable {
    let channelID: String
    let value: ExternalIOValue

    fileprivate init(_ r: Reader, schemas: [ExternalIOChannelSchema]) throws {
        try r.requireKeys(["channel_id"])
        let id = try r.identifier("channel_id")
        channelID = id
        guard let s = schemas.first(where: { $0.channelID == id }) else {
            throw ExternalIOError(code: .unknownChannel, path: r.at("channel_id"), detail: "'\(id)' not declared")
        }
        switch s.kind {
        case .continuous:
            let unit = try r.vocabulary("unit", ExternalIOVocabulary.units, .unknownUnit)
            guard unit == s.unit else { throw ExternalIOError(code: .unknownUnit, path: r.at("unit"), detail: "'\(unit)' != declared '\(s.unit)'") }
            let v = try r.numbers("values")
            guard v.count == s.length else { throw ExternalIOError(code: .wrongLength, path: r.at("values"), detail: "\(v.count) != \(s.length)") }
            for (i, x) in v.enumerated() where x < s.minimum! || x > s.maximum! {
                throw ExternalIOError(code: .outOfRange, path: r.at("values") + "[\(i)]", detail: "\(x) outside \(s.minimum!)...\(s.maximum!)")
            }
            value = .continuous(v)
        case .discrete:
            let c = try r.string("choice", max: 64)
            guard s.choices.contains(c) else { throw ExternalIOError(code: .outOfRange, path: r.at("choice"), detail: "'\(c)' not a declared choice") }
            value = .discrete(c)
        case .frame:
            throw ExternalIOError(code: .invalidValue, path: r.at("channel_id"), detail: "frame channels travel in `frame`, not `channels`")
        }
    }

    var jsonObject: [String: Any] {
        switch value {
        case .continuous(let v): return ["channel_id": channelID, "values": v]
        case .discrete(let c): return ["channel_id": channelID, "choice": c]
        }
    }
    /// Encoding needs the unit for continuous entries; supplied from the schema.
    func jsonObject(unit: String?) -> [String: Any] {
        var d = jsonObject
        if let unit, case .continuous = value { d["unit"] = unit }
        return d
    }
}

struct ExternalIOFrameReference: Equatable {
    let channelID: String
    let format: ExternalIOFrameFormat
    let width: Int, height: Int, byteLength: Int
    let transportRef: String
    var jsonObject: [String: Any] {
        ["channel_id": channelID, "format": format.rawValue, "width": width, "height": height,
         "byte_length": byteLength, "transport_ref": transportRef]
    }
}

struct ExternalIOObservationFrame: Equatable {
    let moduleID: String
    let sessionID: String
    let epoch: Int, seq: Int
    let sourceTick: Int
    let timebase: ExternalIOTimebase
    /// Host-stamped on receipt; never taken from the peer.
    let receiveMonotonicTime: Double
    let validUntil: Int                // in `timebase` units, >= source_tick
    let sourceTimeSeconds: Double?     // optional telemetry
    let channels: [ExternalIOChannelValue]
    let frame: ExternalIOFrameReference?

    static func decode(_ data: Data, descriptor: ExternalIOModuleDescriptor, receiveMonotonic: Double) throws -> ExternalIOObservationFrame {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { throw ExternalIOError(code: .wrongType, path: "", detail: "not JSON") }
        return try decode(any, descriptor: descriptor, receiveMonotonic: receiveMonotonic)
    }

    static func decode(_ any: Any, descriptor d: ExternalIOModuleDescriptor, receiveMonotonic: Double) throws -> ExternalIOObservationFrame {
        let r = try Reader(any, path: "")
        guard let v = r.obj["api_version"] as? String else { throw ExternalIOError(code: .missingField, path: "api_version", detail: "required field") }
        guard v == ExternalIOVocabulary.apiVersion else { throw ExternalIOError(code: .unsupportedAPIVersion, path: "api_version", detail: v) }
        try r.requireKeys(ExternalIOVocabulary.observationRequiredKeys)
        guard try r.string("type", max: 32) == "observation_frame" else { throw ExternalIOError(code: .invalidValue, path: "type", detail: "expected observation_frame") }
        guard receiveMonotonic.isFinite, receiveMonotonic >= 0 else { throw ExternalIOError(code: .notFinite, path: "receive_monotonic_time", detail: "host stamp invalid") }
        let moduleID = try r.identifier("module_id")
        guard moduleID == d.moduleID else { throw ExternalIOError(code: .invalidValue, path: "module_id", detail: "not the descriptor's module") }
        let sessionID = try r.identifier("session_id")
        let epoch = try r.int("epoch", min: 1), seq = try r.int("seq", min: 1)
        let sourceTick = try r.int("source_tick", min: 0)
        let timebase = try r.enumValue("timebase", ExternalIOTimebase.self)
        if d.clockMode == .lockstep, timebase != .simTick {
            throw ExternalIOError(code: .modeViolation, path: "timebase", detail: "lockstep module must use sim_tick")
        }
        let validUntil = try r.int("valid_until")
        guard validUntil >= sourceTick else { throw ExternalIOError(code: .outOfRange, path: "valid_until", detail: "before source_tick") }
        let sourceTimeSeconds: Double? = r.has("source_time_s") ? try r.double("source_time_s") : nil
        var entries: [ExternalIOChannelValue] = []
        for (i, item) in try r.array("channels").enumerated() {
            entries.append(try ExternalIOChannelValue(Reader(item, path: "channels[\(i)]"), schemas: d.observations))
        }
        guard distinct(entries.map { $0.channelID }) else { throw ExternalIOError(code: .duplicateID, path: "channels", detail: "duplicate channel") }
        // Required control fields: every non-optional scalar channel must be present.
        for s in d.observations where s.kind != .frame && !s.optional && !entries.contains(where: { $0.channelID == s.channelID }) {
            throw ExternalIOError(code: .missingField, path: "channels", detail: "required channel '\(s.channelID)' absent")
        }
        var frame: ExternalIOFrameReference?
        if r.has("frame") {
            let f = try r.object("frame")
            try f.requireKeys(["channel_id", "format", "width", "height", "byte_length", "transport_ref"])
            let cid = try f.identifier("channel_id")
            guard let s = d.observation(cid), s.kind == .frame else { throw ExternalIOError(code: .unknownChannel, path: f.at("channel_id"), detail: "no such frame channel") }
            let fmt = try f.enumValue("format", ExternalIOFrameFormat.self)
            guard s.formats.contains(fmt) else { throw ExternalIOError(code: .invalidValue, path: f.at("format"), detail: "format not declared for channel") }
            let w = try f.int("width", min: 1), h = try f.int("height", min: 1), n = try f.int("byte_length", min: 1)
            // Check dims against the budget before any arithmetic on them.
            guard w <= d.budgets.maxFrameWidth, h <= d.budgets.maxFrameHeight, n <= d.budgets.maxFrameBytes else {
                throw ExternalIOError(code: .oversizeFrame, path: f.path, detail: "\(w)x\(h) \(n) B exceeds budget")
            }
            guard n == w * h * fmt.bytesPerPixel else { throw ExternalIOError(code: .wrongLength, path: f.at("byte_length"), detail: "\(n) != w*h*bpp") }
            frame = ExternalIOFrameReference(channelID: cid, format: fmt, width: w, height: h, byteLength: n,
                                             transportRef: try f.string("transport_ref", max: 200))
        } else {
            if let s = d.observations.first(where: { $0.kind == .frame && !$0.optional }) {
                throw ExternalIOError(code: .missingField, path: "frame", detail: "required frame channel '\(s.channelID)' absent")
            }
            frame = nil
        }
        return ExternalIOObservationFrame(moduleID: moduleID, sessionID: sessionID, epoch: epoch, seq: seq,
            sourceTick: sourceTick, timebase: timebase, receiveMonotonicTime: receiveMonotonic, validUntil: validUntil,
            sourceTimeSeconds: sourceTimeSeconds, channels: entries, frame: frame)
    }

    // `init` is only reachable through decode (strict); memberwise use is internal.
    private init(moduleID: String, sessionID: String, epoch: Int, seq: Int, sourceTick: Int, timebase: ExternalIOTimebase,
                 receiveMonotonicTime: Double, validUntil: Int, sourceTimeSeconds: Double?,
                 channels: [ExternalIOChannelValue], frame: ExternalIOFrameReference?) {
        self.moduleID = moduleID; self.sessionID = sessionID; self.epoch = epoch; self.seq = seq
        self.sourceTick = sourceTick; self.timebase = timebase; self.receiveMonotonicTime = receiveMonotonicTime
        self.validUntil = validUntil; self.sourceTimeSeconds = sourceTimeSeconds; self.channels = channels; self.frame = frame
    }

    func jsonObject(descriptor d: ExternalIOModuleDescriptor) -> [String: Any] {
        var o: [String: Any] = ["type": "observation_frame", "api_version": ExternalIOVocabulary.apiVersion,
                                "module_id": moduleID, "session_id": sessionID, "epoch": epoch, "seq": seq,
                                "source_tick": sourceTick, "timebase": timebase.rawValue,
                                "receive_monotonic_time": receiveMonotonicTime, "valid_until": validUntil,
                                "channels": channels.map { $0.jsonObject(unit: d.observation($0.channelID)?.unit) }]
        if let sourceTimeSeconds { o["source_time_s"] = sourceTimeSeconds }
        if let frame { o["frame"] = frame.jsonObject }
        return o
    }
}

struct ExternalIOActionFrame: Equatable {
    let targetEndpoint: String
    let sessionID: String
    let epoch: Int, seq: Int
    let actionID: String
    let neuralTick: Int
    let decoderVersion: String
    let expiresTick: Int
    let actions: [ExternalIOChannelValue]

    static func decode(_ data: Data, descriptor: ExternalIOModuleDescriptor) throws -> ExternalIOActionFrame {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { throw ExternalIOError(code: .wrongType, path: "", detail: "not JSON") }
        return try decode(any, descriptor: descriptor)
    }

    /// Policy: every envelope field is required; the `actions` list may address a
    /// subset of the declared channels but must be non-empty, and each present
    /// entry must be complete, finite, correctly sized and inside its range.
    static func decode(_ any: Any, descriptor d: ExternalIOModuleDescriptor) throws -> ExternalIOActionFrame {
        let r = try Reader(any, path: "")
        guard let v = r.obj["api_version"] as? String else { throw ExternalIOError(code: .missingField, path: "api_version", detail: "required field") }
        guard v == ExternalIOVocabulary.apiVersion else { throw ExternalIOError(code: .unsupportedAPIVersion, path: "api_version", detail: v) }
        try r.requireKeys(ExternalIOVocabulary.actionRequiredKeys)
        guard try r.string("type", max: 32) == "action_frame" else { throw ExternalIOError(code: .invalidValue, path: "type", detail: "expected action_frame") }
        guard d.attachMode == .externalEnvironment else {
            throw ExternalIOError(code: .modeViolation, path: "target_endpoint", detail: "auxiliary modules receive no action frames")
        }
        let target = try r.identifier("target_endpoint")
        guard target == d.moduleID else { throw ExternalIOError(code: .invalidValue, path: "target_endpoint", detail: "not the descriptor's module") }
        let tick = try r.int("neural_tick", min: 0)
        let expiry = try r.int("expires_tick")
        guard expiry >= tick else { throw ExternalIOError(code: .outOfRange, path: "expires_tick", detail: "before neural_tick") }
        let items = try r.array("actions")
        guard !items.isEmpty, items.count <= ExternalIOVocabulary.maxChannels else {
            throw ExternalIOError(code: .wrongLength, path: "actions", detail: "1...\(ExternalIOVocabulary.maxChannels) entries")
        }
        var entries: [ExternalIOChannelValue] = []
        for (i, item) in items.enumerated() {
            entries.append(try ExternalIOChannelValue(Reader(item, path: "actions[\(i)]"), schemas: d.actions))
        }
        guard distinct(entries.map { $0.channelID }) else { throw ExternalIOError(code: .duplicateID, path: "actions", detail: "duplicate channel") }
        return ExternalIOActionFrame(targetEndpoint: target, sessionID: try r.identifier("session_id"),
                                     epoch: try r.int("epoch", min: 1), seq: try r.int("seq", min: 1),
                                     actionID: try r.identifier("action_id"), neuralTick: tick,
                                     decoderVersion: try r.string("decoder_version", max: 32),
                                     expiresTick: expiry, actions: entries)
    }

    func jsonObject(descriptor d: ExternalIOModuleDescriptor) -> [String: Any] {
        ["type": "action_frame", "api_version": ExternalIOVocabulary.apiVersion, "target_endpoint": targetEndpoint,
         "session_id": sessionID, "epoch": epoch, "seq": seq, "action_id": actionID, "neural_tick": neuralTick,
         "decoder_version": decoderVersion, "expires_tick": expiresTick,
         "actions": actions.map { $0.jsonObject(unit: d.action($0.channelID)?.unit) }]
    }
}
