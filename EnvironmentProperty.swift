// EnvironmentProperty.swift — V6.1 backend-owned capability manifest and the
// V6.2 strict edit request. Descriptors describe legacy controls; they do not
// promise scene persistence, atomic application, or biological calibration.
// The backend stays authoritative for targets, revisions and appliers.
import Foundation

// The Python producer/validator compares code points; Swift String equality uses
// canonical equivalence ("é" == "e\u{301}"). Compare scalars so both sides accept
// and reject exactly the same manifests.
private func sameScalars(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}
private func scalarDistinct(_ items: [String]) -> Bool {
    Set(items.map { Array($0.unicodeScalars) }).count == items.count
}
// Exactly Python str.strip()'s set: it also strips U+001C...U+001F, and unlike
// Foundation it keeps U+200B. Checked over every scalar against Python 3.12.
private let pythonWhitespace = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))
    .subtracting(CharacterSet(charactersIn: "\u{200B}"))
/// Python `_text`: nonempty, at most `limit` code points, nothing strip() removes.
private func pythonText(_ s: String, _ limit: Int) -> Bool {
    !s.isEmpty && s.unicodeScalars.count <= limit && sameScalars(s, s.trimmingCharacters(in: pythonWhitespace))
}

enum EnvironmentPropertyValue: Codable, Equatable {
    case number(Double), vector([Double]), boolean(Bool), choice(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([Double].self) { self = .vector(v) }
        else { self = .choice(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .vector(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        case .choice(let v): try c.encode(v)
        }
    }

    /// JSONSerialization-shaped value, as EnvironmentEdit.validate reads it.
    var jsonObject: Any {
        switch self {
        case .number(let v): return v
        case .vector(let v): return v
        case .boolean(let v): return v
        case .choice(let v): return v
        }
    }
}

struct EnvironmentPropertyDescriptor: Decodable {
    enum ValueType: String, Decodable { case number, vector, boolean, `enum` }
    enum Scope: String, Decodable { case global, local }
    enum ApplyMode: String, Decodable { case live, spawnOnly = "spawn_only", recompile }
    enum Persistence: String, Decodable { case sceneCandidate = "scene_candidate", transient }
    enum Effect: String, Decodable {
        case physical = "PHYSICAL", sensoryModel = "SENSORY-MODEL"
        case directNeural = "DIRECT-NEURAL", visual = "VISUAL"
    }
    let propertyID: String
    let label: String
    let valueType: ValueType
    let unit: String
    let minimum: EnvironmentPropertyValue?
    let maximum: EnvironmentPropertyValue?
    let defaultValue: EnvironmentPropertyValue?
    let choices: [String]
    let scope: Scope
    let applyMode: ApplyMode
    let supportedEffects: [Effect]
    let persistence: Persistence
    let legacyCommands: [String]
    let legacyField: String
    let notes: String

    enum CodingKeys: String, CodingKey {
        case propertyID = "property_id", label, valueType = "value_type", unit
        case minimum = "min", maximum = "max", defaultValue = "default", choices
        case scope, applyMode = "apply_mode", supportedEffects = "supported_effects"
        case persistence, legacyCommands = "legacy_commands", legacyField = "legacy_field", notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // null is explicit for context-dependent defaults/non-numeric bounds;
        // missing mandatory keys must not masquerade as that intentional null.
        for key in [CodingKeys.minimum, .maximum, .defaultValue] where !c.contains(key) {
            throw DecodingError.keyNotFound(key, .init(codingPath: c.codingPath, debugDescription: "required descriptor field"))
        }
        propertyID = try c.decode(String.self, forKey: .propertyID)
        label = try c.decode(String.self, forKey: .label)
        valueType = try c.decode(ValueType.self, forKey: .valueType)
        unit = try c.decode(String.self, forKey: .unit)
        minimum = try c.decodeIfPresent(EnvironmentPropertyValue.self, forKey: .minimum)
        maximum = try c.decodeIfPresent(EnvironmentPropertyValue.self, forKey: .maximum)
        defaultValue = try c.decodeIfPresent(EnvironmentPropertyValue.self, forKey: .defaultValue)
        choices = try c.decode([String].self, forKey: .choices)
        scope = try c.decode(Scope.self, forKey: .scope)
        applyMode = try c.decode(ApplyMode.self, forKey: .applyMode)
        supportedEffects = try c.decode([Effect].self, forKey: .supportedEffects)
        persistence = try c.decode(Persistence.self, forKey: .persistence)
        legacyCommands = try c.decode([String].self, forKey: .legacyCommands)
        legacyField = try c.decode(String.self, forKey: .legacyField)
        notes = try c.decode(String.self, forKey: .notes)
        func require(_ valid: Bool, _ reason: String) throws {
            if !valid { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: reason)) }
        }
        let text = pythonText
        try require(text(propertyID, 96) && text(label, 200) && text(legacyField, 96), "invalid identity/label/field")
        try require(notes.unicodeScalars.count <= 2000 && (defaultValue != nil || !notes.trimmingCharacters(in: pythonWhitespace).isEmpty), "context-dependent default needs notes")
        try require(!legacyCommands.isEmpty && legacyCommands.count <= 16
                    && scalarDistinct(legacyCommands)
                    && legacyCommands.allSatisfy { text($0, 96) }, "invalid legacy commands")
        try require(Set(supportedEffects).count == supportedEffects.count, "invalid effects")
        try require(scalarDistinct(choices) && choices.count <= 64
                    && choices.allSatisfy { text($0, 96) }, "invalid choices")
        let numericUnits = ["mm", "mm/s", "deg", "degC", "ms", "normalized"]
        switch valueType {
        case .number:
            try require(numericUnits.contains(unit) && choices.isEmpty, "invalid number unit/choices")
            guard case let .number(lo)? = minimum, case let .number(hi)? = maximum else {
                try require(false, "number bounds required"); return
            }
            try require(lo.isFinite && hi.isFinite && lo <= hi, "invalid number bounds")
            if let value = defaultValue {
                guard case let .number(v) = value else { try require(false, "wrong number default type"); return }
                try require(v.isFinite && v >= lo && v <= hi, "number default outside bounds")
            }
        case .vector:
            try require(["mm", "unit_vector", "rgba"].contains(unit) && choices.isEmpty, "invalid vector unit/choices")
            guard case let .vector(lo)? = minimum, case let .vector(hi)? = maximum else {
                try require(false, "vector bounds required"); return
            }
            try require((2...4).contains(lo.count) && lo.count == hi.count, "invalid vector arity")
            try require(zip(lo, hi).allSatisfy { $0.isFinite && $1.isFinite && $0 <= $1 }, "invalid vector bounds")
            try require((unit != "rgba" || lo.count == 4) && (unit != "unit_vector" || lo.count == 3), "unit/vector arity mismatch")
            if let value = defaultValue {
                guard case let .vector(v) = value else { try require(false, "wrong vector default type"); return }
                try require(v.count == lo.count && v.enumerated().allSatisfy {
                    $0.element.isFinite && $0.element >= lo[$0.offset] && $0.element <= hi[$0.offset]
                }, "vector default outside bounds")
            }
        case .boolean:
            try require(unit == "none" && minimum == nil && maximum == nil && choices.isEmpty, "invalid boolean metadata")
            if let value = defaultValue {
                guard case .boolean = value else { try require(false, "wrong boolean default type"); return }
            }
        case .enum:
            try require(unit == "none" && minimum == nil && maximum == nil && !choices.isEmpty, "invalid enum metadata")
            if let value = defaultValue {
                guard case let .choice(v) = value else { try require(false, "wrong enum default type"); return }
                try require(choices.contains { sameScalars($0, v) }, "default missing from choices")
            }
        }
    }
}

