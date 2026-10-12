// InteractionExplanation.swift — V7.7 `interaction_explanation.v1`: rule-based
// sentences about one interaction window, built from its numbers and its
// observation state only.
//
// `explain` is PURE (no globals, no clock, no randomness): the same window gives the
// same explanation. It separates what a direct physical force did to the body from
// what the neural output did, and it states only what was measured and when (sim
// ticks). It never names a cause, an emotion, an intention or a thought: the
// sentences are fixed templates filled with `facts`, and every number printed in
// a sentence is one of the facts (the helper `Facts.add` returns the very text it
// stored). Missing data is a reason in the output, never a guess.

import Foundation

/// Thresholds. Each says where it comes from; none was tuned to a test.
struct ExplanationThresholds: Equatable {
    /// Group rate change (Hz/neuron) must exceed max(floor, `noiseK` × the Poisson noise of
    /// Δ). Noise: independent Poisson spiking gives Var(rate) = rate / (members × seconds), so
    /// sd(Δ) = sqrt(rb/(N·Tb) + rr/(N·Tr)) from the window's own rates, member count and
    /// lengths. Real spiking is correlated, which makes this a LOWER bound of the noise.
    /// `noiseK` 3 is the usual three-sigma convention.
    var groupFloorHz = 1.0
    var noiseK = 3.0
    /// Motor signal means (walkDrive, turnBias, groomDrive, wingDrive, nervous, arousal) all live on
    /// a ~0…1.3 scale (SignalBuilder clamps). A change must exceed 0.1, about 8 % of full
    /// scale: a documented constant, since the per-tick signal has no baseline-derived noise model.
    var motorFloor = 0.1
    /// Body: the change in displacement RATE (net displacement ÷ first→last sample time) between the
    /// response and baseline windows. Fixed floors per unit, again with no noise model for one
    /// displacement sample: 1 mm/s (FlyGym, a walking fly covers ~10 mm/s) and 10 pt/s (local fly).
    var bodyFloorMmPerS = 1.0
    var bodyFloorPtPerS = 10.0
    func bodyFloor(unit: String) -> Double { unit == "mm" ? bodyFloorMmPerS : bodyFloorPtPerS }
    static let standard = ExplanationThresholds()

    /// Strictly-greater-than rule: a change exactly at the threshold is NOT beyond it.
    func groupThreshold(baselineHz: Double, responseHz: Double, members: Int, baselineTicks: Int, responseTicks: Int) -> Double {
        let n = Double(max(members, 1)), tb = Double(max(baselineTicks, 1)) / 1000, tr = Double(max(responseTicks, 1)) / 1000
        let sd = (max(baselineHz, 0) / (n * tb) + max(responseHz, 0) / (n * tr)).squareRoot()
        return max(groupFloorHz, noiseK * sd)
    }
}

enum ExplanationVerdict: String, Codable, CaseIterable {
    case observing, insufficient
    case noResponse = "no_response", neuralResponse = "neural_response", neuralActivityOnly = "neural_activity_only"
    case physicalOnly = "physical_only", mixed, unclear
}

struct ExplanationFact: Codable, Equatable {
    var key: String
    /// The exact text a sentence prints for this fact.
    var value: String
}

struct ExplanationSentences: Codable, Equatable {
    var ko: [String]
    var en: [String]
}

struct InteractionExplanation: Codable, Equatable {
    var schema = InteractionExplanation.schemaName
    static let schemaName = "interaction_explanation.v1"
    var eventID: String
    var verdict: ExplanationVerdict
    /// Machine-readable reasons (insufficient / unclear), `code` or `code:detail`.
    var reasons: [String]
    var facts: [ExplanationFact]
    var sentences: ExplanationSentences

    enum CodingKeys: String, CodingKey { case schema, verdict, reasons, facts, sentences, eventID = "event_id" }
}

