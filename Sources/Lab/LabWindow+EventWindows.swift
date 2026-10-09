import Cocoa

// V7.5 pre/post-event windows — Lab side: how each backend command becomes an
// event, where finished windows are recorded, and the Brain-page readout.
//
// Anchoring rule: an event is anchored only on a reliable NEURAL tick. Direct
// neural and local modeled interventions are noted on the simulation thread
// (Coordinator+EventWindows.swift). A backend command is noted from its ACK, and
// only a deterministic-session ACK of the current session/epoch is trusted:
// there `applied_tick` is the lockstep tick, which LabSession/
// driveDeterministicSession assert equal to `MetalSim.simMs` before every
// quantum. An interactive-session ACK carries the backend's body clock
// (`body.t`), which is a different clock from the brain's, so it is recorded as
// invalid(applied_tick_unknown) instead of being used.

enum EventWindowIntent {
    typealias Intent = (kind: String, source: InteractionEventSource)

    /// What a command means for event windows; nil when it is not an
    /// intervention (resets, scene files, wind-off, a zero-strength wind...).
    static func classify(_ c: LabCommand) -> Intent? {
        switch c.action {
        case "wind", "wind_puff":
            guard (c.strength ?? 0) > 0 else { return nil }
            switch (c.physical ?? true, c.sensory ?? true) {
            case (true, true): return ("wind", .physicalAndSensoryModel)
            case (true, false): return ("wind", .physical)
            case (false, true): return ("wind", .sensoryModel)
            case (false, false): return nil
            }
        case "touch":
            return ("touch", (c.sensory ?? true) ? .physicalAndSensoryModel : .physical)
        case "temperature", "set_temperature":
            // Only flywire_sensory drives neurons (TRN current). environment_only
            // changes the arena, and modeled_physiology only the body's tempo.
            guard c.mode == "flywire_sensory" else { return nil }
            return ("temperature:flywire_sensory", .sensoryModel)
        default:
            return classify(action: c.action)
        }
    }

    /// Actions whose meaning does not depend on command flags.
    static func classify(action: String) -> Intent? {
        switch action {
        case "flash_eye", "set_eye_state", "eye_state", "restore_eyes":
            return (action, .sensoryModel)
        case "spawn_object", "spawn_box", "spawn_sphere", "spawn_wall", "spawn_ramp", "spawn_food",
             "spawn_food_marker", "move_object", "resize_object", "delete_object", "remove_object",
             "approach_object", "approach", "edit_property", "edit_object", "interaction",
             "drive_object", "arm_trap", "fire_bb":
            return (action, .physical)
        default:
            return nil
        }
    }

    /// The neural applied tick an ACK can honestly anchor, or nil with the
    /// reason. Pure so the diagnostics can drive every branch.
    static func anchor(for ack: LabAck, in session: LabSessionSnapshot) -> (tick: Int?, origin: String) {
        if session.mode != .deterministic {
            return (nil, "unknown: interactive-session ACK tick is the backend body clock, not the neural tick")
        }
        if session.phase == .failed { return (nil, "unknown: deterministic session failed") }
        guard let at = ack.appliedTick, at >= 0, ack.appliedEpoch == session.epoch,
              ack.sessionID == nil || ack.sessionID == session.sessionID else {
            return (nil, "unknown: ACK has no applied tick for the current session epoch")
        }
        return (at + 1, "ack.applied_tick \(at) + 1 (deterministic session: neural tick == lockstep tick)")
    }

    /// One `interaction_window` record (root IDs as strings, as encoded) per
    /// finalized window, appended to the events stream of an active recording.
    static func recordingSink(_ recorder: ExperimentRecorder) -> (InteractionWindow) -> Void {
        { window in
            guard recorder.isRecording,
                  let data = try? JSONEncoder().encode(window),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            recorder.mark(kind: "interaction_window", detail: "\(window.eventKind) \(window.status.rawValue)",
                          simTick: window.appliedTick, appliedTick: window.appliedTick,
                          status: window.status.rawValue, extra: ["interaction_window": object])
        }
    }

    /// Writes the windows still collecting when a recording stops, as they are
    /// (status collecting): once the recorder leaves `.recording` the sink above
    /// drops them, and the event would otherwise have no window line at all.
    static func recordCollecting(_ buffer: EventWindowBuffer?, to recorder: ExperimentRecorder) {
        guard let buffer else { return }
        let sink = recordingSink(recorder)
        for w in buffer.windows().reversed() where w.status == .collecting { sink(w) }
    }

