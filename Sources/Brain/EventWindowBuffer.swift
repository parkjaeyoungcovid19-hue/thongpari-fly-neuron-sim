// EventWindowBuffer.swift — V7.5 pre/post-event neural buffer.
//
// Owns the `interaction_window.v1` records. An event is noted at its applied
// tick; the buffer then waits for SIMULATION ticks (the observer's last
// recorded tick) and never for wall time, so a paused simulation leaves every
// window `collecting` however long the wall clock runs. The window is read
// from the observer's 2,048-tick ring right after the batch that completes it
// (`MetalSim.step` calls `advance()` on the simulation thread), long before the
// ring could evict its baseline (pre + post ≤ ring − one 64-tick batch).
//
// Bounds and overflow (playbook §4: every queue has a size and a policy):
// - at most `InteractionWindowCapability.maxCollecting` (16) windows collect at
//   once. A 17th event displaces the OLDEST collecting window, which is
//   finalized as invalid(buffer_overflow) and kept in history — nothing is
//   dropped silently.
// - at most `maxHistory` (64) finished windows stay in memory for the UI; older
//   ones leave memory (counted in `stats().historyEvicted`) after they were
//   handed to `onFinalized` (the Lab recorder).
// - command intents waiting for their ACK: at most 256; the oldest is evicted
//   (counted), and an ACK without an intent for a flag-dependent action is
//   counted as `unclassifiedAcks` rather than guessed.
//
// Groups: the buffer asks `groupProvider` for `[(id, members)]` when an event is
// noted. The default is one group "selection" = the whole current exact
// selection. A later step (V7.4 registry) replaces the closure; nothing else
// here knows about groups.

import Foundation

typealias EventWindowGroup = (id: String, members: [Int])

struct EventWindowStats: Equatable {
    var collecting = 0
    var history = 0
    /// Collecting windows displaced by overflow (finalized invalid, kept in history).
    var overflowDisplaced = 0
    /// Finished windows that left the in-memory history (already recorded).
    var historyEvicted = 0
    var intentsEvicted = 0
    var unclassifiedAcks = 0
}

final class EventWindowBuffer {
    private struct Pending {
        var seq: Int
        var window: InteractionWindow
        var groups: [EventWindowGroup]
    }

    private let lock = NSLock()
    private let observer: NeuralObserver
    private var config: EventWindowConfig
    private var provider: () -> [EventWindowGroup]
    private var collecting: [Pending] = []
    private var history: [(seq: Int, window: InteractionWindow)] = []
    private var seqCounter = 0
    private var localCounter = 0
    private var intents: [Int: (kind: String, source: InteractionEventSource)] = [:]
    private var counters = EventWindowStats()
    private var sink: ((InteractionWindow) -> Void)?

    static let maxIntents = 256

    init(observer: NeuralObserver, config: EventWindowConfig = .standard) {
        self.observer = observer
        self.config = config
        provider = { [unowned observer] in
            let info = observer.selection()
            return info.isEmpty ? [] : [(id: "selection", members: info.neurons)]
        }
    }

    // MARK: Configuration seams

    /// THE groups hook. Called off the buffer lock, when an event is noted.
    var groupProvider: () -> [EventWindowGroup] {
        get { lock.lock(); defer { lock.unlock() }; return provider }
        set { lock.lock(); provider = newValue; lock.unlock() }
    }

