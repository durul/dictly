import AppKit
import QuartzCore

/// Onboarding hero icon: the actual app icon (paper + arcs) with two flourishes:
///   - a soft drop-shadow that grounds it on the cream background,
///   - a continuous brand-orange ripple halo *shaped like the icon* (squircle).
///
/// All decorations are positioned in the layer's own coordinate space so they stay locked
/// to the icon as the parent's layout changes.
final class RingedIcon: NSView {

    private let iconView = NSImageView()
    private let shadowLayer = CALayer()
    private let rings: [CAShapeLayer]
    private let iconSize: CGFloat

    /// macOS Big-Sur squircle ratio used by the bundled app icon.
    private let cornerRatio: CGFloat = 0.2237

    init(iconSize: CGFloat = 84) {
        self.iconSize = iconSize
        self.rings = (0..<2).map { _ in CAShapeLayer() }
        super.init(frame: NSRect(x: 0, y: 0, width: iconSize * 1.6, height: iconSize * 1.6))
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        // Behind everything: ripple rings (drawn first so they sit under the icon).
        for ring in rings {
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = DesignTokens.brand500.withAlphaComponent(0.55).cgColor
            ring.lineWidth = 1.5
            layer?.addSublayer(ring)
        }

        // Soft drop-shadow layer behind the icon. Stronger than before so it actually reads
        // on the paper background; offset slightly downward to suggest light from above.
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.32
        shadowLayer.shadowRadius = 18
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        shadowLayer.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        layer?.addSublayer(shadowLayer)

        iconView.image = Self.loadAppIconImage()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let cornerRadius = iconSize * cornerRatio

        // ─── Shadow ───────────────────────────────────────────────────────────────
        // Sized exactly like the icon and positioned at the icon's frame inside the
        // parent. shadowPath uses the layer's own bounds (origin .zero), not the
        // parent's coords — that's what was placing the shadow off to the side before.
        let iconFrame = NSRect(
            x: center.x - iconSize / 2,
            y: center.y - iconSize / 2,
            width: iconSize, height: iconSize
        )
        shadowLayer.frame = iconFrame
        shadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: iconFrame.size),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // ─── Rings ───────────────────────────────────────────────────────────────
        // Each ring is a squircle tracing the icon's silhouette. Layer bounds match the
        // icon, so transform.scale 0.7→1.5 expands the squircle outward, keeping the
        // rounded-corner shape rather than morphing into a circle.
        for (i, ring) in rings.enumerated() {
            ring.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
            ring.position = center
            ring.path = CGPath(
                roundedRect: CGRect(x: 0, y: 0, width: iconSize, height: iconSize),
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )

            ring.removeAnimation(forKey: "ripple")
            let group = CAAnimationGroup()
            group.duration = 2.6
            group.repeatCount = .greatestFiniteMagnitude
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.beginTime = CACurrentMediaTime() - Double(i) * 1.3

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.85
            scale.toValue = 1.45

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, 0.55, 0.0]
            opacity.keyTimes = [0.0, 0.35, 1.0]

            group.animations = [scale, opacity]
            ring.add(group, forKey: "ripple")
        }
    }

    private static func loadAppIconImage() -> NSImage? {
        if let img = NSImage(named: "BrandIcon") { return img }
        if let img = NSImage(named: "AppIcon") { return img }
        return NSApplication.shared.applicationIconImage
    }
}
