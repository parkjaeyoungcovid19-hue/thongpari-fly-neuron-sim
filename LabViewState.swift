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

struct LabViewState: Equatable {
    var mode: LabViewMode = .observe
    var selectedFlyID: String? = "fly"
    var selectedObjectID: String?

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
        if let selectedObjectID,
           !snapshot.objects.contains(where: { $0.id == selectedObjectID }) {
            self.selectedObjectID = nil
        }
    }

    mutating func clearViewerIdentity(clearObjectSelection: Bool) {
        snapshotSeq = nil
        worldRevision = nil
        snapshotTick = nil
        connectionGeneration = 0
        if clearObjectSelection { selectedObjectID = nil }
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
        return "fly \(fly) · object \(object)"
    }

    var commonStatusLine: String {
        "View — \(mode.title.uppercased()) · \(selectionSummary) · tick \(timelineTick) ms · \(phaseBadge)"
    }

    var sessionStatusLine: String {
        let bodyTick = lastBodyResultTick.map(String.init) ?? "—"
        let error = sessionError.map { " · ERROR \($0)" } ?? ""
        return "Session — \(sessionMode.rawValue.uppercased()) · \(sessionPhase.rawValue) · epoch \(epoch) · tick \(timelineTick) ms · body result \(bodyTick)\(error)"
    }
}
