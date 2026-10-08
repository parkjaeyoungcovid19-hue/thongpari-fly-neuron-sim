// Diagnostics.swift — `--brainstats [seconds]`: what the whole-brain sim is
// actually doing at rest. Steps 1 ms at a time so `lastStepSpikes()` yields a
// per-neuron spike count, then slices it every way the tuning pass needs
// (population, super class, role, cell type, rate histogram) and repeats the
// run with `weightScale = 0` so the network's contribution to each population
// is visible next to the intrinsic (baseline+noise only) floor.

import Foundation

private struct Run {
    var counts: [Int] = []      // spikes per neuron over `ms`
    var ms = 0
    var stepUs: Double = 0      // 1-step batches (the counting loop)
    var batchUs: Double = 0     // 16-step batches — the realtime number
    var spikesPerStep: Double = 0
}

/// Mean Hz over a neuron subset.
private func hz(_ r: Run, _ idx: [Int]) -> Double {
    guard !idx.isEmpty, r.ms > 0 else { return 0 }
    let total = idx.reduce(0) { $0 + r.counts[$1] }
    return Double(total) * 1000 / Double(r.ms) / Double(idx.count)
}

private func collect(_ c: Connectome, _ p: SimParams, settleMs: Int, runMs: Int) -> (MetalSim, Run)? {
    guard let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED, params: p) else { return nil }
    sim.perfLogIntervalMs = 0
    sim.step(settleMs)

    var r = Run(counts: [Int](repeating: 0, count: sim.n), ms: runMs)
    let t0 = DispatchTime.now()
    for _ in 0..<runMs {
        sim.step(1)
        for s in sim.lastStepSpikes() { r.counts[Int(s)] += 1 }
    }
    r.stepUs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1000 / Double(runMs)
    r.spikesPerStep = Double(r.counts.reduce(0, +)) / Double(runMs)

    // realtime margin is measured the way the render loop steps: 16 ms batches
    sim.step(50)
    let t1 = DispatchTime.now()
    for _ in 0..<125 { sim.step(16) }
    r.batchUs = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1000 / 2000
    return (sim, r)
}

/// One pass over the CSR: total in-weight (threshold units, so 1.0 = "one
/// presynaptic volley fires this neuron from rest") onto each role population,
/// split by sign. The giant fiber's line also splits the excitation into the
/// electrically boosted LC/sensory path and everything else, which is the escape
/// race in two numbers. Weights come dequantized from the sim's own edge buffer,
/// so this audits what the GPU steps rather than a second copy of the transform.
private func inWeightAudit(_ c: Connectome, _ sim: MetalSim) {
    let groups: [(String, [Int])] = [
        ("gf", sim.gf), ("dnaL", sim.dnaL), ("dnaR", sim.dnaR), ("mdn", sim.mdn),
        ("fwd", sim.fwd), ("groom", sim.groom), ("escw", sim.escw), ("loom", sim.loomLeft + sim.loomRight)]
    var slot = [Int](repeating: -1, count: c.n)
    for (g, (_, idx)) in groups.enumerated() { for i in idx { slot[i] = g } }
    var exc = [Double](repeating: 0, count: groups.count)
    var inh = [Double](repeating: 0, count: groups.count)
    var boosted = 0.0   // gf only: LC4/LPLC2/sensory -> GF, the gap-junction path
    let wfx = sim.edgeWeightsFx, invFx = 1 / Double(sim.fixedPointScale)
    c.colIdxData.withUnsafeBytes { cb in
        let col = cb.baseAddress!.assumingMemoryBound(to: UInt32.self)
        for i in 0..<c.n {
            let r = c.role[i]
            let electrical = r == Role.lc4 || r == Role.lplc2 || r == Role.sens
            for k in Int(c.rowStart[i])..<Int(c.rowStart[i + 1]) {
                let j = Int(col[k]); let s = slot[j]
                if s < 0 { continue }
                let isGF = c.role[j] == Role.gf
                let w = Double(wfx[k]) * invFx
                if w >= 0 { exc[s] += w; if isGF && electrical { boosted += w } } else { inh[s] += w }
            }
        }
    }
    print("in-weight per neuron (threshold units, 1.0 = one full volley fires it):")
    for (g, (name, idx)) in groups.enumerated() where !idx.isEmpty {
        let n = Double(idx.count)
        let extra = name == "gf"
            ? String(format: "  [electrical LC/sens path %+.2f]", boosted / n) : ""
        print(String(format: "  %-6@ exc %+8.2f  inh %+8.2f  net %+8.2f%@",
                     name as NSString, exc[g] / n, inh[g] / n, (exc[g] + inh[g]) / n, extra as NSString))
    }
}

