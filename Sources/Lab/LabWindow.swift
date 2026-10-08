// LabWindow.swift — AppKit Virtual Fly Lab integrated control/telemetry window.

import Cocoa
import UniformTypeIdentifiers

final class LabWindowController: NSWindowController, NSWindowDelegate {
    let participant = LabParticipantController()
    unowned let coordinator: Coordinator
    let bridge: FlyGymBridge?
    let recorder = ExperimentRecorder()
    var brainController: BrainWindowController?
    var timer: Timer?
    private let timelineLabel = NSTextField(wrappingLabelWithString: L("No commands yet", "아직 명령 없음"))
    private let responseLabel = NSTextField(wrappingLabelWithString: L("Waiting for body and eye samples", "몸·눈 데이터를 기다리는 중"))
    let recordButton = NSButton(title: L("Record", "기록"), target: nil, action: nil)
    let runButton = NSButton(title: L("Pause", "일시 정지"), target: nil, action: nil)
    let protocolLabel = NSTextField(labelWithString: L("FlyGym bridge — starting…", "물리 시뮬레이터 연결 — 시작 중…"))
    let remoteStateLabel = NSTextField(labelWithString: L("Environment — waiting for state…", "환경 — 상태를 기다리는 중…"))
    private let recorderLabel = NSTextField(labelWithString: L("not recording", "기록 안 함"))
    let freshnessLabel = NSTextField(labelWithString: L("Packets — waiting for body/environment telemetry…", "데이터 — 몸/환경 정보를 기다리는 중…"))
    let commandDiagnosticsLabel = NSTextField(wrappingLabelWithString: L("Commands — no command sent yet", "명령 — 아직 보낸 명령 없음"))
    let signalPathLabel = NSTextField(wrappingLabelWithString: L("Signal path — waiting for telemetry…", "신호 경로 — 데이터를 기다리는 중…"))
    let sessionStatusLabel = NSTextField(wrappingLabelWithString: L("Session — interactive", "세션 — 실시간"))
    let viewStateLabel = NSTextField(wrappingLabelWithString: "View — OBSERVE · fly fly · object none · tick 0 ms · RUNNING")
    /// Edit is a later-version contract, so the toolbar offers only these two.
    private let segmentModes: [LabViewMode] = [.observe, .participate, .edit]
    let viewModeControl = NSSegmentedControl(labels: ["Observe", "Participate", "Edit"],
                                                     trackingMode: .selectOne,
                                                     target: nil, action: nil)

    let objectID = NSTextField(string: "")
    let objectShape = NSPopUpButton(frame: .zero, pullsDown: false)
    let objectX = NSTextField(string: "60")
    let objectY = NSTextField(string: "0")
    let objectZ = NSTextField(string: "5")
    let objectSize = NSTextField(string: "5")
    let objectSpeed = NSTextField(string: "12")
    let objectEndDistance = NSTextField(string: "8")
    let worldObjectStatusLabel = NSTextField(wrappingLabelWithString: L("Object status — ready", "물체 상태 — 준비됨"))
    let worldCapacityLabel = NSTextField(wrappingLabelWithString: L("Object capacity — waiting for backend…", "물체 수 — 시뮬레이터를 기다리는 중…"))
    let worldViewer = WorldViewer(frame: .zero)
    private let worldViewerStatusLabel = NSTextField(wrappingLabelWithString: L("3D world — waiting for V5.1 backend capability…", "3D 화면 — 시뮬레이터 준비를 기다리는 중…"))
    private let observationCameraMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let playerInputStatusLabel = NSTextField(wrappingLabelWithString: L("Participant controls — waiting for V5.5 player_input capability…", "참여 조작 — 시뮬레이터 준비를 기다리는 중…"))
    let interactionStatusLabel = NSTextField(wrappingLabelWithString: L("Interaction state unknown", "상호작용 상태 알 수 없음"))
    /// V5.6.2 toys: selected-object actions, object list and BB-gun status.
    let driveSpeed = NSTextField(string: String(format: "%.0f", LabToy.driveSpeedMMs))
    let driveDistance = NSTextField(string: String(format: "%.0f", LabToy.driveDistanceMM))
    /// Rebuilt with the page on a language change.
    var driveButton: NSButton?
    var rearmButton: NSButton?
    let toyTargetLabel = NSTextField(wrappingLabelWithString: L("Selected — none", "선택한 물체 — 없음"))
    let objectListLabel = NSTextField(wrappingLabelWithString: L("Objects — none", "물체 목록 — 없음"))
    let gunStatusLabel = NSTextField(labelWithString: "")
    let gunHUDLabel = NSTextField(labelWithString: "")
    var gunHUD: NSVisualEffectView?
    var gunCommandPending: (id: Int, equipped: Bool, sentAt: Date)? {
        get { participant.gunCommandPending }
        set { participant.gunCommandPending = newValue }
    }
    var lastFireCommandID: Int? {
        get { participant.lastFireCommandID }
        set { participant.lastFireCommandID = newValue }
    }
    var lastGunConnectionGeneration: UInt64? {
        get { participant.lastGunConnectionGeneration }
        set { participant.lastGunConnectionGeneration = newValue }
    }
    /// A rejection/"not sent" note stays readable across the 10 Hz refresh.
    var gunNote: (text: String, color: NSColor, until: Date)? {
        get { participant.gunNote }
        set { participant.gunNote = newValue }
    }
    let lookSensitivitySlider = NSSlider(value: PlayerController.defaultLookRadiansPerPoint,
                                                 minValue: PlayerController.lookSensitivityRange.lowerBound,
                                                 maxValue: PlayerController.lookSensitivityRange.upperBound,
                                                 target: nil, action: nil)
    var playerController: PlayerController {
        get { participant.playerController }
    }
    var interactionPresentation: LabInteractionPresentation {
        get { participant.interactionPresentation }
        set { participant.interactionPresentation = newValue }
    }
    var playerCaptureArmed: Bool {
        get { participant.playerCaptureArmed }
        set { participant.playerCaptureArmed = newValue }
    }
    var lastPlayerInputConnectionGeneration: UInt64? {
        get { participant.lastPlayerInputConnectionGeneration }
        set { participant.lastPlayerInputConnectionGeneration = newValue }
    }
    var lastPlayerInputSeq: Int? {
        get { participant.lastPlayerInputSeq }
        set { participant.lastPlayerInputSeq = newValue }
    }
    /// F-01: a player-input send that could not be queued already consumed the
    /// local key state. Re-send the current held state until one is queued.
    var playerInputReconcilePending: Bool {
        get { participant.playerInputReconcilePending }
        set { participant.playerInputReconcilePending = newValue }
    }
    let arenaPlacement = LabArenaPlacementView(frame: .zero)
    let createOnArenaClick = NSButton(checkboxWithTitle: "Create selected object when clicking arena", target: nil, action: nil)
    private var autoObjectSerial: [String: Int] = [:]
    private var lastAutoObjectID: String?
    var lastObjectCommandID: Int?
    var lastObjectCommandTarget: String?
    var lastObjectCommandDescription = ""

    /// V6.5 environment panel: applied values, in-flight edits, sample at the fly.
    let environmentPanel = EnvironmentPanel()
    let windDuration = NSTextField(string: "500")
    let foodVariant = NSPopUpButton(frame: .zero, pullsDown: false)
    let foodStatusLabel = NSTextField(wrappingLabelWithString: "")
    var lastFoodCommandID: Int?
    /// Last backend temperature handed to the brain side (V6.5 authority fix).
    private var adoptedTemperature: (celsius: Double, mode: String, at: Date)?
    let touchStrength = NSTextField(string: "0.55")
    let touchDuration = NSTextField(string: "150")
    let touchTarget = NSPopUpButton(frame: .zero, pullsDown: false)
    let flashEye = NSPopUpButton(frame: .zero, pullsDown: false)
    let flashIntensity = NSTextField(string: "1.0")
    let flashDuration = NSTextField(string: "100")

    let brainRole = NSPopUpButton(frame: .zero, pullsDown: false)
    let brainStrength = NSTextField(string: "0.30")
    let brainDuration = NSTextField(string: "300")
    let brainRoleDescription = NSTextField(wrappingLabelWithString: "")

    let neuralGraph = LabGraphView(frame: .zero,
                                           names: ["brain", "loom", "walk", "back", "groom"])
    let commandGraph = LabGraphView(frame: .zero,
                                           names: ["DNa L", "DNa R", "MDN", "DNp09", "DNg11", "escW"])
    let sensoryGraph = LabGraphView(frame: .zero,
                                            names: ["loom L", "loom R", "legacy air", "gait"])
    let flywireSensoryGraph = LabGraphView(frame: .zero,
                                                   names: ["food L", "food R", "warm", "cool", "wind C", "wind E"])
    let worldEditor = WorldEditorInspector(frame: .zero)
    let bodyGraph = LabGraphView(frame: .zero,
                                         names: ["speed×20", "turn÷5", "contact", "eye loom", "food L", "food R", "distance÷100"])
    let visionGraph = LabGraphView(frame: .zero,
                                           names: ["light L", "light R", "target L", "target R", "expand L", "expand R"])
    let bodyTelemetryLabel = NSTextField(labelWithString: "Movement — speed 0.0000 m/s · turn 0.00 rad/s · contact 0.00")
    let foodTelemetryLabel = NSTextField(labelWithString: "Food odor — left 0.000 · right 0.000 · nearest source: none")
    let visionTelemetryLabel = NSTextField(labelWithString: "Vision — expansion L/R 0.000/0.000 · brightness L/R 0.000/0.000")
    var lastPreset: String?
    var eyeCommandPendingID: Int?
    var eyeCommandStartedAt: Date?
    var eyeCommandSide: String?
    var eyeCommandCovered: Bool?
    var lastCommandID: Int?
    var lastCommandAction = "none"
    private var backendDetail = ""
    private var viewerFrameStale = false
    /// V6.6 undo/redo of applied settings (Edit ▸ Undo, ⌘Z).
    let sceneStatus = NSTextField(wrappingLabelWithString: L("Scene settings only — not a checkpoint", "장면 설정만 저장합니다 — 체크포인트 아님"))
    private var sceneStatusRender: (() -> String)?
    var saveSceneButton: NSButton?
    var loadSceneButton: NSButton?
    private var pendingScene: (id: Int, url: URL?, generation: UInt64, sessionID: String, epoch: Int, sentAt: Date)?
    private var editHistory = WorldEditHistory()
    var pendingCommandSchedules: [Int: LabCommandSchedule] = [:]
    private var lastPickRequestSeq: Int?
    private var lastAppliedPickSeq: Int?
    private var lastPickSource: WorldViewerSnapshotSource?
    private var lastPickSummary = ""
    var participantCommandPending: ParticipantCommandPendingState {
        get { participant.participantCommandPending }
        set { participant.participantCommandPending = newValue }
    }
    private var lastViewerConnectionGeneration: UInt64?
    private var lastViewerSessionID: String?
    private var lastViewerEpoch: Int?
    var viewState = LabViewState()
    let service: FlyGymService?
    var timeline = LabCommandTimeline()
    private var ackCursor: UInt64 = 0
    private var eventCursor: UInt64 = 0
    var recordingPresentation = LabRecordingPresentation()
    var workspace: WorkspaceSnapshot?
    private let restartBackendButton = NSButton(title: L("Restart Backend", "시뮬레이터 다시 시작"), target: nil, action: nil)
    private let canvasBadge = NSTextField(labelWithString: "")
    private var canvasStatusHUD: NSVisualEffectView?
    /// MuJoCo's own rendering of the live scene, streamed by a headless real
    /// backend and drawn over WorldViewer's SceneKit mirror.
    private let mujocoFrameView = MuJoCoFrameView(frame: .zero)
    private var mujocoStream: MuJoCoFrameStream?
    /// Mode the camera popup last followed, and the observation camera to
    /// restore when Participate ends.
    private var cameraFollowsMode: LabViewMode = .observe
    /// Rebuilding the interface for a language change keeps the window size,
    /// the open section, every control value and the live canvas.
    private var hasBuiltUI = false
    private var canvasHUDs: [NSView] = []
    private var selectedSection: LabSection = .world
    let moodEstimator = FlyMoodEstimator()
    let moodEmoji = NSTextField(labelWithString: "🙂")
    let moodTitle = NSTextField(labelWithString: "")
    let moodReason = NSTextField(labelWithString: "")
    private let moodNote = NSTextField(labelWithString: "")
    /// V5.7 read-only activity cards (Data page). Rebuilt with the page on a
    /// language change; fed from the existing 10 Hz refresh, never a new timer.
    var activityCards = ActivityCardPanel()
    /// Edge detector for the participant body touching the fly.
    var participantTouchingFly: Bool {
        get { participant.participantTouchingFly }
        set { participant.participantTouchingFly = newValue }
    }
    var cameraBeforeParticipate: WorldViewerCameraMode? {
        get { participant.cameraBeforeParticipate }
        set { participant.cameraBeforeParticipate = newValue }
    }

