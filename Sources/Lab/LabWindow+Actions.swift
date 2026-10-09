import Cocoa
import SceneKit

extension LabWindowController {
    @discardableResult
    func send(_ action: String, target: String? = nil,
                      x: Double? = nil, y: Double? = nil, z: Double? = nil,
                      size: Double? = nil, speed: Double? = nil,
                      strength: Double? = nil, durationMs: Int? = nil,
                      value: Double? = nil, directionDeg: Double? = nil,
                      endDistance: Double? = nil, physical: Bool? = nil,
                      sensory: Bool? = nil, continuous: Bool? = nil,
                      mode: String? = nil,
                      toolID: String? = nil, actorID: String? = nil,
                      rayOriginMM: [Double]? = nil,
                      rayDirection: [Double]? = nil,
                      scheduleOverride: LabCommandSchedule? = nil) -> Int? {
        let command: LabCommand
        if action == "interaction" {
            guard let toolID, let actorID,
                  let built = LabCommand.interaction(id: 0, toolID: toolID, actorID: actorID,
                                                     target: target, rayOriginMM: rayOriginMM,
                                                     rayDirection: rayDirection) else { return nil }
            command = built
        } else {
            command = LabCommand(id: 0, action: action, target: target,
                                 x: x, y: y, z: z, size: size, speed: speed,
                                 strength: strength, durationMs: durationMs, value: value,
                                 directionDeg: directionDeg, endDistance: endDistance,
                                 physical: physical, sensory: sensory, continuous: continuous, mode: mode)
        }
        return sendCommand(command, scheduleOverride: scheduleOverride)
    }

    func commandSchedule(explicit: LabCommandSchedule? = nil) -> LabCommandSchedule? {
        LabCommandSchedule.choose(explicit: explicit, fallback: coordinator.labCommandSchedule())
    }

    /// Sends a prebuilt V5.6.2 toy command with the same V4 envelope,
    /// timeline row and recorder mark as `send`.
    @discardableResult
    func sendCommand(_ command: LabCommand,
                             scheduleOverride: LabCommandSchedule? = nil) -> Int? {
        guard let bridge else {
            protocolLabel.stringValue = L("FlyGym bridge — disabled (launch with --flygym for physical-world controls)", "물리 시뮬레이터 꺼짐 — 물리 세계를 조작하려면 시뮬레이터와 함께 실행하세요")
            return nil
        }
        let schedule = commandSchedule(explicit: scheduleOverride)
        if command.action == "interaction" && schedule == nil { return nil }
        var command = command
        command.protocolVersion = schedule == nil ? nil : FlyGymProtocolV4.version
        command.sessionID = schedule?.sessionID
        command.epoch = schedule?.epoch
        command.requestedTick = schedule?.requestedTick
        let id = bridge.sendLabCommand(command)
        declareEventWindowIntent(command, id: id)
        noteSent(id: id, action: command.action, target: command.target ?? command.actorID,
                 schedule: schedule, bridge: bridge)
        return id
    }

    private func noteSent(id: Int, action: String, target: String?,
                          schedule: LabCommandSchedule?, bridge: FlyGymBridge) {
        lastCommandID = id
        lastCommandAction = action
        if let schedule {
            pendingCommandSchedules[id] = schedule
            if pendingCommandSchedules.count > 256,
               let oldest = pendingCommandSchedules.keys.min() {
                pendingCommandSchedules.removeValue(forKey: oldest)
            }
        }
        let session = coordinator.sessionSnapshot()
        timeline.append(LabTimelineEntry(
            commandID: id, action: action, detail: target ?? "",
            kind: .of(action: action),
            sessionID: schedule?.sessionID ?? session.sessionID,
            epoch: schedule?.epoch ?? session.epoch,
            requestedTick: schedule?.requestedTick ?? session.simTick,
            requestedAt: Date(), connectionGeneration: bridge.connectionGeneration,
            status: .requested))
        recorder.mark(kind: "lab_command", detail: "\(action) target=\(target ?? "-")", commandID: id,
                      sessionID: schedule?.sessionID ?? session.sessionID,
                      epoch: schedule?.epoch ?? session.epoch,
                      simTick: session.simTick, requestedTick: schedule?.requestedTick)
    }

