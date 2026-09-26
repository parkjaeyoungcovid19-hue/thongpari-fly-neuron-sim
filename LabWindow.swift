// LabWindow.swift — AppKit Virtual Fly Lab integrated control/telemetry window.

import Cocoa

private final class LabArenaPlacementView: NSView {
    var onPick: ((Double, Double) -> Void)?
    var selectedShape: String = "box" { didSet { needsDisplay = true } }
    var selectedPoint: (x: Double, y: Double)? { didSet { needsDisplay = true } }
    var worldObjects: [LabWorldObjectRemote] = [] { didSet { needsDisplay = true } }
    var flyPose: (x: Double, y: Double, heading: Double)? { didSet { needsDisplay = true } }

    private let minimumExtentMm = 100.0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 250) }

    private func visibleExtentMm() -> Double {
        var required = minimumExtentMm
        func include(_ x: Double, _ y: Double, pad: Double = 0) {
            required = max(required, abs(x) + pad, abs(y) + pad)
        }
        if let selectedPoint { include(selectedPoint.x, selectedPoint.y, pad: 8) }
        if let flyPose { include(flyPose.x, flyPose.y, pad: 8) }
        for obj in worldObjects {
            let sx = obj.sizeMM.indices.contains(0) ? abs(obj.sizeMM[0]) : 5
            let sy = obj.sizeMM.indices.contains(1) ? abs(obj.sizeMM[1]) : sx
            include(obj.positionMM.indices.contains(0) ? obj.positionMM[0] : 0,
                    obj.positionMM.indices.contains(1) ? obj.positionMM[1] : 0,
                    pad: max(sx, sy) * 0.75 + 5)
        }
        let padded = required * 1.10
        for candidate in [100.0, 150, 200, 300, 500, 750, 1000, 1500, 2000] where padded <= candidate {
            return candidate
        }
        return ceil(padded / 500.0) * 500.0
    }

    private func plotGeometry() -> (extent: Double, scale: Double, rect: NSRect) {
        let extent = visibleExtentMm()
        let side = max(1.0, min(bounds.width, bounds.height) - 16.0)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                          width: side, height: side)
        return (extent, Double(side) / (2.0 * extent), rect)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let g = plotGeometry()
        guard g.scale > 0, g.rect.contains(p) else { return }
        // Top-down lab convention: screen up = +X (forward), screen left = +Y.
        let x = max(-g.extent, min(g.extent, Double(p.y - g.rect.midY) / g.scale))
        let y = max(-g.extent, min(g.extent, Double(g.rect.midX - p.x) / g.scale))
        selectedPoint = (x, y)
        onPick?(x, y)
    }

    private func point(x: Double, y: Double, geometry g: (extent: Double, scale: Double, rect: NSRect)) -> CGPoint {
        CGPoint(x: g.rect.midX - CGFloat(y * g.scale),
                y: g.rect.midY + CGFloat(x * g.scale))
    }

    private func objectPath(_ obj: LabWorldObjectRemote,
                            geometry g: (extent: Double, scale: Double, rect: NSRect)) -> NSBezierPath {
        let x = obj.positionMM.indices.contains(0) ? obj.positionMM[0] : 0
        let y = obj.positionMM.indices.contains(1) ? obj.positionMM[1] : 0
        let sx = max(0.2, obj.sizeMM.indices.contains(0) ? abs(obj.sizeMM[0]) : 5)
        let sy = max(0.2, obj.sizeMM.indices.contains(1) ? abs(obj.sizeMM[1]) : sx)
        if obj.shape == "sphere" || obj.shape == "food" {
            let c = point(x: x, y: y, geometry: g)
            let d = max(2.0, CGFloat(sx * g.scale))
            return NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        }

        let hx = sx * 0.5
        let hy = sy * 0.5
        let yaw = obj.yawDeg * Double.pi / 180.0
        let c = cos(yaw), sn = sin(yaw)
        let corners = [(-hx, -hy), (-hx, hy), (hx, hy), (hx, -hy)].map { local -> CGPoint in
            let wx = x + local.0 * c - local.1 * sn
            let wy = y + local.0 * sn + local.1 * c
            return point(x: wx, y: wy, geometry: g)
        }
        let path = NSBezierPath()
        if let first = corners.first {
            path.move(to: first)
            for p in corners.dropFirst() { path.line(to: p) }
            path.close()
        }
        return path
    }

    private func drawWorldObjects(geometry g: (extent: Double, scale: Double, rect: NSRect),
                                  labelAttrs: [NSAttributedString.Key: Any]) {
        for obj in worldObjects {
            let path = objectPath(obj, geometry: g)
            let color: NSColor
            switch obj.shape {
            case "food": color = .systemGreen
            case "wall": color = .systemPurple
            case "sphere": color = .systemPink
            default: color = .systemIndigo
            }
            color.withAlphaComponent(0.22).setFill()
            color.withAlphaComponent(0.95).setStroke()
            path.lineWidth = obj.shape == "wall" ? 2.0 : 1.4
            path.fill(); path.stroke()

            let x = obj.positionMM.indices.contains(0) ? obj.positionMM[0] : 0
            let y = obj.positionMM.indices.contains(1) ? obj.positionMM[1] : 0
            let c = point(x: x, y: y, geometry: g)
            let label = "\(obj.id) · \(obj.shape)"
            (label as NSString).draw(at: CGPoint(x: min(bounds.maxX - 140, c.x + 5),
                                                 y: min(bounds.maxY - 15, c.y + 4)),
                                     withAttributes: labelAttrs)
        }
    }

    private func drawFly(geometry g: (extent: Double, scale: Double, rect: NSRect),
                         labelAttrs: [NSAttributedString.Key: Any]) {
        guard let flyPose else { return }
        let center = point(x: flyPose.x, y: flyPose.y, geometry: g)
        // Keep the fly legible even when the arena auto-zooms far out. Position
        // and heading are authoritative; marker pixel size is intentionally UI-sized.
        let length = max(10.0, min(18.0, CGFloat(4.0 * g.scale)))
        let worldForward = point(x: flyPose.x + cos(flyPose.heading) * 5.0,
                                 y: flyPose.y + sin(flyPose.heading) * 5.0,
                                 geometry: g)
        let dx = worldForward.x - center.x, dy = worldForward.y - center.y
        let mag = max(0.001, hypot(dx, dy))
        let ux = dx / mag, uy = dy / mag
        let px = -uy, py = ux
        let tip = CGPoint(x: center.x + ux * length * 0.65, y: center.y + uy * length * 0.65)
        let tail = CGPoint(x: center.x - ux * length * 0.45, y: center.y - uy * length * 0.45)
        let left = CGPoint(x: tail.x + px * length * 0.35, y: tail.y + py * length * 0.35)
        let right = CGPoint(x: tail.x - px * length * 0.35, y: tail.y - py * length * 0.35)
        let path = NSBezierPath()
        path.move(to: tip); path.line(to: left); path.line(to: right); path.close()
        NSColor.systemGreen.withAlphaComponent(0.90).setFill()
        NSColor.systemGreen.setStroke()
        path.lineWidth = 1.5
        path.fill(); path.stroke()
        let text = String(format: L("fly  %.1f, %.1f", "파리  %.1f, %.1f"), flyPose.x, flyPose.y)
        (text as NSString).draw(at: CGPoint(x: min(bounds.maxX - 120, center.x + 8),
                                            y: max(4, center.y - 16)),
                                withAttributes: labelAttrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let g = plotGeometry()
        NSColor.windowBackgroundColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: g.rect, xRadius: 6, yRadius: 6).fill()

        let grid = NSBezierPath()
        let step: Double = g.extent <= 100 ? 25 : (g.extent <= 200 ? 50 : (g.extent <= 500 ? 100 : (g.extent <= 1000 ? 250 : 500)))
        var v = -g.extent
        while v <= g.extent + 0.001 {
            let a = point(x: -g.extent, y: v, geometry: g)
            let b = point(x: g.extent, y: v, geometry: g)
            grid.move(to: a); grid.line(to: b)
            let c = point(x: v, y: -g.extent, geometry: g)
            let d = point(x: v, y: g.extent, geometry: g)
            grid.move(to: c); grid.line(to: d)
            v += step
        }
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        grid.lineWidth = 0.7
        grid.stroke()

        let origin = point(x: 0, y: 0, geometry: g)
        let axes = NSBezierPath()
        axes.move(to: CGPoint(x: g.rect.minX, y: origin.y)); axes.line(to: CGPoint(x: g.rect.maxX, y: origin.y))
        axes.move(to: CGPoint(x: origin.x, y: g.rect.minY)); axes.line(to: CGPoint(x: origin.x, y: g.rect.maxY))
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setStroke()
        axes.lineWidth = 1.2
        axes.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let objectAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
        ]
        (L("+X forward", "+X 앞") as NSString).draw(at: CGPoint(x: origin.x + 7, y: g.rect.maxY - 16), withAttributes: attrs)
        (L("+Y left", "+Y 왼쪽") as NSString).draw(at: CGPoint(x: g.rect.minX + 6, y: origin.y + 5), withAttributes: attrs)
        (String(format: L("±%.0f mm · %d objects", "±%.0f mm · 물체 %d개"), g.extent, worldObjects.count) as NSString)
            .draw(at: CGPoint(x: g.rect.maxX - 120, y: g.rect.minY + 5), withAttributes: attrs)

        drawWorldObjects(geometry: g, labelAttrs: objectAttrs)
        drawFly(geometry: g, labelAttrs: objectAttrs)

        guard let selectedPoint else { return }
        let p = point(x: selectedPoint.x, y: selectedPoint.y, geometry: g)
        let markerRect = NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
        NSColor.systemOrange.setStroke()
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        let marker: NSBezierPath
        if selectedShape == "sphere" || selectedShape == "food" {
            marker = NSBezierPath(ovalIn: markerRect)
        } else {
            marker = NSBezierPath(rect: markerRect)
        }
        marker.lineWidth = 2
        marker.fill(); marker.stroke()

        let coordinate = String(format: L("pick %.1f, %.1f mm", "고른 위치 %.1f, %.1f mm"), selectedPoint.x, selectedPoint.y)
        (coordinate as NSString).draw(at: CGPoint(x: min(bounds.maxX - 120, p.x + 10),
                                                  y: max(4, min(bounds.maxY - 16, p.y + 7))),
                                        withAttributes: attrs)
    }
}

final class LabWindowController: NSWindowController, NSWindowDelegate {
    private unowned let coordinator: Coordinator
    private let bridge: FlyGymBridge?
    private let recorder = ExperimentRecorder()
    private var brainController: BrainWindowController?
    private var timer: Timer?
    private let timelineLabel = NSTextField(wrappingLabelWithString: L("No commands yet", "아직 명령 없음"))
    private let responseLabel = NSTextField(wrappingLabelWithString: L("Waiting for body and eye samples", "몸·눈 데이터를 기다리는 중"))
    private let recordButton = NSButton(title: L("Record", "기록"), target: nil, action: nil)
    private let runButton = NSButton(title: L("Pause", "일시 정지"), target: nil, action: nil)
    private let protocolLabel = NSTextField(labelWithString: L("FlyGym bridge — starting…", "물리 시뮬레이터 연결 — 시작 중…"))
    private let remoteStateLabel = NSTextField(labelWithString: L("Environment — waiting for state…", "환경 — 상태를 기다리는 중…"))
    private let recorderLabel = NSTextField(labelWithString: L("not recording", "기록 안 함"))
    private let freshnessLabel = NSTextField(labelWithString: L("Packets — waiting for body/environment telemetry…", "데이터 — 몸/환경 정보를 기다리는 중…"))
    private let commandDiagnosticsLabel = NSTextField(wrappingLabelWithString: L("Commands — no command sent yet", "명령 — 아직 보낸 명령 없음"))
    private let signalPathLabel = NSTextField(wrappingLabelWithString: L("Signal path — waiting for telemetry…", "신호 경로 — 데이터를 기다리는 중…"))
    private let sessionStatusLabel = NSTextField(wrappingLabelWithString: L("Session — interactive", "세션 — 실시간"))
    private let viewStateLabel = NSTextField(wrappingLabelWithString: "View — OBSERVE · fly fly · object none · tick 0 ms · RUNNING")
    /// Edit is a later-version contract, so the toolbar offers only these two.
    private let segmentModes: [LabViewMode] = [.observe, .participate]
    private let viewModeControl = NSSegmentedControl(labels: ["Observe", "Participate"],
                                                     trackingMode: .selectOne,
                                                     target: nil, action: nil)
    private let temperatureModeStatusLabel = NSTextField(wrappingLabelWithString: L("Neural input: OFF — environment-only temperature is recorded without neural input.", "신경 입력 끔 — 온도는 기록만 하고 뇌에는 전달하지 않습니다."))

