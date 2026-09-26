// Thongpari Fly Neuron Sim — a 3D fruit fly that walks across your macOS desktop, driven by
// REAL FlyWire v783 connectome data: a live GPU (Metal) LIF simulation of the
// WHOLE brain — 139,255 neurons, 15,091,983 signed edges — with the escape
// circuit (LC4/LPLC2 -> DNp01 giant fiber), DNa01/02 steering, DNp09 walking
// and MDN backward-walking neurons read out as behavior.
//
// Files:  Sim.swift (connectome loader + shared types), MetalSim.swift + LIF.metal
//         (the GPU simulation), FlyModel.swift (body), BrainView.swift (brain
//         window), Environment.swift (permission-free senses). Self-tests live in
//         SimDiagnostics.swift, LabDiagnostics.swift and BridgeDiagnostics.swift.
//
// Build:  ./build.sh
// Run:    ./ThongpariFlyNeuronSim                     (menu-bar 🪰; brain window shows live spikes)
//         ./ThongpariFlyNeuronSim --snapshot out.png  (offscreen fly model render)
//         ./ThongpariFlyNeuronSim --brainshot out.png (offscreen brain window render)
//         ./ThongpariFlyNeuronSim --simtest           (headless circuit test + GPU benchmark)
//         ./ThongpariFlyNeuronSim --behaviortest      (end-to-end sim -> body checks)
//         ./ThongpariFlyNeuronSim --flygym            (stream BrainSignals to a FlyGym body)
//         ./ThongpariFlyNeuronSim --bridgetest        (bridge serialization/mapping checks)
//         ./ThongpariFlyNeuronSim --gpucheck          (GPU sim vs an independent CPU reference)
//         ./ThongpariFlyNeuronSim --brainstats [s]    (resting-regime diagnostics: rates by class/role)
//         --seed N                          (pin the sim seed; N decimal or 0x hex)

import Cocoa
import SceneKit

// Sim seed. `--seed N` pins every sim in this process. Without it the CLI
// diagnostic modes use the shipped default, so --simtest/--behaviortest/
// --gpucheck/--brainstats/--brainshot stay reproducible, and the live app draws
// a fresh seed per launch (two launches are not the same fly).
let seedOverride: UInt32? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--seed"), i + 1 < a.count else { return nil }
    let t = a[i + 1]
    let hex = t.hasPrefix("0x") || t.hasPrefix("0X")
    return UInt32(hex ? String(t.dropFirst(2)) : t, radix: hex ? 16 : 10)
}()
let SIM_SEED: UInt32 = seedOverride ?? 0x5EED_1F1F
func launchSeed() -> UInt32 { seedOverride ?? .random(in: 1...UInt32.max) }

// MARK: - Desktop overlay scene

func buildScene(bounds: CGSize) -> SCNScene {
    let scene = SCNScene()

    let camera = SCNCamera()
    camera.usesOrthographicProjection = true
    camera.orthographicScale = Double(bounds.height / 2)
    camera.zNear = 1
    camera.zFar = 600
    let camNode = SCNNode()
    camNode.name = "camera"
    camNode.camera = camera
    camNode.position = SCNVector3(0, 0, 300)
    scene.rootNode.addChildNode(camNode)

    let key = SCNLight()
    key.type = .directional
    key.intensity = 1000
    if SHADOWS_ENABLED {
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.30)
        key.shadowRadius = 6
        key.shadowSampleCount = 8
    }
    let keyNode = SCNNode()
    keyNode.light = key
    keyNode.eulerAngles = SCNVector3(-0.35, 0.30, 0)
    scene.rootNode.addChildNode(keyNode)

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 550
    ambient.color = NSColor(calibratedWhite: 1.0, alpha: 1)
    let ambNode = SCNNode()
    ambNode.light = ambient
    scene.rootNode.addChildNode(ambNode)

    if SHADOWS_ENABLED {
        // fixed size: large enough for any display the fly may be moved to
        let plane = SCNPlane(width: 6000, height: 6000)
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        plane.materials = [m]
        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3(0, 0, -0.6)
        scene.rootNode.addChildNode(planeNode)
    }

    return scene
}

// MARK: - Offscreen render modes

func offscreenRender(_ scene: SCNScene, camNode: SCNNode, size: CGSize, path: String) {
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    renderer.pointOfView = camNode
    let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    savePNG(img, to: path)
    print("snapshot written to \(path)")
}

func runSnapshot(path: String) {
    let scene = SCNScene()
    scene.background.contents = NSColor(calibratedWhite: 0.94, alpha: 1)
    let fly = Fly(at: .zero)
    fly.heading = .pi / 2
    for (i, leg) in fly.model.legs.enumerated() {
        leg.angle = [0.25, -0.2, -0.22, 0.28, 0.2, -0.25][i]
        leg.lift = [0.35, 0, 0, 0.3, 0, 0.35][i]
        leg.apply()
    }
    fly.syncNode()
    scene.rootNode.addChildNode(fly.node)
    let camera = SCNCamera()
    camera.fieldOfView = 42
    let camNode = SCNNode()
    camNode.camera = camera
    camNode.position = SCNVector3(30, -58, 42)
    let lookAt = SCNLookAtConstraint(target: fly.node)
    lookAt.isGimbalLockEnabled = true
    camNode.constraints = [lookAt]
    scene.rootNode.addChildNode(camNode)
    let key = SCNLight(); key.type = .directional; key.intensity = 1100
    let keyNode = SCNNode(); keyNode.light = key
    keyNode.eulerAngles = SCNVector3(-0.9, 0.5, 0)
    scene.rootNode.addChildNode(keyNode)
    let amb = SCNLight(); amb.type = .ambient; amb.intensity = 500
    let ambNode = SCNNode(); ambNode.light = amb
    scene.rootNode.addChildNode(ambNode)
    offscreenRender(scene, camNode: camNode, size: CGSize(width: 720, height: 720), path: path)
}

func runBrainshot(path: String) {
    guard let c = loadConnectome(),
          let sim = MetalSim(connectome: c, spikeBus: nil, seed: SIM_SEED) else {
        fputs("no data/ — run etl.py first\n", stderr); exit(1)
    }
    let bs = buildBrainScene(connectome: c, sim: sim)
    bs.brainGroup.removeAllActions()
    bs.brainGroup.eulerAngles = SCNVector3(-0.15, 0.5, 0)
    // decorate with a burst of fake spikes so the preview shows the live look
    let driver = BrainRenderDriver(sim: sim, flashPool: bs.flashPool)
    for _ in 0..<40 { driver.flash(neuron: Int.random(in: 0..<sim.n), isGF: false) }
    if let gfIdx = sim.gf.first { driver.flash(neuron: gfIdx, isGF: true) }
    for node in bs.flashPool { node.removeAllActions() }   // freeze mid-flash
    offscreenRender(bs.scene, camNode: bs.cameraNode, size: CGSize(width: 720, height: 560), path: path)
}

// MARK: - Coordinator

final class Coordinator: NSObject, SCNSceneRendererDelegate {
    let scene: SCNScene
    var bounds: CGSize
    var flies: [Fly] = []
    var lastTime: TimeInterval?
    var mouseScene: CGPoint?
    private let lock = NSLock()
    private var pending: [(Coordinator) -> Void] = []
    private var simulationPending: [(Coordinator) -> Void] = []
    private let simulationLock = NSLock()
    private let deterministicQueue = DispatchQueue(label: "ThongpariFlyNeuronSim.v4-deterministic")
    private var deterministicTimer: DispatchSourceTimer?
    let labSession = LabSession()
    private var deterministicEnabled = false
    private var localNeuralPaused = false
    private var deterministicLatestSignals = BrainSignals()
    private var deterministicSleepy = false
    private var deterministicTempo: CGFloat = 1
    private var deterministicActivity: Float = 1
    private var pendingDeterministicResetScopes = Set<String>()
    private var deterministicResetControlInFlight = false
    private var resumeAfterDeterministicReset = false
    private var deterministicResetCompletions: [() -> Void] = []
    private var interactiveSessionStarted = false
    private var interactiveSessionGeneration: UInt64?

