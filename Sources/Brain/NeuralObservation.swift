// NeuralObservation.swift — V7.2 exact observation primitive.
//
// A small selection (at most `ObservationCapability.exactSelectionLimit`
// neurons) is tagged in the LIF kernel; every simulated millisecond the kernel
// marks which selected neurons spiked (see LIF.metal `observeSlot`). Only that
// 256-byte row per step is read back — never the whole GPU state.
//
// Contract (docs/plans/VIRTUAL_FLY_LAB_V7_PLAN.md §4 NeuralObservation):
// - Ticks are 1-based simulation steps (`MetalSim.simMs` after the step), 1 ms
//   each. A window is the closed range startTick...endTick.
// - `spike_count` sums the exact spikes of the DISTINCT members over the ticks
//   that were actually observed. A neuron listed twice in one group counts once;
//   overlapping (nested) groups each count their shared neurons.
// - `rate_hz_per_neuron` = spike_count × 1000 / (observed_ticks × member_count).
//   It is absent (null) when either factor is 0 — never a fabricated 0 Hz.
// - Ticks before the selection began, evicted from the ring, or not simulated
//   yet are `dropped_samples`; the result is then `partial`, not complete.
// - Root IDs are JSON strings (64-bit IDs do not survive JSON doubles).
// - `source` is always `exact` here. The lossy SpikeBus flashes are `sampled`
//   and are never promoted to this type.

import Foundation

enum ObservationCapability {
    static let schema = "neural_observation.v1"
    /// Neurons one exact selection may hold (LIF.metal's observed row width).
    static let exactSelectionLimit = 256
    /// Simulated milliseconds retained per selection (≈2 s: room for a 0.5 s
    /// pre-event + 1 s post-event window later in V7.5).
    static let retainedTicks = 2048
    static let tickMs = 1
}

enum ObservationSource: String, Codable { case exact, sampled }

enum ObservationValidity: String, Codable {
    /// Every requested tick was observed and the group has members.
    case complete
    /// Some ticks were not observed (before the selection, evicted, or future).
    case partial
    /// Nothing usable: no observed tick or no member.
    case empty
}

enum ObservationError: Error, Equatable, CustomStringConvertible {
    case overLimit(requested: Int, limit: Int)
    case outOfRange(index: Int)
    case notSelected(indices: [Int])
    case invalidWindow(start: Int, end: Int)

    var description: String {
        switch self {
        case let .overLimit(r, l): return "selection of \(r) neurons exceeds the exact limit \(l)"
        case let .outOfRange(i): return "neuron index \(i) is out of range"
        case let .notSelected(ix): return "\(ix.count) member(s) are not in the exact selection"
        case let .invalidWindow(s, e): return "invalid window \(s)...\(e)"
        }
    }
}

struct NeuralObservation: Codable, Equatable {
    var schema = ObservationCapability.schema
    var sessionID: String?
    var sessionEpoch: Int?
    /// MetalSim reset generation; ticks restart at 1 after every reset.
    var brainEpoch: Int
    var selectionID: Int
    var startTick: Int
    var endTick: Int
    var groupID: String
    var rootIDs: [String]
    var memberCount: Int
    var spikeCount: Int
    var observedTicks: Int
    var droppedSamples: Int
    var rateHzPerNeuron: Double?
    var source: ObservationSource
    var validity: ObservationValidity

    enum CodingKeys: String, CodingKey {
        case schema, source, validity
        case sessionID = "session_id", sessionEpoch = "session_epoch", brainEpoch = "brain_epoch"
        case selectionID = "selection_id", startTick = "start_tick", endTick = "end_tick"
        case groupID = "group_id", rootIDs = "root_ids", memberCount = "member_count"
        case spikeCount = "spike_count", observedTicks = "observed_ticks"
        case droppedSamples = "dropped_samples", rateHzPerNeuron = "rate_hz_per_neuron"
    }