    private let objectID = NSTextField(string: "")
    private let objectShape = NSPopUpButton(frame: .zero, pullsDown: false)
    private let objectX = NSTextField(string: "60")
    private let objectY = NSTextField(string: "0")
    private let objectZ = NSTextField(string: "5")
    private let objectSize = NSTextField(string: "5")
    private let objectSpeed = NSTextField(string: "12")
    private let objectEndDistance = NSTextField(string: "8")
    private let worldObjectStatusLabel = NSTextField(wrappingLabelWithString: L("Object status — ready", "물체 상태 — 준비됨"))
    private let worldCapacityLabel = NSTextField(wrappingLabelWithString: L("Object capacity — waiting for backend…", "물체 수 — 시뮬레이터를 기다리는 중…"))
    private let worldViewer = WorldViewer(frame: .zero)
    private let worldViewerStatusLabel = NSTextField(wrappingLabelWithString: L("3D world — waiting for V5.1 backend capability…", "3D 화면 — 시뮬레이터 준비를 기다리는 중…"))
    private let observationCameraMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerInputStatusLabel = NSTextField(wrappingLabelWithString: L("Participant controls — waiting for V5.5 player_input capability…", "참여 조작 — 시뮬레이터 준비를 기다리는 중…"))
    private let interactionStatusLabel = NSTextField(wrappingLabelWithString: L("Interaction state unknown", "상호작용 상태 알 수 없음"))
    private let playerForwardKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerBackwardKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerLeftKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerRightKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerInteractKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerController = PlayerController()
    private var interactionPresentation = LabInteractionPresentation()
    private var playerCaptureArmed = false
    private var lastPlayerInputConnectionGeneration: UInt64?
    private var lastPlayerInputSeq: Int?
    /// F-01: a player-input send that could not be queued already consumed the
    /// local key state. Re-send the current held state until one is queued.
    private var playerInputReconcilePending = false
    private let arenaPlacement = LabArenaPlacementView(frame: .zero)
    private let createOnArenaClick = NSButton(checkboxWithTitle: "Create selected object when clicking arena", target: nil, action: nil)
    private var autoObjectSerial: [String: Int] = [:]
    private var lastAutoObjectID: String?
    private var lastObjectCommandID: Int?
    private var lastObjectCommandTarget: String?
    private var lastObjectCommandDescription = ""

    private let windStrength = NSTextField(string: "0.7")
    private let windDuration = NSTextField(string: "500")
    private let windDirection = NSTextField(string: "0")
    private let windPhysical = NSButton(checkboxWithTitle: "physical force", target: nil, action: nil)
    private let windSensory = NSButton(checkboxWithTitle: "sensory input", target: nil, action: nil)
    private let windContinuous = NSButton(checkboxWithTitle: "continuous", target: nil, action: nil)
    private let touchStrength = NSTextField(string: "0.55")
    private let touchDuration = NSTextField(string: "150")
    private let touchTarget = NSPopUpButton(frame: .zero, pullsDown: false)
    private let temperature = NSTextField(string: "25")
    private let temperatureMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flashEye = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flashIntensity = NSTextField(string: "1.0")
    private let flashDuration = NSTextField(string: "100")

    private let brainRole = NSPopUpButton(frame: .zero, pullsDown: false)
    private let brainStrength = NSTextField(string: "0.30")
    private let brainDuration = NSTextField(string: "300")
    private let brainRoleDescription = NSTextField(wrappingLabelWithString: "")

    private let neuralGraph = LabGraphView(frame: .zero,
                                           names: ["brain", "loom", "walk", "back", "groom"])
    private let commandGraph = LabGraphView(frame: .zero,
                                           names: ["DNa L", "DNa R", "MDN", "DNp09", "DNg11", "escW"])
    private let sensoryGraph = LabGraphView(frame: .zero,
                                            names: ["loom L", "loom R", "legacy air", "gait"])
    private let flywireSensoryGraph = LabGraphView(frame: .zero,
                                                   names: ["food L", "food R", "warm", "cool", "wind C", "wind E"])
    private let bodyGraph = LabGraphView(frame: .zero,
                                         names: ["speed×20", "turn÷5", "contact", "eye loom", "food L", "food R", "distance÷100"])
    private let visionGraph = LabGraphView(frame: .zero,
                                           names: ["light L", "light R", "target L", "target R", "expand L", "expand R"])
    private let bodyTelemetryLabel = NSTextField(labelWithString: "Movement — speed 0.0000 m/s · turn 0.00 rad/s · contact 0.00")
    private let foodTelemetryLabel = NSTextField(labelWithString: "Food odor — left 0.000 · right 0.000 · nearest source: none")
    private let visionTelemetryLabel = NSTextField(labelWithString: "Vision — expansion L/R 0.000/0.000 · brightness L/R 0.000/0.000")
    private var lastPreset: String?
    private var eyeButtons: [NSButton] = []
    private var eyeCommandPendingID: Int?
    private var eyeCommandStartedAt: Date?
    private var eyeCommandSide: String?
    private var eyeCommandCovered: Bool?
    private var lastCommandID: Int?
    private var lastCommandAction = "none"
    private var lastEventReceivedAt: Date?
    private var backendDetail = ""
    private var viewerFrameStale = false
    private var pendingCommandSchedules: [Int: LabCommandSchedule] = [:]
    private var lastPickRequestSeq: Int?
    private var lastAppliedPickSeq: Int?
    private var lastPickSource: WorldViewerSnapshotSource?
    private var lastPickSummary = ""
    private var participantCommandPending = ParticipantCommandPendingState()
    private var lastViewerConnectionGeneration: UInt64?
    private var lastViewerSessionID: String?
    private var lastViewerEpoch: Int?
    private var viewState = LabViewState()
    private let service: FlyGymService?
    private var timeline = LabCommandTimeline()
    private var ackCursor: UInt64 = 0
    private var eventCursor: UInt64 = 0
    private var recordingStartedAt: Date?
    private var lastRecordingOutcome = WorkspaceRecording.idle
    private var workspace: WorkspaceSnapshot?
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
    private let moodEstimator = FlyMoodEstimator()
    private let moodEmoji = NSTextField(labelWithString: "🙂")
    private let moodTitle = NSTextField(labelWithString: "")
    private let moodReason = NSTextField(labelWithString: "")
    private let moodNote = NSTextField(labelWithString: "")
    /// Edge detector for the participant body touching the fly.
    private var participantTouchingFly = false
    private var cameraBeforeParticipate: WorldViewerCameraMode?

