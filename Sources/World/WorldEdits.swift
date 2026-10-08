// Shared owner-boundary rules; each edit surface retains its own queue/history policy.
import Cocoa

enum WorldEdits {
    static let timeout: TimeInterval = 8
    static func expired(_ startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) > timeout
    }
    static func matches(_ ack: LabAck, commandID: Int, identity: WorldEditorIdentity) -> Bool {
        ack.id == commandID && ack.connectionGeneration == identity.generation
    }
    static func matches(_ ack: LabAck, schedule: LabCommandSchedule) -> Bool {
        ack.sessionID == schedule.sessionID && ack.epoch == schedule.epoch
    }
    static func rejectionDetail(_ ack: LabAck) -> String {
        (ack.edit?.reason ?? ack.message) + (ack.edit?.path.map { " (\($0))" } ?? "")
    }
}

enum WorldPropertyLabels {
    static let names: [String: (String, String)] = [
        "position_mm": ("Move", "이동"),
        "yaw_deg": ("Rotate", "회전"),
        "size_mm": ("Resize", "크기"),
        "pitch_deg": ("Tilt", "기울기"),
        "celsius": ("Temperature", "온도"),
        "mode": ("Temperature Mode", "온도 방식"),
        "strength": ("Wind Strength", "바람 세기"),
        "direction_deg": ("Wind Direction", "바람 방향"),
        "physical": ("Wind Push", "바람 힘"),
        "sensory": ("Wind Sensing", "바람 감각"),
        "left_mask": ("Left Eye", "왼쪽 눈"),
        "left_enabled": ("Left Eye", "왼쪽 눈"),
        "right_mask": ("Right Eye", "오른쪽 눈"),
        "right_enabled": ("Right Eye", "오른쪽 눈"),
    ]
    static func label(propertyID: String) -> String {
        let suffix = propertyID.split(separator: ".").last.map(String.init) ?? propertyID
        guard let name = names[suffix] else { return propertyID }
        return L(name.0, name.1)
    }
}

struct WorldEditorIdentity: Equatable {
    let generation: UInt64
    let sessionID: String
    let epoch: Int
}

struct WorldEditorPending {
    let commandID: Int
    let identity: WorldEditorIdentity
    let schedule: LabCommandSchedule?
    let propertyID: String
    let targetID: String
    let expectedRevision: Int
    let proposedValue: EnvironmentPropertyValue?
    let capabilities: EnvironmentCapabilities?
    let startedAt: Date
}

