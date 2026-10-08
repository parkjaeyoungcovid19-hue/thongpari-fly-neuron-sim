// LabDiagnostics.swift — `--labtest`: headless Virtual Fly Lab protocol,
// presentation and input checks (no socket, no backend).
import Foundation
import Cocoa
import SceneKit

/// Headless lab protocol test. No socket is opened; queue behavior, tolerant
/// state parsing and direct-neural population selection are exercised directly.
func runLabTest() {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS" : "FAIL") + "  " + name + (detail.isEmpty ? "" : ": " + detail))
        if !ok { failures += 1 }
    }

    let bridge = FlyGymBridge()
    for i in 0..<100 {
        _ = bridge.sendLab(action: "move_object", target: "box", x: Double(i), y: 0, z: 5)
    }
    check("lab command queue bounded", bridge.pendingLabDepth() == 32,
          "depth=\(bridge.pendingLabDepth()) dropped=\(bridge.labDropped)")
    check("lab queue drops oldest", bridge.labDropped == 68, "dropped=\(bridge.labDropped)")

    let stateLine = #"{"type":"lab_state","t":1.25,"ack":7,"ok":false,"error":"bad target","object_count":1,"state":{"objects":[{"id":"wall_1","shape":"wall","position_mm":[12.0,-3.0,7.5],"size_mm":[2.0,30.0,15.0],"yaw_deg":15.0}],"slot_capacity":{"box":64,"sphere":64,"wall":64,"food":32},"slot_free":{"box":64,"sphere":64,"wall":63,"food":32}},"temperature":27.0,"wind":0.4,"left_eye_covered":true,"right_eye_covered":false}"#
    let state = parseLabStateLine(Data(stateLine.utf8))
    let wallState = state?.authoritativeObjects?.first
    check("lab_state parse", state?.ack == 7 && state?.ok == false && state?.error == "bad target"
          && state?.objectCount == 1 && state?.leftEyeCovered == true && state?.rightEyeCovered == false
          && wallState?.id == "wall_1" && wallState?.shape == "wall"
          && wallState?.positionMM == [12.0, -3.0, 7.5]
          && wallState?.sizeMM == [2.0, 30.0, 15.0]
          && abs((wallState?.yawDeg ?? -999) - 15.0) < 1e-9
          && state?.authoritativeSlotCapacity?["wall"] == 64
          && state?.authoritativeSlotFree?["wall"] == 63)
    check("lab_state type gate", parseLabStateLine(Data(#"{"type":"body","ack":7}"#.utf8)) == nil)
    runEnvironmentCapabilityChecks(check)
    runEnvironmentEditChecks(check)
    func wire(_ command: LabCommand) -> [String: Any] {
        let data = try! JSONEncoder().encode(command)
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }
    let grab = LabCommand.interaction(id: 71, toolID: "grab", actorID: "player",
                                      rayOriginMM: [1, 2, 3], rayDirection: [1, 0, 0],
                                      protocolVersion: 4, sessionID: "s", epoch: 1,
                                      requestedTick: 42)
    let place = LabCommand.interaction(id: 72, toolID: "place", actorID: "player",
                                       target: "box_1", protocolVersion: 4,
                                       sessionID: "s", epoch: 1, requestedTick: 43)
    let grabWire = grab.map(wire) ?? [:]
    let placeWire = place.map(wire) ?? [:]
    check("V5.6 grab/place flat wire and V4 envelope",
          grabWire["action"] as? String == "interaction"
          && grabWire["tool_id"] as? String == "grab"
          && grabWire["actor_id"] as? String == "player"
          && grabWire["ray_origin_mm"] as? [Double] == [1, 2, 3]
          && grabWire["ray_direction"] as? [Double] == [1, 0, 0]
          && grabWire["requested_tick"] as? Int == 42
          && placeWire["tool_id"] as? String == "place"
          && placeWire["target"] as? String == "box_1"
          && placeWire["ray_origin_mm"] == nil && placeWire["ray_direction"] == nil)
    check("V5.6 command constructor rejects bad ray and place ray",
          LabCommand.interaction(id: 1, toolID: "grab", actorID: "player",
                                 rayOriginMM: [0, 0, 0], rayDirection: [0, 0, 0]) == nil
          && LabCommand.interaction(id: 1, toolID: "grab", actorID: "player",
                                    rayOriginMM: [0, .nan, 0], rayDirection: [1, 0, 0]) == nil
          && LabCommand.interaction(id: 1, toolID: "place", actorID: "player",
                                    rayOriginMM: [0, 0, 0]) == nil)
    let interactionBridge = FlyGymBridge()
    let queuedGrabID = interactionBridge.sendInteraction(
        toolID: "grab", actorID: "player", rayOriginMM: [1, 2, 3],
        rayDirection: [1, 0, 0], protocolVersion: 4,
        sessionID: "interactive-session", epoch: 2, requestedTick: 90)
    let queuedGrab = interactionBridge.dequeueSendForTesting(at: Date())
    let queuedGrabWire = queuedGrab.flatMap { try? JSONSerialization.jsonObject(with: $0.1) as? [String: Any] } ?? [:]
    check("bridge interaction uses lab queue and interactive V4 envelope",
          queuedGrabID != nil && queuedGrab?.0 == .lab
          && queuedGrabWire["id"] as? Int == queuedGrabID
          && queuedGrabWire["tool_id"] as? String == "grab"
          && queuedGrabWire["session_id"] as? String == "interactive-session"
          && queuedGrabWire["epoch"] as? Int == 2
          && queuedGrabWire["requested_tick"] as? Int == 90)
    let oldWire = wire(LabCommand(id: 73, action: "move_object", target: "box_1", x: 2))
    check("legacy LabCommand wire has no interaction keys",
          oldWire["action"] as? String == "move_object"
          && oldWire["target"] as? String == "box_1"
          && oldWire["x"] as? Double == 2
          && oldWire["tool_id"] == nil && oldWire["actor_id"] == nil
          && oldWire["ray_origin_mm"] == nil && oldWire["ray_direction"] == nil)

    let validInteraction = parseLabStateLine(Data(#"{"type":"lab_state","interaction":{"held_object_id":"box_1","carry_blocked":true,"reach_mm":12.0}}"#.utf8))
    let nullHeld = parseLabStateLine(Data(#"{"type":"lab_state","interaction":{"held_object_id":null,"carry_blocked":false,"reach_mm":12.0}}"#.utf8))
    let malformedBlocks = [
        #"{"carry_blocked":false,"reach_mm":12}"#,
        #"{"held_object_id":7,"carry_blocked":false,"reach_mm":12}"#,
        #"{"held_object_id":null,"carry_blocked":"false","reach_mm":12}"#,
        #"{"held_object_id":null,"carry_blocked":false,"reach_mm":0}"#,
        #"{"held_object_id":null,"carry_blocked":false,"reach_mm":-1}"#,
        #"{"held_object_id":null,"carry_blocked":false}"#
    ]
    let malformedStates = malformedBlocks.map {
        parseLabStateLine(Data("{\"type\":\"lab_state\",\"object_count\":3,\"interaction\":\($0)}".utf8))
    }
    check("interaction strict optional decode and old backend contrast",
          validInteraction?.interaction?.heldObjectID == "box_1"
          && validInteraction?.interaction?.carryBlocked == true
          && validInteraction?.interaction?.reachMM == 12
          && nullHeld?.interaction?.heldObjectID == nil
          && state?.interaction == nil
          && malformedStates.allSatisfy { $0?.interaction == nil && $0?.objectCount == 3 })
    var interactionUI = LabInteractionPresentation()
    check("old or malformed backend disables interaction and says unknown",
          !interactionUI.canSend(participating: true, captured: true, focused: true,
                                 hasInteractionState: state?.interaction != nil)
          && interactionUI.line(state: nil) == L("Interaction state unknown", "상호작용 상태 알 수 없음"))
    interactionUI.begin(id: 71, generation: 4)
    check("pending interaction prevents a duplicate E command",
          !interactionUI.canSend(participating: true, captured: true, focused: true,
                                 hasInteractionState: true)
          && interactionUI.line(state: nullHeld?.interaction).contains("Waiting"))
    var accepted = LabAck(); accepted.id = 71; accepted.ok = true
    accepted.connectionGeneration = 4
    interactionUI.accept(ack: accepted)
    check("successful interaction ACK clears pending",
          interactionUI.pendingID == nil && interactionUI.rejection == nil
          && interactionUI.canSend(participating: true, captured: true, focused: true,
                                    hasInteractionState: true))
    let pendingAt = Date(timeIntervalSince1970: 100)
    interactionUI.begin(id: 72, generation: 4, at: pendingAt)
    interactionUI.expire(at: pendingAt.addingTimeInterval(LabCommandTimeline.ackTimeout + 0.01))
    check("lost interaction ACK releases pending gate with timeout status",
          interactionUI.pendingID == nil
          && interactionUI.line(state: nullHeld?.interaction).contains("response timed out"))
    let rejectCodes = ["invalid_interaction", "not_participating", "wrong_actor",
                       "ray_origin_not_at_participant", "ray_miss", "unsupported_target",
                       "out_of_reach", "target_mismatch", "already_holding", "not_holding"]
    var rejectedLines: [String] = []
    for (index, code) in rejectCodes.enumerated() {
        interactionUI.begin(id: index + 100, generation: 4)
        var rejected = LabAck(); rejected.id = index + 100; rejected.ok = false
        rejected.message = code == "out_of_reach" ? "out_of_reach: 17.3mm" : code
        rejected.connectionGeneration = 4
        interactionUI.accept(ack: rejected)
        rejectedLines.append(interactionUI.line(state: nullHeld?.interaction))
    }
    check("all ten interaction rejection codes have user text",
          rejectedLines.count == 10 && rejectedLines.allSatisfy { $0.hasPrefix("Rejected: ")
            && !$0.contains("request rejected") }
          && rejectedLines[6].contains("12.0 mm") && rejectedLines[6].contains("17.3mm"))
    let testDefaults = UserDefaults(suiteName: "SiliconFly.V5.6.Tests.\(UUID().uuidString)")!
    let keyController = PlayerController(defaults: testDefaults)
    _ = keyController.setCaptureEnabled(true)
    let firstE = keyController.handleKeyDown(keyCode: 14, isRepeat: false)
    let freshE = keyController.freshInteractPress
    let repeatE = keyController.handleKeyDown(keyCode: 14, isRepeat: true)
    let repeatFresh = keyController.freshInteractPress
    let duplicateE = keyController.handleKeyDown(keyCode: 14, isRepeat: false)
    _ = keyController.handleKeyUp(keyCode: 14)
    let secondE = keyController.handleKeyDown(keyCode: 14, isRepeat: false)
    check("E physical key press is one command; repeat and duplicate down ignored",
          firstE != nil && freshE && repeatE == nil && !repeatFresh
          && duplicateE == nil && secondE != nil && keyController.freshInteractPress)
    var waitingUI = LabInteractionPresentation()
    waitingUI.begin(id: 71, generation: 4)
    let blockedBridge = FlyGymBridge()
    if secondE != nil && keyController.freshInteractPress && waitingUI.canAttempt() {
        _ = blockedBridge.sendInteraction(toolID: "grab", actorID: "player",
                                          rayOriginMM: [0, 0, 1], rayDirection: [1, 0, 0])
    }
    check("second E while pending shows reason and queues no interaction command",
          blockedBridge.dequeueSendForTesting(at: Date()) == nil
          && waitingUI.line(state: nullHeld?.interaction)
              == L("Waiting — previous request response pending", "대기 중 — 이전 요청 응답 기다리는 중"))
    waitingUI.ignore(.waitingForState)
    check("missing interaction state shows ignored E reason",
          waitingUI.line(state: nil)
              == L("Interaction not ready — waiting for world state", "상호작용 준비 안 됨 — 세계 상태 수신 대기"))
    waitingUI.ignore(.waitingForSession)
    check("inactive session shows ignored E reason",
          waitingUI.line(state: nullHeld?.interaction)
              == L("Interaction not ready — waiting for active session", "상호작용 준비 안 됨 — 세션 활성화 대기"))
    check("text focus, non-participation and pending all suppress E",
          !interactionUI.canSend(participating: true, captured: true, focused: false,
                                 hasInteractionState: true)
          && !interactionUI.canSend(participating: false, captured: true, focused: true,
                                    hasInteractionState: true)
          && PlayerInputFocusPolicy.allowsCapture(windowIsKey: true,
                                                   firstResponder: NSTextField(string: ""),
                                                   viewer: WorldViewer(frame: .zero)) == false)
    let event = parseLabEventLine(Data(#"{"type":"lab_event","event":"approach_complete","data":{"id":"x"}}"#.utf8))
    check("lab_event parse", event?.event == "approach_complete")
    let contact = parseLabEventLine(Data(#"{"type":"lab_event","event":"object_contact_end","data":{"id":"box_1","fly_segment":"thorax","peak_normal_force":0.25,"duration_ms":14,"sim_tick_ms":1200,"force_units":"mujoco_model","classification":"PHYSICAL"}}"#.utf8))
    let badDetail = parseLabEventLine(Data(#"{"type":"lab_event","event":"object_placed","data":{"id":7,"sim_tick_ms":"x"}}"#.utf8))
    check("V5.6 lab_event detail decode; malformed detail keeps the event",
          contact?.detail?.id == "box_1" && contact?.detail?.flySegment == "thorax"
          && contact?.detail?.peakNormalForce == 0.25 && contact?.detail?.durationMS == 14
          && contact?.detail?.simTickMS == 1200
          && contact?.detail?.summary.contains("@1200 ms") == true
          && badDetail?.event == "object_placed" && badDetail?.detail == nil,
          contact?.detail?.summary ?? "nil")
    let feedingEnd = parseLabEventLine(Data(#"{"type":"lab_event","event":"feeding_end","data":{"id":"gui_capacity6","reason":"food deleted","contact_s":0.02,"sim_tick_ms":20}}"#.utf8))
    check("lab_event recorder line keeps the raw event name and wire fields",
          contact?.recordDetail == "object_contact_end id=box_1 fly_segment=thorax peak_normal_force=0.25 force_units=mujoco_model duration_ms=14 sim_tick_ms=1200"
          && feedingEnd?.recordDetail == "feeding_end id=gui_capacity6 contact_s=0.02 sim_tick_ms=20 reason=food deleted"
          && badDetail?.recordDetail == "object_placed",
          feedingEnd?.recordDetail ?? "nil")
    let speedState = parseLabStateLine(Data(#"{"type":"lab_state","interaction":{"held_object_id":null,"carry_blocked":false,"reach_mm":12,"carry_speed_mm_s":40}}"#.utf8))
    let badSpeed = parseLabStateLine(Data(#"{"type":"lab_state","interaction":{"held_object_id":null,"carry_blocked":false,"reach_mm":12,"carry_speed_mm_s":0}}"#.utf8))
    // V5.6.1 feel fixes: latest-wins frame hand-off, look sensitivity, pointer lock.
    func testImage(width: Int) -> CGImage? {
        CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    let frameStream = MuJoCoFrameStream(port: 0)
    var shownWidths: [Int] = []
    frameStream.onFrame = { shownWidths.append($0.width) }
    let heldQueue = DispatchQueue(label: "labtest-frames")
    heldQueue.suspend()  // a busy main thread: five frames arrive before it runs
    for width in 1...5 { if let image = testImage(width: width) { frameStream.deliver(image, on: heldQueue) } }
    heldQueue.resume()
    heldQueue.sync {}
    check("MuJoCo frames are latest-wins, never a replay backlog",
          shownWidths == [5] && frameStream.framesReplaced == 4,
          "shown=\(shownWidths) replaced=\(frameStream.framesReplaced)")

    let lookDefaultsName = "SiliconFly.LookSensitivity.labtest.\(UUID().uuidString)"
    let lookDefaults = UserDefaults(suiteName: lookDefaultsName)!
    lookDefaults.removePersistentDomain(forName: lookDefaultsName)
    let freshLook = PlayerController(defaults: lookDefaults)
    let shippedDefault = freshLook.lookRadiansPerPoint
    freshLook.setLookSensitivity(0.0025, defaults: lookDefaults)
    let reloaded = PlayerController(defaults: lookDefaults).lookRadiansPerPoint
    freshLook.setLookSensitivity(1.0, defaults: lookDefaults)
    let clampedHigh = freshLook.lookRadiansPerPoint
    freshLook.setLookSensitivity(.nan, defaults: lookDefaults)
    let nanFallback = freshLook.lookRadiansPerPoint
    lookDefaults.removePersistentDomain(forName: lookDefaultsName)
    check("look sensitivity default 0.0015, persisted, clamped",
          shippedDefault == 0.0015 && reloaded == 0.0025
          && clampedHigh == PlayerController.lookSensitivityRange.upperBound
          && nanFallback == PlayerController.defaultLookRadiansPerPoint,
          "default=\(shippedDefault) reloaded=\(reloaded) high=\(clampedHigh) nan=\(nanFallback)")

    let windowlessViewer = WorldViewer(frame: .zero)
    windowlessViewer.participateInputEnabled = true
    let lockedWithoutWindow = windowlessViewer.pointerLocked
    windowlessViewer.participateInputEnabled = false
    check("pointer lock never touches the cursor without a window", !lockedWithoutWindow)

    check("carry_speed_mm_s optional strict decode",
          speedState?.interaction?.carrySpeedMMs == 40
          && validInteraction?.interaction?.carrySpeedMMs == nil
          && badSpeed != nil && badSpeed?.interaction == nil)

    var backendStim = FlyGymBodyFeedback()
    backendStim.windStrength = 0.7
    backendStim.windDirectionDeg = -30
    backendStim.windSensory = true
    backendStim.touchStrength = 0.55
    backendStim.touchSensory = true
    let activeBackend = SensoryModel.backendState(backendStim)
    backendStim.windSensory = false
    backendStim.touchSensory = false
    let disabledBackend = SensoryModel.backendState(backendStim)
    let missingBackend = SensoryModel.backendState(nil)
    check("backend body state is authoritative for wind/touch neural source",
          abs(activeBackend.wind - 0.7) < 1e-6
          && abs(activeBackend.windDirectionDeg + 30) < 1e-9
          && abs(activeBackend.touchDrive - 0.119) < 1e-6
          && disabledBackend.wind == 0 && disabledBackend.touchDrive == 0
          && missingBackend.wind == 0 && missingBackend.touchDrive == 0)

    // V3 module extraction parity. These local equations are the frozen V2
    // pre-extraction formulas, not calls back into SensoryModel. Any future
    // model change must therefore be deliberate rather than hidden in a refactor.
    func legacyOdor(_ x: Float, _ gate: Float) -> Float {
        let bounded = min(1, max(0, x))
        return 0.060 * sqrt(sqrt(bounded)) * gate
    }
    func legacyThermal(_ celsius: Double, _ enabled: Bool, _ gate: Float) -> (Float, Float) {
        guard enabled else { return (0, 0) }
        let warm = Float(max(0, min(1, (celsius - 25) / 10)))
        let cool = Float(max(0, min(1, (25 - celsius) / 10)))
        return (warm * 0.060 * gate, cool * 0.060 * gate)
    }
    func legacyWind(_ strength: Float, _ direction: Double, _ heading: Double,
                    _ gate: Float) -> (Float, Float) {
        guard strength > 0 else { return (0, 0) }
        let opponent = Float(cos(direction * .pi / 180 - heading))
        return (strength * (0.5 + 0.5 * opponent) * 0.055 * gate,
                strength * (0.5 - 0.5 * opponent) * 0.055 * gate)
    }
    var sensoryParity = true
    for gate: Float in [0.0, 0.55, 1.0] {
        for x: Float in [-0.2, 0, 0.0732, 0.5, 1, 1.4] {
            sensoryParity = sensoryParity
                && SensoryModel.odorCurrent(x, sensoryGate: gate) == legacyOdor(x, gate)
        }
        for temp in [10.0, 20.0, 25.0, 32.0, 40.0] {
            for enabled in [false, true] {
                let got = SensoryModel.thermal(celsius: temp, enabled: enabled, sensoryGate: gate)
                let old = legacyThermal(temp, enabled, gate)
                sensoryParity = sensoryParity && got.warm == old.0 && got.cool == old.1
            }
        }
        for (strength, direction, heading): (Float, Double, Double) in [
            (0, 0, 0), (0.2, 90, 0), (0.7, -30, 0.3), (1, 360, -.pi / 2)
        ] {
            let got = SensoryModel.wind(strength: strength, directionDeg: direction,
                                        bodyHeading: heading, sensoryGate: gate)
            let old = legacyWind(strength, direction, heading, gate)
            sensoryParity = sensoryParity && got.c == old.0 && got.e == old.1
        }
        for source: Float in [0, 0.02, 0.119, 0.2] {
            sensoryParity = sensoryParity
                && SensoryModel.touch(sourceDrive: source, sensoryGate: gate) == source * gate
        }
    }
    let tempoParity = [10.0, 20.0, 25.0, 32.0, 40.0].allSatisfy { temp in
        let old = clampf(CGFloat(1 + (min(40, max(10, temp)) - 25) * 0.03), 0.55, 1.45)
        return SensoryModel.locomotorTempo(celsius: temp) == old
    }
    check("V3 SensoryModel preserves V2 source→drive equations", sensoryParity && tempoParity)

    // SignalBuilder was also moved out of main.swift. Compare its stateful DNa
    // adaptation and all command channels against the exact frozen V2 equations.
    let motorBuilder = SignalBuilder()
    var legacyDNaBaseline: Float = 0
    var motorParity = true
    let motorInputs = [
        MotorReadoutInput(giantFiberSpiked: false, rateLoom: 0, rateDNaL: 45, rateDNaR: 38,
                          rateMDN: 20, rateFwd: 8, rateGroom: 1, rateEscW: 0, ratePop: 1.8),
        MotorReadoutInput(giantFiberSpiked: true, rateLoom: 80, rateDNaL: 70, rateDNaR: 20,
                          rateMDN: 90, rateFwd: 43, rateGroom: 12, rateEscW: 15, ratePop: 7),
        MotorReadoutInput(giantFiberSpiked: false, rateLoom: 12, rateDNaL: 25, rateDNaR: 60,
                          rateMDN: 59.9, rateFwd: 20, rateGroom: 3, rateEscW: 4, ratePop: 3),
    ]
    let motorDt: CGFloat = 1.0 / 60.0
    for input in motorInputs {
        let diff = input.rateDNaL - input.rateDNaR
        legacyDNaBaseline += (diff - legacyDNaBaseline) * Float(min(1, motorDt / 8))
        var old = BrainSignals()
        old.escape = input.giantFiberSpiked
        old.nervous = clampf(CGFloat(input.rateLoom) / 115, 0, 1)
        old.turnBias = clampf(CGFloat(diff - legacyDNaBaseline) * 0.04, -1, 1)
        old.backward = input.rateMDN > 60
        old.walkDrive = clampf((CGFloat(input.rateFwd) - 10) / 33, 0, 1.3)
        old.groomDrive = clampf(CGFloat(input.rateGroom) / 5, 0, 1.5)
        old.wingDrive = clampf(CGFloat(input.rateEscW) / 10, 0, 1.3)
        old.arousal = clampf(CGFloat(input.ratePop) / 10, 0, 1)
        let got = motorBuilder.make(input, dt: motorDt)
        motorParity = motorParity
            && got.escape == old.escape && got.nervous == old.nervous
            && got.turnBias == old.turnBias && got.backward == old.backward
            && got.walkDrive == old.walkDrive && got.groomDrive == old.groomDrive
            && got.wingDrive == old.wingDrive && got.arousal == old.arousal
    }
    motorBuilder.reset(); legacyDNaBaseline = 0
    let resetInput = motorInputs[1]
    let resetDiff = resetInput.rateDNaL - resetInput.rateDNaR
    legacyDNaBaseline += (resetDiff - legacyDNaBaseline) * Float(min(1, motorDt / 8))
    let resetExpectedTurn = clampf(CGFloat(resetDiff - legacyDNaBaseline) * 0.04, -1, 1)
    motorParity = motorParity && motorBuilder.make(resetInput, dt: motorDt).turnBias == resetExpectedTurn
    check("V3 MotorReadout preserves V2 rate→command sequence/reset", motorParity)

    var decodedSignals = BrainSignals()
    decodedSignals.walkDrive = 0.42
    decodedSignals.turnBias = -0.17
    decodedSignals.escape = true
    decodedSignals.backward = true
    decodedSignals.groomDrive = 0.23
    decodedSignals.wingDrive = 0.31
    decodedSignals.arousal = 0.44
    decodedSignals.tempo = 1.25
    decodedSignals.sleep = true
    decodedSignals.nervous = 0.66
    var decodedTelemetry = LabTelemetry()
    decodedTelemetry.applyBrainSignals(decodedSignals)
    check("decoded BrainSignals reach telemetry",
          decodedTelemetry.brainSignalsAvailable
          && abs(decodedTelemetry.brainWalkDrive - 0.42) < 1e-9
          && abs(decodedTelemetry.brainTurnBias + 0.17) < 1e-9
          && decodedTelemetry.brainEscape && decodedTelemetry.brainBackward
          && abs(decodedTelemetry.brainGroomDrive - 0.23) < 1e-9
          && abs(decodedTelemetry.brainWingDrive - 0.31) < 1e-9
          && abs(decodedTelemetry.brainArousal - 0.44) < 1e-9
          && abs(decodedTelemetry.brainTempo - 1.25) < 1e-9
          && decodedTelemetry.brainSleep
          && abs(decodedTelemetry.brainNervous - 0.66) < 1e-9)
    decodedTelemetry.applyBrainSignals(nil)
    check("missing BrainSignals clear telemetry",
          !decodedTelemetry.brainSignalsAvailable
          && decodedTelemetry.brainWalkDrive == 0 && decodedTelemetry.brainTurnBias == 0
          && !decodedTelemetry.brainEscape && !decodedTelemetry.brainBackward
          && decodedTelemetry.brainTempo == 1 && !decodedTelemetry.brainSleep)

    let telemetryBodyLine = #"{"type":"body","t":2.5,"sim_dt":0.003,"wall_dt":0.030,"sim_wall_ratio":0.1,"controller_left":0.22,"controller_right":0.44,"wind_strength":0.7,"wind_direction_deg":45,"wind_sensory":true,"touch_strength":0.55,"touch_sensory":true,"vx":0.004,"yaw_rate":0.2,"contacts":[1,1,1,1,1,1],"eye_sample_sim_tick":2300,"odor_left":0.3,"odor_right":0.4}"#
    if let bodyPacket = parseBodyLine(Data(telemetryBodyLine.utf8)) {
        let now = Date()
        var feedback = FlyGymBodyFeedback(bodyPacket)
        feedback.receivedAt = now.addingTimeInterval(-0.125)
        feedback.connectionGeneration = 9
        var bodyTelemetry = LabTelemetry()
        bodyTelemetry.applyBodyFeedback(feedback, now: now)
        check("body timing reaches lab telemetry",
              abs(bodyTelemetry.bodySimTime - 2.5) < 1e-9
              && abs(bodyTelemetry.bodySimDt - 0.003) < 1e-9
              && abs(bodyTelemetry.bodyWallDt - 0.030) < 1e-9
              && abs(bodyTelemetry.bodySimWallRatio - 0.1) < 1e-9
              && abs(bodyTelemetry.bodyControllerLeft - 0.22) < 1e-9
              && abs(bodyTelemetry.bodyControllerRight - 0.44) < 1e-9
              && abs(bodyTelemetry.bodyWindStrength - 0.7) < 1e-9
              && abs(bodyTelemetry.bodyWindDirectionDeg - 45) < 1e-9
              && bodyTelemetry.bodyWindSensory
              && abs(bodyTelemetry.bodyTouchStrength - 0.55) < 1e-9
              && bodyTelemetry.bodyTouchSensory
              && bodyTelemetry.bodyEyeSampleSimTick == 2300
              && abs(bodyTelemetry.bodyPacketAgeS - 0.125) < 1e-6
              && bodyTelemetry.bodyConnectionGeneration == 9)
        check("body timing columns recorded",
              LabTelemetry.csvHeader.contains("body_sim_s")
              && LabTelemetry.csvHeader.contains("body_sim_dt")
              && LabTelemetry.csvHeader.contains("body_sim_wall_ratio")
              && LabTelemetry.csvHeader.contains("controller_left")
              && LabTelemetry.csvHeader.contains("controller_right")
              && LabTelemetry.csvHeader.contains("body_wind_strength")
              && LabTelemetry.csvHeader.contains("body_touch_strength")
              && LabTelemetry.csvHeader.contains("body_generation,body_eye_sample_sim_tick,receptor_odor_l_hz")
              && bodyTelemetry.csvLine.contains(",9,2300,")
              && bodyTelemetry.csvLine.contains(",2.500000,0.003000,0.030000,0.100000,"))
    } else {
        check("body timing reaches lab telemetry", false, "body packet did not parse")
    }

    if let c = loadConnectome(), let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) {
        sim.perfLogIntervalMs = 0
        let roles = ["GF", "DNa-left", "DNa-right", "MDN", "DNp09", "DNg11", "escW",
                     "LC4/LPLC2-left", "LC4/LPLC2-right", "LC4/LPLC2", "ascend", "sens",
                     "ORN-food-left", "ORN-food-right", "TRN-warm", "TRN-cool",
                     "JO-C-wind", "JO-E-wind", "HRN-dry", "HRN-moist"]
        check("direct-neural roles map to existing neurons",
              roles.allSatisfy { !labPopulationIndices(sim, role: $0).isEmpty })
        check("FlyWire sensory group counts",
              sim.foodOdorLeft.count == 69 && sim.foodOdorRight.count == 66
              && sim.thermoWarm.count == 7 && sim.thermoCool.count == 9
              && sim.windC.count == 56 && sim.windE.count == 363,
              "odor=\(sim.foodOdorLeft.count)/\(sim.foodOdorRight.count) thermo=\(sim.thermoWarm.count)/\(sim.thermoCool.count) wind=\(sim.windC.count)/\(sim.windE.count)")
        sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: 0.05)
        let odorCurrent = sim.debugExternalInput(sim.foodOdorLeft)
        check("persistent sensory current reaches ORN group",
              odorCurrent.count == sim.foodOdorLeft.count
              && odorCurrent.allSatisfy { abs($0 - 0.05) < 1e-6 })
        sim.clearModeledSensoryDrives()
        check("modeled sensory clear zeros ORN current",
              sim.debugExternalInput(sim.foodOdorLeft).allSatisfy { abs($0) < 1e-8 })
        sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: 0.05)
        sim.reset(seed: SIM_SEED)
        check("brain reset clears persistent sensory current",
              sim.debugExternalInput(sim.foodOdorLeft).allSatisfy { abs($0) < 1e-8 })

        // Gain sanity: a modeled odor current should make its receptor group
        // more active than the same seeded baseline. This deliberately tests a
        // receptor response only, never a scripted downstream behavior.
        let odorSet = Set(sim.foodOdorLeft)
        func odorSpikes(_ drive: Float) -> Int {
            sim.reset(seed: SIM_SEED)
            sim.perfLogIntervalMs = 0
            sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: drive)
            var count = 0
            for _ in 0..<150 {
                sim.step(1)
                count += sim.lastStepSpikes().reduce(0) { $0 + (odorSet.contains(Int($1)) ? 1 : 0) }
            }
            return count
        }
        let odorBaselineSpikes = odorSpikes(0)
        let odorDrivenSpikes = odorSpikes(0.060)
        check("modeled odor raises ORN receptor spiking",
              odorDrivenSpikes > odorBaselineSpikes,
              "baseline=\(odorBaselineSpikes) driven=\(odorDrivenSpikes)")

        // End-to-end calibration for the shipped UI defaults. A 5 mm food
        // marker at (60, 0, 5) mm relative to a nominal thorax at z=0.7 mm
        // produces the same isotropic LabWorld concentration used by Python;
        // frontal bearing splits it equally across the two antenna channels.
        // The Coordinator's bounded compressive transduction must make that
        // ordinary placement measurable without raising the 0.060 max current.
        let defaultCenterDistance = sqrt(60.0 * 60.0 + 4.3 * 4.3)
        let defaultSurfaceDistance = max(0.0, defaultCenterDistance - 2.5)
        let defaultConcentration = exp(-defaultSurfaceDistance / 30.0)
        let defaultOdorLeft = Float(0.5 * defaultConcentration)
        let defaultFoodDrive: Float = 0.060 * sqrt(sqrt(defaultOdorLeft))
        let defaultFoodSpikes = odorSpikes(defaultFoodDrive)
        check("default UI food geometry raises ORN receptor spiking",
              defaultFoodDrive > 0 && defaultFoodDrive <= 0.060
              && defaultFoodSpikes > odorBaselineSpikes,
              String(format: "odor=%.4f current=%.4f baseline=%d driven=%d",
                     defaultOdorLeft, defaultFoodDrive, odorBaselineSpikes, defaultFoodSpikes))

        func receptorSpikes(_ indices: [Int], channel: MetalSim.ModeledSensoryChannel,
                            drive: Float) -> Int {
            let set = Set(indices)
            sim.reset(seed: SIM_SEED)
            sim.perfLogIntervalMs = 0
            sim.setModeledSensoryDrive(channel, indices: indices, strength: drive)
            var count = 0
            for _ in 0..<150 {
                sim.step(1)
                count += sim.lastStepSpikes().reduce(0) { $0 + (set.contains(Int($1)) ? 1 : 0) }
            }
            return count
        }
        func receptorCheck(_ name: String, indices: [Int],
                           channel: MetalSim.ModeledSensoryChannel, drive: Float) {
            let baseline = receptorSpikes(indices, channel: channel, drive: 0)
            let driven = receptorSpikes(indices, channel: channel, drive: drive)
            check(name, driven > baseline,
                  "baseline=\(baseline) driven=\(driven) current=\(drive)")
        }
        receptorCheck("warm TRN modeled drive raises receptor spiking",
                      indices: sim.thermoWarm, channel: .thermoWarm, drive: 0.060)
        receptorCheck("cool TRN modeled drive raises receptor spiking",
                      indices: sim.thermoCool, channel: .thermoCool, drive: 0.060)
        receptorCheck("JO-C wind modeled drive raises receptor spiking",
                      indices: sim.windC, channel: .windC, drive: 0.055)
        receptorCheck("JO-E wind modeled drive raises receptor spiking",
                      indices: sim.windE, channel: .windE, drive: 0.055)
        var receptorTelemetry = LabTelemetry()
        receptorTelemetry.applyReceptorRates(sim)
        check("receptor EMA rates reach telemetry",
              abs(receptorTelemetry.rateFoodOdorL - Double(sim.rateFoodOdorL)) < 1e-9
              && abs(receptorTelemetry.rateFoodOdorR - Double(sim.rateFoodOdorR)) < 1e-9
              && abs(receptorTelemetry.rateThermoWarm - Double(sim.rateThermoWarm)) < 1e-9
              && abs(receptorTelemetry.rateThermoCool - Double(sim.rateThermoCool)) < 1e-9
              && abs(receptorTelemetry.rateWindC - Double(sim.rateWindC)) < 1e-9
              && abs(receptorTelemetry.rateWindE - Double(sim.rateWindE)) < 1e-9
              && receptorTelemetry.rateWindE > 0,
              String(format: "ORN L/R %.1f/%.1f Hz · JO-E %.1f Hz",
                     receptorTelemetry.rateFoodOdorL, receptorTelemetry.rateFoodOdorR,
                     receptorTelemetry.rateWindE))
        sim.reset(seed: SIM_SEED)
        check("unknown neural role rejected", labPopulationIndices(sim, role: "invented").isEmpty)

        // Same-seed downstream parity: feed one sim through the extracted model
        // and another through the frozen V2 equations, then require identical
        // neural state/spikes. This catches an arithmetic-order change that a
        // source-only comparison could otherwise miss.
        if let legacySim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) {
            legacySim.perfLogIntervalMs = 0
            sim.reset(seed: SIM_SEED); legacySim.reset(seed: SIM_SEED)
            let sequence: [(Float, Double, Bool, Float, Double, Double, Float)] = [
                (0.0732, 32, true, 0.7, 90, 0.2, 0.55),
                (0.4, 20, true, 0.2, -30, -0.4, 1.0),
                (0.0, 25, false, 0.0, 0, 0, 1.0),
            ]
            var neuralParity = true
            var neuralParityDetail = ""
            for (odor, temp, thermoOn, wind, windDeg, heading, gate) in sequence {
                let newThermal = SensoryModel.thermal(celsius: temp, enabled: thermoOn, sensoryGate: gate)
                let oldThermal = legacyThermal(temp, thermoOn, gate)
                let newWind = SensoryModel.wind(strength: wind, directionDeg: windDeg,
                                                bodyHeading: heading, sensoryGate: gate)
                let oldWind = legacyWind(wind, windDeg, heading, gate)
                let newOdor = SensoryModel.odorCurrent(odor, sensoryGate: gate)
                let oldOdor = legacyOdor(odor, gate)
                sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: newOdor)
                sim.setModeledSensoryDrive(.thermoWarm, indices: sim.thermoWarm, strength: newThermal.warm)
                sim.setModeledSensoryDrive(.thermoCool, indices: sim.thermoCool, strength: newThermal.cool)
                sim.setModeledSensoryDrive(.windC, indices: sim.windC, strength: newWind.c)
                sim.setModeledSensoryDrive(.windE, indices: sim.windE, strength: newWind.e)
                legacySim.setModeledSensoryDrive(.foodOdorLeft, indices: legacySim.foodOdorLeft, strength: oldOdor)
                legacySim.setModeledSensoryDrive(.thermoWarm, indices: legacySim.thermoWarm, strength: oldThermal.0)
                legacySim.setModeledSensoryDrive(.thermoCool, indices: legacySim.thermoCool, strength: oldThermal.1)
                legacySim.setModeledSensoryDrive(.windC, indices: legacySim.windC, strength: oldWind.0)
                legacySim.setModeledSensoryDrive(.windE, indices: legacySim.windE, strength: oldWind.1)
                sim.step(40); legacySim.step(40)
                let vA = sim.membrane(), vB = legacySim.membrane()
                let rA = sim.debugRefr(), rB = legacySim.debugRefr()
                // GPU atomics do not promise append order; compare the spike set,
                // exactly as GPUCheck does, while membrane/refractory remain exact.
                let sA = sim.lastStepSpikes().sorted(), sB = legacySim.lastStepSpikes().sorted()
                let gA = sim.lastStepGroupCounts(), gB = legacySim.lastStepGroupCounts()
                let same = vA == vB && rA == rB && sA == sB && gA == gB
                if !same && neuralParityDetail.isEmpty {
                    let firstV = zip(vA, vB).enumerated().first { $0.element.0 != $0.element.1 }
                    neuralParityDetail = "simMs=\(sim.simMs) v=\(firstV?.offset ?? -1) refr=\(rA == rB) spikes=\(sA.count)/\(sB.count) groups=\(gA == gB)"
                }
                neuralParity = neuralParity && same
            }
            check("V3 extraction preserves same-seed downstream neural state", neuralParity,
                  neuralParityDetail)

            // V5.7: clicking every activity card must leave the neural state
            // bit-identical to an untouched same-seed twin. The control run wires
            // a click to a real GF stimulus and must be caught by the same probe.
            func cardClicksDiverge(stimulateOnClick: Bool) -> (diverged: Bool, missed: [ActivityCardID]) {
                sim.reset(seed: SIM_SEED); legacySim.reset(seed: SIM_SEED)
                sim.step(20); legacySim.step(20)
                let panel = ActivityCardPanel()
                var t = LabTelemetry()
                t.ratePop = Double(sim.ratePop); t.rateLoom = Double(sim.rateLoom)
                t.rateDNaL = Double(sim.rateDNaL); t.rateDNaR = Double(sim.rateDNaR)
                t.rateMDN = Double(sim.rateMDN)
                t.applyReceptorRates(sim)
                t.applyBrainSignals(SignalBuilder().make(MotorReadoutInput(ratePop: sim.ratePop), dt: 0.02))
                panel.update(ActivityCardInput(telemetry: t, brainSimLoaded: true))
                let missed = clickEveryActivityCard(panel) { _ in
                    if stimulateOnClick { sim.stimulate(sim.gf, strength: 0.5, durationMs: 30) }
                }
                sim.step(40); legacySim.step(40)
                let same = sim.membrane() == legacySim.membrane()
                    && sim.debugRefr() == legacySim.debugRefr()
                    && sim.lastStepSpikes().sorted() == legacySim.lastStepSpikes().sorted()
                    && sim.simMs == legacySim.simMs
                return (!same, missed)
            }
            let cardRun = cardClicksDiverge(stimulateOnClick: false)
            let cardControl = cardClicksDiverge(stimulateOnClick: true)
            check("V5.7 activity card clicks leave neural state identical to an untouched twin",
                  !cardRun.diverged && cardRun.missed.isEmpty,
                  "diverged=\(cardRun.diverged) missed=\(cardRun.missed)")
            check("V5.7 control: a click wired to a GF stimulus is detected by the same probe",
                  cardControl.diverged)
            sim.reset(seed: SIM_SEED); legacySim.reset(seed: SIM_SEED)
        } else {
            check("V3 extraction preserves same-seed downstream neural state", false,
                  "could not initialize legacy parity sim")
        }
    } else {
        check("direct-neural role mapping", false, "could not initialize MetalSim")
    }

    // Recording is part of the user-facing lab contract. Exercise the serialized
    // lifecycle in a temporary directory so queued tail data cannot be reported
    // as saved before write/flush/close actually finish.
    let fm = FileManager.default
    let recorderRoot = fm.temporaryDirectory
        .appendingPathComponent("siliconfly-recorder-test-\(UUID().uuidString)", isDirectory: true)
    let recorder = ExperimentRecorder(baseDirectory: recorderRoot)
    if let recordingPath = recorder.start() {
        var sample = LabTelemetry()
        sample.simMs = 42
        sample.odorDriveL = 0.04
        sample.bodyOdorL = 0.7
        sample.bodyNearestFoodDistanceMm = 11.5
        sample.rateFoodOdorL = 23.5
        sample.brainSignalsAvailable = true
        sample.brainWalkDrive = 0.42
        sample.brainTurnBias = -0.17
        sample.flyState = "walking"
        recorder.append(sample)
        recorder.mark(kind: "lab_test_marker", detail: "flush")
        var tail = sample
        tail.simMs = 4242
        recorder.append(tail)

        let stopDone = DispatchSemaphore(value: 0)
        var stopOutcome: ExperimentRecorderStopOutcome?
        recorder.stop { outcome in
            stopOutcome = outcome
            stopDone.signal()
        }
        let completed = stopDone.wait(timeout: .now() + 3) == .success
        recorder.flushForTesting()

        let metadata = (try? String(contentsOfFile: recordingPath + "/metadata.json", encoding: .utf8)) ?? ""
        let telemetry = (try? String(contentsOfFile: recordingPath + "/telemetry.csv", encoding: .utf8)) ?? ""
        let events = (try? String(contentsOfFile: recordingPath + "/events.jsonl", encoding: .utf8)) ?? ""
        check("recorder writes V4 metadata", metadata.contains("Thongpari Fly Neuron Sim Virtual Fly Lab V4"))
        check("recorder stop completes only after saved state",
              completed && stopOutcome?.succeeded == true && recorder.state == .saved,
              "completed=\(completed) state=\(recorder.state.rawValue)")
        check("recorder flushes queued telemetry tail on stop",
              telemetry.contains("odor_drive_l") && telemetry.contains("nearest_food_mm")
              && telemetry.contains("receptor_odor_l_hz")
              && telemetry.contains("brain_signals_available")
              && telemetry.contains("brain_walk")
              && telemetry.contains(",42,") && telemetry.contains(",4242,"))
        check("recorder preserves start/marker/stop events",
              events.contains("recording_started") && events.contains("lab_test_marker")
              && events.contains("recording_stopped"))

        // A rapid stop→start must never reuse/open a second session while the old
        // file handles are still in `stopping`. Once completion lands, restarting
        // is allowed and produces a distinct directory.
        if let secondPath = recorder.start() {
            var secondTail = sample
            secondTail.simMs = 5151
            recorder.append(secondTail)
            let rapidDone = DispatchSemaphore(value: 0)
            recorder.stop { _ in rapidDone.signal() }
            let immediateRestart = recorder.start()
            let rapidStopped = rapidDone.wait(timeout: .now() + 3) == .success
            let restartAfterStop = immediateRestart ?? recorder.start()
            check("rapid stop→start never overlaps recorder sessions",
                  rapidStopped && restartAfterStop != nil && restartAfterStop != secondPath,
                  "immediate=\(immediateRestart ?? "nil") after=\(restartAfterStop ?? "nil")")
            if recorder.isRecording {
                let cleanup = DispatchSemaphore(value: 0)
                recorder.stop { _ in cleanup.signal() }
                _ = cleanup.wait(timeout: .now() + 3)
            }
        } else {
            check("recorder restarts after saved stop", false)
        }
    } else {
        check("recorder starts in temporary directory", false)
    }

    // Deterministic write-failure seam: queued append/final-event errors must
    // surface as `failed`, never as a false saved result.
    let failingRoot = recorderRoot.appendingPathComponent("forced-failure", isDirectory: true)
    let failingRecorder = ExperimentRecorder(baseDirectory: failingRoot, forceWriteFailureForTesting: true)
    if failingRecorder.start() != nil {
        var failingSample = LabTelemetry()
        failingSample.simMs = 7
        failingRecorder.append(failingSample)
        let failureDone = DispatchSemaphore(value: 0)
        var failureOutcome: ExperimentRecorderStopOutcome?
        failingRecorder.stop { outcome in
            failureOutcome = outcome
            failureDone.signal()
        }
        let failureCompleted = failureDone.wait(timeout: .now() + 3) == .success
        let failed: Bool
        if case .failed = failureOutcome { failed = true } else { failed = false }
        check("recorder write failure propagates as failed",
              failureCompleted && failed && failingRecorder.state == .failed
              && failingRecorder.lastErrorMessage != nil,
              failingRecorder.lastErrorMessage ?? "no error")
        if let failureOutcome {
            let policy = applicationQuitAfterRecorderDrain(failureOutcome)
            let requiresConfirmation: Bool
            if case .requireFailureConfirmation = policy { requiresConfirmation = true }
            else { requiresConfirmation = false }
            check("AppKit quit policy blocks automatic termination after save failure",
                  !failureOutcome.succeeded && requiresConfirmation)

            var keepOpenReply: Bool?
            resolveApplicationQuitAfterRecorderDrain(
                failureOutcome,
                confirmFailure: { _, _, decision in decision(false) },
                reply: { keepOpenReply = $0 }
            )
            var explicitQuitReply: Bool?
            resolveApplicationQuitAfterRecorderDrain(
                failureOutcome,
                confirmFailure: { _, _, decision in decision(true) },
                reply: { explicitQuitReply = $0 }
            )
            check("AppKit quit failure requires explicit user override",
                  keepOpenReply == false && explicitQuitReply == true)
        } else {
            check("AppKit quit policy blocks automatic termination after save failure", false,
                  "missing failure outcome")
            check("AppKit quit failure requires explicit user override", false,
                  "missing failure outcome")
        }
    } else {
        check("forced-failure recorder starts before injected write", false)
    }

    // App quit uses the same completion contract; exercise its terminal reason
    // and queued tail independently from AppKit UI event delivery.
    let quitRoot = recorderRoot.appendingPathComponent("quit-drain", isDirectory: true)
    let quitRecorder = ExperimentRecorder(baseDirectory: quitRoot)
    if let quitPath = quitRecorder.start() {
        var quitTail = LabTelemetry()
        quitTail.simMs = 9001
        quitRecorder.append(quitTail)
        let quitDone = DispatchSemaphore(value: 0)
        quitRecorder.stop(reason: "application quit") { _ in quitDone.signal() }
        let quitCompleted = quitDone.wait(timeout: .now() + 3) == .success
        let quitTelemetry = (try? String(contentsOfFile: quitPath + "/telemetry.csv", encoding: .utf8)) ?? ""
        let quitEvents = (try? String(contentsOfFile: quitPath + "/events.jsonl", encoding: .utf8)) ?? ""
        check("application-quit recorder drain keeps tail",
              quitCompleted && quitRecorder.state == .saved && quitTelemetry.contains(",9001,")
              && quitEvents.contains("application quit"))
        let savedOutcome = ExperimentRecorderStopOutcome.saved(path: quitPath)
        check("AppKit quit policy terminates only after successful recorder drain",
              applicationQuitAfterRecorderDrain(savedOutcome) == .terminate)
        var savedReply: Bool?
        var unexpectedPrompt = false
        resolveApplicationQuitAfterRecorderDrain(
            savedOutcome,
            confirmFailure: { _, _, _ in unexpectedPrompt = true },
            reply: { savedReply = $0 }
        )
        check("AppKit quit success replies terminate without failure prompt",
              savedReply == true && !unexpectedPrompt)
    } else {
        check("application-quit recorder starts", false)
    }
    try? fm.removeItem(at: recorderRoot)

    // V5.5.1 one-window state: every ACK reaches the timeline exactly once.
    let ackBridge = FlyGymBridge()
    let ackGeneration = ackBridge.beginConnectionForTesting()
    for line in [#"{"type":"lab_ack","id":1,"ok":true,"action":"spawn_box","message":"ok","applied_tick":20}"#,
                 #"{"type":"lab_ack","id":2,"ok":false,"action":"move_object","message":"unknown target"}"#,
                 #"{"type":"lab_state","t":0.1,"ack":2,"ok":false,"error":"unknown target"}"#,
                 #"{"type":"lab_state","t":0.2,"ack":2,"ok":false,"error":"unknown target"}"#] {
        _ = ackBridge.receiveLineForTesting(Data(line.utf8))
    }
    let firstRead = ackBridge.labAcks(after: 0)
    let secondRead = ackBridge.labAcks(after: firstRead.serial)
    check("bridge keeps every ACK between UI refreshes, repeated lab_state ACK once",
          firstRead.acks.map(\.id) == [1, 2] && secondRead.acks.isEmpty,
          "ids=\(firstRead.acks.map(\.id))")
    let interactionEvents = ["object_grabbed", "object_placed", "carry_blocked",
                             "object_contact_begin", "object_contact_end"]
    for name in interactionEvents {
        _ = ackBridge.receiveLineForTesting(Data("{\"type\":\"lab_event\",\"event\":\"\(name)\"}".utf8))
    }
    let eventBatch = ackBridge.labEvents(after: 0)
    check("interaction events survive between UI refreshes for existing timeline",
          eventBatch.events.map(\.event) == interactionEvents
          && ackBridge.labEvents(after: eventBatch.serial).events.isEmpty)

    let t0 = Date()
    func entry(_ id: Int, generation: UInt64 = ackGeneration, at: Date = t0) -> LabTimelineEntry {
        LabTimelineEntry(commandID: id, action: "spawn_box", detail: "box_\(id)", kind: .physical,
                         sessionID: "s", epoch: 1, requestedTick: 10 * id, requestedAt: at,
                         connectionGeneration: generation, status: .requested)
    }
    var timeline = LabCommandTimeline()
    timeline.append(entry(1)); timeline.append(entry(2)); timeline.append(entry(3))
    timeline.append(entry(4, generation: ackGeneration &- 1))
    let resolved = firstRead.acks.map { timeline.apply(ack: $0) }
    let duplicate = timeline.apply(ack: firstRead.acks[0])
    timeline.expire(now: t0.addingTimeInterval(LabCommandTimeline.ackTimeout + 1),
                    connectionGeneration: ackGeneration)
    let statuses = timeline.entries.map(\.status)
    check("timeline resolves applied/rejected once, then times out and loses stale rows",
          resolved == [true, true] && !duplicate
          && statuses == [.applied, .rejected, .timedOut, .lost]
          && timeline.entries[0].appliedTick == 20 && timeline.pendingCount == 0,
          "\(statuses)")
    var late = LabAck(); late.id = 3; late.ok = true; late.appliedTick = 90
    late.connectionGeneration = ackGeneration
    check("late ACK still resolves a timed-out row with the real applied tick",
          timeline.apply(ack: late) && timeline.entries[2].status == .applied
          && timeline.entries[2].appliedTick == 90)

    let serviceDown = WorkspaceSnapshot.connection(bridgeEnabled: true, service: .exited(1),
                                                  connected: true, bodyFresh: true, bodyAge: 0)
    let stale = WorkspaceSnapshot.connection(bridgeEnabled: true, service: .running,
                                            connected: true, bodyFresh: false, bodyAge: 2.5)
    let live = WorkspaceSnapshot.connection(bridgeEnabled: true, service: nil,
                                           connected: true, bodyFresh: true, bodyAge: 0.01)
    let waiting = WorkspaceSnapshot.connection(bridgeEnabled: true, service: .starting,
                                              connected: false, bodyFresh: false, bodyAge: nil)
    check("workspace connection never reports live for a dead backend or stale body",
          serviceDown == .backendDown("exited with status 1") && stale == .stale(2.5)
          && live == .live && waiting == .connecting
          && WorkspaceSnapshot.connection(bridgeEnabled: false, service: nil, connected: false,
                                          bodyFresh: false, bodyAge: nil) == .disabled)
    check("V6.6 a confirmed pause with a fresh owner is live, not stale; a silent owner is still stale",
          WorkspaceSnapshot.connection(bridgeEnabled: true, service: .running, connected: true,
                                       bodyFresh: false, bodyAge: 60, pausedOwnerFresh: true) == .live
          && WorkspaceSnapshot.connection(bridgeEnabled: true, service: .running, connected: true,
                                          bodyFresh: false, bodyAge: 60, pausedOwnerFresh: false) == .stale(60))
    check("recording line never implies a save that has not completed",
          WorkspaceRecording.stopping(path: "/r").line.hasPrefix("Saving")
          && WorkspaceRecording.idle.line == "Not recording"
          && WorkspaceRecording.recording(path: "/r", elapsed: 75).line.contains("01:15")
          && WorkspaceRecording.failed(path: "/r", message: "disk full").line.contains("disk full"))

    // App-owned backend lifecycle against a stand-in "python" (/bin/sh) that
    // just sleeps: start → stop leaves no child, and only then offers restart.
    let fakeRoot = fm.temporaryDirectory.appendingPathComponent("thongpari-service-\(UUID().uuidString)")
    try? fm.createDirectory(at: fakeRoot.appendingPathComponent("flygym_bridge"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: fakeRoot.appendingPathComponent("flygym-venv/bin"), withIntermediateDirectories: true)
    try? "exec sleep 30\n".write(to: fakeRoot.appendingPathComponent("flygym_bridge/bridge.py"),
                                 atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(atPath: fakeRoot.appendingPathComponent("flygym-venv/bin/python").path,
                               withDestinationPath: "/bin/sh")
    let probeStarted = DispatchSemaphore(value: 0), probeRelease = DispatchSemaphore(value: 0)
    let blockedProbeService = FlyGymService(mode: .mock, root: fakeRoot, cloudEvictionProbe: { _ in
        probeStarted.signal(); probeRelease.wait(); return true
    })
    let probeDidStart = probeStarted.wait(timeout: .now() + 1) == .success
    let probeReadStart = Date()
    let probePendingValue = blockedProbeService.runtimeIsCloudEvicted
    check("cloud-runtime probe cannot block UI reads", probeDidStart && !probePendingValue
          && Date().timeIntervalSince(probeReadStart) < 0.1)
    probeRelease.signal()
    let probeDeadline = Date().addingTimeInterval(1)
    while !blockedProbeService.runtimeIsCloudEvicted && Date() < probeDeadline { usleep(1_000) }
    check("cloud-runtime probe publishes its eventual result", blockedProbeService.runtimeIsCloudEvicted)
    let service = FlyGymService(mode: .mock, root: fakeRoot)
    service.start()
    let startedRunning = service.state == .running && !service.canRestart && service.port != 0
    service.stop()
    let deadline = Date().addingTimeInterval(2)
    while service.state == .running && Date() < deadline { usleep(10_000) }
    if case .exited = service.state {
        check("app-owned backend stops cleanly and becomes restartable",
              startedRunning && service.canRestart)
    } else {
        check("app-owned backend stops cleanly and becomes restartable", false, "\(service.state)")
    }
    check("backend without a checkout reports unavailable, never restartable",
          { if case .unavailable = FlyGymService(mode: .mock, root: nil).state { return true }; return false }()
          && !FlyGymService(mode: .mock, root: nil).canRestart)
    try? fm.removeItem(at: fakeRoot)

    // Mood readout: fixed, explainable rules with a fading memory of hits.
    let mood = FlyMoodEstimator()
    let moodT0 = Date(timeIntervalSince1970: 1_000)
    var calm = FlyMoodInputs()
    var food = FlyMoodInputs(); food.nearestFoodMM = 8
    var cold = FlyMoodInputs(); cold.temperatureC = 12
    var hot = FlyMoodInputs(); hot.temperatureC = 34
    var looming = FlyMoodInputs(); looming.nervous = 0.8; looming.nearestFoodMM = 8
    let calmMood = mood.update(calm, now: moodT0).mood
    let happyMood = mood.update(food, now: moodT0).mood
    let coldMood = mood.update(cold, now: moodT0).mood
    let hotMood = mood.update(hot, now: moodT0).mood
    let scaredOverFood = mood.update(looming, now: moodT0).mood
    mood.registerHit(strength: 0.5, at: moodT0)
    let angryAfterTap = mood.update(food, now: moodT0.addingTimeInterval(1)).mood
    let fadedAfterTap = mood.update(food, now: moodT0.addingTimeInterval(20)).mood
    mood.registerHit(strength: 0.95, at: moodT0.addingTimeInterval(30))
    let hurtAfterHardHit = mood.update(calm, now: moodT0.addingTimeInterval(31)).mood
    mood.reset()
    calm.sleep = true
    let sleepyMood = mood.update(calm, now: moodT0.addingTimeInterval(32)).mood
    check("mood readout follows its stated rules and hits fade",
          calmMood == .calm && happyMood == .happy && coldMood == .cold && hotMood == .hot
          && scaredOverFood == .scared && angryAfterTap == .angry && fadedAfterTap == .happy
          && hurtAfterHardHit == .hurt && sleepyMood == .sleepy,
          "\(calmMood) \(happyMood) \(coldMood) \(hotMood) \(scaredOverFood) \(angryAfterTap) \(fadedAfterTap) \(hurtAfterHardHit) \(sleepyMood)")

    // Participant views ride the participant's own look quaternion.
    let yawLeft = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":4,"sim_tick":40,"ok":true,"snapshot_seq":4,"world_revision":6,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"actor_id":"player","position_mm":[24,0,2.5],"orientation_quat_xyzw":[0,0,0.7071067811865476,0.7071067811865476],"collision_radius_mm":2.5,"mode":"participate"}}"#
    let viewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    if let snap = parseWorldRenderSnapshotLine(Data(yawLeft.utf8)) { viewer.apply(snapshot: snap) }
    viewer.setObservationCameraMode(.firstPerson)
    let eye = viewer.mujocoCamera
    let firstPersonRay = viewer.participantAimRay()
    viewer.participateInputEnabled = true
    let firstPersonMarkVisible = viewer.aimMarkVisible
    // Eye at 0.6 x radius, inside the collision sphere (view_stream.py mirrors it).
    let eyeOK = zip(eye.positionMM, [24.0, 1.5, 2.5]).allSatisfy { abs($0 - $1) < 1e-3 }
        && zip(eye.forward, [0.0, 1.0, 0.0]).allSatisfy { abs($0 - $1) < 1e-3 }
        && firstPersonRay != nil
        && zip(eye.positionMM, firstPersonRay?.originMM ?? []).allSatisfy { abs($0 - $1) < 1e-3 }
        && zip(eye.forward, firstPersonRay?.direction ?? []).allSatisfy { abs($0 - $1) < 1e-3 }
        && eye.anchor == "participant_first"
    viewer.rotateObservationCamera(deltaX: 40, deltaY: 10)
    viewer.panObservationCamera(deltaX: 9, deltaY: 3)
    let dragIgnored = viewer.mujocoCamera == eye
    viewer.setObservationCameraMode(.behindParticipant)
    let thirdPersonMarkHidden = !viewer.aimMarkVisible
    let behind = viewer.mujocoCamera
    let aimBehind = viewer.participantAimRay()
    let behindOK = behind.anchor == "participant_third"
        && behind.positionMM[1] < 0 && behind.positionMM[2] > 2.5
    check("third-person interaction ray starts at participant eye, not camera",
          aimBehind != nil
          && zip(aimBehind?.originMM ?? [], [24.0, 1.5, 2.5]).allSatisfy { abs($0 - $1) < 1e-3 }
          && zip(aimBehind?.direction ?? [], [0.0, 1.0, 0.0]).allSatisfy { abs($0 - $1) < 1e-3 }
          && hypot((aimBehind?.originMM[0] ?? 999) - 24, (aimBehind?.originMM[1] ?? 999)) <= 5
          && behind.positionMM != aimBehind?.originMM)
    viewer.setObservationCameraMode(.followFly)
    viewer.setObservationCameraMode(.firstPerson)
    viewer.participateInputEnabled = false
    let uncapturedMarkHidden = !viewer.aimMarkVisible
    check("aim mark appears only for captured first-person view",
          firstPersonMarkVisible && thirdPersonMarkHidden && uncapturedMarkHidden)
    viewer.setObservationCameraMode(.followFly)
    check("participant first/third person cameras follow the participant's look",
          eyeOK && behindOK && dragIgnored && viewer.mujocoCamera.anchor == "fly",
          "eye=\(eye.positionMM) fwd=\(eye.forward) behind=\(behind.positionMM)")
    // V5.7 read-only activity cards: existing telemetry only, hunger unsupported,
    // absent sources shown as "—", and clicks that reach no command queue.
    var cardSignals = BrainSignals()
    cardSignals.arousal = 0.4375; cardSignals.nervous = 0.6875
    cardSignals.walkDrive = 0.8125; cardSignals.turnBias = -0.3125
    cardSignals.groomDrive = 1.125; cardSignals.sleep = true; cardSignals.escape = true
    var cardFixture = LabTelemetry()
    cardFixture.applyBrainSignals(cardSignals)
    cardFixture.ratePop = 3.625; cardFixture.rateLoom = 41.75
    cardFixture.rateDNaL = 37.75; cardFixture.rateDNaR = 12.5; cardFixture.rateMDN = 22.25
    cardFixture.rateFoodOdorL = 88.5; cardFixture.rateFoodOdorR = 61.25
    cardFixture.rateSugarGRN = 42.75; cardFixture.rateMN9 = 17.5
    cardFixture.bodyOdorL = 0.9; cardFixture.bodyOdorR = 0.8
    let expectedCards: [ActivityCardID: ActivityCardValue] = [
        .arousal: .number(cardFixture.brainArousal), .nervous: .number(cardFixture.brainNervous),
        .walk: .number(cardFixture.brainWalkDrive), .turn: .number(cardFixture.brainTurnBias),
        .groom: .number(cardFixture.brainGroomDrive), .sleep: .flag(cardFixture.brainSleep),
        .gfSpike: .flag(cardFixture.brainEscape), .populationRate: .number(cardFixture.ratePop),
        .loomRate: .number(cardFixture.rateLoom), .dnaLeft: .number(cardFixture.rateDNaL),
        .dnaRight: .number(cardFixture.rateDNaR), .mdn: .number(cardFixture.rateMDN),
        .ornFoodLeft: .number(cardFixture.rateFoodOdorL), .ornFoodRight: .number(cardFixture.rateFoodOdorR),
        .sugarGRN: .number(cardFixture.rateSugarGRN), .mn9: .number(cardFixture.rateMN9),
        .hunger: .unsupported,
    ]
    let cardPanel = ActivityCardPanel()
    cardPanel.update(ActivityCardInput(telemetry: cardFixture, brainSimLoaded: true))
    let wrongCards = cardPanel.cards.filter { card in
        guard card.displayedValue == expectedCards[card.spec.id] else { return true }
        if case .number(let v) = card.displayedValue {
            // The text is the same number, only rounded for display.
            guard let shown = Double(card.valueText) else { return true }
            return abs(shown - v) > 0.5 * pow(10, -Double(card.spec.decimals)) + 1e-9
        }
        return false
    }.map(\.spec.id)
    check("V5.7 activity cards pass existing telemetry through unchanged",
          cardPanel.cards.count == expectedCards.count && wrongCards.isEmpty,
          "cards=\(cardPanel.cards.count) wrong=\(wrongCards)")

    let hungerWithOdor = cardPanel.card(.hunger)
    var noOdor = cardFixture
    noOdor.rateFoodOdorL = 0; noOdor.rateFoodOdorR = 0; noOdor.bodyOdorL = 0; noOdor.bodyOdorR = 0
    let hungerPanel = ActivityCardPanel()
    hungerPanel.update(ActivityCardInput(telemetry: noOdor, brainSimLoaded: true))
    check("V5.7 hunger card is unsupported, with no odour-derived proxy",
          hungerWithOdor?.displayedValue == .unsupported && hungerWithOdor?.spec.kind == .unsupported
          && hungerWithOdor?.valueText == "Unsupported" && Double(hungerWithOdor?.valueText ?? "0") == nil
          && hungerPanel.card(.hunger)?.displayedValue == .unsupported
          && hungerPanel.card(.hunger)?.valueText == hungerWithOdor?.valueText)

    check("V5.7 pause help distinguishes held spike rates from missing indices/events",
          ActivityCardPanel.helpText.contains("model indices and spike events show “—”")
          && ActivityCardPanel.helpText.contains("spike-rate cards keep the last sample, not a live measurement"))
    var absent = LabTelemetry()
    absent.applyBrainSignals(nil)
    let absentPanel = ActivityCardPanel()
    absentPanel.update(ActivityCardInput(telemetry: absent, brainSimLoaded: false))
    let absentShown = absentPanel.cards.filter { $0.spec.id != .hunger }
        .filter { $0.displayedValue != .missing || $0.valueText != "—" }.map(\.spec.id)
    var paused = cardFixture
    paused.applyBrainSignals(nil)
    paused.rateMDN = .nan
    let pausedPanel = ActivityCardPanel()
    pausedPanel.update(ActivityCardInput(telemetry: paused, brainSimLoaded: true))
    let pausedSignalDash = pausedPanel.cards.filter { $0.spec.kind == .modelIndex || $0.spec.id == .gfSpike }
        .allSatisfy { $0.displayedValue == .missing && $0.valueText == "—" }
    let pausedRatesShown = pausedPanel.card(.dnaLeft)?.displayedValue == .number(paused.rateDNaL)
        && pausedPanel.card(.mdn)?.valueText == "—"
    check("V5.7 absent telemetry shows — never 0 (no brain, paused, non-finite)",
          absentShown.isEmpty && pausedSignalDash && pausedRatesShown,
          "absent-but-shown=\(absentShown) pausedDash=\(pausedSignalDash) pausedRates=\(pausedRatesShown)")

    let unlabeled = cardPanel.cards.filter { card in
        let s = card.spec
        let unitOK: Bool
        switch s.kind {
        case .measured: unitOK = s.unit.contains("Hz") || card.displayedValue == .flag(true) || card.displayedValue == .flag(false)
        case .modelIndex: unitOK = !s.unit.isEmpty && s.meaning.contains("not a feeling")
        case .unsupported: unitOK = s.meaning.contains("Not modelled")
        }
        return !unitOK || s.source.isEmpty || !(card.toolTip ?? "").contains(s.source)
    }.map(\.spec.id)
    check("V5.7 every card states its unit, classification and source",
          unlabeled.isEmpty && ActivityCardKind.measured.label.contains("MEASURED")
          && ActivityCardKind.modelIndex.label == "MODEL INDEX"
          && ActivityCardKind.unsupported.label == "UNSUPPORTED",
          "unlabeled=\(unlabeled)")

    let clickBridge = FlyGymBridge()
    let missedClicks = clickEveryActivityCard(cardPanel)
    check("V5.7 every card click selects it and shows its source",
          missedClicks.isEmpty && cardPanel.selectedCard != nil, "missed=\(missedClicks)")
    check("V5.7 card clicks queue no bridge, lab or player command",
          clickBridge.pendingDepth() == 0 && clickBridge.pendingLabDepth() == 0
          && clickBridge.dequeueSendForTesting(at: Date()) == nil)
    let controlBridge = FlyGymBridge()
    _ = clickEveryActivityCard(ActivityCardPanel()) { _ in
        _ = controlBridge.sendLab(action: "stimulate", target: "GF", strength: 0.5, durationMs: 30)
    }
    check("V5.7 control: a click wired to a lab command is detected by the same probe",
          controlBridge.pendingDepth() > 0)

    runSandboxToyChecks(check)

    check("interface language is pinned to English for suites",
          LabLanguage.current == .english && L("Observe", "관찰") == "Observe")

    print(failures == 0 ? "ALL LAB TESTS PASS" : "\(failures) LAB TEST FAILURES")
    exit(failures == 0 ? 0 : 1)
}

/// V6.1 shared fixtures: strict standalone decode; tolerant optional telemetry.
private func runEnvironmentCapabilityChecks(_ check: (String, Bool, String) -> Void) {
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("fixtures/environment_capabilities", isDirectory: true)
    let required = ["valid.json", "missing-field.json", "bad-range.json", "bad-unit.json", "bad-type.json",
                    "duplicate-id.json", "wrong-vector.json", "bad-default.json", "unknown-version.json"]
    check("V6.1 shared fixtures present", required.allSatisfy {
        FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
    }, root.path)
    guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
    let fixtures = urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let decoder = JSONDecoder()
    for url in fixtures {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { check("V6.1 fixture read " + name, false, "unreadable"); continue }
        let expectedValid = name.hasPrefix("valid")
        let decoded = try? decoder.decode(EnvironmentCapabilities.self, from: data)
        check("V6.1 strict fixture " + name, (decoded != nil) == expectedValid, expectedValid ? "accept" : "reject")
        guard let manifest = try? JSONSerialization.jsonObject(with: data) else {
            check("V6.1 JSON fixture " + name, false, "fixture must be JSON"); continue
        }
        let object: [String: Any] = ["id": "box_1", "shape": "box", "position_mm": [1, 2, 3], "size_mm": [4, 5, 6], "yaw_deg": 0]
        let packet: [String: Any] = ["type": "lab_state", "session_id": "v6-fixture", "epoch": 2, "sim_tick": 40,
                                   "state": ["objects": [object], "slot_capacity": ["food": 8], "environment_capabilities": manifest]]
        guard let wire = try? JSONSerialization.data(withJSONObject: packet), let state = parseLabStateLine(wire) else {
            check("V6.1 optional manifest state " + name, false, "lost lab_state"); continue
        }
        check("V6.1 optional manifest state " + name,
              (state.worldState?.environmentCapabilities != nil) == expectedValid
              && state.authoritativeObjects?.first?.id == "box_1" && state.authoritativeSlotCapacity?["food"] == 8
              && state.sessionID == "v6-fixture" && state.epoch == 2 && state.simTick == 40, "no partial salvage or telemetry loss")
    }
    if let data = try? Data(contentsOf: root.appendingPathComponent("valid.json")),
       let manifest = try? decoder.decode(EnvironmentCapabilities.self, from: data) {
        var decodeMS: [Double] = []
        for _ in 0..<1000 {
            let start = Date.timeIntervalSinceReferenceDate
            _ = try? decoder.decode(EnvironmentCapabilities.self, from: data)
            decodeMS.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
        }
        decodeMS.sort()
        print(String(format: "V6.1 DECODE BENCH: bytes=%d descriptors=%d n=1000 p50=%.3fms p95=%.3fms (standalone only; not live acceptance)",
                     data.count, manifest.descriptors.count, decodeMS[500], decodeMS[950]))
        let temperature = manifest.descriptors.first { $0.legacyField == "celsius" }
        let mode = manifest.descriptors.first { $0.legacyField == "mode" && $0.legacyCommands.contains("temperature") }
        let wind = manifest.descriptors.first { $0.legacyField == "strength" && $0.legacyCommands.contains("wind") }
        check("V6.1 authoritative temperature modes/range and normalized wind",
              temperature?.unit == "degC" && temperature?.minimum == .number(0) && temperature?.maximum == .number(50)
              && mode?.choices == ["environment_only", "modeled_physiology", "flywire_sensory"]
              && wind?.unit == "normalized" && wind?.minimum == .number(0) && wind?.maximum == .number(1), "backend0...50 vs UI10...40; wind not m/s")
        check("V6.1 unsupported controls not fabricated",
              !manifest.descriptors.contains { $0.propertyID.hasPrefix("lighting.") || $0.propertyID.hasPrefix("humidity.") || $0.propertyID.contains("advection") }
              && manifest.descriptor("not.a.property") == nil, "read-only lookup, not edit authorization")
    }
    let legacy = parseLabStateLine(Data(#"{"type":"lab_state","state":{"objects":[],"slot_capacity":{"food":8}}}"#.utf8))
    check("V6.1 older backend without manifest remains valid", legacy != nil
          && legacy?.worldState?.environmentCapabilities == nil && legacy?.authoritativeSlotCapacity?["food"] == 8, "no fabricated defaults")
}

/// V6.2 shared edit fixtures: same accept/reject and first failing path as
/// Python validate_edit; wire encoding and ACK detail decode.
private func runEnvironmentEditChecks(_ check: (String, Bool, String) -> Void) {
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("fixtures/environment_edits", isDirectory: true)
    let urls = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    check("V6.2 shared edit fixtures present", urls.count >= 30, "\(urls.count) in \(root.path)")
    var capabilities: EnvironmentCapabilities?
    var accepted = 0, rejected = 0
    for url in urls {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifestPath = doc["manifest"] as? String, let expect = doc["expect"] as? String,
              let edit = doc["edit"],
              let manifestData = try? Data(contentsOf: root.appendingPathComponent(manifestPath)),
              let manifest = try? JSONDecoder().decode(EnvironmentCapabilities.self, from: manifestData) else {
            check("V6.2 edit fixture read " + name, false, "unreadable"); continue
        }
        capabilities = manifest
        do {
            let validated = try EnvironmentEdit.validate(json: edit, capabilities: manifest)
            accepted += 1
            // Round trip: what Swift would send validates again to the same request.
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(validated))
            let again = try? EnvironmentEdit.validate(json: wire, capabilities: manifest)
            check("V6.2 edit fixture " + name, expect == "accept" && again == validated, "accept + encode round trip")
        } catch let error as EnvironmentEditError {
            rejected += 1
            check("V6.2 edit fixture " + name, expect == "reject" && error.path == doc["path"] as? String,
                  "\(error) (expected \(doc["path"] ?? "accept"))")
        } catch {
            check("V6.2 edit fixture " + name, false, "\(error)")
        }
    }
    check("V6.2 edit fixtures cover accept and reject", accepted >= 5 && rejected >= 20, "accept=\(accepted) reject=\(rejected)")
    guard let capabilities else { return }
    func rejectsValue(_ value: EnvironmentPropertyValue, _ id: String, _ target: String? = nil) -> String? {
        do { _ = try EnvironmentEdit.make(propertyID: id, targetID: target, expectedRevision: 0,
                                          value: value, capabilities: capabilities); return nil }
        catch let error as EnvironmentEditError { return error.path } catch { return "\(error)" }
    }
    check("V6.2 nonfinite values rejected before encoding",
          rejectsValue(.number(.nan), "temperature.celsius") == "edit.value"
          && rejectsValue(.number(.infinity), "temperature.celsius") == "edit.value"
          && rejectsValue(.vector([1, .nan, 3]), "object.box.position_mm", "box_1") == "edit.value[1]"
          && rejectsValue(.number(1), "eyes.left_enabled") == "edit.value", "NaN/inf/number-as-bool")
    if let edit = try? EnvironmentEdit.make(propertyID: "eyes.left_enabled", targetID: nil, expectedRevision: 7,
                                            value: .boolean(false), capabilities: capabilities),
       let line = try? JSONEncoder().encode(LabCommand.editProperty(id: 12, edit)),
       let wire = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
       let body = wire["edit"] as? [String: Any] {
        check("V6.2 edit_property wire shape",
              wire["action"] as? String == "edit_property" && wire["id"] as? Int == 12
              && body["target_id"] is NSNull && body["unit"] as? String == "none"
              && Set(body.keys) == Set(EnvironmentEdit.fields)
              && (body["value"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true,
              String(decoding: line, as: UTF8.self))
    } else {
        check("V6.2 edit_property wire shape", false, "make/encode failed")
    }
    let applied = parseLabStateLine(Data(#"{"type":"lab_state","ack":12,"ok":true,"state":{},"edit":{"ok":true,"status":"applied","property_id":"object.box.position_mm","target_id":"box_1","actual_value":[1,2,3],"revision":9}}"#.utf8))
    let stale = parseLabStateLine(Data(#"{"type":"lab_state","ack":13,"ok":false,"error":"edit.expected_revision: stale revision","state":{},"edit":{"ok":false,"status":"rejected_stale_revision","path":"edit.expected_revision","reason":"stale revision","current_revision":11}}"#.utf8))
    let malformed = parseLabStateLine(Data(#"{"type":"lab_state","ack":14,"ok":true,"state":{},"edit":{"ok":"yes"}}"#.utf8))
    check("V6.2 ACK edit detail decodes; malformed detail drops only itself",
          applied?.edit?.actualValue == .vector([1, 2, 3]) && applied?.edit?.revision == 9
          && stale?.edit?.path == "edit.expected_revision" && stale?.edit?.currentRevision == 11
          && malformed?.ack == 14 && malformed?.edit == nil, "applied/stale/malformed")
}

/// V5.7: clicks every activity card the way AppKit delivers a click — hit-test
/// the card's centre inside an (offscreen, never shown) window and send the hit
/// view a mouse-down — and then again through the accessibility press action.
/// Returns the cards whose click did not select exactly that card and show its
/// source.
private func clickEveryActivityCard(_ panel: ActivityCardPanel,
                                    afterEach: (ActivityCardID) -> Void = { _ in }) -> [ActivityCardID] {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: true)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 900))
    window.contentView = content
    panel.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(panel)
    NSLayoutConstraint.activate([
        panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)
    ])
    content.layoutSubtreeIfNeeded()
    defer { panel.removeFromSuperview() }

    var missed: [ActivityCardID] = []
    for card in panel.cards {
        let id = card.spec.id
        let centre = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        let hit = content.hitTest(content.superview?.convert(centre, from: nil) ?? centre)
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: centre, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
            hit?.mouseDown(with: event)
        }
        afterEach(id)
        if hit !== card || card.bounds.isEmpty || panel.selectedCard != id
            || !panel.detailText.contains(card.spec.source) {
            missed.append(id)
        }
    }
    for card in panel.cards.reversed() {
        let pressed = card.accessibilityPerformPress()
        afterEach(card.spec.id)
        if !pressed || panel.selectedCard != card.spec.id { missed.append(card.spec.id) }
    }
    return missed
}

/// V5.6.2 sandbox toys: wire names against the backend schema, gun key/click
/// routing, focus suppression, remap persistence, shape-gated actions and
/// tolerant decoding of the new optional state fields.
private func runSandboxToyChecks(_ report: (String, Bool, String) -> Void) {
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }
    func wire(_ command: LabCommand?) -> [String: Any] {
        guard let command, let data = try? JSONEncoder().encode(command),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    func isJSONBool(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    /// flygym_bridge/protocol.py LabCommand.from_dict: every top-level key
    /// outside the envelope becomes an arg, `target` becomes `id`, x/y/z
    /// become `position_mm`, and `size` becomes `size_mm` only when absent.
    func backendArgs(_ w: [String: Any]) -> [String: Any] {
        let envelope: Set<String> = ["type", "seq", "op", "id", "action", "args", "session_id",
                                     "epoch", "requested_tick", "protocol_version"]
        var args = w.filter { !envelope.contains($0.key) }
        if let target = w["target"] { args["id"] = target }
        if ["x", "y", "z"].contains(where: { w[$0] != nil }) {
            args["position_mm"] = [w["x"] ?? 0.0, w["y"] ?? 0.0, w["z"] ?? 0.0]
        }
        if let size = w["size"], args["size_mm"] == nil { args["size_mm"] = [size, size, size] }
        return args
    }
    // Field names apply_command reads (flygym_bridge/lab_world.py), verbatim.
    let backendKeys: [String: [String]] = [
        "spawn_object": ["shape", "id", "position_mm", "size_mm"],
        "drive_object": ["id", "speed_mm_s", "distance_mm"],
        "arm_trap": ["id"],
        "equip_gun": ["actor_id", "equipped"],
        "fire_bb": ["actor_id", "direction"],
    ]

    let car = wire(LabCommand.spawnToy(shape: "car", target: "car_1",
                                       positionMM: [30, -4, LabToy.spawnCenterZ(shape: "car", sizeMM: 14)],
                                       sizeMM: 14))
    let trap = wire(LabCommand.spawnToy(shape: "trap", target: "trap_1",
                                        positionMM: [40, 0, LabToy.spawnCenterZ(shape: "trap", sizeMM: 20)],
                                        sizeMM: 20))
    let drive = wire(LabCommand.driveObject(target: "car_1"))
    let arm = wire(LabCommand.armTrap(target: "trap_1"))
    let equip = wire(LabCommand.equipGun(actorID: "player", equipped: true))
    let fire = wire(LabCommand.fireBB(actorID: "player", direction: [2, 0, 0]))
    let carArgs = backendArgs(car), trapArgs = backendArgs(trap)
    check("V5.6.2 spawn_object toy wire: shape + scalar size_mm, never size",
          car["action"] as? String == "spawn_object" && car["shape"] as? String == "car"
          && car["size_mm"] as? Double == 14 && car["size"] == nil
          && carArgs["id"] as? String == "car_1"
          && (carArgs["position_mm"] as? [Double]).map { abs($0[2] - 2.87) < 1e-9 } == true
          && trap["shape"] as? String == "trap" && trap["size_mm"] as? Double == 20
          && (trapArgs["position_mm"] as? [Double]).map { abs($0[2] - 10.0) < 1e-9 } == true, "\(car)")
    check("V5.6.2 drive/arm/equip/fire wire names and defaults",
          drive["action"] as? String == "drive_object" && drive["target"] as? String == "car_1"
          && drive["speed_mm_s"] as? Double == 20 && drive["distance_mm"] as? Double == 80
          && drive["speed"] == nil
          && arm["action"] as? String == "arm_trap" && arm["target"] as? String == "trap_1"
          && equip["action"] as? String == "equip_gun" && equip["actor_id"] as? String == "player"
          && isJSONBool(equip["equipped"]) && equip["equipped"] as? Bool == true
          && fire["action"] as? String == "fire_bb" && fire["actor_id"] as? String == "player"
          && fire["direction"] as? [Double] == [1, 0, 0], "drive=\(drive.keys.sorted())")
    let merged = ["spawn_object": carArgs, "drive_object": backendArgs(drive), "arm_trap": backendArgs(arm),
                  "equip_gun": backendArgs(equip), "fire_bb": backendArgs(fire)]
    let missing = backendKeys.flatMap { op, keys in
        keys.filter { merged[op]?[$0] == nil }.map { "\(op).\($0)" }
    }.sorted()
    check("V5.6.2 every backend-read argument arrives after Python's flat merge",
          missing.isEmpty, "missing=\(missing)")
    check("V5.6.2 toy constructors enforce the backend bounds",
          LabCommand.spawnToy(shape: "car", target: "c", positionMM: [0, 0, 1], sizeMM: 3.9) == nil
          && LabCommand.spawnToy(shape: "car", target: "c", positionMM: [0, 0, 1], sizeMM: 60) != nil
          && LabCommand.spawnToy(shape: "trap", target: "t", positionMM: [0, 0, 1], sizeMM: 7.9) == nil
          && LabCommand.spawnToy(shape: "trap", target: "t", positionMM: [0, 0, 1], sizeMM: 60.1) == nil
          && LabCommand.spawnToy(shape: "box", target: "b", positionMM: [0, 0, 1], sizeMM: 10) == nil
          && LabCommand.driveObject(target: "c", speedMMs: 0) == nil
          && LabCommand.driveObject(target: "c", speedMMs: 60.5) == nil
          && LabCommand.driveObject(target: "c", distanceMM: 300.5) == nil
          && LabCommand.driveObject(target: "", speedMMs: 20) == nil
          && LabCommand.equipGun(actorID: "", equipped: true) == nil
          && LabCommand.fireBB(actorID: "player", direction: [0, 0, 0]) == nil
          && LabCommand.fireBB(actorID: "player", direction: [.nan, 1, 0]) == nil)

    // The fire direction is the participant look forward — the same ray a grab uses.
    let pitchedLine = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":4,"sim_tick":40,"ok":true,"snapshot_seq":4,"world_revision":6,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[],"player":{"actor_id":"player","position_mm":[24,0,10.3],"orientation_quat_xyzw":[-0.099046,0.239118,0.369644,0.892399],"collision_radius_mm":2.5,"mode":"participate"}}"#
    let pitched = parseWorldRenderSnapshotLine(Data(pitchedLine.utf8))
    let aim = pitched?.player.flatMap { WorldViewer.participantAimRay(player: $0) }
    let aimFire = wire(aim.flatMap { LabCommand.fireBB(actorID: "player", direction: $0.direction) })
    let fireDir = aimFire["direction"] as? [Double] ?? []
    let fireNorm = sqrt(fireDir.reduce(0) { $0 + $1 * $1 })
    check("V5.6.2 fire_bb direction = participant aim forward, unit length",
          aim != nil && fireDir.count == 3 && abs(fireNorm - 1) < 1e-9
          && zip(fireDir, aim!.direction).allSatisfy { abs($0 - $1) < 1e-3 }
          && fireDir[2] < -0.1 && fireDir[1] > 0.1, "dir=\(fireDir)")

    // G/F/click routing through the real PlayerController + WorldViewer.
    let suite = "SiliconFly.PlayerInput.labtest.toys.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    store.removePersistentDomain(forName: suite)
    let player = PlayerController(defaults: store, lookRadiansPerPoint: 0.01)
    _ = player.setCaptureEnabled(true)
    let gunKey = player.bindings.keyCode(for: .gun), fireKey = player.bindings.keyCode(for: .fire)
    let forwardKey = player.bindings.keyCode(for: .forward)
    _ = player.handleKeyDown(keyCode: forwardKey, isRepeat: false)
    let fireUnequippedIntent = player.handleKeyDown(keyCode: fireKey, isRepeat: false)
    let fireUnequipped = player.takeToolAction(focusAllowsCapture: true)
    let gunIntent = player.handleKeyDown(keyCode: gunKey, isRepeat: false)
    let equipAction = player.takeToolAction(focusAllowsCapture: true)
    let clickBeforeAck = player.primaryClickAction(focusAllowsCapture: true)
    player.setGunEquipped(true)   // the equip_gun ACK
    _ = player.handleKeyDown(keyCode: fireKey, isRepeat: false)
    let fireEquipped = player.takeToolAction(focusAllowsCapture: true)
    _ = player.handleKeyDown(keyCode: fireKey, isRepeat: true)
    let fireRepeat = player.takeToolAction(focusAllowsCapture: true)
    _ = player.handleKeyDown(keyCode: gunKey, isRepeat: false)
    let holster = player.takeToolAction(focusAllowsCapture: true)
    let clickEquipped = player.primaryClickAction(focusAllowsCapture: true)
    let held = player.heldIntent()
    check("V5.6.2 G toggles equip, F fires only when equipped, never on key-repeat",
          player.bindings.keyCode(for: .gun) == 5 && fireKey == 3
          && fireUnequippedIntent == nil && fireUnequipped == nil
          && gunIntent == nil && equipAction == .equipGun(true) && clickBeforeAck == .grab
          && fireEquipped == .fire && fireRepeat == nil && holster == .equipGun(false)
          && clickEquipped == .fire,
          "unequipped=\(String(describing: fireUnequipped)) equip=\(String(describing: equipAction)) fire=\(String(describing: fireEquipped))")
    check("V5.6.2 tool keys are never held movement/actions",
          held.moveAxes == [1, 0] && held.heldActions.isEmpty)

    let viewer = WorldViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let textField = NSTextField(string: "typing f and g")
    var focusResponder: NSResponder = viewer
    var captures = 0
    var routed: [PlayerToolAction] = []
    viewer.onPlayerCaptureRequested = { captures += 1 }
    viewer.onPlayerPrimaryClick = {
        let focus = PlayerInputFocusPolicy.allowsCapture(windowIsKey: true, firstResponder: focusResponder,
                                                         viewer: viewer)
        if let action = player.primaryClickAction(focusAllowsCapture: focus) { routed.append(action) }
    }
    viewer.participateModeEnabled = false
    let observeClick = viewer.routeParticipateClick()
    viewer.participateModeEnabled = true
    let captureClick = viewer.routeParticipateClick()
    viewer.participateInputEnabled = true
    player.setGunEquipped(false)
    let grabClick = viewer.routeParticipateClick()
    player.setGunEquipped(true)
    _ = viewer.routeParticipateClick()
    check("V5.6.2 click: first captures, then fires when equipped and grabs when not",
          observeClick == .ignored && captureClick == .capture && captures == 1
          && grabClick == .action && routed == [.grab, .fire], "routed=\(routed)")

    focusResponder = textField
    let textFocus = PlayerInputFocusPolicy.allowsCapture(windowIsKey: true, firstResponder: textField,
                                                        viewer: viewer)
    _ = player.handleKeyDown(keyCode: fireKey, isRepeat: false)
    let textKeyFire = player.takeToolAction(focusAllowsCapture: textFocus)
    let routedBefore = routed.count
    _ = viewer.routeParticipateClick()
    let textClickRouted = routed.count != routedBefore
    _ = player.setCaptureEnabled(false)   // Esc / focus loss path
    let releasedClick = player.primaryClickAction(focusAllowsCapture: true)
    _ = player.handleKeyDown(keyCode: fireKey, isRepeat: false)
    let releasedFire = player.takeToolAction(focusAllowsCapture: true)
    check("V5.6.2 no fire while a text field has focus or capture is released",
          !textFocus && textKeyFire == nil && !textClickRouted
          && releasedClick == nil && releasedFire == nil)

    // Remap persistence round trip, including a swap and the upgrade path.
    _ = player.setCaptureEnabled(true)
    _ = player.rebind(.gun, to: 40, defaults: store)            // K
    _ = player.rebind(.fire, to: 40, defaults: store)           // swap: gun takes F
    let reloaded = PlayerKeyBindings(defaults: store)
    player.setGunEquipped(false)
    _ = player.handleKeyDown(keyCode: 3, isRepeat: false)      // F is now the gun key
    let remappedGun = player.takeToolAction(focusAllowsCapture: true)
    let upgradeSuite = "SiliconFly.PlayerInput.labtest.upgrade.\(UUID().uuidString)"
    let upgradeStore = UserDefaults(suiteName: upgradeSuite)!
    upgradeStore.removePersistentDomain(forName: upgradeSuite)
    upgradeStore.set(3, forKey: PlayerKeyBindings.preferencePrefix + "interact")  // pre-V5.6.2 custom F
    let upgraded = PlayerKeyBindings(defaults: upgradeStore)
    let upgradedCodes = PlayerControlAction.allCases.map { upgraded.keyCode(for: $0) }
    check("V5.6.2 gun/fire remap persists and older custom keys survive the upgrade",
          reloaded.keyCode(for: .fire) == 40 && reloaded.keyCode(for: .gun) == 3
          && remappedGun == .equipGun(true)
          && upgraded.keyCode(for: .interact) == 3 && upgraded.keyCode(for: .gun) == 5
          && upgraded.keyCode(for: .forward) == 13 && upgraded.keyCode(for: .fire) != 3
          && Set(upgradedCodes).count == upgradedCodes.count,
          "reloaded fire=\(reloaded.keyCode(for: .fire)) gun=\(reloaded.keyCode(for: .gun)) upgraded=\(upgradedCodes)")
    store.removePersistentDomain(forName: suite)
    upgradeStore.removePersistentDomain(forName: upgradeSuite)

    let enable = ["car", "trap", "box", "sphere", "wall", "food"].map { LabToy.actions(forShape: $0) }
    check("V5.6.2 Drive only for a car, Re-arm only for a trap",
          enable[0] == (true, false) && enable[1] == (false, true)
          && enable.dropFirst(2).allSatisfy { $0 == (false, false) }
          && LabToy.actions(forShape: nil) == (false, false))

    // New optional fields: present, absent (older backend) and malformed.
    let toyState = #"{"type":"lab_state","ack":1,"ok":true,"state":{"objects":[{"id":"trap_1","shape":"trap","position_mm":[40,0,10],"size_mm":[20,20,12],"yaw_deg":0,"trap_state":"closed"},{"id":"food_1","shape":"food","position_mm":[20,0,1.5],"size_mm":[3,3,3],"yaw_deg":0,"food_variant":"apple"},{"id":"box_1","shape":"box","position_mm":[1,0,5],"size_mm":[5,5,5],"yaw_deg":0}],"projectiles":[{"id":"bb_1","position_mm":[1,2,3]}]}}"#
    let oldState = #"{"type":"lab_state","state":{"objects":[{"id":"trap_1","shape":"trap","position_mm":[40,0,10],"size_mm":[20,20,12],"yaw_deg":0}]}}"#
    let badState = #"{"type":"lab_state","state":{"objects":[{"id":"trap_1","shape":"trap","position_mm":[40,0,10],"size_mm":[20,20,12],"yaw_deg":0,"trap_state":7,"food_variant":[1]}],"projectiles":"many"}}"#
    let toys = parseLabStateLine(Data(toyState.utf8))?.authoritativeObjects ?? []
    let old = parseLabStateLine(Data(oldState.utf8))
    let bad = parseLabStateLine(Data(badState.utf8))
    let renderTrap = #"{"id":"trap_1","shape":"trap","position_mm":[40,0,10],"orientation_quat_xyzw":[0,0,0,1],"size_mm":[20,20,12],"revision":1,"trap_state":"armed"}"#
    let renderOld = #"{"id":"trap_1","shape":"trap","position_mm":[40,0,10],"orientation_quat_xyzw":[0,0,0,1],"size_mm":[20,20,12],"revision":1}"#
    let decodedTrap = try? JSONDecoder().decode(WorldRenderObject.self, from: Data(renderTrap.utf8))
    let decodedOld = try? JSONDecoder().decode(WorldRenderObject.self, from: Data(renderOld.utf8))
    check("V5.6.2 trap_state/food_variant/projectiles decode when present",
          toys.count == 3 && toys[0].trapState == "closed" && toys[1].foodVariant == "apple"
          && toys[2].trapState == nil && toys[2].foodVariant == nil
          && parseLabStateLine(Data(toyState.utf8))?.worldState?.projectiles?.first?.id == "bb_1"
          && decodedTrap?.trapState == "armed"
          && LabToy.objectLine(toys[1]).contains("apple") && LabToy.objectLine(toys[0]).contains("closed"))
    check("V5.6.2 older/malformed toy fields decode as absent, never drop the state",
          old?.authoritativeObjects?.first?.trapState == nil && old?.worldState?.projectiles == nil
          && bad?.authoritativeObjects?.first?.id == "trap_1"
          && bad?.authoritativeObjects?.first?.trapState == nil
          && bad?.authoritativeObjects?.first?.foodVariant == nil && bad?.worldState?.projectiles == nil
          && decodedOld != nil && decodedOld?.trapState == nil)

    // Timeline wording: physical events with backend force units, no feelings.
    let hitLine = #"{"type":"lab_event","event":"car_hit_fly","data":{"id":"car_1","peak_normal_force":0.0123,"force_units":"mujoco_model","classification":"PHYSICAL","sim_tick_ms":1200}}"#
    let bbObject = #"{"type":"lab_event","event":"bb_hit_object","data":{"id":"bb_3","object_id":"box_1"}}"#
    let hit = parseLabEventLine(Data(hitLine.utf8))
    let bbHit = parseLabEventLine(Data(bbObject.utf8))
    let toyEvents = ["car_hit_fly", "car_blocked", "drive_complete", "trap_triggered", "trap_closed",
                     "trap_armed", "trap_blocked", "bb_fired", "bb_hit_fly", "bb_hit_object", "bb_expired"]
    let lines = toyEvents.map { LabToy.eventLine($0, hit?.detail) ?? "" }
    let feelings = ["pain", "hurt", "scared", "angry", "afraid", "feel", "suffer"]
    let hitText = LabToy.eventLine("car_hit_fly", hit?.detail) ?? ""
    check("V5.6.2 toy events read as physical events with force in model units",
          !lines.contains("") && hitText.contains("0.0123") && hitText.contains("model units")
          && (LabToy.eventLine("bb_hit_object", bbHit?.detail) ?? "").contains("box_1")
          && !lines.contains { line in feelings.contains { line.lowercased().contains($0) } }
          && LabToy.eventLine("object_grabbed", nil) == nil, hitText)

    // Feeding events (backend `lab_world.feeding_update`) get a timeline line in
    // both languages instead of the raw event name.
    let eaten = parseLabEventLine(Data(#"{"type":"lab_event","event":"food_eaten","data":{"id":"food_2","food_variant":"apple","contact_s":1.5}}"#.utf8))
    let feedLines = ["feeding_begin", "feeding_end", "food_eaten"].map { LabToy.eventLine($0, eaten?.detail) ?? "" }
    let eatenText = feedLines[2]
    check("V5.6.2 feeding events have their own wording, not the raw event name",
          !feedLines.contains("") && !feedLines.contains { $0.contains("_begin") || $0.contains("_end") || $0.contains("_eaten") }
          && eatenText.contains("food_2") && eatenText.contains(LabToy.foodName("apple")) && eatenText.contains("1.50")
          && !feedLines.contains { line in feelings.contains { line.lowercased().contains($0) } }
          && LabToy.eventLine("feeding_end", nil) != nil, feedLines.joined(separator: " | "))

    // SceneKit fallback draws car/trap boxes at their backend size.
    let toySnapshot = #"{"type":"world_render_snapshot","protocol_version":4,"session_id":"","epoch":0,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":9,"world_revision":3,"fly":{"id":"fly","position_mm":[1,2,0.7],"orientation_quat_xyzw":[0,0,0,1]},"objects":[{"id":"car_1","shape":"car","position_mm":[30,0,2.87],"orientation_quat_xyzw":[0,0,0,1],"size_mm":[14,6.16,5.74],"revision":1},{"id":"trap_1","shape":"trap","position_mm":[40,0,10],"orientation_quat_xyzw":[0,0,0,1],"size_mm":[20,20,12],"revision":1,"trap_state":"armed"}]}"#
    let fallback = WorldViewer(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    if let snap = parseWorldRenderSnapshotLine(Data(toySnapshot.utf8)) { fallback.apply(snapshot: snap) }
    let carBox = fallback.scene?.rootNode.childNode(withName: "car_1", recursively: false)?.geometry as? SCNBox
    let trapNode = fallback.scene?.rootNode.childNode(withName: "trap_1", recursively: false)
    let trapBox = trapNode?.geometry as? SCNBox
    check("V5.6.2 SceneKit fallback draws car/trap as sized boxes",
          carBox.map { abs($0.width - 14) < 1e-4 && abs($0.length - 6.16) < 1e-4 && abs($0.height - 5.74) < 1e-4 } == true
          && trapBox.map { abs($0.width - 20) < 1e-4 && abs($0.height - 12) < 1e-4 } == true
          && (trapBox?.firstMaterial?.transparency ?? 1) < 1,
          "car=\(String(describing: carBox)) trap=\(String(describing: trapBox))")
}
