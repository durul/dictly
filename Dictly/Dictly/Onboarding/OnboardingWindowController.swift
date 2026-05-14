import AppKit

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(coordinator: DictationCoordinator, onFinish: @escaping () -> Void) {
        let vc = OnboardingViewController(coordinator: coordinator, onFinish: onFinish)
        let window = NSWindow(contentViewController: vc)
        window.title = "Welcome to Dictly"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = DesignTokens.paper
        window.isMovableByWindowBackground = true
        // Paper UI lives on the Light side of macOS — Aqua appearance keeps controls coherent.
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 460, height: 790))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
