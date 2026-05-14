import AppKit

/// One model in the Settings → Models list. Shows:
///   ● status dot   Title  ‹tier badge›
///                  size · notes                              [ action ] [ trash ]
///
/// The status dot reflects: active (brand) / downloaded (good) / not-downloaded (mute) /
/// downloading (brand pulsing).
@MainActor
final class ModelRowView: NSView {

    enum State {
        case notDownloaded
        case downloaded
        case active
        case downloading(progress: Double)   // pulling fresh bytes from HuggingFace
        case preparing(progress: Double)     // model is local (cache or bundle) — just warming up
        case bundled       // ships inside the .app — always available, can't delete
        case bundledActive
    }

    let model: ModelInfo

    private let dotLayer = CALayer()
    private let dotPulse = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let bundleBadge = NSTextField(labelWithString: " BUNDLED ")
    private let info  = NSTextField(labelWithString: "")
    private let actionButton: BrandButton
    private let trashButton = NSButton(title: "", target: nil, action: nil)
    private let progressTrack = CALayer()
    private let progressFill  = CAGradientLayer()
    private let progressHost  = NSView()

    var onUse: ((ModelInfo) -> Void)?
    var onDelete: ((ModelInfo) -> Void)?

    init(model: ModelInfo) {
        self.model = model
        self.actionButton = BrandButton(title: "Download", variant: .secondary, size: .sm)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // White paper-card row.
        layer?.backgroundColor = DesignTokens.card.cgColor
        layer?.cornerRadius = DesignTokens.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = DesignTokens.paperBorder.cgColor

        setupDot()
        setupLabels()
        setupProgress()
        setupTrash()
        setupLayout()
        actionButton.target = self
        actionButton.action = #selector(useTapped(_:))
        trashButton.target = self
        trashButton.action = #selector(trashTapped(_:))

        apply(.notDownloaded)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: State) {
        // Outside loading states we keep the original "size · multilingual · notes"
        // subtitle. Reset it on every transition into a non-loading state.
        switch state {
        case .downloading, .preparing: break   // subtitle handled inline below
        default: restoreInfoSubtitle()
        }

        switch state {
        case .notDownloaded:
            setDot(color: DesignTokens.inkMute, pulse: false)
            actionButton.title = "Download"
            actionButton.setVariant(.secondary, animated: false)
            actionButton.isEnabled = true
            trashButton.isHidden = true
            progressHost.isHidden = true
        case .downloaded:
            setDot(color: DesignTokens.good, pulse: false)
            actionButton.title = "Use"
            actionButton.setVariant(.brand, animated: false)
            actionButton.isEnabled = true
            trashButton.isHidden = false
            progressHost.isHidden = true
        case .active:
            setDot(color: DesignTokens.brand500, pulse: false)
            actionButton.title = "Active"
            actionButton.setVariant(.success, animated: false)
            actionButton.isEnabled = false
            trashButton.isHidden = true   // can't delete the in-use model
            progressHost.isHidden = true
        case .downloading(let p):
            setDot(color: DesignTokens.brand500, pulse: true)
            actionButton.title = "Downloading"
            actionButton.setVariant(.ghost, animated: false)
            actionButton.isEnabled = false
            trashButton.isHidden = true
            progressHost.isHidden = false
            updateProgressFill(p)
            updateDownloadingSubtitle(progress: p)
        case .preparing(let p):
            // Already on disk; just loading + prewarming. No "downloading XX MB" lie,
            // no progress bar — it'd snap from 0 to 100 in <1 s anyway.
            setDot(color: DesignTokens.brand500, pulse: true)
            actionButton.title = "Loading"
            actionButton.setVariant(.ghost, animated: false)
            actionButton.isEnabled = false
            trashButton.isHidden = true
            progressHost.isHidden = true
            info.stringValue = ModelInfo.bundledIDs.contains(model.id)
                ? "Loading bundled model…"
                : "Loading from cache…"
            _ = p   // unused — preparing has no meaningful percentage
        case .bundled:
            setDot(color: DesignTokens.good, pulse: false)
            actionButton.title = "Use"
            actionButton.setVariant(.brand, animated: false)
            actionButton.isEnabled = true
            trashButton.isHidden = true   // bundled models live in the .app, not deletable
            progressHost.isHidden = true
        case .bundledActive:
            setDot(color: DesignTokens.brand500, pulse: false)
            actionButton.title = "Active"
            actionButton.setVariant(.success, animated: false)
            actionButton.isEnabled = false
            trashButton.isHidden = true
            progressHost.isHidden = true
        }
    }

