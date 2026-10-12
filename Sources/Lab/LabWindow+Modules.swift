// LabWindow+Modules.swift — V8.2 "외부 모듈" section (Lab World page).
//
// Everything shown is GENERATED from installed descriptors through the pure
// `ExternalIOModuleListModel`; no module is hardcoded. Read-only: nothing is
// attached or sent in 8.2, so there is deliberately no attach button (8.3).

import Cocoa

enum ExternalModulesText {
    static var help: String {
        L("Modules found as JSON descriptors in the modules folder. A descriptor is data only — nothing in it is run. Each is checked against the external_io.v1 contract; invalid or duplicate ones are listed with the reason. Nothing is attached or sent anywhere yet, and the fly keeps using the default world.",
          "modules 폴더에서 찾은 JSON 설명 파일 목록입니다. 설명 파일은 데이터일 뿐이며 그 안의 내용은 실행되지 않습니다. 각 파일을 external_io.v1 계약으로 검사하고, 잘못되었거나 중복된 파일은 이유와 함께 표시합니다. 아직 어떤 것도 연결하거나 보내지 않으며, 파리는 기본 세계를 계속 사용합니다.")
    }

    static func lines(_ model: ExternalIOModuleListModel) -> String {
        if model.modules.isEmpty && model.rejected.isEmpty {
            return L("No external modules installed.", "설치된 외부 모듈이 없습니다.")
        }
        var out: [String] = []
        for m in model.modules {
            out.append("\(m.title)  [\(m.moduleID) v\(m.version)]  \(m.attachMode) · \(m.clockMode) · \(m.lifecycle)")
            if m.channels.isEmpty { out.append("    " + L("(no channels)", "(채널 없음)")) }
            for c in m.channels {
                out.append("    \(c.direction == "in" ? "in " : "out") \(c.name)  \(c.kind)  \(c.unit)/\(c.axis)  \(c.range)  \(c.rate)")
            }
        }
        if !model.rejected.isEmpty {
            out.append(L("Rejected:", "거부됨:"))
            for r in model.rejected { out.append("    \(r.file)" + (r.moduleID.map { " [\($0)]" } ?? "") + " — \(r.reason)") }
        }
        return out.joined(separator: "\n")
    }
}

final class ExternalModulesPanel: NSStackView {
    private let registry: ExternalIOModuleRegistry
    private let listLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var rescanButton = NSButton()
    var text: String { listLabel.stringValue }

    init(registry: ExternalIOModuleRegistry = ExternalIOModuleRegistry()) {
        self.registry = registry
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        _ = LabForm.status(listLabel, mono: true)
        listLabel.isSelectable = true
        rescanButton = NSButton(title: L("Rescan folder", "폴더 다시 검사"), target: self, action: #selector(rescan))
        rescanButton.bezelStyle = .rounded
        for v in [listLabel, LabForm.buttons([rescanButton], columns: 1),
                  LabForm.note(L("Attach: available in a later step (8.3+).", "연결: 이후 단계(8.3+)에서 제공됩니다."))] as [NSView] {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func rescan() { registry.reload(); render() }
    private func render() { listLabel.stringValue = ExternalModulesText.lines(ExternalIOModuleListModel(registry)) }
}

extension LabWindowController {
    func externalModulesSection() -> NSView {
        section(L("External modules", "외부 모듈"), help: ExternalModulesText.help, [ExternalModulesPanel()])
    }
}
