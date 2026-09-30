// ActivityCards.swift — V5.7 read-only activity cards for the Lab window.
//
// Every card shows a value the runtime already publishes in `LabTelemetry`;
// nothing here computes a new state. "Measured" cards are spike rates/events of
// the simulated connectome (not recordings from a real fly). "Model index" cards
// are the existing SignalBuilder readouts that drive the body model. Hunger is
// shown as unsupported until an internal-state model exists (planned V11) — no
// proxy is derived from odour or anything else.
//
// Selecting a card only shows where its value comes from. The panel holds no
// reference to the simulator, bridge, player controller or view state, so a click
// cannot become a stimulus or a command (`--labtest` asserts this).

import Cocoa

enum ActivityCardKind {
    case measured, modelIndex, unsupported

    var label: String {
        switch self {
        case .measured: return L("MEASURED · simulated spikes", "측정값 · 시뮬레이션 발화")
        case .modelIndex: return L("MODEL INDEX", "모델 지표")
        case .unsupported: return L("UNSUPPORTED", "미지원")
        }
    }

    var color: NSColor {
        switch self {
        case .measured: return .systemTeal
        case .modelIndex: return .systemOrange
        case .unsupported: return .secondaryLabelColor
        }
    }
}

enum ActivityCardValue: Equatable {
    case number(Double)
    case flag(Bool)
    /// The source is not available in this sample (paused, no brain loaded).
    case missing
    case unsupported
}

enum ActivityCardID: String, CaseIterable {
    case arousal, nervous, walk, turn, groom, sleep
    case gfSpike, populationRate, loomRate, dnaLeft, dnaRight, mdn, ornFoodLeft, ornFoodRight
    case sugarGRN, mn9
    case hunger
}

/// One telemetry sample plus whether this process has a brain simulation at all
/// (without one the rate fields are absent, not zero).
struct ActivityCardInput {
    var telemetry: LabTelemetry
    var brainSimLoaded: Bool
}

struct ActivityCardSpec {
    let id: ActivityCardID
    let kind: ActivityCardKind
    let title: String
    let unit: String
    let decimals: Int
    /// Which telemetry field the value is read from, and where that field comes from.
    let source: String
    /// What the value is — and is not.
    let meaning: String
    let read: (ActivityCardInput) -> ActivityCardValue

