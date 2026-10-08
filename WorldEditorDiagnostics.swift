import Cocoa

/// Headless owner-boundary, projection, and Cocoa draft checks. No GPU/listener.
func runWorldEditorTest() {
    _ = NSApplication.shared
    var failures=0
    func check(_ name:String,_ ok:Bool) { print((ok ? "PASS" : "FAIL")+"  "+(name.hasPrefix("V6") ? "" : "V6.3 ")+name); if !ok { failures += 1 } }
    let root=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
    guard let data=try? Data(contentsOf:root.appendingPathComponent("fixtures/environment_capabilities/valid.json")),
          let caps=try? JSONDecoder().decode(EnvironmentCapabilities.self,from:data) else { print("FAIL fixture capabilities"); exit(1) }
    let identity=WorldEditorIdentity(generation:4,sessionID:"editor",epoch:2)
    let schedule=LabCommandSchedule(sessionID:"editor",epoch:2,requestedTick:40)
    var derives=0
    func afterReset()->LabCommandSchedule? { derives += 1; return LabCommandSchedule(sessionID:"new",epoch:3,requestedTick:0) }
    check("production schedule chooser retains captured epoch across reset",LabCommandSchedule.choose(explicit:schedule,fallback:afterReset()) == schedule && derives == 0)
    check("production schedule chooser still derives unsupplied controls",LabCommandSchedule.choose(explicit:nil,fallback:afterReset())?.epoch == 3 && derives == 1)
    func pending(_ property:String="object.yaw_deg",_ s:LabCommandSchedule?=schedule) -> WorldEditorPending {
        WorldEditorPending(commandID:7,identity:identity,schedule:s,propertyID:property,targetID:"source",expectedRevision:3,
                           proposedValue:property == "object.yaw_deg" ? .number(721) : nil,capabilities:caps,startedAt:Date())
    }
    func ack(_ property:String="object.yaw_deg",_ actual:Any=1.0) -> LabAck {
        var a=LabAck(id:7,ok:true,action:property.hasSuffix("duplicate") || property.hasSuffix("delete") ? "edit_object" : "edit_property",
                     message:"applied",appliedTick:40,appliedEpoch:2,status:"applied",sessionID:"editor",epoch:2)
        a.connectionGeneration=4
        a.edit=try! JSONDecoder().decode(EnvironmentEditResult.self,from:JSONSerialization.data(withJSONObject:[
            "ok":true,"status":"applied","property_id":property,"target_id":"source","revision":4,"actual_value":actual]))
        return a
    }
    for mismatch in 0..<4 {
        var state=WorldEditorState(); state.begin(pending()); var a=ack()
        if mismatch==0 { a.id=8 }; if mismatch==1 { a.connectionGeneration=5 }; if mismatch==2 { a.sessionID="wrong" }; if mismatch==3 { a.epoch=1 }
        _=state.accept(a); check("mismatched ACK retained \(mismatch)",state.pending != nil)
    }
    for malformed in 0..<7 {
        var state=WorldEditorState(); state.begin(pending("object.yaw_deg",malformed==0 ? nil : schedule)); var a=ack()
        if malformed==1 { a.edit=nil }; if malformed==2 { a.appliedEpoch=1 }; if malformed==3 { a.appliedTick=39 }
        if malformed==4 { a=ack("object.yaw_deg",-1.0) }; if malformed==5 { a=ack("object.yaw_deg",1e9) }; if malformed==6 { a.status="queued" }
        _=state.accept(a); check("malformed/boundary not applied \(malformed)",state.isError)
    }
    var state=WorldEditorState(); state.begin(pending()); _=state.accept(ack()); let message=state.message
    check("ACK reports normalized actual only",!state.isError && state.pending == nil && message.hasSuffix("1"))
    _=state.accept(ack("object.yaw_deg",90)); check("replayed ACK ignored",state.message==message)
    state.begin(pending()); state.reconcile(identity:WorldEditorIdentity(generation:4,sessionID:"editor",epoch:3))
    check("reset discards pending identity",state.pending == nil && state.isError)
    state.begin(pending()); state.reconcile(identity:identity,now:Date().addingTimeInterval(9))
    check("timeout unknown outcome",state.pending == nil && state.isError)
    for id in ["source", " new", String(repeating:"a",count:65)] {
        state.begin(pending("object.duplicate")); _=state.accept(ack("object.duplicate",id)); check("invalid duplicate ID rejected",state.isError)
    }
    state.begin(pending("object.duplicate")); check("confirmed duplicate ID",state.accept(ack("object.duplicate","new"))=="new")
    let camera=WorldViewerMuJoCoCamera(positionMM:[0,-100,40],forward:[0,1,-0.3],distanceMM:100,fovyDeg:45)
    let projection=WorldEditorProjection(camera:camera,viewport:NSSize(width:800,height:600))
    let source=LabWorldObjectRemote(id:"source",shape:"box",positionMM:[0,0,5],sizeMM:[6,8,10],yawDeg:30,revision:3)
    check("camera projection finite",projection.project(source.positionMM) != nil)
    check("move projected axis metric",projection.axisDelta(at:source.positionMM,axis:0,pixels:NSPoint(x:10,y:0)) != nil)
    let inspector=WorldEditorInspector(frame:.zero)
    func update() { inspector.update(objects:[source],selectedID:"source",capabilities:caps,identity:identity,mode:.edit,available:true,heldID:nil,camera:camera) }
    var submitted=0; inspector.onSubmit={ _, captured in
        guard captured==identity else { return nil }; submitted += 1; return (7,schedule)
    }
    update(); inspector.fields[0].stringValue="bad-number"; inspector.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
    update(); check("dirty invalid draft survives polling",inspector.fields[0].stringValue=="bad-number")
    let editor=NSTextView()
    _=inspector.control(inspector.fields[0],textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
    check("Return rejects invalid draft without send",submitted==0 && inspector.state.isError)
    _=inspector.control(inspector.fields[0],textView:editor,doCommandBy:#selector(NSResponder.cancelOperation(_:)))
    check("Escape restores owner numeric value",inspector.fields[0].stringValue=="0" && !inspector.state.isError)
    inspector.fields[0].stringValue="10"; inspector.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
    _=inspector.control(inspector.fields[0],textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
    _=inspector.control(inspector.fields[0],textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
    check("Return sends once while pending",submitted==1 && inspector.state.pending != nil)
    check("owner geometry never optimistic",inspector.overlay.selected?.positionMM==source.positionMM)
    runWorldEditorAppKitChecks(check)
    runRampEditorChecks(check, caps: caps, identity: identity, schedule: schedule, camera: camera)
    runEnvironmentPanelChecks(check, caps: caps)
    runWorldEditHistoryChecks(check, caps: caps)
    print("V6.3 editor diagnostics: \(failures) failures"); exit(failures==0 ? 0 : 1)
}

/// V6.4 ramp: decoding, tilt tool, the outline frame against the backend
/// quaternion formula, the spawn_ramp wire shape and the slot-budget wording.
private func runRampEditorChecks(_ check: (String, Bool) -> Void, caps: EnvironmentCapabilities,
                                 identity: WorldEditorIdentity, schedule: LabCommandSchedule,
                                 camera: WorldViewerMuJoCoCamera) {
    func decode(_ json: String) -> LabWorldObjectRemote? {
        try? JSONDecoder().decode(LabWorldObjectRemote.self, from: Data(json.utf8))
    }
    let ramp = decode(#"{"id":"r","shape":"ramp","position_mm":[10,-5,3],"size_mm":[30,12,2],"yaw_deg":40,"pitch_deg":25,"revision":2}"#)
    let box = decode(#"{"id":"b","shape":"box","position_mm":[0,0,5],"size_mm":[6,8,10],"yaw_deg":30,"revision":2}"#)
    check("ramp pitch decodes; other shapes have none", ramp?.pitchDeg == 25 && box != nil && box?.pitchDeg == nil)
    guard let ramp, let box else { return }

    // lab_world.LabObject.quat_wxyz, rotated independently of localAxes.
    let (hy, hp) = (40.0 * .pi / 360, 25.0 * .pi / 360)
    let (w, x, y, z) = (cos(hy) * cos(hp), sin(hy) * sin(hp), -cos(hy) * sin(hp), sin(hy) * cos(hp))
    let matrix = [[1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
                  [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
                  [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]]
    let axes = ramp.localAxes
    let worst = (0..<3).flatMap { axis in (0..<3).map { row in abs(axes[axis][row] - matrix[row][axis]) } }.max() ?? 1
    check("outline axes equal the backend quaternion (yaw 40°, tilt 25°)", worst < 1e-12)

    // The live editor reads poses from world_render_snapshot, not lab_state.
    func render(_ shape: String, _ q: [Double]) -> WorldRenderObject? {
        try? JSONDecoder().decode(WorldRenderObject.self, from: Data(
            #"{"id":"r","shape":"\#(shape)","position_mm":[10,-5,3],"orientation_quat_xyzw":[\#(q.map { "\($0)" }.joined(separator: ","))],"size_mm":[30,12,2],"revision":2}"#.utf8))
    }
    let mappedRamp = render("ramp", [x, y, z, w]).map { LabWorldObjectRemote(render: $0, lab: nil) }
    let mappedBox = render("box", [x, y, z, w]).map { LabWorldObjectRemote(render: $0, lab: nil) }
    check("render snapshot → editor keeps ramp tilt 25° and yaw 40°",
          abs((mappedRamp?.pitchDeg ?? 0) - 25) < 1e-9 && abs((mappedRamp?.yawDeg ?? 0) - 40) < 1e-9
          && mappedBox != nil && mappedBox?.pitchDeg == nil)

    check("tilt descriptor only for ramps",
          caps.descriptor(WorldEditorTool.tilt.propertyID(shape: "ramp"))?.maximum == .number(45)
          && caps.descriptor(WorldEditorTool.tilt.propertyID(shape: "box")) == nil)
    let accepted = try? EnvironmentEdit.make(propertyID: "object.ramp.pitch_deg", targetID: "r",
                                             expectedRevision: 2, value: .number(45), capabilities: caps)
    let rejected = try? EnvironmentEdit.make(propertyID: "object.ramp.pitch_deg", targetID: "r",
                                             expectedRevision: 2, value: .number(45.0001), capabilities: caps)
    check("tilt 45° accepted, 45.0001° rejected before sending", accepted != nil && rejected == nil)

    let inspector = WorldEditorInspector(frame: .zero)
    var sent: [LabCommand] = []
    inspector.onSubmit = { command, _ in sent.append(command); return (9, schedule) }
    func show(_ object: LabWorldObjectRemote) {
        inspector.update(objects: [object], selectedID: object.id, capabilities: caps, identity: identity,
                         mode: .edit, available: true, heldID: nil, camera: camera)
    }
    show(box)
    let tilt = WorldEditorTool.tilt.rawValue
    check("tilt tool disabled for a box", !inspector.tools.isEnabled(forSegment: tilt))
    show(ramp)
    inspector.tools.selectedSegment = tilt
    _ = inspector.tools.sendAction(inspector.tools.action, to: inspector.tools.target)
    check("tilt tool enabled for a ramp and shows its tilt",
          inspector.tools.isEnabled(forSegment: tilt) && inspector.fields[0].stringValue == "25")
    inspector.fields[0].stringValue = "30"
    inspector.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    _ = inspector.control(inspector.fields[0], textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    check("Return sends one pitch edit", sent.count == 1 && sent.first?.edit?.propertyID == "object.ramp.pitch_deg"
          && sent.first?.edit?.value == .number(30))
    inspector.fields[0].stringValue = "33"   // an unsent draft
    inspector.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    LabLanguage.pinForTests(.korean); inspector.relabel()
    check("language change relabels the open editor and keeps an unsent draft (GUI F03)",
          inspector.tools.label(forSegment: WorldEditorTool.move.rawValue) == "이동"
          && inspector.tools.label(forSegment: tilt) == "기울기" && inspector.fields[0].stringValue == "33")
    LabLanguage.pinForTests(.english); inspector.relabel()

    let size = LabRamp.size(lengthMM: 40)
    let flush = LabRamp.flushCenterZ(sizeMM: size, pitchDeg: 15)
    check("flush spawn height matches lab_world (4.69342 mm)", size == [40, 20, 1] && abs(flush - 4.693419) < 1e-5)
    let spawn = LabCommand.spawnRamp(target: "r", positionMM: [10, 0, flush], sizeMM: size, pitchDeg: 15)
    let wire = spawn.flatMap { try? JSONEncoder().encode($0) }
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check("spawn_ramp wire: vector size_mm and pitch_deg, no legacy size",
          wire?["action"] as? String == "spawn_ramp" && wire?["size_mm"] as? [Double] == [40, 20, 1]
          && wire?["pitch_deg"] as? Double == 15 && wire?["size"] == nil)
    check("spawn_ramp bounds checked before sending",
          LabCommand.spawnRamp(target: "r", positionMM: [0, 0, 0], sizeMM: [40, 20, 21], pitchDeg: 15) == nil
          && LabCommand.spawnRamp(target: "r", positionMM: [0, 0, 0], sizeMM: size, pitchDeg: 46) == nil)

    var state = WorldEditorState()
    state.begin(WorldEditorPending(commandID: 9, identity: identity, schedule: schedule, propertyID: "object.duplicate",
                                   targetID: "r", expectedRevision: 2, proposedValue: nil, capabilities: caps,
                                   startedAt: Date()))
    var ack = LabAck(id: 9, ok: false, action: "edit_object", message: "no free shape slots",
                     appliedTick: 40, appliedEpoch: 2, status: "rejected", sessionID: "editor", epoch: 2)
    ack.connectionGeneration = identity.generation
    ack.edit = try? JSONDecoder().decode(EnvironmentEditResult.self, from: Data(
        #"{"ok":false,"status":"rejected_capacity","path":"object_edit.operation","reason":"no free shape slots"}"#.utf8))
    _ = state.accept(ack)
    check("full slot pool explained in words, not the raw backend reason",
          state.isError && !state.message.contains("no free") && state.message.contains(L("slot", "자리")))
}