    /// Timeline row for something that never waits on a backend ACK: direct
    /// neural stimulation, markers, session and recording requests.
    func noteLocal(_ action: String, _ detail: String = "", kind: LabTimelineKind,
                           status: LabTimelineStatus = .local, tick: Int? = nil) {
        let s = coordinator.sessionSnapshot()
        timeline.append(LabTimelineEntry(
            commandID: nil, action: action, detail: detail, kind: kind,
            sessionID: s.sessionID, epoch: s.epoch, requestedTick: tick ?? s.simTick,
            requestedAt: Date(), connectionGeneration: bridge?.connectionGeneration ?? 0,
            status: status))
    }

    /// The backend's own reason, before sending, when every slot of a shape is taken.
    private func slotBudgetMessage(for shape: String) -> String? {
        guard let state = bridge?.latestLabState(), let total = state.authoritativeSlotCapacity?[shape],
              let free = state.authoritativeSlotFree?[shape], free <= 0 else { return nil }
        return Self.slotBudgetText(shape: shape, total: total)
    }

    static func slotBudgetText(shape: String, total: Int?) -> String {
        let name = LabToy.shapeName(shape)
        let count = total.map { L(" (\($0) of \($0))", " (\($0)/\($0)개)") } ?? ""
        return L("every \(name) slot is in use\(count) — the simulator's object pools are fixed; delete one to make another",
                 "\(name) 자리를 모두 쓰고 있습니다\(count) — 시뮬레이터의 물체 자리 수는 고정이니, 하나를 지우면 다시 만들 수 있습니다")
    }

    @objc func createObject() {
        let shape = selectedValue(objectShape, fallback: "box")
        if let full = slotBudgetMessage(for: shape) {
            worldObjectStatusLabel.stringValue = L("Object status — not sent · ", "물체 상태 — 보내지 않음 · ") + full
            worldObjectStatusLabel.textColor = .systemOrange
            return
        }
        let objectTarget = creationTarget(for: shape)
        let action: String
        switch shape {
        case "sphere": action = "spawn_sphere"
        case "wall": action = "spawn_wall"
        case "food": action = "spawn_food"
        case "car", "trap": action = "spawn_object"
        default: action = "spawn_box"
        }
        let sent: Int?
        if let range = LabToy.sizeRangeMM(shape: shape) {
            // Scalar length/side; Z follows the size so a car rests on the lawn
            // and a trap starts armed, whatever the Z field held.
            let fallback = shape == "car" ? LabToy.carDefaultLengthMM : LabToy.trapDefaultSideMM
            let size = min(range.upperBound, max(range.lowerBound, d(objectSize, fallback: fallback)))
            let z = LabToy.spawnCenterZ(shape: shape, sizeMM: size)
            objectSize.stringValue = String(format: "%g", size)
            objectZ.stringValue = String(format: "%.2f", z)
            sent = LabCommand.spawnToy(shape: shape, target: objectTarget,
                                       positionMM: [d(objectX), d(objectY), z], sizeMM: size)
                .flatMap { sendCommand($0) }
        } else if shape == "ramp" {
            // Laid flush with the lawn at the default tilt; tilt it later in Edit mode.
            let size = LabRamp.size(lengthMM: d(objectSize, fallback: LabRamp.defaultLengthMM))
            let z = LabRamp.flushCenterZ(sizeMM: size, pitchDeg: LabRamp.defaultPitchDeg)
            objectSize.stringValue = String(format: "%g", size[0])
            objectZ.stringValue = String(format: "%.2f", z)
            sent = LabCommand.spawnRamp(target: objectTarget, positionMM: [d(objectX), d(objectY), z],
                                        sizeMM: size, pitchDeg: LabRamp.defaultPitchDeg)
                .flatMap { sendCommand($0) }
        } else {
            sent = send(action, target: objectTarget, x: d(objectX), y: d(objectY), z: d(objectZ),
                        size: max(0.1, d(objectSize, fallback: 5)))
        }
        trackObjectCommand(sent, target: objectTarget,
                           describe: L("create \(shape) ‘\(objectTarget)’", "‘\(objectTarget)’ 만들기"))
    }
    @objc func moveObject() {
        let objectTarget = target
        selectSent(send("move_object", target: objectTarget, x: d(objectX), y: d(objectY), z: d(objectZ)),
                   target: objectTarget, describe: L("move ‘\(objectTarget)’", "‘\(objectTarget)’ 옮기기"))
    }
    @objc func resizeObject() {
        let objectTarget = target
        selectSent(send("resize_object", target: objectTarget, size: max(0.1, d(objectSize, fallback: 5))),
                   target: objectTarget, describe: L("resize ‘\(objectTarget)’", "‘\(objectTarget)’ 크기 바꾸기"))
    }
    @objc func deleteObject() {
        let objectTarget = target
        selectSent(send("delete_object", target: objectTarget),
                   target: objectTarget, describe: L("delete ‘\(objectTarget)’", "‘\(objectTarget)’ 지우기"))
    }
    @objc func approachObject() {
        let objectTarget = target
        selectSent(send("approach_object", target: objectTarget,
                        speed: max(0.1, d(objectSpeed, fallback: 12)),
                        endDistance: max(0.5, d(objectEndDistance, fallback: 8))),
                   target: objectTarget, describe: L("approach ‘\(objectTarget)’", "‘\(objectTarget)’ 다가가기"))
    }

