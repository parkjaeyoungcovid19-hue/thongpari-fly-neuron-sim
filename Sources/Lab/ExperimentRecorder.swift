// ExperimentRecorder.swift — asynchronous CSV recorder for compact lab telemetry.

import Foundation

enum ExperimentRecorderState: String {
    case idle, recording, stopping, saved, failed
}

enum ExperimentRecorderStopOutcome {
    case saved(path: String)
    case failed(path: String?, message: String)
    case notRecording(path: String?)

    var succeeded: Bool {
        if case .saved = self { return true }
        return false
    }

    var path: String? {
        switch self {
        case .saved(let path): return path
        case .failed(let path, _), .notRecording(let path): return path
        }
    }

    var message: String {
        switch self {
        case .saved(let path): return "saved: \(path)"
        case .failed(_, let message): return message
        case .notRecording: return "not recording"
        }
    }
}

private enum ExperimentRecorderTestError: LocalizedError {
    case forcedWriteFailure
    var errorDescription: String? { "forced recorder write failure (test)" }
}

final class ExperimentRecorder {
    private let queue = DispatchQueue(label: "thongpari.lab.recorder", qos: .utility)
    private let lock = NSLock()
    private let baseDirectory: URL?
    private let forceWriteFailureForTesting: Bool
    private var telemetryHandle: FileHandle?
    private var eventsHandle: FileHandle?
    private var _path: String?
    private var _state: ExperimentRecorderState = .idle
    private var _lastErrorMessage: String?
    private var stopCompletions: [(ExperimentRecorderStopOutcome) -> Void] = []

    var state: ExperimentRecorderState { lock.lock(); defer { lock.unlock() }; return _state }
    var isRecording: Bool { state == .recording }
    var isStopping: Bool { state == .stopping }
    var path: String? { lock.lock(); defer { lock.unlock() }; return _path }
    var lastErrorMessage: String? { lock.lock(); defer { lock.unlock() }; return _lastErrorMessage }

    init(baseDirectory: URL? = nil, forceWriteFailureForTesting: Bool = false) {
        self.baseDirectory = baseDirectory
        self.forceWriteFailureForTesting = forceWriteFailureForTesting
    }

    private func setError(_ context: String, _ error: Error) {
        let message = "\(context): \(error.localizedDescription)"
        lock.lock()
        if _lastErrorMessage == nil { _lastErrorMessage = message }
        lock.unlock()
        fputs("lab recorder \(message)\n", stderr)
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        if forceWriteFailureForTesting { throw ExperimentRecorderTestError.forcedWriteFailure }
        try handle.write(contentsOf: data)
    }