    /// Strict decode: required fields must be present, the schema must match,
    /// counts must be non-negative and the rate (when present) finite and
    /// consistent with its own denominator.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        sessionEpoch = try c.decodeIfPresent(Int.self, forKey: .sessionEpoch)
        brainEpoch = try c.decode(Int.self, forKey: .brainEpoch)
        selectionID = try c.decode(Int.self, forKey: .selectionID)
        startTick = try c.decode(Int.self, forKey: .startTick)
        endTick = try c.decode(Int.self, forKey: .endTick)
        groupID = try c.decode(String.self, forKey: .groupID)
        rootIDs = try c.decode([String].self, forKey: .rootIDs)
        memberCount = try c.decode(Int.self, forKey: .memberCount)
        spikeCount = try c.decode(Int.self, forKey: .spikeCount)
        observedTicks = try c.decode(Int.self, forKey: .observedTicks)
        droppedSamples = try c.decode(Int.self, forKey: .droppedSamples)
        rateHzPerNeuron = try c.decodeIfPresent(Double.self, forKey: .rateHzPerNeuron)
        source = try c.decode(ObservationSource.self, forKey: .source)
        validity = try c.decode(ObservationValidity.self, forKey: .validity)
        func fail(_ why: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: c.codingPath, debugDescription: why))
        }
        guard schema == ObservationCapability.schema else { throw fail("schema \(schema)") }
        guard rootIDs.count == memberCount,
              rootIDs.allSatisfy({ id in UInt64(id).map { String($0) == id } ?? false }) else {
            throw fail("root_ids must be \(memberCount) canonical decimal strings")
        }
        guard min(memberCount, spikeCount, observedTicks, droppedSamples) >= 0, startTick <= endTick,
              observedTicks + droppedSamples == endTick - startTick + 1,
              spikeCount <= observedTicks * memberCount else {
            throw fail("counts inconsistent with the window")
        }
        // Rate and validity must be the ones the counts imply.
        let implied = NeuralObservation(brainEpoch: brainEpoch, selectionID: selectionID, startTick: startTick,
                                        endTick: endTick, groupID: groupID, rootIDs: rootIDs,
                                        memberCount: memberCount, spikeCount: spikeCount,
                                        observedTicks: observedTicks, droppedSamples: droppedSamples, source: source)
        switch (rateHzPerNeuron, implied.rateHzPerNeuron) {
        case (nil, nil): break
        case let (r?, want?) where r.isFinite && abs(r - want) <= 1e-9 * max(1, want): break
        default: throw fail("rate_hz_per_neuron disagrees with its counts")
        }
        guard validity == implied.validity else { throw fail("validity disagrees with its counts") }
    }

    init(sessionID: String? = nil, sessionEpoch: Int? = nil, brainEpoch: Int, selectionID: Int,
         startTick: Int, endTick: Int, groupID: String, rootIDs: [String], memberCount: Int,
         spikeCount: Int, observedTicks: Int, droppedSamples: Int, source: ObservationSource) {
        self.sessionID = sessionID; self.sessionEpoch = sessionEpoch
        self.brainEpoch = brainEpoch; self.selectionID = selectionID
        self.startTick = startTick; self.endTick = endTick
        self.groupID = groupID; self.rootIDs = rootIDs; self.memberCount = memberCount
        self.spikeCount = spikeCount; self.observedTicks = observedTicks
        self.droppedSamples = droppedSamples; self.source = source
        rateHzPerNeuron = memberCount > 0 && observedTicks > 0
            ? Double(spikeCount) * 1000 / Double(observedTicks * memberCount) : nil
        validity = memberCount == 0 || observedTicks == 0 ? .empty : (droppedSamples > 0 ? .partial : .complete)
    }
}

/// Per-tick spike bits for one selection, retained for the last `capacity`
/// ticks. Pure value type: no GPU, no locks, so a fixture can drive it.
struct ObservationRing {
    static let words = ObservationCapability.exactSelectionLimit / 64

    let capacity: Int
    /// Neuron index per slot, in slot order.
    private(set) var selection: [Int] = []
    private var slotOf: [Int: Int] = [:]
    /// First tick that belongs to this selection (0 before any is armed).
    private(set) var firstTick = 0
    /// Last tick recorded (firstTick - 1 when none yet).
    private(set) var lastTick = 0
    /// Ticks whose row never arrived (a gap in `record`): never counted.
    private(set) var gapTicks = 0
    private var bits: [UInt64]
    private var tickAt: [Int]

    init(capacity: Int = ObservationCapability.retainedTicks) {
        self.capacity = max(1, capacity)
        bits = [UInt64](repeating: 0, count: self.capacity * Self.words)
        tickAt = [Int](repeating: -1, count: self.capacity)
    }

    /// Starts a new selection whose first observed tick is `startTick`.
    mutating func arm(_ neurons: [Int], startTick: Int) {
        selection = neurons
        slotOf = Dictionary(uniqueKeysWithValues: neurons.enumerated().map { ($1, $0) })
        restart(at: startTick)
    }

    /// Forgets every recorded tick but keeps the selection.
    mutating func restart(at startTick: Int) {
        firstTick = startTick; lastTick = startTick - 1; gapTicks = 0
        for i in tickAt.indices { tickAt[i] = -1 }
    }

    func slot(of neuron: Int) -> Int? { slotOf[neuron] }

