import Cocoa
import UniformTypeIdentifiers
import Darwin
import CryptoKit

/// Backend-owned document text. No neuron/body checkpoint is decoded here.
struct SceneResult: Decodable {
    var documentText: String?
    var canonicalScene: String?
    var kind: String
    var contentSHA256: String?
    enum CodingKeys: String, CodingKey {
        case documentText = "document_text", kind
        case contentSHA256 = "content_sha256"
        case canonicalScene = "canonical_scene"
    }
}

enum SceneFile {
    static let maximumBytes = 1 << 20
    static func checkedData(_ text: String, canonicalScene: String? = nil) throws -> Data {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == "thongpari.flyworld",
              json["schema_version"] as? Int == 1,
              json["kind"] as? String == "scene_settings",
              let hash = json["content_sha256"] as? String,
              hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
              json["scene"] is [String: Any] else {
            throw NSError(domain: "SceneFile", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Invalid scene document", "잘못된 장면 파일입니다")])
        }
        if let canonicalScene {
            let bytes = Data(canonicalScene.utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == hash,
                  let scene = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary,
                  scene.isEqual(json["scene"]) else { throw CocoaError(.fileReadCorruptFile) }
        }
        return data
    }
    static func read(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        _ = try checkedData(text)
        return text
    }
    static func write(_ text: String, to url: URL, canonicalScene: String) throws {
        let data = try checkedData(text, canonicalScene: canonicalScene)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".flyworld-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard try Data(contentsOf: temporary) == data else { throw CocoaError(.fileWriteUnknown) }
        _ = try read(temporary)
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

/// End-to-end transport acceptance through the app's public decoder and queues.
func runSceneLoopTest() {
    let bridge = FlyGymBridge()
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") scene \(name)")
        if !ok { failures += 1 }
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
        } catch { print("FAIL scene file \(error)"); failures += 1 }
    } else { failures += 1 }
    bridge.stop()
    print("SCENELOOP \(failures == 0 ? "PASS" : "FAIL") (\(failures) failures)")
    exit(failures == 0 ? 0 : 1)
}
