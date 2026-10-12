// ExternalIOSession.swift — V8.3 output-ownership boundary for external I/O modules.
//
// Policy (plan §4 Lifecycle, §6):
//   * The fly body has exactly ONE output target: the default world (FlyGym/local)
//     OR one `external_environment` module. `owner` is the single source of truth.
//   * `auxiliary` modules may only connect the observation channels their
//     descriptor declares; they can never own body output (mode_violation).
//   * A second controller asking for a body that is already owned is refused
//     (`output_owned`) and nothing changes. Switching owner is explicit:
//     release old -> acquire new (`switchOutput`). Release goes through
//     `releaseHandler` (the peer's ACK in a later step); a release that is not
//     ACKed marks the old module `failed`, latches the session failure and does
//     NOT reassign the owner — release success is never assumed (plan §6).
//     Only `acknowledgeFailure` (explicit operator action) returns the body to
//     the default world.
//   * Lifecycle changes go through `ExternalIOLifecycle.canTransition`; an
//     illegal transition returns an error and leaves the state unchanged.
//   * Nothing here opens a socket or runs code. With no module attached the
//     owner is `.defaultWorld` and `defaultWorldWritesOutput` is true, so the
//     existing FlyGym/local drive path is untouched.
// All methods are thread-safe (one lock); the render thread only reads
// `defaultWorldWritesOutput`.
import Foundation

struct ExternalIOSessionError: Error, Equatable, CustomStringConvertible {
    enum Code: String {
        case unknownModule = "unknown_module", illegalTransition = "illegal_transition", outputOwned = "output_owned"
        case modeViolation = "mode_violation", notAttached = "not_attached", sessionFailed = "session_failed"
        case releaseFailed = "release_failed", notOwner = "not_owner", busy = "modules_active"
    }
    let code: Code
    let detail: String
    var description: String { "\(code.rawValue): \(detail)" }
}

enum ExternalIOOutputOwner: Equatable {
    case defaultWorld
    case module(String)
    var label: String { if case .module(let id) = self { return id }; return "default_world" }
}

final class ExternalIOSession {
    let registry: ExternalIOModuleRegistry
    /// Asks the peer to release body output; true = ACKed. The fixture loopback has no peer, so
    /// the default ACKs. Tests/later steps inject the real result.
    var releaseHandler: (String) -> Bool = { _ in true }

    private let lock = NSLock()
    private var states: [String: ExternalIOLifecycle] = [:]
    private var _owner = ExternalIOOutputOwner.defaultWorld
    private var _failure: String?

    init(registry: ExternalIOModuleRegistry) { self.registry = registry }

    var owner: ExternalIOOutputOwner { lock.lock(); defer { lock.unlock() }; return _owner }
    /// Latched failure text (failed release); nil when healthy.
    var failure: String? { lock.lock(); defer { lock.unlock() }; return _failure }
    /// Hot-path check for the body-output producer: true unless an external module owns output.
    var defaultWorldWritesOutput: Bool { lock.lock(); defer { lock.unlock() }; return _owner == .defaultWorld }

    func lifecycle(_ id: String) -> ExternalIOLifecycle? { lock.lock(); defer { lock.unlock() }; return stateLocked(id) }

    private func stateLocked(_ id: String) -> ExternalIOLifecycle? {
        guard let m = registry.module(id) else { return nil }
        return states[id] ?? m.lifecycle
    }

    private func err(_ c: ExternalIOSessionError.Code, _ d: String) -> ExternalIOSessionError { ExternalIOSessionError(code: c, detail: d) }

    private func moveLocked(_ id: String, to next: ExternalIOLifecycle) throws {
        guard let cur = stateLocked(id) else { throw err(.unknownModule, id) }
        guard cur.canTransition(to: next) else { throw err(.illegalTransition, "\(id): \(cur.rawValue) -> \(next.rawValue)") }
        states[id] = next
    }

    /// Validated lifecycle step (e.g. attached -> ready -> running). Ownership changes use the dedicated calls.
    func transition(_ id: String, to next: ExternalIOLifecycle) throws {
        lock.lock(); defer { lock.unlock() }
        if next == .detached || next == .failed, case .module(id) = _owner {
            throw err(.notOwner, "\(id) owns body output; use detach(_:) or acknowledgeFailure(_:)")
        }
        try moveLocked(id, to: next)
    }

