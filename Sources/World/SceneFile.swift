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
