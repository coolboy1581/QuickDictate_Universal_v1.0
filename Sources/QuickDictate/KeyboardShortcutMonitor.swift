import Cocoa
import ApplicationServices
import Carbon

// MARK: - Modifier Tap Detector (Pure, Testable State Machine)

public struct ModifierTapDetector {
    public var shortcut: ShortcutOption
    public var maxTapDurationSeconds: TimeInterval = 0.65
    public var minDebounceSeconds: TimeInterval = 0.18

    private var targetKeyDownTimestamp: TimeInterval?
    private var chordDisqualified: Bool = false
    private var lastTriggerTimestamp: TimeInterval = -10.0

    public init(shortcut: ShortcutOption = .rightOption) {
        self.shortcut = shortcut
    }

    public mutating func reset() {
        targetKeyDownTimestamp = nil
        chordDisqualified = false
    }

    /// Disqualifies any in-progress modifier tap when a regular key, mouse click, or scroll event occurs while held.
    public mutating func noteNonModifierActivity() {
        if targetKeyDownTimestamp != nil {
            chordDisqualified = true
        }
    }

    /// Processes a `.flagsChanged` event and returns `true` ONLY when a clean single tap of the configured modifier key completes on key-up.
    /// - Note on macOS Permissions:
    ///   - `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` delivers modifier flag changes (`Right Option`, `Left Option`, `Right Command`, `Fn`) on macOS without requiring Input Monitoring permission.
    ///   - However, `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` in another application requires **Input Monitoring** (`CGPreflightListenEventAccess()`) or **Accessibility** (`AXIsProcessTrusted()`) permission on macOS 10.15+.
    ///   - To ensure `Option + key` typing (such as `Option + E` or `Option + Left/Right` word navigation) does not accidentally trigger dictation even if a user has not yet granted Input Monitoring, `KeyboardShortcutMonitor` also polls `CGEventSource.keyState(.combinedSessionState, key:)` while the modifier is held down.
    public mutating func handleFlagsChanged(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval
    ) -> Bool {
        guard let targetCode = shortcut.expectedKeyCode else {
            reset()
            return false
        }

        // Check if another modifier key was pressed while our target modifier is held
        if keyCode != targetCode {
            if targetKeyDownTimestamp != nil {
                chordDisqualified = true
            }
            return false
        }

        let isTargetFlagActive = Self.isModifierActive(for: shortcut, in: modifierFlags)
        let hasOtherModifiers = Self.hasCompetingModifiers(for: shortcut, in: modifierFlags)

        if isTargetFlagActive {
            // Target modifier key pressed down
            if targetKeyDownTimestamp == nil {
                targetKeyDownTimestamp = timestamp
                chordDisqualified = hasOtherModifiers
            } else if hasOtherModifiers {
                chordDisqualified = true
            }
            return false
        } else {
            // Target modifier key released
            guard let downTime = targetKeyDownTimestamp else {
                return false
            }
            let wasDisqualified = chordDisqualified || hasOtherModifiers
            targetKeyDownTimestamp = nil
            chordDisqualified = false

            guard !wasDisqualified else {
                return false
            }

            let heldDuration = timestamp - downTime
            guard heldDuration >= 0.01 && heldDuration <= maxTapDurationSeconds else {
                return false
            }

            guard (timestamp - lastTriggerTimestamp) >= minDebounceSeconds else {
                return false
            }

            lastTriggerTimestamp = timestamp
            return true
        }
    }

    public static func isModifierActive(for shortcut: ShortcutOption, in flags: NSEvent.ModifierFlags) -> Bool {
        switch shortcut {
        case .rightOption, .leftOption:
            return flags.contains(.option)
        case .rightCommand:
            return flags.contains(.command)
        case .fnKey:
            return flags.contains(.function)
        case .disabled, .custom:
            return false
        }
    }

    public static func hasCompetingModifiers(for shortcut: ShortcutOption, in flags: NSEvent.ModifierFlags) -> Bool {
        let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let active = flags.intersection(relevantFlags)
        switch shortcut {
        case .rightOption, .leftOption:
            return !active.subtracting([.option]).isEmpty
        case .rightCommand:
            return !active.subtracting([.command]).isEmpty
        case .fnKey:
            return !active.isEmpty
        case .disabled, .custom:
            return true
        }
    }
}

// MARK: - Keyboard Shortcut Monitor Manager

public final class KeyboardShortcutMonitor {
    public static let shared = KeyboardShortcutMonitor()

    public var onToggleRequested: (() -> Void)?
    private var detector: ModifierTapDetector
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var keyChordPollTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    /// Standard non-modifier macOS virtual keycodes (`0x00`..`0x7E`, excluding modifier keycodes `54..63`).
    private static let nonModifierKeyCodes: [CGKeyCode] = (0...126).compactMap { code in
        let c = CGKeyCode(code)
        // Exclude Command (54, 55), Shift (56, 60), CapsLock (57), Option (58, 61), Control (59, 62), Fn (63)
        if (54...63).contains(c) { return nil }
        return c
    }

