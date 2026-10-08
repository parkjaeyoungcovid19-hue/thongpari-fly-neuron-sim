import Cocoa

final class LabParticipantController {
    let playerController = PlayerController()
    var interactionPresentation = LabInteractionPresentation()
    var playerCaptureArmed = false
    var lastPlayerInputConnectionGeneration: UInt64?
    var lastPlayerInputSeq: Int?
    var playerInputReconcilePending = false
    var gunCommandPending: (id: Int, equipped: Bool, sentAt: Date)?
    var lastFireCommandID: Int?
    var lastGunConnectionGeneration: UInt64?
    var gunNote: (text: String, color: NSColor, until: Date)?
    var participantCommandPending = ParticipantCommandPendingState()
    var participantTouchingFly = false
    var cameraBeforeParticipate: WorldViewerCameraMode?
}

import Cocoa
import SceneKit

extension LabWindowController {
    func playerInputFocusAllowsCapture() -> Bool {
        guard let window else { return false }
        return PlayerInputFocusPolicy.allowsCapture(
            windowIsKey: window.isKeyWindow,
            firstResponder: window.firstResponder,
            viewer: worldViewer)
    }

    func refreshInteractionStatus(state: LabInteractionState?) {
        var line = interactionPresentation.line(state: state)
        if viewState.mode == .participate && worldViewer.cameraState.mode == .behindParticipant {
            line += L(" · Third person: E grabs in the participant's forward direction",
                      " · 3인칭: E는 참여체 정면을 집습니다")
        }
        interactionStatusLabel.stringValue = line
        interactionStatusLabel.textColor = interactionPresentation.ignoredReason != nil
            || interactionPresentation.rejection == nil
            ? .secondaryLabelColor : .systemRed
    }

    private func showInteractionIgnored(_ reason: LabInteractionPresentation.IgnoredReason,
                                        state: LabInteractionState? = nil) {
        interactionPresentation.ignore(reason)
        refreshInteractionStatus(state: state)
    }

    func sendParticipantInteraction() {
        guard viewState.mode == .participate,
              playerController.captureEnabled, worldViewer.participateInputEnabled,
              playerInputFocusAllowsCapture() else { return }
        guard viewState.pendingMode == nil, viewState.sessionPhase == .running else {
            showInteractionIgnored(.waitingForSession)
            return
        }
        guard interactionPresentation.canAttempt() else {
            refreshInteractionStatus(state: bridge?.latestLabState()?.interaction)
            return
        }
        guard let bridge, bridge.labStateFreshness().isFresh,
              let interaction = bridge.latestLabState()?.interaction else {
            showInteractionIgnored(.waitingForState)
            return
        }
        guard let envelope = playerInputEnvelope(),
              let snapshot = bridge.latestWorldRenderSnapshot(maxAge: 1.0),
              snapshot.ok, let player = snapshot.player,
              player.id == "player",
              snapshot.sessionID == envelope.sessionID,
              snapshot.epoch == envelope.epoch else {
            showInteractionIgnored(.waitingForWorld, state: interaction)
            return
        }

        let toolID = interaction.heldObjectID == nil ? "grab" : "place"
        let ray = toolID == "grab" ? WorldViewer.participantAimRay(player: player) : nil
        if toolID == "grab" && ray == nil {
            showInteractionIgnored(.invalidAim, state: interaction)
            return
        }
        guard let id = send("interaction", target: interaction.heldObjectID,
                            toolID: toolID, actorID: player.id,
                            rayOriginMM: ray?.originMM,
                            rayDirection: ray?.direction,
                            scheduleOverride: LabCommandSchedule(
                                sessionID: envelope.sessionID, epoch: envelope.epoch,
                                requestedTick: envelope.requestedTick)) else {
            showInteractionIgnored(.queueUnavailable, state: interaction)
            return
        }
        interactionPresentation.begin(id: id, generation: bridge.connectionGeneration)
        refreshInteractionStatus(state: interaction)
    }

    func performParticipantTool(_ action: PlayerToolAction) {
        switch action {
        case .grab: sendParticipantInteraction()
        case .equipGun(let equipped): sendGunEquip(equipped)
        case .fire: fireBB()
        }
    }

    /// The authoritative participant pose and V4 envelope the gun commands use,
    /// matched to the current session exactly like a grab.
    private func participantToolContext() -> (player: WorldRenderPose, schedule: LabCommandSchedule)? {
        guard viewState.mode == .participate, viewState.pendingMode == nil,
              viewState.sessionPhase == .running, let bridge,
              let envelope = playerInputEnvelope(),
              let snapshot = bridge.latestWorldRenderSnapshot(maxAge: 1.0),
              snapshot.ok, let player = snapshot.player,
              snapshot.sessionID == envelope.sessionID,
              snapshot.epoch == envelope.epoch else { return nil }
        return (player, LabCommandSchedule(sessionID: envelope.sessionID, epoch: envelope.epoch,
                                           requestedTick: envelope.requestedTick))
    }

