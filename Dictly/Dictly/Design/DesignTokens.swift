import AppKit
import QuartzCore

/// Brand design tokens — mirror of `handoff/tokens.css` (Dictly-handoff §1).
///
/// Two surface palettes:
///   - **paper** — warm cream for onboarding / settings / web. Ink for text.
///   - **dark** — neutral grays for HUD and menu bar overlays. Light text.
///
/// Brand orange-yellow gradient is reserved for primary CTAs, the wordmark "i", and
/// icon arcs — never bathe a whole surface in it.
@MainActor
enum DesignTokens {

    // MARK: - Dark surfaces (HUD, dark chrome)

    static let surface         = NSColor(srgbRed: 0x22/255, green: 0x24/255, blue: 0x28/255, alpha: 1)
    static let surfaceLight    = NSColor(srgbRed: 0x2A/255, green: 0x2C/255, blue: 0x30/255, alpha: 1)
    static let surfaceLighter  = NSColor(srgbRed: 0x32/255, green: 0x34/255, blue: 0x38/255, alpha: 1)
    static let surfaceBorder   = NSColor(srgbRed: 0x3A/255, green: 0x3C/255, blue: 0x40/255, alpha: 1)

    // MARK: - Paper (onboarding, settings, web)

    static let paper           = NSColor(srgbRed: 0xF4/255, green: 0xED/255, blue: 0xE0/255, alpha: 1)
    static let paperDeep       = NSColor(srgbRed: 0xE7/255, green: 0xDC/255, blue: 0xC6/255, alpha: 1)
    static let paperBorder     = NSColor(srgbRed: 0xD8/255, green: 0xCC/255, blue: 0xB1/255, alpha: 1)

    /// Pure white card on paper — used for the onboarding step rows.
    static let card            = NSColor.white

    // MARK: - Ink (text on paper)

    static let ink             = NSColor(srgbRed: 0x22/255, green: 0x24/255, blue: 0x28/255, alpha: 1)
    static let inkDim          = NSColor(srgbRed: 0x6C/255, green: 0x6E/255, blue: 0x74/255, alpha: 1)
    static let inkMute         = NSColor(srgbRed: 0x9A/255, green: 0x9C/255, blue: 0xA2/255, alpha: 1)

    // MARK: - Text on dark

    static let text            = NSColor(srgbRed: 0xEC/255, green: 0xEC/255, blue: 0xEE/255, alpha: 1)
    static let textDim         = NSColor(srgbRed: 0x9A/255, green: 0x9C/255, blue: 0xA2/255, alpha: 1)
    static let textMute        = NSColor(srgbRed: 0x6C/255, green: 0x6E/255, blue: 0x74/255, alpha: 1)

    // MARK: - Brand

    static let brand300        = NSColor(srgbRed: 0xF7/255, green: 0xB6/255, blue: 0x4D/255, alpha: 1)
    static let brand500        = NSColor(srgbRed: 0xD3/255, green: 0x77/255, blue: 0x4D/255, alpha: 1)
    static let brandGlow       = NSColor(srgbRed: 0xD3/255, green: 0x77/255, blue: 0x4D/255, alpha: 0.35)

    // MARK: - Semantic

    static let good            = NSColor(srgbRed: 0x5B/255, green: 0xB6/255, blue: 0x7A/255, alpha: 1)
    static let goodInk         = NSColor(srgbRed: 0x3F/255, green: 0x8A/255, blue: 0x5A/255, alpha: 1)
    static let info            = NSColor(srgbRed: 0x6F/255, green: 0xA8/255, blue: 0xDC/255, alpha: 1)
    static let danger          = NSColor(srgbRed: 0xE0/255, green: 0x65/255, blue: 0x4E/255, alpha: 1)

    // MARK: - Icon-circle gradients (HUD)

    static let doneStart       = NSColor(srgbRed: 0x79/255, green: 0xD1/255, blue: 0x99/255, alpha: 1)
    static let doneEnd         = NSColor(srgbRed: 0x4F/255, green: 0xA4/255, blue: 0x6A/255, alpha: 1)
    static let recHi           = NSColor(srgbRed: 0xFF/255, green: 0xCB/255, blue: 0x73/255, alpha: 1)
    static let recLo           = NSColor(srgbRed: 0xE0/255, green: 0x65/255, blue: 0x4E/255, alpha: 1)
    static let errHi           = NSColor(srgbRed: 0xF0/255, green: 0x8A/255, blue: 0x75/255, alpha: 1)
    static let errLo           = NSColor(srgbRed: 0xE0/255, green: 0x65/255, blue: 0x4E/255, alpha: 1)

    // MARK: - Radii

    static let radiusSm: CGFloat       = 6
    static let radius:   CGFloat       = 10
    static let radiusLg: CGFloat       = 14
    static let radiusXl: CGFloat       = 18

    // MARK: - Animation timing

    /// `cubic-bezier(0.22, 1, 0.36, 1)` — refreshed ease-out (handoff §1).
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    /// `cubic-bezier(0.65, 0, 0.35, 1)` — ease-in-out.
    static let easeIn  = CAMediaTimingFunction(controlPoints: 0.65, 0.0, 0.35, 1.0)

    static let durFast: TimeInterval = 0.14
    static let durBase: TimeInterval = 0.22
    static let durSlow: TimeInterval = 0.36

    // MARK: - Helpers

    static func brandGradientColors() -> [CGColor] { [brand300.cgColor, brand500.cgColor] }
    static func recordingGradientColors() -> [CGColor] { [recHi.cgColor, recLo.cgColor] }
    static func errorGradientColors() -> [CGColor] { [errHi.cgColor, errLo.cgColor] }
    static func doneGradientColors() -> [CGColor] { [doneStart.cgColor, doneEnd.cgColor] }
    /// Vertical paper gradient — used as the onboarding/settings window background.
    static func paperGradientColors() -> [CGColor] { [paper.cgColor, paperDeep.cgColor] }
}
