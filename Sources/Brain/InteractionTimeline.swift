// InteractionTimeline.swift — V7.6 integrated timeline store.
//
// Links event → sensory sample → spike → motor → observed body data on ONE
// clock: the simulation tick (1 ms, 1-based, `MetalSim.simMs`; restarts at a
// brain reset). This type stores DISCRETE samples, one lane per source, each at
// the tick it really has and with the source's real period:
//   eye      FlyGym eye frames (`eye_sample_sim_tick`, ~5 Hz) with loom L/R
//   sensory  FlyGym wind/touch as reported by the body packet, plus the
//            local (no backend) modeled drives at the tick they were applied
//   motor    `BrainSignals` at the tick they were computed (once per neural quantum)
//   body     FlyGym body state, or the local procedural fly when no backend
// Spikes are NOT copied here: the exact ones stay in the observer ring.
//
// Contract:
// - Every sample carries `tick` and `tick_origin`. `sampled_at`: the tick the
//   sample was truly taken (a FlyGym `eye_sample_sim_tick` of a deterministic
//   session, the end tick of a lockstep quantum, the tick a brain signal or a
//   local drive was computed). `received_at`: the brain tick when the packet
//   was consumed; its real sample time is UNKNOWN (interactive sessions run the
//   body on its own clock). `received_at` is never relabeled `sampled_at`, and
//   no latency or sensory_sample_tick is ever derived from one.
// - A sample with no usable tick (nil, < 1) is counted as `untimed`, not placed.
// - No interpolation anywhere. A query returns the raw samples of a tick range
//   plus the lane's measured period (median Δtick of the samples present);
//   callers draw marks/steps, never lines implying 1 kHz data.
// - Bounded rings (cost: one lock + one struct write per sample, no per-tick
//   allocation after warm-up). Capacities cover a pre + post window of 1,500
//   ticks (+ one 64-tick batch) of the fastest lane with margin: motor and
//   body are written at most once per tick (2,048), the sensory lane at most
//   four channels per tick (8,192), the eye lane is ~5 Hz (512 = ~100 s).
//   Overwriting the oldest sample is counted (`evicted`, `evictedThrough`),
//   never silent. `reset()` (brain reset) clears every lane: a new epoch.
// - Window summaries (V7.6 `motor_output` / `observed_body_action`) are read
//   when a window finalizes, right after the response batch. A motor/body
//   sample recorded after that (the batch's own end-of-step sample) is not
//   back-filled into the finished record.

import Foundation

enum TickOrigin: String, Codable { case sampledAt = "sampled_at", receivedAt = "received_at" }

enum TimelineLane: Int, CaseIterable {
    case eye, sensory, motor, body
    var key: String { ["eye", "sensory", "motor", "body"][rawValue] }
}

/// What a sensory-lane sample describes. `wind`/`touch` come from a body packet
/// (a measured backend report); the `local*` ones are modeled drives the app
/// applied itself (no backend) — a drive is the stimulus, not a sensor sample.
enum SensoryChannel: String, CaseIterable {
    case wind, touch, localLoom = "local_loom", localWind = "local_wind", localTouch = "local_touch"
    var isLocalDrive: Bool { self == .localLoom || self == .localWind || self == .localTouch }
}

/// Where a body sample's position comes from; decides the unit.
enum BodySource: String { case flygym, local
    var unit: String { self == .flygym ? "mm" : "pt" }
}

protocol TimelineSample { var tick: Int { get } }

struct EyeSample: TimelineSample, Equatable {
    var tick: Int
    var origin: TickOrigin
    var loomL: Float
    var loomR: Float
}

/// `a`/`b`: wind = strength, direction°; touch = strength; local_loom = L, R;
/// local_wind = strength, direction°; local_touch = drive. `sensoryOn` is the
/// packet's wind_sensory/touch_sensory flag (nil for local drives).
struct SensorySample: TimelineSample, Equatable {
    var tick: Int
    var origin: TickOrigin
    var channel: SensoryChannel
    var a: Double
    var b: Double = 0
    var sensoryOn: Bool?
}

struct MotorSample: TimelineSample, Equatable {
    var tick: Int
    var origin: TickOrigin
    var walkDrive: Double, turnBias: Double, groomDrive: Double, wingDrive: Double
    var nervous: Double, arousal: Double
    var backward: Bool, escape: Bool
}

struct BodySample: TimelineSample, Equatable {
    var tick: Int
    var origin: TickOrigin
    var source: BodySource
    var x: Double, y: Double          // mm (flygym) or pt (local)
    var heading: Double               // rad
    var vx: Double?                   // m/s, flygym only
    var yawRate: Double?              // rad/s, flygym only
    var contactMean: Double?          // 0…1, flygym only
    var state: Int8 = -1              // local FlyModel state code, -1 = none
}