    init(coordinator: Coordinator, bridge: FlyGymBridge?, connectome: Connectome? = nil,
         service: FlyGymService? = nil) {
        self.coordinator = coordinator
        self.bridge = bridge
        self.service = service
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Virtual Fly Lab"
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 980, height: 620)
        w.setFrameAutosaveName("VirtualFlyLabWindow")
        PlayerInputFocusPolicy.prepareWindowForCapture(w)
        super.init(window: w)
        w.delegate = self
        if let connectome, let sim = coordinator.sim, let screen = NSScreen.main {
            brainController = BrainWindowController(connectome: connectome, sim: sim, screen: screen)
        }
        buildUI()
        brainController?.onClickStimulus = { [weak self] picked, name, strength, durationMs in
            self?.noteBrainClickStimulus(count: picked.count, name: name,
                                         strength: strength, durationMs: durationMs)
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

    private func startMuJoCoStream() {
        guard let port = service?.renderPort, port != 0 else { return }
        let stream = MuJoCoFrameStream(port: port)
        stream.onFrame = { [weak self] image in
            guard let self else { return }
            self.mujocoFrameView.show(image)
            if self.mujocoFrameView.isHidden {
                self.mujocoFrameView.isHidden = false
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
        let popups = [objectShape, touchTarget, temperatureMode, flashEye, brainRole]
        let values = popups.map { $0.selectedItem?.representedObject as? String }
        let checks = [windPhysical, windSensory, windContinuous, createOnArenaClick]
        let states = checks.map(\.state)
        buildUI()
        for (popup, value) in zip(popups, values) { if let value { selectPopupValue(popup, value) } }
        for (check, state) in zip(checks, states) { check.state = state }
        arenaPlacement.selectedShape = selectedValue(objectShape, fallback: "box")
        updateTemperatureModeStatus()
        updateBrainRoleDescription()
        refresh()
    }

    @objc private func languagePicked(_ sender: NSPopUpButton) {
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
        worldViewer.bringAimMarkToFront()
        NSLayoutConstraint.activate([
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
            NSLayoutConstraint.activate([
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
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: worldViewer.leadingAnchor, constant: 12),
                status.topAnchor.constraint(equalTo: worldViewer.topAnchor, constant: 12),
                status.trailingAnchor.constraint(lessThanOrEqualTo: cameraHUD.leadingAnchor, constant: -12)
            ])
        }
        NSLayoutConstraint.activate([
            cameraHUD.trailingAnchor.constraint(equalTo: worldViewer.trailingAnchor, constant: -12),
            cameraHUD.topAnchor.constraint(equalTo: worldViewer.topAnchor, constant: 12),
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
        NSLayoutConstraint.activate([
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
            viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
        }
        renderViewState()
    }

    private func renderViewState() {
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
        runButton.title = paused ? L("Resume", "재개") : L("Pause", "일시 정지")
        runButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                  accessibilityDescription: nil)
        runButton.isEnabled = viewState.sessionPhase == .running || paused
        if case .recording(_, let elapsed)? = workspace?.recording {
            recordButton.title = L("Stop · ", "멈춤 · ") + WorkspaceSnapshot.clock(elapsed)
            recordButton.contentTintColor = .systemRed
            recordButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        } else {
            recordButton.title = recorder.isStopping ? L("Saving…", "저장 중…") : L("Record", "기록")
            recordButton.contentTintColor = nil
            recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        }
        recordButton.isEnabled = !recorder.isStopping
        recordButton.setAccessibilityLabel(recorder.isRecording ? L("Stop recording and save", "기록을 멈추고 저장") : L("Start recording", "기록 시작"))
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

    private func playerInputFocusAllowsCapture() -> Bool {
        guard let window else { return false }
        return PlayerInputFocusPolicy.allowsCapture(
            windowIsKey: window.isKeyWindow,
            firstResponder: window.firstResponder,
            viewer: worldViewer)
    }

    private func refreshInteractionStatus(state: LabInteractionState?) {
        var line = interactionPresentation.line(state: state)
        if viewState.mode == .participate && worldViewer.cameraState.mode == .behindParticipant {
            line += L(" · Third person: E grabs in the participant's forward direction",
                      " · 3인칭: E는 참여체 정면을 집습니다")
        }
        interactionStatusLabel.stringValue = line
        interactionStatusLabel.textColor = interactionPresentation.ignoredReason != nil
            || interactionPresentation.rejection == nil
            ? .secondaryLabelColor : .systemRed
    }

    private func showInteractionIgnored(_ reason: LabInteractionPresentation.IgnoredReason,
                                        state: LabInteractionState? = nil) {
        interactionPresentation.ignore(reason)
        refreshInteractionStatus(state: state)
    }

    private func sendParticipantInteraction() {
        guard viewState.mode == .participate,
              playerController.captureEnabled, worldViewer.participateInputEnabled,
              playerInputFocusAllowsCapture() else { return }
        guard viewState.pendingMode == nil, viewState.sessionPhase == .running else {
            showInteractionIgnored(.waitingForSession)
            return
        }
        guard interactionPresentation.canAttempt() else {
            refreshInteractionStatus(state: bridge?.latestLabState()?.interaction)
            return
        }
        guard let bridge, bridge.labStateFreshness().isFresh,
              let interaction = bridge.latestLabState()?.interaction else {
            showInteractionIgnored(.waitingForState)
            return
        }
        guard let envelope = playerInputEnvelope(),
              let snapshot = bridge.latestWorldRenderSnapshot(maxAge: 1.0),
              snapshot.ok, let player = snapshot.player,
              player.id == "player",
              snapshot.sessionID == envelope.sessionID,
              snapshot.epoch == envelope.epoch else {
            showInteractionIgnored(.waitingForWorld, state: interaction)
            return
        }

        let toolID = interaction.heldObjectID == nil ? "grab" : "place"
        let ray = toolID == "grab" ? WorldViewer.participantAimRay(player: player) : nil
        if toolID == "grab" && ray == nil {
            showInteractionIgnored(.invalidAim, state: interaction)
            return
        }
        guard let id = send("interaction", target: interaction.heldObjectID,
                            toolID: toolID, actorID: player.id,
                            rayOriginMM: ray?.originMM,
                            rayDirection: ray?.direction,
                            scheduleOverride: LabCommandSchedule(
                                sessionID: envelope.sessionID, epoch: envelope.epoch,
                                requestedTick: envelope.requestedTick)) else {
            showInteractionIgnored(.queueUnavailable, state: interaction)
            return
        }
        interactionPresentation.begin(id: id, generation: bridge.connectionGeneration)
        refreshInteractionStatus(state: interaction)
    }

    private func playerInputEnvelope(allowStaleSnapshotForRelease: Bool = false)
        -> (sessionID: String, epoch: Int, requestedTick: Int)? {
        guard let bridge, bridge.playerInputV5_5Available else { return nil }
        let session = coordinator.sessionSnapshot()
        if session.mode == .deterministic {
            guard session.phase == .running,
                  let schedule = coordinator.labCommandSchedule() else { return nil }
            // The deterministic schedule is already the authoritative exact
            // owner boundary. Requiring a render snapshot here can strand a held
            // key when focus is lost during a temporary viewer stall.
            return (schedule.sessionID, schedule.epoch, schedule.requestedTick)
        }

        guard coordinator.ensureInteractivePlayerInputSession() else { return nil }
        let current = coordinator.sessionSnapshot()
        let maxSnapshotAge = allowStaleSnapshotForRelease
            ? TimeInterval.greatestFiniteMagnitude : 1.0
        guard current.mode == .interactive, current.phase == .running else { return nil }
        if let snapshot = bridge.latestWorldRenderSnapshot(maxAge: maxSnapshotAge),
           snapshot.ok,
           snapshot.sessionID == current.sessionID,
           snapshot.epoch == current.epoch {
            if !allowStaleSnapshotForRelease && snapshot.player == nil { return nil }
            return (current.sessionID, current.epoch, snapshot.simTick)
        }
        if allowStaleSnapshotForRelease {
            // Safety neutralization must not depend on view freshness. Tick zero
            // is a conservative interactive provenance floor: Python still
            // validates session/epoch and applies at its current owner boundary,
            // rejecting only client claims that are in the future.
            return (current.sessionID, current.epoch, 0)
        }
        return nil
    }

    @discardableResult
    private func sendPlayerInput(_ intent: PlayerInputIntent, reason: String,
                                 allowStaleSnapshotForRelease: Bool = false,
                                 discardPendingLook: Bool = false) -> Int? {
        guard let bridge,
              let envelope = playerInputEnvelope(
                allowStaleSnapshotForRelease: allowStaleSnapshotForRelease) else {
            playerInputStatusLabel.stringValue = L("Participant controls — waiting for authoritative session snapshot before \(reason)", "참여 조작 — 시뮬레이터 화면을 기다리는 중이라 입력을 보내지 못했습니다")
            playerInputStatusLabel.textColor = .systemOrange
            playerInputReconcilePending = true
            return nil
        }
        guard let seq = bridge.sendPlayerInput(
            sessionID: envelope.sessionID,
            epoch: envelope.epoch,
            requestedTick: envelope.requestedTick,
            moveAxes: intent.moveAxes,
            lookDelta: intent.lookDelta,
            heldActions: intent.heldActions,
            discardPendingLook: discardPendingLook) else {
            playerInputStatusLabel.stringValue = L("Participant controls — \(reason) was not queued", "참여 조작 — 입력을 보내지 못했습니다")
            playerInputStatusLabel.textColor = .systemOrange
            playerInputReconcilePending = true
            return nil
        }
        lastPlayerInputSeq = seq
        playerInputReconcilePending = false
        return seq
    }

    /// Called from the 10 Hz refresh. A neutral state may use the stale-snapshot
    /// release path; a still-moving state needs a fresh snapshot like key down.
    /// Only an already-running session is reconciled: this timer must never
    /// begin an interactive session the user did not request.
    private func reconcilePlayerHeldInputIfNeeded() {
        guard playerInputReconcilePending else { return }
        guard bridge?.playerInputV5_5Available == true,
              viewState.mode == .participate else {
            // Disconnect releases held input on the backend, and leaving
            // Participate deactivates the participant; nothing to resend.
            playerInputReconcilePending = false
            return
        }
        guard coordinator.sessionSnapshot().phase == .running else { return }
        let held = playerController.heldIntent()
        // A neutral state is a safety release and drops unsent look, like
        // key up. A still-moving state keeps any queued look delta (F-03).
        sendPlayerInput(held, reason: "held-input reconcile",
                        allowStaleSnapshotForRelease: held.isNeutral,
                        discardPendingLook: held.isNeutral)
    }

    private func releasePlayerHeldInput(reason: String) {
        playerCaptureArmed = false
        _ = playerController.releaseHeldInput(blockUntilFreshPress: true)
        _ = playerController.setCaptureEnabled(false)
        worldViewer.participateInputEnabled = false
        let neutral = playerController.heldIntent()
        sendPlayerInput(neutral, reason: reason,
                        allowStaleSnapshotForRelease: true,
                        discardPendingLook: true)
    }

    private func playerKeyPopup(for action: PlayerControlAction) -> NSPopUpButton {
        switch action {
        case .forward: return playerForwardKey
        case .backward: return playerBackwardKey
        case .left: return playerLeftKey
        case .right: return playerRightKey
        case .interact: return playerInteractKey
        }
    }

    private func configurePlayerKeyPopups() {
        for action in PlayerControlAction.allCases {
            let popup = playerKeyPopup(for: action)
            popup.removeAllItems()
            for choice in PlayerKeyChoice.remappable {
                popup.addItem(withTitle: choice.title)
                popup.lastItem?.representedObject = NSNumber(value: choice.keyCode)
            }
            popup.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            popup.target = self
            popup.action = #selector(playerKeyBindingChanged(_:))
        }
        syncPlayerKeyPopups()
    }

    private func syncPlayerKeyPopups() {
        for action in PlayerControlAction.allCases {
            let popup = playerKeyPopup(for: action)
            let code = playerController.bindings.keyCode(for: action)
            if let item = popup.itemArray.first(where: {
                ($0.representedObject as? NSNumber)?.uint16Value == code
            }) {
                popup.select(item)
            }
        }
    }

    @objc private func playerKeyBindingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue,
              let action = PlayerControlAction(rawValue: raw),
              let number = sender.selectedItem?.representedObject as? NSNumber else {
            syncPlayerKeyPopups()
            return
        }
        if let neutral = playerController.rebind(action, to: number.uint16Value) {
            sendPlayerInput(neutral, reason: "key remap",
                            allowStaleSnapshotForRelease: true,
                            discardPendingLook: true)
        }
        syncPlayerKeyPopups()
        playerInputStatusLabel.stringValue = L("Participant controls — key mapping saved · Esc remains fixed safety release", "참여 조작 — 키 설정 저장됨 · Esc는 항상 해제 키입니다")
        playerInputStatusLabel.textColor = .secondaryLabelColor
    }

    private func addPopupItems(_ popup: NSPopUpButton, _ items: [(String, String)]) {
        popup.removeAllItems()
        for (title, value) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
    }

    private func selectedValue(_ popup: NSPopUpButton, fallback: String) -> String {
        (popup.selectedItem?.representedObject as? String) ?? fallback
    }

    private func selectPopupValue(_ popup: NSPopUpButton, _ value: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) {
            popup.select(item)
        }
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: selector)
        b.bezelStyle = .rounded
        return b
    }

    private func section(_ title: String, kind: LabInterventionKind? = nil,
                         help: String? = nil, _ content: [NSView]) -> NSView {
        LabInspectorSection(title, kind: kind, help: help, content)
    }

    private func worldPage() -> NSViewController {
        objectID.placeholderString = L("auto", "자동")
        objectID.widthAnchor.constraint(equalToConstant: 120).isActive = true
        _ = LabForm.status(worldObjectStatusLabel)
        _ = LabForm.status(worldCapacityLabel, mono: true)
        _ = LabForm.status(playerInputStatusLabel)
        configurePlayerKeyPopups()
        [objectX, objectY, objectZ, objectSize, objectSpeed, objectEndDistance].forEach { _ = LabForm.number($0) }
        addPopupItems(objectShape, [(L("Box", "상자"), "box"), (L("Sphere", "공"), "sphere"), (L("Wall", "벽"), "wall"),
                                    (L("Food / odor source", "먹이 (냄새가 나는 곳)"), "food")])
        objectShape.target = self
        objectShape.action = #selector(objectShapeChanged)
        createOnArenaClick.title = L("Create on map click", "지도를 클릭하면 바로 만들기")
        createOnArenaClick.state = .off
        arenaPlacement.translatesAutoresizingMaskIntoConstraints = false
        arenaPlacement.heightAnchor.constraint(equalToConstant: 250).isActive = true
        arenaPlacement.selectedShape = selectedValue(objectShape, fallback: "box")
        arenaPlacement.selectedPoint = (d(objectX), d(objectY))
        return LabInspectorPage([
            section(L("Selection", "선택한 대상"), help: L("Click the fly or an object in the 3D view. A selection is confirmed only by the backend's ray pick; the fly is drawn as a position marker, not its real body geometry.", "3D 화면에서 파리나 물체를 클릭하면 선택됩니다. 드래그하면 카메라가 돌아가고, Shift나 Option을 누른 채 드래그하면 옮겨지며, 스크롤이나 핀치로 확대합니다. 선택은 시뮬레이터가 실제로 맞았는지 확인한 뒤에 확정됩니다."),
                    [viewStateLabel]),
            section(L("Place objects", "물체 놓기"), kind: .physical,
                    help: L("Top-down map of the arena: up is +X (forward), left is +Y. Clicking the map fills X/Y; with “Create on map click” on, the click also creates the object.", "경기장을 위에서 본 지도입니다. 위쪽이 앞(+X), 왼쪽이 +Y입니다. 지도를 클릭하면 X/Y 칸이 채워지고, ‘지도를 클릭하면 바로 만들기’를 켜 두면 클릭과 동시에 물체가 생깁니다."),
                    [LabForm.grid([(L("Type", "종류"), objectShape), (L("Name", "이름"), objectID)]),
                     arenaPlacement, createOnArenaClick,
                     LabForm.grid([("X (mm)", objectX), ("Y (mm)", objectY),
                                   ("Z (mm)", objectZ), (L("Size (mm)", "크기 (mm)"), objectSize)]),
                     LabForm.buttons([button(L("Create", "만들기"), #selector(createObject)),
                                      button(L("Move", "옮기기"), #selector(moveObject)),
                                      button(L("Resize", "크기 바꾸기"), #selector(resizeObject)),
                                      button(L("Remove", "지우기"), #selector(deleteObject))]),
                     worldObjectStatusLabel, worldCapacityLabel]),
            section(L("Approach the fly", "물체를 파리에게 다가가게 하기"), kind: .physical,
                    help: L("Moves the named object toward the fly. The fly is never commanded; any response comes from the model.", "이름을 적은 물체를 파리 쪽으로 움직입니다. 파리에게 직접 명령하지 않습니다. 파리가 보이는 반응은 모두 뇌·몸 모델이 스스로 만든 것입니다."),
                    [LabForm.grid([(L("Speed (mm/s)", "속도 (mm/s)"), objectSpeed), (L("Stop at (mm)", "멈출 거리 (mm)"), objectEndDistance)]),
                     LabForm.buttons([button(L("Start approach", "다가가기 시작"), #selector(approachObject))], columns: 1)]),
            section(L("Participate", "참여"), kind: .physical,
                    help: L("Choose Participate, then click the 3D view to capture. Aim with the center mark and press E once to grab an object; press E again to place it. WASD moves, the mouse looks, Esc releases capture. Text fields do not trigger interaction.", "‘참여’를 고르고 3D 화면을 클릭해 조작을 시작하세요. 중앙 조준점으로 물체를 겨누고 E를 한 번 누르면 집고, 다시 누르면 놓습니다. WASD로 이동하고 마우스로 둘러봅니다. Esc는 조작을 해제합니다. 입력 칸에서는 상호작용하지 않습니다."),
                    [LabForm.grid([(L("Forward", "앞으로"), playerForwardKey), (L("Backward", "뒤로"), playerBackwardKey),
                                   (L("Left", "왼쪽"), playerLeftKey), (L("Right", "오른쪽"), playerRightKey),
                                   (L("Interact", "상호작용"), playerInteractKey), (L("Release", "해제"), LabForm.note(L("Esc (fixed)", "Esc (고정)")))]),
                     playerInputStatusLabel, interactionStatusLabel]),
            section(L("Reset", "초기화"), help: L("Use the smallest reset you need. Everything clears world, body, brain state, modeled stimuli, eye covers and graphs.", "필요한 부분만 초기화하세요. ‘전부’는 세계, 몸, 뇌 상태, 자극, 눈 가리개, 그래프를 모두 처음으로 되돌립니다."),
                    [LabForm.buttons([button(L("World", "세계"), #selector(resetWorld)),
                                      button(L("Body", "몸"), #selector(resetBody)),
                                      button(L("Brain", "뇌"), #selector(resetBrain)),
                                      button(L("Everything", "전부"), #selector(resetAll))])])
        ])
    }

    private func sensesPage() -> NSViewController {
        [windStrength, windDuration, windDirection, touchStrength, touchDuration, temperature,
         flashIntensity, flashDuration].forEach { _ = LabForm.number($0) }
        windPhysical.state = .on; windSensory.state = .on
        windPhysical.title = L("Physical force", "바람으로 몸을 실제로 밀기")
        windSensory.title = L("Wind receptors (JO-C/E)", "더듬이의 바람 감각에도 전달 (JO-C/E)")
        windContinuous.title = L("Keep on until stopped", "멈출 때까지 계속")
        addPopupItems(touchTarget, [
            (L("Thorax", "가슴 (흉부)"), "thorax"), (L("Head", "머리"), "head"), (L("Abdomen", "배"), "abdomen"),
            (L("Left front leg", "왼쪽 앞다리"), "left_front_leg"), (L("Left middle leg", "왼쪽 가운데 다리"), "left_middle_leg"),
            (L("Left hind leg", "왼쪽 뒷다리"), "left_hind_leg"), (L("Right front leg", "오른쪽 앞다리"), "right_front_leg"),
            (L("Right middle leg", "오른쪽 가운데 다리"), "right_middle_leg"), (L("Right hind leg", "오른쪽 뒷다리"), "right_hind_leg")
        ])
        addPopupItems(temperatureMode, [
            (L("FlyWire thermosensory", "온도 감각 뉴런에 전달"), "flywire_sensory"),
            (L("Record only", "기록만"), "environment_only"),
            (L("Legacy tempo model", "예전 방식 (활동 속도만)"), "modeled_physiology")
        ])
        selectPopupValue(temperatureMode, "environment_only")
        temperatureMode.target = self
        temperatureMode.action = #selector(temperatureModeChanged)
        addPopupItems(flashEye, [(L("Left eye", "왼쪽 눈"), "left"), (L("Right eye", "오른쪽 눈"), "right"), (L("Both eyes", "양쪽 눈"), "both")])
        eyeButtons = [button(L("Cover left", "왼쪽 눈 가리기"), #selector(coverLeft)), button(L("Cover right", "오른쪽 눈 가리기"), #selector(coverRight)),
                      button(L("Open left", "왼쪽 눈 뜨기"), #selector(restoreLeft)), button(L("Open right", "오른쪽 눈 뜨기"), #selector(restoreRight))]
        _ = LabForm.status(temperatureModeStatusLabel)
        updateTemperatureModeStatus()
        return LabInspectorPage([
            section(L("Vision", "시각"), kind: .sensoryModel,
                    help: L("Covering an eye changes the rendered input reaching it. Flash changes full-field brightness only; there is no invented flash-to-escape circuit.", "눈을 가리면 그 눈에 들어가는 화면이 실제로 바뀝니다. 번쩍임은 눈 전체의 밝기만 바꿉니다. ‘번쩍이면 도망’ 같은 회로를 따로 만들어 넣지 않았습니다."),
                    [LabForm.buttons(eyeButtons),
                     LabForm.grid([(L("Flash", "번쩍임"), flashEye), (L("Intensity 0–1", "세기 0–1"), flashIntensity),
                                   (L("Duration (ms)", "지속 시간 (ms)"), flashDuration)]),
                     LabForm.buttons([button(L("Apply flash", "번쩍이기"), #selector(applyFlash))], columns: 1)]),
            section(L("Wind", "바람"), kind: .sensoryModel,
                    help: L("Physical force pushes the MuJoCo thorax; receptor mode drives the real JO-C/E FlyWire groups. Direction is relative to the fly's heading.", "‘몸을 밀기’는 물리 엔진에서 파리 가슴을 실제로 밉니다. ‘바람 감각’은 더듬이에서 바람을 느끼는 실제 뉴런 그룹(JO-C/E)을 자극합니다. 방향은 파리가 바라보는 쪽 기준입니다."),
                    [LabForm.grid([(L("Strength 0–1", "세기 0–1"), windStrength), (L("Direction (°)", "방향 (°)"), windDirection),
                                   (L("Duration (ms)", "지속 시간 (ms)"), windDuration)]),
                     windPhysical, windSensory, windContinuous,
                     LabForm.buttons([button(L("Apply wind", "바람 불기"), #selector(applyWind)),
                                      button(L("Stop", "멈추기"), #selector(stopWind))])]),
            section(L("Touch", "건드리기"), kind: .physical,
                    help: L("An impulse on the chosen body part. The neural side is a generic touch/startle channel, not body-part-specific transduction.", "고른 몸 부위를 한 번 툭 칩니다. 뇌 쪽 입력은 부위와 상관없는 일반적인 ‘닿음/놀람’ 신호입니다."),
                    [LabForm.grid([(L("Body part", "몸 부위"), touchTarget), (L("Strength 0–1", "세기 0–1"), touchStrength),
                                   (L("Duration (ms)", "지속 시간 (ms)"), touchDuration)]),
                     LabForm.buttons([button(L("Apply touch", "건드리기 실행"), #selector(applyTouch))], columns: 1)]),
            section(L("Temperature", "온도"), kind: .sensoryModel,
                    help: L("FlyWire thermosensory drives TRN_VP2 (warm) and TRN_VP3a/b (cool). Record only stores the value with no neural input. The temperature→current conversion is a modeling assumption.", "‘온도 감각 뉴런에 전달’은 따뜻함을 느끼는 뉴런(TRN_VP2)과 차가움을 느끼는 뉴런(TRN_VP3a/b)을 자극합니다. ‘기록만’은 값만 저장하고 뇌에는 전달하지 않습니다. 온도를 뉴런 신호 세기로 바꾸는 비율은 모델이 가정한 값입니다."),
                    [LabForm.grid([("°C", temperature), (L("Mode", "방식"), temperatureMode)]),
                     temperatureModeStatusLabel,
                     LabForm.buttons([button(L("Set temperature", "온도 적용"), #selector(setTemperature)),
                                      button(L("Reset stimuli", "자극 모두 끄기"), #selector(resetSenses))])])
        ])
    }

    private func brainPage() -> NSViewController {
        let brainView: NSView
        if let brainController {
            let view = brainController.embeddedView
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: 280).isActive = true
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.masksToBounds = true
            view.setAccessibilityLabel(L("FlyWire whole-brain activity. Clicking a cluster stimulates it directly.", "초파리 뇌 전체 활동. 뉴런 덩어리를 클릭하면 그 부분을 직접 자극합니다."))
            brainView = view
        } else {
            brainView = LabForm.note(L("The brain model is not loaded in this session.", "이번 실행에서는 뇌 모델을 불러오지 않았습니다."))
        }
        addPopupItems(brainRole, NeuronGuide.groups.compactMap { group in
            group.stimulusID.map { (group.name, $0) }
        })
        brainRole.target = self
        brainRole.action = #selector(brainRoleChanged)
        _ = LabForm.status(brainRoleDescription)
        updateBrainRoleDescription()
        _ = LabForm.number(brainStrength); _ = LabForm.number(brainDuration)
        return LabInspectorPage([
            section(L("Whole-brain activity", "뇌 전체 활동"),
                    help: L("All 139,255 FlyWire somata; flashes are spikes. Clicking a cluster applies direct neural stimulation to it — the same kind of intervention as the controls below.", "초파리 뇌의 뉴런 139,255개를 점으로 표시했습니다. 반짝이는 점이 지금 신호를 보내는(발화하는) 뉴런입니다. 덩어리를 클릭하면 아래 버튼과 같은 방식으로 그 부분을 직접 자극합니다."),
                    [brainView]),
            section(L("What the colours mean", "색 안내 — 각 뉴런이 하는 일"),
                    [neuronLegend()]),
            section(L("Stimulate a population", "뉴런 그룹 직접 자극하기"), kind: .directNeural,
                    help: L("Bypasses the physical stimulus and sense organs: the chosen FlyWire population is driven directly while the rest of the brain runs normally. Labels describe the modeled readout, not a guaranteed behavior.", "눈·더듬이 같은 감각기관을 거치지 않고 고른 뉴런 그룹만 직접 자극합니다. 나머지 뇌는 평소처럼 돌아갑니다. 이름 옆 설명은 그 뉴런이 모델에서 주로 맡는 일이며, 자극하면 반드시 그 행동이 나온다는 뜻은 아닙니다."),
                    [LabForm.grid([(L("Population", "뉴런 그룹"), brainRole), (L("Strength", "세기"), brainStrength),
                                   (L("Duration (ms)", "지속 시간 (ms)"), brainDuration)]),
                     brainRoleDescription,
                     LabForm.buttons([button(L("Stimulate", "자극하기"), #selector(stimulateBrain))], columns: 1)])
        ])
    }

    @objc private func brainRoleChanged() { updateBrainRoleDescription() }

    private func updateBrainRoleDescription() {
        let group = NeuronGuide.group(stimulusID: selectedValue(brainRole, fallback: "GF"))
        brainRoleDescription.stringValue = group.map { "→ " + $0.what } ?? ""
    }

    /// Colour key for the 3D brain: swatch, name and one plain sentence per row.
    private func neuronLegend() -> NSView {
        let rows = NeuronGuide.legend.map { row -> NSView in
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = row.color.cgColor
            swatch.layer?.cornerRadius = 5
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 10),
                                         swatch.heightAnchor.constraint(equalToConstant: 10)])
            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            let what = NSTextField(wrappingLabelWithString: row.what)
            what.font = .systemFont(ofSize: 11)
            what.textColor = .secondaryLabelColor
            let text = NSStackView(views: [name, what])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let line = NSStackView(views: [swatch, text])
            line.orientation = .horizontal
            line.alignment = .top
            line.spacing = 8
            line.setAccessibilityElement(true)
            line.setAccessibilityLabel("\(row.name): \(row.what)")
            return line
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        return stack
    }

    private func metricsPage() -> NSViewController {
        neuralGraph.fixedRange = 0...220
        commandGraph.fixedRange = 0...220
        sensoryGraph.fixedRange = 0...1.2
        flywireSensoryGraph.fixedRange = 0...0.065
        flywireSensoryGraph.valueDecimals = 3
        flywireSensoryGraph.unitLabel = L("injected current · sim units", "넣어 준 전류 · 시뮬레이션 단위")
        bodyGraph.fixedRange = -1.2...1.2
        visionGraph.fixedRange = 0...1.05
        for text in [bodyTelemetryLabel, foodTelemetryLabel, visionTelemetryLabel] {
            _ = LabForm.status(text, mono: true)
        }
        for g in [neuralGraph, commandGraph, sensoryGraph, flywireSensoryGraph, bodyGraph, visionGraph] {
            g.translatesAutoresizingMaskIntoConstraints = false
            g.heightAnchor.constraint(equalToConstant: 120).isActive = true
        }
        return LabInspectorPage([
            section(L("Signal path", "신호 경로 — 감각에서 몸까지"),
                    help: L("Read top to bottom to find where a response stops. Each line uses only telemetry the runtime actually exposes.", "위에서 아래로 읽으면 자극이 어디까지 전달됐는지 알 수 있습니다: 1 바깥 자극 → 2 감각 신호 → 3 뉴런 반응 → 4 몸에 내린 명령 → 5 실제 움직임. 모두 실제로 측정된 값만 씁니다."),
                    [signalPathLabel]),
            section(L("Brain activity (Hz)", "뇌 활동 (초당 발화 횟수)"),
                    help: L("Population spike rates. walk/back/groom are DN readouts; a higher line means more activity, not a guaranteed behavior.", "뉴런 그룹이 1초에 몇 번 신호를 보내는지입니다. brain=뇌 전체 평균, loom=다가오는 물체 감지, walk=걷기, back=뒤로 걷기, groom=몸 손질. 선이 높을수록 활발하다는 뜻이지 그 행동을 꼭 한다는 뜻은 아닙니다."),
                    [neuralGraph]),
            section(L("Descending populations (Hz)", "몸에 명령을 내리는 뉴런 (초당 발화 횟수)"),
                    help: L("DNa L/R steering, MDN backward, DNp09 forward walking, DNg11 grooming, escW escape/wing.", "뇌에서 몸으로 명령을 내리는 뉴런입니다. DNa L/R=왼쪽/오른쪽으로 돌기, MDN=뒤로 걷기, DNp09=앞으로 걷기, DNg11=몸 손질, escW=도망·날개."),
                    [commandGraph]),
            section(L("Compact sensory inputs", "주요 감각 입력"),
                    help: L("Loom is the left/right visual expansion signal; gait is body feedback; legacy air is the older generic channel, not JO-C/E wind.", "loom L/R=왼쪽/오른쪽 눈에 무언가 커지며 다가오는 신호, gait=다리가 땅을 딛는 감각, legacy air=예전 방식의 바람 신호(더듬이 바람 감각과는 다름)."),
                    [sensoryGraph]),
            section(L("FlyWire sensory groups", "감각 뉴런 그룹에 들어가는 신호"),
                    help: L("Modeled current injected into real receptor groups (ORN food odor, TRN warm/cool, JO-C/E wind). Expected maxima are about 0.055–0.060.", "실제 감각 뉴런 그룹에 넣어 준 신호 세기입니다. food=먹이 냄새(후각 뉴런 ORN), warm/cool=따뜻함/차가움(TRN), wind C/E=더듬이 바람 감각(JO-C/E). 최대 약 0.055–0.060입니다."),
                    [flywireSensoryGraph, foodTelemetryLabel]),
            section(L("Body", "몸"),
                    help: L("Speed ×20, turn ÷5 and nearest-food distance ÷100 share one axis; exact values are listed below.", "속도(×20), 회전(÷5), 가장 가까운 먹이까지 거리(÷100)를 한 그래프에 맞춰 그렸습니다. 정확한 값은 아래에 있습니다."),
                    [bodyGraph, bodyTelemetryLabel]),
            section(L("Rendered-eye vision", "파리 눈에 보이는 것"),
                    help: L("Brightness is mean light; target is configured-color occupancy; expansion is a raw-frame optic-expansion proxy, not reconstructed retinotopy.", "파리 눈 카메라로 본 화면에서 계산합니다. light=밝기, target=표시 색 물체가 차지하는 비율, expand=물체가 커지는 정도(다가옴의 단서)."),
                    [visionGraph, visionTelemetryLabel]),
            section(L("Connection", "연결 상태"), [remoteStateLabel, freshnessLabel, commandDiagnosticsLabel,
                                   LabForm.buttons([button(L("Clear graphs", "그래프 지우기"), #selector(clearGraphs))], columns: 1)])
        ])
    }

    private func experimentPage() -> NSViewController {
        return LabInspectorPage([
            section(L("Session", "세션"),
                    help: L("Interactive is the responsive default. Deterministic starts a tick-zero brain/body session: 1 ms neural ticks and one exact 20 ms FlyGym quantum at a time, independent of display FPS. Pause and Resume are in the toolbar.", "기본은 반응이 빠른 실시간 모드입니다. ‘재현 가능한 세션’은 시간을 0부터 다시 시작해 뇌는 1 ms, 몸은 20 ms 단위로 정확히 맞춰 계산하므로 같은 실험을 똑같이 되풀이할 수 있습니다. 일시 정지/재개는 위쪽 막대에 있습니다."),
                    [sessionStatusLabel,
                     LabForm.buttons([button(L("Start deterministic session", "재현 가능한 세션 시작"), #selector(startDeterministicSession))],
                                     columns: 1)]),
            section(L("Markers", "구간 표시"),
                    help: L("Markers never change the simulation; they label the timeline and the recording so baseline, stimulus and observation periods line up later. Record from the toolbar; files go to Documents/ThongpariFlyNeuronSimExperiments.", "구간 표시는 시뮬레이션을 바꾸지 않고, 나중에 기록을 볼 때 ‘기준/자극/관찰’ 구간을 구분하도록 이름표만 붙입니다. 기록은 위쪽 막대의 ‘기록’ 버튼으로 하며 파일은 문서/ThongpariFlyNeuronSimExperiments에 저장됩니다."),
                    [LabForm.buttons([button(L("Baseline", "기준 구간"), #selector(markBaseline)),
                                      button(L("Stimulus on", "자극 시작"), #selector(markStimulusOn)),
                                      button(L("Stimulus off", "자극 끝"), #selector(markStimulusOff)),
                                      button(L("Observation", "관찰 구간"), #selector(markObservation))])]),
            section(L("Physical & sensory trials", "물리·감각 실험 예시"), kind: .physical,
                    help: L("Presets use the same World and Stimuli controls. They move objects or apply stimuli; they never command the fly.", "세계·자극 메뉴와 같은 조작을 한 번에 해 주는 예시입니다. 물체를 움직이거나 자극만 줄 뿐, 파리에게 직접 명령하지 않습니다."),
                    [LabForm.buttons([button(L("Frontal loom", "정면에서 물체 접근"), #selector(presetFrontalLoom)),
                                      button(L("Loom from left", "왼쪽에서 물체 접근"), #selector(presetLeftLoom)),
                                      button(L("Loom from right", "오른쪽에서 물체 접근"), #selector(presetRightLoom)),
                                      button(L("Loom, left eye covered", "왼눈 가리고 물체 접근"), #selector(presetCoveredLoom)),
                                      button(L("Wind puff", "바람 한 번"), #selector(presetWind)),
                                      button(L("Thorax touch", "가슴 건드리기"), #selector(presetTouch))])]),
            section(L("Direct neural trials", "뉴런 직접 자극 실험"), kind: .directNeural,
                    help: L("Explicit neural probes that bypass the natural stimulus.", "자연스러운 자극 없이 특정 뉴런 그룹만 직접 자극하는 실험입니다."),
                    [LabForm.buttons([button(L("Escape (GF)", "비상 탈출 (GF)"), #selector(presetGF)),
                                      button(L("Turn left (DNa)", "왼쪽 돌기 (DNa)"), #selector(presetDNa)),
                                      button(L("Turn right (DNa)", "오른쪽 돌기 (DNa)"), #selector(presetDNaRight)),
                                      button(L("Walk backward (MDN)", "뒤로 걷기 (MDN)"), #selector(presetMDN)),
                                      button(L("Walk forward (DNp09)", "앞으로 걷기 (DNp09)"), #selector(presetDNp09))])]),
            section(L("Repeat", "반복"),
                    [LabForm.buttons([button(L("Replay last preset", "마지막 실험 다시 하기"), #selector(replayLastPreset)),
                                      button(L("Reset everything", "전부 초기화"), #selector(resetAll))])])
        ])
    }

    private func d(_ f: NSTextField, fallback: Double = 0) -> Double {
        let x = f.doubleValue
        return x.isFinite ? x : fallback
    }
    private func ms(_ f: NSTextField, fallback: Int) -> Int { max(1, min(60_000, f.integerValue == 0 ? fallback : f.integerValue)) }
    private var target: String { objectID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "stimulus" : objectID.stringValue }

    private func creationTarget(for shape: String) -> String {
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

    @objc private func objectShapeChanged() {
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

    @objc private func resetObservationCamera() {
        worldViewer.resetObservationCamera()
        worldViewerStatusLabel.stringValue = L("3D world — observation camera reset", "3D 화면 — 카메라 초기화됨")
        worldViewerStatusLabel.textColor = .secondaryLabelColor
    }

    private func setEyeButtonsEnabled(_ enabled: Bool) {
        eyeButtons.forEach { $0.isEnabled = enabled }
    }

    private func clearEyePending() {
        eyeCommandPendingID = nil
        eyeCommandStartedAt = nil
        eyeCommandSide = nil
        eyeCommandCovered = nil
        setEyeButtonsEnabled(true)
    }

    private func updateTemperatureModeStatus() {
        switch selectedValue(temperatureMode, fallback: "environment_only") {
        case "flywire_sensory":
            temperatureModeStatusLabel.stringValue = L("Neural input: ON — temperature drives FlyWire TRN warm/cool receptor groups.", "신경 입력 켬 — 온도가 따뜻함/차가움을 느끼는 감각 뉴런을 자극합니다.")
            temperatureModeStatusLabel.textColor = .labelColor
        case "modeled_physiology":
            temperatureModeStatusLabel.stringValue = L("Neural input: TEMPO MODEL — changes the legacy physiology tempo path; it does not drive FlyWire TRNs.", "예전 방식 — 몸의 활동 속도만 바꾸고, 온도 감각 뉴런은 자극하지 않습니다.")
            temperatureModeStatusLabel.textColor = .secondaryLabelColor
        default:
            temperatureModeStatusLabel.stringValue = L("Neural input: OFF — environment-only temperature is recorded without neural input.", "신경 입력 끔 — 온도는 기록만 하고 뇌에는 전달하지 않습니다.")
            temperatureModeStatusLabel.textColor = .systemOrange
        }
    }

    @objc private func temperatureModeChanged() {
        updateTemperatureModeStatus()
    }

    @objc private func quitLab() {
        NSApp.terminate(nil)
    }

    @objc private func toggleRecording() {
        if recorder.isRecording { stopRecording() }
        else { startRecording() }
        renderViewState()
    }

    @discardableResult
    private func send(_ action: String, target: String? = nil,
                      x: Double? = nil, y: Double? = nil, z: Double? = nil,
                      size: Double? = nil, speed: Double? = nil,
                      strength: Double? = nil, durationMs: Int? = nil,
                      value: Double? = nil, directionDeg: Double? = nil,
                      endDistance: Double? = nil, physical: Bool? = nil,
                      sensory: Bool? = nil, continuous: Bool? = nil,
                      mode: String? = nil,
                      toolID: String? = nil, actorID: String? = nil,
                      rayOriginMM: [Double]? = nil,
                      rayDirection: [Double]? = nil,
                      scheduleOverride: LabCommandSchedule? = nil) -> Int? {
        guard let bridge else {
            protocolLabel.stringValue = L("FlyGym bridge — disabled (launch with --flygym for physical-world controls)", "물리 시뮬레이터 꺼짐 — 물리 세계를 조작하려면 시뮬레이터와 함께 실행하세요")
            return nil
        }
        let schedule = coordinator.labCommandSchedule() ?? scheduleOverride
        let id: Int
        if action == "interaction" {
            guard let toolID, let actorID, schedule != nil,
                  let interactionID = bridge.sendInteraction(
                    toolID: toolID, actorID: actorID, target: target,
                    rayOriginMM: rayOriginMM, rayDirection: rayDirection,
                    protocolVersion: schedule == nil ? nil : FlyGymProtocolV4.version,
                    sessionID: schedule?.sessionID, epoch: schedule?.epoch,
                    requestedTick: schedule?.requestedTick) else { return nil }
            id = interactionID
        } else {
            id = bridge.sendLab(action: action, target: target, x: x, y: y, z: z,
                                size: size, speed: speed, strength: strength,
                                durationMs: durationMs, value: value,
                                directionDeg: directionDeg, endDistance: endDistance,
                                physical: physical, sensory: sensory,
                                continuous: continuous, mode: mode,
                                protocolVersion: schedule == nil ? nil : FlyGymProtocolV4.version,
                                sessionID: schedule?.sessionID, epoch: schedule?.epoch,
                                requestedTick: schedule?.requestedTick)
        }
        lastCommandID = id
        lastCommandAction = action
        if let schedule {
            pendingCommandSchedules[id] = schedule
            if pendingCommandSchedules.count > 256,
               let oldest = pendingCommandSchedules.keys.min() {
                pendingCommandSchedules.removeValue(forKey: oldest)
            }
        }
        let session = coordinator.sessionSnapshot()
        timeline.append(LabTimelineEntry(
            commandID: id, action: action, detail: target ?? "",
            kind: .of(action: action),
            sessionID: schedule?.sessionID ?? session.sessionID,
            epoch: schedule?.epoch ?? session.epoch,
            requestedTick: schedule?.requestedTick ?? session.simTick,
            requestedAt: Date(), connectionGeneration: bridge.connectionGeneration,
            status: .requested))
        recorder.mark(kind: "lab_command", detail: "\(action) target=\(target ?? "-")", commandID: id,
                      sessionID: schedule?.sessionID ?? session.sessionID,
                      epoch: schedule?.epoch ?? session.epoch,
                      simTick: session.simTick, requestedTick: schedule?.requestedTick)
        return id
    }

    /// Timeline row for something that never waits on a backend ACK: direct
    /// neural stimulation, markers, session and recording requests.
    private func noteLocal(_ action: String, _ detail: String = "", kind: LabTimelineKind,
                           status: LabTimelineStatus = .local, tick: Int? = nil) {
        let s = coordinator.sessionSnapshot()
        timeline.append(LabTimelineEntry(
            commandID: nil, action: action, detail: detail, kind: kind,
            sessionID: s.sessionID, epoch: s.epoch, requestedTick: tick ?? s.simTick,
            requestedAt: Date(), connectionGeneration: bridge?.connectionGeneration ?? 0,
            status: status))
    }

    @objc private func createObject() {
        let shape = selectedValue(objectShape, fallback: "box")
        let objectTarget = creationTarget(for: shape)
        let action: String
        switch shape {
        case "sphere": action = "spawn_sphere"
        case "wall": action = "spawn_wall"
        case "food": action = "spawn_food"
        default: action = "spawn_box"
        }
        if let id = send(action, target: objectTarget, x: d(objectX), y: d(objectY), z: d(objectZ),
                         size: max(0.1, d(objectSize, fallback: 5))) {
            lastObjectCommandID = id
            lastObjectCommandTarget = objectTarget
            lastObjectCommandDescription = L("create \(shape) ‘\(objectTarget)’", "‘\(objectTarget)’ 만들기")
            worldObjectStatusLabel.stringValue = L("Object status — sending \(lastObjectCommandDescription)…", "물체 상태 — \(lastObjectCommandDescription) 요청 보냄…")
            worldObjectStatusLabel.textColor = .secondaryLabelColor
        } else {
            worldObjectStatusLabel.stringValue = L("Object status — bridge unavailable; object was not sent", "물체 상태 — 시뮬레이터에 연결되지 않아 보내지 못했습니다")
            worldObjectStatusLabel.textColor = .systemOrange
        }
    }
    @objc private func moveObject() {
        let objectTarget = target
        if send("move_object", target: objectTarget, x: d(objectX), y: d(objectY), z: d(objectZ)) != nil {
            viewState.selectObject(objectTarget)
            renderViewState()
        }
    }
    @objc private func resizeObject() {
        let objectTarget = target
        if send("resize_object", target: objectTarget, size: max(0.1, d(objectSize, fallback: 5))) != nil {
            viewState.selectObject(objectTarget)
            renderViewState()
        }
    }
    @objc private func deleteObject() {
        let objectTarget = target
        if send("delete_object", target: objectTarget) != nil {
            viewState.selectObject(objectTarget)
            renderViewState()
        }
    }
    @objc private func approachObject() {
        let objectTarget = target
        if send("approach_object", target: objectTarget,
                speed: max(0.1, d(objectSpeed, fallback: 12)),
                endDistance: max(0.5, d(objectEndDistance, fallback: 8))) != nil {
            viewState.selectObject(objectTarget)
            renderViewState()
        }
    }
    @objc private func resetWorld() {
        releasePlayerHeldInput(reason: "world reset")
        clearEyePending()
        temperature.stringValue = "25"
        selectPopupValue(temperatureMode, "environment_only")
        updateTemperatureModeStatus()
        if !coordinator.requestDeterministicReset(scopes: ["world", "modeled"]) {
            coordinator.labResetModeledStimuli()
            send("reset_world")
        }
        recorder.mark(kind: "reset", detail: "world+modeled environment")
    }
    @objc private func resetBody() {
        releasePlayerHeldInput(reason: "body reset")
        if !coordinator.requestDeterministicReset(scopes: ["body"]) { send("reset_body") }
        recorder.mark(kind: "reset", detail: "body")
    }
    @objc private func resetBrain() {
        if !coordinator.requestDeterministicReset(scopes: ["brain"]) { coordinator.labResetBrain() }
        recorder.mark(kind: "reset", detail: "brain")
    }
    @objc private func resetAll() {
        releasePlayerHeldInput(reason: "full reset")
        clearEyePending()
        temperature.stringValue = "25"
        selectPopupValue(temperatureMode, "environment_only")
        updateTemperatureModeStatus()
        if !coordinator.requestDeterministicReset(scopes: ["brain", "body", "world", "modeled"]) {
            coordinator.labResetBrain()
            coordinator.labResetModeledStimuli()
            send("reset_world")
            send("reset_body")
            send("restore_eyes")
        }
        neuralGraph.clear(); sensoryGraph.clear(); flywireSensoryGraph.clear(); bodyGraph.clear(); visionGraph.clear()
        commandGraph.clear()
        moodEstimator.reset()
        recorder.mark(kind: "reset", detail: "all")
    }

    private func eye(_ side: String, covered: Bool) {
        guard eyeCommandPendingID == nil else {
            commandDiagnosticsLabel.stringValue = L("Commands — eye change waiting for previous eye command acknowledgement", "명령 — 이전 눈 명령이 확인되기를 기다리는 중")
            return
        }
        if let id = send("set_eye_state", target: side, value: covered ? 1 : 0) {
            eyeCommandPendingID = id
            eyeCommandStartedAt = Date()
            eyeCommandSide = side
            eyeCommandCovered = covered
            setEyeButtonsEnabled(false)
        }
    }
    @objc private func coverLeft() { eye("left", covered: true) }
    @objc private func restoreLeft() { eye("left", covered: false) }
    @objc private func coverRight() { eye("right", covered: true) }
    @objc private func restoreRight() { eye("right", covered: false) }

    @objc private func applyFlash() {
        let eye = selectedValue(flashEye, fallback: "both")
        let intensity = max(0, min(1, d(flashIntensity, fallback: 1)))
        let duration = ms(flashDuration, fallback: 100)
        send("flash_eye", target: eye, strength: intensity, durationMs: duration)
        recorder.mark(kind: "sensory_model", detail: "flash eye=\(eye) intensity=\(intensity) duration_ms=\(duration)")
    }

    @objc private func applyWind() {
        let strength = max(0, min(1, d(windStrength, fallback: 0.7)))
        let duration = ms(windDuration, fallback: 500)
        let direction = d(windDirection, fallback: 0).truncatingRemainder(dividingBy: 360)
        let physical = windPhysical.state == .on
        let sensory = windSensory.state == .on
        let continuous = windContinuous.state == .on
        if sensory {
            coordinator.labApplyWind(strength: Float(strength), directionDeg: direction,
                                     durationMs: duration, continuous: continuous)
        } else {
            coordinator.labStopWind()
        }
        send("wind", strength: strength, durationMs: duration, directionDeg: direction,
             physical: physical, sensory: sensory, continuous: continuous)
        recorder.mark(kind: physical ? "physical" : "sensory_model",
                      detail: "wind strength=\(strength) dir=\(direction) physical=\(physical) sensory=\(sensory) continuous=\(continuous)")
    }

    @objc private func stopWind() {
        coordinator.labStopWind()
        send("stop_wind")
        recorder.mark(kind: "stimulus_off", detail: "wind")
    }

    @objc private func applyTouch() {
        let strength = max(0, min(1, d(touchStrength, fallback: 0.55)))
        let duration = ms(touchDuration, fallback: 150)
        let bodyTarget = selectedValue(touchTarget, fallback: "thorax")
        coordinator.labApplyTouch(strength: Float(strength), durationMs: duration)
        moodEstimator.registerHit(strength: strength)
        send("touch", target: bodyTarget, strength: strength, durationMs: duration)
        recorder.mark(kind: "physical+sensory_model", detail: "touch target=\(bodyTarget) strength=\(strength) duration_ms=\(duration)")
    }

    @objc private func setTemperature() {
        let c = max(10, min(40, d(temperature, fallback: 25)))
        temperature.doubleValue = c
        let mode = selectedValue(temperatureMode, fallback: "flywire_sensory")
        updateTemperatureModeStatus()
        coordinator.labSetTemperature(celsius: c,
                                      modeledPhysiology: mode == "modeled_physiology",
                                      flywireSensory: mode == "flywire_sensory")
        send("temperature", value: c, mode: mode)
        recorder.mark(kind: mode == "environment_only" ? "environment_record_only" : "sensory_model",
                      detail: "temperature_c=\(c) mode=\(mode)")
    }

    @objc private func resetSenses() {
        coordinator.labResetModeledStimuli()
        clearEyePending()
        windStrength.stringValue = "0.7"; temperature.stringValue = "25"
        selectPopupValue(temperatureMode, "environment_only")
        updateTemperatureModeStatus()
        send("stop_wind")
        send("restore_eyes")
        send("temperature", value: 25, mode: "environment_only")
        recorder.mark(kind: "reset", detail: "modeled sensory interventions")
    }

    /// A point-cloud click stimulates neurons directly; record it like the
    /// population button so every direct neural intervention is on the timeline.
    private func noteBrainClickStimulus(count: Int, name: String, strength: Float, durationMs: Int) {
        let schedule = coordinator.labCommandSchedule()
        let session = coordinator.sessionSnapshot()
        noteLocal("stimulate", "brain click \(name) (\(count) neurons) ×\(strength) \(durationMs) ms",
                  kind: .directNeural, tick: schedule?.requestedTick)
        recorder.mark(kind: "direct_neural",
                      detail: "brain_click cluster=\(name) neurons=\(count) strength=\(strength) duration_ms=\(durationMs)",
                      sessionID: session.sessionID, epoch: session.epoch, simTick: session.simTick,
                      requestedTick: schedule?.requestedTick)
    }

    @objc private func stimulateBrain() {
        let role = selectedValue(brainRole, fallback: "GF")
        let strength = Float(max(0, min(2, d(brainStrength, fallback: 0.3))))
        let duration = ms(brainDuration, fallback: 300)
        let schedule = coordinator.labCommandSchedule()
        let session = coordinator.sessionSnapshot()
        coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
        noteLocal("stimulate", "\(role) ×\(strength) \(duration) ms", kind: .directNeural,
                  tick: schedule?.requestedTick)
        recorder.mark(kind: "direct_neural", detail: "role=\(role) strength=\(strength) duration_ms=\(duration)",
                      sessionID: session.sessionID, epoch: session.epoch, simTick: session.simTick,
                      requestedTick: schedule?.requestedTick,
                      appliedTick: schedule?.requestedTick,
                      appliedEpoch: schedule?.epoch,
                      status: schedule == nil ? nil : "scheduled_local_boundary")
    }

    private func runPreset(_ name: String) {
        lastPreset = name
        recorder.mark(kind: "preset", detail: name)
        switch name {
        case "frontal_loom", "left_loom", "right_loom", "left_eye_covered_loom":
            if coordinator.requestDeterministicReset(
                scopes: ["brain", "body", "world", "modeled"],
                after: { [weak self] in self?.runLoomPresetAfterReset(name) }) {
                return
            }
            coordinator.labResetBrain()
            coordinator.labResetModeledStimuli()
            send("reset_world"); send("reset_body")
            runLoomPresetAfterReset(name)
        case "wind_puff":
            windStrength.stringValue = "0.7"; windDirection.stringValue = "0"; windDuration.stringValue = "500"
            windPhysical.state = .on; windSensory.state = .on; windContinuous.state = .off
            applyWind()
        case "thorax_touch":
            selectPopupValue(touchTarget, "thorax")
            touchStrength.stringValue = "0.55"; touchDuration.stringValue = "150"
            applyTouch()
        case "gf": presetStim(role: "GF", strength: 0.5, duration: 40)
        case "dna_left": presetStim(role: "DNa-left", strength: 0.3, duration: 900)
        case "dna_right": presetStim(role: "DNa-right", strength: 0.3, duration: 900)
        case "mdn": presetStim(role: "MDN", strength: 0.3, duration: 600)
        case "dnp09": presetStim(role: "DNp09", strength: 0.25, duration: 1200)
        default: break
        }
    }

    private func presetStim(role: String, strength: Float, duration: Int) {
        if coordinator.requestDeterministicReset(
            scopes: ["brain"],
            after: { [weak self] in
                guard let self else { return }
                self.coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
                let s = self.coordinator.sessionSnapshot()
                let schedule = self.coordinator.labCommandSchedule()
                self.noteLocal("stimulate", "preset \(role) ×\(strength) \(duration) ms",
                               kind: .directNeural, tick: schedule?.requestedTick)
                self.recorder.mark(kind: "direct_neural",
                                   detail: "preset role=\(role) strength=\(strength) duration_ms=\(duration)",
                                   sessionID: s.sessionID, epoch: s.epoch, simTick: s.simTick,
                                   requestedTick: schedule?.requestedTick,
                                   appliedTick: schedule?.requestedTick,
                                   appliedEpoch: schedule?.epoch,
                                   status: "scheduled_local_boundary")
            }) {
            return
        }
        coordinator.labResetBrain()
        coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
        noteLocal("stimulate", "preset \(role) ×\(strength) \(duration) ms", kind: .directNeural)
        recorder.mark(kind: "direct_neural", detail: "preset role=\(role) strength=\(strength) duration_ms=\(duration)")
    }

    private func runLoomPresetAfterReset(_ name: String) {
        clearEyePending()
        temperature.stringValue = "25"
        selectPopupValue(temperatureMode, "environment_only")
        updateTemperatureModeStatus()
        if name == "left_eye_covered_loom" { eye("left", covered: true) }
        let y: Double = name == "left_loom" ? 22 : (name == "right_loom" ? -22 : 0)
        let id = "preset_loom"
        send("spawn_box", target: id, x: 60, y: y, z: 5, size: 10)
        send("approach_object", target: id, speed: 80, endDistance: 8)
    }

    @objc private func presetFrontalLoom() { runPreset("frontal_loom") }
    @objc private func presetLeftLoom() { runPreset("left_loom") }
    @objc private func presetRightLoom() { runPreset("right_loom") }
    @objc private func presetCoveredLoom() { runPreset("left_eye_covered_loom") }
    @objc private func presetWind() { runPreset("wind_puff") }
    @objc private func presetTouch() { runPreset("thorax_touch") }
    @objc private func presetGF() { runPreset("gf") }
    @objc private func presetDNa() { runPreset("dna_left") }
    @objc private func presetDNaRight() { runPreset("dna_right") }
    @objc private func presetMDN() { runPreset("mdn") }
    @objc private func presetDNp09() { runPreset("dnp09") }
    @objc private func replayLastPreset() {
        guard let lastPreset else {
            noteLocal("preset", "nothing to replay yet", kind: .marker, status: .rejected)
            return
        }
        runPreset(lastPreset)
    }

    @objc private func clearGraphs() {
        neuralGraph.clear(); commandGraph.clear(); sensoryGraph.clear(); flywireSensoryGraph.clear(); bodyGraph.clear(); visionGraph.clear()
        recorder.mark(kind: "ui", detail: "graphs cleared")
    }

    @objc private func startRecording() {
        // The workspace status already shows L("Saving…", "저장 중…") until the flush completes.
        if recorder.isStopping { return }
        let session = coordinator.sessionSnapshot()
        var metadata: [String: Any] = [
            "protocol_version": FlyGymProtocolV4.version,
            "session_id": session.sessionID,
            "session_mode": session.mode.rawValue,
            "initial_epoch": session.epoch,
            "initial_sim_tick": session.simTick,
            "neural_tick_ms": 1,
            "experiment_quantum_ticks": session.quantumTicks,
            "experiment_quantum_ms": session.quantumTicks,
        ]
        if let hello = bridge?.serverHello() {
            metadata["backend_physics_timestep_s"] = hello.physicsTimestepS as Any
            metadata["backend_capabilities"] = hello.capabilities
            metadata["backend_supported_quantum_ticks"] = hello.supportedQuantumTicks
        }
        if let p = recorder.start(metadata: metadata) {
            recordingStartedAt = Date()
            lastRecordingOutcome = .idle
            noteLocal("recording", "start → \(p)", kind: .recording)
        } else {
            lastRecordingOutcome = .failed(path: nil, message: recorder.lastErrorMessage ?? "see stderr")
        }
        refreshWorkspace()
    }

    @objc private func startDeterministicSession() {
        releasePlayerHeldInput(reason: "session change")
        if let error = coordinator.startDeterministicSession() {
            sessionStatusLabel.stringValue = "Session — deterministic unavailable: \(error)"
            sessionStatusLabel.textColor = .systemOrange
            return
        }
        let s = coordinator.sessionSnapshot()
        sessionStatusLabel.textColor = .labelColor
        noteLocal("session", "deterministic begin", kind: .session)
        recorder.mark(kind: "session_begin", detail: "deterministic V4",
                      sessionID: s.sessionID, epoch: s.epoch, simTick: s.simTick,
                      status: s.phase.rawValue)
    }

    @objc private func pauseSession() {
        releasePlayerHeldInput(reason: "pause")
        let before = coordinator.sessionSnapshot()
        coordinator.requestSessionPause()
        noteLocal("session", "pause requested", kind: .session)
        recorder.mark(kind: "pause_requested", detail: before.mode.rawValue,
                      sessionID: before.sessionID, epoch: before.epoch, simTick: before.simTick,
                      status: before.phase.rawValue)
    }

    @objc private func resumeSession() {
        let before = coordinator.sessionSnapshot()
        coordinator.requestSessionResume()
        noteLocal("session", "resume requested", kind: .session)
        recorder.mark(kind: "resume_requested", detail: before.mode.rawValue,
                      sessionID: before.sessionID, epoch: before.epoch, simTick: before.simTick,
                      status: before.phase.rawValue)
    }
    @objc private func stopRecording() {
        guard recorder.isRecording || recorder.isStopping else { return }
        noteLocal("recording", "stop requested", kind: .recording)
        recorder.stop { [weak self] outcome in
            DispatchQueue.main.async { self?.noteRecordingOutcome(outcome) }
        }
        refreshWorkspace()
    }

    private func noteRecordingOutcome(_ outcome: ExperimentRecorderStopOutcome) {
        switch outcome {
        case .saved(let path):
            lastRecordingOutcome = .saved(path: path)
            noteLocal("recording", "saved", kind: .recording)
        case .failed(let path, let message):
            lastRecordingOutcome = .failed(path: path, message: message)
            noteLocal("recording", "save failed: \(message)", kind: .recording, status: .rejected)
        case .notRecording:
            break
        }
        recordingStartedAt = nil
        refreshWorkspace()
    }

    @objc private func restartBackend() {
        guard let service, service.canRestart else { return }
        noteLocal("backend", "restart \(service.mode.rawValue) on port \(service.port)", kind: .session)
        service.start()
        refreshWorkspace()
    }

    /// App termination waits for the same recorder drain/close completion as the
    /// manual Stop button. The caller decides when to reply to AppKit's quit request.
    func prepareForApplicationTermination(completion: @escaping (ExperimentRecorderStopOutcome) -> Void) {
        guard recorder.isRecording || recorder.isStopping else {
            // Keep AppDelegate's terminateLater/reply ordering asynchronous even
            // if a manual Stop finishes in the narrow gap before this call.
            let outcome = ExperimentRecorderStopOutcome.notRecording(path: recorder.path)
            DispatchQueue.main.async { completion(outcome) }
            return
        }
        noteLocal("recording", "stop for quit", kind: .recording)
        recorder.stop(reason: "application quit") { [weak self] outcome in
            DispatchQueue.main.async {
                self?.noteRecordingOutcome(outcome)
                completion(outcome)
            }
        }
        refreshWorkspace()
    }

    /// A failed recorder drain must not disappear with the app. Keep the Lab
    /// window alive, show the exact failure/path, and require an explicit choice
    /// before AppDelegate replies to AppKit's pending termination request.
    func presentTerminationSaveFailure(path: String?, message: String,
                                       completion: @escaping (Bool) -> Void) {
        let whereText = path.map { L("\n\nPartial recording files remain at:\n", "\n\n저장된 일부 기록 파일 위치:\n") + $0 } ?? ""
        lastRecordingOutcome = .failed(path: path, message: message)
        refreshWorkspace()
        show()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Recording could not be saved completely", "기록을 완전히 저장하지 못했습니다")
        alert.informativeText = L("The app will stay open by default so you can inspect the recording and retry a new recording if needed. Already-lost queued data cannot be reconstructed automatically.\n\nError: ", "기록을 확인하고 필요하면 다시 기록할 수 있도록 앱은 기본적으로 열어 둡니다. 이미 잃어버린 데이터는 자동으로 되살릴 수 없습니다.\n\n오류: ") + message + whereText
        alert.addButton(withTitle: L("Keep App Open", "앱 열어두기"))
        alert.addButton(withTitle: L("Quit Anyway", "그래도 종료"))

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertSecondButtonReturn)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
    private func markTimeline(_ detail: String) {
        let session = coordinator.sessionSnapshot()
        noteLocal("marker", detail, kind: .marker, status: .marker)
        recorder.mark(kind: "marker", detail: detail,
                      sessionID: session.sessionID, epoch: session.epoch, simTick: session.simTick)
    }
    @objc private func markBaseline() { markTimeline("baseline") }
    @objc private func markStimulusOn() { markTimeline("stimulus_on") }
    @objc private func markStimulusOff() { markTimeline("stimulus_off") }
    @objc private func markObservation() { markTimeline("observation") }

    private func updateMood(_ t: LabTelemetry, now: Date) {
        var inputs = FlyMoodInputs()
        inputs.foodOdor = max(t.bodyOdorL, t.bodyOdorR)
        inputs.nearestFoodMM = t.bodyNearestFoodDistanceMm
        inputs.temperatureC = t.temperatureC
        inputs.escape = t.brainEscape
        inputs.nervous = t.brainNervous
        inputs.sleep = t.brainSleep
        inputs.grooming = t.brainGroomDrive
        let reading = moodEstimator.update(inputs, now: now)
        moodEmoji.stringValue = reading.mood.emoji
        moodTitle.stringValue = reading.mood.title
        moodReason.stringValue = reading.reason
        moodTitle.superview?.superview?.setAccessibilityValue("\(reading.mood.title) — \(reading.reason)")
    }

    /// The participant body bumping into the fly counts as a hit for the mood
    /// readout (edge-triggered: one hit per contact, not per frame).
    private func noteParticipantContact(_ snapshot: WorldRenderSnapshot) {
        guard let player = snapshot.player, let fly = snapshot.fly,
              player.positionMM.count == 3, fly.positionMM.count == 3 else {
            participantTouchingFly = false
            return
        }
        let d = sqrt(zip(player.positionMM, fly.positionMM).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
        let touching = d < (player.collisionRadiusMM ?? 2.5) + 1.5
        if touching && !participantTouchingFly { moodEstimator.registerHit(strength: 0.6) }
        participantTouchingFly = touching
    }

    private func onOff(_ on: Bool) -> String { on ? L("ON", "켬") : L("OFF", "끔") }

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
        arenaPlacement.worldObjects = snapshot.objects.map { object in
            LabWorldObjectRemote(id: object.id, shape: object.shape,
                                 positionMM: object.positionMM, sizeMM: object.sizeMM,
                                 yawDeg: yawRadians(quaternion: object.orientationQuatXYZW) * 180 / .pi)
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

    /// Each ACK resolves its timeline row once; only that first resolution is
    /// recorded, so the repeated `ack` field of lab_state never double-counts.
    private func handle(ack: LabAck) {
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
                let message = ack.message.isEmpty ? L("command rejected", "명령 거절됨") : ack.message
                worldObjectStatusLabel.stringValue = L("Object status — ERROR · ", "물체 상태 — 오류 · ") + message
                worldObjectStatusLabel.textColor = .systemRed
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
    private func refreshWorkspace() {
        let recording: WorkspaceRecording
        switch recorder.state {
        case .recording:
            recording = .recording(path: recorder.path ?? "",
                                   elapsed: Date().timeIntervalSince(recordingStartedAt ?? Date()))
        case .stopping:
            recording = .stopping(path: recorder.path)
        default:
            recording = lastRecordingOutcome
        }
        let body = bridge?.bodyFreshness()
        let snapshot = WorkspaceSnapshot(
            connection: WorkspaceSnapshot.connection(
                bridgeEnabled: bridge != nil, service: service?.state,
                connected: bridge?.connected == true,
                bodyFresh: body?.isFresh == true, bodyAge: body?.ageSeconds),
            session: coordinator.sessionSnapshot(),
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

    private func refresh() {
        let now = Date()
        let t = coordinator.labTelemetry()
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
                        viewState.accept(snapshot: snapshot, connectionGeneration: viewerGeneration)
                        worldViewer.apply(snapshot: snapshot)
                        updateArenaFromAtomicSnapshot(snapshot)
                        noteParticipantContact(snapshot)
                        let pickSuffix = lastPickSummary.isEmpty ? "" : " · \(lastPickSummary)"
                        let playerSuffix = snapshot.player == nil ? "" : L(" · participant body", " · 참여자 있음")
                        worldViewerStatusLabel.stringValue = L("3D world — snapshot #\(snapshotID) · rev \(revision) · tick \(snapshot.simTick) · \(snapshot.objects.count) objects\(playerSuffix)\(pickSuffix)", "3D 화면 — 시각 \(snapshot.simTick) ms · 물체 \(snapshot.objects.count)개\(playerSuffix)\(pickSuffix)")
                        worldViewerStatusLabel.textColor = .secondaryLabelColor
                    } else {
                        worldViewerStatusLabel.stringValue = L("3D world — snapshot error: ", "3D 화면 — 화면 오류: ") + (snapshot.error ?? L("backend rejected request", "시뮬레이터가 요청을 거절함"))
                        worldViewerStatusLabel.textColor = .systemRed
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
                    worldViewerStatusLabel.textColor = .systemOrange
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
                        worldViewerStatusLabel.stringValue = "3D world — \(lastPickSummary)"
                        worldViewerStatusLabel.textColor = .systemRed
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
                worldViewerStatusLabel.textColor = bridge.connected ? .systemOrange : .secondaryLabelColor
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
                let order = ["box", "sphere", "wall", "food"]
                let parts = order.compactMap { shape -> String? in
                    guard let total = capacity[shape] else { return nil }
                    let remain = free[shape] ?? max(0, total - (state?.authoritativeObjects?.filter { $0.shape == shape }.count ?? 0))
                    return "\(shape) \(total - remain)/\(total)"
                }
                worldCapacityLabel.stringValue = L("Object capacity — ", "물체 수 (사용/최대) — ") + parts.joined(separator: " · ")
            }
            let (newAcks, cursor) = bridge.labAcks(after: ackCursor)
            ackCursor = cursor
            newAcks.forEach(handle(ack:))
            timeline.expire(now: now, connectionGeneration: bridge.connectionGeneration)
            let (newEvents, nextEventCursor) = bridge.labEvents(after: eventCursor)
            eventCursor = nextEventCursor
            for notice in newEvents where !notice.event.isEmpty {
                let detail = notice.detail?.summary ?? ""
                noteLocal("event", detail.isEmpty ? notice.event : "\(notice.event) — \(detail)",
                          kind: .physical, status: .event, tick: notice.detail?.simTickMS)
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

        refreshWorkspace()
        renderViewState()
        updateMood(t, now: now)
        let rows = timeline.recent(5).map(\.line)
        timelineLabel.stringValue = rows.isEmpty
            ? L("t\(session.simTick) · No commands yet — stimuli, markers and their ACKs appear here", "아직 명령이 없습니다 — 자극, 구간 표시와 그 결과가 여기에 나타납니다")
            : rows.joined(separator: "\n")
        responseLabel.stringValue = String(format: L(
            "body %.0f ms old · speed %.4f m/s · contact %.2f · eye sample t%d · loom L/R %.3f/%.3f · brain %.1f Hz",
            "몸 데이터 %.0f ms 전 · 속도 %.4f m/s · 발 닿음 %.2f · 눈 샘플 t%d · 다가옴 감지 L/R %.3f/%.3f · 뇌 활동 %.1f Hz"),
            max(0, t.bodyPacketAgeS * 1000), t.bodyVX, t.bodyContactMean,
            t.bodyEyeSampleSimTick, t.loomL, t.loomR, t.ratePop)
        responseLabel.textColor = (bridge?.bodyFreshness().isFresh == true) ? .secondaryLabelColor : .systemOrange

        if let result = bridge?.latestPlayerInputResult(),
           result.seq == lastPlayerInputSeq {
            if result.ok {
                playerInputStatusLabel.stringValue = L("Participant controls — input #\(result.seq) applied at tick \(result.appliedTick ?? result.requestedTick)", "참여 조작 — 입력 적용됨 (시각 \(result.appliedTick ?? result.requestedTick) ms)")
                playerInputStatusLabel.textColor = .systemGreen
            } else {
                playerInputStatusLabel.stringValue = L("Participant controls — input rejected: ", "참여 조작 — 입력 거절됨: ") + (result.error ?? result.status)
                playerInputStatusLabel.textColor = .systemRed
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
            foodTelemetryLabel.stringValue = String(format: L("Food odor — left %.3f · right %.3f · nearest source: %@ · ORN %.1f/%.1f Hz", "먹이 냄새 — 왼쪽 %.3f · 오른쪽 %.3f · 가장 가까운 먹이: %@ · 후각 뉴런 %.1f/%.1f Hz"),
                                                     t.bodyOdorL, t.bodyOdorR, nearest,
                                                     t.rateFoodOdorL, t.rateFoodOdorR)
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

        let nearest = t.bodyNearestFoodDistanceMm >= 0
            ? String(format: "%.1f mm", t.bodyNearestFoodDistanceMm)
            : L("none", "없음")
        // The body packet is the same fresh backend snapshot that drives the
        // neural model, so source diagnostics cannot disagree with actual
        // LabWorld timer expiry merely because lab_state arrived at another rate.
        let windSource = t.bodyPacketAgeS >= 0
            ? String(format: "%.2f%@", t.bodyWindStrength,
                     (t.bodyWindStrength > 0 && t.bodyWindSensory) ? L(" sensory", " 감각") : "")
            : L("unavailable", "없음")
        let touchSource = t.bodyPacketAgeS >= 0
            ? String(format: "%.2f%@", t.bodyTouchStrength,
                     (t.bodyTouchStrength > 0 && t.bodyTouchSensory) ? L(" sensory", " 감각") : "")
            : L("unavailable", "없음")
        let sourceLine = String(format: LabLanguage.current == .korean ?
            "1  바깥 자극 → 감각기관    먹이 %@ → 냄새 %.3f/%.3f  |  눈에 보이는 커짐 %.3f/%.3f → 다가옴 %.3f/%.3f  |  바람 %@  |  닿음 %@  |  온도 %.1f°C" :
            "1  Source → sensor     food %@ → odor %.3f/%.3f  |  vision expansion %.3f/%.3f → loom %.3f/%.3f  |  wind %@  |  touch %@  |  temp %.1f°C",
            nearest, t.bodyOdorL, t.bodyOdorR,
            t.bodyOpticExpansionL, t.bodyOpticExpansionR, t.loomL, t.loomR,
            windSource, touchSource, t.temperatureC)
        let currentLine = String(format: LabLanguage.current == .korean ?
            "2  감각기관 → 신호 세기    먹이 냄새 %.3f/%.3f  |  따뜻함/차가움 %.3f/%.3f  |  더듬이 바람 C/E %.3f/%.3f  (시뮬레이션 단위)" :
            "2  Sensor → current    ORN food %.3f/%.3f  |  TRN warm/cool %.3f/%.3f  |  JO-C/E wind %.3f/%.3f  (simulation current units)",
            t.odorDriveL, t.odorDriveR, t.thermoWarmDrive, t.thermoCoolDrive,
            t.windCDrive, t.windEDrive)
        let neuralLine = String(format: LabLanguage.current == .korean ?
            "3  감각 뉴런 → 뇌    후각 L/R %.1f/%.1f Hz  |  따뜻함/차가움 %.1f/%.1f  |  바람 C/E %.1f/%.1f  |  다가옴 감지 %.1f  |  왼쪽/오른쪽 돌기 %.1f/%.1f  |  앞으로 걷기 %.1f" :
            "3  Receptor → brain    ORN L/R %.1f/%.1f Hz  |  TRN warm/cool %.1f/%.1f  |  JO-C/E %.1f/%.1f  |  loom %.1f  |  DNa L/R %.1f/%.1f  |  DNp09 %.1f",
            t.rateFoodOdorL, t.rateFoodOdorR, t.rateThermoWarm, t.rateThermoCool,
            t.rateWindC, t.rateWindE, t.rateLoom, t.rateDNaL, t.rateDNaR, t.rateFwd)
        let commandLine: String
        if t.brainSignalsAvailable {
            commandLine = String(format: LabLanguage.current == .korean ?
                "4  뇌 → 몸에 내린 명령    걷기 %.2f  |  돌기 %.2f  |  도망 %@  |  뒤로 %@  |  손질 %.2f  |  날개 %.2f  |  흥분도 %.2f  |  긴장 %.2f  |  활동 속도 %.2f  |  잠 %@  |  왼쪽/오른쪽 출력 %.3f/%.3f" :
                "4  BrainSignals → FlyGym controller    walk %.2f  |  turn %.2f  |  escape %@  |  back %@  |  groom %.2f  |  wing %.2f  |  arousal %.2f  |  nervous %.2f  |  tempo %.2f  |  sleep %@  |  controller L/R %.3f/%.3f",
                t.brainWalkDrive, t.brainTurnBias, onOff(t.brainEscape),
                onOff(t.brainBackward), t.brainGroomDrive, t.brainWingDrive,
                t.brainArousal, t.brainNervous, t.brainTempo, onOff(t.brainSleep),
                t.bodyControllerLeft, t.bodyControllerRight)
        } else {
            commandLine = String(format: LabLanguage.current == .korean ?
                "4  뇌 → 몸에 내린 명령    이번 순간에는 해석된 명령 없음  |  왼쪽/오른쪽 출력 %.3f/%.3f" :
                "4  BrainSignals → FlyGym controller    no decoded BrainSignals this frame  |  controller L/R %.3f/%.3f",
                t.bodyControllerLeft, t.bodyControllerRight)
        }
        let bodyPacketDetail = t.bodyPacketAgeS >= 0
            ? String(format: L("body packet %.0f ms old · MuJoCo t %.3f s · sim/wall %.2fx",
                               "몸 데이터 %.0f ms 전 · 물리 시각 %.3f s · 실시간 대비 %.2f배"),
                     t.bodyPacketAgeS * 1000, t.bodySimTime, t.bodySimWallRatio)
            : L("no fresh body packet used", "새 몸 데이터 없음")
        let motionLine = String(format: LabLanguage.current == .korean ?
            "5  실제로 측정한 움직임    앞으로 %.4f m/s  |  회전 %.2f rad/s  |  발 닿음 %.2f  |  %@" :
            "5  Measured motion     forward %.4f m/s  |  yaw %.2f rad/s  |  contact %.2f  |  %@",
            t.bodyVX, t.bodyYawRate, t.bodyContactMean, bodyPacketDetail)
        signalPathLabel.stringValue = [sourceLine, currentLine, neuralLine, commandLine, motionLine]
            .joined(separator: "\n")

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
            freshnessLabel.stringValue = L("Packets — ", "데이터 — ") + "\(bodyStatus) · \(envStatus)"

            if let s = state {
                var bits = [String(format: "%.1f s", s.t)]
                if let n = s.objectCount { bits.append(L("\(n) object\(n == 1 ? "" : "s")", "물체 \(n)개")) }
                if let w = s.wind { bits.append(String(format: L("wind %.2f", "바람 %.2f"), w)) }
                if let c = s.temperature { bits.append(String(format: "%.1f°C", c)) }
                let eyeState = { (covered: Bool) in covered ? L("covered", "가림") : L("open", "뜸") }
                if let l = s.leftEyeCovered { bits.append(L("left eye ", "왼눈 ") + eyeState(l)) }
                if let r = s.rightEyeCovered { bits.append(L("right eye ", "오른눈 ") + eyeState(r)) }
                if let e = s.error, !e.isEmpty { bits.append(L("error: ", "오류: ") + e) }
                if let event, !event.event.isEmpty { bits.append(L("last event: ", "최근 알림: ") + event.event) }
                remoteStateLabel.stringValue = L("Environment — ", "환경 — ") + bits.joined(separator: " · ")
            } else {
                remoteStateLabel.stringValue = L("Environment — waiting for FlyGym state…", "환경 — 시뮬레이터 상태를 기다리는 중…")
            }

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
            commandDiagnosticsLabel.stringValue = commandBits.joined(separator: "\n")
        } else {
            freshnessLabel.stringValue = L("Packets — body STALE · bridge disabled · environment STALE · bridge disabled",
                                           "데이터 — 물리 시뮬레이터가 꺼져 있어 몸·환경 데이터가 없습니다")
            remoteStateLabel.stringValue = L("Environment — local brain/sensory controls are still available", "환경 — 시뮬레이터 없이도 뇌·감각 조작은 쓸 수 있습니다")
            let sleeping = t.brainSleep
            commandDiagnosticsLabel.stringValue = L("Brain state — sleep ", "뇌 상태 — 잠 ") + onOff(sleeping)
                + L(" · sensoryGate ×", " · 감각 통과율 ×") + (sleeping ? "0.55" : "1.00")
                + L("\nCommands — FlyGym bridge disabled", "\n명령 — 물리 시뮬레이터 꺼짐")
        }
    }
}

extension NSToolbarItem.Identifier {
    static let labMode = NSToolbarItem.Identifier("lab.mode")
    static let labRun = NSToolbarItem.Identifier("lab.run")
    static let labRecord = NSToolbarItem.Identifier("lab.record")
    static let labLanguage = NSToolbarItem.Identifier("lab.language")
}

extension LabWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator,
                                                 .labMode, .flexibleSpace, .labRun, .labRecord, .labLanguage]
        if #available(macOS 14.0, *) { items += [.inspectorTrackingSeparator, .toggleInspector] }
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .labMode:
            item.view = viewModeControl
            item.label = L("Mode", "방식")
            item.toolTip = L("Observe moves only the camera; Participate puts a controllable body in the world", "관찰은 카메라만 움직이고, 참여는 조종할 수 있는 몸을 세계에 넣습니다")
        case .labRun:
            item.view = runButton
            item.label = L("Pause / Resume", "일시 정지 / 재개")
        case .labLanguage:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for language in LabLanguage.allCases {
                popup.addItem(withTitle: language.menuTitle)
                popup.lastItem?.representedObject = language.rawValue
            }
            selectPopupValue(popup, LabLanguage.current.rawValue)
            popup.bezelStyle = .texturedRounded
            popup.target = self
            popup.action = #selector(languagePicked(_:))
            popup.setAccessibilityLabel(L("Interface language", "화면 언어"))
            item.view = popup
            item.label = L("Language", "언어")
            item.toolTip = L("Interface language — English or Korean", "화면 언어 — 영어 또는 한국어")
        case .labRecord:
            item.view = recordButton
            item.label = L("Record", "기록")
        default:
            return nil
        }
        return item
    }
}
