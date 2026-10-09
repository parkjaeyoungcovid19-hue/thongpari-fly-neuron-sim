// InteractionWindow.swift — V7.5 `interaction_window.v1` contract.
//
// One record per discrete interaction event: the exact neural activity of
// each group over a baseline window just before it and a response window from
// it onward, on the SIMULATION tick clock only (1 ms, 1-based, restarting at a
// brain reset). Wall-clock time appears nowhere in this type.
//
// Tick convention (docs/plans/VIRTUAL_FLY_LAB_V7_PLAN.md §4 InteractionAnalysis):
// - `applied_tick` is the FIRST simulation tick whose dynamics can reflect the
//   event. For an intervention applied between steps while `MetalSim.simMs ==
//   T` (ticks completed), that is T + 1; `applied_tick_origin` states how it was
//   obtained. It is null when no reliable neural tick exists — the event is then
//   recorded as invalid(applied_tick_unknown), never anchored on UI wall time.
// - baseline_window = applied − pre … applied − 1 (default 500 ticks),
//   response_window = applied … applied + post − 1 (default 1000 ticks).
//   Both are closed ranges and may start before tick 1 (then the baseline is
//   insufficient — never fabricated).
// - `sensory_sample_tick` is the simulation tick at which a sensory sample (for
//   example an eye frame) was genuinely taken. It is null unless that tick is
//   known; it is never derived from `applied_tick` and no latency is computed.
// - A baseline/response observation is present only when EVERY tick of its
//   window was observed (`NeuralObservation.validity == complete`). A partial
//   one is reported as null plus its missing tick count. `delta_hz_per_neuron`
//   (response − baseline, Hz per neuron) exists only when both are present.
// - Motor output and the observed body action are V7.6 scope: they are marked
//   "not_collected", not given placeholder zeros.

import Foundation

enum InteractionWindowCapability {
    static let schema = "interaction_window.v1"
    static let defaultPreMs = 500
    static let defaultPostMs = 1000
    /// Windows still waiting for their response ticks (overflow displaces the oldest).
    static let maxCollecting = 16
    /// Finished windows kept in memory for the UI (older ones were already recorded).
    static let maxHistory = 64
    /// Largest batch `MetalSim.step` hands the observer; a window completes right
    /// after a batch, so the ring must still hold the baseline start then.
    static let maxBatchTicks = 64
    /// Largest pre + post span the 2,048-tick ring can serve exactly.
    static var maxSpanMs: Int { ObservationCapability.retainedTicks - maxBatchTicks }
}

/// Window lengths in ticks (1 ms each). `nil` from `validated` when the ring
/// could not serve the span exactly.
struct EventWindowConfig: Equatable {
    let preMs: Int
    let postMs: Int
    static let standard = EventWindowConfig(preMs: InteractionWindowCapability.defaultPreMs,
                                            postMs: InteractionWindowCapability.defaultPostMs)
    private init(preMs: Int, postMs: Int) { self.preMs = preMs; self.postMs = postMs }
    static func validated(preMs: Int, postMs: Int) -> EventWindowConfig? {
        guard preMs >= 1, postMs >= 1, preMs + postMs <= InteractionWindowCapability.maxSpanMs else { return nil }
        return EventWindowConfig(preMs: preMs, postMs: postMs)
    }
}

enum InteractionEventSource: String, Codable {
    case physical
    case sensoryModel = "sensory_model"
    case directNeural = "direct_neural"
    case controllerModel = "controller_model"
    case observed
    case stateEstimate = "state_estimate"
    /// One command with both effects (touch; wind with both switches on).
    case physicalAndSensoryModel = "physical+sensory_model"
}

enum InteractionEventIDOrigin: String, Codable {
    /// Built from the Lab command id the backend ACKs (session-qualified).
    case labCommandID = "lab_command_id"
    /// Counter generated here for events that never had a command id.
    case local = "local_counter"
}

enum InteractionWindowStatus: String, Codable { case collecting, complete, invalid }

/// A closed tick range.
struct TickWindow: Codable, Equatable {
    var start: Int
    var end: Int
    var length: Int { end - start + 1 }
}

