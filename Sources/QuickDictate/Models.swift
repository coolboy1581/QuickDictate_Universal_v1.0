import Foundation
import Cocoa

// MARK: - Provider & Models

public enum Provider: String, Codable, CaseIterable, Equatable {
    case groq = "groq"
    case openai = "openai"

    public var displayName: String {
        switch self {
        case .groq:
            return "Groq (Whisper Large V3 Turbo)"
        case .openai:
            return "OpenAI (Whisper-1)"
        }
    }

    public var shortName: String {
        switch self {
        case .groq:
            return "Groq"
        case .openai:
            return "OpenAI"
        }
    }

    public var endpoint: URL {
        switch self {
        case .groq:
            return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        case .openai:
            return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }
    }

    public var modelName: String {
        switch self {
        case .groq:
            return "whisper-large-v3-turbo"
        case .openai:
            return "whisper-1"
        }
    }

    /// Maximum multipart upload size documented for the standard tier (25 MB).
    public var maxFileSizeBytes: Int {
        return 25 * 1024 * 1024
    }

    /// Infers a default provider from a key prefix during legacy migration or quick add,
    /// while allowing the user to explicitly override or store the provider in metadata.
    public static func infer(fromKey key: String) -> Provider {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("gsk_") {
            return .groq
        } else if trimmed.hasPrefix("sk-") {
            return .openai
        } else {
            return .groq
        }
    }
}

// MARK: - Stored Credential Metadata

public struct StoredCredentialMetadata: Codable, Equatable, Identifiable {
    public let id: UUID
    public var provider: Provider
    public var label: String
    public var maskedPreview: String
    public var createdAt: Date

    public init(id: UUID = UUID(), provider: Provider, label: String, maskedPreview: String, createdAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.label = label
        self.maskedPreview = maskedPreview
        self.createdAt = createdAt
    }

    public static func makeMaskedPreview(for rawKey: String) -> String {
        let clean = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 8 else {
            return "••••••••"
        }
        let prefix = String(clean.prefix(4))
        let suffix = String(clean.suffix(4))
        return "\(prefix)••••\(suffix)"
    }
}

public struct ResolvedCredential: Equatable {
    public let metadata: StoredCredentialMetadata
    public let secret: String

    public init(metadata: StoredCredentialMetadata, secret: String) {
        self.metadata = metadata
        self.secret = secret
    }
}

// MARK: - Dictation Lifecycle State Machine

public enum DictationLifecycleState: Equatable {
    case idle
    case requestingPermission
    case recording(sessionID: UUID, fileURL: URL)
    case stopping(sessionID: UUID, fileURL: URL)
    case transcribing(sessionID: UUID, fileURL: URL)
    case completed(sessionID: UUID)
    case failed(sessionID: UUID?, message: String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isTranscribingOrStopping: Bool {
        switch self {
        case .stopping, .transcribing:
            return true
        default:
            return false
        }
    }

    public var activeSessionID: UUID? {
        switch self {
        case .recording(let id, _),
             .stopping(let id, _),
             .transcribing(let id, _),
             .completed(let id):
            return id
        case .failed(let id, _):
            return id
        case .idle, .requestingPermission:
            return nil
        }
    }

    public var iconState: IconState {
        switch self {
        case .idle, .completed, .failed, .requestingPermission:
            return .idle
        case .recording:
            return .recording
        case .stopping, .transcribing:
            return .processing
        }
    }
}

public enum IconState: Equatable {
    case idle
    case recording
    case processing
}

public enum SoundType: Equatable {
    case startRecording
    case stopRecording
    case error
}

// MARK: - Keyboard Shortcut Choice

public enum ShortcutOption: String, Codable, CaseIterable, Equatable {
    case rightOption = "right_option"
    case leftOption = "left_option"
    case rightCommand = "right_command"
    case fnKey = "fn_key"
    case custom = "custom"
    case disabled = "disabled"

