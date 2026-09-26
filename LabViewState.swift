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
        case .observe: return L("Observe", "관찰")
        case .participate: return L("Participate", "참여")
        case .edit: return L("Edit", "편집")
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

    var displayedMode: LabViewMode {
        pendingMode ?? mode
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
        case .paused: return L("PAUSED", "일시 정지")
        case .pausing: return L("PAUSING", "정지 중")
        case .resuming: return L("RESUMING", "재개 중")
        case .resetting: return L("RESETTING", "초기화 중")
        case .starting: return L("STARTING", "시작 중")
        case .failed: return L("FAILED", "실패")
        case .running: return L("RUNNING", "실행 중")
        }
    }

    var selectionSummary: String {
        let none = L("none", "없음")
        let fly = selectedFlyID ?? none
        let object = selectedObjectID ?? none
        let player = selectedPlayerID ?? none
        return L("fly \(fly) · player \(player) · object \(object)",
                 "파리 \(fly) · 참여자 \(player) · 물체 \(object)")
    }

    var commonStatusLine: String {
        let transition = pendingMode.map { L(" → \($0.title.uppercased()) PENDING", " → \($0.title) 전환 중") } ?? ""
        return L("View — \(mode.title.uppercased())\(transition) · \(selectionSummary) · tick \(timelineTick) ms · \(phaseBadge)",
                 "보기 — \(mode.title)\(transition) · \(selectionSummary) · 시뮬레이션 시각 \(timelineTick) ms · \(phaseBadge)")
    }

    var sessionStatusLine: String {
        let bodyTick = lastBodyResultTick.map(String.init) ?? "—"
        let error = sessionError.map { L(" · ERROR \($0)", " · 오류 \($0)") } ?? ""
        return LabLanguage.current == .korean
            ? "세션 — \(sessionMode == .deterministic ? "재현 모드" : "실시간 모드") · \(phaseBadge) · 회차 \(epoch) · 시각 \(timelineTick) ms · 몸 결과 \(bodyTick)\(error)"
            : "Session — \(sessionMode.rawValue.uppercased()) · \(sessionPhase.rawValue) · epoch \(epoch) · tick \(timelineTick) ms · body result \(bodyTick)\(error)"
    }
}

// MARK: - V5.5.1 one-window state

/// Display and duplicate-send gate for one authoritative interaction ACK.
struct LabInteractionPresentation {
    enum IgnoredReason {
        case waitingForResponse
        case waitingForState
        case waitingForSession
        case waitingForWorld
        case invalidAim
        case queueUnavailable

        var text: String {
            switch self {
            case .waitingForResponse:
                return L("Waiting — previous request response pending", "대기 중 — 이전 요청 응답 기다리는 중")
            case .waitingForState:
                return L("Interaction not ready — waiting for world state", "상호작용 준비 안 됨 — 세계 상태 수신 대기")
            case .waitingForSession:
                return L("Interaction not ready — waiting for active session", "상호작용 준비 안 됨 — 세션 활성화 대기")
            case .waitingForWorld:
                return L("Interaction not ready — waiting for current world snapshot", "상호작용 준비 안 됨 — 최신 세계 화면 수신 대기")
            case .invalidAim:
                return L("Interaction not ready — participant aim unavailable", "상호작용 준비 안 됨 — 참여체 조준 정보 없음")
            case .queueUnavailable:
                return L("Interaction not ready — request could not be queued", "상호작용 준비 안 됨 — 요청을 보낼 수 없음")
            }
        }
    }

    private(set) var pendingID: Int?
    private(set) var pendingGeneration: UInt64?
    private var pendingSince: Date?
    private(set) var rejection: String?
    private(set) var ignoredReason: IgnoredReason?

    /// Called only for a fresh E press while participation and capture are active.
    mutating func canAttempt() -> Bool {
        guard pendingID == nil else {
            ignoredReason = .waitingForResponse
            return false
        }
        ignoredReason = nil
        return true
    }

