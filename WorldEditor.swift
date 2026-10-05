// WorldEditor.swift — V6.3 presentation-only drafts and revision-checked commands.
// The owner snapshot remains the only source of applied geometry.
import Cocoa

struct WorldObjectEdit: Codable, Equatable {
    let schemaVersion: Int = 1
    let operation: String
    let targetID: String
    let expectedRevision: Int
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", operation, targetID = "target_id"
        case expectedRevision = "expected_revision"
    }
}

enum WorldEditorTool: Int, CaseIterable {
    case move, rotate, size
    var title: String {
        switch self { case .move: return L("Move", "이동")
        case .rotate: return L("Rotate Z", "Z 회전")
        case .size: return L("Size", "크기") }
    }
    func propertyID(shape: String) -> String {
        self == .rotate ? "object.yaw_deg" : "object.\(shape).\(self == .move ? "position_mm" : "size_mm")"
    }
}

struct WorldEditorIdentity: Equatable {
    let generation: UInt64
    let sessionID: String
    let epoch: Int
}

struct WorldEditorPending {
    let commandID: Int
    let identity: WorldEditorIdentity
    let schedule: LabCommandSchedule?
    let propertyID: String
    let targetID: String
    let expectedRevision: Int
    let proposedValue: EnvironmentPropertyValue?
    let capabilities: EnvironmentCapabilities?
    let startedAt: Date
}

/// Separate from the views for deterministic lifecycle tests. Never edits an object.
struct WorldEditorState {
    private(set) var pending: WorldEditorPending?
    private(set) var message = ""
    private(set) var isError = false
    mutating func clearDraftMessage() { if pending == nil { message=""; isError=false } }
    mutating func fail(_ text: String) { message = text; isError = true }
    mutating func begin(_ request: WorldEditorPending) {
        pending = request; isError = false
        message = L("Applying… waiting for the simulator", "적용 중… 시뮬레이터 응답을 기다립니다")
    }
    mutating func reconcile(identity: WorldEditorIdentity, now: Date = Date()) {
        guard let p = pending else { return }
        if p.identity != identity {
            pending = nil; fail(L("Session changed — the earlier request was discarded", "세션이 바뀌어 이전 요청은 무시했습니다"))
        } else if now.timeIntervalSince(p.startedAt) > 8 {
            pending = nil; fail(L("No reply from the simulator — check the current values before retrying", "시뮬레이터 응답이 없습니다 — 현재 값을 확인한 뒤 다시 시도하세요"))
        }
    }
    /// Returns a newly duplicated ID only after a matching, valid owner result.
    mutating func accept(_ ack: LabAck) -> String? {
        guard let p = pending, ack.id == p.commandID,
              ack.connectionGeneration == p.identity.generation else { return nil }
        guard let schedule = p.schedule else {
            pending = nil; fail(L("Missing session boundary — not confirmed", "세션 정보 없음 — 적용 확인 불가")); return nil
        }
        guard ack.sessionID == schedule.sessionID, ack.epoch == schedule.epoch else { return nil }
        pending = nil
        guard ack.ok else {
            fail(Self.rejection(ack))
            return nil
        }
        guard let result = ack.edit, result.ok, result.status == "applied",
              result.propertyID == p.propertyID, result.targetID == p.targetID,
              let revision = result.revision, revision > p.expectedRevision,
              let actual = result.actualValue else {
            fail(L("Malformed ACK — application not confirmed", "잘못된 응답 — 적용 확인 불가")); return nil
        }
        guard ack.status == "applied", ack.appliedEpoch == schedule.epoch,
              let tick = ack.appliedTick, tick >= schedule.requestedTick else {
            fail(L("ACK boundary mismatch — not confirmed", "응답 시각 불일치 — 적용 확인 불가")); return nil
        }
        let duplicate: String?
        if p.propertyID == "object.duplicate" || p.propertyID == "object.delete" {
            guard case .choice(let id) = actual, !id.isEmpty, id.unicodeScalars.count <= 64,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  p.propertyID != "object.duplicate" || id != p.targetID,
                  p.propertyID != "object.delete" || id == p.targetID else {
                fail(L("Malformed object result", "잘못된 물체 응답")); return nil
            }
            duplicate = p.propertyID == "object.duplicate" ? id : nil
        } else {
            guard let proposal = p.proposedValue, Self.compatible(actual, proposal),
                  let caps = p.capabilities,
                  (try? EnvironmentEdit.make(propertyID: p.propertyID, targetID: p.targetID, expectedRevision: revision, value: actual, capabilities: caps)) != nil,
                  p.propertyID != "object.yaw_deg" || Self.appliedYaw(actual) else {
                fail(L("Malformed actual value", "잘못된 실제 값")); return nil
            }
            duplicate = nil
        }
        isError = false
        message = L("Applied", "적용됨") + " · " + (duplicate.map { L("new object ", "새 물체 ") + $0 } ?? Self.describe(actual))
        return duplicate
    }
    private static func rejection(_ ack: LabAck) -> String {
        guard let edit = ack.edit else { return L("Not applied — ", "적용 안 됨 — ") + ack.message }
        if edit.status == "rejected_stale_revision" {
            return L("Not applied — the object changed first; check the current values and retry",
                     "적용 안 됨 — 그사이 물체가 바뀌었습니다. 현재 값을 확인하고 다시 시도하세요")
        }
        return L("Not applied — ", "적용 안 됨 — ") + (edit.reason ?? ack.message) + (edit.path.map { " (\($0))" } ?? "")
    }
    private static func appliedYaw(_ value: EnvironmentPropertyValue) -> Bool {
        if case .number(let n) = value { return n >= 0 && n < 360 }; return false
    }
    private static func compatible(_ a: EnvironmentPropertyValue, _ b: EnvironmentPropertyValue) -> Bool {
        switch (a, b) {
        case (.number(let v), .number): return v.isFinite
        case (.vector(let v), .vector(let p)): return v.count == p.count && v.allSatisfy(\.isFinite)
        default: return false
        }
    }
    static func describe(_ value: EnvironmentPropertyValue) -> String {
        switch value {
        case .number(let n): return String(format: "%g", n)
        case .vector(let v): return v.map { String(format: "%g", $0) }.joined(separator: ", ")
        case .choice(let s): return s
        case .boolean(let b): return String(b)
        }
    }
}

