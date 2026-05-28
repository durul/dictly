import AppKit
import Carbon.HIToolbox

/// System-wide hotkey listener. Uses **Carbon `RegisterEventHotKey`** — the same API
/// every other macOS hotkey app uses (Alfred, Raycast, BetterTouchTool, KeyboardShortcuts,
/// Sindre Sorhus's HotKey, …). The OS itself owns the hotkey registration and calls our
/// handler, so there's no Input Monitoring / Accessibility permission to grant; the user
/// just picks a key in settings and it works.
///
/// Carbon emits both `kEventHotKeyPressed` and `kEventHotKeyReleased`, so push-to-talk
/// (hold to record / release to transcribe) is supported out of the box.
///
/// Modifier-only hotkeys (Fn alone, right Option…) aren't representable as Carbon hotkeys,
/// so for those we fall back to a `flagsChanged` event monitor.
@MainActor
final class HotkeyManager {

    private static let log = AppLogger(category: "Hotkey")

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var combo: KeyCombo = .defaultHotkey
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var modifierMonitor: Any?
    private var modifierLocalMonitor: Any?
    private var isHeld = false

    /// Registry mapping a Carbon hotkey id → its `HotkeyManager`. Carbon handlers are
    /// `@convention(c)`, so they can't capture `self`; we look it up from the id passed
    /// in the event payload.
    nonisolated(unsafe) private static var registry: [UInt32: WeakBox] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    private final class WeakBox { weak var manager: HotkeyManager?; init(_ m: HotkeyManager) { manager = m } }
    private var hotKeyID: UInt32 = 0

    /// Used to ignore the synthetic keyDown that Carbon sometimes emits before the
    /// matching keyUp — we only want one onPress per real press.
    private var awaitingRelease = false

    func update(combo: KeyCombo) {
        self.combo = combo
        isHeld = false
        awaitingRelease = false
        // Re-install with the new combo if we were already running.
        if hotKeyRef != nil || modifierMonitor != nil {
            stop()
            start()
        }
    }

    func start() {
        stop()
        switch combo.kind {
        case .keyCombo:
            installCarbonHotkey()
        case .modifierOnly:
            installModifierMonitor()
        }
        Self.log.info("HotkeyManager.start kind=\(String(describing: self.combo.kind)) combo=\(self.combo.displayName)")
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = hotKeyHandler {
            RemoveEventHandler(h)
            hotKeyHandler = nil
        }
        if hotKeyID != 0 {
            Self.registry.removeValue(forKey: hotKeyID)
            hotKeyID = 0
        }
        if let m = modifierMonitor { NSEvent.removeMonitor(m); modifierMonitor = nil }
        if let m = modifierLocalMonitor { NSEvent.removeMonitor(m); modifierLocalMonitor = nil }
        isHeld = false
        awaitingRelease = false
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = hotKeyHandler { RemoveEventHandler(h) }
        if let m = modifierMonitor { NSEvent.removeMonitor(m) }
        if let m = modifierLocalMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Carbon hotkey path

    private func installCarbonHotkey() {
        guard let keyCode = combo.keyCode else { return }

        // Generate a unique 32-bit id and remember the back-pointer.
        let id: UInt32 = {
            Self.nextID &+= 1
            return Self.nextID
        }()
        hotKeyID = id
        Self.registry[id] = WeakBox(self)

        // Translate NSEvent modifiers to Carbon's mask.
        let nsModifiers = NSEvent.ModifierFlags(rawValue: combo.modifierFlags)
        var carbonModifiers: UInt32 = 0
        if nsModifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if nsModifiers.contains(.option)  { carbonModifiers |= UInt32(optionKey) }
        if nsModifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if nsModifiers.contains(.shift)   { carbonModifiers |= UInt32(shiftKey) }

        // Install our shared handler exactly once per manager. Carbon delivers BOTH
        // press and release events for any hotkey we register.
        let signature: OSType = 0x44_43_54_4C  // "DCTL" — arbitrary 4cc unique to us
        let hkID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard regStatus == noErr, ref != nil else {
            Self.log.error("RegisterEventHotKey failed with OSStatus \(regStatus)")
            return
        }
        hotKeyRef = ref

        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            eventSpecs.count, &eventSpecs,
            nil,
            &handlerRef
        )
        guard handlerStatus == noErr else {
            Self.log.error("InstallEventHandler failed with OSStatus \(handlerStatus)")
            UnregisterEventHotKey(ref!)
            hotKeyRef = nil
            return
        }
        hotKeyHandler = handlerRef
    }

    fileprivate func dispatchCarbonEvent(kind: UInt32) {
        if Int(kind) == kEventHotKeyPressed {
            guard !isHeld else { return }
            isHeld = true
            onPress?()
        } else if Int(kind) == kEventHotKeyReleased {
            guard isHeld else { return }
            isHeld = false
            onRelease?()
        }
    }

    // MARK: - Modifier-only path
    //
    // Carbon doesn't know how to register a "modifier alone" as a hotkey, so for Fn /
    // right Option / right Shift we keep an `NSEvent` flagsChanged monitor. These don't
    // require Input Monitoring — modifier flag changes are observable by every app.

    private func installModifierMonitor() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated { self.handleModifierFlags(event: event) }
        }
        modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            self.handleModifierFlags(event: event)
            return event
        }
    }

    private func handleModifierFlags(event: NSEvent) {
        guard let solo = combo.solo else { return }
        let pressed = solo.isPressed(in: event)
        if pressed && !isHeld {
            isHeld = true
            onPress?()
        } else if !pressed && isHeld {
            isHeld = false
            onRelease?()
        }
    }

    // MARK: - Carbon → Swift bridge

    fileprivate static func lookup(id: UInt32) -> HotkeyManager? {
        registry[id]?.manager
    }
}

/// C-callable Carbon event handler. Looks up our HotkeyManager via the hotkey id, then
/// dispatches into Swift on the main actor. Carbon already delivers on the main thread
/// (we attach to `GetApplicationEventTarget`), but we hop through `DispatchQueue.main`
/// to satisfy the actor boundary cleanly.
private let carbonHotKeyHandler:
    @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus
= { _, event, _ in
    guard let event else { return noErr }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    guard status == noErr else { return status }
    let kind = GetEventKind(event)
    let id = hkID.id
    DispatchQueue.main.async {
        HotkeyManager.lookup(id: id)?.dispatchCarbonEvent(kind: kind)
    }
    return noErr
}

extension KeyCombo.SoloModifier {
    fileprivate func isPressed(in event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch self {
        case .fn:           return event.modifierFlags.contains(.function)
        case .leftControl:  return raw & 0x00000001 != 0
        case .rightShift:   return raw & 0x00000004 != 0
        case .rightCommand: return raw & 0x00000010 != 0
        case .leftOption:   return raw & 0x00000020 != 0
        case .rightOption:  return raw & 0x00000040 != 0
        case .rightControl: return raw & 0x00002000 != 0
        }
    }
}
