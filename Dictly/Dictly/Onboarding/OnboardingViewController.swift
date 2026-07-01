import AppKit
import Combine

/// 3-step setup checklist (handoff §5).
///
/// New aesthetic: **paper / vintage** — warm cream background, white step cards, ink text.
/// The brand orange is reserved for the icon arcs and the primary "Done" CTA, never as a
/// background fill.
@MainActor
final class OnboardingViewController: NSViewController {

    // MARK: - Accessibility step

    /// The onboarding flow always shows the Accessibility (Universal Access)
    /// permission step: auto-paste relies on the user granting Accessibility
    /// so a `CGEvent` ⌘V can be posted into the focused app. Layout, the
    /// progress counter, and `render()` all consult this flag.
    private static let showUniversalAccessStep = true

    private weak var coordinator: DictationCoordinator?
    private let onFinish: () -> Void

    // MARK: - State

    private struct SetupState: Equatable {
        var mic:   StepStatus = .pending
        var ua:    StepStatus = .pending
        var model: StepStatus = .pending
        var modelProgress: Double = 0
        var modelError: String? = nil
    }
    private enum StepStatus: Equatable { case pending, granted, loading, ready, skipped }

    private var state = SetupState()
    private var subs = Set<AnyCancellable>()
    private var axPollTimer: Timer?

    // MARK: - Views

    private let header = OnboardingHeaderView()
    // App Review (Guideline 5.1.1): the CTA preceding a system permission
    // prompt must be a neutral "Continue"/"Next" — not "Allow microphone".
    private let micStep    = OnboardingStepView(number: 1, title: "Microphone",
                                                 ctaTitle: "Continue")
    private let uaStep     = OnboardingStepView(number: 2, title: "Universal Access",
                                                 sublabel: "for auto-paste",
                                                 ctaTitle: "Open Settings")
    private let modelStep  = OnboardingStepView(number: 3, title: "Transcription model",
                                                 sublabel: "Whisper",
                                                 ctaTitle: "Download model")

    private let languagePopup = NSPopUpButton()

    private let footerLabel = NSTextField(labelWithString: "step 1 of 3")
    private let doneButton  = BrandButton(title: "Done", variant: .secondary, size: .md)
    private let paperGradient = CAGradientLayer()