    /// Records one tick: `spiked` yields the selection slots that spiked.
    /// Ticks must arrive in order; a skipped tick is a gap, never zeros.
    mutating func record(tick: Int, spiked: (inout [UInt64]) -> Void) {
        guard !selection.isEmpty, tick > lastTick else { return }
        if tick > lastTick + 1 { gapTicks += tick - lastTick - 1 }
        lastTick = tick
        let r = tick % capacity
        var w = [UInt64](repeating: 0, count: Self.words)
        spiked(&w)
        for k in 0..<Self.words { bits[r * Self.words + k] = w[k] }
        tickAt[r] = tick
    }

    /// True when `tick` was recorded and is still retained.
    func has(_ tick: Int) -> Bool { tick >= 1 && tickAt[tick % capacity] == tick }

    func spiked(slot: Int, at tick: Int) -> Bool {
        guard has(tick) else { return false }
        return bits[(tick % capacity) * Self.words + slot / 64] >> UInt64(slot % 64) & 1 == 1
    }

    /// Exact count over `start...end` for the distinct `members`: one popcount
    /// of the member mask per retained tick. Per-neuron counts on request.
    func aggregate(members: [Int], start: Int, end: Int, perNeuron wantPer: Bool = false)
        -> Result<(spikes: Int, observedTicks: Int, dropped: Int, perNeuron: [Int: Int]), ObservationError> {
        guard start <= end, start >= 1 else { return .failure(.invalidWindow(start: start, end: end)) }
        let distinct = Array(Set(members)).sorted()
        let missing = distinct.filter { slotOf[$0] == nil }
        guard missing.isEmpty else { return .failure(.notSelected(indices: missing)) }
        var mask = [UInt64](repeating: 0, count: Self.words)
        for m in distinct { let s = slotOf[m]!; mask[s / 64] |= 1 << UInt64(s % 64) }
        var spikes = 0, observed = 0
        var per: [Int: Int] = wantPer ? Dictionary(uniqueKeysWithValues: distinct.map { ($0, 0) }) : [:]
        // Only the retained span can hold ticks; skip the rest arithmetically.
        let lo = max(start, lastTick - capacity + 1, 1), hi = min(end, lastTick)
        if lo <= hi {
            for t in lo...hi where has(t) {
                observed += 1
                let base = (t % capacity) * Self.words
                for k in 0..<Self.words { spikes += (bits[base + k] & mask[k]).nonzeroBitCount }
                if wantPer {
                    for m in distinct where spiked(slot: slotOf[m]!, at: t) { per[m, default: 0] += 1 }
                }
            }
        }
        return .success((spikes, observed, (end - start + 1) - observed, per))
    }
}

/// What a UI needs to show about the current selection.
struct ObservationSelectionInfo: Equatable {
    var selectionID = 0
    var brainEpoch = 0
    var name = ""
    var neurons: [Int] = []
    /// Neurons the caller asked for but which did not fit under the exact limit.
    var omitted = 0
    var firstTick = 0
    var lastTick = 0
    var isEmpty: Bool { neurons.isEmpty }
}

/// Thread-safe owner of the ring. MetalSim writes from the simulation thread;
/// any thread may query.
final class NeuralObserver {
    private let lock = NSLock()
    private var ring: ObservationRing
    private var info = ObservationSelectionInfo()
    private let rootIds: [UInt64]
    let limit: Int
    /// A selection requested but not yet applied by the simulation thread
    /// (e.g. while paused). Cleared when the next selection is armed.
    private var pendingName: String?

    init(rootIds: [UInt64], limit: Int = ObservationCapability.exactSelectionLimit,
         capacity: Int = ObservationCapability.retainedTicks) {
        self.rootIds = rootIds
        self.limit = min(limit, ObservationCapability.exactSelectionLimit)   // the ring row is 256 bits
        ring = ObservationRing(capacity: capacity)
    }

    /// Validates a request. Duplicates collapse; order is kept. Returns the
    /// distinct indices, or why they cannot be observed exactly.
    func validate(_ indices: [Int]) -> Result<[Int], ObservationError> {
        var seen = Set<Int>(), out: [Int] = []
        for i in indices {
            guard i >= 0 && i < rootIds.count else { return .failure(.outOfRange(index: i)) }
            if seen.insert(i).inserted { out.append(i) }
        }
        guard out.count <= limit else { return .failure(.overLimit(requested: out.count, limit: limit)) }
        return .success(out)
    }

    func arm(_ neurons: [Int], name: String, omitted: Int, startTick: Int) {
        lock.lock(); defer { lock.unlock() }
        ring.arm(neurons, startTick: startTick)
        pendingName = nil
        info.selectionID += 1
        info.name = name; info.neurons = neurons; info.omitted = omitted
        info.firstTick = startTick; info.lastTick = startTick - 1
    }

