import Cocoa

/// V6.6 undo/redo history: recording from owner ACKs, coalescing, the
/// still-unchanged check, ACK settlement and the Edit-menu routing. Headless.
func runWorldEditHistoryChecks(_ check: (String, Bool) -> Void, caps: EnvironmentCapabilities) {
    let identity = WorldEditorIdentity(generation: 4, sessionID: "hist", epoch: 2)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func ack(_ id: Int, _ pid: String, target: String? = nil, actual: Any, previous: Any? = nil, ok: Bool = true,
             status: String = "applied", transaction: String? = nil, session: String = "hist") -> LabAck {
        let objectOp = pid == "object.duplicate" || pid == "object.delete"
        var a = LabAck(id: id, ok: ok, action: objectOp ? "edit_object" : "edit_property", message: ok ? "applied" : status,
                       appliedTick: ok ? 50 : nil, appliedEpoch: ok ? 2 : nil, status: ok ? "applied" : status,
                       sessionID: session, epoch: 2)
        a.connectionGeneration = 4
        var r: [String: Any] = ["ok": ok, "status": status, "property_id": pid, "target_id": target ?? NSNull()]
        if ok { r["revision"] = 9; r["actual_value"] = actual }
        else { r["path"] = "edit.expected_revision"; r["reason"] = status }
        if let previous { r["previous_value"] = previous }
        if let transaction { r["transaction"] = transaction }
        a.edit = try! JSONDecoder().decode(EnvironmentEditResult.self, from: JSONSerialization.data(withJSONObject: r))
        return a
    }
    func world(celsius: Double = 30, revision: Int = 5, puff: Bool = false) -> LabRemoteWorldState? {
        try? JSONDecoder().decode(LabRemoteWorldState.self, from: Data("""
            {"environment_revision": \(revision),
             "temperature": {"celsius": \(celsius), "mode": "environment_only"},
             "wind": {"strength": \(puff ? 0.5 : 0), "direction_deg": 0, "continuous": false,
                      "physical_enabled": true, "sensory_enabled": true},
             "eyes": {"left_enabled": true, "right_enabled": true, "left_mask": 0, "right_mask": 0}}
            """.utf8))
    }
    func box(_ id: String = "box", x: Double = 70, yaw: Double = 30, revision: Int = 7) -> LabWorldObjectRemote {
        LabWorldObjectRemote(id: id, shape: "box", positionMM: [x, 0, 5], sizeMM: [10, 10, 10], yawDeg: yaw, revision: revision)
    }
    func fresh() -> WorldEditHistory { var h = WorldEditHistory(); h.observe(identity: identity, now: t0); return h }

    // Recording.
    var h = fresh()
    h.accept(ack(1, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0)
    check("V6.6 applied edit with previous_value is one undo step",
          h.undoStack == [.property(propertyID: "temperature.celsius", targetID: nil, before: .number(25), after: .number(30))])
    h.accept(ack(2, "temperature.celsius", actual: 31.0), now: t0.addingTimeInterval(5))
    h.accept(ack(3, "temperature.celsius", actual: 31.0, previous: 31.0), now: t0.addingTimeInterval(10))
    h.accept(ack(4, "temperature.celsius", actual: 20.0, previous: 31.0, session: "other"), now: t0.addingTimeInterval(15))
    h.accept(ack(5, "temperature.celsius", actual: 20.0, previous: 31.0, ok: false, status: "rejected_invalid"), now: t0.addingTimeInterval(20))
    check("V6.6 no previous_value, no-op, other session or rejection records nothing", h.undoStack.count == 1)

    // Coalescing: a slider drag sent as three edits is one step; a later edit is another.
    h = fresh()
    h.accept(ack(1, "temperature.celsius", actual: 27.0, previous: 25.0), now: t0)
    h.accept(ack(2, "temperature.celsius", actual: 31.0, previous: 27.0), now: t0.addingTimeInterval(0.4))
    h.accept(ack(3, "temperature.celsius", actual: 35.0, previous: 31.0), now: t0.addingTimeInterval(0.8))
    h.accept(ack(4, "temperature.celsius", actual: 20.0, previous: 35.0), now: t0.addingTimeInterval(5))
    check("V6.6 drag edits coalesce to first→last; a later edit is its own step",
          h.undoStack == [.property(propertyID: "temperature.celsius", targetID: nil, before: .number(25), after: .number(35)),
                          .property(propertyID: "temperature.celsius", targetID: nil, before: .number(35), after: .number(20))])
    h = fresh()
    h.accept(ack(1, "eyes.left_mask", actual: 0.5, previous: 0.0), now: t0)
    h.accept(ack(2, "eyes.left_mask", actual: 0.0, previous: 0.5), now: t0.addingTimeInterval(0.3))
    check("V6.6 a drag that ends where it began leaves no step", h.undoStack.isEmpty)

    // Undo/redo of an environment setting.
    h = fresh()
    h.accept(ack(1, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0)
    check("V6.6 menu title names the step", h.canUndo && h.undoTitle.hasSuffix("Temperature") && !h.canRedo)
    var owner = WorldEditOwnerState(objects: [], world: world(celsius: 30, revision: 5))
    let undo = h.command(.undo, owner: owner, capabilities: caps)
    check("V6.6 undo sends the previous value at the current revision",
          undo?.action == "edit_property" && undo?.edit?.value == .number(25) && undo?.edit?.expectedRevision == 5
          && undo?.edit?.propertyID == "temperature.celsius" && undo?.edit?.targetID == nil)
    h.began(commandID: 11, schedule: nil, direction: .undo, now: t0)
    check("V6.6 one step in flight at a time", !h.canUndo && h.command(.undo, owner: owner, capabilities: caps) == nil)
    h.accept(ack(11, "temperature.celsius", actual: 25.0, previous: 30.0, transaction: "paused"))
    check("V6.6 applied undo moves the step to redo and says it was paused",
          h.undoStack.isEmpty && h.redoStack.count == 1 && !h.isError && h.message.contains("paused"))
    check("V6.6 own undo ACK is not recorded as a new step", h.undoStack.isEmpty)
    owner.world = world(celsius: 25, revision: 6)
    let redo = h.command(.redo, owner: owner, capabilities: caps)
    check("V6.6 redo sends the step's value again", redo?.edit?.value == .number(30) && redo?.edit?.expectedRevision == 6)
    h.began(commandID: 12, schedule: nil, direction: .redo)
    h.accept(ack(12, "temperature.celsius", actual: 30.0, previous: 25.0))
    check("V6.6 applied redo returns the step to undo", h.undoStack.count == 1 && h.redoStack.isEmpty)
    h.accept(ack(13, "temperature.mode", actual: "flywire_sensory", previous: "environment_only"))
    check("V6.6 an enum setting is recorded", h.undoStack.last == .property(propertyID: "temperature.mode", targetID: nil,
                                                                             before: .choice("environment_only"), after: .choice("flywire_sensory")))

    // The setting changed since: the step is dropped, never forced back.
    h = fresh()
    h.accept(ack(1, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0)
    owner.world = world(celsius: 22, revision: 9)
    check("V6.6 changed value refuses undo and drops the step",
          h.command(.undo, owner: owner, capabilities: caps) == nil && h.undoStack.isEmpty && h.isError)

    // Backend rejections.
    h = fresh()
    h.accept(ack(1, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0)
    owner.world = world(celsius: 30, revision: 5)
    _ = h.command(.undo, owner: owner, capabilities: caps); h.began(commandID: 21, schedule: nil, direction: .undo)
    h.accept(ack(21, "temperature.celsius", actual: 0, ok: false, status: "rejected_stale_revision"))
    check("V6.6 stale rejection keeps the step for a retry", h.undoStack.count == 1 && h.isError && h.canUndo)
    _ = h.command(.undo, owner: owner, capabilities: caps); h.began(commandID: 22, schedule: nil, direction: .undo)
    h.accept(ack(22, "temperature.celsius", actual: 0, ok: false, status: "rejected_target"))
    check("V6.6 permanent rejection drops the step", h.undoStack.isEmpty && h.isError)

    // A forward edit landing while an undo is in flight cannot misplace it.
    h = fresh()
    h.accept(ack(1, "object.box.position_mm", target: "box", actual: [70.0, 0, 5], previous: [60.0, 0, 5]), now: t0)
    owner = WorldEditOwnerState(objects: [box()], world: world())
    let move = h.command(.undo, owner: owner, capabilities: caps)
    check("V6.6 object undo uses the object's revision", move?.edit?.expectedRevision == 7 && move?.edit?.value == .vector([60, 0, 5]))
    h.began(commandID: 31, schedule: nil, direction: .undo, now: t0)
    h.accept(ack(32, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0.addingTimeInterval(0.1))
    h.accept(ack(31, "object.box.position_mm", target: "box", actual: [60.0, 0, 5], previous: [70.0, 0, 5]))
    check("V6.6 interleaved forward edit keeps both steps right",
          h.undoStack.map(\.label) == ["Temperature"] && h.redoStack.map(\.label) == ["Move box"])

    // Duplicate: undo deletes the copy, redo duplicates again and follows the new ID.
    h = fresh()
    h.accept(ack(1, "object.duplicate", target: "box", actual: "box-2"), now: t0)
    h.accept(ack(2, "object.box.position_mm", target: "box-2", actual: [90.0, 0, 5], previous: [70.0, 0, 5]), now: t0.addingTimeInterval(3))
    owner = WorldEditOwnerState(objects: [box(), box("box-2", x: 90, revision: 12)], world: world())
    _ = h.command(.undo, owner: owner, capabilities: caps); h.began(commandID: 41, schedule: nil, direction: .undo)
    h.accept(ack(41, "object.box.position_mm", target: "box-2", actual: [70.0, 0, 5], previous: [90.0, 0, 5]))
    owner = WorldEditOwnerState(objects: [box(), box("box-2", x: 70, revision: 13)], world: world())
    let deleteCopy = h.command(.undo, owner: owner, capabilities: caps)
    check("V6.6 undo of a duplicate deletes the copy",
          deleteCopy?.objectEdit?.operation == "delete" && deleteCopy?.objectEdit?.targetID == "box-2"
          && deleteCopy?.objectEdit?.expectedRevision == 13)
    h.began(commandID: 42, schedule: nil, direction: .undo)
    h.accept(ack(42, "object.delete", target: "box-2", actual: "box-2"))
    check("V6.6 own delete does not prune the history", h.redoStack.count == 2 && h.undoStack.isEmpty)
    owner = WorldEditOwnerState(objects: [box()], world: world())
    let again = h.command(.redo, owner: owner, capabilities: caps)
    check("V6.6 redo of a duplicate duplicates the source", again?.objectEdit?.operation == "duplicate" && again?.objectEdit?.targetID == "box")
    h.began(commandID: 43, schedule: nil, direction: .redo)
    h.accept(ack(43, "object.duplicate", target: "box", actual: "box-3"))
    check("V6.6 later steps follow the redone copy's new ID",
          h.redoStack.last == .property(propertyID: "object.box.position_mm", targetID: "box-3",
                                        before: .vector([70, 0, 5]), after: .vector([90, 0, 5])))

    // A user delete voids the steps that refer to that object.
    h = fresh()
    h.accept(ack(1, "object.box.position_mm", target: "box", actual: [70.0, 0, 5], previous: [60.0, 0, 5]), now: t0)
    h.accept(ack(2, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0.addingTimeInterval(3))
    h.accept(ack(3, "object.delete", target: "box", actual: "box"), now: t0.addingTimeInterval(6))
    check("V6.6 deleting an object prunes only its steps", h.undoStack.map(\.label) == ["Temperature"])
    h = fresh()
    h.accept(ack(1, "object.box.position_mm", target: "box", actual: [70.0, 0, 5], previous: [60.0, 0, 5]), now: t0)
    check("V6.6 missing object drops the step",
          h.command(.undo, owner: WorldEditOwnerState(objects: [], world: world()), capabilities: caps) == nil && h.undoStack.isEmpty)

    // Yaw from a render quaternion (−180…180) still matches the owner's 0…360.
    h = fresh()
    h.accept(ack(1, "object.yaw_deg", target: "box", actual: 330.0, previous: 10.0), now: t0)
    let turn = h.command(.undo, owner: WorldEditOwnerState(objects: [box(yaw: -30)], world: world()), capabilities: caps)
    check("V6.6 yaw compares around the circle", turn?.edit?.value == .number(10))

    // Wind waits for a running puff instead of dropping the step.
    h = fresh()
    h.accept(ack(1, "wind.direction_deg", actual: 90.0, previous: 0.0), now: t0)
    check("V6.6 wind undo waits for a timed puff",
          h.command(.undo, owner: WorldEditOwnerState(objects: [], world: world(puff: true)), capabilities: caps) == nil
          && h.undoStack.count == 1 && h.isError)

    // Lifecycle.
    h = fresh()
    h.accept(ack(1, "temperature.celsius", actual: 30.0, previous: 25.0), now: t0)
    _ = h.command(.undo, owner: WorldEditOwnerState(objects: [], world: world()), capabilities: caps)
    h.began(commandID: 51, schedule: nil, direction: .undo, now: t0)
    h.observe(identity: identity, now: t0.addingTimeInterval(9))
    check("V6.6 no reply in 8 s ends the wait", h.pending == nil && h.isError && h.undoStack.count == 1)
    h.accept(ack(51, "temperature.celsius", actual: 25.0, previous: 30.0), now: t0.addingTimeInterval(10))
    check("V6.6 a late reply to our own undo is never a new step", h.undoStack.count == 1)
    h.observe(identity: WorldEditorIdentity(generation: 4, sessionID: "hist", epoch: 3))
    check("V6.6 new session or epoch clears the history", h.undoStack.isEmpty && h.redoStack.isEmpty)
    h = fresh()
    for i in 0..<(WorldEditHistory.limit + 5) {
        h.accept(ack(100 + i, "temperature.celsius", actual: Double(i + 1), previous: Double(i)), now: t0.addingTimeInterval(Double(i) * 2))
    }
    check("V6.6 history is bounded", h.undoStack.count == WorldEditHistory.limit)

    // Edit ▸ Undo routing on the Lab window.
    let window = LabMainWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                               backing: .buffered, defer: true)
    var history = fresh()
    history.accept(ack(1, "object.yaw_deg", target: "box", actual: 90.0, previous: 0.0), now: t0)
    var routed: [WorldEditHistory.Direction] = []
    window.worldHistory = { history }
    window.worldUndo = { routed.append($0) }
    let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    check("V6.6 Edit ▸ Undo is enabled and titled from the world history",
          window.validateMenuItem(undoItem) && undoItem.title == "Undo Rotate box" && !window.validateMenuItem(redoItem))
    window.undo(nil); window.redo(nil)
    check("V6.6 ⌘Z/⇧⌘Z outside a text field step the world history", routed == [.undo, .redo])
    // A focused field after Return (nothing typed left to undo) still steps
    // the world; typing in progress keeps the field's own undo.
    let field = NSTextField(string: "25")
    window.contentView?.addSubview(field)
    window.makeFirstResponder(field)
    window.undoManager?.removeAllActions()
    routed = []
    check("V6.6 focused field with no typing to undo still offers the world step",
          window.firstResponder is NSTextView && window.validateMenuItem(undoItem) && undoItem.title == "Undo Rotate box")
    window.undo(nil)
    check("V6.6 ⌘Z in a focused field after Return undoes the world step", routed == [.undo])
    final class Typing: NSObject { var undone = false; @objc func revert() { undone = true } }
    let typing = Typing()
    window.undoManager?.registerUndo(withTarget: typing, selector: #selector(Typing.revert), object: nil)
    routed = []
    window.undo(nil)
    check("V6.6 typing still being edited keeps the field's own undo", typing.undone && routed.isEmpty)
}
