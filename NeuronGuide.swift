// NeuronGuide.swift — plain-language descriptions of the neuron populations the
// Lab can stimulate or highlight. One table feeds the Brain page menu, its
// description line, the colour legend of the 3D brain and the label shown when
// a brain cluster is clicked, so all four always say the same thing.
//
// Descriptions state the population's modeled role in this simulator (which
// readout or input it feeds), not a promise of behavior and not a claim about
// what the fly experiences.

import Cocoa

struct NeuronGroupInfo {
    /// Identifier passed to Coordinator.labStimulatePopulation; nil for
    /// legend-only rows.
    let stimulusID: String?
    /// Role slugs from the connectome manifest that belong to this row.
    let roles: [String]
    let nameEN: String
    let nameKO: String
    let whatEN: String
    let whatKO: String
    /// Overlay colour in the 3D brain (BrainView), nil when not highlighted.
    let color: NSColor?

    var name: String { L(nameEN, nameKO) }
    var what: String { L(whatEN, whatKO) }
}

enum NeuronGuide {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    static let loomColor = rgb(0.15, 0.85, 1.0)
    static let steerColor = rgb(1.0, 0.55, 0.10)
    static let feedbackColor = rgb(0.45, 0.45, 0.50)

    /// Stimulation menu order; legend rows follow the same order.
    static let groups: [NeuronGroupInfo] = [
        .init(stimulusID: "GF", roles: ["gf"],
              nameEN: "Giant Fiber (GF)", nameKO: "비상 탈출 (GF, 거대섬유)",
              whatEN: "Emergency escape: when danger looms, it fires once and launches a jump away.",
              whatKO: "위험이 닥치면 한 번에 신호를 보내 즉시 점프해 도망치게 합니다.",
              color: rgb(1.0, 0.95, 0.4)),
        .init(stimulusID: "DNa-left", roles: [],
              nameEN: "Turn left (DNa, left)", nameKO: "왼쪽으로 돌기 (DNa 왼쪽)",
              whatEN: "Steering: more activity on the left side turns the fly to the left.",
              whatKO: "방향 조종 뉴런입니다. 왼쪽이 더 활발하면 몸이 왼쪽으로 돕니다.",
              color: steerColor),
        .init(stimulusID: "DNa-right", roles: [],
              nameEN: "Turn right (DNa, right)", nameKO: "오른쪽으로 돌기 (DNa 오른쪽)",
              whatEN: "Steering: more activity on the right side turns the fly to the right.",
              whatKO: "방향 조종 뉴런입니다. 오른쪽이 더 활발하면 몸이 오른쪽으로 돕니다.",
              color: steerColor),
        .init(stimulusID: "MDN", roles: ["mdn"],
              nameEN: "Walk backward (MDN)", nameKO: "뒤로 걷기 (MDN, 문워커)",
              whatEN: "“Moonwalker” neurons: a strong burst makes the fly back up, e.g. at a dead end.",
              whatKO: "‘문워커’ 뉴런입니다. 강하게 켜지면 막다른 곳에서처럼 뒷걸음질합니다.",
              color: rgb(1.0, 0.20, 0.80)),
        .init(stimulusID: "DNp09", roles: ["dnp09"],
              nameEN: "Walk forward (DNp09)", nameKO: "앞으로 걷기 (DNp09)",
              whatEN: "Walking command: sets whether the fly walks and how fast.",
              whatKO: "걷기 명령 뉴런입니다. 걸을지 말지와 걷는 속도를 정합니다.",
              color: rgb(0.25, 1.0, 0.35)),
        .init(stimulusID: "DNg11", roles: ["dng11"],
              nameEN: "Grooming (DNg11)", nameKO: "몸 손질 (DNg11, 그루밍)",
              whatEN: "Grooming command: the urge to clean the body with the legs.",
              whatKO: "다리로 몸을 닦는 ‘손질’ 행동을 하게 하는 뉴런입니다.",
              color: rgb(0.75, 0.55, 1.0)),
        .init(stimulusID: "escW", roles: ["escw"],
              nameEN: "Escape wings (DNp02/04/11)", nameKO: "도망 날갯짓 (DNp02/04/11)",
              whatEN: "Wing effort during escape and take-off; also raises the wings under threat.",
              whatKO: "도망치거나 날아오를 때 날개를 움직이게 하는 뉴런입니다.",
              color: rgb(1.0, 0.35, 0.25)),
        .init(stimulusID: "LC4/LPLC2-left", roles: [],
              nameEN: "Looming, left eye (LC4/LPLC2)", nameKO: "다가오는 물체 감지 — 왼쪽 눈 (LC4/LPLC2)",
              whatEN: "Visual danger detector: fires when something grows quickly in the left eye.",
              whatKO: "왼쪽 눈에 무언가 빠르게 커지면(부딪힐 듯 다가오면) 반응하는 시각 뉴런입니다.",
              color: loomColor),
        .init(stimulusID: "LC4/LPLC2-right", roles: [],
              nameEN: "Looming, right eye (LC4/LPLC2)", nameKO: "다가오는 물체 감지 — 오른쪽 눈 (LC4/LPLC2)",
              whatEN: "Visual danger detector: fires when something grows quickly in the right eye.",
              whatKO: "오른쪽 눈에 무언가 빠르게 커지면 반응하는 시각 뉴런입니다.",
              color: loomColor),
        .init(stimulusID: "LC4/LPLC2", roles: ["lc4", "lplc2"],
              nameEN: "Looming, both eyes (LC4/LPLC2)", nameKO: "다가오는 물체 감지 — 양쪽 눈 (LC4/LPLC2)",
              whatEN: "Visual danger detectors of both eyes; they feed the escape neuron (GF).",
              whatKO: "양쪽 눈의 위험 감지 뉴런입니다. 비상 탈출 뉴런(GF)에 신호를 넘깁니다.",
              color: loomColor),
        .init(stimulusID: "ascend", roles: ["ascend"],
              nameEN: "Leg feedback (ascending)", nameKO: "다리 감각 (몸 → 뇌)",
              whatEN: "Carries the feel of the legs stepping from the body up to the brain.",
              whatKO: "다리가 땅을 딛는 느낌을 몸에서 뇌로 올려 보냅니다.",
              color: feedbackColor),
        .init(stimulusID: "sens", roles: ["sens"],
              nameEN: "Wind / tap (older channel)", nameKO: "바람·두드림 (예전 방식)",
              whatEN: "The older generic wind/tap input; the antenna wind groups below are the detailed version.",
              whatKO: "예전에 쓰던 단순한 바람/두드림 입력입니다. 아래 더듬이 바람 감각이 더 자세한 버전입니다.",
              color: feedbackColor),
        .init(stimulusID: "ORN-food-left", roles: [],
              nameEN: "Food smell, left (ORN)", nameKO: "먹이 냄새 — 왼쪽 (후각 뉴런 ORN)",
              whatEN: "Smell receptors on the left antenna that respond to food odour.",
              whatKO: "왼쪽 더듬이에서 먹이 냄새를 맡는 후각 뉴런입니다.",
              color: nil),
        .init(stimulusID: "ORN-food-right", roles: [],
              nameEN: "Food smell, right (ORN)", nameKO: "먹이 냄새 — 오른쪽 (후각 뉴런 ORN)",
              whatEN: "Smell receptors on the right antenna that respond to food odour.",
              whatKO: "오른쪽 더듬이에서 먹이 냄새를 맡는 후각 뉴런입니다.",
              color: nil),
        .init(stimulusID: "TRN-warm", roles: [],
              nameEN: "Warmth (TRN VP2)", nameKO: "따뜻함 감지 (TRN VP2)",
              whatEN: "Temperature receptors that respond to warming.",
              whatKO: "온도가 오르면 반응하는 온도 감각 뉴런입니다.",
              color: nil),
        .init(stimulusID: "TRN-cool", roles: [],
              nameEN: "Cold (TRN VP3a/b)", nameKO: "차가움 감지 (TRN VP3a/b)",
              whatEN: "Temperature receptors that respond to cooling.",
              whatKO: "온도가 내려가면 반응하는 온도 감각 뉴런입니다.",
              color: nil),
        .init(stimulusID: "JO-C-wind", roles: [],
              nameEN: "Antenna wind C (JO-C)", nameKO: "더듬이 바람 감지 C (JO-C)",
              whatEN: "Antenna neurons that sense steady air flow.",
              whatKO: "더듬이가 꾸준한 바람에 밀리는 것을 느끼는 뉴런입니다.",
              color: nil),
        .init(stimulusID: "JO-E-wind", roles: [],
              nameEN: "Antenna wind E (JO-E)", nameKO: "더듬이 바람 감지 E (JO-E)",
              whatEN: "Antenna neurons that sense air flow from the other direction.",
              whatKO: "더듬이가 반대 방향 바람에 밀리는 것을 느끼는 뉴런입니다.",
              color: nil),
        .init(stimulusID: "HRN-dry", roles: [],
              nameEN: "Dry air (HRN VP4)", nameKO: "건조함 감지 (HRN VP4)",
              whatEN: "Humidity receptors that respond to dry air.",
              whatKO: "공기가 건조하면 반응하는 습도 감각 뉴런입니다.",
              color: nil),
        .init(stimulusID: "HRN-moist", roles: [],
              nameEN: "Moist air (HRN VP5)", nameKO: "습함 감지 (HRN VP5)",
              whatEN: "Humidity receptors that respond to moist air.",
              whatKO: "공기가 축축하면 반응하는 습도 감각 뉴런입니다.",
              color: nil),
    ]

