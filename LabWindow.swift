// LabWindow.swift — AppKit Virtual Fly Lab integrated control/telemetry window.

import Cocoa

private final class LabFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class LabArenaPlacementView: NSView {
    var onPick: ((Double, Double) -> Void)?
    var selectedShape: String = "box" { didSet { needsDisplay = true } }
    var selectedPoint: (x: Double, y: Double)? { didSet { needsDisplay = true } }
    var worldObjects: [LabWorldObjectRemote] = [] { didSet { needsDisplay = true } }
    var flyPose: (x: Double, y: Double, heading: Double)? { didSet { needsDisplay = true } }

    private let minimumExtentMm = 100.0

    override var intrinsicContentSize: NSSize { NSSize(width: 720, height: 360) }

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
        let text = String(format: "fly  %.1f, %.1f", flyPose.x, flyPose.y)
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
        ("+X forward" as NSString).draw(at: CGPoint(x: origin.x + 7, y: g.rect.maxY - 16), withAttributes: attrs)
        ("+Y left" as NSString).draw(at: CGPoint(x: g.rect.minX + 6, y: origin.y + 5), withAttributes: attrs)
        (String(format: "±%.0f mm · %d objects", g.extent, worldObjects.count) as NSString)
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

        let coordinate = String(format: "pick %.1f, %.1f mm", selectedPoint.x, selectedPoint.y)
        (coordinate as NSString).draw(at: CGPoint(x: min(bounds.maxX - 120, p.x + 10),
                                                  y: max(4, min(bounds.maxY - 16, p.y + 7))),
                                        withAttributes: attrs)
    }
}

final class LabWindowController: NSWindowController, NSWindowDelegate {
    private unowned let coordinator: Coordinator
    private let bridge: FlyGymBridge?
    private let recorder = ExperimentRecorder()
    private var timer: Timer?

    private let protocolLabel = NSTextField(labelWithString: "FlyGym bridge — starting…")
    private let remoteStateLabel = NSTextField(labelWithString: "Environment — waiting for state…")
    private let recorderLabel = NSTextField(labelWithString: "not recording")
    private let freshnessLabel = NSTextField(labelWithString: "Packets — waiting for body/environment telemetry…")
    private let commandDiagnosticsLabel = NSTextField(wrappingLabelWithString: "Commands — no command sent yet")
    private let signalPathLabel = NSTextField(wrappingLabelWithString: "Signal path — waiting for telemetry…")
    private let sessionStatusLabel = NSTextField(wrappingLabelWithString: "Session — interactive")
    private let viewStateLabel = NSTextField(wrappingLabelWithString: "View — OBSERVE · fly fly · object none · tick 0 ms · RUNNING")
    private let viewModeControl = NSSegmentedControl(labels: ["Observe", "Participate", "Edit"],
                                                     trackingMode: .selectOne,
                                                     target: nil, action: nil)
    private let temperatureModeStatusLabel = NSTextField(wrappingLabelWithString: "Neural input: OFF — environment-only temperature is recorded without neural input.")

    private let objectID = NSTextField(string: "")
    private let objectShape = NSPopUpButton(frame: .zero, pullsDown: false)
    private let objectX = NSTextField(string: "60")
    private let objectY = NSTextField(string: "0")
    private let objectZ = NSTextField(string: "5")
    private let objectSize = NSTextField(string: "5")
    private let objectSpeed = NSTextField(string: "12")
    private let objectEndDistance = NSTextField(string: "8")
    private let worldObjectStatusLabel = NSTextField(wrappingLabelWithString: "Object status — ready")
    private let worldCapacityLabel = NSTextField(wrappingLabelWithString: "Object capacity — waiting for backend…")
    private let worldViewer = WorldViewer(frame: .zero)
    private let worldViewerStatusLabel = NSTextField(wrappingLabelWithString: "3D world — waiting for V5.1 backend capability…")
    private let observationCameraMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerInputStatusLabel = NSTextField(wrappingLabelWithString: "Participant controls — waiting for V5.5 player_input capability…")
    private let playerForwardKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerBackwardKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerLeftKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerRightKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerInteractKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let playerController = PlayerController()
    private var playerCaptureArmed = false
    private var lastPlayerInputConnectionGeneration: UInt64?
    private var lastPlayerInputSeq: Int?
    private let arenaPlacement = LabArenaPlacementView(frame: .zero)
    private let createOnArenaClick = NSButton(checkboxWithTitle: "Create selected object when clicking arena", target: nil, action: nil)
    private var autoObjectSerial: [String: Int] = [:]
    private var lastAutoObjectID: String?
    private var lastObjectCommandID: Int?
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
    private var lastRecordedAckKey = ""
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