    private func sendGunEquip(_ equipped: Bool) {
        if let pending = gunCommandPending, Date().timeIntervalSince(pending.sentAt) < 3 { return }
        guard let context = participantToolContext(),
              let command = LabCommand.equipGun(actorID: context.player.id, equipped: equipped),
              let id = sendCommand(command, scheduleOverride: context.schedule) else {
            showGunNote(L("not sent — waiting for the participant snapshot",
                          "보내지 못함 — 참여자 화면을 기다리는 중"), color: .systemOrange)
            return
        }
        gunCommandPending = (id, equipped, Date())
        refreshGunStatus()
    }

    /// Direction = the participant's current look forward, the same ray a grab uses.
    private func fireBB() {
        guard playerController.gunEquipped,
              let context = participantToolContext(),
              let ray = WorldViewer.participantAimRay(player: context.player),
              let command = LabCommand.fireBB(actorID: context.player.id, direction: ray.direction),
              let id = sendCommand(command, scheduleOverride: context.schedule) else {
            showGunNote(L("shot not sent — waiting for the participant snapshot",
                          "발사를 보내지 못함 — 참여자 화면을 기다리는 중"), color: .systemOrange)
            return
        }
        lastFireCommandID = id
    }

    /// Gun state lives in the backend; the local mirror is dropped whenever the
    /// backend drops it (Observe mode, world reset, reconnect).
    func dropGunState() {
        playerController.setGunEquipped(false)
        gunCommandPending = nil
        lastFireCommandID = nil
        gunNote = nil
    }

    func showGunNote(_ text: String, color: NSColor) {
        gunNote = (text, color, Date().addingTimeInterval(4))
        refreshGunStatus()
    }

    func refreshGunStatus() {
        let now = Date()
        if let pending = gunCommandPending, now.timeIntervalSince(pending.sentAt) > 3 {
            gunCommandPending = nil
        }
        if let note = gunNote, now > note.until { gunNote = nil }
        let gunKey = PlayerKeyChoice.title(for: playerController.bindings.keyCode(for: .gun))
        let fireKey = PlayerKeyChoice.title(for: playerController.bindings.keyCode(for: .fire))
        let participating = viewState.mode == .participate
        var line: String
        if !participating {
            line = L("BB gun — available in Participate", "비비탄총 — 참여 모드에서 사용")
        } else if gunCommandPending != nil {
            line = L("BB gun — waiting for backend…", "비비탄총 — 시뮬레이터 확인 중…")
        } else if playerController.gunEquipped {
            line = L("Gun equipped · \(fireKey)/click fires · \(gunKey) holsters", "총 장착 · \(fireKey)/클릭 발사 · \(gunKey) 내려놓기")
        } else {
            line = L("BB gun — holstered · \(gunKey) equips", "비비탄총 — 내려놓음 · \(gunKey)로 들기")
        }
        if let note = gunNote { line += " · " + note.text }
        gunStatusLabel.stringValue = line
        gunStatusLabel.textColor = gunNote?.color
            ?? (playerController.gunEquipped ? .labelColor : .secondaryLabelColor)
        let showHUD = participating && playerController.gunEquipped
        gunHUDLabel.stringValue = L("Gun equipped · \(fireKey)/click fires", "총 장착 · \(fireKey)/클릭 발사")
        gunHUD?.isHidden = !showHUD
    }

    private func playerInputEnvelope(allowStaleSnapshotForRelease: Bool = false)
        -> (sessionID: String, epoch: Int, requestedTick: Int)? {
        guard let bridge, bridge.playerInputV5_5Available else { return nil }
        let session = coordinator.sessionSnapshot()
        if session.mode == .deterministic {
            guard session.phase == .running,
                  let schedule = coordinator.labCommandSchedule() else { return nil }
            // The deterministic schedule is already the authoritative exact
            // owner boundary. Requiring a render snapshot here can strand a held
            // key when focus is lost during a temporary viewer stall.
            return (schedule.sessionID, schedule.epoch, schedule.requestedTick)
        }

        guard coordinator.ensureInteractivePlayerInputSession() else { return nil }
        let current = coordinator.sessionSnapshot()
        let maxSnapshotAge = allowStaleSnapshotForRelease
            ? TimeInterval.greatestFiniteMagnitude : 1.0
        guard current.mode == .interactive, current.phase == .running else { return nil }
        if let snapshot = bridge.latestWorldRenderSnapshot(maxAge: maxSnapshotAge),
           snapshot.ok,
           snapshot.sessionID == current.sessionID,
           snapshot.epoch == current.epoch {
            if !allowStaleSnapshotForRelease && snapshot.player == nil { return nil }
            return (current.sessionID, current.epoch, snapshot.simTick)
        }
        if allowStaleSnapshotForRelease {
            // Safety neutralization must not depend on view freshness. Tick zero
            // is a conservative interactive provenance floor: Python still
            // validates session/epoch and applies at its current owner boundary,
            // rejecting only client claims that are in the future.
            return (current.sessionID, current.epoch, 0)
        }
        return nil
    }

