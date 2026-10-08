import Cocoa

/// V6.5 environment panel: applied-state decoding, the bounded send queue,
/// ACK matching, dial geometry and the AppKit panel. Headless, no listener.
func runEnvironmentPanelChecks(_ check: (String, Bool) -> Void, caps: EnvironmentCapabilities) {
    func decodeWorld(_ json: String) -> LabRemoteWorldState? {
        try? JSONDecoder().decode(LabRemoteWorldState.self, from: Data(json.utf8))
    }
    let applied = decodeWorld("""
        {"environment_revision": 7,
         "wind": {"strength": 0.4, "direction_deg": 270.0, "continuous": true, "remaining_ms": null,
                  "physical_enabled": false, "sensory_enabled": true, "classification": "PHYSICAL"},
         "temperature": {"celsius": 31.5, "mode": "flywire_sensory", "neural_connected": true},
         "eyes": {"left_enabled": true, "right_enabled": true, "left_mask": 0.25, "right_mask": 0.0}}
        """)
    check("V6.5 applied wind/temperature/eyes decode",
          applied?.wind == LabRemoteWind(strength: 0.4, directionDeg: 270, continuous: true, remainingMS: nil,
                                         physicalEnabled: false, sensoryEnabled: true)
          && applied?.temperature == LabRemoteTemperature(celsius: 31.5, mode: "flywire_sensory")
          && applied?.eyes?.leftMask == 0.25 && applied?.environmentRevision == 7)
    let partial = decodeWorld("""
        {"environment_revision": 2, "wind": {"strength": "strong"}, "temperature": {"celsius": 20, "mode": "environment_only"}}
        """)
    check("V6.5 malformed wind block drops only the wind",
          partial != nil && partial?.wind == nil && partial?.temperature?.celsius == 20)

    let identity = WorldEditorIdentity(generation: 4, sessionID: "env", epoch: 2)
    let schedule = LabCommandSchedule(sessionID: "env", epoch: 2, requestedTick: 40)
    func ack(_ id: Int, _ property: String, revision: Int, actual: Any = 30.0, ok: Bool = true,
             status: String = "applied", current: Int? = nil) -> LabAck {
        var a = LabAck(id: id, ok: ok, action: "edit_property", message: ok ? "applied" : status,
                       appliedTick: ok ? 41 : nil, appliedEpoch: ok ? 2 : nil, status: ok ? "applied" : status,
                       sessionID: "env", epoch: 2)
        a.connectionGeneration = 4
        var result: [String: Any] = ["ok": ok, "status": status, "property_id": property, "target_id": NSNull()]
        if ok { result["revision"] = revision; result["actual_value"] = actual }
        else { result["path"] = "edit.expected_revision"; result["reason"] = status }
        if let current { result["current_revision"] = current }
        a.edit = try! JSONDecoder().decode(EnvironmentEditResult.self,
                                           from: JSONSerialization.data(withJSONObject: result))
        return a
    }
    func request(_ q: inout EnvironmentSettingQueue, _ c: Double, _ property: String = "temperature.celsius") {
        q.request(EnvironmentSettingRequest(propertyID: property, value: .number(c)))
    }

    // V6-03: a fast 100-step drag sends a bounded number of edits and ends on the last value.
    var q = EnvironmentSettingQueue()
    q.observe(revision: 5, identity: identity)
    var sent: [EnvironmentEdit] = []
    var maxWaiting = 0
    var nextID = 1
    func pump(_ q: inout EnvironmentSettingQueue) {
        if let edit = q.next(capabilities: caps) { sent.append(edit); q.began(commandID: nextID, schedule: schedule, edit: edit); nextID += 1 }
    }
    for step in 0..<100 {
        request(&q, 10 + Double(step) * 0.3)
        maxWaiting = max(maxWaiting, q.waiting.count)
        pump(&q)
        if step == 60, let p = q.inFlight {   // the first edit's ACK arrives mid-drag
            q.accept(ack(p.commandID, "temperature.celsius", revision: p.expectedRevision + 1)); pump(&q)
        }
    }
    while let p = q.inFlight {
        q.accept(ack(p.commandID, "temperature.celsius", revision: p.expectedRevision + 1)); pump(&q)
    }
    let last = 10 + 99 * 0.3
    check("V6-03 100 slider steps -> \(sent.count) edits, waiting <= 1, final value is the last step",
          sent.count == 3 && maxWaiting <= 1 && sent.last?.value == .number(last) && !q.isBusy && !q.isError)
    check("V6-03 each edit chains on the previous ACK revision",
          sent.map(\.expectedRevision) == [5, 6, 7] && q.revision == 8)

    // Matching: other ids, connections and sessions never complete the edit.
    q = EnvironmentSettingQueue(); q.observe(revision: 5, identity: identity)
    request(&q, 30); pump(&q)
    let inflight = q.inFlight!.commandID
    var other = ack(inflight + 1, "temperature.celsius", revision: 6); _ = q.accept(other)
    other = ack(inflight, "temperature.celsius", revision: 6); other.connectionGeneration = 5; _ = q.accept(other)
    other = ack(inflight, "temperature.celsius", revision: 6); other.sessionID = "old"; _ = q.accept(other)
    check("V6.5 mismatched ACKs leave the edit in flight", q.inFlight?.commandID == inflight)
    for malformed in 0..<4 {
        var m = EnvironmentSettingQueue(); m.observe(revision: 5, identity: identity)
        request(&m, 30); pump(&m)
        var a = ack(m.inFlight!.commandID, "temperature.celsius", revision: malformed == 0 ? 5 : 6)
        if malformed == 1 { a = ack(m.inFlight!.commandID, "temperature.mode", revision: 6) }
        if malformed == 2 { a.appliedTick = 39 }
        if malformed == 3 { a.appliedEpoch = 1 }
        request(&m, 31)
        m.accept(a)
        check("V6.5 unconfirming ACK \(malformed) is an error and drops waiting values",
              m.isError && !m.isBusy && m.next(capabilities: caps) == nil)
    }

    // Stale and busy rejections are reported, waiting values dropped, never retried.
    q = EnvironmentSettingQueue(); q.observe(revision: 5, identity: identity)
    request(&q, 30); pump(&q); request(&q, 32)
    q.accept(ack(q.inFlight!.commandID, "temperature.celsius", revision: 0, ok: false,
                 status: "rejected_stale_revision", current: 9))
    let afterStale = q.next(capabilities: caps)
    check("V6.5 stale rejection: error, waiting dropped, no silent retry, revision refreshed",
          q.isError && afterStale == nil && q.revision == 9 && q.message.contains(L("changed first", "바뀌었습니다")))
    q = EnvironmentSettingQueue(); q.observe(revision: 5, identity: identity)
    request(&q, 0.3, "wind.strength"); pump(&q)
    q.accept(ack(q.inFlight!.commandID, "wind.strength", revision: 0, ok: false, status: "rejected_busy"))
    check("V6.5 busy puff rejection explained", q.isError && q.message.contains(L("puff", "시간 제한 바람")))

    // Timeout and session change discard instead of guessing.
    q = EnvironmentSettingQueue(); q.observe(revision: 5, identity: identity)
    request(&q, 30); pump(&q)
    q.observe(revision: 5, identity: identity, now: Date().addingTimeInterval(9))
    check("V6.5 no ACK within 8 s: discarded as unknown", !q.isBusy && q.isError)
    q = EnvironmentSettingQueue(); q.observe(revision: 5, identity: identity)
    request(&q, 30); pump(&q); request(&q, 31)
    q.observe(revision: 0, identity: WorldEditorIdentity(generation: 4, sessionID: "env", epoch: 3))
    check("V6.5 new session discards in-flight and waiting edits", !q.isBusy && q.isError && q.revision == 0)
    q = EnvironmentSettingQueue(); q.observe(revision: 8, identity: identity); q.observe(revision: 6, identity: identity)
    check("V6.5 an older lab_state never lowers the known revision", q.revision == 8)
    q = EnvironmentSettingQueue(); q.observe(revision: 5, identity: identity)
    request(&q, 55); let invalid = q.next(capabilities: caps)
    check("V6.5 out-of-range request rejected before sending", invalid == nil && q.isError && q.inFlight == nil)

    // Dial: knob points where the wind blows in a top-down view (+X right, +Y up).
    let roundTrip = stride(from: 0.0, to: 360, by: 15).allSatisfy {
        abs(EnvironmentPanel.worldDeg(dialValue: EnvironmentPanel.dialValue(worldDeg: $0)) - $0) < 1e-9 }
    check("V6.5 dial mapping: +X at the right (90), +Y at the top (0), round trip",
          EnvironmentPanel.dialValue(worldDeg: 0) == 90 && EnvironmentPanel.dialValue(worldDeg: 90) == 0
          && EnvironmentPanel.dialValue(worldDeg: 180) == 270 && roundTrip)
    let tail = EnvironmentWords.windRelative(windDeg: 90, headingRad: .pi / 2)
    let fromLeft = EnvironmentWords.windRelative(windDeg: 0, headingRad: .pi / 2)
    let headOn = EnvironmentWords.windRelative(windDeg: 0, headingRad: .pi)
    check("V6.5 wind relative to the fly: tail, toward its right, head-on",
          abs(tail.degrees) < 1e-9 && abs(fromLeft.degrees + 90) < 1e-9 && abs(abs(headOn.degrees) - 180) < 1e-9
          && tail.text == L("forward (from behind)", "앞쪽으로 (뒤에서 붊)")
          && fromLeft.text == L("to its right (from its left)", "오른쪽으로 (왼쪽에서 붊)"))

    runEnvironmentPanelAppKitChecks(check, caps: caps, identity: identity, schedule: schedule, ack: ack)
}

