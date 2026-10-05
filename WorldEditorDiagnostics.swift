import Cocoa

/// Headless owner-boundary, projection, and Cocoa draft checks. No GPU/listener.
func runWorldEditorTest() {
    _ = NSApplication.shared
    var failures=0
    func check(_ name:String,_ ok:Bool) { print((ok ? "PASS" : "FAIL")+"  V6.3 "+name); if !ok { failures += 1 } }
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
    print("V6.3 editor diagnostics: \(failures) failures"); exit(failures==0 ? 0 : 1)
}
