#if DIAGNOSTICS
// --externaliotest: V8.1 external_io.v1 contract. Fixtures are decoded by the
// real decoder; mutations are derived from the valid fixtures by path edits and
// must each be rejected with the code named in mutations.json. The neural-output
// table is compared with a Mirror of the real `BrainSignals` type, and its
// ranges against what SignalBuilder actually emits for extreme inputs.
import Foundation

private func setPath(_ node: Any, _ path: ArraySlice<Substring>, _ op: [String: Any]) -> Any? {
    guard let head = path.first else {
        if op["remove"] as? Bool == true { return nil }
        if let f = op["float"] as? String { return f == "nan" ? Double.nan : Double.infinity }
        return op["set"]
    }
    let rest = path.dropFirst()
    if var d = node as? [String: Any] {
        let key = String(head)
        if let v = setPath(d[key] as Any, rest, op) { d[key] = v } else if rest.isEmpty { d.removeValue(forKey: key) }
        return d
    }
    if var a = node as? [Any], let i = Int(head), a.indices.contains(i) {
        if let v = setPath(a[i], rest, op) { a[i] = v }
        return a
    }
    return node
}

private struct SeededUnit {
    var state: UInt64
    mutating func nextUnit() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
}
private extension SystemRandomNumberGenerator { static func withSeed(_ s: UInt64) -> SeededUnit { SeededUnit(state: s) } }