/// Same right/up basis and vertical FOV as view_stream's z-up MuJoCo free camera.
/// AppKit canvas coordinates are points, origin bottom-left (not JPEG top-left).
struct WorldEditorProjection {
    let camera: WorldViewerMuJoCoCamera
    let viewport: NSSize
    private var forward: [Double] { Self.unit(camera.forward) }
    private var right: [Double] { Self.unit([forward[1], -forward[0], 0]) }
    private var up: [Double] { Self.cross(right, forward) }
    private var focal: Double { Double(viewport.height) / (2 * tan(camera.fovyDeg * .pi / 360)) }
    static func unit(_ v: [Double]) -> [Double] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 1e-12 ? v.map { $0 / n } : [1, 0, 0]
    }
    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
    }
    private func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } }
    func project(_ position: [Double]) -> NSPoint? {
        guard position.count == 3, camera.positionMM.count == 3, viewport.width > 0, viewport.height > 0 else { return nil }
        let offset = zip(position, camera.positionMM).map(-)
        let depth = dot(offset, forward)
        guard depth > 0.01 else { return nil }
        return NSPoint(x: Double(viewport.width)/2 + focal * dot(offset, right)/depth,
                       y: Double(viewport.height)/2 + focal * dot(offset, up)/depth)
    }
    /// World-units per projected axis: near end-on axes are disabled, not unstable.
    func axisDelta(at center: [Double], axis: Int, pixels: NSPoint) -> Double? {
        var end = center; end[axis] += 1
        guard let a = project(center), let b = project(end) else { return nil }
        let dx = b.x-a.x, dy = b.y-a.y, length2 = dx*dx+dy*dy
        guard length2 > 0.04 else { return nil }
        return (pixels.x*dx + pixels.y*dy)/length2
    }
    func ray(at p: NSPoint) -> WorldViewerRay {
        let x = (Double(p.x)-Double(viewport.width)/2)/focal
        let y = (Double(p.y)-Double(viewport.height)/2)/focal
        return WorldViewerRay(originMM: camera.positionMM,
                              direction: Self.unit((0..<3).map { forward[$0]+right[$0]*x+up[$0]*y }))
    }
}

