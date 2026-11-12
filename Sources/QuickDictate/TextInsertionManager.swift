import Cocoa
import ApplicationServices

// MARK: - Target Application & Window/Element Context

public struct TargetApplicationContext: Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let localizedName: String
    /// Opaque identity token for the focused window (`CGWindowID` or structural frame+role hash) captured without reading any text content.
    public let windowIdentityToken: String?
    /// Opaque identity token for the focused UI element (`CFHash` of `AXUIElementRef` + `AXRole`) captured without reading `AXValue` or text content.
    public let focusedElementToken: String?

    public init(
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        localizedName: String,
        windowIdentityToken: String? = nil,
        focusedElementToken: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
        self.windowIdentityToken = windowIdentityToken
        self.focusedElementToken = focusedElementToken
    }
}

// MARK: - Insertion Outcome

/// Note: Posting a synthetic `Cmd + V` keystroke via `CGEvent` dispatches the paste command to the active window,
/// but macOS does not provide a synchronous guarantee that the target application finished consuming the pasteboard.
public enum TextInsertionOutcome: Equatable {
    case pasteEventDispatched(restoredClipboardScheduled: Bool)
    case focusChanged(expectedApp: String, actualApp: String, copiedToClipboard: Bool)
    case windowOrElementChanged(appName: String, copiedToClipboard: Bool)
    case accessibilityPermissionMissing(copiedToClipboard: Bool)
    case targetUnavailable(copiedToClipboard: Bool)
    case duplicateBlocked
}

// MARK: - Pasteboard & Accessibility Abstractions (Testable)

public struct SavedPasteboardItem: Equatable {
    public let dataByType: [NSPasteboard.PasteboardType: Data]

    public init(dataByType: [NSPasteboard.PasteboardType: Data]) {
        self.dataByType = dataByType
    }
}

public protocol PasteboardProviding: AnyObject {
    var changeCount: Int { get }
    func snapshotItems() -> [SavedPasteboardItem]
    @discardableResult func writePlainText(_ text: String) -> Int
    func restoreSnapshot(_ items: [SavedPasteboardItem])
}

public final class SystemPasteboardProvider: PasteboardProviding {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        return pasteboard.changeCount
    }

    public func snapshotItems() -> [SavedPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var saved: [SavedPasteboardItem] = []
        for item in items {
            var typeMap: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeMap[type] = data
                }
            }
            if !typeMap.isEmpty {
                saved.append(SavedPasteboardItem(dataByType: typeMap))
            }
        }
        return saved
    }

    @discardableResult
    public func writePlainText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    public func restoreSnapshot(_ items: [SavedPasteboardItem]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pbItems: [NSPasteboardItem] = items.map { saved in
            let pbItem = NSPasteboardItem()
            for (type, data) in saved.dataByType {
                pbItem.setData(data, forType: type)
            }
            return pbItem
        }
        pasteboard.writeObjects(pbItems)
    }
}

public protocol AccessibilityPermissionChecking {
    func isTrusted(promptIfNeeded: Bool) -> Bool
    func postCommandVPasteEvent() -> Bool
    /// Queries non-text structural tokens (`windowIdentityToken`, `focusedElementToken`) for a process PID using Accessibility/CGWindow APIs.
    /// Never queries `kAXValueAttribute` or `kAXSelectedTextAttribute`.
    func queryStructuralFocusTokens(for pid: pid_t) -> (windowToken: String?, elementToken: String?)
}

public struct SystemAccessibilityController: AccessibilityPermissionChecking {
    public init() {}

    public func isTrusted(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        } else {
            return AXIsProcessTrusted()
        }
    }

    public func postCommandVPasteEvent() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    public func queryStructuralFocusTokens(for pid: pid_t) -> (windowToken: String?, elementToken: String?) {
        var windowToken: String? = nil
        var elementToken: String? = nil

        // 1. Check CGWindowList for the frontmost on-screen layer-0 window owned by `pid` (reads only numeric kCGWindowNumber, never window title)
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in windowList {
                let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
                let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
                if ownerPID == pid && layer == 0,
                   let winNum = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                    windowToken = "cgwin:\(winNum)"
                    break
                }
            }
        }

        // 2. If Accessibility is trusted, inspect the focused window & UI element structurally without reading text content
        guard AXIsProcessTrusted() else {
            return (windowToken, nil)
        }

        let appElement = AXUIElementCreateApplication(pid)

        var focusedWinRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWinRef) == .success,
           let winObj = focusedWinRef {
            let winHash = CFHash(winObj)
            if windowToken == nil {
                windowToken = "axwin:\(winHash)"
            } else {
                windowToken = "\(windowToken!)|axwin:\(winHash)"
            }
        }

        var focusedElemRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElemRef) == .success,
           let elemObj = focusedElemRef {
            let elemHash = CFHash(elemObj)
            var roleRef: CFTypeRef?
            let axElem = elemObj as! AXUIElement
            var roleString = "unknown"
            if AXUIElementCopyAttributeValue(axElem, kAXRoleAttribute as CFString, &roleRef) == .success,
               let r = roleRef as? String {
                roleString = r
            }
            elementToken = "axelem:\(elemHash):\(roleString)"
        }

        return (windowToken, elementToken)
    }
}

// MARK: - Text Insertion Manager

public final class TextInsertionManager {
    public static let shared = TextInsertionManager()

    private let pasteboard: PasteboardProviding
    private let accessibility: AccessibilityPermissionChecking
    private var insertedSessionIDs: Set<UUID> = []
    public private(set) var lastTranscriptionText: String?

