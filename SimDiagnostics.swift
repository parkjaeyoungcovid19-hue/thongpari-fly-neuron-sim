// SimDiagnostics.swift — headless sim/body self-tests: `--simtest` (circuit
// invariants + GPU benchmark), `--behaviortest` (sim -> 3D body end-to-end) and
// `--v4timingtest` (deterministic lockstep timing against Coordinator).
import Cocoa
import SceneKit

// MARK: - Sim test (headless circuit invariants + throughput)

func runSimtest() {
    guard let c = loadConnectome(),
          let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) else {
        fputs("no data/ — run etl.py first\n", stderr); exit(1)
    }
    // the 30 s throughput line stays on here: one long run, and it is the same
    // production log path the app uses (--behaviortest makes many short sims,
    // so it stays quiet there)
    print("connectome: \(sim.n) neurons | \(c.e) edges | \(sim.deviceName)"
          + " | fixed point Q\(Int(log2(Double(sim.fixedPointScale))))")
    print("groups: loom L/R \(sim.loomLeft.count)/\(sim.loomRight.count)"
          + " | GF: \(sim.gf.count) | DNa L/R: \(sim.dnaL.count)/\(sim.dnaR.count) | MDN: \(sim.mdn.count)"
          + " | DNp09: \(sim.fwd.count) | DNg11: \(sim.groom.count) | escW: \(sim.escw.count)"
          + " | ascend: \(sim.ascend.count) | sens: \(sim.sens.count)")

    // Phase 1: 4 s spontaneous activity
    var gfSpont = 0
    for _ in 0..<40 { sim.step(100); if sim.consumeGF() { gfSpont += 1 } }
    let popHz = Float(sim.totalSpikes) / 4.0 / Float(sim.n)
    print(String(format: "spontaneous 4s: pop %.2f Hz/neuron, LC %.1f Hz, DNa02 L/R %.1f/%.1f Hz, "
                 + "MDN %.1f Hz, GF spikes: %d", popHz, sim.rateLoom, sim.rateDNaL, sim.rateDNaR,
                 sim.rateMDN, gfSpont))

    // Closed-loop bootstrap probe: a real body starts stationary, so gaitDrive
    // is initially zero.  DNp09 must still occasionally cross the locomotor
    // entry threshold from network activity alone, otherwise body->gait->DNp09
    // becomes a self-locking zero-feedback loop.
    sim.gaitDrive = 0
    var bootstrapWalkOn = 0, bootstrapSamples = 0
    var bootstrapFwdMin = Float.greatestFiniteMagnitude, bootstrapFwdMax: Float = 0
    for ms in 0..<5_000 {
        sim.step(1)
        if ms % 10 == 0 {
            bootstrapSamples += 1
            let w = SignalBuilder.walkDrive(sim.rateFwd)
            if w > 0.22 { bootstrapWalkOn += 1 }
            bootstrapFwdMin = min(bootstrapFwdMin, sim.rateFwd)
            bootstrapFwdMax = max(bootstrapFwdMax, sim.rateFwd)
        }
    }
    let bootstrapPct = 100 * Float(bootstrapWalkOn) / Float(max(1, bootstrapSamples))
    print(String(format: "stationary bootstrap 5s: walk-drive on %.0f%%, DNp09 %.1f-%.1f Hz",
                 bootstrapPct, bootstrapFwdMin, bootstrapFwdMax))

    // Phase 2: abrupt loom, as produced by a cursor lunge (step, not ramp)
    var gfLatencyMs = -1
    var gfLoom = 0
    for ms in 0..<400 {
        sim.loomL = 1.0
        sim.loomR = 0.5
        sim.step(1)
        if sim.consumeGF() {
            gfLoom += 1
            if gfLatencyMs < 0 { gfLatencyMs = ms }
        }
    }
    sim.loomL = 0; sim.loomR = 0
    print(String(format: "abrupt loom 0.4s: LC rate %.1f Hz, GF spikes %d, first at %d ms",
                 sim.rateLoom, gfLoom, gfLatencyMs))

    // Phase 3: 20 s with walking proprioception; do behavior states emerge?
    var walkOn = 0, groomOn = 0, samples = 0
    var fwdMin = Float.greatestFiniteMagnitude, fwdMax: Float = 0
    for ms in 0..<20_000 {
        sim.gaitDrive = 0.5
        sim.gaitPhase = Float(ms % 125) / 125    // 8 Hz gait
        sim.step(1)
        if ms % 10 == 0 {
            samples += 1
            if SignalBuilder.walkDrive(sim.rateFwd) > 0.22 { walkOn += 1 }
            if SignalBuilder.groomDrive(sim.rateGroom) > 0.5 { groomOn += 1 }
            fwdMin = min(fwdMin, sim.rateFwd); fwdMax = max(fwdMax, sim.rateFwd)
        }
    }
    print(String(format: "behavior 20s: walk-drive on %.0f%%, groom-drive on %.0f%%, "
                 + "DNp09 %.1f-%.1f Hz, pop %.1f Hz", 100 * Float(walkOn) / Float(samples),
                 100 * Float(groomOn) / Float(samples), fwdMin, fwdMax, sim.ratePop))

    // Phase 3b: midday siesta must slow the fly down, not paralyze it
    sim.activityScale = 1 - (1 - 0.55) * 0.35   // = 0.84, the compressed siesta scale
    var siestaWalkOn = 0, siestaSamples = 0
    for ms in 0..<15_000 {
        sim.step(1)
        if ms % 10 == 0 {
            siestaSamples += 1
            if SignalBuilder.walkDrive(sim.rateFwd) > 0.22 { siestaWalkOn += 1 }
        }
    }
    sim.activityScale = 1
    let siestaPct = 100 * Float(siestaWalkOn) / Float(siestaSamples)
    print(String(format: "siesta 15s (scale 0.84): walk-drive on %.0f%%", siestaPct))

    // Phase 4: air puff (fast cursor whoosh) for 1 s — wind startle pathway
    var gfPuff = 0
    for _ in 0..<1000 {
        sim.airPuff = 1.0
        sim.step(1)
        if sim.consumeGF() { gfPuff += 1 }
    }
    sim.airPuff = 0
    print("air puff 1s: GF spikes \(gfPuff)")

    // Phase 5: gentle left-eye-only loom 1 s — steering response probe
    for _ in 0..<500 { sim.step(1); _ = sim.consumeGF() }   // settle
    let diff0 = sim.rateDNaL - sim.rateDNaR
    for _ in 0..<1000 {
        sim.loomL = 0.30; sim.loomR = 0
        sim.step(1)
        _ = sim.consumeGF()
    }
    let diff1 = sim.rateDNaL - sim.rateDNaR
    sim.loomL = 0
    print(String(format: "left-eye loom: DNa L-R rate diff %+.1f -> %+.1f Hz, LC %.1f Hz",
                 diff0, diff1, sim.rateLoom))

    // Phase 6: click-stimulation probes (what the interactive brain window does)
    sim.stimulate(sim.gf, strength: 0.5, durationMs: 40)
    sim.step(60)
    let gfStim = sim.consumeGF()
    sim.stimulate(sim.groom, strength: 0.25, durationMs: 400)
    sim.step(400)
    let groomStim = sim.rateGroom
    _ = sim.consumeGF()
    print(String(format: "click probes: GF cluster -> spike %@, DNg11 cluster -> groom rate %.0f Hz",
                 gfStim ? "yes" : "NO", groomStim))

    // Phase 7: GPU state consistency. Right after a step, every neuron in the
    // spike list must sit at v = 0 with a full refractory period, the list must
    // hold no duplicates, and the group histogram must agree with it.
    var consistent = true
    var checkedSteps = 0, checkedSpikes = 0, checkedGrouped = 0
    for _ in 0..<200 {
        sim.step(1)
        let spikes = sim.lastStepSpikes()
        let v = sim.membrane()
        let refr = sim.debugRefr()
        let hist = sim.lastStepGroupCounts()
        guard v.count == sim.n, refr.count == sim.n else { consistent = false; break }
        var seen = Set<Int32>()
        var grouped = 0
        for s in spikes {
            let i = Int(s)
            if i < 0 || i >= sim.n || !seen.insert(s).inserted { consistent = false; break }
            if v[i] != 0 || refr[i] != 2 { consistent = false; break }
            if sim.roles[i] != "other" && sim.roles[i] != "ascend" && sim.roles[i] != "sens" {
                grouped += 1
            }
        }
        if Int(hist[1...8].reduce(0, +)) != grouped { consistent = false }
        if !consistent { break }
        checkedSteps += 1; checkedSpikes += spikes.count; checkedGrouped += grouped
    }
    print("state check: \(checkedSteps) steps, \(checkedSpikes) spikers"
          + " (\(checkedGrouped) role-tagged) match membrane/refractory/histogram"
          + " -> \(consistent ? "consistent" : "INCONSISTENT")")

    // Phase 8: throughput. The render loop steps in batches of 8-50 ms, so the
    // 16-step number is the one that has to clear real time.
    func bench(_ batch: Int, steps: Int) -> (us: Double, spikes: Double) {
        sim.step(50)                       // warm up / flush
        let s0 = sim.totalSpikes
        let t0 = DispatchTime.now()
        var done = 0
        while done < steps { sim.step(batch); done += batch }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1000
        return (us / Double(done), Double(sim.totalSpikes - s0) / Double(done))
    }
    let b16 = bench(16, steps: 2000)
    let b1 = bench(1, steps: 2000)
    let realtime = b16.us < 1000
    print(String(format: "bench 16-step batches: %.0f µs/step, %.0f spikes/step", b16.us, b16.spikes))
    print(String(format: "bench  1-step batches: %.0f µs/step, %.0f spikes/step", b1.us, b1.spikes))
    print("\(realtime ? "PASS" : "FAIL") realtime: 16-step batches "
          + String(format: "%.0f µs/step (budget 1000)", b16.us))
    if b16.spikes > 0.2 * Double(sim.n) {
        sim.activityScale = 0.3
        let b16q = bench(16, steps: 2000)
        sim.activityScale = 1
        print(String(format: "bench 16-step @ activityScale 0.3: %.0f µs/step, %.0f spikes/step",
                     b16q.us, b16q.spikes))
    }

    let pass = gfSpont == 0 && gfLoom > 0 && walkOn > 0 && gfStim && siestaPct > 3
        && consistent && realtime
    print(pass ? "PASS: GF silent at rest, fires on loom; locomotor drive fluctuates; stim works; siesta alive"
               : "FAIL: tune weights/noise")
    exit(pass ? 0 : 1)
}