    let sim: MetalSim?
    var flyGym: FlyGymBridge?
    private let fpsLog = ProcessInfo.processInfo.environment["DESKTOPFLY_FPS"] != nil
    private var fpsFrames = 0
    private var fpsWindowStart: TimeInterval = 0
    private let signalBuilder = SignalBuilder()
    private var msAccumulator: Double = 0
    private var prevMouse: CGPoint?
    private var mouseVel = CGPoint.zero
    private var loomOverride: CGFloat = 0

    // environment senses (written from main-thread timers, read in render loop)
    private var terrain: [Ledge] = []
    private var typingLevel: CGFloat = 0
    private var sleepy = false
    private var tempo: CGFloat = 1
    private var activity: Float = 1
    private var windowLoomL: Float = 0
    private var windowLoomR: Float = 0
    private var labWind: Float = 0
    private var labWindContinuous = false
    private var labWindRemainingS: Double = 0
    private var labWindDirectionDeg: Double = 0
    private var labTemperatureC: Double = 25
    private var labTempoOverride: CGFloat?
    private var labThermosensoryEnabled = false
    private var labOdorDriveL: Float = 0
    private var labOdorDriveR: Float = 0
    private var labThermoWarmDrive: Float = 0
    private var labThermoCoolDrive: Float = 0
    private var labWindCDrive: Float = 0
    private var labWindEDrive: Float = 0
    private var labTouchDrive: Float = 0
    private var labTouchRemainingS: Double = 0
    private var labSnapshot = LabTelemetry()
    private(set) var lastFlyPos = CGPoint.zero

    init(bounds: CGSize, sim: MetalSim?) {
        self.bounds = bounds
        self.sim = sim
        self.scene = buildScene(bounds: bounds)
        super.init()
        enqueue { $0.addFlyNow() }
    }

    func enqueue(_ action: @escaping (Coordinator) -> Void) {
        lock.lock(); pending.append(action); lock.unlock()
    }

    /// Simulation mutations have a single owner. In interactive mode the
    /// renderer drains them; in deterministic mode the V4 lockstep queue does.
    func enqueueSimulation(_ action: @escaping (Coordinator) -> Void) {
        lock.lock(); simulationPending.append(action); lock.unlock()
    }

    private func drainSimulationActions() -> [(Coordinator) -> Void] {
        lock.lock(); defer { lock.unlock() }
        let actions = simulationPending
        simulationPending.removeAll(keepingCapacity: true)
        return actions
    }

    /// UI/recorder view of the session. A deterministic session's tick is the
    /// lockstep tick. An interactive session has no lockstep tick: LabSession
    /// keeps only the tick it began at, so report the backend world clock (body
    /// simulation time, the same clock as render snapshots and player-input
    /// ticks) instead of that frozen start tick.
    func sessionSnapshot() -> LabSessionSnapshot {
        var snapshot = labSession.snapshot()
        guard snapshot.mode == .interactive else { return snapshot }
        // Read the bridge before taking our lock so the two locks never nest.
        let body = flyGym?.latestBody(maxAge: .greatestFiniteMagnitude)
        lock.lock(); defer { lock.unlock() }
        if let body, body.simTime.isFinite, body.simTime >= 0 {
            lastInteractiveWorldTick = Int((body.simTime * 1000.0).rounded())
        }
        // Right after a session begin the bridge has no body packet yet; keep
        // the last world time rather than falling back to the begin tick.
        if let tick = lastInteractiveWorldTick { snapshot.simTick = tick }
        return snapshot
    }
    private var lastInteractiveWorldTick: Int?

    func labCommandSchedule() -> LabCommandSchedule? { labSession.commandSchedule() }

    /// V5.5 game input uses an explicit V4 interactive session when available so
    /// session/epoch rejection remains meaningful outside deterministic runs. The
    /// actual requested tick still comes from the latest atomic backend snapshot.
    @discardableResult
    func ensureInteractivePlayerInputSession() -> Bool {
        let current = labSession.snapshot()
        if current.mode == .deterministic { return current.phase != .failed }
        guard let bridge = flyGym, bridge.playerInputV5_5Available else { return false }

        let generation = bridge.connectionGeneration
        lock.lock()
        let alreadyStarted = interactiveSessionStarted && interactiveSessionGeneration == generation
        if interactiveSessionStarted && interactiveSessionGeneration != generation {
            interactiveSessionStarted = false
            interactiveSessionGeneration = nil
        }
        lock.unlock()
        if alreadyStarted { return true }

        let tick = sim?.simMs ?? 0
        let start = labSession.beginNew(mode: .interactive, initialTick: tick)
        labSession.markInteractiveRunning(at: tick)
        guard bridge.sendSessionControl(action: "begin", sessionID: start.sessionID,
                                        epoch: start.epoch, simTick: tick,
                                        mode: .interactive) != nil else {
            labSession.fail("failed to queue interactive player-input session begin")
            return false
        }
        lock.lock()
        interactiveSessionStarted = true
        interactiveSessionGeneration = generation
        lock.unlock()
        ensureDeterministicDriver()
        return true
    }

    func noteLabAck(_ ack: LabAck?) {
        guard let ack, ack.ok else { return }
        labSession.noteAppliedCommand(epoch: ack.appliedEpoch, tick: ack.appliedTick)
    }

    func deterministicCapabilityDescription() -> String {
        guard sim != nil else { return "brain simulation unavailable" }
        guard let flyGym else { return "FlyGym bridge disabled" }
        guard flyGym.connected else { return "FlyGym bridge disconnected" }
        guard let hello = flyGym.serverHello() else { return "waiting for V4 capability handshake" }
        guard hello.supportsDeterministicV4 else { return "backend lacks V4 deterministic capability" }
        return String(format: "ready · %.3f ms physics · %d ms quantum",
                      (hello.physicsTimestepS ?? 0) * 1000,
                      FlyGymProtocolV4.experimentQuantumTicks)
    }

    /// Starts a new epoch-1 deterministic session. A new session intentionally
    /// resets brain + body dynamics to tick zero while preserving LabWorld
    /// objects/environment; later resets are epoch transitions inside it.
    @discardableResult
    func startDeterministicSession() -> String? {
        guard let sim, let flyGym else { return "brain/FlyGym unavailable" }
        guard flyGym.deterministicV4Available else { return deterministicCapabilityDescription() }

        lock.lock()
        deterministicEnabled = true
        localNeuralPaused = false
        deterministicSleepy = sleepy
        deterministicTempo = tempo
        deterministicActivity = activity
        lock.unlock()

        let start = labSession.beginNew(mode: .deterministic, initialTick: 0)
        simulationLock.lock()
        sim.reset()
        signalBuilder.reset()
        msAccumulator = 0
        loomOverride = 0
        windowLoomL = 0; windowLoomR = 0
        labOdorDriveL = 0; labOdorDriveR = 0
        labThermoWarmDrive = 0; labThermoCoolDrive = 0
        labWindCDrive = 0; labWindEDrive = 0
        var initial = signalBuilder.make(sim, dt: 0)
        initial.tempo = labTempoOverride ?? deterministicTempo
        initial.sleep = deterministicSleepy
        deterministicLatestSignals = initial
        simulationLock.unlock()

        guard flyGym.sendSessionControl(action: "begin", sessionID: start.sessionID,
                                        epoch: start.epoch, simTick: 0,
                                        mode: .deterministic) != nil else {
            labSession.fail("failed to queue deterministic begin")
            return "failed to queue deterministic begin"
        }
        ensureDeterministicDriver()
        return nil
    }

