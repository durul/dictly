import Cocoa

@main
enum DictlyMain {
    static func main() {
        AppDiagnostics.shared.start()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        // Hold a strong reference so the delegate isn't released before the runloop starts.
        // NSApplication only holds it weakly.
        objc_setAssociatedObject(app, &DictlyMain.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.delegate = delegate
        app.run()
    }
    private static var delegateKey: UInt8 = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    static let log = AppLogger(category: "App")

    private var menuBarController: MenuBarController?
    private var dictationCoordinator: DictationCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Self.log.notice("Application did finish launching")

        let coordinator = DictationCoordinator()
        self.dictationCoordinator = coordinator

        let menuBar = MenuBarController(coordinator: coordinator)
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onShowOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
        self.menuBarController = menuBar

        // Let the HUD anchor itself under our menu-bar icon when the user picks the
        // "top of screen" position.
        coordinator.hud.statusItemFrameProvider = { [weak menuBar] in
            menuBar?.statusItemScreenFrame()
        }

        // Always boot the coordinator (loads the bundled model in the background, starts the
        // hotkey monitor). Onboarding shows on top of that flow if needed.
        coordinator.start()

        if !Settings.shared.didCompleteOnboarding {
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.log.notice("Application will terminate")
        AppDiagnostics.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(coordinator: dictationCoordinator!)
        }
        NSApp.setActivationPolicy(.regular)
        guard let win = settingsWindowController?.window else { return }
        Self.centerOnActiveScreen(win)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(coordinator: dictationCoordinator!) { [weak self] in
                Settings.shared.didCompleteOnboarding = true
                self?.onboardingWindowController?.close()
                self?.onboardingWindowController = nil
                NSApp.setActivationPolicy(.accessory)
                self?.dictationCoordinator?.start()
            }
        }
        NSApp.setActivationPolicy(.regular)
        guard let win = onboardingWindowController?.window else { return }
        Self.centerOnActiveScreen(win)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func centerOnActiveScreen(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }
}