/// What an incomplete or mismatched window is flagged with.
struct InteractionValidity: Codable, Equatable {
    /// The baseline could not be observed in full (selection began after its
    /// start, it starts before tick 1, or its ticks were evicted).
    var baselineInsufficient = false
    /// Other events (same brain epoch) whose windows intersect this one.
    var overlappingEvents: [String] = []
    /// Missing ticks over both windows (worst group); nil when never measured.
    var droppedSamples: Int?
    var selectionChanged = false
    var brainReset = false
    /// Needed ticks had already left the 2,048-tick ring when it was read.
    var evicted = false
    var noSelection = false
    var appliedTickUnknown = false
    var bufferOverflow = false
    /// Both windows fully observed for every group, no flag that weakens that.
    var sufficient = false

    /// Flags that make a window unusable on their own.
    var hasInvalidatingFlag: Bool {
        selectionChanged || brainReset || noSelection || appliedTickUnknown || bufferOverflow
    }

    enum CodingKeys: String, CodingKey {
        case baselineInsufficient = "baseline_insufficient", overlappingEvents = "overlapping_events"
        case droppedSamples = "dropped_samples", selectionChanged = "selection_changed"
        case brainReset = "brain_reset", evicted, noSelection = "no_selection"
        case appliedTickUnknown = "applied_tick_unknown", bufferOverflow = "buffer_overflow", sufficient
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baselineInsufficient = try c.decode(Bool.self, forKey: .baselineInsufficient)
        overlappingEvents = try c.decode([String].self, forKey: .overlappingEvents)
        guard c.contains(.droppedSamples) else {
            throw DecodingError.keyNotFound(CodingKeys.droppedSamples, .init(codingPath: c.codingPath, debugDescription: "dropped_samples (nullable) must be present"))
        }
        droppedSamples = try c.decodeIfPresent(Int.self, forKey: .droppedSamples)
        selectionChanged = try c.decode(Bool.self, forKey: .selectionChanged)
        brainReset = try c.decode(Bool.self, forKey: .brainReset)
        evicted = try c.decode(Bool.self, forKey: .evicted)
        noSelection = try c.decode(Bool.self, forKey: .noSelection)
        appliedTickUnknown = try c.decode(Bool.self, forKey: .appliedTickUnknown)
        bufferOverflow = try c.decode(Bool.self, forKey: .bufferOverflow)
        sufficient = try c.decode(Bool.self, forKey: .sufficient)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baselineInsufficient, forKey: .baselineInsufficient)
        try c.encode(overlappingEvents, forKey: .overlappingEvents)
        try c.encode(droppedSamples, forKey: .droppedSamples)   // explicit null when never measured
        try c.encode(selectionChanged, forKey: .selectionChanged)
        try c.encode(brainReset, forKey: .brainReset)
        try c.encode(evicted, forKey: .evicted)
        try c.encode(noSelection, forKey: .noSelection)
        try c.encode(appliedTickUnknown, forKey: .appliedTickUnknown)
        try c.encode(bufferOverflow, forKey: .bufferOverflow)
        try c.encode(sufficient, forKey: .sufficient)
    }
}

