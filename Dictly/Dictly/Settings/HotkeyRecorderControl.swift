import AppKit

/// `NSTextFieldCell` that vertically centers its text within the cell bounds.
/// Plain `NSTextField` anchors text to the top — that looks broken when we
/// give it an explicit 28 pt height to match an adjacent `NSButton`.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let titleSize = attributedStringValue.size()
        var titleRect = super.titleRect(forBounds: rect)
        titleRect.origin.y = rect.origin.y + (rect.size.height - titleSize.height) / 2
        titleRect.size.height = titleSize.height
        return titleRect
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

/// A single-line "click to record hotkey" control. Captures either a modifier-only press
/// (Fn / right Option / right Shift / …) or a regular keyDown combo, then commits via callback.
final class HotkeyRecorderControl: NSView {

    var combo: KeyCombo {
        didSet { updateLabel() }
    }
    var onChange: ((KeyCombo) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private var monitor: Any?
    private var flagsMonitor: Any?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var recording = false

    /// Modifier-only commits are deferred briefly so a follow-up keyDown can
    /// override them. macOS sets the `.function` flag immediately when an
    /// F-row key (or the dedicated 🎤 dictation key) is pressed, *before*
    /// the matching `keyDown` event arrives. Without the delay, the recorder
    /// commits "Fn" the instant that flagsChanged fires and the F-key
    /// keycode is never seen. The window is short enough that a deliberate
    /// solo Fn tap still feels instant.
    private var pendingSoloCombo: KeyCombo?
    private var pendingSoloTimer: Timer?
    private static let modifierCommitDelay: TimeInterval = 0.2

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Label styled as a paper-tinted text field that visually matches the height
        // and bezel of the Record button next to it.
        // Replace the default cell with a vertically-centering one so text sits in
        // the middle of the bordered pill rather than hugging the top edge.
        let centeringCell = VerticallyCenteredTextFieldCell(textCell: "")
        centeringCell.isBezeled = false
        centeringCell.isEditable = false
        centeringCell.isSelectable = false
        centeringCell.usesSingleLineMode = true
        centeringCell.lineBreakMode = .byTruncatingTail
        centeringCell.alignment = .center
        label.cell = centeringCell
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = DesignTokens.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.borderWidth = 1
        label.layer?.borderColor = DesignTokens.paperBorder.cgColor
        // No fill behind the text — `NSTextField`'s bg is a square rect that would
        // bleed past the rounded border. The layer-level border alone gives the pill
        // its shape, against the parent paper.
        label.drawsBackground = false
        label.backgroundColor = .clear
        addSubview(label)

        recordButton.target = self
        recordButton.action = #selector(toggleRecording(_:))
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.bezelStyle = .rounded
        addSubview(recordButton)

        // Match Record's bezel height exactly. NSButton.rounded reports an intrinsic
        // height of about 21 pt on modern macOS; the label, when its height is just
        // tied via `equalTo:` against an Auto Layout-driven button, sometimes ends up
        // shorter because of intrinsic-content priorities. Pinning both to a constant
        // sidesteps that completely.
        let controlHeight: CGFloat = 28
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: controlHeight),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            recordButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            recordButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            recordButton.heightAnchor.constraint(equalToConstant: controlHeight),

            heightAnchor.constraint(equalToConstant: controlHeight)
        ])
        // Lower the label's resistance to the Auto Layout system so our explicit
        // height is what wins, not its tiny intrinsic text-only size.
        label.setContentHuggingPriority(.defaultLow, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        pendingSoloTimer?.invalidate()
    }

    private func updateLabel() {
        label.stringValue = recording ? "Press a key…" : combo.displayName
    }

    @objc private func toggleRecording(_ sender: Any?) {
        recording.toggle()
        recordButton.title = recording ? "Cancel" : "Record"
        updateLabel()
        if recording { startMonitors() } else { stopMonitors() }
    }

    private func startMonitors() {
        lastFlags = []
        cancelPendingSolo()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Allow Esc to cancel.
            if event.keyCode == 53 && mods.isEmpty {
                self.cancel()
                return nil
            }
            // A keyDown wins over a pending modifier-only commit: F-row keys
            // and the dictation key emit `.function` via flagsChanged just
            // before their keyDown lands. Discarding the pending Fn lets the
            // F-key keycode become the actual binding.
            self.cancelPendingSolo()
            self.commit(.combo(keyCode: event.keyCode, modifiers: mods))
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            let now = event.modifierFlags
            let previous = self.lastFlags
            let solo = Self.detectSolo(previous: previous, current: now, event: event)
            self.lastFlags = now

            if let solo {
                // Don't commit yet — a keyDown may follow within
                // `modifierCommitDelay` and supersede this. The timer fires
                // the commit if no keyDown arrives in time.
                self.armPendingSolo(KeyCombo(kind: .modifierOnly, solo: solo, keyCode: nil, modifierFlags: 0))
                return nil
            }

            // No new modifier added — typically a release. If a solo is
            // pending and the modifier-set just shrank, the user tapped the
            // modifier on its own; commit immediately so the binding feels
            // snappy rather than waiting out the timer.
            if self.pendingSoloCombo != nil && now.rawValue < previous.rawValue {
                self.firePendingSoloNow()
                return nil
            }
            return event
        }
    }

    private func stopMonitors() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }

    private func armPendingSolo(_ combo: KeyCombo) {
        pendingSoloCombo = combo
        pendingSoloTimer?.invalidate()
        pendingSoloTimer = Timer.scheduledTimer(withTimeInterval: Self.modifierCommitDelay,
                                                 repeats: false) { [weak self] _ in
            self?.firePendingSoloNow()
        }
    }

    private func firePendingSoloNow() {
        guard let pending = pendingSoloCombo else { return }
        cancelPendingSolo()
        commit(pending)
    }

    private func cancelPendingSolo() {
        pendingSoloCombo = nil
        pendingSoloTimer?.invalidate()
        pendingSoloTimer = nil
    }

    private func cancel() {
        recording = false
        recordButton.title = "Record"
        stopMonitors()
        cancelPendingSolo()
        updateLabel()
    }

    private func commit(_ newCombo: KeyCombo) {
        recording = false
        recordButton.title = "Record"
        stopMonitors()
        cancelPendingSolo()
        combo = newCombo
        onChange?(newCombo)
    }

    private static func detectSolo(previous: NSEvent.ModifierFlags,
                                   current: NSEvent.ModifierFlags,
                                   event: NSEvent) -> KeyCombo.SoloModifier? {
        // Use raw bits to distinguish left/right.
        let raw = event.modifierFlags.rawValue
        let prevRaw = previous.rawValue
        let added = raw & ~prevRaw

        if current.contains(.function) && !previous.contains(.function) {
            return .fn
        }
        if added & 0x00000001 != 0 { return .leftControl }
        if added & 0x00000004 != 0 { return .rightShift }
        if added & 0x00000010 != 0 { return .rightCommand }
        if added & 0x00000020 != 0 { return .leftOption }
        if added & 0x00000040 != 0 { return .rightOption }
        if added & 0x00002000 != 0 { return .rightControl }
        return nil
    }
}