/// Separate from the views for deterministic lifecycle tests. Never edits an object.
struct WorldEditorState {
    private(set) var pending: WorldEditorPending?
    private(set) var message = ""
    private(set) var isError = false
    mutating func clearDraftMessage() { if pending == nil { message=""; isError=false } }
    mutating func fail(_ text: String) { message = text; isError = true }
    /// V6.6 undo/redo feedback; never touches a pending edit.
    mutating func note(_ text: String, isError: Bool) { message = text; self.isError = isError }
    mutating func begin(_ request: WorldEditorPending) {
        pending = request; isError = false
        message = L("Applying… waiting for the simulator", "적용 중… 시뮬레이터 응답을 기다립니다")
    }
    mutating func reconcile(identity: WorldEditorIdentity, now: Date = Date()) {
        guard let p = pending else { return }
        if p.identity != identity {
            pending = nil; fail(L("Session changed — the earlier request was discarded", "세션이 바뀌어 이전 요청은 무시했습니다"))
        } else if WorldEdits.expired(p.startedAt, now: now) {
            pending = nil; fail(L("No reply from the simulator — check the current values before retrying", "시뮬레이터 응답이 없습니다 — 현재 값을 확인한 뒤 다시 시도하세요"))
        }
    }
    /// Returns a newly duplicated ID only after a matching, valid owner result.
    mutating func accept(_ ack: LabAck) -> String? {
        guard let p = pending, WorldEdits.matches(ack, commandID: p.commandID, identity: p.identity) else { return nil }
        guard let schedule = p.schedule else {
            pending = nil; fail(L("Missing session boundary — not confirmed", "세션 정보 없음 — 적용 확인 불가")); return nil
        }
        guard WorldEdits.matches(ack, schedule: schedule) else { return nil }
        pending = nil
        guard ack.ok else {
            fail(Self.rejection(ack))
            return nil
        }
        guard let result = ack.edit, result.ok, result.status == "applied",
              result.propertyID == p.propertyID, result.targetID == p.targetID,
              let revision = result.revision, revision > p.expectedRevision,
              let actual = result.actualValue else {
            fail(L("Malformed ACK — application not confirmed", "잘못된 응답 — 적용 확인 불가")); return nil
        }
        guard ack.status == "applied", ack.appliedEpoch == schedule.epoch,
              let tick = ack.appliedTick, tick >= schedule.requestedTick else {
            fail(L("ACK boundary mismatch — not confirmed", "응답 시각 불일치 — 적용 확인 불가")); return nil
        }
        let duplicate: String?
        if p.propertyID == "object.duplicate" || p.propertyID == "object.delete" {
            guard case .choice(let id) = actual, !id.isEmpty, id.unicodeScalars.count <= 64,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  p.propertyID != "object.duplicate" || id != p.targetID,
                  p.propertyID != "object.delete" || id == p.targetID else {
                fail(L("Malformed object result", "잘못된 물체 응답")); return nil
            }
            duplicate = p.propertyID == "object.duplicate" ? id : nil
        } else {
            guard let proposal = p.proposedValue, Self.compatible(actual, proposal),
                  let caps = p.capabilities,
                  (try? EnvironmentEdit.make(propertyID: p.propertyID, targetID: p.targetID, expectedRevision: revision, value: actual, capabilities: caps)) != nil,
                  p.propertyID != "object.yaw_deg" || Self.appliedYaw(actual) else {
                fail(L("Malformed actual value", "잘못된 실제 값")); return nil
            }
            duplicate = nil
        }
        isError = false
        message = L("Applied", "적용됨") + " · " + (duplicate.map { L("new object ", "새 물체 ") + $0 } ?? Self.describe(actual))
        return duplicate
    }
    private static func rejection(_ ack: LabAck) -> String {
        guard let edit = ack.edit else { return L("Not applied — ", "적용 안 됨 — ") + ack.message }
        if edit.status == "rejected_capacity" {
            return L("Not applied — every slot for this kind of object is in use; delete one first",
                     "적용 안 됨 — 이 종류의 물체 자리가 모두 찼습니다. 하나를 지운 뒤 다시 하세요")
        }
        if edit.status == "rejected_stale_revision" {
            return L("Not applied — the object changed first; check the current values and retry",
                     "적용 안 됨 — 그사이 물체가 바뀌었습니다. 현재 값을 확인하고 다시 시도하세요")
        }
        return L("Not applied — ", "적용 안 됨 — ") + WorldEdits.rejectionDetail(ack)
    }
    private static func appliedYaw(_ value: EnvironmentPropertyValue) -> Bool {
        if case .number(let n) = value { return n >= 0 && n < 360 }; return false
    }
    private static func compatible(_ a: EnvironmentPropertyValue, _ b: EnvironmentPropertyValue) -> Bool {
        switch (a, b) {
        case (.number(let v), .number): return v.isFinite
        case (.vector(let v), .vector(let p)): return v.count == p.count && v.allSatisfy(\.isFinite)
        default: return false
        }
    }
    static func describe(_ value: EnvironmentPropertyValue) -> String {
        switch value {
        case .number(let n): return String(format: "%g", n)
        case .vector(let v): return v.map { String(format: "%g", $0) }.joined(separator: ", ")
        case .choice(let s): return s
        case .boolean(let b): return String(b)
        }
    }
}

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
    static let timeout = WorldEdits.timeout
    private(set) var inFlight: EnvironmentSettingInFlight?
    private(set) var waiting: [EnvironmentSettingRequest] = []
    private(set) var revision: Int?
    private(set) var identity: WorldEditorIdentity?
    private(set) var message = ""
    private(set) var isError = false
    /// The property `message` is about, so it is shown under its own section.
    private(set) var messagePropertyID: String?

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
        if let p = inFlight, WorldEdits.expired(p.startedAt, now: now) {
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
        guard let p = inFlight, WorldEdits.matches(ack, commandID: p.commandID, identity: p.identity) else { return false }
        guard let schedule = p.schedule, WorldEdits.matches(ack, schedule: schedule) else {
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
            guard ack.edit != nil else { return prefix + ack.message }
            return prefix + WorldEdits.rejectionDetail(ack)
        }
    }
}