    mutating func ignore(_ reason: IgnoredReason) { ignoredReason = reason }

    func canSend(participating: Bool, captured: Bool, focused: Bool,
                 hasInteractionState: Bool) -> Bool {
        participating && captured && focused && hasInteractionState && pendingID == nil
    }

    mutating func begin(id: Int, generation: UInt64, at now: Date = Date()) {
        ignoredReason = nil
        pendingID = id
        pendingGeneration = generation
        pendingSince = now
        rejection = nil
    }

    mutating func accept(ack: LabAck) {
        guard ack.id == pendingID, ack.connectionGeneration == pendingGeneration else { return }
        ignoredReason = nil
        pendingID = nil
        pendingGeneration = nil
        pendingSince = nil
        rejection = ack.ok ? nil : (ack.message.isEmpty ? "invalid_interaction" : ack.message)
    }

    mutating func expire(at now: Date = Date()) {
        guard let pendingSince, now.timeIntervalSince(pendingSince) >= LabCommandTimeline.ackTimeout else { return }
        pendingID = nil
        pendingGeneration = nil
        self.pendingSince = nil
        rejection = "response_timeout"
    }

    mutating func reset() {
        ignoredReason = nil
        pendingID = nil
        pendingGeneration = nil
        pendingSince = nil
        rejection = nil
    }

    static func rejectionText(_ error: String, reachMM: Double) -> String {
        let code = error.split(separator: ":", maxSplits: 1).first.map(String.init) ?? error
        let detail = error.split(separator: ":", maxSplits: 1).dropFirst().first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch code {
        case "invalid_interaction": return L("invalid interaction", "잘못된 상호작용")
        case "not_participating": return L("participant inactive", "참여자가 비활성 상태")
        case "wrong_actor": return L("wrong participant", "참여자 불일치")
        case "ray_origin_not_at_participant": return L("aim origin too far from participant", "조준 시작점이 참여자에서 너무 멂")
        case "ray_miss": return L("nothing under aim", "조준한 대상 없음")
        case "unsupported_target": return L("unsupported target", "집을 수 없는 대상")
        case "out_of_reach":
            let suffix = detail.isEmpty ? "" : " (\(detail))"
            return L("too far\(suffix) · reach \(reachMM) mm", "너무 멂\(suffix) · \(reachMM) mm 초과")
        case "target_mismatch": return L("target changed", "대상이 바뀜")
        case "already_holding": return L("already holding an object", "이미 물체를 잡는 중")
        case "not_holding": return L("no held object", "잡은 물체 없음")
        case "response_timeout": return L("response timed out", "응답 시간 초과")
        default: return L("request rejected", "요청 거절됨")
        }
    }

    func line(state: LabInteractionState?) -> String {
        if let ignoredReason { return ignoredReason.text }
        if pendingID != nil { return L("Waiting for grab/place response…", "집기/놓기 응답 대기 중…") }
        guard let state else { return L("Interaction state unknown", "상호작용 상태 알 수 없음") }
        if let rejection { return L("Rejected: ", "거절: ") + Self.rejectionText(rejection, reachMM: state.reachMM) }
        if let id = state.heldObjectID {
            return L("Holding: \(id)", "잡는 중: \(id)")
                + (state.carryBlocked ? L(" · blocked", " · 막힘") : "")
        }
        return L("E: grab aimed object", "E: 조준한 물체 집기")
    }
}

/// One row of the Lab's shared event timeline. Backend commands start as
/// `requested` and only become `applied`/`rejected` from an ACK; local neural
/// stimulation, markers and session requests are recorded as they happen.
enum LabTimelineStatus: String, Equatable {
    case requested, applied, rejected, timedOut, lost, local, marker, event

