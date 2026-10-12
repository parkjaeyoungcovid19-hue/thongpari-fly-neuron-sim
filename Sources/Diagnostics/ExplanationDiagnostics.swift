#if DIAGNOSTICS
// --explaintest: V7.7 observation-based explanation. Hand-made windows (one per
// verdict, boundaries on both sides of every threshold) go through the pure
// `explain`; then the sentences are scanned for forbidden vocabulary and for numbers
// that are not facts, and a real MetalSim event goes through the app's own funnel.
import Cocoa

private struct Fx {
    var groups: [(id: String, n: Int, b: Double, r: Double)] = [("GRP", 256, 5, 5)]
    var walk: (b: Double, r: Double) = (0.25, 0.25)
    var escapeResponse = 0
    var dispB = 0.0, dispR = 0.0          // mm; baseline span 400 ticks, response span 800 ticks
    var bodyUnit = "mm"
    var body = true, motor = true
    var force: Bool? = false, sensory: Bool? = false
    var received = false
    var status: InteractionWindowStatus = .complete

    func window(_ th: ExplanationThresholds = .standard) -> InteractionWindow {
        var w = InteractionWindow(eventID: "fx", eventIDOrigin: .local, eventKind: "wind", source: .physical,
                                  appliedTick: 1000, appliedTickOrigin: "fixture", brainEpoch: 1, selectionID: 1, config: .standard)
        if status == .collecting { w.responseTicksCollected = 250; return w }
        w.status = status
        w.responseTicksCollected = 1000
        w.forceApplied = force; w.sensoryApplied = sensory
        func obs(_ g: (id: String, n: Int, b: Double, r: Double), _ rate: Double, _ s: Int, _ e: Int) -> NeuralObservation {
            let ticks = e - s + 1
            return NeuralObservation(brainEpoch: 1, selectionID: 1, startTick: s, endTick: e, groupID: g.id,
                                     rootIDs: (0..<g.n).map { String(720_575_940_000_000_000 + $0) }, memberCount: g.n,
                                     spikeCount: Int((rate * Double(ticks * g.n) / 1000).rounded()), observedTicks: ticks, droppedSamples: 0, source: .exact)
        }
        w.groups = groups.map { g in
            GroupWindowResult(groupID: g.id, memberCount: g.n, baseline: obs(g, g.b, 500, 999), baselineMissingTicks: 0,
                              response: obs(g, g.r, 1000, 1999), responseMissingTicks: 0)
        }
        w.validity.droppedSamples = 0
        w.validity.sufficient = w.impliedSufficient
        func m(_ walk: Double, _ esc: Int, _ f: Int, _ l: Int) -> MotorWindowSummary {
            MotorWindowSummary(status: .collected, reason: nil, sampleCount: 20, firstTick: f, lastTick: l, periodTicks: 20,
                               mean: MotorMeans(walkDrive: walk, turnBias: 0, groomDrive: 0.1, wingDrive: 0, nervous: 0, arousal: 0.2),
                               escapeCount: esc, backwardCount: 0)
        }
        func b(_ disp: Double, _ f: Int, _ l: Int) -> BodyWindowSummary {
            BodyWindowSummary(status: .collected, reason: nil, sampleCount: 20, firstTick: f, lastTick: l, periodTicks: 20,
                              sampledAtCount: received ? 0 : 20, receivedAtCount: received ? 20 : 0, positionUnit: bodyUnit,
                              netDisplacement: disp, meanSpeed: nil, meanYawRate: nil, stateTransitions: nil)
        }
        if motor { w.motorOutput = MotorOutput(baseline: m(walk.b, 0, 540, 940), response: m(walk.r, escapeResponse, 1100, 1900)) }
        else { w.motorOutput = .unavailable("ring_evicted") }
        if body { w.observedBodyAction = ObservedBodyAction(baseline: b(dispB, 540, 940), response: b(dispR, 1100, 1900)) }
        else { w.observedBodyAction = .unavailable("no_samples_in_window") }
        return w
    }
}

private let forbidden = ["무서", "놀라", "원하", "생각", "하려고", "의도", "감정", "기분", "결정", "두려", "wants", "afraid", "decid", "feels", "feeling",
                         "fear", "scared", "emotion", "intend", "desire", "thought", "thinks", "wish", "mood", "scare", "surpris"]