enum WorldEditChange: Equatable {
    /// `propertyID` of `targetID` (nil: the environment) went from `before` to `after`.
    case property(propertyID: String, targetID: String?, before: EnvironmentPropertyValue, after: EnvironmentPropertyValue)
    /// `copyID` was made by duplicating `sourceID`. Undo deletes the copy.
    case duplicate(sourceID: String, copyID: String)

    var label: String {
        switch self {
        case .duplicate(_, let copy): return L("Duplicate ", "복제 ") + copy
        case .property(let pid, let target, _, _):
            let name = WorldPropertyLabels.label(propertyID: pid)
            return target.map { name + " " + $0 } ?? name
        }
    }

    /// Objects this change refers to; a deleted one makes the change void.
    var objectIDs: [String] {
        switch self {
        case .duplicate(let source, let copy): return [source, copy]
        case .property(_, let target, _, _): return target.map { [$0] } ?? []
        }
    }
}

/// What the owner reports now: the atomic snapshot's objects and lab_state.
struct WorldEditOwnerState {
    var objects: [LabWorldObjectRemote]
    var world: LabRemoteWorldState?

    /// Current value and revision of an editable property, shaped like
    /// `sample` (a scalar or vector size). nil when the owner does not report it.
    func value(_ propertyID: String, target: String?, like sample: EnvironmentPropertyValue)
        -> (value: EnvironmentPropertyValue, revision: Int)? {
        let field = propertyID.split(separator: ".").last.map(String.init) ?? ""
        if let target {
            guard let o = objects.first(where: { $0.id == target }), let revision = o.revision else { return nil }
            switch field {
            case "position_mm": return (.vector(o.positionMM), revision)
            case "yaw_deg": return (.number(o.yawDeg), revision)
            case "pitch_deg": return (.number(o.pitchDeg ?? 0), revision)
            case "size_mm":
                if case .number = sample { return o.sizeMM.first.map { (.number($0), revision) } }
                return (.vector(o.sizeMM), revision)
            default: return nil
            }
        }
        guard let world, let revision = world.environmentRevision else { return nil }
        let value: EnvironmentPropertyValue?
        switch propertyID {
        case "temperature.celsius": value = world.temperature.map { .number($0.celsius) }
        case "temperature.mode": value = world.temperature.map { .choice($0.mode) }
        case "wind.strength": value = world.wind.map { .number($0.strength) }
        case "wind.direction_deg": value = world.wind.map { .number($0.directionDeg) }
        case "wind.physical": value = world.wind.map { .boolean($0.physicalEnabled) }
        case "wind.sensory": value = world.wind.map { .boolean($0.sensoryEnabled) }
        case "eyes.left_mask": value = world.eyes.map { .number($0.leftMask) }
        case "eyes.right_mask": value = world.eyes.map { .number($0.rightMask) }
        case "eyes.left_enabled": value = world.eyes.map { .boolean($0.leftEnabled) }
        case "eyes.right_enabled": value = world.eyes.map { .boolean($0.rightEnabled) }
        default: value = nil
        }
        return value.map { ($0, revision) }
    }

