// Sim.swift — loads the FULL FlyWire v783 connectome (139,255 neurons,
// 15,091,983 signed edges) from `data/` and defines the types the body, the
// brain window and the simulation share. The simulation itself is a Metal
// compute kernel; see MetalSim.swift and LIF.metal.

import Foundation
import simd

// What the brain tells the body each frame.
struct BrainSignals {
    var escape = false        // giant fiber spiked -> takeoff NOW
    var nervous: CGFloat = 0  // looming-detector population rate, 0..1
    var turnBias: CGFloat = 0 // rad/s steering from DNa01/DNa02 left-right rate difference
    var backward = false      // MDN burst -> backward walking
    var walkDrive: CGFloat = 0  // DNp09 forward-walking command rate, ~0..1.5
    var groomDrive: CGFloat = 0 // DNg11 grooming command rate, ~0..1.5
    var wingDrive: CGFloat = 0  // DNp02/04/11 escape-maneuver DN rate, ~0..1.3
    var arousal: CGFloat = 0    // whole-population activity, ~0..1
    var tempo: CGFloat = 1      // thermal "temperature" scaling of locomotion
    var sleep = false           // circadian + idle -> sleep-like state
}

// Thread-safe spike hand-off from the sim (fly render loop) to the brain window.
final class SpikeBus {
    private let lock = NSLock()
    private var events: [(neuron: Int, isGF: Bool)] = []
    func push(_ e: [(Int, Bool)]) {
        guard !e.isEmpty else { return }
        lock.lock()
        events.append(contentsOf: e)
        if events.count > 256 { events.removeFirst(events.count - 256) }
        lock.unlock()
    }
    func popAll() -> [(neuron: Int, isGF: Bool)] {
        lock.lock(); defer { lock.unlock() }
        let e = events; events.removeAll(); return e
    }
}

/// Finds a shipped resource (`data/connectome.json`, `LIF.metal`, ...) next to
/// the executable first, then in the current directory.
func findResource(_ relativePath: String) -> URL? {
    let fm = FileManager.default
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent()
    var roots = [exeDir]
    if let resources = Bundle.main.resourceURL { roots.append(resources) }
    roots.append(URL(fileURLWithPath: fm.currentDirectoryPath))
    return roots.map { $0.appendingPathComponent(relativePath) }
                .first { fm.fileExists(atPath: $0.path) }
}

// MARK: - Connectome

/// Role ids, i.e. indices into the manifest's `roles` string table (mirrored by
/// `Role.names`). The order is fixed by the ETL and asserted at load.
enum Role {
    static let other: UInt8 = 0, lc4: UInt8 = 1, lplc2: UInt8 = 2, gf: UInt8 = 3
    static let dna01: UInt8 = 4, dna02: UInt8 = 5, dnp09: UInt8 = 6, dng11: UInt8 = 7
    static let mdn: UInt8 = 8, escw: UInt8 = 9, ascend: UInt8 = 10, sens: UInt8 = 11
    static let count = 12
    static let names = ["other", "lc4", "lplc2", "gf", "dna01", "dna02",
                        "dnp09", "dng11", "mdn", "escw", "ascend", "sens"]
}

/// The whole connectome, exactly as `data/connectome.json` describes it. Every
/// array is located through the manifest (`{file, byteOffset, dtype, count,
/// components}`) — no byte offsets are hardcoded here.
///
/// The two 60 MB edge arrays stay as raw (memory-mapped) `Data`; they are only
/// ever consumed once, when the shared `MTLBuffer`s are built.
struct Connectome {
    let n: Int
    let e: Int
    let positions: [SIMD3<Float>]
    let superClass: [UInt8]
    let side: [UInt8]            // 0 center/unknown, 1 left, 2 right
    let nt: [UInt8]              // 0 UNKNOWN, 1 ACH, 2 GABA, 3 GLUT, 4 DA, 5 SER, 6 OCT
    let role: [UInt8]            // index into Role.names, 0 = other
    let rootId: [UInt64]         // FlyWire root id, for labels and debugging
    let rowStart: [UInt32]       // N+1; rowStart[i]..rowStart[i+1] = i's OUT-edges
    let colIdxData: Data         // uint32 × E
    let weightData: Data         // int16 × E, sign(pre) × synapse count
    let superClassNames: [String]
    let ntNames: [String]
    let isModulatory: [Bool]     // indexed by nt id (DA / SER / OCT)
    let roleIndices: [[Int]]     // neuron indices per role id; [Role.other] is left empty
    let roleName: [String]       // per neuron
    let typeName: [String]       // per neuron: cell type name, else super class name
    let loadMs: Double

