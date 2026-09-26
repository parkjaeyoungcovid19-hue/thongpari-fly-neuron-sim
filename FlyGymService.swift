// FlyGymService.swift — the app-owned FlyGym backend process for the one-window Lab.
//
// The packaged app and `--lab` start their own Python bridge on a private
// loopback port, so they never touch a listener someone else owns (17841 stays
// the external/diagnostic port). The child watches THONGPARI_PARENT_PID and
// exits on its own if this app dies without running applicationWillTerminate.

import Foundation

enum FlyGymServiceMode: String {
    case headless   // real FlyGym/MuJoCo, no viewer window (default)
    case viewer     // real FlyGym plus MuJoCo's own viewer window (development only)
    case mock       // kinematic mock body, no MuJoCo

    var bridgeArgument: String {
        switch self {
        case .headless: return "--flygym-headless"
        case .viewer: return "--flygym"
        case .mock: return "--mock"
        }
    }
}

enum FlyGymServiceState: Equatable {
    case unavailable(String)
    case starting
    case running
    case exited(Int32)

    var summary: String {
        switch self {
        case .unavailable(let reason): return "backend unavailable — \(reason)"
        case .starting: return "backend starting"
        case .running: return "backend running"
        case .exited(let status): return "backend exited (status \(status))"
        }
    }
}

final class FlyGymService {
    let mode: FlyGymServiceMode
    let port: UInt16
    /// Private loopback port on which a headless real backend streams MuJoCo's
    /// own rendering of the scene into the Lab canvas; 0 when not streamed.
    let renderPort: UInt16
    private let root: URL?
    private let lock = NSLock()
    private var process: Process?
    private var _state: FlyGymServiceState
    private var stopping = false
    private var _startedAt: Date?
    private var _lastOutputLine = ""
    private var outputTail = Data()
    private var logHandle: FileHandle?

    /// Bridge stdout/stderr, appended per launch.
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Thongpari Virtual Fly Lab/bridge.log")

    var state: FlyGymServiceState { lock.lock(); defer { lock.unlock() }; return _state }
    var startedAt: Date? { lock.lock(); defer { lock.unlock() }; return _startedAt }
    var lastOutputLine: String { lock.lock(); defer { lock.unlock() }; return _lastOutputLine }
    /// Set when the Python runtime has been evicted to iCloud (Optimize Mac
    /// Storage): every import then downloads on demand and startup takes minutes.
    private(set) lazy var runtimeIsCloudEvicted: Bool = root.map(FlyGymService.hasCloudEvictedRuntime) ?? false
    var canRestart: Bool {
        if case .exited = state { return root != nil && port != 0 }
        return false
    }

    init(mode: FlyGymServiceMode, root: URL? = FlyGymService.locateProjectRoot()) {
        self.mode = mode
        self.root = root
        self.port = FlyGymService.freeLoopbackPort() ?? 0
        self.renderPort = mode == .headless ? (FlyGymService.freeLoopbackPort(excluding: port) ?? 0) : 0
        if root == nil {
            _state = .unavailable("no flygym_bridge/ + flygym-venv/ next to the app")
        } else if port == 0 {
            _state = .unavailable("no free loopback port")
        } else {
            _state = .starting
        }
    }

    /// Checkout that holds `flygym_bridge/bridge.py` and `flygym-venv/`: the
    /// packaged app records it in Info.plist; a CLI build sits in the checkout.
    static func locateProjectRoot() -> URL? {
        var candidates: [URL] = []
        if let recorded = Bundle.main.infoDictionary?["ThongpariProjectRoot"] as? String {
            candidates.append(URL(fileURLWithPath: recorded))
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent())
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return candidates.first { root in
            ["flygym_bridge/bridge.py", "flygym-venv/bin/python"].allSatisfy {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
            }
        }
    }

    static func hasCloudEvictedRuntime(root: URL) -> Bool {
        let probes = ["numpy/__init__.py", "scipy/__init__.py", "mujoco/__init__.py", "flygym/__init__.py"]
        let siteDirs = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("flygym-venv/lib"), includingPropertiesForKeys: nil)) ?? []
        for lib in siteDirs {
            for probe in probes {
                var info = stat()
                let path = lib.appendingPathComponent("site-packages/\(probe)").path
                if lstat(path, &info) == 0, info.st_flags & 0x4000_0000 != 0 { return true }   // SF_DATALESS
            }
        }
        return false
    }

    static func freeLoopbackPort(excluding taken: UInt16? = nil) -> UInt16? {
        for _ in 0..<8 {
            guard let candidate = anyFreeLoopbackPort() else { return nil }
            if candidate != taken { return candidate }
        }
        return nil
    }

    private static func anyFreeLoopbackPort() -> UInt16? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && Darwin.getsockname(fd, $0, &length) == 0
            }
        }
        return ok ? UInt16(bigEndian: address.sin_port) : nil
    }

    func start() {
        guard let root, port != 0 else { return }
        lock.lock()
        guard process?.isRunning != true else { lock.unlock(); return }
        stopping = false
        _state = .starting
        lock.unlock()

        let python = root.appendingPathComponent("flygym-venv/bin/python")
        let bridgeScript = root.appendingPathComponent("flygym_bridge/bridge.py").path
        let p = Process()
        p.executableURL = python
        // mjpython is a Python script; the venv path may contain spaces, so run
        // the trampoline through the interpreter instead of its shebang.
        p.arguments = mode == .mock
            ? [bridgeScript, mode.bridgeArgument]
            : [root.appendingPathComponent("flygym-venv/bin/mjpython").path, bridgeScript, mode.bridgeArgument]
        p.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["THONGPARI_BRIDGE_PORT"] = String(port)
        if renderPort != 0 { environment["THONGPARI_RENDER_PORT"] = String(renderPort) }
        environment["THONGPARI_PARENT_PID"] = String(getpid())
        environment["PYTHONUNBUFFERED"] = "1"
        p.environment = environment
        let output = Pipe()
        p.standardOutput = output
        p.standardError = output
        try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: Self.logURL)
        _ = try? log?.seekToEnd()
        log?.write(Data("\n--- \(Date()) \(mode.rawValue) bridge on port \(port) ---\n".utf8))
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }   // EOF
            guard let self else { return }
            FileHandle.standardError.write(chunk)
            self.lock.lock()
            self.logHandle?.write(chunk)
            self.outputTail.append(chunk)
            if self.outputTail.count > 4096 { self.outputTail.removeFirst(self.outputTail.count - 4096) }
            let lines = String(decoding: self.outputTail, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init)
            if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                self._lastOutputLine = last
            }
            self.lock.unlock()
        }
        p.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            if self.process === finished { self._state = .exited(finished.terminationStatus) }
            let expected = self.stopping
            self.lock.unlock()
            if !expected {
                fputs("flygym service: bridge exited (\(finished.terminationStatus)) on port \(self.port)\n", stderr)
            }
        }
        do {
            try p.run()
            lock.lock()
            process = p; _state = .running; _startedAt = Date()
            _lastOutputLine = ""; outputTail.removeAll(); logHandle = log
            lock.unlock()
            fputs("flygym service: \(mode.rawValue) bridge pid \(p.processIdentifier) on 127.0.0.1:\(port)\n", stderr)
        } catch {
            lock.lock(); _state = .unavailable("could not launch bridge: \(error.localizedDescription)"); lock.unlock()
        }
    }

    func restart() {
        stop()
        start()
    }

    /// SIGTERM, then SIGKILL after `grace` seconds; returns once the child is gone.
    func stop(grace: TimeInterval = 3) {
        lock.lock()
        let p = process
        stopping = true
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
    }
}
