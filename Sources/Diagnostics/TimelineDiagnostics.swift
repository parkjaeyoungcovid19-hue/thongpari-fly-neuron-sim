#if DIAGNOSTICS
// --timelinetest: V7.6 integrated timeline. Fixture checks drive the real
// InteractionTimeline / EventWindowBuffer with hand-made samples and compare
// with hand-computed values; the real-path section runs a real MetalSim through
// the app's own `advanceNeuralQuantum` and checks the motor/body/eye lanes and
// the finalized window against independent queries.
import Cocoa

/// Observer armed on [10…13] (zero spikes: the neural side is V7.5's test), a
/// timeline and the buffer that reads it.
private final class TLFixture {
    let observer = NeuralObserver(rootIds: (0..<100).map { 720_575_940_000_000_000 + UInt64($0) })
    let timeline: InteractionTimeline
    let buffer: EventWindowBuffer
    private(set) var tick = 0

    init(timeline: InteractionTimeline = InteractionTimeline()) {
        self.timeline = timeline
        observer.arm([10, 11, 12, 13], name: "fixture", omitted: 0, startTick: 1)
        buffer = EventWindowBuffer(observer: observer, timeline: timeline)
    }

    func feed(to end: Int, batch: Int = 20) {
        while tick < end {
            let k = min(batch, end - tick)
            let rows = [UInt8](repeating: 0, count: k * ObservationCapability.exactSelectionLimit)
            rows.withUnsafeBufferPointer {
                observer.record(firstTick: tick + 1, count: k, rows: $0.baseAddress!, rowWidth: ObservationCapability.exactSelectionLimit)
            }
            tick += k
            buffer.advance()
        }
    }
}

private func motor(_ walk: Double, turn: Double = 0, escape: Bool = false) -> BrainSignals {
    var s = BrainSignals()
    s.walkDrive = CGFloat(walk); s.turnBias = CGFloat(turn); s.escape = escape
    return s
}

private func jsonObject(_ w: InteractionWindow) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any]) ?? [:]
}

private func decode(_ obj: [String: Any]) -> InteractionWindow? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return try? JSONDecoder().decode(InteractionWindow.self, from: d)
}

func runTimelineTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check(name, ok, detail) }
    func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= eps } ?? false }

    // ---- no interpolation: a 5 Hz eye stays 5 Hz ----------------------------------
    do {
        let tl = InteractionTimeline()
        let eyeTicks = stride(from: 150, through: 1350, by: 200).map { $0 }     // 7 samples in 1…1500
        for (i, t) in eyeTicks.enumerated() { tl.recordEye(tick: t, origin: .sampledAt, loomL: Float(i) / 10, loomR: 0.5) }
        let slice = tl.eyeSlice(1...1500)
        check("5 Hz eye over 1,500 ticks: exactly the 7 recorded samples, at their ticks",
              slice.samples.map(\.tick) == eyeTicks && slice.samples.count == 7, "\(slice.samples.map(\.tick))")
        check("measured period is the real one (200 ticks), not a 1 ms rate", slice.periodTicks == 200)
        var populated = 0, foreign = 0
        for t in 1...1500 {
            let one = tl.eyeSlice(t...t).samples
            if !one.isEmpty { populated += 1 }
            if one.contains(where: { $0.tick != t }) { foreign += 1 }
        }
        check("a 1 kHz query (every tick) finds values only at the 7 sample ticks, nothing in between",
              populated == 7 && foreign == 0 && tl.eyeSlice(151...349).samples.isEmpty)
        check("loom values are the stored ones, untouched", slice.samples.map(\.loomL) == (0..<7).map { Float($0) / 10 })
        check("an eye lane with one sample reports no period (never invented)",
              InteractionTimeline().eyeSlice(1...10).periodTicks == nil && tl.eyeSlice(150...150).periodTicks == nil)
    }

    // ---- untimed / out-of-order / reset / evictions are counted ---------------------
    do {
        let tl = InteractionTimeline(eyeCapacity: 2, motorCapacity: 4)
        check("a sample with no usable tick is counted untimed, not placed",
              !tl.recordEye(tick: nil, origin: .sampledAt, loomL: 1, loomR: 1) && !tl.recordEye(tick: 0, origin: .sampledAt, loomL: 1, loomR: 1)
                && tl.stats().untimed == 2 && tl.eyeSlice(1...100).samples.isEmpty)
        tl.recordMotor(tick: 50, motor(0.1))
        check("an older motor tick is rejected and counted out of order", !tl.recordMotor(tick: 40, motor(0.2)) && tl.stats().outOfOrder == 1
              && tl.motorSlice(1...100).samples.count == 1)
        for t in stride(from: 60, through: 100, by: 10) { tl.recordMotor(tick: t, motor(0.3)) }   // 6 recorded, ring holds 4
        let st = tl.stats()
        check("overwriting the oldest motor sample is counted, not silent (6 recorded, 2 evicted, 4 kept)",
              st.recorded[TimelineLane.motor.rawValue] == 6 && st.evicted[TimelineLane.motor.rawValue] == 2
                && tl.motorSlice(1...200).samples.map(\.tick) == [70, 80, 90, 100] && tl.motorSlice(1...200).evictedThrough == 60)
        tl.reset()
        check("reset (brain epoch) clears every lane, keeps the cumulative counters and starts a new epoch",
              tl.motorSlice(1...200).samples.isEmpty && tl.motorSlice(1...200).evictedThrough == 0
                && tl.stats().evicted[TimelineLane.motor.rawValue] == 2 && tl.stats().epoch == 1)
    }

    // ---- sensory lane: drives record their edges only; packets carry origin ------------
    do {
        let tl = InteractionTimeline()
        for (t, w) in [(10, 0.0), (20, 0.5), (30, 0.5), (40, 0.0), (50, 0.0)] {
            tl.recordLocalDrives(tick: t, loomL: 0, loomR: 0, windStrength: w, windDirectionDeg: 90, touch: 0)
        }
        check("local wind drive: only the active ticks and the falling edge are recorded (20, 30, 40)",
              tl.sensorySlice(1...100, channel: .localWind).samples.map(\.tick) == [20, 30, 40]
                && tl.sensorySlice(1...100, channel: .localLoom).samples.isEmpty
                && tl.sensorySlice(1...100).samples.allSatisfy { $0.origin == .sampledAt && $0.sensoryOn == nil })
        var fb = FlyGymBodyFeedback()
        fb.receivedAt = Date(timeIntervalSinceReferenceDate: 100)
        fb.positionXmm = 1.5; fb.positionYmm = -2; fb.headingRad = 0.25; fb.vx = 0.01; fb.yawRate = 0.4
        fb.windStrength = 0.7; fb.windSensory = true; fb.eyeSampleSimTick = 195
        fb.loomLeft = 0.6; fb.loomRight = 0.1
        let live = InteractionTimeline()
        live.ingestBody(fb, tickNow: 300, lockstepEndTick: 300)
        live.ingestBody(fb, tickNow: 301, lockstepEndTick: 301)      // the same packet delivered again
        let eye = live.eyeSlice(1...1000).samples, body = live.bodySlice(1...1000).samples
        check("lockstep packet: body at the quantum end and the eye at its true sample tick, both sampled_at; re-delivery ignored",
              eye.map(\.tick) == [195] && eye[0].origin == .sampledAt && body.count == 1 && body[0].tick == 300
                && body[0].origin == .sampledAt && body[0].source == .flygym && body[0].x == 1.5 && live.stats().recorded[TimelineLane.body.rawValue] == 1)
        let wind = live.sensorySlice(1...1000, channel: .wind).samples
        check("backend wind sample keeps the packet's strength, direction and sensory flag",
              wind.count == 1 && wind[0].a == 0.7 && wind[0].sensoryOn == true && live.sensorySlice(1...1000, channel: .touch).samples.isEmpty)
        let rcv = InteractionTimeline()
        rcv.ingestBody(fb, tickNow: 480, lockstepEndTick: nil)
        var next = fb; next.receivedAt = Date(timeIntervalSinceReferenceDate: 101)
        rcv.ingestBody(next, tickNow: 496, lockstepEndTick: nil)    // same eye_sample_sim_tick: not a new frame
        check("interactive packet: everything is received_at at the brain tick; an unchanged eye stamp is not a new frame",
              rcv.eyeSlice(1...1000).samples.map(\.tick) == [480] && rcv.eyeSlice(1...1000).samples[0].origin == .receivedAt
                && rcv.bodySlice(1...1000).samples.map(\.tick) == [480, 496]
                && rcv.bodySlice(1...1000).samples.allSatisfy { $0.origin == .receivedAt })
        let lookup = rcv.firstSampledTick(.eye, in: 1...1000)
        check("a received_at-only lane never yields a sample tick", lookup.tick == nil && lookup.receivedOnly)
    }

    // ---- V7-03: applied tick and sensory sample tick stay separate -------------------------
    do {
        let f = TLFixture()
        for t in [300, 500, 700, 900, 1100] { f.timeline.recordEye(tick: t, origin: .sampledAt, loomL: 0.5, loomR: 0.5) }   // 5 Hz
        f.timeline.recordSensory(tick: 800, origin: .receivedAt, channel: .wind, a: 0.5, sensoryOn: true)   // wind: received only
        f.feed(to: 700)
        let flash = f.buffer.noteEvent(id: "flash", kind: "flash_eye", source: .sensoryModel, appliedTick: 701)
        let wind = f.buffer.noteEvent(id: "wind", kind: "wind", source: .physicalAndSensoryModel, appliedTick: 701)
        check("a window records why its sample tick is still null", flash.sensorySampleTick == nil && flash.sensorySampleUnavailableReason != nil)
        for _ in 0..<2 { Thread.sleep(forTimeInterval: 0.1); f.buffer.advance() }      // a pause: ticks do not move
        f.feed(to: 1700)
        let w = f.buffer.window(eventID: "flash"), json = (try? JSONEncoder().encode(w!)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("eye event: applied 701, first sampled_at eye sample ≥ 701 is 900 — both correct and different; no latency field",
              w?.appliedTick == 701 && w?.sensorySampleTick == 900 && w?.sensorySampleUnavailableReason == nil
                && !json.contains("latency") && w?.status == .complete)
        let v = f.buffer.window(eventID: "wind")
        check("wind event whose only sample is received_at: sensory_sample_tick stays null, with that reason",
              v?.sensorySampleTick == nil && v?.sensorySampleUnavailableReason == "only_received_at_samples")
        f.timeline.recordSensory(tick: 1800, origin: .sampledAt, channel: .wind, a: 0.5, sensoryOn: true)   // before the next event
        f.buffer.noteEvent(id: "late", kind: "wind", source: .sensoryModel, appliedTick: 1901)
        f.feed(to: 2900)
        check("a sampled_at sample outside the response window is not used; no channel / no sample are different reasons",
              f.buffer.window(eventID: "late")?.sensorySampleTick == nil
                && f.buffer.window(eventID: "late")?.sensorySampleUnavailableReason == "no_sampled_at_sample_in_response_window")
        f.timeline.recordSensory(tick: 2950, origin: .sampledAt, channel: .touch, a: 0.4, sensoryOn: true)
        f.buffer.noteEvent(id: "touch", kind: "touch", source: .physicalAndSensoryModel, appliedTick: 2901)
        f.buffer.noteEvent(id: "stim", kind: "population:GF", source: .directNeural, appliedTick: 2901)
        f.feed(to: 3900)
        check("touch: first sampled_at touch sample 2950; a direct neural stimulus has no sensory channel to sample",
              f.buffer.window(eventID: "touch")?.sensorySampleTick == 2950
                && f.buffer.window(eventID: "stim")?.sensorySampleTick == nil
                && f.buffer.window(eventID: "stim")?.sensorySampleUnavailableReason == "no_measured_sensory_channel")
    }

    // ---- summaries equal hand-computed fixture values ----------------------------------------
    // Event applied at 601 → baseline 101…600, response 601…1600.
    //   motor every 10 ticks 110…1600, walk = tick/1000, turn −0.2, escape at 700 and 710
    //     baseline 110…600: 50 samples, mean walk (110+600)/2/1000 = 0.355
    //     response 610…1600: 100 samples, mean walk (610+1600)/2/1000 = 1.105, escapes 2, period 10
    //   body (local) every 20 ticks 120…1600, x = tick/2 pt, state walking→idle at 800→walking at 1200
    //     response 620…1600: 50 samples, displacement (1600−620)/2 = 490 pt, speed 10 pt / 20 ms = 500 pt/s, 2 transitions
    do {
        let f = TLFixture()
        for t in stride(from: 110, through: 1600, by: 10) { f.timeline.recordMotor(tick: t, motor(Double(t) / 1000, turn: -0.2, escape: t == 700 || t == 710)) }
        for t in stride(from: 120, through: 1600, by: 20) {
            f.timeline.recordLocalBody(tick: t, x: Double(t) / 2, y: 0, heading: 1, state: (800..<1200).contains(t) ? 1 : 0)
        }
        f.feed(to: 600)
        f.buffer.noteEvent(id: "S", kind: "touch", source: .physical, appliedTick: 601)
        f.feed(to: 1600)
        let w = f.buffer.window(eventID: "S"), m = w?.motorOutput, b = w?.observedBodyAction
        check("motor baseline: 50 samples 110…600, period 10, mean walk 0.355, mean turn −0.2, no escape",
              m?.baseline.status == .collected && m?.baseline.sampleCount == 50 && m?.baseline.firstTick == 110
                && m?.baseline.lastTick == 600 && m?.baseline.periodTicks == 10 && near(m?.baseline.mean?.walkDrive, 0.355)
                && near(m?.baseline.mean?.turnBias, -0.2) && m?.baseline.escapeCount == 0)
        check("motor response: 100 samples 610…1600, mean walk 1.105, 2 escape samples",
              m?.response.status == .collected && m?.response.sampleCount == 100 && m?.response.firstTick == 610
                && m?.response.lastTick == 1600 && near(m?.response.mean?.walkDrive, 1.105) && m?.response.escapeCount == 2)
        check("body baseline: 25 sampled_at local samples, unit pt, 480 → 0 transitions, displacement (600−120)/2 = 240",
              b?.baseline.sampleCount == 25 && b?.baseline.sampledAtCount == 25 && b?.baseline.receivedAtCount == 0
                && b?.baseline.positionUnit == "pt" && near(b?.baseline.netDisplacement, 240) && b?.baseline.stateTransitions == 0)
        check("body response: 50 samples, period 20, displacement 490 pt, speed 500 pt/s, 2 state transitions, no yaw rate invented",
              b?.response.status == .collected && b?.response.sampleCount == 50 && b?.response.periodTicks == 20
                && near(b?.response.netDisplacement, 490) && near(b?.response.meanSpeed, 500) && b?.response.stateTransitions == 2
                && b?.response.meanYawRate == nil)
        check("flags from the event: physical → force_applied true, sensory_applied false",
              w?.forceApplied == true && w?.sensoryApplied == false)
        check("the finished record round-trips through the strict decoder", w.flatMap { decode(jsonObject($0)) } == w)
        // Mixed origin: received_at body samples give no speed (their tick is not a sample time).
        let g = InteractionTimeline()
        for (i, t) in [100, 120, 140].enumerated() {
            var fb = FlyGymBodyFeedback(); fb.receivedAt = Date(timeIntervalSinceReferenceDate: Double(i)); fb.positionXmm = Double(t); fb.yawRate = 0.5
            g.ingestBody(fb, tickNow: t, lockstepEndTick: nil)
        }
        let s = g.bodySummary(TickWindow(start: 100, end: 199))
        check("received_at-only body samples: counted by origin, displacement/yaw from the data, mean speed absent (no sample time)",
              s.receivedAtCount == 3 && s.sampledAtCount == 0 && s.positionUnit == "mm" && near(s.netDisplacement, 40)
                && s.meanSpeed == nil && near(s.meanYawRate, 0.5))
    }

    // ---- flags for events the source does not classify come from the backend packet ------------
    do {
        let f = TLFixture()
        for t in stride(from: 20, through: 1500, by: 20) {
            var fb = FlyGymBodyFeedback(); fb.receivedAt = Date(timeIntervalSinceReferenceDate: Double(t))
            fb.windStrength = (700..<900).contains(t) ? 0.6 : 0; fb.windSensory = true
            f.timeline.ingestBody(fb, tickNow: t - 20, lockstepEndTick: t)
        }
        f.feed(to: 600)
        f.buffer.noteEvent(id: "obs", kind: "wind", source: .observed, appliedTick: 601)
        f.feed(to: 1600)
        let w = f.buffer.window(eventID: "obs")
        check("source 'observed': force unknown (null), sensory_applied from the packet's wind_sensory flag",
              w?.forceApplied == nil && w?.sensoryApplied == true)
    }

    // ---- V7-04: missing data is unavailable/partial, never zero ------------------------------
    do {
        // Lane overflow: motor ring of 8 samples, one sample per 20 ticks.
        let small = InteractionTimeline(motorCapacity: 8)
        let f = TLFixture(timeline: small)
        for t in stride(from: 20, through: 1600, by: 20) { small.recordMotor(tick: t, motor(0.5)) }
        f.feed(to: 600)
        f.buffer.noteEvent(id: "ov", kind: "touch", source: .physical, appliedTick: 601)
        f.feed(to: 1600)
        let m = f.buffer.window(eventID: "ov")?.motorOutput
        check("ring overflow: the response is partial (ring_evicted) with the 8 samples left, the evicted baseline is unavailable",
              m?.response.status == .partial && m?.response.reason == "ring_evicted" && m?.response.sampleCount == 8
                && m?.baseline.status == .unavailable && m?.baseline.reason == "ring_evicted" && m?.baseline.mean == nil
                && small.stats().evicted[TimelineLane.motor.rawValue] == 72)
        // A gap inside the window.
        let g = TLFixture()
        for t in stride(from: 10, through: 1600, by: 10) where !(250...700).contains(t) { g.timeline.recordMotor(tick: t, motor(0.5)) }
        g.feed(to: 600)
        g.buffer.noteEvent(id: "gap", kind: "touch", source: .physical, appliedTick: 601)
        g.feed(to: 1600)
        let gm = g.buffer.window(eventID: "gap")?.motorOutput?.baseline
        check("no motor sample for the last 360 ticks of the baseline: partial with the gap named, the samples that exist are still reported",
              gm?.status == .partial && gm?.reason == "gap_360_ticks" && (gm?.sampleCount ?? 0) > 0)
        // Event at tick ~1: no baseline exists.
        let e = TLFixture()
        for t in stride(from: 20, through: 1100, by: 20) { e.timeline.recordMotor(tick: t, motor(0.9)) }
        e.buffer.noteEvent(id: "early", kind: "touch", source: .physical, appliedTick: 1)
        e.buffer.noteEvent(id: "early3", kind: "touch", source: .physical, appliedTick: 3)
        e.feed(to: 1100)
        let early = e.buffer.window(eventID: "early"), early3 = e.buffer.window(eventID: "early3")
        check("event at tick 1: baseline motor/body are unavailable (window before tick 1), not zeros; response is real",
              early?.motorOutput?.baseline.status == .unavailable && early?.motorOutput?.baseline.reason == "window_before_tick_1"
                && early?.motorOutput?.baseline.mean == nil && early?.motorOutput?.baseline.sampleCount == 0
                && early?.observedBodyAction?.baseline.status == .unavailable && early?.observedBodyAction?.baseline.netDisplacement == nil
                && early?.motorOutput?.response.status == .collected && early?.observedBodyAction?.response.reason == "no_samples_in_window")
        check("event at tick 3: baseline with no samples is unavailable too, and baseline_insufficient is set",
              early3?.motorOutput?.baseline.status == .unavailable && early3?.validity.baselineInsufficient == true)
        // Overlapping events keep their flags.
        let o = TLFixture()
        o.feed(to: 600)
        o.buffer.noteEvent(id: "A", kind: "touch", source: .physical, appliedTick: 601)
        o.feed(to: 700)
        o.buffer.noteEvent(id: "B", kind: "flash_eye", source: .sensoryModel, appliedTick: 701)
        o.feed(to: 2300)
        let a = o.buffer.window(eventID: "A"), b = o.buffer.window(eventID: "B")
        check("overlapping events: both flagged, each keeps its own force/sensory flags",
              a?.validity.overlappingEvents == ["B"] && b?.validity.overlappingEvents == ["A"]
                && a?.forceApplied == true && a?.sensoryApplied == false && b?.forceApplied == false && b?.sensoryApplied == true
                && a?.validity.sufficient == false)
    }

    // ---- strict decode: v1 still accepted, malformed v2 rejected ------------------------------------
    do {
        let f = TLFixture()
        for t in stride(from: 10, through: 1600, by: 10) { f.timeline.recordMotor(tick: t, motor(0.5)) }
        f.feed(to: 600)
        f.buffer.noteEvent(id: "D", kind: "touch", source: .physical, appliedTick: 601)
        let collecting = f.buffer.window(eventID: "D")!
        f.feed(to: 1600)
        let complete = f.buffer.window(eventID: "D")!
        let unknown = f.buffer.noteEvent(id: "U", kind: "touch", source: .physical, appliedTick: nil)
        check("v2 fixtures round-trip (collecting, complete, unknown tick)",
              [collecting, complete, unknown].allSatisfy { decode(jsonObject($0)) == $0 } && complete.schema == "interaction_window.v2"
                && collecting.motorOutput?.response.reason == "collecting")
        var v1 = jsonObject(complete)
        v1["schema"] = "interaction_window.v1"
        let notCollected: [String: Any] = ["status": "not_collected", "reason": "V7.6 integrated timeline"]
        v1["motor_output"] = notCollected; v1["observed_body_action"] = notCollected
        for k in ["force_applied", "sensory_applied", "sensory_sample_unavailable_reason"] { v1[k] = nil }
        let old = decode(v1)
        check("a v1 record still decodes: motor/body stay not collected, new fields absent; re-encoded it is still v1",
              old?.schema == "interaction_window.v1" && old?.motorOutput == nil && old?.observedBodyAction == nil
                && old?.forceApplied == nil && old.map { jsonObject($0)["schema"] as? String == "interaction_window.v1"
                    && ($0.motorOutput == nil) && (jsonObject($0)["force_applied"] == nil) } == true)
        var v1bad = v1; v1bad["motor_output"] = ["status": "collected", "reason": "x"]
        check("bad: a v1 record claiming collected motor output", decode(v1bad) == nil)
        func rejects(_ base: InteractionWindow, _ mutate: (inout [String: Any]) -> Void) -> Bool {
            var o = jsonObject(base); mutate(&o); return decode(o) == nil
        }
        func mutate(_ o: inout [String: Any], _ lane: String, _ win: String, _ f: (inout [String: Any]) -> Void) {
            var l = o[lane] as? [String: Any] ?? [:]; var w = l[win] as? [String: Any] ?? [:]
            f(&w); l[win] = w; o[lane] = l
        }
        check("bad v2: motor summary without a status",
              rejects(complete) { mutate(&$0, "motor_output", "response") { $0["status"] = nil } })
        check("bad v2: zeros (a mean) on an unavailable summary",
              rejects(complete) { mutate(&$0, "motor_output", "baseline") { w in
                  w["status"] = "unavailable"; w["reason"] = "ring_evicted"; w["sample_count"] = 0
                  w["first_tick"] = NSNull(); w["last_tick"] = NSNull(); w["period_ticks"] = NSNull()
                  w["mean"] = ["walk_drive": 0.0, "turn_bias": 0.0, "groom_drive": 0.0, "wing_drive": 0.0, "nervous": 0.0, "arousal": 0.0] } })
        check("bad v2: unavailable without a reason",
              rejects(complete) { mutate(&$0, "observed_body_action", "response") { $0["status"] = "unavailable"; $0["reason"] = NSNull() } })
        check("bad v2: count and period mismatch (more samples than ticks / period beyond the range)",
              rejects(complete) { mutate(&$0, "motor_output", "response") { $0["sample_count"] = 5000 } }
                && rejects(complete) { mutate(&$0, "motor_output", "response") { $0["period_ticks"] = 5000.0 } }
                && rejects(complete) { mutate(&$0, "motor_output", "response") { $0["period_ticks"] = NSNull() } })
        check("bad v2: summary range outside its window", rejects(complete) { mutate(&$0, "motor_output", "response") { $0["first_tick"] = 1 } })
        check("bad v2: collecting window already carrying a summary",
              rejects(collecting) { mutate(&$0, "motor_output", "response") { $0["status"] = "collected" } })
        check("bad v2: a null sensory_sample_tick without a reason, flags key missing",
              rejects(complete) { $0["sensory_sample_tick"] = NSNull(); $0["sensory_sample_unavailable_reason"] = NSNull() }
                && rejects(complete) { $0["force_applied"] = nil })
    }

    // ---- CSV export carries the raw samples only --------------------------------------------------
    do {
        let tl = InteractionTimeline()
        tl.recordEye(tick: 200, origin: .sampledAt, loomL: 0.25, loomR: 0.5)
        tl.recordMotor(tick: 240, motor(0.5, escape: true))
        tl.recordLocalBody(tick: 260, x: 3, y: 4, heading: 1, state: 2)
        let csv = TimelineCSV.make(tl, range: 1...1000, spikes: [(tick: 250, rootID: "720575940000000010"), (tick: 5000, rootID: "x")])
        let rows = csv.split(separator: "\n").map(String.init)
        let cols = TimelineCSV.header.dropLast().split(separator: ",").count
        check("timeline.csv: header + one row per raw sample (eye, motor, body, spike), none interpolated, fixed column count",
              rows.count == 5 && rows[0] == String(TimelineCSV.header.dropLast())
                && rows.dropFirst().allSatisfy { $0.split(separator: ",", omittingEmptySubsequences: false).count == cols }
                && rows[1].hasPrefix("eye,200,sampled_at") && rows[2].hasPrefix("motor,240,sampled_at")
                && rows[3].hasPrefix("body,260,sampled_at,local") && rows[3].hasSuffix("grooming") && rows[4].hasPrefix("spike,250,sampled_at,720575940000000010"),
              rows.joined(separator: " | "))
    }

    // ---- UI data: lane labels state the measured period and receive-time lanes ------------------
    do {
        let f = TLFixture()
        for t in [150, 350, 550] { f.timeline.recordEye(tick: t, origin: .sampledAt, loomL: 0, loomR: 0) }
        f.timeline.recordSensory(tick: 400, origin: .receivedAt, channel: .wind, a: 0.5)
        f.feed(to: 600)
        f.buffer.noteEvent(id: "ui", kind: "flash_eye", source: .sensoryModel, appliedTick: 601)
        f.feed(to: 1600)
        if let w = f.buffer.window(eventID: "ui"), let s = TimelineSnapshot.make(window: w, timeline: f.timeline, observer: f.observer) {
            check("UI snapshot: eye label says 200 ms apart, the received_at sensory lane is marked, raw samples only",
                  s.labels[0] == "Eye 200 ms apart" && s.labels[1].contains("receive time") && s.eye.samples.count == 3
                    && s.range == 101...1600 && s.applied == 601, s.labels.joined(separator: " | "))
        } else { check("UI snapshot builds", false) }
    }

    // ---- real path: a real MetalSim through the app's own advanceNeuralQuantum ------------------------
    guard let c = loadConnectome(), let sim = makeDiagSim(connectome: c) else { print("no sim"); exit(1) }
    let chosen = sim.gf + sim.dnaL + sim.dnaR + sim.mdn + sim.fwd + sim.groom + sim.escw
    let coord = Coordinator(bounds: CGSize(width: 800, height: 600), sim: sim)
    func drain() { for action in coord.drainSimulationActions() { action(coord) } }
    coord.observeBrainPick(BrainPick(indices: chosen, anchor: .zero, name: "timelinetest"))
    drain()
    sim.step(600)                                         // no producer ran: the lanes are empty, simMs = 600
    check("before any quantum the lanes are empty (nothing is back-filled for ticks no producer saw)",
          sim.timeline.motorSlice(1...700).samples.isEmpty && sim.timeline.bodySlice(1...700).samples.isEmpty)
    coord.labStimulatePopulation("GF", strength: 0.5, durationMs: 40)
    drain()
    let applied = sim.simMs + 1
    sim.eventWindows.noteEvent(id: "flash", kind: "flash_eye", source: .sensoryModel, appliedTick: applied)
    var eyeTicks: [Int] = []
    for i in 0..<51 {                                      // 51 lockstep quanta of 20 ticks = 1,020 ticks
        var fb = FlyGymBodyFeedback()
        fb.receivedAt = Date(timeIntervalSinceReferenceDate: Double(i + 1))
        fb.positionXmm = Double(i); fb.vx = 0.01; fb.yawRate = 0.1
        if i % 10 == 0 { fb.eyeSampleSimTick = sim.simMs + 13; eyeTicks.append(sim.simMs + 13) }   // ~5 Hz inside 20-tick quanta
        _ = coord.advanceV4TimingQuantumForTesting(fb)
    }
    let a = sim.eventWindows.window(eventID: "local-1"), fl = sim.eventWindows.window(eventID: "flash")
    let rw = a?.responseWindow ?? TickWindow(start: 0, end: 0)
    check("real path: the window finalized after exactly 1,000 ticks (simMs \(sim.simMs))", a?.status == .complete && fl?.status == .complete && sim.simMs == 1620)
    let mr = a?.motorOutput?.response, br = a?.observedBodyAction?.response
    check("real path: motor lane collected for the response — 49 samples 620…1580, 20-tick period (the batch's own sample lands after finalize)",
          mr?.status == .collected && mr?.sampleCount == 49 && mr?.firstTick == 620 && mr?.lastTick == 1580 && mr?.periodTicks == 20,
          "\(String(describing: mr?.status)) \(String(describing: mr?.sampleCount)) \(String(describing: mr?.lastTick))")
    check("real path: not back-filled — the lane now holds the late sample at 1600, the finished record does not",
          sim.timeline.motorSlice(rw.start...rw.end).samples.count == 50 && mr?.lastTick == 1580)
    check("real path: body lane at the lockstep end ticks (sampled_at): 50 samples 620…1600, displacement 49 mm over 49 steps",
          br?.status == .collected && br?.sampleCount == 50 && br?.firstTick == 620 && br?.lastTick == 1600 && br?.sampledAtCount == 50
            && br?.positionUnit == "mm" && near(br?.netDisplacement, 49) && near(br?.meanYawRate, 0.1))
    check("real path: baseline never observed by any producer is unavailable, not zero",
          a?.motorOutput?.baseline.status == .unavailable && a?.observedBodyAction?.baseline.status == .unavailable
            && a?.motorOutput?.baseline.mean == nil)
    let first = eyeTicks.first { $0 >= applied }
    check("real path: eye samples at true sample ticks every 200 ticks (sampled_at); event sample tick = first one ≥ applied (\(String(describing: first)))",
          sim.timeline.eyeSlice(1...2000).samples.map(\.tick) == eyeTicks && sim.timeline.eyeSlice(1...2000).periodTicks == 200
            && sim.timeline.eyeSlice(1...2000).samples.allSatisfy { $0.origin == .sampledAt }
            && fl?.sensorySampleTick == first && fl?.appliedTick == applied && first != applied)
    check("real path: the GF stimulus is visible in the motor lane's own record (escape count is a count, not a rate)",
          (mr?.escapeCount ?? -1) >= 0 && (mr?.escapeCount ?? 99) <= 49 && a?.forceApplied == false && a?.sensoryApplied == false)
    // Read-only: selecting/observing/querying the timeline injects nothing and moves no tick.
    let extBefore = sim.debugExternalInput(chosen), tickBefore = sim.simMs
    coord.observeBrainPick(BrainPick(indices: chosen, anchor: .zero, name: "again"))
    drain()
    _ = sim.timeline.motorSlice(1...3000); _ = sim.timeline.eyeSlice(1...3000); _ = sim.eventWindows.windows()
    _ = TimelineCSV.make(sim.timeline, range: 1...3000)
    check("read-only: selecting, observing and querying the timeline leaves extInput and simMs unchanged",
          sim.debugExternalInput(chosen) == extBefore && sim.simMs == tickBefore)
    // Brain reset starts a new epoch for the lanes too.
    coord.labResetBrain()
    drain()
    check("brain reset clears the timeline lanes (new epoch)",
          sim.timeline.motorSlice(1...3000).samples.isEmpty && sim.timeline.bodySlice(1...3000).samples.isEmpty && sim.timeline.stats().epoch >= 1)
    suite.finish()
}
#endif
