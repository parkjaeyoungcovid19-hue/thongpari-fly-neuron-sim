// EnvironmentPanel.swift — V6.5 environment panel. Keeps three things apart:
// the value the backend applied (lab_state), the edit still on its way
// (EnvironmentSettingQueue), and the live sample at the fly (body packet plus
// the receptor current the brain side actually injected).
import Cocoa

struct EnvironmentSettingRequest: Equatable {
    let propertyID: String
    let value: EnvironmentPropertyValue
}

struct EnvironmentSettingInFlight {
    let commandID: Int
    let identity: WorldEditorIdentity
    let schedule: LabCommandSchedule?
    let request: EnvironmentSettingRequest
    let expectedRevision: Int
    let startedAt: Date
}

/// Send discipline for live controls (V6-03). At most one edit is in flight;
/// while it waits, each property keeps only its newest requested value, so a
/// fast drag sends a bounded number of edits and ends on the last value. The
/// next edit is built on the revision the previous ACK returned. A rejected or
/// stale edit is reported and the waiting values are dropped — never retried
/// silently over a change someone else made.
struct EnvironmentSettingQueue {
    static let timeout: TimeInterval = 8
    private(set) var inFlight: EnvironmentSettingInFlight?
    private(set) var waiting: [EnvironmentSettingRequest] = []
    private(set) var revision: Int?
    private(set) var identity: WorldEditorIdentity?
    private(set) var message = ""
    private(set) var isError = false
    /// The property `message` is about, so it is shown under its own section.
    private(set) var messagePropertyID: String?
    private(set) var sentCount = 0

    var isBusy: Bool { inFlight != nil || !waiting.isEmpty }

    /// The newest value not yet confirmed for `propertyID`, if any.
    func pendingValue(_ propertyID: String) -> EnvironmentPropertyValue? {
        if let w = waiting.last(where: { $0.propertyID == propertyID }) { return w.value }
        return inFlight?.request.propertyID == propertyID ? inFlight?.request.value : nil
    }

    mutating func request(_ r: EnvironmentSettingRequest) {
        if let i = waiting.firstIndex(where: { $0.propertyID == r.propertyID }) { waiting[i] = r }
        else { waiting.append(r) }
    }

    /// Owner revision seen in a lab_state of `current`. A different session or
    /// connection drops everything; revisions only move forward within one.
    mutating func observe(revision observed: Int?, identity current: WorldEditorIdentity, now: Date = Date()) {
        if identity != current {
            if identity != nil && isBusy {
                fail(L("Session changed — unsent changes were discarded", "세션이 바뀌어 보내지 못한 변경은 버렸습니다"),
                     propertyID: inFlight?.request.propertyID ?? waiting.first?.propertyID)
            } else {
                message = ""; isError = false; messagePropertyID = nil
            }
            identity = current; inFlight = nil; waiting.removeAll(); revision = nil
        }
        if let observed { revision = max(revision ?? observed, observed) }
        if let p = inFlight, now.timeIntervalSince(p.startedAt) > Self.timeout {
            inFlight = nil; waiting.removeAll()
            fail(L("No reply from the simulator — check the applied values before retrying",
                   "시뮬레이터 응답이 없습니다 — 적용된 값을 확인한 뒤 다시 시도하세요"), propertyID: p.request.propertyID)
        }
    }

    /// Builds the next edit, or nil when one is in flight, nothing waits, or
    /// no owner revision is known yet. An invalid request is dropped and reported.
    mutating func next(capabilities: EnvironmentCapabilities?) -> EnvironmentEdit? {
        guard inFlight == nil, !waiting.isEmpty, let revision, let capabilities else { return nil }
        let r = waiting.removeFirst()
        do {
            return try EnvironmentEdit.make(propertyID: r.propertyID, targetID: nil, expectedRevision: revision,
                                            value: r.value, capabilities: capabilities)
        } catch {
            fail(L("Not sent — ", "보내지 않음 — ") + String(describing: error), propertyID: r.propertyID)
            return nil
        }
    }