    /// Points the object status line at this command, so it shows this
    /// command's own ACK — never a stale result from an earlier one.
    private func trackObjectCommand(_ id: Int?, target: String?, describe: String) {
        guard let id else {
            worldObjectStatusLabel.stringValue = L("Object status — \(describe) was not sent", "물체 상태 — \(describe) 요청을 보내지 못했습니다")
            worldObjectStatusLabel.textColor = .systemOrange
            return
        }
        lastObjectCommandID = id
        lastObjectCommandTarget = target
        lastObjectCommandDescription = describe
        worldObjectStatusLabel.stringValue = L("Object status — sending \(describe)…", "물체 상태 — \(describe) 요청 보냄…")
        worldObjectStatusLabel.textColor = .secondaryLabelColor
    }

    private func selectSent(_ id: Int?, target: String?, describe: String) {
        trackObjectCommand(id, target: target, describe: describe)
        guard id != nil else { return }
        viewState.selectObject(target)
        renderViewState()
    }
    /// Shape of the object named in the Name field, from the latest lab_state.
    private func namedObject() -> LabWorldObjectRemote? {
        let name = objectID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return bridge?.latestLabState()?.authoritativeObjects?.first { $0.id == name }
    }

    private func sendToyAction(_ command: LabCommand?, describe: String) {
        selectSent(command.flatMap { sendCommand($0) }, target: command?.target, describe: describe)
    }

    @objc func driveSelectedCar() {
        guard let car = namedObject(), LabToy.actions(forShape: car.shape).drive else { return }
        let speed = min(60, max(1, d(driveSpeed, fallback: LabToy.driveSpeedMMs)))
        let distance = min(300, max(1, d(driveDistance, fallback: LabToy.driveDistanceMM)))
        driveSpeed.stringValue = String(format: "%g", speed)
        driveDistance.stringValue = String(format: "%g", distance)
        sendToyAction(LabCommand.driveObject(target: car.id, speedMMs: speed, distanceMM: distance),
                      describe: L("drive ‘\(car.id)’", "‘\(car.id)’ 주행"))
    }

    @objc func rearmSelectedTrap() {
        guard let trap = namedObject(), LabToy.actions(forShape: trap.shape).rearm else { return }
        sendToyAction(LabCommand.armTrap(target: trap.id),
                      describe: L("re-arm ‘\(trap.id)’", "‘\(trap.id)’ 다시 설치"))
    }