/// Raw samples of one tick range, ordered by tick, plus what the lane measured.
struct LaneSlice<S: TimelineSample> {
    var samples: [S]
    /// Median Δtick of the samples present; nil below two samples.
    var periodTicks: Double?
    /// Highest tick the ring has overwritten this epoch (0 = nothing evicted).
    var evictedThrough: Int
}

struct TimelineStats: Equatable {
    var recorded = [Int](repeating: 0, count: TimelineLane.allCases.count)
    var evicted = [Int](repeating: 0, count: TimelineLane.allCases.count)
    var untimed = 0
    var outOfOrder = 0
    var epoch = 0
}

private struct SampleRing<S: TimelineSample> {
    let capacity: Int
    private var items: [S] = []
    private var head = 0
    private(set) var evictedThrough = 0
    private(set) var lastTick = 0

    init(capacity: Int) { self.capacity = capacity; items.reserveCapacity(capacity) }

    /// True when the oldest sample was overwritten.
    mutating func append(_ s: S) -> Bool {
        lastTick = max(lastTick, s.tick)
        if items.count < capacity { items.append(s); return false }
        evictedThrough = max(evictedThrough, items[head].tick)
        items[head] = s
        head = (head + 1) % capacity
        return true
    }

    mutating func clear() {
        items.removeAll(keepingCapacity: true); head = 0; evictedThrough = 0; lastTick = 0
    }

    /// Overwrites the newest retained sample at `tick` that `matches` (a later
    /// frame on the same tick wins). False when none is retained.
    mutating func replaceNewest(tick: Int, where matches: (S) -> Bool, with s: S) -> Bool {
        guard !items.isEmpty else { return false }
        var i = items.count < capacity ? items.count - 1 : (head + capacity - 1) % capacity
        for _ in 0..<items.count {
            if items[i].tick < tick { return false }
            if items[i].tick == tick && matches(items[i]) { items[i] = s; return true }
            i = (i + items.count - 1) % items.count
        }
        return false
    }

    func slice(_ range: ClosedRange<Int>, where keep: (S) -> Bool = { _ in true }) -> LaneSlice<S> {
        var out: [S] = []
        for s in items where range.contains(s.tick) && keep(s) { out.append(s) }
        out.sort { $0.tick < $1.tick }
        return LaneSlice(samples: out, periodTicks: InteractionTimeline.period(of: out.map(\.tick)),
                         evictedThrough: evictedThrough)
    }
}

final class InteractionTimeline {
    static let eyeCapacity = 512
    static let sensoryCapacity = 8192
    static let motorCapacity = 2048
    static let bodyCapacity = 2048

    private let lock = NSLock()
    private var eye: SampleRing<EyeSample>
    private var sensory: SampleRing<SensorySample>
    private var motor: SampleRing<MotorSample>
    private var body: SampleRing<BodySample>
    private var counters = TimelineStats()
    private var lastBodyStamp: Double?
    private var lastEyeStamp: Double?
    private var lastChannelTick: [SensoryChannel: Int] = [:]
    /// The last drive/packet value per channel was non-zero (so a falling edge is recorded).
    private var channelActive: Set<SensoryChannel> = []

    init(eyeCapacity: Int = InteractionTimeline.eyeCapacity, sensoryCapacity: Int = InteractionTimeline.sensoryCapacity,
         motorCapacity: Int = InteractionTimeline.motorCapacity, bodyCapacity: Int = InteractionTimeline.bodyCapacity) {
        eye = SampleRing(capacity: max(1, eyeCapacity))
        sensory = SampleRing(capacity: max(1, sensoryCapacity))
        motor = SampleRing(capacity: max(1, motorCapacity))
        body = SampleRing(capacity: max(1, bodyCapacity))
    }

    // MARK: Epoch

