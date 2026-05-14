import AppKit

/// Owns the floating "Wispr-style" pill that surfaces recording / transcribing / done state.
/// Positioning, lifetime, and entrance/exit animation; the visual is in [RecordingHUDView].
@MainActor
final class RecordingHUDController {

    /// HUD states (handoff §4 colour matrix).
    enum State {
        case recording                   // pulse, live wave
        case transcribing                // brand grad, breathe wave + spinner ring
        case inserted(words: Int, app: String?)
        case copiedToClipboard
        case needsAccessibility
        case error(String)
    }

    private static let hudSize = NSSize(width: 320, height: 52)

    private var window: HUDPanel?
    private var hudView: RecordingHUDView?
    private var hideTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    /// Set by `AppDelegate` after the menu-bar status item is installed. Returns the
    /// status item's window frame (in screen coords) — used to anchor the HUD under
    /// our icon when the user picks "top" position in Settings.
    var statusItemFrameProvider: (() -> NSRect?)?

    func show(state: State) {
        ensureWindow()
        place()

        switch state {
        case .recording:
            recordingStartedAt = Date()
            startElapsedTimer()
        default:
            stopElapsedTimer()
            recordingStartedAt = nil
        }

        hudView?.apply(state: state)
        if window?.isVisible != true {
            animateIn()
        }
        hideTask?.cancel()
    }

    func update(level: Float) {
        hudView?.pushLevel(level)
    }

    func hide(animated: Bool = true) {
        guard let window, window.isVisible else { return }
        if animated {
            animateOut { [window] in
                Task { @MainActor in window.orderOut(nil) }
            }
        } else {
            window.orderOut(nil)
        }
    }

    func hideAfter(seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.hide() }
        }
    }

    func flash(message: String) {
        show(state: .error(message))
        hideAfter(seconds: 1.4)
    }

    // MARK: - Window plumbing

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.hudSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // we draw the shadow ourselves to control color & radius
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        // Some macOS appearances paint a faint material/tint on a window's default
        // contentView even when the window itself is `.clear`. Force it to a fully
        // transparent layer-backed view so only our HUDView paints anything.
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
        }

        let view = RecordingHUDView(frame: NSRect(origin: .zero, size: Self.hudSize))
        view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(view)

        self.window = panel
        self.hudView = view
    }

    private func place() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size

        switch Settings.shared.hudPosition {
        case .bottom:
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 40
            )
            window.setFrameOrigin(origin)
        case .top:
            // Try to anchor under our menu-bar icon. Fall back to top-centre if we
            // somehow don't have a status item frame yet (very early launch races).
            let menuBarBottom = visible.maxY   // visibleFrame already excludes the bar
            let centerX: CGFloat
            if let iconFrame = statusItemFrameProvider?() {
                centerX = iconFrame.midX
            } else {
                centerX = visible.midX
            }
            // Clamp so the pill stays fully on-screen even if the user has the icon
            // very close to a screen edge.
            var x = centerX - size.width / 2
            x = max(visible.minX + 8, min(visible.maxX - size.width - 8, x))
            let origin = NSPoint(
                x: x,
                y: menuBarBottom - size.height - 8
            )
            window.setFrameOrigin(origin)
        }
    }

    private func animateIn() {
        guard let window else { return }
        window.alphaValue = 0
        let target = window.frame
        var start = target
        start.origin.y -= 20
        window.setFrame(start, display: false)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.durBase
            ctx.timingFunction = DesignTokens.easeOut
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }

    private func animateOut(_ completion: @escaping @Sendable () -> Void) {
        guard let window else { completion(); return }
        let start = window.frame
        var end = start
        end.origin.y += 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = DesignTokens.easeIn
            window.animator().alphaValue = 0
            window.animator().setFrame(end, display: true)
        }, completionHandler: completion)
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let started = self.recordingStartedAt else { return }
                self.hudView?.updateRecordingElapsed(seconds: Date().timeIntervalSince(started))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

@MainActor
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