    private func ensureDeterministicDriver() {
        lock.lock()
        if deterministicTimer != nil { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: deterministicQueue)
        deterministicTimer = timer
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.driveDeterministicSession() }
        timer.resume()
    }

    func requestSessionPause() {
        deterministicQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.labSession.snapshot()
            if snap.mode == .deterministic {
                _ = self.labSession.requestPause()
                self.sendPauseControlIfReady()
            } else {
                self.lock.lock(); self.localNeuralPaused = true; self.lock.unlock()
                if self.interactiveSessionStarted {
                    _ = self.labSession.requestPause()
                    self.sendPauseControlIfReady()
                    self.ensureDeterministicDriver()
                } else {
                    self.beginOrPauseInteractiveSession()
                }
            }
        }
    }

    func requestSessionResume() {
        deterministicQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.labSession.snapshot()
            if snap.mode == .deterministic {
                guard self.labSession.requestResume(), let bridge = self.flyGym else { return }
                let s = self.labSession.snapshot()
                _ = bridge.sendSessionControl(action: "resume", sessionID: s.sessionID,
                                              epoch: s.epoch, simTick: s.simTick,
                                              mode: .deterministic)
            } else {
                guard self.interactiveSessionStarted,
                      self.labSession.requestResume(), let bridge = self.flyGym else {
                    // Legacy peers cannot provide the V4 body pause barrier. Keep
                    // the old local-only behavior rather than pretending an ACK
                    // exists, but never use this path for a negotiated V4 session.
                    self.lock.lock(); self.localNeuralPaused = false; self.lock.unlock()
                    return
                }
                let s = self.labSession.snapshot()
                _ = bridge.sendSessionControl(action: "resume", sessionID: s.sessionID,
                                              epoch: s.epoch, simTick: s.simTick,
                                              mode: .interactive)
                // Neural time stays frozen until the matching backend running
                // confirmation is accepted in driveDeterministicSession().
                self.ensureDeterministicDriver()
            }
        }
    }

    /// Schedules one logical V4 reset transaction. Body resets are paired with
    /// brain reset because MetalSim.reset() returns neural time to zero; keeping
    /// body time nonzero would immediately violate the lockstep tick invariant.
    /// World-only resets may preserve the current synchronized tick.
    @discardableResult
    func requestDeterministicReset(scopes requested: Set<String>,
                                   after completion: (() -> Void)? = nil) -> Bool {
        let snap = labSession.snapshot()
        guard snap.mode == .deterministic else { return false }
        var scopes = requested
        if scopes.contains("brain") || scopes.contains("body") {
            scopes.insert("brain"); scopes.insert("body")
        }
        deterministicQueue.async { [weak self] in
            guard let self else { return }
            self.pendingDeterministicResetScopes.formUnion(scopes)
            if let completion { self.deterministicResetCompletions.append(completion) }
            let before = self.labSession.snapshot()
            self.resumeAfterDeterministicReset = before.phase != .paused
            _ = self.labSession.requestPause()
            self.sendPauseControlIfReady()
            self.ensureDeterministicDriver()
        }
        return true
    }

    private func performDeterministicResetIfReady() {
        guard !pendingDeterministicResetScopes.isEmpty,
              !deterministicResetControlInFlight,
              labSession.snapshot().phase == .paused,
              let bridge = flyGym else { return }
        let scopes = pendingDeterministicResetScopes
        let resetClock = scopes.contains("brain") || scopes.contains("body")
        let targetTick = resetClock ? 0 : labSession.snapshot().simTick

        simulationLock.lock()
        if let sim {
            if scopes.contains("brain") {
                sim.reset()
                signalBuilder.reset()
                msAccumulator = 0
                loomOverride = 0
                windowLoomL = 0; windowLoomR = 0
                deterministicLatestSignals = BrainSignals()
            }
            if scopes.contains("modeled") || scopes.contains("world") {
                labWind = 0; labWindContinuous = false; labWindRemainingS = 0
                labWindDirectionDeg = 0
                labTemperatureC = 25; labTempoOverride = nil
                labThermosensoryEnabled = false
                labOdorDriveL = 0; labOdorDriveR = 0
                labThermoWarmDrive = 0; labThermoCoolDrive = 0
                labWindCDrive = 0; labWindEDrive = 0
                labTouchDrive = 0; labTouchRemainingS = 0
                sim.clearModeledSensoryDrives()
            }
        }
        simulationLock.unlock()

        guard let reset = labSession.beginReset(resetTick: targetTick) else { return }
        let backendScopes = scopes.filter { $0 == "body" || $0 == "world" }.sorted()
        guard bridge.sendSessionControl(action: "reset", sessionID: reset.sessionID,
                                        epoch: reset.epoch, simTick: reset.simTick,
                                        mode: .deterministic,
                                        resetScope: backendScopes) != nil else {
            labSession.fail("failed to queue coordinated reset")
            return
        }
        deterministicResetControlInFlight = true
    }

    private func beginOrPauseInteractiveSession() {
        guard let bridge = flyGym, bridge.deterministicV4Available else { return }
        let tick = sim?.simMs ?? 0
        let start = labSession.beginNew(mode: .interactive, initialTick: tick)
        labSession.markInteractiveRunning(at: tick)
        guard bridge.sendSessionControl(action: "begin", sessionID: start.sessionID,
                                        epoch: start.epoch, simTick: tick,
                                        mode: .interactive) != nil else {
            labSession.fail("failed to queue interactive pause session begin")
            return
        }
        interactiveSessionStarted = true
        interactiveSessionGeneration = bridge.connectionGeneration
        _ = labSession.requestPause()
        if let seq = bridge.sendSessionControl(action: "pause", sessionID: start.sessionID,
                                               epoch: start.epoch, simTick: tick,
                                               mode: .interactive) {
            _ = seq
            labSession.markPauseControlSent()
        }
        ensureDeterministicDriver()
    }

    private func sendPauseControlIfReady() {
        guard labSession.pauseControlReady(), let bridge = flyGym else { return }
        let s = labSession.snapshot()
        if bridge.sendSessionControl(action: "pause", sessionID: s.sessionID,
                                     epoch: s.epoch, simTick: s.simTick,
                                     mode: s.mode) != nil {
            labSession.markPauseControlSent()
        }
    }

    private func driveDeterministicSession() {
        guard let bridge = flyGym else { return }

        if let state = bridge.latestSessionState() {
            _ = labSession.acceptSessionState(state)
        }
        var snap = labSession.snapshot()
        if snap.mode == .interactive {
            lock.lock()
            localNeuralPaused = snap.phase != .running
            lock.unlock()
            return
        }

        if deterministicResetControlInFlight && snap.phase == .paused {
            deterministicResetControlInFlight = false
            pendingDeterministicResetScopes.removeAll()
            let completions = deterministicResetCompletions
            deterministicResetCompletions.removeAll()
            let shouldResume = resumeAfterDeterministicReset
            resumeAfterDeterministicReset = false
            if shouldResume, labSession.requestResume() {
                let resumed = labSession.snapshot()
                _ = bridge.sendSessionControl(action: "resume", sessionID: resumed.sessionID,
                                              epoch: resumed.epoch, simTick: resumed.simTick,
                                              mode: .deterministic)
            }
            if !completions.isEmpty {
                DispatchQueue.main.async {
                    for completion in completions { completion() }
                }
            }
            return
        }
        if !pendingDeterministicResetScopes.isEmpty && snap.phase == .running {
            _ = labSession.requestPause()
            sendPauseControlIfReady()
            snap = labSession.snapshot()
        }
        if !pendingDeterministicResetScopes.isEmpty && snap.phase == .paused {
            performDeterministicResetIfReady()
            return
        }

        if let expectedSeq = snap.outstandingStepSeq,
           let result = bridge.latestExperimentStepResult(), result.seq == expectedSeq {
            let startTick = snap.simTick
            if labSession.acceptStepResult(result) {
                var feedback = FlyGymBodyFeedback(result.body)
                feedback.receivedAt = result.receivedAt
                feedback.connectionGeneration = result.connectionGeneration

                simulationLock.lock()
                guard let sim else { simulationLock.unlock(); labSession.fail("brain simulation unavailable"); return }
                if sim.simMs != startTick {
                    simulationLock.unlock()
                    labSession.fail("neural tick \(sim.simMs) != body step start \(startTick)")
                    return
                }
                let fixedDt = CGFloat(LabSession.quantumSeconds)
                let signals = advanceNeuralQuantum(first: nil, bodyFeedback: feedback,
                                                   mouse: nil, dt: fixedDt,
                                                   exactSteps: LabSession.quantumTicks,
                                                   desktopInputs: false,
                                                   ambientSleepy: deterministicSleepy,
                                                   ambientTempo: deterministicTempo,
                                                   ambientActivity: deterministicActivity,
                                                   bodyMaxAge: .infinity)
                deterministicLatestSignals = signals ?? BrainSignals()
                let neuralEnd = sim.simMs
                simulationLock.unlock()

                let accepted = labSession.snapshot()
                if neuralEnd != accepted.simTick {
                    labSession.fail("neural end tick \(neuralEnd) != body end tick \(accepted.simTick)")
                    return
                }
                publishLabTelemetry(first: nil, bodyFeedback: feedback, signals: signals)
            }
        }

        snap = labSession.snapshot()
        if snap.phase == .pausing {
            sendPauseControlIfReady()
            return
        }
        guard snap.phase == .running, snap.outstandingStepSeq == nil else { return }
        // Local neural/sensory mutations are simulation-time commands. Apply
        // them only at a deterministic boundary before reserving the next body
        // quantum, never on a SceneKit/render callback and never after that body
        // quantum has already executed.
        simulationLock.lock()
        let boundaryActions = drainSimulationActions()
        for action in boundaryActions { action(self) }
        simulationLock.unlock()
        guard let reservation = labSession.reserveStep() else { return }
        if !bridge.sendExperimentStep(sessionID: reservation.sessionID,
                                      epoch: reservation.epoch,
                                      seq: reservation.seq,
                                      simTick: reservation.startTick,
                                      signals: deterministicLatestSignals) {
            labSession.cancelStepReservation(seq: reservation.seq)
        }
    }

    private func addFlyNow() {
        let hw = bounds.width / 2 - 100, hh = bounds.height / 2 - 100
        let fly = Fly(at: CGPoint(x: rnd(-hw...hw), y: rnd(-hh...hh)))
        scene.rootNode.addChildNode(fly.node)
        flies.append(fly)
    }

    func addFly() { enqueue { $0.addFlyNow() } }
    func removeFly() {
        enqueue { c in
            guard c.flies.count > 1 else { return }   // fly #1 carries the brain
            c.flies.removeLast().node.removeFromParentNode()
        }
    }
    func scareAll() {
        enqueue { c in
            c.loomOverride = 0.6   // real stimulus into the real circuit for fly #1
            for fly in c.flies.dropFirst() where fly.state != .flying {
                fly.startFlight(bounds: c.bounds)
            }
        }
    }
    func escapeTest() { enqueue { $0.loomOverride = 0.6 } }
    func setMouse(_ p: CGPoint?) { lock.lock(); mouseScene = p; lock.unlock() }

    func setTerrain(_ ledges: [Ledge]) { enqueue { $0.terrain = ledges } }

    // the fly moved to a different display: new bounds + camera extent
    func retarget(size: CGSize) {
        enqueue { c in
            c.bounds = size
            c.terrain = []   // stale until the next window poll
            if let camNode = c.scene.rootNode.childNode(withName: "camera", recursively: false) {
                camNode.camera?.orthographicScale = Double(size.height / 2)
            }
            // keep flies inside the new display
            for fly in c.flies {
                fly.ledge = nil
                fly.pos.x = clampf(fly.pos.x, -size.width / 2 + 40, size.width / 2 - 40)
                fly.pos.y = clampf(fly.pos.y, -size.height / 2 + 40, size.height / 2 - 40)
            }
        }
    }
    func setAmbient(typing: CGFloat, sleepy: Bool, tempo: CGFloat, activity: Float) {
        enqueue { c in
            c.typingLevel = typing; c.sleepy = sleepy; c.tempo = tempo; c.activity = activity
        }
    }
    func flyPosition() -> CGPoint { lock.lock(); defer { lock.unlock() }; return lastFlyPos }

    func labApplyWind(strength: Float, directionDeg: Double = 0,
                      durationMs: Int, continuous: Bool = false) {
        enqueueSimulation { c in
            guard c.sim != nil else { return }
            // With a live FlyGym bridge, Python LabWorld is authoritative for
            // stimulus onset/expiry. Do not pre-activate the neural model from
            // the UI command before the backend has actually applied it.
            guard c.flyGym == nil else { return }
            c.labWind = min(1, max(0, strength))
            c.labWindDirectionDeg = directionDeg.isFinite ? directionDeg : 0
            c.labWindContinuous = continuous
            let duration = max(1, min(10_000, durationMs))
            c.labWindRemainingS = continuous ? 0 : Double(duration) / 1000.0
        }
    }

    func labStopWind() {
        enqueueSimulation { c in
            c.labWind = 0; c.labWindContinuous = false
            c.labWindRemainingS = 0
            c.labWindCDrive = 0; c.labWindEDrive = 0
            c.sim?.setModeledSensoryDrive(.windC, indices: c.sim?.windC ?? [], strength: 0)
            c.sim?.setModeledSensoryDrive(.windE, indices: c.sim?.windE ?? [], strength: 0)
        }
    }

    func labApplyTouch(strength: Float, durationMs: Int) {
        enqueueSimulation { c in
            guard c.sim != nil else { return }
            // Same rule as wind: when FlyGym is attached, the body packet's
            // active touch state is the single source of truth.
            guard c.flyGym == nil else { return }
            let s = min(1, max(0, strength))
            // This is a generic modeled startle/touch channel, not a claim that
            // the selected physical body part maps to these JO-A/B-like cells.
            // Unlike direct-neural probes it is sensory-gated and maintained as
            // a continuous modeled current for the requested stimulus window.
            c.labTouchDrive = 0.02 + 0.18 * s
            let duration = max(1, min(1_000, durationMs))
            c.labTouchRemainingS = Double(duration) / 1000.0
        }
    }

    func labSetTemperature(celsius: Double, modeledPhysiology: Bool = true,
                           flywireSensory: Bool = false) {
        enqueueSimulation { c in
            let temp = min(40, max(10, celsius))
            c.labTemperatureC = temp
            c.labTempoOverride = modeledPhysiology ? SensoryModel.locomotorTempo(celsius: temp) : nil
            c.labThermosensoryEnabled = flywireSensory
            if !flywireSensory {
                c.labThermoWarmDrive = 0; c.labThermoCoolDrive = 0
                if let sim = c.sim {
                    sim.setModeledSensoryDrive(.thermoWarm, indices: sim.thermoWarm, strength: 0)
                    sim.setModeledSensoryDrive(.thermoCool, indices: sim.thermoCool, strength: 0)
                }
            }
        }
    }

    func labResetBrain() {
        enqueueSimulation { c in
            c.sim?.reset()
            c.signalBuilder.reset()
            c.msAccumulator = 0
            c.loomOverride = 0
            c.windowLoomL = 0; c.windowLoomR = 0
            // Brain reset clears neural state, not the physical/environmental
            // experiment. Active wind/touch/temperature are re-applied on the
            // next render step from their preserved environment state.
            c.labOdorDriveL = 0; c.labOdorDriveR = 0
            c.labThermoWarmDrive = 0; c.labThermoCoolDrive = 0
            c.labWindCDrive = 0; c.labWindEDrive = 0
        }
    }

    func labResetModeledStimuli() {
        enqueueSimulation { c in
            c.labWind = 0
            c.labWindContinuous = false
            c.labWindRemainingS = 0
            c.labWindDirectionDeg = 0
            c.labTemperatureC = 25
            c.labTempoOverride = nil
            c.labThermosensoryEnabled = false
            c.labOdorDriveL = 0; c.labOdorDriveR = 0
            c.labThermoWarmDrive = 0; c.labThermoCoolDrive = 0
            c.labWindCDrive = 0; c.labWindEDrive = 0
            c.labTouchDrive = 0
            c.labTouchRemainingS = 0
            c.sim?.clearModeledSensoryDrives()
        }
    }

    func labStimulatePopulation(_ role: String, strength: Float, durationMs: Int) {
        enqueueSimulation { c in
            guard let sim = c.sim else { return }
            let indices = labPopulationIndices(sim, role: role)
            guard !indices.isEmpty else { return }
            sim.stimulate(indices, strength: min(2, max(0, strength)),
                          durationMs: max(1, min(60_000, durationMs)))
        }
    }

    func labTelemetry() -> LabTelemetry {
        lock.lock(); defer { lock.unlock() }
        return labSnapshot
    }

    private func publishLabTelemetry(first: Fly?, bodyFeedback: FlyGymBodyFeedback?,
                                     signals: BrainSignals?) {
        var t = LabTelemetry()
        let session = labSession.snapshot()
        t.sessionID = session.sessionID
        t.sessionEpoch = session.epoch
        t.sessionSimTick = session.simTick
        t.sessionMode = session.mode.rawValue
        t.sessionPhase = session.phase.rawValue
        t.sessionPaused = session.isPaused
        t.bodyResultTick = session.lastBodyResultTick ?? -1
        t.temperatureC = labTemperatureC
        if let sim {
            t.simMs = sim.simMs
            t.ratePop = Double(sim.ratePop); t.rateLoom = Double(sim.rateLoom)
            t.rateDNaL = Double(sim.rateDNaL); t.rateDNaR = Double(sim.rateDNaR)
            t.rateMDN = Double(sim.rateMDN); t.rateFwd = Double(sim.rateFwd)
            t.rateGroom = Double(sim.rateGroom); t.rateEscW = Double(sim.rateEscW)
            t.loomL = Double(sim.loomL); t.loomR = Double(sim.loomR)
            t.airPuff = Double(sim.airPuff); t.gaitDrive = Double(sim.gaitDrive)
            t.odorDriveL = Double(labOdorDriveL); t.odorDriveR = Double(labOdorDriveR)
            t.thermoWarmDrive = Double(labThermoWarmDrive); t.thermoCoolDrive = Double(labThermoCoolDrive)
            t.windCDrive = Double(labWindCDrive); t.windEDrive = Double(labWindEDrive)
            t.applyReceptorRates(sim)
        }
        t.applyBodyFeedback(bodyFeedback)
        t.applyBrainSignals(signals)
        if let first { t.flyState = String(describing: first.state) }
        lock.lock(); labSnapshot = t; lock.unlock()
    }

    // a window appeared near the fly: a real looming object
    func injectWindowLoom(strength: CGFloat, at p: CGPoint) {
        enqueue { c in
            guard let fly = c.flies.first else { return }
            let rel = CGPoint(x: p.x - fly.pos.x, y: p.y - fly.pos.y)
            let dist = max(1, hypot(rel.x, rel.y))
            let f = CGPoint(x: cos(fly.heading), y: sin(fly.heading))
            let crossZ = (f.x * rel.y - f.y * rel.x) / dist
            c.windowLoomL = max(c.windowLoomL, Float(strength * clampf(0.5 + 0.5 * crossZ, 0.12, 1)))
            c.windowLoomR = max(c.windowLoomR, Float(strength * clampf(0.5 - 0.5 * crossZ, 0.12, 1)))
        }
    }

    // a global mouse click: a tap on the fly's substrate -> sensory pathway
    func injectTap(at p: CGPoint) {
        enqueue { c in
            guard let sim = c.sim, let fly = c.flies.first else { return }
            let d = hypot(p.x - fly.pos.x, p.y - fly.pos.y)
            let strength = Float(clampf(1 - d / 520, 0, 1))
            if strength > 0.05 {
                // This is a sensory event, not a direct-neural probe, so apply
                // the same sleep/sensory gate used by the other modeled senses.
                sim.stimulate(sim.sens,
                              strength: (0.15 + strength * 0.35) * sim.sensoryGate,
                              durationMs: 130)
            }
        }
    }

    // Cursor kinematics -> looming drive for each eye of fly #1 + air puff.
    // This is the sensory transduction step; everything downstream of the
    // LC4/LPLC2 population is the real connectome.
    private func computeLoom(fly: Fly, mouse: CGPoint?, dt: CGFloat) -> (l: Float, r: Float, puff: Float) {
        guard let m = mouse else { return (0, 0, 0) }
        if let pm = prevMouse, dt > 0 {
            let v = CGPoint(x: (m.x - pm.x) / dt, y: (m.y - pm.y) / dt)
            mouseVel.x += (v.x - mouseVel.x) * 0.4
            mouseVel.y += (v.y - mouseVel.y) * 0.4
        }
        prevMouse = m
        let rel = CGPoint(x: m.x - fly.pos.x, y: m.y - fly.pos.y)
        let dist = max(20, hypot(rel.x, rel.y))
        // radial approach speed (positive = cursor closing in)
        let approach = -(rel.x * mouseVel.x + rel.y * mouseVel.y) / dist
        // loom ~ rate of angular expansion, attenuated with distance
        var loom = clampf(approach / dist * 6, 0, 1) * clampf(1 - dist / 800, 0, 1)
        loom += clampf((130 - dist) / 130, 0, 1) * 0.5          // hovering close = big object
        loom = clampf(loom + loomOverride, 0, 1)
        // split between eyes by bearing relative to heading
        let f = CGPoint(x: cos(fly.heading), y: sin(fly.heading))
        let rd = CGPoint(x: rel.x / dist, y: rel.y / dist)
        let crossZ = f.x * rd.y - f.y * rd.x                     // >0: threat on the left
        let lw = clampf(0.5 + 0.5 * crossZ, 0.12, 1)
        let rw = clampf(0.5 - 0.5 * crossZ, 0.12, 1)
        let puff = clampf(hypot(mouseVel.x, mouseVel.y) / 1500, 0, 1) * clampf(1 - dist / 500, 0, 1)
        return (Float(loom * lw), Float(loom * rw), Float(puff))
    }

    /// Advances the neural model from one authoritative sensory snapshot. The
    /// caller owns `simulationLock`. Interactive mode passes a render-derived
    /// step count; V4 deterministic mode passes exactly 20 ticks and disables
    /// unscheduled desktop/window input so wall/render timing cannot enter the
    /// experiment timeline.
    private func advanceNeuralQuantum(first: Fly?, bodyFeedback: FlyGymBodyFeedback?,
                                      mouse: CGPoint?, dt: CGFloat,
                                      exactSteps: Int?, desktopInputs: Bool,
                                      ambientSleepy: Bool, ambientTempo: CGFloat,
                                      ambientActivity: Float,
                                      bodyMaxAge: TimeInterval = FlyGymBridge.bodyFreshMaxAge) -> BrainSignals? {
        guard let sim else { return nil }

        sim.sensoryGate = ambientSleepy ? 0.55 : 1
        if let fb = bodyFeedback {
            let backend = SensoryModel.backendState(fb)
            labWind = backend.wind
            labWindDirectionDeg = backend.windDirectionDeg
            labWindContinuous = false
            labWindRemainingS = 0
            labTouchDrive = backend.touchDrive
            labTouchRemainingS = 0
        } else if flyGym != nil {
            labWind = 0; labWindContinuous = false; labWindRemainingS = 0
            labTouchDrive = 0; labTouchRemainingS = 0
        } else {
            let localAdvance = Double(dt)
            if !labWindContinuous && labWind > 0 && localAdvance > 0 {
                labWindRemainingS = max(0, labWindRemainingS - localAdvance)
                if labWindRemainingS <= 0 { labWind = 0 }
            }
            if labTouchDrive > 0 && localAdvance > 0 {
                labTouchRemainingS = max(0, labTouchRemainingS - localAdvance)
                if labTouchRemainingS <= 0 { labTouchDrive = 0 }
            }
        }

        let sensory: (l: Float, r: Float, puff: Float)
        if desktopInputs, let first {
            sensory = computeLoom(fly: first, mouse: mouse, dt: dt)
            let decayF = Float(exp(-4 * Double(dt)))
            windowLoomL *= decayF
            windowLoomR *= decayF
        } else {
            sensory = (0, 0, 0)
            // Window/cursor events are wall-time desktop inputs and therefore do
            // not participate in deterministic experiment mode.
            windowLoomL = 0; windowLoomR = 0
        }

        let flyGymLoom = FlyGymSensoryMap.looming(body: bodyFeedback, maxAge: bodyMaxAge)
        sim.loomL = max(sensory.l, windowLoomL, flyGymLoom.l)
        sim.loomR = max(sensory.r, windowLoomR, flyGymLoom.r)
        sim.airPuff = max(sensory.puff, desktopInputs ? Float(typingLevel * 0.30) : 0)

        let odor = FlyGymSensoryMap.foodOdor(body: bodyFeedback, maxAge: bodyMaxAge)
        labOdorDriveL = SensoryModel.odorCurrent(odor.l, sensoryGate: sim.sensoryGate)
        labOdorDriveR = SensoryModel.odorCurrent(odor.r, sensoryGate: sim.sensoryGate)
        sim.setModeledSensoryDrive(.foodOdorLeft, indices: sim.foodOdorLeft, strength: labOdorDriveL)
        sim.setModeledSensoryDrive(.foodOdorRight, indices: sim.foodOdorRight, strength: labOdorDriveR)

        let thermal = SensoryModel.thermal(celsius: labTemperatureC,
                                           enabled: labThermosensoryEnabled,
                                           sensoryGate: sim.sensoryGate)
        labThermoWarmDrive = thermal.warm
        labThermoCoolDrive = thermal.cool
        sim.setModeledSensoryDrive(.thermoWarm, indices: sim.thermoWarm, strength: labThermoWarmDrive)
        sim.setModeledSensoryDrive(.thermoCool, indices: sim.thermoCool, strength: labThermoCoolDrive)

        let fallbackHeading = first.map { Double($0.heading) } ?? 0
        let bodyHeading = FlyGymSensoryMap.heading(body: bodyFeedback, maxAge: bodyMaxAge) ?? fallbackHeading
        let windDrive = SensoryModel.wind(strength: labWind,
                                          directionDeg: labWindDirectionDeg,
                                          bodyHeading: bodyHeading,
                                          sensoryGate: sim.sensoryGate)
        labWindCDrive = windDrive.c
        labWindEDrive = windDrive.e
        sim.setModeledSensoryDrive(.windC, indices: sim.windC, strength: labWindCDrive)
        sim.setModeledSensoryDrive(.windE, indices: sim.windE, strength: labWindEDrive)

        let touchDrive = SensoryModel.touch(sourceDrive: labTouchDrive,
                                            sensoryGate: sim.sensoryGate)
        sim.setModeledSensoryDrive(.touchGeneric, indices: sim.sens, strength: touchDrive)

        if let fb = bodyFeedback {
            let fallbackDrive = first.map { Float($0.walkingIntensity) } ?? 0
            let fallbackPhase = first.map { Float($0.gaitPhasePublic) } ?? 0
            sim.gaitDrive = FlyGymSensoryMap.gaitDrive(procedural: fallbackDrive, body: fb,
                                                       maxAge: bodyMaxAge)
            sim.gaitPhase = FlyGymSensoryMap.gaitPhase(procedural: fallbackPhase, body: fb,
                                                       maxAge: bodyMaxAge)
        } else if let first {
            sim.gaitDrive = Float(first.walkingIntensity)
            sim.gaitPhase = Float(first.gaitPhasePublic)
        } else {
            sim.gaitDrive = 0; sim.gaitPhase = 0
        }

        sim.activityScale = (1 - (1 - ambientActivity) * 0.35) * (ambientSleepy ? 0.75 : 1)
        loomOverride = max(0, loomOverride - dt * 1.2)

        if let exactSteps {
            sim.step(exactSteps)
        } else {
            msAccumulator += Double(dt) * 1000
            let steps = min(50, Int(msAccumulator))
            msAccumulator -= Double(steps)
            sim.step(steps)
        }

        var s = signalBuilder.make(sim, dt: dt)
        s.tempo = labTempoOverride ?? ambientTempo
        s.sleep = ambientSleepy
        return s
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime t: TimeInterval) {
        advanceFrame(at: t, desktopInputs: true)
    }

    func advanceFrame(at t: TimeInterval, desktopInputs: Bool) {
        if fpsLog {
            if fpsWindowStart == 0 { fpsWindowStart = t }
            fpsFrames += 1
            if t - fpsWindowStart >= 5 {
                fputs(String(format: "fps: %.1f\n", Double(fpsFrames) / (t - fpsWindowStart)), stderr)
                fpsFrames = 0
                fpsWindowStart = t
            }
        }
        lock.lock()
        let actions = pending; pending.removeAll()
        let mouse = mouseScene
        let deterministic = deterministicEnabled
        let neuralPaused = localNeuralPaused
        lock.unlock()
        for a in actions { a(self) }

        guard let last = lastTime else { lastTime = t; return }
        let dt = CGFloat(min(0.05, max(0, t - last)))
        lastTime = t

        var signals: BrainSignals? = nil
        var frameBodyFeedback: FlyGymBodyFeedback? = nil
        if deterministic {
            signals = deterministicLatestSignals
            frameBodyFeedback = flyGym?.latestBody(maxAge: 3600)
        } else if !neuralPaused, sim != nil, let first = flies.first {
            simulationLock.lock()
            let simActions = drainSimulationActions()
            for action in simActions { action(self) }
            let bodyFeedback = flyGym?.latestBody()
            frameBodyFeedback = bodyFeedback
            signals = advanceNeuralQuantum(first: first, bodyFeedback: bodyFeedback,
                                           mouse: mouse, dt: dt, exactSteps: nil,
                                           desktopInputs: desktopInputs,
                                           ambientSleepy: sleepy,
                                           ambientTempo: tempo,
                                           ambientActivity: activity)
            if let s = signals, let fg = flyGym, let sim {
                fg.sendBrain(s, simMs: sim.simMs)
            }
            simulationLock.unlock()
        }

        for (i, fly) in flies.enumerated() {
            fly.terrain = terrain
            fly.update(dt: dt, bounds: bounds, mouse: mouse, signals: i == 0 ? signals : nil)
        }
        if let first = flies.first {
            lock.lock(); lastFlyPos = first.pos; lock.unlock()
        }
        if !deterministic {
            publishLabTelemetry(first: flies.first, bodyFeedback: frameBodyFeedback, signals: signals)
        }
    }

    // Headless V4 acceptance hooks. These deliberately call the same production
    // deterministic neural primitive used by driveDeterministicSession(); they do
    // not introduce a second stepping implementation.
    func prepareV4TimingTest(seed: UInt32) {
        simulationLock.lock()
        sim?.reset(seed: seed)
        signalBuilder.reset()
        msAccumulator = 0
        loomOverride = 0
        windowLoomL = 0; windowLoomR = 0
        labWind = 0; labWindDirectionDeg = 0; labWindContinuous = false; labWindRemainingS = 0
        labTouchDrive = 0; labTouchRemainingS = 0
        labTemperatureC = 25; labTempoOverride = nil; labThermosensoryEnabled = false
        labOdorDriveL = 0; labOdorDriveR = 0
        labThermoWarmDrive = 0; labThermoCoolDrive = 0
        labWindCDrive = 0; labWindEDrive = 0
        sim?.clearModeledSensoryDrives()
        deterministicLatestSignals = BrainSignals()
        simulationLock.unlock()
        lock.lock()
        deterministicEnabled = true
        localNeuralPaused = false
        deterministicSleepy = false
        deterministicTempo = 1
        deterministicActivity = 1
        simulationPending.removeAll(keepingCapacity: true)
        lock.unlock()
        lastTime = nil
    }

    func advanceV4TimingQuantumForTesting(_ feedback: FlyGymBodyFeedback) -> BrainSignals? {
        simulationLock.lock(); defer { simulationLock.unlock() }
        let s = advanceNeuralQuantum(first: nil, bodyFeedback: feedback,
                                     mouse: nil, dt: CGFloat(LabSession.quantumSeconds),
                                     exactSteps: LabSession.quantumTicks,
                                     desktopInputs: false,
                                     ambientSleepy: false, ambientTempo: 1,
                                     ambientActivity: 1,
                                     bodyMaxAge: .infinity)
        deterministicLatestSignals = s ?? BrainSignals()
        return s
    }
}