    /// Immutable GPU resources (CSR buffers, compiled pipelines) shared by every
    /// `MetalSim` built on this connectome. Populated on the first sim init so a
    /// second sim (e.g. one per --behaviortest scenario) is cheap.
    let gpu = GPUCache()
    final class GPUCache { var shared: MetalShared? }

    var summary: String { "FlyWire v783 · \(n) neurons · \(e) edges" }
}

private struct Manifest: Decodable {
    struct Rec: Decodable {
        let file: String, byteOffset: Int, dtype: String, count: Int, components: Int
    }
    struct Tables: Decodable {
        let superClasses: [String], sides: [String], nts: [String]
        let roles: [String], cellTypes: [String]
    }
    let neuronCount: Int
    let edgeCount: Int
    let arrays: [String: Rec]
    let stringTables: Tables
    let roleCounts: [String: Int]
    let modulatoryNts: [String]
}

private let dtypeBytes = ["float32": 4, "uint8": 1, "uint16": 2, "uint32": 4,
                          "int16": 2, "int32": 4, "uint64": 8]

private struct Bin {
    let files: [String: Data]
    let arrays: [String: Manifest.Rec]

    func raw(_ name: String, elementSize: Int) throws -> Data {
        guard let rec = arrays[name] else { throw Err("manifest has no array '\(name)'") }
        guard dtypeBytes[rec.dtype] == elementSize else {
            throw Err("array '\(name)': dtype \(rec.dtype) does not match the \(elementSize)-byte reader")
        }
        guard let file = files[rec.file] else { throw Err("array '\(name)': missing file \(rec.file)") }
        // `count` is the total element count; `components` only describes the
        // interleave (pos is 417,765 floats = 139,255 x 3).
        guard rec.components > 0, rec.count % rec.components == 0 else {
            throw Err("array '\(name)': count \(rec.count) is not a multiple of \(rec.components) components")
        }
        let bytes = rec.count * elementSize
        guard rec.byteOffset >= 0, rec.byteOffset + bytes <= file.count else {
            throw Err("array '\(name)' runs past the end of \(rec.file)")
        }
        return file[rec.byteOffset..<(rec.byteOffset + bytes)]
    }

