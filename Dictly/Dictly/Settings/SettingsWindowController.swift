import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {

    init(coordinator: DictationCoordinator) {
        let vc = SettingsViewController(coordinator: coordinator)
        let window = NSWindow(contentViewController: vc)
        window.title = "Dictly · Settings"
        // `.resizable` was added so users on small displays (Apple Review flagged
        // content truncation on a 1280×800 reviewer screen) can shrink the
        // window and scroll through the settings list.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DesignTokens.paper
        window.appearance = NSAppearance(named: .aqua)
        // Default content size matches the Onboarding window (790 pt) for
        // visual consistency. If the user is on a smaller display, the
        // scroll view inside takes care of overflow and the window stays
        // shrinkable via the resize handle (minSize below).
        window.setContentSize(NSSize(width: 600, height: 790))
        window.minSize = NSSize(width: 600, height: 420)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