    /// Brain reset: every lane restarts (ticks restart at 1). Cumulative
    /// counters and the re-delivery stamps survive, so a stale packet is not
    /// re-recorded as a new sample.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        eye.clear(); sensory.clear(); motor.clear(); body.clear()
        lastChannelTick.removeAll(keepingCapacity: true)
        channelActive.removeAll(keepingCapacity: true)
        counters.epoch += 1
    }

    func stats() -> TimelineStats { lock.lock(); defer { lock.unlock() }; return counters }

    // MARK: Producers (any thread; the simulation thread in the app)

    private func usable(_ tick: Int?) -> Int? {
        if let t = tick, t >= 1 { return t }
        counters.untimed += 1
        return nil
    }

    private func note(_ lane: TimelineLane, evicted: Bool) {
        counters.recorded[lane.rawValue] += 1
        if evicted { counters.evicted[lane.rawValue] += 1 }
    }

    /// One eye frame. `stamp` identifies the frame for re-delivery of the same
    /// packet (`received_at` frames); false when nothing was placed.
    @discardableResult
    func recordEye(tick: Int?, origin: TickOrigin, loomL: Float, loomR: Float, stamp: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = usable(tick) else { return false }
        if let stamp { guard stamp != lastEyeStamp else { return false }; lastEyeStamp = stamp }
        guard t > eye.lastTick else {
            if t < eye.lastTick { counters.outOfOrder += 1 }
            return false
        }
        note(.eye, evicted: eye.append(EyeSample(tick: t, origin: origin, loomL: loomL, loomR: loomR)))
        return true
    }

    @discardableResult
    func recordSensory(tick: Int?, origin: TickOrigin, channel: SensoryChannel, a: Double, b: Double = 0,
                       sensoryOn: Bool? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = usable(tick) else { return false }
        if let last = lastChannelTick[channel], t <= last {
            if t < last { counters.outOfOrder += 1; return false }
            // Two frames on one tick: the later one replaces the channel's sample (a falling edge is not lost).
            return sensory.replaceNewest(tick: t, where: { $0.channel == channel },
                                         with: SensorySample(tick: t, origin: origin, channel: channel, a: a, b: b, sensoryOn: sensoryOn))
        }
        lastChannelTick[channel] = t
        note(.sensory, evicted: sensory.append(SensorySample(tick: t, origin: origin, channel: channel, a: a, b: b, sensoryOn: sensoryOn)))
        return true
    }

    /// `BrainSignals` computed at `tick` (ticks completed after the step). Once per tick at most.
    @discardableResult
    func recordMotor(tick: Int?, _ s: BrainSignals) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = usable(tick) else { return false }
        guard t > motor.lastTick else {
            if t < motor.lastTick { counters.outOfOrder += 1 }
            return false
        }
        note(.motor, evicted: motor.append(MotorSample(
            tick: t, origin: .sampledAt, walkDrive: Double(s.walkDrive), turnBias: Double(s.turnBias),
            groomDrive: Double(s.groomDrive), wingDrive: Double(s.wingDrive), nervous: Double(s.nervous),
            arousal: Double(s.arousal), backward: s.backward, escape: s.escape)))
        return true
    }

    @discardableResult
    func recordBody(_ sample: BodySample, stamp: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = usable(sample.tick) else { return false }
        if let stamp { guard stamp != lastBodyStamp else { return false }; lastBodyStamp = stamp }
        guard t >= body.lastTick else { counters.outOfOrder += 1; return false }
        note(.body, evicted: body.append(sample))
        return true
    }

    /// The local procedural fly after its update at `tick` (no backend).
    @discardableResult
    func recordLocalBody(tick: Int, x: Double, y: Double, heading: Double, state: Int8) -> Bool {
        recordBody(BodySample(tick: tick, origin: .sampledAt, source: .local, x: x, y: y, heading: heading,
                              vx: nil, yawRate: nil, contactMean: nil, state: state), stamp: Double(tick))
    }

    /// One FlyGym body packet consumed by the brain. `tickNow` = ticks completed
    /// when it was consumed. `lockstepEndTick` is non-nil only in a deterministic
    /// session, where body clock == brain tick, the packet is the body state at
    /// the END of the quantum and `eye_sample_sim_tick` is a true brain tick;
    /// everywhere else the packet is `received_at` (its body clock is not ours).
    func ingestBody(_ fb: FlyGymBodyFeedback, tickNow: Int, lockstepEndTick: Int?) {
        let stamp = fb.receivedAt.timeIntervalSinceReferenceDate
        let origin: TickOrigin = lockstepEndTick == nil ? .receivedAt : .sampledAt
        let tick = lockstepEndTick ?? tickNow
        guard recordBody(BodySample(
            tick: tick, origin: origin, source: .flygym, x: fb.positionXmm, y: fb.positionYmm, heading: fb.headingRad,
            vx: fb.vx, yawRate: fb.yawRate, contactMean: fb.contactMean), stamp: stamp) else { return }
        if let est = fb.eyeSampleSimTick {
            if let end = lockstepEndTick {
                // A true brain tick is 1…end of this quantum, and newer than the last eye frame
                // (`recordEye` ignores a repeat and counts an older one); anything else is untimed.
                if est >= 1 && est <= end {
                    recordEye(tick: est, origin: .sampledAt, loomL: Float(fb.loomLeft), loomR: Float(fb.loomRight))
                } else {
                    lock.lock(); counters.untimed += 1; lock.unlock()
                }
            } else {
                recordEye(tick: tickNow, origin: .receivedAt, loomL: Float(fb.loomLeft), loomR: Float(fb.loomRight),
                          stamp: Double(est))
            }
        }
        recordActive(.wind, tick: tick, origin: origin, a: fb.windStrength, b: fb.windDirectionDeg, on: fb.windSensory)
        recordActive(.touch, tick: tick, origin: origin, a: fb.touchStrength, b: 0, on: fb.touchSensory)
    }

    /// Modeled drives applied locally from tick `tick` (the first tick they
    /// can affect); only while non-zero, plus the sample that returns to zero.
    func recordLocalDrives(tick: Int, loomL: Double, loomR: Double, windStrength: Double, windDirectionDeg: Double,
                           touch: Double) {
        recordActive(.localLoom, tick: tick, origin: .sampledAt, a: loomL, b: loomR, on: nil)
        recordActive(.localWind, tick: tick, origin: .sampledAt, a: windStrength, b: windDirectionDeg, on: nil)
        recordActive(.localTouch, tick: tick, origin: .sampledAt, a: touch, b: 0, on: nil)
    }

    private func recordActive(_ channel: SensoryChannel, tick: Int, origin: TickOrigin, a: Double, b: Double, on: Bool?) {
        let active = a > 0 || (channel == .localLoom && b > 0)
        lock.lock()
        let was = channelActive.contains(channel)
        if active { channelActive.insert(channel) } else { channelActive.remove(channel) }
        lock.unlock()
        if active || was { recordSensory(tick: tick, origin: origin, channel: channel, a: a, b: b, sensoryOn: on) }
    }

    // MARK: Queries (any thread; raw samples, never interpolated)

    func eyeSlice(_ r: ClosedRange<Int>) -> LaneSlice<EyeSample> { lock.lock(); defer { lock.unlock() }; return eye.slice(r) }
    func sensorySlice(_ r: ClosedRange<Int>, channel: SensoryChannel? = nil) -> LaneSlice<SensorySample> {
        lock.lock(); defer { lock.unlock() }
        return sensory.slice(r) { channel == nil || $0.channel == channel }
    }
    func motorSlice(_ r: ClosedRange<Int>) -> LaneSlice<MotorSample> { lock.lock(); defer { lock.unlock() }; return motor.slice(r) }
    func bodySlice(_ r: ClosedRange<Int>) -> LaneSlice<BodySample> { lock.lock(); defer { lock.unlock() }; return body.slice(r) }

    /// Median Δtick per channel (ticks of ONE channel only: channels that share a tick
    /// would otherwise contribute Δ=0). Channels without a sample are absent; nil = one sample.
    static func periodsByChannel(_ samples: [SensorySample]) -> [(channel: SensoryChannel, period: Double?, count: Int)] {
        SensoryChannel.allCases.compactMap { c in
            let ticks = samples.filter { $0.channel == c }.map(\.tick).sorted()
            return ticks.isEmpty ? nil : (c, period(of: ticks), ticks.count)
        }
    }

    /// Median Δtick of ascending ticks; nil below two.
    static func period(of ticks: [Int]) -> Double? {
        guard ticks.count >= 2 else { return nil }
        var d: [Int] = []
        d.reserveCapacity(ticks.count - 1)
        for i in 1..<ticks.count { d.append(ticks[i] - ticks[i - 1]) }
        d.sort()
        let m = d.count / 2
        return d.count % 2 == 1 ? Double(d[m]) : Double(d[m - 1] + d[m]) / 2
    }
}

