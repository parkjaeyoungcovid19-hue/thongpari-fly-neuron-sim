import Cocoa
import SceneKit

// MARK: - Coordinator

final class Coordinator: NSObject, SCNSceneRendererDelegate {
    var lastInteractiveWorldTick: Int?
    let scene: SCNScene
    var bounds: CGSize
    var flies: [Fly] = []
    var lastTime: TimeInterval?
    var mouseScene: CGPoint?
    let lock = NSLock()
    private var pending: [(Coordinator) -> Void] = []
    private var simulationPending: [(Coordinator) -> Void] = []
    let simulationLock = NSLock()
    let deterministicQueue = DispatchQueue(label: "ThongpariFlyNeuronSim.v4-deterministic")
    var deterministicTimer: DispatchSourceTimer?
    let labSession = LabSession()
    var deterministicEnabled = false
    var localNeuralPaused = false
    var deterministicLatestSignals = BrainSignals()
    var deterministicSleepy = false
    var deterministicTempo: CGFloat = 1
    var deterministicActivity: Float = 1
    var pendingDeterministicResetScopes = Set<String>()
    var deterministicResetControlInFlight = false
    var resumeAfterDeterministicReset = false
    var deterministicResetCompletions: [() -> Void] = []
    let interactiveStartLock = NSLock()
    var hasInteractiveSession: Bool {
        lock.lock(); defer { lock.unlock() }; return interactiveSessionStarted
    }
    var interactiveSessionStarted = false
    var interactiveSessionGeneration: UInt64?

    let sim: MetalSim?
    var flyGym: FlyGymBridge?
    private let fpsLog = ProcessInfo.processInfo.environment["DESKTOPFLY_FPS"] != nil
    private var fpsFrames = 0
    private var fpsWindowStart: TimeInterval = 0
    let signalBuilder = SignalBuilder()
    var msAccumulator: Double = 0
    var prevMouse: CGPoint?
    var mouseVel = CGPoint.zero
    var loomOverride: CGFloat = 0

    // environment senses (written from main-thread timers, read in render loop)
    private var terrain: [Ledge] = []
    var typingLevel: CGFloat = 0
    var sleepy = false
    var tempo: CGFloat = 1
    var activity: Float = 1
    var windowLoomL: Float = 0
    var windowLoomR: Float = 0
    var labWind: Float = 0
    var labWindContinuous = false
    var labWindRemainingS: Double = 0
    var labWindDirectionDeg: Double = 0
    var labTemperatureC: Double = 25
    var labTempoOverride: CGFloat?
    var labThermosensoryEnabled = false
    var labOdorDriveL: Float = 0
    var labOdorDriveR: Float = 0
    var labTasteSugarDrive: Float = 0   // modeled sugar-GRN current (threshold units/ms)
    var labThermoWarmDrive: Float = 0
    var labThermoCoolDrive: Float = 0
    var labWindCDrive: Float = 0
    var labWindEDrive: Float = 0
    var labTouchDrive: Float = 0
    var labTouchRemainingS: Double = 0
    var labSnapshot = LabTelemetry()
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

    func drainSimulationActions() -> [(Coordinator) -> Void] {
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
        resetNeuralState(seed: seed)
        loomOverride = 0
        windowLoomL = 0; windowLoomR = 0
        labWind = 0; labWindDirectionDeg = 0; labWindContinuous = false; labWindRemainingS = 0
        labTouchDrive = 0; labTouchRemainingS = 0
        labTemperatureC = 25; labTempoOverride = nil; labThermosensoryEnabled = false
        clearLabSensoryReadouts()
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

    #if DIAGNOSTICS
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
    #endif
}
