import Cocoa
import SceneKit

/// Standard App / Edit / Window menus: text fields need Edit for copy/paste,
/// and the key equivalents (⌘Q, ⌘W, ⌘M, ⌃⌘F) follow the platform.
func makeLabMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        main.addItem(holder)
    }
    func item(_ title: String, _ action: Selector, _ key: String,
              _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = modifiers
        return it
    }
    submenu("Virtual Fly Lab", [
        item(L("Hide Virtual Fly Lab", "Virtual Fly Lab 가리기"), #selector(NSApplication.hide(_:)), "h"),
        .separator(),
        item(L("Quit Virtual Fly Lab", "Virtual Fly Lab 종료"), #selector(NSApplication.terminate(_:)), "q")
    ])
    submenu(L("Edit", "편집"), [
        item(L("Undo", "실행 취소"), Selector(("undo:")), "z"),
        item(L("Redo", "실행 복귀"), Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item(L("Cut", "오려두기"), #selector(NSText.cut(_:)), "x"),
        item(L("Copy", "복사하기"), #selector(NSText.copy(_:)), "c"),
        item(L("Paste", "붙여넣기"), #selector(NSText.paste(_:)), "v"),
        item(L("Select All", "전체 선택"), #selector(NSText.selectAll(_:)), "a")
    ])
    submenu(L("Language", "언어"), LabLanguage.allCases.map { language in
        let it = NSMenuItem(title: language.menuTitle, action: #selector(LabLanguageMenu.choose(_:)),
                            keyEquivalent: "")
        it.target = LabLanguageMenu.shared
        it.representedObject = language.rawValue
        it.state = language == LabLanguage.current ? .on : .off
        return it
    })
    let window = [
        item(L("Minimize", "최소화"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(L("Zoom", "확대/축소"), #selector(NSWindow.performZoom(_:)), ""),
        item(L("Enter Full Screen", "전체 화면 시작"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    ]
    submenu(L("Window", "윈도우"), window)
    NSApplication.shared.windowsMenu = main.items.last?.submenu
    return main
}
