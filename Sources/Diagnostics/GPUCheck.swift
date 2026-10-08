// GPUCheck.swift — `./ThongpariFlyNeuronSim --gpucheck`: an independent CPU reference for
// the Metal whole-brain sim, compared to it step by step.
//
// `RefSim` is written from the ORIGINAL 668-neuron CPU sim (`git show
// HEAD:Sim.swift`, `LIFSim.step`) run over the full connectome: the same
// per-step order (refractory/leak/baseline/noise -> loom/gait/puff -> click stim
// -> delayed inhibition -> threshold/reset -> propagation), the same
// pre-decremented refractory test, the same immediate excitation clamped at -2,
// the same 4 ms inhibition ring, the same group-rate EMAs and the same stim
// bookkeeping (`untilMs = simMs + duration`, active while `simMs < untilMs`).
//
// Two departures are deliberate, and are the port's whole point:
//   * synaptic accumulation is Int32 fixed point (Q18) instead of one float add
//     per edge, so the sum is order-independent;
//   * the membrane-noise draw is a hash of (seed, step, neuron) instead of a
//     sequential system RNG, so both sides make the same noise decisions.
//
// Placement note: HEAD applied a spike's excitation at the END of step t and
// decayed it at t+1; the GPU parks it in an accumulator and applies it at the
// START of t+1, before the decay. `(v + exc) * decay + baseline` is the same
// float expression either way. The reference keeps HEAD's placement and exposes
// `membrane` = v *before* that end-of-step excitation, which is exactly what the
// GPU's v buffer holds between steps.

import Foundation
import simd

// MARK: - RNG (transcribed from LIF.metal, not from MetalSim.swift)

@inline(__always) private func gcPcg(_ v: UInt32) -> UInt32 {
    let state = v &* 747_796_405 &+ 2_891_336_453
    let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277_803_737
    return (word >> 22) ^ word
}
@inline(__always) private func gcUnit(_ h: UInt32) -> Float { Float(h >> 8) * 5.9604645e-8 }
@inline(__always) private func gcDraw(_ seed: UInt32, _ salt: UInt32, _ i: UInt32) -> Float {
    gcUnit(gcPcg(gcPcg(seed &+ salt) &+ i))
}
private let gcSaltBaseline: UInt32 = 0x51ED_2701
private let gcSaltPhase: UInt32 = 0x2F1B_3C4D
private let gcSaltBurst: UInt32 = 0x7A3B_9F11
private let gcNoiseSalt: UInt32 = 2_654_435_761

// Histogram ids are part of the CPU reference contract, not copied from the
// live GPU group buffer. Keep these values in sync with the documented kernel
// ABI and derive membership independently from the shipped connectome fields.
private enum GCGroup {
    static let loom: UInt8 = 1, gf: UInt8 = 2, dnaL: UInt8 = 3, dnaR: UInt8 = 4
    static let mdn: UInt8 = 5, fwd: UInt8 = 6, groom: UInt8 = 7, escw: UInt8 = 8
    static let foodL: UInt8 = 9, foodR: UInt8 = 10
    static let thermoWarm: UInt8 = 11, thermoCool: UInt8 = 12
    static let windC: UInt8 = 13, windE: UInt8 = 14
    static let slots = 16

    static let names = [
        "ungrouped", "loom", "gf", "dnaL", "dnaR", "mdn", "fwd", "groom", "escw",
        "foodL", "foodR", "thermoWarm", "thermoCool", "windC", "windE", "reserved"
    ]
}

private func gcHistogram(_ spikes: ArraySlice<Int32>, groupOf: [UInt8]) -> [UInt32] {
    var g = [UInt32](repeating: 0, count: GCGroup.slots)
    for spike in spikes {
        let i = Int(spike)
        if i >= 0 && i < groupOf.count { g[Int(groupOf[i])] += 1 }
    }
    g[0] = 0
    return g
}

// MARK: - CPU reference

final class RefSim {
    let n: Int
    let e: Int
    let p: SimParams
    let seed: UInt32
    let fxScale: Float
    let invFx: Float
    let ringSlots: Int
    private let c: Connectome

    // per-neuron configuration
    private(set) var baseline: [Float]
    let groupOf: [UInt8]
    let inputKind: [UInt8]
    let phase: [Float]

    // state (raw buffers: this is a test harness, they live for the process)
    private let vP: UnsafeMutablePointer<Float>      // HEAD's v (end-of-step excitation applied)
    private let vObsP: UnsafeMutablePointer<Float>   // v as the GPU's buffer holds it
    private let baseP: UnsafeMutablePointer<Float>
    private let refrP: UnsafeMutablePointer<UInt8>
    private let excP: UnsafeMutablePointer<Int32>
    private let inhP: UnsafeMutablePointer<Int32>
    private let rowP: UnsafeMutablePointer<UInt32>
    private let colP: UnsafeMutablePointer<UInt32>
    let wP: UnsafeMutablePointer<Int32>
    private var spikeBuf: [Int32]
    private var extAcc: [Float]
    private var spikeCount = 0

    // Which float contractions the shader's compiler actually emits. `mathMode
    // = .safe` forbids reassociation but NOT fused multiply-add contraction, and
    // an fma rounds once where `a * b + c` rounds twice. Probed at startup.
    var fusedLeak = false        // v*decay + baseline*scale -> fma
    var fusedSyn = false         // v + acc*invFx            -> fma
    var gaitFma = 0              // bit 0: 0.5 + 0.5*sin, bit 1: v + drive*(...)
    /// HEAD added each active stim's strength to v in turn; the GPU sums them
    /// into one `extInput` value per neuron and adds that once. Same result
    /// unless two stims overlap on the same neuron.
    var stimSummed = false

    // inputs
    var loomL: Float = 0, loomR: Float = 0
    var gaitDrive: Float = 0, gaitPhase: Float = 0, airPuff: Float = 0
    var activityScale: Float = 1, sensoryGate: Float = 1

    // outputs
    private(set) var rateLoom: Float = 0, rateDNaL: Float = 0, rateDNaR: Float = 0
    private(set) var rateMDN: Float = 0, rateFwd: Float = 0, rateGroom: Float = 0
    private(set) var rateEscW: Float = 0, ratePop: Float = 0
    private(set) var simMs = 0, totalSpikes = 0
    private(set) var gfLatch = false
    private(set) var lastGroupCounts = [UInt32](repeating: 0, count: GCGroup.slots)
    var lastSpikes: [Int32] { Array(spikeBuf[0..<spikeCount]) }
    var membrane: [Float] { [Float](UnsafeBufferPointer(start: vObsP, count: n)) }
    var refractory: [UInt8] { [UInt8](UnsafeBufferPointer(start: refrP, count: n)) }