private func runEnvironmentPanelAppKitChecks(
    _ check: (String, Bool) -> Void, caps: EnvironmentCapabilities, identity: WorldEditorIdentity,
    schedule: LabCommandSchedule,
    ack: (Int, String, Int, Any, Bool, String, Int?) -> LabAck) {
    func state(revision: Int, celsius: Double, wind: Double, puff: Bool = false) -> LabRemoteState {
        var s = try! JSONDecoder().decode(LabRemoteState.self, from: Data("""
            {"type": "lab_state", "state": {"environment_revision": \(revision),
             "wind": {"strength": \(wind), "direction_deg": 0, "continuous": \(!puff && wind > 0), "remaining_ms": \(puff ? "250" : "null"),
                      "physical_enabled": true, "sensory_enabled": true},
             "temperature": {"celsius": \(celsius), "mode": "environment_only"},
             "eyes": {"left_enabled": true, "right_enabled": true, "left_mask": 0, "right_mask": 0}}}
            """.utf8))
        s.worldState?.environmentCapabilities = caps
        return s
    }
    let panel = EnvironmentPanel()
    panel.configure()
    var sent: [LabCommand] = []
    panel.onSubmit = { command, captured in
        guard captured == identity else { return nil }
        sent.append(command); return (100 + sent.count, schedule)
    }
    let telemetry = LabTelemetry()
    func update(_ s: LabRemoteState?, backend: Bool = true, now: Date = Date()) {
        panel.update(state: s, telemetry: telemetry, body: nil, identity: backend ? identity : nil,
                     backendConnected: backend, available: backend, now: now)
    }
    func drag(_ slider: NSSlider, _ value: Double) {
        slider.doubleValue = value
        NSApp.sendAction(slider.action!, to: slider.target, from: slider)
    }
    update(state(revision: 3, celsius: 25, wind: 0))
    check("V6.5 panel shows the backend's applied temperature", panel.temperatureApplied.stringValue.contains("25.0 °C"))
    for step in 0..<100 { drag(panel.temperatureSlider, 10 + Double(step) * 0.3) }
    check("V6.5 panel drag: one edit in flight, draft not shown as applied",
          sent.count == 1 && panel.temperatureApplied.stringValue.contains("25.0 °C")
          && panel.temperatureApplied.stringValue.contains(L("Sending", "보내는 중")))
    var a = ack(101, "temperature.celsius", 4, 10.0, true, "applied", nil)
    panel.accept(a)
    let final = sent.last?.edit
    check("V6.5 panel ACK sends the newest drag value on the ACK revision",
          sent.count == 2 && final?.expectedRevision == 4 && final?.value == .number(39.5))
    a = ack(102, "temperature.celsius", 5, 39.5, true, "applied", nil)
    panel.accept(a)
    update(state(revision: 5, celsius: 39.5, wind: 0), now: Date().addingTimeInterval(2))
    check("V6.5 panel settles on the applied value",
          panel.temperatureSlider.doubleValue == 39.5 && !panel.temperatureApplied.stringValue.contains(L("Sending", "보내는 중")))
    update(state(revision: 6, celsius: 18, wind: 0), now: Date().addingTimeInterval(3))
    check("V6.5 untouched control follows a backend change (e.g. reset)", panel.temperatureSlider.doubleValue == 18)

    // Wind: a strength drag edits the continuous wind; the dial sends world degrees.
    let before = sent.count
    drag(panel.windStrengthSlider, 0.35)
    check("V6.5 wind strength drag sends wind.strength", sent.count == before + 1
          && sent.last?.edit?.propertyID == "wind.strength" && sent.last?.edit?.value == .number(0.35))
    panel.accept(ack(100 + sent.count, "wind.strength", 7, 0.35, true, "applied", nil))
    drag(panel.windDirectionDial, 0)   // knob at the top = toward +Y
    check("V6.5 dial at the top sends direction 90 (+Y)", sent.last?.edit?.propertyID == "wind.direction_deg"
          && sent.last?.edit?.value == .number(90))
    check("V6.5 Stop wind is left to the window (a legacy stop works during puffs)", panel.windOffButton.action == nil)

    // Feedback stays with its own section (GUI F02): a busy wind rejection
    // must not reappear under temperature, nor hide a typed range error.
    panel.accept(ack(100 + sent.count, "wind.direction_deg", 8, 90.0, true, "applied", nil))
    drag(panel.windStrengthSlider, 0.5)
    panel.accept(ack(100 + sent.count, "wind.strength", 0, 0, false, "rejected_busy", nil))
    let busyText = panel.windStatus.stringValue
    panel.temperatureField.stringValue = "50"
    NSApp.sendAction(panel.temperatureField.action!, to: panel.temperatureField.target, from: panel.temperatureField)
    let sentAfterTyping = sent.count
    update(state(revision: 8, celsius: 18, wind: 0.35), now: Date().addingTimeInterval(4))
    check("V6.5 range error stays under temperature across refreshes; busy stays under wind",
          !panel.temperatureStatus.isHidden && panel.temperatureStatus.stringValue.contains("10")
          && panel.temperatureStatus.stringValue.contains("40") && !busyText.isEmpty
          && panel.windStatus.stringValue == busyText && sentAfterTyping == sent.count)
    panel.clearFeedback()
    check("V6.5 reset clears earlier replies and refusals",
          panel.temperatureStatus.isHidden && panel.windStatus.isHidden && panel.lightStatus.isHidden)

    // Eye covers follow the backend even when the wind block is missing or malformed.
    var eyesOnly = try! JSONDecoder().decode(LabRemoteState.self, from: Data("""
        {"type": "lab_state", "state": {"environment_revision": 9,
         "eyes": {"left_enabled": true, "right_enabled": true, "left_mask": 1.0, "right_mask": 0.5}}}
        """.utf8))
    eyesOnly.worldState?.environmentCapabilities = caps
    let eyePanel = EnvironmentPanel()
    eyePanel.configure()
    eyePanel.update(state: eyesOnly, telemetry: telemetry, body: nil, identity: identity,
                    backendConnected: true, available: true)
    check("V6.5 eye covers follow the backend without a wind block",
          eyePanel.leftMaskSlider.doubleValue == 1.0 && eyePanel.rightMaskSlider.doubleValue == 0.5
          && eyePanel.leftMaskValue.stringValue == "100%" && eyePanel.leftMaskSlider.isEnabled
          && !eyePanel.windStrengthSlider.isEnabled)

    // Paused: the last body packet is shown as paused, not as missing data.
    let pausedBody = FlyGymBodyFeedback(try! JSONDecoder().decode(FlyGymBodyPacket.self, from: Data("""
        {"type": "body", "t": 7.25, "position_x_mm": 4.0, "position_y_mm": 2.0, "heading_rad": 0.0}
        """.utf8)))
    eyePanel.update(state: eyesOnly, telemetry: telemetry, body: pausedBody, bodyPaused: true,
                    identity: identity, backendConnected: true, available: true)
    let pausedText = eyePanel.sample.stringValue
    eyePanel.update(state: eyesOnly, telemetry: telemetry, body: nil, identity: identity,
                    backendConnected: true, available: true)
    check("V6.6 paused body sample says paused, not missing",
          pausedText.contains("7.250") && pausedText.contains(L("(paused)", "(일시정지)"))
          && !pausedText.contains(L("no fresh body data", "새 몸 데이터 없음"))
          && eyePanel.sample.stringValue.contains(L("no fresh body data", "새 몸 데이터 없음")))

    // Without a physics backend: temperature applies on the brain side only, wind/eyes are disabled.
    let noBackend = EnvironmentPanel()
    noBackend.configure()
    var noBackendSent = 0
    noBackend.onSubmit = { _, _ in noBackendSent += 1; return nil }
    var localCalls: [(Double, String)] = []
    noBackend.onLocalTemperature = { localCalls.append(($0, $1)) }
    noBackend.update(state: nil, telemetry: telemetry, body: nil, identity: nil, backendConnected: false, available: false)
    noBackend.temperatureSlider.doubleValue = 30
    NSApp.sendAction(noBackend.temperatureSlider.action!, to: noBackend.temperatureSlider.target, from: noBackend.temperatureSlider)
    check("V6.5 no backend: temperature applies locally, nothing sent, wind and eyes disabled",
          noBackendSent == 0 && localCalls.last?.0 == 30 && !noBackend.windStrengthSlider.isEnabled
          && !noBackend.leftMaskSlider.isEnabled && noBackend.temperatureSlider.isEnabled)
}