    mutating func began(commandID: Int, schedule: LabCommandSchedule?, edit: EnvironmentEdit, now: Date = Date()) {
        guard let identity else { return }
        inFlight = EnvironmentSettingInFlight(
            commandID: commandID, identity: identity, schedule: schedule,
            request: EnvironmentSettingRequest(propertyID: edit.propertyID, value: edit.value),
            expectedRevision: edit.expectedRevision, startedAt: now)
        sentCount += 1
        isError = false
        message = L("Sending…", "보내는 중…")
        messagePropertyID = edit.propertyID
    }

    mutating func sendFailed(propertyID: String) {
        waiting.removeAll()
        fail(L("Command not sent", "명령 전송 실패"), propertyID: propertyID)
    }

    /// Consumes the ACK of the in-flight edit. Returns false for any other ACK.
    @discardableResult
    mutating func accept(_ ack: LabAck) -> Bool {
        guard let p = inFlight, ack.id == p.commandID,
              ack.connectionGeneration == p.identity.generation else { return false }
        guard let schedule = p.schedule, ack.sessionID == schedule.sessionID, ack.epoch == schedule.epoch else {
            return false
        }
        inFlight = nil
        guard ack.ok else {
            waiting.removeAll()
            if let current = ack.edit?.currentRevision { revision = max(revision ?? current, current) }
            fail(Self.rejection(ack), propertyID: p.request.propertyID)
            return true
        }
        guard let result = ack.edit, result.ok, result.status == "applied",
              result.propertyID == p.request.propertyID, result.targetID == nil,
              let applied = result.revision, applied > p.expectedRevision, result.actualValue != nil,
              ack.status == "applied", ack.appliedEpoch == schedule.epoch,
              let tick = ack.appliedTick, tick >= schedule.requestedTick else {
            waiting.removeAll()
            fail(L("Reply did not confirm the change — check the applied values",
                   "응답이 적용을 확인하지 못했습니다 — 적용된 값을 확인하세요"), propertyID: p.request.propertyID)
            return true
        }
        revision = max(revision ?? applied, applied)
        isError = false
        message = waiting.isEmpty ? L("Applied at tick \(tick)", "적용됨 (시각 \(tick) ms)") : L("Sending…", "보내는 중…")
        messagePropertyID = p.request.propertyID
        return true
    }

    /// Forgets the last reply after a reset; an edit still on its way keeps its status.
    mutating func clearMessage() {
        guard !isBusy else { return }
        message = ""; isError = false; messagePropertyID = nil
    }

    private mutating func fail(_ text: String, propertyID: String?) {
        message = text; isError = true; messagePropertyID = propertyID
    }

    static func rejection(_ ack: LabAck) -> String {
        let prefix = L("Not applied — ", "적용 안 됨 — ")
        switch ack.edit?.status {
        case "rejected_stale_revision":
            return prefix + L("the environment changed first; check the applied values and try again",
                              "그사이 환경이 바뀌었습니다. 적용된 값을 확인하고 다시 하세요")
        case "rejected_busy":
            return prefix + L("a timed wind puff is running; wait for it to end or press Stop",
                              "시간 제한 바람이 부는 중입니다. 끝나거나 ‘끄기’를 누른 뒤 다시 하세요")
        default:
            guard let edit = ack.edit else { return prefix + ack.message }
            return prefix + (edit.reason ?? ack.message) + (edit.path.map { " (\($0))" } ?? "")
        }
    }
}

