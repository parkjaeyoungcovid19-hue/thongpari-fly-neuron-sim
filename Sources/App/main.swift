import Cocoa

dispatchCLI()

let app = NSApplication.shared
if case .lab = LaunchMode.current {
    app.setActivationPolicy(.regular)
    app.mainMenu = makeLabMainMenu()
    NotificationCenter.default.addObserver(forName: .labLanguageChanged, object: nil, queue: .main) { _ in
        NSApp.mainMenu = makeLabMainMenu()
    }
} else {
    app.setActivationPolicy(.accessory)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