    /// Without the sent command these cannot be classified honestly.
    static func dependsOnFlags(_ action: String) -> Bool {
        ["wind", "wind_puff", "touch", "temperature", "set_temperature"].contains(action)
    }
}

extension LabWindowController {
    /// Called once per command right after it was sent: remembers its meaning
    /// until the ACK (flags such as physical/sensory are only known here).
    func declareEventWindowIntent(_ command: LabCommand, id: Int) {
        guard let intent = EventWindowIntent.classify(command) else { return }
        coordinator.sim?.eventWindows.declareCommand(id: id, kind: intent.kind, source: intent.source)
    }

    /// Called once per resolved ACK (the same first-resolution guard as the
    /// timeline row). A rejected command was not applied and is not an event.
    func noteEventWindow(ack: LabAck) {
        guard let buffer = coordinator.sim?.eventWindows else { return }
        let declared = buffer.takeIntent(commandID: ack.id)
        guard ack.ok else { return }
        guard let intent = declared ?? EventWindowIntent.classify(action: ack.action) else {
            if EventWindowIntent.dependsOnFlags(ack.action) { buffer.countUnclassifiedAck() }
            return
        }
        let session = coordinator.sessionSnapshot()
        let anchor = EventWindowIntent.anchor(for: ack, in: session)
        buffer.noteEvent(id: "cmd:\(ack.sessionID ?? session.sessionID):\(ack.id)", idOrigin: .labCommandID,
                         kind: intent.kind, source: intent.source,
                         appliedTick: anchor.tick, appliedTickOrigin: anchor.origin)
    }

    /// Writes every finalized window to the active recording's events stream.
    /// The sink runs on the simulation thread; the recorder is thread-safe.
    func installEventWindowRecording() {
        coordinator.sim?.eventWindows.onFinalized = EventWindowIntent.recordingSink(recorder)
    }

    /// The one call the Brain page makes.
    func eventWindowsSection() -> NSView {
        let label = EventWindowsLabel(coordinator: coordinator)
        let config = coordinator.sim?.eventWindows.currentConfig ?? .standard
        let title = String(format: L("Around events (%g s before / %g s after)", "사건 전후 (전 %g초 / 후 %g초)"),
                           Double(config.preMs) / 1000, Double(config.postMs) / 1000)
        return section(title,
                       help: L("Exact spike rates of the selected neurons just before and just after each intervention, on simulation ticks only (1 ms). The window starts at the first tick the event can affect and fills as the simulation runs — pausing stops it, wall time never completes it. An unobserved baseline stays “—”, it is never estimated.",
                               "선택한 뉴런이 각 개입 직전과 직후에 낸 정확한 발화율입니다. 시뮬레이션 tick(1 ms)만 기준으로 하며, 사건이 처음 영향을 줄 수 있는 tick부터 시뮬레이션이 돌아야 채워집니다. 일시 정지하면 멈추고, 실제 시간이 흘러도 완성되지 않습니다. 관측하지 못한 이전 구간은 추정하지 않고 “—”로 둡니다."),
                       [label])
    }
}

/// Text readout of the latest windows. It polls the buffer only to repaint;
/// no window state depends on this timer.
final class EventWindowsLabel: NSTextField {
    private weak var coordinator: Coordinator?
    private var timer: Timer?
    static let shown = 4

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        isEditable = false; isBordered = false; drawsBackground = false; isSelectable = true
        _ = LabForm.status(self, mono: true)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    private var paused: Bool {
        guard let c = coordinator else { return false }
        let s = c.labSession.snapshot()
        c.lock.lock(); let local = c.localNeuralPaused; c.lock.unlock()
        return local || (s.mode == .deterministic && s.phase != .running)
    }

    func refresh() {
        guard let buffer = coordinator?.sim?.eventWindows else {
            stringValue = L("The brain model is not loaded.", "뇌 모델을 불러오지 않았습니다.")
            return
        }
        stringValue = Self.text(windows: Array(buffer.windows().prefix(Self.shown)), stats: buffer.stats(), paused: paused)
    }

