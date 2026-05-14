import AppKit
import QuartzCore

/// HUD pill (handoff §4): 280×52, dark vertical-gradient background with 1px border + drop
/// shadow, 32px circular icon on the left, title + sub on the right of icon, 14-bar waveform
/// pinned to the right edge.
@MainActor
final class RecordingHUDView: NSView {

    private let backgroundLayer  = CAGradientLayer()
    private let borderLayer      = CAShapeLayer()
    private let iconCircleLayer  = CAGradientLayer()
    private let iconBorderLayer  = CAShapeLayer()
    private let iconGlyphLayer   = CALayer()
    private let pulseLayer       = CALayer()
    private let waveform         = WaveformLayer()

    private let titleLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        l.textColor = DesignTokens.text
        l.alignment = .left
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        return l
    }()
    private let subLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        l.textColor = DesignTokens.textDim
        l.alignment = .left
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        return l
    }()

    private var currentState: RecordingHUDController.State = .recording

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        // Background pill — gradient fill, rounded corners, no shadow. The pill
        // alone is the entire visible HUD; nothing extends past its silhouette.
        backgroundLayer.colors = [
            NSColor(srgbRed: 0x2E/255, green: 0x30/255, blue: 0x35/255, alpha: 1).cgColor,
            NSColor(srgbRed: 0x23/255, green: 0x25/255, blue: 0x29/255, alpha: 1).cgColor
        ]
        backgroundLayer.startPoint = CGPoint(x: 0.5, y: 1)
        backgroundLayer.endPoint   = CGPoint(x: 0.5, y: 0)
        backgroundLayer.cornerRadius = DesignTokens.radiusXl
        backgroundLayer.cornerCurve = .continuous
        layer?.addSublayer(backgroundLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = DesignTokens.surfaceBorder.cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        // Icon circle — 32×32 — colours/gradient swap by state.
        iconCircleLayer.cornerRadius = 16
        iconCircleLayer.cornerCurve = .continuous
        iconCircleLayer.masksToBounds = true
        iconCircleLayer.startPoint = CGPoint(x: 0.3, y: 0.3)
        iconCircleLayer.endPoint   = CGPoint(x: 1.0, y: 1.0)
        layer?.addSublayer(iconCircleLayer)

        iconBorderLayer.fillColor = NSColor.clear.cgColor
        iconBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        iconBorderLayer.lineWidth = 1
        layer?.addSublayer(iconBorderLayer)

        // Outer pulse — only animates while recording (handoff §5.2).
        pulseLayer.cornerRadius = 16
        pulseLayer.cornerCurve = .continuous
        pulseLayer.borderWidth = 2
        pulseLayer.borderColor = DesignTokens.recLo.withAlphaComponent(0.55).cgColor
        pulseLayer.opacity = 0
        layer?.addSublayer(pulseLayer)

        // Glyph layer is overlaid on the icon circle. Set via state-specific update.
        iconGlyphLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconGlyphLayer)

        layer?.addSublayer(waveform)

        addSubview(titleLabel)
        addSubview(subLabel)

        layoutPieces()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutPieces()
    }

    private func layoutPieces() {
        let b = bounds
        backgroundLayer.frame = b
        borderLayer.path = CGPath(
            roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: DesignTokens.radiusXl,
            cornerHeight: DesignTokens.radiusXl,
            transform: nil
        )
        borderLayer.frame = b

        let circle = NSRect(x: 14, y: b.midY - 16, width: 32, height: 32)
        iconCircleLayer.frame = circle
        iconBorderLayer.frame = circle
        // Path is in iconBorderLayer's *local* coordinate space (0..32 × 0..32), not the
        // parent view's. Using parent coords here was placing the stroke off to the side.
        iconBorderLayer.path = CGPath(
            ellipseIn: CGRect(x: 0.5, y: 0.5, width: circle.width - 1, height: circle.height - 1),
            transform: nil
        )
        pulseLayer.frame = circle
        iconGlyphLayer.frame = circle

        // Wave occupies the larger half of the pill — bumped from 110→150 so it
        // reads as the dominant "live" element while the user speaks.
        let waveWidth: CGFloat = 150
        waveform.frame = NSRect(x: b.maxX - waveWidth - 14, y: 14, width: waveWidth, height: 24)

        let textX = circle.maxX + 12
        let textRight = waveform.frame.minX - 8
        // Title on top, sub below — same two-line layout for every state.
        titleLabel.frame = NSRect(x: textX, y: b.midY,
                                  width: textRight - textX,
                                  height: 16)
        subLabel.frame = NSRect(x: textX, y: b.midY - 16,
                                width: textRight - textX,
                                height: 14)
    }

    // MARK: - State

    func apply(state: RecordingHUDController.State) {
        currentState = state
        switch state {
        case .recording:
            titleLabel.stringValue = "Listening"
            subLabel.stringValue = "0:00"
            iconCircleLayer.colors = DesignTokens.recordingGradientColors()
            setGlyph(.micFilled, color: NSColor.white)
            // Live wave is green ("active / capturing OK") — distinct from the
            // red recording icon, which signals the pill itself is in record mode.
            waveform.setStyle(.live(color: DesignTokens.good))
            startPulse(true)
            applyBorder(forErrorState: false)
        case .transcribing:
            titleLabel.stringValue = "Transcribing"
            subLabel.stringValue = "Whisper · \(Self.shortModelName())"
            iconCircleLayer.colors = DesignTokens.brandGradientColors()
            setGlyph(.spinner, color: NSColor.white)
            waveform.setStyle(.breathe(color: DesignTokens.brand300))
            startPulse(false)
            applyBorder(forErrorState: false)
        case .inserted(let words, let app):
            titleLabel.stringValue = "Inserted"
            let target = app ?? "frontmost app"
            subLabel.stringValue = words > 0
                ? "\(words) word\(words == 1 ? "" : "s") · pasted to \(target)"
                : "pasted to \(target)"
            iconCircleLayer.colors = DesignTokens.doneGradientColors()
            setGlyph(.check, color: NSColor.white)
            waveform.setStyle(.staticLow(color: DesignTokens.good))
            startPulse(false)
            applyBorder(forErrorState: false)
        case .copiedToClipboard:
            titleLabel.stringValue = "Copied"
            subLabel.stringValue = "Press ⌘V to paste"
            iconCircleLayer.colors = DesignTokens.doneGradientColors()
            setGlyph(.check, color: NSColor.white)
            waveform.setStyle(.staticLow(color: DesignTokens.good))
            startPulse(false)
            applyBorder(forErrorState: false)
        case .needsAccessibility:
            titleLabel.stringValue = "Permission needed"
            subLabel.stringValue = "Allow Accessibility in Settings"
            iconCircleLayer.colors = DesignTokens.errorGradientColors()
            setGlyph(.cross, color: NSColor.white)
            waveform.setStyle(.staticLow(color: DesignTokens.danger))
            startPulse(false)
            applyBorder(forErrorState: true)
        case .error(let msg):
            titleLabel.stringValue = "Error"
            subLabel.stringValue = msg
            iconCircleLayer.colors = DesignTokens.errorGradientColors()
            setGlyph(.cross, color: NSColor.white)
            waveform.setStyle(.staticLow(color: DesignTokens.danger))
            startPulse(false)
            applyBorder(forErrorState: true)
        }
        layoutPieces()
    }

    /// Tint the pill's outer 1pt outline. Subtle paper border in normal flow,
    /// red in error / permission-denied states so the failure is unmissable.
    private func applyBorder(forErrorState isError: Bool) {
        let target: CGColor = isError
            ? DesignTokens.danger.cgColor
            : DesignTokens.surfaceBorder.cgColor
        // Animate the colour swap to soften the transition between states.
        let anim = CABasicAnimation(keyPath: "strokeColor")
        anim.fromValue = borderLayer.strokeColor
        anim.toValue = target
        anim.duration = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayer.add(anim, forKey: "stroke")
        borderLayer.strokeColor = target
        borderLayer.lineWidth = isError ? 1.5 : 1
    }

    func updateRecordingElapsed(seconds: TimeInterval) {
        guard case .recording = currentState else { return }
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        subLabel.stringValue = String(format: "%d:%02d", m, s)
    }

    func pushLevel(_ level: Float) {
        waveform.pushLive(level: CGFloat(level))
    }

    private func startPulse(_ on: Bool) {
        let key = "rec.pulse"
        if !on {
            pulseLayer.removeAnimation(forKey: key)
            pulseLayer.opacity = 0
            return
        }
        if pulseLayer.animation(forKey: key) != nil { return }
        pulseLayer.opacity = 1

        // Match handoff §5.2: 8 px outward → 1.4× of a 32 px icon. Quieter than the
        // earlier 1.6× and stays inside the icon's own region of the pill.
        let group = CAAnimationGroup()
        group.duration = 1.4
        group.repeatCount = .greatestFiniteMagnitude
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.4

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.55, 0.0]
        opacity.keyTimes = [0.0, 1.0]
        opacity.duration = 1.4

        group.animations = [scale, opacity]
        pulseLayer.add(group, forKey: key)
    }

    // MARK: - Glyphs

    private enum Glyph { case micFilled, spinner, check, cross }

    private func setGlyph(_ g: Glyph, color: NSColor) {
        let img = Self.renderGlyph(g, size: NSSize(width: 32, height: 32), color: color)
        // Spinner gets a 360° rotation animation; everything else is static.
        iconGlyphLayer.removeAnimation(forKey: "spin")
        iconGlyphLayer.transform = CATransform3DIdentity
        iconGlyphLayer.contents = img

        if case .spinner = g {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .greatestFiniteMagnitude
            iconGlyphLayer.add(spin, forKey: "spin")
        }
    }

    /// Render a 32×32 white glyph. Cached per (glyph, color) by key.
    private static var glyphCache: [String: CGImage] = [:]

    private static func renderGlyph(_ g: Glyph, size: NSSize, color: NSColor) -> CGImage? {
        let key = "\(g)-\(color.hashValue)-\(Int(size.width))"
        if let hit = glyphCache[key] { return hit }

        let img: CGImage?
        switch g {
        case .micFilled:
            img = renderSFSymbol("mic.fill", pointSize: 13, weight: .semibold,
                                 size: size, color: color)
        case .check:
            img = renderSFSymbol("checkmark", pointSize: 14, weight: .bold,
                                 size: size, color: color)
        case .cross:
            img = renderSFSymbol("xmark", pointSize: 12, weight: .semibold,
                                 size: size, color: color)
        case .spinner:
            // Custom 270° arc — SF Symbols don't have a clean spinner ring, and a
            // hand-drawn one rotates cleanly under transform.rotation.z.
            img = renderSpinnerArc(size: size, color: color)
        }
        if let img { glyphCache[key] = img }
        return img
    }

    /// Rasterises an SF Symbol into a CGImage of the given pixel size, drawing the symbol
    /// at its natural `pointSize` *centered* inside the canvas (rather than stretched to
    /// fill it). NSImage.draw(in:) defaults to scaling — without this centring trick a
    /// 13-point glyph would expand to fill all 32 points of the canvas.
    private static func renderSFSymbol(_ name: String,
                                        pointSize: CGFloat,
                                        weight: NSFont.Weight,
                                        size: NSSize,
                                        color: NSColor) -> CGImage? {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let coloredConfig = baseConfig.applying(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(coloredConfig) else { return nil }

        let scale: CGFloat = 2
        let pixelSize = NSSize(width: size.width * scale, height: size.height * scale)
        let bitmap = NSImage(size: pixelSize)
        bitmap.lockFocusFlipped(false)

        // Draw the symbol at its real intrinsic size, centered. `NSImage.size` is in
        // points → multiply by our `scale` to land in pixel space.
        let glyphPx = NSSize(width: symbol.size.width * scale,
                             height: symbol.size.height * scale)
        let centered = NSRect(
            x: (pixelSize.width - glyphPx.width) / 2,
            y: (pixelSize.height - glyphPx.height) / 2,
            width: glyphPx.width,
            height: glyphPx.height
        )
        symbol.draw(in: centered, from: .zero, operation: .sourceOver, fraction: 1.0)
        bitmap.unlockFocus()

        var rect = NSRect(origin: .zero, size: pixelSize)
        return bitmap.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func renderSpinnerArc(size: NSSize, color: NSColor) -> CGImage? {
        let scale: CGFloat = 2
        let px = Int(size.width * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: px, height: px,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(2.4)
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: 16, y: 16), radius: 8,
                   startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
        ctx.strokePath()
        return ctx.makeImage()
    }

    private static func shortModelName() -> String {
        // Settings.modelID already holds the WhisperKit variant suffix (e.g. "large-v3-turbo").
        return Settings.shared.modelID
    }
}

// MARK: - Waveform

@MainActor
final class WaveformLayer: CALayer {

    enum Style {
        case live(color: NSColor)
        case breathe(color: NSColor)
        case staticLow(color: NSColor)
    }

    /// More bars look livelier — each is thinner so we get higher visual density
    /// at the wider waveform width.
    private static let barCount = 26

    private var bars: [CAShapeLayer] = []
    /// Latest peak landed in each slot by `pushLive` — this is the "history" we
    /// scroll left every time a new audio buffer arrives. Stays at 0 while the
    /// user is silent so the bars render as a flat line of dots.
    private var targetLevels: [CGFloat] = Array(repeating: 0, count: WaveformLayer.barCount)
    /// What each bar is currently rendered at. Animated toward `targetLevels`
    /// every display tick so motion stays smooth between sparse buffer updates.
    private var displayLevels: [CGFloat] = Array(repeating: 0, count: WaveformLayer.barCount)
    /// Anything quieter than this counts as ambient noise / not yet speaking —
    /// the bars stay flat (no shimmer, fixed minimum height) instead of dancing
    /// to room hum. Calibrated against `AudioRecorder.currentLevel` which is
    /// `peak * 1.5`, so a typical silent-room reading of 0.002–0.005 stays well
    /// under this gate.
    private static let silenceGate: CGFloat = 0.05
    private var waveStyle: Style = .staticLow(color: .gray)
    private var liveColor: NSColor = .gray
    private var liveLoop: Task<Void, Never>?
    private let startTime: CFTimeInterval = CACurrentMediaTime()

    override init() {
        super.init()
        for _ in 0..<Self.barCount {
            let bar = CAShapeLayer()
            bar.fillColor = NSColor.white.withAlphaComponent(0.4).cgColor
            addSublayer(bar)
            bars.append(bar)
        }
    }

    override init(layer: Any) { super.init(layer: layer); bars = [] }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Cancel the render loop before the layer goes away.
        liveLoop?.cancel()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        redraw()
    }

    func setStyle(_ style: Style) {
        self.waveStyle = style
        let color = style.color.cgColor
        for bar in bars {
            bar.removeAllAnimations()
            bar.fillColor = color
        }
        stopLiveTimer()

        switch style {
        case .live(let c):
            liveColor = c
            // Start every recording from a clean flat line — no carry-over from
            // the previous session.
            for i in 0..<targetLevels.count {
                targetLevels[i] = 0
                displayLevels[i] = 0
            }
            startLiveTimer()
        case .staticLow:
            break
        case .breathe:
            // handoff §5.4: each bar pulses with sine, phase-shifted by index.
            for (i, bar) in bars.enumerated() {
                let anim = CABasicAnimation(keyPath: "transform.scale.y")
                anim.fromValue = 0.3
                anim.toValue = 1.0
                anim.duration = 1.1
                anim.autoreverses = true
                anim.repeatCount = .greatestFiniteMagnitude
                anim.timeOffset = -CFTimeInterval(i) * 0.08
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(anim, forKey: "breathe")
            }
        }
        redraw()
    }

    func pushLive(level: CGFloat) {
        guard case .live = waveStyle else { return }
        targetLevels.removeFirst()
        let clamped = min(max(level, 0), 1)
        // Subtract the silence gate so room ambience reads as 0; everything
        // above gets shaped with a mild γ-curve so quiet speech still moves
        // the bars meaningfully (linear scaling makes whispers invisible).
        let signal = max(0, clamped - Self.silenceGate)
        let scale = max(0.001, 1 - Self.silenceGate)
        let shaped = pow(signal / scale, 0.6)
        targetLevels.append(min(1, shaped))
    }

    // MARK: - Live render loop

    /// 30 fps tick that interpolates each bar toward the latest pushed level and
    /// adds a tiny per-bar shimmer so the waveform never looks frozen — even
    /// between sparse audio buffers (built-in mic delivers ~10/s, BT ~4/s).
    private func startLiveTimer() {
        liveLoop?.cancel()
        liveLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tickLive()
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30 fps
            }
        }
    }

    private func stopLiveTimer() {
        liveLoop?.cancel()
        liveLoop = nil
    }

    private func tickLive() {
        guard case .live = waveStyle else { return }
        // Lerp display toward target. ~0.35 per frame at 30 fps gives a fast,
        // organic catch-up without snapping.
        for i in 0..<displayLevels.count {
            let delta = targetLevels[i] - displayLevels[i]
            displayLevels[i] += delta * 0.35
        }
        redraw()
    }

    private func redraw() {
        guard bounds.width > 0, !bars.isEmpty else { return }
        let count = bars.count
        let gap: CGFloat = 2
        let totalGap = gap * CGFloat(count - 1)
        let barWidth = max(1, (bounds.width - totalGap) / CGFloat(count))
        let midY = bounds.midY
        let now = CACurrentMediaTime() - startTime

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let lvl: CGFloat
            var alpha: CGFloat = 1.0
            switch waveStyle {
            case .live:
                let base = displayLevels[i]
                // Below the silence gate the bar stays a flat 2 px dot with a
                // dim tint — no shimmer, no motion. As soon as real speech
                // arrives, shimmer + height kick in.
                if base < 0.02 {
                    lvl = 0   // `max(2, ...)` below pins the visible height
                    alpha = 0.35
                } else {
                    let shimmerAmp = 0.04 + 0.06 * base
                    let shimmer = sin(now * 5.5 + Double(i) * 0.55) * shimmerAmp
                    lvl = max(0, base + shimmer)
                    let levelBrightness = 0.45 + 0.55 * base
                    let positionBrightness = 0.85 + 0.15 * (CGFloat(i) / CGFloat(count - 1))
                    alpha = min(1, levelBrightness * positionBrightness)
                }
            case .breathe:
                lvl = 0.6 + 0.3 * sin(CGFloat(i) / CGFloat(count) * .pi)
            case .staticLow:
                lvl = 0.18 + 0.06 * sin(CGFloat(i) / 1.5)
            }
            let h = max(2, lvl * bounds.height)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            bar.path = CGPath(roundedRect: rect,
                              cornerWidth: barWidth / 2,
                              cornerHeight: barWidth / 2,
                              transform: nil)
            bar.bounds = rect
            bar.position = CGPoint(x: rect.midX, y: rect.midY)
            bar.opacity = Float(alpha)
        }
        CATransaction.commit()
    }
}

private extension WaveformLayer.Style {
    var color: NSColor {
        switch self {
        case .live(let c), .breathe(let c), .staticLow(let c): return c
        }
    }
}