    /// A timed puff owns the wind until it ends; wind settings wait for it.
    var windPuffRunning: Bool { world?.wind.map { $0.strength > 0 && !$0.continuous } ?? false }
}

/// Undo/redo stacks fed only by applied owner ACKs. Before sending, the
/// setting must still hold the value the step left (otherwise someone or
/// something changed it and the step is dropped, never forced back); the
/// backend's revision check then catches any change racing the request.
struct WorldEditHistory {
    enum Direction { case undo, redo }
    struct Pending {
        let commandID: Int
        let identity: WorldEditorIdentity
        let schedule: LabCommandSchedule?
        let direction: Direction
        /// The exact step being sent; a forward edit landing meanwhile may push above it.
        let change: WorldEditChange
        let startedAt: Date
    }
    static let limit = 100
    /// Successive edits of one setting this close together (a slider drag
    /// sent as a few edits) become one step from the first value to the last.
    static let coalesceWindow: TimeInterval = 1.5
    static let timeout = WorldEdits.timeout

    private(set) var undoStack: [WorldEditChange] = []
    private(set) var redoStack: [WorldEditChange] = []
    private(set) var pending: Pending?
    private(set) var message = ""
    private(set) var isError = false
    /// The change `message` is about, so a panel can show it in place.
    private(set) var messageChange: WorldEditChange?
    private var identity: WorldEditorIdentity?
    /// When the top undo step was last extended; nil once an undo/redo seals it.
    private var lastForwardAt: Date?
    /// Our own undo/redo commands, so a late ACK is never recorded as a new step.
    private var ownCommandIDs: [Int] = []

    var canUndo: Bool { pending == nil && !undoStack.isEmpty }
    var canRedo: Bool { pending == nil && !redoStack.isEmpty }
    /// Edit-menu titles in each language's own order ("Undo Move box", "이동 box 실행 취소").
    var undoTitle: String {
        undoStack.last.map { L("Undo \($0.label)", "\($0.label) 실행 취소") } ?? L("Undo", "실행 취소")
    }
    var redoTitle: String {
        redoStack.last.map { L("Redo \($0.label)", "\($0.label) 실행 복귀") } ?? L("Redo", "실행 복귀")
    }

    /// A new connection, session or epoch is a different world: forget it all.
    mutating func observe(identity current: WorldEditorIdentity, now: Date = Date()) {
        if identity != current {
            if identity != nil && !(undoStack.isEmpty && redoStack.isEmpty && pending == nil) {
                note(L("Session changed — undo history cleared", "세션이 바뀌어 되돌리기 기록을 지웠습니다"), error: false, about: nil)
            }
            identity = current
            undoStack.removeAll(); redoStack.removeAll(); pending = nil; lastForwardAt = nil
        }
        if let p = pending, WorldEdits.expired(p.startedAt, now: now) {
            pending = nil
            note(L("No reply from the simulator — check the current values", "시뮬레이터 응답이 없습니다 — 현재 값을 확인하세요"),
                 error: true, about: nil)
        }
    }

    /// Records an applied edit, or settles our own undo/redo. Returns true for our own.
    @discardableResult
    mutating func accept(_ ack: LabAck, now: Date = Date()) -> Bool {
        guard let identity, ack.connectionGeneration == identity.generation,
              ack.sessionID == identity.sessionID, ack.epoch == identity.epoch,
              ack.action == "edit_property" || ack.action == "edit_object" else { return false }
        if let p = pending, ack.id == p.commandID {
            pending = nil
            settle(ack, p)
            return true
        }
        guard !ownCommandIDs.contains(ack.id), ack.ok, ack.status == "applied",
              let edit = ack.edit, edit.ok, edit.status == "applied", let pid = edit.propertyID,
              let actual = edit.actualValue else { return false }
        switch pid {
        case "object.duplicate":
            guard let source = edit.targetID, case .choice(let copy) = actual else { return false }
            push(.duplicate(sourceID: source, copyID: copy), now: now, coalesce: false)
        case "object.delete":
            guard let id = edit.targetID else { return false }
            undoStack.removeAll { $0.objectIDs.contains(id) }
            redoStack.removeAll { $0.objectIDs.contains(id) }
            lastForwardAt = nil
        default:
            guard let before = edit.previousValue, !Self.same(before, actual, pid) else { return false }
            push(.property(propertyID: pid, targetID: edit.targetID, before: before, after: actual), now: now, coalesce: true)
        }
        return false
    }

