// LabViewState.swift — V5.2 presentation-state ownership for the integrated Lab.
//
// Simulation/session authority stays in LabSession/Python. This type owns only
// what the AppKit screen needs to present consistently across panels: current
// view mode, selected fly/object, timeline tick, pause phase, and the identity
// of the atomic world snapshot being shown.

import Foundation

enum LabViewMode: String, CaseIterable, Codable {
    case observe
    case participate
    case edit

    var title: String {
        switch self {
        case .observe: return "Observe"
        case .participate: return "Participate"
        case .edit: return "Edit"
        }
    }
}

struct ParticipantCommandPendingState: Equatable {
    private(set) var commandID: Int?
    private(set) var connectionGeneration: UInt64?

    var isPending: Bool { commandID != nil }

    mutating func begin(commandID: Int, connectionGeneration: UInt64) {
        self.commandID = commandID
        self.connectionGeneration = connectionGeneration
    }

    mutating func consumeAck(commandID: Int) -> Bool {
        guard self.commandID == commandID else { return false }
        clear()
        return true
    }

    @discardableResult
    mutating func clearIfViewerLifecycleInvalid(playerAvailable: Bool,
                                                connectionGeneration: UInt64) -> Bool {
        guard isPending else { return false }
        guard !playerAvailable || self.connectionGeneration != connectionGeneration else {
            return false
        }
        clear()
        return true
    }

    mutating func clear() {
        commandID = nil
        connectionGeneration = nil
    }
}

struct LabViewState: Equatable {
    var mode: LabViewMode = .observe
    var pendingMode: LabViewMode?
    var selectedFlyID: String? = "fly"
    var selectedObjectID: String?
    var selectedPlayerID: String?

    var timelineTick: Int = 0
    var sessionMode: LabSessionMode = .interactive
    var sessionPhase: LabSessionPhase = .running
    var sessionID: String = ""
    var epoch: Int = 0
    var lastBodyResultTick: Int?
    var sessionError: String?

    var viewerAvailable = false
    var connectionGeneration: UInt64 = 0
    var snapshotSeq: Int?
    var worldRevision: Int?
    var snapshotTick: Int?

    mutating func sync(session: LabSessionSnapshot) {
        sessionMode = session.mode
        sessionPhase = session.phase
        sessionID = session.sessionID
        epoch = session.epoch
        timelineTick = max(0, session.simTick)
        lastBodyResultTick = session.lastBodyResultTick
        sessionError = session.lastError
    }

    mutating func setViewerAvailable(_ available: Bool) {
        viewerAvailable = available
        if !available {
            mode = .observe
            pendingMode = nil
            clearViewerIdentity(clearObjectSelection: true)
        }
    }

    mutating func accept(snapshot: WorldRenderSnapshot, connectionGeneration: UInt64) {
        guard snapshot.ok else { return }
        self.connectionGeneration = connectionGeneration
        snapshotSeq = snapshot.snapshotID
        worldRevision = snapshot.revision
        snapshotTick = snapshot.simTick
        if let fly = snapshot.fly { selectedFlyID = selectedFlyID ?? fly.id }
        if snapshot.player == nil { selectedPlayerID = nil }
        if let selectedObjectID,
           !snapshot.objects.contains(where: { $0.id == selectedObjectID }) {
            self.selectedObjectID = nil
        }
        let backendMode: LabViewMode = snapshot.player == nil ? .observe : .participate
        if let pendingMode {
            if pendingMode == backendMode {
                mode = backendMode
                self.pendingMode = nil
            }
        } else if mode != .edit {
            // The player body in the atomic backend snapshot is authoritative for
            // whether the user is actually participating. UI intent alone cannot
            // claim a mode that the physical world does not contain.
            mode = backendMode
        }
    }

    mutating func clearViewerIdentity(clearObjectSelection: Bool) {
        snapshotSeq = nil
        worldRevision = nil
        snapshotTick = nil
        connectionGeneration = 0
        if clearObjectSelection {
            selectedObjectID = nil
            selectedPlayerID = nil
        }
    }

    mutating func beginModeTransition(to target: LabViewMode) {
        pendingMode = target
    }

    mutating func rejectModeTransition() {
        pendingMode = nil
    }

    mutating func selectObject(_ id: String?) {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selectedObjectID = trimmed.isEmpty ? nil : trimmed
    }

    mutating func apply(pick: RayPickResult) {
        guard pick.ok, pick.hit, let targetID = pick.targetID,
              let targetKind = pick.targetKind else { return }
        switch targetKind {
        case "fly":
            selectedFlyID = targetID
        case "lab_object":
            selectObject(targetID)
        case "player":
            selectedPlayerID = targetID
        default:
            break
        }
    }

    var phaseBadge: String {
        switch sessionPhase {
        case .paused: return "PAUSED"
        case .pausing: return "PAUSING"
        case .resuming: return "RESUMING"
        case .resetting: return "RESETTING"
        case .starting: return "STARTING"
        case .failed: return "FAILED"
        case .running: return "RUNNING"
        }
    }

    var selectionSummary: String {
        let fly = selectedFlyID ?? "none"
        let object = selectedObjectID ?? "none"
        let player = selectedPlayerID ?? "none"
        return "fly \(fly) · player \(player) · object \(object)"
    }

    var commonStatusLine: String {
        let transition = pendingMode.map { " → \($0.title.uppercased()) PENDING" } ?? ""
        return "View — \(mode.title.uppercased())\(transition) · \(selectionSummary) · tick \(timelineTick) ms · \(phaseBadge)"
    }

    var sessionStatusLine: String {
        let bodyTick = lastBodyResultTick.map(String.init) ?? "—"
        let error = sessionError.map { " · ERROR \($0)" } ?? ""
        return "Session — \(sessionMode.rawValue.uppercased()) · \(sessionPhase.rawValue) · epoch \(epoch) · tick \(timelineTick) ms · body result \(bodyTick)\(error)"
    }
}