    /// Selected-object inspector, object list and toy button enablement (10 Hz).
    func refreshToyInspector(objects: [LabWorldObjectRemote]?) {
        let named = namedObject()
        let actions = LabToy.actions(forShape: named?.shape)
        driveButton?.isEnabled = actions.drive
        rearmButton?.isEnabled = actions.rearm
        if let named {
            toyTargetLabel.stringValue = L("Selected — ", "선택한 물체 — ") + LabToy.objectLine(named)
        } else {
            toyTargetLabel.stringValue = L("Selected — type or pick a car or trap name above", "선택한 물체 — 위 ‘이름’ 칸에 자동차나 함정 이름을 적거나 3D 화면에서 고르세요")
        }
        let rows = (objects ?? []).sorted { $0.id < $1.id }.map(LabToy.objectLine)
        objectListLabel.stringValue = rows.isEmpty ? L("Objects — none", "물체 목록 — 없음")
            : (rows.prefix(12) + (rows.count > 12 ? ["… +\(rows.count - 12)"] : [])).joined(separator: "\n")
    }

    @objc func resetWorld() {
        releasePlayerHeldInput(reason: "world reset")
        dropGunState()   // the backend world reset holsters the gun
        clearEyePending()
        environmentPanel.clearFeedback()
        if !coordinator.requestDeterministicReset(scopes: ["world", "modeled"]) {
            coordinator.labResetModeledStimuli()
            send("reset_world")
        }
        recorder.mark(kind: "reset", detail: "world+modeled environment")
    }
    @objc func resetBody() {
        releasePlayerHeldInput(reason: "body reset")
        if !coordinator.requestDeterministicReset(scopes: ["body"]) { send("reset_body") }
        recorder.mark(kind: "reset", detail: "body")
    }
    @objc func resetBrain() {
        if !coordinator.requestDeterministicReset(scopes: ["brain"]) { coordinator.labResetBrain() }
        recorder.mark(kind: "reset", detail: "brain")
    }
    @objc func resetAll() {
        releasePlayerHeldInput(reason: "full reset")
        dropGunState()
        clearEyePending()
        environmentPanel.clearFeedback()
        if !coordinator.requestDeterministicReset(scopes: ["brain", "body", "world", "modeled"]) {
            coordinator.labResetBrain()
            coordinator.labResetModeledStimuli()
            send("reset_world")
            send("reset_body")
            send("restore_eyes")
        }
        neuralGraph.clear(); sensoryGraph.clear(); flywireSensoryGraph.clear(); bodyGraph.clear(); visionGraph.clear()
        commandGraph.clear()
        moodEstimator.reset()
        recorder.mark(kind: "reset", detail: "all")
    }

    func eye(_ side: String, covered: Bool) {
        guard eyeCommandPendingID == nil else {
            commandDiagnosticsLabel.stringValue = L("Commands — eye change waiting for previous eye command acknowledgement", "명령 — 이전 눈 명령이 확인되기를 기다리는 중")
            return
        }
        if let id = send("set_eye_state", target: side, value: covered ? 1 : 0) {
            eyeCommandPendingID = id
            eyeCommandStartedAt = Date()
            eyeCommandSide = side
            eyeCommandCovered = covered
        }
    }

    @objc func applyFlash() {
        let eye = selectedValue(flashEye, fallback: "both")
        let intensity = max(0, min(1, d(flashIntensity, fallback: 1)))
        let duration = ms(flashDuration, fallback: 100)
        send("flash_eye", target: eye, strength: intensity, durationMs: duration)
        recorder.mark(kind: "sensory_model", detail: "flash eye=\(eye) intensity=\(intensity) duration_ms=\(duration)")
    }

    /// A timed puff is an action, not the panel's continuous-wind setting: it
    /// borrows the panel's strength, direction and switches and then stops.
    @objc func applyWindPuff() {
        let panel = environmentPanel
        sendWindPuff(strength: max(0.01, (panel.windStrengthSlider.doubleValue * 100).rounded() / 100),
                     directionDeg: EnvironmentPanel.worldDeg(dialValue: panel.windDirectionDial.doubleValue).rounded(),
                     durationMs: ms(windDuration, fallback: 500),
                     physical: panel.windPhysical.state == .on, sensory: panel.windSensory.state == .on)
    }