/// Polling cannot overwrite dirty fields or turn an ACK into optimistic geometry.
final class WorldEditorInspector: NSStackView, NSTextFieldDelegate {
    let overlay = WorldEditorOverlay(frame: .zero)
    var onSubmit: ((LabCommand, WorldEditorIdentity) -> (Int, LabCommandSchedule)?)?
    var onSelect: ((String?) -> Void)?
    var onSelectResult: ((String?, String) -> Bool)?
    /// Asks the window to bring an object into the 3D view.
    var onFocus: ((String) -> Void)?
    let objectsPopup = NSPopUpButton()
    let tools = NSSegmentedControl()
    let fields = (0..<3).map { _ in NSTextField(string: "") }
    private let labels = (0..<3).map { _ in NSTextField(labelWithString: "") }
    private let focusButton = NSButton()
    private let actualLabel = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton()
    private let duplicateButton = NSButton()
    private let deleteButton = NSButton()
    /// Everything but the status line; collapsed outside Edit mode.
    private let body = NSStackView()
    private(set) var state = WorldEditorState()
    private var identity = WorldEditorIdentity(generation: 0, sessionID: "", epoch: 0)
    private var capabilities: EnvironmentCapabilities?
    private var object: LabWorldObjectRemote?
    private var editingObject: LabWorldObjectRemote?
    private var heldID: String?
    private var dirty = false
    private var available = false
    private var wasAvailable = false
    private var mode: LabViewMode = .observe
    private var selectionID: String?
    private var confirmedDuplicate: (id: String, until: Date)?
    private var selectionSerial = 0
    private var requestSelectionSerial = 0
    private var tool: WorldEditorTool { WorldEditorTool(rawValue: tools.selectedSegment) ?? .move }

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        objectsPopup.target = self
        objectsPopup.action = #selector(selectionChanged)
        objectsPopup.setAccessibilityLabel(L("Simulator objects", "시뮬레이터 물체 목록"))
        focusButton.title = L("Show in view", "선택 물체 보기")
        focusButton.bezelStyle = .rounded
        focusButton.target = self
        focusButton.action = #selector(focusSelected)
        let picker = NSStackView(views: [objectsPopup, focusButton])
        picker.spacing = 8

        tools.segmentCount = 3
        tools.selectedSegment = 0
        for t in WorldEditorTool.allCases { tools.setLabel(t.title, forSegment: t.rawValue) }
        tools.target = self
        tools.action = #selector(toolChanged)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.addArrangedSubview(picker)
        body.addArrangedSubview(tools)
        for i in 0..<3 {
            fields[i].delegate = self
            fields[i].target = self
            fields[i].action = #selector(applyNumeric)
            fields[i].widthAnchor.constraint(equalToConstant: 100).isActive = true
            labels[i].widthAnchor.constraint(equalToConstant: 80).isActive = true
            let row = NSStackView(views: [labels[i], fields[i]])
            row.spacing = 8
            body.addArrangedSubview(row)
        }

