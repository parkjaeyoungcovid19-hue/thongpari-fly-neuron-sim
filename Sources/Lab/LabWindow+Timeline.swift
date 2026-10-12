import Cocoa

// V7.6 integrated timeline — Lab Brain page ("사건 전후"). Read-only: it reads the
// event buffer, the InteractionTimeline and the observer ring and never calls
// `stimulate`. Every lane shows its DISCRETE samples at their real ticks (dots and
// held steps with visible gaps); nothing is interpolated, so a 5 Hz eye stays 5 Hz.

/// What the panel shows: one event, the exact neurons selected, and its tick window.
struct TraceSelection: Equatable {
    var eventID: String?
    var neurons: [Int] = []
    var groupIDs: [String] = []
    var window: TickWindow?
}

/// Pure data behind the drawing (the diagnostics read it too).
struct TimelineSnapshot {
    var range: ClosedRange<Int>          // baseline start … response end (may start before 1)
    var applied: Int
    var eye: LaneSlice<EyeSample>
    var sensory: LaneSlice<SensorySample>
    var motor: LaneSlice<MotorSample>
    var body: LaneSlice<BodySample>
    var spikes: [(tick: Int, row: Int)]  // selected-neuron spikes; row = index in the selection
    var neuronCount: Int

    static func make(window w: InteractionWindow, timeline: InteractionTimeline, observer: NeuralObserver) -> TimelineSnapshot? {
        guard let a = w.appliedTick, let b = w.baselineWindow, let r = w.responseWindow else { return nil }
        let q = max(b.start, 1)...max(r.end, 1)
        let sel = observer.selection()
        var row: [Int: Int] = [:]
        for (i, n) in sel.neurons.enumerated() { row[n] = i }
        // The raster is only valid for the selection the event was noted under.
        let spikes = sel.selectionID == w.selectionID && sel.brainEpoch == w.brainEpoch
            ? observer.spikeEvents(start: q.lowerBound, end: q.upperBound).compactMap { e in row[e.neuron].map { (e.tick, $0) } }
            : []
        return TimelineSnapshot(range: b.start...r.end, applied: a, eye: timeline.eyeSlice(q), sensory: timeline.sensorySlice(q),
                                motor: timeline.motorSlice(q), body: timeline.bodySlice(q), spikes: spikes,
                                neuronCount: spikes.isEmpty ? 0 : sel.neurons.count)
    }

    private static func period(_ p: Double?) -> String {
        guard let p else { return L("period not measured", "간격 미측정") }
        return String(format: p == p.rounded() ? "%.0f" : "%.1f", p)
    }

    /// Lane label: name, measured period, and whether the tick is a receive time.
    static func label(_ name: (String, String), period p: Double?, received: Bool, count: Int) -> String {
        var t = L(name.0, name.1) + " "
        t += p == nil ? L("(period not measured, \(count))", "(간격 미측정, \(count)개)")
            : String(format: L("%@ ms apart", "%@ ms 간격"), period(p))
        if received { t += " · " + L("receive time", "수신 시각") }
        return t
    }

    var labels: [String] {
        func rec(_ o: [TickOrigin]) -> Bool { o.contains(.receivedAt) }
        return [
            Self.label(("Eye", "눈"), period: eye.periodTicks, received: rec(eye.samples.map(\.origin)), count: eye.samples.count),
            Self.label(("Sensory", "감각"), period: sensory.periodTicks, received: rec(sensory.samples.map(\.origin)), count: sensory.samples.count),
            L("Spikes (exact)", "발화 (정확)") + " · " + String(format: L("%d neurons", "뉴런 %d개"), neuronCount),
            Self.label(("Motor", "운동"), period: motor.periodTicks, received: rec(motor.samples.map(\.origin)), count: motor.samples.count),
            Self.label(("Body", "몸"), period: body.periodTicks, received: rec(body.samples.map(\.origin)), count: body.samples.count)
        ]
    }
}

