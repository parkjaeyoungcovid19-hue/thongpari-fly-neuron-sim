import Cocoa

extension NSToolbarItem.Identifier {
    static let labMode = NSToolbarItem.Identifier("lab.mode")
    static let labRun = NSToolbarItem.Identifier("lab.run")
    static let labRecord = NSToolbarItem.Identifier("lab.record")
    static let labLanguage = NSToolbarItem.Identifier("lab.language")
}

extension LabWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator,
                                                 .labMode, .flexibleSpace, .labRun, .labRecord, .labLanguage]
        if #available(macOS 14.0, *) { items += [.inspectorTrackingSeparator, .toggleInspector] }
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .labMode:
            item.view = viewModeControl
            item.label = L("Mode", "방식")
            item.toolTip = L("Observe moves only the camera; Participate puts a controllable body in the world", "관찰은 카메라만 움직이고, 참여는 조종할 수 있는 몸을 세계에 넣습니다")
        case .labRun:
            item.view = runButton
            item.label = L("Pause / Resume", "일시 정지 / 재개")
        case .labLanguage:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for language in LabLanguage.allCases {
                popup.addItem(withTitle: language.menuTitle)
                popup.lastItem?.representedObject = language.rawValue
            }
            selectPopupValue(popup, LabLanguage.current.rawValue)
            popup.bezelStyle = .texturedRounded
            popup.target = self
            popup.action = #selector(languagePicked(_:))
            popup.setAccessibilityLabel(L("Interface language", "화면 언어"))
            item.view = popup
            item.label = L("Language", "언어")
            item.toolTip = L("Interface language — English or Korean", "화면 언어 — 영어 또는 한국어")
        case .labRecord:
            item.view = recordButton
            item.label = L("Record", "기록")
        default:
            return nil
        }
        return item
    }
}