/// Why is the hottest cell type hot? Prints its own neurotransmitter bytes (an
/// UNKNOWN byte means the ETL took the edge sign from the parquet rather than
/// from Codex's nt_type, which is the one place a sign could be an artifact),
/// the effective sign each of those neurons actually sends, and the ten
/// presynaptic neurons delivering the most POSITIVE weight into the type.
private func hotspotProbe(_ c: Connectome, _ sim: MetalSim, _ r: Run, _ type: String) {
    var isTarget = [Bool](repeating: false, count: c.n)
    var target: [Int] = []
    for i in 0..<c.n where sim.types[i] == type { isTarget[i] = true; target.append(i) }
    guard !target.isEmpty else { return }

    // effective out-sign per neuron: the sign the ETL baked into its edges
    var outSign = [Int8](repeating: 0, count: c.n)
    var inPos = [Double](repeating: 0, count: c.n)   // positive weight into the target set
    var totalPos = 0.0, fromSameType = 0.0
    let wfx = sim.edgeWeightsFx, invFx = 1 / Double(sim.fixedPointScale)
    c.colIdxData.withUnsafeBytes { cb in
        let col = cb.baseAddress!.assumingMemoryBound(to: UInt32.self)
        for i in 0..<c.n {
            for k in Int(c.rowStart[i])..<Int(c.rowStart[i + 1]) {
                if outSign[i] == 0 { outSign[i] = wfx[k] > 0 ? 1 : -1 }
                guard isTarget[Int(col[k])], wfx[k] > 0 else { continue }
                let w = Double(wfx[k]) * invFx
                inPos[i] += w; totalPos += w
                if sim.types[i] == type { fromSameType += w }
            }
        }
    }

    print("hotspot \(type) (n=\(target.count), \(String(format: "%.0f", hz(r, target))) Hz):")
    var ntTally = [String: (Int, Int, Int)]()   // nt name -> (count, excitatory, inhibitory)
    for i in target {
        let key = c.ntNames[Int(c.nt[i])]
        var t = ntTally[key] ?? (0, 0, 0)
        t.0 += 1; if outSign[i] > 0 { t.1 += 1 } else { t.2 += 1 }
        ntTally[key] = t
    }
    print("  own nt bytes: " + ntTally.sorted { $0.value.0 > $1.value.0 }
        .map { "\($0.key) \($0.value.0) (sends +\($0.value.1)/-\($0.value.2))" }.joined(separator: ", "))
    print(String(format: "  positive in-weight %.1f total, %.0f%% of it from other %@",
                 totalPos / Double(target.count), 100 * fromSameType / max(totalPos, 1e-9),
                 type as NSString))
    // Class-wide: the ETL signs an UNKNOWN-nt neuron from the parquet (or +1 if it
    // has no parquet call at all), so "UNKNOWN nt that sends +" is the set where a
    // wrong excitatory sign is possible. How much of the hot tail is in it?
    let unk = (0..<c.n).filter { c.nt[$0] == 0 && outSign[$0] > 0 }
    let hotAll = (0..<c.n).filter { Double(r.counts[$0]) * 1000 / Double(r.ms) > 20 }
    let hotUnk = hotAll.filter { c.nt[$0] == 0 && outSign[$0] > 0 }
    print(String(format: "  class-wide: %d UNKNOWN-nt neurons send + (%.1f%% of the brain, %.2f Hz mean);"
                 + " they are %d of the %d neurons above 20 Hz (%.0f%%)",
                 unk.count, 100 * Double(unk.count) / Double(c.n), hz(r, unk),
                 hotUnk.count, hotAll.count, 100 * Double(hotUnk.count) / Double(max(hotAll.count, 1))))
    var hotNt = [String: Int]()
    for i in hotAll { hotNt[c.ntNames[Int(c.nt[i])], default: 0] += 1 }
    let hotNtSorted: [String] = hotNt.sorted { $0.value > $1.value }.map { pair in
        "\(pair.key) \(pair.value)"
    }
    print("  nt bytes of ALL \(hotAll.count) neurons above 20 Hz: "
          + hotNtSorted.joined(separator: ", "))
    print("  top presynaptic sources by summed +weight (per target neuron):")
    for i in inPos.indices.sorted(by: { inPos[$0] > inPos[$1] }).prefix(10) {
        print(String(format: "    %-22@ nt %-7@ sends %@  %6.2f Hz  +%.2f",
                     sim.types[i] as NSString, c.ntNames[Int(c.nt[i])] as NSString,
                     outSign[i] > 0 ? "+" : "-", Double(r.counts[i]) * 1000 / Double(r.ms),
                     inPos[i] / Double(target.count)))
    }
}