    private(set) var burstUntil = 0, burstNext = 12_000
    private var burstCounter: UInt32 = 0
    var burstActive: Bool { simMs < burstUntil }
    private let nLoom, nDNaL, nDNaR, nMDN, nFwd, nGroom, nEscW, nPop: Float

    // click stimulation, same bookkeeping as HEAD:Sim.swift
    private struct Stim { let idx: [Int]; let strength: Float; let durationMs: Int; var untilMs = 0 }
    private var pendingStims: [Stim] = []
    private var activeStims: [Stim] = []

    init(_ c: Connectome, params: SimParams, seed: UInt32, fxScale: Float) {
        self.c = c
        n = c.n; e = c.e; p = params; self.seed = seed; self.fxScale = fxScale
        invFx = 1 / fxScale
        ringSlots = params.inhDelayMs + 1

        // ---- per-neuron config, from the roles/sides in the connectome --------
        var base = [Float](repeating: 0, count: n)
        var grp = [UInt8](repeating: 0, count: n)
        var kind = [UInt8](repeating: 0, count: n)
        var ph = [Float](repeating: 0, count: n)
        // Resting drive is drawn from the neuron's super-class range (SimParams
        // .baselineByClass); LC4/LPLC2 have their own range. Transcribed from the
        // parameter table, not from MetalSim's loop.
        let ranges = c.superClassNames.map { params.baselineByClass[$0] ?? params.baselineFallback }
        func gcRange(_ r: ClosedRange<Float>, _ i: Int) -> Float {
            r.lowerBound + (r.upperBound - r.lowerBound) * gcDraw(seed, gcSaltBaseline, UInt32(i))
        }
        var loomL = 0, loomR = 0, dnaL = 0, dnaR = 0, mdn = 0, fwd = 0, groom = 0, escw = 0
        for i in 0..<n {
            let left = c.side[i] == 1
            let hetero = gcRange(ranges[Int(c.superClass[i])], i)
            switch c.role[i] {
            case Role.lc4, Role.lplc2:
                base[i] = gcRange(params.baselineLoom, i); grp[i] = GCGroup.loom; kind[i] = left ? 1 : 2
                if left { loomL += 1 } else { loomR += 1 }
            case Role.gf:
                base[i] = params.baselineGF; grp[i] = GCGroup.gf
            case Role.dna01, Role.dna02:
                base[i] = params.baselineCommand
                grp[i] = left ? GCGroup.dnaL : GCGroup.dnaR
                if left { dnaL += 1 } else { dnaR += 1 }
            case Role.mdn:   base[i] = params.baselineCommand; grp[i] = GCGroup.mdn; mdn += 1
            case Role.dnp09: base[i] = params.baselineFwd;     grp[i] = GCGroup.fwd; fwd += 1
            case Role.dng11: base[i] = params.baselineCommand; grp[i] = GCGroup.groom; groom += 1
            case Role.escw:  base[i] = params.baselineCommand; grp[i] = GCGroup.escw; escw += 1
            case Role.ascend:
                base[i] = hetero; kind[i] = 3
                ph[i] = 2 * Float.pi * gcDraw(seed, gcSaltPhase, UInt32(i))
            case Role.sens:  base[i] = hetero; kind[i] = 4
            default:         base[i] = hetero
            }

            // Virtual Fly Lab V2 receptor telemetry groups. Membership is
            // reconstructed from cell type, side and outgoing-row presence so
            // this CPU oracle remains independent of MetalSim.groupOf.
            if grp[i] == 0 {
                let type = c.typeName[i]
                if type == "ORN_DM1" || type == "ORN_VA2" {
                    if c.side[i] == 1 { grp[i] = GCGroup.foodL }
                    else if c.side[i] == 2 { grp[i] = GCGroup.foodR }
                } else if type == "TRN_VP2" {
                    grp[i] = GCGroup.thermoWarm
                } else if type == "TRN_VP3a" || type == "TRN_VP3b" {
                    grp[i] = GCGroup.thermoCool
                } else if type.hasPrefix("JO-C") && c.rowStart[i + 1] > c.rowStart[i] {
                    grp[i] = GCGroup.windC
                } else if type.hasPrefix("JO-E") && c.rowStart[i + 1] > c.rowStart[i] {
                    grp[i] = GCGroup.windE
                }
            }
        }
        baseline = base; groupOf = grp; inputKind = kind; phase = ph
        nLoom = Float(max(1, loomL + loomR))
        nDNaL = Float(max(1, dnaL)); nDNaR = Float(max(1, dnaR))
        nMDN = Float(max(1, mdn)); nFwd = Float(max(1, fwd))
        nGroom = Float(max(1, groom)); nEscW = Float(max(1, escw))
        nPop = Float(max(1, n))

        // ---- buffers ----------------------------------------------------------
        vP = .allocate(capacity: n); vObsP = .allocate(capacity: n)
        baseP = .allocate(capacity: n); refrP = .allocate(capacity: n)
        excP = .allocate(capacity: n); inhP = .allocate(capacity: n * ringSlots)
        rowP = .allocate(capacity: n + 1); colP = .allocate(capacity: e)
        wP = .allocate(capacity: e)
        spikeBuf = [Int32](repeating: 0, count: n)
        extAcc = [Float](repeating: 0, count: n)
        vP.update(repeating: 0, count: n); vObsP.update(repeating: 0, count: n)
        refrP.update(repeating: 0, count: n)
        excP.update(repeating: 0, count: n); inhP.update(repeating: 0, count: n * ringSlots)
        baseP.update(from: base, count: n)
        rowP.update(from: c.rowStart, count: n + 1)
        c.colIdxData.withUnsafeBytes { raw in
            colP.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt32.self), count: e)
        }
        quantizeWeights(rowFactored: false)
    }

    /// Load-time weight transform. HEAD:Sim.swift's rules (weightScale, and the
    /// electrical boost on lc4/lplc2 -> gf and sens -> gf, one factor each) plus
    /// the port's documented neuromodulator scaling and the giant fiber's own
    /// input gain (`gfInputScale`, on every edge into the GF), then Q18 rounding.
    /// `rowFactored` folds the row-constant factors first the way MetalShared
    /// does; the two differ only in float rounding order.
    func quantizeWeights(rowFactored: Bool) {
        let mod = p.modScale, ws = p.weightScale, fx = fxScale
        c.weightData.withUnsafeBytes { wb in
            let w16 = wb.baseAddress!.assumingMemoryBound(to: Int16.self)
            for i in 0..<n {
                let a = Int(c.rowStart[i]), b = Int(c.rowStart[i + 1])
                if a == b { continue }
                let isMod = c.isModulatory[Int(c.nt[i])]
                let r = c.role[i]
                let electrical = r == Role.lc4 || r == Role.lplc2 || r == Role.sens
                let boost = r == Role.sens ? p.sensGFBoost : p.gapJunctionBoost
                let g = ws * (isMod ? mod : 1) * fx
                for k in a..<b {
                    let toGF = c.role[Int(colP[k])] == Role.gf
                    let post: Float = toGF ? (electrical ? boost : p.gfInputScale) : 1
                    if rowFactored {
                        wP[k] = Int32((Float(w16[k]) * g * post).rounded())
                    } else {
                        var w = Float(w16[k]) * ws
                        if isMod { w *= mod }
                        w *= post
                        wP[k] = Int32((w * fx).rounded())
                    }
                }
            }
        }
    }

    func reset() {
        vP.update(repeating: 0, count: n); vObsP.update(repeating: 0, count: n)
        refrP.update(repeating: 0, count: n)
        excP.update(repeating: 0, count: n); inhP.update(repeating: 0, count: n * ringSlots)
        simMs = 0; totalSpikes = 0; spikeCount = 0; gfLatch = false
        rateLoom = 0; rateDNaL = 0; rateDNaR = 0; rateMDN = 0
        rateFwd = 0; rateGroom = 0; rateEscW = 0; ratePop = 0
        burstUntil = 0; burstNext = 12_000; burstCounter = 0
        pendingStims.removeAll(); activeStims.removeAll()
        lastGroupCounts = [UInt32](repeating: 0, count: GCGroup.slots)
        loomL = 0; loomR = 0; gaitDrive = 0; gaitPhase = 0; airPuff = 0
        activityScale = 1; sensoryGate = 1
    }

    func setBaseline(_ values: [Float]) {
        guard values.count == n else { return }
        baseline = values
        baseP.update(from: values, count: n)
    }

    func consumeGF() -> Bool { let s = gfLatch; gfLatch = false; return s }

    func stimulate(_ indices: [Int], strength: Float, durationMs: Int) {
        guard !indices.isEmpty else { return }
        pendingStims.append(Stim(idx: indices, strength: strength, durationMs: durationMs))
        if pendingStims.count > 8 { pendingStims.removeFirst() }
    }

    /// Out-edges of `i` as (post, fixed-point weight), aggregated per target.
    func outEdges(_ i: Int) -> [Int: Int32] {
        var out: [Int: Int32] = [:]
        for k in Int(c.rowStart[i])..<Int(c.rowStart[i + 1]) {
            out[Int(colP[k]), default: 0] += wP[k]
        }
        return out
    }

    // MARK: step

    func step(_ ms: Int) {
        guard ms > 0 else { return }
        for var s in pendingStims { s.untilMs = simMs + s.durationMs; activeStims.append(s) }
        pendingStims.removeAll()
        activeStims.removeAll { simMs >= $0.untilMs }
        for _ in 0..<ms { stepOne() }
    }

    private func stepOne() {
        simMs += 1
        if simMs >= burstNext {
            burstUntil = simMs + p.burstMs
            burstCounter &+= 1
            let span = p.burstGapMs.upperBound - p.burstGapMs.lowerBound + 1
            burstNext = simMs + p.burstGapMs.lowerBound
                + Int(gcDraw(seed, gcSaltBurst, burstCounter) * Float(span))
        }
        let pn = (simMs < burstUntil ? p.pNoise * p.burstFactor : p.pNoise) * activityScale
        let dL: Float = loomL > 0.001 ? loomL * p.loomGain * sensoryGate : 0
        let dR: Float = loomR > 0.001 ? loomR * p.loomGain * sensoryGate : 0
        let dA: Float = gaitDrive > 0.001 ? gaitDrive * p.ascendGain : 0
        let dP: Float = airPuff > 0.001 ? airPuff * p.airPuffGain * sensoryGate : 0
        let gaitPh = gaitPhase * 2 * Float.pi
        let decay = p.decay, kick = p.noiseKick, aScale = activityScale
        let floorV = p.floorV, threshold = p.threshold
        let h0 = gcPcg(seed &+ (UInt32(truncatingIfNeeded: simMs) &* gcNoiseSalt))
        let curBase = ((simMs - 1) % ringSlots) * n
        let inhBase = ((simMs - 1 + p.inhDelayMs) % ringSlots) * n

        // 1. refractory / leak / baseline / noise, then the sensory drives
        //    (loom, gait, air puff) — applied refractory or not, as in HEAD.
        for i in 0..<n {
            var vi = vP[i]
            let r = refrP[i]
            if r > 0 {
                refrP[i] = r - 1
                vi *= decay
            } else {
                vi = fusedLeak ? (baseP[i] * aScale).addingProduct(vi, decay)
                               : vi * decay + baseP[i] * aScale
                if gcUnit(gcPcg(h0 &+ UInt32(i))) < pn { vi += kick }
            }
            switch inputKind[i] {
            case 1: vi += dL
            case 2: vi += dR
            case 3:
                let sv = sin(gaitPh + phase[i])
                let shape = gaitFma & 1 != 0 ? Float(0.5).addingProduct(0.5, sv) : 0.5 + 0.5 * sv
                vi = gaitFma & 2 != 0 ? vi.addingProduct(dA, shape) : vi + dA * shape
            case 4: vi += dP
            default: break
            }
            vP[i] = vi
        }

        // 2. click stimulation
        if stimSummed {
            var touched: [Int] = []
            for s in activeStims where simMs < s.untilMs {
                for i in s.idx where i >= 0 && i < n {
                    if extAcc[i] == 0 { touched.append(i) }
                    extAcc[i] += s.strength
                }
            }
            for i in touched { vP[i] += extAcc[i]; extAcc[i] = 0 }
        } else {
            for s in activeStims where simMs < s.untilMs {
                for i in s.idx where i >= 0 && i < n { vP[i] += s.strength }
            }
        }

        // 3. inhibition scheduled for this millisecond, then threshold/reset
        spikeCount = 0
        for i in 0..<n {
            var vi = vP[i]
            let q = inhP[curBase + i]
            if q != 0 {
                vi = max(floorV, fusedSyn ? vi.addingProduct(Float(q), invFx)
                                          : vi + Float(q) * invFx)
                inhP[curBase + i] = 0
            }
            if refrP[i] == 0 && vi >= threshold {
                vi = 0
                refrP[i] = UInt8(p.refractoryMs)
                spikeBuf[spikeCount] = Int32(i); spikeCount += 1
            }
            vP[i] = vi
        }
        totalSpikes += spikeCount

        // 4. group histogram + rate EMAs
        let g = gcHistogram(spikeBuf[0..<spikeCount], groupOf: groupOf)
        lastGroupCounts = g
        if g[2] > 0 { gfLatch = true }
        let a = p.rateAlpha
        rateLoom += (Float(g[1]) * 1000 / nLoom - rateLoom) * a
        rateDNaL += (Float(g[3]) * 1000 / nDNaL - rateDNaL) * a
        rateDNaR += (Float(g[4]) * 1000 / nDNaR - rateDNaR) * a
        rateMDN  += (Float(g[5]) * 1000 / nMDN  - rateMDN)  * a
        rateFwd  += (Float(g[6]) * 1000 / nFwd  - rateFwd)  * a
        rateGroom += (Float(g[7]) * 1000 / nGroom - rateGroom) * a
        rateEscW += (Float(g[8]) * 1000 / nEscW - rateEscW) * a
        ratePop  += (Float(spikeCount) * 1000 / nPop - ratePop) * a

        // 5. propagation: excitation now (accumulated, one clamped add), the
        //    inhibition into the +4 ms ring slot
        for t in 0..<spikeCount {
            let i = Int(spikeBuf[t])
            for k in Int(rowP[i])..<Int(rowP[i + 1]) {
                let w = wP[k]
                let j = Int(colP[k])
                if w >= 0 { excP[j] &+= w } else { inhP[inhBase + j] &+= w }
            }
        }
        // the GPU's v buffer is snapshotted here: it holds the step's membrane
        // *before* this excitation, which it applies at the top of the next step
        vObsP.update(from: vP, count: n)
        for i in 0..<n where excP[i] != 0 {
            let x = Float(excP[i])
            vP[i] = max(floorV, fusedSyn ? vP[i].addingProduct(x, invFx) : vP[i] + x * invFx)
            excP[i] = 0
        }
    }
}