        applyButton.title = L("Apply", "적용")
        applyButton.target = self
        applyButton.action = #selector(applyNumeric)
        duplicateButton.title = L("Duplicate", "복제")
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicate)
        deleteButton.title = L("Delete", "삭제")
        deleteButton.target = self
        deleteButton.action = #selector(remove)
        for b in [applyButton, duplicateButton, deleteButton] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [applyButton, duplicateButton, deleteButton])
        buttons.spacing = 6
        body.addArrangedSubview(buttons)

        actualLabel.font = .systemFont(ofSize: 11)
        actualLabel.textColor = .secondaryLabelColor
        body.addArrangedSubview(actualLabel)
        let hint = NSTextField(wrappingLabelWithString: L(
            "Position and size are in mm, rotation in degrees (around the vertical axis only). Press Return to apply typed values, or drag a colored handle in the 3D view; Esc cancels a drag. A duplicate appears on top of the original — move it next. There is no undo yet.",
            "위치·크기는 mm, 회전은 도(°) 단위이며 수직축으로만 돕니다. 값을 입력하고 Return을 누르거나 3D 화면의 색깔 핸들을 끌어 바꾸고, 끄는 중 Esc를 누르면 취소됩니다. 복제본은 원본과 같은 자리에 생기니 바로 옮기세요. 되돌리기는 아직 없습니다."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        body.addArrangedSubview(hint)

        status.font = .systemFont(ofSize: 12)
        addArrangedSubview(body)
        addArrangedSubview(status)
        overlay.onCommit = { [weak self] t, value, object in self?.submit(t, value, object) }
        overlay.onDraft = { [weak self] text in self?.status.stringValue = text }
        populate()
        renderStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if !dirty { editingObject = object }
    }
    func controlTextDidChange(_ notification: Notification) { dirty = true }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            dirty = false
            editingObject = object
            populate(resetFocused: true)
            overlay.cancelDrag()
            state.clearDraftMessage()
            renderStatus()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            applyNumeric()
            return true
        }
        return false
    }

    /// Keep only a captured delete target until its own ACK, or a confirmed new
    /// duplicate while its first owner snapshot is in flight. Never restore a
    /// different, newer user selection.
    func retainSelection(_ current: String?, snapshot: WorldRenderSnapshot) -> String? {
        guard mode == .edit, current == selectionID else { return nil }
        if snapshot.objects.contains(where: { $0.id == current }) {
            if confirmedDuplicate?.id == current { confirmedDuplicate = nil }
            return nil
        }
        if let p = state.pending, p.propertyID == "object.delete", p.targetID == current,
           requestSelectionSerial == selectionSerial { return current }
        if let d = confirmedDuplicate, d.id == current, Date() < d.until { return current }
        return nil
    }

    @objc private func selectionChanged() {
        selectionSerial += 1
        overlay.cancelDrag()
        dirty = false
        guard let id = objectsPopup.selectedItem?.representedObject as? String else { return }
        onSelect?(id)
        onFocus?(id)
    }
    @objc private func focusSelected() {
        if let id = object?.id { onFocus?(id) }
    }
    @objc private func toolChanged() {
        dirty = false
        editingObject = object
        overlay.cancelDrag()
        overlay.tool = tool
        populate(resetFocused: true)
        refreshEnabled()
        renderStatus()
    }

    private func descriptor(_ t: WorldEditorTool, _ o: LabWorldObjectRemote) -> EnvironmentPropertyDescriptor? {
        capabilities?.descriptor(t.propertyID(shape: o.shape))
    }
    private func supported(_ t: WorldEditorTool) -> Bool {
        guard let o = object, let d = descriptor(t, o) else { return false }
        return d.applyMode == .live && o.revision != nil
    }
    /// Rotation, and size of round/long shapes, are one number.
    private func isScalar(_ t: WorldEditorTool, _ o: LabWorldObjectRemote?) -> Bool {
        t == .rotate || (t == .size && o.flatMap { descriptor(.size, $0) }?.valueType == .number)
    }

    func update(objects: [LabWorldObjectRemote], selectedID: String?, capabilities: EnvironmentCapabilities?,
                identity: WorldEditorIdentity, mode: LabViewMode, available: Bool, heldID: String?,
                camera: WorldViewerMuJoCoCamera) {
        let next = objects.first { $0.id == selectedID }
        let changed = self.identity != identity || selectionID != selectedID || self.mode != mode
        if changed {
            selectionSerial += 1
            confirmedDuplicate = nil
        }
        self.identity = identity
        self.mode = mode
        self.capabilities = capabilities
        self.heldID = heldID
        selectionID = selectedID
        self.available = available && next != nil && next?.id != heldID
        state.reconcile(identity: identity)
        let previousRevision = object?.revision
        object = next
        let revised = next != nil && previousRevision != next?.revision
        if changed || revised || (!self.available && wasAvailable) {
            overlay.cancelDrag()
            dirty = false
            editingObject = next
            populate(resetFocused: true)
        } else if !dirty && !fields.contains(where: { $0.currentEditor() != nil }) {
            editingObject = next
        }
        wasAvailable = self.available
        refreshPopup(objects: objects, selectedID: selectedID)
        overlay.camera = camera
        overlay.selected = next
        overlay.visibleSelection = mode == .edit
        overlay.scalarSize = isScalar(.size, next)
        if !dirty { populate() }
        actualLabel.stringValue = next.map(Self.describeCurrent) ?? ""
        actualLabel.isHidden = next == nil
        body.isHidden = mode != .edit
        refreshEnabled()
        renderStatus()
    }

    private func refreshPopup(objects: [LabWorldObjectRemote], selectedID: String?) {
        let ids = objects.map(\.id)
        let listed = objectsPopup.itemArray.compactMap { $0.representedObject as? String }
        if listed != ids || objectsPopup.numberOfItems != ids.count + 1 {
            objectsPopup.removeAllItems()
            objectsPopup.addItem(withTitle: ids.isEmpty
                ? L("No objects — place one below", "물체 없음 — 아래 ‘물체 놓기’에서 만드세요")
                : L("Choose an object…", "물체 선택…"))
            for o in objects {
                objectsPopup.addItem(withTitle: "\(o.id) · \(LabToy.shapeName(o.shape))")
                objectsPopup.lastItem?.representedObject = o.id
            }
        }
        objectsPopup.selectItem(at: ids.firstIndex(of: selectedID ?? "").map { $0 + 1 } ?? 0)
    }

    private static func describeCurrent(_ o: LabWorldObjectRemote) -> String {
        let position = o.positionMM.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        let size = o.sizeMM.map { String(format: "%.1f", $0) }.joined(separator: " × ")
        let yaw = String(format: "%.1f", o.yawDeg)
        return L("Now — position \(position) mm · rotation \(yaw)° · size \(size) mm",
                 "현재 — 위치 \(position) mm · 회전 \(yaw)° · 크기 \(size) mm")
    }

    private func populate(resetFocused: Bool = false) {
        let scalar = isScalar(tool, editingObject ?? object)
        for i in 0..<3 {
            let label = tool == .rotate ? L("Rotation (°)", "회전 (°)")
                : scalar ? L("Size (mm)", "크기 (mm)") : ["X (mm)", "Y (mm)", "Z (mm)"][i]
            labels[i].stringValue = label
            labels[i].superview?.isHidden = scalar && i > 0
            fields[i].setAccessibilityLabel(tool.title + " " + label)
        }
        guard let o = editingObject else {
            for field in fields {
                field.stringValue = ""
                if resetFocused { field.currentEditor()?.string = "" }
            }
            return
        }
        let values = tool == .move ? o.positionMM : tool == .rotate ? [o.yawDeg] : scalar ? [o.sizeMM[0]] : o.sizeMM
        for (i, field) in fields.enumerated() {
            let value = i < values.count ? String(format: "%.6g", values[i]) : ""
            guard field.stringValue != value, resetFocused || field.currentEditor() == nil else { continue }
            field.stringValue = value
            if resetFocused { field.currentEditor()?.string = value }
        }
    }

    private func refreshEnabled() {
        let enabled = available && mode == .edit && state.pending == nil
        for t in WorldEditorTool.allCases { tools.setEnabled(enabled && supported(t), forSegment: t.rawValue) }
        let valueEnabled = enabled && supported(tool)
        fields.forEach { $0.isEnabled = valueEnabled }
        applyButton.isEnabled = valueEnabled
        let canMutate = enabled && object?.revision != nil
        duplicateButton.isEnabled = canMutate && capabilities?.objectOperations.contains("duplicate") == true
        deleteButton.isEnabled = canMutate && capabilities?.objectOperations.contains("delete") == true
        objectsPopup.isEnabled = mode == .edit
        focusButton.isEnabled = mode == .edit && object != nil
        overlay.editable = valueEnabled
    }

    private func renderStatus() {
        status.textColor = mode == .edit && state.isError ? .systemRed : .secondaryLabelColor
        status.stringValue = mode == .edit && !state.message.isEmpty ? state.message : guidance
    }
    private var guidance: String {
        if mode != .edit {
            return L("Press Edit in the toolbar to move, rotate, resize, duplicate or delete objects.",
                     "물체를 옮기거나 돌리고, 크기를 바꾸거나 복제·삭제하려면 위쪽 ‘편집’을 누르세요.")
        }
        guard let object else {
            return L("Click an object in the 3D view or choose one from the list.",
                     "3D 화면에서 물체를 클릭하거나 목록에서 고르세요.")
        }
        if object.id == heldID {
            return L("A held object can't be edited — drop it first.", "잡고 있는 물체는 편집할 수 없습니다. 먼저 내려놓으세요.")
        }
        if !available { return L("Waiting for the simulator view…", "시뮬레이터 화면을 기다리는 중…") }
        if !supported(tool) { return L("This simulator can't change this property.", "이 시뮬레이터에서는 이 속성을 바꿀 수 없습니다.") }
        return L("Type a value and press Return, or drag a colored handle in the 3D view.",
                 "값을 입력하고 Return을 누르거나, 3D 화면의 색깔 핸들을 끌어 바꾸세요.")
    }

    @objc private func applyNumeric() {
        guard let o = editingObject, applyButton.isEnabled else { return }
        let scalar = isScalar(tool, o)
        let text = fields.prefix(scalar ? 1 : 3).map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let bad = text.firstIndex(where: { Double($0)?.isFinite != true }) {
            let name = scalar ? labels[0].stringValue : ["X", "Y", "Z"][bad]
            state.fail(name + L(": enter a number (decimal point .) — not applied", ": 숫자를 입력하세요 (소수점은 .) — 적용 안 됨"))
            renderStatus()
            return
        }
        let values = text.compactMap(Double.init)
        submit(tool, scalar ? .number(values[0]) : .vector(values), o)
    }
    private func submit(_ t: WorldEditorTool, _ value: EnvironmentPropertyValue, _ source: LabWorldObjectRemote) {
        guard available, mode == .edit, state.pending == nil, object?.id == source.id,
              let caps = capabilities, let revision = source.revision else { return }
        do {
            let edit = try EnvironmentEdit.make(propertyID: t.propertyID(shape: source.shape), targetID: source.id,
                                                expectedRevision: revision, value: value, capabilities: caps)
            enqueue(LabCommand.editProperty(edit), propertyID: edit.propertyID, source: source, value: value)
        } catch {
            state.fail(L("Not applied — ", "적용 안 됨 — ") + String(describing: error))
            renderStatus()
        }
    }
    private func enqueue(_ command: LabCommand, propertyID: String, source: LabWorldObjectRemote,
                         value: EnvironmentPropertyValue?) {
        guard let (id, schedule) = onSubmit?(command, identity), let revision = source.revision else {
            state.fail(L("Command not sent", "명령 전송 실패"))
            renderStatus()
            return
        }
        dirty = false
        requestSelectionSerial = selectionSerial
        state.begin(WorldEditorPending(commandID: id, identity: identity, schedule: schedule,
                                       propertyID: propertyID, targetID: source.id,
                                       expectedRevision: revision, proposedValue: value,
                                       capabilities: capabilities, startedAt: Date()))
        overlay.cancelDrag()
        refreshEnabled()
        renderStatus()
    }
    @objc private func duplicate() { mutate("duplicate") }
    @objc private func remove() { mutate("delete") }
    private func mutate(_ op: String) {
        guard available, mode == .edit, state.pending == nil, let o = object, let revision = o.revision,
              capabilities?.objectOperations.contains(op) == true else { return }
        var command = LabCommand(id: 0, action: "edit_object", target: o.id)
        command.objectEdit = WorldObjectEdit(operation: op, targetID: o.id, expectedRevision: revision)
        enqueue(command, propertyID: "object." + op, source: o, value: nil)
    }

    func accept(_ ack: LabAck) {
        let pending = state.pending
        let duplicateID = state.accept(ack)
        if let p = pending, state.pending == nil, !state.isError,
           selectionSerial == requestSelectionSerial, selectionID == p.targetID, mode == .edit,
           ["object.duplicate", "object.delete"].contains(p.propertyID) {
            let selectionApplied = onSelectResult?(duplicateID, p.targetID) ?? true
            if selectionApplied, let duplicateID {
                selectionID = duplicateID
                confirmedDuplicate = (duplicateID, Date().addingTimeInterval(2))
                if onSelectResult == nil { onSelect?(duplicateID) }
            } else if selectionApplied && p.propertyID == "object.delete", onSelectResult == nil {
                onSelect?(nil)
            }
        }
        refreshEnabled()
        renderStatus()
    }
}