func runBrainStats(seconds: Int) {
    guard let c = loadConnectome() else {
        fputs("no data/ — run etl.py first\n", stderr); exit(1)
    }
    let runMs = max(1, seconds) * 1000
    let p = SimParams()
    guard let (sim, r) = collect(c, p, settleMs: 1000, runMs: runMs) else {
        fputs("no Metal sim\n", stderr); exit(1)
    }

    print("brainstats: \(sim.n) neurons | \(c.e) edges | \(sim.deviceName)"
          + " | \(seconds) s of rest after 1 s settle")
    print(String(format: "params: weightScale %.5f modScale %.2f gap %.1f pNoise %.4f kick %.3f"
                 + " loomGain %.3f puffGain %.3f ascendGain %.3f",
                 p.weightScale, p.modScale, p.gapJunctionBoost, p.pNoise, p.noiseKick,
                 p.loomGain, p.airPuffGain, p.ascendGain))
    print(String(format: "population: %.2f Hz/neuron | %.0f spikes/step | %.0f µs/step (1-step)"
                 + " | %.0f µs/step (16-step batches)",
                 hz(r, Array(0..<sim.n)), r.spikesPerStep, r.stepUs, r.batchUs))

    // ---- per-neuron rate histogram -------------------------------------------
    var bins = [Int](repeating: 0, count: 5)   // silent, <1, 1-5, 5-20, >20 Hz
    for k in r.counts {
        let f = Double(k) * 1000 / Double(r.ms)
        bins[k == 0 ? 0 : (f < 1 ? 1 : (f < 5 ? 2 : (f < 20 ? 3 : 4)))] += 1
    }
    let pct = { (v: Int) in String(format: "%.1f%%", 100 * Double(v) / Double(sim.n)) }
    print("histogram: silent \(bins[0]) (\(pct(bins[0]))) | <1 Hz \(bins[1]) (\(pct(bins[1])))"
          + " | 1-5 Hz \(bins[2]) (\(pct(bins[2]))) | 5-20 Hz \(bins[3]) (\(pct(bins[3])))"
          + " | >20 Hz \(bins[4]) (\(pct(bins[4])))")

    // ---- per super class ------------------------------------------------------
    var byClass = [[Int]](repeating: [], count: c.superClassNames.count)
    for i in 0..<sim.n { byClass[Int(c.superClass[i])].append(i) }
    print("super classes (mean Hz, % silent):")
    for (k, idx) in byClass.enumerated() where !idx.isEmpty {
        let silent = idx.filter { r.counts[$0] == 0 }.count
        print(String(format: "  %-20@ n=%6d  %6.2f Hz  silent %5.1f%%",
                     c.superClassNames[k] as NSString, idx.count, hz(r, idx),
                     100 * Double(silent) / Double(idx.count)))
    }

    // ---- per role -------------------------------------------------------------
    let roles: [(String, [Int])] = [
        ("loom", sim.loomLeft + sim.loomRight), ("gf", sim.gf),
        ("dnaL", sim.dnaL), ("dnaR", sim.dnaR), ("mdn", sim.mdn), ("fwd", sim.fwd),
        ("groom", sim.groom), ("escw", sim.escw), ("ascend", sim.ascend), ("sens", sim.sens)]
    print("roles: " + roles.map { String(format: "%@ %.1f", $0.0, hz(r, $0.1)) }.joined(separator: " | "))

    // ---- most active cell types (>= 4 neurons, so singletons can't win) --------
    var typeIdx = [String: [Int]]()
    for i in 0..<sim.n { typeIdx[sim.types[i], default: []].append(i) }
    var byType: [(String, Int, Double)] = []
    for (name, idx) in typeIdx where idx.count >= 4 { byType.append((name, idx.count, hz(r, idx))) }
    // rate first, then name: ties at the 500 Hz ceiling must not reorder run to run
    byType.sort { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
    let top = byType.prefix(10)
    print("top cell types by mean rate (n >= 4):")
    for (name, n, f) in top { print(String(format: "  %-24@ n=%5d  %7.2f Hz", name as NSString, n, f)) }

    if let hottest = top.first { hotspotProbe(c, sim, r, hottest.0) }
    inWeightAudit(c, sim)

    // ---- network contribution: same seed, weights off --------------------------
    var zero = p
    zero.weightScale = 0
    guard let (simZ, rz) = collect(c, zero, settleMs: 1000, runMs: runMs) else {
        fputs("brainstats: could not build the weightScale=0 sim\n", stderr); exit(1)
    }
    print(String(format: "intrinsic only (weightScale 0): population %.2f Hz/neuron | %.0f spikes/step",
                 hz(rz, Array(0..<simZ.n)), rz.spikesPerStep))
    print("network contribution (intrinsic -> tuned, x = ratio):")
    let compare: [(String, [Int])] = [("population", Array(0..<sim.n))] + roles
    for (name, idx) in compare {
        let a = hz(rz, idx), b = hz(r, idx)
        let ratio = a > 0.001 ? String(format: "%.2fx", b / a) : (b > 0.001 ? "inf" : "-")
        print(String(format: "  %-11@ intrinsic %7.2f Hz -> tuned %7.2f Hz  (%@)",
                     name as NSString, a, b, ratio as NSString))
    }
    for (k, idx) in byClass.enumerated() where !idx.isEmpty {
        print(String(format: "  %-11@ intrinsic %7.2f Hz -> tuned %7.2f Hz",
                     c.superClassNames[k] as NSString, hz(rz, idx), hz(r, idx)))
    }
    exit(0)
}
