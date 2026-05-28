import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

@MainActor
enum PermissionsChecker {

    private static let log = AppLogger(category: "Permissions")

    // MARK: Microphone

    enum MicrophoneStatus {
        case notDetermined
        case denied
        case authorized
    }

    static var microphoneStatus: MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized:    return .authorized
        case .denied, .restricted: return .denied
        @unknown default:    return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Accessibility (auto-paste path; not applicable to App Store builds)

    static var isAccessibilityGranted: Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    static func promptAccessibilityIfNeeded(reason: String = "manual") {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)

        log.info("Accessibility prompt requested; reason=\(reason) trusted=\(trusted) bundleID=\(Bundle.main.bundleIdentifier ?? "unknown") bundlePath=\(Bundle.main.bundleURL.path) executable=\(Bundle.main.executableURL?.path ?? "unknown")")
    }

    static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security"
        ]

        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) {
                log.info("Opened Accessibility settings url=\(raw)")
                return
            }
        }

        log.error("Failed to open Accessibility settings")
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

}