private struct Facts {
    var list: [ExplanationFact] = []
    @discardableResult mutating func add(_ key: String, _ text: String) -> String {
        if !list.contains(where: { $0.key == key }) { list.append(ExplanationFact(key: key, value: text)) }
        return text
    }
    mutating func int(_ key: String, _ v: Int) -> String { add(key, String(v)) }
    mutating func hz(_ key: String, _ v: Double) -> String { add(key, String(format: "%.1f", v)) }
    mutating func signedHz(_ key: String, _ v: Double) -> String { add(key, String(format: "%+.1f", v)) }
    mutating func motor(_ key: String, _ v: Double) -> String { add(key, String(format: "%.2f", v)) }
    mutating func signedMotor(_ key: String, _ v: Double) -> String { add(key, String(format: "%+.2f", v)) }
}

private struct Out {
    var en: [String] = [], ko: [String] = []
    mutating func add(_ e: String, _ k: String) { en.append(e); ko.append(k) }
}

enum InteractionExplainer {
    private static let signals: [(name: String, get: (MotorMeans) -> Double)] = [
        ("walkDrive", { $0.walkDrive }), ("turnBias", { $0.turnBias }), ("groomDrive", { $0.groomDrive }),
        ("wingDrive", { $0.wingDrive }), ("nervous", { $0.nervous }), ("arousal", { $0.arousal })]

    private struct GroupM { var id: String; var b: Double, r: Double, d: Double, thr: Double
        var beyond: Bool { abs(d) > thr } }
    private struct MotorM { var name: String; var b: Double, r: Double }
    private struct BodyM { var unit: String; var db: Double, dr: Double, rateB: Double, rateR: Double }

    private static func yesNo(_ v: Bool?) -> (en: String, ko: String) {
        v == nil ? ("unknown", "알 수 없음") : (v! ? ("yes", "예") : ("no", "아니오"))
    }

    /// Reason code → (EN, KO) text; the part after ':' is appended verbatim.
    private static func reasonText(_ code: String) -> (en: String, ko: String) {
        let name = String(code.split(separator: ":", maxSplits: 1).first ?? "")
        let detail = code.contains(":") ? " (" + code.split(separator: ":", maxSplits: 1)[1] + ")" : ""
        let t: (String, String)
        switch name {
        case "window_invalid": t = ("the window is invalid", "창이 무효임")
        case "baseline_insufficient": t = ("the baseline was not fully observed", "이전(기준) 구간을 다 관측하지 못함")
        case "overlapping_events": t = ("other events overlap this window", "다른 사건과 창이 겹침")
        case "no_groups": t = ("no observed group", "관측된 그룹이 없음")
        case "group_delta_unavailable": t = ("a group has no rate change", "변화량이 없는 그룹이 있음")
        case "motor_not_collected": t = ("motor output was not collected (v1 record)", "운동 출력을 수집하지 않음(v1 기록)")
        case "body_not_collected": t = ("body action was not collected (v1 record)", "몸 동작을 수집하지 않음(v1 기록)")
        case "motor_baseline_unavailable": t = ("no motor samples in the baseline", "이전 구간 운동 표본 없음")
        case "motor_response_unavailable": t = ("no motor samples in the response", "이후 구간 운동 표본 없음")
        case "body_baseline_unavailable": t = ("no body samples in the baseline", "이전 구간 몸 표본 없음")
        case "body_response_unavailable": t = ("no body samples in the response", "이후 구간 몸 표본 없음")
        case "body_position_unit_mixed": t = ("body positions mix two units", "몸 위치 단위가 섞여 있음")
        case "body_single_sample": t = ("a window has one body sample, so no displacement rate exists", "몸 표본이 하나뿐이라 이동 속도를 구할 수 없음")
        case "groups_opposite_direction": t = ("groups changed in opposite directions", "그룹 변화 방향이 서로 반대임")
        case "motor_changed_body_unavailable": t = ("motor output changed but body samples are unavailable", "운동 출력은 바뀌었지만 몸 표본이 없음")
        case "motor_changed_body_not_moved": t = ("motor output changed but the body did not move beyond its threshold", "운동 출력은 바뀌었지만 몸은 기준 이상 움직이지 않음")
        case "motor_changed_without_group_change": t = ("motor output changed without a group change beyond its threshold", "그룹 변화가 기준 이내인데 운동 출력이 바뀜")
        case "body_moved_without_force_or_motor_change": t = ("the body moved without an applied force or a motor change", "가해진 힘도 운동 출력 변화도 없는데 몸이 움직임")
        case "force_unknown": t = ("the event does not say whether a force was applied", "사건이 힘을 가했는지 알려주지 않음")
        default: t = (name, name)
        }
        return (t.0 + detail, t.1 + detail)
    }