    var title: String {
        switch self {
        case .requested: return L("requested", "요청함")
        case .applied: return L("applied", "적용됨")
        case .rejected: return L("rejected", "거절됨")
        case .timedOut: return L("timed out", "시간 초과")
        case .lost: return L("lost (reconnect)", "연결이 끊겨 사라짐")
        case .local: return L("local", "앱 안에서 처리")
        case .marker: return L("marker", "표시")
        case .event: return L("backend event", "시뮬레이터 알림")
        }
    }
    var isPending: Bool { self == .requested }
}

enum LabTimelineKind: String, Equatable {
    case physical, sensoryModel, directNeural, session, marker, recording

    /// Backend lab actions are either physical-world mutations or modeled senses.
    static func of(action: String) -> LabTimelineKind {
        switch action {
        case "set_eye_state", "restore_eyes", "flash_eye", "temperature": return .sensoryModel
        default: return .physical
        }
    }
}

struct LabTimelineEntry: Equatable {
    let commandID: Int?
    let action: String
    let detail: String
    let kind: LabTimelineKind
    let sessionID: String
    let epoch: Int
    let requestedTick: Int
    let requestedAt: Date
    let connectionGeneration: UInt64
    var status: LabTimelineStatus
    var appliedTick: Int?
    var message = ""

    var line: String {
        let id = commandID.map { "#\($0) " } ?? ""
        let applied = appliedTick.map { " @t\($0)" } ?? ""
        let note = message.isEmpty || message == "ok" ? "" : " · \(message)"
        let what = detail.isEmpty ? action : "\(action) \(detail)"
        // A tick of 0 means none was known when the row was created.
        let tick = requestedTick > 0 ? "t\(requestedTick)  " : ""
        return "\(tick)\(id)\(what) — \(status.title)\(applied)\(note)"
    }
}

struct LabCommandTimeline: Equatable {
    static let ackTimeout: TimeInterval = 5
    /// Larger than the bridge's 32-command queue, so a pending row is never evicted.
    static let capacity = 200
    private(set) var entries: [LabTimelineEntry] = []

    var pendingCount: Int { entries.filter { $0.status.isPending }.count }
    func recent(_ n: Int) -> ArraySlice<LabTimelineEntry> { entries.suffix(n) }

    mutating func append(_ entry: LabTimelineEntry) {
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Resolves the pending (or timed-out: a late ACK still reports the truth)
    /// entry with the ACK's id on the same connection. Returns false for ACKs of
    /// unknown, already-resolved or older-connection commands.
    @discardableResult
    mutating func apply(ack: LabAck) -> Bool {
        guard let i = entries.lastIndex(where: {
            $0.commandID == ack.id && ($0.status.isPending || $0.status == .timedOut)
                && $0.connectionGeneration == ack.connectionGeneration
        }) else { return false }
        entries[i].status = ack.ok ? .applied : .rejected
        entries[i].appliedTick = ack.ok ? ack.appliedTick : nil
        entries[i].message = ack.ok ? "" : (ack.message.isEmpty ? (ack.status ?? L("rejected", "거절됨")) : ack.message)
        return true
    }

    /// Pending commands never silently stay "in flight": a new connection makes
    /// them lost, and no ACK within `ackTimeout` marks them timed out.
    mutating func expire(now: Date, connectionGeneration: UInt64) {
        for i in entries.indices where entries[i].status.isPending {
            if entries[i].connectionGeneration != connectionGeneration {
                entries[i].status = .lost
            } else if now.timeIntervalSince(entries[i].requestedAt) > Self.ackTimeout {
                entries[i].status = .timedOut
            }
        }
    }
}

enum WorkspaceConnection: Equatable {
    case disabled                  // brain-only launch, no FlyGym bridge
    case backendDown(String)       // the app-owned backend is not running
    case connecting                // waiting for TCP connection / capability hello
    case live
    case stale(TimeInterval?)      // connected, but body telemetry is old or missing