    static func group(stimulusID: String) -> NeuronGroupInfo? {
        groups.first { $0.stimulusID == stimulusID }
    }

    /// Short label for a clicked brain cluster, keyed by manifest role slug.
    static func clusterLabel(role: String) -> String? {
        switch role {
        case "dna01", "dna02":
            return L("Steering neurons (DNa01/02)", "방향 조종 뉴런 (DNa01/02)")
        case "lc4", "lplc2":
            return L("Looming detectors (LC4/LPLC2)", "다가오는 물체 감지 (LC4/LPLC2)")
        default:
            return groups.first { $0.roles.contains(role) }?.name
        }
    }

    /// Rows for the colour legend: one per colour that appears in the 3D brain.
    static var legend: [(color: NSColor, name: String, what: String)] {
        var rows: [(NSColor, String, String)] = []
        rows.append((rgb(1.0, 0.95, 0.4), groups[0].name, groups[0].what))
        rows.append((steerColor, L("Steering (DNa)", "방향 조종 (DNa)"),
                     L("Left/right turning; the stronger side wins.",
                       "왼쪽/오른쪽 돌기 뉴런입니다. 더 활발한 쪽으로 돕니다.")))
        for g in groups where g.color != nil && !g.roles.isEmpty
            && g.stimulusID != "GF" && g.color != feedbackColor {
            rows.append((g.color!, g.name, g.what))
        }
        rows.append((feedbackColor, L("Body feedback & wind/tap input", "몸 감각·바람/두드림 입력"),
                     L("Leg-stepping feedback and the older wind/tap input channel.",
                       "다리 딛는 느낌과 예전 방식의 바람/두드림 입력 뉴런입니다.")))
        rows.append((rgb(0.75, 0.95, 1.0), L("Flash = a spike", "반짝임 = 발화"),
                     L("A neuron sending a signal right now.",
                       "지금 막 신호를 보낸 뉴런입니다.")))
        rows.append((NSColor.tertiaryLabelColor, L("Faint dots = all other neurons", "흐린 점 = 나머지 뉴런"),
                     L("The rest of the 139,255 neurons, tinted by broad class; overall activity reads as arousal.",
                       "나머지 약 13만 9천 개 뉴런으로, 큰 분류별로 색이 다릅니다. 전체가 얼마나 활발한지가 ‘흥분도’로 쓰입니다.")))
        return rows
    }
}