    /// Called once per finalized window (complete or invalid) with no buffer
    /// lock held. On the simulation thread for `advance`/overflow, on the
    /// noting thread for windows that are invalid on arrival.
    var onFinalized: ((InteractionWindow) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return sink }
        set { lock.lock(); sink = newValue; lock.unlock() }
    }

    var currentConfig: EventWindowConfig { lock.lock(); defer { lock.unlock() }; return config }

    /// New window lengths for events noted from now on. False when the ring
    /// could not serve the span exactly (nothing changes then).
    @discardableResult
    func configure(preMs: Int, postMs: Int) -> Bool {
        guard let c = EventWindowConfig.validated(preMs: preMs, postMs: postMs) else { return false }
        lock.lock(); config = c; lock.unlock()
        return true
    }

    // MARK: Event funnel

    /// Notes one discrete event. Any thread. `appliedTick` is the first
    /// simulation tick that can reflect it, or nil when no reliable neural tick
    /// exists — the event is then kept as invalid(applied_tick_unknown).
    /// `id == nil` generates a local id (origin `local_counter`). Noting an id
    /// that is already known returns that window unchanged.
    @discardableResult
    func noteEvent(id: String? = nil, idOrigin: InteractionEventIDOrigin = .labCommandID,
                   kind: String, source: InteractionEventSource,
                   appliedTick: Int?, appliedTickOrigin: String? = nil,
                   sensorySampleTick: Int? = nil) -> InteractionWindow {
        let usable = appliedTick.flatMap { $0 >= 1 ? $0 : nil }
        let info = observer.selection()
        let provided = usable == nil ? [] : groupProvider()
        var groups: [EventWindowGroup] = []
        for g in provided {
            var seen = Set<Int>()
            let members = g.members.filter { seen.insert($0).inserted }
            if !members.isEmpty { groups.append((id: g.id, members: members)) }
        }

        var finalized: [InteractionWindow] = []
        lock.lock()
        let eventID: String, origin: InteractionEventIDOrigin
        if let id {
            if let existing = find(id) { lock.unlock(); return existing }
            eventID = id; origin = idOrigin
        } else {
            localCounter += 1
            eventID = "local-\(localCounter)"; origin = .local
        }
        seqCounter += 1
        let selectionID: Int? = info.isEmpty ? nil : info.selectionID
        var w = InteractionWindow(
            eventID: eventID, eventIDOrigin: origin, eventKind: kind, source: source,
            appliedTick: usable,
            appliedTickOrigin: appliedTickOrigin ?? (usable == nil ? "unknown: no reliable neural tick" : "caller"),
            sensorySampleTick: sensorySampleTick, brainEpoch: info.brainEpoch,
            selectionID: selectionID, config: config)
        if let a = usable {
            markOverlaps(of: &w, appliedTick: a)
            if a - w.preMs < 1 || info.firstTick > a - w.preMs { w.validity.baselineInsufficient = true }
        }
        let seq = seqCounter
        if usable == nil {
            w.validity.appliedTickUnknown = true
            w.validity.baselineInsufficient = false
            finalized.append(finishInvalid(&w, seq: seq))
        } else if info.isEmpty || groups.isEmpty {
            w.validity.noSelection = true
            finalized.append(finishInvalid(&w, seq: seq))
        } else {
            if collecting.count >= InteractionWindowCapability.maxCollecting {
                var displaced = collecting.removeFirst()
                displaced.window.validity.bufferOverflow = true
                counters.overflowDisplaced += 1
                finalized.append(finishInvalid(&displaced.window, seq: displaced.seq))
            }
            collecting.append(Pending(seq: seq, window: w, groups: groups))
        }
        let sink = self.sink
        lock.unlock()
        for f in finalized { sink?(f) }
        return finalized.first(where: { $0.eventID == eventID }) ?? w
    }

    /// Records the tick at which a sensory sample (e.g. an eye frame) was truly
    /// taken for an event. Only a caller that knows it should call this; the
    /// buffer never derives it and computes no latency. False when unknown id.
    @discardableResult
    func setSensorySampleTick(eventID: String, tick: Int) -> Bool {
        guard tick >= 1 else { return false }
        lock.lock(); defer { lock.unlock() }
        if let i = collecting.firstIndex(where: { $0.window.eventID == eventID }) {
            collecting[i].window.sensorySampleTick = tick; return true
        }
        if let i = history.firstIndex(where: { $0.window.eventID == eventID }) {
            history[i].window.sensorySampleTick = tick; return true
        }
        return false
    }

    // MARK: Command intents (Lab ACK funnel)

    /// Remembers what a just-sent backend command means, until its ACK.
    func declareCommand(id: Int, kind: String, source: InteractionEventSource) {
        lock.lock(); defer { lock.unlock() }
        intents[id] = (kind, source)
        if intents.count > Self.maxIntents, let oldest = intents.keys.min() {
            intents.removeValue(forKey: oldest)
            counters.intentsEvicted += 1
        }
    }

    func takeIntent(commandID: Int) -> (kind: String, source: InteractionEventSource)? {
        lock.lock(); defer { lock.unlock() }
        return intents.removeValue(forKey: commandID)
    }

    func countUnclassifiedAck() { lock.lock(); counters.unclassifiedAcks += 1; lock.unlock() }

    // MARK: Simulation-thread advance

    /// Call on the simulation thread right after the observer recorded a batch
    /// (and after reset / selection changes). Uses only simulation ticks.
    func advance() {
        let info = observer.selection()
        let capacity = observer.retainedCapacity
        var finalized: [InteractionWindow] = []
        lock.lock()
        var keep: [Pending] = []
        for var p in collecting {
            let w = p.window
            if w.brainEpoch != info.brainEpoch {
                p.window.validity.brainReset = true
                finalized.append(finishInvalid(&p.window, seq: p.seq))
            } else if info.isEmpty || info.selectionID != w.selectionID {
                p.window.validity.selectionChanged = true
                finalized.append(finishInvalid(&p.window, seq: p.seq))
            } else if let a = w.appliedTick {
                let collected = min(w.postMs, max(0, info.lastTick - a + 1))
                p.window.responseTicksCollected = collected
                if collected >= w.postMs {
                    finalized.append(finishComplete(&p, info: info, capacity: capacity))
                } else {
                    keep.append(p)
                }
            } else {
                keep.append(p)
            }
        }
        collecting = keep
        let sink = self.sink
        lock.unlock()
        for f in finalized { sink?(f) }
    }

    // MARK: Reads (any thread)

    /// Newest-noted first: collecting windows and finished history together.
    func windows() -> [InteractionWindow] {
        lock.lock(); defer { lock.unlock() }
        let all = collecting.map { ($0.seq, $0.window) } + history.map { ($0.seq, $0.window) }
        return all.sorted { $0.0 > $1.0 }.map(\.1)
    }

    func window(eventID: String) -> InteractionWindow? { lock.lock(); defer { lock.unlock() }; return find(eventID) }

    func stats() -> EventWindowStats {
        lock.lock(); defer { lock.unlock() }
        var s = counters
        s.collecting = collecting.count; s.history = history.count
        return s
    }

    // MARK: Internals (lock held)

    private func find(_ id: String) -> InteractionWindow? {
        collecting.first(where: { $0.window.eventID == id })?.window
            ?? history.first(where: { $0.window.eventID == id })?.window
    }

    /// Two events overlap when their analysis ranges [applied − pre, applied +
    /// post − 1] intersect in the same brain epoch (one's response then sits in
    /// the other's baseline or response). Flagged on both, including a window
    /// that already finished (the recorder line of that one stays as written).
    private func markOverlaps(of w: inout InteractionWindow, appliedTick a: Int) {
        func intersects(_ o: InteractionWindow) -> Bool {
            guard let b = o.appliedTick, o.brainEpoch == w.brainEpoch, o.eventID != w.eventID else { return false }
            return b - o.preMs <= a + w.postMs - 1 && a - w.preMs <= b + o.postMs - 1
        }
        func add(_ id: String, to v: inout InteractionValidity) {
            if !v.overlappingEvents.contains(id) { v.overlappingEvents.append(id) }
        }
        for i in collecting.indices where intersects(collecting[i].window) {
            add(collecting[i].window.eventID, to: &w.validity)
            add(w.eventID, to: &collecting[i].window.validity)
        }
        for i in history.indices where intersects(history[i].window) {
            add(history[i].window.eventID, to: &w.validity)
            add(w.eventID, to: &history[i].window.validity)
        }
    }

    private func finishInvalid(_ w: inout InteractionWindow, seq: Int) -> InteractionWindow {
        w.status = .invalid
        w.validity.sufficient = false
        remember(w, seq: seq)
        return w
    }

    private func remember(_ w: InteractionWindow, seq: Int) {
        history.append((seq, w))
        if history.count > InteractionWindowCapability.maxHistory {
            history.removeFirst()
            counters.historyEvicted += 1
        }
    }

    /// Reads both windows for every group. A window is `complete` once its
    /// response is fully observed for every group; a baseline that is not fully
    /// observed is null (and flagged), never estimated.
    private func finishComplete(_ p: inout Pending, info: ObservationSelectionInfo, capacity: Int) -> InteractionWindow {
        let w0 = p.window
        guard let bw = w0.baselineWindow, let rw = w0.responseWindow else { return finishInvalid(&p.window, seq: p.seq) }
        // First tick the ring still holds; ticks of this selection before it were evicted.
        let retainedFrom = info.lastTick - capacity + 1
        func evicted(_ win: TickWindow) -> Bool {
            let lo = max(win.start, info.firstTick, 1)
            return lo <= win.end && lo < retainedFrom
        }
        func slice(_ g: EventWindowGroup, _ win: TickWindow) -> (obs: NeuralObservation?, missing: Int, notSelected: Bool) {
            let lo = max(win.start, 1)
            guard lo <= win.end else { return (nil, win.length, false) }
            switch observer.observe(groupID: g.id, members: g.members, start: lo, end: win.end) {
            case .failure: return (nil, win.length, true)
            case .success(let o):
                let missing = win.length - o.observedTicks
                return (lo == win.start && o.validity == .complete ? o : nil, missing, false)
            }
        }
        var results: [GroupWindowResult] = []
        var droppedPerObservable: [Int] = []
        for g in p.groups {
            let b = slice(g, bw), r = slice(g, rw)
            let notSelected = b.notSelected || r.notSelected
            if !notSelected { droppedPerObservable.append(b.missing + r.missing) }
            results.append(GroupWindowResult(
                groupID: g.id, memberCount: g.members.count,
                baseline: b.obs, baselineMissingTicks: b.missing,
                response: r.obs, responseMissingTicks: r.missing,
                deltaUnavailableReason: notSelected ? "members_not_in_selection" : nil))
        }
        var w = w0
        w.groups = results
        // Missing ticks are a property of the ring, so they are taken over the
        // groups that could be read; a group outside the selection says so itself.
        w.validity.droppedSamples = droppedPerObservable.max()
            ?? results.map { $0.baselineMissingTicks + $0.responseMissingTicks }.max() ?? 0
        w.validity.evicted = evicted(bw) || evicted(rw)
        if results.contains(where: { $0.baseline == nil }) { w.validity.baselineInsufficient = true }
        // Complete = the response window was read for at least one group.
        let responseObserved = results.contains { $0.response != nil }
        w.responseTicksCollected = w.postMs
        w.status = responseObserved ? .complete : .invalid
        w.validity.sufficient = w.impliedSufficient
        remember(w, seq: p.seq)
        return w
    }
}