    private func sendWindPuff(strength: Double, directionDeg: Double, durationMs: Int,
                              physical: Bool, sensory: Bool) {
        if sensory {
            coordinator.labApplyWind(strength: Float(strength), directionDeg: directionDeg,
                                     durationMs: durationMs, continuous: false)
        } else {
            coordinator.labStopWind()
        }
        send("wind", strength: strength, durationMs: durationMs, directionDeg: directionDeg,
             physical: physical, sensory: sensory, continuous: false)
        recorder.mark(kind: physical ? "physical" : "sensory_model",
                      detail: "wind puff strength=\(strength) dir=\(directionDeg) duration_ms=\(durationMs) physical=\(physical) sensory=\(sensory)")
    }

    @objc func stopWind() {
        coordinator.labStopWind()
        send("stop_wind")
        recorder.mark(kind: "stimulus_off", detail: "wind")
    }

    @objc func placeFoodInFront() {
        guard let body = bridge?.latestBody() else {
            foodStatusLabel.stringValue = L("No fresh body data — start the physics simulator first", "새 몸 데이터 없음 — 물리 시뮬레이터를 먼저 실행하세요")
            foodStatusLabel.textColor = .systemOrange
            foodStatusLabel.isHidden = false
            return
        }
        let variant = selectedValue(foodVariant, fallback: "apple")
        var command = LabCommand(id: 0, action: "spawn_food")
        command.x = body.positionXmm + 15 * cos(body.headingRad)
        command.y = body.positionYmm + 15 * sin(body.headingRad)
        command.z = 1.5
        command.variant = variant
        lastFoodCommandID = sendCommand(command)
        foodStatusLabel.stringValue = lastFoodCommandID == nil ? L("Command not sent", "명령 전송 실패")
            : L("Placing ", "놓는 중: ") + LabToy.foodName(variant) + "…"
        foodStatusLabel.textColor = .secondaryLabelColor
        foodStatusLabel.isHidden = false
    }

    @objc func applyTouch() {
        let strength = max(0, min(1, d(touchStrength, fallback: 0.55)))
        let duration = ms(touchDuration, fallback: 150)
        let bodyTarget = selectedValue(touchTarget, fallback: "thorax")
        coordinator.labApplyTouch(strength: Float(strength), durationMs: duration)
        moodEstimator.registerHit(strength: strength)
        send("touch", target: bodyTarget, strength: strength, durationMs: duration)
        recorder.mark(kind: "physical+sensory_model", detail: "touch target=\(bodyTarget) strength=\(strength) duration_ms=\(duration)")
    }

    @objc func resetSenses() {
        coordinator.labResetModeledStimuli()
        clearEyePending()
        send("stop_wind")
        send("restore_eyes")
        send("temperature", value: 25, mode: "environment_only")
        recorder.mark(kind: "reset", detail: "modeled sensory interventions")
    }

    private func recordDirectNeural(detail: String) {
        let session = coordinator.sessionSnapshot(), schedule = coordinator.labCommandSchedule()
        recorder.mark(kind: "direct_neural", detail: detail,
                      sessionID: session.sessionID, epoch: session.epoch, simTick: session.simTick,
                      requestedTick: schedule?.requestedTick, appliedTick: nil,
                      appliedEpoch: nil,
                      status: schedule == nil ? "queued_local" : "scheduled_local_boundary")
    }

    /// A point-cloud click stimulates neurons directly; record it like the
    /// population button so every direct neural intervention is on the timeline.
    func noteBrainClickStimulus(count: Int, name: String, strength: Float, durationMs: Int) {
        let schedule = coordinator.labCommandSchedule()
        noteLocal("stimulate", "brain click \(name) (\(count) neurons) ×\(strength) \(durationMs) ms",
                  kind: .directNeural, tick: schedule?.requestedTick)
        recordDirectNeural(detail: "brain_click cluster=\(name) neurons=\(count) strength=\(strength) duration_ms=\(durationMs)")
    }