// MARK: - Event ↔ sensory lane

/// The sensory sample an event's channel is measured by.
enum SensoryLaneRef: Equatable {
    case eye
    case channel(SensoryChannel)

    /// nil: this kind of event has no measured sensory channel (a direct neural
    /// stimulus, a physical edit, a local modeled drive).
    static func forEventKind(_ kind: String) -> SensoryLaneRef? {
        switch kind {
        case "flash_eye", "set_eye_state", "eye_state", "restore_eyes", "loom", "visual": return .eye
        case "wind", "wind_puff": return .channel(.wind)
        case "touch": return .channel(.touch)
        default: return nil
        }
    }
}

extension InteractionTimeline {
    /// First `sampled_at` sample of the lane in `range` (V7-03). `receivedOnly`:
    /// the lane has samples there but every one is `received_at` — no sample tick exists.
    func firstSampledTick(_ ref: SensoryLaneRef, in range: ClosedRange<Int>) -> (tick: Int?, receivedOnly: Bool) {
        let samples: [(Int, TickOrigin)]
        switch ref {
        case .eye: samples = eyeSlice(range).samples.map { ($0.tick, $0.origin) }
        case .channel(let c): samples = sensorySlice(range, channel: c).samples.map { ($0.tick, $0.origin) }
        }
        if let s = samples.first(where: { $0.1 == .sampledAt }) { return (s.0, false) }
        return (nil, !samples.isEmpty)
    }

    /// The backend's own wind/touch sensory flag over `range`: true when any
    /// sample had the sensory pathway on, false when samples exist and none had
    /// it, nil without samples.
    func packetSensoryFlag(_ channel: SensoryChannel, in range: ClosedRange<Int>) -> Bool? {
        let s = sensorySlice(range, channel: channel).samples.compactMap(\.sensoryOn)
        return s.isEmpty ? nil : s.contains(true)
    }
}

// MARK: - Window summaries (the v2 `motor_output` / `observed_body_action` fields)

enum LaneSummaryStatus: String, Codable { case collected, partial, unavailable }

/// What a summary of one lane over one window says about its own coverage.
struct LaneCoverage {
    var status: LaneSummaryStatus
    var reason: String?
    var periodTicks: Double?

