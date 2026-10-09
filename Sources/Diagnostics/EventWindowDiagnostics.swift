#if DIAGNOSTICS
// --eventwindowtest: V7.5 pre/post-event neural buffer (V7-03 event time, V7-04
// missing data). Fixture checks drive the real NeuralObserver/ObservationRing
// with hand-made spike rows and compare with hand-computed counts; the
// real-path section uses a real MetalSim through the app's own Coordinator
// entry points and compares with independent queries over the same windows.
import Cocoa
import simd

/// A fixture selection [10, 11, 12, 13] (slots 0…3) fed one tick at a time.
/// Pattern (hand-countable): slot 0 spikes when tick % 10 == 0, slot 1 when
/// tick % 50 == 0, slot 2 on ticks 700…709, slot 3 never.
private final class EWFixture {
    let observer: NeuralObserver
    let buffer: EventWindowBuffer
    private(set) var tick: Int
    static let neurons = [10, 11, 12, 13]

    init(armAt: Int = 1, capacity: Int = ObservationCapability.retainedTicks, neurons: [Int] = EWFixture.neurons) {
        observer = NeuralObserver(rootIds: (0..<100).map { 720_575_940_000_000_000 + UInt64($0) }, capacity: capacity)
        if !neurons.isEmpty { observer.arm(neurons, name: "fixture", omitted: 0, startTick: armAt) }
        buffer = EventWindowBuffer(observer: observer)
        tick = armAt - 1
    }

    static func pattern(_ t: Int) -> [Int] {
        var s: [Int] = []
        if t % 10 == 0 { s.append(0) }
        if t % 50 == 0 { s.append(1) }
        if (700...709).contains(t) { s.append(2) }
        return s
    }

    /// Records ticks up to and including `end`, `batch` rows per `record` call
    /// (as `MetalSim.step` does). Calls `advance()` after each batch when asked.
    func feed(to end: Int, batch: Int = 1, advance: Bool = true) {
        while tick < end {
            let k = min(batch, end - tick)
            var rows = [UInt8](repeating: 0, count: k * ObservationCapability.exactSelectionLimit)
            for s in 0..<k {
                for slot in Self.pattern(tick + 1 + s) { rows[s * ObservationCapability.exactSelectionLimit + slot] = 1 }
            }
            rows.withUnsafeBufferPointer {
                observer.record(firstTick: tick + 1, count: k, rows: $0.baseAddress!,
                                rowWidth: ObservationCapability.exactSelectionLimit)
            }
            tick += k
            if advance { buffer.advance() }
        }
    }
}

private func jsonObject(_ w: InteractionWindow) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any]) ?? [:]
}

private func decodeWindow(_ obj: [String: Any]) -> InteractionWindow? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return try? JSONDecoder().decode(InteractionWindow.self, from: d)
}

func runEventWindowTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check(name, ok, detail) }
    func rate(_ o: NeuralObservation?) -> Double? { o?.rateHzPerNeuron }

    // ---- exact counts and rates (hand-computed) -----------------------------
    // Event applied at tick 600 → baseline 100…599, response 600…1599.
    //   slot 0: 50 / 100 spikes · slot 1: 10 / 20 · slot 2: 0 / 10 · slot 3: 0 / 0
    //   all four: 60 → 60×1000/(500×4) = 30 Hz · 130 → 130×1000/(1000×4) = 32.5 Hz
    do {
        let f = EWFixture()
        f.feed(to: 599)
        let noted = f.buffer.noteEvent(id: "A", kind: "unit", source: .directNeural, appliedTick: 600)
        check("event noted: collecting, windows are applied−500…−1 and applied…+999",
              noted.status == .collecting && noted.baselineWindow == TickWindow(start: 100, end: 599)
                && noted.responseWindow == TickWindow(start: 600, end: 1599) && noted.preMs == 500 && noted.postMs == 1000)
        f.feed(to: 1598)
        check("one tick short of the window: still collecting 999/1000",
              f.buffer.window(eventID: "A")?.status == .collecting
                && f.buffer.window(eventID: "A")?.responseTicksCollected == 999)
        f.feed(to: 1599)
        let w = f.buffer.window(eventID: "A")
        let g = w?.groups.first
        check("complete after the 1000th response tick, not before", w?.status == .complete && w?.responseTicksCollected == 1000)
        check("group 'selection': baseline 60 spikes = 30.0 Hz, response 130 spikes = 32.5 Hz",
              g?.groupID == "selection" && g?.baseline?.spikeCount == 60 && g?.response?.spikeCount == 130
                && rate(g?.baseline) == 30.0 && rate(g?.response) == 32.5 && g?.baseline?.observedTicks == 500
                && g?.response?.observedTicks == 1000 && g?.memberCount == 4)
        check("delta = response − baseline = +2.5 Hz/neuron; window sufficient, nothing flagged",
              g?.deltaHzPerNeuron == 2.5 && g?.deltaUnavailableReason == nil && w?.validity.sufficient == true
                && w?.validity.droppedSamples == 0 && w?.validity.baselineInsufficient == false
                && w?.validity.overlappingEvents == [] && w?.validity.hasInvalidatingFlag == false)
        check("motor output and observed body action are explicitly not collected (V7.6)",
              w?.motorOutput.status == "not_collected" && w?.observedBodyAction.status == "not_collected")
        check("finished window is in history, nothing left collecting",
              f.buffer.stats().collecting == 0 && f.buffer.stats().history == 1)
    }
    // Same data fed in 64-tick batches, advance once per batch: the window completes
    // right after the batch that contains its last tick and counts no tick beyond it.
    do {
        let f = EWFixture()
        f.feed(to: 576, batch: 64)
        f.buffer.noteEvent(id: "A", kind: "unit", source: .directNeural, appliedTick: 600)
        f.feed(to: 1664, batch: 64)    // 1664 = 26×64: the batch ending past tick 1599
        let g = f.buffer.window(eventID: "A")?.groups.first
        check("batched feed: same exact counts, ticks after the window not counted",
              f.buffer.window(eventID: "A")?.status == .complete && g?.baseline?.spikeCount == 60
                && g?.response?.spikeCount == 130 && g?.response?.endTick == 1599)
    }
    // Several groups through the provider seam: a real 0 Hz baseline is 0, not null; a group
    // outside the exact selection is null with its reason and weakens sufficiency.
    do {
        let f = EWFixture()
        f.buffer.groupProvider = { [(id: "n10", members: [10]), (id: "n12n13", members: [12, 13]), (id: "outside", members: [99])] }
        f.feed(to: 599)
        f.buffer.noteEvent(id: "G", kind: "unit", source: .directNeural, appliedTick: 600)
        f.feed(to: 1599)
        let w = f.buffer.window(eventID: "G")
        let by = Dictionary(uniqueKeysWithValues: (w?.groups ?? []).map { ($0.groupID, $0) })
        check("seam: n10 = 100 Hz → 100 Hz (Δ 0); n12+n13 = a real 0 Hz → 5 Hz (Δ +5)",
              rate(by["n10"]?.baseline) == 100 && rate(by["n10"]?.response) == 100 && by["n10"]?.deltaHzPerNeuron == 0
                && rate(by["n12n13"]?.baseline) == 0 && rate(by["n12n13"]?.response) == 5 && by["n12n13"]?.deltaHzPerNeuron == 5)
        check("seam: a group outside the selection is null with a reason; window complete but not sufficient",
              by["outside"]?.baseline == nil && by["outside"]?.response == nil && by["outside"]?.deltaHzPerNeuron == nil
                && by["outside"]?.deltaUnavailableReason == "members_not_in_selection"
                && w?.status == .complete && w?.validity.sufficient == false && w?.validity.droppedSamples == 0)
    }

    // ---- pause: wall time never completes a window (the step's required output) ----
    do {
        let f = EWFixture()
        f.feed(to: 700)
        f.buffer.noteEvent(id: "P", kind: "unit", source: .directNeural, appliedTick: 701)
        for _ in 0..<3 { Thread.sleep(forTimeInterval: 0.1); f.buffer.advance() }
        let idle = f.buffer.window(eventID: "P")
        check("paused (300 ms of wall time, no ticks): still collecting 0/1000",
              idle?.status == .collecting && idle?.responseTicksCollected == 0)
        f.feed(to: 800)
        Thread.sleep(forTimeInterval: 0.3); f.buffer.advance()
        check("100 ticks, then 300 ms of wall time: collecting 100/1000",
              f.buffer.window(eventID: "P")?.status == .collecting && f.buffer.window(eventID: "P")?.responseTicksCollected == 100)
        f.feed(to: 1699)
        check("completes only after the remaining ticks (one short: still collecting)",
              f.buffer.window(eventID: "P")?.status == .collecting)
        f.feed(to: 1700)
        let done = f.buffer.window(eventID: "P")
        // response 701…1700: slot 0 → 100, slot 1 → 20, slot 2 → 10 (700 is before the window → 9)
        check("then complete with exact counts (129 spikes = 32.25 Hz)",
              done?.status == .complete && done?.groups.first?.response?.spikeCount == 129
                && rate(done?.groups.first?.response) == 32.25)
    }

    // ---- missing data: nothing is fabricated (V7-04) -------------------------
    do {   // observation began 100 ticks before the event
        let f = EWFixture(armAt: 501)
        f.feed(to: 600)
        f.buffer.noteEvent(id: "S", kind: "unit", source: .directNeural, appliedTick: 601)
        f.feed(to: 1600)
        let w = f.buffer.window(eventID: "S"), g = w?.groups.first
        check("selection began 100 ticks before the event: baseline_insufficient, null baseline rate and delta",
              w?.status == .complete && w?.validity.baselineInsufficient == true && w?.validity.sufficient == false
                && g?.baseline == nil && g?.baselineMissingTicks == 400 && g?.deltaHzPerNeuron == nil
                && g?.deltaUnavailableReason == "baseline_insufficient" && w?.validity.droppedSamples == 400,
              "missing \(String(describing: g?.baselineMissingTicks))")
        check("…while the response is still exact (130 spikes = 32.5 Hz)",
              g?.response?.spikeCount == 130 && rate(g?.response) == 32.5)
        let json = (try? JSONEncoder().encode(w!)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("JSON carries explicit nulls for the baseline and the delta",
              json.contains("\"baseline\":null") && json.contains("\"delta_hz_per_neuron\":null"))
    }
    do {   // event before tick 500
        let f = EWFixture()
        f.feed(to: 299)
        f.buffer.noteEvent(id: "E300", kind: "unit", source: .directNeural, appliedTick: 300)
        f.feed(to: 1299)
        let w = f.buffer.window(eventID: "E300"), g = w?.groups.first
        check("event at tick 300: baseline −200…299 is insufficient (299 observed, 201 missing), delta null",
              w?.baselineWindow == TickWindow(start: -200, end: 299) && w?.validity.baselineInsufficient == true
                && g?.baseline == nil && g?.baselineMissingTicks == 201 && g?.deltaHzPerNeuron == nil
                && g?.response?.spikeCount == 130)
        let g2 = EWFixture()
        g2.buffer.noteEvent(id: "E1", kind: "unit", source: .directNeural, appliedTick: 1)
        g2.feed(to: 1000)
        let w1 = g2.buffer.window(eventID: "E1")
        check("event at tick 1: baseline entirely before the first tick (500 missing), response exact",
              w1?.status == .complete && w1?.groups.first?.baselineMissingTicks == 500 && w1?.groups.first?.baseline == nil
                && w1?.groups.first?.response?.spikeCount == 130)
    }
    do {   // overlap
        let f = EWFixture()
        f.feed(to: 599)
        f.buffer.noteEvent(id: "O1", kind: "unit", source: .directNeural, appliedTick: 600)
        f.feed(to: 899)
        f.buffer.noteEvent(id: "O2", kind: "unit", source: .physical, appliedTick: 900)
        check("overlapping events are flagged on both (while both collect)",
              f.buffer.window(eventID: "O1")?.validity.overlappingEvents == ["O2"]
                && f.buffer.window(eventID: "O2")?.validity.overlappingEvents == ["O1"])
        f.feed(to: 2000)
        f.buffer.noteEvent(id: "O3", kind: "unit", source: .physical, appliedTick: 2099)   // 1499 after O1
        f.buffer.noteEvent(id: "O4", kind: "unit", source: .physical, appliedTick: 2100)   // 1500 after O1
        check("1499 ticks apart still overlap (ranges touch); 1500 do not — also onto an already finished window",
              f.buffer.window(eventID: "O1")?.status == .complete
                && f.buffer.window(eventID: "O1")?.validity.overlappingEvents.contains("O3") == true
                && f.buffer.window(eventID: "O1")?.validity.overlappingEvents.contains("O4") == false
                && f.buffer.window(eventID: "O3")?.validity.overlappingEvents.contains("O1") == true
                && f.buffer.window(eventID: "O4")?.validity.overlappingEvents.contains("O1") == false)
        check("an overlapped window still reports exact counts but names its neighbours",
              f.buffer.window(eventID: "O1")?.groups.first?.response?.spikeCount == 130)
    }
    do {   // overflow
        let f = EWFixture()
        var sunk: [InteractionWindow] = []
        f.buffer.onFinalized = { sunk.append($0) }
        f.feed(to: 2000)
        for i in 1...17 { f.buffer.noteEvent(id: "ov-\(i)", kind: "unit", source: .directNeural, appliedTick: 2000 + i) }
        let first = f.buffer.window(eventID: "ov-1")
        check("17th concurrent event displaces the oldest: invalid(buffer_overflow), kept in history, recorded",
              f.buffer.stats().collecting == 16 && f.buffer.stats().overflowDisplaced == 1
                && first?.status == .invalid && first?.validity.bufferOverflow == true
                && sunk.map(\.eventID) == ["ov-1"] && f.buffer.windows().count == 17)
        f.feed(to: 3100)
        let ws = f.buffer.windows()
        check("the other 16 complete; all 17 events are accounted for, none lost",
              ws.count == 17 && ws.filter { $0.status == .complete }.count == 16
                && ws.filter { $0.status == .invalid }.count == 1 && sunk.count == 17)
    }
    do {   // history bound
        let f = EWFixture()
        var sunk = 0
        f.buffer.onFinalized = { _ in sunk += 1 }
        for i in 1...70 { f.buffer.noteEvent(id: "u-\(i)", kind: "unit", source: .physical, appliedTick: nil) }
        let ws = f.buffer.windows()
        check("history is bounded at 64; the 6 that left memory were all handed to the recorder first",
              ws.count == InteractionWindowCapability.maxHistory && f.buffer.stats().historyEvicted == 6 && sunk == 70
                && ws.last?.eventID == "u-7" && ws.first?.eventID == "u-70")
    }
    do {   // unknown tick, no selection
        let f = EWFixture()
        let u = f.buffer.noteEvent(id: "unk", kind: "wind", source: .sensoryModel, appliedTick: nil,
                                   appliedTickOrigin: "unknown: test")
        check("no reliable applied tick: invalid(applied_tick_unknown), null windows, not skipped",
              u.status == .invalid && u.validity.appliedTickUnknown && u.appliedTick == nil
                && u.baselineWindow == nil && u.responseWindow == nil && f.buffer.window(eventID: "unk") != nil
                && u.validity.droppedSamples == nil)
        let bare = EWFixture(neurons: [])
        let n = bare.buffer.noteEvent(id: "nosel", kind: "unit", source: .directNeural, appliedTick: 600)
        check("nothing selected: invalid(no_selection)", n.status == .invalid && n.validity.noSelection && n.selectionID == nil)
    }
    do {   // brain reset
        let f = EWFixture()
        f.feed(to: 599)
        f.buffer.noteEvent(id: "R", kind: "unit", source: .directNeural, appliedTick: 600)
        f.feed(to: 700)
        f.observer.newEpoch()
        f.buffer.advance()
        let r = f.buffer.window(eventID: "R")
        check("brain reset mid-window: invalid(brain_reset), no results, nothing collecting",
              r?.status == .invalid && r?.validity.brainReset == true && r?.groups.isEmpty == true
                && f.buffer.stats().collecting == 0)
        let after = f.buffer.noteEvent(id: "R2", kind: "unit", source: .directNeural, appliedTick: 5)
        check("an event in the new epoch is independent (tick 5 does not overlap tick 600 of the old epoch)",
              after.brainEpoch == 1 && after.validity.overlappingEvents.isEmpty && r?.brainEpoch == 0)
    }
    do {   // selection change / clear
        let f = EWFixture()
        f.feed(to: 599)
        f.buffer.noteEvent(id: "C1", kind: "unit", source: .directNeural, appliedTick: 600)
        f.feed(to: 700)
        f.observer.arm([20, 21], name: "other", omitted: 0, startTick: 701)
        f.buffer.advance()
        check("selection changed mid-window: invalid(selection_changed)",
              f.buffer.window(eventID: "C1")?.status == .invalid && f.buffer.window(eventID: "C1")?.validity.selectionChanged == true)
        f.buffer.noteEvent(id: "C2", kind: "unit", source: .directNeural, appliedTick: 800)
        f.observer.arm([], name: "", omitted: 0, startTick: 701)
        f.buffer.advance()
        check("selection cleared mid-window: invalid(selection_changed)",
              f.buffer.window(eventID: "C2")?.status == .invalid && f.buffer.window(eventID: "C2")?.validity.selectionChanged == true)
    }
    do {   // late finalize past eviction
        let f = EWFixture()
        f.feed(to: 599)
        f.buffer.noteEvent(id: "L1", kind: "unit", source: .directNeural, appliedTick: 600)
        f.feed(to: 3000, advance: false)    // the ring now holds 953…3000
        f.buffer.advance()
        let l = f.buffer.window(eventID: "L1"), g = l?.groups.first
        check("finalized after the ring moved on: evicted, partial and invalid — 353 response and 500 baseline ticks missing",
              l?.status == .invalid && l?.validity.evicted == true && g?.response == nil && g?.responseMissingTicks == 353
                && g?.baseline == nil && g?.baselineMissingTicks == 500 && l?.validity.droppedSamples == 853,
              "\(String(describing: g?.responseMissingTicks)) \(String(describing: g?.baselineMissingTicks)) \(String(describing: l?.validity.droppedSamples))")
        let h = EWFixture()
        h.feed(to: 599)
        h.buffer.noteEvent(id: "L2", kind: "unit", source: .directNeural, appliedTick: 600)
        h.feed(to: 2300, advance: false)    // ring holds 253…2300: the baseline start is gone, the response is not
        h.buffer.advance()
        let m = h.buffer.window(eventID: "L2"), gm = m?.groups.first
        check("only the baseline evicted (153 ticks): complete + evicted + baseline_insufficient, response exact",
              m?.status == .complete && m?.validity.evicted == true && m?.validity.baselineInsufficient == true
                && gm?.baseline == nil && gm?.baselineMissingTicks == 153 && gm?.response?.spikeCount == 130
                && m?.validity.sufficient == false)
    }

    // ---- V7-03: applied tick and sensory sample tick stay separate -----------
    do {
        let f = EWFixture()
        f.feed(to: 700)
        let e = f.buffer.noteEvent(id: "V", kind: "flash", source: .sensoryModel, appliedTick: 701)
        check("sensory_sample_tick is null until genuinely known", e.sensorySampleTick == nil)
        for _ in 0..<2 { Thread.sleep(forTimeInterval: 0.1); f.buffer.advance() }   // a pause, then a slow (5 Hz) eye sample
        f.feed(to: 901)
        check("a non-positive sample tick is refused", !f.buffer.setSensorySampleTick(eventID: "V", tick: 0))
        check("sample tick set from the real sample (tick 901)", f.buffer.setSensorySampleTick(eventID: "V", tick: 901))
        f.feed(to: 1700)
        let v = f.buffer.window(eventID: "V")
        let json = (try? JSONEncoder().encode(v!)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("applied 701 and sample 901 kept apart; windows anchored on the applied tick only; no latency field",
              v?.appliedTick == 701 && v?.sensorySampleTick == 901 && v?.responseWindow?.start == 701
                && v?.baselineWindow?.end == 700 && !json.contains("latency") && v?.status == .complete)
        let other = f.buffer.noteEvent(id: "V2", kind: "flash", source: .sensoryModel, appliedTick: nil)
        check("an event without an applied tick never gets a derived sample tick",
              other.sensorySampleTick == nil && other.appliedTick == nil)
    }

    // ---- ACK anchoring (pure part of the Lab funnel) --------------------------
    do {
        var session = LabSession().snapshot()
        session.mode = .deterministic; session.phase = .running
        var ack = LabAck(); ack.id = 7; ack.ok = true; ack.appliedTick = 1200; ack.appliedEpoch = session.epoch
        let a = EventWindowIntent.anchor(for: ack, in: session)
        check("deterministic ACK of the current epoch anchors at applied_tick + 1", a.tick == 1201 && a.origin.contains("1200"))
        var old = ack; old.appliedEpoch = session.epoch + 1
        var none = ack; none.appliedTick = nil
        var otherSession = ack; otherSession.sessionID = "not-this-session"
        var interactive = session; interactive.mode = .interactive
        var failed = session; failed.phase = .failed
        check("other epoch / no applied tick / other session / interactive body clock / failed session → no anchor",
              EventWindowIntent.anchor(for: old, in: session).tick == nil && EventWindowIntent.anchor(for: none, in: session).tick == nil
                && EventWindowIntent.anchor(for: otherSession, in: session).tick == nil
                && EventWindowIntent.anchor(for: ack, in: interactive).tick == nil && EventWindowIntent.anchor(for: ack, in: failed).tick == nil)
        func cmd(_ action: String, strength: Double? = nil, physical: Bool? = nil, sensory: Bool? = nil, mode: String? = nil) -> LabCommand {
            var c = LabCommand(id: 0, action: action); c.strength = strength; c.physical = physical; c.sensory = sensory; c.mode = mode; return c
        }
        let wind = EventWindowIntent.classify(cmd("wind", strength: 0.7, physical: true, sensory: true))
        check("command kinds: wind both → physical+sensory_model, sensory-only → sensory_model, touch, flash, edit → physical",
              wind?.source == .physicalAndSensoryModel
                && EventWindowIntent.classify(cmd("wind", strength: 0.7, physical: false, sensory: true))?.source == .sensoryModel
                && EventWindowIntent.classify(cmd("touch", strength: 0.5))?.source == .physicalAndSensoryModel
                && EventWindowIntent.classify(cmd("flash_eye"))?.source == .sensoryModel
                && EventWindowIntent.classify(cmd("edit_property"))?.source == .physical)
        check("not events: zero wind, wind with both switches off, resets, scene files, environment-only temperature",
              EventWindowIntent.classify(cmd("wind", strength: 0)) == nil
                && EventWindowIntent.classify(cmd("wind", strength: 1, physical: false, sensory: false)) == nil
                && EventWindowIntent.classify(cmd("reset_world")) == nil && EventWindowIntent.classify(cmd("load_scene")) == nil
                && EventWindowIntent.classify(cmd("temperature", mode: "environment_only")) == nil
                && EventWindowIntent.classify(cmd("temperature", mode: "flywire_sensory"))?.source == .sensoryModel)
    }

    // ---- strict decode ---------------------------------------------------------
    do {
        let f = EWFixture()
        f.feed(to: 599)
        f.buffer.noteEvent(id: "J", kind: "unit", source: .directNeural, appliedTick: 600)
        let collecting = f.buffer.window(eventID: "J")!
        f.feed(to: 1599)
        let complete = f.buffer.window(eventID: "J")!
        let g = EWFixture(armAt: 501)
        g.feed(to: 600)
        g.buffer.noteEvent(id: "K", kind: "unit", source: .directNeural, appliedTick: 601)
        g.feed(to: 1600)
        let insufficient = g.buffer.window(eventID: "K")!
        let unknown = g.buffer.noteEvent(id: "U", kind: "unit", source: .physical, appliedTick: nil)
        check("valid fixtures round-trip exactly (collecting, complete, insufficient baseline, unknown tick)",
              [collecting, complete, insufficient, unknown].allSatisfy { w in decodeWindow(jsonObject(w)) == w })
        let big = jsonObject(complete)
        let rootIDs = ((big["groups"] as? [[String: Any]])?.first?["baseline"] as? [String: Any])?["root_ids"] as? [String]
        check("embedded observations keep root IDs as strings",
              rootIDs == ["720575940000000010", "720575940000000011", "720575940000000012", "720575940000000013"])
        func rejects(_ base: InteractionWindow, _ mutate: (inout [String: Any]) -> Void) -> Bool {
            var o = jsonObject(base); mutate(&o); return decodeWindow(o) == nil
        }
        func mutateGroup(_ o: inout [String: Any], _ f: (inout [String: Any]) -> Void) {
            var gs = o["groups"] as? [[String: Any]] ?? []
            if !gs.isEmpty { f(&gs[0]) }
            o["groups"] = gs
        }
        func mutateWindow(_ o: inout [String: Any], _ key: String, _ f: (inout [String: Any]) -> Void) {
            var w = o[key] as? [String: Any] ?? [:]; f(&w); o[key] = w
        }
        check("bad: missing event_id", rejects(complete) { $0["event_id"] = nil })
        check("bad: nullable applied_tick key absent", rejects(complete) { $0["applied_tick"] = nil })
        check("bad: delta present although the baseline is not complete (fabricated baseline)",
              rejects(insufficient) { mutateGroup(&$0) { $0["delta_hz_per_neuron"] = 5.0; $0["delta_unavailable_reason"] = NSNull() } })
        check("bad: delta that is not response − baseline", rejects(complete) { mutateGroup(&$0) { $0["delta_hz_per_neuron"] = 9.0 } })
        check("bad: baseline window of 499 ticks", rejects(complete) { mutateWindow(&$0, "baseline_window") { $0["start"] = 101 } })
        check("bad: response window of 999 ticks", rejects(complete) { mutateWindow(&$0, "response_window") { $0["end"] = 1598 } })
        check("bad: baseline kept although flagged insufficient",
              rejects(complete) { mutateWindow(&$0, "validity") { $0["baseline_insufficient"] = true } })
        check("bad: sufficient=true on a window with a missing baseline",
              rejects(insufficient) { mutateWindow(&$0, "validity") { $0["sufficient"] = true } })
        check("bad: motor_output claimed collected", rejects(complete) { mutateWindow(&$0, "motor_output") { $0["status"] = "collected" } })
        check("bad: unknown applied tick but windows present", rejects(unknown) { $0["baseline_window"] = ["start": 1, "end": 500] })
        check("bad: invalid status without any reason", rejects(unknown) { $0["status"] = "invalid"; mutateWindow(&$0, "validity") { $0["applied_tick_unknown"] = false } })
        check("bad: complete window carrying an invalidating flag", rejects(complete) { mutateWindow(&$0, "validity") { $0["brain_reset"] = true } })
        check("bad: wrong schema", rejects(complete) { $0["schema"] = "interaction_window.v0" })
        check("bad: overlapping_events lists the event itself", rejects(complete) { mutateWindow(&$0, "validity") { $0["overlapping_events"] = ["J"] } })
    }

    // ---- recorder: one interaction_window line per finalized window -----------
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eventwindowtest-\(UUID().uuidString)")
        let rec = ExperimentRecorder(baseDirectory: dir)
        let f = EWFixture()
        f.buffer.onFinalized = EventWindowIntent.recordingSink(rec)
        f.feed(to: 599)
        f.buffer.noteEvent(id: "idle", kind: "unit", source: .physical, appliedTick: nil)   // not recording: no line
        let path = rec.start()
        f.buffer.noteEvent(id: "R1", kind: "unit", source: .directNeural, appliedTick: 600)
        f.buffer.noteEvent(id: "R2", kind: "wind", source: .sensoryModel, appliedTick: nil)
        f.feed(to: 1599)
        rec.stop(); rec.flushForTesting()
        let lines = path.flatMap { try? String(contentsOfFile: $0 + "/events.jsonl", encoding: .utf8) }?
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
        let rows = lines.filter { $0["kind"] as? String == "interaction_window" }
        let decoded = rows.compactMap { ($0["interaction_window"] as? [String: Any]).flatMap(decodeWindow) }
        check("recorder: exactly the two windows finalized while recording, each strict-decodable, none from before",
              rows.count == 2 && decoded.count == 2 && Set(decoded.map(\.eventID)) == ["R1", "R2"]
                && decoded.first(where: { $0.eventID == "R1" }) == f.buffer.window(eventID: "R1"),
              "rows \(rows.count)")
        if let path { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try? FileManager.default.removeItem(at: dir)
    }

    // ---- UI text ------------------------------------------------------------------
    do {
        let f = EWFixture(armAt: 501)
        f.feed(to: 800)
        f.buffer.noteEvent(id: "T", kind: "flash", source: .sensoryModel, appliedTick: 801)
        let shown = EventWindowsLabel.text(windows: f.buffer.windows(), stats: f.buffer.stats(), paused: true)
        check("UI: collecting while paused says the window does not advance",
              shown.contains("collecting 0/1000 ms") && shown.contains("does not advance") && shown.contains("t801"), shown)
        f.feed(to: 1800)
        let done = EventWindowsLabel.text(windows: f.buffer.windows(), stats: f.buffer.stats(), paused: false)
        check("UI: insufficient baseline shows — and the reason, response in Hz, delta —",
              done.contains("— (") && done.contains("→ 30.00 Hz") && done.contains("Δ — (baseline not fully observed)"), done)
    }

    // ---- real path: a real MetalSim through the app's Coordinator entry points -------
    guard let c = loadConnectome(), let sim = makeDiagSim(connectome: c) else { print("no sim"); exit(1) }
    var chosen = sim.gf + sim.dnaL + sim.dnaR + sim.mdn + sim.fwd + sim.groom + sim.escw
    var seen = Set(chosen)
    for _ in 0..<150 {   // warm-up: add neurons that actually spike so the baseline is not vacuous
        sim.step(1)
        for i in sim.lastStepSpikes().map(Int.init) where chosen.count < 256 && seen.insert(i).inserted { chosen.append(i) }
    }
    let coord = Coordinator(bounds: CGSize(width: 800, height: 600), sim: sim)
    func drain() { for action in coord.drainSimulationActions() { action(coord) } }
    coord.observeBrainPick(BrainPick(indices: chosen, anchor: .zero, name: "eventwindow"))
    drain()
    sim.step(600)                    // observation began at tick 151; simMs is now 750
    let tickBefore = sim.simMs
    coord.labStimulatePopulation("GF", strength: 0.5, durationMs: 40)   // the Lab's group-stimulation path
    check("nothing is noted before the action runs on the simulation thread", sim.eventWindows.windows().isEmpty)
    drain()
    let real = sim.eventWindows.windows().first
    check("real path: direct-neural event anchored at simMs + 1 on the sim thread, local id with its origin stated",
          real?.appliedTick == tickBefore + 1 && real?.source == .directNeural && real?.eventIDOrigin == .local
            && real?.eventID == "local-1" && real?.eventKind == "population:GF" && real?.status == .collecting
            && real?.appliedTickOrigin.contains("sim_thread") == true,
          "applied \(String(describing: real?.appliedTick)) simMs \(tickBefore)")
    check("the stimulus has not reached the sim yet (pending until the next step)",
          sim.debugExternalInput(sim.gf).allSatisfy { $0 == 0 })
    Thread.sleep(forTimeInterval: 0.3)   // paused: wall time passes, no step runs
    check("paused for 300 ms of wall time: still collecting 0/1000",
          sim.eventWindows.windows().first?.status == .collecting && sim.eventWindows.windows().first?.responseTicksCollected == 0)
    sim.step(1)
    check("applied_tick is exactly the first step the stimulus drives (extInput on GF from that tick)",
          sim.simMs == real?.appliedTick && sim.debugExternalInput(sim.gf).allSatisfy { $0 >= 0.5 })
    var left = 998
    for chunk in [7, 64, 13, 1, 64] where left > 0 { let k = min(chunk, left); sim.step(k); left -= k }
    while left > 0 { let k = min(64, left); sim.step(k); left -= k }
    check("999 of 1000 response ticks: still collecting",
          sim.eventWindows.windows().first?.status == .collecting && sim.eventWindows.windows().first?.responseTicksCollected == 999)
    sim.step(1)
    let doneWindow = sim.eventWindows.window(eventID: "local-1")
    let rg = doneWindow?.groups.first
    let a = real?.appliedTick ?? 0
    let baseIndependent = try? sim.observer.observe(groupID: "x", members: chosen, start: a - 500, end: a - 1).get()
    let respIndependent = try? sim.observer.observe(groupID: "x", members: chosen, start: a, end: a + 999).get()
    var perTickBase = 0, perTickResp = 0
    for t in (a - 500)...(a - 1) { perTickBase += sim.observer.spikes(at: t)?.count ?? -100_000 }
    for t in a...(a + 999) { perTickResp += sim.observer.spikes(at: t)?.count ?? -100_000 }
    check("real path: complete after exactly 1000 simulated ticks, sufficient",
          doneWindow?.status == .complete && doneWindow?.validity.sufficient == true)
    check("real path: window counts equal an independent observe() query over the same windows",
          rg?.baseline?.spikeCount == baseIndependent?.spikeCount && rg?.response?.spikeCount == respIndependent?.spikeCount
            && rg?.baseline?.rateHzPerNeuron == baseIndependent?.rateHzPerNeuron
            && rg?.response?.rateHzPerNeuron == respIndependent?.rateHzPerNeuron,
          "baseline \(String(describing: rg?.baseline?.spikeCount)) vs \(String(describing: baseIndependent?.spikeCount)), response \(String(describing: rg?.response?.spikeCount)) vs \(String(describing: respIndependent?.spikeCount))")
    check("real path: counts also equal the sum of per-tick spike rows, and are not vacuous (GF stimulus drove spikes)",
          rg?.baseline?.spikeCount == perTickBase && rg?.response?.spikeCount == perTickResp && perTickResp > 0 && perTickBase > 0,
          "baseline \(perTickBase) response \(perTickResp)")
    let gfBase = try? sim.observer.observe(groupID: "gf", members: sim.gf, start: a - 500, end: a - 1).get()
    let gfResp = try? sim.observer.observe(groupID: "gf", members: sim.gf, start: a, end: a + 999).get()
    check("real path: the event is visible where it was applied (GF silent before, spiking after the stimulus)",
          gfBase?.spikeCount == 0 && (gfResp?.spikeCount ?? 0) > 0,
          "GF baseline \(String(describing: gfBase?.spikeCount)) response \(String(describing: gfResp?.spikeCount))")
    if let b = rg?.baseline?.rateHzPerNeuron, let r = rg?.response?.rateHzPerNeuron {
        check("real path: delta is response − baseline", rg?.deltaHzPerNeuron == r - b, String(format: "%.3f → %.3f Hz", b, r))
    } else { check("real path: baseline and response present", false) }
    // V7.4 seam: the selection plus exactly the registry groups it fully covers.
    let covered = sim.groupRegistry.groups(fullyCoveredBy: chosen).map(\.groupID)
    let ids = doneWindow?.groups.map(\.groupID) ?? []
    let gfGroup = doneWindow?.groups.first { $0.groupID == "threat.gf" }
    check("registry seam: window groups = selection + every fully covered registry group (none partial)",
          ids == ["selection"] + covered && covered.contains("motor.command_dns") && covered.contains("threat.gf")
            && !ids.contains("threat.looming"), ids.joined(separator: ","))
    check("registry seam: threat.gf counts equal an independent GF observe()",
          gfGroup?.baseline?.spikeCount == gfBase?.spikeCount && gfGroup?.response?.spikeCount == gfResp?.spikeCount,
          "\(String(describing: gfGroup?.response?.spikeCount)) vs \(String(describing: gfResp?.spikeCount))")

    // Local modeled sensory event, then a brain reset through the app's path.
    sim.step(1600)   // clear the first window's range so nothing below overlaps it
    coord.labApplyWind(strength: 0.5, durationMs: 100)
    drain()
    let wind = sim.eventWindows.windows().first
    check("real path: local modeled wind noted at simMs + 1 as sensory_model",
          wind?.eventKind == "wind" && wind?.source == .sensoryModel && wind?.appliedTick == sim.simMs + 1
            && wind?.status == .collecting && wind?.validity.overlappingEvents.isEmpty == true)
    let epoch0 = sim.observer.selection().brainEpoch
    coord.labResetBrain()
    drain()
    let afterReset = sim.eventWindows.window(eventID: wind?.eventID ?? "")
    check("real path: brain reset through the app invalidates the collecting window (brain_reset)",
          sim.observer.selection().brainEpoch == epoch0 + 1 && afterReset?.status == .invalid
            && afterReset?.validity.brainReset == true)
    sim.step(10)

    // ⚡ click path and selection change through the app's real wiring.
    guard let screen = NSScreen.screens.first else { check("brain view needs a screen", false); suite.finish() }
    let wc = BrainWindowController(connectome: c, sim: sim, screen: screen)
    wc.connect(to: coord) { _, _, _ in }
    wc.clickStimulates = true
    guard let pick = wc.pick(rayOrigin: SIMD3<Float>(0, 0, 40), direction: SIMD3(0, 0, -1)) else {
        check("brain pick", false); suite.finish()
    }
    wc.activate(pick)
    drain()
    let click = sim.eventWindows.windows().first
    check("real path: ⚡ click noted as direct_neural at simMs + 1, collecting",
          click?.eventKind.hasPrefix("brain_click") == true && click?.source == .directNeural
            && click?.appliedTick == sim.simMs + 1 && click?.status == .collecting)
    coord.clearBrainObservation()
    drain()
    check("real path: clearing the selection invalidates it (selection_changed)",
          sim.eventWindows.window(eventID: click?.eventID ?? "")?.validity.selectionChanged == true
            && sim.eventWindows.window(eventID: click?.eventID ?? "")?.status == .invalid)
    let noSel = sim.eventWindows.noteEvent(kind: "late", source: .directNeural, appliedTick: sim.simMs + 1)
    check("with no selection a new event is invalid(no_selection)", noSel.status == .invalid && noSel.validity.noSelection)
    suite.finish()
}
#endif