    @objc func stimulateBrain() {
        let role = selectedValue(brainRole, fallback: "GF")
        let strength = Float(max(0, min(2, d(brainStrength, fallback: 0.3))))
        let duration = ms(brainDuration, fallback: 300)
        let schedule = coordinator.labCommandSchedule()
        coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
        noteLocal("stimulate", "\(role) ×\(strength) \(duration) ms", kind: .directNeural,
                  tick: schedule?.requestedTick)
        recordDirectNeural(detail: "role=\(role) strength=\(strength) duration_ms=\(duration)")
    }

    private func runPreset(_ name: String) {
        lastPreset = name
        recorder.mark(kind: "preset", detail: name)
        switch name {
        case "frontal_loom", "left_loom", "right_loom", "left_eye_covered_loom":
            if coordinator.requestDeterministicReset(
                scopes: ["brain", "body", "world", "modeled"],
                after: { [weak self] in self?.runLoomPresetAfterReset(name) }) {
                return
            }
            coordinator.labResetBrain()
            coordinator.labResetModeledStimuli()
            send("reset_world"); send("reset_body")
            runLoomPresetAfterReset(name)
        case "wind_puff":
            sendWindPuff(strength: 0.7, directionDeg: 0, durationMs: 500, physical: true, sensory: true)
        case "thorax_touch":
            selectPopupValue(touchTarget, "thorax")
            touchStrength.stringValue = "0.55"; touchDuration.stringValue = "150"
            applyTouch()
        case "gf": presetStim(role: "GF", strength: 0.5, duration: 40)
        case "dna_left": presetStim(role: "DNa-left", strength: 0.3, duration: 900)
        case "dna_right": presetStim(role: "DNa-right", strength: 0.3, duration: 900)
        case "mdn": presetStim(role: "MDN", strength: 0.3, duration: 600)
        case "dnp09": presetStim(role: "DNp09", strength: 0.25, duration: 1200)
        default: break
        }
    }

    private func presetStim(role: String, strength: Float, duration: Int) {
        if coordinator.requestDeterministicReset(
            scopes: ["brain"],
            after: { [weak self] in
                guard let self else { return }
                self.coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
                let schedule = self.coordinator.labCommandSchedule()
                self.noteLocal("stimulate", "preset \(role) ×\(strength) \(duration) ms",
                               kind: .directNeural, tick: schedule?.requestedTick)
                self.recordDirectNeural(detail: "preset role=\(role) strength=\(strength) duration_ms=\(duration)")
            }) {
            return
        }
        coordinator.labResetBrain()
        coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
        noteLocal("stimulate", "preset \(role) ×\(strength) \(duration) ms", kind: .directNeural)
        recordDirectNeural(detail: "preset role=\(role) strength=\(strength) duration_ms=\(duration)")
    }

    private func runLoomPresetAfterReset(_ name: String) {
        clearEyePending()
        if name == "left_eye_covered_loom" { eye("left", covered: true) }
        let y: Double = name == "left_loom" ? 22 : (name == "right_loom" ? -22 : 0)
        let id = "preset_loom"
        send("spawn_box", target: id, x: 60, y: y, z: 5, size: 10)
        send("approach_object", target: id, speed: 80, endDistance: 8)
    }

    @objc func presetSelected(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        runPreset(id)
    }
    @objc func replayLastPreset() {
        guard let lastPreset else {
            noteLocal("preset", "nothing to replay yet", kind: .marker, status: .rejected)
            return
        }
        runPreset(lastPreset)
    }

    @objc func clearGraphs() {
        graphs.forEach { $0.clear() }
        recorder.mark(kind: "ui", detail: "graphs cleared")
    }