    // MARK: - Layout

    private func setupDot() {
        dotPulse.cornerRadius = 8
        dotPulse.backgroundColor = DesignTokens.brand500.cgColor
        dotPulse.opacity = 0
        dotLayer.cornerRadius = 4
        layer?.addSublayer(dotPulse)
        layer?.addSublayer(dotLayer)
    }

    private func setupLabels() {
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = DesignTokens.ink
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.usesSingleLineMode = true
        title.stringValue = model.displayName
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        badge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        badge.textColor = DesignTokens.brand500
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = DesignTokens.brand300.withAlphaComponent(0.18).cgColor
        badge.stringValue = " \(model.tier.rawValue.uppercased()) "
        badge.alignment = .center
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        bundleBadge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        bundleBadge.textColor = DesignTokens.goodInk
        bundleBadge.wantsLayer = true
        bundleBadge.layer?.cornerRadius = 4
        bundleBadge.layer?.backgroundColor = DesignTokens.good.withAlphaComponent(0.14).cgColor
        bundleBadge.alignment = .center
        bundleBadge.stringValue = " BUNDLED "
        bundleBadge.isHidden = !model.isBundled
        bundleBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        bundleBadge.setContentHuggingPriority(.required, for: .horizontal)

        info.font = NSFont.systemFont(ofSize: 11)
        info.textColor = DesignTokens.inkDim
        info.lineBreakMode = .byTruncatingTail
        info.maximumNumberOfLines = 1
        info.cell?.usesSingleLineMode = true
        info.stringValue = Self.formatSubtitle(for: model)
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// "547 MB · multilingual · Updated Sep 30, 2024 · Bundled with Dictly"
    /// Anything optional gracefully drops out.
    private static func formatSubtitle(for model: ModelInfo) -> String {
        var parts: [String] = []
        if let mb = model.approximateSizeMB { parts.append(formattedSize(mb)) }
        parts.append(model.multilingual ? "multilingual" : "English-only")
        if let date = model.lastModified {
            parts.append("Updated " + Self.dateFormatter.string(from: date))
        }
        if !model.notes.isEmpty { parts.append(model.notes) }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func setupProgress() {
        progressHost.wantsLayer = true
        progressHost.translatesAutoresizingMaskIntoConstraints = false
        progressHost.heightAnchor.constraint(equalToConstant: 3).isActive = true
        progressHost.isHidden = true
        progressTrack.backgroundColor = DesignTokens.paperBorder.cgColor
        progressTrack.cornerRadius = 1.5
        progressFill.colors = DesignTokens.brandGradientColors()
        progressFill.startPoint = CGPoint(x: 0, y: 0.5)
        progressFill.endPoint   = CGPoint(x: 1, y: 0.5)
        progressFill.cornerRadius = 1.5
        progressHost.layer?.addSublayer(progressTrack)
        progressHost.layer?.addSublayer(progressFill)
    }

    private func setupTrash() {
        trashButton.bezelStyle = .regularSquare
        trashButton.isBordered = false
        trashButton.image = NSImage(systemSymbolName: "trash",
                                     accessibilityDescription: "Delete model")
        trashButton.contentTintColor = DesignTokens.inkMute
        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        trashButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        trashButton.toolTip = "Delete from disk"
        trashButton.isHidden = true
    }

    private func setupLayout() {
        let dotHost = NSView()
        dotHost.wantsLayer = true
        dotHost.translatesAutoresizingMaskIntoConstraints = false
        dotHost.widthAnchor.constraint(equalToConstant: 18).isActive = true
        dotHost.heightAnchor.constraint(equalToConstant: 18).isActive = true
        dotPulse.frame = NSRect(x: 1, y: 1, width: 16, height: 16)
        dotLayer.frame = NSRect(x: 5, y: 5, width: 8, height: 8)
        dotHost.layer?.addSublayer(dotPulse)
        dotHost.layer?.addSublayer(dotLayer)

        let titleRow = NSStackView(views: [title, badge, bundleBadge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6
        titleRow.distribution = .fill

        // Text column lives in its own stack so titleRow + info wrap nicely. The
        // progress bar sits *outside* the column so it can span the full row width,
        // matching the row's 14 pt left padding on the right too.
        let textCol = NSStackView(views: [titleRow, info])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 4
        textCol.distribution = .fill
        textCol.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [actionButton, trashButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(dotHost)
        addSubview(textCol)
        addSubview(actions)
        addSubview(progressHost)

        NSLayoutConstraint.activate([
            dotHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dotHost.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            textCol.leadingAnchor.constraint(equalTo: dotHost.trailingAnchor, constant: 10),
            textCol.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            // Leave 14 pt at the bottom of the row for the (sometimes-visible) progress
            // bar. Stable row height prevents the whole table from jumping when a row
            // enters/leaves the downloading state.
            textCol.bottomAnchor.constraint(lessThanOrEqualTo: progressHost.topAnchor, constant: -6),
            textCol.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -12),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Progress bar — full row width minus 14 pt margins on each side (matches
            // the row's left padding to the dot indicator).
            progressHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progressHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    override func layout() {
        super.layout()
        progressTrack.frame = progressHost.bounds
        // progressFill width is set in updateProgressFill
    }

    private func updateProgressFill(_ progress: Double) {
        let clamped = max(0, min(1, progress))
        let target = progressHost.bounds.width * CGFloat(clamped)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(DesignTokens.easeOut)
        progressFill.frame = CGRect(x: 0, y: 0,
                                     width: target,
                                     height: progressHost.bounds.height)
        CATransaction.commit()
    }

    private func setDot(color: NSColor, pulse: Bool) {
        dotLayer.backgroundColor = color.cgColor
        let key = "row.dot.pulse"
        dotPulse.removeAnimation(forKey: key)
        if pulse {
            dotPulse.backgroundColor = color.withAlphaComponent(0.55).cgColor
            dotPulse.opacity = 1
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
            dotPulse.add(group, forKey: key)
        } else {
            dotPulse.opacity = 0
        }
    }

    static func formattedSize(_ mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024)
        }
        return "\(mb) MB"
    }

    /// While the row is downloading, replace its size/notes subtitle with a live status:
    /// "Downloading 23% · 125 MB / 547 MB" or "Loading model…" once bytes are in.
    private func updateDownloadingSubtitle(progress: Double) {
        let pct = Int((progress * 100).rounded())
        // We reserve 95–100% for the WhisperKit init step that runs after download
        // finishes. Use that to switch the subtitle so the user knows what the spinner
        // is waiting on.
        if progress < 0.95 {
            if let totalMB = model.approximateSizeMB.map(Double.init) {
                let doneMB = (totalMB * progress).rounded()
                info.stringValue = String(
                    format: "Downloading %d%% · %.0f MB / %.0f MB", pct, doneMB, totalMB
                )
            } else {
                info.stringValue = "Downloading \(pct)%"
            }
        } else {
            info.stringValue = "Loading model…"
        }
    }

    private func restoreInfoSubtitle() {
        info.stringValue = Self.formatSubtitle(for: model)
    }

    @objc private func useTapped(_ sender: Any?) { onUse?(model) }
    @objc private func trashTapped(_ sender: Any?) { onDelete?(model) }
}