/// One group's exact activity around the event.
struct GroupWindowResult: Codable, Equatable {
    var groupID: String
    var memberCount: Int
    /// Present only when every baseline tick was observed.
    var baseline: NeuralObservation?
    var baselineMissingTicks: Int
    /// Present only when every response tick was observed.
    var response: NeuralObservation?
    var responseMissingTicks: Int
    /// response − baseline rate, Hz per neuron; nil unless both are present.
    var deltaHzPerNeuron: Double?
    /// Why the delta is null (nil exactly when the delta exists).
    var deltaUnavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id", memberCount = "member_count", baseline
        case baselineMissingTicks = "baseline_missing_ticks", response
        case responseMissingTicks = "response_missing_ticks"
        case deltaHzPerNeuron = "delta_hz_per_neuron", deltaUnavailableReason = "delta_unavailable_reason"
    }

    init(groupID: String, memberCount: Int, baseline: NeuralObservation?, baselineMissingTicks: Int,
         response: NeuralObservation?, responseMissingTicks: Int, deltaUnavailableReason: String? = nil) {
        self.groupID = groupID; self.memberCount = memberCount
        self.baseline = baseline; self.baselineMissingTicks = baselineMissingTicks
        self.response = response; self.responseMissingTicks = responseMissingTicks
        if let b = baseline?.rateHzPerNeuron, let r = response?.rateHzPerNeuron {
            deltaHzPerNeuron = r - b
            self.deltaUnavailableReason = nil
        } else {
            deltaHzPerNeuron = nil
            self.deltaUnavailableReason = deltaUnavailableReason ?? (response == nil ? "response_incomplete" : "baseline_insufficient")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func present(_ k: CodingKeys) throws {
            guard c.contains(k) else {
                throw DecodingError.keyNotFound(k, .init(codingPath: c.codingPath, debugDescription: "\(k.rawValue) (nullable) must be present"))
            }
        }
        groupID = try c.decode(String.self, forKey: .groupID)
        memberCount = try c.decode(Int.self, forKey: .memberCount)
        try present(.baseline); baseline = try c.decodeIfPresent(NeuralObservation.self, forKey: .baseline)
        baselineMissingTicks = try c.decode(Int.self, forKey: .baselineMissingTicks)
        try present(.response); response = try c.decodeIfPresent(NeuralObservation.self, forKey: .response)
        responseMissingTicks = try c.decode(Int.self, forKey: .responseMissingTicks)
        try present(.deltaHzPerNeuron); deltaHzPerNeuron = try c.decodeIfPresent(Double.self, forKey: .deltaHzPerNeuron)
        try present(.deltaUnavailableReason)
        deltaUnavailableReason = try c.decodeIfPresent(String.self, forKey: .deltaUnavailableReason)
        func fail(_ why: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: c.codingPath, debugDescription: why))
        }
        guard memberCount >= 1, baselineMissingTicks >= 0, responseMissingTicks >= 0 else { throw fail("counts out of range") }
        for (obs, missing, name) in [(baseline, baselineMissingTicks, "baseline"), (response, responseMissingTicks, "response")] {
            if let obs {
                guard obs.validity == .complete, missing == 0, obs.memberCount == memberCount else {
                    throw fail("\(name) observation must be complete, with 0 missing ticks and this group's members")
                }
            } else {
                guard missing >= 1 else { throw fail("a null \(name) must report the ticks it is missing") }
            }
        }
        switch (baseline?.rateHzPerNeuron, response?.rateHzPerNeuron, deltaHzPerNeuron) {
        case let (b?, r?, d?):
            guard d.isFinite, abs(d - (r - b)) <= 1e-9 * max(1, abs(d)) else { throw fail("delta disagrees with response − baseline") }
            guard deltaUnavailableReason == nil else { throw fail("delta present but a reason is given") }
        case (_, _, nil):
            guard let reason = deltaUnavailableReason, !reason.isEmpty else { throw fail("a null delta needs a reason") }
        default:
            // delta present with an absent/incomplete baseline or response: a fabricated baseline.
            throw fail("delta requires a complete baseline and response")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(memberCount, forKey: .memberCount)
        try c.encode(baseline, forKey: .baseline)
        try c.encode(baselineMissingTicks, forKey: .baselineMissingTicks)
        try c.encode(response, forKey: .response)
        try c.encode(responseMissingTicks, forKey: .responseMissingTicks)
        try c.encode(deltaHzPerNeuron, forKey: .deltaHzPerNeuron)
        try c.encode(deltaUnavailableReason, forKey: .deltaUnavailableReason)
    }
}

/// A field this step does not collect — explicit, never a zero.
struct NotCollected: Codable, Equatable {
    var status = "not_collected"
    var reason = "V7.6 integrated timeline"
}

struct InteractionWindow: Codable, Equatable {
    var schema = InteractionWindowCapability.schema
    var eventID: String
    var eventIDOrigin: InteractionEventIDOrigin
    var eventKind: String
    var source: InteractionEventSource
    /// First tick that can reflect the event; nil when it is not anchorable.
    var appliedTick: Int?
    /// How `appliedTick` was obtained (or why it is unknown).
    var appliedTickOrigin: String
    var sensorySampleTick: Int?
    var brainEpoch: Int
    /// Selection that was armed when the event was noted; nil when none.
    var selectionID: Int?
    var preMs: Int
    var postMs: Int
    var baselineWindow: TickWindow?
    var responseWindow: TickWindow?
    var status: InteractionWindowStatus
    /// Response ticks simulated so far (0…postMs).
    var responseTicksCollected: Int
    var validity: InteractionValidity
    var groups: [GroupWindowResult]
    var motorOutput = NotCollected()
    var observedBodyAction = NotCollected()