    init(coordinator: Coordinator, bridge: FlyGymBridge?, connectome: Connectome? = nil,
         service: FlyGymService? = nil) {
        self.coordinator = coordinator
        self.bridge = bridge
        self.service = service
        let w = LabMainWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Virtual Fly Lab"
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 980, height: 620)
        w.setFrameAutosaveName("VirtualFlyLabWindow")
        PlayerInputFocusPolicy.prepareWindowForCapture(w)
        super.init(window: w)
        w.delegate = self
        w.worldUndo = { [weak self] direction in self?.stepEditHistory(direction) }
        w.worldHistory = { [weak self] in self?.editHistory ?? WorldEditHistory() }
        if let connectome, let sim = coordinator.sim, let screen = NSScreen.main {
            brainController = BrainWindowController(connectome: connectome, sim: sim, screen: screen)
        }
        brainController?.onStimulate = { [weak coordinator] indices, strength, duration in
            coordinator?.enqueueSimulation { $0.sim?.stimulate(indices, strength: strength, durationMs: duration) }
        }
        buildUI()
        brainController?.onPick = { [weak self] pick in
            self?.noteBrainClickStimulus(count: pick.indices.count, name: pick.name,
                                         strength: 0.25, durationMs: 400)
        }
        arenaPlacement.onPick = { [weak self] x, y in
            guard let self else { return }
            self.objectX.stringValue = String(format: "%.1f", x)
            self.objectY.stringValue = String(format: "%.1f", y)
            self.worldObjectStatusLabel.stringValue = String(format: L("Object status — picked X %.1f · Y %.1f mm", "물체 상태 — 지도에서 고른 위치 X %.1f · Y %.1f mm"), x, y)
            self.worldObjectStatusLabel.textColor = .secondaryLabelColor
            if self.createOnArenaClick.state == .on { self.createObject() }
        }
        worldViewer.onPickRay = { [weak self] ray in
            guard let self, let bridge = self.bridge else { return }
            guard bridge.worldViewerV5_1Available else {
                self.worldViewerStatusLabel.stringValue = L("3D world — backend does not advertise V5.1 snapshot/pick", "3D 화면 — 이 시뮬레이터는 클릭 선택을 지원하지 않습니다")
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            guard let source = self.worldViewer.currentSnapshotSource else {
                self.worldViewerStatusLabel.stringValue = L("3D world — no atomic snapshot available for picking", "3D 화면 — 아직 선택할 수 있는 화면이 없습니다")
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            guard bridge.latestWorldRenderSnapshot(maxAge: 1.0) != nil else {
                self.worldViewerStatusLabel.stringValue = L("3D world — old frame; wait for a fresh snapshot before selecting", "3D 화면 — 오래된 화면입니다. 새 화면이 온 뒤 선택하세요")
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            guard let seq = bridge.sendRayPick(rayOriginMM: ray.originMM,
                                               rayDirection: ray.direction,
                                               sourceSnapshotSeq: source.snapshotSeq,
                                               sourceWorldRevision: source.worldRevision,
                                               sourceSimTick: source.simTick) else {
                self.worldViewerStatusLabel.stringValue = L("3D world — pick request was not queued", "3D 화면 — 선택 요청을 보내지 못했습니다")
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            self.lastPickRequestSeq = seq
            self.lastPickSource = source
            self.worldViewerStatusLabel.stringValue = L("3D world — authoritative pick #\(seq) pending…", "3D 화면 — 클릭한 대상 확인 중 (#\(seq))…")
            self.worldViewerStatusLabel.textColor = .secondaryLabelColor
        }
        worldViewer.onPlayerKeyDown = { [weak self] keyCode, isRepeat in
            guard let self else { return }
            guard self.playerInputFocusAllowsCapture() else {
                self.releasePlayerHeldInput(reason: "focus suppression")
                return
            }
            if let intent = self.playerController.handleKeyDown(keyCode: keyCode, isRepeat: isRepeat) {
                let isEscape = keyCode == PlayerController.escapeKeyCode
                self.sendPlayerInput(
                    intent,
                    reason: isEscape ? "Esc safety release" : "key down",
                    allowStaleSnapshotForRelease: isEscape,
                    discardPendingLook: isEscape)
                if self.playerController.freshInteractPress {
                    self.sendParticipantInteraction()
                }
                if isEscape {
                    self.playerCaptureArmed = false
                    _ = self.playerController.setCaptureEnabled(false)
                    self.worldViewer.participateInputEnabled = false
                    self.playerInputStatusLabel.stringValue = L("Participant controls — capture released by Esc · click the 3D view to recapture", "참여 조작 — Esc로 해제됨 · 3D 화면을 클릭하면 다시 조작합니다")
                }
            }
            if let tool = self.playerController.takeToolAction(
                focusAllowsCapture: self.playerInputFocusAllowsCapture()) {
                self.performParticipantTool(tool)
            }
        }
        worldViewer.onPlayerPrimaryClick = { [weak self] in
            guard let self,
                  let tool = self.playerController.primaryClickAction(
                    focusAllowsCapture: self.playerInputFocusAllowsCapture()) else { return }
            self.performParticipantTool(tool)
        }
        worldViewer.onPlayerKeyUp = { [weak self] keyCode in
            guard let self else { return }
            if let intent = self.playerController.handleKeyUp(keyCode: keyCode) {
                self.sendPlayerInput(intent, reason: "key up", allowStaleSnapshotForRelease: true,
                                     discardPendingLook: true)
            }
        }
        worldViewer.onPlayerLookDelta = { [weak self] dx, dy in
            guard let self, self.playerInputFocusAllowsCapture() else { return }
            if let intent = self.playerController.handleLook(deltaX: dx, deltaY: dy) {
                self.sendPlayerInput(intent, reason: "look")
            }
        }
        worldViewer.onPlayerFocusLost = { [weak self] in
            self?.releasePlayerHeldInput(reason: "viewer focus lost")
        }
        worldViewer.onPlayerCaptureRequested = { [weak self] in
            guard let self,
                  self.viewState.mode == .participate,
                  self.viewState.pendingMode == nil,
                  self.bridge?.playerInputV5_5Available == true else { return }
            self.playerCaptureArmed = true
            _ = self.playerController.setCaptureEnabled(true)
            self.worldViewer.participateInputEnabled = true
            self.playerInputStatusLabel.stringValue = L("Participant controls — CAPTURED · WASD move · mouse look · E interact · Esc release", "참여 조작 중 — WASD 이동 · 마우스로 둘러보기 · E 상호작용 · Esc 해제")
        }
        startMuJoCoStream()
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged),
                                               name: .labLanguageChanged, object: nil)
        let refreshTimer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.reconcilePlayerHeldInputIfNeeded()
            self?.syncMuJoCoView()
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    let playerKeys: [PlayerControlAction: NSPopUpButton] = Dictionary(uniqueKeysWithValues:
        PlayerControlAction.allCases.map { ($0, NSPopUpButton(frame: .zero, pullsDown: false)) })
    var graphs: [LabGraphView] { [neuralGraph, commandGraph, sensoryGraph, flywireSensoryGraph, bodyGraph, visionGraph] }

    private func startMuJoCoStream() {
        guard let port = service?.renderPort, port != 0 else { return }
        let stream = MuJoCoFrameStream(port: port)
        stream.onFrame = { [weak self] image in
            guard let self else { return }
            self.mujocoFrameView.show(image)
            if self.mujocoFrameView.isHidden {
                self.mujocoFrameView.isHidden = false
                self.worldViewer.isPlaying = false
                self.worldViewer.rendersContinuously = false
                self.worldViewer.setAccessibilityLabel(
                    L("Live FlyGym world rendered by MuJoCo (NeuroMechFly body). The backend confirms selections.", "MuJoCo가 그린 실시간 가상 세계 (실제 초파리 몸 모델). 클릭한 대상은 시뮬레이터가 확인합니다."))
                // Start close on the fly, as MuJoCo's own viewer did.
                self.worldViewer.prefersFlyCloseUp = true
                self.selectPopupValue(self.observationCameraMode, WorldViewerCameraMode.followFly.rawValue)
                self.worldViewer.setObservationCameraMode(.followFly)
                self.worldViewer.resetObservationCamera()
            }
        }
        worldViewer.onCameraChanged = { [weak self] in self?.syncMuJoCoView() }
        mujocoStream = stream
        stream.start()
        syncMuJoCoView()
    }

    /// Tell the backend which view to render: WorldViewer's camera at the
    /// canvas's pixel size. The stream drops repeats.
    private func syncMuJoCoView() {
        guard let mujocoStream else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = worldViewer.bounds.size
        guard size.width >= 32, size.height >= 32 else { return }
        mujocoStream.sendView(camera: worldViewer.mujocoCamera,
                              pixelWidth: Int(size.width * scale),
                              pixelHeight: Int(size.height * scale))
    }

    var hasRecordingToFinish: Bool { recorder.isRecording || recorder.isStopping }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        releasePlayerHeldInput(reason: "window closed")
    }

    /// In the one-window Lab, closing the window is quitting: the same path
    /// flushes any recording (with the Keep Open / Quit Anyway sheet on failure)
    /// and stops the app-owned backend, so nothing keeps running invisibly.
    /// Opened from the desktop-fly menu, the window just closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard case .lab = LaunchMode.current else { return true }
        NSApp.terminate(nil)
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        releasePlayerHeldInput(reason: "window focus lost")
    }

