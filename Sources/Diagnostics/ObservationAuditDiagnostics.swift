#if DIAGNOSTICS
// V7.1 audit of existing observation paths. No new runtime observation API.
import Foundation

func runObservationAuditTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool) {
        suite.check("observation " + name, ok)
    }
    guard let c = loadConnectome() else { exit(1) }
    let bus = SpikeBus()
    guard let observed = makeDiagSim(connectome: c, spikeBus: bus),
          let control = makeDiagSim(connectome: c, spikeBus: nil) else { exit(1) }
    observed.perfLogIntervalMs = 0; control.perfLogIntervalMs = 0
    // Use the existing independent CPU membership contract, not the live GPU
    // group buffer. Histogram membership must match its documented denominator.
    let reference = RefSim(c, params: control.debugParams, seed: SIM_SEED, fxScale: control.fixedPointScale)
    let groups: [(String, Int, [Int])] = [
        ("loom", 1, observed.loomLeft + observed.loomRight), ("GF", 2, observed.gf),
        ("DNaL", 3, observed.dnaL), ("DNaR", 4, observed.dnaR),
        ("MDN", 5, observed.mdn), ("DNp09", 6, observed.fwd),
        ("DNg11", 7, observed.groom), ("escW", 8, observed.escw),
        ("foodL", 9, observed.foodOdorLeft), ("foodR", 10, observed.foodOdorRight),
        ("warm", 11, observed.thermoWarm), ("cool", 12, observed.thermoCool),
        ("windC", 13, observed.windC), ("windE", 14, observed.windE)
    ]
    for (name, tag, members) in groups {
        let tagged = Set(reference.groupOf.indices.filter { reference.groupOf[$0] == tag })
        check("\(name) denominator \(members.count) equals independent membership", Set(members) == tagged && !members.isEmpty)
    }
    print("AUDIT population=\(c.n) sugarGRN=\(observed.sugarGRN.count) MN9=\(observed.mn9.count) alpha=\(observed.debugParams.rateAlpha)")
    var histogramOK = true, ratesOK = true, stateOK = true, exact = 0, sampled = 0
    let indices = Array(0..<c.n)
    var popRate: Float = 0
    for _ in 0..<30 {
        observed.step(1); control.step(1)
        let spikes = observed.lastStepSpikes()
        let counts = observed.lastStepGroupCounts()
        var expected = [UInt32](repeating: 0, count: 16)
        for i in spikes {
            let tag = Int(reference.groupOf[Int(i)])
            if tag > 0 { expected[tag] += 1 }
        }
        histogramOK = histogramOK && counts == expected
        exact += spikes.count
        popRate += (Float(spikes.count) * 1000 / Float(c.n) - popRate) * observed.debugParams.rateAlpha
        ratesOK = ratesOK && observed.ratePop == popRate
        // Repeated display reads and draining the visual bus must not advance
        // time, inject current, consume the GF motor latch, or alter dynamics.
        let before = observed.debugExternalInput(indices)
        for _ in 0..<100 {
            _ = observed.lastStepSpikes(); _ = observed.lastStepGroupCounts()
            _ = observed.ratePop
        }
        sampled += bus.popAll().count
        stateOK = stateOK && observed.debugExternalInput(indices) == before
            && observed.simMs == control.simMs && observed.totalSpikes == control.totalSpikes
            && observed.membrane() == control.membrane() && observed.debugRefr() == control.debugRefr()
            && Set(observed.lastStepSpikes()) == Set(control.lastStepSpikes())
            && observed.lastStepGroupCounts() == control.lastStepGroupCounts()
            && observed.ratePop == control.ratePop
    }
    check("exact histogram from independent memberships and full spikes", histogramOK)
    check("population Hz/neuron EMA from full spikes", ratesOK)
    check("3,000 display reads and bus drains leave neural state unchanged", stateOK)
    check("sampled display is smaller than exact count", sampled > 0 && sampled < exact)
    print("AUDIT 30 simulated ms: exact=\(exact) sampled=\(sampled); sampled has no tick or loss counter")
    let overflow = SpikeBus()
    overflow.push((0..<400).map { ($0, false) })
    let retained = overflow.popAll()
    check("overflow silently loses earlier display events", retained.count == 256 && retained.first?.neuron == 144 && overflow.popAll().isEmpty)
    // A display can lose a GF flash; this must not consume its motor event.
    observed.stimulate(observed.gf, strength: 1, durationMs: 2)
    observed.step(2); _ = bus.popAll()
    check("display drain preserves exact GF latch", observed.consumeGF())
    check("GF latch consumption is destructive, not a read-only query", !observed.consumeGF())
    let rateGetters: [(MetalSim) -> Float] = [
        { $0.rateLoom }, { $0.rateDNaL }, { $0.rateDNaR }, { $0.rateMDN },
        { $0.rateFwd }, { $0.rateGroom }, { $0.rateEscW }, { $0.rateFoodOdorL },
        { $0.rateFoodOdorR }, { $0.rateThermoWarm }, { $0.rateThermoCool },
        { $0.rateWindC }, { $0.rateWindE }, { $0.rateSugarGRN }, { $0.rateMN9 }, { $0.ratePop }
    ]
    let members = groups.filter { $0.1 != 2 }
    let slots = members.map { $0.1 } + [15, 15, 0]
    let occupied = Set(groups.flatMap { $0.2 })
    let sugar = observed.sugarGRN.filter { !occupied.contains($0) }
    let mn9 = observed.mn9.filter { !occupied.contains($0) }
    let denominators = members.map { Float(max(1, $0.2.count)) } + [Float(max(1, sugar.count)), Float(max(1, mn9.count)), Float(c.n)]
    observed.reset(); observed.tasteReadout = true
    var expectedRates = [Float](repeating: 0, count: 16), allRatesEqual = true
    for tick in 1...130 {
        observed.step(1)
        let counts = observed.lastStepGroupCounts()
        let phase = ((tick - 1) / 32) & 1
        for i in expectedRates.indices {
            if i == 13 && phase != 0 || i == 14 && phase != 1 { continue }
            let g = slots[i] == 0 ? observed.lastStepSpikes().count : Int(counts[slots[i]])
            var r = expectedRates[i]; let n = denominators[i], a = observed.debugParams.rateAlpha
            r += (Float(g) * 1000 / n - r) * a
            expectedRates[i] = r
        }
        allRatesEqual = allRatesEqual && zip(rateGetters, expectedRates).allSatisfy { $0.0(observed).bitPattern == $0.1.bitPattern }
    }
    check("table rates preserve every original EMA bit across taste windows", allRatesEqual)
    check("population table resolves menu indices", NeuronGuide.groups.allSatisfy { $0.stimulusID.map { !labPopulationIndices(observed, role: $0).isEmpty } ?? true })
    print("OBSERVATION AUDIT \(suite.failures == 0 ? "PASS" : "FAIL") (\(suite.failures) failures)")
    suite.finish()
}

#endif
