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
    /// What the spike lane can say about the current observer selection.
    enum SpikeState: Equatable {
        case shown(neurons: Int)
        case selectionChanged          // the armed selection is not the one the event was noted under
        case noSelection               // the event was noted with nothing selected
    }

    var range: ClosedRange<Int>          // baseline start … response end (may start before 1)
    var applied: Int
    /// The brain was reset since the event: its lanes belong to another epoch, none is shown.
    var epochMismatch = false
    var eye: LaneSlice<EyeSample>
    var sensory: LaneSlice<SensorySample>
    var motor: LaneSlice<MotorSample>
    var body: LaneSlice<BodySample>
    var spikes: [(tick: Int, row: Int)]  // selected-neuron spikes; row = index in the selection
    var neuronCount: Int                 // the real selected count (0 unless the spike lane is shown)
    var spikeState: SpikeState = .noSelection
    /// Sensory period per channel (channels that share a tick must not halve one median).
    var sensoryPeriods: [(channel: SensoryChannel, period: Double?, count: Int)] = []
    /// Ticks of the range that are no longer retained, per lane (eye, sensory, spikes, motor, body).
    var notRetained: [[ClosedRange<Int>]] = Array(repeating: [], count: 5)
    var note: String?

    static let epochNote = L("different brain epoch (reset since the event)", "다른 뇌 세션 (사건 이후 리셋됨)")

    private static func emptySlice<S: TimelineSample>() -> LaneSlice<S> { LaneSlice(samples: [], periodTicks: nil, evictedThrough: 0) }

    static func make(window w: InteractionWindow, timeline: InteractionTimeline, observer: NeuralObserver) -> TimelineSnapshot? {
        guard let a = w.appliedTick, let b = w.baselineWindow, let r = w.responseWindow else { return nil }
        let q = max(b.start, 1)...max(r.end, 1)
        let sel = observer.selection()
        guard sel.brainEpoch == w.brainEpoch else {
            // Every lane was cleared by the reset; what they hold now is another epoch's data.
            return TimelineSnapshot(range: b.start...r.end, applied: a, epochMismatch: true, eye: emptySlice(), sensory: emptySlice(),
                                    motor: emptySlice(), body: emptySlice(), spikes: [], neuronCount: 0,
                                    spikeState: .selectionChanged, note: epochNote)
        }
        var snap = TimelineSnapshot(range: b.start...r.end, applied: a, eye: timeline.eyeSlice(q), sensory: timeline.sensorySlice(q),
                                    motor: timeline.motorSlice(q), body: timeline.bodySlice(q), spikes: [], neuronCount: 0)
        snap.sensoryPeriods = InteractionTimeline.periodsByChannel(snap.sensory.samples)
        func evicted(_ through: Int) -> [ClosedRange<Int>] { through >= q.lowerBound ? [q.lowerBound...min(through, q.upperBound)] : [] }
        snap.notRetained[0] = evicted(snap.eye.evictedThrough); snap.notRetained[1] = evicted(snap.sensory.evictedThrough)
        snap.notRetained[3] = evicted(snap.motor.evictedThrough); snap.notRetained[4] = evicted(snap.body.evictedThrough)
        if w.selectionID == nil {
            snap.spikeState = .noSelection
        } else if sel.selectionID == w.selectionID {
            // The raster is only valid for the selection the event was noted under.
            var row: [Int: Int] = [:]
            for (i, n) in sel.neurons.enumerated() { row[n] = i }
            snap.spikes = observer.spikeEvents(start: q.lowerBound, end: q.upperBound).compactMap { e in row[e.neuron].map { (e.tick, $0) } }
            snap.neuronCount = sel.neurons.count
            snap.spikeState = .shown(neurons: sel.neurons.count)
            // Ticks not simulated yet are not "missing"; only ones the ring no longer holds.
            if sel.lastTick >= q.lowerBound {
                snap.notRetained[2] = observer.missingRanges(start: q.lowerBound, end: min(q.upperBound, sel.lastTick))
            }
        } else {
            snap.spikeState = .selectionChanged
            snap.note = L("selection changed since the event: no spike raster", "사건 이후 선택이 바뀌어 발화 래스터를 그리지 않습니다")
        }
        return snap
    }

    private static func period(_ p: Double?) -> String {
        guard let p else { return L("period not measured", "간격 미측정") }
        return String(format: p == p.rounded() ? "%.0f" : "%.1f", p)
    }

    private static let notRetainedText = " · " + L("not retained", "보관 안 됨")

    /// Lane label: name, measured period, and whether the tick is a receive time.
    static func label(_ name: (String, String), period p: Double?, received: Bool, count: Int, notRetained: Bool = false) -> String {
        var t = L(name.0, name.1) + " "
        t += p == nil ? L("(period not measured, \(count))", "(간격 미측정, \(count)개)")
            : String(format: L("%@ ms apart", "%@ ms 간격"), period(p))
        if received { t += " · " + L("receive time", "수신 시각") }
        if notRetained { t += notRetainedText }
        return t
    }

    /// Sensory label: each channel's own period (never one median over channels).
    private func sensoryLabel(received: Bool) -> String {
        guard !sensoryPeriods.isEmpty else {
            return Self.label(("Sensory", "감각"), period: nil, received: received, count: 0, notRetained: !notRetained[1].isEmpty)
        }
        let parts = sensoryPeriods.map { c in
            c.period.map { "\(c.channel.rawValue) \(Self.period($0))" } ?? "\(c.channel.rawValue) (\(c.count))"
        }.joined(separator: ", ")
        var t = L("Sensory", "감각") + " " + parts + L(" ms apart per channel", " ms 간격 (채널별)")
        if received { t += " · " + L("receive time", "수신 시각") }
        if !notRetained[1].isEmpty { t += Self.notRetainedText }
        return t
    }

    var labels: [String] {
        func rec(_ o: [TickOrigin]) -> Bool { o.contains(.receivedAt) }
        let spikeLabel: String
        switch spikeState {
        case .shown(let n): spikeLabel = L("Spikes (exact)", "발화 (정확)") + " · " + String(format: L("%d neurons", "뉴런 %d개"), n)
        case .selectionChanged: spikeLabel = L("Spikes: selection changed since the event", "발화: 사건 이후 선택이 바뀜")
        case .noSelection: spikeLabel = L("Spikes: nothing was selected", "발화: 선택된 뉴런 없음")
        }
        return [
            Self.label(("Eye", "눈"), period: eye.periodTicks, received: rec(eye.samples.map(\.origin)), count: eye.samples.count, notRetained: !notRetained[0].isEmpty),
            sensoryLabel(received: rec(sensory.samples.map(\.origin))),
            spikeLabel + (notRetained[2].isEmpty ? "" : Self.notRetainedText),
            Self.label(("Motor", "운동"), period: motor.periodTicks, received: rec(motor.samples.map(\.origin)), count: motor.samples.count, notRetained: !notRetained[3].isEmpty),
            Self.label(("Body", "몸"), period: body.periodTicks, received: rec(body.samples.map(\.origin)), count: body.samples.count, notRetained: !notRetained[4].isEmpty)
        ]
    }
}