    init(coordinator: DictationCoordinator, onFinish: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 790))
        root.wantsLayer = true
        root.layer?.backgroundColor = DesignTokens.paper.cgColor
        view = root

        // Vertical paper gradient (#f4ede0 → #e7dcc6) — primary onboarding background.
        paperGradient.colors = DesignTokens.paperGradientColors()
        paperGradient.startPoint = CGPoint(x: 0.5, y: 1)
        paperGradient.endPoint   = CGPoint(x: 0.5, y: 0)
        root.layer?.insertSublayer(paperGradient, at: 0)

        // Steps stack — each step expands to full body width so progress bars and CTAs align.
        let stepsStack = NSStackView()
        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.distribution = .fill
        stepsStack.spacing = 14
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        let languageRow = makeLanguageRow()
        stepsStack.addArrangedSubview(languageRow)
        stepsStack.addArrangedSubview(micStep)
        if Self.showUniversalAccessStep {
            stepsStack.addArrangedSubview(uaStep)
        }
        stepsStack.addArrangedSubview(modelStep)

        let privacyCard = makePrivacyCard()
        let footer = makeFooter()

        header.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(stepsStack)
        root.addSubview(privacyCard)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            stepsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            stepsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stepsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            privacyCard.topAnchor.constraint(equalTo: stepsStack.bottomAnchor, constant: 18),
            privacyCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            privacyCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        // IMPORTANT: only constrain steps that are actually inside `stepsStack`.
        // If the UA step is ever gated off, `uaStep` has no superview. Activating
        // a constraint between two views with no common ancestor throws
        // NSInternalInconsistencyException — on macOS 26.4 this terminates the app
        // on launch, so we only constrain steps we actually added.
        var layoutSteps: [NSView] = [languageRow, micStep]
        if Self.showUniversalAccessStep { layoutSteps.append(uaStep) }
        layoutSteps.append(modelStep)
        for step in layoutSteps {
            step.widthAnchor.constraint(equalTo: stepsStack.widthAnchor).isActive = true
        }

        wireActions()
        bindCoordinator()
        refreshFromSystem()
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        paperGradient.frame = view.bounds
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startAccessibilityPoll()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopAccessibilityPoll()
    }

    // MARK: - Language row

    /// A paper card with a language picker, shown above the setup steps so a new
    /// user explicitly chooses their spoken language up front. Defaults to the
    /// system language (see `Settings.systemDefaultLanguage`); the picker just
    /// makes it visible and changeable. Addresses GitHub #4, where a non-Russian
    /// user's speech was silently decoded with the wrong language.
    private func makeLanguageRow() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = DesignTokens.card.cgColor
        card.layer?.cornerRadius = DesignTokens.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = DesignTokens.paperBorder.cgColor

        let title = NSTextField(labelWithString: "Spoken language")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = DesignTokens.ink

        languagePopup.removeAllItems()
        for opt in LanguageOption.popular {
            languagePopup.addItem(withTitle: opt.displayName)
            languagePopup.lastItem?.representedObject = opt.code
        }
        if let idx = LanguageOption.popular.firstIndex(where: { $0.code == Settings.shared.language }) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(onboardingLanguageChanged(_:))
        languagePopup.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [title, spacer, languagePopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    @objc private func onboardingLanguageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            Settings.shared.language = code
        }
    }

    // MARK: - Privacy card

    /// White paper card sitting between the setup steps and the footer. Reassures
    /// the user that nothing leaves their Mac and signs off with a small
    /// hand-crafted tagline. Pure presentation — no state, no actions.
    private func makePrivacyCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = DesignTokens.card.cgColor
        card.layer?.cornerRadius = DesignTokens.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = DesignTokens.paperBorder.cgColor

        // Header row: lock glyph + title
        let lockHost = NSView()
        lockHost.translatesAutoresizingMaskIntoConstraints = false
        lockHost.wantsLayer = true
        lockHost.layer?.backgroundColor = DesignTokens.brand300
            .withAlphaComponent(0.18).cgColor
        lockHost.layer?.cornerRadius = 7

        let lockGlyph = NSImageView()
        lockGlyph.image = NSImage(systemSymbolName: "lock.shield.fill",
                                   accessibilityDescription: "Privacy")
        lockGlyph.contentTintColor = DesignTokens.brand500
        lockGlyph.translatesAutoresizingMaskIntoConstraints = false
        lockGlyph.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        lockHost.addSubview(lockGlyph)

        let title = NSTextField(labelWithString: "Private by design")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = DesignTokens.ink

        let headerRow = NSStackView(views: [lockHost, title])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10

        // Bullet list — concise, scannable
        let bullets = NSStackView(views: [
            makePrivacyBullet("No cloud API — your audio never leaves this Mac"),
            makePrivacyBullet("Whisper models run 100% on-device"),
            makePrivacyBullet("Zero telemetry. Zero account. Zero strings."),
        ])
        bullets.orientation = .vertical
        bullets.alignment = .leading
        bullets.spacing = 6

        let body = NSStackView(views: [headerRow, bullets])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        body.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        card.addSubview(body)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            lockHost.widthAnchor.constraint(equalToConstant: 24),
            lockHost.heightAnchor.constraint(equalToConstant: 24),
            lockGlyph.centerXAnchor.constraint(equalTo: lockHost.centerXAnchor),
            lockGlyph.centerYAnchor.constraint(equalTo: lockHost.centerYAnchor),
        ])
        return card
    }

    private func makePrivacyBullet(_ text: String) -> NSView {
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                             accessibilityDescription: nil)
        dot.contentTintColor = DesignTokens.good
        dot.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 14).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 14).isActive = true
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = DesignTokens.inkDim
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let bg = NSView()
        bg.wantsLayer = true
        // Slightly deeper paper tint at the bottom anchors the footer visually.
        bg.layer?.backgroundColor = DesignTokens.paperDeep.withAlphaComponent(0.55).cgColor

        let topBorder = NSBox()
        topBorder.boxType = .custom
        topBorder.fillColor = DesignTokens.paperBorder
        topBorder.borderColor = .clear
        topBorder.borderWidth = 0
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(topBorder)

        footerLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = DesignTokens.inkMute
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(footerLabel)
        bg.addSubview(doneButton)

        NSLayoutConstraint.activate([
            bg.heightAnchor.constraint(equalToConstant: 64),
            topBorder.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: bg.topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),
            footerLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24),
            footerLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -24),
            doneButton.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])
        return bg
    }

    private func wireActions() {
        micStep.onCTA = { [weak self] in self?.requestMic() }
        uaStep.onCTA = { [weak self] in self?.openUniversalAccess() }
        modelStep.onCTA = { [weak self] in self?.toggleModelDownload() }
        doneButton.target = self
        doneButton.action = #selector(finish(_:))
        doneButton.keyEquivalent = "\r"
    }

    private func bindCoordinator() {
        if coordinator?.isModelReady == true {
            state.model = .ready
        }
        coordinator?.phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .modelLoading(let p):
                    self.state.model = .loading
                    self.state.modelProgress = p
                    self.state.modelError = nil
                case .idle:
                    if self.coordinator?.isModelReady == true {
                        self.state.model = .ready
                        self.state.modelError = nil
                    } else if self.state.model == .loading {
                        self.state.model = .pending
                    }
                case .error(let msg):
                    if self.state.model == .loading {
                        self.state.model = .pending
                        self.state.modelError = msg
                    }
                default: break
                }
                self.render()
            }
            .store(in: &subs)
    }

    // MARK: - Accessibility polling

    private func startAccessibilityPoll() {
        stopAccessibilityPoll()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFromSystem() }
        }
        RunLoop.main.add(timer, forMode: .common)
        axPollTimer = timer
    }

    private func stopAccessibilityPoll() {
        axPollTimer?.invalidate()
        axPollTimer = nil
    }

    private func refreshFromSystem() {
        switch PermissionsChecker.microphoneStatus {
        case .authorized: state.mic = .granted
        default:          state.mic = .pending
        }
        if state.ua != .skipped {
            state.ua = PermissionsChecker.isAccessibilityGranted ? .granted : .pending
        } else if PermissionsChecker.isAccessibilityGranted {
            state.ua = .granted
        }
        render()
    }

    // MARK: - Actions

    private func requestMic() {
        Task {
            _ = await PermissionsChecker.requestMicrophone()
            self.refreshFromSystem()
        }
    }

    private func openUniversalAccess() {
        PermissionsChecker.promptAccessibilityIfNeeded()
        PermissionsChecker.openAccessibilitySettings()
    }

    private func toggleModelDownload() {
        if state.model == .loading { return }
        state.model = .loading
        state.modelProgress = 0
        render()
        Task { await coordinator?.prepareModelInBackground() }
    }

    @objc private func finish(_ sender: Any?) { onFinish() }

    // MARK: - Render

    private func render() {
        switch state.mic {
        case .granted:
            micStep.applyStatus(.granted)
            micStep.setSubtitle("Granted")
            micStep.setCTADone(title: "Microphone allowed")
        case .pending:
            micStep.applyStatus(.pending)
            micStep.setSubtitle(PermissionsChecker.microphoneStatus == .denied
                                ? "Denied — open System Settings"
                                : "Required for recording")
            // CTA must be neutral ("Continue") before the OS permission dialog —
            // App Review Guideline 5.1.1 rejects "Allow microphone"-style copy.
            micStep.setCTA(title: "Continue", variant: .brand, enabled: true)
        default: break
        }

        switch state.ua {
        case .granted:
            uaStep.applyStatus(.granted)
            uaStep.setSubtitle("Granted")
            uaStep.setCTADone(title: "Access granted")
        case .skipped:
            uaStep.applyStatus(.skipped)
            uaStep.setSubtitle("Optional · text will go to clipboard")
            uaStep.setCTA(title: "Open Settings", variant: .secondary, enabled: true)
        default:
            uaStep.applyStatus(.pending)
            uaStep.setSubtitle("Not granted — text will go to clipboard")
            uaStep.setCTA(title: "Open Settings", variant: .secondary, enabled: true)
        }

        switch state.model {
        case .ready:
            modelStep.applyStatus(.ready)
            modelStep.setSubtitle("Ready · runs locally")
            modelStep.setCTADone(title: "Model installed")
        case .loading:
            modelStep.applyStatus(.loading(progress: state.modelProgress))
            modelStep.setSubtitle(String(format: "Loading · %.0f%%", state.modelProgress * 100))
            modelStep.updateProgressFill(state.modelProgress)
            modelStep.setCTA(title: "Loading", variant: .ghost, enabled: false)
        default:
            modelStep.applyStatus(.pending)
            if let err = state.modelError {
                modelStep.setSubtitle("Failed: \(err)")
            } else if let info = ModelInfo.info(for: Settings.shared.modelID) {
                let isBundled = ModelInfo.bundledIDs.contains(info.id)
                let sizeStr = info.approximateSizeMB.map { "~\($0) MB" } ?? "downloads on use"
                modelStep.setSubtitle(isBundled
                                       ? "Bundled · \(sizeStr)"
                                       : "\(sizeStr) · downloads on use")
            } else {
                modelStep.setSubtitle("Required for offline transcription")
            }
            modelStep.setCTA(title: state.modelError == nil ? "Download model" : "Retry",
                              variant: .secondary, enabled: true)
        }

        let totalSteps = totalStepCount()
        let allDone = state.mic == .granted && state.model == .ready
        if allDone {
            footerLabel.stringValue = "all set"
            doneButton.setVariant(.brand, animated: true)
            doneButton.isEnabled = true
        } else {
            footerLabel.stringValue = "step \(nextStepNumber()) of \(totalSteps)"
            doneButton.setVariant(.secondary, animated: true)
            doneButton.isEnabled = false
        }
    }

    private func totalStepCount() -> Int {
        Self.showUniversalAccessStep ? 3 : 2
    }

    private func nextStepNumber() -> Int {
        if state.mic != .granted { return 1 }
        if Self.showUniversalAccessStep {
            if state.ua == .pending { return 2 }
            return 3
        }
        return 2
    }
}

