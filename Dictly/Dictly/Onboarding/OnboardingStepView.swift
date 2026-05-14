import AppKit
import QuartzCore

/// One step in the onboarding checklist (handoff §5). Rendered as a **white card on paper**
/// with a left-side status dot, title + sublabel, ink subtitle, optional progress bar, and
/// a CTA on the right edge.
@MainActor
final class OnboardingStepView: NSView {

    enum Status {
        case pending
        case granted
        case loading(progress: Double)
        case ready
        case skipped
        case error(String)
    }

    // MARK: - UI

    private let cardLayer = CALayer()
    private let cardBorder = CAShapeLayer()
    private let cardShadow = CALayer()

    private let dotHost = NSView()
    private let dotLayer = CALayer()
    private let dotPulseLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sublabelLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let progressTrack = CALayer()
    private let progressFill  = CAGradientLayer()
    private let progressHost  = NSView()
    private let cta: BrandButton

    // MARK: - Init

    private let stepNumber: Int
    private let titleText: String
    private let sublabelText: String?

    init(number: Int, title: String, sublabel: String? = nil, ctaTitle: String) {
        self.stepNumber = number
        self.titleText = title
        self.sublabelText = sublabel
        self.cta = BrandButton(title: ctaTitle, variant: .secondary, size: .sm)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        setupCard()
        setupDot()
        setupLabels()
        setupProgress()
        setupLayout()
        applyStatus(.pending)
    }

    required init?(coder: NSCoder) { fatalError() }

    var onCTA: (() -> Void)? {
        didSet {
            cta.target = self
            cta.action = #selector(ctaTapped(_:))
        }
    }

    // MARK: - Setup

    private func setupCard() {
        cardShadow.shadowColor = NSColor.black.cgColor
        cardShadow.shadowOpacity = 0.05
        cardShadow.shadowRadius = 8
        cardShadow.shadowOffset = CGSize(width: 0, height: -2)
        cardShadow.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        layer?.addSublayer(cardShadow)

        cardLayer.backgroundColor = DesignTokens.card.cgColor
        cardLayer.cornerRadius = DesignTokens.radius
        cardLayer.cornerCurve = .continuous
        layer?.addSublayer(cardLayer)

        cardBorder.fillColor = NSColor.clear.cgColor
        cardBorder.strokeColor = DesignTokens.paperBorder.cgColor
        cardBorder.lineWidth = 1
        layer?.addSublayer(cardBorder)
    }

    private func setupDot() {
        dotHost.wantsLayer = true
        dotHost.translatesAutoresizingMaskIntoConstraints = false
        dotHost.widthAnchor.constraint(equalToConstant: 18).isActive = true
        dotHost.heightAnchor.constraint(equalToConstant: 18).isActive = true

        dotPulseLayer.frame = NSRect(x: 1, y: 1, width: 16, height: 16)
        dotPulseLayer.cornerRadius = 8
        dotPulseLayer.backgroundColor = DesignTokens.brand500.cgColor
        dotPulseLayer.opacity = 0
        dotHost.layer?.addSublayer(dotPulseLayer)

        dotLayer.frame = NSRect(x: 5, y: 5, width: 8, height: 8)
        dotLayer.cornerRadius = 4
        dotHost.layer?.addSublayer(dotLayer)
    }

    private func setupLabels() {
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = DesignTokens.ink

        sublabelLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        sublabelLabel.textColor = DesignTokens.inkMute

        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = DesignTokens.inkDim
        subtitleLabel.lineBreakMode = .byTruncatingTail
    }

    private func setupProgress() {
        progressHost.wantsLayer = true
        progressHost.translatesAutoresizingMaskIntoConstraints = false
        progressHost.heightAnchor.constraint(equalToConstant: 4).isActive = true
        progressHost.isHidden = true

        progressTrack.backgroundColor = DesignTokens.paperBorder.cgColor
        progressTrack.cornerRadius = 2
        progressHost.layer?.addSublayer(progressTrack)

        progressFill.colors = DesignTokens.brandGradientColors()
        progressFill.startPoint = CGPoint(x: 0, y: 0.5)
        progressFill.endPoint   = CGPoint(x: 1, y: 0.5)
        progressFill.cornerRadius = 2
        progressHost.layer?.addSublayer(progressFill)
    }