    /// Brain reset: ticks restart at 1 in a new epoch, the selection stays.
    func newEpoch() {
        lock.lock(); defer { lock.unlock() }
        info.brainEpoch += 1
        ring.restart(at: 1)
        info.firstTick = 1; info.lastTick = 0
    }

    var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return !info.neurons.isEmpty }

    /// Ticks the ring retains (V7.5 asks whether a window's ticks were evicted).
    var retainedCapacity: Int { lock.lock(); defer { lock.unlock() }; return ring.capacity }

    /// One batch from the kernel: `rows` holds `count` rows of `rowWidth`
    /// bytes, row s being tick `firstTick + s`.
    func record(firstTick: Int, count: Int, rows: UnsafePointer<UInt8>, rowWidth: Int) {
        lock.lock(); defer { lock.unlock() }
        let n = ring.selection.count
        guard n > 0 else { return }
        for s in 0..<count {
            let row = rows + s * rowWidth
            ring.record(tick: firstTick + s) { w in
                for slot in 0..<n where row[slot] != 0 { w[slot / 64] |= 1 << UInt64(slot % 64) }
            }
        }
        info.lastTick = ring.lastTick
    }

    func selection() -> ObservationSelectionInfo {
        lock.lock(); defer { lock.unlock() }
        return info
    }

    /// Any thread: note a request the simulation thread has not applied yet.
    func markPending(_ name: String) { lock.lock(); pendingName = name; lock.unlock() }
    func pending() -> String? { lock.lock(); defer { lock.unlock() }; return pendingName }

    /// Exact observation of `members` (indices; all must be selected) over
    /// `start...end`. A nil window means the whole retained span.
    func observe(groupID: String, members: [Int], start: Int? = nil, end: Int? = nil,
                 sessionID: String? = nil, sessionEpoch: Int? = nil) -> Result<NeuralObservation, ObservationError> {
        lock.lock(); defer { lock.unlock() }
        let e = end ?? ring.lastTick
        let s = start ?? max(ring.firstTick, e - ring.capacity + 1)
        switch ring.aggregate(members: members, start: s, end: e) {
        case .failure(let err): return .failure(err)
        case .success(let a):
            let distinct = Array(Set(members)).sorted()
            return .success(NeuralObservation(
                sessionID: sessionID, sessionEpoch: sessionEpoch,
                brainEpoch: info.brainEpoch, selectionID: info.selectionID,
                startTick: s, endTick: e, groupID: groupID,
                rootIDs: distinct.map { String(rootIds[$0]) }, memberCount: distinct.count,
                spikeCount: a.spikes, observedTicks: a.observedTicks, droppedSamples: a.dropped,
                source: .exact))
        }
    }

    /// Per-neuron exact counts over a window (same rules as `observe`).
    func perNeuronCounts(start: Int, end: Int) -> [Int: Int] {
        lock.lock(); defer { lock.unlock() }
        guard case .success(let a) = ring.aggregate(members: ring.selection, start: start, end: end, perNeuron: true) else { return [:] }
        return a.perNeuron
    }

    /// Exact raster: every selected-neuron spike in `start...end` still retained,
    /// as (tick, neuron index). Ticks that left the ring are simply absent.
    func spikeEvents(start: Int, end: Int) -> [(tick: Int, neuron: Int)] {
        lock.lock(); defer { lock.unlock() }
        guard start <= end else { return [] }
        var out: [(tick: Int, neuron: Int)] = []
        for t in max(start, 1)...max(end, 1) where ring.has(t) {
            for (slot, neuron) in ring.selection.enumerated() where ring.spiked(slot: slot, at: t) { out.append((t, neuron)) }
        }
        return out
    }

    /// The sub-ranges of `start...end` whose ticks are NOT retained in the ring
    /// (evicted, never recorded, or not yet simulated); empty when all are held.
    func missingRanges(start: Int, end: Int) -> [ClosedRange<Int>] {
        lock.lock(); defer { lock.unlock() }
        guard start <= end else { return [] }
        var out: [ClosedRange<Int>] = []
        var from: Int?
        for t in start...end {
            if ring.has(t) { if let f = from { out.append(f...(t - 1)); from = nil } }
            else if from == nil { from = t }
        }
        if let f = from { out.append(f...end) }
        return out
    }

    /// Selected neurons that spiked at `tick` (test hook / future raster).
    func spikes(at tick: Int) -> [Int]? {
        lock.lock(); defer { lock.unlock() }
        guard ring.has(tick) else { return nil }
        return ring.selection.enumerated().filter { ring.spiked(slot: $0.offset, at: tick) }.map(\.element)
    }
}
