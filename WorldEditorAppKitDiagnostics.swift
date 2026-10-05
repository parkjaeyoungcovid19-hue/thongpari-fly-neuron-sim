import Cocoa

func runWorldEditorAppKitChecks(_ check:(String,Bool)->Void) {
    let root=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
    let caps=try! JSONDecoder().decode(EnvironmentCapabilities.self,from:Data(contentsOf:root.appendingPathComponent("fixtures/environment_capabilities/valid.json")))
    let identity=WorldEditorIdentity(generation:4,sessionID:"editor",epoch:2)
    let schedule=LabCommandSchedule(sessionID:"editor",epoch:2,requestedTick:40)
    let camera=WorldViewerMuJoCoCamera(positionMM:[0,-100,40],forward:[0,1,-0.3],distanceMM:100,fovyDeg:45)
    let source=LabWorldObjectRemote(id:"source",shape:"box",positionMM:[0,0,5],sizeMM:[6,8,10],yawDeg:30,revision:7)
    let hidden=NSWindow(contentRect:NSRect(x:-2000,y:-2000,width:360,height:480),styleMask:.borderless,backing:.buffered,defer:false)
    let live=WorldEditorInspector(frame:NSRect(x:0,y:0,width:340,height:450)); hidden.contentView=live
    var owner=source
    func poll() { live.update(objects:[owner],selectedID:owner.id,capabilities:caps,identity:identity,mode:.edit,available:true,heldID:nil,camera:camera) }
    var sent:[LabCommand]=[]; live.onSubmit={c, captured in guard captured==identity else { return nil }; sent.append(c); return (7,schedule) }
    poll(); owner.positionMM[0]=12; poll(); check("clean dynamic pose tracks owner",live.fields[0].stringValue=="12")
    live.fields[0].selectText(nil)
    if let e=live.fields[0].currentEditor() as? NSTextView {
        check("real shared field editor exists",true)
        e.string="77"; live.fields[0].stringValue="77"; live.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        owner.positionMM[0]=20; poll(); check("active same-revision draft frozen",e.string=="77")
        owner.revision=8; owner.positionMM[0]=23; poll(); check("authored revision replaces shared field editor",e.string=="23" && live.fields[0].stringValue=="23")
        _=live.control(live.fields[0],textView:e,doCommandBy:#selector(NSResponder.insertNewline(_:)))
        check("Return cannot silently rebase old text",sent.last?.edit?.value == .vector([23,0,5]) && sent.last?.edit?.expectedRevision==8)
    } else { check("real shared field editor exists",false) }
    let esc=WorldEditorInspector(frame:live.frame); hidden.contentView=esc
    esc.update(objects:[source],selectedID:"source",capabilities:caps,identity:identity,mode:.edit,available:true,heldID:nil,camera:camera)
    esc.onSubmit={c,_ in sent.append(c); return (8,schedule)}; esc.fields[0].selectText(nil)
    if let e=esc.fields[0].currentEditor() as? NSTextView {
        e.string="99"; esc.fields[0].stringValue="99"; esc.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        _=esc.control(esc.fields[0],textView:e,doCommandBy:#selector(NSResponder.cancelOperation(_:)))
        check("Escape replaces real shared editor",e.string=="0" && esc.fields[0].stringValue=="0")
        _=esc.control(esc.fields[0],textView:e,doCommandBy:#selector(NSResponder.insertNewline(_:)))
        check("Escape then Return cannot resubmit old text",sent.last?.edit?.value == .vector([0,0,5]))
    } else { check("second shared field editor exists",false) }
    hidden.close()
    let empty=try! JSONDecoder().decode(WorldRenderSnapshot.self,from:Data(#"{"type":"world_render_snapshot","protocol_version":5,"session_id":"editor","epoch":2,"request_seq":1,"sim_tick":40,"ok":true,"snapshot_seq":1,"world_revision":8,"fly":{"id":"fly","position_mm":[0,0,0],"orientation_quat_xyzw":[0,0,0,1]},"objects":[]}"#.utf8))
    func ack(_ property:String,_ id:String) -> LabAck {
        var a=LabAck(id:7,ok:true,action:"edit_object",message:"applied",appliedTick:40,appliedEpoch:2,status:"applied",sessionID:"editor",epoch:2)
        a.connectionGeneration=4
        a.edit=try! JSONDecoder().decode(EnvironmentEditResult.self,from:JSONSerialization.data(withJSONObject:["ok":true,"status":"applied","property_id":property,"target_id":"source","revision":8,"actual_value":id]))
        return a
    }
    var modeState=LabViewState(); modeState.mode = .participate; modeState.beginModeTransition(to:.edit)
    modeState.accept(snapshot:empty,connectionGeneration:4)
    check("confirmed participant removal enters Edit",modeState.mode == .edit && modeState.pendingMode == nil && modeState.selectedPlayerID == nil)
    let selection=WorldEditorInspector(frame:.zero)
    func select(_ id:String?,objects:[LabWorldObjectRemote]=[source]) { selection.update(objects:objects,selectedID:id,capabilities:caps,identity:identity,mode:.edit,available:true,heldID:nil,camera:camera) }
    func button(_ selector:String,_ view:NSView) -> NSButton? {
        if let b=view as? NSButton, b.action==NSSelectorFromString(selector) { return b }
        return view.subviews.compactMap { button(selector,$0) }.first
    }
    select("source"); selection.onSubmit={_,_ in (7,schedule)}
    var chosen:String?="source"; selection.onSelect={chosen=$0}
    button("remove",selection)?.performClick(nil)
    check("snapshot before delete ACK retains original",selection.retainSelection(chosen,snapshot:empty)=="source")
    select(chosen,objects:[]); selection.accept(ack("object.delete","source")); check("own delete ACK clears captured selection",chosen==nil)
    select("source"); chosen="source"; button("duplicate",selection)?.performClick(nil); selection.accept(ack("object.duplicate","new"))
    check("duplicate ACK before snapshot retains new ID",chosen=="new" && selection.retainSelection(chosen,snapshot:empty)=="new")
    select("source"); chosen="source"; button("duplicate",selection)?.performClick(nil); select("newer"); chosen="newer"
    selection.accept(ack("object.duplicate","late")); check("late ACK cannot steal newer selection",chosen=="newer")
}