    @objc func startRecording() {
        // The workspace status already shows L("Saving…", "저장 중…") until the flush completes.
        if recorder.isStopping { return }
        let session = coordinator.sessionSnapshot()
        var metadata: [String: Any] = [
            "protocol_version": FlyGymProtocolV4.version,
            "session_id": session.sessionID,
            "session_mode": session.mode.rawValue,
            "initial_epoch": session.epoch,
            "initial_sim_tick": session.simTick,
            "neural_tick_ms": 1,
            "experiment_quantum_ticks": session.quantumTicks,
            "experiment_quantum_ms": session.quantumTicks,
        ]
        if let hello = bridge?.serverHello() {
            metadata["backend_physics_timestep_s"] = hello.physicsTimestepS as Any
            metadata["backend_capabilities"] = hello.capabilities
            metadata["backend_supported_quantum_ticks"] = hello.supportedQuantumTicks
        }
        if let p = recorder.start(metadata: metadata) {
            recordingPresentation.startedAt = Date()
            recordingPresentation.outcome = .idle
            noteLocal("recording", "start → \(p)", kind: .recording)
        } else {
            recordingPresentation.outcome = .failed(path: nil, message: recorder.lastErrorMessage ?? "see stderr")
        }
        refreshWorkspace()
    }

    @objc func startDeterministicSession() {
        releasePlayerHeldInput(reason: "session change")
        if let error = coordinator.startDeterministicSession() {
            sessionStatusLabel.stringValue = "Session — deterministic unavailable: \(error)"
            sessionStatusLabel.textColor = .systemOrange
            return
        }
        let s = coordinator.sessionSnapshot()
        sessionStatusLabel.textColor = .labelColor
        noteLocal("session", "deterministic begin", kind: .session)
        recorder.mark(kind: "session_begin", detail: "deterministic V4",
                      sessionID: s.sessionID, epoch: s.epoch, simTick: s.simTick,
                      status: s.phase.rawValue)
    }

    @objc func pauseSession() {
        releasePlayerHeldInput(reason: "pause")
        let before = coordinator.sessionSnapshot()
        coordinator.requestSessionPause()
        noteLocal("session", "pause requested", kind: .session)
        recorder.mark(kind: "pause_requested", detail: before.mode.rawValue,
                      sessionID: before.sessionID, epoch: before.epoch, simTick: before.simTick,
                      status: before.phase.rawValue)
    }

    @objc func resumeSession() {
        let before = coordinator.sessionSnapshot()
        coordinator.requestSessionResume()
        noteLocal("session", "resume requested", kind: .session)
        recorder.mark(kind: "resume_requested", detail: before.mode.rawValue,
                      sessionID: before.sessionID, epoch: before.epoch, simTick: before.simTick,
                      status: before.phase.rawValue)
    }
    @objc func stopRecording() {
        guard recorder.isRecording || recorder.isStopping else { return }
        noteLocal("recording", "stop requested", kind: .recording)
        recorder.stop { [weak self] outcome in
            DispatchQueue.main.async { self?.noteRecordingOutcome(outcome) }
        }
        refreshWorkspace()
    }

    private func noteRecordingOutcome(_ outcome: ExperimentRecorderStopOutcome) {
        switch outcome {
        case .saved(let path):
            recordingPresentation.outcome = .saved(path: path)
            noteLocal("recording", "saved", kind: .recording)
        case .failed(let path, let message):
            recordingPresentation.outcome = .failed(path: path, message: message)
            noteLocal("recording", "save failed: \(message)", kind: .recording, status: .rejected)
        case .notRecording:
            break
        }
        recordingPresentation.startedAt = nil
        refreshWorkspace()
    }

    @objc func restartBackend() {
        guard let service, service.canRestart else { return }
        noteLocal("backend", "restart \(service.mode.rawValue) on port \(service.port)", kind: .session)
        service.start()
        refreshWorkspace()
    }