    /// validated -> attached. Both modes attach; only external_environment may later own output.
    func attach(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try moveLocked(id, to: .attached)
    }

    /// Take body output for an external_environment module that is attached/ready/running.
    func acquireOutput(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try acquireLocked(id)
    }

    private func acquireLocked(_ id: String) throws {
        guard let m = registry.module(id), let st = stateLocked(id) else { throw err(.unknownModule, id) }
        if let f = _failure { throw err(.sessionFailed, f) }
        guard m.descriptor.attachMode == .externalEnvironment else {
            throw err(.modeViolation, "\(id) is auxiliary and may not own body output")
        }
        guard [.attached, .ready, .running].contains(st) else { throw err(.notAttached, "\(id) is \(st.rawValue)") }
        guard _owner == .defaultWorld else {
            throw err(.outputOwned, "body output is owned by \(_owner.label)")
        }
        _owner = .module(id)
    }

    /// Hand output back to the default world after the owner's release is ACKed.
    func releaseOutput(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try releaseLocked(id)
    }

    private func releaseLocked(_ id: String) throws {
        guard _owner == .module(id) else { throw err(.notOwner, "\(id) does not own body output") }
        guard releaseHandler(id) else {
            states[id] = .failed
            _failure = "release of \(id) was not acknowledged"
            throw err(.releaseFailed, _failure!)
        }
        _owner = .defaultWorld
    }

    /// Explicit owner switch: release the current module, then acquire the new one.
    /// If the release fails nothing is reassigned and the session stays failed.
    func switchOutput(from old: String, to new: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let m = registry.module(new), let st = stateLocked(new) else { throw err(.unknownModule, new) }
        guard m.descriptor.attachMode == .externalEnvironment else { throw err(.modeViolation, "\(new) is auxiliary and may not own body output") }
        guard [.attached, .ready, .running].contains(st) else { throw err(.notAttached, "\(new) is \(st.rawValue)") }
        try releaseLocked(old)
        try acquireLocked(new)
    }

    /// draining -> detached, releasing output first when this module owns it. A failed release
    /// leaves module and session `failed` and the owner unchanged.
    func detach(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let st = stateLocked(id) else { throw err(.unknownModule, id) }
        if st == .validated { try moveLocked(id, to: .detached); return }
        try moveLocked(id, to: .draining)
        if _owner == .module(id) {
            guard releaseHandler(id) else {
                states[id] = .failed
                _failure = "release of \(id) was not acknowledged"
                throw err(.releaseFailed, _failure!)
            }
            _owner = .defaultWorld
        }
        try moveLocked(id, to: .detached)
    }

    /// Operator acknowledges a failed module: failed -> detached, body returns to the default world.
    func acknowledgeFailure(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try moveLocked(id, to: .detached)
        if _owner == .module(id) { _owner = .defaultWorld }
        if !states.values.contains(.failed) { _failure = nil }
    }

    /// Channels the module may use right now. Observations: any attached module, declared only.
    /// Actions (body output): only the current output owner.
    func allowedChannels(_ id: String) -> (observations: [String], actions: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard let m = registry.module(id), let st = stateLocked(id), [.attached, .ready, .running].contains(st) else { return ([], []) }
        return (m.descriptor.observations.map { $0.channelID }, _owner == .module(id) ? m.descriptor.actions.map { $0.channelID } : [])
    }

    func permits(_ id: String, channel: String, output: Bool) -> Bool {
        let a = allowedChannels(id)
        return (output ? a.actions : a.observations).contains(channel)
    }

    /// Rescan the modules folder. Refused while any module is attached or beyond, so lifecycle
    /// state is never dropped under a live connection.
    func rescan() throws {
        lock.lock(); defer { lock.unlock() }
        if let busy = registry.modules.first(where: { ![.validated, .detached].contains(stateLocked($0.descriptor.moduleID) ?? .validated) }) {
            throw err(.busy, "\(busy.descriptor.moduleID) is \(stateLocked(busy.descriptor.moduleID)!.rawValue)")
        }
        registry.reload(); states = [:]
    }
}