    /// `ticks` ascending. A gap longer than max(4 × period, 64) ticks (also at
    /// either end of the window; 64 covers the one batch whose own sample is
    /// recorded after its window finalized), an eviction inside the window, a window that
    /// starts before tick 1 (`window_truncated_at_tick_1`) or a single sample
    /// (coverage cannot be verified) makes it `partial`; no sample at all is
    /// `unavailable` — never a zero.
    static func of(ticks: [Int], window: TickWindow, evictedThrough: Int) -> LaneCoverage {
        let from = max(window.start, 1)
        if ticks.isEmpty {
            let why = window.end < 1 ? "window_before_tick_1" : (evictedThrough >= from ? "ring_evicted" : "no_samples_in_window")
            return LaneCoverage(status: .unavailable, reason: why, periodTicks: nil)
        }
        let period = InteractionTimeline.period(of: ticks)
        var partial: String?
        if evictedThrough >= from { partial = "ring_evicted" }
        else if let period {
            let tolerance = max(4 * period, 64)
            var worst = Double(ticks[0] - from)
            for i in 1..<ticks.count { worst = max(worst, Double(ticks[i] - ticks[i - 1])) }
            worst = max(worst, Double(window.end - ticks[ticks.count - 1]))
            if worst > tolerance { partial = "gap_\(Int(worst))_ticks" }
            else if window.start < 1 { partial = "window_truncated_at_tick_1" }
        } else {
            partial = "single_sample"
        }
        return LaneCoverage(status: partial == nil ? .collected : .partial, reason: partial, periodTicks: period)
    }
}

struct MotorMeans: Codable, Equatable {
    var walkDrive: Double, turnBias: Double, groomDrive: Double, wingDrive: Double, nervous: Double, arousal: Double
    enum CodingKeys: String, CodingKey {
        case walkDrive = "walk_drive", turnBias = "turn_bias", groomDrive = "groom_drive"
        case wingDrive = "wing_drive", nervous, arousal
    }
    var allFinite: Bool { [walkDrive, turnBias, groomDrive, wingDrive, nervous, arousal].allSatisfy(\.isFinite) }
}

/// Shared shape of both per-window summaries; the strict decoders enforce it.
private func validateSummary(status: LaneSummaryStatus, reason: String?, count: Int, first: Int?, last: Int?,
                             period: Double?, window: TickWindow?) -> String? {
    guard count >= 0 else { return "count negative" }
    switch status {
    case .unavailable:
        guard count == 0, first == nil, last == nil, period == nil, let r = reason, !r.isEmpty else {
            return "an unavailable summary has no samples, no range, no period and a reason"
        }
        return nil
    case .collected, .partial:
        guard count >= 1, let f = first, let l = last, f <= l else { return "samples need a tick range" }
        guard count <= l - f + 1 else { return "more samples than ticks in the range" }
        if let window { guard f >= window.start, l <= window.end else { return "range outside the window" } }
        if count == 1 {
            guard period == nil, f == l else { return "a single sample has no period" }
        } else {
            guard let p = period, p.isFinite, p >= 1, p <= Double(l - f),
                  p * Double(count - 1) / 2 <= Double(l - f) + 1e-9 else { return "period disagrees with count and range" }
        }
        if status == .collected { guard reason == nil else { return "a collected summary has no reason" } }
        else { guard let r = reason, !r.isEmpty else { return "a partial summary names why" } }
        return nil
    }
}

/// One window of the motor lane. Means and the escape count exist only with samples.
struct MotorWindowSummary: Codable, Equatable {
    var status: LaneSummaryStatus
    var reason: String?
    var sampleCount: Int
    var firstTick: Int?
    var lastTick: Int?
    var periodTicks: Double?
    var mean: MotorMeans?
    var escapeCount: Int?
    var backwardCount: Int?

    enum CodingKeys: String, CodingKey {
        case status, reason, mean
        case sampleCount = "sample_count", firstTick = "first_tick", lastTick = "last_tick"
        case periodTicks = "period_ticks", escapeCount = "escape_count", backwardCount = "backward_count"
    }

    static func unavailable(_ reason: String) -> MotorWindowSummary {
        MotorWindowSummary(status: .unavailable, reason: reason, sampleCount: 0)
    }