    /// Window shell: standard toolbar, and an NSSplitViewController with a
    /// source-list sidebar, the always-visible world canvas, and an inspector
    /// whose page follows the sidebar. Only the inspector page changes; the
    /// canvas instance, camera and selection are never rebuilt.
    private func buildUI() {
        guard let window else { return }
        sceneStatus.stringValue = sceneStatusRender?() ?? L("Scene settings only — not a checkpoint", "장면 설정만 저장합니다 — 체크포인트 아님")
        canvasHUDs.forEach { $0.removeFromSuperview() }
        canvasHUDs.removeAll()
        for (index, mode) in segmentModes.enumerated() {
            viewModeControl.setLabel(mode.title, forSegment: index)
        }
        for text in [protocolLabel, recorderLabel] {
            text.font = .systemFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byTruncatingMiddle
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        recorderLabel.alignment = .right
        recorderLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        recorderLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        [remoteStateLabel, freshnessLabel, viewStateLabel, sessionStatusLabel,
         commandDiagnosticsLabel, signalPathLabel].forEach { _ = LabForm.status($0, mono: true) }
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = 0
        viewModeControl.setEnabled(false, forSegment: 1)
        viewModeControl.segmentStyle = .separated
        runButton.target = self
        runButton.action = #selector(toggleRun)
        runButton.bezelStyle = .texturedRounded
        runButton.imagePosition = .imageLeading
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.bezelStyle = .texturedRounded
        recordButton.imagePosition = .imageLeading
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)

        let tabs = NSTabViewController()
        tabs.tabStyle = .unspecified
        tabs.tabView.tabViewType = .noTabsNoBorder
        for (section, page) in [(LabSection.world, worldPage()), (.stimuli, sensesPage()),
                                (.brain, brainPage()), (.data, metricsPage()),
                                (.experiment, experimentPage())] {
            let item = NSTabViewItem(viewController: page)
            item.label = section.title
            tabs.addTabViewItem(item)
        }
        let sidebar = LabSidebarController()
        sidebar.onSelect = { [weak self, weak tabs] section in
            guard let self else { return }
            if self.viewState.mode == .participate || self.playerCaptureArmed {
                self.releasePlayerHeldInput(reason: "section changed")
            }
            tabs?.selectedTabViewItemIndex = section.rawValue
            self.selectedSection = section
            self.window?.makeFirstResponder(nil)
        }
        tabs.selectedTabViewItemIndex = selectedSection.rawValue
        sidebar.select(selectedSection)

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 240
        let canvasItem = NSSplitViewItem(viewController: canvasController())
        canvasItem.minimumThickness = 420
        canvasItem.holdingPriority = .defaultLow - 1
        let inspectorItem: NSSplitViewItem
        if #available(macOS 14.0, *) {
            inspectorItem = NSSplitViewItem(inspectorWithViewController: tabs)
        } else {
            inspectorItem = NSSplitViewItem(viewController: tabs)
            inspectorItem.canCollapse = true
        }
        inspectorItem.minimumThickness = 300
        inspectorItem.maximumThickness = 520
        inspectorItem.preferredThicknessFraction = 0.30
        [sidebarItem, canvasItem, inspectorItem].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "VirtualFlyLabSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "VirtualFlyLabToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if !hasBuiltUI { window.setContentSize(NSSize(width: 1320, height: 820)) }
        hasBuiltUI = true
        renderViewState()
    }

    @objc private func languageChanged() {
        let popups = [objectShape, touchTarget, foodVariant, flashEye, brainRole]
        let values = popups.map { $0.selectedItem?.representedObject as? String }
        let checks = [createOnArenaClick]
        let states = checks.map(\.state)
        buildUI()
        worldEditor.relabel()
        for (popup, value) in zip(popups, values) { if let value { selectPopupValue(popup, value) } }
        for (check, state) in zip(checks, states) { check.state = state }
        arenaPlacement.selectedShape = selectedValue(objectShape, fallback: "box")
        updateBrainRoleDescription()
        refresh()
    }

    @objc func languagePicked(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let language = LabLanguage(rawValue: raw), language != LabLanguage.current else { return }
        LabLanguage.current = language
    }

    /// Center pane: the 3D world with its own small HUDs, the event timeline
    /// and a one-line status bar. Fixed-height bands; the canvas takes the rest.
    private func canvasController() -> NSViewController {
        let container = NSView()
        worldViewer.translatesAutoresizingMaskIntoConstraints = false
        worldViewer.setAccessibilityLabel(L("Live FlyGym world. The fly is a position marker; the backend confirms selections.", "실시간 가상 세계. 클릭한 대상은 시뮬레이터가 확인합니다."))
        container.addSubview(worldViewer)
        mujocoFrameView.translatesAutoresizingMaskIntoConstraints = false
        mujocoFrameView.isHidden = true
        worldViewer.addSubview(mujocoFrameView)
        // Above the streamed primary canvas, below HUDs. Outside handle circles,
        // hitTest passes through to WorldViewer for existing camera/pick gestures.
        worldEditor.overlay.translatesAutoresizingMaskIntoConstraints = false
        worldViewer.addSubview(worldEditor.overlay, positioned: .above, relativeTo: mujocoFrameView)
        activateUnique([
            worldEditor.overlay.leadingAnchor.constraint(equalTo: worldViewer.leadingAnchor),
            worldEditor.overlay.trailingAnchor.constraint(equalTo: worldViewer.trailingAnchor),
            worldEditor.overlay.topAnchor.constraint(equalTo: worldViewer.topAnchor),
            worldEditor.overlay.bottomAnchor.constraint(equalTo: worldViewer.bottomAnchor)
        ])
        worldEditor.onSelect = { [weak self] id in self?.viewState.selectObject(id) }
        worldEditor.onFocus = { [weak self] id in self?.focusCamera(onObject: id) }
        worldEditor.onSelectResult = { [weak self] id,source in
            guard let self, self.viewState.mode == .edit, self.viewState.selectedObjectID == source else { return false }
            self.viewState.selectObject(id); return true
        }
        worldEditor.onSubmit = { [weak self] command, captured in
            guard let self, let bridge = self.bridge,
                  self.viewState.mode == .edit, !self.viewerFrameStale,
                  self.viewState.selectedObjectID == (command.edit?.targetID ?? command.objectEdit?.targetID),
                  self.workspace?.acceptsBackendCommands == true else { return nil }
            let session = self.coordinator.sessionSnapshot()
            guard !session.sessionID.isEmpty, session.epoch > 0,
                  session.sessionID == captured.sessionID, session.epoch == captured.epoch,
                  bridge.connectionGeneration == captured.generation,
                  session.phase == .running || session.phase == .paused else { return nil }
            // Interactive controls must carry the same identity/boundary as
            // deterministic controls, not use the legacy unstamped path.
            let schedule = self.coordinator.labCommandSchedule() ?? LabCommandSchedule(
                sessionID: session.sessionID, epoch: session.epoch, requestedTick: session.simTick)
            guard schedule.sessionID == captured.sessionID, schedule.epoch == captured.epoch,
                  bridge.connectionGeneration == self.viewState.connectionGeneration,
                  let id = self.sendCommand(command, scheduleOverride: schedule) else { return nil }
            return (id, self.pendingCommandSchedules[id] ?? schedule)
        }
        worldViewer.bringAimMarkToFront()
        activateUnique([
            mujocoFrameView.leadingAnchor.constraint(equalTo: worldViewer.leadingAnchor),
            mujocoFrameView.trailingAnchor.constraint(equalTo: worldViewer.trailingAnchor),
            mujocoFrameView.topAnchor.constraint(equalTo: worldViewer.topAnchor),
            mujocoFrameView.bottomAnchor.constraint(equalTo: worldViewer.bottomAnchor)
        ])

        func hud(_ views: [NSView]) -> NSVisualEffectView {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 8
            effect.appearance = NSAppearance(named: .darkAqua)
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            activateUnique([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
            ])
            effect.translatesAutoresizingMaskIntoConstraints = false
            worldViewer.addSubview(effect)
            canvasHUDs.append(effect)
            return effect
        }

        addPopupItems(observationCameraMode, WorldViewerCameraMode.allCases.map { ($0.title, $0.rawValue) })
        observationCameraMode.target = self
        observationCameraMode.action = #selector(observationCameraModeChanged)
        observationCameraMode.controlSize = .small
        observationCameraMode.autoenablesItems = false
        selectPopupValue(observationCameraMode, worldViewer.cameraState.mode.rawValue)
        let resetCamera = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise",
                                                  accessibilityDescription: L("Reset camera", "카메라 초기화")) ?? NSImage(),
                                   target: self, action: #selector(resetObservationCamera))
        resetCamera.isBordered = false
        resetCamera.toolTip = L("Reset camera", "카메라 초기화")
        let cameraLabel = NSTextField(labelWithString: L("Camera", "시점"))
        cameraLabel.font = .systemFont(ofSize: 11)
        let cameraHUD = hud([cameraLabel, observationCameraMode, resetCamera])

        canvasBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        canvasBadge.lineBreakMode = .byTruncatingTail
        restartBackendButton.target = self
        restartBackendButton.action = #selector(restartBackend)
        restartBackendButton.controlSize = .small
        restartBackendButton.bezelStyle = .rounded
        restartBackendButton.isHidden = true
        canvasStatusHUD = hud([canvasBadge, restartBackendButton])
        canvasStatusHUD?.isHidden = true

        gunHUDLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let gunHUD = hud([gunHUDLabel])
        gunHUD.isHidden = true
        self.gunHUD = gunHUD

        worldViewerStatusLabel.font = .systemFont(ofSize: 11)
        worldViewerStatusLabel.maximumNumberOfLines = 1
        worldViewerStatusLabel.lineBreakMode = .byTruncatingTail
        worldViewerStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let captionHUD = hud([worldViewerStatusLabel])

        moodEmoji.font = .systemFont(ofSize: 26)
        moodTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        moodReason.font = .systemFont(ofSize: 10.5)
        moodReason.textColor = .secondaryLabelColor
        moodNote.font = .systemFont(ofSize: 9)
        moodNote.textColor = .tertiaryLabelColor
        moodNote.stringValue = L("Estimated from senses & behaviour", "감각·행동 신호로 만든 추정")
        let moodText = NSStackView(views: [moodTitle, moodReason, moodNote])
        moodText.orientation = .vertical
        moodText.alignment = .leading
        moodText.spacing = 0
        let moodHUD = hud([moodEmoji, moodText])
        moodHUD.toolTip = L("A simple rule-based mood, not a measurement of feelings. Food nearby → happy; cold, heat or a hard hit → sad; being hit → angry; something looming or an escape → scared.",
                            "실제 감정을 잰 것이 아니라 정해진 규칙으로 만든 단순 표시입니다. 먹이가 가까우면 행복, 춥거나 덥거나 세게 맞으면 슬픔, 맞으면 화남, 무언가 다가오거나 도망 신호가 켜지면 겁남.")
        moodHUD.setAccessibilityElement(true)
        moodHUD.setAccessibilityLabel(L("Fly mood (estimate)", "파리 기분 (추정)"))

        if let status = canvasStatusHUD {
            activateUnique([
                status.leadingAnchor.constraint(equalTo: worldViewer.leadingAnchor, constant: 12),
                status.topAnchor.constraint(equalTo: worldViewer.topAnchor, constant: 12),
                status.trailingAnchor.constraint(lessThanOrEqualTo: cameraHUD.leadingAnchor, constant: -12)
            ])
        }
        activateUnique([
            cameraHUD.trailingAnchor.constraint(equalTo: worldViewer.trailingAnchor, constant: -12),
            cameraHUD.topAnchor.constraint(equalTo: worldViewer.topAnchor, constant: 12),
            gunHUD.centerXAnchor.constraint(equalTo: worldViewer.centerXAnchor),
            gunHUD.bottomAnchor.constraint(equalTo: captionHUD.topAnchor, constant: -8),
            captionHUD.leadingAnchor.constraint(equalTo: worldViewer.leadingAnchor, constant: 12),
            captionHUD.bottomAnchor.constraint(equalTo: worldViewer.bottomAnchor, constant: -12),
            captionHUD.trailingAnchor.constraint(lessThanOrEqualTo: moodHUD.leadingAnchor, constant: -8),
            moodHUD.trailingAnchor.constraint(equalTo: worldViewer.trailingAnchor, constant: -12),
            moodHUD.bottomAnchor.constraint(equalTo: worldViewer.bottomAnchor, constant: -12)
        ])

        let timelineTitle = NSTextField(labelWithString: L("Timeline", "타임라인 — 최근 명령과 반응"))
        timelineTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        timelineTitle.textColor = .secondaryLabelColor
        timelineLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        timelineLabel.textColor = .labelColor
        timelineLabel.maximumNumberOfLines = 5
        timelineLabel.lineBreakMode = .byTruncatingTail
        timelineLabel.setAccessibilityLabel(L("Recent commands and events", "최근 명령과 사건"))
        responseLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        responseLabel.textColor = .secondaryLabelColor
        responseLabel.maximumNumberOfLines = 1
        responseLabel.lineBreakMode = .byTruncatingTail
        for text in [timelineLabel, responseLabel] {
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let timeline = NSStackView(views: [timelineTitle, timelineLabel, responseLabel])
        timeline.orientation = .vertical
        timeline.alignment = .leading
        timeline.spacing = 4
        timeline.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        let statusBar = NSStackView(views: [protocolLabel, recorderLabel])
        statusBar.orientation = .horizontal
        statusBar.distribution = .fill
        statusBar.spacing = 12
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)

        let rule1 = NSBox(); rule1.boxType = .separator
        let rule2 = NSBox(); rule2.boxType = .separator
        for v in [timeline, statusBar, rule1, rule2] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        activateUnique([
            worldViewer.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            worldViewer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            worldViewer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            worldViewer.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            rule1.topAnchor.constraint(equalTo: worldViewer.bottomAnchor),
            timeline.topAnchor.constraint(equalTo: rule1.bottomAnchor),
            rule2.topAnchor.constraint(equalTo: timeline.bottomAnchor),
            statusBar.topAnchor.constraint(equalTo: rule2.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 118)
        ])
        for v in [rule1, timeline, rule2, statusBar] as [NSView] {
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        }
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    @objc private func toggleRun() {
        switch viewState.sessionPhase {
        case .running: pauseSession()
        case .paused: resumeSession()
        default: break
        }
    }

    @objc private func viewModeChanged() {
        let modes = segmentModes
        guard viewModeControl.selectedSegment >= 0,
              viewModeControl.selectedSegment < modes.count else { return }
        let requested = modes[viewModeControl.selectedSegment]
        if participantCommandPending.isPending {
            viewModeControl.selectedSegment = modes.firstIndex(of: viewState.displayedMode) ?? 0
            return
        }
        switch requested {
        case .participate:
            guard bridge?.playerV5_4Available == true else {
                viewState.rejectModeTransition()
                viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
                renderViewState()
                return
            }
            if bridge?.playerInputV5_5Available == true {
                // Establish/promote the V4 identity before queueing the physical
                // participant mutation. The bridge sends session-control packets
                // ahead of LabCommands; doing this in the opposite order would
                // let `begin` change the backend identity before an old-identity
                // set_player_active command reached Python.
                guard coordinator.ensureInteractivePlayerInputSession() else {
                    viewState.rejectModeTransition()
                    viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
                    playerInputStatusLabel.stringValue = L("Participant controls — could not establish interactive input session", "참여 조작 — 조작 세션을 만들지 못했습니다")
                    playerInputStatusLabel.textColor = .systemRed
                    renderViewState()
                    return
                }
            }
            guard let id = send("set_player_active", value: 1) else {
                viewState.rejectModeTransition()
                viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
                renderViewState()
                return
            }
            participantCommandPending.begin(
                commandID: id,
                connectionGeneration: bridge?.connectionGeneration ?? 0)
            viewState.beginModeTransition(to: .participate)
            // Capture starts only from a click on the 3D view (V5.5.1 plan §3).
            // Arming it here turned the pointer's trip from the toolbar to the
            // canvas into a large look rotation before the user could aim.
            playerCaptureArmed = false
            viewModeControl.selectedSegment = modes.firstIndex(of: viewState.displayedMode) ?? 0
            worldViewerStatusLabel.stringValue = L("3D world — enabling backend participant probe…", "3D 화면 — 참여자 몸을 세계에 넣는 중…")
        case .observe:
            if viewState.mode == .edit { viewState.mode = .observe; viewState.rejectModeTransition() }
            if viewState.mode == .participate {
                releasePlayerHeldInput(reason: "mode exit")
                guard let id = send("set_player_active", value: 0) else {
                    viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
                    return
                }
                participantCommandPending.begin(
                    commandID: id,
                    connectionGeneration: bridge?.connectionGeneration ?? 0)
                viewState.beginModeTransition(to: .observe)
                viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
                worldViewerStatusLabel.stringValue = L("3D world — disabling backend participant probe…", "3D 화면 — 참여자 몸을 세계에서 빼는 중…")
            }
        case .edit:
            guard workspace?.acceptsBackendCommands == true, !viewerFrameStale else {
                viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
                return
            }
            guard coordinator.ensureInteractivePlayerInputSession() else { return }
            if viewState.mode == .participate {
                releasePlayerHeldInput(reason: "enter Edit")
                guard let id = send("set_player_active", value: 0) else { return }
                participantCommandPending.begin(commandID: id, connectionGeneration: bridge?.connectionGeneration ?? 0)
                viewState.beginModeTransition(to: .edit)
            } else {
                viewState.mode = .edit
                viewState.rejectModeTransition()
                // Follow-fly framing usually leaves the selected object off screen.
                if let id = viewState.selectedObjectID, !worldEditor.overlay.selectionOnScreen {
                    focusCamera(onObject: id)
                }
            }
            viewModeControl.selectedSegment = modes.firstIndex(of: viewState.displayedMode) ?? 0
        }
        renderViewState()
    }

    private func sceneMessage(_ text: @autoclosure @escaping () -> String, error: Bool = false) {
        sceneStatusRender = text
        sceneStatus.stringValue = text()
        sceneStatus.textColor = error ? .systemRed : .secondaryLabelColor
    }

    @objc func saveScene() {
        guard pendingScene == nil, let bridge, bridge.connected, bridge.latestLabState()?.worldState?.sceneCapabilities?.supported == true else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "flyworld") ?? .json]
        panel.nameFieldStringValue = "Scene.flyworld"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.submitScene(LabCommand(id: 0, action: "export_scene"), url: url)
        }
    }

    @objc func loadScene() {
        guard pendingScene == nil, bridge?.connected == true, bridge?.latestLabState()?.worldState?.sceneCapabilities?.supported == true else { return }
        guard coordinator.sessionSnapshot().phase == .paused else {
            sceneMessage(L("Pause the simulation before loading a scene", "장면을 불러오기 전에 일시정지하세요"), error: true); return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "flyworld") ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let text = try SceneFile.read(url)
                self.submitScene(LabCommand(id: 0, action: "load_scene", sceneDocument: text), url: nil)
            } catch { self.sceneMessage(error.localizedDescription, error: true) }
        }
    }

    private func submitScene(_ command: LabCommand, url: URL?) {
        guard pendingScene == nil, let bridge, coordinator.ensureInteractivePlayerInputSession() else { return }
        let session = coordinator.sessionSnapshot()
        let schedule = coordinator.labCommandSchedule() ?? LabCommandSchedule(
            sessionID: session.sessionID, epoch: session.epoch, requestedTick: session.simTick)
        guard let id = sendCommand(command, scheduleOverride: schedule) else { return }
        pendingScene = (id, url, bridge.connectionGeneration, session.sessionID, session.epoch, Date())
        sceneMessage(L("Waiting for scene result…", "장면 처리 결과를 기다리는 중…"))
    }

    private func acceptScene(_ ack: LabAck) {
        guard let p = pendingScene, ack.id == p.id, ack.connectionGeneration == p.generation,
              ack.sessionID == p.sessionID, ack.epoch == p.epoch else { return }
        pendingScene = nil
        guard ack.ok, let result = ack.scene, result.kind == "scene_settings" else {
            sceneMessage(ack.message, error: true); return
        }
        do {
            if let url = p.url {
                guard let text = result.documentText, let canonical = result.canonicalScene else { throw CocoaError(.fileWriteUnknown) }
                try SceneFile.write(text, to: url, canonicalScene: canonical)
                sceneMessage(L("Scene saved: ", "장면 저장됨: ") + url.lastPathComponent)
                recorder.mark(kind: "scene_saved", detail: url.lastPathComponent, commandID: ack.id, appliedTick: ack.appliedTick)
            } else {
                editHistory = WorldEditHistory()
                viewState.selectObject(nil)
                sceneMessage(L("Scene loaded — body and neurons were not rewound", "장면 불러옴 — 몸과 뉴런 시간은 되돌리지 않았습니다"))
                recorder.mark(kind: "scene_loaded", detail: result.contentSHA256 ?? "", commandID: ack.id,
                              appliedTick: ack.appliedTick)
            }
        } catch { sceneMessage(error.localizedDescription, error: true) }
    }

    func renderViewState(session suppliedSession: LabSessionSnapshot? = nil) {
        let session = suppliedSession ?? coordinator.sessionSnapshot()
        let sceneSupported = bridge?.connected == true && bridge?.latestLabState()?.worldState?.sceneCapabilities?.supported == true
        saveSceneButton?.isEnabled = sceneSupported && pendingScene == nil
        loadSceneButton?.isEnabled = sceneSupported && pendingScene == nil
        if sceneStatusRender == nil {
            sceneStatus.stringValue = sceneSupported ? L("Scene settings only — not a checkpoint", "장면 설정만 저장합니다 — 체크포인트 아님")
                : L("Scene files need a compatible connected backend", "장면 파일은 연결된 호환 백엔드가 필요합니다")
        }
        if let p = pendingScene {
            if bridge?.connectionGeneration != p.generation || session.sessionID != p.sessionID || session.epoch != p.epoch || Date().timeIntervalSince(p.sentAt) > 10 {
                pendingScene = nil
                sceneMessage(L("Scene result unavailable — check the connection and retry", "장면 결과를 받지 못했습니다 — 연결 확인 후 다시 시도하세요"), error: true)
            }
        }
        interactionPresentation.expire()
        let connection = workspace?.connection ?? .connecting
        window?.subtitle = "\(connection.title) · \(viewState.phaseBadge.capitalized)"
        restartBackendButton.isHidden = service?.canRestart != true
        viewModeControl.setEnabled(bridge?.playerV5_4Available == true, forSegment: 1)
        let playerAvailable = bridge?.playerV5_4Available == true
        let playerInputAvailable = bridge?.playerInputV5_5Available == true
        let generation = bridge?.connectionGeneration ?? 0
        if let previous = lastPlayerInputConnectionGeneration, previous != generation {
            _ = playerController.setCaptureEnabled(false)
            _ = playerController.releaseHeldInput(blockUntilFreshPress: true)
            playerCaptureArmed = false
            lastPlayerInputSeq = nil
            playerInputReconcilePending = false
            interactionPresentation.reset()
        }
        lastPlayerInputConnectionGeneration = generation
        // Leaving Participate or reconnecting deactivates the backend
        // participant, which holsters the gun there.
        if viewState.mode != .participate || lastGunConnectionGeneration != generation {
            if playerController.gunEquipped || gunCommandPending != nil { dropGunState() }
        }
        lastGunConnectionGeneration = generation
        if participantCommandPending.clearIfViewerLifecycleInvalid(
            playerAvailable: playerAvailable,
            connectionGeneration: generation) {
            viewState.rejectModeTransition()
        }
        if !playerAvailable && viewState.mode == .participate {
            viewState.mode = .observe
        }

        let wantsPlayerInputMode = viewState.mode == .participate
            && viewState.pendingMode == nil && playerInputAvailable
            && viewState.sessionPhase == .running
        let participatePending = viewState.pendingMode == .participate && playerInputAvailable
        worldViewer.participateModeEnabled = wantsPlayerInputMode || participatePending
        if !wantsPlayerInputMode {
            if participatePending && playerCaptureArmed {
                _ = playerController.setCaptureEnabled(false)
                worldViewer.participateInputEnabled = false
            } else {
                let hadCapture = playerController.captureEnabled
                    || playerCaptureArmed || worldViewer.participateInputEnabled
                if hadCapture {
                    releasePlayerHeldInput(reason: "input capability/mode release")
                } else {
                    _ = playerController.setCaptureEnabled(false)
                    playerCaptureArmed = false
                    worldViewer.participateInputEnabled = false
                }
            }
        } else {
            // A 3D-view click arms capture and focuses WorldViewer. If focus
            // moved to an editor/control before the participant was confirmed,
            // fail closed rather than stealing it back.
            let focused = playerInputFocusAllowsCapture()
            let shouldCapture = playerCaptureArmed && focused
            if shouldCapture {
                _ = playerController.setCaptureEnabled(true)
                worldViewer.participateInputEnabled = true
            } else if playerCaptureArmed
                        || playerController.captureEnabled
                        || worldViewer.participateInputEnabled {
                releasePlayerHeldInput(reason: "focus release")
            } else {
                _ = playerController.setCaptureEnabled(false)
                worldViewer.participateInputEnabled = false
            }
        }

        if viewState.mode == .participate {
            if playerInputAvailable {
                playerInputStatusLabel.stringValue = worldViewer.participateInputEnabled
                    ? L("Participant controls — CAPTURED · WASD move · mouse look · E interact · Esc release", "참여 조작 중 — WASD 이동 · 마우스로 둘러보기 · E 상호작용 · Esc 해제")
                    : L("Participant controls — not captured · click the 3D view to move and look", "참여 조작 — 3D 화면을 클릭하면 WASD 이동과 마우스 시선 조작이 시작됩니다")
                playerInputStatusLabel.textColor = worldViewer.participateInputEnabled ? .systemGreen : .secondaryLabelColor
            } else {
                playerInputStatusLabel.stringValue = L("Participant controls — backend has V5.4 body but not V5.5 player_input", "참여 조작 — 이 시뮬레이터 버전은 키보드 조작을 지원하지 않습니다")
                playerInputStatusLabel.textColor = .systemOrange
            }
        } else {
            interactionPresentation.reset()
            playerInputStatusLabel.stringValue = L("Participant controls — Observe mode; camera controls remain presentation-only", "참여 조작 — 관찰 모드입니다. 카메라는 보는 방향만 바꾸고 세계에는 영향을 주지 않습니다")
            playerInputStatusLabel.textColor = .secondaryLabelColor
        }
        let interaction = bridge?.labStateFreshness().isFresh == true
            ? bridge?.latestLabState()?.interaction : nil
        syncCameraWithMode()
        refreshInteractionStatus(state: interaction)
        viewModeControl.selectedSegment = segmentModes.firstIndex(of: viewState.displayedMode) ?? 0
        viewStateLabel.stringValue = viewState.commonStatusLine
        viewStateLabel.textColor = viewState.sessionPhase == .failed ? .systemRed : .labelColor
        sessionStatusLabel.stringValue = viewState.sessionStatusLine
        sessionStatusLabel.textColor = viewState.sessionPhase == .failed ? .systemRed : .labelColor
        let paused = viewState.sessionPhase == .paused
        show(runButton, title: paused ? L("Resume", "재개") : L("Pause", "일시 정지"),
             symbol: paused ? "play.fill" : "pause.fill")
        runButton.isEnabled = viewState.sessionPhase == .running || paused
        if case .recording(_, let elapsed)? = workspace?.recording {
            show(recordButton, title: L("Stop · ", "멈춤 · ") + WorkspaceSnapshot.clock(elapsed),
                 symbol: "stop.circle.fill", tint: .systemRed)
        } else {
            show(recordButton, title: recorder.isStopping ? L("Saving…", "저장 중…") : L("Record", "기록"),
                 symbol: "record.circle")
        }
        recordButton.isEnabled = !recorder.isStopping
        recordButton.setAccessibilityLabel(recorder.isRecording ? L("Stop recording and save", "기록을 멈추고 저장") : L("Start recording", "기록 시작"))
    }

    /// The status refresh runs at 10 Hz, and on macOS 26 every title or image
    /// write re-measures the button (SwiftUI sizing plus an SF Symbol lookup):
    /// rewriting unchanged values cost ~13% of the main thread (2026-09-29).
    private var shownButtonSymbols: [ObjectIdentifier: String] = [:]
    func show(_ button: NSButton, title: String, symbol: String, tint: NSColor? = nil) {
        if button.title != title { button.title = title }
        if shownButtonSymbols[ObjectIdentifier(button)] != symbol {
            shownButtonSymbols[ObjectIdentifier(button)] = symbol
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if button.contentTintColor != tint { button.contentTintColor = tint }
    }

    /// Participate looks through the participant's eyes by default; leaving it
    /// returns to the observation camera that was in use before.
    private func syncCameraWithMode() {
        let participating = viewState.mode == .participate
        for item in observationCameraMode.itemArray {
            if let raw = item.representedObject as? String,
               let mode = WorldViewerCameraMode(rawValue: raw), mode.ridesParticipant {
                item.isEnabled = participating
            }
        }
        guard viewState.mode != cameraFollowsMode else { return }
        cameraFollowsMode = viewState.mode
        let current = worldViewer.cameraState.mode
        if participating {
            if !current.ridesParticipant { cameraBeforeParticipate = current }
            applyCameraMode(.firstPerson)
        } else if current.ridesParticipant {
            applyCameraMode(cameraBeforeParticipate ?? .followFly)
        }
    }

    private func applyCameraMode(_ mode: WorldViewerCameraMode) {
        selectPopupValue(observationCameraMode, mode.rawValue)
        worldViewer.setObservationCameraMode(mode)
    }

    func d(_ f: NSTextField, fallback: Double = 0) -> Double {
        let x = f.doubleValue
        return x.isFinite ? x : fallback
    }
    func ms(_ f: NSTextField, fallback: Int) -> Int { max(1, min(60_000, f.integerValue == 0 ? fallback : f.integerValue)) }
    var target: String { objectID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "stimulus" : objectID.stringValue }

    func creationTarget(for shape: String) -> String {
        let typed = objectID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && typed != lastAutoObjectID {
            lastAutoObjectID = nil
            return typed
        }
        let next = (autoObjectSerial[shape] ?? 0) + 1
        autoObjectSerial[shape] = next
        let generated = "\(shape)_\(next)"
        lastAutoObjectID = generated
        objectID.stringValue = generated
        return generated
    }

    @objc func objectShapeChanged() {
        let shape = selectedValue(objectShape, fallback: "box")
        arenaPlacement.selectedShape = shape
        // If the previous name was auto-generated, switching shape should not
        // make the new object inherit the old shape's ID.
        if objectID.stringValue == lastAutoObjectID {
            objectID.stringValue = ""
            lastAutoObjectID = nil
        }
        switch shape {
        case "wall":
            if d(objectSize, fallback: 5) <= 5.01 { objectSize.stringValue = "20" }
            if d(objectZ, fallback: 5) <= 5.01 { objectZ.stringValue = "7.5" }
        case "food":
            objectSize.stringValue = "3"
            objectZ.stringValue = "1.5"
        case "sphere":
            objectSize.stringValue = "5"
            objectZ.stringValue = "3"
        case "car", "trap":
            let size = shape == "car" ? LabToy.carDefaultLengthMM : LabToy.trapDefaultSideMM
            objectSize.stringValue = String(format: "%.0f", size)
            objectZ.stringValue = String(format: "%.2f", LabToy.spawnCenterZ(shape: shape, sizeMM: size))
        case "ramp":
            let size = LabRamp.size(lengthMM: LabRamp.defaultLengthMM)
            objectSize.stringValue = String(format: "%.0f", size[0])
            objectZ.stringValue = String(format: "%.2f", LabRamp.flushCenterZ(sizeMM: size, pitchDeg: LabRamp.defaultPitchDeg))
        default:
            objectSize.stringValue = "5"
            objectZ.stringValue = "5"
        }
    }

    @objc private func observationCameraModeChanged() {
        let raw = selectedValue(observationCameraMode, fallback: WorldViewerCameraMode.orbit.rawValue)
        guard let mode = WorldViewerCameraMode(rawValue: raw) else { return }
        worldViewer.setObservationCameraMode(mode)
        let interaction = bridge?.labStateFreshness().isFresh == true
            ? bridge?.latestLabState()?.interaction : nil
        refreshInteractionStatus(state: interaction)
        worldViewerStatusLabel.stringValue = L("3D world — \(mode.title) camera · presentation only", "3D 화면 — 시점: \(mode.title) (보기만 바뀝니다)")
        worldViewerStatusLabel.textColor = .secondaryLabelColor
    }

    /// Orbit the 3D view around an object, keeping the camera popup in sync.
    private func focusCamera(onObject id: String) {
        guard let object = arenaPlacement.worldObjects.first(where: { $0.id == id }) else { return }
        applyCameraMode(.orbit)
        worldViewer.focusObservationCamera(onMM: object.positionMM, extentMM: object.sizeMM.max() ?? 10)
        worldViewerStatusLabel.stringValue = L("3D world — orbiting \(id)", "3D 화면 — \(id) 중심으로 보기")
        worldViewerStatusLabel.textColor = .secondaryLabelColor
    }

    @objc private func resetObservationCamera() {
        worldViewer.resetObservationCamera()
        worldViewerStatusLabel.stringValue = L("3D world — observation camera reset", "3D 화면 — 카메라 초기화됨")
        worldViewerStatusLabel.textColor = .secondaryLabelColor
    }


    func clearEyePending() {
        eyeCommandPendingID = nil
        eyeCommandStartedAt = nil
        eyeCommandSide = nil
        eyeCommandCovered = nil
    }


    @objc private func toggleRecording() {
        if recorder.isRecording { stopRecording() }
        else { startRecording() }
        renderViewState()
    }

    @discardableResult
    private func ageString(_ age: TimeInterval) -> String {
        let a = max(0, age)
        return a < 1 ? String(format: "%.0f ms", a * 1000) : String(format: "%.1f s", a)
    }

    private func yawRadians(quaternion q: [Double]) -> Double {
        guard q.count == 4 else { return 0 }
        // xyzw quaternion -> z-up yaw.
        let x = q[0], y = q[1], z = q[2], w = q[3]
        return atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
    }

    private func updateArenaFromAtomicSnapshot(_ snapshot: WorldRenderSnapshot) {
        // The render snapshot carries poses; the food model name only comes
        // with lab_state, so it is joined by id for the map label alone.
        let labObjects = bridge?.latestLabState()?.authoritativeObjects ?? []
        arenaPlacement.worldObjects = snapshot.objects.map { object in
            LabWorldObjectRemote(render: object, lab: labObjects.first { $0.id == object.id })
        }
        if let fly = snapshot.fly {
            arenaPlacement.flyPose = (fly.positionMM[0], fly.positionMM[1],
                                      yawRadians(quaternion: fly.orientationQuatXYZW))
        } else {
            arenaPlacement.flyPose = nil
        }
    }

    private func clearWorldViewerSnapshotPresentation(resetIdentity: Bool) {
        worldViewer.clearSnapshot()
        arenaPlacement.worldObjects = []
        arenaPlacement.flyPose = nil
        viewState.clearViewerIdentity(clearObjectSelection: resetIdentity)
        lastPickRequestSeq = nil
        lastAppliedPickSeq = nil
        lastPickSource = nil
        lastPickSummary = ""
        if resetIdentity {
            lastViewerConnectionGeneration = nil
            lastViewerSessionID = nil
            lastViewerEpoch = nil
        }
    }

    /// An edit stamped with the session it was made in, sent only while that
    /// session is still running or paused (a paused edit is a V6.6 transaction).
    func sendEdit(_ command: LabCommand, captured: WorldEditorIdentity) -> (Int, LabCommandSchedule)? {
        guard let bridge, workspace?.acceptsBackendCommands == true else { return nil }
        let session = coordinator.sessionSnapshot()
        guard !session.sessionID.isEmpty, session.epoch > 0,
              session.sessionID == captured.sessionID, session.epoch == captured.epoch,
              bridge.connectionGeneration == captured.generation,
              session.phase == .running || session.phase == .paused else { return nil }
        let schedule = coordinator.labCommandSchedule() ?? LabCommandSchedule(
            sessionID: session.sessionID, epoch: session.epoch, requestedTick: session.simTick)
        guard schedule.sessionID == captured.sessionID, schedule.epoch == captured.epoch,
              let id = sendCommand(command, scheduleOverride: schedule) else { return nil }
        return (id, pendingCommandSchedules[id] ?? schedule)
    }

    private var editIdentity: WorldEditorIdentity? {
        guard let bridge else { return nil }
        let s = coordinator.sessionSnapshot()
        return WorldEditorIdentity(generation: bridge.connectionGeneration, sessionID: s.sessionID, epoch: s.epoch)
    }

    /// Edit ▸ Undo/Redo outside a text field: send the step's inverse (or its
    /// edit again) as an ordinary revision-checked edit.
    private func stepEditHistory(_ direction: WorldEditHistory.Direction) {
        guard let bridge, let identity = editIdentity else { return }
        editHistory.observe(identity: identity)
        let owner = WorldEditOwnerState(objects: arenaPlacement.worldObjects, world: bridge.latestLabState()?.worldState)
        guard let command = editHistory.command(direction, owner: owner,
                                                capabilities: bridge.environmentCapabilities()) else {
            presentEditHistory(); return
        }
        let targetsObject = command.objectEdit != nil || command.edit?.targetID != nil
        if targetsObject && viewerFrameStale {
            editHistory.sendFailed()
        } else if let (id, schedule) = sendEdit(command, captured: identity) {
            editHistory.began(commandID: id, schedule: schedule, direction: direction)
        } else {
            editHistory.sendFailed()
        }
        presentEditHistory()
    }

    /// Shows the history's latest word where its setting lives.
    private func presentEditHistory() {
        let text = editHistory.message, error = editHistory.isError
        guard !text.isEmpty else { return }
        switch editHistory.messageChange {
        case .property(let pid, nil, _, _)?:
            environmentPanel.showHistory(propertyID: pid, text: text, isError: error)
        default:
            worldEditor.showHistory(text, isError: error)
        }
    }

    /// Each ACK resolves its timeline row once; only that first resolution is
    /// recorded, so the repeated `ack` field of lab_state never double-counts.
    private func handle(ack: LabAck) {
        acceptScene(ack)
        worldEditor.accept(ack)
        environmentPanel.accept(ack)
        if editHistory.accept(ack) {
            presentEditHistory()
            recorder.mark(kind: "edit_history", detail: editHistory.message, commandID: ack.id)
        }
        if ack.id == lastFoodCommandID {
            lastFoodCommandID = nil
            foodStatusLabel.stringValue = ack.ok ? L("Placed", "놓았습니다")
                : L("Not placed — ", "놓지 못함 — ") + ((ack.status == "rejected_capacity" || ack.message.hasPrefix("no free "))
                    ? Self.slotBudgetText(shape: "food", total: bridge?.latestLabState()?.authoritativeSlotCapacity?["food"])
                    : ack.message)
            foodStatusLabel.textColor = ack.ok ? .systemGreen : .systemRed
        }
        coordinator.noteLabAck(ack)
        interactionPresentation.accept(ack: ack)
        guard timeline.apply(ack: ack) else { return }
        let s = coordinator.sessionSnapshot()
        let request = pendingCommandSchedules.removeValue(forKey: ack.id)
        recorder.mark(kind: "lab_command_result",
                      detail: "\(ack.action.isEmpty ? lastCommandAction : ack.action) \(ack.ok ? "OK" : "ERR") \(ack.message)",
                      commandID: ack.id,
                      sessionID: ack.sessionID ?? s.sessionID,
                      epoch: ack.epoch ?? s.epoch,
                      // An interactive ACK's sim_tick is the session's begin tick.
                      simTick: s.mode == .deterministic ? (ack.simTick ?? s.simTick) : s.simTick,
                      requestedTick: request?.requestedTick,
                      appliedTick: ack.appliedTick,
                      appliedEpoch: ack.appliedEpoch,
                      status: ack.status ?? (ack.ok ? "applied" : "rejected"))
        if ack.id == lastObjectCommandID {
            if ack.ok {
                let tick = ack.appliedTick.map { L(" at tick \($0)", " (시각 \($0) ms)") } ?? ""
                worldObjectStatusLabel.stringValue = L("Object status — OK · \(lastObjectCommandDescription)\(tick)", "물체 상태 — 완료 · \(lastObjectCommandDescription)\(tick)")
                worldObjectStatusLabel.textColor = .systemGreen
                if ack.action.hasPrefix("spawn_") {
                    viewState.selectObject(lastObjectCommandTarget)
                }
            } else {
                var message = ack.message.isEmpty ? L("command rejected", "명령 거절됨") : ack.message
                if ack.status == "rejected_capacity" || ack.message.hasPrefix("no free ") {
                    let shape = ack.message.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
                    message = Self.slotBudgetText(shape: shape, total: bridge?.latestLabState()?.authoritativeSlotCapacity?[shape])
                }
                worldObjectStatusLabel.stringValue = L("Object status — ERROR · ", "물체 상태 — 오류 · ") + message
                worldObjectStatusLabel.textColor = .systemRed
            }
        }
        if let pending = gunCommandPending, ack.id == pending.id {
            gunCommandPending = nil
            if ack.ok {
                playerController.setGunEquipped(pending.equipped)
                refreshGunStatus()
            } else {
                showGunNote(L("rejected: ", "거절됨: ") + ack.message, color: .systemRed)
            }
        }
        if ack.id == lastFireCommandID {
            lastFireCommandID = nil
            if !ack.ok {
                // The backend is authoritative: a shot refused for a missing gun
                // means our equipped mirror is stale.
                if ack.message.contains("equipped gun required") { playerController.setGunEquipped(false) }
                showGunNote(L("shot rejected: ", "발사 거절됨: ") + ack.message, color: .systemOrange)
            }
        }
        if participantCommandPending.consumeAck(commandID: ack.id) {
            if ack.ok {
                // Do not switch mode from the ACK alone. The next atomic
                // world snapshot must confirm player presence/absence;
                // LabViewState.accept(snapshot:) is the authority gate.
                worldViewerStatusLabel.stringValue = L("3D world — participant command applied; waiting for atomic snapshot…", "3D 화면 — 참여자 명령 적용됨, 화면 갱신을 기다리는 중…")
                worldViewerStatusLabel.textColor = .secondaryLabelColor
            } else {
                viewState.rejectModeTransition()
                let message = ack.message.isEmpty ? L("participant command rejected", "참여자 명령 거절됨") : ack.message
                worldViewerStatusLabel.stringValue = L("3D world — participant ERROR · ", "3D 화면 — 참여자 오류 · ") + message
                worldViewerStatusLabel.textColor = .systemRed
            }
        }
    }

    /// Assembles the one WorkspaceSnapshot and renders every region that shows
    /// connection, session or recording state from it.
    func refreshWorkspace(session suppliedSession: LabSessionSnapshot? = nil) {
        let session = suppliedSession ?? coordinator.sessionSnapshot()
        let recording: WorkspaceRecording
        switch recorder.state {
        case .recording:
            recording = .recording(path: recorder.path ?? "",
                                   elapsed: Date().timeIntervalSince(recordingPresentation.startedAt ?? Date()))
        case .stopping:
            recording = .stopping(path: recorder.path)
        default:
            recording = recordingPresentation.outcome
        }
        let body = bridge?.bodyFreshness()
        let snapshot = WorkspaceSnapshot(
            connection: WorkspaceSnapshot.connection(
                bridgeEnabled: bridge != nil, service: service?.state,
                connected: bridge?.connected == true,
                bodyFresh: body?.isFresh == true, bodyAge: body?.ageSeconds,
                pausedOwnerFresh: session.phase == .paused
                    && bridge?.labStateFreshness().isFresh == true),
            session: session,
            recording: recording,
            pendingCommands: timeline.pendingCount,
            backendDetail: backendDetail)
        workspace = snapshot

        protocolLabel.stringValue = snapshot.connectionLine
        switch snapshot.connection {
        case .live, .disabled: protocolLabel.textColor = .labelColor
        case .backendDown: protocolLabel.textColor = .systemRed
        case .connecting, .stale: protocolLabel.textColor = .systemOrange
        }
        recorderLabel.stringValue = snapshot.recording.line
        if case .failed = snapshot.recording {
            recorderLabel.textColor = .systemRed
        } else {
            recorderLabel.textColor = snapshot.recording.isActive ? .labelColor : .secondaryLabelColor
        }

        let badge: String?
        switch snapshot.connection {
        case .live:
            badge = viewerFrameStale ? L("Old frame — waiting for a fresh backend snapshot", "오래된 화면 — 새 화면을 기다리는 중") : nil
        case .disabled:
            badge = nil
        default:
            badge = snapshot.connection.title
                + (worldViewer.currentSnapshotSource == nil ? "" : L(" — showing the last known state", " — 마지막 상태를 보여주는 중"))
        }
        canvasBadge.stringValue = badge ?? ""
        canvasStatusHUD?.isHidden = badge == nil && service?.canRestart != true
        worldViewer.setAccessibilityValue(badge ?? L("Live", "실시간"))
    }

    /// With a physics backend attached, the temperature the brain uses follows
    /// the backend's applied value (lab_state) instead of being set locally
    /// before the ACK. Re-sent at most once a second while the two disagree.
    private func adoptBackendTemperature(_ applied: LabRemoteTemperature?, local t: LabTelemetry, now: Date) {
        guard let applied, bridge?.connected == true, bridge?.labStateFreshness().isFresh == true else { return }
        let celsius = min(40, max(10, applied.celsius))
        guard abs(celsius - t.temperatureC) > 1e-9 || applied.mode != t.temperatureMode else { return }
        if let last = adoptedTemperature, last.celsius == celsius, last.mode == applied.mode,
           now.timeIntervalSince(last.at) < 1 { return }
        adoptedTemperature = (celsius, applied.mode, now)
        coordinator.labSetTemperature(celsius: applied.celsius,
                                      modeledPhysiology: applied.mode == "modeled_physiology",
                                      flywireSensory: applied.mode == "flywire_sensory")
        recorder.mark(kind: applied.mode == "environment_only" ? "environment_record_only" : "sensory_model",
                      detail: "temperature_c=\(applied.celsius) mode=\(applied.mode) adopted_from_backend")
    }

    func refresh() {
        let now = Date()
        let t = coordinator.labTelemetry()
        // Every backend command carries the V4 identity, so begin the
        // interactive session as soon as the backend can take it — not only on
        // entering Participate/Edit. Otherwise a fresh launch's first
        // environment-panel edit carries a local session ID the backend has
        // never seen and is rejected as "wrong session".
        if let bridge, bridge.connected, bridge.playerInputV5_5Available {
            coordinator.ensureInteractivePlayerInputSession()
        }
        let session = coordinator.sessionSnapshot()
        viewState.sync(session: session)
        var state: LabRemoteState?
        var ack: LabAck?
        var event: LabEventNotice?

        if let bridge {
            state = bridge.latestLabState()
            ack = bridge.latestLabAck()
            event = bridge.latestLabEvent()

            let viewerGeneration = bridge.connectionGeneration
            viewState.setViewerAvailable(bridge.worldViewerV5_1Available)
            if let previousGeneration = lastViewerConnectionGeneration,
               previousGeneration != viewerGeneration {
                clearWorldViewerSnapshotPresentation(resetIdentity: true)
            }

            if bridge.worldViewerV5_1Available {
                _ = bridge.requestWorldRenderSnapshot()
                let freshSnapshot = bridge.latestWorldRenderSnapshot(maxAge: 1.0)
                viewerFrameStale = freshSnapshot == nil
                if let snapshot = freshSnapshot {
                    let identityChanged = lastViewerConnectionGeneration != viewerGeneration
                        || lastViewerSessionID != snapshot.sessionID
                        || lastViewerEpoch != snapshot.epoch
                    if identityChanged {
                        clearWorldViewerSnapshotPresentation(resetIdentity: false)
                    }
                    lastViewerConnectionGeneration = viewerGeneration
                    lastViewerSessionID = snapshot.sessionID
                    lastViewerEpoch = snapshot.epoch
                    if snapshot.ok, let snapshotID = snapshot.snapshotID, let revision = snapshot.revision {
                        let retainedSelection = worldEditor.retainSelection(viewState.selectedObjectID, snapshot: snapshot)
                        viewState.accept(snapshot: snapshot, connectionGeneration: viewerGeneration)
                        if let retainedSelection { viewState.selectObject(retainedSelection) }
                        worldViewer.apply(snapshot: snapshot)
                        updateArenaFromAtomicSnapshot(snapshot)
                        noteParticipantContact(snapshot)
                        let pickSuffix = lastPickSummary.isEmpty ? "" : " · \(lastPickSummary)"
                        let playerSuffix = snapshot.player == nil ? "" : L(" · participant body", " · 참여자 있음")
                        setStatus(worldViewerStatusLabel, L("3D world — snapshot #\(snapshotID) · rev \(revision) · tick \(snapshot.simTick) · \(snapshot.objects.count) objects\(playerSuffix)\(pickSuffix)", "3D 화면 — 시각 \(snapshot.simTick) ms · 물체 \(snapshot.objects.count)개\(playerSuffix)\(pickSuffix)"))
                        if worldViewerStatusLabel.textColor != (.secondaryLabelColor) { worldViewerStatusLabel.textColor = .secondaryLabelColor }
                    } else {
                        setStatus(worldViewerStatusLabel, L("3D world — snapshot error: ", "3D 화면 — 화면 오류: ") + (snapshot.error ?? L("backend rejected request", "시뮬레이터가 요청을 거절함")))
                        if worldViewerStatusLabel.textColor != (.systemRed) { worldViewerStatusLabel.textColor = .systemRed }
                    }
                } else {
                    let ownerChanged = lastViewerSessionID != nil &&
                        (lastViewerSessionID != session.sessionID || lastViewerEpoch != session.epoch)
                    if ownerChanged {
                        clearWorldViewerSnapshotPresentation(resetIdentity: false)
                        lastViewerSessionID = nil
                        lastViewerEpoch = nil
                    }
                    lastViewerConnectionGeneration = viewerGeneration
                    worldViewerStatusLabel.stringValue = worldViewer.currentSnapshotSource == nil
                        ? L("3D world — waiting for atomic backend snapshot…", "3D 화면 — 시뮬레이터 화면을 기다리는 중…")
                        : L("3D world — old frame; controls wait for a fresh backend snapshot", "3D 화면 — 오래된 화면입니다. 새 화면이 오면 조작할 수 있습니다")
                    if worldViewerStatusLabel.textColor != (.systemOrange) { worldViewerStatusLabel.textColor = .systemOrange }
                }
                if let pick = bridge.latestRayPickResult() {
                    switch worldViewerPickDisposition(
                        pick,
                        latestRequestSeq: lastPickRequestSeq,
                        consumedSeq: lastAppliedPickSeq,
                        expectedSource: lastPickSource) {
                    case .ignore:
                        break
                    case .showError:
                        lastAppliedPickSeq = pick.seq
                        lastPickSummary = L("pick #\(pick.seq) error: ", "선택 오류: ") + (pick.error ?? L("rejected", "거절됨"))
                        setStatus(worldViewerStatusLabel, "3D world — \(lastPickSummary)")
                        if worldViewerStatusLabel.textColor != (.systemRed) { worldViewerStatusLabel.textColor = .systemRed }
                    case .applySuccess:
                        lastAppliedPickSeq = pick.seq
                        worldViewer.apply(pickResult: pick)
                        viewState.apply(pick: pick)
                        if pick.targetKind == "lab_object", let targetID = pick.targetID {
                            objectID.stringValue = targetID
                            lastAutoObjectID = nil
                        }
                        if pick.hit {
                            lastPickSummary = LabLanguage.current == .korean
                                ? String(format: "선택: %@ · 거리 %.1f mm", pick.targetID ?? "대상", pick.distanceMM ?? 0)
                                : String(format: "pick #%d %@ · %.1f mm",
                                                     pick.seq, pick.targetID ?? "hit", pick.distanceMM ?? 0)
                        } else {
                            lastPickSummary = L("pick #\(pick.seq) miss", "선택: 빈 곳")
                        }
                    }
                }
            } else {
                viewerFrameStale = false
                clearWorldViewerSnapshotPresentation(resetIdentity: true)
                worldViewerStatusLabel.stringValue = bridge.connected
                    ? L("3D world — unavailable: backend does not advertise world_render_snapshot + ray_pick", "3D 화면 — 이 시뮬레이터는 3D 화면을 지원하지 않습니다")
                    : L("3D world — waiting for FlyGym connection…", "3D 화면 — 물리 시뮬레이터 연결을 기다리는 중…")
                if worldViewerStatusLabel.textColor != (bridge.connected ? .systemOrange : .secondaryLabelColor) { worldViewerStatusLabel.textColor = bridge.connected ? .systemOrange : .secondaryLabelColor }
                // Preserve the V4 minimap when connected to an older backend.
                if let objects = state?.authoritativeObjects {
                    arenaPlacement.worldObjects = objects
                }
                if let body = bridge.latestBody(maxAge: 3600.0) {
                    arenaPlacement.flyPose = (body.positionXmm, body.positionYmm, body.headingRad)
                } else {
                    arenaPlacement.flyPose = nil
                }
            }
            if let capacity = state?.authoritativeSlotCapacity {
                let free = state?.authoritativeSlotFree ?? [:]
                let order = ["box", "sphere", "wall", "ramp", "food", "car", "trap"]
                let parts = order.compactMap { shape -> String? in
                    guard let total = capacity[shape] else { return nil }
                    let remain = free[shape] ?? max(0, total - (state?.authoritativeObjects?.filter { $0.shape == shape }.count ?? 0))
                    return "\(shape) \(total - remain)/\(total)"
                }
                setStatus(worldCapacityLabel, L("Object capacity — ", "물체 수 (사용/최대) — ") + parts.joined(separator: " · "))
            }
            refreshToyInspector(objects: state?.authoritativeObjects)
            let editorSession = session
            worldEditor.update(objects: arenaPlacement.worldObjects,
                               selectedID: viewState.selectedObjectID,
                               capabilities: bridge.environmentCapabilities(),
                               identity: WorldEditorIdentity(generation: bridge.connectionGeneration,
                                                             sessionID: editorSession.sessionID, epoch: editorSession.epoch),
                               mode: viewState.mode,
                               available: workspace?.acceptsBackendCommands == true && !viewerFrameStale && viewState.viewerAvailable,
                               heldID: state?.interaction?.heldObjectID, camera: worldViewer.mujocoCamera)
            let historyMessage = editHistory.message
            editHistory.observe(identity: WorldEditorIdentity(generation: bridge.connectionGeneration,
                                                              sessionID: editorSession.sessionID, epoch: editorSession.epoch))
            if editHistory.message != historyMessage { presentEditHistory() }
            let (newAcks, cursor) = bridge.labAcks(after: ackCursor)
            ackCursor = cursor
            newAcks.forEach(handle(ack:))
            timeline.expire(now: now, connectionGeneration: bridge.connectionGeneration)
            let (newEvents, nextEventCursor) = bridge.labEvents(after: eventCursor)
            eventCursor = nextEventCursor
            for notice in newEvents where !notice.event.isEmpty {
                let detail = notice.detail?.summary ?? ""
                let text = LabToy.eventLine(notice.event, notice.detail)
                    ?? (detail.isEmpty ? notice.event : "\(notice.event) — \(detail)")
                noteLocal("event", text, kind: .physical, status: .event, tick: notice.detail?.simTickMS)
                let s = session
                recorder.mark(kind: "lab_event", detail: notice.recordDetail,
                              sessionID: s.sessionID, epoch: s.epoch, simTick: s.simTick)
            }

            if eyeCommandPendingID != nil {
                let stateFresh = bridge.labStateFreshness().isFresh
                let observed: Bool?
                if eyeCommandSide == "left" { observed = state?.leftEyeCovered }
                else if eyeCommandSide == "right" { observed = state?.rightEyeCovered }
                else { observed = nil }
                if stateFresh, let expected = eyeCommandCovered, observed == expected {
                    clearEyePending()
                } else if bridge.connected,
                          let started = eyeCommandStartedAt,
                          now.timeIntervalSince(started) > 5 {
                    // Avoid permanently trapping the controls if an old command
                    // was dropped from the bounded queue. A later eye command is
                    // still serialized one-at-a-time by this UI.
                    clearEyePending()
                }
            }
        }

        // Paused: body packets stop on purpose, so show the last one as paused
        // rather than as missing (same rule as the workspace connection).
        let bodyPaused = session.phase == .paused && bridge?.labStateFreshness().isFresh == true
        environmentPanel.update(
            state: state, telemetry: t,
            body: bodyPaused ? bridge?.latestBody(maxAge: .greatestFiniteMagnitude) : bridge?.latestBody(),
            bodyPaused: bodyPaused,
            identity: bridge.map { WorldEditorIdentity(generation: $0.connectionGeneration,
                                                       sessionID: session.sessionID, epoch: session.epoch) },
            backendConnected: bridge?.connected == true,
            available: workspace?.acceptsBackendCommands == true, now: now)
        adoptBackendTemperature(state?.worldState?.temperature, local: t, now: now)
        refreshWorkspace(session: session)
        renderViewState(session: session)
        refreshGunStatus()
        updateMood(t, now: now)
        activityCards.update(ActivityCardInput(telemetry: t, brainSimLoaded: coordinator.sim != nil))
        let rows = timeline.recent(5).map(\.line)
        timelineLabel.stringValue = rows.isEmpty
            ? L("t\(session.simTick) · No commands yet — stimuli, markers and their ACKs appear here", "아직 명령이 없습니다 — 자극, 구간 표시와 그 결과가 여기에 나타납니다")
            : rows.joined(separator: "\n")
        responseLabel.stringValue = String(format: L(
            "body %.0f ms old · speed %.4f m/s · contact %.2f · eye sample t%d · loom L/R %.3f/%.3f · brain %.1f Hz",
            "몸 데이터 %.0f ms 전 · 속도 %.4f m/s · 발 닿음 %.2f · 눈 샘플 t%d · 다가옴 감지 L/R %.3f/%.3f · 뇌 활동 %.1f Hz"),
            max(0, t.bodyPacketAgeS * 1000), t.bodyVX, t.bodyContactMean,
            t.bodyEyeSampleSimTick, t.loomL, t.loomR, t.ratePop)
        if responseLabel.textColor != ((bridge?.bodyFreshness().isFresh == true) ? .secondaryLabelColor : .systemOrange) { responseLabel.textColor = (bridge?.bodyFreshness().isFresh == true) ? .secondaryLabelColor : .systemOrange }

        if let result = bridge?.latestPlayerInputResult(),
           result.seq == lastPlayerInputSeq {
            if result.ok {
                setStatus(playerInputStatusLabel, L("Participant controls — input #\(result.seq) applied at tick \(result.appliedTick ?? result.requestedTick)", "참여 조작 — 입력 적용됨 (시각 \(result.appliedTick ?? result.requestedTick) ms)"))
                if playerInputStatusLabel.textColor != (.systemGreen) { playerInputStatusLabel.textColor = .systemGreen }
            } else {
                setStatus(playerInputStatusLabel, L("Participant controls — input rejected: ", "참여 조작 — 입력 거절됨: ") + (result.error ?? result.status))
                if playerInputStatusLabel.textColor != (.systemRed) { playerInputStatusLabel.textColor = .systemRed }
            }
        }

        if window?.isVisible == true {
            neuralGraph.append([t.ratePop, t.rateLoom, t.rateFwd, t.rateMDN, t.rateGroom])
            commandGraph.append([t.rateDNaL, t.rateDNaR, t.rateMDN, t.rateFwd, t.rateGroom, t.rateEscW])
            sensoryGraph.append([t.loomL, t.loomR, t.airPuff, t.gaitDrive])
            flywireSensoryGraph.append([t.odorDriveL, t.odorDriveR, t.thermoWarmDrive,
                                        t.thermoCoolDrive, t.windCDrive, t.windEDrive])
            let distanceScaled = t.bodyNearestFoodDistanceMm >= 0 ? min(1.2, t.bodyNearestFoodDistanceMm / 100.0) : 0
            bodyGraph.append([t.bodyVX * 20, t.bodyYawRate / 5, t.bodyContactMean,
                              max(t.bodyLoomL, t.bodyLoomR), t.bodyOdorL, t.bodyOdorR,
                              distanceScaled])
            let nearest = t.bodyNearestFoodDistanceMm >= 0
                ? String(format: "%.1f mm", t.bodyNearestFoodDistanceMm)
                : L("none", "없음")
            bodyTelemetryLabel.stringValue = String(format: L("Movement — speed %.4f m/s · turn %.2f rad/s · contact %.2f", "움직임 — 속도 %.4f m/s · 회전 %.2f rad/s · 발 닿음 %.2f"),
                                                     t.bodyVX, t.bodyYawRate, t.bodyContactMean)
            let eating = t.bodyTasteSugar > 0
                ? String(format: L("eating (sugar %.2f)", "먹는 중 (당 %.2f)"), t.bodyTasteSugar)
                : L("not eating", "먹지 않음")
            foodTelemetryLabel.stringValue = String(format: L("Food odor — left %.3f · right %.3f · nearest source: %@ · ORN %.1f/%.1f Hz\nTaste — %@ · sugar GRN %.1f Hz · MN9 %.1f Hz", "먹이 냄새 — 왼쪽 %.3f · 오른쪽 %.3f · 가장 가까운 먹이: %@ · 후각 뉴런 %.1f/%.1f Hz\n맛 — %@ · 당 미각 뉴런 %.1f Hz · MN9 %.1f Hz"),
                                                     t.bodyOdorL, t.bodyOdorR, nearest,
                                                     t.rateFoodOdorL, t.rateFoodOdorR,
                                                     eating, t.rateSugarGRN, t.rateMN9)
            visionGraph.append([t.bodyBrightnessL, t.bodyBrightnessR, t.bodyOccupancyL,
                                t.bodyOccupancyR, t.bodyOpticExpansionL, t.bodyOpticExpansionR])
            let eyeSample: String
            if t.bodyEyeSampleSimTick >= 0 {
                let bodyTick = max(0, Int((t.bodySimTime * 1000.0).rounded()))
                let ageMs = max(0, bodyTick - t.bodyEyeSampleSimTick)
                eyeSample = L("raw-eye sample tick \(t.bodyEyeSampleSimTick) ms · \(ageMs) ms old", "눈 화면 \(ageMs) ms 전")
            } else {
                eyeSample = L("raw-eye sample not rendered yet", "아직 눈 화면 없음")
            }
            visionTelemetryLabel.stringValue = String(format: L("Vision — expansion L/R %.3f/%.3f · brightness L/R %.3f/%.3f · %@", "시각 — 커짐 L/R %.3f/%.3f · 밝기 L/R %.3f/%.3f · %@"),
                                                       t.bodyOpticExpansionL, t.bodyOpticExpansionR,
                                                       t.bodyBrightnessL, t.bodyBrightnessR, eyeSample)
        }

        signalPathLabel.stringValue = LabStatusText.signalPath(t)

        recorder.append(t)

        if let bridge {
            let origin = service.map { L("\($0.mode.rawValue) backend :\($0.port)", "시뮬레이터(\($0.mode.rawValue)) :\($0.port)") }
                ?? L("external bridge :\(bridge.port)", "외부 시뮬레이터 :\(bridge.port)")
            if bridge.connected {
                let hz = bridge.bodyHz
                let dropped = bridge.labDropped
                let degraded = hz > 0 && hz < 30 ? L(" · DEGRADED: body feedback below 30 Hz", " · 느림: 몸 데이터가 초당 30회 미만") : ""
                let ratio = t.bodyPacketAgeS >= 0 ? String(format: L(" · sim/wall %.2fx", " · 실시간 대비 %.2f배"), t.bodySimWallRatio) : ""
                backendDetail = String(format: L("%@ · body feedback %.0f Hz%@%@%@", "%@ · 몸 데이터 초당 %.0f회%@%@%@"), origin,
                                       hz, ratio, degraded,
                                       dropped > 0 ? L(" · \(dropped) UI command\(dropped == 1 ? "" : "s") dropped", " · 명령 \(dropped)개 버려짐") : "")
            } else if let service, service.state == .running, let started = service.startedAt {
                let elapsed = Int(now.timeIntervalSince(started))
                var bits = [L("starting \(origin) · \(elapsed) s", "시작 중 \(origin) · \(elapsed)초")]
                let last = service.lastOutputLine
                if !last.isEmpty { bits.append(last) }
                if service.runtimeIsCloudEvicted {
                    bits.append(L("Python packages are iCloud-only (Optimize Mac Storage) and download on first use — set the project folder to Keep Downloaded",
                                  "파이썬 패키지가 iCloud에만 있어 처음 쓸 때 내려받습니다(맥 저장 공간 최적화) — 프로젝트 폴더를 ‘다운로드 유지’로 설정하세요"))
                } else if elapsed > 90 {
                    bits.append(L("slow start — log: ", "시작이 느립니다 — 기록 파일: ") + "~/Library/Logs/Thongpari Virtual Fly Lab/bridge.log")
                }
                backendDetail = bits.joined(separator: " · ")
            } else {
                backendDetail = origin + L(" · brain simulation continues locally", " · 뇌 계산은 앱 안에서 계속됩니다")
            }

            let bodyFreshness = bridge.bodyFreshness()
            let stateFreshness = bridge.labStateFreshness()
            let noPacket = L("no packet", "없음")
            let bodyAge = bodyFreshness.ageSeconds.map(ageString) ?? noPacket
            let stateAge = stateFreshness.ageSeconds.map(ageString) ?? noPacket
            let fresh = { (ok: Bool) in ok ? L("FRESH", "최신") : L("STALE", "오래됨") }
            let bodyStatus = L("body", "몸") + " \(fresh(bodyFreshness.isFresh)) \(bodyAge)"
            let envStatus = L("environment", "환경") + " \(fresh(stateFreshness.isFresh)) \(stateAge)"
            setStatus(freshnessLabel, L("Packets — ", "데이터 — ") + "\(bodyStatus) · \(envStatus)")

            setStatus(remoteStateLabel, LabStatusText.remoteState(state, event: event?.event))

            let sleeping = t.brainSleep
            let gate = sleeping ? 0.55 : 1.0
            var commandBits = [L("Brain state — sleep ", "뇌 상태 — 잠 ") + onOff(sleeping)
                               + L(" · sensoryGate ×", " · 감각 통과율 ×") + String(format: "%.2f", gate)]
            if let lastCommandID {
                commandBits.append(L("sent #", "보낸 명령 #") + "\(lastCommandID) \(lastCommandAction)")
            } else {
                commandBits.append(L("sent: none", "보낸 명령 없음"))
            }
            if let ack {
                let age = ageString(ack.ageSeconds(at: now))
                let ackFreshness = bridge.labAckFreshness()
                let message = ack.message.isEmpty ? "" : " · \(ack.message)"
                commandBits.append(LabLanguage.current == .korean
                    ? "확인 #\(ack.id) \(ack.ok ? "성공" : "오류") · \(ackFreshness.isFresh ? "최신" : "오래됨") · \(ack.action)\(message) · \(age) 전"
                    : "ack #\(ack.id) \(ack.ok ? "OK" : "ERROR") · \(ackFreshness.isFresh ? "FRESH" : "STALE") · \(ack.action)\(message) · seen \(age) ago")
            } else {
                commandBits.append(L("ack: none yet", "확인 아직 없음"))
            }
            if let action = state?.lastAction, !action.isEmpty { commandBits.append(L("bridge last action: ", "시뮬레이터 마지막 동작: ") + action) }
            if let error = state?.error, !error.isEmpty { commandBits.append(L("ERROR: ", "오류: ") + error) }
            commandBits.append(L("queue ", "대기열 ") + "\(bridge.pendingLabDepth())")
            setStatus(commandDiagnosticsLabel, commandBits.joined(separator: "\n"))
        } else {
            freshnessLabel.stringValue = L("Packets — body STALE · bridge disabled · environment STALE · bridge disabled",
                                           "데이터 — 물리 시뮬레이터가 꺼져 있어 몸·환경 데이터가 없습니다")
            setStatus(remoteStateLabel, L("Environment — local brain/sensory controls are still available", "환경 — 시뮬레이터 없이도 뇌·감각 조작은 쓸 수 있습니다"))
            let sleeping = t.brainSleep
            setStatus(commandDiagnosticsLabel, L("Brain state — sleep ", "뇌 상태 — 잠 ") + onOff(sleeping)
                + L(" · sensoryGate ×", " · 감각 통과율 ×") + (sleeping ? "0.55" : "1.00")
                + L("\nCommands — FlyGym bridge disabled", "\n명령 — 물리 시뮬레이터 꺼짐"))
        }
    }
}

