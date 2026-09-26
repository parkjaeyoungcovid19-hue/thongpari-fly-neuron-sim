// FlyGymBridge.swift — localhost TCP bridge between the Metal brain and a
// Python FlyGym body. Swift is the CLIENT, Python `bridge.py` is the SERVER.
//
// Design constraints (see docs/plans/PLAN_FLYGYM.md):
// - The Metal brain stays authoritative at 1 kHz. Only compact population
//   signals cross the process boundary (~50-100 Hz BrainSignals).
// - Socket I/O NEVER runs on the render thread. A sender thread ships the
//   latest BrainSignals; a receiver thread parses body feedback. Bounded
//   buffers everywhere (latest-packet-wins); disconnect never crashes the sim.
// - Body->brain mapping is a MODELING ASSUMPTION, centralized in
//   FlyGymSensoryMap, reusing the existing ascend/sens input paths.

import Foundation
import Cocoa
import Darwin

enum FlyGymSendLane: Int {
    case brain = 0
    case escape = 1
    case lab = 2
    case control = 3
    case experimentStep = 4
    case worldRender = 5
    case rayPick = 6
    case playerInput = 7
}

fileprivate struct FlyGymPendingSend {
    var lane: FlyGymSendLane
    var data: Data
}

// MARK: - TCP client (POSIX, background threads only)

final class FlyGymBridge {
    /// Maximum bytes allowed for one unterminated inbound JSON line. V4 lab
    /// state can legitimately be much larger than the old 64 KiB assumption
    /// because it carries the authoritative object list for the preallocated
    /// world. Keep a hard bound so a malformed peer still cannot grow memory
    /// without limit.
    private let maxInboundLineBytes = 512 * 1024
    let host: String
    let port: UInt16
    /// Minimum interval between brain packets on the wire (~66 Hz cap).
    var minSendInterval: TimeInterval = 0.0125
    /// A queued lab burst may use the shared wire between brain packets, but a
    /// normal latest-state brain packet becomes mandatory before this age.
    var maxNormalBrainGap: TimeInterval = 0.075

    static let bodyFreshMaxAge: TimeInterval = 0.5
    static let labStateFreshMaxAge: TimeInterval = 1.5
    static let labDiscreteFreshMaxAge: TimeInterval = 5.0

    private let lock = NSLock()
    private var running = false
    private var sock: Int32 = -1
    private var _connected = false
    private var _connectionGeneration: UInt64 = 0
    private var pending: Data?          // latest unsent brain line (bounded: 1)
    private var pendingEscape: Data?    // bounded pulse lane: escape cannot be coalesced away
    private var pendingLab: [Data] = [] // ordered lab commands (bounded FIFO, cap 32)
    private var pendingControl: [Data] = []
    private var pendingExperimentStep: Data?
    private var pendingWorldRenderRequest: Data?
    private var pendingRayPicks: [Data] = []
    private var pendingPlayerInput: Data?
    private var pendingPlayerLookRemainder = [0.0, 0.0]
    private let labQueueCap = 32
    private let controlQueueCap = 16
    private let rayPickQueueCap = 8
    private var pendingCount = 0        // packets coalesced since last send
    private var droppedCoalesced: Int = 0
    private var droppedLab: Int = 0
    private var _latestBody: FlyGymBodyFeedback?
    private var _latestLabState: LabRemoteState?
    private var _latestLabAck: LabAck?
    private var recentLabAcks: [(serial: UInt64, ack: LabAck)] = []  // bounded ring (cap 128)
    private var labAckSerial: UInt64 = 0
    private var _latestLabEvent: LabEventNotice?
    private var _serverHello: FlyGymHelloPacket?
    private var _latestSessionState: FlyGymSessionStatePacket?
    private var _latestExperimentStepResult: FlyGymExperimentStepResultPacket?
    private var _latestWorldRenderSnapshot: WorldRenderSnapshot?
    private var _latestRayPickResult: RayPickResult?
    private var _latestPlayerInputResult: PlayerInputResult?
    private var requestedSessionID: String?
    private var requestedEpoch: Int?
    private var requestedSessionMode: LabSessionMode?
    private var outstandingExperimentStepSeq: Int?
    private var nextSessionControlSeq = 1
    private var nextLabID = 1
    private var nextViewerSeq = 1
    private var nextPlayerInputSeq = 1
    private var lastSend = Date.distantPast
    private var lastNormalBrainSendAt = Date.distantPast
    private var lastBodyAt: Date?
    private var bodyIntervals: [TimeInterval] = []   // bounded ring (cap 120)
    private(set) var sentCount = 0
    private(set) var recvCount = 0
    private(set) var malformedCount = 0
    private(set) var connectAttempts = 0
    private(set) var labSentCount = 0
    private(set) var labRecvCount = 0
    private(set) var controlSentCount = 0
    private(set) var experimentStepSentCount = 0
    private(set) var experimentStepRecvCount = 0
    private(set) var staleSessionPacketCount = 0