final class TimelineView: NSView {
    var snapshot: TimelineSnapshot? { didSet { needsDisplay = true } }
    var emptyText = ""
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.secondaryLabelColor]
        guard let s = snapshot else {
            NSAttributedString(string: emptyText, attributes: small).draw(at: NSPoint(x: 10, y: 10))
            return
        }
        let labelW: CGFloat = min(190, bounds.width * 0.4)
        let plot = NSRect(x: labelW + 8, y: 18, width: max(20, bounds.width - labelW - 16), height: bounds.height - 24)
        let span = Double(s.range.upperBound - s.range.lowerBound + 1)
        func x(_ tick: Int) -> CGFloat { plot.minX + CGFloat(Double(tick - s.range.lowerBound) / span) * plot.width }
        let laneH = plot.height / 5
        func midY(_ lane: Int) -> CGFloat { plot.minY + (CGFloat(lane) + 0.5) * laneH }

        // Baseline / response backgrounds, event marker.
        NSColor.tertiaryLabelColor.withAlphaComponent(0.12).setFill()
        NSRect(x: plot.minX, y: plot.minY, width: x(s.applied) - plot.minX, height: plot.height).fill()
        NSColor.systemOrange.withAlphaComponent(0.10).setFill()
        NSRect(x: x(s.applied), y: plot.minY, width: plot.maxX - x(s.applied), height: plot.height).fill()
        for (i, text) in s.labels.enumerated() {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: text, attributes: small.merging([.paragraphStyle: p]) { $1 })
                .draw(in: NSRect(x: 8, y: midY(i) - 7, width: labelW - 4, height: 14))
            NSColor.separatorColor.withAlphaComponent(0.4).setFill()
            NSRect(x: plot.minX, y: plot.minY + CGFloat(i + 1) * laneH - 0.5, width: plot.width, height: 0.5).fill()
        }
        NSAttributedString(string: String(format: L("event at t%d · motor lane = walkDrive", "사건 t%d · 운동 줄 = walkDrive"), s.applied), attributes: small)
            .draw(at: NSPoint(x: plot.minX, y: 2))

        func dot(_ tick: Int, _ lane: Int, origin: TickOrigin, color: NSColor, dy: CGFloat = 0) {
            let r = NSRect(x: x(tick) - 3, y: midY(lane) + dy - 3, width: 6, height: 6)
            let path = NSBezierPath(ovalIn: r)
            if origin == .sampledAt { color.setFill(); path.fill() }
            else { color.setStroke(); path.lineWidth = 1.2; path.setLineDash([1.5, 1.5], count: 2, phase: 0); path.stroke() }   // receive time: hollow
        }
        for e in s.eye.samples { dot(e.tick, 0, origin: e.origin, color: .systemBlue) }
        for e in s.sensory.samples {
            let c: NSColor = e.channel == .wind || e.channel == .localWind ? .systemTeal : (e.channel == .touch || e.channel == .localTouch ? .systemPurple : .systemBlue)
            dot(e.tick, 1, origin: e.origin, color: c, dy: e.channel.isLocalDrive ? 5 : -2)
        }
        NSColor.labelColor.withAlphaComponent(0.75).setFill()
        let rowH = max(0.5, (laneH - 6) / CGFloat(max(1, s.neuronCount)))
        for sp in s.spikes {
            NSRect(x: x(sp.tick), y: plot.minY + 2 * laneH + 3 + CGFloat(sp.row) * rowH, width: 1, height: max(1, min(rowH, 3))).fill()
        }
        // Motor: each value held only until the next computation (or 2 periods), a step, never a ramp.
        let hold = (s.motor.periodTicks ?? 20) * 2
        let motor = s.motor.samples
        NSColor.systemGreen.setStroke()
        for (i, m) in motor.enumerated() {
            let end = i + 1 < motor.count ? min(Double(motor[i + 1].tick), Double(m.tick) + hold) : Double(m.tick) + 1
            let y = plot.minY + 3 * laneH + laneH - 4 - CGFloat(min(1.3, max(0, m.walkDrive)) / 1.3) * (laneH - 8)
            let p = NSBezierPath(); p.move(to: NSPoint(x: x(m.tick), y: y)); p.line(to: NSPoint(x: x(Int(end)), y: y)); p.lineWidth = 1.5; p.stroke()
            if m.escape { NSColor.systemRed.setFill(); NSRect(x: x(m.tick) - 1, y: plot.minY + 3 * laneH + 1, width: 2, height: laneH - 2).fill() }
        }
        for b in s.body.samples {
            dot(b.tick, 4, origin: b.origin, color: b.source == .local ? .systemBrown : .systemIndigo)
        }
        NSColor.systemRed.setFill()
        NSRect(x: x(s.applied) - 0.5, y: plot.minY, width: 1.5, height: plot.height).fill()
    }
}

/// Event picker + timeline + CSV export, under the event-window text.
final class TimelinePanel: NSStackView {
    private weak var coordinator: Coordinator?
    private let recordingDirectory: () -> String?
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let view = TimelineView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let exportButton = NSButton(title: L("Export timeline.csv…", "timeline.csv 내보내기…"), target: nil, action: nil)
    private(set) var selection = TraceSelection()
    private var timer: Timer?
    private var shownIDs: [String] = []