    /// Pure formatting (the diagnostics read it too).
    static func text(windows: [InteractionWindow], stats: EventWindowStats, paused: Bool) -> String {
        guard !windows.isEmpty else {
            return L("No events yet — a ⚡ click, a population stimulation, a flash, wind or touch appears here.",
                     "아직 사건이 없습니다 — ⚡ 클릭, 뉴런 그룹 자극, 빛, 바람, 건드리기가 여기에 나타납니다.")
        }
        var lines: [String] = []
        for w in windows {
            let tick = w.appliedTick.map { "t\($0)" } ?? L("t unknown", "시각 모름")
            lines.append("\(w.eventKind) · \(w.source.rawValue) · \(tick) — \(statusText(w, paused: paused))")
            if w.selectionOmitted > 0 {
                lines.append("  " + String(format: L("selection: %d picked neuron(s) over the exact limit are not in it", "selection: 정확 관측 한도를 넘은 뉴런 %d개는 빠져 있음"),
                                            w.selectionOmitted))
            }
            for g in w.groups { lines.append("  " + groupText(g, w)) }
            if !w.validity.overlappingEvents.isEmpty {
                lines.append("  " + String(format: L("overlaps %d other event(s): baseline/response are mixed", "다른 사건 %d개와 겹침: 이전/이후 구간이 섞여 있음"),
                                            w.validity.overlappingEvents.count))
            }
        }
        lines.append(String(format: L("latest %d shown · collecting %d/%d · kept %d/%d · overflow-displaced %d", "최근 %d개 표시 · 수집 중 %d/%d · 보관 %d/%d · 넘쳐서 밀려남 %d"),
                            windows.count, stats.collecting, InteractionWindowCapability.maxCollecting,
                            stats.history, InteractionWindowCapability.maxHistory, stats.overflowDisplaced))
        return lines.joined(separator: "\n")
    }

    static func statusText(_ w: InteractionWindow, paused: Bool) -> String {
        switch w.status {
        case .collecting:
            var t = String(format: L("collecting %d/%d ms", "수집 중 %d/%d ms"), w.responseTicksCollected, w.postMs)
            if paused { t += L(" · paused: simulation ticks stopped, the window does not advance", " · 일시 정지: 시뮬레이션 tick이 멈춰 창이 진행되지 않음") }
            return t
        case .complete:
            let v = w.validity
            if v.sufficient { return L("complete", "완료") }
            if v.baselineInsufficient { return L("complete (baseline not observed)", "완료 (이전 구간 관측 부족)") }
            if !v.overlappingEvents.isEmpty { return L("complete (overlaps another event)", "완료 (다른 사건과 겹침)") }
            return L("complete (not every group observed)", "완료 (관측 못 한 그룹 있음)")
        case .invalid:
            let v = w.validity
            var why: [String] = []
            if v.appliedTickUnknown { why.append(L("applied tick unknown", "적용 시각을 알 수 없음")) }
            if v.noSelection { why.append(L("no neurons selected", "선택한 뉴런 없음")) }
            if v.brainReset { why.append(L("brain reset", "뇌 초기화됨")) }
            if v.selectionChanged { why.append(L("selection changed", "선택이 바뀜")) }
            if v.bufferOverflow { why.append(L("buffer overflow", "보관 한도 초과")) }
            if v.evicted { why.append(L("ticks evicted", "tick이 보관 범위를 벗어남")) }
            if why.isEmpty, let d = v.droppedSamples, d > 0 { why.append(String(format: L("%d ms missing", "%d ms 빠짐"), d)) }
            return L("invalid — ", "무효 — ") + why.joined(separator: ", ")
        }
    }

    static func groupText(_ g: GroupWindowResult, _ w: InteractionWindow) -> String {
        func rate(_ o: NeuralObservation?, missing: Int) -> String {
            guard let r = o?.rateHzPerNeuron else { return String(format: L("— (%d ms not observed)", "— (%d ms 관측 못 함)"), missing) }
            return String(format: "%.2f", r)
        }
        let delta = g.deltaHzPerNeuron.map { String(format: "%+.2f", $0) }
            ?? "— (\(reasonText(g.deltaUnavailableReason)))"
        return "\(g.groupID): " + rate(g.baseline, missing: g.baselineMissingTicks) + " → "
            + rate(g.response, missing: g.responseMissingTicks) + " Hz/" + L("neuron", "뉴런") + "  Δ " + delta
    }

    private static func reasonText(_ reason: String?) -> String {
        switch reason {
        case "baseline_insufficient": return L("baseline not fully observed", "이전 구간을 다 관측하지 못함")
        case "response_incomplete": return L("response not fully observed", "이후 구간을 다 관측하지 못함")
        case "members_not_in_selection": return L("members are not in the exact selection", "구성 뉴런이 정확 관측 선택에 없음")
        default: return reason ?? ""
        }
    }
}