// MARK: - App

enum ApplicationQuitAfterRecorderDrain: Equatable {
    case terminate
    case requireFailureConfirmation(path: String?, message: String)
}

func applicationQuitAfterRecorderDrain(_ outcome: ExperimentRecorderStopOutcome) -> ApplicationQuitAfterRecorderDrain {
    switch outcome {
    case .saved, .notRecording:
        return .terminate
    case .failed(let path, let message):
        return .requireFailureConfirmation(path: path, message: message)
    }
}

func resolveApplicationQuitAfterRecorderDrain(
    _ outcome: ExperimentRecorderStopOutcome,
    confirmFailure: @escaping (String?, String, @escaping (Bool) -> Void) -> Void,
    reply: @escaping (Bool) -> Void
) {
    switch applicationQuitAfterRecorderDrain(outcome) {
    case .terminate:
        reply(true)
    case .requireFailureConfirmation(let path, let message):
        confirmFailure(path, message, reply)
    }
}

/// How this process presents itself. The packaged app and `--lab` open the
/// one-window Lab with an app-owned backend on a private port (`--mock` /
/// `--viewer` pick the backend flavor); `--flygym` opens the same window against
/// an external bridge on 17841; no flag is the original desktop-overlay fly.
enum LaunchMode: Equatable {
    case desktopOverlay
    case lab(service: FlyGymServiceMode?)   // nil: external bridge