    public init(shortcut: ShortcutOption = .rightOption) {
        self.detector = ModifierTapDetector(shortcut: shortcut)
    }

    /// Checks whether macOS Input Monitoring / Listen Event Access (`CGPreflightListenEventAccess()`) or Accessibility (`AXIsProcessTrusted()`) is granted for global `.keyDown` chord detection.
    public static func hasGlobalKeyDownMonitoringPermission() -> Bool {
        return AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    public func updateShortcut(_ newShortcut: ShortcutOption, customCombo: KeyCombo? = nil) {
        unregisterCarbonHotKey()
        detector.shortcut = newShortcut
        detector.reset()
        stopKeyChordPollTimer()

        if newShortcut == .custom {
            let combo = customCombo ?? PreferencesManager.shared.customKeyCombo
            registerCarbonHotKey(combo: combo)
        }
    }

    public func startMonitoring() {
        stopMonitoring()

        if detector.shortcut == .custom {
            registerCarbonHotKey(combo: PreferencesManager.shared.customKeyCombo)
            return
        }

        guard detector.shortcut != .disabled else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processFlagsEvent(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.processFlagsEvent(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.detector.noteNonModifierActivity()
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.detector.noteNonModifierActivity()
            return event
        }
    }

    public func stopMonitoring() {
        stopKeyChordPollTimer()
        unregisterCarbonHotKey()

        if let m = globalFlagsMonitor {
            NSEvent.removeMonitor(m)
            globalFlagsMonitor = nil
        }
        if let m = localFlagsMonitor {
            NSEvent.removeMonitor(m)
            localFlagsMonitor = nil
        }
        if let m = globalKeyDownMonitor {
            NSEvent.removeMonitor(m)
            globalKeyDownMonitor = nil
        }
        if let m = localKeyDownMonitor {
            NSEvent.removeMonitor(m)
            localKeyDownMonitor = nil
        }
        detector.reset()
    }

    // MARK: - Carbon Global HotKey Implementation (Zero-Permission Global Shortcut)

    private func registerCarbonHotKey(combo: KeyCombo) {
        unregisterCarbonHotKey()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, theEvent, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let monitor = Unmanaged<KeyboardShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.onToggleRequested?()
            }
            return noErr
        }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, ptr, &hotKeyHandlerRef)

        var carbonMods: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: combo.modifiers)
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x51444943), id: 1) // 'QDIC'
        RegisterEventHotKey(UInt32(combo.keyCode), carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterCarbonHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let hRef = hotKeyHandlerRef {
            RemoveEventHandler(hRef)
            hotKeyHandlerRef = nil
        }
    }

    private func processFlagsEvent(_ event: NSEvent) {
        // Before evaluating flagsChanged, check if any non-modifier key or mouse button is currently pressed
        if Self.isAnyNonModifierKeyOrMousePressed() {
            detector.noteNonModifierActivity()
        }

        let isDown = ModifierTapDetector.isModifierActive(for: detector.shortcut, in: event.modifierFlags)
        if isDown {
            startKeyChordPollTimer()
        } else {
            stopKeyChordPollTimer()
        }

        if detector.handleFlagsChanged(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp
        ) {
            DispatchQueue.main.async { [weak self] in
                self?.onToggleRequested?()
            }
        }
    }

    private func startKeyChordPollTimer() {
        stopKeyChordPollTimer()
        // Poll hardware key state every 15ms during the brief window (<0.65s) while the modifier key is held down
        // so that even if Input Monitoring permission is not granted, fast Option+Key chords are reliably detected and disqualified.
        keyChordPollTimer = Timer.scheduledTimer(withTimeInterval: 0.015, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Self.isAnyNonModifierKeyOrMousePressed() {
                self.detector.noteNonModifierActivity()
                self.stopKeyChordPollTimer()
            }
        }
    }

    private func stopKeyChordPollTimer() {
        keyChordPollTimer?.invalidate()
        keyChordPollTimer = nil
    }

    private static func isAnyNonModifierKeyOrMousePressed() -> Bool {
        if NSEvent.pressedMouseButtons != 0 {
            return true
        }
        for keyCode in nonModifierKeyCodes {
            if CGEventSource.keyState(.combinedSessionState, key: keyCode) {
                return true
            }
        }
        return false
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - Safe Interactive Shortcut Recorder Session

public final class ShortcutRecorderSession {
    private var monitor: Any?
    public var onCaptured: ((KeyCombo) -> Void)?
    public var onCancelled: (() -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public func startRecording() {
        stopRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == 53 { // Escape cancels recording mode
                self.onCancelled?()
                self.stopRecording()
                return nil
            }

            let (isValid, reason) = KeyCombo.validate(keyCode: event.keyCode, flags: event.modifierFlags)
            if !isValid {
                self.onError?(reason ?? "Invalid shortcut combination.")
                return nil
            }

            let display = KeyCombo.formatDisplayString(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            let combo = KeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue, displayString: display)
            self.onCaptured?(combo)
            self.stopRecording()
            return nil
        }
    }

    public func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        stopRecording()
    }
}