    init(coordinator: Coordinator, bridge: FlyGymBridge?) {
        self.coordinator = coordinator
        self.bridge = bridge
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Thongpari Fly Neuron Sim — Virtual Fly Lab V5.5"
        w.minSize = NSSize(width: 760, height: 600)
        PlayerInputFocusPolicy.prepareWindowForCapture(w)
        super.init(window: w)
        w.delegate = self
        buildUI()
        arenaPlacement.onPick = { [weak self] x, y in
            guard let self else { return }
            self.objectX.stringValue = String(format: "%.1f", x)
            self.objectY.stringValue = String(format: "%.1f", y)
            self.worldObjectStatusLabel.stringValue = String(format: "Object status — picked X %.1f · Y %.1f mm", x, y)
            self.worldObjectStatusLabel.textColor = .secondaryLabelColor
            if self.createOnArenaClick.state == .on { self.createObject() }
        }
        worldViewer.onPickRay = { [weak self] ray in
            guard let self, let bridge = self.bridge else { return }
            guard bridge.worldViewerV5_1Available else {
                self.worldViewerStatusLabel.stringValue = "3D world — backend does not advertise V5.1 snapshot/pick"
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            guard let source = self.worldViewer.currentSnapshotSource else {
                self.worldViewerStatusLabel.stringValue = "3D world — no atomic snapshot available for picking"
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            guard let seq = bridge.sendRayPick(rayOriginMM: ray.originMM,
                                               rayDirection: ray.direction,
                                               sourceSnapshotSeq: source.snapshotSeq,
                                               sourceWorldRevision: source.worldRevision,
                                               sourceSimTick: source.simTick) else {
                self.worldViewerStatusLabel.stringValue = "3D world — pick request was not queued"
                self.worldViewerStatusLabel.textColor = .systemOrange
                return
            }
            self.lastPickRequestSeq = seq
            self.lastPickSource = source
            self.worldViewerStatusLabel.stringValue = "3D world — authoritative pick #\(seq) pending…"
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
                if isEscape {
                    self.playerCaptureArmed = false
                    _ = self.playerController.setCaptureEnabled(false)
                    self.worldViewer.participateInputEnabled = false
                    self.playerInputStatusLabel.stringValue = "Participant controls — capture released by Esc · click the 3D view to recapture"
                }
            }
        }
        worldViewer.onPlayerKeyUp = { [weak self] keyCode in
            guard let self else { return }
            if let intent = self.playerController.handleKeyUp(keyCode: keyCode) {
                self.sendPlayerInput(intent, reason: "key up")
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
            self.playerInputStatusLabel.stringValue = "Participant controls — CAPTURED · WASD move · mouse look · E interact · Esc release"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var hasRecordingToFinish: Bool { recorder.isRecording || recorder.isStopping }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        releasePlayerHeldInput(reason: "window closed")
        // Keep the controller reusable from the menu; telemetry recording can
        // intentionally continue after the window is hidden.
    }

    func windowDidResignKey(_ notification: Notification) {
        releasePlayerHeldInput(reason: "window focus lost")
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSViewController()
        let rootView = NSView()
        root.view = rootView

        protocolLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        protocolLabel.textColor = .labelColor
        protocolLabel.lineBreakMode = .byTruncatingMiddle
        remoteStateLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        remoteStateLabel.textColor = .secondaryLabelColor
        remoteStateLabel.lineBreakMode = .byTruncatingMiddle
        freshnessLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        freshnessLabel.textColor = .secondaryLabelColor
        freshnessLabel.lineBreakMode = .byTruncatingMiddle
        viewStateLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        viewStateLabel.textColor = .labelColor
        viewStateLabel.lineBreakMode = .byTruncatingMiddle
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = 0
        // Participate becomes capability-gated in V5.4 once a backend-owned
        // collidable probe is available. Edit remains a later-version contract.
        viewModeControl.setEnabled(false, forSegment: 1)
        viewModeControl.setEnabled(false, forSegment: 2)

        let intro = NSTextField(wrappingLabelWithString:
            "Change the fly's environment or sensory input, then watch the whole-brain model respond. " +
            "Physical and sensory controls do not script a behavior; direct-neural controls are explicitly marked.")
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 2

        let quitButton = button("Quit Lab", #selector(quitLab))
        quitButton.toolTip = "Quit Thongpari Fly Neuron Sim. When launched by the lab launcher, its FlyGym bridge process is stopped too."
        let topStatusRow = NSStackView(views: [protocolLabel, NSView(), quitButton])
        topStatusRow.orientation = .horizontal
        topStatusRow.alignment = .centerY
        topStatusRow.spacing = 8
        topStatusRow.distribution = .fill
        let statusStack = NSStackView(views: [topStatusRow, freshnessLabel, remoteStateLabel])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 3
        statusStack.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 6, right: 2)
        topStatusRow.widthAnchor.constraint(equalTo: statusStack.widthAnchor).isActive = true

        let commonStateRow = NSStackView(views: [label("Mode"), viewModeControl, NSView(),
                                                  button("Pause", #selector(pauseSession)),
                                                  button("Resume", #selector(resumeSession))])
        commonStateRow.orientation = .horizontal
        commonStateRow.alignment = .centerY
        commonStateRow.spacing = 8
        commonStateRow.distribution = .fill
        let commonStateStack = NSStackView(views: [commonStateRow, viewStateLabel])
        commonStateStack.orientation = .vertical
        commonStateStack.alignment = .leading
        commonStateStack.spacing = 5
        commonStateStack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        commonStateStack.wantsLayer = true
        commonStateStack.layer?.cornerRadius = 7
        commonStateStack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        commonStateRow.widthAnchor.constraint(equalTo: commonStateStack.widthAnchor, constant: -16).isActive = true

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("World", worldPage()))
        tabs.addTabViewItem(tab("Stimuli", sensesPage()))
        tabs.addTabViewItem(tab("Brain", brainPage()))
        tabs.addTabViewItem(tab("Live Data", metricsPage()))
        tabs.addTabViewItem(tab("Experiments", experimentPage()))

        root.addChild(tabs)
        let stack = NSStackView(views: [intro, statusStack, commonStateStack, tabs.view])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),
            tabs.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 500)
        ])
        window.contentViewController = root
        renderViewState()
    }

    @objc private func viewModeChanged() {
        let modes = LabViewMode.allCases
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
                    playerInputStatusLabel.stringValue = "Participant controls — could not establish interactive input session"
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
            playerCaptureArmed = bridge?.playerInputV5_5Available == true
            if playerCaptureArmed {
                window?.makeFirstResponder(worldViewer)
            }
            viewModeControl.selectedSegment = modes.firstIndex(of: viewState.displayedMode) ?? 0
            worldViewerStatusLabel.stringValue = "3D world — enabling backend participant probe…"
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
                worldViewerStatusLabel.stringValue = "3D world — disabling backend participant probe…"
            }
        case .edit:
            viewModeControl.selectedSegment = modes.firstIndex(of: viewState.mode) ?? 0
        }
        renderViewState()
    }