// MARK: - Comparison

private struct ScenarioResult {
    var name: String
    var steps = 0
    var spikesEqual = true, refrEqual = true, groupsEqual = true, ratesEqual = true
    var maxDV: Float = 0, argmax = -1, maxDVStep = -1
    var firstDivergence = -1, firstSpikeDivergence = -1
    var detail: [String] = []
    var refSpikes = 0, gpuSpikes = 0, gfSpikes = 0
    var tol: Float = 1e-5        // membrane tolerance; only gait needs a loose one
    var ok: Bool { spikesEqual && refrEqual && groupsEqual && ratesEqual && maxDV <= tol }
}

/// Best guess at why two membranes differ, from the size of the difference.
private func explainDelta(_ d: Float, invFx: Float, kick: Float) -> String {
    let a = abs(d)
    if a == 0 { return "no membrane difference (spike-set difference only)" }
    if a >= kick * 0.99 && a <= kick * 1.01 { return "≈ noiseKick: the noise draw differed" }
    if a >= 0.5 { return "large: a spike/reset or a whole synaptic volley differs" }
    if a <= invFx * 4 { return "≈ \(Int((a / invFx).rounded())) fixed-point units: weight quantization / accumulation" }
    if a < 1e-6 { return "≈ 1 ulp: float rounding order (fma / reassociation)" }
    return "intermediate: an upstream spike difference has propagated"
}