#if DIAGNOSTICS
extension LabWindowController {
    /// `--envpanelshot`: draws the real environment page offscreen with a given
    /// owner state. Layout evidence only — not a GUI acceptance test.
    func renderEnvironmentPage(state: LabRemoteState, body: FlyGymBodyFeedback?,
                               dark: Bool, to url: URL) -> Bool {
        let page = sensesPage()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = page
        window.setContentSize(NSSize(width: 380, height: 900))
        var telemetry = LabTelemetry()
        telemetry.temperatureC = 31.5; telemetry.temperatureMode = "flywire_sensory"
        telemetry.thermoWarmDrive = 0.039; telemetry.windCDrive = 0.012; telemetry.windEDrive = 0.043
        telemetry.bodyBrightnessL = 0.0; telemetry.bodyBrightnessR = 0.27; telemetry.bodyEyeSampleSimTick = 12_400
        telemetry.bodyOdorL = 0.31; telemetry.bodyOdorR = 0.12; telemetry.bodyNearestFoodDistanceMm = 20.1
        telemetry.bodyPacketAgeS = 0.03
        let identity = WorldEditorIdentity(generation: 1, sessionID: "shot", epoch: 1)
        environmentPanel.update(state: state, telemetry: telemetry, body: body, identity: identity,
                                backendConnected: true, available: true)
        environmentPanel.update(state: state, telemetry: telemetry, body: body, identity: identity,
                                backendConnected: true, available: true, now: Date().addingTimeInterval(2))
        let p = environmentPanel
        print(String(format: "slider values: temperature %.2f wind %.2f dial %.0f left-mask %.2f right-mask %.2f",
                     p.temperatureSlider.doubleValue, p.windStrengthSlider.doubleValue,
                     p.windDirectionDial.doubleValue, p.leftMaskSlider.doubleValue, p.rightMaskSlider.doubleValue))
        guard let document = (page.view as? NSScrollView)?.documentView else { return false }
        window.layoutIfNeeded()
        document.layoutSubtreeIfNeeded()
        let bounds = document.bounds
        guard bounds.height > 0, let rep = document.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        document.cacheDisplay(in: bounds, to: rep)
        // The cached view is transparent; flatten it onto the window background.
        guard let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: flat) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Fixed stand-ins for the window background (dynamic colors don't resolve here).
        NSColor(deviceWhite: dark ? 0.16 : 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = flat.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

#endif
