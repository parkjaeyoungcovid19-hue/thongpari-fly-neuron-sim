// NeuralGroupRegistry.swift — V7.4 functional group registry.
//
// A `GroupDefinition` names a set of neurons by FlyWire root ID, binds it to the
// dataset it was derived from, and says where the "this group does X" claim comes
// from. The registry is metadata over exact observation (NeuralObservation.swift):
// it never touches the simulation itself.
//
// Contract (docs/plans/VIRTUAL_FLY_LAB_V7_PLAN.md §4 GroupDefinition, §6):
// - `schema` neural_group.v1. Root IDs are canonical decimal JSON strings.
// - `dataset_hash` is the manifest's neurons.bin sha256 (`Connectome.datasetHash`).
//   A definition whose hash differs from the loaded dataset, that names a root ID
//   the dataset lacks, or that has no members is DISABLED with a reason. A disabled
//   group has no members and no observation — never a 0 Hz.
// - Categories are exactly arousal / threat_related / motor / sensory /
//   unclassified. Nothing else (no drive/emotion categories) can decode.
//   `arousal` has no registered group: the simulator's arousal readout is the
//   rate of the whole role=other population (BrainSignals.arousal), which is
//   unclassified, not an identified arousal circuit. The registry says so.
// - Nesting: `parent_ids`; every member of a child must be a member of each parent
//   (checked on the root-ID sets, so it also holds for a disabled group).
//   Groups overlap by design; an overlapping neuron counts in each group.
// - Exact observation: a group is observable only while enabled and at most
//   `ObservationCapability.exactSelectionLimit` members. Larger groups are
//   reported unavailable — never a truncated/sampled substitute.

import Foundation

enum GroupRegistryCapability {
    static let schema = "neural_group.v1"
    /// The rate definition of NeuralObservation.rate_hz_per_neuron.
    static let normalizationVersion = "rate_hz_per_neuron.v1"
}

enum GroupCategory: String, Codable, CaseIterable {
    case arousal, threatRelated = "threat_related", motor, sensory, unclassified
}

/// How strongly the membership/role claim is backed.
enum GroupEvidenceTier: String, Codable {
    /// Membership is an exact FlyWire v783 cell-type label; the functional role is
    /// this simulator's modeled readout of that type.
    case annotatedCellType = "annotated_cell_type"
    /// Membership was chosen by the ETL from connectivity (strongest partners of
    /// the core populations), not by an identified functional type.
    case modelSelected = "model_selected"
    /// No functional claim: whatever no registered group claims.
    case residual
}

/// What a baseline comparison may use (consumed from V7.5 on).
enum GroupBaselinePolicy: String, Codable {
    /// The group's own exact pre-event window; no external constant.
    case preEventWindow = "pre_event_window"
    case none
}

struct GroupText: Codable, Equatable {
    var en: String
    var ko: String
}

struct GroupMembership: Codable, Equatable {
    /// Canonical decimal root IDs, distinct.
    var rootIDs: [String]
    /// Human-readable rule the IDs were derived from (documentation, not executed).
    var query: String

    enum CodingKeys: String, CodingKey { case rootIDs = "root_ids", query }
}

struct GroupDefinition: Codable, Equatable {
    var schema = GroupRegistryCapability.schema
    var groupID: String
    var datasetHash: String
    var membership: GroupMembership
    var labels: GroupText
    var category: GroupCategory
    var evidenceSource: GroupText
    var evidenceTier: GroupEvidenceTier
    var baselinePolicy: GroupBaselinePolicy
    var normalizationVersion = GroupRegistryCapability.normalizationVersion
    var parentIDs: [String]

    enum CodingKeys: String, CodingKey {
        case schema, membership, labels, category
        case groupID = "group_id", datasetHash = "dataset_hash", evidenceSource = "evidence_source"
        case evidenceTier = "evidence_tier", baselinePolicy = "baseline_policy"
        case normalizationVersion = "normalization_version", parentIDs = "parent_ids"
    }