struct EnvironmentCapabilities: Decodable {
    let schemaVersion: Int
    let descriptors: [EnvironmentPropertyDescriptor]
    /// V6.3 optional discrete operations; absent on older descriptor producers.
    let objectOperations: [String]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", descriptors, objectOperations = "object_operations" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        descriptors = try c.decode([EnvironmentPropertyDescriptor].self, forKey: .descriptors)
        let operations = (try? c.decode([String].self, forKey: .objectOperations)) ?? []
        objectOperations = scalarDistinct(operations) && operations.allSatisfy { ["duplicate", "delete"].contains($0) } ? operations : []
        guard schemaVersion == 1, !descriptors.isEmpty, descriptors.count <= 128,
              scalarDistinct(descriptors.map { $0.propertyID }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "unsupported version, duplicate IDs or invalid manifest size"))
        }
    }

    func descriptor(_ propertyID: String) -> EnvironmentPropertyDescriptor? {
        descriptors.first { sameScalars($0.propertyID, propertyID) }
    }
}

// MARK: - V6.2 strict edit request

struct EnvironmentEditError: Error, Equatable, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "\(path): \(reason)" }
}

/// One `edit_property` request. `validate` mirrors Python
/// environment_properties.validate_edit check for check and in the same order,
/// so both report the same first failing path (fixtures/environment_edits).
/// Nothing is clamped or coerced. The backend still checks the target object,
/// the current revision and whether it has an applier for the property.
struct EnvironmentEdit: Codable, Equatable {
    static let schemaVersion = 1
    static let fields = ["schema_version", "property_id", "target_id", "expected_revision", "unit", "value"]
    static let maxRevision = 9_007_199_254_740_992.0  // 2^53, Python MAX_REVISION