    static let current: LaunchMode = {
        let args = CommandLine.arguments
        if args.contains("--flygym") { return .lab(service: nil) }
        guard args.contains("--lab") || Bundle.main.bundleURL.pathExtension == "app" else {
            return .desktopOverlay
        }
        if args.contains("--mock") { return .lab(service: .mock) }
        return .lab(service: args.contains("--viewer") ? .viewer : .headless)
    }()
}

/// Standard App / Edit / Window menus: text fields need Edit for copy/paste,
/// and the key equivalents (⌘Q, ⌘W, ⌘M, ⌃⌘F) follow the platform.
func makeLabMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        main.addItem(holder)
    }
    func item(_ title: String, _ action: Selector, _ key: String,
              _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = modifiers
        return it
    }
    submenu("Virtual Fly Lab", [
        item(L("Hide Virtual Fly Lab", "Virtual Fly Lab 가리기"), #selector(NSApplication.hide(_:)), "h"),
        .separator(),
        item(L("Quit Virtual Fly Lab", "Virtual Fly Lab 종료"), #selector(NSApplication.terminate(_:)), "q")
    ])
    submenu(L("Edit", "편집"), [
        item(L("Undo", "실행 취소"), Selector(("undo:")), "z"),
        item(L("Redo", "실행 복귀"), Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item(L("Cut", "오려두기"), #selector(NSText.cut(_:)), "x"),
        item(L("Copy", "복사하기"), #selector(NSText.copy(_:)), "c"),
        item(L("Paste", "붙여넣기"), #selector(NSText.paste(_:)), "v"),
        item(L("Select All", "전체 선택"), #selector(NSText.selectAll(_:)), "a")
    ])
    submenu(L("Language", "언어"), LabLanguage.allCases.map { language in
        let it = NSMenuItem(title: language.menuTitle, action: #selector(LabLanguageMenu.choose(_:)),
                            keyEquivalent: "")
        it.target = LabLanguageMenu.shared
        it.representedObject = language.rawValue
        it.state = language == LabLanguage.current ? .on : .off
        return it
    })
    let window = [
        item(L("Minimize", "최소화"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(L("Zoom", "확대/축소"), #selector(NSWindow.performZoom(_:)), ""),
        item(L("Enter Full Screen", "전체 화면 시작"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    ]
    submenu(L("Window", "윈도우"), window)
    NSApplication.shared.windowsMenu = main.items.last?.submenu
    return main
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // only offer the display hop when there is somewhere to hop to
        moveDisplayItem?.isHidden = NSScreen.screens.count < 2
    }

    var window: NSWindow!
    var scnView: SCNView!
    var coordinator: Coordinator!
    var statusItem: NSStatusItem!
    var mouseTimer: Timer?
    var windowTimer: Timer?
    var integratedSimulationTimer: Timer?
    var clickMonitor: Any?
    let windowSense = WindowSense()
    var typingLevel: CGFloat = 0
    var paused = false
    var brainWC: BrainWindowController?
    var labWC: LabWindowController?
    var labConnectome: Connectome?
    var flyGymBridge: FlyGymBridge?
    private var flyGymService: FlyGymService?
    var dataInfo = "no data — run etl.py"
    var screenFrame = NSRect.zero
    var moveDisplayItem: NSMenuItem?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { fatalError("no screen") }
        let frame = screen.frame
        screenFrame = frame

        var sim: MetalSim? = nil
        let spikeBus = SpikeBus()
        var connectome: Connectome? = nil
        if let c = loadConnectome(),
           let s = MetalSim(connectome: c, spikeBus: spikeBus, seed: launchSeed()) {
            sim = s
            connectome = c
            labConnectome = c
            dataInfo = "\(c.summary) · \(s.deviceName)"
        }

        coordinator = Coordinator(bounds: frame.size, sim: sim)
        if case .lab(let serviceMode) = LaunchMode.current {
            startIntegratedLab(serviceMode: serviceMode)
            return
        }

        window = NSWindow(contentRect: frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        scnView = SCNView(frame: NSRect(origin: .zero, size: frame.size))
        scnView.scene = coordinator.scene
        scnView.backgroundColor = .clear
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X
        scnView.preferredFramesPerSecond = 120   // ProMotion; caps at display refresh
        if ProcessInfo.processInfo.environment["DESKTOPFLY_FPS"] != nil {
            fputs("display max fps: \(NSScreen.main?.maximumFramesPerSecond ?? 0)\n", stderr)
        }
        scnView.delegate = coordinator
        scnView.isPlaying = true
        window.contentView = scnView
        window.orderFrontRegardless()

        if let sim = sim, let c = connectome {
            let wc = BrainWindowController(connectome: c, sim: sim, screen: screen)
            wc.show()
            brainWC = wc
        }

        setupStatusItem()

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            self.coordinator.setMouse(CGPoint(x: loc.x - self.screenFrame.midX,
                                              y: loc.y - self.screenFrame.midY))
            // typing = substrate vibration (when, never what)
            let keyIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            self.typingLevel += ((keyIdle < 0.6 ? 1.0 : 0.0) - self.typingLevel) * 0.15
            // circadian hour + sleep from user idleness + thermal tempo
            let idle = userIdleSeconds()
            let now = Date()
            let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
            let h = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60
            let sleepy = (idle > 600 && (h >= 22 || h < 6)) || idle > 1800
            self.coordinator.setAmbient(typing: self.typingLevel, sleepy: sleepy,
                                        tempo: thermalTempo(), activity: circadianActivity(hour: h))
        }

        // window terrain + new-window looms, ~1.4 Hz
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snap = self.windowSense.poll(screen: self.screenFrame)
            self.coordinator.setTerrain(snap.ledges)
            let flyPos = self.coordinator.flyPosition()
            for nw in snap.newWindows {
                let d = hypot(nw.center.x - flyPos.x, nw.center.y - flyPos.y)
                let strength = clampf(1 - d / 480, 0, 1) * 0.75
                if strength > 0.08 {
                    self.coordinator.injectWindowLoom(strength: strength, at: nw.center)
                }
            }
        }

        // global mouse clicks = taps on the fly's substrate (mouse monitors are permission-free)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            self.coordinator.injectTap(at: CGPoint(x: loc.x - self.screenFrame.midX,
                                                   y: loc.y - self.screenFrame.midY))
        }

        // if the current display disappears, retreat to the main screen
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if !NSScreen.screens.contains(where: { $0.frame == self.screenFrame }),
               let main = NSScreen.main {
                self.move(to: main)
            }
        }
    }

    func move(to screen: NSScreen) {
        screenFrame = screen.frame
        window.setFrame(screen.frame, display: true)
        scnView.frame = NSRect(origin: .zero, size: screen.frame.size)
        coordinator.retarget(size: screen.frame.size)
        brainWC?.move(to: screen)
    }

    @objc func moveToNextDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let idx = screens.firstIndex(where: { $0.frame == screenFrame }) ?? 0
        move(to: screens[(idx + 1) % screens.count])
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪰"
        let menu = NSMenu()
        menu.addItem(withTitle: "Desktop Fly", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: dataInfo, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            return it
        }
        menu.addItem(item("Pause", #selector(togglePause(_:)), "p"))
        menu.addItem(item("Show/Hide Brain", #selector(toggleBrain), "b"))
        menu.addItem(item("Virtual Fly Lab…", #selector(showLab), "l"))
        menu.addItem(item("Escape Test (loom)", #selector(escapeTest), "e"))
        let move = item("Move to Next Display", #selector(moveToNextDisplay), "d")
        menu.addItem(move)
        moveDisplayItem = move
        menu.delegate = self
        menu.addItem(item("Add Fly", #selector(addFly), "a"))
        menu.addItem(item("Remove Fly", #selector(removeFly), "r"))
        menu.addItem(item("Scare Flies", #selector(scareAll), "s"))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(requestQuit), "q"))
        statusItem.menu = menu
    }

    @objc func requestQuit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let labWC, labWC.hasRecordingToFinish else { return .terminateNow }

        terminationPending = true
        labWC.prepareForApplicationTermination { outcome in
            if case .saved(let path) = outcome {
                fputs("lab recorder: quit drain saved \(path)\n", stderr)
            } else if case .failed(let path, let message) = outcome {
                fputs("lab recorder: quit drain failed \(message) \(path ?? "")\n", stderr)
            }
            resolveApplicationQuitAfterRecorderDrain(
                outcome,
                confirmFailure: { path, message, decision in
                    labWC.presentTerminationSaveFailure(path: path, message: message, completion: decision)
                },
                reply: { allowTermination in
                    self.terminationPending = false
                    sender.reply(toApplicationShouldTerminate: allowTermination)
                }
            )
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the cursor frozen if Participate capture was active.
        CGAssociateMouseAndMouseCursorPosition(1)
        integratedSimulationTimer?.invalidate()
        flyGymBridge?.stop()
        flyGymService?.stop()
    }

    /// The one-window Lab: no overlay, no floating brain panel, no global
    /// mouse/click/window senses. The brain and body step from a main-run-loop
    /// timer in `.common` mode so resizing, scrolling or an open menu never
    /// freezes the simulation behind the window.
    private func startIntegratedLab(serviceMode: FlyGymServiceMode?) {
        let port: UInt16
        if let serviceMode {
            let service = FlyGymService(mode: serviceMode)
            service.start()
            flyGymService = service
            port = service.port
        } else {
            port = 17841   // external bridge (run_flygym.sh --bridge-only, diagnostics)
        }
        let fg = FlyGymBridge(port: port)
        if port != 0 { fg.start() }
        coordinator.flyGym = fg
        flyGymBridge = fg
        fputs("flygym: client for 127.0.0.1:\(port)\(serviceMode == nil ? " (external bridge)" : "")\n", stderr)

        labWC = LabWindowController(coordinator: coordinator, bridge: fg,
                                    connectome: labConnectome, service: flyGymService)
        labWC?.show()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.coordinator.advanceFrame(at: ProcessInfo.processInfo.systemUptime,
                                           desktopInputs: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        integratedSimulationTimer = timer
    }

    @objc func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        if paused { coordinator.requestSessionPause() }
        else { coordinator.requestSessionResume() }
        // Keep SceneKit rendering while paused so telemetry/status and the lab UI
        // remain live. V4 pause freezes simulation clocks, not presentation.
        coordinator.lastTime = nil
        sender.title = paused ? "Resume" : "Pause"
    }
    @objc func toggleBrain() {
        guard let wc = brainWC else { return }
        wc.isVisible ? wc.hide() : wc.show()
    }
    @objc func showLab() {
        if labWC == nil { labWC = LabWindowController(coordinator: coordinator, bridge: flyGymBridge,
                                                     connectome: labConnectome) }
        labWC?.show()
    }
    @objc func escapeTest() { coordinator.escapeTest() }
    @objc func addFly() { coordinator.addFly() }
    @objc func removeFly() { coordinator.removeFly() }
    @objc func scareAll() { coordinator.scareAll() }
}

// MARK: - Entry point

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot") {
    runSnapshot(path: args.count > i + 1 ? args[i + 1] : "preview.png")
    exit(0)
}
if let i = args.firstIndex(of: "--brainshot") {
    runBrainshot(path: args.count > i + 1 ? args[i + 1] : "brain.png")
    exit(0)
}
// Suites compare English interface strings; never read the saved language.
if args.contains(where: { $0.hasSuffix("test") || $0.hasSuffix("loop") }) {
    LabLanguage.pinEnglishForTests()
}
if args.contains("--gpucheck") {
    runGPUCheck()
}
if args.contains("--bridgetest") {
    runBridgeTest()
}
if args.contains("--labtest") {
    runLabTest()
}
if args.contains("--v4test") || args.contains("--v4sessiontest") {
    runV4SessionTest()
}
if args.contains("--v4loop") {
    runV4LoopTest()
}
if args.contains("--v4timingtest") {
    runV4TimingTest()
}
if args.contains("--bridgeloop") {
    runBridgeLoopTest()
}
if args.contains("--labloop") {
    runLabLoopTest()
}
if args.contains("--inputprobe") {
    runInputProbe()
}
if args.contains("--interactionloop") {
    runInteractionLoopTest()
}
if args.contains("--simtest") {
    runSimtest()
}
if args.contains("--behaviortest") {
    runBehaviorTest()
}
if let i = args.firstIndex(of: "--brainstats") {
    runBrainStats(seconds: args.count > i + 1 ? Int(args[i + 1]) ?? 5 : 5)
}

let app = NSApplication.shared
if case .lab = LaunchMode.current {
    app.setActivationPolicy(.regular)
    app.mainMenu = makeLabMainMenu()
    NotificationCenter.default.addObserver(forName: .labLanguageChanged, object: nil, queue: .main) { _ in
        NSApp.mainMenu = makeLabMainMenu()
    }
} else {
    app.setActivationPolicy(.accessory)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
