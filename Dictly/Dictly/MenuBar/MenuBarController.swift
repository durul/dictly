import AppKit
import Combine

/// Status-bar entry point. Reflects coordinator phase as one of four brand icons
/// (handoff §3) and exposes Settings / Onboarding / About / Quit.
///
/// `idle` and `processing` ship as template images — AppKit re-tints them to follow the
/// menu-bar appearance (white on dark bar, black on light bar). `recording` (red accent
/// dot) and `disabled` (red slash) are colored, so they're set as non-template.
@MainActor
final class MenuBarController {

    private weak var coordinator: DictationCoordinator?
    private let statusItem: NSStatusItem
    private var subscriptions = Set<AnyCancellable>()
    private var processingAnimationTimer: Timer?
    private var statusMenuItem: NSMenuItem?

    var onShowSettings: (() -> Void)?
    var onShowOnboarding: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Frame of the status-item button in screen coordinates. Used by the HUD to
    /// anchor itself under the icon in "top" position mode. Returns `nil` if the item
    /// isn't on-screen yet.
    func statusItemScreenFrame() -> NSRect? {
        statusItem.button?.window?.frame
    }

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func install() {
        applyAsset(named: "MenuBar-idle", template: true)

        let menu = NSMenu()
        let status = NSMenuItem(title: "Dictly Ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)),
                                keyEquivalent: ",").configured { $0.target = self })
        menu.addItem(NSMenuItem(title: "Permissions…",
                                action: #selector(showOnboarding(_:)),
                                keyEquivalent: "").configured { $0.target = self })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About Dictly", action: #selector(about(_:)),
                                keyEquivalent: "").configured { $0.target = self })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dictly", action: #selector(quit(_:)),
                                keyEquivalent: "q").configured { $0.target = self })
        statusItem.menu = menu

        coordinator?.phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.reflect(phase: phase) }
            .store(in: &subscriptions)
    }

    private func reflect(phase: DictationCoordinator.Phase) {
        let title: String
        let asset: String
        let template: Bool
        let animateProcessing: Bool

        switch phase {
        case .idle:
            asset = "MenuBar-idle"; template = true; animateProcessing = false
            title = "Dictly Ready"
        case .modelLoading(let p):
            asset = "MenuBar-processing"; template = true; animateProcessing = true
            title = String(format: "Loading model · %.0f%%", p * 100)
        case .recording:
            asset = "MenuBar-recording"; template = false; animateProcessing = false
            title = "Listening"
        case .transcribing:
            asset = "MenuBar-processing"; template = true; animateProcessing = true
            title = "Transcribing"
        case .inserted:
            asset = "MenuBar-idle"; template = true; animateProcessing = false
            title = "Inserted"
        case .error(let msg):
            asset = "MenuBar-disabled"; template = false; animateProcessing = false
            title = "Error · \(msg)"
        }

        applyAsset(named: asset, template: template)
        statusMenuItem?.title = title

        if animateProcessing { startProcessingAnimation() } else { stopProcessingAnimation() }
    }

    private func applyAsset(named: String, template: Bool) {
        guard let button = statusItem.button else { return }
        let image = NSImage(named: named)
        image?.isTemplate = template
        button.image = image
        button.contentTintColor = nil   // template icons inherit bar color natively
    }

    /// "processing" / "loading" — pulse the icon's alpha for a sense of motion. Combines
    /// with the three-dot static glyph from `MenuBar-processing` to give a subtle
    /// "thinking…" effect without re-rendering animation frames.
    private func startProcessingAnimation() {
        guard processingAnimationTimer == nil else { return }
        let button = statusItem.button
        button?.alphaValue = 1.0
        processingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in
                guard let b = button else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    b.animator().alphaValue = b.alphaValue > 0.7 ? 0.4 : 1.0
                }
            }
        }
    }

    private func stopProcessingAnimation() {
        processingAnimationTimer?.invalidate()
        processingAnimationTimer = nil
        statusItem.button?.alphaValue = 1.0
    }

    @objc private func showSettings(_ sender: Any?) { onShowSettings?() }
    @objc private func showOnboarding(_ sender: Any?) { onShowOnboarding?() }
    @objc private func quit(_ sender: Any?) { onQuit?() }
    @objc private func about(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension NSMenuItem {
    func configured(_ block: (NSMenuItem) -> Void) -> NSMenuItem {
        block(self); return self
    }
}