/// Reuses a finished window's snapshot while the observer selection and brain epoch are unchanged
/// (the raster scan walks the whole observer ring under its lock). A window still collecting is rebuilt.
struct TimelineSnapshotCache {
    private struct Key: Equatable { var eventID: String; var status: InteractionWindowStatus; var selectionID: Int; var brainEpoch: Int }
    private var key: Key?
    private var snapshot: TimelineSnapshot?
    private(set) var builds = 0

    mutating func snapshot(window w: InteractionWindow, timeline: InteractionTimeline, observer: NeuralObserver) -> TimelineSnapshot? {
        let sel = observer.selection()
        let k = Key(eventID: w.eventID, status: w.status, selectionID: sel.selectionID, brainEpoch: sel.brainEpoch)
        if w.status != .collecting, k == key { return snapshot }
        builds += 1
        snapshot = TimelineSnapshot.make(window: w, timeline: timeline, observer: observer)
        key = k
        return snapshot
    }
}

/// Picker rows: the title carries the status, so the rebuild key must too.
enum TimelinePickerModel {
    static func title(_ w: InteractionWindow) -> String {
        let t = w.appliedTick.map { "t\($0)" } ?? L("t unknown", "시각 모름")
        return "\(w.eventKind) · \(t) · \(w.status.rawValue)"
    }
    static func key(_ windows: [InteractionWindow]) -> [String] { windows.map { "\($0.eventID)|\(title($0))" } }
    /// The event to show: the current one while it is still listed, else the first listed (nil when none).
    static func resolve(current: String?, listed ids: [String]) -> String? {
        if let c = current, ids.contains(c) { return c }
        return ids.first
    }
}