    init(status: LaneSummaryStatus, reason: String?, sampleCount: Int, firstTick: Int? = nil, lastTick: Int? = nil,
         periodTicks: Double? = nil, mean: MotorMeans? = nil, escapeCount: Int? = nil, backwardCount: Int? = nil) {
        self.status = status; self.reason = reason; self.sampleCount = sampleCount
        self.firstTick = firstTick; self.lastTick = lastTick; self.periodTicks = periodTicks
        self.mean = mean; self.escapeCount = escapeCount; self.backwardCount = backwardCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for k in [CodingKeys.reason, .firstTick, .lastTick, .periodTicks, .mean, .escapeCount, .backwardCount] where !c.contains(k) {
            throw DecodingError.keyNotFound(k, .init(codingPath: c.codingPath, debugDescription: "\(k.rawValue) (nullable) must be present"))
        }
        status = try c.decode(LaneSummaryStatus.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        firstTick = try c.decodeIfPresent(Int.self, forKey: .firstTick)
        lastTick = try c.decodeIfPresent(Int.self, forKey: .lastTick)
        periodTicks = try c.decodeIfPresent(Double.self, forKey: .periodTicks)
        mean = try c.decodeIfPresent(MotorMeans.self, forKey: .mean)
        escapeCount = try c.decodeIfPresent(Int.self, forKey: .escapeCount)
        backwardCount = try c.decodeIfPresent(Int.self, forKey: .backwardCount)
        if let why = validate(window: nil) { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: why)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(reason, forKey: .reason)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(firstTick, forKey: .firstTick); try c.encode(lastTick, forKey: .lastTick)
        try c.encode(periodTicks, forKey: .periodTicks); try c.encode(mean, forKey: .mean)
        try c.encode(escapeCount, forKey: .escapeCount); try c.encode(backwardCount, forKey: .backwardCount)
    }

    /// nil when consistent. `window` adds the range check.
    func validate(window: TickWindow?) -> String? {
        if let why = validateSummary(status: status, reason: reason, count: sampleCount, first: firstTick, last: lastTick,
                                     period: periodTicks, window: window) { return why }
        if status == .unavailable {
            return mean == nil && escapeCount == nil && backwardCount == nil ? nil : "an unavailable summary carries no values (never zeros)"
        }
        guard let m = mean, m.allFinite, let e = escapeCount, let b = backwardCount,
              (0...sampleCount).contains(e), (0...sampleCount).contains(b) else { return "motor values missing or out of range" }
        return nil
    }
}

/// One window of the body lane.
struct BodyWindowSummary: Codable, Equatable {
    var status: LaneSummaryStatus
    var reason: String?
    var sampleCount: Int
    var firstTick: Int?
    var lastTick: Int?
    var periodTicks: Double?
    var sampledAtCount: Int?
    var receivedAtCount: Int?
    /// "mm" (FlyGym), "pt" (local procedural fly) or "mixed" (no displacement/speed then).
    var positionUnit: String?
    /// First → last sample position, in `positionUnit`.
    var netDisplacement: Double?
    /// Path length ÷ time over consecutive `sampled_at` samples (unit/s); nil without such a pair.
    var meanSpeed: Double?
    /// Mean of the backend's yaw rate (rad/s); nil for the local fly, which reports none.
    var meanYawRate: Double?
    /// Local FlyModel state changes; nil when no sample carries a state.
    var stateTransitions: Int?

    enum CodingKeys: String, CodingKey {
        case status, reason
        case sampleCount = "sample_count", firstTick = "first_tick", lastTick = "last_tick", periodTicks = "period_ticks"
        case sampledAtCount = "sampled_at_count", receivedAtCount = "received_at_count"
        case positionUnit = "position_unit", netDisplacement = "net_displacement", meanSpeed = "mean_speed"
        case meanYawRate = "mean_yaw_rate", stateTransitions = "state_transitions"
    }

    static func unavailable(_ reason: String) -> BodyWindowSummary {
        BodyWindowSummary(status: .unavailable, reason: reason, sampleCount: 0)
    }

    init(status: LaneSummaryStatus, reason: String?, sampleCount: Int, firstTick: Int? = nil, lastTick: Int? = nil,
         periodTicks: Double? = nil, sampledAtCount: Int? = nil, receivedAtCount: Int? = nil, positionUnit: String? = nil,
         netDisplacement: Double? = nil, meanSpeed: Double? = nil, meanYawRate: Double? = nil, stateTransitions: Int? = nil) {
        self.status = status; self.reason = reason; self.sampleCount = sampleCount
        self.firstTick = firstTick; self.lastTick = lastTick; self.periodTicks = periodTicks
        self.sampledAtCount = sampledAtCount; self.receivedAtCount = receivedAtCount; self.positionUnit = positionUnit
        self.netDisplacement = netDisplacement; self.meanSpeed = meanSpeed; self.meanYawRate = meanYawRate
        self.stateTransitions = stateTransitions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for k in [CodingKeys.reason, .firstTick, .lastTick, .periodTicks, .sampledAtCount, .receivedAtCount, .positionUnit,
                  .netDisplacement, .meanSpeed, .meanYawRate, .stateTransitions] where !c.contains(k) {
            throw DecodingError.keyNotFound(k, .init(codingPath: c.codingPath, debugDescription: "\(k.rawValue) (nullable) must be present"))
        }
        status = try c.decode(LaneSummaryStatus.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        firstTick = try c.decodeIfPresent(Int.self, forKey: .firstTick)
        lastTick = try c.decodeIfPresent(Int.self, forKey: .lastTick)
        periodTicks = try c.decodeIfPresent(Double.self, forKey: .periodTicks)
        sampledAtCount = try c.decodeIfPresent(Int.self, forKey: .sampledAtCount)
        receivedAtCount = try c.decodeIfPresent(Int.self, forKey: .receivedAtCount)
        positionUnit = try c.decodeIfPresent(String.self, forKey: .positionUnit)
        netDisplacement = try c.decodeIfPresent(Double.self, forKey: .netDisplacement)
        meanSpeed = try c.decodeIfPresent(Double.self, forKey: .meanSpeed)
        meanYawRate = try c.decodeIfPresent(Double.self, forKey: .meanYawRate)
        stateTransitions = try c.decodeIfPresent(Int.self, forKey: .stateTransitions)
        if let why = validate(window: nil) { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: why)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status); try c.encode(reason, forKey: .reason)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(firstTick, forKey: .firstTick); try c.encode(lastTick, forKey: .lastTick)
        try c.encode(periodTicks, forKey: .periodTicks)
        try c.encode(sampledAtCount, forKey: .sampledAtCount); try c.encode(receivedAtCount, forKey: .receivedAtCount)
        try c.encode(positionUnit, forKey: .positionUnit); try c.encode(netDisplacement, forKey: .netDisplacement)
        try c.encode(meanSpeed, forKey: .meanSpeed); try c.encode(meanYawRate, forKey: .meanYawRate)
        try c.encode(stateTransitions, forKey: .stateTransitions)
    }