    override func layout() {
        super.layout()
        let b = bounds
        cardLayer.frame = b
        cardShadow.frame = b
        cardShadow.shadowPath = CGPath(roundedRect: b,
                                       cornerWidth: DesignTokens.radius,
                                       cornerHeight: DesignTokens.radius,
                                       transform: nil)
        cardBorder.path = CGPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
                                 cornerWidth: DesignTokens.radius,
                                 cornerHeight: DesignTokens.radius,
                                 transform: nil)
        cardBorder.frame = b
        progressTrack.frame = progressHost.bounds
    }

    private func setupLayout() {
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = "\(stepNumber). \(titleText)"
        titleRow.addArrangedSubview(titleLabel)
        if let sub = sublabelText {
            sublabelLabel.stringValue = sub
            titleRow.addArrangedSubview(sublabelLabel)
        }

        let textCol = NSStackView()
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 4
        textCol.translatesAutoresizingMaskIntoConstraints = false
        textCol.addArrangedSubview(titleRow)
        textCol.addArrangedSubview(subtitleLabel)
        textCol.addArrangedSubview(progressHost)

        let leftCol = NSStackView()
        leftCol.orientation = .horizontal
        leftCol.alignment = .top
        leftCol.spacing = 12
        leftCol.translatesAutoresizingMaskIntoConstraints = false
        leftCol.addArrangedSubview(dotHost)
        leftCol.addArrangedSubview(textCol)

        addSubview(leftCol)
        addSubview(cta)

        NSLayoutConstraint.activate([
            leftCol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            leftCol.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            leftCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            leftCol.trailingAnchor.constraint(lessThanOrEqualTo: cta.leadingAnchor, constant: -12),

            progressHost.widthAnchor.constraint(equalToConstant: 220),

            cta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cta.centerYAnchor.constraint(equalTo: leftCol.centerYAnchor)
        ])

        // Minimum height so the card has room for the CTA + text + progress.
        heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
    }

    // MARK: - State

    func applyStatus(_ status: Status) {
        switch status {
        case .pending:
            setDot(color: DesignTokens.danger, pulse: false)
            subtitleLabel.stringValue = ""
            subtitleLabel.textColor = DesignTokens.inkDim
            progressHost.isHidden = true
        case .granted, .ready:
            setDot(color: DesignTokens.good, pulse: false)
            subtitleLabel.stringValue = ""
            subtitleLabel.textColor = DesignTokens.inkDim
            progressHost.isHidden = true
        case .loading(let progress):
            setDot(color: DesignTokens.brand500, pulse: true)
            progressHost.isHidden = false
            updateProgressFill(progress)
        case .skipped:
            setDot(color: DesignTokens.inkMute, pulse: false)
            subtitleLabel.textColor = DesignTokens.inkDim
            progressHost.isHidden = true
        case .error:
            setDot(color: DesignTokens.danger, pulse: false)
            subtitleLabel.textColor = DesignTokens.danger
            progressHost.isHidden = true
        }
    }

    func setSubtitle(_ text: String) {
        subtitleLabel.stringValue = text.isEmpty ? "" : "· \(text)"
    }

    func updateProgressFill(_ progress: Double) {
        let clamped = max(0, min(1, progress))
        let target = progressHost.bounds.width * CGFloat(clamped)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(DesignTokens.easeOut)
        progressFill.frame = CGRect(x: 0, y: 0, width: target, height: progressHost.bounds.height)
        CATransaction.commit()
    }

    // MARK: - CTA passthrough

    func setCTA(title: String, variant: BrandButton.Variant, enabled: Bool) {
        cta.title = title
        cta.setVariant(variant, animated: true)
        cta.isEnabled = enabled
    }

    func setCTADone(title: String) {
        cta.setDoneState(label: title)
    }

    @objc private func ctaTapped(_ sender: Any?) { onCTA?() }

    // MARK: - Dot helper

    private func setDot(color: NSColor, pulse: Bool) {
        dotLayer.backgroundColor = color.cgColor
        let key = "step.dot.pulse"
        dotPulseLayer.removeAnimation(forKey: key)
        if pulse {
            dotPulseLayer.backgroundColor = color.withAlphaComponent(0.55).cgColor
            dotPulseLayer.opacity = 1

            let group = CAAnimationGroup()
            group.duration = 1.4
            group.repeatCount = .greatestFiniteMagnitude
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.6
            scale.toValue = 1.4

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.55, 0.0]
            opacity.keyTimes = [0.0, 1.0]

            group.animations = [scale, opacity]
            dotPulseLayer.add(group, forKey: key)
        } else {
            dotPulseLayer.opacity = 0
        }
    }
}