/// `--envpanelshot DIR`: PNGs of the environment page (en/ko, light/dark)
/// with a sample owner state: wind toward +Y, left eye covered, one cheese.
func runEnvironmentPanelShot(directory: String) {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    guard let manifest = try? Data(contentsOf: root.appendingPathComponent("fixtures/environment_capabilities/valid.json")),
          let caps = String(data: manifest, encoding: .utf8) else { print("FAIL fixture"); exit(1) }
    let stateJSON = """
        {"type": "lab_state", "state": {"environment_revision": 12, "environment_capabilities": \(caps),
         "objects": [{"id": "food_1", "shape": "food", "position_mm": [20, 0, 1.5], "size_mm": [3, 3, 3],
                      "yaw_deg": 0, "food_variant": "cheese", "revision": 1}],
         "slot_capacity": {"food": 8}, "slot_free": {"food": 7},
         "wind": {"strength": 0.6, "direction_deg": 90, "continuous": true, "remaining_ms": null,
                  "physical_enabled": true, "sensory_enabled": true},
         "temperature": {"celsius": 31.5, "mode": "flywire_sensory"},
         "eyes": {"left_enabled": true, "right_enabled": true, "left_mask": 1.0, "right_mask": 0.0}}}
        """
    let bodyJSON = """
        {"type": "body", "t": 12.43, "wind_strength": 0.6, "wind_direction_deg": 90, "wind_sensory": true,
         "position_x_mm": 3.2, "position_y_mm": -1.4, "heading_rad": 0.0, "brightness_left": 0, "brightness_right": 0.27,
         "odor_left": 0.31, "odor_right": 0.12, "nearest_food_distance_mm": 20.1}
        """
    guard let state = try? JSONDecoder().decode(LabRemoteState.self, from: Data(stateJSON.utf8)),
          state.worldState?.environmentCapabilities != nil,
          let packet = try? JSONDecoder().decode(FlyGymBodyPacket.self, from: Data(bodyJSON.utf8)) else {
        print("FAIL sample state"); exit(1)
    }
    let body = FlyGymBodyFeedback(packet)
    var ok = true
    for language in [LabLanguage.english, .korean] {
        LabLanguage.pinForTests(language)
        for dark in [false, true] {
            let controller = LabWindowController(coordinator: Coordinator(bounds: CGSize(width: 800, height: 600), sim: nil),
                                                 bridge: nil)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("environment-\(language.rawValue)-\(dark ? "dark" : "light").png")
            let written = controller.renderEnvironmentPage(state: state, body: body, dark: dark, to: url)
            print((written ? "WROTE " : "FAIL ") + url.path)
            ok = ok && written
        }
    }
    exit(ok ? 0 : 1)
}