    func validate(window: TickWindow?) -> String? {
        if let why = validateSummary(status: status, reason: reason, count: sampleCount, first: firstTick, last: lastTick,
                                     period: periodTicks, window: window) { return why }
        if status == .unavailable {
            return sampledAtCount == nil && receivedAtCount == nil && positionUnit == nil && netDisplacement == nil
                && meanSpeed == nil && meanYawRate == nil && stateTransitions == nil
                ? nil : "an unavailable summary carries no values (never zeros)"
        }
        guard let s = sampledAtCount, let r = receivedAtCount, s >= 0, r >= 0, s + r == sampleCount,
              let unit = positionUnit, ["mm", "pt", "mixed"].contains(unit) else { return "tick origin mix or unit inconsistent" }
        if unit == "mixed" { guard netDisplacement == nil, meanSpeed == nil else { return "no displacement across units" } }
        else { guard let d = netDisplacement, d.isFinite, d >= 0 else { return "net displacement missing" } }
        if let v = meanSpeed { guard v.isFinite, v >= 0, s >= 2 else { return "mean speed needs two sampled_at samples" } }
        if let y = meanYawRate { guard y.isFinite else { return "yaw rate not finite" } }
        if let t = stateTransitions { guard (0..<sampleCount).contains(t) else { return "state transitions out of range" } }
        return nil
    }
}

struct MotorOutput: Codable, Equatable {
    var baseline: MotorWindowSummary
    var response: MotorWindowSummary
    static func unavailable(_ reason: String) -> MotorOutput { MotorOutput(baseline: .unavailable(reason), response: .unavailable(reason)) }
}

struct ObservedBodyAction: Codable, Equatable {
    var baseline: BodyWindowSummary
    var response: BodyWindowSummary
    static func unavailable(_ reason: String) -> ObservedBodyAction { ObservedBodyAction(baseline: .unavailable(reason), response: .unavailable(reason)) }
}

extension InteractionTimeline {
    func motorSummary(_ w: TickWindow) -> MotorWindowSummary {
        let slice = motorSlice(max(w.start, 1)...max(w.end, 1))
        let s = w.end < 1 ? [] : slice.samples
        let cov = LaneCoverage.of(ticks: s.map(\.tick), window: w, evictedThrough: slice.evictedThrough)
        guard cov.status != .unavailable, let first = s.first, let last = s.last else {
            return .unavailable(cov.reason ?? "no_samples_in_window")
        }
        let n = Double(s.count)
        func mean(_ f: (MotorSample) -> Double) -> Double { s.reduce(0) { $0 + f($1) } / n }
        return MotorWindowSummary(
            status: cov.status, reason: cov.reason, sampleCount: s.count, firstTick: first.tick, lastTick: last.tick,
            periodTicks: cov.periodTicks,
            mean: MotorMeans(walkDrive: mean(\.walkDrive), turnBias: mean(\.turnBias), groomDrive: mean(\.groomDrive),
                             wingDrive: mean(\.wingDrive), nervous: mean(\.nervous), arousal: mean(\.arousal)),
            escapeCount: s.filter(\.escape).count, backwardCount: s.filter(\.backward).count)
    }