    enum CodingKeys: String, CodingKey {
        case schema, source, status, validity, groups
        case eventID = "event_id", eventIDOrigin = "event_id_origin", eventKind = "event_kind"
        case appliedTick = "applied_tick", appliedTickOrigin = "applied_tick_origin"
        case sensorySampleTick = "sensory_sample_tick", brainEpoch = "brain_epoch", selectionID = "selection_id"
        case preMs = "pre_ms", postMs = "post_ms", baselineWindow = "baseline_window"
        case responseWindow = "response_window", responseTicksCollected = "response_ticks_collected"
        case motorOutput = "motor_output", observedBodyAction = "observed_body_action"
    }

    init(eventID: String, eventIDOrigin: InteractionEventIDOrigin, eventKind: String,
         source: InteractionEventSource, appliedTick: Int?, appliedTickOrigin: String,
         sensorySampleTick: Int? = nil, brainEpoch: Int, selectionID: Int?, config: EventWindowConfig) {
        self.eventID = eventID; self.eventIDOrigin = eventIDOrigin; self.eventKind = eventKind
        self.source = source; self.appliedTick = appliedTick; self.appliedTickOrigin = appliedTickOrigin
        self.sensorySampleTick = sensorySampleTick; self.brainEpoch = brainEpoch; self.selectionID = selectionID
        preMs = config.preMs; postMs = config.postMs
        if let a = appliedTick {
            baselineWindow = TickWindow(start: a - config.preMs, end: a - 1)
            responseWindow = TickWindow(start: a, end: a + config.postMs - 1)
        }
        status = .collecting
        responseTicksCollected = 0
        validity = InteractionValidity()
        groups = []
    }

    /// The sufficiency this window's contents imply. Decode requires the stored
    /// flag to agree; the buffer assigns it with this.
    var impliedSufficient: Bool {
        status == .complete && !validity.baselineInsufficient && validity.droppedSamples == 0
            && !validity.evicted && !validity.hasInvalidatingFlag && !groups.isEmpty
            && groups.allSatisfy { $0.baseline != nil && $0.response != nil }
    }