    /// Default delay before restoring previous clipboard items (0.60s gives slower Electron/web apps enough time to consume Cmd+V).
    public static let defaultClipboardRestoreDelay: TimeInterval = 0.60

    public init(
        pasteboard: PasteboardProviding = SystemPasteboardProvider(),
        accessibility: AccessibilityPermissionChecking = SystemAccessibilityController()
    ) {
        self.pasteboard = pasteboard
        self.accessibility = accessibility
    }

    public func captureCurrentTargetApplication() -> TargetApplicationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        // Never treat QuickDictate itself as an auto-paste target
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier ||
           app.bundleIdentifier == "com.github.quickdictate" {
            return nil
        }

        let tokens = accessibility.queryStructuralFocusTokens(for: app.processIdentifier)
        return TargetApplicationContext(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            localizedName: app.localizedName ?? "Active Application",
            windowIdentityToken: tokens.windowToken,
            focusedElementToken: tokens.elementToken
        )
    }

    public func copyLastTranscriptionToClipboard() -> Bool {
        guard let text = lastTranscriptionText, !text.isEmpty else { return false }
        _ = pasteboard.writePlainText(text)
        return true
    }

    /// Safely inserts transcribed text into the captured target application/window:
    /// - Requires a non-nil `expectedTarget` and `currentTarget` (never auto-pastes if original destination was not captured).
    /// - Verifies application identity (`processIdentifier` or `bundleIdentifier`).
    /// - Verifies window identity (`windowIdentityToken`) and focused element (`focusedElementToken`) when available so switching windows within the same app does not blindly paste into the wrong document.
    /// - Preserves the transcription on the clipboard whenever auto-paste is skipped or fails.
    /// - Restores the prior clipboard snapshot after `restoreClipboardDelay` ONLY if `pasteboard.changeCount` is still unchanged AND the original snapshot was non-empty.
    public func insertTranscribedText(
        _ text: String,
        sessionID: UUID,
        expectedTarget: TargetApplicationContext?,
        currentTarget: TargetApplicationContext?,
        restoreClipboardDelay: TimeInterval = TextInsertionManager.defaultClipboardRestoreDelay,
        onClipboardRestoreCheckCompleted: ((Bool) -> Void)? = nil
    ) -> TextInsertionOutcome {
        guard !insertedSessionIDs.contains(sessionID) else {
            return .duplicateBlocked
        }
        insertedSessionIDs.insert(sessionID)
        lastTranscriptionText = text

        // 1. Check Accessibility permission first
        guard accessibility.isTrusted(promptIfNeeded: false) else {
            _ = pasteboard.writePlainText(text)
            return .accessibilityPermissionMissing(copiedToClipboard: true)
        }

        // 2. Both the original expected target and the current active target MUST be captured and non-nil
        guard let expected = expectedTarget, let actualTarget = currentTarget else {
            _ = pasteboard.writePlainText(text)
            return .targetUnavailable(copiedToClipboard: true)
        }

        // 3. Guard against application focus changes while transcription was processing
        // A matching bundle identifier does not prove the same running process.
        if expected.processIdentifier != actualTarget.processIdentifier {
            _ = pasteboard.writePlainText(text)
            return .focusChanged(
                expectedApp: expected.localizedName,
                actualApp: actualTarget.localizedName,
                copiedToClipboard: true
            )
        }

        // 4. Require reliable identity for both the original and current window
        // and focused UI element. Never auto-paste into an unverified destination.
        // Some apps deny structural Accessibility inspection; in those cases
        // keep the result on the clipboard for deliberate user paste.
        guard let expectedWindow = expected.windowIdentityToken,
              let actualWindow = actualTarget.windowIdentityToken,
              let expectedElement = expected.focusedElementToken,
              let actualElement = actualTarget.focusedElementToken,
              expectedWindow == actualWindow,
              expectedElement == actualElement else {
            _ = pasteboard.writePlainText(text)
            return .windowOrElementChanged(
                appName: actualTarget.localizedName,
                copiedToClipboard: true
            )
        }

        // 6. Snapshot existing clipboard items before placing transcription on pasteboard
        let originalSnapshot = pasteboard.snapshotItems()
        let changeCountAfterWrite = pasteboard.writePlainText(text)

        // 7. Post synthetic Cmd + V
        guard accessibility.postCommandVPasteEvent() else {
            return .targetUnavailable(copiedToClipboard: true)
        }

        // 8. Schedule safe clipboard restoration ONLY if originalSnapshot is non-empty (so an empty initial clipboard never wipes the user's transcription)
        //    and pasteboard.changeCount has not been modified by another app.
        let shouldScheduleRestore = !originalSnapshot.isEmpty
        if shouldScheduleRestore {
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreClipboardDelay) { [weak self] in
                guard let self = self else { return }
                let didRestore = self.restoreClipboardIfUnchanged(
                    expectedChangeCount: changeCountAfterWrite,
                    snapshot: originalSnapshot
                )
                onClipboardRestoreCheckCompleted?(didRestore)
            }
        } else {
            onClipboardRestoreCheckCompleted?(false)
        }

        return .pasteEventDispatched(restoredClipboardScheduled: shouldScheduleRestore)
    }

    /// Restores the saved clipboard snapshot if and only if `snapshot` is non-empty and `pasteboard.changeCount == expectedChangeCount`.
    @discardableResult
    public func restoreClipboardIfUnchanged(
        expectedChangeCount: Int,
        snapshot: [SavedPasteboardItem]
    ) -> Bool {
        guard !snapshot.isEmpty else {
            return false
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            // Another application or the user modified the clipboard during the delay; do NOT overwrite their newer data!
            return false
        }
        pasteboard.restoreSnapshot(snapshot)
        return true
    }
}