    func bodySummary(_ w: TickWindow) -> BodyWindowSummary {
        let slice = bodySlice(max(w.start, 1)...max(w.end, 1))
        let s = w.end < 1 ? [] : slice.samples
        let cov = LaneCoverage.of(ticks: s.map(\.tick), window: w, evictedThrough: slice.evictedThrough)
        guard cov.status != .unavailable, let first = s.first, let last = s.last else {
            return .unavailable(cov.reason ?? "no_samples_in_window")
        }
        let sources = Set(s.map(\.source))
        let unit = sources.count == 1 ? s[0].source.unit : "mixed"
        var displacement: Double?, speed: Double?
        if sources.count == 1 {
            displacement = hypot(last.x - first.x, last.y - first.y)
            var path = 0.0, ticks = 0
            for i in 1..<max(1, s.count) where s[i].origin == .sampledAt && s[i - 1].origin == .sampledAt && s[i].tick > s[i - 1].tick {
                path += hypot(s[i].x - s[i - 1].x, s[i].y - s[i - 1].y)
                ticks += s[i].tick - s[i - 1].tick
            }
            if ticks > 0 { speed = path / (Double(ticks) / 1000) }
        }
        let yaws = s.compactMap(\.yawRate)
        let states = s.map(\.state).filter { $0 >= 0 }
        var transitions: Int?
        if !states.isEmpty { transitions = zip(states, states.dropFirst()).filter { $0 != $1 }.count }
        let sampled = s.filter { $0.origin == .sampledAt }.count
        return BodyWindowSummary(
            status: cov.status, reason: cov.reason, sampleCount: s.count, firstTick: first.tick, lastTick: last.tick,
            periodTicks: cov.periodTicks, sampledAtCount: sampled, receivedAtCount: s.count - sampled, positionUnit: unit,
            netDisplacement: displacement, meanSpeed: speed,
            meanYawRate: yaws.isEmpty ? nil : yaws.reduce(0, +) / Double(yaws.count), stateTransitions: transitions)
    }
}

// MARK: - CSV export (timeline.csv)

enum TimelineCSV {
    static let header = "lane,tick,tick_origin,channel,loom_l,loom_r,strength,direction_deg,sensory_on,walk_drive,turn_bias,groom_drive,wing_drive,backward,escape,nervous,arousal,vx,yaw_rate,x,y,heading,contact_mean,state\n"
    static let stateNames = ["walking", "idle", "grooming", "flying", "sleeping"]

    /// The raw samples of every lane in `range`, one row each (empty cell = not
    /// applicable). `spikes`: selected-neuron spikes from the exact observer ring
    /// as (tick, root id); they are exact per-tick facts, written as lane `spike`.
    static func make(_ timeline: InteractionTimeline, range: ClosedRange<Int>, spikes: [(tick: Int, rootID: String)] = []) -> String {
        make(eye: timeline.eyeSlice(range).samples, sensory: timeline.sensorySlice(range).samples,
             motor: timeline.motorSlice(range).samples, body: timeline.bodySlice(range).samples, range: range, spikes: spikes)
    }

    /// The same rows from samples already read (the panel exports exactly what it drew).
    static func make(eye: [EyeSample], sensory: [SensorySample], motor: [MotorSample], body: [BodySample],
                     range: ClosedRange<Int>, spikes: [(tick: Int, rootID: String)]) -> String {
        func g(_ v: Double?) -> String { v.map { String(format: "%.6g", $0) } ?? "" }
        func row(_ lane: String, _ tick: Int, _ origin: TickOrigin, _ cells: [String: String]) -> String {
            let cols = header.dropLast().split(separator: ",").dropFirst(3).map(String.init)
            return ([lane, "\(tick)", origin.rawValue] + cols.map { cells[$0] ?? "" }).joined(separator: ",") + "\n"
        }
        var out = header
        for s in eye {
            out += row("eye", s.tick, s.origin, ["loom_l": g(Double(s.loomL)), "loom_r": g(Double(s.loomR))])
        }
        for s in sensory {
            var c: [String: String] = ["channel": s.channel.rawValue, "sensory_on": s.sensoryOn.map { $0 ? "1" : "0" } ?? ""]
            if s.channel == .localLoom { c["loom_l"] = g(s.a); c["loom_r"] = g(s.b) }
            else { c["strength"] = g(s.a); if s.channel == .wind || s.channel == .localWind { c["direction_deg"] = g(s.b) } }
            out += row("sensory", s.tick, s.origin, c)
        }
        for s in motor {
            out += row("motor", s.tick, s.origin, [
                "walk_drive": g(s.walkDrive), "turn_bias": g(s.turnBias), "groom_drive": g(s.groomDrive),
                "wing_drive": g(s.wingDrive), "backward": s.backward ? "1" : "0", "escape": s.escape ? "1" : "0",
                "nervous": g(s.nervous), "arousal": g(s.arousal)])
        }
        for s in body {
            out += row("body", s.tick, s.origin, [
                "channel": s.source.rawValue, "vx": g(s.vx), "yaw_rate": g(s.yawRate), "x": g(s.x), "y": g(s.y),
                "heading": g(s.heading), "contact_mean": g(s.contactMean),
                "state": s.state >= 0 && Int(s.state) < stateNames.count ? stateNames[Int(s.state)] : ""])
        }
        for s in spikes where range.contains(s.tick) { out += row("spike", s.tick, .sampledAt, ["channel": s.rootID]) }
        return out
    }
}
