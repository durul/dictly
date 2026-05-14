import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import OSLog

@MainActor
enum PermissionsChecker {

    private static let log = Logger(subsystem: "com.mydear.voicetotext", category: "Permissions")

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
        AXIsProcessTrusted()
    }

    static func promptAccessibilityIfNeeded() {
        let systemElement = AXUIElementCreateSystemWide()
        var dummy: AnyObject?
        _ = AXUIElementCopyAttributeValue(systemElement,
                                           kAXFocusedUIElementAttribute as CFString,
                                           &dummy)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)

        log.info("Accessibility prompt requested; trusted=\(self.isAccessibilityGranted, privacy: .public)")
    }

    static func openAccessibilitySettings() {
        promptAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

}