    /// The edit that steps back (or forward), or nil after reporting why not.
    mutating func command(_ direction: Direction, owner: WorldEditOwnerState,
                          capabilities: EnvironmentCapabilities?) -> LabCommand? {
        guard pending == nil, let change = (direction == .undo ? undoStack.last : redoStack.last) else { return nil }
        func drop(_ why: String) -> LabCommand? {
            if direction == .undo { undoStack.removeLast() } else { redoStack.removeLast() }
            note(why + L(" — removed from history", " — 이 단계는 기록에서 뺐습니다"), error: true, about: change)
            return nil
        }
        switch change {
        case .duplicate(let source, let copy):
            let id = direction == .undo ? copy : source
            guard let o = owner.objects.first(where: { $0.id == id }), let revision = o.revision else {
                return drop(L("Object \(id) is gone", "물체 \(id)가 없습니다"))
            }
            var command = LabCommand(id: 0, action: "edit_object", target: id)
            command.objectEdit = WorldObjectEdit(operation: direction == .undo ? "delete" : "duplicate",
                                                 targetID: id, expectedRevision: revision)
            return command
        case .property(let pid, let target, let before, let after):
            let (expected, goal) = direction == .undo ? (after, before) : (before, after)
            if pid.hasPrefix("wind."), owner.windPuffRunning {
                note(L("A timed wind puff is running — try again when it ends", "시간 제한 바람이 부는 중입니다 — 끝난 뒤 다시 하세요"),
                     error: true, about: change)
                return nil
            }
            guard let current = owner.value(pid, target: target, like: goal) else {
                return drop(target.map { L("Object \($0) is gone", "물체 \($0)가 없습니다") }
                            ?? L("The simulator does not report this setting", "시뮬레이터가 이 설정을 알려 주지 않습니다"))
            }
            guard Self.same(current.value, expected, pid) else {
                return drop(L("\(change.label) changed since", "그사이 \(change.label) 값이 바뀌었습니다"))
            }
            guard let caps = capabilities,
                  let edit = try? EnvironmentEdit.make(propertyID: pid, targetID: target,
                                                       expectedRevision: current.revision, value: goal, capabilities: caps) else {
                return drop(L("The simulator no longer accepts this value", "시뮬레이터가 이 값을 더 이상 받지 않습니다"))
            }
            return LabCommand.editProperty(edit)
        }
    }

    /// Call right after sending the command `command(direction, …)` returned.
    mutating func began(commandID: Int, schedule: LabCommandSchedule?, direction: Direction, now: Date = Date()) {
        guard let identity, let change = direction == .undo ? undoStack.last : redoStack.last else { return }
        pending = Pending(commandID: commandID, identity: identity, schedule: schedule, direction: direction,
                          change: change, startedAt: now)
        ownCommandIDs = Array((ownCommandIDs + [commandID]).suffix(64))
        note(direction == .undo ? L("Undoing…", "되돌리는 중…") : L("Redoing…", "다시 하는 중…"), error: false, about: change)
    }

    mutating func sendFailed() {
        note(L("Command not sent", "명령 전송 실패"), error: true, about: nil)
    }

