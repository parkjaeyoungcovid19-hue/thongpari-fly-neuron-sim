#if DIAGNOSTICS
// --observetest: V7.2 exact observation primitive and V7.3 read/stimulate split.
// Expected values in the fixture are worked out by hand, and the live check
// compares against the independent CPU reference (RefSim), not against the
// kernel's own readout.
import Cocoa
import simd

func runObservationTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check(name, ok, detail) }

    // ---- V7-01 fixture: known spikes, hand-computed counts -----------------
    // Selection [10, 11, 12] armed at tick 5 (slots 0, 1, 2). Spikes:
    //   t5: 10 · t6: 10, 11 · t7: — · t8: 12 · t9: 10, 12
    var ring = ObservationRing(capacity: 8)
    ring.arm([10, 11, 12], startTick: 5)
    let fixture: [Int: [Int]] = [5: [0], 6: [0, 1], 7: [], 8: [2], 9: [0, 2]]
    for t in 5...9 { ring.record(tick: t) { w in for s in fixture[t]! { w[0] |= 1 << UInt64(s) } } }
    func agg(_ m: [Int], _ a: Int, _ b: Int) -> (Int, Int, Int)? {
        guard case .success(let r) = ring.aggregate(members: m, start: a, end: b) else { return nil }
        return (r.spikes, r.observedTicks, r.dropped)
    }
    func obs(_ m: [Int], _ a: Int, _ b: Int) -> NeuralObservation? {
        guard let (s, o, d) = agg(m, a, b) else { return nil }
        return NeuralObservation(brainEpoch: 0, selectionID: 1, startTick: a, endTick: b, groupID: "g",
                                 rootIDs: Set(m).sorted().map { String($0) }, memberCount: Set(m).count,
                                 spikeCount: s, observedTicks: o, droppedSamples: d, source: .exact)
    }
    let single = obs([10], 5, 9)
    check("V7-01 single neuron: 3 spikes in 5 ms = 600 Hz/neuron",
          single?.spikeCount == 3 && single?.observedTicks == 5 && single?.rateHzPerNeuron == 600
            && single?.validity == .complete)
    let group = obs([10, 11, 12], 5, 9)
    check("V7-01 group of 3: 6 spikes / (5 ms × 3) = 400 Hz/neuron",
          group?.spikeCount == 6 && group?.memberCount == 3 && group?.rateHzPerNeuron == 400)
    let dup = obs([10, 10, 11], 5, 9)
    check("V7-01 duplicate membership counts once (2 members, 4 spikes)",
          dup?.memberCount == 2 && dup?.spikeCount == 4 && dup?.rateHzPerNeuron == 400)
    let a = agg([10, 11], 5, 9)?.0, b = agg([11, 12], 5, 9)?.0, union = agg([10, 11, 12], 5, 9)?.0
    check("V7-01 overlapping groups each count the shared neuron (4 + 3 ≠ union 6)",
          a == 4 && b == 3 && union == 6)
    let early = obs([10], 3, 9)
    check("V7-04 ticks before the selection are missing, not zero",
          early?.observedTicks == 5 && early?.droppedSamples == 2 && early?.validity == .partial
            && early?.rateHzPerNeuron == 600)
    let future = obs([10], 8, 12)
    check("V7-04 ticks not simulated yet are missing", future?.observedTicks == 2 && future?.droppedSamples == 3)
    if case .failure(.notSelected(let ix)) = ring.aggregate(members: [10, 13], start: 5, end: 9) {
        check("unselected member is rejected, never reported as 0 Hz", ix == [13])
    } else { check("unselected member is rejected, never reported as 0 Hz", false) }
    if case .failure(.invalidWindow) = ring.aggregate(members: [10], start: 9, end: 5) {
        check("inverted window is rejected", true)
    } else { check("inverted window is rejected", false) }
    let none = obs([], 5, 9)
    check("empty group has no rate (null), validity empty",
          none?.rateHzPerNeuron == nil && none?.validity == .empty && none?.memberCount == 0)
    for t in 10...14 { ring.record(tick: t) { w in w[0] |= 1 } }   // 10 spikes each tick
    let evicted = agg([10], 5, 14)
    // retained t7…t14 for neuron 10: t9 once + t10…t14 five times = 6
    check("V7-04 ring overflow: ticks 5–6 evicted (8 observed, 2 missing, 6 spikes)",
          evicted?.1 == 8 && evicted?.2 == 2 && evicted?.0 == 6,
          "\(String(describing: evicted))")
    ring.record(tick: 20) { _ in }
    let gap = agg([10], 13, 20)
    check("a skipped tick is a gap, never zeros", ring.gapTicks == 5 && gap?.1 == 3 && gap?.2 == 5,
          "gap \(ring.gapTicks) \(String(describing: gap))")

    // ---- JSON contract ------------------------------------------------------
    let bigRoot = "720575940624963786"
    let sample = NeuralObservation(sessionID: "s1", sessionEpoch: 2, brainEpoch: 3, selectionID: 4,
                                   startTick: 1, endTick: 10, groupID: "g", rootIDs: [bigRoot],
                                   memberCount: 1, spikeCount: 2, observedTicks: 10, droppedSamples: 0,
                                   source: .exact)
    let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
    let json = (try? enc.encode(sample)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let back = try? JSONDecoder().decode(NeuralObservation.self, from: Data(json.utf8))
    check("JSON root IDs are strings and round-trip exactly",
          json.contains("\"root_ids\":[\"\(bigRoot)\"]") && back == sample, json)
    check("JSON carries schema, source and validity",
          json.contains("\"schema\":\"neural_observation.v1\"") && json.contains("\"source\":\"exact\"")
            && json.contains("\"validity\":\"complete\""))
    func rejects(_ mutate: (inout [String: Any]) -> Void) -> Bool {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return false }
        mutate(&obj)
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return true }
        return (try? JSONDecoder().decode(NeuralObservation.self, from: d)) == nil
    }
    check("strict decode rejects a missing spike_count", rejects { $0["spike_count"] = nil })
    check("strict decode rejects a numeric root ID", rejects { $0["root_ids"] = [720575940624963786] })
    check("strict decode rejects a root ID count mismatch", rejects { $0["member_count"] = 2 })
    check("strict decode rejects a wrong schema", rejects { $0["schema"] = "neural_observation.v0" })
    check("strict decode rejects a rate without observed ticks",
          rejects { $0["observed_ticks"] = 0; $0["dropped_samples"] = 10 })
    check("strict decode rejects a rate that disagrees with its counts", rejects { $0["rate_hz_per_neuron"] = 150 })
    check("strict decode rejects a null rate the counts define", rejects { $0["rate_hz_per_neuron"] = NSNull() })
    check("strict decode rejects ticks that do not add up to the window", rejects { $0["dropped_samples"] = 1 })
    check("strict decode rejects a non-canonical root ID", rejects { $0["root_ids"] = ["+" + bigRoot] })
    check("strict decode rejects a validity the counts contradict", rejects { $0["validity"] = "partial" })

    // ---- capability and limits on a real sim --------------------------------
    guard let c = loadConnectome(), let sim = makeDiagSim(connectome: c) else { print("no sim"); exit(1) }
    check("capability: exact selection limit is 256", sim.observer.limit == 256
          && ObservationCapability.exactSelectionLimit == 256)
    if case .failure(.overLimit(257, 256)) = sim.setObservation(Array(0..<257)) {
        check("257 neurons rejected as a whole; nothing armed", sim.observer.selection().isEmpty)
    } else { check("257 neurons rejected as a whole; nothing armed", false) }
    if case .failure(.outOfRange(let i)) = sim.setObservation([0, c.n]) {
        check("out-of-range index rejected", i == c.n && sim.observer.selection().isEmpty)
    } else { check("out-of-range index rejected", false) }
    if case .success(let info) = sim.setObservation(Array(0..<400), name: "wide", truncate: true) {
        check("truncating request keeps the first 256 and reports 144 omitted",
              info.neurons == Array(0..<256) && info.omitted == 144)
    } else { check("truncating request keeps the first 256 and reports 144 omitted", false) }
    if case .success(let info) = sim.setObservation([5, 5, 6]) {
        check("duplicate indices collapse", info.neurons == [5, 6])
    } else { check("duplicate indices collapse", false) }
    sim.clearObservation()

    // ---- exact stream vs the independent CPU reference ----------------------
    // Selection: every command DN + GF, then neurons seen spiking in a pilot
    // run, up to 256. GPU steps in uneven batches; the reference steps 1 ms.
    var chosen = sim.gf + sim.dnaL + sim.dnaR + sim.mdn + sim.fwd + sim.groom + sim.escw
    guard let pilot = makeDiagSim(connectome: c) else { exit(1) }
    var seen = Set(chosen)
    for _ in 0..<80 where chosen.count < 256 {
        pilot.step(1)
        for i in pilot.lastStepSpikes().map(Int.init) where chosen.count < 256 && seen.insert(i).inserted {
            chosen.append(i)
        }
    }
    guard let gpu = makeDiagSim(connectome: c), let control = makeDiagSim(connectome: c) else { exit(1) }
    let ref = RefSim(c, params: gpu.debugParams, seed: SIM_SEED, fxScale: gpu.fixedPointScale)
    if let w = c.gpu.shared?.weightFx {
        let g = w.contents().bindMemory(to: Int32.self, capacity: c.e)
        if (0..<c.e).contains(where: { g[$0] != ref.wP[$0] }) { ref.quantizeWeights(rowFactored: true) }
    }
    ref.fusedLeak = true   // --gpucheck's arithmetic probe: "1 fma leak" is bit-exact
    _ = gpu.setObservation(chosen, name: "ref")
    let chosenSet = Set(chosen)
    // (ticks, action) segments; actions run before the segment on all sims.
    let gfStim = { (s: MetalSim) in s.stimulate(s.gf, strength: 0.5, durationMs: 40) }
    let segments: [(Int, (MetalSim) -> Void, (RefSim) -> Void)] = [
        (37, { _ in }, { _ in }), (64, { _ in }, { _ in }), (99, { _ in }, { _ in }),
        (50, gfStim, { $0.stimulate(gpu.gf, strength: 0.5, durationMs: 40) }),
        (120, { $0.loomL = 0.9; $0.loomR = 0.6 }, { $0.loomL = 0.9; $0.loomR = 0.6 }),
        (230, { $0.loomL = 0; $0.loomR = 0 }, { $0.loomL = 0; $0.loomR = 0 })
    ]
    var tick = 0, mismatches = 0, exactSpikes = 0, gfSpikes = 0, firstBad = -1, shiftedMismatches = 0
    var dnaRefCount = 0
    let dnaSet = Set(gpu.dnaL + gpu.dnaR)
    for (len, act, refAct) in segments {
        act(gpu); act(control); refAct(ref)
        var left = len
        for chunk in [1, 7, 64, 13] where left > 0 {   // uneven GPU batches
            let k = min(chunk, left); gpu.step(k); control.step(k); left -= k
        }
        if left > 0 { gpu.step(left); control.step(left) }
        for _ in 0..<len {
            ref.step(1); tick += 1
            let want = Set(ref.lastSpikes.map(Int.init)).intersection(chosenSet)
            let got = Set(gpu.observer.spikes(at: tick) ?? [-1])
            if want != got { mismatches += 1; if firstBad < 0 { firstBad = tick } }
            // negative control: the same comparison one tick off must notice
            if tick > 1, want != Set(gpu.observer.spikes(at: tick - 1) ?? []) { shiftedMismatches += 1 }
            exactSpikes += want.count
            gfSpikes += want.intersection(gpu.gf).count
            dnaRefCount += want.intersection(dnaSet).count
        }
    }
    check("V7-02 exact stream equals the CPU reference on every tick (\(tick) ticks, \(chosen.count) neurons)",
          mismatches == 0 && gpu.simMs == tick,
          "mismatched ticks \(mismatches), first \(firstBad); \(exactSpikes) reference spikes, GF \(gfSpikes)")
    check("the comparison is not vacuous (spikes seen, GF fired, a 1-tick shift is caught)",
          exactSpikes > 100 && gfSpikes > 0 && shiftedMismatches > tick / 2,
          "\(exactSpikes) spikes, GF \(gfSpikes), shifted mismatches \(shiftedMismatches)/\(tick)")
    let dnaObs = try? gpu.observer.observe(groupID: "DNa", members: Array(dnaSet), start: 1, end: tick).get()
    let dnaRate = Double(dnaRefCount) * 1000 / Double(tick * dnaSet.count)
    check("group count/rate equal the reference (DNa, 4 neurons)",
          dnaObs?.spikeCount == dnaRefCount && dnaObs?.rateHzPerNeuron == dnaRate && dnaObs?.validity == .complete,
          "obs \(String(describing: dnaObs?.spikeCount)) ref \(dnaRefCount), \(String(format: "%.2f", dnaRate)) Hz")
    check("observation has no side effect (state equals an unobserved sim)",
          gpu.membrane() == control.membrane() && gpu.debugRefr() == control.debugRefr()
            && gpu.totalSpikes == control.totalSpikes)

    // ---- retention and reset ------------------------------------------------
    gpu.step(2000); control.step(2000)
    let old = try? gpu.observer.observe(groupID: "all", members: chosen, start: 1, end: gpu.simMs).get()
    check("V7-04 beyond retention: partial with the evicted ticks missing",
          old?.validity == .partial && old?.droppedSamples == gpu.simMs - ObservationCapability.retainedTicks,
          "dropped \(String(describing: old?.droppedSamples))")
    let epochBefore = gpu.observer.selection().brainEpoch, selBefore = gpu.observer.selection().selectionID
    gpu.reset()
    let afterReset = gpu.observer.selection()
    check("reset: new epoch, selection kept, old ticks gone",
          afterReset.brainEpoch == epochBefore + 1 && afterReset.selectionID == selBefore
            && afterReset.neurons == chosen && gpu.observer.spikes(at: 5) == nil)
    gpu.step(10)
    let fresh = try? gpu.observer.observe(groupID: "all", members: chosen).get()
    check("after reset the window restarts at tick 1", fresh?.startTick == 1 && fresh?.endTick == 10
          && fresh?.observedTicks == 10)

    // ---- cost: 256 observed vs none (load-sensitive, loose bound) ------------
    func timePerStep(_ s: MetalSim) -> Double {
        let t0 = DispatchTime.now(); for _ in 0..<40 { s.step(64) }
        return Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1000 / 2560
    }
    _ = timePerStep(gpu); _ = timePerStep(control)
    let withObs = timePerStep(gpu), without = timePerStep(control)
    check("cost of 256 exact neurons stays small", withObs < without * 1.5 + 20,
          String(format: "%.1f vs %.1f µs/step", withObs, without))

    // ---- V7.3 / V7-02: selection never stimulates ----------------------------
    guard let screen = NSScreen.screens.first else {
        check("V7-02 brain view needs a screen", false); suite.finish()
    }
    // The app's own wiring: connect(to:) -> Coordinator.observeBrainPick /
    // enqueueSimulation. Queued actions are drained as the render loop does.
    let s3 = sim
    let coord = Coordinator(bounds: CGSize(width: 800, height: 600), sim: s3)
    let wc = BrainWindowController(connectome: c, sim: s3, screen: screen)
    var stimCalls = 0
    wc.connect(to: coord) { _, _, _ in stimCalls += 1 }
    func drain() { for action in coord.drainSimulationActions() { action(coord) } }
    let all = Array(0..<c.n)
    s3.step(5)
    let selBefore3 = s3.observer.selection().selectionID
    let extBefore = s3.debugExternalInput(all), reqBefore = s3.directStimulationStatus().requests
    check("default mode is select (switch off)", !wc.clickStimulates && wc.stimulateSwitch.state == .off
          && wc.panel.title.contains("select"))
    var lastPick: BrainPick?, sizesOK = true
    for k in 0..<100 {
        let angle = Float(k) * 0.37
        let origin = SIMD3<Float>(6 * cos(angle), 4 * sin(angle * 1.3), 40)
        guard let pick = wc.pick(rayOrigin: origin, direction: SIMD3(0, 0, -1)) else { continue }
        wc.activate(pick)
        let queued = s3.observer.pending() != nil
        drain()
        lastPick = pick
        sizesOK = sizesOK && queued && s3.observer.pending() == nil
            && s3.observer.selection().neurons.count == min(256, Set(pick.indices).count)
        if k % 10 == 0 { wc.embeddedView.onClick?(NSPoint(x: 170 + k, y: 140)); drain(); s3.step(20) }
    }
    s3.step(5)
    let selects = s3.observer.selection().selectionID - selBefore3
    check("V7-02 100 picks + 10 real click routes: no stimulation callback, no new injection request",
          stimCalls == 0 && s3.directStimulationStatus().requests == reqBefore && selects == 110,
          "stim \(stimCalls), selections applied \(selects)")
    check("V7-02 extInput unchanged after selections", s3.debugExternalInput(all) == extBefore)
    check("each selection is shown as queued, then armed min(256, picked) exact neurons", sizesOK)
    if let pick = lastPick {
        wc.clickStimulates = true
        wc.activate(pick)
        drain()
        s3.step(1)
        let ext = s3.debugExternalInput(pick.indices)
        let st = s3.directStimulationStatus()
        check("switch on: one click = one stimulation of the picked neurons",
              stimCalls == 1 && st.requests == reqBefore + 1 && ext.allSatisfy { $0 == BrainWindowController.clickStrength }
                && st.active == 1 && st.neurons == Set(pick.indices).count && wc.panel.title.contains("STIMULATE"),
              "stim \(stimCalls) active \(st.active) neurons \(st.neurons)")
        wc.clickStimulates = false
        wc.activate(pick)
        drain()
        check("switch off again: click selects only", stimCalls == 1 && s3.directStimulationStatus().requests == reqBefore + 1)
    }
    s3.stimulate(s3.groom, strength: 0.25, durationMs: 50); s3.step(1)
    check("population stimulation still works with the switch off",
          s3.directStimulationStatus().requests == reqBefore + 2
            && s3.debugExternalInput(s3.groom).allSatisfy { $0 >= 0.25 })
    suite.finish()
}
#endif