private func compareStep(_ sim: MetalSim, _ ref: RefSim, _ r: inout ScenarioResult, step: Int) {
    let gv = sim.membrane(), rv = ref.membrane
    let gr = sim.debugRefr(), rr = ref.refractory
    let gs = sim.lastStepSpikes().sorted(), rs = ref.lastSpikes.sorted()
    let gg = sim.lastStepGroupCounts(), rg = ref.lastGroupCounts
    r.steps += 1
    r.gpuSpikes += gs.count; r.refSpikes += rs.count; r.gfSpikes += Int(gg[2])

    var dv: Float = 0, arg = -1
    for i in 0..<ref.n {
        let d = abs(gv[i] - rv[i])
        if d > dv { dv = d; arg = i }
    }
    if dv > r.maxDV { r.maxDV = dv; r.argmax = arg; r.maxDVStep = step }

    // the spike column also carries what rides on the spike list: the sim clock
    // and the giant-fiber takeoff latch (both consumed, so this is per step)
    let spikesEqual = gs == rs && sim.simMs == ref.simMs && sim.consumeGF() == ref.consumeGF()
    let refrEqual = gr == rr
    let groupsEqual = Array(gg.prefix(16)) == Array(rg.prefix(16))
    if !spikesEqual {
        r.spikesEqual = false
        if r.firstSpikeDivergence < 0 { r.firstSpikeDivergence = step }
    }
    if !refrEqual { r.refrEqual = false }
    if !groupsEqual { r.groupsEqual = false }

    var rateBad: [String] = []
    let rates: [(String, Float, Float)] = [
        ("rateLoom", ref.rateLoom, sim.rateLoom), ("rateDNaL", ref.rateDNaL, sim.rateDNaL),
        ("rateDNaR", ref.rateDNaR, sim.rateDNaR), ("rateMDN", ref.rateMDN, sim.rateMDN),
        ("rateFwd", ref.rateFwd, sim.rateFwd), ("rateGroom", ref.rateGroom, sim.rateGroom),
        ("rateEscW", ref.rateEscW, sim.rateEscW), ("ratePop", ref.ratePop, sim.ratePop)]
    for (name, a, b) in rates {
        let rel = abs(a - b) / max(1e-6, max(abs(a), abs(b)))
        if rel > 1e-3 { rateBad.append(String(format: "%@ %.6g vs %.6g (rel %.3g)", name, a, b, rel)) }
    }
    if !rateBad.isEmpty { r.ratesEqual = false }

    guard r.firstDivergence < 0 else { return }
    guard !spikesEqual || !refrEqual || !groupsEqual || !rateBad.isEmpty || dv > r.tol else { return }
    r.firstDivergence = step
    r.detail.append("first divergence at step \(step) (simMs \(sim.simMs)/\(ref.simMs))")
    if !spikesEqual {
        let onlyRef = Set(rs).subtracting(gs).sorted(), onlyGPU = Set(gs).subtracting(rs).sorted()
        r.detail.append("  spikes: ref \(rs.count), gpu \(gs.count); ref-only \(onlyRef.count), gpu-only \(onlyGPU.count)")
        for i in (onlyRef + onlyGPU).prefix(5).map({ Int($0) }) {
            r.detail.append(String(format: "  n%d role %@ ref v=%.9g gpu v=%.9g refr ref/gpu %d/%d base %.6g",
                                   i, sim.roles[i], rv[i], gv[i], rr[i], gr[i], ref.baseline[i]))
        }
    }
    if !refrEqual {
        let bad = (0..<ref.n).filter { gr[$0] != rr[$0] }
        r.detail.append("  refr differs on \(bad.count) neurons, first \(bad.prefix(5).map(String.init).joined(separator: ","))")
    }
    if !groupsEqual {
        var diffs: [String] = []
        for i in 1...14 where rg[i] != gg[i] {
            diffs.append("\(i):\(GCGroup.names[i]) ref=\(rg[i]) gpu=\(gg[i])")
        }
        r.detail.append("  group diffs " + (diffs.isEmpty ? "none in slots 1...14" : diffs.joined(separator: ", ")))
    }
    if !rateBad.isEmpty { r.detail.append("  rates: " + rateBad.joined(separator: "; ")) }
    if dv > 0, arg >= 0 {
        r.detail.append(String(format: "  max |Δv| %.6g at n%d (role %@): ref %.9g gpu %.9g — %@",
                               dv, arg, sim.roles[arg], rv[arg], gv[arg],
                               explainDelta(gv[arg] - rv[arg], invFx: ref.invFx, kick: ref.p.noiseKick)))
    }
}