final class WorldEditorOverlay: NSView {
    var onCommit: ((WorldEditorTool, EnvironmentPropertyValue, LabWorldObjectRemote) -> Void)?
    var onDraft: ((String) -> Void)?
    var camera: WorldViewerMuJoCoCamera? { didSet { needsDisplay = true } }
    var tool: WorldEditorTool = .move { didSet { cancelDrag(); needsDisplay = true } }
    var selected: LabWorldObjectRemote? { didSet {
        if oldValue?.id != selected?.id || oldValue?.revision != selected?.revision { cancelDrag() }
        needsDisplay = true
    } }
    var editable = false { didSet { if !editable { cancelDrag() }; needsDisplay = true } }
    var visibleSelection = false { didSet { needsDisplay = true } }
    var scalarSize = false
    private struct Handle { let axis: Int; let point: NSPoint; let center: NSPoint }
    private struct Drag { let object: LabWorldObjectRemote; let axis: Int; let start: NSPoint
        let projection: WorldEditorProjection; var value: EnvironmentPropertyValue? }
    private var drag: Drag?
    override var acceptsFirstResponder: Bool { true }
    func cancelDrag() { drag = nil; needsDisplay = true }
    /// Whether the selected object's center projects comfortably inside the view.
    var selectionOnScreen: Bool {
        guard let object = selected, let center = projection?.project(object.positionMM) else { return false }
        return bounds.insetBy(dx: 24, dy: 24).contains(center)
    }
    private var projection: WorldEditorProjection? { camera.map { WorldEditorProjection(camera: $0, viewport: bounds.size) } }
    private func handles() -> [Handle] {
        guard editable, let object = selected, let p = projection, let center = p.project(object.positionMM) else { return [] }
        if tool == .rotate { return [Handle(axis: 2, point: NSPoint(x: center.x+55, y: center.y+35), center: center)] }
        let axes = scalarSize && tool == .size ? [0] : [0, 1, 2]
        let yaw = object.yawDeg * .pi / 180
        return axes.compactMap { axis in
            var direction = [0.0, 0, 0]; direction[axis] = 1
            if tool == .size && !scalarSize && axis < 2 {
                direction = axis == 0 ? [cos(yaw), sin(yaw), 0] : [-sin(yaw), cos(yaw), 0]
            }
            let end = (0..<3).map { object.positionMM[$0]+direction[$0] }
            guard let b = p.project(end) else { return nil }
            let dx = b.x-center.x, dy = b.y-center.y, length = hypot(dx,dy)
            guard length > 0.2 else { return nil }
            return Handle(axis: axis, point: NSPoint(x:center.x+dx/length*55, y:center.y+dy/length*55), center: center)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return handles().contains { hypot($0.point.x-local.x,$0.point.y-local.y) <= 14 } ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let h = handles().min(by: { hypot($0.point.x-point.x,$0.point.y-point.y) < hypot($1.point.x-point.x,$1.point.y-point.y) }),
              let object = selected, let p = projection else { return }
        window?.makeFirstResponder(self)
        drag = Drag(object: object, axis: h.axis, start: point, projection: p, value: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: point.x-d.start.x, y: point.y-d.start.y)
        if tool == .rotate {
            d.value = .number(d.object.yawDeg + Double(delta.x)) // 1 degree / point
        } else {
            var unit = [0.0,0,0]; unit[d.axis] = 1
            if tool == .size && !scalarSize && d.axis < 2 {
                let yaw = d.object.yawDeg * .pi / 180
                unit = d.axis == 0 ? [cos(yaw),sin(yaw),0] : [-sin(yaw),cos(yaw),0]
            }
            let end = (0..<3).map { d.object.positionMM[$0]+unit[$0] }
            guard let a = d.projection.project(d.object.positionMM), let b = d.projection.project(end) else { return }
            let dx = b.x-a.x, dy = b.y-a.y, l2 = dx*dx+dy*dy
            guard l2 > 0.04 else { return }
            let amount = Double((delta.x*dx+delta.y*dy)/l2)
            if tool == .move { var v = d.object.positionMM; v[d.axis] += amount; d.value = .vector(v) }
            else if scalarSize { d.value = .number(d.object.sizeMM[0]+amount*2) }
            else { var v = d.object.sizeMM; v[d.axis] += amount*2; d.value = .vector(v) }
        }
        drag = d
        if let v = d.value { onDraft?(L("Draft (not applied): ", "초안 (미적용): ")+WorldEditorState.describe(v)) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }; drag = nil; needsDisplay = true
        if let value = d.value { onCommit?(tool, value, d.object) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag(); onDraft?(L("Draft cancelled", "초안 취소됨")) }
        else { super.keyDown(with:event) }
    }
    override func resignFirstResponder() -> Bool { cancelDrag(); return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        guard visibleSelection, let object = selected, let p = projection else { return }
        let yaw = object.yawDeg * .pi / 180
        let corners: [NSPoint?] = (0..<8).map { index in
            let x = object.sizeMM[0]/2 * (index & 1 == 0 ? -1.0:1.0)
            let y = object.sizeMM[1]/2 * (index & 2 == 0 ? -1.0:1.0)
            let z = object.sizeMM[2]/2 * (index & 4 == 0 ? -1.0:1.0)
            return p.project([object.positionMM[0]+x*cos(yaw)-y*sin(yaw), object.positionMM[1]+x*sin(yaw)+y*cos(yaw),object.positionMM[2]+z])
        }
        let outline = NSBezierPath(); outline.lineWidth = 2
        for index in 0..<8 { for bit in [1,2,4] where index & bit == 0 {
            if let a = corners[index], let b = corners[index|bit] { outline.move(to:a); outline.line(to:b) }
        } }
        NSColor.black.withAlphaComponent(0.8).setStroke(); outline.lineWidth=4; outline.stroke()
        NSColor.systemYellow.setStroke(); outline.lineWidth=2; outline.stroke()
        for h in handles() {
            let color: NSColor = [NSColor.systemRed,.systemGreen,.systemBlue][h.axis]
            let line = NSBezierPath(); line.move(to:h.center); line.line(to:h.point); line.lineWidth=3
            color.setStroke(); line.stroke()
            let rect = NSRect(x:h.point.x-10,y:h.point.y-10,width:20,height:20)
            color.setFill(); NSBezierPath(ovalIn:rect).fill()
            let label = tool == .rotate ? "↻" : scalarSize && tool == .size ? "S" : ["X","Y","Z"][h.axis]
            (label as NSString).draw(at:NSPoint(x:h.point.x-5,y:h.point.y-7),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.bold),.foregroundColor:NSColor.white])
        }
        if let v = drag?.value, let center = p.project(object.positionMM) {
            (L("Draft: ","초안: ")+WorldEditorState.describe(v) as NSString).draw(at:NSPoint(x:center.x+12,y:center.y-25),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:NSColor.systemYellow,.backgroundColor:NSColor.black])
        }
    }
}