    /// Built on demand so the text follows the current interface language.
    static var all: [ActivityCardSpec] {
        // Decoded BrainSignals exist only for a frame the brain actually stepped.
        func signal(_ get: @escaping (LabTelemetry) -> Double) -> (ActivityCardInput) -> ActivityCardValue {
            { $0.telemetry.brainSignalsAvailable ? .number(get($0.telemetry)) : .missing }
        }
        func signalFlag(_ get: @escaping (LabTelemetry) -> Bool) -> (ActivityCardInput) -> ActivityCardValue {
            { $0.telemetry.brainSignalsAvailable ? .flag(get($0.telemetry)) : .missing }
        }
        func rate(_ get: @escaping (LabTelemetry) -> Double) -> (ActivityCardInput) -> ActivityCardValue {
            { $0.brainSimLoaded ? .number(get($0.telemetry)) : .missing }
        }
        let modelNote = L("An engineering index of the simulation, not a feeling or thought of the fly.",
                          "시뮬레이션의 모델 지표이며 파리의 감정이나 생각을 읽은 값이 아닙니다.")
        let rateNote = L("Spike rate of the simulated FlyWire population (moving average), not a recording from a real fly.",
                         "시뮬레이션한 FlyWire 뉴런 그룹의 발화율(이동 평균)이며 실제 파리에서 잰 값이 아닙니다.")
        return [
            ActivityCardSpec(id: .arousal, kind: .modelIndex,
                             title: L("Arousal", "각성 지표"), unit: "0–1", decimals: 2,
                             source: L("BrainSignals.arousal — whole-brain mean rate scaled to 0–1 by SignalBuilder",
                                       "BrainSignals.arousal — 뇌 전체 평균 발화율을 SignalBuilder가 0–1로 줄인 값"),
                             meaning: L("Overall network activity. ", "전체 뉴런 활동 수준입니다. ") + modelNote,
                             read: signal { $0.brainArousal }),
            ActivityCardSpec(id: .nervous, kind: .modelIndex,
                             title: L("Looming threat", "다가옴(위협) 감지"), unit: "0–1", decimals: 2,
                             source: L("BrainSignals.nervous — LC4/LPLC2 looming-detector rate scaled to 0–1",
                                       "BrainSignals.nervous — LC4/LPLC2 다가옴 감지 뉴런 발화율을 0–1로 줄인 값"),
                             meaning: L("Visual threat-related activity; it does not mean the fly feels fear. ",
                                        "시각 위협 관련 활동이며 공포를 느낀다는 뜻이 아닙니다. ") + modelNote,
                             read: signal { $0.brainNervous }),
            ActivityCardSpec(id: .walk, kind: .modelIndex,
                             title: L("Walk drive", "걷기 명령"), unit: "0–1.3", decimals: 2,
                             source: L("BrainSignals.walkDrive — from the DNp09 rate", "BrainSignals.walkDrive — DNp09 발화율에서 계산"),
                             meaning: L("Forward-walking command sent to the body; a command, not proof the body moved. ",
                                        "몸에 보낸 앞으로 걷기 명령이며, 몸이 실제로 움직였다는 증거는 아닙니다. ") + modelNote,
                             read: signal { $0.brainWalkDrive }),
            ActivityCardSpec(id: .turn, kind: .modelIndex,
                             title: L("Turn bias", "방향 전환 명령"), unit: "−1…1", decimals: 2,
                             source: L("BrainSignals.turnBias — DNa01/02 left−right rate difference minus its slow baseline",
                                       "BrainSignals.turnBias — DNa01/02 왼쪽−오른쪽 발화율 차이에서 느린 기준값을 뺀 값"),
                             meaning: L("Steering command sent to the body. ", "몸에 보낸 방향 전환 명령입니다. ") + modelNote,
                             read: signal { $0.brainTurnBias }),
            ActivityCardSpec(id: .groom, kind: .modelIndex,
                             title: L("Grooming drive", "몸 손질 명령"), unit: "0–1.5", decimals: 2,
                             source: L("BrainSignals.groomDrive — from the DNg11 rate", "BrainSignals.groomDrive — DNg11 발화율에서 계산"),
                             meaning: L("Grooming command sent to the body. ", "몸에 보낸 몸 손질 명령입니다. ") + modelNote,
                             read: signal { $0.brainGroomDrive }),
            ActivityCardSpec(id: .sleep, kind: .modelIndex,
                             title: L("Sleep gate", "수면 상태 스위치"), unit: L("on/off", "켬/끔"), decimals: 0,
                             source: L("BrainSignals.sleep — circadian curve and user idle time",
                                       "BrainSignals.sleep — 하루 주기 곡선과 사용자 입력 없는 시간으로 켜짐"),
                             meaning: L("A behaviour-model switch, not a measured fatigue or need for rest. ",
                                        "행동 모델의 스위치이며 피로나 휴식 욕구를 잰 값이 아닙니다. ") + modelNote,
                             read: signalFlag { $0.brainSleep }),
            ActivityCardSpec(id: .gfSpike, kind: .measured,
                             title: L("Giant fiber spike", "거대 신경(GF) 발화"), unit: L("this frame", "이번 프레임"), decimals: 0,
                             source: L("BrainSignals.escape — the GF (DNp01) spiked since the previous readout",
                                       "BrainSignals.escape — 직전 읽기 이후 GF(DNp01)가 발화했는지"),
                             meaning: L("A single escape-pathway spike event in the simulation; it does not mean fear.",
                                        "시뮬레이션의 도피 경로 발화 한 번이며 공포를 뜻하지 않습니다."),
                             read: signalFlag { $0.brainEscape }),
            ActivityCardSpec(id: .populationRate, kind: .measured,
                             title: L("Whole-brain rate", "뇌 전체 평균 발화율"), unit: L("Hz/neuron", "Hz/뉴런"), decimals: 2,
                             source: L("LabTelemetry.ratePop — MetalSim population rate", "LabTelemetry.ratePop — MetalSim 전체 평균 발화율"),
                             meaning: rateNote, read: rate { $0.ratePop }),
            ActivityCardSpec(id: .loomRate, kind: .measured,
                             title: L("LC4/LPLC2 (loom)", "LC4/LPLC2 (다가옴)"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateLoom — MetalSim LC4/LPLC2 rate", "LabTelemetry.rateLoom — MetalSim LC4/LPLC2 발화율"),
                             meaning: rateNote, read: rate { $0.rateLoom }),
            ActivityCardSpec(id: .dnaLeft, kind: .measured,
                             title: L("DNa01/02 left", "DNa01/02 왼쪽"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateDNaL — MetalSim DNa left rate", "LabTelemetry.rateDNaL — MetalSim DNa 왼쪽 발화율"),
                             meaning: rateNote, read: rate { $0.rateDNaL }),
            ActivityCardSpec(id: .dnaRight, kind: .measured,
                             title: L("DNa01/02 right", "DNa01/02 오른쪽"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateDNaR — MetalSim DNa right rate", "LabTelemetry.rateDNaR — MetalSim DNa 오른쪽 발화율"),
                             meaning: rateNote, read: rate { $0.rateDNaR }),
            ActivityCardSpec(id: .mdn, kind: .measured,
                             title: L("MDN (backward)", "MDN (뒤로 걷기)"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateMDN — MetalSim MDN rate", "LabTelemetry.rateMDN — MetalSim MDN 발화율"),
                             meaning: rateNote, read: rate { $0.rateMDN }),
            ActivityCardSpec(id: .ornFoodLeft, kind: .measured,
                             title: L("Food-odour ORN left", "먹이 냄새 후각 뉴런 왼쪽"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateFoodOdorL — receptor-group rate of the FlyWire ORN food group",
                                       "LabTelemetry.rateFoodOdorL — FlyWire 먹이 냄새 후각 뉴런(ORN) 그룹 발화율"),
                             meaning: rateNote + L(" Smelling food is a sensory input, not hunger.", " 냄새를 맡는 것은 감각 입력이며 배고픔이 아닙니다."),
                             read: rate { $0.rateFoodOdorL }),
            ActivityCardSpec(id: .ornFoodRight, kind: .measured,
                             title: L("Food-odour ORN right", "먹이 냄새 후각 뉴런 오른쪽"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateFoodOdorR — receptor-group rate of the FlyWire ORN food group",
                                       "LabTelemetry.rateFoodOdorR — FlyWire 먹이 냄새 후각 뉴런(ORN) 그룹 발화율"),
                             meaning: rateNote + L(" Smelling food is a sensory input, not hunger.", " 냄새를 맡는 것은 감각 입력이며 배고픔이 아닙니다."),
                             read: rate { $0.rateFoodOdorR }),
            ActivityCardSpec(id: .sugarGRN, kind: .measured,
                             title: L("Sugar taste GRN", "당 미각 뉴런 (GRN)"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateSugarGRN — 21 identified v783 sugar GRNs (eonsystemspbc/fly-brain), sampled on alternate 32 ms windows",
                                       "LabTelemetry.rateSugarGRN — v783 당 GRN 21개(eonsystemspbc/fly-brain 출처), 32 ms 창을 번갈아 표본"),
                             meaning: rateNote + L(" Driven only while the fly's mouth touches food (modelled sugar content).",
                                                   " 파리 주둥이가 음식에 닿아 있는 동안만 모델 당 신호로 자극됩니다."),
                             read: rate { $0.rateSugarGRN }),
            ActivityCardSpec(id: .mn9, kind: .measured,
                             title: L("MN9 (proboscis motor)", "MN9 (주둥이 운동 뉴런)"), unit: "Hz", decimals: 1,
                             source: L("LabTelemetry.rateMN9 — 2 identified v783 MN9 cells, read-only",
                                       "LabTelemetry.rateMN9 — v783 MN9 2개, 읽기 전용"),
                             meaning: rateNote + L(" The body has no proboscis actuator; this is the network's response only.",
                                                   " 몸에는 주둥이 구동이 없어 네트워크 반응만 보여 줍니다."),
                             read: rate { $0.rateMN9 }),
            ActivityCardSpec(id: .hunger, kind: .unsupported,
                             title: L("Hunger", "배고픔"), unit: "", decimals: 0,
                             source: L("None — no internal energy/satiety model exists yet (planned for V11).",
                                       "없음 — 몸속 에너지·포만 상태 모델이 아직 없습니다 (V11 예정)."),
                             meaning: L("Not modelled. No value is estimated from odour or any other signal.",
                                        "아직 모델이 없습니다. 냄새나 다른 신호로 대신 추정하지 않습니다."),
                             read: { _ in .unsupported }),
        ]
    }
}

/// One card: title, value with unit, and its classification. Clicking selects it.
final class ActivityCardView: NSView {
    let spec: ActivityCardSpec
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let unitLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private(set) var displayedValue: ActivityCardValue = .missing
    var onPress: ((ActivityCardView) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    var valueText: String { valueLabel.stringValue }

    init(spec: ActivityCardSpec) {
        self.spec = spec
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.stringValue = spec.title
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        unitLabel.stringValue = spec.unit
        unitLabel.font = .systemFont(ofSize: 10)
        unitLabel.textColor = .secondaryLabelColor
        kindLabel.stringValue = spec.kind.label
        kindLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        kindLabel.textColor = spec.kind.color
        kindLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, kindLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let valueRow = NSStackView(views: [valueLabel, unitLabel])
        valueRow.orientation = .horizontal
        valueRow.alignment = .firstBaseline
        valueRow.spacing = 4
        let stack = NSStackView(views: [titleLabel, valueRow, kindLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        toolTip = spec.source + "\n" + spec.meaning
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(spec.title)
        show(.missing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ value: ActivityCardValue) {
        displayedValue = value
        switch value {
        case .number(let v) where v.isFinite:
            valueLabel.stringValue = String(format: "%.\(spec.decimals)f", v)
        case .flag(let on):
            valueLabel.stringValue = on ? L("yes", "예") : L("no", "아니오")
        case .unsupported:
            valueLabel.stringValue = L("Unsupported", "미지원")
        case .number, .missing:
            valueLabel.stringValue = "—"
        }
        valueLabel.textColor = value == .unsupported || valueLabel.stringValue == "—"
            ? .tertiaryLabelColor : .labelColor
        setAccessibilityValue("\(valueLabel.stringValue) \(spec.unit), \(spec.kind.label)")
    }

    // The whole card is the click target; its labels never take the event.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?(self) }
    override func accessibilityPerformPress() -> Bool { onPress?(self); return true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 6
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderWidth = isSelected ? 2 : 1
            layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }
}

/// The card grid plus a detail line for the selected card.
final class ActivityCardPanel: NSStackView {
    private(set) var cards: [ActivityCardView] = []
    private(set) var selectedCard: ActivityCardID?
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    static var helpText: String {
        L("Read-only. MEASURED cards are spike rates or spike events of the simulated connectome, not recordings from a real fly. MODEL INDEX cards are the existing readouts that drive the body model. Neither reads the fly's thoughts or feelings. Hunger is not modelled yet. Clicking a card only shows its source; it never stimulates the brain or sends a command. “—” means the value is not available right now (paused, or no brain loaded).",
          "읽기 전용입니다. ‘측정값’은 시뮬레이션한 연결망의 발화율이나 발화 사건이며 실제 파리에서 잰 값이 아닙니다. ‘모델 지표’는 몸 모델을 움직이는 기존 계산값입니다. 둘 다 파리의 생각이나 감정을 읽은 것이 아닙니다. 배고픔은 아직 모델이 없습니다. 카드를 눌러도 출처만 보여 줄 뿐 뇌를 자극하거나 명령을 보내지 않습니다. ‘—’는 지금 값을 읽을 수 없다는 뜻입니다(일시 정지 또는 뇌 모델 없음).")
    }

    var detailText: String { detailLabel.stringValue }

    init(selected: ActivityCardID? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        cards = ActivityCardSpec.all.map(ActivityCardView.init(spec:))
        for card in cards { card.onPress = { [weak self] in self?.select($0.spec.id) } }
        for start in stride(from: 0, to: cards.count, by: 2) {
            var views: [NSView] = Array(cards[start..<min(start + 2, cards.count)])
            if views.count == 1 { views.append(NSView()) }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        _ = LabForm.status(detailLabel)
        addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        if let selected { select(selected) } else { showDetail() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func card(_ id: ActivityCardID) -> ActivityCardView? { cards.first { $0.spec.id == id } }

    /// Called from the Lab window's existing telemetry refresh; reads only.
    func update(_ input: ActivityCardInput) {
        for card in cards { card.show(card.spec.read(input)) }
        showDetail()
    }

    /// Presentation only: highlights the card and shows its source text.
    func select(_ id: ActivityCardID) {
        selectedCard = id
        for card in cards { card.isSelected = card.spec.id == id }
        showDetail()
    }

    private func showDetail() {
        guard let id = selectedCard, let card = card(id) else {
            detailLabel.stringValue = L("Select a card to see where its value comes from.",
                                        "카드를 누르면 그 값이 어디서 오는지 보여 줍니다.")
            return
        }
        let spec = card.spec
        let unit = spec.unit.isEmpty ? "" : " " + spec.unit
        detailLabel.stringValue = "\(spec.title) — \(spec.kind.label): \(card.valueText)\(unit)\n"
            + L("Source: ", "출처: ") + spec.source + "\n" + spec.meaning
    }
}