    init(coordinator: Coordinator, recordingDirectory: @escaping () -> String?) {
        self.coordinator = coordinator
        self.recordingDirectory = recordingDirectory
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        _ = LabForm.status(note)
        picker.target = self; picker.action = #selector(pickerChanged)
        exportButton.target = self; exportButton.action = #selector(exportCSV); exportButton.bezelStyle = .rounded
        view.translatesAutoresizingMaskIntoConstraints = false
        view.emptyText = L("Select an event to see its timeline.", "사건을 고르면 timeline이 나타납니다.")
        for v in [picker, view, note, exportButton] as [NSView] { addArrangedSubview(v) }
        for v in [view, note] as [NSView] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        view.heightAnchor.constraint(equalToConstant: 200).isActive = true
        note.stringValue = L("● filled = sampled at that tick · ○ dashed = receive time only (true sample time unknown). Eye frames are ~5 Hz and drawn as separate dots; motor values are held steps between computations; gaps are gaps.",
                             "● 채움 = 그 tick에 실제로 잰 값 · ○ 점선 = 수신 시각뿐(실제 측정 시각은 모름). 눈 프레임은 약 5 Hz라 점으로만 그리며, 운동 값은 계산 사이를 유지한 계단입니다. 빈 곳은 빈 곳입니다.")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func pickerChanged() {
        selection.eventID = picker.selectedItem?.representedObject as? String
        refresh()
    }

    private func currentWindow() -> InteractionWindow? {
        guard let id = selection.eventID else { return nil }
        return coordinator?.sim?.eventWindows.window(eventID: id)
    }

    func refresh() {
        guard let sim = coordinator?.sim else { view.snapshot = nil; return }
        let windows = Array(sim.eventWindows.windows().prefix(40))
        let ids = windows.map(\.eventID)
        if ids != shownIDs {
            shownIDs = ids
            picker.removeAllItems()
            for w in windows {
                let t = w.appliedTick.map { "t\($0)" } ?? L("t unknown", "시각 모름")
                picker.addItem(withTitle: "\(w.eventKind) · \(t) · \(w.status.rawValue)")
                picker.lastItem?.representedObject = w.eventID
            }
            if let id = selection.eventID, let i = ids.firstIndex(of: id) { picker.selectItem(at: i) }
            else { selection.eventID = ids.first; if !ids.isEmpty { picker.selectItem(at: 0) } }
        }
        guard let w = currentWindow() else { view.snapshot = nil; exportButton.isEnabled = false; return }
        let info = sim.observer.selection()
        selection.neurons = info.neurons; selection.groupIDs = w.groups.map(\.groupID)
        selection.window = w.appliedTick != nil ? TickWindow(start: w.baselineWindow?.start ?? 0, end: w.responseWindow?.end ?? 0) : nil
        view.snapshot = TimelineSnapshot.make(window: w, timeline: sim.timeline, observer: sim.observer)
        view.emptyText = L("This event has no applied tick, so it cannot be placed on the timeline.", "적용 tick을 알 수 없는 사건이라 timeline에 놓을 수 없습니다.")
        exportButton.isEnabled = view.snapshot != nil
    }

    @objc private func exportCSV() {
        guard let sim = coordinator?.sim, let w = currentWindow(), let b = w.baselineWindow, let r = w.responseWindow else { return }
        let q = max(b.start, 1)...max(r.end, 1)
        let sel = sim.observer.selection()
        let spikes = sel.selectionID == w.selectionID && sel.brainEpoch == w.brainEpoch ? sim.observer.spikeEvents(start: q.lowerBound, end: q.upperBound)
            .map { (tick: $0.tick, rootID: String(sim.rootIds[$0.neuron])) } : []
        let csv = TimelineCSV.make(sim.timeline, range: q, spikes: spikes)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "timeline.csv"
        if let dir = recordingDirectory() { panel.directoryURL = URL(fileURLWithPath: dir) }
        let write: (URL) -> Void = { [weak self] url in
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.note.stringValue = L("Export failed: ", "내보내기 실패: ") + error.localizedDescription }
        }
        if let win = window { panel.beginSheetModal(for: win) { if $0 == .OK, let u = panel.url { write(u) } } }
        else if panel.runModal() == .OK, let u = panel.url { write(u) }
    }
}