    public var displayName: String {
        switch self {
        case .rightOption:
            return "Right Option (Single Tap)"
        case .leftOption:
            return "Left Option (Single Tap)"
        case .rightCommand:
            return "Right Command (Single Tap)"
        case .fnKey:
            return "Fn / Globe Key (Single Tap)"
        case .custom:
            return "Custom Keyboard Shortcut"
        case .disabled:
            return "Disabled (Menu Bar Only)"
        }
    }

    public var expectedKeyCode: UInt16? {
        switch self {
        case .rightOption:
            return 61 // kVK_RightOption (0x3D)
        case .leftOption:
            return 58 // kVK_Option (0x3A)
        case .rightCommand:
            return 54 // kVK_RightCommand (0x36)
        case .fnKey:
            return 63 // kVK_Function (0x3F)
        case .custom, .disabled:
            return nil
        }
    }
}

// MARK: - Custom Key Combination Model

public struct KeyCombo: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt // NSEvent.ModifierFlags.rawValue
    public var displayString: String

    public init(keyCode: UInt16, modifiers: UInt, displayString: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayString = displayString
    }

    public static let defaultCustom = KeyCombo(
        keyCode: 2, // 'D'
        modifiers: 0x00080000 | 0x00040000, // Control + Option
        displayString: "⌃⌥D"
    )

    public static func validate(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (isValid: Bool, errorReason: String?) {
        let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let active = flags.intersection(relevantFlags)

        // Must have at least one non-shift modifier or be an F-key
        let fKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        let isFKey = fKeyCodes.contains(keyCode)
        let hasControlOrAltOrCmd = !active.intersection([.command, .option, .control]).isEmpty

        if !hasControlOrAltOrCmd && !isFKey {
            return (false, "Shortcut must include at least one modifier key (⌃ Control, ⌥ Option, or ⌘ Command).")
        }

        // Check common system reserved combinations
        if active == .command {
            switch keyCode {
            case 12: return (false, "⌘Q is reserved by macOS for Quit.")
            case 13: return (false, "⌘W is reserved by macOS for Close Window.")
            case 4:  return (false, "⌘H is reserved by macOS for Hide Application.")
            case 46: return (false, "⌘M is reserved by macOS for Minimize Window.")
            case 48: return (false, "⌘Tab is reserved by macOS for Application Switcher.")
            case 49: return (false, "⌘Space is reserved by macOS for Spotlight Search.")
            default: break
            }
        }
        if active == [.command, .option] && keyCode == 49 {
            return (false, "⌥⌘Space is reserved by macOS for Finder Search.")
        }

        return (true, nil)
    }

    public static func formatDisplayString(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var str = ""
        if flags.contains(.control) { str += "⌃" }
        if flags.contains(.option) { str += "⌥" }
        if flags.contains(.shift) { str += "⇧" }
        if flags.contains(.command) { str += "⌘" }

        str += keyNameForCode(keyCode, characters: characters)
        return str
    }

    public static func keyNameForCode(_ keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 50: return "`"
        default:
            if let c = characters?.uppercased(), !c.isEmpty && c.count == 1 {
                return c
            }
            return "Key(\(keyCode))"
        }
    }
}

// MARK: - Voice Snippet Model

public struct Snippet: Codable, Equatable {
    public var trigger: String
    public var value: String

    public init(trigger: String, value: String) {
        self.trigger = trigger
        self.value = value
    }
}

// MARK: - Redacting Logger

public enum SafeLogger {
    /// Scrubs anything resembling an API key (`gsk_...`, `sk-...`, or Bearer tokens) before logging.
    public static func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            "Bearer\\s+[A-Za-z0-9_\\-\\.]+",
            "gsk_[A-Za-z0-9_\\-]{6,}",
            "sk-[A-Za-z0-9_\\-]{6,}"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: result.utf16.count)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED_KEY]")
            }
        }
        return result
    }

    public static func logInfo(_ message: String) {
        let safe = redact(message)
        fputs("[QuickDictate] \(safe)\n", stderr)
    }

    public static func logError(_ message: String) {
        let safe = redact(message)
        fputs("[QuickDictate ERROR] \(safe)\n", stderr)
    }
}