func runExternalIOTest() {
    let suite = Suite()
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check("V8.1 " + name, ok, detail) }
    let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let dir = binDir.appendingPathComponent("fixtures/external-io", isDirectory: true)
    func json(_ url: URL) -> Any? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    func fixture(_ name: String) -> Any? { json(dir.appendingPathComponent(name)) }

    // ---- valid descriptors decode and round-trip -------------------------------------------------
    var descriptors: [String: ExternalIOModuleDescriptor] = [:]
    for name in ["descriptor-auxiliary.json", "descriptor-external-environment.json"] {
        guard let any = fixture(name), let d = try? ExternalIOModuleDescriptor.decode(any) else {
            check("\(name) decodes", false); continue
        }
        descriptors[d.moduleID] = d
        let again = try? ExternalIOModuleDescriptor.decode(d.jsonObject)
        check("\(name) decodes and round-trips", again == d)
    }
    let aux = descriptors["fixture.sensor_loopback"], env = descriptors["fixture.loopback"]
    check("auxiliary fixture is sensor-only", aux?.attachMode == .auxiliary && aux?.actions.isEmpty == true && aux?.observations.isEmpty == false)
    check("external_environment fixture has continuous + discrete actions",
          env?.attachMode == .externalEnvironment && Set(env?.actions.map { $0.kind } ?? []) == [.continuous, .discrete])
    check("fixture ids are generic", descriptors.keys.allSatisfy { $0.hasPrefix("fixture.") })

    // ---- valid frames decode and round-trip ------------------------------------------------------
    if let aux, let env {
        func obs(_ name: String, _ d: ExternalIOModuleDescriptor) {
            guard let any = fixture(name), let f = try? ExternalIOObservationFrame.decode(any, descriptor: d, receiveMonotonic: 12.5) else {
                check("\(name) decodes", false); return
            }
            let data = try? JSONSerialization.data(withJSONObject: f.jsonObject(descriptor: d))
            let again = data.flatMap { try? ExternalIOObservationFrame.decode($0, descriptor: d, receiveMonotonic: 12.5) }
            check("\(name) decodes and round-trips", again == f)
            check("\(name) keeps host receive time apart from source time", f.receiveMonotonicTime == 12.5 && Double(f.sourceTick) != f.receiveMonotonicTime)
        }
        obs("observation-sensor.json", aux)
        obs("observation-loopback.json", env)
        if let any = fixture("observation-sensor.json"), let f = try? ExternalIOObservationFrame.decode(any, descriptor: aux, receiveMonotonic: 1) {
            check("sensor frame carries a bounded frame reference", f.frame?.width == 16 && f.frame?.byteLength == 256 && f.sourceTimeSeconds == 1.2)
        }
        if var o = fixture("observation-sensor.json") as? [String: Any] {
            o["source_time_s"] = nil; o["frame"] = nil; o["receive_monotonic_time"] = -5
            check("optional telemetry (source_time_s, optional frame) tolerated absent; peer receive time ignored",
                  (try? ExternalIOObservationFrame.decode(o, descriptor: aux, receiveMonotonic: 3))?.receiveMonotonicTime == 3)
        }
        if let any = fixture("action-loopback.json"), let f = try? ExternalIOActionFrame.decode(any, descriptor: env) {
            let data = try? JSONSerialization.data(withJSONObject: f.jsonObject(descriptor: env))
            check("action-loopback.json decodes and round-trips", data.flatMap { try? ExternalIOActionFrame.decode($0, descriptor: env) } == f)
            check("action frame has continuous + discrete entries and an id", f.actions.count == 2 && f.actionID == "act-0004")
            check("auxiliary descriptor refuses action frames", { () -> Bool in
                do { _ = try ExternalIOActionFrame.decode(any, descriptor: aux); return false } catch let e as ExternalIOError { return e.code == .modeViolation } catch { return false }
            }())
        } else { check("action-loopback.json decodes", false) }
    }

    // ---- mutations -------------------------------------------------------------------------------
    if let m = fixture("mutations.json") as? [String: Any], let cases = m["cases"] as? [[String: Any]] {
        check("mutation catalogue is non-trivial", cases.count >= 20, "\(cases.count)")
        for c in cases {
            guard let name = c["name"] as? String, let base = c["base"] as? String, let ops = c["ops"] as? [[String: Any]],
                  let code = c["code"] as? String, var doc = fixture(base) else { check("mutation case well-formed", false); continue }
            let orig = doc as? [String: Any]
            let moduleID = (orig?["module_id"] ?? orig?["target_endpoint"]) as? String ?? ""
            for op in ops {
                guard let path = op["path"] as? String, let r = setPath(doc, path.split(separator: ".")[...], op) else { continue }
                doc = r
            }
            var got = "accepted"
            do {
                if base.hasPrefix("descriptor-") { _ = try ExternalIOModuleDescriptor.decode(doc) }
                else if let d = descriptors[moduleID] {
                    if base.hasPrefix("observation-") { _ = try ExternalIOObservationFrame.decode(doc, descriptor: d, receiveMonotonic: 1) }
                    else { _ = try ExternalIOActionFrame.decode(doc, descriptor: d) }
                } else { got = "no descriptor" }
            } catch let e as ExternalIOError { got = e.code.rawValue } catch { got = "other error" }
            check("mutation \(name) rejected as \(code)", got == code, "got \(got)")
        }
    } else { check("mutations.json present", false) }

    // ---- unknown *offered* capability is tolerated; unknown required is not (covered above) -----------
    if var o = fixture("descriptor-auxiliary.json") as? [String: Any] {
        o["capabilities"] = ["observation_frames", "image_frames", "future_thing"]
        o["unknown_extra_key"] = 1
        check("unknown offered capability and extra keys tolerated", (try? ExternalIOModuleDescriptor.decode(o))?.capabilities == ["observation_frames", "image_frames"])
    }

    // ---- neural output enumeration vs the real types ---------------------------------------------
    let mirrored = Mirror(reflecting: BrainSignals()).children.compactMap { $0.label }
    check("neural-output table lists exactly the BrainSignals fields", Set(mirrored) == Set(ExternalIONeuralOutput.names) && mirrored.count == ExternalIONeuralOutput.names.count,
          "\(mirrored) vs \(ExternalIONeuralOutput.names)")
    let packetKeys = Set(Mirror(reflecting: FlyGymBrainPacket(signals: BrainSignals(), simMs: 0)).children.compactMap { $0.label })
    check("every neural-output field reaches the FlyGym brain packet", packetKeys.isSuperset(of: ["walk", "turn", "escape", "backward", "groom", "wing", "arousal", "tempo", "sleep", "nervous"]))
    // Ranges measured against SignalBuilder itself, not restated: extreme inputs must stay inside.
    var lo = Dictionary(uniqueKeysWithValues: ExternalIONeuralOutput.names.map { ($0, Double.infinity) })
    var hi = Dictionary(uniqueKeysWithValues: ExternalIONeuralOutput.names.map { ($0, -Double.infinity) })
    let builder = SignalBuilder()
    for rate in [Float(0), 1, 10, 50, 200, 5000, 1e6] {
        for sign in [Float(1), -1] {
            let s = builder.make(MotorReadoutInput(giantFiberSpiked: sign > 0, rateLoom: rate, rateDNaL: rate * sign, rateDNaR: 0, rateMDN: rate,
                                                   rateFwd: rate * sign, rateGroom: rate * sign, rateEscW: rate * sign, ratePop: rate * sign), dt: 0.5)
            let v: [String: Double] = ["escape": s.escape ? 1 : 0, "nervous": Double(s.nervous), "turnBias": Double(s.turnBias),
                                       "backward": s.backward ? 1 : 0, "walkDrive": Double(s.walkDrive), "groomDrive": Double(s.groomDrive),
                                       "wingDrive": Double(s.wingDrive), "arousal": Double(s.arousal)]
            for (k, x) in v { lo[k] = Swift.min(lo[k]!, x); hi[k] = Swift.max(hi[k]!, x) }
        }
    }
    var inside = true, reachesMax = true
    for f in ExternalIONeuralOutput.fields where !f.bodySide {
        if lo[f.name]! < f.min - 1e-6 || hi[f.name]! > f.max + 1e-6 { inside = false; print("  range \(f.name): observed \(lo[f.name]!)...\(hi[f.name]!) declared \(f.min)...\(f.max)") }
        if f.kind == .continuous, abs(hi[f.name]! - f.max) > 1e-6, f.name != "turnBias" { reachesMax = false }
    }
    check("SignalBuilder output stays inside the declared neural-output ranges", inside)
    check("declared continuous maxima are reachable (table not looser than the mapping)", reachesMax)
    check("neural-output table is not mapped to any game action", !ExternalIONeuralOutput.names.contains { ["aim", "fire", "shoot", "jump", "key"].contains($0.lowercased()) })

    // ---- lifecycle graph -------------------------------------------------------------------------
    let chain: [ExternalIOLifecycle] = [.discovered, .validated, .attached, .ready, .running, .draining, .detached]
    check("lifecycle chain discovered->...->detached is allowed", zip(chain, chain.dropFirst()).allSatisfy { $0.canTransition(to: $1) })
    check("lifecycle forbids skipping and going back",
          !ExternalIOLifecycle.discovered.canTransition(to: .running) && !ExternalIOLifecycle.running.canTransition(to: .ready)
          && !ExternalIOLifecycle.detached.canTransition(to: .discovered) && !ExternalIOLifecycle.attached.canTransition(to: .running))
    check("failed is reachable from live states and only releases to detached",
          ([.validated, .attached, .ready, .running, .draining] as [ExternalIOLifecycle]).allSatisfy { $0.canTransition(to: .failed) }
          && ExternalIOLifecycle.failed.canTransition(to: .detached) && !ExternalIOLifecycle.failed.canTransition(to: .ready)
          && !ExternalIOLifecycle.detached.canTransition(to: .failed))

    // ---- schema file matches the Swift vocabulary --------------------------------------------------
    if let sc = json(binDir.appendingPathComponent("schemas/external-io.schema.json")) as? [String: Any], let defs = sc["$defs"] as? [String: Any] {
        func enumOf(_ k: String) -> [String]? { (defs[k] as? [String: Any])?["enum"] as? [String] }
        func required(_ k: String) -> [String]? { (defs[k] as? [String: Any])?["required"] as? [String] }
        check("schema units/axes/capabilities equal the Swift vocabulary",
              enumOf("unit") == ExternalIOVocabulary.units && enumOf("axis") == ExternalIOVocabulary.axes
              && enumOf("capability") == ExternalIOVocabulary.knownCapabilities && enumOf("host_capability") == ExternalIOVocabulary.hostCapabilities
              && enumOf("frame_format") == ExternalIOFrameFormat.allCases.map { $0.rawValue })
        check("schema required keys equal the Swift required keys",
              required("module_descriptor") == ExternalIOVocabulary.descriptorRequiredKeys && required("channel_schema") == ExternalIOVocabulary.channelRequiredKeys
              && required("observation_frame") == ExternalIOVocabulary.observationRequiredKeys && required("action_frame") == ExternalIOVocabulary.actionRequiredKeys
              && ((defs["module_descriptor"] as? [String: Any])?["properties"] as? [String: Any]).flatMap { ($0["budgets"] as? [String: Any])?["required"] as? [String] } == ExternalIOVocabulary.budgetKeys)
        let props = (defs["module_descriptor"] as? [String: Any])?["properties"] as? [String: Any]
        func enumProp(_ k: String) -> [String]? { (props?[k] as? [String: Any])?["enum"] as? [String] }
        check("schema modes/clock/restore equal the Swift enums",
              enumProp("attach_mode") == ExternalIOAttachMode.allCases.map { $0.rawValue } && enumProp("clock_mode") == ExternalIOClockMode.allCases.map { $0.rawValue }
              && enumProp("restore_support") == ExternalIORestoreSupport.allCases.map { $0.rawValue })
    } else { check("schemas/external-io.schema.json present", false) }

    // ---- V8-06: fixtures and contract sources name no real game ------------------------------------
    let deny = ["overwatch", "counter-strike", "counterstrike", "valorant", "fortnite", "apex legends", "forza", "gran turismo",
                "need for speed", "mario kart", "flight simulator", "msfs", "x-plane", "xplane", "dcs world", "minecraft", "call of duty"]
    var files: [URL] = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    files.append(binDir.appendingPathComponent("schemas/external-io.schema.json"))
    for n in ["ExternalIOProtocol", "ModuleRegistry", "ExternalIOSession"] { files.append(binDir.appendingPathComponent("Sources/Bridge/\(n).swift")) }
    var scanned = 0, hits: [String] = []
    for f in files {
        guard let text = (try? String(contentsOf: f, encoding: .utf8))?.lowercased() else { continue }
        scanned += 1
        for w in deny where text.contains(w) { hits.append("\(f.lastPathComponent):\(w)") }
    }
    check("no fixture/schema/contract source names a real game", hits.isEmpty && scanned >= 7, "scanned \(scanned) \(hits)")
    check("only fixture.* descriptors are shipped", ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("descriptor-") }.count == 2)

    // ---- V8.2 host registry --------------------------------------------------------------------------
    func rcheck(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check("V8.2 " + name, ok, detail) }
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("externalio-registry-\(getpid())", isDirectory: true)
    let tmp2 = fm.temporaryDirectory.appendingPathComponent("externalio-registry2-\(getpid())", isDirectory: true)
    defer { try? fm.removeItem(at: tmp); try? fm.removeItem(at: tmp2) }
    try? fm.removeItem(at: tmp); try? fm.removeItem(at: tmp2)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    try? fm.createDirectory(at: tmp2, withIntermediateDirectories: true)
    func put(_ dir: URL, _ name: String, _ obj: Any) { try? JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent(name)) }
    func putText(_ dir: URL, _ name: String, _ text: String) { try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent(name)) }
    if let auxJSON = fixture("descriptor-auxiliary.json") as? [String: Any], let envJSON = fixture("descriptor-external-environment.json") as? [String: Any] {
        put(tmp, "a-aux.json", auxJSON)
        put(tmp, "b-env.json", envJSON)
        var dup = envJSON; dup["display_name"] = "Second copy"
        put(tmp, "c-dup.json", dup)                       // same module_id as b-env -> later rejected
        var bad = auxJSON; bad["module_id"] = "fixture.badunit"
        if var obs = bad["observations"] as? [[String: Any]], !obs.isEmpty { obs[0]["unit"] = "furlongs"; bad["observations"] = obs }
        put(tmp, "d-badunit.json", bad)
        var ver = auxJSON; ver["module_id"] = "fixture.newer"; ver["api_version"] = "external_io.v9"
        put(tmp, "e-version.json", ver)
        putText(tmp, "f-garbage.json", "{ not json")
        putText(tmp, "notes.txt", "ignored: not a descriptor file")
        // Script-like keys: data only, never interpreted.
        var scripty = auxJSON; scripty["module_id"] = "fixture.scripty"
        scripty["command"] = "/bin/sh -c 'touch \(tmp.path)/PWNED'"; scripty["script"] = "touch PWNED"
        scripty["plugin_path"] = "/nonexistent/lib.dylib"; scripty["on_attach"] = ["exec": "touch PWNED"]
        put(tmp, "g-scripty.json", scripty)
        put(tmp2, "a-override.json", envJSON)             // duplicate across directories -> later directory rejected

        let reg = ExternalIOModuleRegistry(directories: [tmp, tmp2])
        let regAgain = ExternalIOModuleRegistry(directories: [tmp, tmp2])
        rcheck("registers exactly the valid descriptors", Set(reg.modules.map { $0.descriptor.moduleID }) == ["fixture.sensor_loopback", "fixture.loopback", "fixture.scripty"],
               "\(reg.modules.map { $0.descriptor.moduleID })")
        rcheck("registered modules start at lifecycle validated", reg.modules.allSatisfy { $0.lifecycle == .validated })
        let rej = Dictionary(uniqueKeysWithValues: reg.rejected.map { ($0.file, $0) })
        rcheck("every invalid descriptor is listed as rejected with its reason",
               rej["d-badunit.json"]?.code == "unknown_unit" && rej["e-version.json"]?.code == "unsupported_api_version"
               && rej["f-garbage.json"]?.code == "wrong_type" && reg.rejected.allSatisfy { !$0.reason.isEmpty },
               "\(reg.rejected.map { "\($0.file):\($0.code)" })")
        rcheck("duplicate module_id: the later one is rejected, the first kept",
               rej["c-dup.json"]?.code == "duplicate_id" && rej["a-override.json"]?.code == "duplicate_id"
               && reg.module("fixture.loopback")?.file == "b-env.json" && reg.module("fixture.loopback")?.descriptor.displayName != "Second copy")
        rcheck("rejected entries carry the module_id when readable", rej["c-dup.json"]?.moduleID == "fixture.loopback" && rej["d-badunit.json"]?.moduleID == "fixture.badunit")
        rcheck("non-.json files are not descriptors and are ignored", rej["notes.txt"] == nil && reg.modules.count + reg.rejected.count == 8,
               "\(reg.modules.count) + \(reg.rejected.count)")
        rcheck("lookup by module_id", reg.module("fixture.sensor_loopback")?.file == "a-aux.json" && reg.module("nope") == nil)
        rcheck("script-like fields are data only: module registered, nothing executed, fields not carried",
               reg.module("fixture.scripty") != nil && !fm.fileExists(atPath: tmp.appendingPathComponent("PWNED").path)
               && reg.module("fixture.scripty").map { m in ["command", "script", "plugin_path", "on_attach"].allSatisfy { m.descriptor.jsonObject[$0] == nil } } == true)
        reg.reload()
        rcheck("reload is idempotent", reg.modules.count == 3 && reg.rejected.count == 5)

        // Oversize and symlink files are refused, not read.
        putText(tmp2, "z-big.json", String(repeating: " ", count: ExternalIOModuleRegistry.maximumDescriptorBytes + 1))
        try? fm.createSymbolicLink(at: tmp2.appendingPathComponent("y-link.json"), withDestinationURL: tmp.appendingPathComponent("a-aux.json"))
        let reg2 = ExternalIOModuleRegistry(directories: [tmp2])
        let rej2 = Dictionary(uniqueKeysWithValues: reg2.rejected.map { ($0.file, $0.code) })
        rcheck("oversize and symlinked descriptors are rejected unread", rej2["z-big.json"] == "file_too_large" && rej2["y-link.json"] == "not_a_regular_file", "\(rej2)")

        // Pure view model generated from the descriptor.
        let model = ExternalIOModuleListModel(reg)
        if let env = model.modules.first(where: { $0.moduleID == "fixture.loopback" }) {
            let move = env.channels.first { $0.name == "move" }, heading = env.channels.first { $0.name == "heading?" }
            rcheck("view model: module row from descriptor", env.lifecycle == "validated" && env.attachMode == "external_environment" && env.clockMode == "lockstep" && env.version == "1.0.0")
            rcheck("view model: per-channel rows with direction, unit, axis, range, rate",
                   env.channels.count == 4 && move == ExternalIOChannelRow(name: "move", direction: "out", kind: "continuous", unit: "normalized", axis: "forward", range: "-1...1 x2", rate: "30 Hz")
                   && heading?.direction == "in" && heading?.unit == "deg" && heading?.axis == "yaw" && heading?.range == "-180...180"
                   && env.channels.first { $0.name == "mode_switch" }?.range == "idle|go|stop")
        } else { rcheck("view model contains fixture.loopback", false) }
        rcheck("view model: rejected descriptors with reasons", model.rejected == reg.rejected && model.modules.count == 3)
        let text = ExternalModulesText.lines(model)
        rcheck("panel text lists modules, channels and rejections", text.contains("fixture.loopback") && text.contains("mode_switch") && text.contains("d-badunit.json") && text.contains("unknown_unit"))
        rcheck("registry output is deterministic", ExternalIOModuleListModel(regAgain) == model)
    } else { rcheck("fixtures available for registry tests", false) }
    let missing = fm.temporaryDirectory.appendingPathComponent("externalio-missing-\(getpid())")
    let none = ExternalIOModuleRegistry(directories: [missing])
    rcheck("no module directory: empty registry, no rejections, directory not created",
           none.modules.isEmpty && none.rejected.isEmpty && !fm.fileExists(atPath: missing.path)
           && ExternalModulesText.lines(ExternalIOModuleListModel(none)).isEmpty == false)
    rcheck("default directory is under Application Support and the registry never writes", ExternalIOModuleRegistry.defaultDirectory.path.hasSuffix("Library/Application Support/ThongpariFlyNeuronSim/modules"))
    if let src = try? String(contentsOf: binDir.appendingPathComponent("Sources/Bridge/ModuleRegistry.swift"), encoding: .utf8) {
        let banned = ["dlopen", "Process(", "NSTask", "Bundle(", "NSAppleScript", "JavaScriptCore", "system(", "posix_spawn"]
        // Comments describe the boundary; scan code lines only.
        let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        rcheck("registry source contains no code-execution APIs", banned.allSatisfy { !code.contains($0) })
    }

    // ---- V8.3 output ownership ---------------------------------------------------------------------
    func scheck(_ name: String, _ ok: Bool, _ detail: String = "") { suite.check("V8.3 " + name, ok, detail) }
    let tmp3 = fm.temporaryDirectory.appendingPathComponent("externalio-session-\(getpid())")
    try? fm.removeItem(at: tmp3)
    try? fm.createDirectory(at: tmp3, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp3) }
    if let auxJSON = fixture("descriptor-auxiliary.json") as? [String: Any], let envJSON = fixture("descriptor-external-environment.json") as? [String: Any] {
        put(tmp3, "a-aux.json", auxJSON)
        put(tmp3, "b-env.json", envJSON)
        var env2 = envJSON; env2["module_id"] = "fixture.loopback2"
        put(tmp3, "c-env2.json", env2)
        let A = "fixture.sensor_loopback", E = "fixture.loopback", E2 = "fixture.loopback2"
        func fresh() -> ExternalIOSession { ExternalIOSession(registry: ExternalIOModuleRegistry(directories: [tmp3])) }
        func code(_ op: () throws -> Void) -> String? {
            do { try op(); return nil } catch let e as ExternalIOSessionError { return e.code.rawValue } catch { return "other" }
        }
        let s0 = fresh()
        scheck("initial: default world owns output, all modules validated",
               s0.owner == .defaultWorld && s0.defaultWorldWritesOutput && s0.failure == nil && [A, E, E2].allSatisfy { s0.lifecycle($0) == .validated })

        // illegal transitions are rejected and leave state unchanged
        let before = [A, E, E2].map { s0.lifecycle($0) }
        scheck("illegal transitions rejected, state unchanged",
               code({ try s0.transition(E, to: .running) }) == "illegal_transition" && code({ try s0.transition(E, to: .ready) }) == "illegal_transition"
               && code({ try s0.acquireOutput(E) }) == "not_attached" && code({ try s0.attach("nope") }) == "unknown_module"
               && [A, E, E2].map({ s0.lifecycle($0) }) == before && s0.owner == .defaultWorld)
        scheck("attach twice is illegal", { let s = fresh(); try? s.attach(E); return code({ try s.attach(E) }) == "illegal_transition" && s.lifecycle(E) == .attached }())

        // auxiliary can never own output, in any ordering
        let s1 = fresh()
        scheck("auxiliary attach ok but taking output is refused (mode_violation), owner unchanged",
               code({ try s1.attach(A) }) == nil && code({ try s1.acquireOutput(A) }) == "mode_violation"
               && code({ try s1.switchOutput(from: E, to: A) }) == "mode_violation" && s1.owner == .defaultWorld && s1.defaultWorldWritesOutput)
        scheck("auxiliary cannot be released/owned later either", { try? s1.attach(E); try? s1.acquireOutput(E)
            return code({ try s1.acquireOutput(A) }) == "mode_violation" && s1.owner == .module(E) }())

        // second controller refused
        let s2 = fresh()
        try? s2.attach(E); try? s2.attach(E2); try? s2.attach(A)
        scheck("first external_environment takes output; default world stops writing", code({ try s2.acquireOutput(E) }) == nil && s2.owner == .module(E) && !s2.defaultWorldWritesOutput)
        scheck("second controller refused with a reason, owner unchanged", code({ try s2.acquireOutput(E2) }) == "output_owned" && code({ try s2.acquireOutput(E) }) == "output_owned" && s2.owner == .module(E))
        scheck("non-owner cannot release", code({ try s2.releaseOutput(E2) }) == "not_owner" && s2.owner == .module(E))
        scheck("owner cannot be detached/failed through plain transition", code({ try s2.transition(E, to: .detached) }) == "not_owner" && code({ try s2.transition(E, to: .failed) }) == "not_owner")

        // explicit switch = release old then acquire new
        var released: [String] = []
        s2.releaseHandler = { released.append($0); return true }
        scheck("explicit switch: release old -> acquire new", code({ try s2.switchOutput(from: E, to: E2) }) == nil && s2.owner == .module(E2) && released == [E])
        scheck("switch from a non-owner is refused, nothing released", { released = []
            return code({ try s2.switchOutput(from: E, to: E2) }) == "not_owner" && released.isEmpty && s2.owner == .module(E2) }())

        // failed release: session failed, owner NOT reassigned
        let s3 = fresh()
        try? s3.attach(E); try? s3.attach(E2); try? s3.acquireOutput(E)
        s3.releaseHandler = { _ in false }
        scheck("failed release in switch: module+session failed, owner not reassigned",
               code({ try s3.switchOutput(from: E, to: E2) }) == "release_failed" && s3.owner == .module(E) && s3.lifecycle(E) == .failed
               && s3.failure != nil && !s3.defaultWorldWritesOutput && s3.lifecycle(E2) == .attached)
        scheck("while failed no one can take output", code({ try s3.acquireOutput(E2) }) == "session_failed" && s3.owner == .module(E))
        scheck("failed state is not silently left: only explicit acknowledge returns the body",
               code({ try s3.detach(E) }) == "illegal_transition" && s3.owner == .module(E) && code({ try s3.acknowledgeFailure(E) }) == nil
               && s3.owner == .defaultWorld && s3.failure == nil && s3.lifecycle(E) == .detached)
        let s4 = fresh()
        try? s4.attach(E); try? s4.acquireOutput(E); s4.releaseHandler = { _ in false }
        scheck("failed release in detach: failed, owner kept, not detached",
               code({ try s4.detach(E) }) == "release_failed" && s4.lifecycle(E) == .failed && s4.owner == .module(E) && s4.failure != nil)
        let s5 = fresh()
        try? s5.attach(E); try? s5.transition(E, to: .ready); try? s5.acquireOutput(E)
        scheck("clean detach returns body to the default world", code({ try s5.detach(E) }) == nil && s5.owner == .defaultWorld && s5.lifecycle(E) == .detached && s5.defaultWorldWritesOutput)
        scheck("detached is terminal", code({ try s5.attach(E) }) == "illegal_transition" && code({ try s5.acquireOutput(E) }) == "not_attached")

        // every ordering of three controllers: never two owners
        var ok = true, orderings = 0
        let ids = [A, E, E2]
        func perms(_ a: [String]) -> [[String]] { a.count <= 1 ? [a] : a.indices.flatMap { i in perms(Array(a[..<i] + a[(i + 1)...])).map { [a[i]] + $0 } } }
        for order in perms(ids) {
            for preAttach in [true, false] {
                let s = fresh()
                if preAttach { for id in ids { try? s.attach(id) } }
                var winners: [String] = []
                for id in order {
                    if !preAttach { try? s.attach(id) }
                    if (try? s.acquireOutput(id)) != nil { winners.append(id) }
                }
                orderings += 1
                if winners.count != 1 || winners[0] == A || s.owner != .module(winners[0]) { ok = false }
            }
        }
        scheck("every ordering (\(orderings)): exactly one winner, never the auxiliary", ok && orderings == 12)

        // concurrent requests from two threads
        var concurrentOK = true
        for _ in 0..<200 {
            let s = fresh(); try? s.attach(E); try? s.attach(E2)
            var results = [Bool](repeating: false, count: 2)
            let g = DispatchGroup(); let rl = NSLock()
            for (i, id) in [E, E2].enumerated() {
                g.enter()
                DispatchQueue.global().async { let r = (try? s.acquireOutput(id)) != nil; rl.lock(); results[i] = r; rl.unlock(); g.leave() }
            }
            g.wait()
            if results.filter({ $0 }).count != 1 || s.owner != .module(results[0] ? E : E2) { concurrentOK = false; break }
        }
        scheck("two threads racing for output: exactly one wins (200 rounds)", concurrentOK)

        // auxiliary declared channels only
        let s6 = fresh(); try? s6.attach(A); try? s6.attach(E)
        let auxObs = s6.registry.module(A)?.descriptor.observations.map { $0.channelID } ?? []
        let allowedA = s6.allowedChannels(A)
        scheck("auxiliary: only its declared observation channels, never actions",
               !auxObs.isEmpty && allowedA.observations == auxObs && allowedA.actions.isEmpty
               && s6.permits(A, channel: auxObs[0], output: false) && !s6.permits(A, channel: auxObs[0], output: true)
               && !s6.permits(A, channel: "move", output: false) && !s6.permits(A, channel: "move", output: true))
        let moveAllowedBefore = s6.permits(E, channel: "move", output: true)
        try? s6.acquireOutput(E)
        scheck("external_environment: actions only once it owns output; undeclared channels never",
               !moveAllowedBefore && s6.permits(E, channel: "move", output: true) && !s6.permits(E, channel: "fire", output: true)
               && !s6.permits(E2, channel: "move", output: true) && s0.allowedChannels(E).actions.isEmpty && s0.allowedChannels(E).observations.isEmpty)

        // rescan refused while active
        scheck("rescan refused while a module is attached, allowed when idle", code({ try s6.rescan() }) == "modules_active" && code({ try s0.rescan() }) == nil)

        // view model
        let vm = ExternalIOModuleListModel(s6.registry, session: s6)
        scheck("view model shows owner, lifecycle and allowed channels",
               vm.outputOwner == E && vm.modules.first { $0.moduleID == E }?.ownsOutput == true
               && vm.modules.first { $0.moduleID == A }?.allowedActions.isEmpty == true && vm.modules.first { $0.moduleID == A }?.lifecycle == "attached"
               && ExternalModulesText.lines(vm).contains("output owner"))

        // no module attached: identical output vs a run without the session
        func packets(_ gate: ExternalIOSession?) -> [Data] {
            var rng = SystemRandomNumberGenerator.withSeed(7)
            var out: [Data] = []
            let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys   // unsorted key order is not byte-stable
            for i in 0..<500 {
                var sig = BrainSignals()
                sig.walkDrive = CGFloat(rng.nextUnit()) * 1.3; sig.turnBias = CGFloat(rng.nextUnit() * 2 - 1)
                sig.escape = i % 97 == 0; sig.backward = i % 13 == 0; sig.groomDrive = CGFloat(rng.nextUnit())
                if let g = gate, !g.defaultWorldWritesOutput { continue }       // the hook, as in Coordinator
                if let d = try? enc.encode(FlyGymBrainPacket(signals: sig, simMs: i)) { out.append(d) }
            }
            return out
        }
        let baseline = packets(nil), idle = fresh()
        scheck("no module attached: default-world output byte-identical to a run without the session", baseline.count == 500 && packets(idle) == baseline)
        try? idle.attach(A)
        scheck("auxiliary attached: default-world output still byte-identical", packets(idle) == baseline)
        try? idle.attach(E); try? idle.acquireOutput(E)
        scheck("external owner: default world writes nothing", packets(idle).isEmpty)
        try? idle.releaseOutput(E)
        scheck("after release: default-world output identical again", packets(idle) == baseline)
        if let src = try? String(contentsOf: binDir.appendingPathComponent("Sources/App/Coordinator.swift"), encoding: .utf8) {
            scheck("Coordinator gates both the FlyGym send and the local drive on the session", src.components(separatedBy: "externalIO.defaultWorldWritesOutput").count == 3)
        }
        // The local body under an external owner: no brain and no legacy autopilot may move it.
        // Control: the same fly given nil signals (the legacy path) flees a mouse at its feet.
        let held = Fly(at: CGPoint(x: 400, y: 300)), free = Fly(at: CGPoint(x: 400, y: 300))
        let mouse = CGPoint(x: 402, y: 300), area = CGSize(width: 800, height: 600)
        for _ in 0..<300 {
            held.hold(dt: 1.0 / 60)
            free.update(dt: 1.0 / 60, bounds: area, mouse: mouse, signals: nil)
        }
        scheck("external owner: the held local fly stays put and idle while the legacy path would have moved it",
               held.pos == CGPoint(x: 400, y: 300) && held.state == .idle && free.pos != CGPoint(x: 400, y: 300))
        if let src = try? String(contentsOf: binDir.appendingPathComponent("Sources/Bridge/ExternalIOSession.swift"), encoding: .utf8) {
            let banned = ["dlopen", "Process(", "NSTask", "socket(", "URLSession", "NWConnection", "posix_spawn", "system("]
            let codeOnly = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            scheck("session source opens no sockets and runs no code", banned.allSatisfy { !codeOnly.contains($0) })
        }
    } else { scheck("fixtures available for session tests", false) }

    print(suite.failures == 0 ? "ALL EXTERNAL IO TESTS PASS" : "\(suite.failures) EXTERNAL IO TEST FAILURES")
    suite.finish()
}
#endif