    var title: String {
        switch self {
        case .disabled: return L("FlyGym off", "물리 시뮬레이터 꺼짐")
        case .backendDown: return L("Backend stopped", "시뮬레이터 멈춤")
        case .connecting: return L("Connecting…", "연결 중…")
        case .live: return L("Live", "실시간")
        case .stale: return L("Stale data", "오래된 데이터")
        }
    }
}

enum WorkspaceRecording: Equatable {
    case idle
    case recording(path: String, elapsed: TimeInterval)
    case stopping(path: String?)
    case saved(path: String)
    case failed(path: String?, message: String)

    var isActive: Bool {
        switch self {
        case .recording, .stopping: return true
        default: return false
        }
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    var line: String {
        switch self {
        case .idle: return L("Not recording", "기록 안 함")
        case .recording(let path, let elapsed):
            return L("● Recording \(WorkspaceSnapshot.clock(elapsed)) → \(Self.name(path))",
                     "● 기록 중 \(WorkspaceSnapshot.clock(elapsed)) → \(Self.name(path))")
        case .stopping(let path): return L("Saving… flushing \(path.map(Self.name) ?? "recording")",
                                           "저장 중… \(path.map(Self.name) ?? "기록")")
        case .saved(let path): return L("Saved \(Self.name(path))", "저장됨 \(Self.name(path))")
        case .failed(let path, let message): return L("Save failed: ", "저장 실패: ") + "\(message)\(path.map { " — \($0)" } ?? "")"
        }
    }
}

/// The single read-only status every Lab region renders from, assembled once
/// per refresh so no label guesses `connected`/`paused`/`recording` on its own.
struct WorkspaceSnapshot: Equatable {
    var connection: WorkspaceConnection
    var session: LabSessionSnapshot
    var recording: WorkspaceRecording
    var pendingCommands: Int
    var backendDetail: String

    static func connection(bridgeEnabled: Bool, service: FlyGymServiceState?,
                           connected: Bool,
                           bodyFresh: Bool, bodyAge: TimeInterval?) -> WorkspaceConnection {
        guard bridgeEnabled else { return .disabled }
        if let service {
            switch service {
            case .unavailable(let reason): return .backendDown(reason)
            case .exited(let status): return .backendDown(L("exited with status \(status)", "종료됨 (상태 \(status))"))
            case .starting, .running: break
            }
        }
        guard connected else { return .connecting }
        return bodyFresh ? .live : .stale(bodyAge)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Commands and participant input may only claim live effects when true.
    var acceptsBackendCommands: Bool {
        switch connection {
        case .live, .stale: return true
        default: return false
        }
    }

    var connectionLine: String {
        switch connection {
        case .disabled: return L("FlyGym off — brain-only session", "물리 시뮬레이터 꺼짐 — 뇌만 계산 중")
        case .backendDown(let why): return L("Backend stopped — ", "시뮬레이터 멈춤 — ") + why
        case .connecting: return L("Connecting to FlyGym backend… ", "물리 시뮬레이터(FlyGym)에 연결 중… ") + backendDetail
        case .live: return L("Live — ", "실시간 — ") + backendDetail
        case .stale(let age):
            let a = age.map { String(format: L("%.1f s old", "%.1f초 전"), $0) } ?? L("no body packet yet", "아직 몸 데이터 없음")
            return L("Stale data — body telemetry \(a); the view shows the last known state",
                     "오래된 데이터 — 몸 데이터가 \(a) 것입니다. 화면은 마지막 상태를 보여줍니다")
        }
    }

    var sessionLine: String {
        "\(session.mode.rawValue) · \(session.phase.rawValue) · \(session.sessionID.prefix(8)) / e\(session.epoch) / t\(session.simTick)"
    }

    var statusLine: String {
        let pending = pendingCommands > 0 ? L(" · \(pendingCommands) pending", " · 대기 \(pendingCommands)건") : ""
        return "\(connection.title) · \(sessionLine)\(pending) · \(recording.line)"
    }
}
