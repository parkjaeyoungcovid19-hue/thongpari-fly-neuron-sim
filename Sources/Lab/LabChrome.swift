// LabChrome.swift — AppKit building blocks for the one-window Lab: the source
// list, inspector sections, label/control forms and button grids. Everything is
// system controls, semantic colors and Auto Layout that follows the pane width,
// so the inspector can be resized, collapsed or shown in dark mode unchanged.

import Cocoa

final class LabFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class LabDisclosureView: NSStackView {
    private let toggle = NSButton()
    private let detail: NSView

    init(title: String, detail: NSView) {
        self.detail = detail
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        toggle.title = title
        toggle.bezelStyle = .inline
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 11)
        toggle.contentTintColor = .secondaryLabelColor
        toggle.imagePosition = .imageLeading
        toggle.target = self
        toggle.action = #selector(toggleDetail)
        addArrangedSubview(toggle)
        addArrangedSubview(detail)
        detail.isHidden = true
        detail.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        updateToggle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleDetail() {
        detail.isHidden.toggle()
        updateToggle()
    }

    private func updateToggle() {
        toggle.image = NSImage(systemSymbolName: detail.isHidden ? "chevron.right" : "chevron.down",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        toggle.setAccessibilityValue(detail.isHidden ? L("Collapsed", "접힘") : L("Expanded", "펼침"))
    }
}

enum LabSection: Int, CaseIterable {
    case world, stimuli, brain, data, experiment

    var title: String {
        switch self {
        case .world: return L("World", "세계")
        case .stimuli: return L("Stimuli", "자극")
        case .brain: return L("Brain", "뇌")
        case .data: return L("Data", "데이터")
        case .experiment: return L("Experiment", "실험")
        }
    }

    var symbol: String {
        switch self {
        case .world: return "cube.transparent"
        case .stimuli: return "wind"
        case .brain: return "brain"
        case .data: return "waveform.path.ecg"
        case .experiment: return "flask"
        }
    }
}

final class LabSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((LabSection) -> Void)?
    private let table = NSTableView()

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("section")))
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .default
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(L("Lab sections", "실험실 메뉴"))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = table
        view = scroll
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    func select(_ section: LabSection) {
        loadViewIfNeeded()
        table.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { LabSection.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = LabSection.allCases[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: section.symbol,
                                              accessibilityDescription: nil) ?? NSImage())
        let text = NSTextField(labelWithString: section.title)
        for v in [icon, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = icon
        cell.textField = text
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let section = LabSection(rawValue: table.selectedRow) else { return }
        onSelect?(section)
    }
}

/// Inspector layout vocabulary. Sections are separated by hairlines rather than
/// boxed cards; forms are two-column grids (trailing labels, leading controls).
enum LabForm {
    static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        return l
    }

    static func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    /// A wrapping status/readout line whose text is set later.
    static func status(_ field: NSTextField, mono: Bool = false) -> NSTextField {
        field.font = mono ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func number(_ f: NSTextField) -> NSTextField {
        f.alignment = .right
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        f.controlSize = .regular
        f.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return f
    }

    static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 0).width = 96
        return grid
    }

    /// Buttons in rows of `columns`, each filling its cell, so long titles wrap
    /// into more rows instead of pushing the inspector wider.
    static func buttons(_ items: [NSButton], columns: Int = 2) -> NSGridView {
        var rows: [[NSView]] = []
        for start in stride(from: 0, to: items.count, by: columns) {
            var row: [NSView] = Array(items[start..<min(items.count, start + columns)])
            while row.count < columns { row.append(NSGridCell.emptyContentView) }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        for i in 0..<grid.numberOfColumns { grid.column(at: i).xPlacement = .fill }
        for b in items {
            b.controlSize = .regular
            b.setContentHuggingPriority(.defaultLow, for: .horizontal)
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            b.lineBreakMode = .byTruncatingTail
        }
        // Equal columns: every button matches the first one's width.
        for b in items.dropFirst() {
            b.widthAnchor.constraint(equalTo: items[0].widthAnchor).isActive = true
        }
        return grid
    }

    static func tag(_ kind: LabInterventionKind) -> NSTextField {
        let t = NSTextField(labelWithString: kind.title)
        t.font = .systemFont(ofSize: 10, weight: .semibold)
        t.textColor = kind.color
        t.toolTip = kind.explanation
        t.setAccessibilityLabel("\(kind.title): \(kind.explanation)")
        return t
    }
}

extension LabInterventionKind {
    var title: String {
        switch self {
        case .physical: return L("PHYSICAL", "물리")
        case .sensoryModel: return L("SENSORY MODEL", "감각 모델")
        case .directNeural: return L("DIRECT NEURAL", "뉴런 직접 자극")
        }
    }
    var color: NSColor {
        switch self {
        case .physical: return .systemBlue
        case .sensoryModel: return .systemTeal
        case .directNeural: return .systemPurple
        }
    }
    var explanation: String {
        switch self {
        case .physical: return L("Changes the MuJoCo world or body", "가상 세계나 파리 몸을 실제로 움직입니다")
        case .sensoryModel: return L("Drives modeled receptor input", "감각기관(눈·더듬이 등)에 들어가는 신호를 흉내 냅니다")
        case .directNeural: return L("Stimulates neurons directly, bypassing the senses", "감각기관을 거치지 않고 뉴런을 직접 자극합니다")
        }
    }
}

/// One inspector section: headline + optional kind tag, content, optional
/// collapsed explanation. Children are pinned to the section width.
final class LabInspectorSection: NSStackView {
    init(_ title: String, kind: LabInterventionKind? = nil, help: String? = nil, _ content: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setAccessibilityRole(.staticText)
        let header = NSStackView(views: [heading, NSView()])
        header.orientation = .horizontal
        if let kind { header.addArrangedSubview(LabForm.tag(kind)) }
        var views: [NSView] = [header]
        views += content
        if let help { views.append(LabDisclosureView(title: L("About", "설명"), detail: LabForm.note(help))) }
        for v in views {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A vertically scrolling inspector page whose sections follow the pane width.
final class LabInspectorPage: NSViewController {
    private let sections: [NSView]

    init(_ sections: [NSView]) {
        self.sections = sections
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        let document = LabFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        for (i, section) in sections.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
                stack.setCustomSpacing(0, after: line)
            }
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.alignment = .centerX
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        view = scroll
    }
}
