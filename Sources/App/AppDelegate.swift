import Cocoa
import SceneKit

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
    var integratedSimulationThread: Thread?
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
            wc.onStimulate = { [weak coordinator] indices, strength, duration in
                coordinator?.enqueueSimulation { $0.sim?.stimulate(indices, strength: strength, durationMs: duration) }
            }
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
        integratedSimulationThread?.cancel()
        flyGymBridge?.stop()
        flyGymService?.stop()
    }

    /// The one-window Lab: no overlay, no floating brain panel, no global
    /// mouse/click/window senses. The brain and body step from a 60 Hz timer
    /// on their own thread and run loop, so resizing, scrolling or an open menu
    /// never freezes the simulation behind the window, and the Metal step's GPU
    /// wait (~2.4 ms per tick on an M2, ~4.5 ms while MuJoCo renders) no longer
    /// blocks input and frame delivery on the main thread (a quarter of it,
    /// 2026-09-29 profile). Coordinator already steps off the main thread in the
    /// overlay (SceneKit renderer) and in V4 lockstep; the UI reaches it only
    /// through its locked queues and snapshots.
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
        let coordinator = coordinator!
        let thread = Thread {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
                guard !Thread.current.isCancelled else { timer.invalidate(); return }
                coordinator.advanceFrame(at: ProcessInfo.processInfo.systemUptime,
                                         desktopInputs: false)
            }
            RunLoop.current.add(timer, forMode: .default)
            RunLoop.current.run()   // returns once the timer is invalidated
        }
        thread.name = "lab-simulation"
        thread.qualityOfService = .userInteractive
        thread.start()
        integratedSimulationThread = thread
    }

    @objc func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        if paused { coordinator.requestSessionPause() }
        else { coordinator.requestSessionResume() }
        // Keep SceneKit rendering while paused so telemetry/status and the lab UI
        // remain live. V4 pause freezes simulation clocks, not presentation.
        coordinator.enqueue { $0.lastTime = nil }
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
