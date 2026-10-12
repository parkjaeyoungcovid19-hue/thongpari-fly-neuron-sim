import Cocoa

// V7.7 "설명" card — under the event timeline. Read-only: it only calls the pure
// `explain(window:)` on the selected event's window (never stimulates, never
// writes). Every verdict, including observing / no response / unclear /
// insufficient, is shown as a visible badge plus its sentences; the facts the
// sentences cite are behind a disclosure.

extension ExplanationVerdict {
    var badge: String {
        switch self {
        case .observing: return L("Observing", "관측 중")
        case .insufficient: return L("Insufficient data", "데이터 부족")
        case .noResponse: return L("No response", "무반응")
        case .neuralResponse: return L("Neural response", "신경 반응")
        case .neuralActivityOnly: return L("Neural activity only", "신경 활동만")
        case .physicalOnly: return L("Physical force", "물리적 힘")
        case .mixed: return L("Mixed", "혼합")
        case .unclear: return L("Unclear", "불명확")
        }
    }

    var color: NSColor {
        switch self {
        case .observing: return .systemBlue
        case .insufficient, .unclear: return .systemOrange
        case .noResponse: return .systemGray
        case .neuralResponse, .neuralActivityOnly: return .systemGreen
        case .physicalOnly: return .systemBrown
        case .mixed: return .systemPurple
        }
    }
}

enum ExplanationText {
    /// Pure formatting (the diagnostics read it too).
    static func sentences(_ e: InteractionExplanation) -> String {
        (LabLanguage.current == .korean ? e.sentences.ko : e.sentences.en).joined(separator: "\n")
    }

    static func facts(_ e: InteractionExplanation) -> String {
        e.facts.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
    }
}

final class ExplanationPanel: NSStackView {
    private weak var coordinator: Coordinator?
    private let eventID: () -> String?
    private let badge = NSTextField(labelWithString: "")
    private let sentences = NSTextField(wrappingLabelWithString: "")
    private let factsLabel = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: L("Facts used", "사용한 수치"), target: nil, action: nil)
    private var timer: Timer?

    init(coordinator: Coordinator, eventID: @escaping () -> String?) {
        self.coordinator = coordinator
        self.eventID = eventID
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        let title = LabForm.label(L("Explanation (from measured numbers only)", "설명 (잰 수치만 근거)"))
        title.alignment = .left
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.isBordered = false; badge.drawsBackground = false
        _ = LabForm.status(sentences)
        sentences.textColor = .labelColor
        _ = LabForm.status(factsLabel, mono: true)
        factsLabel.isHidden = true
        toggle.setButtonType(.pushOnPushOff); toggle.bezelStyle = .disclosure
        toggle.target = self; toggle.action = #selector(toggled)
        for v in [title, badge, sentences, toggle, factsLabel] as [NSView] { addArrangedSubview(v) }
        for v in [sentences, factsLabel] as [NSView] { v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
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

    @objc private func toggled() { factsLabel.isHidden = toggle.state != .on }

    func refresh() {
        guard let id = eventID(), let w = coordinator?.sim?.eventWindows.window(eventID: id) else {
            badge.isHidden = true; toggle.isHidden = true; factsLabel.isHidden = true
            sentences.stringValue = L("Select an event to see what was measured around it.", "사건을 고르면 그 전후에 잰 값에 대한 설명이 나타납니다.")
            return
        }
        let e = explain(window: w)
        badge.isHidden = false; toggle.isHidden = false
        badge.stringValue = " \(e.verdict.badge) "
        badge.drawsBackground = true
        badge.backgroundColor = e.verdict.color
        sentences.stringValue = ExplanationText.sentences(e)
        factsLabel.stringValue = ExplanationText.facts(e)
        factsLabel.isHidden = toggle.state != .on
    }
}