// MARK: - Behavior test (headless sim -> 3D body end-to-end)

func runBehaviorTest() {
    guard let connectome = loadConnectome() else {
        fputs("no data/ — run etl.py first\n", stderr); exit(1)
    }
    let bounds = CGSize(width: 1512, height: 982)
    let dt: CGFloat = 1.0 / 60.0
    var failures = 0

    func scenario(_ name: String, stim: (MetalSim) -> Void, hold: CGFloat,
                  setup: ((Fly) -> Void)? = nil,
                  check: (Fly) -> Bool, describe: (Fly) -> String) {
        // the connectome's CSR buffers and compiled kernels are shared, so a
        // fresh per-scenario sim only reallocates its own ~7 MB of state
        guard let sim = MetalSim(connectome: connectome, spikeBus: nil, seed: SIM_SEED) else {
            failures += 1; print("FAIL  \(name): no Metal sim"); return
        }
        sim.perfLogIntervalMs = 0
        let builder = SignalBuilder()
        let fly = Fly(at: .zero)
        fly.state = .idle
        fly.speed = 0
        setup?(fly)
        // settle the network, drain any startup GF latch
        sim.step(400)
        _ = sim.consumeGF()
        stim(sim)
        var passed = false
        var frames = Int(hold / dt)
        while frames > 0 {
            frames -= 1
            sim.step(Int((dt * 1000).rounded()))
            let s = builder.make(sim, dt: dt)
            fly.update(dt: dt, bounds: bounds, mouse: nil, signals: s)
            if check(fly) { passed = true; break }
        }
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL")  \(name): \(describe(fly))")
    }

    scenario("GF stim -> escape flight",
             stim: { $0.stimulate($0.gf, strength: 0.5, durationMs: 40) }, hold: 0.5,
             check: { $0.state == .flying },
             describe: { "state=\($0.state)" })

    scenario("DNg11 stim -> grooming",
             stim: { $0.stimulate($0.groom, strength: 0.25, durationMs: 600) }, hold: 1.5,
             check: { $0.state == .grooming },
             describe: { "state=\($0.state)" })

    scenario("DNp09 stim -> walks, speed rises (capped)",
             stim: { $0.stimulate($0.fwd, strength: 0.25, durationMs: 1200) }, hold: 1.5,
             check: { $0.state == .walking && $0.speed > 40 && $0.speed < 100 },
             describe: { "state=\($0.state) speed=\(Int($0.speed))" })

    scenario("MDN stim (from idle) -> backward walk",
             stim: { $0.stimulate($0.mdn, strength: 0.3, durationMs: 600) }, hold: 1.2,
             check: { $0.backwardTimer > 0 },
             describe: { "backwardTimer=\(String(format: "%.2f", $0.backwardTimer))" })

    var heading0: CGFloat = 0
    scenario("DNa-left stim -> left (CCW) turn while walking",
             stim: { $0.stimulate($0.dnaL, strength: 0.3, durationMs: 900) }, hold: 1.4,
             setup: { fly in
                 fly.state = .walking
                 fly.speed = 30
                 fly.heading = 0
                 heading0 = 0
             },
             check: { $0.heading - heading0 > 0.25 },
             describe: { "heading change \(String(format: "%+.2f", $0.heading - heading0)) rad" })

    scenario("moderate loom -> fear response (dart or escape)",
             stim: { sim in
                 sim.loomL = 0.45; sim.loomR = 0.45
             }, hold: 1.0,
             check: { ($0.state == .walking && $0.speed > 100) || $0.state == .flying },
             describe: { "state=\($0.state) speed=\(Int($0.speed))" })

    scenario("tap near fly -> startle escape via sensory pathway",
             stim: { $0.stimulate($0.sens, strength: 0.45, durationMs: 150) }, hold: 0.8,
             check: { $0.state == .flying },
             describe: { "state=\($0.state)" })

    // ---- body-level environment checks (hand-built signals, no sim) ----
    func bodyCheck(_ name: String, _ run: () -> (Bool, String)) {
        let (ok, detail) = run()
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
    }
    var walkSignals = BrainSignals()
    walkSignals.walkDrive = 0.6

    bodyCheck("ledge follow window edge") {
        let fly = Fly(at: CGPoint(x: 0, y: -55))
        fly.state = .walking; fly.speed = 30; fly.heading = 0
        fly.terrain = [Ledge(y: -40, x0: -300, x1: 300, id: 1)]
        // Attachment in the live fly is intentionally stochastic.  The old
        // regression waited for that random latch and therefore failed a few
        // percent of otherwise-correct runs.  Seed the *state under test*
        // directly and verify deterministic edge following here; randomness is
        // not a correctness gate.
        fly.ledge = fly.terrain[0]
        for _ in 0..<120 {
            fly.update(dt: dt, bounds: bounds, mouse: nil, signals: walkSignals)
            if fly.ledge != nil && abs(fly.pos.y + 40) < 8 { return (true, "attached, y=\(Int(fly.pos.y))") }
        }
        return (false, "state=\(fly.state) y=\(Int(fly.pos.y)) ledge=\(fly.ledge != nil)")
    }

    bodyCheck("window closes underfoot -> takeoff") {
        let fly = Fly(at: CGPoint(x: 0, y: -40))
        fly.state = .walking; fly.speed = 25; fly.heading = 0
        fly.terrain = [Ledge(y: -40, x0: -300, x1: 300, id: 1)]
        fly.ledge = fly.terrain[0]
        fly.terrain = []
        for _ in 0..<60 {
            fly.update(dt: dt, bounds: bounds, mouse: nil, signals: walkSignals)
            if fly.state == .flying { return (true, "took off") }
        }
        return (false, "state=\(fly.state)")
    }

    bodyCheck("sleep signal -> sleeping; wake -> grooming") {
        let fly = Fly(at: .zero)
        fly.state = .idle
        var s = BrainSignals(); s.sleep = true
        for _ in 0..<60 { fly.update(dt: dt, bounds: bounds, mouse: nil, signals: s) }
        guard fly.state == .sleeping else { return (false, "no sleep: \(fly.state)") }
        s.sleep = false
        fly.update(dt: dt, bounds: bounds, mouse: nil, signals: s)
        return (fly.state == .grooming, "woke to \(fly.state)")
    }

    bodyCheck("thermal tempo scales walking speed") {
        let fly = Fly(at: .zero)
        fly.state = .walking; fly.speed = 20; fly.heading = 0
        var cool = walkSignals; cool.tempo = 1.0
        for _ in 0..<120 { fly.update(dt: dt, bounds: bounds, mouse: nil, signals: cool) }
        let coolSpeed = fly.speed
        var hot = walkSignals; hot.tempo = 1.5
        for _ in 0..<120 { fly.update(dt: dt, bounds: bounds, mouse: nil, signals: hot) }
        let hotSpeed = fly.speed
        return (fly.state == .walking && hotSpeed > coolSpeed + 10,
                "cool \(Int(coolSpeed)) -> hot \(Int(hotSpeed)) pt/s")
    }

    bodyCheck("flight: altitude drives scale; escape flies higher than casual") {
        func flight(escape: Bool, effort: CGFloat?) -> (alt: CGFloat, scale: CGFloat) {
            let fly = Fly(at: .zero)
            fly.state = .idle
            fly.startFlight(bounds: bounds, escape: escape, effort: effort)
            var maxAlt: CGFloat = 0, maxScale: CGFloat = 0
            var frames = 0
            while fly.state == .flying && frames < 400 {
                frames += 1
                fly.update(dt: dt, bounds: bounds, mouse: nil, signals: BrainSignals())
                maxAlt = max(maxAlt, fly.alt)
                maxScale = max(maxScale, fly.node.scale.x)
            }
            return (maxAlt, maxScale)
        }
        let esc = flight(escape: true, effort: nil)
        let casual = flight(escape: false, effort: 0.45)
        let ok = esc.alt > casual.alt + 0.15 && esc.scale > FLY_SCALE * 1.5
            && abs(esc.scale - FLY_SCALE * (1 + 0.8 * esc.alt)) < 0.15
        return (ok, String(format: "escape alt %.2f scale %.2f | casual alt %.2f scale %.2f",
                           esc.alt, esc.scale, casual.alt, casual.scale))
    }

    bodyCheck("flight: wings actually beat") {
        let fly = Fly(at: .zero)
        fly.state = .idle
        fly.startFlight(bounds: bounds, effort: 0.8)
        var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
        for _ in 0..<30 where fly.state == .flying {
            fly.update(dt: dt, bounds: bounds, mouse: nil, signals: BrainSignals())
            let z = fly.model.foldedWings.childNodes[0].eulerAngles.z
            lo = min(lo, z); hi = max(hi, z)
        }
        return (hi - lo > 0.25, String(format: "wing sweep %.2f rad over 0.5 s", hi - lo))
    }

    bodyCheck("escape-DN activity mid-flight raises wing-beat effort") {
        let fly = Fly(at: .zero)
        fly.state = .idle
        fly.startFlight(bounds: bounds, effort: 0.5)
        let calm = BrainSignals()
        for _ in 0..<12 { fly.update(dt: dt, bounds: bounds, mouse: nil, signals: calm) }
        let calmEffort = fly.effortCurrent
        var hot = BrainSignals(); hot.wingDrive = 1.0; hot.arousal = 0.6
        for _ in 0..<12 where fly.state == .flying {
            fly.update(dt: dt, bounds: bounds, mouse: nil, signals: hot)
        }
        let hotEffort = fly.effortCurrent
        return (fly.state == .flying && hotEffort > calmEffort + 0.2,
                String(format: "effort %.2f -> %.2f", calmEffort, hotEffort))
    }

    bodyCheck("threat while grounded raises the wings (no takeoff)") {
        let fly = Fly(at: .zero)
        fly.state = .walking; fly.speed = 20
        fly.dartCooldown = 99   // isolate the posture from darting
        var threat = BrainSignals(); threat.wingDrive = 0.9; threat.walkDrive = 0.4
        for _ in 0..<40 { fly.update(dt: dt, bounds: bounds, mouse: nil, signals: threat) }
        let x = fly.model.foldedWings.childNodes[0].eulerAngles.x
        return (fly.state != .flying && fly.wingRaise > 0.6 && x < -0.2,
                String(format: "raise %.2f, wing tilt %.2f rad", fly.wingRaise, x))
    }

    bodyCheck("landing is smooth: no scale/height snap at touchdown") {
        let fly = Fly(at: .zero)
        fly.state = .idle
        fly.startFlight(bounds: bounds, escape: true)
        var prevScale = fly.node.scale.x, prevZ = fly.node.position.z
        var maxDS: CGFloat = 0, maxDZ: CGFloat = 0
        var post = 20, frames = 0
        var landed = false
        while post > 0 && frames < 600 {
            frames += 1
            fly.update(dt: dt, bounds: bounds, mouse: nil, signals: BrainSignals())
            maxDS = max(maxDS, abs(fly.node.scale.x - prevScale))
            maxDZ = max(maxDZ, abs(fly.node.position.z - prevZ))
            prevScale = fly.node.scale.x; prevZ = fly.node.position.z
            if fly.state != .flying { landed = true; post -= 1 }
        }
        return (landed && maxDS < 0.2 && maxDZ < 25,
                String(format: "landed=%@, max per-frame Δscale %.2f, Δz %.1f",
                       landed ? "yes" : "NO", maxDS, maxDZ))
    }

    bodyCheck("circadian curve: siesta + night dips, dawn/dusk peaks") {
        let night = circadianActivity(hour: 3), dawn = circadianActivity(hour: 9)
        let siesta = circadianActivity(hour: 14), dusk = circadianActivity(hour: 18)
        let ok = night < 0.4 && dawn > 0.9 && siesta < 0.7 && siesta > 0.3 && dusk > 0.9
        return (ok, String(format: "3h %.2f, 9h %.2f, 14h %.2f, 18h %.2f", night, dawn, siesta, dusk))
    }

    print(failures == 0 ? "ALL BEHAVIOR TESTS PASS" : "\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - V4 deterministic timing test

func runV4TimingTest() {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }
    guard let c = loadConnectome(),
          let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) else {
        fputs("V4 timing test: no connectome/Metal sim\n", stderr)
        exit(1)
    }
    sim.perfLogIntervalMs = 0
    let coordinator = Coordinator(bounds: CGSize(width: 800, height: 600), sim: sim)
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = coordinator.scene

    struct Digest {
        var membrane: [Float]
        var refr: [UInt8]
        var spikes: [Int32]
        var groups: [UInt32]
        var totalSpikes: Int
        var signalTrace: [[Double]]
        var simMs: Int
    }
    func feedback(_ q: Int, staleWallStamp: Bool) -> FlyGymBodyFeedback {
        var b = FlyGymBodyFeedback()
        b.simTime = Double(q + 1) * LabSession.quantumSeconds
        b.simDt = LabSession.quantumSeconds
        b.wallDt = 0
        b.vx = q < 3 ? 0.006 : 0.018
        b.yawRate = q >= 5 && q <= 7 ? -0.8 : 0.12
        b.gaitPhase = Double((q * 3) % 10) / 10.0
        b.contacts = q.isMultiple(of: 2) ? [1,0,1,0,1,0] : [0,1,0,1,0,1]
        b.leftContact = 0.5; b.rightContact = 0.5
        if q == 3 || q == 4 { b.loomLeft = 0.7; b.loomRight = 0.25 }
        if q >= 2 && q <= 6 { b.odorLeft = 0.55; b.odorRight = 0.20 }
        if q >= 5 && q <= 8 {
            b.windStrength = 0.4; b.windDirectionDeg = 70; b.windSensory = true
        }
        if q == 7 { b.touchStrength = 0.35; b.touchSensory = true }
        b.headingRad = 0.3
        b.receivedAt = staleWallStamp ? Date(timeIntervalSinceNow: -10) : Date()
        return b
    }
    func signalVector(_ s: BrainSignals?) -> [Double] {
        guard let s else { return [] }
        return [s.escape ? 1 : 0, Double(s.nervous), Double(s.turnBias),
                s.backward ? 1 : 0, Double(s.walkDrive), Double(s.groomDrive),
                Double(s.wingDrive), Double(s.arousal), Double(s.tempo), s.sleep ? 1 : 0]
    }
    func callbacks(hz: Double) -> [TimeInterval] {
        var out: [TimeInterval] = [0]
        var t = 1.0 / hz
        while t <= 0.240 + 1e-9 { out.append(t); t += 1.0 / hz }
        return out
    }
    let profiles: [(String, [TimeInterval], Bool)] = [
        ("30fps", callbacks(hz: 30), false),
        ("60fps", callbacks(hz: 60), true),
        ("120fps", callbacks(hz: 120), true),
        ("stall", [0, 1.0/60, 2.0/60, 3.0/60, 0.180, 0.197, 0.214, 0.231], true),
    ]
    func trial(_ profile: (String, [TimeInterval], Bool)) -> Digest {
        coordinator.prepareV4TimingTest(seed: SIM_SEED)
        var renderIndex = 0
        var trace: [[Double]] = []
        for q in 0..<12 {
            let boundary = Double(q + 1) * LabSession.quantumSeconds
            while renderIndex < profile.1.count && profile.1[renderIndex] <= boundary + 1e-12 {
                coordinator.renderer(renderer, updateAtTime: profile.1[renderIndex])
                renderIndex += 1
            }
            trace.append(signalVector(coordinator.advanceV4TimingQuantumForTesting(
                feedback(q, staleWallStamp: profile.2))))
        }
        while renderIndex < profile.1.count {
            coordinator.renderer(renderer, updateAtTime: profile.1[renderIndex])
            renderIndex += 1
        }
        return Digest(membrane: sim.membrane(), refr: sim.debugRefr(),
                      spikes: sim.lastStepSpikes().sorted(),
                      groups: sim.lastStepGroupCounts(), totalSpikes: sim.totalSpikes,
                      signalTrace: trace, simMs: sim.simMs)
    }

    let baseline = trial(profiles[0])
    check("deterministic neural test advances exactly 12x20ms", baseline.simMs == 240,
          "simMs=\(baseline.simMs)")
    for profile in profiles.dropFirst() {
        let d = trial(profile)
        let equal = d.simMs == baseline.simMs
            && d.totalSpikes == baseline.totalSpikes
            && d.membrane == baseline.membrane
            && d.refr == baseline.refr
            && d.spikes == baseline.spikes
            && d.groups == baseline.groups
            && d.signalTrace == baseline.signalTrace
        check("V4 neural + SignalBuilder invariant at \(profile.0)", equal,
              "simMs=\(d.simMs) spikes=\(d.totalSpikes)/\(baseline.totalSpikes)")
    }
    check("accepted deterministic body result ignores wall-age freshness",
          profiles.dropFirst().allSatisfy { trial($0).signalTrace == baseline.signalTrace })

    print(failures == 0 ? "ALL V4 TIMING TESTS PASS" : "\(failures) V4 TIMING FAILURES")
    exit(failures == 0 ? 0 : 1)
}
