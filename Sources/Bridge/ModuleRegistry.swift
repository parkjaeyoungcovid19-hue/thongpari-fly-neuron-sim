// ModuleRegistry.swift — V8.2 host registry of INSTALLED external I/O modules.
//
// A module is installed when a `*.json` descriptor sits in a declared directory
// (default `~/Library/Application Support/ThongpariFlyNeuronSim/modules`, plus
// any extra directories a caller/test passes). Each file is decoded with the
// 8.1 decoder (`ExternalIOModuleDescriptor.decode`) and is either registered or
// listed as rejected WITH the reason — never silently dropped. A second
// descriptor with an already-registered module_id is rejected (`duplicate_id`);
// directories are scanned in the given order and files sorted by name, so the
// earlier one wins deterministically.
//
// DATA ONLY. Loading reads bytes and parses JSON; nothing here executes,
// loads, links or launches anything (no plugins, scripts, dlopen, Process) —
// the same boundary as declarative scene import (`SceneFile`: bounded JSON,
// strict decode). Unknown keys in a descriptor (including script-like ones) are
// ignored by the decoder and never interpreted. Nothing is attached or sent in
// 8.2; every registered module stays at lifecycle `validated`.
import Foundation

struct ExternalIORegisteredModule: Equatable {
    let descriptor: ExternalIOModuleDescriptor
    let file: String
    var lifecycle: ExternalIOLifecycle
}

struct ExternalIORejectedModule: Equatable {
    let file: String
    let moduleID: String?          // best effort, only when the file is JSON with a string module_id
    let code: String               // ExternalIOError.Code raw value, or file-level code
    let reason: String             // human-readable detail with path
}

final class ExternalIOModuleRegistry {
    static let maximumDescriptorBytes = 256 * 1024
    static let maximumFilesPerDirectory = 256

    /// Production location. Absent directory = no modules (not an error).
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThongpariFlyNeuronSim/modules", isDirectory: true)
    }

    let directories: [URL]
    private(set) var modules: [ExternalIORegisteredModule] = []
    private(set) var rejected: [ExternalIORejectedModule] = []

    init(directories: [URL] = [ExternalIOModuleRegistry.defaultDirectory]) {
        self.directories = directories
        reload()
    }

    /// Runtime lookup by module_id.
    func module(_ id: String) -> ExternalIORegisteredModule? { modules.first { $0.descriptor.moduleID == id } }

    func reload() {
        modules = []; rejected = []
        let fm = FileManager.default
        for dir in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let jsonNames = names.filter { $0.lowercased().hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
            for name in jsonNames.prefix(Self.maximumFilesPerDirectory) {
                load(dir.appendingPathComponent(name), fileLabel: name)
            }
            if jsonNames.count > Self.maximumFilesPerDirectory {
                rejected.append(ExternalIORejectedModule(file: dir.lastPathComponent + "/…", moduleID: nil, code: "too_many_files",
                                                         reason: "\(jsonNames.count) descriptors; only the first \(Self.maximumFilesPerDirectory) are read"))
            }
        }
    }

    private func reject(_ file: String, _ id: String?, _ code: String, _ reason: String) {
        rejected.append(ExternalIORejectedModule(file: file, moduleID: id, code: code, reason: reason))
    }

    private func load(_ url: URL, fileLabel: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else {
            reject(fileLabel, nil, "not_a_regular_file", "not a regular file (symlinks and directories are not followed)"); return
        }
        guard (attrs[.size] as? Int ?? .max) <= Self.maximumDescriptorBytes else {
            reject(fileLabel, nil, "file_too_large", "descriptor larger than \(Self.maximumDescriptorBytes) bytes"); return
        }
        guard let data = try? Data(contentsOf: url) else { reject(fileLabel, nil, "unreadable", "cannot read file"); return }
        let rawID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["module_id"] as? String }
        do {
            let d = try ExternalIOModuleDescriptor.decode(data)
            if let first = module(d.moduleID) {
                reject(fileLabel, d.moduleID, ExternalIOError.Code.duplicateID.rawValue, "module_id already registered from \(first.file)")
            } else {
                modules.append(ExternalIORegisteredModule(descriptor: d, file: fileLabel, lifecycle: .validated))
            }
        } catch let e as ExternalIOError {
            reject(fileLabel, rawID, e.code.rawValue, e.description)
        } catch {
            reject(fileLabel, rawID, "invalid_value", "\(error)")
        }
    }
}

// MARK: - Pure view model (the Lab panel only renders this)

struct ExternalIOChannelRow: Equatable {
    let name: String
    let direction: String      // "in" = module -> host observation, "out" = host -> module action
    let kind: String
    let unit: String
    let axis: String
    let range: String
    let rate: String
}

struct ExternalIOModuleRow: Equatable {
    let moduleID: String
    let title: String
    let version: String
    let attachMode: String
    let clockMode: String
    let lifecycle: String
    let channels: [ExternalIOChannelRow]
}

struct ExternalIOModuleListModel: Equatable {
    let modules: [ExternalIOModuleRow]
    let rejected: [ExternalIORejectedModule]

    init(_ registry: ExternalIOModuleRegistry) {
        func rows(_ list: [ExternalIOChannelSchema], _ dir: String) -> [ExternalIOChannelRow] {
            list.map { c in
                let range: String
                switch c.kind {
                case .continuous: range = "\(Self.num(c.minimum ?? 0))...\(Self.num(c.maximum ?? 0))" + (c.length > 1 ? " x\(c.length)" : "")
                case .discrete: range = c.choices.joined(separator: "|")
                case .frame: range = c.formats.map { $0.rawValue }.joined(separator: "|")
                }
                return ExternalIOChannelRow(name: c.channelID + (c.optional ? "?" : ""), direction: dir, kind: c.kind.rawValue,
                                            unit: c.unit, axis: c.axis, range: range, rate: Self.num(c.rateHz) + " Hz")
            }
        }
        modules = registry.modules.map { m in
            let d = m.descriptor
            return ExternalIOModuleRow(moduleID: d.moduleID, title: d.displayName, version: d.version, attachMode: d.attachMode.rawValue,
                                       clockMode: d.clockMode.rawValue, lifecycle: m.lifecycle.rawValue,
                                       channels: rows(d.observations, "in") + rows(d.actions, "out"))
        }
        rejected = registry.rejected
    }

    private static func num(_ x: Double) -> String { x == x.rounded() && abs(x) < 1e9 ? String(Int(x)) : String(format: "%g", x) }
}