    let schemaVersion: Int
    let propertyID: String
    let targetID: String?
    let expectedRevision: Int
    let unit: String
    let value: EnvironmentPropertyValue

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", propertyID = "property_id", targetID = "target_id"
        case expectedRevision = "expected_revision", unit, value
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(propertyID, forKey: .propertyID)
        try c.encode(targetID, forKey: .targetID)  // explicit null: the key is required
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(unit, forKey: .unit)
        try c.encode(value, forKey: .value)
    }

    /// A validated request for `propertyID` in the descriptor's own unit.
    static func make(propertyID: String, targetID: String?, expectedRevision: Int,
                     value: EnvironmentPropertyValue,
                     capabilities: EnvironmentCapabilities) throws -> EnvironmentEdit {
        try validate(json: [
            "schema_version": schemaVersion, "property_id": propertyID,
            "target_id": targetID ?? NSNull(), "expected_revision": expectedRevision,
            "unit": capabilities.descriptor(propertyID)?.unit ?? "", "value": value.jsonObject,
        ] as [String: Any], capabilities: capabilities)
    }

    /// Validates a JSONSerialization object (NSNumber booleans are not numbers).
    static func validate(json: Any, capabilities: EnvironmentCapabilities) throws -> EnvironmentEdit {
        func fail(_ path: String, _ reason: String) -> EnvironmentEditError {
            EnvironmentEditError(path: path, reason: reason)
        }
        func number(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        guard let edit = json as? [String: Any] else { throw fail("edit", "must be an object") }
        let unknown = edit.keys.filter { key in !fields.contains { sameScalars($0, key) } }
            .sorted { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
        if let key = unknown.first { throw fail("edit.\(key)", "unknown field") }
        if let key = fields.first(where: { edit[$0] == nil }) { throw fail("edit.\(key)", "required") }
        guard number(edit["schema_version"]) == Double(schemaVersion) else {
            throw fail("edit.schema_version", "unsupported edit schema_version")
        }
        guard let propertyID = edit["property_id"] as? String,
              let d = capabilities.descriptor(propertyID) else {
            throw fail("edit.property_id", "unknown property")
        }
        guard d.applyMode == .live else { throw fail("edit.property_id", "\(d.applyMode.rawValue) property is not live-editable") }
        guard d.persistence == .sceneCandidate else {
            throw fail("edit.property_id", "transient action parameter is not an editable setting")
        }
        guard let unit = edit["unit"] as? String, sameScalars(unit, d.unit) else {
            throw fail("edit.unit", "unit must be \(d.unit)")
        }
        let targetID: String?
        if d.scope == .local {
            guard let target = edit["target_id"] as? String, pythonText(target, 64) else {
                throw fail("edit.target_id", "local property requires a target_id")
            }
            targetID = target
        } else {
            guard edit["target_id"] is NSNull else { throw fail("edit.target_id", "global property takes null target_id") }
            targetID = nil
        }
        guard let revision = number(edit["expected_revision"]), revision.rounded() == revision,
              revision >= 0, revision <= maxRevision else {
            throw fail("edit.expected_revision", "must be a nonnegative integer")
        }
        let raw = edit["value"], value: EnvironmentPropertyValue
        switch (d.valueType, d.minimum, d.maximum) {
        case (.number, .number(let lo)?, .number(let hi)?):
            guard let v = number(raw), v >= lo, v <= hi else {
                throw fail("edit.value", "must be a finite number in [\(lo), \(hi)]")
            }
            value = .number(v)
        case (.vector, .vector(let lo)?, .vector(let hi)?):
            guard let items = raw as? [Any], items.count == lo.count else {
                throw fail("edit.value", "must be a \(lo.count)-vector")
            }
            value = .vector(try items.enumerated().map { i, item in
                guard let v = number(item), v >= lo[i], v <= hi[i] else {
                    throw fail("edit.value[\(i)]", "must be a finite number in [\(lo[i]), \(hi[i])]")
                }
                return v
            })
        case (.boolean, _, _):
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw fail("edit.value", "must be a boolean")
            }
            value = .boolean(n.boolValue)
        default:  // .enum (a decoded manifest guarantees number/vector bounds)
            guard let v = raw as? String, d.choices.contains(where: { sameScalars($0, v) }) else {
                throw fail("edit.value", "must be one of the descriptor choices")
            }
            value = .choice(v)
        }
        return EnvironmentEdit(schemaVersion: schemaVersion, propertyID: propertyID, targetID: targetID,
                               expectedRevision: Int(revision), unit: unit, value: value)
    }
}

/// Backend ACK detail for `edit_property`: applied value/revision, or the
/// rejection path. `currentRevision` accompanies a stale-revision rejection.
/// V6.6: `previousValue` is the owner value the edit replaced (the undo
/// inverse); `transaction` is "paused" for an edit applied while paused.
struct EnvironmentEditResult: Decodable, Equatable {
    let ok: Bool
    let status: String
    let propertyID: String?
    let targetID: String?
    let actualValue: EnvironmentPropertyValue?
    let revision: Int?
    let path: String?
    let reason: String?
    let currentRevision: Int?
    var previousValue: EnvironmentPropertyValue? = nil
    var transaction: String? = nil

    enum CodingKeys: String, CodingKey {
        case ok, status, revision, path, reason, transaction
        case propertyID = "property_id", targetID = "target_id"
        case actualValue = "actual_value", currentRevision = "current_revision"
        case previousValue = "previous_value"
    }
}