/// timeline.csv export rules shared by the panel and the diagnostics.
enum TimelineExport {
    /// nil csv + the reason when the lanes no longer belong to the event's brain epoch.
    static func csv(window w: InteractionWindow, timeline: InteractionTimeline, observer: NeuralObserver,
                    rootID: (Int) -> String) -> (csv: String?, note: String?) {
        guard let b = w.baselineWindow, let r = w.responseWindow else { return (nil, nil) }
        let sel = observer.selection()
        guard sel.brainEpoch == w.brainEpoch else { return (nil, TimelineSnapshot.epochNote) }
        let q = max(b.start, 1)...max(r.end, 1)
        let spikes = w.selectionID != nil && sel.selectionID == w.selectionID
            ? observer.spikeEvents(start: q.lowerBound, end: q.upperBound).map { (tick: $0.tick, rootID: rootID($0.neuron)) } : []
        return (TimelineCSV.make(timeline, range: q, spikes: spikes), nil)
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
        if s.epochMismatch {
            NSAttributedString(string: s.note ?? "", attributes: small).draw(at: NSPoint(x: 10, y: 10))
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
        // Ticks a lane no longer retains are hatched grey: absence there is not silence.
        for (lane, ranges) in s.notRetained.enumerated() {
            for r in ranges {
                let rect = NSRect(x: x(r.lowerBound), y: plot.minY + CGFloat(lane) * laneH, width: max(1, x(r.upperBound + 1) - x(r.lowerBound)), height: laneH)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                NSColor.systemGray.withAlphaComponent(0.22).setFill(); rect.fill()
                NSColor.systemGray.withAlphaComponent(0.55).setStroke()
                let h = NSBezierPath(); h.lineWidth = 0.6
                var hx = rect.minX - rect.height
                while hx < rect.maxX { h.move(to: NSPoint(x: hx, y: rect.maxY)); h.line(to: NSPoint(x: hx + rect.height, y: rect.minY)); hx += 5 }
                h.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
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
    private var shownKey: [String] = []
    private var cache = TimelineSnapshotCache()
    private let warning = NSTextField(wrappingLabelWithString: "")
    private var exportMessage: String?

    init(coordinator: Coordinator, recordingDirectory: @escaping () -> String?) {
        self.coordinator = coordinator
        self.recordingDirectory = recordingDirectory
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        _ = LabForm.status(note); _ = LabForm.status(warning)
        warning.isHidden = true
        picker.target = self; picker.action = #selector(pickerChanged)
        exportButton.target = self; exportButton.action = #selector(exportCSV); exportButton.bezelStyle = .rounded
        view.translatesAutoresizingMaskIntoConstraints = false
        view.emptyText = L("Select an event to see its timeline.", "사건을 고르면 timeline이 나타납니다.")
        for v in [picker, view, warning, note, exportButton] as [NSView] { addArrangedSubview(v) }
        for v in [view, note, warning] as [NSView] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
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
        exportMessage = nil
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
        let key = TimelinePickerModel.key(windows)
        if key != shownKey {       // titles carry the status, so a status change rebuilds the rows too
            shownKey = key
            picker.removeAllItems()
            for w in windows {
                picker.addItem(withTitle: TimelinePickerModel.title(w))
                picker.lastItem?.representedObject = w.eventID
            }
        }
        // The shown event must be one the picker lists; else fall back to the first listed one.
        let wanted = TimelinePickerModel.resolve(current: selection.eventID, listed: ids)
        if wanted != selection.eventID { selection.eventID = wanted; exportMessage = nil }
        if let id = wanted, let i = ids.firstIndex(of: id) { if picker.indexOfSelectedItem != i { picker.selectItem(at: i) } }
        guard let w = currentWindow() else { view.snapshot = nil; exportButton.isEnabled = false; return }
        let info = sim.observer.selection()
        selection.neurons = info.neurons; selection.groupIDs = w.groups.map(\.groupID)
        selection.window = w.appliedTick != nil ? TickWindow(start: w.baselineWindow?.start ?? 0, end: w.responseWindow?.end ?? 0) : nil
        view.snapshot = cache.snapshot(window: w, timeline: sim.timeline, observer: sim.observer)
        let message = exportMessage ?? view.snapshot?.note ?? ""
        warning.stringValue = message; warning.isHidden = message.isEmpty
        view.emptyText = L("This event has no applied tick, so it cannot be placed on the timeline.", "적용 tick을 알 수 없는 사건이라 timeline에 놓을 수 없습니다.")
        exportButton.isEnabled = view.snapshot != nil
    }

    @objc private func exportCSV() {
        guard let sim = coordinator?.sim, let w = currentWindow() else { return }
        let out = TimelineExport.csv(window: w, timeline: sim.timeline, observer: sim.observer) { String(sim.rootIds[$0]) }
        guard let csv = out.csv else {
            if let n = out.note { exportMessage = L("Export refused: ", "내보내기 거부: ") + n; warning.stringValue = exportMessage ?? ""; warning.isHidden = false }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "timeline.csv"
        if let dir = recordingDirectory() { panel.directoryURL = URL(fileURLWithPath: dir) }
        let write: (URL) -> Void = { [weak self] url in
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.exportMessage = L("Export failed: ", "내보내기 실패: ") + error.localizedDescription; self?.refresh() }
        }
        if let win = window { panel.beginSheetModal(for: win) { if $0 == .OK, let u = panel.url { write(u) } } }
        else if panel.runModal() == .OK, let u = panel.url { write(u) }
    }
}