    static func isCanonicalRootID(_ s: String) -> Bool { UInt64(s).map { String($0) == s } ?? false }
    static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Strict decode: every field is required; the schema and normalization
    /// version must be the known ones; the category/tier/policy must be known
    /// values; root IDs canonical and distinct; the hash a lowercase sha256.
    /// A well-formed definition for ANOTHER dataset still decodes — validating it
    /// against the loaded data is `GroupRegistry`'s job.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        groupID = try c.decode(String.self, forKey: .groupID)
        datasetHash = try c.decode(String.self, forKey: .datasetHash)
        membership = try c.decode(GroupMembership.self, forKey: .membership)
        labels = try c.decode(GroupText.self, forKey: .labels)
        category = try c.decode(GroupCategory.self, forKey: .category)
        evidenceSource = try c.decode(GroupText.self, forKey: .evidenceSource)
        evidenceTier = try c.decode(GroupEvidenceTier.self, forKey: .evidenceTier)
        baselinePolicy = try c.decode(GroupBaselinePolicy.self, forKey: .baselinePolicy)
        normalizationVersion = try c.decode(String.self, forKey: .normalizationVersion)
        parentIDs = try c.decode([String].self, forKey: .parentIDs)
        func fail(_ why: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: c.codingPath, debugDescription: why))
        }
        guard schema == GroupRegistryCapability.schema else { throw fail("schema \(schema)") }
        guard normalizationVersion == GroupRegistryCapability.normalizationVersion else {
            throw fail("normalization_version \(normalizationVersion)")
        }
        guard !groupID.isEmpty, groupID.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 }) else {
            throw fail("group_id must be non-empty lowercase [a-z0-9._]")
        }
        guard Self.isSHA256(datasetHash) else { throw fail("dataset_hash must be a lowercase sha256") }
        guard membership.rootIDs.allSatisfy(Self.isCanonicalRootID),
              Set(membership.rootIDs).count == membership.rootIDs.count else {
            throw fail("membership.root_ids must be distinct canonical decimal strings")
        }
        guard !membership.query.isEmpty, !labels.en.isEmpty, !labels.ko.isEmpty,
              !evidenceSource.en.isEmpty, !evidenceSource.ko.isEmpty else {
            throw fail("query, labels and evidence_source must be non-empty")
        }
        guard !parentIDs.contains(groupID), Set(parentIDs).count == parentIDs.count,
              !parentIDs.contains("") else { throw fail("parent_ids must be distinct ids other than the group itself") }
    }

    init(groupID: String, datasetHash: String, membership: GroupMembership, labels: GroupText,
         category: GroupCategory, evidenceSource: GroupText, evidenceTier: GroupEvidenceTier,
         baselinePolicy: GroupBaselinePolicy = .preEventWindow, parentIDs: [String] = []) {
        self.groupID = groupID; self.datasetHash = datasetHash; self.membership = membership
        self.labels = labels; self.category = category; self.evidenceSource = evidenceSource
        self.evidenceTier = evidenceTier; self.baselinePolicy = baselinePolicy; self.parentIDs = parentIDs
    }
}

/// The loaded dataset a definition is validated against.
struct GroupDataset {
    let hash: String
    let rootIDs: [UInt64]
    private let indexOf: [UInt64: Int]