    @discardableResult
    func sendPlayerInput(_ intent: PlayerInputIntent, reason: String,
                                 allowStaleSnapshotForRelease: Bool = false,
                                 discardPendingLook: Bool = false) -> Int? {
        guard let bridge,
              let envelope = playerInputEnvelope(
                allowStaleSnapshotForRelease: allowStaleSnapshotForRelease) else {
            playerInputStatusLabel.stringValue = L("Participant controls — waiting for authoritative session snapshot before \(reason)", "참여 조작 — 시뮬레이터 화면을 기다리는 중이라 입력을 보내지 못했습니다")
            playerInputStatusLabel.textColor = .systemOrange
            playerInputReconcilePending = true
            return nil
        }
        guard let seq = bridge.sendPlayerInput(
            sessionID: envelope.sessionID,
            epoch: envelope.epoch,
            requestedTick: envelope.requestedTick,
            moveAxes: intent.moveAxes,
            lookDelta: intent.lookDelta,
            heldActions: intent.heldActions,
            discardPendingLook: discardPendingLook) else {
            playerInputStatusLabel.stringValue = L("Participant controls — \(reason) was not queued", "참여 조작 — 입력을 보내지 못했습니다")
            playerInputStatusLabel.textColor = .systemOrange
            playerInputReconcilePending = true
            return nil
        }
        lastPlayerInputSeq = seq
        playerInputReconcilePending = false
        return seq
    }

    /// Called from the 10 Hz refresh. A neutral state may use the stale-snapshot
    /// release path; a still-moving state needs a fresh snapshot like key down.
    /// Only an already-running session is reconciled: this timer must never
    /// begin an interactive session the user did not request.
    func reconcilePlayerHeldInputIfNeeded() {
        guard playerInputReconcilePending else { return }
        guard bridge?.playerInputV5_5Available == true,
              viewState.mode == .participate else {
            // Disconnect releases held input on the backend, and leaving
            // Participate deactivates the participant; nothing to resend.
            playerInputReconcilePending = false
            return
        }
        guard coordinator.sessionSnapshot().phase == .running else { return }
        let held = playerController.heldIntent()
        // A neutral state is a safety release and drops unsent look, like
        // key up. A still-moving state keeps any queued look delta (F-03).
        sendPlayerInput(held, reason: "held-input reconcile",
                        allowStaleSnapshotForRelease: held.isNeutral,
                        discardPendingLook: held.isNeutral)
    }

    func releasePlayerHeldInput(reason: String) {
        playerCaptureArmed = false
        _ = playerController.releaseHeldInput(blockUntilFreshPress: true)
        _ = playerController.setCaptureEnabled(false)
        worldViewer.participateInputEnabled = false
        let neutral = playerController.heldIntent()
        sendPlayerInput(neutral, reason: reason,
                        allowStaleSnapshotForRelease: true,
                        discardPendingLook: true)
    }

    func playerKeyPopup(for action: PlayerControlAction) -> NSPopUpButton { playerKeys[action]! }


    func configureLookSensitivitySlider() {
        lookSensitivitySlider.doubleValue = playerController.lookRadiansPerPoint
        lookSensitivitySlider.isContinuous = true
        lookSensitivitySlider.target = self
        lookSensitivitySlider.action = #selector(lookSensitivityChanged(_:))
        lookSensitivitySlider.toolTip = L("Mouse-look speed while controlling the participant", "참여 조작 중 마우스로 둘러보는 속도")
    }

    @objc private func lookSensitivityChanged(_ sender: NSSlider) {
        playerController.setLookSensitivity(sender.doubleValue)
    }

    func configurePlayerKeyPopups() {
        for action in PlayerControlAction.allCases {
            let popup = playerKeyPopup(for: action)
            popup.removeAllItems()
            for choice in PlayerKeyChoice.remappable {
                popup.addItem(withTitle: choice.title)
                popup.lastItem?.representedObject = NSNumber(value: choice.keyCode)
            }
            popup.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            popup.target = self
            popup.action = #selector(playerKeyBindingChanged(_:))
        }
        syncPlayerKeyPopups()
    }

    private func syncPlayerKeyPopups() {
        for action in PlayerControlAction.allCases {
            let popup = playerKeyPopup(for: action)
            let code = playerController.bindings.keyCode(for: action)
            if let item = popup.itemArray.first(where: {
                ($0.representedObject as? NSNumber)?.uint16Value == code
            }) {
                popup.select(item)
            }
        }
    }

    @objc private func playerKeyBindingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = PlayerControlAction(rawValue: raw),
              let number = sender.selectedItem?.representedObject as? NSNumber else {
            syncPlayerKeyPopups()
            return
        }
        if let neutral = playerController.rebind(action, to: number.uint16Value) {
            sendPlayerInput(neutral, reason: "key remap",
                            allowStaleSnapshotForRelease: true,
                            discardPendingLook: true)
        }
        syncPlayerKeyPopups()
        refreshGunStatus()
        playerInputStatusLabel.stringValue = L("Participant controls — key mapping saved · Esc remains fixed safety release", "참여 조작 — 키 설정 저장됨 · Esc는 항상 해제 키입니다")
        playerInputStatusLabel.textColor = .secondaryLabelColor
    }
}
