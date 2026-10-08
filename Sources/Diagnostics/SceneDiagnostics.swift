#if DIAGNOSTICS
import Cocoa
/// End-to-end transport acceptance through the app's public decoder and queues.
func runSceneLoopTest() {
    let bridge = FlyGymBridge()
    let suite = Suite()
    func check(_ name: String, _ ok: Bool) {
        suite.check("scene " + name, ok)
    }
    func wait<T>(_ get: () -> T?) -> T? {
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if let value = get() { return value }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
    bridge.start()
    guard let _ = wait({ bridge.serverHello() }) else { bridge.stop(); exit(1) }
    let session = "scene-" + UUID().uuidString
    _ = bridge.sendSessionControl(action: "begin", sessionID: session, epoch: 1, simTick: 0, mode: .interactive)
    check("scene capability public decoder", wait { bridge.latestLabState()?.worldState?.sceneCapabilities }.map { $0.supported } == true)
    check("begin", wait { bridge.latestSessionState().flatMap { $0.sessionID == session && $0.state == "running" ? $0 : nil } }?.ok == true)
    _ = bridge.sendSessionControl(action: "pause", sessionID: session, epoch: 1, simTick: 0, mode: .interactive)
    let paused = wait { bridge.latestSessionState().flatMap { $0.sessionID == session && $0.state == "paused" ? $0 : nil } }
    check("paused barrier", paused?.ok == true)
    func send(_ command: LabCommand) -> LabAck? {
        var command = command
        command.protocolVersion = 4; command.sessionID = session; command.epoch = 1; command.requestedTick = 0
        let id = bridge.sendLabCommand(command)
        return wait { bridge.latestLabAck().flatMap { $0.id == id ? $0 : nil } }
    }
    let export = send(LabCommand(id: 0, action: "export_scene"))
    check("export exact text through decoder", export?.ok == true && export?.scene?.documentText != nil)
    if let text = export?.scene?.documentText, let canonical = export?.scene?.canonicalScene {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scene-test-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("Roundtrip.flyworld")
            try SceneFile.write(text, to: url, canonicalScene: canonical)
            check("atomic file roundtrip", try SceneFile.read(url) == text)
            do { try SceneFile.write(text, to: url, canonicalScene: "{}"); check("wrong hash fails", false) }
            catch { check("wrong hash keeps previous file", try SceneFile.read(url) == text) }
            let load = send(LabCommand(id: 0, action: "load_scene", sceneDocument: try SceneFile.read(url)))
            check("load at same paused tick", load?.ok == true && load?.appliedTick == export?.appliedTick && load?.scene?.contentSHA256 != nil)
            let before = bridge.latestLabState()?.authoritativeObjects?.map(\.id)
            let reject = send(LabCommand(id: 0, action: "load_scene", sceneDocument: "{}"))
            check("invalid scene rejected unchanged", reject?.ok == false && before == bridge.latestLabState()?.authoritativeObjects?.map(\.id))
            let again = send(LabCommand(id: 0, action: "export_scene"))
            check("same settings after rejected load", again?.scene?.documentText == text)
        } catch { suite.check("scene file", false, "\(error)") }
    } else { check("export has text and canonical scene", false) }
    bridge.stop()
    print("SCENELOOP \(suite.failures == 0 ? "PASS" : "FAIL") (\(suite.failures) failures)")
    suite.finish()
}

#endif
