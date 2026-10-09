// LabWindow+Groups.swift — V7.4 functional group registry panel (Lab Brain page).
//
// Lists the registered groups by category, shows one group's membership/source/
// dataset status, and can arm the group as the exact (read-only) observation
// selection through `Coordinator.observeGroup`. The panel only reads the
// registry and observer; it never stimulates and never touches extInput.

import Cocoa

extension GroupCategory {
    var title: String {
        switch self {
        case .arousal: return L("Arousal", "각성")
        case .threatRelated: return L("Threat-related", "위협 관련")
        case .motor: return L("Motor", "운동")
        case .sensory: return L("Sensory", "감각")
        case .unclassified: return L("Unclassified", "분류되지 않음")
        }
    }
}

extension GroupEvidenceTier {
    var title: String {
        switch self {
        case .annotatedCellType: return L("annotated cell type", "세포 유형 주석")
        case .modelSelected: return L("model-selected (by connectivity)", "모델이 연결 기반으로 선별")
        case .residual: return L("residual (no functional claim)", "잔여 (기능 주장 없음)")
        }
    }
}

extension GroupDisableReason {
    var localized: String {
        switch self {
        case let .datasetMismatch(b, l):
            return String(format: L("dataset hash mismatch: group bound to %@…, loaded %@…", "데이터셋 해시 불일치: 그룹은 %@…용, 불러온 것은 %@…"),
                          String(b.prefix(12)), String(l.prefix(12)))
        case let .unknownRootIDs(n, f):
            return String(format: L("%d root ID(s) are not in the loaded dataset (first %@)", "root ID %d개가 불러온 데이터셋에 없음 (첫 번째 %@)"), n, f)
        case .noMembers: return L("the group has no members", "구성원이 없음")
        }
    }
}

extension GroupObservationError {
    var localized: String {
        switch self {
        case let .unknownGroup(g): return L("unknown group ", "알 수 없는 그룹 ") + g
        case let .disabled(r): return L("group disabled: ", "비활성 그룹: ") + r.localized
        case let .overLimit(n, l): return String(format: L("exact observation unavailable (%d > %d)", "정확 관측 불가 (%d > %d)"), n, l)
        case .noSimulation: return L("The brain model is not loaded.", "뇌 모델을 불러오지 않았습니다.")
        }
    }
}

final class GroupRegistryPanel: NSStackView {
    /// Root IDs shown inline; "Copy all" carries every one.
    static let visibleRootIDs = 20

    static var helpText: String {
        L("Named neuron sets bound to the loaded dataset by hash and root ID, with where each claim comes from. A group whose hash, root IDs or members do not match the loaded data is disabled and unknown — never shown as 0 Hz. Exact observation covers at most \(ObservationCapability.exactSelectionLimit) neurons; a larger group is reported unavailable, not sampled. Observing a group only selects its neurons; it never injects current. There is no registered arousal group.",
          "불러온 데이터셋과 해시·root ID로 묶인 뉴런 집합이며, 각 분류의 근거를 함께 보여 줍니다. 해시, root ID, 구성원이 맞지 않는 그룹은 비활성·상태 불명으로 표시하며 0 Hz로 보여 주지 않습니다. 정확 관측은 최대 \(ObservationCapability.exactSelectionLimit)개까지이며, 더 큰 그룹은 표본으로 대신하지 않고 ‘불가’로 표시합니다. 그룹 관측은 뉴런을 고르기만 하고 전류를 넣지 않습니다. 각성 그룹은 등록되어 있지 않습니다.")
    }

    private weak var coordinator: Coordinator?
    private let registry: GroupRegistry?
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let rootsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var observeButton = NSButton()
    private(set) var copyButton = NSButton()
    private(set) var selectedGroup: String?
    private var lastActionText = ""
    private var timer: Timer?

    var detailText: String { detailLabel.stringValue }
    var rootsText: String { rootsLabel.stringValue }
    var statusText: String { statusLabel.stringValue }
    var summaryText: String { summaryLabel.stringValue }

