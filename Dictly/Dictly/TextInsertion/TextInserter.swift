import AppKit
import Carbon.HIToolbox
import OSLog

/// Inserts the recognized text into whatever app is currently focused.
///
/// MVP path: clipboard + simulated ⌘V via `CGEvent`.
/// Posting `CGEvent`s into other apps requires the user to grant **Accessibility** to Dictly
/// in System Settings → Privacy & Security → Accessibility. Without it, we still copy to the
/// clipboard and let the user paste manually (or surface the text in the HUD).
///
/// In `APP_STORE` builds the auto-paste path is compiled out: the App Store version is
/// clipboard-only to avoid review friction around Accessibility entitlements.
@MainActor
final class TextInserter {

    private static let log = Logger(subsystem: "com.mydear.voicetotext", category: "TextInsert")

    enum Outcome {
        case insertedAutomatically
        case copiedToClipboard
        case missingAccessibilityPermission
    }

    func insert(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .copiedToClipboard }

        let pasteboard = NSPasteboard.general
        let savedItems: [(NSPasteboard.PasteboardType, Data)]? = Settings.shared.restoreClipboard
            ? snapshot(pasteboard: pasteboard)
            : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if !Settings.shared.autoInsert {
            return .copiedToClipboard
        }

        #if APP_STORE
        // App Store build: never simulate paste. User pastes manually.
        return .copiedToClipboard
        #else
        guard PermissionsChecker.isAccessibilityGranted else {
            Self.log.notice("Accessibility not granted — leaving text in clipboard.")
            return .missingAccessibilityPermission
        }

        guard simulateCommandV() else {
            return .copiedToClipboard
        }

        if let savedItems {
            // Wait long enough for the focused app to consume our paste before restoring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.restore(items: savedItems, on: pasteboard)
            }
        }

        return .insertedAutomatically
        #endif
    }

    private func snapshot(pasteboard: NSPasteboard) -> [(NSPasteboard.PasteboardType, Data)] {
        guard let types = pasteboard.types else { return [] }
        return types.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
    }

    private func restore(items: [(NSPasteboard.PasteboardType, Data)], on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for (type, data) in items {
            pasteboard.setData(data, forType: type)
        }
    }

    private func simulateCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
