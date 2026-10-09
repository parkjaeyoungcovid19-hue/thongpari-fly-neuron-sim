#if DIAGNOSTICS
// --registrytest: V7.4 functional group registry.
// Expected memberships are recomputed here straight from the connectome's own
// tables (role ids, cell-type names, side, out-degree, root IDs) — never through
// the registry, NeuronGuide or MetalSim's group arrays. Bad definitions are
// built by mutating the registry's own JSON, so a fixture can only fail for the
// reason the mutation names.
import Cocoa

func runRegistryTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check(name, ok, detail) }
    guard let c = loadConnectome(), let sim = makeDiagSim(connectome: c) else { print("no sim"); exit(1) }
    let reg = sim.groupRegistry
    let n = c.n
    check("built-in registry builds from the loaded data", reg.buildError == nil && reg.definitions.count >= 20,
          "\(reg.definitions.count) groups \(reg.buildError ?? "")")

    // ---- independent recomputation from the connectome tables -------------------
    func set(_ pred: (Int) -> Bool) -> [Int] { (0..<n).filter(pred) }
    let role = c.role, type = c.typeName, side = c.side
    func isRole(_ i: Int, _ rs: UInt8...) -> Bool { rs.contains(role[i]) }
    func hasOut(_ i: Int) -> Bool { c.rowStart[i + 1] > c.rowStart[i] }
    let loom = { (i: Int) in isRole(i, Role.lc4, Role.lplc2) }
    let command = { (i: Int) in isRole(i, Role.gf, Role.dna01, Role.dna02, Role.dnp09, Role.dng11, Role.mdn, Role.escw) }
    var expected: [String: [Int]] = [
        "threat.looming": set(loom),
        "threat.looming.left": set { loom($0) && side[$0] == 1 },
        "threat.looming.right": set { loom($0) && side[$0] != 1 },
        "threat.gf": set { isRole($0, Role.gf) },
        "motor.command_dns": set(command),
        "motor.dna.left": set { isRole($0, Role.dna01, Role.dna02) && side[$0] == 1 },
        "motor.dna.right": set { isRole($0, Role.dna01, Role.dna02) && side[$0] != 1 },
        "motor.mdn": set { isRole($0, Role.mdn) },
        "motor.dnp09": set { isRole($0, Role.dnp09) },
        "motor.dng11": set { isRole($0, Role.dng11) },
        "motor.escape_wings": set { isRole($0, Role.escw) },
        "sensory.ascending": set { isRole($0, Role.ascend) },
        "sensory.wind_touch": set { isRole($0, Role.sens) },
        "sensory.odor_food.left": set { (type[$0] == "ORN_DM1" || type[$0] == "ORN_VA2") && side[$0] == 1 },
        "sensory.odor_food.right": set { (type[$0] == "ORN_DM1" || type[$0] == "ORN_VA2") && side[$0] == 2 },
        "sensory.thermo.warm": set { type[$0] == "TRN_VP2" },
        "sensory.thermo.cool": set { type[$0] == "TRN_VP3a" || type[$0] == "TRN_VP3b" },
        "sensory.wind.jo_c": set { type[$0].hasPrefix("JO-C") && hasOut($0) },
        "sensory.wind.jo_e": set { type[$0].hasPrefix("JO-E") && hasOut($0) },
        "sensory.humidity.dry": set { type[$0] == "HRN_VP4" },
        "sensory.humidity.moist": set { type[$0] == "HRN_VP5" },
    ]
    let claimed = Set(expected.values.joined())
    expected["unclassified.other"] = set { role[$0] == Role.other && !claimed.contains($0) }

    var bad: [String] = []
    for (id, want) in expected.sorted(by: { $0.key < $1.key }) {
        let got = reg.members(id) ?? []
        let ids = reg.definition(id)?.membership.rootIDs ?? []
        if got.sorted() != want || ids != want.map({ String(c.rootId[$0]) }) || want.isEmpty { bad.append("\(id) \(got.count)≠\(want.count)") }
    }
    check("membership equals the independent recomputation for all \(expected.count) groups (indices and root IDs)",
          bad.isEmpty && Set(reg.definitions.map(\.groupID)) == Set(expected.keys), bad.joined(separator: "; "))
    // A second, separate derivation: the cell-type table must agree with the role table.
    func typed(_ names: Set<String>) -> [Int] { set { names.contains(type[$0]) } }
    check("role table and cell-type table agree (GF=DNp01, MDN, DNp09, DNg11, escape wings=DNp02/04/11, LC4/LPLC2)",
          expected["threat.gf"] == typed(["DNp01"]) && expected["motor.mdn"] == typed(["MDN"])
            && expected["motor.dnp09"] == typed(["DNp09"]) && expected["motor.dng11"] == typed(["DNg11"])
            && expected["motor.escape_wings"] == typed(["DNp02", "DNp04", "DNp11"])
            && expected["threat.looming"] == typed(["LC4", "LPLC2"]),
          "gf \(expected["threat.gf"]!.count) vs \(typed(["DNp01"]).count)")
    let roleOther = n - c.roleIndices.reduce(0) { $0 + $1.count }
    let receptors = Set(expected.filter { $0.key.hasPrefix("sensory.") && $0.key != "sensory.ascending" && $0.key != "sensory.wind_touch" }.values.joined())
    check("counts tie to the manifest: looming = lc4+lplc2, command DNs = 24, unclassified + receptors = role other",
          expected["threat.looming"]!.count == c.roleIndices[Int(Role.lc4)].count + c.roleIndices[Int(Role.lplc2)].count
            && expected["motor.command_dns"]!.count == [Role.gf, Role.dna01, Role.dna02, Role.dnp09, Role.dng11, Role.mdn, Role.escw].reduce(0) { $0 + c.roleIndices[Int($1)].count }
            && expected["unclassified.other"]!.count + receptors.count == roleOther && receptors.allSatisfy({ role[$0] == Role.other }),
          "unclassified \(expected["unclassified.other"]!.count) receptors \(receptors.count) other \(roleOther)")
    check("no neuron is both unclassified and in a registered group",
          Set(reg.members("unclassified.other") ?? []).isDisjoint(with: claimed))

    // ---- categories ---------------------------------------------------------------
    check("categories are exactly arousal, threat_related, motor, sensory, unclassified",
          GroupCategory.allCases.map(\.rawValue) == ["arousal", "threat_related", "motor", "sensory", "unclassified"])
    for cat in GroupCategory.allCases where cat != .arousal {
        check("category \(cat.rawValue) has registered groups", reg.categoryStatus(cat) != .noRegisteredGroup && !reg.groups(in: cat).isEmpty)
    }
    check("arousal has no registered group and says why (rate of the unclassified population)",
          reg.categoryStatus(.arousal) == .noRegisteredGroup && reg.groups(in: .arousal).isEmpty
            && GroupRegistry.emptyCategoryNote(.arousal)?.en.contains("role=other") == true
            && GroupRegistry.emptyCategoryNote(.arousal)?.ko.isEmpty == false
            && GroupRegistry.emptyCategoryNote(.motor) == nil)
    check("every non-arousal category is populated; the unclassified group is category unclassified, not arousal",
          reg.definition("unclassified.other")?.category == .unclassified && reg.definition("unclassified.other")?.evidenceTier == .residual
            && reg.definition("unclassified.other")?.baselinePolicy == GroupBaselinePolicy.none)
    let forbidden = ["hunger", "thirst", "emotion", "desire", "mood", "배고", "갈증", "감정", "욕구"]
    let allText = reg.definitions.map { [$0.groupID, $0.labels.en, $0.labels.ko, $0.evidenceSource.en, $0.evidenceSource.ko, $0.membership.query].joined(separator: " ").lowercased() }
    check("no hunger/thirst/emotion/desire wording in any registered group",
          !allText.contains { t in forbidden.contains { t.contains($0) } })
    check("GF sits under threat_related and (as a command DN) under motor, with the reasoning in its evidence",
          reg.definition("threat.gf")?.category == .threatRelated
            && reg.parents(of: "threat.gf").map(\.groupID) == ["motor.command_dns"]
            && reg.parents(of: "threat.gf").first?.category == .motor
            && reg.definition("threat.gf")?.evidenceSource.en.contains("motor.command_dns") == true)
    check("tiers: type-labelled groups are annotated, partner-selected ascend/sens are model_selected",
          reg.definition("motor.mdn")?.evidenceTier == .annotatedCellType
            && reg.definition("sensory.ascending")?.evidenceTier == .modelSelected
            && reg.definition("sensory.wind_touch")?.evidenceTier == .modelSelected
            && reg.definitions.allSatisfy { $0.datasetHash == c.datasetHash })

    // ---- nesting ---------------------------------------------------------------------
    var nestBad: [String] = []
    for d in reg.definitions {
        let mine = Set(d.membership.rootIDs)
        for p in d.parentIDs {
            guard let parent = reg.definition(p) else { nestBad.append("\(d.groupID)→\(p) missing"); continue }
            if !mine.isSubset(of: Set(parent.membership.rootIDs)) { nestBad.append("\(d.groupID) ⊄ \(p)") }
        }
    }
    let kids = ["threat.looming.left", "threat.looming.right"].map { Set(expected[$0]!) }
    check("nesting consistency: every child is a subset of every parent; looming eyes partition the parent",
          nestBad.isEmpty && !reg.definitions.allSatisfy { $0.parentIDs.isEmpty }
            && kids[0].isDisjoint(with: kids[1]) && kids[0].union(kids[1]) == Set(expected["threat.looming"]!),
          nestBad.joined(separator: "; "))
    func mutated(_ id: String, _ f: (inout GroupDefinition) -> Void) -> GroupDefinition { var d = reg.definition(id)!; f(&d); return d }
    func buildError(_ defs: [GroupDefinition]) -> GroupRegistryError? {
        do { _ = try GroupRegistry(definitions: defs, dataset: GroupDataset(hash: c.datasetHash, rootIDs: c.rootId)); return nil }
        catch { return error as? GroupRegistryError }
    }
    let looming = reg.definition("threat.looming")!, gfDef = reg.definition("threat.gf")!
    check("nesting fixture: a child with a member its parent lacks is rejected",
          buildError([looming, mutated("threat.gf") { $0.parentIDs = ["threat.looming"] }]) == .notSubset(child: "threat.gf", parent: "threat.looming"))
    check("nesting fixture: an unregistered parent and a duplicate id are rejected",
          buildError([mutated("threat.gf") { $0.parentIDs = ["nope"] }]) == .unknownParent(child: "threat.gf", parent: "nope")
            && buildError([gfDef, gfDef]) == .duplicateID("threat.gf"))
    let a = mutated("threat.gf") { $0.groupID = "a.x"; $0.parentIDs = ["b.x"] }, b = mutated("threat.gf") { $0.groupID = "b.x"; $0.parentIDs = ["a.x"] }
    check("nesting fixture: a cycle is rejected", buildError([a, b]) == .cycle("a.x") || buildError([a, b]) == .cycle("b.x"))

    // ---- JSON ----------------------------------------------------------------------------
    let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
    var roundTrip = true
    for d in reg.definitions {
        let back = (try? enc.encode(d)).flatMap { try? JSONDecoder().decode(GroupDefinition.self, from: $0) }
        if back != d { roundTrip = false; print("  round trip failed: \(d.groupID)") }
    }
    check("JSON round trip is exact for every built-in definition", roundTrip)
    let all = try? enc.encode(reg.definitions)
    let decoded = all.flatMap { try? JSONDecoder().decode([GroupDefinition].self, from: $0) }
    let rebuilt = decoded.flatMap { try? GroupRegistry(definitions: $0, dataset: GroupDataset(hash: c.datasetHash, rootIDs: c.rootId)) }
    check("the whole registry survives encode → decode → rebuild with identical memberships",
          decoded == reg.definitions && reg.definitions.allSatisfy { rebuilt?.members($0.groupID) == reg.members($0.groupID) })
    let baseData = (try? enc.encode(gfDef)) ?? Data()
    let baseJSON = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] ?? [:]
    let membership = baseJSON["membership"] as? [String: Any] ?? [:]
    check("JSON carries schema, string root IDs, category as a string",
          baseJSON["schema"] as? String == "neural_group.v1" && membership["root_ids"] as? [String] == gfDef.membership.rootIDs
            && baseJSON["category"] as? String == "threat_related" && baseJSON["normalization_version"] as? String == "rate_hz_per_neuron.v1")
    func decodes(_ mutate: (inout [String: Any]) -> Void) -> GroupDefinition? {
        var obj = baseJSON; mutate(&obj)
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(GroupDefinition.self, from: d)
    }
    func nested(_ key: String, _ f: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { obj in var inner = obj[key] as? [String: Any] ?? [:]; f(&inner); obj[key] = inner }
    }
    check("control: the unmodified JSON decodes", decodes { _ in } == gfDef)
    var missing: [String] = []
    for key in baseJSON.keys where decodes({ $0[key] = nil }) != nil { missing.append(key) }
    check("bad fixture: removing any one top-level field fails decode (\(baseJSON.count) fields)", missing.isEmpty, "accepted without: \(missing)")
    check("bad fixture: nested required fields (membership.query, membership.root_ids, labels.ko, evidence_source.en) fail decode",
          decodes(nested("membership") { $0["query"] = nil }) == nil && decodes(nested("membership") { $0["root_ids"] = nil }) == nil
            && decodes(nested("labels") { $0["ko"] = nil }) == nil && decodes(nested("evidence_source") { $0["en"] = nil }) == nil)
    let realID = gfDef.membership.rootIDs[0]
    for (name, ids) in [("a JSON number", [720575940624963786] as [Any]), ("a leading '+'", ["+" + realID]),
                        ("a leading zero", ["0" + realID]), ("a decimal point", [realID + ".0"]), ("above UInt64", ["18446744073709551616"]),
                        ("whitespace", [" " + realID]), ("a duplicate", [realID, realID]), ("an empty string", [""])] {
        check("bad fixture: non-canonical root ID — \(name) — fails decode", decodes(nested("membership") { $0["root_ids"] = ids }) == nil)
    }
    for (name, cat) in [("hunger", "hunger"), ("thirst", "thirst"), ("emotion", "emotion"), ("the old role name", "other"), ("wrong case", "Motor")] {
        check("bad fixture: unknown category \(name) fails decode", decodes { $0["category"] = cat } == nil)
    }
    check("bad fixture: unknown tier/policy, wrong schema or normalization version, self-parent, malformed hash fail decode",
          decodes { $0["evidence_tier"] = "gospel" } == nil && decodes { $0["baseline_policy"] = "literature" } == nil
            && decodes { $0["schema"] = "neural_group.v0" } == nil && decodes { $0["normalization_version"] = "rate.v0" } == nil
            && decodes { $0["parent_ids"] = ["threat.gf"] } == nil && decodes { $0["dataset_hash"] = "ABC" } == nil
            && decodes { $0["dataset_hash"] = String(repeating: "A", count: 64) } == nil)

    // ---- dataset binding: well-formed but unusable definitions decode, then disable ----
    let dataset = GroupDataset(hash: c.datasetHash, rootIDs: c.rootId)
    let foreignHash = String(repeating: "a", count: 64)
    let mismatched = decodes { $0["dataset_hash"] = foreignHash }
    check("hash mismatch: a well-formed foreign-dataset definition decodes", mismatched != nil)
    let unknownRoot = decodes(nested("membership") { $0["root_ids"] = [realID, "1"] })
    let noMembers = decodes(nested("membership") { $0["root_ids"] = [] as [String] })
    check("root ID not in the dataset / zero members: well-formed, so they decode", unknownRoot != nil && noMembers != nil)
    let fixtures = [mismatched, unknownRoot, noMembers].compactMap { $0 }.enumerated().map { i, d -> GroupDefinition in
        var d = d; d.groupID = "fixture.\(i)"; d.parentIDs = []; return d
    }
    let gfRoot = mutated("threat.gf") { $0.parentIDs = [] }   // standalone: its parent is not part of this fixture set
    let fx = try? GroupRegistry(definitions: fixtures + [gfRoot], dataset: dataset)
    check("hash mismatch ⇒ disabled with a mismatch reason, no members, observation unsupported",
          fx?.status("fixture.0") == .disabled(.datasetMismatch(bound: foreignHash, loaded: c.datasetHash))
            && fx?.members("fixture.0") == nil
            && fx?.observability("fixture.0") == .unsupported(.datasetMismatch(bound: foreignHash, loaded: c.datasetHash))
            && fx?.armPlan("fixture.0") == .failure(.disabled(.datasetMismatch(bound: foreignHash, loaded: c.datasetHash))))
    check("a root ID missing from the dataset disables the WHOLE group (no partial membership)",
          fx?.status("fixture.1") == .disabled(.unknownRootIDs(count: 1, first: "1")) && fx?.members("fixture.1") == nil
            && fx?.observability("fixture.1")?.canArm == false)
    check("zero members ⇒ disabled (no member count of 0 reported as a rate)",
          fx?.status("fixture.2") == .disabled(.noMembers) && fx?.observability("fixture.2")?.canArm == false)
    check("control: the same group with a matching hash and real IDs is enabled and armable",
          fx?.status("threat.gf") == .enabled(members: expected["threat.gf"]!) && fx?.armPlan("threat.gf") == .success(expected["threat.gf"]!))
    check("disabled groups never count as covered, even when the selection holds every neuron",
          fx?.groups(fullyCoveredBy: Array(0..<n)).map(\.groupID) == ["threat.gf"])

    // ---- exact-observation limit -----------------------------------------------------------
    func synthetic(_ count: Int) -> GroupRegistry? {
        let d = GroupDefinition(groupID: "synthetic", datasetHash: c.datasetHash,
                                membership: GroupMembership(rootIDs: (0..<count).map { String(c.rootId[$0]) }, query: "first \(count) neurons"),
                                labels: GroupText(en: "s", ko: "s"), category: .unclassified,
                                evidenceSource: GroupText(en: "s", ko: "s"), evidenceTier: .residual)
        return try? GroupRegistry(definitions: [d], dataset: dataset)
    }
    check("limit boundary: 256 members are exact-observable, 257 are not (no truncation offered)",
          synthetic(256)?.observability("synthetic") == .exact(members: 256) && synthetic(256)?.armPlan("synthetic") == .success(Array(0..<256))
            && synthetic(257)?.observability("synthetic") == .overLimit(members: 257, limit: 256)
            && synthetic(257)?.armPlan("synthetic") == .failure(.overLimit(members: 257, limit: 256)))
    check("LC4+LPLC2 (\(expected["threat.looming"]!.count)) and unclassified are over the limit; their per-eye children and the command DNs are not",
          reg.observability("threat.looming") == .overLimit(members: expected["threat.looming"]!.count, limit: ObservationCapability.exactSelectionLimit)
            && reg.observability("unclassified.other")?.canArm == false
            && reg.observability("threat.looming.left")?.canArm == true && reg.observability("motor.command_dns")?.canArm == true,
          "left \(expected["threat.looming.left"]!.count) right \(expected["threat.looming.right"]!.count)")

    // ---- arming through the real app path -------------------------------------------------
    let coord = Coordinator(bounds: CGSize(width: 800, height: 600), sim: sim)
    func drain() { for action in coord.drainSimulationActions() { action(coord) } }
    let everyone = Array(0..<n)
    sim.step(5)
    let extBefore = sim.debugExternalInput(everyone), reqBefore = sim.directStimulationStatus().requests
    var armBad: [String] = [], armed = 0
    for d in reg.definitions {
        guard let want = expected[d.groupID], want.count <= sim.observer.limit else { continue }
        guard case .success(let count) = coord.observeGroup(d.groupID) else { armBad.append("\(d.groupID) refused"); continue }
        let pending = sim.observer.pending()
        drain(); sim.step(3)
        let sel = sim.observer.selection()
        if count != want.count || pending != d.labels.pick || sim.observer.pending() != nil || sel.neurons.sorted() != want
            || sel.omitted != 0 || sel.name != d.labels.pick { armBad.append(d.groupID) }
        armed += 1
    }
    check("arming each exact-observable group selects exactly its members (omitted 0), queued then applied (\(armed) groups)",
          armBad.isEmpty && armed >= 18, armBad.joined(separator: "; "))
    let gf = reg.definition("threat.gf")!.labels
    check("a group-armed selection name shows in the current language; other names pass through",
          reg.relabel(gf.en) == gf.pick && reg.relabel(gf.ko) == gf.pick && reg.relabel("brain pick 12") == "brain pick 12")
    check("arming groups issues no stimulation request and leaves extInput unchanged",
          sim.directStimulationStatus().requests == reqBefore && sim.debugExternalInput(everyone) == extBefore)
    _ = coord.observeGroup("threat.gf"); drain(); sim.step(10)
    let gfSel = sim.observer.selection()
    let gfObs = try? sim.observer.observe(groupID: "threat.gf", members: reg.members("threat.gf") ?? []).get()
    check("an armed group is read exactly: source exact, member count and observed ticks match the selection",
          gfObs?.source == .exact && gfObs?.memberCount == expected["threat.gf"]!.count && gfObs?.droppedSamples == 0
            && gfObs?.observedTicks == gfSel.lastTick - gfSel.firstTick + 1 && gfObs?.validity == .complete,
          "\(String(describing: gfObs?.observedTicks)) ticks")
    // over-limit groups are refused and leave the current selection alone
    let before = sim.observer.selection()
    let refused = ["threat.looming", "unclassified.other"].map { coord.observeGroup($0) }
    let pendingAfter = sim.observer.pending()
    drain(); sim.step(2)
    check("over-limit groups are refused (\(expected["threat.looming"]!.count) > 256): nothing queued, selection unchanged, never truncated",
          refused == [.failure(.overLimit(members: expected["threat.looming"]!.count, limit: 256)),
                      .failure(.overLimit(members: expected["unclassified.other"]!.count, limit: 256))]
            && pendingAfter == nil && sim.observer.selection().selectionID == before.selectionID
            && sim.observer.selection().neurons == before.neurons && sim.observer.selection().omitted == 0)
    check("a disabled or unknown group is refused the same way",
          coord.observeGroup("fixture.0", registry: fx) == .failure(.disabled(.datasetMismatch(bound: foreignHash, loaded: c.datasetHash)))
            && coord.observeGroup("nope") == .failure(.unknownGroup("nope")) && sim.observer.pending() == nil)

    // ---- groups(fullyCoveredBy:) ---------------------------------------------------------------
    func covered(_ sel: [Int]) -> Set<String> { Set(reg.groups(fullyCoveredBy: sel).map(\.groupID)) }
    func want(_ sel: [Int]) -> Set<String> { let s = Set(sel); return Set(expected.filter { !$0.value.isEmpty && Set($0.value).isSubset(of: s) }.keys) }
    let cmd = expected["motor.command_dns"]!
    check("fullyCoveredBy: the 24 command DNs cover the command parent, its children and the GF group — nothing else",
          covered(cmd) == want(cmd) && covered(cmd).contains("threat.gf") && covered(cmd).contains("motor.command_dns")
            && !covered(cmd).contains("threat.looming"), "\(covered(cmd).sorted())")
    let oneGF = [expected["threat.gf"]![0]]
    check("fullyCoveredBy: half of a group is not coverage; an empty selection covers nothing",
          covered(oneGF).isEmpty && covered([]).isEmpty && covered(expected["threat.gf"]!) == ["threat.gf"])
    check("fullyCoveredBy: left eye selected ⇒ the left-eye group only, not its parent or the right eye",
          covered(expected["threat.looming.left"]!) == ["threat.looming.left"])
    check("fullyCoveredBy: a selection beyond the limit still answers by subset (whole data covers every enabled group)",
          covered(everyone).count == reg.definitions.count)

    // ---- the Lab panel ----------------------------------------------------------------------------
    let pb = NSPasteboard.general, savedClipboard = pb.string(forType: .string)
    defer { pb.clearContents(); if let s = savedClipboard { pb.setString(s, forType: .string) } }
    let panel = GroupRegistryPanel(coordinator: coord)
    check("panel lists every category, arousal's honest empty state included, and a disabled placeholder row",
          GroupCategory.allCases.allSatisfy { panel.summaryText.contains($0.title) }
            && panel.summaryText.contains("No registered group") && panel.summaryText.contains("unclassified")
            && panel.picker.itemArray.contains { $0.title.contains("no registered group") && !$0.isEnabled })
    panel.select(groupID: "threat.looming")
    let shownIDs = panel.rootsText.split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { $0.allSatisfy(\.isNumber) && $0.count > 10 }
    let loomCount = expected["threat.looming"]!.count
    let first20: [String] = Array(looming.membership.rootIDs[0..<20])
    let shown: [String] = shownIDs.map { String($0) }
    let limitText = panel.statusText.contains("unavailable (\(loomCount) > 256)") && !panel.observeButton.isEnabled
    let idsText = shown.count == GroupRegistryPanel.visibleRootIDs && shown == first20
        && panel.rootsText.contains("+\(loomCount - 20) more") && panel.copyButton.isEnabled
    let detail = panel.detailText.contains("Category: Threat-related") && panel.detailText.contains("Dataset: OK")
        && panel.detailText.contains(looming.evidenceSource.en) && panel.detailText.contains("role=lc4|lplc2")
    check("panel over-limit group: states unavailable (314 > 256), button disabled", limitText)
    check("panel shows the first 20 root IDs, the remainder count and an enabled Copy-all", idsText)
    check("panel detail shows category, dataset status ok, evidence source and membership rule", detail)
    let before2 = sim.observer.selection()
    panel.observeSelected(); drain()
    check("panel: pressing Observe on an over-limit group arms nothing",
          sim.observer.selection().selectionID == before2.selectionID && panel.statusText.contains("unavailable"))
    panel.select(groupID: "motor.dna.left")
    check("panel nested group: shows parent, evidence tier, and an enabled Observe button",
          panel.observeButton.isEnabled && panel.detailText.contains("Nested in: Command descending neurons")
            && panel.detailText.contains("annotated cell type") && panel.statusText.contains("Exact observation available (\(expected["motor.dna.left"]!.count) ≤ 256)"))
    panel.observeSelected(); drain(); sim.step(2)
    panel.refresh()   // the Lab window's 0.5 s timer does this live
    check("panel: Observe arms the selection read-only and the panel reports the group as covered",
          sim.observer.selection().neurons.sorted() == expected["motor.dna.left"]! && panel.statusText.contains("already covers this whole group")
            && sim.directStimulationStatus().requests == reqBefore && sim.debugExternalInput(everyone) == extBefore)
    panel.select(groupID: "threat.gf")
    pb.clearContents(); panel.copyAllRootIDs()
    check("panel: Copy all puts every root ID on the clipboard", pb.string(forType: .string) == gfDef.membership.rootIDs.joined(separator: "\n"))
    panel.select(groupID: "unclassified.other")
    check("panel unclassified: shown, huge, honest (no arousal wording as a category)",
          panel.detailText.contains("Category: Unclassified") && panel.statusText.contains("unavailable") && !panel.observeButton.isEnabled
            && panel.rootsText.contains("more"))
    let panelFx = GroupRegistryPanel(coordinator: coord, registry: fx)
    panelFx.select(groupID: "fixture.0")
    check("panel disabled group: dataset MISMATCH and unsupported, never a 0 Hz; Observe off, status unknown",
          panelFx.detailText.contains("Dataset: MISMATCH") && panelFx.detailText.contains("status unknown")
            && panelFx.statusText.contains("unsupported") && !panelFx.observeButton.isEnabled)
    panelFx.select(groupID: "fixture.1")
    check("panel unknown-root-ID group says which ID is missing", panelFx.detailText.contains("not in the loaded dataset (first 1)") && !panelFx.observeButton.isEnabled)
    check("panels, arming and refusals never stimulated: requests and extInput identical to the start",
          sim.directStimulationStatus().requests == reqBefore && sim.debugExternalInput(everyone) == extBefore)
    print("\ngroup table (id · category · members · tier · exact observation)")
    for d in reg.definitions {
        let o = reg.observability(d.groupID, limit: sim.observer.limit)
        let obs: String
        switch o {
        case .exact?: obs = "exact"
        case .overLimit(let m, let l)?: obs = "unavailable (\(m) > \(l))"
        case .unsupported(let r)?: obs = "unsupported (\(r))"
        case nil: obs = "?"
        }
        print("  \(d.groupID) · \(d.category.rawValue) · \(d.membership.rootIDs.count) · \(d.evidenceTier.rawValue) · \(obs)")
    }
    print("  arousal · no registered group")
    suite.finish()
}
#endif