// MARK: - Header

@MainActor
final class OnboardingHeaderView: NSView {
    private let ringedIcon = RingedIcon(iconSize: 84)
    private let h1 = NSTextField(labelWithString: "Speak. We'll write.")
    private let sub = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        ringedIcon.translatesAutoresizingMaskIntoConstraints = false

        h1.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        h1.textColor = DesignTokens.ink
        h1.alignment = .center

        sub.alignment = .center
        sub.maximumNumberOfLines = 2
        sub.lineBreakMode = .byWordWrapping
        sub.attributedStringValue = Self.subAttrString()

        let stack = NSStackView(views: [ringedIcon, h1, sub])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 12, right: 32)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 84 × 1.6 = 134 — ringedIcon's outer view sized for the ripple max scale.
            ringedIcon.widthAnchor.constraint(equalToConstant: 134),
            ringedIcon.heightAnchor.constraint(equalToConstant: 134)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func subAttrString() -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: DesignTokens.inkDim,
            .paragraphStyle: para
        ]
        let kbd: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: DesignTokens.paper,
            .backgroundColor: DesignTokens.ink,
            .baselineOffset: 1,
            .paragraphStyle: para
        ]

        // Reflect the real activation hotkey from Settings — falls back to a
        // plain "any hotkey" label if the user has cleared the binding.
        let display = Settings.shared.hotkey.displayName
        let isAssigned = !display.isEmpty && display != "—"

        let label = isAssigned ? display : "any hotkey"
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Hold ", attributes: base))
        s.append(NSAttributedString(string: " \(label) ", attributes: kbd))
        s.append(NSAttributedString(string: " anywhere on macOS to dictate.", attributes: base))
        return s
    }
}