/// Plain-language direction of a world-frame wind relative to the fly.
enum EnvironmentWords {
    /// `windDeg` is where the wind blows toward (0 = +X, 90 = +Y); heading in radians.
    static func windRelative(windDeg: Double, headingRad: Double) -> (degrees: Double, text: String) {
        var rel = (windDeg - headingRad * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if rel > 180 { rel -= 360 }
        if rel <= -180 { rel += 360 }
        let sector = Int(((rel + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        let en = ["forward (from behind)", "forward-left", "to its left (from its right)", "back-left",
                  "backward (head-on)", "back-right", "to its right (from its left)", "forward-right"]
        let ko = ["앞쪽으로 (뒤에서 붊)", "왼쪽 앞으로", "왼쪽으로 (오른쪽에서 붊)", "왼쪽 뒤로",
                  "뒤쪽으로 (정면에서 붊)", "오른쪽 뒤로", "오른쪽으로 (왼쪽에서 붊)", "오른쪽 앞으로"]
        return (rel, L(en[sector], ko[sector]))
    }

    static func temperatureMode(_ mode: String) -> String {
        switch mode {
        case "flywire_sensory": return L("thermosensory neurons", "온도 감각 뉴런에 전달")
        case "modeled_physiology": return L("legacy tempo model", "예전 방식 (활동 속도만)")
        default: return L("record only", "기록만")
        }
    }
}

/// The panel's controls. LabWindow composes them into inspector sections and
/// owns the transient actions (puff, flash, touch, placing food).
final class EnvironmentPanel: NSObject {
    /// Sends an edit_property command; returns its id and owner boundary.
    var onSubmit: ((LabCommand, WorldEditorIdentity) -> (Int, LabCommandSchedule?)?)?
    /// Without a physics backend the brain-side temperature is the only owner.
    var onLocalTemperature: ((Double, String) -> Void)?

    private(set) var queue = EnvironmentSettingQueue()

    let temperatureSlider = NSSlider(value: 25, minValue: 10, maxValue: 40, target: nil, action: nil)
    let temperatureField = NSTextField(string: "25")
    let temperatureMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let temperatureApplied = NSTextField(wrappingLabelWithString: "")
    let windStrengthSlider = NSSlider(value: 0.7, minValue: 0, maxValue: 1, target: nil, action: nil)
    let windStrengthField = NSTextField(string: "0.7")
    let windDirectionDial = NSSlider(value: 90, minValue: 0, maxValue: 360, target: nil, action: nil)
    let windDirectionField = NSTextField(string: "0")
    let windPhysical = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let windSensory = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let windOnButton = NSButton(title: "", target: nil, action: nil)
    /// Wired by the window to the legacy stop_wind action, which also ends a
    /// running puff (a strength-0 edit would be rejected while one runs).
    let windOffButton = NSButton(title: "", target: nil, action: nil)
    let windApplied = NSTextField(wrappingLabelWithString: "")
    let leftMaskSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let rightMaskSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let leftMaskValue = NSTextField(labelWithString: "0%")
    let rightMaskValue = NSTextField(labelWithString: "0%")
    let lightApplied = NSTextField(wrappingLabelWithString: "")
    let foodSummary = NSTextField(wrappingLabelWithString: "")
    let sample = NSTextField(wrappingLabelWithString: "")
    /// Edit status shown under the section it is about.
    let temperatureStatus = NSTextField(wrappingLabelWithString: "")
    let windStatus = NSTextField(wrappingLabelWithString: "")
    let lightStatus = NSTextField(wrappingLabelWithString: "")
    /// A refusal made here, before anything was sent (bad number, no
    /// simulator). It covers its own section until that section is used again.
    private var localStatus: (propertyID: String, text: String)?

    private var capabilities: EnvironmentCapabilities?
    private var backend = false
    private var available = false
    private var wind: LabRemoteWind?
    private var temperature: LabRemoteTemperature?
    private var eyes: LabRemoteEyes?
    private var localTemperature = (celsius: 25.0, mode: "environment_only")
    /// Controls the user touched recently keep their draft instead of snapping
    /// back to the applied value between ACKs.
    private var touchedAt: [ObjectIdentifier: Date] = [:]

    /// (Re)labels the controls; safe to call again after a language change.
    func configure() {
        for f in [temperatureField, windStrengthField, windDirectionField] { _ = LabForm.number(f) }
        for f in [temperatureApplied, windApplied, lightApplied, foodSummary,
                  temperatureStatus, windStatus, lightStatus] { _ = LabForm.status(f) }
        _ = LabForm.status(sample, mono: true)
        for label in [temperatureStatus, windStatus, lightStatus] where label.stringValue.isEmpty { label.isHidden = true }
        for label in [leftMaskValue, rightMaskValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        temperatureMode.removeAllItems()
        for mode in ["flywire_sensory", "environment_only", "modeled_physiology"] {
            temperatureMode.addItem(withTitle: EnvironmentWords.temperatureMode(mode))
            temperatureMode.lastItem?.representedObject = mode
        }
        select(temperatureMode, localTemperature.mode)
        windDirectionDial.sliderType = .circular
        windDirectionDial.setAccessibilityLabel(L("Wind direction dial", "바람 방향 다이얼"))
        windDirectionDial.toolTip = L("Points where the wind blows, seen from above: right = +X, up = +Y",
                                      "위에서 본 바람이 부는 쪽: 오른쪽 = +X, 위 = +Y")
        windPhysical.title = L("Push the body (physics)", "몸을 실제로 밀기 (물리)")
        windSensory.title = L("Antenna wind sense (JO-C/E)", "더듬이 바람 감각 (JO-C/E)")
        windOnButton.title = L("Blow continuously", "계속 불기")
        windOffButton.title = L("Stop wind", "바람 끄기")
        [windOnButton, windOffButton].forEach { $0.bezelStyle = .rounded }
        leftMaskSlider.setAccessibilityLabel(L("Left eye cover amount", "왼쪽 눈 가림 정도"))
        rightMaskSlider.setAccessibilityLabel(L("Right eye cover amount", "오른쪽 눈 가림 정도"))
        let actions: [(NSControl, Selector)] = [
            (temperatureSlider, #selector(temperatureSliderMoved)), (temperatureField, #selector(temperatureTyped)),
            (temperatureMode, #selector(temperatureModePicked)),
            (windStrengthSlider, #selector(windStrengthMoved)), (windStrengthField, #selector(windStrengthTyped)),
            (windDirectionDial, #selector(windDialMoved)), (windDirectionField, #selector(windDirectionTyped)),
            (windPhysical, #selector(windFlagToggled)), (windSensory, #selector(windFlagToggled)),
            (windOnButton, #selector(windOn)),
            (leftMaskSlider, #selector(maskMoved)), (rightMaskSlider, #selector(maskMoved)),
        ]
        for (control, action) in actions { control.target = self; control.action = action }
        for slider in [temperatureSlider, windStrengthSlider, windDirectionDial, leftMaskSlider, rightMaskSlider] {
            slider.isContinuous = true
        }
        render()
    }

    // MARK: - Dial geometry

    /// The circular slider runs clockwise from the top; world angles run
    /// counter-clockwise from +X. Map so the knob points where the wind blows
    /// in a top-down view (+X right, +Y up).
    static func dialValue(worldDeg: Double) -> Double { normalized(90 - worldDeg) }
    static func worldDeg(dialValue: Double) -> Double { normalized(90 - dialValue) }
    static func normalized(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    // MARK: - Inputs

    private func touched(_ control: NSControl) { touchedAt[ObjectIdentifier(control)] = Date() }
    private func recentlyTouched(_ control: NSControl, now: Date) -> Bool {
        if let editor = (control as? NSTextField)?.currentEditor(), editor.window != nil { return true }
        return touchedAt[ObjectIdentifier(control)].map { now.timeIntervalSince($0) < 1.0 } ?? false
    }

    @objc private func temperatureSliderMoved() {
        touched(temperatureSlider)
        let c = (temperatureSlider.doubleValue * 2).rounded() / 2
        temperatureField.doubleValue = c
        submitTemperature(celsius: c)
    }
    @objc private func temperatureTyped() {
        touched(temperatureField)
        guard let c = number(temperatureField, in: 10...40, name: L("Temperature", "온도")) else { return }
        temperatureSlider.doubleValue = c
        submitTemperature(celsius: c)
    }
    @objc private func temperatureModePicked() {
        touched(temperatureMode)
        let mode = (temperatureMode.selectedItem?.representedObject as? String) ?? "environment_only"
        if backend { submit("temperature.mode", .choice(mode)) }
        else { onLocalTemperature?(temperatureSlider.doubleValue, mode); localTemperature.mode = mode }
        render()
    }
    private func submitTemperature(celsius: Double) {
        if !backend { clearRefusal("temperature.celsius") }
        if backend { submit("temperature.celsius", .number(celsius)) }
        else {
            let mode = (temperatureMode.selectedItem?.representedObject as? String) ?? "environment_only"
            onLocalTemperature?(celsius, mode)
            localTemperature = (celsius, mode)
        }
        render()
    }

    @objc private func windStrengthMoved() {
        touched(windStrengthSlider)
        let v = (windStrengthSlider.doubleValue * 100).rounded() / 100
        windStrengthField.doubleValue = v
        submit("wind.strength", .number(v))
    }
    @objc private func windStrengthTyped() {
        touched(windStrengthField)
        guard let v = number(windStrengthField, in: 0...1, name: L("Wind strength", "바람 세기")) else { return }
        windStrengthSlider.doubleValue = v
        submit("wind.strength", .number(v))
    }
    @objc private func windDialMoved() {
        touched(windDirectionDial)
        let deg = Self.worldDeg(dialValue: windDirectionDial.doubleValue).rounded()
        windDirectionField.doubleValue = deg == 360 ? 0 : deg
        submit("wind.direction_deg", .number(windDirectionField.doubleValue))
    }
    @objc private func windDirectionTyped() {
        touched(windDirectionField)
        guard let v = number(windDirectionField, in: -360...360, name: L("Wind direction", "바람 방향")) else { return }
        windDirectionDial.doubleValue = Self.dialValue(worldDeg: v)
        submit("wind.direction_deg", .number(v))
    }
    @objc private func windFlagToggled(_ sender: NSButton) {
        touched(sender)
        submit(sender === windPhysical ? "wind.physical" : "wind.sensory", .boolean(sender.state == .on))
    }
    @objc private func windOn() {
        let v = max(0.01, (windStrengthSlider.doubleValue * 100).rounded() / 100)
        touched(windStrengthSlider)
        windStrengthSlider.doubleValue = v; windStrengthField.doubleValue = v
        submit("wind.direction_deg", .number(Self.worldDeg(dialValue: windDirectionDial.doubleValue).rounded()))
        submit("wind.strength", .number(v))
    }
    @objc private func maskMoved(_ sender: NSSlider) {
        touched(sender)
        let v = (sender.doubleValue * 20).rounded() / 20
        showMaskValues()
        submit(sender === leftMaskSlider ? "eyes.left_mask" : "eyes.right_mask", .number(v))
    }

    private func number(_ field: NSTextField, in range: ClosedRange<Double>, name: String) -> Double? {
        let propertyID = field === temperatureField ? "temperature.celsius"
            : field === windStrengthField ? "wind.strength" : "wind.direction_deg"
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Double(text), v.isFinite, range.contains(v) else {
            refuse(propertyID, name + L(": enter a number from \(fmt(range.lowerBound)) to \(fmt(range.upperBound)) — not sent",
                               ": \(fmt(range.lowerBound))–\(fmt(range.upperBound)) 사이 숫자를 입력하세요 — 보내지 않음"))
            return nil
        }
        return v
    }

    private func submit(_ propertyID: String, _ value: EnvironmentPropertyValue) {
        guard backend else {
            refuse(propertyID, L("Start with the physics simulator to change this", "물리 시뮬레이터와 함께 실행해야 바꿀 수 있습니다"))
            return
        }
        guard available else {
            refuse(propertyID, L("Not sent — the simulator is not accepting commands right now", "보내지 않음 — 지금은 시뮬레이터가 명령을 받지 않습니다"))
            return
        }
        clearRefusal(propertyID)
        queue.request(EnvironmentSettingRequest(propertyID: propertyID, value: value))
        pump()
        render()
    }

    private func pump() {
        guard let identity = queue.identity, let edit = queue.next(capabilities: capabilities) else { return }
        guard let (id, schedule) = onSubmit?(LabCommand.editProperty(edit), identity) else {
            queue.sendFailed(propertyID: edit.propertyID); return
        }
        queue.began(commandID: id, schedule: schedule, edit: edit)
    }

    func accept(_ ack: LabAck) {
        guard queue.accept(ack) else { return }
        pump()
        render()
    }

    // MARK: - Owner state

    func update(state: LabRemoteState?, telemetry t: LabTelemetry, body: FlyGymBodyFeedback?,
                identity: WorldEditorIdentity?, backendConnected: Bool, available: Bool, now: Date = Date()) {
        backend = backendConnected
        self.available = available
        let world = state?.worldState
        if let caps = world?.environmentCapabilities { capabilities = caps }
        if let identity, identity != queue.identity { localStatus = nil }
        if let identity { queue.observe(revision: world?.environmentRevision, identity: identity, now: now) }
        if let w = world?.wind { wind = w }
        if let tp = world?.temperature { temperature = tp }
        if let e = world?.eyes { eyes = e }
        if !backendConnected { wind = nil; temperature = nil; eyes = nil }
        localTemperature = (t.temperatureC, t.temperatureMode)
        pump()
        snapControls(now: now)
        renderSample(t, body: body, state: state)
        render()
    }

    /// Draft controls follow the applied value unless the user is working them
    /// or an edit for that property has not been confirmed yet.
    private func snapControls(now: Date) {
        func follow(_ c: NSControl, _ pid: String, _ apply: () -> Void) {
            if queue.pendingValue(pid) == nil && !recentlyTouched(c, now: now) { apply() }
        }
        let celsius = temperature?.celsius ?? localTemperature.celsius
        let mode = temperature?.mode ?? localTemperature.mode
        follow(temperatureSlider, "temperature.celsius") { temperatureSlider.doubleValue = celsius }
        follow(temperatureField, "temperature.celsius") { temperatureField.doubleValue = celsius }
        follow(temperatureMode, "temperature.mode") { select(temperatureMode, mode) }
        if let wind {
            if wind.strength > 0 {
                follow(windStrengthSlider, "wind.strength") { windStrengthSlider.doubleValue = wind.strength }
                follow(windStrengthField, "wind.strength") { windStrengthField.doubleValue = wind.strength }
            }
            follow(windDirectionDial, "wind.direction_deg") { windDirectionDial.doubleValue = Self.dialValue(worldDeg: wind.directionDeg) }
            follow(windDirectionField, "wind.direction_deg") { windDirectionField.doubleValue = wind.directionDeg }
            follow(windPhysical, "wind.physical") { windPhysical.state = wind.physicalEnabled ? .on : .off }
            follow(windSensory, "wind.sensory") { windSensory.state = wind.sensoryEnabled ? .on : .off }
        }
        if let eyes {
            follow(leftMaskSlider, "eyes.left_mask") { leftMaskSlider.doubleValue = eyes.leftMask }
            follow(rightMaskSlider, "eyes.right_mask") { rightMaskSlider.doubleValue = eyes.rightMask }
            showMaskValues()
        }
    }

    private func pendingText(_ pids: [String], _ describe: (String, EnvironmentPropertyValue) -> String) -> String {
        let parts = pids.compactMap { pid in queue.pendingValue(pid).map { describe(pid, $0) } }
        return parts.isEmpty ? "" : "\n" + L("Sending (not applied yet): ", "보내는 중 (아직 미적용): ") + parts.joined(separator: " · ")
    }

    private func render() {
        let applied = L("Applied: ", "적용됨: ")
        if let tp = temperature {
            temperatureApplied.stringValue = applied + String(format: "%.1f °C · ", tp.celsius) + EnvironmentWords.temperatureMode(tp.mode)
                + pendingText(["temperature.celsius", "temperature.mode"]) { pid, v in
                    if case .number(let c) = v, pid == "temperature.celsius" { return String(format: "%.1f °C", c) }
                    if case .choice(let m) = v { return EnvironmentWords.temperatureMode(m) }
                    return ""
                }
        } else if backend {
            temperatureApplied.stringValue = L("Waiting for the simulator's applied value…", "시뮬레이터의 적용값을 기다리는 중…")
        } else {
            temperatureApplied.stringValue = applied + String(format: "%.1f °C · ", localTemperature.celsius)
                + EnvironmentWords.temperatureMode(localTemperature.mode) + L(" (brain only, no physics simulator)", " (뇌 쪽만, 물리 시뮬레이터 없음)")
        }
        if let w = wind {
            let state: String
            if w.strength <= 0 { state = L("off", "꺼짐") }
            else if w.continuous { state = L("continuous", "계속 부는 중") }
            else { state = String(format: L("puff, %.0f ms left", "한 번 불기, %.0f ms 남음"), w.remainingMS ?? 0) }
            let flags = [w.physicalEnabled ? L("pushes body", "몸 밀기") : nil,
                         w.sensoryEnabled ? L("antenna sense", "더듬이 감각") : nil].compactMap { $0 }
            windApplied.stringValue = applied + String(format: L("strength %.2f · toward %.0f° · ", "세기 %.2f · 방향 %.0f° · "), w.strength, w.directionDeg)
                + state + " · " + (flags.isEmpty ? L("no effect enabled", "효과 모두 꺼짐") : flags.joined(separator: ", "))
                + pendingText(["wind.strength", "wind.direction_deg", "wind.physical", "wind.sensory"]) { pid, v in
                    switch (pid, v) {
                    case ("wind.strength", .number(let s)): return String(format: L("strength %.2f", "세기 %.2f"), s)
                    case ("wind.direction_deg", .number(let d)): return String(format: L("toward %.0f°", "방향 %.0f°"), d)
                    case (_, .boolean(let b)): return (pid == "wind.physical" ? L("push ", "몸 밀기 ") : L("sense ", "감각 ")) + (b ? L("on", "켬") : L("off", "끔"))
                    default: return ""
                    }
                }
        } else {
            windApplied.stringValue = backend ? L("Waiting for the simulator's applied value…", "시뮬레이터의 적용값을 기다리는 중…")
                : L("Wind needs the physics simulator.", "바람은 물리 시뮬레이터가 있어야 합니다.")
        }
        if let e = eyes {
            func eye(_ enabled: Bool, _ mask: Double) -> String {
                enabled ? String(format: L("%.0f%% covered", "%.0f%% 가림"), mask * 100) : L("disabled", "꺼짐")
            }
            lightApplied.stringValue = applied + L("left eye ", "왼쪽 눈 ") + eye(e.leftEnabled, e.leftMask)
                + L(" · right eye ", " · 오른쪽 눈 ") + eye(e.rightEnabled, e.rightMask)
                + pendingText(["eyes.left_mask", "eyes.right_mask"]) { pid, v in
                    guard case .number(let m) = v else { return "" }
                    return (pid == "eyes.left_mask" ? L("left ", "왼쪽 ") : L("right ", "오른쪽 ")) + String(format: "%.0f%%", m * 100)
                }
        } else {
            lightApplied.stringValue = backend ? L("Waiting for the simulator's applied value…", "시뮬레이터의 적용값을 기다리는 중…")
                : L("Eye covers need the physics simulator.", "눈 가리기는 물리 시뮬레이터가 있어야 합니다.")
        }
        let windControls = backend && wind != nil
        [windStrengthSlider, windStrengthField, windDirectionDial, windDirectionField, windPhysical,
         windSensory, windOnButton, windOffButton].forEach { $0.isEnabled = windControls && available }
        [leftMaskSlider, rightMaskSlider].forEach { $0.isEnabled = backend && eyes != nil && available }
        let temperatureEnabled = !backend || (temperature != nil && available)
        [temperatureSlider, temperatureField, temperatureMode].forEach { $0.isEnabled = temperatureEnabled }
        renderStatus()
    }

    /// A reset makes earlier replies and refusals describe a world that is gone.
    func clearFeedback() {
        localStatus = nil
        queue.clearMessage()
        renderStatus()
    }

    private func refuse(_ propertyID: String, _ text: String) {
        localStatus = (propertyID, text)
        renderStatus()
    }
    private func clearRefusal(_ propertyID: String) {
        if let local = localStatus, Self.section(local.propertyID) == Self.section(propertyID) { localStatus = nil }
    }

    private static func section(_ propertyID: String) -> Substring { propertyID.prefix { $0 != "." } }

    /// Each section shows only feedback about its own properties: a local
    /// refusal first, otherwise the queue's latest word on that section.
    private func renderStatus() {
        for (label, section) in [(temperatureStatus, "temperature"), (windStatus, "wind"), (lightStatus, "eyes")] {
            var text = "", error = false
            if let local = localStatus, Self.section(local.propertyID) == section {
                (text, error) = (local.text, true)
            } else if let pid = queue.messagePropertyID, Self.section(pid) == section {
                (text, error) = (queue.message, queue.isError)
            }
            label.stringValue = text
            label.isHidden = text.isEmpty
            label.textColor = error ? .systemRed : .secondaryLabelColor
        }
    }

    private func renderSample(_ t: LabTelemetry, body: FlyGymBodyFeedback?, state: LabRemoteState?) {
        var lines: [String] = []
        if let body {
            lines.append(String(format: L("At the fly  x %.1f · y %.1f mm · facing %.0f° · body t %.3f s (%.0f ms ago)",
                                          "파리 위치  x %.1f · y %.1f mm · 바라보는 방향 %.0f° · 몸 시각 %.3f s (%.0f ms 전)"),
                                body.positionXmm, body.positionYmm, Self.normalized(body.headingRad * 180 / .pi),
                                body.simTime, max(0, t.bodyPacketAgeS * 1000)))
        } else {
            lines.append(L("At the fly  no fresh body data — the values below are the brain side only",
                           "파리 위치  새 몸 데이터 없음 — 아래는 뇌 쪽 값만입니다"))
        }
        lines.append(String(format: L("Temperature  %.1f °C (%@) · receptor current warm %.3f / cool %.3f · TRN %.1f / %.1f Hz",
                                      "온도  %.1f °C (%@) · 감각 전류 따뜻 %.3f / 차가 %.3f · 온도 뉴런 %.1f / %.1f Hz"),
                            t.temperatureC, EnvironmentWords.temperatureMode(t.temperatureMode),
                            t.thermoWarmDrive, t.thermoCoolDrive, t.rateThermoWarm, t.rateThermoCool))
        if let body, body.windStrength > 0 {
            let rel = EnvironmentWords.windRelative(windDeg: body.windDirectionDeg, headingRad: body.headingRad)
            lines.append(String(format: L("Wind  strength %.2f toward %.0f° = %@ (%+.0f° from facing) · JO-C/E current %.3f / %.3f · %.1f / %.1f Hz",
                                          "바람  세기 %.2f, %.0f° 쪽 = 파리 기준 %@ (%+.0f°) · 더듬이 전류 C %.3f / E %.3f · %.1f / %.1f Hz"),
                                body.windStrength, body.windDirectionDeg, rel.text, rel.degrees,
                                t.windCDrive, t.windEDrive, t.rateWindC, t.rateWindE))
        } else {
            lines.append(String(format: L("Wind  none at the fly · JO-C/E current %.3f / %.3f", "바람  파리 위치에 없음 · 더듬이 전류 C %.3f / E %.3f"),
                                t.windCDrive, t.windEDrive))
        }
        let eyeTick = t.bodyEyeSampleSimTick >= 0 ? "t\(t.bodyEyeSampleSimTick)" : L("none", "없음")
        lines.append(String(format: L("Light  eye brightness L %.2f / R %.2f (eye image %@) · flash %.2f / %.2f",
                                      "빛  눈 밝기 왼 %.2f / 오 %.2f (눈 영상 %@) · 번쩍임 %.2f / %.2f"),
                            t.bodyBrightnessL, t.bodyBrightnessR, eyeTick, t.bodyFlashL, t.bodyFlashR))
        let nearest = t.bodyNearestFoodDistanceMm >= 0 ? String(format: "%.1f mm", t.bodyNearestFoodDistanceMm) : L("no food", "먹이 없음")
        lines.append(String(format: L("Food  odor L %.3f / R %.3f · nearest %@ · taste sugar %.2f · ORN %.1f / %.1f Hz",
                                      "먹이  냄새 왼 %.3f / 오 %.3f · 가장 가까운 먹이 %@ · 맛(당) %.2f · 후각 뉴런 %.1f / %.1f Hz"),
                            t.bodyOdorL, t.bodyOdorR, nearest, t.bodyTasteSugar, t.rateFoodOdorL, t.rateFoodOdorR))
        sample.stringValue = lines.joined(separator: "\n")
        sample.textColor = body == nil ? .systemOrange : .secondaryLabelColor

        let objects = state?.authoritativeObjects ?? []
        let foods = objects.filter { $0.shape == "food" }
        let capacity = state?.authoritativeSlotCapacity?["food"]
        let names = foods.map { $0.foodVariant.map(LabToy.foodName) ?? $0.id }
        foodSummary.stringValue = (capacity.map { L("Food \(foods.count) of \($0)", "먹이 \(foods.count)/\($0)개") }
                                   ?? L("Food \(foods.count)", "먹이 \(foods.count)개"))
            + (names.isEmpty ? "" : " — " + names.joined(separator: ", "))
    }

    private func showMaskValues() {
        leftMaskValue.stringValue = String(format: "%.0f%%", leftMaskSlider.doubleValue * 100)
        rightMaskValue.stringValue = String(format: "%.0f%%", rightMaskSlider.doubleValue * 100)
    }

    private func select(_ popup: NSPopUpButton, _ value: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) { popup.select(item) }
    }
}

private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