    /// App termination waits for the same recorder drain/close completion as the
    /// manual Stop button. The caller decides when to reply to AppKit's quit request.
    func prepareForApplicationTermination(completion: @escaping (ExperimentRecorderStopOutcome) -> Void) {
        guard recorder.isRecording || recorder.isStopping else {
            // Keep AppDelegate's terminateLater/reply ordering asynchronous even
            // if a manual Stop finishes in the narrow gap before this call.
            let outcome = ExperimentRecorderStopOutcome.notRecording(path: recorder.path)
            DispatchQueue.main.async { completion(outcome) }
            return
        }
        noteLocal("recording", "stop for quit", kind: .recording)
        recorder.stop(reason: "application quit") { [weak self] outcome in
            DispatchQueue.main.async {
                self?.noteRecordingOutcome(outcome)
                completion(outcome)
            }
        }
        refreshWorkspace()
    }

    /// A failed recorder drain must not disappear with the app. Keep the Lab
    /// window alive, show the exact failure/path, and require an explicit choice
    /// before AppDelegate replies to AppKit's pending termination request.
    func presentTerminationSaveFailure(path: String?, message: String,
                                       completion: @escaping (Bool) -> Void) {
        let whereText = path.map { L("\n\nPartial recording files remain at:\n", "\n\n저장된 일부 기록 파일 위치:\n") + $0 } ?? ""
        recordingPresentation.outcome = .failed(path: path, message: message)
        refreshWorkspace()
        show()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Recording could not be saved completely", "기록을 완전히 저장하지 못했습니다")
        alert.informativeText = L("The app will stay open by default so you can inspect the recording and retry a new recording if needed. Already-lost queued data cannot be reconstructed automatically.\n\nError: ", "기록을 확인하고 필요하면 다시 기록할 수 있도록 앱은 기본적으로 열어 둡니다. 이미 잃어버린 데이터는 자동으로 되살릴 수 없습니다.\n\n오류: ") + message + whereText
        alert.addButton(withTitle: L("Keep App Open", "앱 열어두기"))
        alert.addButton(withTitle: L("Quit Anyway", "그래도 종료"))

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertSecondButtonReturn)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
    private func markTimeline(_ detail: String) {
        let session = coordinator.sessionSnapshot()
        noteLocal("marker", detail, kind: .marker, status: .marker)
        recorder.mark(kind: "marker", detail: detail,
                      sessionID: session.sessionID, epoch: session.epoch, simTick: session.simTick)
    }

    @objc func markerSelected(_ sender: NSButton) {
        if let marker = sender.identifier?.rawValue { markTimeline(marker) }
    }
    func markerButton(_ title: String, _ marker: String) -> NSButton {
        let result = button(title, #selector(markerSelected(_:)))
        result.identifier = NSUserInterfaceItemIdentifier(marker)
        return result
    }

    func updateMood(_ t: LabTelemetry, now: Date) {
        var inputs = FlyMoodInputs()
        inputs.foodOdor = max(t.bodyOdorL, t.bodyOdorR)
        inputs.nearestFoodMM = t.bodyNearestFoodDistanceMm
        inputs.temperatureC = t.temperatureC
        inputs.escape = t.brainEscape
        inputs.nervous = t.brainNervous
        inputs.sleep = t.brainSleep
        inputs.grooming = t.brainGroomDrive
        let reading = moodEstimator.update(inputs, now: now)
        moodEmoji.stringValue = reading.mood.emoji
        moodTitle.stringValue = reading.mood.title
        moodReason.stringValue = reading.reason
        moodTitle.superview?.superview?.setAccessibilityValue("\(reading.mood.title) — \(reading.reason)")
    }

    /// The participant body bumping into the fly counts as a hit for the mood
    /// readout (edge-triggered: one hit per contact, not per frame).
    func noteParticipantContact(_ snapshot: WorldRenderSnapshot) {
        guard let player = snapshot.player, let fly = snapshot.fly,
              player.positionMM.count == 3, fly.positionMM.count == 3 else {
            participantTouchingFly = false
            return
        }
        let d = sqrt(zip(player.positionMM, fly.positionMM).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
        let touching = d < (player.collisionRadiusMM ?? 2.5) + 1.5
        if touching && !participantTouchingFly { moodEstimator.registerHit(strength: 0.6) }
        participantTouchingFly = touching
    }

    func onOff(_ on: Bool) -> String { on ? L("ON", "켬") : L("OFF", "끔") }
}