/// Numbers a sentence prints (a digit run not glued to a letter, `_` or digit before it, as in `DNp09`).
private func numbers(in s: String) -> [String] {
    let re = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])[+-]?[0-9]+(\\.[0-9]+)?")
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
}

func runExplanationTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check(name, ok, detail) }
    func verdict(_ fx: Fx, _ th: ExplanationThresholds = .standard) -> ExplanationVerdict { explain(window: fx.window(), thresholds: th).verdict }

    var all: [(String, InteractionExplanation)] = []
    func fixture(_ name: String, _ fx: Fx, _ want: ExplanationVerdict, th: ExplanationThresholds = .standard, reason: String? = nil) {
        let e = explain(window: fx.window(), thresholds: th)
        all.append((name, e))
        check("verdict \(want.rawValue): \(name)", e.verdict == want && (reason.map { r in e.reasons.contains { $0.hasPrefix(r) } } ?? true),
              "got \(e.verdict.rawValue) \(e.reasons)")
    }
    let flat = Fx()
    // ---- one fixture per verdict -------------------------------------------------------------
    var obsFx = Fx(); obsFx.status = .collecting
    let observing = explain(window: obsFx.window())
    all.append(("observing", observing))
    check("verdict observing: still collecting, shows ticks collected / needed",
          observing.verdict == .observing && observing.facts.contains { $0.key == "response_ticks_collected" && $0.value == "250" }
            && observing.facts.contains { $0.key == "response_ticks_needed" && $0.value == "1000" } && observing.sentences.en[0].contains("250 of 1000"))
    fixture("flat everything", flat, .noResponse)
    var neural = Fx(); neural.groups = [("DNp09", 2, 14, 31.5)]; neural.walk = (0.12, 0.85); neural.dispR = 4
    let ne = explain(window: neural.window())
    all.append(("neural", ne))
    check("verdict neural_response: DNp09 14.0 → 31.5 (+17.5), walkDrive 0.12 → 0.85, body moved",
          ne.verdict == .neuralResponse && ne.sentences.en.contains { $0.contains("DNp09") && $0.contains("14.0 → 31.5") && $0.contains("+17.5") && $0.contains("rose") }
            && ne.sentences.ko.contains { $0.contains("DNp09 그룹 발화율이 14.0 → 31.5 Hz/뉴런(+17.5") && $0.contains("올랐다") }
            && ne.sentences.en.contains { $0.contains("walkDrive 0.12 → 0.85") }, ne.sentences.en.joined(separator: " | "))
    var activity = Fx(); activity.groups = [("GRP", 256, 5, 8)]
    fixture("group beyond, motor and body flat", activity, .neuralActivityOnly)
    var physical = Fx(); physical.force = true; physical.dispR = 4
    fixture("force applied, body moved, motor flat", physical, .physicalOnly)
    var mixed = Fx(); mixed.force = true; mixed.walk = (0.12, 0.85); mixed.dispR = 4
    fixture("force applied and motor changed", mixed, .mixed)
    var opposite = Fx(); opposite.groups = [("A", 256, 5, 8), ("B", 256, 8, 5)]
    fixture("groups beyond in opposite directions", opposite, .unclear, reason: "groups_opposite_direction")
    var motorNoBody = Fx(); motorNoBody.groups = [("GRP", 256, 5, 8)]; motorNoBody.walk = (0.1, 0.9); motorNoBody.body = false
    fixture("motor changed, body unavailable (not forced)", motorNoBody, .unclear, reason: "motor_changed_body_unavailable")
    var motorNoMove = Fx(); motorNoMove.groups = [("GRP", 256, 5, 8)]; motorNoMove.walk = (0.1, 0.9)
    fixture("motor changed, body did not move", motorNoMove, .unclear, reason: "motor_changed_body_not_moved")
    var unforcedMove = Fx(); unforcedMove.dispR = 4
    fixture("body moved, no force, no motor change", unforcedMove, .unclear, reason: "body_moved_without_force")
    var forceUnknown = Fx(); forceUnknown.force = nil; forceUnknown.dispR = 4
    fixture("body moved, force unknown", forceUnknown, .unclear, reason: "force_unknown")
    // insufficient
    var inv = Fx(); inv.status = .invalid
    var w = inv.window(); w.validity.noSelection = true; w.groups = []; w.validity.sufficient = false
    let invE = explain(window: w); all.append(("invalid", invE))
    check("verdict insufficient: invalid window lists its flag", invE.verdict == .insufficient && invE.reasons.contains("window_invalid:no_selection"), "\(invE.reasons)")
    w = flat.window(); w.validity.baselineInsufficient = true; w.validity.sufficient = false
    let baseE = explain(window: w); all.append(("baseline insufficient", baseE))
    check("verdict insufficient: baseline not observed", baseE.verdict == .insufficient && baseE.reasons.contains("baseline_insufficient"))
    w = flat.window(); w.validity.overlappingEvents = ["other"]; w.validity.sufficient = false
    let ovE = explain(window: w); all.append(("overlap", ovE))
    check("verdict insufficient: overlapping event, with its count as a fact", ovE.verdict == .insufficient && ovE.reasons == ["overlapping_events"]
          && ovE.facts.contains { $0.key == "overlapping_events" && $0.value == "1" })
    var noMotor = Fx(); noMotor.motor = false
    fixture("motor unavailable", noMotor, .insufficient, reason: "motor_baseline_unavailable:ring_evicted")
    var noBody = Fx(); noBody.body = false
    fixture("body unavailable, motor flat (cannot claim 'no body change')", noBody, .insufficient, reason: "body_baseline_unavailable")
    w = flat.window()
    w.groups[0] = GroupWindowResult(groupID: "GRP", memberCount: 256, baseline: nil, baselineMissingTicks: 500, response: w.groups[0].response, responseMissingTicks: 0)
    let gE = explain(window: w); all.append(("group delta unavailable", gE))
    check("verdict insufficient: a group without a delta names it", gE.verdict == .insufficient && gE.reasons.contains { $0.hasPrefix("group_delta_unavailable:GRP") })

    // ---- thresholds: both sides of each boundary -----------------------------------------------
    var g = Fx(); g.groups = [("GRP", 256, 5, 6)]                       // Δ exactly +1.0 = the 1.0 Hz floor (noise term 0.75 is below it)
    check("group boundary: Δ exactly at the floor is NOT beyond; just above (+1.25) is", verdict(g) == .noResponse
          && { var x = Fx(); x.groups = [("GRP", 256, 5, 6.25)]; return verdict(x) == .neuralActivityOnly }())
    check("group threshold follows the noise: 2-neuron group, +10 Hz is within 3σ; +17.5 is beyond",
          { var a = Fx(); a.groups = [("DNp09", 2, 14, 24)]; return verdict(a) == .noResponse }()
            && verdict(neural) == .neuralResponse)
    check("group Δ below zero counts the same (|Δ|)", { var x = Fx(); x.groups = [("GRP", 256, 8, 5)]; return verdict(x) == .neuralActivityOnly }())
    let exact = ExplanationThresholds(groupFloorHz: 1, noiseK: 3, motorFloor: 0.125, bodyFloorMmPerS: 1, bodyFloorPtPerS: 10)
    var mAt = Fx(); mAt.walk = (0.25, 0.375)
    var mAbove = Fx(); mAbove.walk = (0.25, 0.5)
    check("motor boundary: Δ exactly at the floor is NOT a change; above it is", verdict(mAt, exact) == .noResponse && verdict(mAbove, exact) == .unclear)
    var eNew = Fx(); eNew.escapeResponse = 2
    check("a first escape in the response (none before) counts as a motor change", verdict(eNew, exact) == .unclear)
    var bAt = Fx(); bAt.dispR = 0.8                                     // 0.8 mm over 0.8 s = exactly 1 mm/s
    var bAbove = Fx(); bAbove.dispR = 0.9
    check("body boundary: rate change exactly at 1 mm/s is NOT movement; above it is",
          verdict(bAt, exact) == .noResponse && { var x = bAbove; x.force = true; return verdict(x, exact) == .physicalOnly }())
    var pt = Fx(); pt.bodyUnit = "pt"; pt.dispR = 6; pt.force = true       // 7.5 pt/s < 10 pt/s floor
    var pt2 = pt; pt2.dispR = 10                                           // 12.5 pt/s
    check("local fly (pt) uses its own floor: 7.5 pt/s still, 12.5 pt/s moved", verdict(pt) == .noResponse && verdict(pt2) == .physicalOnly)
    var mixedUnit = Fx(); mixedUnit.force = true
    var wm = mixedUnit.window(); wm.observedBodyAction?.response.positionUnit = "mixed"
    check("a window mixing position units cannot claim a body result", explain(window: wm).verdict == .insufficient
          && explain(window: wm).reasons.contains("body_position_unit_mixed"))

    // ---- V7-05: physical force vs neural output -------------------------------------------------
    var wind = Fx(); wind.force = true; wind.sensory = false; wind.dispR = 4
    let windE = explain(window: wind.window()); all.append(("V7-05 wind force only", windE))
    let phys = windE.sentences.en.joined(separator: " ") + windE.sentences.ko.joined(separator: " ")
    check("V7-05 wind force only: physical_only; the body was moved by the applied force; no neural decision claimed",
          windE.verdict == .physicalOnly && windE.sentences.en.contains { $0.contains("moved by the applied force") }
            && windE.sentences.ko.contains { $0.contains("가해진 힘 때문") } && !phys.lowercased().contains("decision") && !phys.contains("신경이"))
    var sens = Fx(); sens.force = false; sens.sensory = true; sens.groups = [("GRP", 256, 5, 8)]; sens.walk = (0.12, 0.85); sens.dispR = 4
    check("V7-05 sensory only (no force): a neural verdict, never physical_only/mixed", verdict(sens) == .neuralResponse)
    var both = sens; both.force = true
    let bothE = explain(window: both.window()); all.append(("V7-05 both", bothE))
    check("V7-05 force and sensory with a motor change: mixed, states both, attributes the displacement to neither alone",
          bothE.verdict == .mixed && bothE.sentences.en.contains { $0.contains("not attributed to either alone") })
    var recv = physical; recv.received = true
    let recvE = explain(window: recv.window()); all.append(("received_at body", recvE))
    check("a received_at body lane says its time is the receive time",
          recvE.sentences.en.contains { $0.contains("receive time") } && recvE.sentences.ko.contains { $0.contains("수신 시각") }
            && !explain(window: physical.window()).sentences.en.contains { $0.contains("receive time") })

    // ---- vocabulary, numbers, determinism, v1 ---------------------------------------------------------------
    var badWords: [String] = [], badNumbers: [String] = [], blank = 0, count = 0
    for (name, e) in all {
        let factValues = Set(e.facts.map(\.value))
        for (lang, list) in [("en", e.sentences.en), ("ko", e.sentences.ko)] {
            if list.isEmpty || list.contains(where: { $0.isEmpty }) { blank += 1 }
            for s in list {
                count += 1
                for f in forbidden where s.lowercased().contains(f) { badWords.append("\(name)/\(lang): \(f)") }
                for n in numbers(in: s) where !factValues.contains(n) { badNumbers.append("\(name)/\(lang): \(n) in “\(s)”") }
            }
        }
    }
    check("forbidden vocabulary (feelings, intentions, thoughts, wants) in \(count) sentences of \(all.count) fixtures, both languages: none", badWords.isEmpty, badWords.joined(separator: "; "))
    check("every number in every sentence is one of that explanation's facts", badNumbers.isEmpty, badNumbers.prefix(3).joined(separator: "; "))
    check("every fixture explanation has non-empty sentences in both languages and as many KO as EN", blank == 0 && all.allSatisfy { $0.1.sentences.en.count == $0.1.sentences.ko.count })
    check("all eight verdicts are covered by the fixtures", Set(all.map { $0.1.verdict }) == Set(ExplanationVerdict.allCases),
          Set(ExplanationVerdict.allCases).subtracting(all.map { $0.1.verdict }).map(\.rawValue).joined(separator: ","))
    check("deterministic: the same window gives an identical explanation (and encodes identically)",
          explain(window: neural.window()) == explain(window: neural.window())
            && { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return (try? e.encode(explain(window: neural.window()))) == (try? e.encode(explain(window: neural.window()))) }())
    check("contract: schema name and verdict strings", ne.schema == "interaction_explanation.v1"
          && ExplanationVerdict.allCases.map(\.rawValue) == ["observing", "insufficient", "no_response", "neural_response", "neural_activity_only", "physical_only", "mixed", "unclear"])
    var v1 = flat.window(); v1.schema = InteractionWindowCapability.schemaV1; v1.motorOutput = nil; v1.observedBodyAction = nil
    let v1E = explain(window: v1)
    check("a v1 record (motor/body not collected) is insufficient with that reason, no crash",
          v1E.verdict == .insufficient && v1E.reasons.contains("motor_not_collected") && v1E.sentences.en.joined().contains("v1 record"), "\(v1E.reasons)")
    // round trip of the contract
    check("explanation JSON round-trips", (try? JSONDecoder().decode(InteractionExplanation.self, from: JSONEncoder().encode(ne))) == ne)
    // recorder line carries it beside an untouched v2 window
    do {
        let line = EventWindowIntent.lineExtra(for: flat.window()) ?? [:]
        check("recorder: the window object stays interaction_window.v2 and an interaction_explanation sits beside it",
              (line["interaction_window"] as? [String: Any])?["schema"] as? String == "interaction_window.v2"
                && (line["interaction_explanation"] as? [String: Any])?["schema"] as? String == "interaction_explanation.v1")
    }
    // The UI strings come from the same pure data.
    check("UI: every verdict has a badge in both languages and the card text is the sentences",
          ExplanationVerdict.allCases.allSatisfy { !$0.badge.isEmpty } && ExplanationText.sentences(ne) == ne.sentences.en.joined(separator: "\n"))

    // ---- real path: a real MetalSim event through the app's funnel -------------------------------------------
    guard let c = loadConnectome(), let sim = makeDiagSim(connectome: c) else { print("no sim"); exit(1) }
    let chosen = sim.gf + sim.dnaL + sim.dnaR + sim.mdn + sim.fwd + sim.groom + sim.escw
    let coord = Coordinator(bounds: CGSize(width: 800, height: 600), sim: sim)
    func drain() { for action in coord.drainSimulationActions() { action(coord) } }
    coord.observeBrainPick(BrainPick(indices: chosen, anchor: .zero, name: "explaintest"))
    drain()
    sim.step(600)
    let applied = sim.simMs + 1
    sim.eventWindows.noteEvent(id: "flash", kind: "flash_eye", source: .sensoryModel, appliedTick: applied)
    func quantum(_ i: Int) {
        var fb = FlyGymBodyFeedback()
        fb.receivedAt = Date(timeIntervalSinceReferenceDate: Double(i + 1))
        fb.positionXmm = Double(i); fb.vx = 0.01; fb.yawRate = 0.1
        _ = coord.advanceV4TimingQuantumForTesting(fb)
    }
    for i in 0..<10 { quantum(i) }
    let early = sim.eventWindows.window(eventID: "flash").map { explain(window: $0) }
    check("real path: 200 ticks in, the verdict is observing and says how many ticks were collected",
          early?.verdict == .observing && early?.sentences.en.first?.contains("200 of 1000") == true, early?.sentences.en.first ?? "nil")
    let tickBefore = sim.simMs
    for i in 10..<51 { quantum(i) }
    let done = sim.eventWindows.window(eventID: "flash")
    let late = done.map { explain(window: $0) }
    check("real path: after 1,000 ticks the window is complete and the verdict is not observing (\(late?.verdict.rawValue ?? "nil"))",
          done?.status == .complete && late != nil && late?.verdict != .observing && late?.sentences.en.isEmpty == false)
    check("real path: no baseline was ever observed by a producer, so it says insufficient with the lane reason, not a guess",
          late?.verdict == .insufficient && late?.reasons.contains { $0.hasPrefix("motor_baseline_unavailable") } == true, "\(late?.reasons ?? [])")
    let simAfterStep = sim.simMs, extBefore = sim.debugExternalInput(chosen)
    _ = explain(window: done!); _ = explain(window: done!)
    check("read-only: explaining twice moves no tick (simMs \(simAfterStep)) and the brain input equals what the window run left (sim advanced only by the quanta)",
          sim.simMs == simAfterStep && simAfterStep == tickBefore + 41 * 20 && sim.debugExternalInput(chosen) == extBefore)
    check("real path: the explanation of the real window is deterministic and its numbers are facts",
          late.map { e in explain(window: done!) == e && e.sentences.en.allSatisfy { s in numbers(in: s).allSatisfy { n in e.facts.contains { $0.value == n } } } } == true)
    suite.finish()
}
#endif