    init(host: String = "127.0.0.1", port: UInt16 = 17841) {
        self.host = host; self.port = port
    }

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var connectionGeneration: UInt64 { lock.lock(); defer { lock.unlock() }; return _connectionGeneration }
    var coalescedDropped: Int { lock.lock(); defer { lock.unlock() }; return droppedCoalesced }
    var labDropped: Int { lock.lock(); defer { lock.unlock() }; return droppedLab }
    var deterministicV4Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsDeterministicV4
    }

    var worldViewerV5_1Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsWorldViewerV5_1
    }

    var playerV5_4Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsPlayerV5_4
    }

    var playerInputV5_5Available: Bool {
        lock.lock(); defer { lock.unlock() }
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration else { return false }
        return hello.supportsPlayerInputV5_5
    }

    func serverHello() -> FlyGymHelloPacket? {
        lock.lock(); defer { lock.unlock() }
        guard let hello = _serverHello, _connected,
              hello.connectionGeneration == _connectionGeneration else { return nil }
        return hello
    }

    func latestSessionState() -> FlyGymSessionStatePacket? {
        lock.lock(); defer { lock.unlock() }
        guard let state = _latestSessionState, _connected,
              state.connectionGeneration == _connectionGeneration else { return nil }
        return state
    }

    func latestExperimentStepResult() -> FlyGymExperimentStepResultPacket? {
        lock.lock(); defer { lock.unlock() }
        guard let result = _latestExperimentStepResult, _connected,
              result.connectionGeneration == _connectionGeneration else { return nil }
        return result
    }

    func latestWorldRenderSnapshot(maxAge: TimeInterval = 1.0) -> WorldRenderSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot = _latestWorldRenderSnapshot,
              _connected, snapshot.connectionGeneration == _connectionGeneration,
              max(0, Date().timeIntervalSince(snapshot.receivedAt)) < maxAge else { return nil }
        return snapshot
    }

    func latestRayPickResult(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> RayPickResult? {
        lock.lock(); defer { lock.unlock() }
        guard let result = _latestRayPickResult,
              _connected, result.connectionGeneration == _connectionGeneration,
              max(0, Date().timeIntervalSince(result.receivedAt)) < maxAge else { return nil }
        return result
    }

    func latestPlayerInputResult(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> PlayerInputResult? {
        lock.lock(); defer { lock.unlock() }
        guard let result = _latestPlayerInputResult,
              _connected, result.connectionGeneration == _connectionGeneration,
              max(0, Date().timeIntervalSince(result.receivedAt)) < maxAge else { return nil }
        return result
    }

    private func freshnessLocked(receivedAt: Date?, packetGeneration: UInt64?,
                                 maxAge: TimeInterval, now: Date = Date()) -> FlyGymPacketFreshness {
        let age = receivedAt.map { max(0, now.timeIntervalSince($0)) }
        let sameGeneration = packetGeneration == _connectionGeneration
        let fresh = _connected && sameGeneration && (age.map { $0 < maxAge } ?? false)
        return FlyGymPacketFreshness(connected: _connected,
                                     currentGeneration: _connectionGeneration,
                                     packetGeneration: packetGeneration,
                                     ageSeconds: age,
                                     isFresh: fresh)
    }

    func bodyFreshness(maxAge: TimeInterval = FlyGymBridge.bodyFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestBody?.receivedAt,
                               packetGeneration: _latestBody?.connectionGeneration,
                               maxAge: maxAge)
    }

    func labStateFreshness(maxAge: TimeInterval = FlyGymBridge.labStateFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestLabState?.receivedAt,
                               packetGeneration: _latestLabState?.connectionGeneration,
                               maxAge: maxAge)
    }

    func labAckFreshness(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestLabAck?.receivedAt,
                               packetGeneration: _latestLabAck?.connectionGeneration,
                               maxAge: maxAge)
    }

    func labEventFreshness(maxAge: TimeInterval = FlyGymBridge.labDiscreteFreshMaxAge) -> FlyGymPacketFreshness {
        lock.lock(); defer { lock.unlock() }
        return freshnessLocked(receivedAt: _latestLabEvent?.receivedAt,
                               packetGeneration: _latestLabEvent?.connectionGeneration,
                               maxAge: maxAge)
    }

    func latestBody(maxAge: TimeInterval = FlyGymBridge.bodyFreshMaxAge) -> FlyGymBodyFeedback? {
        lock.lock(); defer { lock.unlock() }
        guard let b = _latestBody,
              freshnessLocked(receivedAt: b.receivedAt,
                              packetGeneration: b.connectionGeneration,
                              maxAge: maxAge).isFresh else { return nil }
        return b
    }

    func latestLabState(maxAge: TimeInterval? = nil) -> LabRemoteState? {
        lock.lock(); defer { lock.unlock() }
        guard let state = _latestLabState,
              _connected, state.connectionGeneration == _connectionGeneration else { return nil }
        if let maxAge, state.ageSeconds() >= maxAge { return nil }
        return state
    }

    func latestLabAck(maxAge: TimeInterval? = nil) -> LabAck? {
        lock.lock(); defer { lock.unlock() }
        guard let ack = _latestLabAck,
              _connected, ack.connectionGeneration == _connectionGeneration else { return nil }
        if let maxAge, ack.ageSeconds() >= maxAge { return nil }
        return ack
    }

    /// Every ACK recorded after `serial` (oldest first), so a 10 Hz UI can resolve
    /// each command it sent rather than only whichever ACK happened to be latest.
    /// lab_state repeats its last ACK; consecutive duplicates are stored once.
    func labAcks(after serial: UInt64) -> (acks: [LabAck], serial: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (recentLabAcks.filter { $0.serial > serial }.map(\.ack), labAckSerial)
    }

    private func setLatestLabAckLocked(_ ack: LabAck) {
        _latestLabAck = ack
        if let last = recentLabAcks.last?.ack, last.id == ack.id, last.ok == ack.ok,
           last.status == ack.status, last.appliedTick == ack.appliedTick,
           last.connectionGeneration == ack.connectionGeneration { return }
        labAckSerial += 1
        recentLabAcks.append((labAckSerial, ack))
        if recentLabAcks.count > 128 { recentLabAcks.removeFirst(recentLabAcks.count - 128) }
    }

    func latestLabEvent(maxAge: TimeInterval? = nil) -> LabEventNotice? {
        lock.lock(); defer { lock.unlock() }
        guard let event = _latestLabEvent,
              _connected, event.connectionGeneration == _connectionGeneration else { return nil }
        if let maxAge, event.ageSeconds() >= maxAge { return nil }
        return event
    }

    var bodyHz: Double {
        lock.lock(); defer { lock.unlock() }
        guard let body = _latestBody,
              freshnessLocked(receivedAt: body.receivedAt,
                              packetGeneration: body.connectionGeneration,
                              maxAge: FlyGymBridge.bodyFreshMaxAge).isFresh,
              bodyIntervals.count >= 4 else { return 0 }
        let span = bodyIntervals.reduce(0, +)
        return span > 0 ? Double(bodyIntervals.count) / span : 0
    }

    /// Largest receive-to-receive gap in the recent body-feedback window. A live
    /// average Hz can hide stalls, so regression/smoke tests assert this too.
    var maxRecentBodyGap: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let body = _latestBody,
              freshnessLocked(receivedAt: body.receivedAt,
                              packetGeneration: body.connectionGeneration,
                              maxAge: FlyGymBridge.bodyFreshMaxAge).isFresh else { return .infinity }
        return bodyIntervals.max() ?? .infinity
    }

    var statusLine: String {
        lock.lock()
        let c = _connected
        let sent = sentCount, recv = recvCount, mal = malformedCount
        let labSent = labSentCount, labRecv = labRecvCount
        let bodyAge = _latestBody.map { max(0, Date().timeIntervalSince($0.receivedAt)) }
        let bodyFresh = _latestBody.map {
            _connected && $0.connectionGeneration == _connectionGeneration
            && max(0, Date().timeIntervalSince($0.receivedAt)) < FlyGymBridge.bodyFreshMaxAge
        } ?? false
        let hz = { () -> Double in
            guard bodyFresh, self.bodyIntervals.count >= 4 else { return 0 }
            let span = self.bodyIntervals.reduce(0, +)
            return span > 0 ? Double(self.bodyIntervals.count) / span : 0
        }()
        lock.unlock()
        if c {
            let bodyStatus: String
            if bodyFresh, let age = bodyAge {
                bodyStatus = String(format: "%.0f Hz, %.0f ms old", hz, age * 1000)
            } else if let age = bodyAge {
                bodyStatus = String(format: "STALE, %.2f s old", age)
            } else {
                bodyStatus = "waiting"
            }
            return "FlyGym connected - brain \(sent), body \(recv) (\(bodyStatus)), lab \(labSent)/\(labRecv), malformed \(mal)"
        }
        return "FlyGym disconnected (brain continues locally)"
    }

    var labStatusLine: String {
        lock.lock()
        let connected = _connected
        let q = pendingLab.count
        let dropped = droppedLab
        let ack = _latestLabAck
        lock.unlock()
        let a = ack.map { "ack #\($0.id) \($0.ok ? "OK" : "ERR") \($0.message)" } ?? "no ack yet"
        return "\(connected ? "connected" : "disconnected") · queue \(q)/\(labQueueCap) · dropped \(dropped) · \(a)"
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        Thread { [weak self] in self?.sendLoop() }.start()
        Thread { [weak self] in self?.recvLoop() }.start()
    }

    func stop() {
        lock.lock()
        running = false
        let s = sock
        sock = -1
        _connected = false
        clearRemoteStateLocked()
        lock.unlock()
        if s >= 0 { Darwin.shutdown(s, Int32(SHUT_RDWR)); Darwin.close(s) }
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Called from the render thread: only encodes JSON + stores one Data.
    /// Never touches the socket. Latest-packet-wins, so bursts coalesce.
    func sendBrain(_ s: BrainSignals, simMs: Int) {
        let pkt = FlyGymBrainPacket(signals: s, simMs: simMs)
        guard let line = try? JSONEncoder().encode(pkt) else { return }
        var data = line; data.append(0x0A)
        lock.lock()
        if s.escape {
            if pendingEscape != nil { droppedCoalesced += 1 }
            pendingEscape = data
        } else {
            if pending != nil { droppedCoalesced += 1 }
            pending = data
        }
        pendingCount += 1
        lock.unlock()
    }

    private func encodeLine<T: Encodable>(_ packet: T) -> Data? {
        guard var data = try? JSONEncoder().encode(packet) else { return nil }
        data.append(0x0A)
        return data
    }

    /// V4 session control shares the background sender but has its own bounded
    /// ordered lane so pause/resume/handshake traffic cannot be coalesced with
    /// ordinary brain state.
    @discardableResult
    func sendSessionControl(action: String, sessionID: String, epoch: Int,
                            simTick: Int, mode: LabSessionMode,
                            resetScope: [String]? = nil) -> Int? {
        lock.lock()
        let seq = nextSessionControlSeq
        nextSessionControlSeq = nextSessionControlSeq == Int.max ? 1 : nextSessionControlSeq + 1
        lock.unlock()
        let packet = FlyGymSessionControlPacket(sessionID: sessionID,
                                               epoch: max(1, epoch), seq: seq,
                                               simTick: max(0, simTick),
                                               action: action, mode: mode,
                                               resetScope: resetScope)
        guard let data = encodeLine(packet) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard pendingControl.count < controlQueueCap else { return nil }
        if action == "begin" {
            requestedSessionID = sessionID
            requestedEpoch = max(1, epoch)
            requestedSessionMode = mode
            _latestSessionState = nil
            _latestExperimentStepResult = nil
            _latestBody = nil
            _latestLabState = nil
            _latestLabAck = nil
            _latestLabEvent = nil
            _latestWorldRenderSnapshot = nil
            _latestRayPickResult = nil
            _latestPlayerInputResult = nil
            lastBodyAt = nil
            bodyIntervals.removeAll(keepingCapacity: true)
            outstandingExperimentStepSeq = nil
            pendingExperimentStep = nil
            pendingWorldRenderRequest = nil
            pendingRayPicks.removeAll(keepingCapacity: true)
            pendingPlayerInput = nil
            pendingPlayerLookRemainder = [0.0, 0.0]
            nextPlayerInputSeq = 1
        } else if action == "reset", requestedSessionID == sessionID {
            // Reset is the one lifecycle control that intentionally changes the
            // simulation epoch. Promote the expected epoch before the packet is
            // sent so the matching reset confirmation can never be mistaken for
            // delayed old-epoch traffic on the same TCP generation.
            requestedEpoch = max(1, epoch)
            _latestSessionState = nil
            _latestExperimentStepResult = nil
            _latestBody = nil
            _latestLabState = nil
            _latestLabAck = nil
            _latestLabEvent = nil
            _latestWorldRenderSnapshot = nil
            _latestRayPickResult = nil
            _latestPlayerInputResult = nil
            lastBodyAt = nil
            bodyIntervals.removeAll(keepingCapacity: true)
            outstandingExperimentStepSeq = nil
            pendingExperimentStep = nil
            pendingWorldRenderRequest = nil
            pendingRayPicks.removeAll(keepingCapacity: true)
            pendingPlayerInput = nil
            pendingPlayerLookRemainder = [0.0, 0.0]
            nextPlayerInputSeq = 1
        }
        pendingControl.append(data)
        return seq
    }

    /// Queue exactly one deterministic body quantum. `false` means an earlier
    /// request is still pending/outstanding; callers must wait for its result.
    func sendExperimentStep(sessionID: String, epoch: Int, seq: Int,
                            simTick: Int, signals: BrainSignals) -> Bool {
        let packet = FlyGymExperimentStepPacket(
            sessionID: sessionID, epoch: max(1, epoch), seq: seq,
            simTick: max(0, simTick),
            brain: FlyGymBrainPacket(signals: signals, simMs: max(0, simTick)))
        guard let data = encodeLine(packet) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard _connected,
              requestedSessionID == sessionID, requestedEpoch == max(1, epoch),
              pendingExperimentStep == nil, outstandingExperimentStepSeq == nil else { return false }
        pendingExperimentStep = data
        outstandingExperimentStepSeq = seq
        return true
    }

    /// Request one immutable backend-originated render snapshot. Requests are
    /// latest-wins because they are observation only; no simulation mutation is
    /// represented by this lane.
    @discardableResult
    func requestWorldRenderSnapshot() -> Int? {
        lock.lock()
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration,
              hello.supportsWorldViewerV5_1 else { lock.unlock(); return nil }
        let seq = nextViewerSeq
        nextViewerSeq = nextViewerSeq == Int.max ? 1 : nextViewerSeq + 1
        let sessionID = requestedSessionID ?? ""
        let epoch = requestedEpoch ?? 0
        let protocolVersion = max(FlyGymProtocolV4.version, hello.protocolVersion)
        lock.unlock()

        var packet = WorldRenderRequest(sessionID: sessionID, epoch: epoch, seq: seq)
        packet.protocolVersion = protocolVersion
        guard let data = encodeLine(packet) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard _connected else { return nil }
        pendingWorldRenderRequest = data
        return seq
    }

    /// Send a read-only ray query. SceneKit only computes the ray; Python/MuJoCo
    /// decides the authoritative hit against the current simulation-owner state.
    @discardableResult
    func sendRayPick(rayOriginMM: [Double], rayDirection: [Double],
                     sourceSnapshotSeq: Int, sourceWorldRevision: Int,
                     sourceSimTick: Int) -> Int? {
        guard rayOriginMM.count == 3, rayOriginMM.allSatisfy(\.isFinite),
              rayDirection.count == 3, rayDirection.allSatisfy(\.isFinite) else { return nil }
        guard sourceSnapshotSeq > 0, sourceWorldRevision >= 0, sourceSimTick >= 0 else { return nil }
        let norm = sqrt(rayDirection.reduce(0) { $0 + $1 * $1 })
        guard norm >= 1e-12 else { return nil }
        let direction = rayDirection.map { $0 / norm }

        lock.lock()
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration,
              hello.supportsWorldViewerV5_1,
              pendingRayPicks.count < rayPickQueueCap else { lock.unlock(); return nil }
        let seq = nextViewerSeq
        nextViewerSeq = nextViewerSeq == Int.max ? 1 : nextViewerSeq + 1
        let sessionID = requestedSessionID ?? ""
        let epoch = requestedEpoch ?? 0
        let protocolVersion = max(FlyGymProtocolV4.version, hello.protocolVersion)
        lock.unlock()

        var packet = RayPickRequest(sessionID: sessionID, epoch: epoch, seq: seq,
                                    sourceSnapshotSeq: sourceSnapshotSeq,
                                    sourceWorldRevision: sourceWorldRevision,
                                    sourceSimTick: sourceSimTick,
                                    rayOriginMM: rayOriginMM, rayDirection: direction)
        packet.protocolVersion = protocolVersion
        guard let data = encodeLine(packet) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard _connected, pendingRayPicks.count < rayPickQueueCap else { return nil }
        pendingRayPicks.append(data)
        return seq
    }

    /// V5.5 continuous participant state. Axes/held state are latest-wins while
    /// unsent look deltas are accumulated so sender throttling cannot silently
    /// discard mouse motion. Deterministic experiment steps never overtake this
    /// lane when the input targets their boundary.
    private func splitPlayerLook(_ total: [Double]) -> (chunk: [Double], remainder: [Double]) {
        let limit = PlayerInputPacket.maxLookDelta
        let chunk = total.map { max(-limit, min(limit, $0)) }
        return (chunk, [total[0] - chunk[0], total[1] - chunk[1]])
    }

    private func allocatePlayerInputSeqLocked() -> Int? {
        guard nextPlayerInputSeq >= 0,
              nextPlayerInputSeq <= PlayerInputPacket.maxSeq else { return nil }
        let seq = nextPlayerInputSeq
        nextPlayerInputSeq = seq == PlayerInputPacket.maxSeq ? PlayerInputPacket.maxSeq + 1 : seq + 1
        return seq
    }

    private func promotePlayerLookRemainderLocked(afterSent data: Data) {
        guard pendingPlayerInput == nil,
              pendingPlayerLookRemainder.count == 2,
              (pendingPlayerLookRemainder[0] != 0 || pendingPlayerLookRemainder[1] != 0),
              let prior = decodePlayerInputLine(data),
              let seq = allocatePlayerInputSeqLocked() else { return }
        let split = splitPlayerLook(pendingPlayerLookRemainder)
        let packet = PlayerInputPacket(
            protocolVersion: prior.protocolVersion,
            actorID: prior.actorID,
            sessionID: prior.sessionID,
            epoch: prior.epoch,
            seq: seq,
            requestedTick: prior.requestedTick,
            moveAxes: prior.moveAxes,
            lookDelta: split.chunk,
            heldActions: prior.heldActions)
        guard let encoded = encodeLine(packet) else { return }
        pendingPlayerInput = encoded
        pendingPlayerLookRemainder = split.remainder
    }

    @discardableResult
    func sendPlayerInput(actorID: String = "player", sessionID: String, epoch: Int,
                         requestedTick: Int, moveAxes: [Double], lookDelta: [Double],
                         heldActions: [String], discardPendingLook: Bool = false) -> Int? {
        guard moveAxes.count == 2, moveAxes.allSatisfy(\.isFinite),
              lookDelta.count == 2, lookDelta.allSatisfy(\.isFinite),
              sessionID.count <= 128, epoch >= 0,
              requestedTick >= 0, requestedTick <= PlayerInputPacket.maxTick else { return nil }

        lock.lock()
        guard _connected, let hello = _serverHello,
              hello.connectionGeneration == _connectionGeneration,
              hello.supportsPlayerInputV5_5 else { lock.unlock(); return nil }
        if let expectedSession = requestedSessionID {
            guard sessionID == expectedSession, epoch == requestedEpoch else {
                lock.unlock(); return nil
            }
        } else {
            guard sessionID.isEmpty, epoch == 0 else { lock.unlock(); return nil }
        }
        let protocolVersion = max(FlyGymProtocolV4.version, hello.protocolVersion)

        if discardPendingLook {
            // Safety release (Esc/focus/mode loss) supersedes any unsent mouse
            // motion. A neutral packet must not inherit a stale look delta or
            // remainder that was captured before release.
            pendingPlayerInput = nil
            pendingPlayerLookRemainder = [0.0, 0.0]
        }
        var mergedLook = [
            lookDelta[0] + pendingPlayerLookRemainder[0],
            lookDelta[1] + pendingPlayerLookRemainder[1],
        ]
        if let pendingPlayerInput,
           let previous = decodePlayerInputLine(pendingPlayerInput),
           previous.actorID == actorID,
           previous.sessionID == sessionID,
           previous.epoch == max(0, epoch) {
            mergedLook[0] += previous.lookDelta[0]
            mergedLook[1] += previous.lookDelta[1]
        }
        guard mergedLook.allSatisfy(\.isFinite),
              let seq = allocatePlayerInputSeqLocked() else {
            lock.unlock(); return nil
        }
        let split = splitPlayerLook(mergedLook)
        let packet = PlayerInputPacket(protocolVersion: protocolVersion,
                                       actorID: actorID,
                                       sessionID: sessionID,
                                       epoch: epoch,
                                       seq: seq,
                                       requestedTick: requestedTick,
                                       moveAxes: moveAxes,
                                       lookDelta: split.chunk,
                                       heldActions: heldActions)
        guard let data = encodeLine(packet) else { lock.unlock(); return nil }
        pendingPlayerInput = data
        pendingPlayerLookRemainder = split.remainder
        lock.unlock()
        return seq
    }

    /// Enqueue one ordered experiment command. AppKit calls this directly; it
    /// performs only JSON encoding and a bounded in-memory append.
    @discardableResult
    func sendLab(action: String, target: String? = nil,
                 x: Double? = nil, y: Double? = nil, z: Double? = nil,
                 size: Double? = nil, speed: Double? = nil,
                 strength: Double? = nil, durationMs: Int? = nil,
                 value: Double? = nil, directionDeg: Double? = nil,
                 endDistance: Double? = nil, physical: Bool? = nil,
                 sensory: Bool? = nil, continuous: Bool? = nil,
                 mode: String? = nil,
                 protocolVersion: Int? = nil, sessionID: String? = nil,
                 epoch: Int? = nil, requestedTick: Int? = nil) -> Int {
        lock.lock()
        let id = nextLabID
        nextLabID = nextLabID == Int.max ? 1 : nextLabID + 1
        lock.unlock()
        let cmd = LabCommand(id: id, action: action, target: target,
                             x: x, y: y, z: z, size: size, speed: speed,
                             strength: strength, durationMs: durationMs, value: value,
                             directionDeg: directionDeg, endDistance: endDistance,
                             physical: physical, sensory: sensory,
                             continuous: continuous, mode: mode,
                             protocolVersion: protocolVersion, sessionID: sessionID,
                             epoch: epoch, requestedTick: requestedTick)
        guard let line = try? JSONEncoder().encode(cmd) else { return id }
        var data = line; data.append(0x0A)
        lock.lock()
        if pendingLab.count >= labQueueCap {
            if protocolVersion ?? 0 >= FlyGymProtocolV4.version {
                // V4 discrete experiment mutations fail closed. Never evict an
                // older command and later make the new one look successfully
                // queued; surface a local explicit failure ACK instead.
                droppedLab += 1
                setLatestLabAckLocked(LabAck(type: "lab_ack", id: id, ok: false,
                                       action: action, message: "local lab command queue full",
                                       appliedTick: nil, appliedEpoch: nil,
                                       status: "queue_full", sessionID: sessionID,
                                       epoch: epoch, simTick: requestedTick,
                                       receivedAt: Date(),
                                       connectionGeneration: _connectionGeneration))
                lock.unlock()
                return id
            } else {
                pendingLab.removeFirst()
                droppedLab += 1
            }
        }
        pendingLab.append(data)
        lock.unlock()
        return id
    }

    // -- test hook: one latest-state slot + one escape-pulse slot.
    func pendingDepth() -> Int {
        lock.lock(); defer { lock.unlock() }
        return (pending == nil ? 0 : 1) + (pendingEscape == nil ? 0 : 1)
            + pendingLab.count + pendingControl.count + (pendingExperimentStep == nil ? 0 : 1)
            + (pendingWorldRenderRequest == nil ? 0 : 1) + pendingRayPicks.count
            + (pendingPlayerInput == nil ? 0 : 1)
    }


    func pendingLabDepth() -> Int { lock.lock(); defer { lock.unlock() }; return pendingLab.count }

    private func clearRemoteStateLocked() {
        _latestBody = nil
        _latestLabState = nil
        _latestLabAck = nil
        _latestLabEvent = nil
        _serverHello = nil
        _latestSessionState = nil
        _latestExperimentStepResult = nil
        _latestWorldRenderSnapshot = nil
        _latestRayPickResult = nil
        _latestPlayerInputResult = nil
        outstandingExperimentStepSeq = nil
        pendingExperimentStep = nil
        pendingPlayerInput = nil
        pendingPlayerLookRemainder = [0.0, 0.0]
        lastBodyAt = nil
        bodyIntervals.removeAll(keepingCapacity: true)
    }

    /// V4 deterministic packets must carry the complete simulation identity.
    /// Interactive sessions keep tolerant legacy parsing so a V3-compatible peer
    /// can still acknowledge ordinary UI commands without V4 envelope fields.
    private func matchesRequestedSessionLocked(sessionID: String?, epoch: Int?) -> Bool {
        guard let expectedSession = requestedSessionID else { return true }
        let expectedEpoch = requestedEpoch
        if requestedSessionMode == .deterministic {
            return sessionID == expectedSession && epoch == expectedEpoch
        }
        if let sessionID, sessionID != expectedSession { return false }
        if let epoch, epoch != expectedEpoch { return false }
        return true
    }

    private func matchesViewerSessionLocked(sessionID: String, epoch: Int) -> Bool {
        if let expectedSession = requestedSessionID {
            return sessionID == expectedSession && epoch == requestedEpoch
        }
        // The backend uses this explicit identity before a V4 session begins.
        return sessionID.isEmpty && epoch == 0
    }

    private func recordDroppedLabLocked(_ data: Data, reason: String) {
        guard let command = try? JSONDecoder().decode(LabCommand.self, from: data),
              command.protocolVersion ?? 0 >= FlyGymProtocolV4.version else { return }
        setLatestLabAckLocked(LabAck(type: "lab_ack", id: command.id, ok: false,
                               action: command.action, message: reason,
                               appliedTick: nil, appliedEpoch: nil,
                               status: "queue_full", sessionID: command.sessionID,
                               epoch: command.epoch, simTick: command.requestedTick,
                               receivedAt: Date(),
                               connectionGeneration: _connectionGeneration))
    }

    private func beginConnectionLocked(_ fd: Int32) {
        sock = fd
        _connected = true
        _connectionGeneration &+= 1
        if _connectionGeneration == 0 { _connectionGeneration = 1 }
        clearRemoteStateLocked()
        pendingControl.removeAll(keepingCapacity: true)
        pendingWorldRenderRequest = nil
        pendingRayPicks.removeAll(keepingCapacity: true)
        pendingPlayerInput = nil
        pendingPlayerLookRemainder = [0.0, 0.0]
        if let hello = encodeLine(FlyGymHelloPacket()) {
            pendingControl.append(hello)
        }
        lastSend = .distantPast
        lastNormalBrainSendAt = .distantPast
    }

    private func currentConnectionLocked(fd: Int32, generation: UInt64) -> Bool {
        _connected && sock == fd && _connectionGeneration == generation
    }

    private func dequeueNextLocked(now: Date) -> FlyGymPendingSend? {
        if !pendingControl.isEmpty {
            return FlyGymPendingSend(lane: .control, data: pendingControl.removeFirst())
        }
        // A deterministic step defines an application boundary. Any lab command
        // already queued by Swift before that step reservation must reach Python
        // first; otherwise the step lane could overtake a requested-tick command
        // and force it to apply one quantum late. Wall time may slow down here —
        // deterministic experiment order must not.
        if pendingExperimentStep != nil, let input = pendingPlayerInput {
            pendingPlayerInput = nil
            return FlyGymPendingSend(lane: .playerInput, data: input)
        }
        if pendingExperimentStep != nil, !pendingLab.isEmpty {
            return FlyGymPendingSend(lane: .lab, data: pendingLab.removeFirst())
        }
        if let step = pendingExperimentStep {
            pendingExperimentStep = nil
            return FlyGymPendingSend(lane: .experimentStep, data: step)
        }
        if let urgent = pendingEscape {
            pendingEscape = nil
            return FlyGymPendingSend(lane: .escape, data: urgent)
        }
        if let brain = pending,
           pendingLab.isEmpty || now.timeIntervalSince(lastNormalBrainSendAt) >= maxNormalBrainGap {
            pending = nil
            return FlyGymPendingSend(lane: .brain, data: brain)
        }
        if let input = pendingPlayerInput {
            pendingPlayerInput = nil
            return FlyGymPendingSend(lane: .playerInput, data: input)
        }
        if !pendingLab.isEmpty {
            return FlyGymPendingSend(lane: .lab, data: pendingLab.removeFirst())
        }
        if !pendingRayPicks.isEmpty {
            return FlyGymPendingSend(lane: .rayPick, data: pendingRayPicks.removeFirst())
        }
        if let request = pendingWorldRenderRequest {
            pendingWorldRenderRequest = nil
            return FlyGymPendingSend(lane: .worldRender, data: request)
        }
        if let brain = pending {
            pending = nil
            return FlyGymPendingSend(lane: .brain, data: brain)
        }
        return nil
    }

    private func requeueLocked(_ item: FlyGymPendingSend) {
        switch item.lane {
        case .escape:
            if pendingEscape == nil { pendingEscape = item.data }
        case .lab:
            pendingLab.insert(item.data, at: 0)
            if pendingLab.count > labQueueCap {
                let dropped = pendingLab.removeLast()
                droppedLab += 1
                recordDroppedLabLocked(dropped, reason: "local lab command queue full while retrying send")
            }
        case .brain:
            // If a newer latest-state packet arrived while send() was running,
            // keep the newer packet rather than restoring an obsolete snapshot.
            if pending == nil { pending = item.data }
        case .control:
            pendingControl.insert(item.data, at: 0)
            if pendingControl.count > controlQueueCap { pendingControl.removeLast() }
        case .experimentStep:
            if pendingExperimentStep == nil { pendingExperimentStep = item.data }
        case .worldRender:
            // Observation requests are latest-wins. If a newer request arrived
            // during send(), keep the newer one.
            if pendingWorldRenderRequest == nil { pendingWorldRenderRequest = item.data }
        case .rayPick:
            pendingRayPicks.insert(item.data, at: 0)
            if pendingRayPicks.count > rayPickQueueCap { pendingRayPicks.removeLast() }
        case .playerInput:
            // Continuous state is latest-wins. Never restore an older packet over
            // a newer key/focus transition that arrived during send().
            if pendingPlayerInput == nil { pendingPlayerInput = item.data }
        }
    }

    /// Called with lock held after connection/session validation succeeds.
    private func acceptBodyLocked(_ body: FlyGymBodyFeedback, receivedAt: Date) {
        if let previous = lastBodyAt {
            let interval = receivedAt.timeIntervalSince(previous)
            if interval > 0 {
                bodyIntervals.append(interval)
                if bodyIntervals.count > 120 { bodyIntervals.removeFirst(bodyIntervals.count - 120) }
            }
        }
        lastBodyAt = receivedAt
        _latestBody = body
        recvCount += 1
    }

    private func acceptInboundLine(_ line: Data, fd: Int32, generation: UInt64,
                                   receivedAt: Date = Date()) -> Bool {
        guard let packet = try? JSONDecoder().decode(FlyGymInboundPacket.self, from: line) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard currentConnectionLocked(fd: fd, generation: generation) else { return true }
        switch packet {
        case .hello(var hello):
            hello.receivedAt = receivedAt
            hello.connectionGeneration = generation
            _serverHello = hello
            if !hello.supportsPlayerInputV5_5 {
                pendingPlayerInput = nil
                pendingPlayerLookRemainder = [0.0, 0.0]
            }
            return true
        case .playerInputResult(var result):
            result.receivedAt = receivedAt
            result.connectionGeneration = generation
            if !matchesViewerSessionLocked(sessionID: result.sessionID, epoch: result.epoch) {
                staleSessionPacketCount += 1
                return true
            }
            _latestPlayerInputResult = result
            return true
        case .sessionState(var session):
            session.receivedAt = receivedAt
            session.connectionGeneration = generation
            if let expected = requestedSessionID {
                let wrongSession = session.sessionID != expected
                let wrongEpoch = requestedEpoch.map { session.epoch != $0 } ?? false
                if wrongSession || wrongEpoch {
                    staleSessionPacketCount += 1
                    return true
                }
            }
            _latestSessionState = session
            return true
        case .experimentStepResult(var result):
            result.receivedAt = receivedAt
            result.connectionGeneration = generation
            var fb: FlyGymBodyFeedback?
            if result.ok {
                var value = FlyGymBodyFeedback(result.body)
                value.receivedAt = receivedAt
                value.connectionGeneration = generation
                fb = value
            }
            let expectedSession = requestedSessionID
            let expectedEpoch = requestedEpoch
            let expectedSeq = outstandingExperimentStepSeq
            guard expectedSession == result.sessionID,
                  expectedEpoch == result.epoch,
                  expectedSeq == result.seq else {
                staleSessionPacketCount += 1
                return true
            }
            _latestExperimentStepResult = result
            outstandingExperimentStepSeq = nil
            experimentStepRecvCount += 1
            if let fb { acceptBodyLocked(fb, receivedAt: receivedAt) }
            return true
        case .worldRenderSnapshot(var snapshot):
            snapshot.receivedAt = receivedAt
            snapshot.connectionGeneration = generation
            guard _serverHello?.supportsWorldViewerV5_1 == true,
                  matchesViewerSessionLocked(sessionID: snapshot.sessionID, epoch: snapshot.epoch) else {
                staleSessionPacketCount += 1
                return true
            }
            if snapshot.ok, let incomingID = snapshot.snapshotID,
               let previous = _latestWorldRenderSnapshot,
               previous.ok, previous.sessionID == snapshot.sessionID,
               previous.epoch == snapshot.epoch,
               let previousID = previous.snapshotID, incomingID <= previousID {
                return true
            }
            _latestWorldRenderSnapshot = snapshot
            return true
        case .rayPickResult(var pick):
            pick.receivedAt = receivedAt
            pick.connectionGeneration = generation
            guard _serverHello?.supportsWorldViewerV5_1 == true,
                  matchesViewerSessionLocked(sessionID: pick.sessionID, epoch: pick.epoch) else {
                staleSessionPacketCount += 1
                return true
            }
            if let previous = _latestRayPickResult,
               previous.sessionID == pick.sessionID, previous.epoch == pick.epoch,
               pick.seq < previous.seq {
                return true
            }
            _latestRayPickResult = pick
            return true
        case .body(let pkt):
            var fb = FlyGymBodyFeedback(pkt)
            fb.receivedAt = receivedAt
            fb.connectionGeneration = generation
            acceptBodyLocked(fb, receivedAt: receivedAt)
            return true
        case .labState(var state):
            state.receivedAt = receivedAt
            state.connectionGeneration = generation
            if !matchesRequestedSessionLocked(sessionID: state.sessionID, epoch: state.epoch) {
                staleSessionPacketCount += 1
                return true
            }
            _latestLabState = state
            labRecvCount += 1
            if let ackID = state.ack {
                setLatestLabAckLocked(LabAck(type: "lab_ack", id: ackID,
                                       ok: state.ok ?? (state.error == nil),
                                       action: state.lastAction ?? "",
                                       message: state.error ?? "ok",
                                       appliedTick: state.appliedTick,
                                       appliedEpoch: state.appliedEpoch,
                                       status: state.status,
                                       sessionID: state.sessionID,
                                       epoch: state.epoch,
                                       simTick: state.simTick,
                                       receivedAt: receivedAt,
                                       connectionGeneration: generation))
            }
            return true
        case .labAck(var ack):
            ack.receivedAt = receivedAt
            ack.connectionGeneration = generation
            if !matchesRequestedSessionLocked(sessionID: ack.sessionID, epoch: ack.epoch) {
                staleSessionPacketCount += 1
                return true
            }
            setLatestLabAckLocked(ack)
            labRecvCount += 1
            return true
        case .labEvent(var event):
            event.receivedAt = receivedAt
            event.connectionGeneration = generation
            _latestLabEvent = event
            labRecvCount += 1
            return true
        }
    }

    // MARK: test hooks (same production lifecycle/arbitration paths, no sockets)

    func beginConnectionForTesting() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        beginConnectionLocked(-2)
        return _connectionGeneration
    }

    func receiveLineForTesting(_ line: Data, at receivedAt: Date = Date()) -> Bool {
        lock.lock()
        let fd = sock
        let generation = _connectionGeneration
        lock.unlock()
        return acceptInboundLine(line, fd: fd, generation: generation, receivedAt: receivedAt)
    }

    /// Test hook for the exact production line-framing path. The caller owns
    /// `buffer`, which lets tests feed the same JSON line in recv()-sized chunks.
    func receiveBytesForTesting(_ chunk: Data, buffer: inout Data,
                                             at receivedAt: Date = Date()) {
        lock.lock()
        let fd = sock
        let generation = _connectionGeneration
        lock.unlock()
        buffer.append(chunk)
        drainInboundBuffer(&buffer, fd: fd, generation: generation, receivedAt: receivedAt)
    }

    func disconnectForTesting() {
        lock.lock()
        let fd = sock
        let generation = _connectionGeneration
        lock.unlock()
        markDown(fd, generation: generation)
    }

    func setNextPlayerInputSeqForTesting(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        nextPlayerInputSeq = value
    }

    func dequeueLaneForTesting(at now: Date) -> FlyGymSendLane? {
        lock.lock(); defer { lock.unlock() }
        guard let item = dequeueNextLocked(now: now) else { return nil }
        if item.lane == .brain { lastNormalBrainSendAt = now }
        if item.lane == .playerInput {
            // Test dequeue models a successful production send so any bounded
            // look remainder is promoted exactly as sendLoop would do.
            promotePlayerLookRemainderLocked(afterSent: item.data)
        }
        return item.lane
    }

    func dequeueSendForTesting(at now: Date) -> (FlyGymSendLane, Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let item = dequeueNextLocked(now: now) else { return nil }
        if item.lane == .brain { lastNormalBrainSendAt = now }
        if item.lane == .playerInput {
            promotePlayerLookRemainderLocked(afterSent: item.data)
        }
        return (item.lane, item.data)
    }

    // MARK: threads

    private func openConnection() -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        withUnsafePointer(to: &tv) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { q in
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, q, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, q, socklen_t(MemoryLayout<timeval>.size))
            }
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = host.withCString { Darwin.inet_addr($0) }
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
                Darwin.connect(fd, q, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    private func sendLoop() {
        while isRunning() {
            lock.lock()
            let fd = sock
            let ok = _connected
            let generation = _connectionGeneration
            lock.unlock()
            if !ok || fd < 0 {
                lock.lock(); connectAttempts += 1; lock.unlock()
                let fd2 = openConnection()
                var closeUnused = false
                lock.lock()
                if fd2 >= 0 && running && !_connected && sock < 0 {
                    beginConnectionLocked(fd2)
                } else if fd2 >= 0 {
                    closeUnused = true
                }
                lock.unlock()
                if closeUnused { Darwin.shutdown(fd2, Int32(SHUT_RDWR)); Darwin.close(fd2) }
                if fd2 < 0 { Thread.sleep(forTimeInterval: 0.5); continue }
                continue
            }
            lock.lock()
            let now = Date()
            let sendWait = minSendInterval - now.timeIntervalSince(lastSend)
            let item = sendWait <= 0 ? dequeueNextLocked(now: now) : nil
            lock.unlock()
            if sendWait > 0 {
                Thread.sleep(forTimeInterval: min(0.005, max(0.001, sendWait)))
                continue
            }
            if let item {
                let d = item.data
                var sent = 0
                d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                    var cur = p.baseAddress!
                    var left = d.count
                    while left > 0 {
                        let n = Darwin.send(fd, cur, left, 0)
                        if n <= 0 { break }
                        sent += n; cur = cur.advanced(by: n); left -= n
                    }
                }
                lock.lock()
                if sent == d.count {
                    let sentAt = Date()
                    switch item.lane {
                    case .brain:
                        sentCount += 1
                        lastNormalBrainSendAt = sentAt
                    case .escape:
                        sentCount += 1
                    case .lab:
                        labSentCount += 1
                    case .control:
                        controlSentCount += 1
                    case .experimentStep:
                        experimentStepSentCount += 1
                    case .worldRender, .rayPick:
                        break
                    case .playerInput:
                        promotePlayerLookRemainderLocked(afterSent: d)
                    }
                    lastSend = sentAt
                }
                else {
                    requeueLocked(item)
                }
                lock.unlock()
                if sent != d.count { markDown(fd, generation: generation) }
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    private func markDown(_ fd: Int32, generation: UInt64) {
        lock.lock()
        let shouldClose = sock == fd && _connectionGeneration == generation
        if shouldClose {
            sock = -1
            _connected = false
            clearRemoteStateLocked()
        }
        lock.unlock()
        // sendLoop and recvLoop can discover the same failure concurrently.
        // Only the first thread that still owns this descriptor may close it;
        // otherwise a reused descriptor for a new connection could be closed.
        if shouldClose && fd >= 0 {
            Darwin.shutdown(fd, Int32(SHUT_RDWR)); Darwin.close(fd)
        }
    }

    /// Split newline-delimited protocol frames, route complete lines through the
    /// production parser/arbitration path, and bound malformed partial input.
    private func drainInboundBuffer(_ buf: inout Data, fd: Int32, generation: UInt64,
                                    receivedAt: Date = Date()) {
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineLength = buf.distance(from: buf.startIndex, to: nl)
            if lineLength > maxInboundLineBytes {
                buf.removeSubrange(buf.startIndex...nl)
                lock.lock()
                if currentConnectionLocked(fd: fd, generation: generation) {
                    malformedCount += 1
                }
                lock.unlock()
                continue
            }
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if line.isEmpty { continue }
            if !acceptInboundLine(line, fd: fd, generation: generation, receivedAt: receivedAt) {
                lock.lock()
                if currentConnectionLocked(fd: fd, generation: generation) {
                    malformedCount += 1
                }
                lock.unlock()
            }
        }
        if buf.count > maxInboundLineBytes {
            buf.removeAll(keepingCapacity: true)
            lock.lock()
            if currentConnectionLocked(fd: fd, generation: generation) {
                malformedCount += 1
            }
            lock.unlock()
        }
    }

    private func recvLoop() {
        var buf = Data()
        var bufferFD: Int32 = -1
        var bufferGeneration: UInt64 = 0
        let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { tmp.deallocate() }
        while isRunning() {
            lock.lock()
            let fd = sock
            let ok = _connected
            let generation = _connectionGeneration
            lock.unlock()
            if !ok || fd < 0 {
                buf.removeAll(keepingCapacity: true)
                bufferFD = -1
                bufferGeneration = 0
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if fd != bufferFD || generation != bufferGeneration {
                buf.removeAll(keepingCapacity: true)
                bufferFD = fd
                bufferGeneration = generation
            }
            let n = Darwin.recv(fd, tmp, 4096, 0)
            if n > 0 {
                buf.append(tmp, count: n)
                drainInboundBuffer(&buf, fd: fd, generation: generation)
            } else if n == 0 {
                markDown(fd, generation: generation); buf.removeAll() // orderly close -> reconnect
                bufferFD = -1; bufferGeneration = 0
            } else {
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    markDown(fd, generation: generation); buf.removeAll()
                    bufferFD = -1; bufferGeneration = 0
                }
                // else: timeout tick, socket still alive
            }
        }
    }
}