    static func explain(window w: InteractionWindow, thresholds th: ExplanationThresholds = .standard) -> InteractionExplanation {
        var facts = Facts()
        var out = Out()
        var reasons: [String] = []
        func done(_ v: ExplanationVerdict) -> InteractionExplanation {
            InteractionExplanation(eventID: w.eventID, verdict: v, reasons: reasons, facts: facts.list,
                                   sentences: ExplanationSentences(ko: out.ko, en: out.en))
        }
        func reasonSentence(_ lead: (String, String)) {
            let texts = reasons.map(reasonText)
            out.add(lead.0 + texts.map(\.en).joined(separator: "; ") + ".", lead.1 + texts.map(\.ko).joined(separator: "; ") + ".")
        }

        // 1. observing
        if w.status == .collecting {
            let c = facts.int("response_ticks_collected", w.responseTicksCollected), n = facts.int("response_ticks_needed", w.postMs)
            let ms = facts.int("tick_ms", 1)
            out.add("Still observing: \(c) of \(n) response ticks (simulation ticks, \(ms) ms each) have been collected. No explanation yet.",
                    "관측 중: 응답 구간 \(n) tick(시뮬레이션 tick, \(ms) ms) 중 \(c) tick을 모았다. 아직 설명하지 않는다.")
            return done(.observing)
        }

        // 2. insufficient — every reason comes from a validity flag or a missing summary.
        let v = w.validity
        var flags: [String] = []
        if v.appliedTickUnknown { flags.append("applied_tick_unknown") }
        if v.noSelection { flags.append("no_selection") }
        if v.brainReset { flags.append("brain_reset") }
        if v.selectionChanged { flags.append("selection_changed") }
        if v.bufferOverflow { flags.append("buffer_overflow") }
        if v.evicted { flags.append("ticks_evicted") }
        if w.status == .invalid || !flags.isEmpty {
            let missing = v.droppedSamples ?? 0
            if flags.isEmpty && missing > 0 { flags.append("dropped_\(missing)_ticks") }
            reasons.append("window_invalid:" + (flags.isEmpty ? "unspecified" : flags.joined(separator: ",")))
        }
        if v.baselineInsufficient { reasons.append("baseline_insufficient") }
        if !v.overlappingEvents.isEmpty { reasons.append("overlapping_events") }
        if w.groups.isEmpty { reasons.append("no_groups") }
        for g in w.groups where g.deltaHzPerNeuron == nil {
            reasons.append("group_delta_unavailable:\(g.groupID):\(g.deltaUnavailableReason ?? "unknown")")
        }
        if let m = w.motorOutput {
            if m.baseline.status == .unavailable { reasons.append("motor_baseline_unavailable:\(m.baseline.reason ?? "unknown")") }
            if m.response.status == .unavailable { reasons.append("motor_response_unavailable:\(m.response.reason ?? "unknown")") }
        } else { reasons.append("motor_not_collected") }
        let body = w.observedBodyAction
        var bodyReasons: [String] = []    // only block the verdicts that need the body
        if let b = body {
            if b.baseline.status == .unavailable { bodyReasons.append("body_baseline_unavailable:\(b.baseline.reason ?? "unknown")") }
            if b.response.status == .unavailable { bodyReasons.append("body_response_unavailable:\(b.response.reason ?? "unknown")") }
        } else { bodyReasons.append("body_not_collected") }
        if !reasons.isEmpty {
            facts.add("event_kind", w.eventKind)
            if !v.overlappingEvents.isEmpty { _ = facts.int("overlapping_events", v.overlappingEvents.count) }
            let n = v.overlappingEvents.count
            reasonSentence(("Not enough data to explain this event: ", "이 사건을 설명하기에 관측이 부족하다: "))
            if n > 0 { out.add("\(n) other event window(s) overlap this one.", "다른 사건 창 \(n)개가 이 창과 겹친다.") }
            return done(.insufficient)
        }

        // Measurements.
        let bt = w.baselineWindow?.length ?? w.preMs, rt = w.responseWindow?.length ?? w.postMs
        let ms: [GroupM] = w.groups.compactMap { g in
            guard let b = g.baseline?.rateHzPerNeuron, let r = g.response?.rateHzPerNeuron, let d = g.deltaHzPerNeuron else { return nil }
            return GroupM(id: g.groupID, b: b, r: r, d: d,
                          thr: th.groupThreshold(baselineHz: b, responseHz: r, members: g.memberCount, baselineTicks: bt, responseTicks: rt))
        }
        let mb = w.motorOutput!.baseline, mr = w.motorOutput!.response
        let mm: [MotorM] = signals.map { MotorM(name: $0.name, b: $0.get(mb.mean!), r: $0.get(mr.mean!)) }
        let motorMoved = mm.filter { abs($0.r - $0.b) > th.motorFloor }
        let escapeNew = (mr.escapeCount ?? 0) > 0 && (mb.escapeCount ?? 0) == 0
        let backwardNew = (mr.backwardCount ?? 0) > 0 && (mb.backwardCount ?? 0) == 0
        let motorChanged = !motorMoved.isEmpty || escapeNew || backwardNew

        var bodyM: BodyM?
        var bodyUnknown = bodyReasons
        if bodyUnknown.isEmpty, let bb = body?.baseline, let br = body?.response {
            func rate(_ s: BodyWindowSummary) -> (disp: Double, perS: Double)? {
                guard let d = s.netDisplacement, let f = s.firstTick, let l = s.lastTick, l > f else { return nil }
                return (d, d / (Double(l - f) / 1000))
            }
            if bb.positionUnit == "mixed" || br.positionUnit == "mixed" || bb.positionUnit != br.positionUnit {
                bodyUnknown.append("body_position_unit_mixed")
            } else if let b = rate(bb), let r = rate(br), let unit = br.positionUnit {
                bodyM = BodyM(unit: unit, db: b.disp, dr: r.disp, rateB: b.perS, rateR: r.perS)
            } else { bodyUnknown.append("body_single_sample") }
        }
        let bodyMoved = bodyM.map { abs($0.rateR - $0.rateB) > th.bodyFloor(unit: $0.unit) }
        let beyond = ms.filter(\.beyond)
        let opposite = beyond.contains { $0.d > 0 } && beyond.contains { $0.d < 0 }
        let force = w.forceApplied

        // 3. verdict
        var verdict: ExplanationVerdict
        if motorChanged {
            if force == true { verdict = .mixed }
            else if bodyMoved == nil { verdict = .unclear; reasons.append("motor_changed_body_unavailable") }
            else if opposite { verdict = .unclear; reasons.append("groups_opposite_direction") }
            else if bodyMoved == true && !beyond.isEmpty { verdict = .neuralResponse }
            else {
                verdict = .unclear
                if bodyMoved == false { reasons.append("motor_changed_body_not_moved") }
                if beyond.isEmpty { reasons.append("motor_changed_without_group_change") }
            }
        } else if bodyMoved == nil {
            verdict = .insufficient; reasons = bodyUnknown
        } else if bodyMoved == true {
            if force == true { verdict = .physicalOnly }
            else {
                verdict = .unclear
                reasons.append(force == nil ? "force_unknown" : "body_moved_without_force_or_motor_change")
                if opposite { reasons.append("groups_opposite_direction") }
            }
        } else if beyond.isEmpty { verdict = .noResponse }
        else if opposite { verdict = .unclear; reasons.append("groups_opposite_direction") }
        else { verdict = .neuralActivityOnly }

        // 4. sentences — measured values first, then the conclusion.
        facts.add("event_kind", w.eventKind)
        let fl = yesNo(force), sn = yesNo(w.sensoryApplied)
        facts.add("force_applied", fl.en); facts.add("sensory_applied", sn.en)
        out.add("Event \(w.eventKind): direct physical force applied: \(fl.en); modeled sensory input: \(sn.en).",
                "사건 \(w.eventKind): 물리적 힘을 가함: \(fl.ko); 모델 감각 입력: \(sn.ko).")
        if let rw = w.responseWindow, let bw = w.baselineWindow {
            let rs = facts.int("response_start_tick", rw.start), re = facts.int("response_end_tick", rw.end)
            let bs = facts.int("baseline_start_tick", bw.start), be = facts.int("baseline_end_tick", bw.end)
            out.add("Windows (simulation ticks): response \(rs) to \(re), baseline \(bs) to \(be).",
                    "구간(시뮬레이션 tick): 이후 \(rs)~\(re), 이전 \(bs)~\(be).")
        }
        let nr = facts.int("response_ticks", rt)
        for g in beyond {
            let b = facts.hz("group.\(g.id).baseline_hz", g.b), r = facts.hz("group.\(g.id).response_hz", g.r)
            let d = facts.signedHz("group.\(g.id).delta_hz", g.d), t = facts.hz("group.\(g.id).threshold_hz", g.thr)
            out.add("Over the \(nr) ticks after the event, group \(g.id) firing rate \(g.d > 0 ? "rose" : "fell") \(b) → \(r) Hz/neuron (\(d), beyond ±\(t)).",
                    "사건 후 \(nr) tick 동안 \(g.id) 그룹 발화율이 \(b) → \(r) Hz/뉴런(\(d), 기준 ±\(t))으로 \(g.d > 0 ? "올랐다" : "내렸다").")
        }
        let within = ms.filter { !$0.beyond }
        if let top = within.max(by: { abs($0.d) < abs($1.d) }) {
            let n = facts.int("groups_within_threshold", within.count)
            let d = facts.signedHz("group.\(top.id).delta_hz", top.d), t = facts.hz("group.\(top.id).threshold_hz", top.thr)
            out.add("\(n) group(s) stayed within their thresholds; the largest change was \(top.id) \(d) Hz/neuron (threshold ±\(t)).",
                    "\(n)개 그룹은 기준 이내였다. 가장 큰 변화는 \(top.id) \(d) Hz/뉴런(기준 ±\(t))이다.")
        }
        if !motorMoved.isEmpty {
            let parts = motorMoved.map { m -> (String, String) in
                let s = "\(m.name) \(facts.motor("motor.\(m.name).baseline", m.b)) → \(facts.motor("motor.\(m.name).response", m.r))"
                return (s, s)
            }
            out.add("In the same window the motor signal means changed: " + parts.map(\.0).joined(separator: ", ") + ".",
                    "같은 구간 운동 신호 평균이 바뀌었다: " + parts.map(\.1).joined(separator: ", ") + ".")
        } else if let top = mm.max(by: { abs($0.r - $0.b) < abs($1.r - $1.b) }) {
            let f = facts.motor("motor_floor", th.motorFloor)
            let d = facts.signedMotor("motor.\(top.name).delta", top.r - top.b)
            out.add("No motor signal mean moved beyond ±\(f) (largest change: \(top.name) \(d)).",
                    "운동 신호 평균은 기준 ±\(f)을 넘어 바뀌지 않았다(가장 큰 변화: \(top.name) \(d)).")
        }
        if escapeNew || backwardNew {
            let eb = facts.int("motor.escape_count.baseline", mb.escapeCount ?? 0), er = facts.int("motor.escape_count.response", mr.escapeCount ?? 0)
            let bb = facts.int("motor.backward_count.baseline", mb.backwardCount ?? 0), br = facts.int("motor.backward_count.response", mr.backwardCount ?? 0)
            out.add("Motor event counts (baseline → response): escape \(eb) → \(er), backward \(bb) → \(br).",
                    "운동 사건 횟수(이전 → 이후): escape \(eb) → \(er), backward \(bb) → \(br).")
        }
        let sb = facts.int("motor.baseline.sample_count", mb.sampleCount), sr = facts.int("motor.response.sample_count", mr.sampleCount)
        let pr = mr.periodTicks.map { facts.add("motor.response.period_ticks", String(format: "%.0f", $0)) }
        out.add("Motor samples: \(sb) in the baseline, \(sr) in the response" + (pr.map { " (period \($0) ticks)" } ?? " (period not measured)") + ".",
                "운동 표본: 이전 \(sb)개, 이후 \(sr)개" + (pr.map { "(간격 \($0) tick)" } ?? "(간격 미측정)") + ".")
        if let b = bodyM {
            let db = facts.motor("body.baseline.displacement", b.db), dr = facts.motor("body.response.displacement", b.dr)
            let rb = facts.motor("body.baseline.rate", b.rateB), rr = facts.motor("body.response.rate", b.rateR)
            let t = facts.motor("body.threshold_rate", th.bodyFloor(unit: b.unit))
            let u = facts.add("body.unit", b.unit)
            out.add("Body net displacement: \(db) \(u) in the baseline (\(rb) \(u)/s), \(dr) \(u) in the response (\(rr) \(u)/s); "
                    + (bodyMoved == true ? "the rate changed beyond ±\(t) \(u)/s." : "the rate stayed within ±\(t) \(u)/s."),
                    "몸 순이동: 이전 \(db) \(u)(\(rb) \(u)/s), 이후 \(dr) \(u)(\(rr) \(u)/s); "
                    + (bodyMoved == true ? "속도 변화가 기준 ±\(t) \(u)/s를 넘었다." : "속도 변화는 기준 ±\(t) \(u)/s 이내였다."))
        }
        for (name, s) in [("baseline", body?.baseline), ("response", body?.response)] {
            guard let s, (s.receivedAtCount ?? 0) > 0, let f = s.firstTick, let l = s.lastTick else { continue }
            let fk = facts.int("body.\(name).first_tick", f), lk = facts.int("body.\(name).last_tick", l)
            let n = facts.int("body.\(name).received_at_count", s.receivedAtCount ?? 0)
            out.add("Body \(name): \(n) sample(s) between ticks \(fk) and \(lk) carry the receive time (the true sample time is unknown).",
                    "몸 \(name == "baseline" ? "이전" : "이후") 구간: tick \(fk)~\(lk)의 표본 \(n)개는 수신 시각이다(실제 측정 시각은 모른다).")
        }

        switch verdict {
        case .noResponse:
            out.add("No response: no group, motor signal or body movement changed beyond its threshold.",
                    "무반응: 어떤 그룹·운동 신호·몸 움직임도 기준을 넘어 바뀌지 않았다.")
        case .neuralResponse:
            out.add("Neural response: group firing and motor output changed and the body moved in the same window.",
                    "신경 반응: 같은 구간에서 그룹 발화와 운동 출력이 바뀌었고 몸이 움직였다.")
        case .neuralActivityOnly:
            out.add("Neural activity only: group firing changed, but motor output and body stayed within their thresholds.",
                    "신경 활동만: 그룹 발화는 바뀌었지만 운동 출력과 몸은 기준 이내였다.")
        case .physicalOnly:
            out.add("Physical force: the body was moved by the applied force; motor output did not change beyond its threshold.",
                    "물리적 힘: 몸의 움직임은 가해진 힘 때문이며, 운동 출력은 기준을 넘어 바뀌지 않았다.")
        case .mixed:
            out.add("Mixed: a physical force was applied and motor output also changed; body movement is not attributed to either alone.",
                    "혼합: 물리적 힘이 가해졌고 운동 출력도 바뀌었다. 몸의 움직임을 둘 중 하나만의 결과로 보지 않는다.")
        case .unclear:
            reasonSentence(("Unclear: ", "불명확: "))
        case .insufficient:
            reasonSentence(("Not enough data to explain this event: ", "이 사건을 설명하기에 관측이 부족하다: "))
        case .observing: break
        }
        return done(verdict)
    }
}

/// The one entry point the UI, the recorder and the diagnostics call.
func explain(window: InteractionWindow, thresholds: ExplanationThresholds = .standard) -> InteractionExplanation {
    InteractionExplainer.explain(window: window, thresholds: thresholds)
}