private func report(_ r: ScenarioResult) -> String {
    let flag = r.ok ? "ok" : "FAIL"
    var s = String(format: "%-22@ %4d steps | spikes+gf %@ (gf %d) | refr %@ | groups %@ | rates %@ | max|Δv| %.3g%@ | %@",
                   r.name as NSString, r.steps,
                   r.spikesEqual ? "=" : "X", r.gfSpikes, r.refrEqual ? "=" : "X",
                   r.groupsEqual ? "=" : "X", r.ratesEqual ? "=" : "X", r.maxDV,
                   r.argmax >= 0 ? " (n\(r.argmax) @step \(r.maxDVStep))" : "", flag)
    if r.firstSpikeDivergence >= 0 { s += " | spike sets first differ at step \(r.firstSpikeDivergence)" }
    if r.firstDivergence >= 0 { s += "\n" + r.detail.joined(separator: "\n") }
    return s
}

// MARK: - Entry point

func runGPUCheck() {
    var failures: [String] = []
    let t0 = DispatchTime.now()
    print("== gpucheck: independent CPU reference vs the Metal whole-brain sim ==")
    guard let c = loadConnectome() else {
        fputs("no data/ — run etl.py first\n", stderr); exit(1)
    }
    let seed: UInt32 = SIM_SEED   // shipped default unless --seed pinned another
    let params = SimParams()
    func newSim(_ withBaseline: [Float]?) -> MetalSim? {
        guard let s = MetalSim(connectome: c, spikeBus: nil, seed: seed, params: params) else { return nil }
        s.perfLogIntervalMs = 0
        if let b = withBaseline { s.setBaseline(b) }
        return s
    }
    guard let sim0 = newSim(nil) else { fputs("no Metal sim\n", stderr); exit(1) }
    print("connectome: \(sim0.n) neurons, \(c.e) edges | fixed point Q\(Int(log2(Double(sim0.fixedPointScale))))"
          + " | \(sim0.deviceName) | seed 0x\(String(seed, radix: 16))")

    // ---- 0a. the RNG transcription -----------------------------------------
    var rngOK = true
    for v: UInt32 in [0, 1, 2, 7, 12345, 0x5EED_1F1F, 0xFFFF_FFFF, 2_654_435_761] {
        if gcPcg(v) != pcgHash(v) { rngOK = false }
        if gcUnit(gcPcg(v)) != pcgUnit(pcgHash(v)) { rngOK = false }
    }
    print("rng: LIF.metal pcg() transcription vs MetalSim.pcgHash -> \(rngOK ? "identical" : "MISMATCH")")
    if !rngOK { failures.append("PCG transcription mismatch") }

    // ---- 0b. the load-time weight transform --------------------------------
    let ref = RefSim(c, params: params, seed: seed, fxScale: sim0.fixedPointScale)

    // Negative control for the V2 receptor histogram oracle. Corrupt one known
    // receptor assignment in a private copy and prove the histogram comparison
    // notices it. This must not depend on MetalSim's runtime group buffer.
    if let receptor = ref.groupOf.indices.first(where: { ref.groupOf[$0] >= GCGroup.foodL && ref.groupOf[$0] <= GCGroup.windE }) {
        let oneSpike = [Int32(receptor)]
        let expected = gcHistogram(oneSpike[...], groupOf: ref.groupOf)
        var corrupted = ref.groupOf
        corrupted[receptor] = 0
        let bad = gcHistogram(oneSpike[...], groupOf: corrupted)
        let detected = expected != bad
        print("group oracle negative control: corrupt \(GCGroup.names[Int(ref.groupOf[receptor])]) n\(receptor) -> \(detected ? "detected" : "MISSED")")
        if !detected { failures.append("receptor histogram negative control was not detected") }
    } else {
        print("group oracle negative control: no V2 receptor-group neuron found")
        failures.append("no V2 receptor-group neuron available for histogram negative control")
    }
    var wDiff = 0, wMaxDiff: Int32 = 0, wOrder = "independent factor order"
    if let gpuW = c.gpu.shared?.weightFx {
        let g = gpuW.contents().bindMemory(to: Int32.self, capacity: c.e)
        func countDiffs() -> (Int, Int32) {
            var d = 0, m: Int32 = 0
            for k in 0..<c.e where g[k] != ref.wP[k] {
                d += 1; m = max(m, abs(g[k] - ref.wP[k]))
            }
            return (d, m)
        }
        (wDiff, wMaxDiff) = countDiffs()
        if wDiff > 0 {
            // retry with MetalShared's row-factored order: float multiplication is
            // not associative, so the reference has to adopt the shader's order.
            ref.quantizeWeights(rowFactored: true)
            let (d2, m2) = countDiffs()
            print("weights: \(wDiff) of \(c.e) differ with an independent factor order (max \(wMaxDiff) Q18 units);"
                  + " with MetalShared's order \(d2) differ")
            wDiff = d2; wMaxDiff = m2; wOrder = "MetalShared factor order"
        }
        print("weights: \(c.e) quantized edges, \(wDiff) differ from the GPU buffer"
              + " (max \(wMaxDiff) Q18 units, \(wOrder))")
        if wDiff > 0 { failures.append("\(wDiff) quantized weights differ from the GPU's") }
    } else {
        print("weights: GPU weight buffer unavailable, skipped")
        failures.append("could not read the GPU weight buffer")
    }

    // ---- 0c. the shader's float arithmetic + MetalSim.init's own baselines --
    // `mathMode = .safe` blocks reassociation but not fma contraction, and the
    // sim is chaotic enough that one ulp flips a spike within ~100 steps, so the
    // reference has to round the same way. This finds out which way that is.
    // These steps use MetalSim.init's own baselines (no setBaseline), so a
    // bit-exact variant also proves the reference's baseline/phase generation.
    var chosen = (leak: false, syn: false)
    var bestName = "", best: Float = .greatestFiniteMagnitude
    print("arithmetic probe — 120 steps at rest, MetalSim.init's own baselines:")
    for (name, leak, syn) in [("0 plain a*b+c", false, false), ("1 fma leak", true, false),
                              ("2 fma synaptic", false, true), ("3 fma leak+syn", true, true)] {
        ref.reset(); ref.fusedLeak = leak; ref.fusedSyn = syn
        guard let s = newSim(nil) else { continue }
        var r = ScenarioResult(name: "  " + name); r.tol = 0
        // 120 steps, not 20: a 1-ulp difference needs ~100 ms to flip a spike,
        // and that amplification is the reason the reference has to round alike.
        for k in 1...120 { s.step(1); ref.step(1); compareStep(s, ref, &r, step: k) }
        print(report(r))
        if r.maxDV < best { best = r.maxDV; bestName = name; chosen = (leak, syn) }
    }
    ref.fusedLeak = chosen.leak; ref.fusedSyn = chosen.syn
    print("reference arithmetic: \(bestName) (max |Δv| \(best))")
    if best != 0 {
        failures.append("no float-contraction variant reproduces the shader bit-exactly (best \(bestName), \(best))")
    }

    // ---- A/B/C: the main step-by-step comparison ----------------------------
    ref.reset()
    guard let sim = newSim(ref.baseline) else { fputs("no Metal sim\n", stderr); exit(1) }
    ref.setBaseline(ref.baseline)

    var rest = ScenarioResult(name: "A rest")
    for s in 1...300 {
        sim.step(1); ref.step(1)
        compareStep(sim, ref, &rest, step: s)
    }
    print(report(rest))
    if !rest.ok { failures.append("scenario A (rest)") }

    var loom = ScenarioResult(name: "B loom+puff")
    sim.loomL = 1; sim.loomR = 0.5; sim.airPuff = 0.3
    ref.loomL = 1; ref.loomR = 0.5; ref.airPuff = 0.3
    for s in 1...300 {
        sim.step(1); ref.step(1)
        compareStep(sim, ref, &loom, step: s)
    }
    sim.loomL = 0; sim.loomR = 0; sim.airPuff = 0
    ref.loomL = 0; ref.loomR = 0; ref.airPuff = 0
    print(report(loom))
    if !loom.ok { failures.append("scenario B (loom + air puff)") }

    // 200 "other" neurons, 0.5 for 7 ms — the click-stimulation path, stepped
    // one millisecond at a time so every step can be compared.
    let others = (0..<c.n).filter { c.role[$0] == Role.other }
    let stimIdx = stride(from: 0, to: others.count, by: max(1, others.count / 200))
        .prefix(200).map { others[$0] }
    var stim = ScenarioResult(name: "C stim 200x0.5/7ms")
    sim.stimulate(stimIdx, strength: 0.5, durationMs: 7)
    ref.stimulate(stimIdx, strength: 0.5, durationMs: 7)
    for s in 1...16 {
        sim.step(1); ref.step(1)
        compareStep(sim, ref, &stim, step: s)
    }
    print(report(stim))
    if !stim.ok { failures.append("scenario C (stim, 1 ms steps)") }
    // Siesta neuromodulation + sleep sensory gating: activityScale != 1 makes
    // `baseline * activityScale` and `pNoise * activityScale` inexact, and
    // sensoryGate scales the loom / air-puff drives.
    var modulated = ScenarioResult(name: "D scale .84 gate .6")
    sim.activityScale = 0.84; ref.activityScale = 0.84
    sim.sensoryGate = 0.6; ref.sensoryGate = 0.6
    sim.loomL = 0.7; ref.loomL = 0.7
    sim.loomR = 0.2; ref.loomR = 0.2
    sim.airPuff = 1.0; ref.airPuff = 1.0
    for s in 1...150 {
        sim.step(1); ref.step(1)
        compareStep(sim, ref, &modulated, step: s)
    }
    sim.activityScale = 1; ref.activityScale = 1
    sim.sensoryGate = 1; ref.sensoryGate = 1
    sim.loomL = 0; ref.loomL = 0; sim.loomR = 0; ref.loomR = 0
    sim.airPuff = 0; ref.airPuff = 0
    print(report(modulated))
    if !modulated.ok { failures.append("scenario D (activityScale 0.84, sensoryGate 0.6)") }

    // Two stims overlapping in time AND in their index sets, with different
    // durations (so the sub-batch splits twice). HEAD added each stim's strength
    // to v in turn; the GPU sums them into extInput and adds once, which is a
    // different float rounding on the neurons in the intersection.
    var multi = ScenarioResult(name: "E 2 overlapping stims")
    let setA = Array(others.prefix(300)), setB = Array(others[150..<450])
    sim.stimulate(setA, strength: 0.1, durationMs: 9)
    ref.stimulate(setA, strength: 0.1, durationMs: 9)
    sim.stimulate(setB, strength: 0.3, durationMs: 5)
    ref.stimulate(setB, strength: 0.3, durationMs: 5)
    for s in 1...20 {
        sim.step(1); ref.step(1)
        compareStep(sim, ref, &multi, step: s)
    }
    print(report(multi))
    if !multi.ok { failures.append("scenario E (two overlapping stims)") }

    print(String(format: "totals: ref %d spikes, gpu %d spikes over %d steps",
                 ref.totalSpikes, sim.totalSpikes, ref.simMs))
    if ref.totalSpikes != sim.totalSpikes { failures.append("total spike counts differ") }

    // Same scenario with the reference switched to the GPU's summation: if that
    // is the whole cause of E's delta, this is bit-exact.
    ref.reset(); ref.stimSummed = true
    if let sumSim = newSim(ref.baseline) {
        var summed = ScenarioResult(name: "E' same, GPU summing")
        summed.tol = 0
        sumSim.step(4); ref.step(4)
        sumSim.stimulate(setA, strength: 0.1, durationMs: 9)
        ref.stimulate(setA, strength: 0.1, durationMs: 9)
        sumSim.stimulate(setB, strength: 0.3, durationMs: 5)
        ref.stimulate(setB, strength: 0.3, durationMs: 5)
        for s in 1...20 {
            sumSim.step(1); ref.step(1)
            compareStep(sumSim, ref, &summed, step: s)
        }
        print(report(summed))
        if !summed.ok { failures.append("scenario E' (overlapping stims, GPU-style summation)") }
    }
    ref.stimSummed = false

    // ---- D. batch invariance -----------------------------------------------
    struct Snapshot { let v: [Float]; let refr: [UInt8]; let spikes: [Int32]; let groups: [UInt32] }
    func runPlan(_ plan: [Int], stimAt: Int? = nil, stimIdx: [Int] = []) -> Snapshot? {
        guard let s = newSim(ref.baseline) else { return nil }
        var done = 0
        for k in plan {
            if let at = stimAt, done == at { s.stimulate(stimIdx, strength: 0.5, durationMs: 7) }
            s.step(k); done += k
        }
        return Snapshot(v: s.membrane(), refr: s.debugRefr(),
                        spikes: s.lastStepSpikes().sorted(), groups: s.lastStepGroupCounts())
    }
    func sameSnapshot(_ a: Snapshot, _ b: Snapshot) -> (Bool, String) {
        var dv: Float = 0, arg = -1
        for i in 0..<a.v.count where abs(a.v[i] - b.v[i]) > dv { dv = abs(a.v[i] - b.v[i]); arg = i }
        let ok = dv == 0 && a.refr == b.refr && a.spikes == b.spikes && a.groups == b.groups
        return (ok, ok ? "bit-identical" :
            String(format: "max|Δv| %.6g at n%d, refr %@, spikes %@ (%d vs %d), groups %@",
                   dv, arg, a.refr == b.refr ? "=" : "X", a.spikes == b.spikes ? "=" : "X",
                   a.spikes.count, b.spikes.count, a.groups == b.groups ? "=" : "X"))
    }
    if let s1 = runPlan([Int](repeating: 1, count: 96)),
       let s16 = runPlan([Int](repeating: 16, count: 6)),
       let s50 = runPlan([50, 46]) {
        let (ok16, why16) = sameSnapshot(s1, s16)
        let (ok50, why50) = sameSnapshot(s1, s50)
        print("batch invariance 96 steps: 96x1 vs 6x16 -> \(why16); 96x1 vs 50+46 -> \(why50)")
        if !ok16 { failures.append("batch invariance 96x1 vs 6x16") }
        if !ok50 { failures.append("batch invariance 96x1 vs 50+46") }
    } else { failures.append("batch-invariance sims could not be built") }

    // ---- E. stim invariance (the sub-batch split at stim expiry) ------------
    if let a = runPlan([4] + [Int](repeating: 1, count: 16), stimAt: 4, stimIdx: stimIdx),
       let b = runPlan([4, 16], stimAt: 4, stimIdx: stimIdx) {
        let (ok, why) = sameSnapshot(a, b)
        print("stim invariance (0.5/7 ms on 200 neurons): 16x1 vs 1x16 -> \(why)")
        if !ok { failures.append("stim invariance 16x1 vs step(16)") }
    } else { failures.append("stim-invariance sims could not be built") }

    // ---- F. synaptic delay probe -------------------------------------------
    // Pick the neurons with the largest negative / positive out-weight sums,
    // force one spike, and time the arrival of the effect at their targets.
    var negSum = [Int64](repeating: 0, count: c.n), posSum = [Int64](repeating: 0, count: c.n)
    for i in 0..<c.n {
        for k in Int(c.rowStart[i])..<Int(c.rowStart[i + 1]) {
            let w = Int64(ref.wP[k])
            if w < 0 { negSum[i] += w } else { posSum[i] += w }
        }
    }
    let inhPre = (0..<c.n).min { negSum[$0] < negSum[$1] }!
    let excPre = (0..<c.n).max { posSum[$0] < posSum[$1] }!
    let invFx = 1 / sim.fixedPointScale
    let armStrength: Float = 12
    for (label, pre) in [("inhibitory", inhPre), ("excitatory", excPre)] {
        guard let ctrl = newSim(ref.baseline), let test = newSim(ref.baseline) else {
            failures.append("delay-probe sims could not be built"); break
        }
        for _ in 0..<40 { ctrl.step(1); test.step(1) }
        if ctrl.membrane() != test.membrane() {
            failures.append("delay probe (\(label)): two identically seeded sims diverged")
        }

        // durationMs 1 covers zero steps — `simMs < untilMs` is false on the only
        // step it could cover. Inherited verbatim from HEAD:Sim.swift.
        test.stimulate([pre], strength: armStrength, durationMs: 1)
        ctrl.step(1); test.step(1)
        // Control-relative: these hub neurons are spontaneously active at this
        // operating point, so "the test spiked" alone does not mean the stim did it.
        let noopSpike = test.lastStepSpikes().contains(Int32(pre))
            != ctrl.lastStepSpikes().contains(Int32(pre))
        let noopSame = ctrl.membrane() == test.membrane()
        print("delay probe (\(label) pre n\(pre)): durationMs 1 -> 0 stimulated steps"
              + " (spiked \(noopSpike), states still identical \(noopSame))")
        if noopSpike || !noopSame { failures.append("a durationMs 1 stim was not a no-op") }

        // Arm: the stim has to clear threshold on a non-refractory neuron in one
        // step. It is applied BEFORE the same step's inhibition (LIF.metal steps 3
        // then 4) and the -2 floor is applied after that sum, so it must out-run the
        // inhibition this neuron can meet in one millisecond — which for the biggest
        // out-weight hub is ~5.6 threshold units at this operating point. Hence
        // `armStrength`, not the +5 the 668-neuron circuit needed. The only bad case
        // left is the control spiking the same neuron by itself — then both runs
        // spike it, stay identical, and we simply try the next millisecond.
        var armed = false, attempts = 0, brokeEarly = false
        while !armed && attempts < 60 {
            attempts += 1
            if ctrl.debugRefr()[pre] != 0 { ctrl.step(1); test.step(1); continue }
            test.stimulate([pre], strength: armStrength, durationMs: 2)
            ctrl.step(1); test.step(1)
            armed = test.lastStepSpikes().contains(Int32(pre))
                && !ctrl.lastStepSpikes().contains(Int32(pre))
            if !armed && ctrl.membrane() != test.membrane() {
                failures.append("delay probe (\(label)): a failed arming attempt perturbed the state")
                brokeEarly = true; break
            }
        }
        if !armed && !brokeEarly { failures.append("delay probe (\(label)): could not force a clean spike") }
        guard armed else { continue }

        var firstDiff = [Int](repeating: 0, count: c.n)
        var delta = [Float](repeating: 0, count: c.n)
        var resetAt = [Set<Int32>](repeating: [], count: 9)   // spiked (v reset) per offset
        var clamped = [Set<Int>](repeating: [], count: 9)
        for off in 1...8 {
            ctrl.step(1); test.step(1)
            resetAt[off] = Set(ctrl.lastStepSpikes()).union(test.lastStepSpikes())
            let a = ctrl.membrane(), b = test.membrane()
            for j in 0..<c.n where firstDiff[j] == 0 && a[j] != b[j] {
                firstDiff[j] = off; delta[j] = b[j] - a[j]
            }
            for j in 0..<c.n where a[j] == ref.p.floorV || b[j] == ref.p.floorV { clamped[off].insert(j) }
        }
        let targets = ref.outEdges(pre)
        let exc = targets.filter { $0.value > 0 }, inh = targets.filter { $0.value < 0 }
        func histogram(_ set: [Int: Int32]) -> [(offset: Int, targets: Int)] {
            var h: [Int: Int] = [:]
            for (j, _) in set { h[firstDiff[j], default: 0] += 1 }
            return h.sorted { $0.key < $1.key }.map { (offset: $0.key, targets: $0.value) }
        }
        /// Arrival size at `off`, over the targets that neither spiked nor hit the
        /// -2 floor on that step (either of those erases the difference).
        func arrival(_ set: [Int: Int32], at off: Int, scale: Float) -> (Int, Int, Float) {
            var checked = 0, skipped = 0, worst: Float = 0
            for (j, w) in set where firstDiff[j] == off {
                if resetAt[off].contains(Int32(j)) || clamped[off].contains(j) { skipped += 1; continue }
                checked += 1
                worst = max(worst, abs(delta[j] - Float(w) * invFx * scale))
            }
            return (checked, skipped, worst)
        }
        let (nE, skipE, errE) = arrival(exc, at: 1, scale: sim.debugParams.decay)
        let (nI, skipI, errI) = arrival(inh, at: 4, scale: 1)
        print("  forced one spike after \(attempts) attempt(s) | \(exc.count) excitatory"
              + " / \(inh.count) inhibitory targets")
        print("  excitatory targets, first Δv at step offset: \(histogram(exc))")
        print("  inhibitory targets, first Δv at step offset: \(histogram(inh))")
        print(String(format: "  t+1: %d checked (%d spiked/clamped), max |Δv - w*decay| = %.3g;"
                     + "  t+4: %d checked (%d spiked/clamped), max |Δv - w| = %.3g",
                     nE, skipE, errE, nI, skipI, errI))
        if !exc.isEmpty && nE == 0 { failures.append("delay probe (\(label)): no excitatory target moved at t+1") }
        if !inh.isEmpty && nI == 0 { failures.append("delay probe (\(label)): no inhibitory target moved at t+4") }
        if errE > 1e-6 || errI > 1e-6 { failures.append("delay probe (\(label)): arrival size does not match the Q18 weight") }
        let strayE = histogram(exc).filter { $0.offset != 1 && $0.offset != 0 }.map(\.targets).reduce(0, +)
        let strayI = histogram(inh).filter { $0.offset != 4 && $0.offset != 0 }.map(\.targets).reduce(0, +)
        if strayE > exc.count / 20 { failures.append("delay probe (\(label)): \(strayE) excitatory targets moved off +1 ms") }
        if strayI > inh.count / 20 { failures.append("delay probe (\(label)): \(strayI) inhibitory targets moved off +4 ms") }
    }

    // ---- G. gait probe -------------------------------------------------------
    // The one op that cannot be assumed bit-identical: Metal's precise::sin vs
    // Swift's sinf, plus the two contraction candidates in the ascend drive
    // `v + drive * (0.5 + 0.5*sin(phase))`.
    let nAscend = ref.inputKind.filter { $0 == 3 }.count
    print("gait probe (gaitDrive 0.5, 8 Hz, 200 steps, \(nAscend) ascend neurons):")
    var gaitBest = Float.greatestFiniteMagnitude, gaitBestVariant = -1
    for variant in 0...3 {
        ref.reset(); ref.gaitFma = variant
        guard let gs = newSim(ref.baseline) else { continue }
        var r = ScenarioResult(name: "  gaitFma \(variant)")
        r.tol = 1e-4
        var ascendFirst: Float = 0, ascendMax: Float = 0
        for k in 1...200 {
            let ph = Float((k - 1) % 125) / 125
            gs.gaitPhase = ph; ref.gaitPhase = ph
            gs.gaitDrive = 0.5; ref.gaitDrive = 0.5
            gs.step(1); ref.step(1)
            compareStep(gs, ref, &r, step: k)
            let a = gs.membrane(), b = ref.membrane
            var m: Float = 0
            for i in 0..<c.n where ref.inputKind[i] == 3 { m = max(m, abs(a[i] - b[i])) }
            if k == 1 { ascendFirst = m }
            ascendMax = max(ascendMax, m)
        }
        print(report(r))
        print(String(format: "    ascend-only |Δv|: step 1 %.3g, worst over 200 steps %.3g",
                     ascendFirst, ascendMax))
        if ascendFirst < gaitBest { gaitBest = ascendFirst; gaitBestVariant = variant }
    }
    print("gait: best ascend-only step-1 |Δv| = \(gaitBest) with gaitFma \(gaitBestVariant)")
    if gaitBest > 1e-4 { failures.append("gait probe: ascend |Δv| > 1e-4 on the first step") }

    // ---- H. long run through the first arousal burst ------------------------
    // The burst branch (p x6 for 400 ms, next gap drawn from the seeded stream)
    // only fires at simMs 12,000, so it needs a long run. The GPU is stepped in
    // 50 ms batches while fast-forwarding, then 1 ms at a time across the burst.
    ref.reset(); ref.gaitFma = 0
    guard let longSim = newSim(ref.baseline) else { fputs("no Metal sim\n", stderr); exit(1) }
    var long = ScenarioResult(name: "H 12.2 s + burst")
    while ref.simMs < 11_900 {
        longSim.step(50); ref.step(50)
        compareStep(longSim, ref, &long, step: ref.simMs)
    }
    let popBefore = ref.ratePop
    for _ in 0..<300 {
        longSim.step(1); ref.step(1)
        compareStep(longSim, ref, &long, step: ref.simMs)
    }
    let popAfter = ref.ratePop
    print(report(long))
    print(String(format: "  %d simulated ms, %d comparison points; population rate %.2f -> %.2f Hz"
                 + " across the burst; reference burst window [%d, %d), next at %d",
                 ref.simMs, long.steps, popBefore, popAfter,
                 ref.burstUntil - ref.p.burstMs, ref.burstUntil, ref.burstNext))
    if !long.ok { failures.append("scenario H (12.2 s run through the first arousal burst)") }
    if !ref.burstActive || popAfter <= popBefore {
        failures.append("the arousal burst branch was not exercised (active \(ref.burstActive),"
                        + " pop \(popBefore) -> \(popAfter))")
    }

    // ---- verdict -------------------------------------------------------------
    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
    print(String(format: "gpucheck ran in %.1f s", secs))
    if failures.isEmpty {
        print("GPUCHECK PASS")
        exit(0)
    }
    print("GPUCHECK FAIL: " + failures.joined(separator: "; "))
    exit(1)
}
