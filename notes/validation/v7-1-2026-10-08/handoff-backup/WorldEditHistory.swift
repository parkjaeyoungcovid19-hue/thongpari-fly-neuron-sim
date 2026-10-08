// WorldEditHistory.swift — V6.6 undo/redo of applied world settings.
// An undo is an ordinary revision-checked edit that sets one setting back to
// the value the backend reported replacing (`previous_value`). It never
// rewinds simulation time, neural state, or anything the world did since.
import Cocoa

enum WorldEditChange: Equatable {
    /// `propertyID` of `targetID` (nil: the environment) went from `before` to `after`.
    case property(propertyID: String, targetID: String?, before: EnvironmentPropertyValue, after: EnvironmentPropertyValue)
    /// `copyID` was made by duplicating `sourceID`. Undo deletes the copy.
    case duplicate(sourceID: String, copyID: String)

    var label: String {
        switch self {
        case .duplicate(_, let copy): return L("Duplicate ", "복제 ") + copy
        case .property(let pid, let target, _, _):
            let name: String
            switch pid.split(separator: ".").last.map(String.init) ?? pid {
            case "position_mm": name = L("Move", "이동")
            case "yaw_deg": name = L("Rotate", "회전")
            case "size_mm": name = L("Resize", "크기")
            case "pitch_deg": name = L("Tilt", "기울기")
            case "celsius": name = L("Temperature", "온도")
            case "mode": name = L("Temperature Mode", "온도 방식")
            case "strength": name = L("Wind Strength", "바람 세기")
            case "direction_deg": name = L("Wind Direction", "바람 방향")
            case "physical": name = L("Wind Push", "바람 힘")
            case "sensory": name = L("Wind Sensing", "바람 감각")
            case "left_mask", "left_enabled": name = L("Left Eye", "왼쪽 눈")
            case "right_mask", "right_enabled": name = L("Right Eye", "오른쪽 눈")
            default: name = pid
            }
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
    static let timeout: TimeInterval = 8

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
        if let p = pending, now.timeIntervalSince(p.startedAt) > Self.timeout {
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

/// Edit ▸ Undo/Redo (⌘Z/⇧⌘Z). NSWindow answers undo: itself, so the Lab
/// window routes it: typing not yet undone in the field being edited keeps
/// its own undo; otherwise (including right after Return applied a value,
/// when the field is still focused) the world history steps.
final class LabMainWindow: NSWindow {
    var worldUndo: ((WorldEditHistory.Direction) -> Void)?
    var worldHistory: (() -> WorldEditHistory)?

    /// The window's undo manager when a text field has typing to undo/redo.
    private func textUndo(_ direction: WorldEditHistory.Direction) -> UndoManager? {
        guard firstResponder is NSTextView, let manager = undoManager else { return nil }
        return (direction == .undo ? manager.canUndo : manager.canRedo) ? manager : nil
    }

    @objc func undo(_ sender: Any?) {
        if let text = textUndo(.undo) { text.undo() } else { worldUndo?(.undo) }
    }
    @objc func redo(_ sender: Any?) {
        if let text = textUndo(.redo) { text.redo() } else { worldUndo?(.redo) }
    }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let isUndo = item.action == Selector(("undo:")), isRedo = item.action == Selector(("redo:"))
        guard isUndo || isRedo else { return super.validateMenuItem(item) }
        if let text = textUndo(isUndo ? .undo : .redo) {
            item.title = isUndo ? text.undoMenuItemTitle : text.redoMenuItemTitle
            return true
        }
        let history = worldHistory?() ?? WorldEditHistory()
        item.title = isUndo ? history.undoTitle : history.redoTitle
        return isUndo ? history.canUndo : history.canRedo
    }
}