    init(hash: String, rootIDs: [UInt64]) {
        self.hash = hash; self.rootIDs = rootIDs
        indexOf = Dictionary(rootIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Neuron index of a canonical decimal root ID, nil when absent or malformed.
    func index(of rootID: String) -> Int? {
        guard GroupDefinition.isCanonicalRootID(rootID), let id = UInt64(rootID) else { return nil }
        return indexOf[id]
    }
}

enum GroupDisableReason: Equatable, CustomStringConvertible {
    case datasetMismatch(bound: String, loaded: String)
    case unknownRootIDs(count: Int, first: String)
    case noMembers

    var description: String {
        switch self {
        case let .datasetMismatch(b, l): return "dataset hash mismatch (group \(b.prefix(12))…, loaded \(l.prefix(12))…)"
        case let .unknownRootIDs(n, f): return "\(n) root ID(s) not in the loaded dataset (first \(f))"
        case .noMembers: return "no members"
        }
    }
}

enum GroupStatus: Equatable {
    /// `members` are neuron indices in the root-ID order of the definition.
    case enabled(members: [Int])
    case disabled(GroupDisableReason)
}

enum GroupObservability: Equatable {
    case exact(members: Int)
    /// Too many members for the exact path; no truncated substitute is offered.
    case overLimit(members: Int, limit: Int)
    case unsupported(GroupDisableReason)
    var canArm: Bool { if case .exact = self { return true } else { return false } }
}

enum GroupObservationError: Error, Equatable, CustomStringConvertible {
    case unknownGroup(String)
    case disabled(GroupDisableReason)
    case overLimit(members: Int, limit: Int)
    case noSimulation

    var description: String {
        switch self {
        case let .unknownGroup(g): return "unknown group \(g)"
        case let .disabled(r): return "group disabled: \(r)"
        case let .overLimit(n, l): return "exact observation unavailable (\(n) > \(l))"
        case .noSimulation: return "the brain model is not loaded"
        }
    }
}

enum GroupRegistryError: Error, Equatable, CustomStringConvertible {
    case duplicateID(String)
    case unknownParent(child: String, parent: String)
    case notSubset(child: String, parent: String)
    case cycle(String)

    var description: String {
        switch self {
        case let .duplicateID(g): return "duplicate group_id \(g)"
        case let .unknownParent(c, p): return "\(c): parent \(p) is not registered"
        case let .notSubset(c, p): return "\(c) has members that \(p) lacks (nesting must be child ⊆ parent)"
        case let .cycle(g): return "nesting cycle through \(g)"
        }
    }
}

/// Registered groups, validated against one dataset. Value type: no GPU, no locks.
struct GroupRegistry {
    let dataset: GroupDataset
    /// Registration order (parents before children for the built-in set).
    let definitions: [GroupDefinition]
    private let statuses: [String: GroupStatus]
    /// Distinct member count per enabled group, counted once (the UI asks often).
    private let distinctCounts: [String: Int]
    /// Set when the built-in registry could not be built; the UI shows it.
    private(set) var buildError: String?

    /// Throws on duplicate ids, a parent that is not registered, a child that is
    /// not a subset of a parent, or a nesting cycle.
    init(definitions: [GroupDefinition], dataset: GroupDataset) throws {
        var byID: [String: GroupDefinition] = [:]
        for d in definitions {
            guard byID.updateValue(d, forKey: d.groupID) == nil else { throw GroupRegistryError.duplicateID(d.groupID) }
        }
        for d in definitions {
            let ids = Set(d.membership.rootIDs)
            for p in d.parentIDs {
                guard let parent = byID[p] else { throw GroupRegistryError.unknownParent(child: d.groupID, parent: p) }
                guard ids.isSubset(of: Set(parent.membership.rootIDs)) else {
                    throw GroupRegistryError.notSubset(child: d.groupID, parent: p)
                }
            }
        }
        for d in definitions {   // depth-first: a path that returns to its start is a cycle
            var stack = d.parentIDs, seen = Set<String>()
            while let g = stack.popLast() {
                if g == d.groupID { throw GroupRegistryError.cycle(d.groupID) }
                if seen.insert(g).inserted { stack += byID[g]?.parentIDs ?? [] }
            }
        }
        self.dataset = dataset
        self.definitions = definitions
        statuses = Dictionary(uniqueKeysWithValues: definitions.map { ($0.groupID, Self.resolve($0, in: dataset)) })
        distinctCounts = statuses.compactMapValues { if case .enabled(let m) = $0 { return Set(m).count } else { return nil } }
    }

    /// Hash first, then root IDs, then emptiness: the order of plan §6.
    static func resolve(_ d: GroupDefinition, in ds: GroupDataset) -> GroupStatus {
        guard d.datasetHash == ds.hash else {
            return .disabled(.datasetMismatch(bound: d.datasetHash, loaded: ds.hash))
        }
        let ids = d.membership.rootIDs
        guard !ids.isEmpty else { return .disabled(.noMembers) }
        let members = ids.map { ds.index(of: $0) }
        if let bad = members.firstIndex(where: { $0 == nil }) {
            return .disabled(.unknownRootIDs(count: members.filter { $0 == nil }.count, first: ids[bad]))
        }
        return .enabled(members: members.map { $0! })
    }

    func definition(_ id: String) -> GroupDefinition? { definitions.first { $0.groupID == id } }
    func status(_ id: String) -> GroupStatus? { statuses[id] }
    /// Neuron indices of an ENABLED group; nil for unknown or disabled ones.
    func members(_ id: String) -> [Int]? {
        if case .enabled(let m)? = statuses[id] { return m }
        return nil
    }
    func groups(in category: GroupCategory) -> [GroupDefinition] { definitions.filter { $0.category == category } }
    func parents(of id: String) -> [GroupDefinition] { (definition(id)?.parentIDs ?? []).compactMap(definition) }
    func children(of id: String) -> [GroupDefinition] { definitions.filter { $0.parentIDs.contains(id) } }

    /// Whether the group's members can be observed exactly right now.
    func observability(_ id: String, limit: Int = ObservationCapability.exactSelectionLimit) -> GroupObservability? {
        switch statuses[id] {
        case nil: return nil
        case .disabled(let r)?: return .unsupported(r)
        case .enabled?:
            let n = distinctCounts[id] ?? 0
            return n <= limit ? .exact(members: n) : .overLimit(members: n, limit: limit)
        }
    }

    /// The exact selection that observes this group as a whole, or why not.
    /// Never a subset: over the limit is an error, not a truncation.
    func armPlan(_ id: String, limit: Int = ObservationCapability.exactSelectionLimit)
        -> Result<[Int], GroupObservationError> {
        switch statuses[id] {
        case nil: return .failure(.unknownGroup(id))
        case .disabled(let r)?: return .failure(.disabled(r))
        case .enabled(let m)?:
            let distinct = Array(Set(m)).sorted()
            return distinct.count <= limit ? .success(distinct)
                                           : .failure(.overLimit(members: distinct.count, limit: limit))
        }
    }

    /// Enabled groups every one of whose members is in `selection` (the current
    /// exact selection). Observing such a group is a pure subset query on the
    /// armed selection — the V7.5 event buffer uses this after merging selections.
    func groups(fullyCoveredBy selection: [Int]) -> [GroupDefinition] {
        let s = Set(selection)
        return definitions.filter {
            if case .enabled(let m)? = statuses[$0.groupID] { return !m.isEmpty && m.allSatisfy(s.contains) }
            return false
        }
    }

    enum CategoryStatus: Equatable {
        case populated(groups: Int)
        /// A category the registry knows but for which it claims no group.
        case noRegisteredGroup
    }
    func categoryStatus(_ c: GroupCategory) -> CategoryStatus {
        let n = groups(in: c).count
        return n > 0 ? .populated(groups: n) : .noRegisteredGroup
    }

    /// Why a category has no group, in both languages (nil when it has some).
    static func emptyCategoryNote(_ c: GroupCategory) -> GroupText? {
        guard c == .arousal else { return nil }
        return GroupText(
            en: "No registered group. The simulator's arousal index (BrainSignals.arousal = population rate / 10) is computed from the rate of the whole role=other population, which is unclassified; it is not an identified arousal circuit, so none is claimed.",
            ko: "등록된 그룹 없음. 시뮬레이터의 흥분도 지표(BrainSignals.arousal = 전체 발화율 / 10)는 분류되지 않은 role=other 전체 뉴런의 발화율로 계산한 값이며, 확인된 각성 회로가 아니므로 그룹으로 등록하지 않았습니다.")
    }

    fileprivate init(emptyFor dataset: GroupDataset, error: String) {
        self.dataset = dataset; definitions = []; statuses = [:]; distinctCounts = [:]; buildError = error
    }
}

// MARK: - Built-in registry

extension GroupRegistry {
    private struct Spec {
        let id: String
        /// NeuronGuide stimulus id whose `indices` (the arrays MetalSim fills) are the membership.
        let guide: String?
        let category: GroupCategory
        let tier: GroupEvidenceTier
        let query: String
        let evidence: GroupText
        var parents: [String] = []
        var labels: GroupText? = nil
    }

    private static let typeEN = "Membership: exact FlyWire v783 cell-type label (data/connectome.json). "
    private static let typeKO = "구성원: FlyWire v783 세포 유형 이름과 정확히 일치하는 뉴런. "
    private static let modelEN = " The functional role is this simulator's modeled readout, not a measured behavior."
    private static let modelKO = " 기능은 이 시뮬레이터가 모델링한 역할이며 실측된 행동이 아닙니다."
    private static func typed(_ en: String, _ ko: String) -> GroupText {
        GroupText(en: typeEN + en + modelEN, ko: typeKO + ko + modelKO)
    }

    /// Registered in this order, parents before children. Every membership comes
    /// from `NeuronGuide.group(stimulusID:).indices(sim)` — the arrays MetalSim
    /// builds from the connectome — except the two derived groups below.
    private static let specs: [Spec] = [
        // threat-related
        Spec(id: "threat.looming", guide: "LC4/LPLC2", category: .threatRelated, tier: .annotatedCellType,
             query: "role=lc4|lplc2",
             evidence: typed("LC4 (104) and LPLC2 (210) of both eyes. Threat-related because the simulator uses them as the looming input that excites the giant fiber and drives the nervous index.",
                             "양쪽 눈의 LC4(104개)와 LPLC2(210개). 시뮬레이터에서 다가오는 물체 입력으로 쓰여 거대섬유를 흥분시키고 ‘긴장’ 지표를 만들기 때문에 위협 관련으로 분류했습니다.")),
        Spec(id: "threat.looming.left", guide: "LC4/LPLC2-left", category: .threatRelated, tier: .annotatedCellType,
             query: "role=lc4|lplc2 & side=left",
             evidence: typed("The left-eye half of threat.looming (child, subset).", "threat.looming 중 왼쪽 눈 쪽 (하위, 부분집합)."),
             parents: ["threat.looming"]),
        Spec(id: "threat.looming.right", guide: "LC4/LPLC2-right", category: .threatRelated, tier: .annotatedCellType,
             query: "role=lc4|lplc2 & side!=left",
             evidence: typed("The right-eye half of threat.looming (child, subset); a neuron with no recorded side counts here, as in MetalSim.",
                             "threat.looming 중 오른쪽 눈 쪽 (하위, 부분집합). 좌우 정보가 없는 뉴런은 MetalSim과 같이 여기에 포함됩니다."),
             parents: ["threat.looming"]),
        Spec(id: "threat.gf", guide: "GF", category: .threatRelated, tier: .annotatedCellType,
             query: "role=gf (cell_type=DNp01)",
             evidence: typed("Giant fiber DNp01 (2). Threat-related because a GF spike is the escape-takeoff trigger and the looming detectors drive it; it is also a descending command neuron, so it is nested under motor.command_dns and appears under both categories.",
                             "거대섬유 DNp01(2개). GF 발화가 탈출 이륙의 신호이고 다가오는 물체 감지 뉴런이 이를 자극하므로 위협 관련입니다. 동시에 뇌에서 몸으로 내려가는 명령 뉴런이라 motor.command_dns의 하위로 두어 두 범주에 모두 나타납니다."),
             parents: ["motor.command_dns"]),
        // motor
        Spec(id: "motor.command_dns", guide: nil, category: .motor, tier: .annotatedCellType,
             query: "role=gf|dna01|dna02|dnp09|dng11|mdn|escw",
             evidence: typed("Every command descending neuron the simulator reads: GF, DNa01/02, DNp09, DNg11, MDN, DNp02/04/11 (24). Parent of the motor and escape groups below.",
                             "시뮬레이터가 읽는 모든 명령 하행 뉴런: GF, DNa01/02, DNp09, DNg11, MDN, DNp02/04/11 (24개). 아래 운동·탈출 그룹의 상위 그룹입니다."),
             labels: GroupText(en: "Command descending neurons (all modeled)", ko: "명령 하행 뉴런 (모델에 쓰인 전체)")),
        Spec(id: "motor.dna.left", guide: "DNa-left", category: .motor, tier: .annotatedCellType,
             query: "role=dna01|dna02 & side=left",
             evidence: typed("DNa01 + DNa02, left side. Steering: the left−right rate difference sets the turn bias.",
                             "DNa01 + DNa02 왼쪽. 좌우 발화율 차이가 회전 방향 입력이 됩니다."),
             parents: ["motor.command_dns"]),
        Spec(id: "motor.dna.right", guide: "DNa-right", category: .motor, tier: .annotatedCellType,
             query: "role=dna01|dna02 & side!=left",
             evidence: typed("DNa01 + DNa02, right side (and any without a recorded side).",
                             "DNa01 + DNa02 오른쪽 (좌우 정보가 없는 뉴런 포함)."),
             parents: ["motor.command_dns"]),
        Spec(id: "motor.mdn", guide: "MDN", category: .motor, tier: .annotatedCellType,
             query: "role=mdn (cell_type=MDN)",
             evidence: typed("Moonwalker descending neurons (4); a strong burst is read as backward walking.",
                             "문워커 하행 뉴런(4개). 강한 발화를 뒤로 걷기로 읽습니다."),
             parents: ["motor.command_dns"]),
        Spec(id: "motor.dnp09", guide: "DNp09", category: .motor, tier: .annotatedCellType,
             query: "role=dnp09 (cell_type=DNp09)",
             evidence: typed("DNp09 (2); its rate sets whether the fly walks and how fast.",
                             "DNp09(2개). 발화율이 걷기 여부와 속도를 정합니다."),
             parents: ["motor.command_dns"]),
        Spec(id: "motor.dng11", guide: "DNg11", category: .motor, tier: .annotatedCellType,
             query: "role=dng11 (cell_type=DNg11)",
             evidence: typed("DNg11 (6); its rate sets the grooming drive.", "DNg11(6개). 발화율이 그루밍 정도를 정합니다."),
             parents: ["motor.command_dns"]),
        Spec(id: "motor.escape_wings", guide: "escW", category: .motor, tier: .annotatedCellType,
             query: "role=escw (cell_type=DNp02|DNp04|DNp11)",
             evidence: typed("Loom-responsive escape-maneuver descending neurons DNp02/04/11 (6): wing-beat effort in flight and the threat wing-raise. Classed as motor (wing output); nested under motor.command_dns only.",
                             "다가오는 물체에 반응하는 탈출 동작 하행 뉴런 DNp02/04/11(6개): 비행 중 날갯짓 세기와 위협 시 날개 들기. 날개 출력이므로 운동으로 분류하고 motor.command_dns 하위에만 둡니다."),
             parents: ["motor.command_dns"]),
        // sensory
        Spec(id: "sensory.ascending", guide: "ascend", category: .sensory, tier: .modelSelected,
             query: "role=ascend (24 strongest ascending-class partners of the core populations)",
             evidence: GroupText(
                en: "Membership: chosen by etl.py as the 24 ascending-class neurons exchanging the most synapses with the core populations (ties by root ID); not an identified functional type. The simulator feeds body-to-brain leg-gait input into them.",
                ko: "구성원: etl.py가 핵심 뉴런 집단과 시냅스를 가장 많이 주고받는 상행 뉴런 24개를 고른 것이며(동률은 root ID 순) 기능이 확인된 유형은 아닙니다. 시뮬레이터는 여기에 몸 → 뇌 다리 보행 입력을 넣습니다.")),
        Spec(id: "sensory.wind_touch", guide: "sens", category: .sensory, tier: .modelSelected,
             query: "role=sens (16 strongest sensory-class partners of the core populations)",
             evidence: GroupText(
                en: "Membership: chosen by etl.py as the 16 sensory-class neurons exchanging the most synapses with the core populations; not an identified functional type. The simulator uses them as the older generic wind/tap input.",
                ko: "구성원: etl.py가 핵심 뉴런 집단과 시냅스를 가장 많이 주고받는 감각 뉴런 16개를 고른 것이며 기능이 확인된 유형은 아닙니다. 시뮬레이터는 예전 방식의 바람·두드림 입력으로 씁니다.")),
        Spec(id: "sensory.odor_food.left", guide: "ORN-food-left", category: .sensory, tier: .annotatedCellType,
             query: "cell_type=ORN_DM1|ORN_VA2 & side=left",
             evidence: typed("Olfactory receptor neurons ORN_DM1 and ORN_VA2, left antenna; modeled as the food-odor input.",
                             "왼쪽 더듬이의 후각 수용 뉴런 ORN_DM1, ORN_VA2. 먹이 냄새 입력으로 모델링합니다.")),
        Spec(id: "sensory.odor_food.right", guide: "ORN-food-right", category: .sensory, tier: .annotatedCellType,
             query: "cell_type=ORN_DM1|ORN_VA2 & side=right",
             evidence: typed("Olfactory receptor neurons ORN_DM1 and ORN_VA2, right antenna.",
                             "오른쪽 더듬이의 후각 수용 뉴런 ORN_DM1, ORN_VA2.")),
        Spec(id: "sensory.thermo.warm", guide: "TRN-warm", category: .sensory, tier: .annotatedCellType,
             query: "cell_type=TRN_VP2",
             evidence: typed("Thermoreceptor neurons TRN_VP2; modeled as the warming input.", "온도 수용 뉴런 TRN_VP2. 따뜻함 입력으로 모델링합니다.")),
        Spec(id: "sensory.thermo.cool", guide: "TRN-cool", category: .sensory, tier: .annotatedCellType,
             query: "cell_type=TRN_VP3a|TRN_VP3b",
             evidence: typed("Thermoreceptor neurons TRN_VP3a/b; modeled as the cooling input.", "온도 수용 뉴런 TRN_VP3a/b. 차가움 입력으로 모델링합니다.")),
        Spec(id: "sensory.wind.jo_c", guide: "JO-C-wind", category: .sensory, tier: .annotatedCellType,
             query: "cell_type^=JO-C & out_degree>0",
             evidence: typed("Johnston's-organ JO-C cells with outgoing edges; modeled as the steady-wind antenna input.",
                             "출력 연결이 있는 존스턴 기관 JO-C 세포. 꾸준한 바람 더듬이 입력으로 모델링합니다.")),
        Spec(id: "sensory.wind.jo_e", guide: "JO-E-wind", category: .sensory, tier: .annotatedCellType,
             query: "cell_type^=JO-E & out_degree>0",
             evidence: typed("Johnston's-organ JO-E cells with outgoing edges; modeled as the second wind antenna input.",
                             "출력 연결이 있는 존스턴 기관 JO-E 세포. 두 번째 바람 더듬이 입력으로 모델링합니다.")),
        Spec(id: "sensory.humidity.dry", guide: "HRN-dry", category: .sensory, tier: .annotatedCellType,
             query: "cell_type=HRN_VP4",
             evidence: typed("Humidity receptor neurons HRN_VP4 (dry-air).", "습도 수용 뉴런 HRN_VP4 (건조함).")),
        Spec(id: "sensory.humidity.moist", guide: "HRN-moist", category: .sensory, tier: .annotatedCellType,
             query: "cell_type=HRN_VP5",
             evidence: typed("Humidity receptor neurons HRN_VP5 (moist-air).", "습도 수용 뉴런 HRN_VP5 (축축함).")),
    ]

    /// Built from the sim's own arrays (single source of membership) and its
    /// loaded dataset hash, then validated like any imported definition set.
    /// Never fails the app: a build error leaves an empty registry that says why.
    static func builtIn(sim: MetalSim) -> GroupRegistry {
        let dataset = GroupDataset(hash: sim.datasetHash, rootIDs: sim.rootIds)
        func ids(_ idx: [Int]) -> [String] { Array(Set(idx)).sorted().map { String(sim.rootIds[$0]) } }
        var defs: [GroupDefinition] = []
        var registered = Set<Int>()
        for s in specs {
            let idx = s.guide.flatMap { NeuronGuide.group(stimulusID: $0)?.indices(sim) }
                ?? (s.id == "motor.command_dns" ? sim.gf + sim.dnaL + sim.dnaR + sim.mdn + sim.fwd + sim.groom + sim.escw : [])
            registered.formUnion(idx)
            let guide = s.guide.flatMap { NeuronGuide.group(stimulusID: $0) }
            let labels = s.labels ?? GroupText(en: guide?.nameEN ?? s.id, ko: guide?.nameKO ?? s.id)
            defs.append(GroupDefinition(groupID: s.id, datasetHash: dataset.hash,
                                        membership: GroupMembership(rootIDs: ids(idx), query: s.query),
                                        labels: labels, category: s.category, evidenceSource: s.evidence,
                                        evidenceTier: s.tier, parentIDs: s.parents))
        }
        // Everything the role table leaves as `other` that no group above claims.
        let rest = (0..<sim.n).filter { sim.roles[$0] == "other" && !registered.contains($0) }
        defs.append(GroupDefinition(
            groupID: "unclassified.other", datasetHash: dataset.hash,
            membership: GroupMembership(rootIDs: ids(rest), query: "role=other, not a member of any registered group"),
            labels: GroupText(en: "Unclassified (everything else)", ko: "분류되지 않음 (나머지 전체)"),
            category: .unclassified,
            evidenceSource: GroupText(
                en: "The role=other population of the shipped connectome, minus the receptor groups registered above (those are role=other in the ETL table but identified by cell type). No functional claim is made. The simulator's arousal index is the rate of the whole role=other population; that does not make these neurons arousal neurons.",
                ko: "배포된 연결체에서 role=other인 뉴런 전체에서 위에 등록한 수용 뉴런 그룹(ETL 표에서는 role=other이지만 세포 유형으로 식별됨)을 뺀 나머지입니다. 기능에 대한 주장은 하지 않습니다. 시뮬레이터의 흥분도 지표는 role=other 전체의 발화율이지만 이 뉴런들을 각성 뉴런이라고 부르는 것은 아닙니다."),
            evidenceTier: .residual, baselinePolicy: .none))
        do { return try GroupRegistry(definitions: defs, dataset: dataset) }
        catch { return GroupRegistry(emptyFor: dataset, error: "\(error)") }
    }
}