    func array<T>(_ name: String, _ type: T.Type) throws -> [T] {
        let d = try raw(name, elementSize: MemoryLayout<T>.size)
        let count = d.count / MemoryLayout<T>.size
        return d.withUnsafeBytes { buf -> [T] in
            // Manifest offsets are 16-byte aligned and Data slices keep the parent
            // mapping's alignment, so a direct bind is safe; loadUnaligned would
            // cost an extra copy of 60 MB arrays.
            [T](UnsafeBufferPointer(start: buf.baseAddress!.assumingMemoryBound(to: T.self),
                                    count: count))
        }
    }

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

/// Reads `data/connectome.json` plus its two binaries and validates the CSR.
/// Returns nil (after logging why) if anything is missing or inconsistent.
func loadConnectome() -> Connectome? {
    let t0 = DispatchTime.now()
    do {
        guard let manifestURL = findResource("data/connectome.json") else {
            throw Bin.Err("no data/connectome.json next to the executable or in the working directory")
        }
        let dir = manifestURL.deletingLastPathComponent()
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        var files: [String: Data] = [:]
        for name in Set(m.arrays.values.map(\.file)) {
            files[name] = try Data(contentsOf: dir.appendingPathComponent(name),
                                   options: .mappedIfSafe)
        }
        let bin = Bin(files: files, arrays: m.arrays)
        let n = m.neuronCount, e = m.edgeCount

        guard m.stringTables.roles == Role.names else {
            throw Bin.Err("role table changed: \(m.stringTables.roles) != \(Role.names)")
        }

        let flat = try bin.array("pos", Float.self)
        guard flat.count == n * 3 else { throw Bin.Err("pos has \(flat.count) floats, expected \(n * 3)") }
        var positions = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n { positions[i] = SIMD3(flat[3 * i], flat[3 * i + 1], flat[3 * i + 2]) }

        let superClass = try bin.array("superClass", UInt8.self)
        let side = try bin.array("side", UInt8.self)
        let nt = try bin.array("nt", UInt8.self)
        let role = try bin.array("role", UInt8.self)
        let cellType = try bin.array("cellType", UInt16.self)
        let rootId = try bin.array("rootId", UInt64.self)
        let rowStart = try bin.array("rowStart", UInt32.self)
        let colIdxData = try bin.raw("colIdx", elementSize: 4)
        let weightData = try bin.raw("weight", elementSize: 2)

        // ---- structural checks -------------------------------------------------
        guard superClass.count == n, side.count == n, nt.count == n, role.count == n,
              cellType.count == n, rootId.count == n else {
            throw Bin.Err("per-neuron array length mismatch")
        }
        guard rowStart.count == n + 1 else { throw Bin.Err("rowStart has \(rowStart.count) entries, expected \(n + 1)") }
        guard rowStart[0] == 0 else { throw Bin.Err("rowStart[0] = \(rowStart[0]), expected 0") }
        guard rowStart[n] == UInt32(e) else { throw Bin.Err("rowStart[N] = \(rowStart[n]), expected E = \(e)") }
        guard colIdxData.count == e * 4, weightData.count == e * 2 else {
            throw Bin.Err("edge arrays are not E = \(e) long")
        }
        var maxCol: UInt32 = 0
        var zeroWeights = 0
        colIdxData.withUnsafeBytes { cb in
            weightData.withUnsafeBytes { wb in
                let c = cb.baseAddress!.assumingMemoryBound(to: UInt32.self)
                let w = wb.baseAddress!.assumingMemoryBound(to: Int16.self)
                for k in 0..<e {
                    if c[k] > maxCol { maxCol = c[k] }
                    if w[k] == 0 { zeroWeights += 1 }
                }
            }
        }
        guard maxCol < UInt32(n) else { throw Bin.Err("colIdx max = \(maxCol), must be < N = \(n)") }
        guard zeroWeights == 0 else { throw Bin.Err("\(zeroWeights) edges have weight 0") }

        // ---- derived tables ----------------------------------------------------
        var roleIndices = [[Int]](repeating: [], count: Role.count)
        var roleTally = [Int](repeating: 0, count: Role.count)
        for i in 0..<n {
            let r = Int(role[i])
            roleTally[r] += 1
            if r != Int(Role.other) { roleIndices[r].append(i) }
        }
        for (r, name) in Role.names.enumerated() {
            guard roleTally[r] == m.roleCounts[name] else {
                throw Bin.Err("role '\(name)': \(roleTally[r]) neurons, manifest says \(m.roleCounts[name] ?? -1)")
            }
        }

        let classNames = m.stringTables.superClasses
        let typeNames = m.stringTables.cellTypes
        var roleName = [String](repeating: "", count: n)
        var typeName = [String](repeating: "", count: n)
        for i in 0..<n {
            roleName[i] = Role.names[Int(role[i])]
            let t = typeNames[Int(cellType[i])]
            typeName[i] = t.isEmpty ? classNames[Int(superClass[i])] : t
        }
        var isModulatory = [Bool](repeating: false, count: m.stringTables.nts.count)
        for (i, name) in m.stringTables.nts.enumerated() where m.modulatoryNts.contains(name) {
            isModulatory[i] = true
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        return Connectome(n: n, e: e, positions: positions, superClass: superClass, side: side,
                          nt: nt, role: role, rootId: rootId,
                          rowStart: rowStart, colIdxData: colIdxData, weightData: weightData,
                          superClassNames: classNames, ntNames: m.stringTables.nts,
                          isModulatory: isModulatory, roleIndices: roleIndices,
                          roleName: roleName, typeName: typeName, loadMs: ms)
    } catch {
        fputs("connectome load failed: \(error)\n", stderr)
        return nil
    }
}