    /// Strict decode: nullable fields must be present, windows must have the
    /// configured lengths around `applied_tick`, a baseline is never present
    /// when it was flagged insufficient, and the status/flags must agree.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func present(_ k: CodingKeys) throws {
            guard c.contains(k) else {
                throw DecodingError.keyNotFound(k, .init(codingPath: c.codingPath, debugDescription: "\(k.rawValue) (nullable) must be present"))
            }
        }
        func fail(_ why: String) -> DecodingError { .dataCorrupted(.init(codingPath: c.codingPath, debugDescription: why)) }
        schema = try c.decode(String.self, forKey: .schema)
        eventID = try c.decode(String.self, forKey: .eventID)
        eventIDOrigin = try c.decode(InteractionEventIDOrigin.self, forKey: .eventIDOrigin)
        eventKind = try c.decode(String.self, forKey: .eventKind)
        source = try c.decode(InteractionEventSource.self, forKey: .source)
        try present(.appliedTick); appliedTick = try c.decodeIfPresent(Int.self, forKey: .appliedTick)
        appliedTickOrigin = try c.decode(String.self, forKey: .appliedTickOrigin)
        try present(.sensorySampleTick); sensorySampleTick = try c.decodeIfPresent(Int.self, forKey: .sensorySampleTick)
        brainEpoch = try c.decode(Int.self, forKey: .brainEpoch)
        try present(.selectionID); selectionID = try c.decodeIfPresent(Int.self, forKey: .selectionID)
        preMs = try c.decode(Int.self, forKey: .preMs)
        postMs = try c.decode(Int.self, forKey: .postMs)
        try present(.baselineWindow); baselineWindow = try c.decodeIfPresent(TickWindow.self, forKey: .baselineWindow)
        try present(.responseWindow); responseWindow = try c.decodeIfPresent(TickWindow.self, forKey: .responseWindow)
        status = try c.decode(InteractionWindowStatus.self, forKey: .status)
        responseTicksCollected = try c.decode(Int.self, forKey: .responseTicksCollected)
        validity = try c.decode(InteractionValidity.self, forKey: .validity)
        groups = try c.decode([GroupWindowResult].self, forKey: .groups)
        motorOutput = try c.decode(NotCollected.self, forKey: .motorOutput)
        observedBodyAction = try c.decode(NotCollected.self, forKey: .observedBodyAction)

        guard schema == InteractionWindowCapability.schema else { throw fail("schema \(schema)") }
        guard !eventID.isEmpty, brainEpoch >= 0, (sensorySampleTick ?? 1) >= 1 else { throw fail("identity fields out of range") }
        guard EventWindowConfig.validated(preMs: preMs, postMs: postMs) != nil else { throw fail("window lengths \(preMs)/\(postMs) are not servable") }
        guard (0...postMs).contains(responseTicksCollected) else { throw fail("response_ticks_collected out of range") }
        guard motorOutput == NotCollected(), observedBodyAction == NotCollected() else {
            throw fail("motor_output/observed_body_action are V7.6 scope and must be marked not_collected")
        }
        if let a = appliedTick {
            guard a >= 1 else { throw fail("applied_tick must be a 1-based tick") }
            guard baselineWindow == TickWindow(start: a - preMs, end: a - 1),
                  responseWindow == TickWindow(start: a, end: a + postMs - 1) else {
                throw fail("windows must be applied−pre…applied−1 and applied…applied+post−1")
            }
        } else {
            guard baselineWindow == nil, responseWindow == nil, validity.appliedTickUnknown, status == .invalid else {
                throw fail("an unknown applied_tick means null windows and invalid(applied_tick_unknown)")
            }
        }
        guard validity.overlappingEvents.count == Set(validity.overlappingEvents).count,
              !validity.overlappingEvents.contains(eventID) else { throw fail("overlapping_events must be unique and exclude the event itself") }
        if let d = validity.droppedSamples { guard d >= 0 else { throw fail("dropped_samples negative") } }
        for g in groups {
            for (obs, win, name) in [(g.baseline, baselineWindow, "baseline"), (g.response, responseWindow, "response")] {
                guard let obs else { continue }
                guard let win, obs.startTick == win.start, obs.endTick == win.end,
                      obs.brainEpoch == brainEpoch, obs.selectionID == selectionID else {
                    throw fail("\(name) observation does not match the event's window, epoch and selection")
                }
            }
            if validity.baselineInsufficient && g.baseline != nil { throw fail("baseline present although flagged insufficient") }
        }
        switch status {
        case .collecting:
            guard groups.isEmpty, !validity.hasInvalidatingFlag, responseTicksCollected < postMs else {
                throw fail("a collecting window has no results, no invalidating flag and fewer than post_ms ticks")
            }
        case .complete:
            guard !validity.hasInvalidatingFlag, responseTicksCollected == postMs, !groups.isEmpty,
                  groups.contains(where: { $0.response != nil }), validity.droppedSamples != nil else {
                throw fail("a complete window has a response observed, no invalidating flag, a measured drop count")
            }
            if validity.evicted && !validity.baselineInsufficient { throw fail("evicted ticks must show as an insufficient baseline") }
            if !validity.baselineInsufficient && groups.contains(where: { $0.baseline == nil }) {
                throw fail("a missing baseline must set baseline_insufficient")
            }
        case .invalid:
            guard validity.hasInvalidatingFlag || (validity.droppedSamples ?? 0) > 0 else {
                throw fail("an invalid window must say why (a flag or dropped samples)")
            }
        }
        guard validity.sufficient == impliedSufficient else { throw fail("sufficient disagrees with the window's contents") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(eventIDOrigin, forKey: .eventIDOrigin)
        try c.encode(eventKind, forKey: .eventKind)
        try c.encode(source, forKey: .source)
        try c.encode(appliedTick, forKey: .appliedTick)
        try c.encode(appliedTickOrigin, forKey: .appliedTickOrigin)
        try c.encode(sensorySampleTick, forKey: .sensorySampleTick)
        try c.encode(brainEpoch, forKey: .brainEpoch)
        try c.encode(selectionID, forKey: .selectionID)
        try c.encode(preMs, forKey: .preMs)
        try c.encode(postMs, forKey: .postMs)
        try c.encode(baselineWindow, forKey: .baselineWindow)
        try c.encode(responseWindow, forKey: .responseWindow)
        try c.encode(status, forKey: .status)
        try c.encode(responseTicksCollected, forKey: .responseTicksCollected)
        try c.encode(validity, forKey: .validity)
        try c.encode(groups, forKey: .groups)
        try c.encode(motorOutput, forKey: .motorOutput)
        try c.encode(observedBodyAction, forKey: .observedBodyAction)
    }
}