    /// `registry` defaults to the sim's built-in one; a fixture may be passed in.
    init(coordinator: Coordinator, registry: GroupRegistry? = nil) {
        self.coordinator = coordinator
        self.registry = registry ?? coordinator.sim?.groupRegistry
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        guard let registry = self.registry else {
            addArrangedSubview(LabForm.note(L("The brain model is not loaded.", "뇌 모델을 불러오지 않았습니다.")))
            return
        }
        if let err = registry.buildError {
            addArrangedSubview(LabForm.note(L("The group registry could not be built: ", "그룹 registry를 만들지 못했습니다: ") + err))
            return
        }
        _ = LabForm.status(summaryLabel); _ = LabForm.status(detailLabel)
        _ = LabForm.status(rootsLabel, mono: true); _ = LabForm.status(statusLabel)
        summaryLabel.stringValue = summary(registry)
        buildPicker(registry)
        picker.target = self
        picker.action = #selector(pickerChanged)
        observeButton = NSButton(title: L("Observe exactly", "정확 관측 시작"), target: self, action: #selector(observeSelected))
        copyButton = NSButton(title: L("Copy all root IDs", "root ID 전체 복사"), target: self, action: #selector(copyAllRootIDs))
        for b in [observeButton, copyButton] { b.bezelStyle = .rounded }
        for v in [summaryLabel, picker, detailLabel, rootsLabel, LabForm.buttons([observeButton, copyButton]), statusLabel] as [NSView] {
            addArrangedSubview(v)
            if !(v is NSPopUpButton) { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }
        if let first = registry.definitions.first(where: { registry.members($0.groupID) != nil }) ?? registry.definitions.first {
            select(groupID: first.groupID)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil, registry != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: list

    private func summary(_ r: GroupRegistry) -> String {
        var lines = [L("Groups are metadata over exact observation. A group may overlap or nest in another; a neuron counts in each group that lists it.",
                       "그룹은 정확 관측 위에 얹은 설명 정보입니다. 그룹끼리 겹치거나 포함될 수 있고, 뉴런은 자신을 포함한 그룹마다 각각 셉니다.")]
        for c in GroupCategory.allCases {
            switch r.categoryStatus(c) {
            case .populated(let n): lines.append("● \(c.title): " + String(format: L("%d group(s)", "그룹 %d개"), n))
            case .noRegisteredGroup:
                lines.append("○ \(c.title): " + (GroupRegistry.emptyCategoryNote(c)?.pick ?? L("no registered group", "등록된 그룹 없음")))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Items grouped under a disabled heading per category; an empty category
    /// gets an explicit "no registered group" row instead of vanishing.
    private func buildPicker(_ r: GroupRegistry) {
        picker.removeAllItems()
        func add(_ title: String, id: String?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            item.isEnabled = id != nil
            picker.menu?.addItem(item)
        }
        for c in GroupCategory.allCases {
            let groups = r.groups(in: c)
            add("— \(c.title) —", id: nil)
            if groups.isEmpty { add("    " + L("(no registered group)", "(등록된 그룹 없음)"), id: nil) }
            for g in groups {
                // Indent only under a parent listed above in the same category.
                let nested = g.parentIDs.contains { r.definition($0)?.category == c }
                add((nested ? "      ↳ " : "    ") + g.labels.pick + " (\(g.membership.rootIDs.count))", id: g.groupID)
            }
        }
    }

    // MARK: selection and actions

    func select(groupID: String) {
        guard let item = picker.itemArray.first(where: { ($0.representedObject as? String) == groupID }) else { return }
        picker.select(item)
        selectedGroup = groupID
        lastActionText = ""
        refresh()
    }

    @objc private func pickerChanged() {
        selectedGroup = picker.selectedItem?.representedObject as? String
        lastActionText = ""
        refresh()
    }

    /// Arms the selected group as the exact selection (read-only; same as a brain pick).
    @objc func observeSelected() {
        guard let id = selectedGroup, let coordinator else { return }
        switch coordinator.observeGroup(id, registry: registry) {
        case .success(let n):
            lastActionText = String(format: L("Queued: %d neurons will be observed exactly once the simulation runs.",
                                              "대기 중: 시뮬레이션이 돌면 뉴런 %d개를 정확 관측합니다."), n)
        case .failure(let e): lastActionText = e.localized
        }
        refresh()
    }

    @objc func copyAllRootIDs() {
        guard let id = selectedGroup, let def = registry?.definition(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(def.membership.rootIDs.joined(separator: "\n"), forType: .string)
        lastActionText = String(format: L("Copied %d root IDs.", "root ID %d개를 복사했습니다."), def.membership.rootIDs.count)
        refresh()
    }

    // MARK: detail

    func refresh() {
        guard let registry, let id = selectedGroup, let def = registry.definition(id) else { return }
        let status = registry.status(id)
        let n = def.membership.rootIDs.count
        var lines = ["\(def.labels.pick)  [\(def.groupID)]",
                     String(format: L("Category: %@ · members: %d · evidence: %@", "범주: %@ · 구성원: %d개 · 근거 수준: %@"),
                            def.category.title, n, def.evidenceTier.title)]
        let parents = registry.parents(of: id), kids = registry.children(of: id)
        lines.append(L("Nested in: ", "상위 그룹: ") + (parents.isEmpty ? "—" : parents.map { "\($0.labels.pick) (\($0.category.title))" }.joined(separator: ", ")))
        lines.append(L("Contains: ", "하위 그룹: ") + (kids.isEmpty ? "—" : kids.map(\.labels.pick).joined(separator: ", ")))
        switch status {
        case .enabled?: lines.append(L("Dataset: OK — matches the loaded neuron binary (sha256 ", "데이터셋: 일치 — 불러온 뉴런 파일과 같음 (sha256 ") + String(def.datasetHash.prefix(12)) + "…)")
        case .disabled(let r)?:
            let head: String
            if case .datasetMismatch = r { head = L("Dataset: MISMATCH — ", "데이터셋: 불일치 — ") }
            else { head = L("Dataset: hash matches, but ", "데이터셋: 해시는 같지만 ") }
            lines.append(head + r.localized + " → " + L("group disabled, status unknown", "그룹 비활성, 상태 알 수 없음"))
        case nil: break
        }
        lines.append(L("Source: ", "출처: ") + def.evidenceSource.pick)
        lines.append(L("Membership rule: ", "구성 규칙: ") + def.membership.query)
        lines.append(L("Baseline policy: ", "기준선 정책: ") + (def.baselinePolicy == .preEventWindow
            ? L("the group's own pre-event window", "그룹 자신의 사건 이전 구간") : L("none", "없음")))
        detailLabel.stringValue = lines.joined(separator: "\n")

        let shown = def.membership.rootIDs.prefix(Self.visibleRootIDs)
        rootsLabel.stringValue = n == 0 ? L("Root IDs: none", "root ID: 없음")
            : String(format: L("Root IDs (first %d of %d):", "root ID (%d / %d개 표시):"), shown.count, n) + "\n" + shown.joined(separator: "  ")
            + (n > shown.count ? "\n" + String(format: L("… +%d more — use “Copy all root IDs”", "… 외 %d개 — ‘root ID 전체 복사’ 사용"), n - shown.count) : "")

        let limit = coordinator?.sim?.observer.limit ?? ObservationCapability.exactSelectionLimit
        var obs: String
        switch registry.observability(id, limit: limit) {
        case .exact(let m)?: obs = String(format: L("Exact observation available (%d ≤ %d). “Observe exactly” arms these neurons read-only; the numbers appear in “Selected neurons” above.",
                                                   "정확 관측 가능 (%d ≤ %d). ‘정확 관측 시작’은 이 뉴런들을 읽기 전용으로 고르며, 수치는 위 ‘선택한 뉴런’에 나옵니다."), m, limit)
        case .overLimit(let m, let l)?: obs = String(format: L("Exact observation unavailable (%d > %d). No subset is observed in its place.",
                                                              "정확 관측 불가 (%d > %d). 일부만 대신 관측하지 않습니다."), m, l)
        case .unsupported(let r)?: obs = L("Exact observation unsupported: ", "정확 관측 지원 안 함: ") + r.localized
        case nil: obs = ""
        }
        if let sel = coordinator?.sim?.observer.selection(), !sel.isEmpty {
            let covered = registry.groups(fullyCoveredBy: sel.neurons)
            if covered.contains(where: { $0.groupID == id }) {
                obs += "\n" + L("The armed selection already covers this whole group.", "지금 고른 정확 관측 선택이 이 그룹 전체를 포함합니다.")
            }
        }
        if !lastActionText.isEmpty { obs += "\n" + lastActionText }
        statusLabel.stringValue = obs
        observeButton.isEnabled = registry.observability(id, limit: limit)?.canArm ?? false
        copyButton.isEnabled = n > 0
    }
}