    @discardableResult
    func start(metadata extraMetadata: [String: Any] = [:]) -> String? {
        lock.lock()
        if _state == .recording { let p = _path; lock.unlock(); return p }
        if _state == .stopping { lock.unlock(); return nil }
        lock.unlock()

        let fm = FileManager.default
        let base = baseDirectory ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("ThongpariFlyNeuronSimExperiments", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stem = "experiment-\(formatter.string(from: Date()))"
            var dir = base.appendingPathComponent(stem, isDirectory: true)
            var suffix = 2
            while fm.fileExists(atPath: dir.path) {
                dir = base.appendingPathComponent("\(stem)-\(suffix)", isDirectory: true)
                suffix += 1
            }
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            let telemetryURL = dir.appendingPathComponent("telemetry.csv")
            let eventsURL = dir.appendingPathComponent("events.jsonl")
            let metadataURL = dir.appendingPathComponent("metadata.json")
            guard fm.createFile(atPath: telemetryURL.path, contents: Data(LabTelemetry.csvHeader.utf8)),
                  fm.createFile(atPath: eventsURL.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var meta: [String: Any] = [
                "format": "Thongpari Fly Neuron Sim Virtual Fly Lab V4",
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "telemetry": "telemetry.csv",
                "events": "events.jsonl"
            ]
            for (key, value) in extraMetadata { meta[key] = value }
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try metaData.write(to: metadataURL, options: .atomic)
            let tfh = try FileHandle(forWritingTo: telemetryURL)
            let efh = try FileHandle(forWritingTo: eventsURL)
            try tfh.seekToEnd(); try efh.seekToEnd()
            lock.lock()
            telemetryHandle = tfh; eventsHandle = efh; _path = dir.path
            _lastErrorMessage = nil; _state = .recording
            lock.unlock()
            mark(kind: "recording_started", detail: "Virtual Fly Lab V4")
            return dir.path
        } catch {
            lock.lock()
            _state = .failed
            _lastErrorMessage = "start: \(error.localizedDescription)"
            lock.unlock()
            fputs("lab recorder: \(error)\n", stderr)
            return nil
        }
    }

    func append(_ sample: LabTelemetry) {
        let data = Data(sample.csvLine.utf8)
        lock.lock()
        let active = _state == .recording
        let fh = telemetryHandle
        if active, let fh {
            // Enqueue while holding the lifecycle lock. Therefore any stop() that
            // transitions to `stopping` can only enqueue its finalizer after this
            // accepted write is already ahead of it on the serial writer queue.
            queue.async { [self] in
                do { try write(data, to: fh) }
                catch { setError("telemetry write", error) }
            }
        }
        lock.unlock()
    }

    func mark(kind: String, detail: String, commandID: Int? = nil,
              sessionID: String? = nil, epoch: Int? = nil, simTick: Int? = nil,
              requestedTick: Int? = nil, appliedTick: Int? = nil,
              appliedEpoch: Int? = nil, status: String? = nil) {
        var obj: [String: Any] = [
            "wall_time": Date().timeIntervalSince1970,
            "kind": kind,
            "detail": detail
        ]
        if let commandID { obj["command_id"] = commandID }
        if let sessionID { obj["session_id"] = sessionID }
        if let epoch { obj["epoch"] = epoch }
        if let simTick { obj["sim_tick"] = simTick }
        if let requestedTick { obj["requested_tick"] = requestedTick }
        if let appliedTick { obj["applied_tick"] = appliedTick }
        if let appliedEpoch { obj["applied_epoch"] = appliedEpoch }
        if let status { obj["status"] = status }
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock()
        let active = _state == .recording
        let fh = eventsHandle
        if active, let fh {
            queue.async { [self] in
                do { try write(data, to: fh) }
                catch { setError("event write", error) }
            }
        }
        lock.unlock()
    }

    /// Stop accepting new writes immediately, then drain all already queued data,
    /// write the terminal event, flush and close before reporting saved/failed.
    /// Multiple callers can wait on the same in-flight stop operation.
    func stop(reason: String = "user stop", completion: ((ExperimentRecorderStopOutcome) -> Void)? = nil) {
        var shouldFinalize = false
        var immediate: ExperimentRecorderStopOutcome?

        lock.lock()
        switch _state {
        case .recording:
            _state = .stopping
            if let completion { stopCompletions.append(completion) }
            shouldFinalize = true
        case .stopping:
            if let completion { stopCompletions.append(completion) }
        case .saved:
            immediate = _path.map { .saved(path: $0) } ?? .notRecording(path: nil)
        case .failed:
            immediate = .failed(path: _path, message: _lastErrorMessage ?? "recording failed")
        case .idle:
            immediate = .notRecording(path: _path)
        }
        lock.unlock()

        if let completion, let immediate {
            queue.async { completion(immediate) }
        }
        guard shouldFinalize else { return }

        queue.async { [self] in
            let tfh: FileHandle?
            let efh: FileHandle?
            lock.lock()
            tfh = telemetryHandle
            efh = eventsHandle
            lock.unlock()

            let stopObj: [String: Any] = [
                "wall_time": Date().timeIntervalSince1970,
                "kind": "recording_stopped",
                "detail": reason
            ]
            if var stopData = try? JSONSerialization.data(withJSONObject: stopObj, options: [.sortedKeys]) {
                stopData.append(0x0A)
                if let efh {
                    do { try write(stopData, to: efh) }
                    catch { setError("final event write", error) }
                }
            }

            if let tfh {
                do { try tfh.synchronize(); try tfh.close() }
                catch { setError("telemetry close", error) }
            }
            if let efh {
                do { try efh.synchronize(); try efh.close() }
                catch { setError("event close", error) }
            }

            lock.lock()
            telemetryHandle = nil
            eventsHandle = nil
            let path = _path
            let err = _lastErrorMessage
            let outcome: ExperimentRecorderStopOutcome
            if let err {
                _state = .failed
                outcome = .failed(path: path, message: err)
            } else if let path {
                _state = .saved
                outcome = .saved(path: path)
            } else {
                _state = .failed
                _lastErrorMessage = "recording path missing at stop"
                outcome = .failed(path: nil, message: "recording path missing at stop")
            }
            let completions = stopCompletions
            stopCompletions.removeAll()
            lock.unlock()

            for completion in completions { completion(outcome) }
        }
    }

    /// Wait until all queued writes/close operations finish. Used only by the
    /// built-in Lab self-test; normal UI recording remains fully asynchronous.
    func flushForTesting() { queue.sync {} }

    deinit {
        // Normal app shutdown uses stop(completion:). This is only a final safety
        // net for an otherwise-unreferenced recorder.
        try? telemetryHandle?.close()
        try? eventsHandle?.close()
    }
}