    private func renderViewState() {
        viewModeControl.setEnabled(bridge?.playerV5_4Available == true, forSegment: 1)
        viewModeControl.setEnabled(false, forSegment: 2)
        let playerAvailable = bridge?.playerV5_4Available == true
        let playerInputAvailable = bridge?.playerInputV5_5Available == true
        let generation = bridge?.connectionGeneration ?? 0
        if let previous = lastPlayerInputConnectionGeneration, previous != generation {
            _ = playerController.setCaptureEnabled(false)
            _ = playerController.releaseHeldInput(blockUntilFreshPress: true)
            playerCaptureArmed = false
            lastPlayerInputSeq = nil
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
            // The Participate click itself arms capture and focuses WorldViewer.
            // If the user moved focus to an editor/control while the backend was
            // confirming the participant, fail closed rather than stealing it back.
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
                    ? "Participant controls — CAPTURED · WASD move · mouse look · E interact · Esc release"
                    : "Participant controls — released · click the 3D view to capture"
                playerInputStatusLabel.textColor = worldViewer.participateInputEnabled ? .systemGreen : .secondaryLabelColor
            } else {
                playerInputStatusLabel.stringValue = "Participant controls — backend has V5.4 body but not V5.5 player_input"
                playerInputStatusLabel.textColor = .systemOrange
            }
        } else {
            playerInputStatusLabel.stringValue = "Participant controls — Observe mode; camera controls remain presentation-only"
            playerInputStatusLabel.textColor = .secondaryLabelColor
        }
        viewModeControl.selectedSegment = LabViewMode.allCases.firstIndex(of: viewState.displayedMode) ?? 0
        viewStateLabel.stringValue = viewState.commonStatusLine
        viewStateLabel.textColor = viewState.sessionPhase == .failed ? .systemRed : .labelColor
        sessionStatusLabel.stringValue = viewState.sessionStatusLine
        sessionStatusLabel.textColor = viewState.sessionPhase == .failed ? .systemRed : .labelColor
    }

    private func playerInputFocusAllowsCapture() -> Bool {
        guard let window else { return false }
        return PlayerInputFocusPolicy.allowsCapture(
            windowIsKey: window.isKeyWindow,
            firstResponder: window.firstResponder,
            viewer: worldViewer)
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
            playerInputStatusLabel.stringValue = "Participant controls — waiting for authoritative session snapshot before \(reason)"
            playerInputStatusLabel.textColor = .systemOrange
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
            playerInputStatusLabel.stringValue = "Participant controls — \(reason) was not queued"
            playerInputStatusLabel.textColor = .systemOrange
            return nil
        }
        lastPlayerInputSeq = seq
        return seq
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
        playerInputStatusLabel.stringValue = "Participant controls — key mapping saved · Esc remains fixed safety release"
        playerInputStatusLabel.textColor = .secondaryLabelColor
    }

    private func tab(_ title: String, _ vc: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: vc)
        item.label = title
        return item
    }

    private func page(_ views: [NSView]) -> NSViewController {
        let vc = NSViewController()
        let view = NSView()
        vc.view = view
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        let document = LabFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14)
        ])
        for child in views where child.identifier?.rawValue == "SiliconFlyLabSection" {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return vc
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 8
        return s
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = .secondaryLabelColor
        l.font = NSFont.systemFont(ofSize: 11.5)
        l.maximumNumberOfLines = 4
        return l
    }

    private func field(_ f: NSTextField, width: CGFloat = 70) -> NSTextField {
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 12)
        return l
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: selector)
        b.bezelStyle = .rounded
        return b
    }

    private func section(_ title: String,
                         kind: LabInterventionKind? = nil,
                         help: String? = nil,
                         views: [NSView]) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        var content: [NSView] = [titleLabel]

        if let kind {
            let explanation: String
            switch kind {
            case .physical:
                explanation = "PHYSICAL · changes the actual MuJoCo/FlyGym world or body"
            case .sensoryModel:
                explanation = "SENSORY MODEL · converts a stimulus into existing modeled sensory inputs"
            case .directNeural:
                explanation = "DIRECT NEURAL · bypasses the sense organ and stimulates an existing FlyWire group"
            }
            let tag = NSTextField(labelWithString: explanation)
            tag.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            tag.textColor = .secondaryLabelColor
            content.append(tag)
        }
        if let help { content.append(note(help)) }
        content.append(contentsOf: views)

        let divider = NSBox()
        divider.boxType = .separator
        content.append(divider)

        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 4, right: 2)
        stack.identifier = NSUserInterfaceItemIdentifier("SiliconFlyLabSection")
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
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

    private func worldPage() -> NSViewController {
        _ = field(objectID, width: 120)
        objectID.placeholderString = "auto name"
        worldObjectStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        worldObjectStatusLabel.textColor = .secondaryLabelColor
        worldObjectStatusLabel.maximumNumberOfLines = 2
        worldCapacityLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        worldCapacityLabel.textColor = .secondaryLabelColor
        worldCapacityLabel.maximumNumberOfLines = 2
        worldViewerStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        worldViewerStatusLabel.textColor = .secondaryLabelColor
        worldViewerStatusLabel.maximumNumberOfLines = 2
        playerInputStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        playerInputStatusLabel.textColor = .secondaryLabelColor
        playerInputStatusLabel.maximumNumberOfLines = 2
        worldViewer.translatesAutoresizingMaskIntoConstraints = false
        worldViewer.heightAnchor.constraint(equalToConstant: 360).isActive = true
        worldViewer.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        addPopupItems(observationCameraMode, WorldViewerCameraMode.allCases.map { ($0.title, $0.rawValue) })
        observationCameraMode.target = self
        observationCameraMode.action = #selector(observationCameraModeChanged)
        selectPopupValue(observationCameraMode, WorldViewerCameraMode.orbit.rawValue)
        configurePlayerKeyPopups()
        [objectX, objectY, objectZ, objectSize, objectSpeed, objectEndDistance].forEach { _ = field($0) }
        addPopupItems(objectShape, [
            ("Box", "box"),
            ("Sphere", "sphere"),
            ("Wall", "wall"),
            ("Food / odor source", "food")
        ])
        objectShape.target = self
        objectShape.action = #selector(objectShapeChanged)
        createOnArenaClick.state = .on
        arenaPlacement.translatesAutoresizingMaskIntoConstraints = false
        arenaPlacement.heightAnchor.constraint(equalToConstant: 360).isActive = true
        arenaPlacement.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        arenaPlacement.selectedShape = selectedValue(objectShape, fallback: "box")
        arenaPlacement.selectedPoint = (d(objectX), d(objectY))
        return page([
            section("3D world — backend snapshot", kind: .physical,
                    help: "Observe uses the presentation-only Orbit/follow/free camera. Selecting Participate arms WASD/mouse/E input and capture begins only after the backend participant is confirmed. Esc releases capture; click the 3D view to recapture. While captured, camera/pick gestures are suppressed rather than mixed with game input.",
                    views: [
                        row([label("Observation camera"), observationCameraMode,
                             button("Reset camera", #selector(resetObservationCamera))]),
                        worldViewer,
                        worldViewerStatusLabel
                    ]),
            section("Participant controls", kind: .physical,
                    help: "Bindings are saved locally. Text fields and controls never consume movement input. Esc is a fixed safety key: it immediately neutralizes held input and releases capture; click the 3D view to capture again. E only reports the V5.5 interact action state; grab/place is not implemented until V5.6.",
                    views: [
                        row([label("Forward"), playerForwardKey,
                             label("Backward"), playerBackwardKey,
                             label("Left"), playerLeftKey,
                             label("Right"), playerRightKey]),
                        row([label("Interact"), playerInteractKey,
                             label("Safety release"), label("Esc (fixed)")]),
                        playerInputStatusLabel
                    ]),
            section("Click to place an object", kind: .physical,
                    help: "This top-down arena remains a minimap and coordinate helper. Choose a type first, then click the arena. Up is +X forward and left is +Y. With the checkbox on, one click creates the selected object; turn it off to pick coordinates only.",
                    views: [
                        row([label("Type"), objectShape, label("Name"), objectID, createOnArenaClick]),
                        arenaPlacement,
                        row([label("X (mm)"), objectX, label("Y (mm)"), objectY,
                             label("Z (mm)"), objectZ, label("Size (mm)"), objectSize]),
                        row([button("Create at current coordinates", #selector(createObject)),
                             button("Update position", #selector(moveObject)),
                             button("Update size", #selector(resizeObject)),
                             button("Remove", #selector(deleteObject))]),
                        worldObjectStatusLabel,
                        worldCapacityLabel
                    ]),
            section("Move an object toward the fly", kind: .physical,
                    help: "This moves the selected object only. The fly is never commanded to approach or escape; any response comes from the model.",
                    views: [
                        row([label("Speed (mm/s)"), objectSpeed,
                             label("Stop distance (mm)"), objectEndDistance,
                             button("Start approach", #selector(approachObject))])
                    ]),
            section("Food marker", kind: .sensoryModel,
                    help: "Food is a non-colliding odor source. Its position creates left/right odor signals that drive the real ORN_DM1/VA2 FlyWire groups. Taste, reward, feeding, and automatic food-seeking are not modeled.",
                    views: []),
            section("Reset", help: "Use the smallest reset you need. Reset everything clears the world, body, brain state, modeled stimuli, eye covers, and live graphs.",
                    views: [
                        row([button("Reset world", #selector(resetWorld)),
                             button("Reset body", #selector(resetBody)),
                             button("Reset brain", #selector(resetBrain)),
                             button("Reset everything", #selector(resetAll))])
                    ])
        ])
    }

    private func sensesPage() -> NSViewController {
        [windStrength, windDuration, windDirection, touchStrength, touchDuration, temperature,
         flashIntensity, flashDuration].forEach { _ = field($0) }
        windPhysical.state = .on; windSensory.state = .on
        windPhysical.title = "Apply physical force"
        windSensory.title = "Drive wind receptors (JO-C/E)"
        windContinuous.title = "Keep on until stopped"
        addPopupItems(touchTarget, [
            ("Thorax", "thorax"), ("Head", "head"), ("Abdomen", "abdomen"),
            ("Left front leg", "left_front_leg"), ("Left middle leg", "left_middle_leg"),
            ("Left hind leg", "left_hind_leg"), ("Right front leg", "right_front_leg"),
            ("Right middle leg", "right_middle_leg"), ("Right hind leg", "right_hind_leg")
        ])
        addPopupItems(temperatureMode, [
            ("FlyWire thermosensory (TRN)", "flywire_sensory"),
            ("Environment only (record value)", "environment_only"),
            ("Legacy physiology (tempo model)", "modeled_physiology")
        ])
        selectPopupValue(temperatureMode, "environment_only")
        temperatureMode.target = self
        temperatureMode.action = #selector(temperatureModeChanged)
        addPopupItems(flashEye, [("Left eye", "left"), ("Right eye", "right"), ("Both eyes", "both")])

        let coverLeftButton = button("Cover left eye", #selector(coverLeft))
        let restoreLeftButton = button("Open left eye", #selector(restoreLeft))
        let coverRightButton = button("Cover right eye", #selector(coverRight))
        let restoreRightButton = button("Open right eye", #selector(restoreRight))
        eyeButtons = [coverLeftButton, restoreLeftButton, coverRightButton, restoreRightButton]

        temperatureModeStatusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        temperatureModeStatusLabel.maximumNumberOfLines = 2
        updateTemperatureModeStatus()
        return page([
            section("Vision", kind: .sensoryModel,
                    help: "Eye cover changes the rendered input reaching that eye. Flash changes full-field brightness telemetry only; it does not invent a direct flash-to-escape circuit.",
                    views: [
                        row([coverLeftButton, restoreLeftButton, coverRightButton, restoreRightButton]),
                        row([label("Flash"), flashEye, label("Intensity (0–1)"), flashIntensity,
                             label("Duration (ms)"), flashDuration, button("Apply flash", #selector(applyFlash))])
                    ]),
            section("Wind", kind: .sensoryModel,
                    help: "Physical force pushes the MuJoCo thorax. Wind-receptor mode drives the real JO-C/E FlyWire groups. Direction is transformed relative to the fly's current body heading.",
                    views: [
                        row([label("Strength (0–1)"), windStrength, label("Direction (°)"), windDirection,
                             label("Duration (ms)"), windDuration]),
                        row([windPhysical, windSensory, windContinuous,
                             button("Apply wind", #selector(applyWind)), button("Stop", #selector(stopWind))])
                    ]),
            section("Touch", kind: .physical,
                    help: "The physical impulse is applied to the selected body part. The neural side is a generic modeled startle/touch channel; it is not body-part-specific tactile transduction.",
                    views: [
                        row([label("Body part"), touchTarget, label("Strength (0–1)"), touchStrength,
                             label("Duration (ms)"), touchDuration, button("Apply touch", #selector(applyTouch))])
                    ]),
            section("Temperature", kind: .sensoryModel,
                    help: "FlyWire thermosensory drives TRN_VP2 for warmth and TRN_VP3a/b for cooling. Environment-only records the value without neural input. The temperature-to-current conversion is a modeling assumption.",
                    views: [
                        row([label("Temperature (°C)"), temperature, label("Mode"), temperatureMode,
                             button("Set temperature", #selector(setTemperature))]),
                        temperatureModeStatusLabel,
                        button("Reset sensory controls", #selector(resetSenses))
                    ])
        ])
    }

    private func brainPage() -> NSViewController {
        addPopupItems(brainRole, [
            ("Giant Fiber — escape pathway (GF)", "GF"),
            ("Turn left channel (DNa-left)", "DNa-left"),
            ("Turn right channel (DNa-right)", "DNa-right"),
            ("Backward locomotion (MDN)", "MDN"),
            ("Forward locomotion (DNp09)", "DNp09"),
            ("Grooming-related output (DNg11)", "DNg11"),
            ("Escape / wing-related output (escW)", "escW"),
            ("Loom-sensitive visual — left (LC4/LPLC2)", "LC4/LPLC2-left"),
            ("Loom-sensitive visual — right (LC4/LPLC2)", "LC4/LPLC2-right"),
            ("Loom-sensitive visual — both (LC4/LPLC2)", "LC4/LPLC2"),
            ("Ascending group", "ascend"),
            ("Legacy sensory group (JO-A/B-like)", "sens"),
            ("Food odor receptors — left (ORN DM1/VA2)", "ORN-food-left"),
            ("Food odor receptors — right (ORN DM1/VA2)", "ORN-food-right"),
            ("Warm receptors (TRN VP2)", "TRN-warm"),
            ("Cool receptors (TRN VP3a/b)", "TRN-cool"),
            ("Wind receptor channel C (JO-C)", "JO-C-wind"),
            ("Wind receptor channel E (JO-E)", "JO-E-wind"),
            ("Dry-air receptors (HRN VP4)", "HRN-dry"),
            ("Moist-air receptors (HRN VP5)", "HRN-moist")
        ])
        _ = field(brainStrength); _ = field(brainDuration)
        return page([
            section("Direct population stimulation", kind: .directNeural,
                    help: "Use this only when you intentionally want to bypass the physical stimulus or sense organ. The selected existing FlyWire population is stimulated directly; downstream whole-brain dynamics still run normally.",
                    views: [
                        row([label("Population"), brainRole]),
                        row([label("Strength"), brainStrength, label("Duration (ms)"), brainDuration,
                             button("Stimulate", #selector(stimulateBrain))])
                    ]),
            section("How to interpret common choices",
                    help: "GF is an escape-pathway probe; DNp09 is associated with forward locomotor output; MDN with backward locomotion; DNa channels with turning; DNg11 with grooming-related output. These labels describe the modeled population readout, not a guaranteed behavior.",
                    views: [])
        ])
    }

    private func metricsPage() -> NSViewController {
        neuralGraph.fixedRange = 0...220
        commandGraph.fixedRange = 0...220
        sensoryGraph.fixedRange = 0...1.2
        flywireSensoryGraph.fixedRange = 0...0.065
        flywireSensoryGraph.valueDecimals = 3
        flywireSensoryGraph.unitLabel = "injected current · sim units"
        bodyGraph.fixedRange = -1.2...1.2
        visionGraph.fixedRange = 0...1.05
        for status in [bodyTelemetryLabel, foodTelemetryLabel, visionTelemetryLabel] {
            status.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            status.textColor = .secondaryLabelColor
        }
        commandDiagnosticsLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        commandDiagnosticsLabel.textColor = .secondaryLabelColor
        signalPathLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        signalPathLabel.textColor = .labelColor
        signalPathLabel.maximumNumberOfLines = 0
        signalPathLabel.lineBreakMode = .byWordWrapping
        for g in [neuralGraph, commandGraph, sensoryGraph, flywireSensoryGraph, bodyGraph, visionGraph] {
            g.translatesAutoresizingMaskIntoConstraints = false
            g.heightAnchor.constraint(equalToConstant: 138).isActive = true
            g.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        }
        return page([
            section("Signal path — find where a response stops",
                    help: "Read top to bottom. Each line uses only telemetry the current V4 runtime actually exposes; missing stages are labeled instead of guessed.",
                    views: [signalPathLabel, commandDiagnosticsLabel]),
            section("Brain activity",
                    help: "Spike-rate summaries in Hz. ‘walk’, ‘back’, and ‘groom’ are DN population readouts; a higher line means that population is currently more active, not that a behavior is guaranteed.",
                    views: [neuralGraph]),
            section("Descending / motor-related populations",
                    help: "DNa L/R are steering-related descending neurons; MDN is backward-related, DNp09 forward-walking-related, DNg11 grooming-related, and escW escape/wing-related. These are neural rates in Hz, not body commands.",
                    views: [commandGraph]),
            section("Compact sensory inputs",
                    help: "Loom is the left/right visual expansion signal. Gait is body feedback. ‘legacy air’ is the older generic sensory channel and is not the Lab's JO-C/E wind-receptor signal.",
                    views: [sensoryGraph]),
            section("FlyWire sensory groups",
                    help: "Modeled injected current sent to real FlyWire receptor groups: food odor ORNs, warm/cool TRNs, and JO-C/E wind channels. This is simulation current, not a 0–1 normalized score; the expected maxima are about 0.055–0.060.",
                    views: [flywireSensoryGraph, foodTelemetryLabel]),
            section("Body state",
                    help: "For one stable plot, speed is shown ×20, turn rate ÷5, and nearest-food distance ÷100. The exact movement values are shown below the graph.",
                    views: [bodyGraph, bodyTelemetryLabel]),
            section("Rendered-eye vision",
                    help: "Brightness is mean light level; target is the legacy configured-color occupancy; expansion is the generic raw-frame optic-expansion estimate. Expansion is an engineering visual-motion proxy, not reconstructed biological retinotopy.",
                    views: [visionGraph, visionTelemetryLabel]),
            button("Clear live graphs", #selector(clearGraphs))
        ])
    }

    private func experimentPage() -> NSViewController {
        recorderLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        recorderLabel.textColor = .secondaryLabelColor
        recorderLabel.lineBreakMode = .byTruncatingMiddle
        sessionStatusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        sessionStatusLabel.textColor = .labelColor
        return page([
            section("V4 experiment time",
                    help: "Interactive keeps the responsive V3 behavior. Deterministic starts a new tick-zero brain/body session: 1 ms neural ticks, one exact 20 ms FlyGym quantum at a time, independent of display FPS. Desktop cursor/window timing is excluded from deterministic neural input.",
                    views: [
                        sessionStatusLabel,
                        row([button("Start deterministic session", #selector(startDeterministicSession)),
                             button("Pause session", #selector(pauseSession)),
                             button("Resume session", #selector(resumeSession))])
                    ]),
            section("Record an experiment",
                    help: "Saves metadata, event markers, and telemetry under Documents/ThongpariFlyNeuronSimExperiments. Start recording before the baseline if you want a complete trial.",
                    views: [
                        row([button("Start recording", #selector(startRecording)), button("Stop & save", #selector(stopRecording))]),
                        recorderLabel
                    ]),
            section("Ready-made physical / sensory trials",
                    help: "These presets use the same controls available in World and Stimuli. They move objects or apply a stimulus, but never command the fly's behavior.",
                    views: [
                        row([button("Frontal looming object", #selector(presetFrontalLoom)),
                             button("Loom from left", #selector(presetLeftLoom)),
                             button("Loom from right", #selector(presetRightLoom))]),
                        row([button("Loom with left eye covered", #selector(presetCoveredLoom)),
                             button("Wind puff", #selector(presetWind)), button("Thorax touch", #selector(presetTouch))])
                    ]),
            section("Ready-made direct-neural trials", kind: .directNeural,
                    help: "These are explicit neural probes. They bypass the natural stimulus and stimulate an existing neural population directly.",
                    views: [
                        row([button("GF", #selector(presetGF)), button("DNa left", #selector(presetDNa)),
                             button("DNa right", #selector(presetDNaRight)), button("MDN", #selector(presetMDN)),
                             button("DNp09", #selector(presetDNp09))])
                    ]),
            section("Repeat / reset",
                    help: "Replay last preset runs the most recent preset again. Reset everything returns the lab to a clean starting state before a new trial.",
                    views: [
                        row([button("Replay last preset", #selector(replayLastPreset)),
                             button("Reset everything", #selector(resetAll))])
                    ]),
            section("Timeline markers",
                    help: "Markers do not change the simulation. They only label the recording so you can line up baseline, stimulus, and observation periods later.",
                    views: [
                        row([button("Baseline", #selector(markBaseline)), button("Stimulus ON", #selector(markStimulusOn)),
                             button("Stimulus OFF", #selector(markStimulusOff)), button("Observation", #selector(markObservation))])
                    ])
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
        worldViewerStatusLabel.stringValue = "3D world — \(mode.title) observation camera · presentation only"
        worldViewerStatusLabel.textColor = .secondaryLabelColor
    }

    @objc private func resetObservationCamera() {
        worldViewer.resetObservationCamera()
        worldViewerStatusLabel.stringValue = "3D world — observation camera reset"
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
            temperatureModeStatusLabel.stringValue = "Neural input: ON — temperature drives FlyWire TRN warm/cool receptor groups."
            temperatureModeStatusLabel.textColor = .labelColor
        case "modeled_physiology":
            temperatureModeStatusLabel.stringValue = "Neural input: TEMPO MODEL — changes the legacy physiology tempo path; it does not drive FlyWire TRNs."
            temperatureModeStatusLabel.textColor = .secondaryLabelColor
        default:
            temperatureModeStatusLabel.stringValue = "Neural input: OFF — environment-only temperature is recorded without neural input."
            temperatureModeStatusLabel.textColor = .systemOrange
        }
    }

    @objc private func temperatureModeChanged() {
        updateTemperatureModeStatus()
    }

    @objc private func quitLab() {
        NSApp.terminate(nil)
    }

    @discardableResult
    private func send(_ action: String, target: String? = nil,
                      x: Double? = nil, y: Double? = nil, z: Double? = nil,
                      size: Double? = nil, speed: Double? = nil,
                      strength: Double? = nil, durationMs: Int? = nil,
                      value: Double? = nil, directionDeg: Double? = nil,
                      endDistance: Double? = nil, physical: Bool? = nil,
                      sensory: Bool? = nil, continuous: Bool? = nil,
                      mode: String? = nil) -> Int? {
        guard let bridge else {
            protocolLabel.stringValue = "FlyGym bridge — disabled (launch with --flygym for physical-world controls)"
            return nil
        }
        let schedule = coordinator.labCommandSchedule()
        let id = bridge.sendLab(action: action, target: target, x: x, y: y, z: z,
                                size: size, speed: speed, strength: strength,
                                durationMs: durationMs, value: value,
                                directionDeg: directionDeg, endDistance: endDistance,
                                physical: physical, sensory: sensory,
                                continuous: continuous, mode: mode,
                                protocolVersion: schedule == nil ? nil : FlyGymProtocolV4.version,
                                sessionID: schedule?.sessionID, epoch: schedule?.epoch,
                                requestedTick: schedule?.requestedTick)
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
        recorder.mark(kind: "lab_command", detail: "\(action) target=\(target ?? "-")", commandID: id,
                      sessionID: schedule?.sessionID ?? session.sessionID,
                      epoch: schedule?.epoch ?? session.epoch,
                      simTick: session.simTick, requestedTick: schedule?.requestedTick)
        return id
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
            viewState.selectObject(objectTarget)
            renderViewState()
            lastObjectCommandID = id
            lastObjectCommandDescription = "create \(shape) ‘\(objectTarget)’"
            worldObjectStatusLabel.stringValue = "Object status — sending \(lastObjectCommandDescription)…"
            worldObjectStatusLabel.textColor = .secondaryLabelColor
        } else {
            worldObjectStatusLabel.stringValue = "Object status — bridge unavailable; object was not sent"
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
        recorder.mark(kind: "reset", detail: "all")
    }

    private func eye(_ side: String, covered: Bool) {
        guard eyeCommandPendingID == nil else {
            commandDiagnosticsLabel.stringValue = "Commands — eye change waiting for previous eye command acknowledgement"
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

    @objc private func stimulateBrain() {
        let role = selectedValue(brainRole, fallback: "GF")
        let strength = Float(max(0, min(2, d(brainStrength, fallback: 0.3))))
        let duration = ms(brainDuration, fallback: 300)
        let schedule = coordinator.labCommandSchedule()
        let session = coordinator.sessionSnapshot()
        coordinator.labStimulatePopulation(role, strength: strength, durationMs: duration)
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
            recorderLabel.stringValue = "no preset has been run yet"
            return
        }
        runPreset(lastPreset)
    }

    @objc private func clearGraphs() {
        neuralGraph.clear(); commandGraph.clear(); sensoryGraph.clear(); flywireSensoryGraph.clear(); bodyGraph.clear(); visionGraph.clear()
        recorder.mark(kind: "ui", detail: "graphs cleared")
    }

    @objc private func startRecording() {
        if recorder.isStopping {
            recorderLabel.stringValue = "stopping… previous recording is still being flushed"
            return
        }
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
        if let p = recorder.start(metadata: metadata) { recorderLabel.stringValue = "recording: \(p)" }
        else { recorderLabel.stringValue = "recording failed — \(recorder.lastErrorMessage ?? "see stderr")" }
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
        recorder.mark(kind: "session_begin", detail: "deterministic V4",
                      sessionID: s.sessionID, epoch: s.epoch, simTick: s.simTick,
                      status: s.phase.rawValue)
    }

    @objc private func pauseSession() {
        releasePlayerHeldInput(reason: "pause")
        let before = coordinator.sessionSnapshot()
        coordinator.requestSessionPause()
        recorder.mark(kind: "pause_requested", detail: before.mode.rawValue,
                      sessionID: before.sessionID, epoch: before.epoch, simTick: before.simTick,
                      status: before.phase.rawValue)
    }

    @objc private func resumeSession() {
        let before = coordinator.sessionSnapshot()
        coordinator.requestSessionResume()
        recorder.mark(kind: "resume_requested", detail: before.mode.rawValue,
                      sessionID: before.sessionID, epoch: before.epoch, simTick: before.simTick,
                      status: before.phase.rawValue)
    }
    @objc private func stopRecording() {
        let p = recorder.path ?? ""
        guard recorder.isRecording || recorder.isStopping else {
            recorderLabel.stringValue = p.isEmpty ? "not recording" : recorder.state.rawValue + ": " + p
            return
        }
        recorderLabel.stringValue = p.isEmpty ? "stopping…" : "stopping: \(p)"
        recorder.stop { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .saved(let path):
                    self.recorderLabel.stringValue = "saved: \(path)"
                case .failed(let path, let message):
                    let whereText = path.map { " — \($0)" } ?? ""
                    self.recorderLabel.stringValue = "save failed: \(message)\(whereText)"
                case .notRecording:
                    self.recorderLabel.stringValue = "not recording"
                }
            }
        }
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
        let p = recorder.path ?? ""
        recorderLabel.stringValue = p.isEmpty ? "stopping for quit…" : "stopping for quit: \(p)"
        recorder.stop(reason: "application quit") { [weak self] outcome in
            DispatchQueue.main.async {
                if let self {
                    switch outcome {
                    case .saved(let path): self.recorderLabel.stringValue = "saved: \(path)"
                    case .failed(let path, let message):
                        self.recorderLabel.stringValue = "save failed: \(message)\(path.map { " — \($0)" } ?? "")"
                    case .notRecording: self.recorderLabel.stringValue = "not recording"
                    }
                }
                completion(outcome)
            }
        }
    }

    /// A failed recorder drain must not disappear with the app. Keep the Lab
    /// window alive, show the exact failure/path, and require an explicit choice
    /// before AppDelegate replies to AppKit's pending termination request.
    func presentTerminationSaveFailure(path: String?, message: String,
                                       completion: @escaping (Bool) -> Void) {
        let whereText = path.map { "\n\nPartial recording files remain at:\n\($0)" } ?? ""
        recorderLabel.stringValue = "save failed: \(message)\(path.map { " — \($0)" } ?? "")"
        show()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Recording could not be saved completely"
        alert.informativeText = "The app will stay open by default so you can inspect the recording and retry a new recording if needed. Already-lost queued data cannot be reconstructed automatically.\n\nError: \(message)\(whereText)"
        alert.addButton(withTitle: "Keep App Open")
        alert.addButton(withTitle: "Quit Anyway")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertSecondButtonReturn)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
    @objc private func markBaseline() { recorder.mark(kind: "marker", detail: "baseline") }
    @objc private func markStimulusOn() { recorder.mark(kind: "marker", detail: "stimulus_on") }
    @objc private func markStimulusOff() { recorder.mark(kind: "marker", detail: "stimulus_off") }
    @objc private func markObservation() { recorder.mark(kind: "marker", detail: "observation") }

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
                if let snapshot = bridge.latestWorldRenderSnapshot(maxAge: 1.0) {
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
                        let pickSuffix = lastPickSummary.isEmpty ? "" : " · \(lastPickSummary)"
                        let playerSuffix = snapshot.player == nil ? "" : " · participant body"
                        worldViewerStatusLabel.stringValue = "3D world — snapshot #\(snapshotID) · rev \(revision) · tick \(snapshot.simTick) · \(snapshot.objects.count) objects\(playerSuffix)\(pickSuffix)"
                        worldViewerStatusLabel.textColor = .secondaryLabelColor
                    } else {
                        worldViewerStatusLabel.stringValue = "3D world — snapshot error: \(snapshot.error ?? "backend rejected request")"
                        worldViewerStatusLabel.textColor = .systemRed
                    }
                } else {
                    // begin/reset promotes bridge identity and clears its V5 cache
                    // before the next owner-boundary snapshot arrives. Never leave
                    // the previous epoch/session rendered during that gap.
                    clearWorldViewerSnapshotPresentation(resetIdentity: false)
                    lastViewerConnectionGeneration = viewerGeneration
                    lastViewerSessionID = nil
                    lastViewerEpoch = nil
                    worldViewerStatusLabel.stringValue = "3D world — waiting for atomic backend snapshot…"
                    worldViewerStatusLabel.textColor = .secondaryLabelColor
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
                        lastPickSummary = "pick #\(pick.seq) error: \(pick.error ?? "rejected")"
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
                            lastPickSummary = String(format: "pick #%d %@ · %.1f mm",
                                                     pick.seq, pick.targetID ?? "hit", pick.distanceMM ?? 0)
                        } else {
                            lastPickSummary = "pick #\(pick.seq) miss"
                        }
                    }
                }
            } else {
                clearWorldViewerSnapshotPresentation(resetIdentity: true)
                worldViewerStatusLabel.stringValue = bridge.connected
                    ? "3D world — unavailable: backend does not advertise world_render_snapshot + ray_pick"
                    : "3D world — waiting for FlyGym connection…"
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
                worldCapacityLabel.stringValue = "Object capacity — " + parts.joined(separator: " · ")
            }
            coordinator.noteLabAck(ack)
            if let ack {
                let key = "\(ack.id):\(ack.status ?? ""):\(ack.appliedEpoch ?? -1):\(ack.appliedTick ?? -1):\(ack.ok)"
                if key != lastRecordedAckKey {
                    lastRecordedAckKey = key
                    let s = coordinator.sessionSnapshot()
                    let request = pendingCommandSchedules[ack.id]
                    recorder.mark(kind: "lab_command_result",
                                  detail: "\(ack.action.isEmpty ? lastCommandAction : ack.action) \(ack.ok ? "OK" : "ERR") \(ack.message)",
                                  commandID: ack.id,
                                  sessionID: ack.sessionID ?? s.sessionID,
                                  epoch: ack.epoch ?? s.epoch,
                                  simTick: ack.simTick ?? s.simTick,
                                  requestedTick: request?.requestedTick,
                                  appliedTick: ack.appliedTick,
                                  appliedEpoch: ack.appliedEpoch,
                                  status: ack.status ?? (ack.ok ? "applied" : "rejected"))
                    pendingCommandSchedules.removeValue(forKey: ack.id)
                }
                if ack.id == lastObjectCommandID {
                    if ack.ok {
                        let tick = ack.appliedTick.map { " at tick \($0)" } ?? ""
                        worldObjectStatusLabel.stringValue = "Object status — OK · \(lastObjectCommandDescription)\(tick)"
                        worldObjectStatusLabel.textColor = .systemGreen
                    } else {
                        let message = ack.message.isEmpty ? "command rejected" : ack.message
                        worldObjectStatusLabel.stringValue = "Object status — ERROR · \(message)"
                        worldObjectStatusLabel.textColor = .systemRed
                    }
                }
                if participantCommandPending.consumeAck(commandID: ack.id) {
                    if ack.ok {
                        // Do not switch mode from the ACK alone. The next atomic
                        // world snapshot must confirm player presence/absence;
                        // LabViewState.accept(snapshot:) is the authority gate.
                        worldViewerStatusLabel.stringValue = "3D world — participant command applied; waiting for atomic snapshot…"
                        worldViewerStatusLabel.textColor = .secondaryLabelColor
                    } else {
                        viewState.rejectModeTransition()
                        let message = ack.message.isEmpty ? "participant command rejected" : ack.message
                        worldViewerStatusLabel.stringValue = "3D world — participant ERROR · \(message)"
                        worldViewerStatusLabel.textColor = .systemRed
                    }
                }
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

        renderViewState()

        if let result = bridge?.latestPlayerInputResult(),
           result.seq == lastPlayerInputSeq {
            if result.ok {
                playerInputStatusLabel.stringValue = "Participant controls — input #\(result.seq) applied at tick \(result.appliedTick ?? result.requestedTick)"
                playerInputStatusLabel.textColor = .systemGreen
            } else {
                playerInputStatusLabel.stringValue = "Participant controls — input #\(result.seq) rejected: \(result.error ?? result.status)"
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
                : "none"
            bodyTelemetryLabel.stringValue = String(format: "Movement — speed %.4f m/s · turn %.2f rad/s · contact %.2f",
                                                     t.bodyVX, t.bodyYawRate, t.bodyContactMean)
            foodTelemetryLabel.stringValue = String(format: "Food odor — left %.3f · right %.3f · nearest source: %@ · ORN %.1f/%.1f Hz",
                                                     t.bodyOdorL, t.bodyOdorR, nearest,
                                                     t.rateFoodOdorL, t.rateFoodOdorR)
            visionGraph.append([t.bodyBrightnessL, t.bodyBrightnessR, t.bodyOccupancyL,
                                t.bodyOccupancyR, t.bodyOpticExpansionL, t.bodyOpticExpansionR])
            let eyeSample: String
            if t.bodyEyeSampleSimTick >= 0 {
                let bodyTick = max(0, Int((t.bodySimTime * 1000.0).rounded()))
                let ageMs = max(0, bodyTick - t.bodyEyeSampleSimTick)
                eyeSample = "raw-eye sample tick \(t.bodyEyeSampleSimTick) ms · \(ageMs) ms old"
            } else {
                eyeSample = "raw-eye sample not rendered yet"
            }
            visionTelemetryLabel.stringValue = String(format: "Vision — expansion L/R %.3f/%.3f · brightness L/R %.3f/%.3f · %@",
                                                       t.bodyOpticExpansionL, t.bodyOpticExpansionR,
                                                       t.bodyBrightnessL, t.bodyBrightnessR, eyeSample)
        }

        let nearest = t.bodyNearestFoodDistanceMm >= 0
            ? String(format: "%.1f mm", t.bodyNearestFoodDistanceMm)
            : "none"
        // The body packet is the same fresh backend snapshot that drives the
        // neural model, so source diagnostics cannot disagree with actual
        // LabWorld timer expiry merely because lab_state arrived at another rate.
        let windSource = t.bodyPacketAgeS >= 0
            ? String(format: "%.2f%@", t.bodyWindStrength,
                     (t.bodyWindStrength > 0 && t.bodyWindSensory) ? " sensory" : "")
            : "unavailable"
        let touchSource = t.bodyPacketAgeS >= 0
            ? String(format: "%.2f%@", t.bodyTouchStrength,
                     (t.bodyTouchStrength > 0 && t.bodyTouchSensory) ? " sensory" : "")
            : "unavailable"
        let sourceLine = String(format:
            "1  Source → sensor     food %@ → odor %.3f/%.3f  |  vision expansion %.3f/%.3f → loom %.3f/%.3f  |  wind %@  |  touch %@  |  temp %.1f°C",
            nearest, t.bodyOdorL, t.bodyOdorR,
            t.bodyOpticExpansionL, t.bodyOpticExpansionR, t.loomL, t.loomR,
            windSource, touchSource, t.temperatureC)
        let currentLine = String(format:
            "2  Sensor → current    ORN food %.3f/%.3f  |  TRN warm/cool %.3f/%.3f  |  JO-C/E wind %.3f/%.3f  (simulation current units)",
            t.odorDriveL, t.odorDriveR, t.thermoWarmDrive, t.thermoCoolDrive,
            t.windCDrive, t.windEDrive)
        let neuralLine = String(format:
            "3  Receptor → brain    ORN L/R %.1f/%.1f Hz  |  TRN warm/cool %.1f/%.1f  |  JO-C/E %.1f/%.1f  |  loom %.1f  |  DNa L/R %.1f/%.1f  |  DNp09 %.1f",
            t.rateFoodOdorL, t.rateFoodOdorR, t.rateThermoWarm, t.rateThermoCool,
            t.rateWindC, t.rateWindE, t.rateLoom, t.rateDNaL, t.rateDNaR, t.rateFwd)
        let commandLine: String
        if t.brainSignalsAvailable {
            commandLine = String(format:
                "4  BrainSignals → FlyGym controller    walk %.2f  |  turn %.2f  |  escape %@  |  back %@  |  groom %.2f  |  wing %.2f  |  arousal %.2f  |  nervous %.2f  |  tempo %.2f  |  sleep %@  |  controller L/R %.3f/%.3f",
                t.brainWalkDrive, t.brainTurnBias, t.brainEscape ? "ON" : "OFF",
                t.brainBackward ? "ON" : "OFF", t.brainGroomDrive, t.brainWingDrive,
                t.brainArousal, t.brainNervous, t.brainTempo, t.brainSleep ? "ON" : "OFF",
                t.bodyControllerLeft, t.bodyControllerRight)
        } else {
            commandLine = String(format:
                "4  BrainSignals → FlyGym controller    no decoded BrainSignals this frame  |  controller L/R %.3f/%.3f",
                t.bodyControllerLeft, t.bodyControllerRight)
        }
        let bodyPacketDetail = t.bodyPacketAgeS >= 0
            ? String(format: "body packet %.0f ms old · MuJoCo t %.3f s · sim/wall %.2fx",
                     t.bodyPacketAgeS * 1000, t.bodySimTime, t.bodySimWallRatio)
            : "no fresh body packet used"
        let motionLine = String(format:
            "5  Measured motion     forward %.4f m/s  |  yaw %.2f rad/s  |  contact %.2f  |  %@",
            t.bodyVX, t.bodyYawRate, t.bodyContactMean, bodyPacketDetail)
        signalPathLabel.stringValue = [sourceLine, currentLine, neuralLine, commandLine, motionLine]
            .joined(separator: "\n")

        recorder.append(t)

        if let bridge {
            if bridge.connected {
                let hz = bridge.bodyHz
                let dropped = bridge.labDropped
                let degraded = hz > 0 && hz < 30 ? " · DEGRADED: body feedback below 30 Hz" : ""
                let ratio = t.bodyPacketAgeS >= 0 ? String(format: " · sim/wall %.2fx", t.bodySimWallRatio) : ""
                protocolLabel.stringValue = String(format: "FlyGym bridge — Connected · body feedback %.0f Hz%@%@%@",
                                                    hz, ratio, degraded,
                                                    dropped > 0 ? " · \(dropped) UI command\(dropped == 1 ? "" : "s") dropped" : "")
            } else {
                protocolLabel.stringValue = "FlyGym bridge — Reconnecting… brain simulation continues locally"
            }

            let bodyFreshness = bridge.bodyFreshness()
            let stateFreshness = bridge.labStateFreshness()
            let bodyAge = bodyFreshness.ageSeconds.map(ageString) ?? "no packet"
            let stateAge = stateFreshness.ageSeconds.map(ageString) ?? "no packet"
            let bodyStatus = "body \(bodyFreshness.isFresh ? "FRESH" : "STALE") \(bodyAge)"
            let envStatus = "environment \(stateFreshness.isFresh ? "FRESH" : "STALE") \(stateAge)"
            freshnessLabel.stringValue = "Packets — \(bodyStatus) · \(envStatus)"

            if let s = state {
                var bits = [String(format: "%.1f s", s.t)]
                if let n = s.objectCount { bits.append("\(n) object\(n == 1 ? "" : "s")") }
                if let w = s.wind { bits.append(String(format: "wind %.2f", w)) }
                if let c = s.temperature { bits.append(String(format: "%.1f°C", c)) }
                if let l = s.leftEyeCovered { bits.append("left eye \(l ? "covered" : "open")") }
                if let r = s.rightEyeCovered { bits.append("right eye \(r ? "covered" : "open")") }
                if let e = s.error, !e.isEmpty { bits.append("error: \(e)") }
                if let event, !event.event.isEmpty { bits.append("last event: \(event.event)") }
                remoteStateLabel.stringValue = "Environment — " + bits.joined(separator: " · ")
            } else {
                remoteStateLabel.stringValue = "Environment — waiting for FlyGym state…"
            }

            let sleeping = t.brainSleep
            let gate = sleeping ? 0.55 : 1.0
            var commandBits = ["Brain state — sleep \(sleeping ? "ON" : "OFF") · sensoryGate ×\(String(format: "%.2f", gate))"]
            if let lastCommandID {
                commandBits.append("sent #\(lastCommandID) \(lastCommandAction)")
            } else {
                commandBits.append("sent: none")
            }
            if let ack {
                let age = ageString(ack.ageSeconds(at: now))
                let ackFreshness = bridge.labAckFreshness()
                let message = ack.message.isEmpty ? "" : " · \(ack.message)"
                commandBits.append("ack #\(ack.id) \(ack.ok ? "OK" : "ERROR") · \(ackFreshness.isFresh ? "FRESH" : "STALE") · \(ack.action)\(message) · seen \(age) ago")
            } else {
                commandBits.append("ack: none yet")
            }
            if let action = state?.lastAction, !action.isEmpty { commandBits.append("bridge last action: \(action)") }
            if let error = state?.error, !error.isEmpty { commandBits.append("ERROR: \(error)") }
            commandBits.append("queue \(bridge.pendingLabDepth())")
            commandDiagnosticsLabel.stringValue = commandBits.joined(separator: "\n")
        } else {
            protocolLabel.stringValue = "FlyGym bridge — disabled"
            freshnessLabel.stringValue = "Packets — body STALE · bridge disabled · environment STALE · bridge disabled"
            remoteStateLabel.stringValue = "Environment — local brain/sensory controls are still available"
            let sleeping = t.brainSleep
            commandDiagnosticsLabel.stringValue = "Brain state — sleep \(sleeping ? "ON" : "OFF") · sensoryGate ×\(sleeping ? "0.55" : "1.00")\nCommands — FlyGym bridge disabled"
        }
    }
}
