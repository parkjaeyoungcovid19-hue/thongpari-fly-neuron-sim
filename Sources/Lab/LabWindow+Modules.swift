// LabWindow+Modules.swift — V8.2 "외부 모듈" section (Lab World page).
//
// Everything shown is GENERATED from installed descriptors through the pure
// `ExternalIOModuleListModel`; no module is hardcoded. Read-only: nothing is
// attached or sent in 8.2. 8.3 adds the output owner, each module's allowed
// channels, and attach / take-output / detach buttons that drive the
// `ExternalIOSession` state machine for the fixture loopback descriptor ONLY
// (no network, no peer; the default world keeps the body unless taken).

import Cocoa

enum ExternalModulesText {
    static var help: String {
        L("Modules found as JSON descriptors in the modules folder. A descriptor is data only — nothing in it is run. Each is checked against the external_io.v1 contract; invalid or duplicate ones are listed with the reason. Nothing is sent anywhere. The fly keeps using the default world unless you explicitly attach the test loopback module and take body output (the fly then idles until you detach).",
          "modules 폴더에서 찾은 JSON 설명 파일 목록입니다. 설명 파일은 데이터일 뿐이며 그 안의 내용은 실행되지 않습니다. 각 파일을 external_io.v1 계약으로 검사하고, 잘못되었거나 중복된 파일은 이유와 함께 표시합니다. 어떤 것도 외부로 보내지 않으며, 테스트용 loopback 모듈을 직접 연결하고 몸 출력을 가져가지 않는 한 파리는 기본 세계를 계속 사용합니다(가져가면 분리할 때까지 파리는 가만히 있습니다).")
    }

    static func lines(_ model: ExternalIOModuleListModel) -> String {
        if model.modules.isEmpty && model.rejected.isEmpty {
            return L("No external modules installed.", "설치된 외부 모듈이 없습니다.")
        }
        var out: [String] = [L("Body output owner: ", "몸 출력 소유자: ") + model.outputOwner]
        if let f = model.failure { out.append(L("FAILED: ", "실패: ") + f) }
        for m in model.modules {
            out.append("\(m.title)  [\(m.moduleID) v\(m.version)]  \(m.attachMode) · \(m.clockMode) · \(m.lifecycle)" + (m.ownsOutput ? "  *output owner*" : ""))
            out.append("    " + L("allowed now: ", "현재 허용: ") + "in[\(m.allowedObservations.joined(separator: ","))] out[\(m.allowedActions.joined(separator: ","))]")
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
    private let session: ExternalIOSession
    static let testModuleID = "fixture.loopback"
    private let listLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var rescanButton = NSButton()
    private(set) var attachButton = NSButton(), takeButton = NSButton(), detachButton = NSButton()
    var text: String { listLabel.stringValue }

    init(session: ExternalIOSession) {
        self.session = session
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        _ = LabForm.status(listLabel, mono: true)
        listLabel.isSelectable = true
        rescanButton = NSButton(title: L("Rescan folder", "폴더 다시 검사"), target: self, action: #selector(rescan))
        rescanButton.bezelStyle = .rounded
        attachButton = NSButton(title: L("Attach test module", "테스트 모듈 연결"), target: self, action: #selector(attach))
        takeButton = NSButton(title: L("Take body output", "몸 출력 가져가기"), target: self, action: #selector(takeOutput))
        detachButton = NSButton(title: L("Detach", "분리"), target: self, action: #selector(detach))
        _ = LabForm.status(statusLabel)
        for v in [listLabel, LabForm.buttons([rescanButton, attachButton, takeButton, detachButton]), statusLabel,
                  LabForm.note(L("Attach buttons drive only the built-in test loopback (fixture.loopback) — no network, no real endpoint.", "연결 버튼은 내장 테스트 loopback(fixture.loopback)만 조작합니다. 네트워크·실제 연결 대상은 없습니다."))] as [NSView] {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func rescan() { run { try self.session.rescan() } }
    @objc private func attach() { run { try self.session.attach(Self.testModuleID); try self.session.transition(Self.testModuleID, to: .ready) } }
    @objc private func takeOutput() { run { try self.session.acquireOutput(Self.testModuleID) } }
    @objc private func detach() { run { try self.session.detach(Self.testModuleID) } }

    private func run(_ op: () throws -> Void) {
        do { try op(); statusLabel.stringValue = "" } catch { statusLabel.stringValue = "\(error)" }
        render()
    }
    private func render() { listLabel.stringValue = ExternalModulesText.lines(ExternalIOModuleListModel(session.registry, session: session)) }
}

extension LabWindowController {
    func externalModulesSection() -> NSView {
        section(L("External modules", "외부 모듈"), help: ExternalModulesText.help, [ExternalModulesPanel(session: coordinator.externalIO)])
    }
}