    private mutating func settle(_ ack: LabAck, _ p: Pending) {
        let direction = p.direction
        var change = p.change
        func remove() {
            if direction == .undo { undoStack.lastIndex(of: p.change).map { _ = undoStack.remove(at: $0) } }
            else { redoStack.lastIndex(of: p.change).map { _ = redoStack.remove(at: $0) } }
        }
        guard ack.ok, ack.status == "applied", let edit = ack.edit, edit.ok, edit.status == "applied",
              let actual = edit.actualValue else {
            let status = ack.edit?.status ?? ack.status ?? ""
            let transient = ["rejected_stale_revision", "rejected_revision", "rejected_busy", "rejected_capacity"].contains(status)
            if !transient { remove() }
            let reason = ack.edit?.reason ?? ack.message
            note(L("Not applied — ", "적용 안 됨 — ") + (status == "rejected_stale_revision" || status == "rejected_revision"
                    ? L("it changed first; try again", "그사이 바뀌었습니다. 다시 시도하세요") : reason)
                 + (transient ? "" : L(" — removed from history", " — 이 단계는 기록에서 뺐습니다")),
                 error: true, about: change)
            return
        }
        switch change {
        case .property(let pid, let target, let before, let after):
            // Keep the owner's own wording of the value it applied (e.g. yaw mod 360).
            change = .property(propertyID: pid, targetID: target,
                               before: direction == .undo ? actual : before, after: direction == .redo ? actual : after)
        case .duplicate(let source, let copy):
            if direction == .redo, case .choice(let fresh) = actual, fresh != copy {
                // A redone duplicate is a new object; later steps follow its new ID.
                func remap(_ c: WorldEditChange) -> WorldEditChange {
                    if case .property(let p, copy?, let b, let a) = c { return .property(propertyID: p, targetID: fresh, before: b, after: a) }
                    if case .duplicate(copy, let k) = c { return .duplicate(sourceID: fresh, copyID: k) }
                    return c
                }
                undoStack = undoStack.map(remap); redoStack = redoStack.map(remap)
                change = .duplicate(sourceID: source, copyID: fresh)
            }
        }
        remove()
        if direction == .undo { redoStack.append(change) } else { undoStack.append(change) }
        lastForwardAt = nil
        note((direction == .undo ? L("Undid ", "되돌림: ") : L("Redid ", "다시 함: ")) + change.label
             + (edit.transaction == "paused" ? L(" (while paused)", " (일시 정지 중)") : ""), error: false, about: change)
    }

    private mutating func push(_ change: WorldEditChange, now: Date, coalesce: Bool) {
        redoStack.removeAll()
        if coalesce, let last = lastForwardAt, now.timeIntervalSince(last) <= Self.coalesceWindow,
           case .property(let pid, let target, let firstBefore, let topAfter)? = undoStack.last,
           case .property(pid, target, let before, let after) = change, Self.same(topAfter, before, pid) {
            undoStack.removeLast()
            if !Self.same(firstBefore, after, pid) {
                undoStack.append(.property(propertyID: pid, targetID: target, before: firstBefore, after: after))
            }
        } else {
            undoStack.append(change)
            if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        }
        lastForwardAt = now
    }

    private mutating func note(_ text: String, error: Bool, about change: WorldEditChange?) {
        message = text; isError = error; messageChange = change
    }

    /// Owner-value equality: angles compare around the circle (the snapshot
    /// derives yaw from a quaternion), numbers within float noise.
    static func same(_ a: EnvironmentPropertyValue, _ b: EnvironmentPropertyValue, _ propertyID: String) -> Bool {
        func near(_ x: Double, _ y: Double) -> Bool {
            var d = x - y
            if propertyID.hasSuffix("yaw_deg") || propertyID.hasSuffix("direction_deg") {
                d = d.truncatingRemainder(dividingBy: 360)
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            }
            return abs(d) <= 1e-6 * max(1, abs(x), abs(y))
        }
        switch (a, b) {
        case (.number(let x), .number(let y)): return near(x, y)
        case (.vector(let x), .vector(let y)): return x.count == y.count && zip(x, y).allSatisfy(near)
        default: return a == b
        }
    }
}
