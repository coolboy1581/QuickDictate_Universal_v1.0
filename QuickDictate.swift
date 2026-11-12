// QuickDictate.swift — Consolidated Single-File Source (v2.0.0)
// Generated from modular sources in Sources/QuickDictate/
// Target: macOS 12.0+ (Universal 2: arm64 + x86_64)

import Cocoa
import Foundation
import AVFoundation
import Security
import ApplicationServices
import ServiceManagement
import Carbon

// ============================================================================
// FILE: Models.swift
// ============================================================================
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

// ============================================================================
// FILE: KeychainCredentialManager.swift
// ============================================================================
// MARK: - Keychain Errors

public enum CredentialStoreError: LocalizedError, Equatable {
    case emptyOrMalformedKey
    case duplicateKey
    case keychainFailure(status: OSStatus)
    case credentialNotFound
    case encodingError
    case migrationVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOrMalformedKey:
            return "The API key is empty or malformed. Keys must be at least 12 characters without spaces or control characters."
        case .duplicateKey:
            return "This API key is already saved in QuickDictate."
        case .keychainFailure(let status):
            return "macOS Keychain operation failed (OSStatus \(status)). Check Keychain Access permissions."
        case .credentialNotFound:
            return "The requested API key could not be found in Keychain."
        case .encodingError:
            return "Failed to encode or decode credential data."
        case .migrationVerificationFailed(let reason):
            return "Legacy API key migration could not be verified: \(reason). Original key files were preserved."
        }
    }
}

// MARK: - Keychain Backend Abstraction (Testable)

public protocol KeychainStorageBackend {
    func setSecret(_ data: Data, service: String, account: String) throws
    func getSecret(service: String, account: String) throws -> Data?
    func deleteSecret(service: String, account: String) throws
}

public final class SystemKeychainBackend: KeychainStorageBackend {
    public init() {}

    public func setSecret(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(status: updateStatus)
            }
        } else if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(status: addStatus)
            }
        } else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }

    public func getSecret(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
        return item as? Data
    }

    public func deleteSecret(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }
}

// MARK: - Legacy Migration Report

public struct MigrationOutcome: Equatable {
    public let attempted: Bool
    public let migratedCount: Int
    public let skippedMalformedCount: Int
    public let legacyFilesRemoved: Bool
    public let errorMessage: String?
}

// MARK: - Keychain Credential Manager

public final class KeychainCredentialManager {
    public static let shared = KeychainCredentialManager()

    public let serviceName: String
    private let backend: KeychainStorageBackend
    private let userDefaults: UserDefaults
    private let metadataDefaultsKey = "QuickDictate.CredentialMetadataList"
    private let migrationCompletedKey = "QuickDictate.LegacyMigrationCompleted"
    private let lock = NSLock()

    public init(
        serviceName: String = "com.github.quickdictate.credentials",
        backend: KeychainStorageBackend = SystemKeychainBackend(),
        userDefaults: UserDefaults = .standard
    ) {
        self.serviceName = serviceName
        self.backend = backend
        self.userDefaults = userDefaults
    }

    // MARK: - Validation

    public static func validateKeyFormat(_ rawKey: String) -> String? {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12, trimmed.count <= 256 else {
            return nil
        }
        // Reject whitespace or control characters inside an API key
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
           trimmed.rangeOfCharacter(from: .controlCharacters) != nil {
            return nil
        }
        return trimmed
    }

    // MARK: - CRUD Operations

    public func listMetadata() -> [StoredCredentialMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return loadMetadataLocked()
    }

    public func resolveCredentials(preferredProvider: Provider?, allowCrossProviderFailover: Bool) -> [ResolvedCredential] {
        lock.lock()
        let metadataList = loadMetadataLocked()
        lock.unlock()

        var allResolved: [ResolvedCredential] = []
        for meta in metadataList {
            if let data = try? backend.getSecret(service: serviceName, account: meta.id.uuidString),
               let secret = String(data: data, encoding: .utf8),
               !secret.isEmpty {
                allResolved.append(ResolvedCredential(metadata: meta, secret: secret))
            }
        }

        guard let preferred = preferredProvider else {
            if let firstProvider = allResolved.first?.metadata.provider, !allowCrossProviderFailover {
                return allResolved.filter { $0.metadata.provider == firstProvider }
            }
            return allResolved
        }

        let primary = allResolved.filter { $0.metadata.provider == preferred }
        if allowCrossProviderFailover {
            let secondary = allResolved.filter { $0.metadata.provider != preferred }
            return primary + secondary
        } else {
            return primary
        }
    }

    @discardableResult
    public func addCredential(rawKey: String, provider: Provider? = nil, label: String? = nil) throws -> StoredCredentialMetadata {
        guard let cleaned = Self.validateKeyFormat(rawKey) else {
            throw CredentialStoreError.emptyOrMalformedKey
        }

        lock.lock()
        defer { lock.unlock() }

        var existingMeta = loadMetadataLocked()

        // Duplicate detection without leaking secrets
        for meta in existingMeta {
            if let existingData = try backend.getSecret(service: serviceName, account: meta.id.uuidString),
               let existingSecret = String(data: existingData, encoding: .utf8),
               existingSecret == cleaned {
                throw CredentialStoreError.duplicateKey
            }
        }

        let resolvedProvider = provider ?? Provider.infer(fromKey: cleaned)
        let resolvedLabel: String
        if let customLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines), !customLabel.isEmpty {
            resolvedLabel = customLabel
        } else {
            resolvedLabel = "\(resolvedProvider.shortName) Key"
        }

        let newMeta = StoredCredentialMetadata(
            provider: resolvedProvider,
            label: resolvedLabel,
            maskedPreview: StoredCredentialMetadata.makeMaskedPreview(for: cleaned)
        )

        guard let secretData = cleaned.data(using: .utf8) else {
            throw CredentialStoreError.encodingError
        }

        try backend.setSecret(secretData, service: serviceName, account: newMeta.id.uuidString)
        existingMeta.append(newMeta)
        saveMetadataLocked(existingMeta)
        return newMeta
    }

    public func replaceCredential(id: UUID, newRawKey: String, provider: Provider, label: String?) throws -> StoredCredentialMetadata {
        guard let cleaned = Self.validateKeyFormat(newRawKey) else {
            throw CredentialStoreError.emptyOrMalformedKey
        }

        lock.lock()
        defer { lock.unlock() }

        var existingMeta = loadMetadataLocked()
        guard let idx = existingMeta.firstIndex(where: { $0.id == id }) else {
            throw CredentialStoreError.credentialNotFound
        }

        // Check duplicate against other entries
        for meta in existingMeta where meta.id != id {
            if let existingData = try backend.getSecret(service: serviceName, account: meta.id.uuidString),
               let existingSecret = String(data: existingData, encoding: .utf8),
               existingSecret == cleaned {
                throw CredentialStoreError.duplicateKey
            }
        }

        guard let secretData = cleaned.data(using: .utf8) else {
            throw CredentialStoreError.encodingError
        }

        try backend.setSecret(secretData, service: serviceName, account: id.uuidString)

        let updatedLabel = (label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? existingMeta[idx].label
        existingMeta[idx].provider = provider
        existingMeta[idx].label = updatedLabel
        existingMeta[idx].maskedPreview = StoredCredentialMetadata.makeMaskedPreview(for: cleaned)
        saveMetadataLocked(existingMeta)
        return existingMeta[idx]
    }

    public func removeCredential(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var existingMeta = loadMetadataLocked()
        try backend.deleteSecret(service: serviceName, account: id.uuidString)
        existingMeta.removeAll { $0.id == id }
        saveMetadataLocked(existingMeta)
    }

    public func moveCredential(fromIndex: Int, toIndex: Int) {
        lock.lock()
        defer { lock.unlock() }

        var list = loadMetadataLocked()
        guard fromIndex >= 0, fromIndex < list.count, toIndex >= 0, toIndex < list.count, fromIndex != toIndex else {
            return
        }
        let item = list.remove(at: fromIndex)
        list.insert(item, at: toIndex)
        saveMetadataLocked(list)
    }

    // MARK: - Safe One-Time Legacy Migration

    /// Migrates plaintext credentials from `~/.quickdictate_keys` and `~/.quickdictate_key` into Keychain.
    /// Deletes the plaintext files ONLY after verifying every valid credential is readable from Keychain.
    /// If any Keychain error occurs, preserves the original files and returns an actionable error.
    public func migrateLegacyPlaintextKeysIfNeeded(
        keysFilePath: String = NSString(string: "~/.quickdictate_keys").expandingTildeInPath,
        singleKeyFilePath: String = NSString(string: "~/.quickdictate_key").expandingTildeInPath,
        fileManager: FileManager = .default
    ) -> MigrationOutcome {
        let keysExists = fileManager.fileExists(atPath: keysFilePath)
        let singleExists = fileManager.fileExists(atPath: singleKeyFilePath)

        guard keysExists || singleExists else {
            return MigrationOutcome(
                attempted: false,
                migratedCount: 0,
                skippedMalformedCount: 0,
                legacyFilesRemoved: false,
                errorMessage: nil
            )
        }

        var candidateLines: [String] = []
        if keysExists {
            if let content = try? String(contentsOfFile: keysFilePath, encoding: .utf8) {
                candidateLines.append(contentsOf: content.components(separatedBy: .newlines))
            } else {
                return MigrationOutcome(
                    attempted: true,
                    migratedCount: 0,
                    skippedMalformedCount: 0,
                    legacyFilesRemoved: false,
                    errorMessage: "Could not read legacy key file ~/.quickdictate_keys. Original file was preserved."
                )
            }
        }
        if singleExists {
            if let content = try? String(contentsOfFile: singleKeyFilePath, encoding: .utf8) {
                candidateLines.append(contentsOf: content.components(separatedBy: .newlines))
            } else {
                return MigrationOutcome(
                    attempted: true,
                    migratedCount: 0,
                    skippedMalformedCount: 0,
                    legacyFilesRemoved: false,
                    errorMessage: "Could not read legacy key file ~/.quickdictate_key. Original file was preserved."
                )
            }
        }

        var validUniqueKeys: [String] = []
        var skippedMalformed = 0

        for line in candidateLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if let valid = Self.validateKeyFormat(trimmed) {
                if !validUniqueKeys.contains(valid) {
                    validUniqueKeys.append(valid)
                }
            } else {
                skippedMalformed += 1
            }
        }

        // If the files contained malformed entries and zero valid keys, preserve the files so the user never loses data.
        if validUniqueKeys.isEmpty && skippedMalformed > 0 {
            return MigrationOutcome(
                attempted: true,
                migratedCount: 0,
                skippedMalformedCount: skippedMalformed,
                legacyFilesRemoved: false,
                errorMessage: "Legacy credential files contained malformed entries that could not be imported. Original files were preserved for manual review."
            )
        }

        var newlyImportedCount = 0
        for rawKey in validUniqueKeys {
            do {
                let provider = Provider.infer(fromKey: rawKey)
                _ = try addCredential(rawKey: rawKey, provider: provider, label: "\(provider.shortName) (Migrated)")
                newlyImportedCount += 1
            } catch CredentialStoreError.duplicateKey {
                // Idempotent: already in Keychain from a previous launch
                continue
            } catch {
                return MigrationOutcome(
                    attempted: true,
                    migratedCount: newlyImportedCount,
                    skippedMalformedCount: skippedMalformed,
                    legacyFilesRemoved: false,
                    errorMessage: error.localizedDescription + " Legacy plaintext files were preserved."
                )
            }
        }

        // Verification step: verify every valid key from the legacy files can actually be read back from Keychain
        let storedSecrets = Set(resolveCredentials(preferredProvider: nil, allowCrossProviderFailover: true).map { $0.secret })
        for expectedKey in validUniqueKeys {
            guard storedSecrets.contains(expectedKey) else {
                return MigrationOutcome(
                    attempted: true,
                    migratedCount: newlyImportedCount,
                    skippedMalformedCount: skippedMalformed,
                    legacyFilesRemoved: false,
                    errorMessage: CredentialStoreError.migrationVerificationFailed("Read-back check failed").localizedDescription
                )
            }
        }

        // If malformed entries existed alongside valid keys, preserve the file and notify user so no partial data is lost
        if skippedMalformed > 0 {
            return MigrationOutcome(
                attempted: true,
                migratedCount: newlyImportedCount,
                skippedMalformedCount: skippedMalformed,
                legacyFilesRemoved: false,
                errorMessage: "Imported \(newlyImportedCount) key(s) to Keychain, but preserved legacy key file(s) because \(skippedMalformed) malformed entry/entries were skipped."
            )
        }

        // Only after 100% verification and zero skipped entries, remove the legacy plaintext files
        var removedCleanly = true
        if keysExists {
            do {
                try fileManager.removeItem(atPath: keysFilePath)
            } catch {
                removedCleanly = false
            }
        }
        if singleExists {
            do {
                try fileManager.removeItem(atPath: singleKeyFilePath)
            } catch {
                removedCleanly = false
            }
        }

        userDefaults.set(true, forKey: migrationCompletedKey)
        return MigrationOutcome(
            attempted: true,
            migratedCount: newlyImportedCount,
            skippedMalformedCount: 0,
            legacyFilesRemoved: removedCleanly,
            errorMessage: removedCleanly ? nil : "Credentials were stored in Keychain, but QuickDictate could not delete the legacy plaintext key file(s). Please delete ~/.quickdictate_keys and ~/.quickdictate_key manually."
        )
    }

    // MARK: - Private Persistence Helpers

    private func loadMetadataLocked() -> [StoredCredentialMetadata] {
        guard let data = userDefaults.data(forKey: metadataDefaultsKey),
              let decoded = try? JSONDecoder().decode([StoredCredentialMetadata].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveMetadataLocked(_ list: [StoredCredentialMetadata]) {
        if let encoded = try? JSONEncoder().encode(list) {
            userDefaults.set(encoded, forKey: metadataDefaultsKey)
        }
    }
}

// ============================================================================
// FILE: AudioSessionManager.swift
// ============================================================================
// MARK: - Audio File & Recording Errors

public enum AudioSessionError: LocalizedError, Equatable {
    case permissionDenied
    case permissionRestricted
    case directoryCreationFailed(String)
    case recorderFailedToStart(String)
    case audioFileMissing
    case audioFileTooSmallOrSilent
    case corruptedWAVHeader
    case audioFileTooLarge(maxBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is denied. Enable QuickDictate in System Settings → Privacy & Security → Microphone."
        case .permissionRestricted:
            return "Microphone access is restricted by a macOS system policy or parental control."
        case .directoryCreationFailed(let reason):
            return "Failed to prepare secure temporary audio directory: \(reason)"
        case .recorderFailedToStart(let reason):
            return "Microphone recorder could not start: \(reason)"
        case .audioFileMissing:
            return "Recording file was not found on disk."
        case .audioFileTooSmallOrSilent:
            return "No speech audio was captured. Speak clearly after the start chime."
        case .corruptedWAVHeader:
            return "Captured audio file has an invalid or corrupted WAV header."
        case .audioFileTooLarge(let maxBytes):
            let mb = maxBytes / (1024 * 1024)
            return "Recording exceeds the provider's \(mb) MB upload limit."
        }
    }
}

// MARK: - Secure Temporary Audio File Manager

public final class AudioSessionFileManager {
    public let baseDirectoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var trackedFiles: Set<URL> = []

    public init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let custom = baseDirectoryURL {
            self.baseDirectoryURL = custom
        } else {
            self.baseDirectoryURL = fileManager.temporaryDirectory
                .appendingPathComponent("com.github.quickdictate.recordings", isDirectory: true)
        }
        try? ensureSecureDirectoryExists()
    }

    public func ensureSecureDirectoryExists() throws {
        lock.lock()
        defer { lock.unlock() }

        let path = baseDirectoryURL.path
        if !fileManager.fileExists(atPath: path) {
            try fileManager.createDirectory(
                at: baseDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }

    /// Generates a unique recording file URL for the given session ID and tracks it for cleanup.
    public func makeRecordingURL(for sessionID: UUID) throws -> URL {
        try ensureSecureDirectoryExists()
        lock.lock()
        defer { lock.unlock() }

        let filename = "dictation-\(sessionID.uuidString).wav"
        let url = baseDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        trackedFiles.insert(url)
        return url
    }

    /// Restricts permissions on a newly created recording file to 0600 (owner read/write only).
    public func secureRecordingFilePermissions(at url: URL) {
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Deletes a specific session recording file if it exists.
    public func cleanupRecordingFile(at url: URL) {
        lock.lock()
        trackedFiles.remove(url)
        lock.unlock()

        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Deletes all tracked and untracked `.wav` files in the application's temporary directory (used on launch & termination).
    public func cleanupAllRecordings() {
        lock.lock()
        let currentTracked = trackedFiles
        trackedFiles.removeAll()
        lock.unlock()

        for url in currentTracked {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }

        if let items = try? fileManager.contentsOfDirectory(at: baseDirectoryURL, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension.lowercased() == "wav" {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    // MARK: - Audio File Validation & WAV Patching

    /// Validates that a recorded WAV file exists, has a valid RIFF/WAVE header, is non-empty (> 1600 bytes / ~0.05s at 16kHz 16-bit mono),
    /// and does not exceed the maximum upload size.
    public static func validateAndReadWAV(at url: URL, maxBytes: Int = 25 * 1024 * 1024) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioSessionError.audioFileMissing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw AudioSessionError.audioFileMissing
        }

        // 44-byte WAV header + at least 1,600 bytes of 16kHz 16-bit mono PCM (~50ms of audio, above Groq's 10ms minimum)
        guard data.count >= 1644 else {
            throw AudioSessionError.audioFileTooSmallOrSilent
        }

        guard data.count <= maxBytes else {
            throw AudioSessionError.audioFileTooLarge(maxBytes: maxBytes)
        }

        guard isValidWAVHeader(data) else {
            throw AudioSessionError.corruptedWAVHeader
        }

        return data
    }

    /// Checks whether the first 12 bytes contain standard RIFF....WAVE magic markers.
    public static func isValidWAVHeader(_ data: Data) -> Bool {
        guard data.count >= 44 else { return false }
        let riff = String(data: data.subdata(in: 0..<4), encoding: .ascii)
        let wave = String(data: data.subdata(in: 8..<12), encoding: .ascii)
        return riff == "RIFF" && wave == "WAVE"
    }

    /// Creates a bounded in-memory WAV snapshot with patched RIFF and data chunk sizes for in-progress periodic previews.
    /// Returns nil if the file is missing, smaller than 0.25 seconds of audio, or has an invalid header.
    public static func makePatchedPreviewWAVSnapshot(at url: URL, maxPreviewBytes: Int = 2 * 1024 * 1024) -> Data? {
        guard let rawData = try? Data(contentsOf: url),
              rawData.count >= 8044, // 44 header + ~0.25s of 16kHz 16-bit mono PCM
              rawData.count <= maxPreviewBytes,
              isValidWAVHeader(rawData) else {
            return nil
        }

        var wavSlice = rawData
        let total = UInt32(wavSlice.count)
        var chunkSize = (total - 8).littleEndian
        wavSlice.replaceSubrange(4..<8, with: Data(bytes: &chunkSize, count: 4))
        var subchunk2Size = (total - 44).littleEndian
        wavSlice.replaceSubrange(40..<44, with: Data(bytes: &subchunk2Size, count: 4))
        return wavSlice
    }
}

// MARK: - Microphone Permission Helper

public protocol MicrophonePermissionChecking {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess(completion: @escaping (Bool) -> Void)
}

public struct SystemMicrophonePermissionChecker: MicrophonePermissionChecking {
    public init() {}

    public func authorizationStatus() -> AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}

// ============================================================================
// FILE: TranscriptionClient.swift
// ============================================================================
// MARK: - Transcription Network Errors

public enum TranscriptionClientError: LocalizedError, Equatable {
    case noCredentialsConfigured
    case authenticationFailed(provider: Provider)
    case rateLimited(provider: Provider, retryAfterSeconds: TimeInterval?)
    case quotaExceeded(provider: Provider)
    case badRequest(provider: Provider, reason: String)
    case payloadTooLarge(provider: Provider, maxBytes: Int)
    case serverError(provider: Provider, statusCode: Int)
    case networkTimeout(provider: Provider)
    case connectivityFailure(provider: Provider, description: String)
    case malformedResponse(provider: Provider)
    case emptyTranscription
    case cancelled
    case crossProviderFailoverBlocked(from: Provider, to: Provider)
    case allKeysExhausted(lastErrorDescription: String)

    public var errorDescription: String? {
        switch self {
        case .noCredentialsConfigured:
            return "No API keys are configured for the selected transcription provider."
        case .authenticationFailed(let provider):
            return "\(provider.shortName) rejected the API key (HTTP 401/403). Verify or replace your key in Settings."
        case .rateLimited(let provider, let retryAfter):
            if let wait = retryAfter, wait > 0 {
                return "\(provider.shortName) rate limit reached (HTTP 429). Try again in \(Int(ceil(wait)))s."
            }
            return "\(provider.shortName) rate limit reached (HTTP 429). Please wait a moment or add a backup key."
        case .quotaExceeded(let provider):
            return "\(provider.shortName) account quota or billing limit exceeded."
        case .badRequest(let provider, let reason):
            return "\(provider.shortName) rejected the audio request: \(reason)"
        case .payloadTooLarge(let provider, let maxBytes):
            return "Recording exceeds \(provider.shortName)'s \(maxBytes / (1024 * 1024)) MB upload limit."
        case .serverError(let provider, let statusCode):
            return "\(provider.shortName) experienced a temporary server error (HTTP \(statusCode))."
        case .networkTimeout(let provider):
            return "Connection to \(provider.shortName) timed out. Check your internet connection."
        case .connectivityFailure(let provider, let description):
            return "Could not reach \(provider.shortName): \(description)"
        case .malformedResponse(let provider):
            return "\(provider.shortName) returned an unexpected or invalid JSON response."
        case .emptyTranscription:
            return "No speech was detected in the recording."
        case .cancelled:
            return "Transcription request was cancelled."
        case .crossProviderFailoverBlocked(let from, let to):
            return "\(from.shortName) keys failed, and cross-provider failover to \(to.shortName) is disabled for privacy."
        case .allKeysExhausted(let lastError):
            return "All configured API keys failed (\(lastError))."
        }
    }

    /// Indicates whether failing over to the next API key is appropriate.
    /// Malformed audio / 400 / 413 / 422 requests will fail on every key and must NOT trigger duplicate uploads.
    public var shouldFailoverToNextKey: Bool {
        switch self {
        case .authenticationFailed, .rateLimited, .quotaExceeded, .serverError, .networkTimeout, .connectivityFailure:
            return true
        case .badRequest, .payloadTooLarge, .malformedResponse, .emptyTranscription, .cancelled, .noCredentialsConfigured, .crossProviderFailoverBlocked, .allKeysExhausted:
            return false
        }
    }

    /// Indicates whether a single bounded retry on the SAME key is appropriate (e.g. short Retry-After or transient 5xx).
    public var isTransientForSameKeyRetry: Bool {
        switch self {
        case .rateLimited(_, let retryAfter):
            if let wait = retryAfter {
                return wait <= 3.0
            }
            return true
        case .serverError:
            return true
        default:
            return false
        }
    }
}

// MARK: - HTTP Transport Abstraction (Testable)

public protocol CancellableTask: AnyObject {
    func cancel()
}

extension URLSessionDataTask: CancellableTask {}

public protocol HTTPTransport {
    @discardableResult
    func sendRequest(
        _ request: URLRequest,
        completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void
    ) -> CancellableTask
}

public final class URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    public func sendRequest(
        _ request: URLRequest,
        completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void
    ) -> CancellableTask {
        let task = session.dataTask(with: request) { data, response, error in
            completion(data, response as? HTTPURLResponse, error)
        }
        task.resume()
        return task
    }
}

// MARK: - Transcription Result & Failover Trace

public struct TranscriptionSuccess: Equatable {
    public let text: String
    public let usedProvider: Provider
    public let usedCredentialID: UUID
    public let attemptsCount: Int

    public init(text: String, usedProvider: Provider, usedCredentialID: UUID, attemptsCount: Int) {
        self.text = text
        self.usedProvider = usedProvider
        self.usedCredentialID = usedCredentialID
        self.attemptsCount = attemptsCount
    }
}

// MARK: - Internal Operation Context (At-Most-Once & Attempt-Scoped Task Tracking)

private final class TranscriptionOperationContext {
    let token: UUID
    private let lock = NSLock()
    private let completionHandler: (Result<TranscriptionSuccess, TranscriptionClientError>) -> Void

    private var hasCompleted: Bool = false
    private var isCancelled: Bool = false
    private var currentAttemptSequence: Int = 0
    private var activeTask: CancellableTask?
    private var activeAttemptID: Int?
    private var pendingRetryWorkItem: DispatchWorkItem?

    init(token: UUID = UUID(), completion: @escaping (Result<TranscriptionSuccess, TranscriptionClientError>) -> Void) {
        self.token = token
        self.completionHandler = completion
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hasCompleted && !isCancelled
    }

    /// Allocates a monotonically increasing attempt sequence ID if the operation is still active.
    func beginAttempt() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasCompleted && !isCancelled else { return nil }
        currentAttemptSequence += 1
        activeAttemptID = currentAttemptSequence
        activeTask = nil
        pendingRetryWorkItem = nil
        return currentAttemptSequence
    }

    /// Registers the returned `CancellableTask` ONLY if `attemptID` is still the current active attempt and the operation was not completed or cancelled synchronously inside `transport.sendRequest`.
    /// If the operation was already cancelled, returns `true` so the caller can cancel `task` OUTSIDE the lock.
    func registerTask(_ task: CancellableTask, forAttemptID attemptID: Int) -> Bool {
        lock.lock()
        if hasCompleted || isCancelled {
            let shouldCancel = isCancelled
            lock.unlock()
            return shouldCancel
        }
        if activeAttemptID == attemptID {
            activeTask = task
        }
        lock.unlock()
        return false
    }

    /// Registers a scheduled retry `DispatchWorkItem` ONLY if `attemptID` is still the current attempt and the operation is active.
    func registerRetryWorkItem(_ item: DispatchWorkItem, forAttemptID attemptID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasCompleted && !isCancelled, activeAttemptID == attemptID else {
            return false
        }
        activeTask = nil
        pendingRetryWorkItem = item
        return true
    }

    /// Verifies that the callback corresponds to the currently active attempt and that the operation has not been cancelled or completed.
    func isCurrentAttemptValid(_ attemptID: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hasCompleted && !isCancelled && activeAttemptID == attemptID
    }

    /// Finishes the operation at most once. Subsequent calls are no-ops.
    func finishOnce(with result: Result<TranscriptionSuccess, TranscriptionClientError>) {
        lock.lock()
        if hasCompleted {
            lock.unlock()
            return
        }
        hasCompleted = true
        activeAttemptID = nil
        activeTask = nil
        let workItem = pendingRetryWorkItem
        pendingRetryWorkItem = nil
        lock.unlock()

        workItem?.cancel()
        completionHandler(result)
    }

    /// Cancels the operation, extracts any active network task and pending retry work item under lock,
    /// releases the lock BEFORE invoking `.cancel()` (preventing lock reentrancy deadlocks),
    /// and delivers `.failure(.cancelled)` at most once.
    func cancel() {
        lock.lock()
        if hasCompleted {
            lock.unlock()
            return
        }
        isCancelled = true
        hasCompleted = true
        activeAttemptID = nil
        let taskToCancel = activeTask
        activeTask = nil
        let retryToCancel = pendingRetryWorkItem
        pendingRetryWorkItem = nil
        lock.unlock()

        // Invoke cancel() strictly OUTSIDE the lock so synchronous mock/URLSession cancellation callbacks cannot deadlock
        retryToCancel?.cancel()
        taskToCancel?.cancel()
        completionHandler(.failure(.cancelled))
    }
}

// MARK: - Transcription Client

public final class TranscriptionClient {
    private let transport: HTTPTransport
    private let lock = NSLock()
    private var activeOperation: TranscriptionOperationContext?

    /// Style-conditioning prompt used to guide Whisper punctuation and capitalization.
    public static let defaultConditioningPrompt = "Hello, how are you? I am speaking in English with proper grammar, punctuation, commas, and periods."

    public init(transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    /// Cancels any in-flight transcription request and any scheduled retry backoff immediately without holding internal locks during task cancellation.
    public func cancelCurrentRequest() {
        lock.lock()
        let op = activeOperation
        activeOperation = nil
        lock.unlock()

        op?.cancel()
    }

    /// Transcribes audio data with deterministic, bounded multi-key failover, lock-free cancellation, at-most-once completion, and explicit cross-provider privacy checks.
    public func transcribeAudio(
        audioData: Data,
        filename: String = "dictation.wav",
        credentials: [ResolvedCredential],
        allowCrossProviderFailover: Bool,
        timeoutInterval: TimeInterval = 20.0,
        maxSameKeyRetries: Int = 1,
        retryDelayScale: TimeInterval = 1.0,
        completion: @escaping (Result<TranscriptionSuccess, TranscriptionClientError>) -> Void
    ) {
        let operation = TranscriptionOperationContext(completion: completion)

        // Cancel any previous operation outside lock before starting the new one
        lock.lock()
        let previousOp = activeOperation
        activeOperation = operation
        lock.unlock()
        previousOp?.cancel()

        guard !credentials.isEmpty else {
            clearActiveOperationIfMatching(operation)
            operation.finishOnce(with: .failure(.noCredentialsConfigured))
            return
        }

        let initialProvider = credentials[0].metadata.provider

        attemptTranscription(
            operation: operation,
            audioData: audioData,
            filename: filename,
            credentials: credentials,
            keyIndex: 0,
            sameKeyRetryCount: 0,
            totalAttempts: 0,
            initialProvider: initialProvider,
            allowCrossProviderFailover: allowCrossProviderFailover,
            timeoutInterval: timeoutInterval,
            maxSameKeyRetries: maxSameKeyRetries,
            retryDelayScale: retryDelayScale,
            lastError: nil
        )
    }

    private func clearActiveOperationIfMatching(_ operation: TranscriptionOperationContext) {
        lock.lock()
        if activeOperation?.token == operation.token {
            activeOperation = nil
        }
        lock.unlock()
    }

    private func attemptTranscription(
        operation: TranscriptionOperationContext,
        audioData: Data,
        filename: String,
        credentials: [ResolvedCredential],
        keyIndex: Int,
        sameKeyRetryCount: Int,
        totalAttempts: Int,
        initialProvider: Provider,
        allowCrossProviderFailover: Bool,
        timeoutInterval: TimeInterval,
        maxSameKeyRetries: Int,
        retryDelayScale: TimeInterval,
        lastError: TranscriptionClientError?
    ) {
        guard operation.isActive else {
            return
        }

        guard keyIndex < credentials.count else {
            clearActiveOperationIfMatching(operation)
            if let lastError = lastError {
                if credentials.count == 1 {
                    operation.finishOnce(with: .failure(lastError))
                } else {
                    operation.finishOnce(with: .failure(.allKeysExhausted(lastErrorDescription: lastError.localizedDescription)))
                }
            } else {
                operation.finishOnce(with: .failure(.noCredentialsConfigured))
            }
            return
        }

        let currentCred = credentials[keyIndex]
        let provider = currentCred.metadata.provider

        // Enforce cross-provider privacy gate
        if provider != initialProvider && !allowCrossProviderFailover {
            clearActiveOperationIfMatching(operation)
            operation.finishOnce(with: .failure(.crossProviderFailoverBlocked(from: initialProvider, to: provider)))
            return
        }

        // Enforce provider-specific upload size limits before sending network traffic
        if audioData.count > provider.maxFileSizeBytes {
            clearActiveOperationIfMatching(operation)
            operation.finishOnce(with: .failure(.payloadTooLarge(provider: provider, maxBytes: provider.maxFileSizeBytes)))
            return
        }

        guard let attemptID = operation.beginAttempt() else {
            return
        }

        let request = Self.buildMultipartRequest(
            provider: provider,
            apiKey: currentCred.secret,
            audioData: audioData,
            filename: filename,
            timeoutInterval: timeoutInterval
        )

        let attemptNumber = totalAttempts + 1
        let task = transport.sendRequest(request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard operation.isCurrentAttemptValid(attemptID) else {
                return
            }

            let parsedResult = Self.evaluateResponse(
                provider: provider,
                data: data,
                response: response,
                error: error
            )

            switch parsedResult {
            case .success(let transcriptText):
                self.clearActiveOperationIfMatching(operation)
                operation.finishOnce(with: .success(TranscriptionSuccess(
                    text: transcriptText,
                    usedProvider: provider,
                    usedCredentialID: currentCred.metadata.id,
                    attemptsCount: attemptNumber
                )))

            case .failure(let clientError):
                if clientError == .cancelled {
                    self.clearActiveOperationIfMatching(operation)
                    operation.finishOnce(with: .failure(.cancelled))
                    return
                }

                // Do not retry or failover on fatal request errors (e.g. 400 Bad Request, 413 Too Large, Malformed JSON)
                guard clientError.shouldFailoverToNextKey else {
                    self.clearActiveOperationIfMatching(operation)
                    operation.finishOnce(with: .failure(clientError))
                    return
                }

                let hasNextKey = (keyIndex + 1) < credentials.count
                let nextKeySameProvider = hasNextKey && (credentials[keyIndex + 1].metadata.provider == initialProvider || allowCrossProviderFailover)

                if sameKeyRetryCount < maxSameKeyRetries && clientError.isTransientForSameKeyRetry && !nextKeySameProvider {
                    let baseWait: TimeInterval
                    if case .rateLimited(_, let retryAfter) = clientError, let headerWait = retryAfter {
                        baseWait = min(max(headerWait, 0.25), 3.0)
                    } else {
                        baseWait = 0.6
                    }
                    let delay = baseWait * retryDelayScale

                    var workItem: DispatchWorkItem!
                    workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        guard operation.isActive else { return }
                        self.attemptTranscription(
                            operation: operation,
                            audioData: audioData,
                            filename: filename,
                            credentials: credentials,
                            keyIndex: keyIndex,
                            sameKeyRetryCount: sameKeyRetryCount + 1,
                            totalAttempts: attemptNumber,
                            initialProvider: initialProvider,
                            allowCrossProviderFailover: allowCrossProviderFailover,
                            timeoutInterval: timeoutInterval,
                            maxSameKeyRetries: maxSameKeyRetries,
                            retryDelayScale: retryDelayScale,
                            lastError: clientError
                        )
                    }

                    if operation.registerRetryWorkItem(workItem, forAttemptID: attemptID) {
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: workItem)
                    }
                    return
                }

                SafeLogger.logInfo("Credential '\(currentCred.metadata.label)' (\(provider.shortName)) failed with \(clientError.localizedDescription). Failing over if backup keys exist.")

                self.attemptTranscription(
                    operation: operation,
                    audioData: audioData,
                    filename: filename,
                    credentials: credentials,
                    keyIndex: keyIndex + 1,
                    sameKeyRetryCount: 0,
                    totalAttempts: attemptNumber,
                    initialProvider: initialProvider,
                    allowCrossProviderFailover: allowCrossProviderFailover,
                    timeoutInterval: timeoutInterval,
                    maxSameKeyRetries: maxSameKeyRetries,
                    retryDelayScale: retryDelayScale,
                    lastError: clientError
                )
            }
        }

        // Register the task only if `attemptID` is still the current attempt.
        // If `transport.sendRequest` synchronously triggered failover to `attemptID + 1`, `registerTask` sees `activeAttemptID != attemptID`
        // and does NOT overwrite the newer attempt's task reference!
        let shouldCancelImmediately = operation.registerTask(task, forAttemptID: attemptID)
        if shouldCancelImmediately {
            task.cancel()
        }
    }

    // MARK: - Request Builder & Response Validator

    public static func buildMultipartRequest(
        provider: Provider,
        apiKey: String,
        audioData: Data,
        filename: String,
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutInterval

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField(name: "model", value: provider.modelName)
        appendFormField(name: "temperature", value: "0.0")
        appendFormField(name: "response_format", value: "json")
        appendFormField(name: "prompt", value: defaultConditioningPrompt)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        return request
    }

    public static func evaluateResponse(
        provider: Provider,
        data: Data?,
        response: HTTPURLResponse?,
        error: Error?
    ) -> Result<String, TranscriptionClientError> {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .failure(.cancelled)
            case .timedOut:
                return .failure(.networkTimeout(provider: provider))
            default:
                return .failure(.connectivityFailure(provider: provider, description: urlError.localizedDescription))
            }
        } else if let error = error {
            return .failure(.connectivityFailure(provider: provider, description: SafeLogger.redact(error.localizedDescription)))
        }

        guard let httpResponse = response else {
            return .failure(.connectivityFailure(provider: provider, description: "No HTTP response received."))
        }

        let statusCode = httpResponse.statusCode

        switch statusCode {
        case 200:
            guard let data = data,
                  let jsonObj = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = jsonObj as? [String: Any],
                  let text = dict["text"] as? String else {
                return .failure(.malformedResponse(provider: provider))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(trimmed)

        case 401, 403:
            return .failure(.authenticationFailed(provider: provider))

        case 413:
            return .failure(.payloadTooLarge(provider: provider, maxBytes: provider.maxFileSizeBytes))

        case 429:
            let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") ??
                                   httpResponse.value(forHTTPHeaderField: "retry-after")
            let retryAfter = retryAfterHeader.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }

            if let data = data,
               let bodyStr = String(data: data, encoding: .utf8)?.lowercased(),
               bodyStr.contains("insufficient_quota") || bodyStr.contains("billing") {
                return .failure(.quotaExceeded(provider: provider))
            }
            return .failure(.rateLimited(provider: provider, retryAfterSeconds: retryAfter))

        case 400, 404, 415, 422:
            var reason = "HTTP \(statusCode)"
            if let data = data,
               let jsonObj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let errObj = jsonObj["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                reason = SafeLogger.redact(msg)
            }
            return .failure(.badRequest(provider: provider, reason: reason))

        case 500...599:
            return .failure(.serverError(provider: provider, statusCode: statusCode))

        default:
            return .failure(.serverError(provider: provider, statusCode: statusCode))
        }
    }
}

// MARK: - Secure API Key Validation & Connection Testing

public enum APIKeyValidationStatus: Equatable {
    case notTested
    case checking
    case verified(provider: Provider, modelName: String)
    case invalidKey(provider: Provider, reason: String)
    case rateLimited(provider: Provider, retryAfterSeconds: TimeInterval?)
    case modelUnavailable(provider: Provider, modelName: String)
    case networkUnavailable(provider: Provider, reason: String)
    case serverError(provider: Provider, statusCode: Int)

    public var isSuccess: Bool {
        if case .verified = self { return true }
        return false
    }

    public var displayMessage: String {
        switch self {
        case .notTested:
            return "Key has not been tested yet."
        case .checking:
            return "Checking connection to provider..."
        case .verified(let provider, let model):
            return "Connection Successful! \(provider.shortName) accepted your key. Model: \(model) ✓"
        case .invalidKey(let provider, let reason):
            return "Invalid API Key: \(provider.shortName) rejected the key (\(reason))."
        case .rateLimited(let provider, let retryAfter):
            if let wait = retryAfter, wait > 0 {
                return "\(provider.shortName) rate limit reached (HTTP 429). Try again in \(Int(ceil(wait)))s."
            }
            return "\(provider.shortName) rate limit reached (HTTP 429). Please wait a moment."
        case .modelUnavailable(let provider, let model):
            return "Connected to \(provider.shortName), but required model '\(model)' was not found in available models."
        case .networkUnavailable(let provider, let reason):
            return "Network unavailable: Could not reach \(provider.shortName) (\(reason))."
        case .serverError(let provider, let code):
            return "\(provider.shortName) server error (HTTP \(code)). Please try again shortly."
        }
    }
}

public final class APIKeyValidator {
    public static let shared = APIKeyValidator()

    private let transport: HTTPTransport
    private let lock = NSLock()
    private var currentTask: CancellableTask?
    private var currentRequestGeneration: Int = 0

    public init(transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.transport = transport
    }

    /// Verifies the given API key against the provider's /v1/models endpoint asynchronously.
    /// Does NOT transmit any microphone audio or personal user data.
    public func validateKey(
        rawKey: String,
        provider: Provider,
        completion: @escaping (APIKeyValidationStatus) -> Void
    ) {
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            completion(.invalidKey(provider: provider, reason: "Key cannot be empty."))
            return
        }

        // Take ownership of the prior task under lock, then cancel it after unlocking.
        // A transport is permitted to invoke its completion synchronously from cancel().
        lock.lock()
        let obsoleteTask = currentTask
        currentTask = nil
        currentRequestGeneration += 1
        let thisGeneration = currentRequestGeneration
        lock.unlock()
        obsoleteTask?.cancel()

        let endpointURL: URL
        let expectedModel: String
        switch provider {
        case .groq:
            endpointURL = URL(string: "https://api.groq.com/openai/v1/models")!
            expectedModel = "whisper-large-v3-turbo"
        case .openai:
            endpointURL = URL(string: "https://api.openai.com/v1/models")!
            expectedModel = "whisper-1"
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10.0

        let task = transport.sendRequest(request) { [weak self] data, response, error in
            guard let self = self else { return }

            self.lock.lock()
            guard thisGeneration == self.currentRequestGeneration else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            let result = self.parseModelsResponse(
                data: data,
                response: response,
                error: error,
                provider: provider,
                expectedModel: expectedModel
            )

            DispatchQueue.main.async {
                self.lock.lock()
                guard thisGeneration == self.currentRequestGeneration else {
                    self.lock.unlock()
                    return
                }
                self.lock.unlock()
                completion(result)
            }
        }

        lock.lock()
        if thisGeneration == currentRequestGeneration {
            currentTask = task
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        currentRequestGeneration += 1
        let taskToCancel = currentTask
        currentTask = nil
        lock.unlock()
        // Never call a transport's cancellation callback while holding this lock.
        taskToCancel?.cancel()
    }

    private func parseModelsResponse(
        data: Data?,
        response: HTTPURLResponse?,
        error: Error?,
        provider: Provider,
        expectedModel: String
    ) -> APIKeyValidationStatus {
        if let err = error as NSError? {
            if err.domain == NSURLErrorDomain && err.code == NSURLErrorCancelled {
                return .notTested
            }
            if err.domain == NSURLErrorDomain && err.code == NSURLErrorTimedOut {
                return .networkUnavailable(provider: provider, reason: "Connection timed out (10s)")
            }
            return .networkUnavailable(provider: provider, reason: SafeLogger.redact(err.localizedDescription))
        }

        guard let httpResponse = response else {
            return .networkUnavailable(provider: provider, reason: "No response from server")
        }

        let statusCode = httpResponse.statusCode
        switch statusCode {
        case 200:
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return .serverError(provider: provider, statusCode: 200)
            }

            // Verify the exact model this app will request for transcription.
            // Seeing a different Whisper model must not be reported as success.
            guard let modelList = json["data"] as? [[String: Any]],
                  modelList.contains(where: { item in
                      guard let modelID = item["id"] as? String else { return false }
                      return modelID.caseInsensitiveCompare(expectedModel) == .orderedSame
                  }) else {
                return .modelUnavailable(provider: provider, modelName: expectedModel)
            }
            return .verified(provider: provider, modelName: expectedModel)

        case 401, 403:
            return .invalidKey(provider: provider, reason: "HTTP \(statusCode)")

        case 429:
            let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") ??
                              httpResponse.value(forHTTPHeaderField: "retry-after")
            let retryAfter = retryHeader.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(provider: provider, retryAfterSeconds: retryAfter)

        case 500...599:
            return .serverError(provider: provider, statusCode: statusCode)

        default:
            return .invalidKey(provider: provider, reason: "HTTP \(statusCode)")
        }
    }
}

// ============================================================================
// FILE: KeyboardShortcutMonitor.swift
// ============================================================================
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

// ============================================================================
// FILE: TextInsertionManager.swift
// ============================================================================
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

// ============================================================================
// FILE: SnippetManager.swift
// ============================================================================
// MARK: - Snippet Validation & Persistence Errors

public enum SnippetError: LocalizedError, Equatable {
    case emptyTrigger
    case emptyValue
    case duplicateTrigger(String)
    case malformedJSONFile(path: String, underlyingDescription: String)
    case recoverySafetyBackupFailed(path: String, reason: String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTrigger:
            return "Voice trigger phrase cannot be empty."
        case .emptyValue:
            return "Replacement value cannot be empty."
        case .duplicateTrigger(let trigger):
            return "A snippet with the trigger \"\(trigger)\" already exists."
        case .malformedJSONFile(let path, let reason):
            return "Your snippets file at \(path) contains invalid JSON (\(reason)). To prevent data loss, QuickDictate did not overwrite it. You can fix the JSON manually or restore from backup."
        case .recoverySafetyBackupFailed(let path, let reason):
            return "Aborted snippet recovery because the existing file could not be safely backed up to \(path) (\(reason)). Your original file was left untouched."
        case .writeFailed(let reason):
            return "Failed to save snippets file: \(reason)"
        }
    }
}

// MARK: - File Operations Abstraction for Transactional Recovery Testing

public protocol SnippetFileStorage {
    func fileExists(atPath path: String) -> Bool
    func readData(atPath path: String) throws -> Data
    func writeDataAtomically(_ data: Data, toPath path: String, permissions: Int) throws
    func copyFile(fromPath srcPath: String, toPath dstPath: String, permissions: Int) throws
}

public struct SystemSnippetFileStorage: SnippetFileStorage {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileExists(atPath path: String) -> Bool {
        return fileManager.fileExists(atPath: path)
    }

    public func readData(atPath path: String) throws -> Data {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeDataAtomically(_ data: Data, toPath path: String, permissions: Int) throws {
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    public func copyFile(fromPath srcPath: String, toPath dstPath: String, permissions: Int) throws {
        if fileManager.fileExists(atPath: dstPath) {
            try fileManager.removeItem(atPath: dstPath)
        }
        try fileManager.copyItem(atPath: srcPath, toPath: dstPath)
        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: dstPath)
    }
}

// MARK: - Snippet Manager

public final class SnippetManager {
    public static let shared = SnippetManager()

    public let filePath: String
    private let legacyEnabledFilePath: String
    private let storage: SnippetFileStorage
    public private(set) var snippets: [Snippet] = []
    public private(set) var lastLoadError: SnippetError?

    public init(
        filePath: String = NSString(string: "~/.quickdictate_snippets.json").expandingTildeInPath,
        legacyEnabledFilePath: String = NSString(string: "~/.quickdictate_snippets_enabled").expandingTildeInPath,
        storage: SnippetFileStorage = SystemSnippetFileStorage()
    ) {
        self.filePath = filePath
        self.legacyEnabledFilePath = legacyEnabledFilePath
        self.storage = storage
        _ = loadSnippets()
    }

    public static var defaultExamples: [Snippet] {
        return [
            Snippet(trigger: "enter email", value: "user@example.com"),
            Snippet(trigger: "enter work email", value: "work@example.com"),
            Snippet(trigger: "enter phone", value: "+1 (555) 123-4567"),
            Snippet(trigger: "enter signature", value: "Best regards,\nYour Name")
        ]
    }

    /// Loads snippets from disk.
    /// CRITICAL DATA-PROTECTION INVARIANT:
    /// - If the file does NOT exist at all, initializes with default sample snippets and writes them atomically.
    /// - If the file DOES exist and is valid JSON, loads the user's snippets in their exact defined order and refreshes the `.bak` last-known-good backup if needed.
    /// - If the file DOES exist but is malformed/corrupted JSON, preserves the original file untouched,
    ///   NEVER overwrites it with defaults, records `lastLoadError`, and returns `.failure`.
    @discardableResult
    public func loadSnippets() -> Result<[Snippet], SnippetError> {
        guard storage.fileExists(atPath: filePath) else {
            self.snippets = Self.defaultExamples
            self.lastLoadError = nil
            _ = try? save()
            return .success(self.snippets)
        }

        do {
            let data = try storage.readData(atPath: filePath)
            let decoded = try JSONDecoder().decode([Snippet].self, from: data)
            self.snippets = decoded
            self.lastLoadError = nil
            // Maintain a genuine last-known-good backup whenever a valid file is loaded
            let backupPath = filePath + ".bak"
            if let encodedValid = try? Self.encodeSnippets(decoded) {
                try? storage.writeDataAtomically(encodedValid, toPath: backupPath, permissions: 0o600)
            }
            return .success(decoded)
        } catch {
            let err = SnippetError.malformedJSONFile(path: filePath, underlyingDescription: error.localizedDescription)
            self.lastLoadError = err
            SafeLogger.logError(err.localizedDescription)
            return .failure(err)
        }
    }

    private static func encodeSnippets(_ list: [Snippet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(list)
    }

    /// Atomically saves the current snippet list with 0600 permissions, and updates the `.bak` last-known-good backup only after verifying the encoded payload decodes cleanly.
    public func save() throws {
        // Refuse to automatically overwrite a corrupted file while `lastLoadError` is active unless explicitly recovered
        if let loadErr = lastLoadError {
            throw loadErr
        }

        let data: Data
        do {
            data = try Self.encodeSnippets(snippets)
            // Verify payload decodes before touching disk
            _ = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            throw SnippetError.writeFailed(error.localizedDescription)
        }

        do {
            // If an existing valid primary file exists on disk, preserve it into `.bak` before writing the new version
            if storage.fileExists(atPath: filePath),
               let currentDiskData = try? storage.readData(atPath: filePath),
               (try? JSONDecoder().decode([Snippet].self, from: currentDiskData)) != nil {
                try? storage.writeDataAtomically(currentDiskData, toPath: filePath + ".bak", permissions: 0o600)
            }

            try storage.writeDataAtomically(data, toPath: filePath, permissions: 0o600)

            // Update `.bak` to reflect the newly verified good state
            try? storage.writeDataAtomically(data, toPath: filePath + ".bak", permissions: 0o600)
        } catch {
            throw SnippetError.writeFailed(error.localizedDescription)
        }
    }

    /// Transactional, fail-closed recovery from a malformed `~/.quickdictate_snippets.json` file:
    /// 1. If the malformed file exists on disk, creates a byte-identical safety backup (`<filePath>.corrupted-<timestamp>-<UUID>`)
    ///    and verifies that the backup file exists and its bytes match the original file 100%.
    /// 2. If creating or verifying the safety backup fails for ANY reason, immediately aborts and throws `.recoverySafetyBackupFailed`
    ///    without modifying the original file or clearing `lastLoadError`.
    /// 3. Determines replacement snippets from `.bak` (only if `.bak` exists AND decodes as valid `[Snippet]`; otherwise falls back to `defaultExamples`).
    /// 4. Atomically writes the recovered JSON to `filePath`. If the write fails, preserves `snippets` and `lastLoadError` and throws `.writeFailed`.
    @discardableResult
    public func recoverFromMalformedFile(useBackupIfAvailable: Bool = true) throws -> URL? {
        var verifiedSafetyBackupURL: URL? = nil

        if storage.fileExists(atPath: filePath) {
            let timestamp = Int(Date().timeIntervalSince1970)
            let shortID = String(UUID().uuidString.prefix(8))
            let safetyBackupPath = "\(filePath).corrupted-\(timestamp)-\(shortID)"

            let originalBytes: Data
            do {
                originalBytes = try storage.readData(atPath: filePath)
            } catch {
                throw SnippetError.recoverySafetyBackupFailed(
                    path: safetyBackupPath,
                    reason: "Could not read original file bytes: \(error.localizedDescription)"
                )
            }

            do {
                try storage.copyFile(fromPath: filePath, toPath: safetyBackupPath, permissions: 0o600)
            } catch {
                throw SnippetError.recoverySafetyBackupFailed(
                    path: safetyBackupPath,
                    reason: error.localizedDescription
                )
            }

            // Strictly verify the safety backup exists and is byte-for-byte identical to the original malformed file
            guard storage.fileExists(atPath: safetyBackupPath),
                  let backupBytes = try? storage.readData(atPath: safetyBackupPath),
                  backupBytes == originalBytes else {
                throw SnippetError.recoverySafetyBackupFailed(
                    path: safetyBackupPath,
                    reason: "Safety backup verification failed (byte mismatch or unreadable backup)."
                )
            }

            verifiedSafetyBackupURL = URL(fileURLWithPath: safetyBackupPath)
        }

        // Determine candidate snippets from last-known-good `.bak` if valid, otherwise defaultExamples
        let backupPath = filePath + ".bak"
        let candidateSnippets: [Snippet]
        if useBackupIfAvailable,
           storage.fileExists(atPath: backupPath),
           let bakData = try? storage.readData(atPath: backupPath),
           let decodedBak = try? JSONDecoder().decode([Snippet].self, from: bakData) {
            candidateSnippets = decodedBak
        } else {
            candidateSnippets = Self.defaultExamples
        }

        // Encode and write atomically BEFORE mutating in-memory state so a write failure stays fail-closed
        let encodedCandidate: Data
        do {
            encodedCandidate = try Self.encodeSnippets(candidateSnippets)
        } catch {
            throw SnippetError.writeFailed(error.localizedDescription)
        }

        do {
            try storage.writeDataAtomically(encodedCandidate, toPath: filePath, permissions: 0o600)
            try? storage.writeDataAtomically(encodedCandidate, toPath: backupPath, permissions: 0o600)
        } catch {
            throw SnippetError.writeFailed(error.localizedDescription)
        }

        self.snippets = candidateSnippets
        self.lastLoadError = nil
        return verifiedSafetyBackupURL
    }

    // MARK: - Add / Update / Delete with Validation

    public func upsertSnippet(trigger: String, value: String, editingIndex: Int? = nil) throws {
        if let loadErr = lastLoadError {
            throw loadErr
        }

        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve internal newlines in multiline values while trimming leading/trailing spaces/newlines
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanTrigger.isEmpty else {
            throw SnippetError.emptyTrigger
        }
        guard !cleanValue.isEmpty else {
            throw SnippetError.emptyValue
        }

        let normalizedNew = cleanTrigger.lowercased()

        // Check for duplicate triggers
        for (idx, existing) in snippets.enumerated() {
            if idx != editingIndex && existing.trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedNew {
                throw SnippetError.duplicateTrigger(existing.trigger)
            }
        }

        var updatedList = snippets
        if let editIdx = editingIndex, editIdx >= 0, editIdx < updatedList.count {
            updatedList[editIdx] = Snippet(trigger: cleanTrigger, value: cleanValue)
        } else {
            updatedList.append(Snippet(trigger: cleanTrigger, value: cleanValue))
        }

        let previousList = snippets
        snippets = updatedList
        do {
            try save()
        } catch {
            snippets = previousList
            throw error
        }
    }

    public func deleteSnippet(at index: Int) throws {
        if let loadErr = lastLoadError {
            throw loadErr
        }
        guard index >= 0 && index < snippets.count else { return }
        let previousList = snippets
        snippets.remove(at: index)
        do {
            try save()
        } catch {
            snippets = previousList
            throw error
        }
    }

    // MARK: - Deterministic Voice Snippet Expansion Engine

    /// Expands voice snippets in `text`:
    /// 1. Exact standalone command match (case-insensitive, ignoring surrounding punctuation).
    /// 2. Inline phrase replacement sorted by trigger length descending, with Unicode-aware token boundaries
    ///    and full `NSRegularExpression.escapedPattern` / `escapedTemplate` protection for `$1`, `\`, Unicode, and multiline values.
    public func expand(in text: String, isEnabled: Bool = true) -> String {
        guard isEnabled, !snippets.isEmpty else { return text }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return text }

        let punctuationTrimSet = CharacterSet(charactersIn: ".?!,;:\"'()[]{}")
        let normalizedStandalone = clean
            .trimmingCharacters(in: punctuationTrimSet)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // 1. Standalone exact voice command match (preserves user-defined snippet order for first match)
        for s in snippets {
            let triggerNorm = s.trigger
                .trimmingCharacters(in: punctuationTrimSet)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !triggerNorm.isEmpty && normalizedStandalone == triggerNorm {
                return s.value
            }
        }

        // 2. Inline phrase expansion
        // Deterministic precedence: longer trigger phrases match first to prevent partial prefix collisions;
        // ties preserve the user's defined snippet order.
        var result = text
        let indexedSnippets = snippets.enumerated().sorted { lhs, rhs in
            let lenA = lhs.element.trigger.count
            let lenB = rhs.element.trigger.count
            if lenA != lenB {
                return lenA > lenB
            }
            return lhs.offset < rhs.offset
        }

        for (_, snippet) in indexedSnippets {
            let rawTrigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTrigger.isEmpty else { continue }

            let escapedTrigger = NSRegularExpression.escapedPattern(for: rawTrigger)
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + escapedTrigger + "(?![\\p{L}\\p{N}_])"

            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: result.utf16.count)
                let escapedTemplate = NSRegularExpression.escapedTemplate(for: snippet.value)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: escapedTemplate)
            }
        }

        return result
    }

    public func filteredSnippets(query: String) -> [(originalIndex: Int, snippet: Snippet)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allIndexed = snippets.enumerated().map { (originalIndex: $0.offset, snippet: $0.element) }
        guard !trimmed.isEmpty else {
            return allIndexed
        }
        return allIndexed.filter {
            $0.snippet.trigger.lowercased().contains(trimmed) ||
            $0.snippet.value.lowercased().contains(trimmed)
        }
    }
}

// MARK: - Voice Snippets Management Window (with Search, Multiline Editor, Validation & Recovery)

public final class SnippetWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public static let shared = SnippetWindowController()

    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var triggerField: NSTextField!
    private var valueTextView: NSTextView!
    private var statusBannerLabel: NSTextField!
    private var recoverButton: NSButton!

    private var displayedRows: [(originalIndex: Int, snippet: Snippet)] = []
    private var selectedOriginalIndex: Int?

    public init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "QuickDictate — Voice Snippets Manager"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        let headerLbl = NSTextField(labelWithString: "Speak a trigger phrase standalone or inline to expand into its replacement text.")
        headerLbl.frame = NSRect(x: 20, y: 482, width: 600, height: 20)
        headerLbl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        cv.addSubview(headerLbl)

        // Search Field
        searchField = NSSearchField(frame: NSRect(x: 20, y: 446, width: 600, height: 26))
        searchField.placeholderString = "Search snippets by trigger phrase or replacement text..."
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.setAccessibilityLabel("Search voice snippets")
        cv.addSubview(searchField)

        // Table View
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 225, width: 600, height: 210))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView(frame: scrollView.bounds)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 26

        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trigger"))
        col1.title = "Voice Trigger (What You Say)"
        col1.width = 210
        tableView.addTableColumn(col1)

        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        col2.title = "Replacement Value (Multiline Supported)"
        col2.width = 370
        tableView.addTableColumn(col2)

        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        cv.addSubview(scrollView)

        // Input Controls (Trigger + Multiline Value)
        let lblTrigger = NSTextField(labelWithString: "Voice Trigger Phrase:")
        lblTrigger.frame = NSRect(x: 20, y: 195, width: 220, height: 18)
        lblTrigger.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        cv.addSubview(lblTrigger)

        triggerField = NSTextField(frame: NSRect(x: 20, y: 166, width: 230, height: 24))
        triggerField.placeholderString = "e.g. enter signature"
        triggerField.setAccessibilityLabel("Voice trigger phrase")
        cv.addSubview(triggerField)

        let newBtn = NSButton(title: "Clear / New", target: self, action: #selector(clearSelectionAction))
        newBtn.frame = NSRect(x: 20, y: 130, width: 110, height: 28)
        newBtn.bezelStyle = .rounded
        cv.addSubview(newBtn)

        let lblValue = NSTextField(labelWithString: "Replacement Value (Multiline Supported):")
        lblValue.frame = NSRect(x: 270, y: 195, width: 350, height: 18)
        lblValue.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        cv.addSubview(lblValue)

        let valueScroll = NSScrollView(frame: NSRect(x: 270, y: 102, width: 350, height: 88))
        valueScroll.hasVerticalScroller = true
        valueScroll.borderType = .bezelBorder

        valueTextView = NSTextView(frame: valueScroll.bounds)
        valueTextView.isRichText = false
        valueTextView.font = NSFont.systemFont(ofSize: 12)
        valueTextView.isVerticallyResizable = true
        valueTextView.isHorizontallyResizable = false
        valueTextView.textContainer?.widthTracksTextView = true
        valueTextView.setAccessibilityLabel("Snippet replacement value")
        valueScroll.documentView = valueTextView
        cv.addSubview(valueScroll)

        // Status / Error Banner
        statusBannerLabel = NSTextField(labelWithString: "")
        statusBannerLabel.frame = NSRect(x: 20, y: 66, width: 470, height: 28)
        statusBannerLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusBannerLabel.textColor = .systemRed
        statusBannerLabel.cell?.wraps = true
        cv.addSubview(statusBannerLabel)

        recoverButton = NSButton(title: "Recover JSON...", target: self, action: #selector(recoverMalformedAction))
        recoverButton.frame = NSRect(x: 500, y: 66, width: 120, height: 28)
        recoverButton.bezelStyle = .rounded
        recoverButton.isHidden = true
        cv.addSubview(recoverButton)

        // Action Buttons
        let saveBtn = NSButton(title: "Save / Update Snippet", target: self, action: #selector(saveAction))
        saveBtn.frame = NSRect(x: 20, y: 20, width: 175, height: 32)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        cv.addSubview(saveBtn)

        let delBtn = NSButton(title: "Delete Selected", target: self, action: #selector(deleteAction))
        delBtn.frame = NSRect(x: 205, y: 20, width: 135, height: 32)
        delBtn.bezelStyle = .rounded
        cv.addSubview(delBtn)

        let openJsonBtn = NSButton(title: "Open JSON File", target: self, action: #selector(openJsonAction))
        openJsonBtn.frame = NSRect(x: 350, y: 20, width: 135, height: 32)
        openJsonBtn.bezelStyle = .rounded
        cv.addSubview(openJsonBtn)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeAction))
        closeBtn.frame = NSRect(x: 535, y: 20, width: 85, height: 32)
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        cv.addSubview(closeBtn)
    }

    public func show() {
        let loadResult = SnippetManager.shared.loadSnippets()
        switch loadResult {
        case .success:
            statusBannerLabel.stringValue = ""
            recoverButton.isHidden = true
        case .failure(let err):
            statusBannerLabel.textColor = .systemRed
            statusBannerLabel.stringValue = err.localizedDescription
            recoverButton.isHidden = false
        }
        refreshFilteredRows()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshFilteredRows() {
        displayedRows = SnippetManager.shared.filteredSnippets(query: searchField.stringValue)
        tableView.reloadData()
    }

    @objc private func searchFieldChanged() {
        refreshFilteredRows()
    }

    public func controlTextDidChange(_ obj: Notification) {
        refreshFilteredRows()
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedRows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < displayedRows.count else { return nil }
        let item = displayedRows[row].snippet
        let rawText = (tableColumn?.identifier.rawValue == "trigger") ? item.trigger : item.value.replacingOccurrences(of: "\n", with: " ⏎ ")

        let cell = NSTextField(labelWithString: rawText)
        cell.font = NSFont.systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < displayedRows.count {
            let entry = displayedRows[row]
            selectedOriginalIndex = entry.originalIndex
            triggerField.stringValue = entry.snippet.trigger
            valueTextView.string = entry.snippet.value
            statusBannerLabel.stringValue = ""
        } else {
            selectedOriginalIndex = nil
        }
    }

    @objc private func clearSelectionAction() {
        tableView.deselectAll(nil)
        selectedOriginalIndex = nil
        triggerField.stringValue = ""
        valueTextView.string = ""
        statusBannerLabel.stringValue = ""
        window?.makeFirstResponder(triggerField)
    }

    @objc private func saveAction() {
        do {
            try SnippetManager.shared.upsertSnippet(
                trigger: triggerField.stringValue,
                value: valueTextView.string,
                editingIndex: selectedOriginalIndex
            )
            statusBannerLabel.textColor = .systemGreen
            statusBannerLabel.stringValue = "Saved snippet \"\(triggerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))\"."
            clearSelectionAction()
            refreshFilteredRows()
        } catch {
            statusBannerLabel.textColor = .systemRed
            statusBannerLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func deleteAction() {
        guard let origIdx = selectedOriginalIndex else {
            statusBannerLabel.textColor = .systemRed
            statusBannerLabel.stringValue = "Select a snippet row to delete."
            return
        }
        do {
            try SnippetManager.shared.deleteSnippet(at: origIdx)
            clearSelectionAction()
            refreshFilteredRows()
        } catch {
            statusBannerLabel.textColor = .systemRed
            statusBannerLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func recoverMalformedAction() {
        let alert = NSAlert()
        alert.messageText = "Recover Malformed Snippets File"
        alert.informativeText = "QuickDictate preserved your existing ~/.quickdictate_snippets.json file because it contained invalid JSON syntax.\n\nWould you like to open the file to fix the syntax manually, or create a verified backup of the broken file and restore from the last valid backup?"
        alert.addButton(withTitle: "Open in Editor")
        alert.addButton(withTitle: "Backup Broken File & Restore")
        alert.addButton(withTitle: "Cancel")

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            openJsonAction()
        } else if resp == .alertSecondButtonReturn {
            do {
                let backupURL = try SnippetManager.shared.recoverFromMalformedFile(useBackupIfAvailable: true)
                statusBannerLabel.textColor = .systemGreen
                if let backupName = backupURL?.lastPathComponent {
                    statusBannerLabel.stringValue = "Recovered snippets configuration. Original file backed up to \(backupName)."
                } else {
                    statusBannerLabel.stringValue = "Recovered snippets configuration."
                }
                recoverButton.isHidden = true
                refreshFilteredRows()
            } catch {
                statusBannerLabel.textColor = .systemRed
                statusBannerLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func openJsonAction() {
        NSWorkspace.shared.open(URL(fileURLWithPath: SnippetManager.shared.filePath))
    }

    @objc private func closeAction() {
        window?.close()
    }
}

// ============================================================================
// FILE: PreferencesAndHUD.swift
// ============================================================================
// MARK: - Preferences Store

public final class PreferencesManager {
    public static let shared = PreferencesManager()

    private let defaults: UserDefaults

    private enum Keys {
        static let preferredProvider = "QuickDictate.PreferredProvider"
        static let allowCrossProviderFailover = "QuickDictate.AllowCrossProviderFailover"
        static let shortcutOption = "QuickDictate.ShortcutOption"
        static let customKeyCombo = "QuickDictate.CustomKeyCombo"
        static let showDockIcon = "QuickDictate.ShowDockIcon"
        static let onboardingCompleted = "QuickDictate.OnboardingCompleted"
        static let onboardingCurrentStep = "QuickDictate.OnboardingCurrentStep"
        static let snippetsEnabled = "QuickDictate.SnippetsEnabled"
        static let periodicPreviewEnabled = "QuickDictate.PeriodicPreviewEnabled"
        static let soundFeedbackEnabled = "QuickDictate.SoundFeedbackEnabled"
        static let legacyPrefsMigrated = "QuickDictate.LegacyPrefsMigrated"
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        migrateLegacyDotfilePreferencesIfNeeded()
    }

    public var preferredProvider: Provider {
        get {
            if let raw = defaults.string(forKey: Keys.preferredProvider),
               let p = Provider(rawValue: raw) {
                return p
            }
            return .groq
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.preferredProvider)
        }
    }

    /// Defaults to `false` so no recording is ever sent to a different cloud provider without explicit user consent.
    public var allowCrossProviderFailover: Bool {
        get {
            return defaults.bool(forKey: Keys.allowCrossProviderFailover)
        }
        set {
            defaults.set(newValue, forKey: Keys.allowCrossProviderFailover)
        }
    }

    public var shortcutOption: ShortcutOption {
        get {
            if let raw = defaults.string(forKey: Keys.shortcutOption),
               let opt = ShortcutOption(rawValue: raw) {
                return opt
            }
            return .rightOption
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.shortcutOption)
        }
    }

    public var customKeyCombo: KeyCombo {
        get {
            if let data = defaults.data(forKey: Keys.customKeyCombo),
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                return combo
            }
            return KeyCombo.defaultCustom
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.customKeyCombo)
            }
        }
    }

    public var showDockIcon: Bool {
        get {
            if defaults.object(forKey: Keys.showDockIcon) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showDockIcon)
        }
        set {
            defaults.set(newValue, forKey: Keys.showDockIcon)
        }
    }

    public var isOnboardingCompleted: Bool {
        get {
            return defaults.bool(forKey: Keys.onboardingCompleted)
        }
        set {
            defaults.set(newValue, forKey: Keys.onboardingCompleted)
        }
    }

    public var onboardingCurrentStep: Int {
        get {
            let val = defaults.integer(forKey: Keys.onboardingCurrentStep)
            return (val >= 1 && val <= 6) ? val : 1
        }
        set {
            defaults.set(newValue, forKey: Keys.onboardingCurrentStep)
        }
    }

    public func isSetupFullyConfigured(credentialManager: KeychainCredentialManager = .shared) -> Bool {
        guard isOnboardingCompleted else { return false }
        let creds = credentialManager.resolveCredentials(
            preferredProvider: preferredProvider,
            allowCrossProviderFailover: allowCrossProviderFailover
        )
        guard !creds.isEmpty else { return false }
        return true
    }

    public var isSetupFullyConfigured: Bool {
        return isSetupFullyConfigured(credentialManager: .shared)
    }

    public var isSnippetsEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.snippetsEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.snippetsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.snippetsEnabled)
        }
    }

    /// Defaults to `false` (disabled by default) because periodic preview uploads consume extra API quota.
    public var isPeriodicPreviewEnabled: Bool {
        get {
            return defaults.bool(forKey: Keys.periodicPreviewEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.periodicPreviewEnabled)
        }
    }

    public var isSoundFeedbackEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.soundFeedbackEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.soundFeedbackEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.soundFeedbackEnabled)
        }
    }

    /// Migrates legacy `~/.quickdictate_snippets_enabled` and `~/.quickdictate_live` files once if present.
    public func migrateLegacyDotfilePreferencesIfNeeded(fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: Keys.legacyPrefsMigrated) else { return }

        let snipPath = NSString(string: "~/.quickdictate_snippets_enabled").expandingTildeInPath
        if let val = try? String(contentsOfFile: snipPath, encoding: .utf8) {
            let enabled = (val.trimmingCharacters(in: .whitespacesAndNewlines) != "0")
            defaults.set(enabled, forKey: Keys.snippetsEnabled)
            try? fileManager.removeItem(atPath: snipPath)
        }

        let livePath = NSString(string: "~/.quickdictate_live").expandingTildeInPath
        if let val = try? String(contentsOfFile: livePath, encoding: .utf8) {
            let enabled = (val.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            defaults.set(enabled, forKey: Keys.periodicPreviewEnabled)
            try? fileManager.removeItem(atPath: livePath)
        }

        defaults.set(true, forKey: Keys.legacyPrefsMigrated)
    }
}

// MARK: - Launch at Login Controller (macOS 13+ SMAppService + macOS 12 Fallback)

public final class LaunchAtLoginController {
    public static let shared = LaunchAtLoginController()

    public init() {}

    public var isSupportedNatively: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    public var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    public func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } else {
            // On macOS 12 Monterey, SMAppService.mainApp is unavailable without a helper bundle;
            // open System Preferences -> Users & Groups -> Login Items so the user remains in full control.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Sound Feedback Player (Supported NSSound APIs)

public final class SoundFeedbackPlayer {
    public static let shared = SoundFeedbackPlayer()

    public init() {}

    public func play(_ type: SoundType, enabled: Bool) {
        guard enabled else { return }
        DispatchQueue.main.async {
            let soundName: NSSound.Name
            switch type {
            case .startRecording:
                soundName = NSSound.Name("Tink")
            case .stopRecording:
                soundName = NSSound.Name("Pop")
            case .error:
                soundName = NSSound.Name("Basso")
            }
            if let sound = NSSound(named: soundName) {
                sound.stop()
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    }
}

// MARK: - HUD Window Controller

public final class HUDWindowController {
    public static let shared = HUDWindowController()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var bgView: NSVisualEffectView?
    private var fadeTimer: Timer?

    public init() {
        if Thread.isMainThread {
            createPanel()
        } else {
            DispatchQueue.main.sync {
                self.createPanel()
            }
        }
    }

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 50),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 25
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1.0
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        p.contentView?.addSubview(bg)

        let lbl = NSTextField(frame: NSRect(x: 16, y: 8, width: 248, height: 34))
        lbl.isBezeled = false
        lbl.drawsBackground = false
        lbl.isEditable = false
        lbl.isSelectable = false
        lbl.alignment = .center
        lbl.textColor = .white
        lbl.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        lbl.cell?.wraps = true
        lbl.cell?.truncatesLastVisibleLine = true
        bg.addSubview(lbl)

        self.panel = p
        self.label = lbl
        self.bgView = bg
    }

    public func show(text: String, autoDismiss: Double? = nil) {
        let work = { [weak self] in
            guard let self = self, let p = self.panel, let lbl = self.label, let bg = self.bgView else { return }

            self.fadeTimer?.invalidate()
            self.fadeTimer = nil
            lbl.stringValue = text

            let textLen = text.count
            let idealWidth = min(max(CGFloat(textLen * 9 + 60), 220), 650)
            let height: CGFloat = textLen > 55 ? 74 : 50

            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let x = screenRect.midX - (idealWidth / 2)
                let y = screenRect.minY + 65
                p.setFrame(NSRect(x: x, y: y, width: idealWidth, height: height), display: true)
                bg.frame = p.contentView!.bounds
                bg.layer?.cornerRadius = height / 2
                lbl.frame = NSRect(x: 16, y: 8, width: idealWidth - 32, height: height - 16)
            }

            p.alphaValue = 1.0
            p.orderFrontRegardless()

            if let delay = autoDismiss {
                self.fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.hide()
                }
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    public func hide() {
        let work = { [weak self] in
            guard let p = self?.panel else { return }
            self?.fadeTimer?.invalidate()
            self?.fadeTimer = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.20
                p.animator().alphaValue = 0.0
            }, completionHandler: {
                p.orderOut(nil)
            })
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

// ============================================================================
// FILE: OnboardingWindowController.swift
// ============================================================================
// MARK: - Native First-Launch Onboarding Wizard

public final class OnboardingWindowController: NSWindowController, NSTextFieldDelegate {
    public static let shared = OnboardingWindowController()

    private var currentStep: Int = 1
    private let totalSteps: Int = 6

    public var currentStepNumber: Int {
        return currentStep
    }

    // Navigation & Container UI
    private var stepHeaderLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var contentContainerView: NSView!
    private var backButton: NSButton!
    private var nextButton: NSButton!

    // Step 2 (Microphone) Controls
    private var micStatusLabel: NSTextField!
    private var micActionBtn: NSButton!

    // Step 3 (Accessibility) Controls
    private var axStatusLabel: NSTextField!
    private var axActionBtn: NSButton!
    private var axOpenSysBtn: NSButton!
    private var axCheckBtn: NSButton!
    private var axCheckTimer: Timer?

    // Step 4 (Provider & Key) Controls
    private var providerPopUp: NSPopUpButton!
    private var apiKeyField: NSSecureTextField!
    private var apiKeyStatusLabel: NSTextField!
    private var testConnectionBtn: NSButton!
    private var testProgressSpinner: NSProgressIndicator!
    private var saveWithoutVerificationBtn: NSButton!
    private var isKeyVerified: Bool = false

    // Step 5 (Shortcut) Controls
    private var shortcutRadioDefault: NSButton!
    private var shortcutRadioCustom: NSButton!
    private var customShortcutContainer: NSView!
    private var shortcutPopUp: NSPopUpButton!
    private var customComboBadge: NSTextField!
    private var recordShortcutBtn: NSButton!
    private var resetShortcutBtn: NSButton!
    private var shortcutHelpLabel: NSTextField!
    private var activeRecorderSession: ShortcutRecorderSession?
    private var selectedKeyCombo: KeyCombo = PreferencesManager.shared.customKeyCombo

    // Step 6 (Complete) Controls
    private var summaryShortcutLabel: NSTextField!
    private var summaryInstructionsLabel: NSTextField!

    public init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 570),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to QuickDictate"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Responsive Text Field Factory

    public static func makeWrappingLabel(
        _ text: String,
        fontSize: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.textColor = color
        label.alignment = alignment
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.usesSingleLineMode = false
        label.cell?.lineBreakMode = .byWordWrapping
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        // Top Progress Bar
        progressBar = NSProgressIndicator(frame: NSRect(x: 28, y: 532, width: 604, height: 6))
        progressBar.isIndeterminate = false
        progressBar.minValue = 1.0
        progressBar.maxValue = Double(totalSteps)
        progressBar.doubleValue = 1.0
        cv.addSubview(progressBar)

        // Step Header Label
        stepHeaderLabel = Self.makeWrappingLabel("Step 1 of 6: Welcome", fontSize: 11, weight: .semibold, color: .secondaryLabelColor)
        stepHeaderLabel.frame = NSRect(x: 28, y: 504, width: 604, height: 20)
        cv.addSubview(stepHeaderLabel)

        // Separator
        let sepTop = NSBox(frame: NSRect(x: 28, y: 494, width: 604, height: 1))
        sepTop.boxType = .separator
        cv.addSubview(sepTop)

        // Central Content View (Dynamic for each step)
        contentContainerView = NSView(frame: NSRect(x: 28, y: 72, width: 604, height: 412))
        cv.addSubview(contentContainerView)

        // Bottom Separator
        let sepBottom = NSBox(frame: NSRect(x: 28, y: 64, width: 604, height: 1))
        sepBottom.boxType = .separator
        cv.addSubview(sepBottom)

        // Navigation Buttons
        backButton = NSButton(title: "← Back", target: self, action: #selector(backAction))
        backButton.frame = NSRect(x: 28, y: 18, width: 110, height: 32)
        backButton.bezelStyle = .rounded
        cv.addSubview(backButton)

        nextButton = NSButton(title: "Get Started →", target: self, action: #selector(nextAction))
        nextButton.frame = NSRect(x: 466, y: 18, width: 166, height: 32)
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        cv.addSubview(nextButton)
    }

    // MARK: - Presentation & State Restoration

    public func show(startingAtStep step: Int? = nil) {
        if let explicitStep = step {
            currentStep = max(1, min(explicitStep, totalSteps))
        } else {
            // If the onboarding wizard is already open on screen, bring it forward without resetting
            if window?.isVisible == true {
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                refreshCurrentStepPermissions()
                return
            }
            // Restore last incomplete step from persistent UserDefaults storage
            let saved = PreferencesManager.shared.onboardingCurrentStep
            currentStep = max(1, min(saved, totalSteps))
        }

        PreferencesManager.shared.onboardingCurrentStep = currentStep
        loadStep(currentStep)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func restartFromBeginning() {
        PreferencesManager.shared.onboardingCurrentStep = 1
        show(startingAtStep: 1)
    }

    public func handleAppDidBecomeActive() {
        guard window?.isVisible == true else { return }
        refreshCurrentStepPermissions()
    }

    public func refreshCurrentStepPermissions() {
        if currentStep == 2 {
            refreshMicStatus()
        } else if currentStep == 3 {
            refreshAxStatus()
        }
    }

    private func loadStep(_ step: Int) {
        currentStep = max(1, min(step, totalSteps))
        PreferencesManager.shared.onboardingCurrentStep = currentStep

        stopAccessibilityPolling()
        activeRecorderSession?.stopRecording()
        activeRecorderSession = nil
        APIKeyValidator.shared.cancel()

        // Clear previous step subviews
        contentContainerView.subviews.forEach { $0.removeFromSuperview() }

        progressBar.doubleValue = Double(currentStep)
        backButton.isHidden = (currentStep == 1)

        switch currentStep {
        case 1:
            stepHeaderLabel.stringValue = "Step 1 of 6: Welcome"
            nextButton.title = "Get Started →"
            nextButton.isEnabled = true
            setupStep1Welcome()
        case 2:
            stepHeaderLabel.stringValue = "Step 2 of 6: Microphone Access"
            nextButton.title = "Continue →"
            setupStep2Microphone()
        case 3:
            stepHeaderLabel.stringValue = "Step 3 of 6: Accessibility Permission"
            nextButton.title = "Continue →"
            setupStep3Accessibility()
            startAccessibilityPolling()
        case 4:
            stepHeaderLabel.stringValue = "Step 4 of 6: Transcription Provider"
            nextButton.title = "Continue →"
            setupStep4Provider()
        case 5:
            stepHeaderLabel.stringValue = "Step 5 of 6: Recording Shortcut"
            nextButton.title = "Continue →"
            nextButton.isEnabled = true
            setupStep5Shortcut()
        case 6:
            stepHeaderLabel.stringValue = "Step 6 of 6: You're Ready!"
            nextButton.title = "Start Using QuickDictate"
            nextButton.isEnabled = true
            setupStep6Complete()
        default:
            break
        }
    }

    // MARK: - Step 1: Welcome

    private func setupStep1Welcome() {
        let iconView = NSImageView(frame: NSRect(x: 262, y: 316, width: 80, height: 80))
        if let icon = NSImage(named: "AppIcon") {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "QuickDictate")
        }
        contentContainerView.addSubview(iconView)

        let title = Self.makeWrappingLabel("Welcome to QuickDictate", fontSize: 22, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 20, y: 274, width: 564, height: 32)
        contentContainerView.addSubview(title)

        let subtitle = Self.makeWrappingLabel("Fast, private speech-to-text for any Mac application.", fontSize: 13, weight: .medium, color: .secondaryLabelColor, alignment: .center)
        subtitle.frame = NSRect(x: 20, y: 246, width: 564, height: 22)
        contentContainerView.addSubview(subtitle)

        let card = NSBox(frame: NSRect(x: 22, y: 20, width: 560, height: 212))
        card.title = ""
        card.boxType = .custom
        card.cornerRadius = 10
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        card.borderColor = NSColor.separatorColor

        // Feature 1
        let icon1 = Self.makeWrappingLabel("🎙️", fontSize: 20)
        icon1.frame = NSRect(x: 18, y: 154, width: 30, height: 28)
        card.addSubview(icon1)

        let f1Title = Self.makeWrappingLabel("Universal Speech-to-Text", fontSize: 13, weight: .bold)
        f1Title.frame = NSRect(x: 54, y: 172, width: 486, height: 18)
        card.addSubview(f1Title)

        let f1Desc = Self.makeWrappingLabel("Dictate directly into Mail, Notes, Chrome, Slack, VS Code, or any text field with zero lag.", fontSize: 12, color: .secondaryLabelColor)
        f1Desc.frame = NSRect(x: 54, y: 140, width: 486, height: 32)
        card.addSubview(f1Desc)

        // Feature 2: Accurate Privacy Transparency
        let icon2 = Self.makeWrappingLabel("🔒", fontSize: 20)
        icon2.frame = NSRect(x: 18, y: 90, width: 30, height: 28)
        card.addSubview(icon2)

        let f2Title = Self.makeWrappingLabel("Private & Secure", fontSize: 13, weight: .bold)
        f2Title.frame = NSRect(x: 54, y: 108, width: 486, height: 18)
        card.addSubview(f2Title)

        let f2Desc = Self.makeWrappingLabel("API keys are encrypted in macOS Keychain. Temporary audio is recorded locally, streamed directly over HTTPS to your chosen provider, and deleted immediately after transcription.", fontSize: 12, color: .secondaryLabelColor)
        f2Desc.frame = NSRect(x: 54, y: 68, width: 486, height: 40)
        card.addSubview(f2Desc)

        // Feature 3
        let icon3 = Self.makeWrappingLabel("⚡", fontSize: 20)
        icon3.frame = NSRect(x: 18, y: 22, width: 30, height: 28)
        card.addSubview(icon3)

        let f3Title = Self.makeWrappingLabel("Voice Snippets", fontSize: 13, weight: .bold)
        f3Title.frame = NSRect(x: 54, y: 38, width: 486, height: 18)
        card.addSubview(f3Title)

        let f3Desc = Self.makeWrappingLabel("Speak trigger phrases to expand custom text templates, emails, and signatures.", fontSize: 12, color: .secondaryLabelColor)
        f3Desc.frame = NSRect(x: 54, y: 10, width: 486, height: 28)
        card.addSubview(f3Desc)

        contentContainerView.addSubview(card)
    }

    // MARK: - Step 2: Microphone Permission

    private func setupStep2Microphone() {
        let title = Self.makeWrappingLabel("Microphone Access", fontSize: 18, weight: .bold)
        title.frame = NSRect(x: 22, y: 366, width: 560, height: 26)
        contentContainerView.addSubview(title)

        let desc = Self.makeWrappingLabel("QuickDictate captures audio locally only when you trigger dictation, converting your spoken words into text. Audio is deleted immediately after transcription.", fontSize: 13, color: .secondaryLabelColor)
        desc.frame = NSRect(x: 22, y: 312, width: 560, height: 48)
        contentContainerView.addSubview(desc)

        let statusBox = NSBox(frame: NSRect(x: 22, y: 140, width: 560, height: 154))
        statusBox.title = ""
        statusBox.boxType = .custom
        statusBox.cornerRadius = 8
        statusBox.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        statusBox.borderColor = NSColor.separatorColor

        micStatusLabel = Self.makeWrappingLabel("Checking permission...", fontSize: 15, weight: .bold)
        micStatusLabel.frame = NSRect(x: 20, y: 102, width: 520, height: 28)
        statusBox.addSubview(micStatusLabel)

        micActionBtn = NSButton(title: "Allow Microphone Access", target: self, action: #selector(requestMicAction))
        micActionBtn.frame = NSRect(x: 20, y: 48, width: 220, height: 34)
        micActionBtn.bezelStyle = .rounded
        statusBox.addSubview(micActionBtn)

        let openSysBtn = NSButton(title: "Open System Preferences...", target: self, action: #selector(openMicSettingsAction))
        openSysBtn.frame = NSRect(x: 250, y: 48, width: 220, height: 34)
        openSysBtn.bezelStyle = .rounded
        statusBox.addSubview(openSysBtn)

        let statusHint = Self.makeWrappingLabel("Click 'Allow' above, or enable QuickDictate under System Preferences → Privacy & Security → Microphone.", fontSize: 11, color: .secondaryLabelColor)
        statusHint.frame = NSRect(x: 20, y: 16, width: 520, height: 24)
        statusBox.addSubview(statusHint)

        contentContainerView.addSubview(statusBox)

        let whyLabel = Self.makeWrappingLabel("Why this is needed: QuickDictate requires microphone access to capture your speech when you activate dictation. You must grant access to continue.", fontSize: 12, color: .secondaryLabelColor)
        whyLabel.frame = NSRect(x: 22, y: 40, width: 560, height: 80)
        contentContainerView.addSubview(whyLabel)

        refreshMicStatus()
    }

    private func refreshMicStatus() {
        guard micStatusLabel != nil else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            micStatusLabel.stringValue = "Microphone Permission: Granted ✓"
            micStatusLabel.textColor = .systemGreen
            micActionBtn.isEnabled = false
            micActionBtn.title = "Access Granted ✓"
            nextButton.isEnabled = true
        case .denied, .restricted:
            micStatusLabel.stringValue = "Microphone Permission: Denied ✗"
            micStatusLabel.textColor = .systemRed
            micActionBtn.isEnabled = false
            micActionBtn.title = "Enable in System Preferences"
            nextButton.isEnabled = false
        case .notDetermined:
            micStatusLabel.stringValue = "Microphone Permission: Required"
            micStatusLabel.textColor = .systemOrange
            micActionBtn.isEnabled = true
            micActionBtn.title = "Allow Microphone Access"
            nextButton.isEnabled = false
        @unknown default:
            micStatusLabel.stringValue = "Microphone Permission: Unknown"
            nextButton.isEnabled = false
        }
    }

    @objc private func requestMicAction() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshMicStatus()
            }
        }
    }

    @objc private func openMicSettingsAction() {
        PreferencesManager.shared.onboardingCurrentStep = 2
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 3: Accessibility Permission

    private func setupStep3Accessibility() {
        let title = Self.makeWrappingLabel("Accessibility Permission", fontSize: 18, weight: .bold)
        title.frame = NSRect(x: 22, y: 366, width: 560, height: 26)
        contentContainerView.addSubview(title)

        let desc = Self.makeWrappingLabel("QuickDictate uses macOS Accessibility to detect your active window and paste transcribed text directly at your cursor. It never reads or logs the text in your documents.", fontSize: 13, color: .secondaryLabelColor)
        desc.frame = NSRect(x: 22, y: 312, width: 560, height: 48)
        contentContainerView.addSubview(desc)

        let statusBox = NSBox(frame: NSRect(x: 22, y: 154, width: 560, height: 150))
        statusBox.title = ""
        statusBox.boxType = .custom
        statusBox.cornerRadius = 8
        statusBox.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        statusBox.borderColor = NSColor.separatorColor

        axStatusLabel = Self.makeWrappingLabel("Checking Accessibility...", fontSize: 15, weight: .bold)
        axStatusLabel.frame = NSRect(x: 20, y: 98, width: 520, height: 28)
        statusBox.addSubview(axStatusLabel)

        axActionBtn = NSButton(title: "Enable Accessibility...", target: self, action: #selector(requestAxAction))
        axActionBtn.frame = NSRect(x: 20, y: 46, width: 190, height: 34)
        axActionBtn.bezelStyle = .rounded
        statusBox.addSubview(axActionBtn)

        axOpenSysBtn = NSButton(title: "Open System Preferences...", target: self, action: #selector(openAxSettingsAction))
        axOpenSysBtn.frame = NSRect(x: 218, y: 46, width: 210, height: 34)
        axOpenSysBtn.bezelStyle = .rounded
        statusBox.addSubview(axOpenSysBtn)

        axCheckBtn = NSButton(title: "Check Again", target: self, action: #selector(refreshAxStatus))
        axCheckBtn.frame = NSRect(x: 436, y: 46, width: 104, height: 34)
        axCheckBtn.bezelStyle = .rounded
        statusBox.addSubview(axCheckBtn)

        let autoDetectNote = Self.makeWrappingLabel("QuickDictate continuously checks for permission and will update automatically once granted.", fontSize: 11, color: .secondaryLabelColor)
        autoDetectNote.frame = NSRect(x: 20, y: 14, width: 520, height: 24)
        statusBox.addSubview(autoDetectNote)

        contentContainerView.addSubview(statusBox)

        let instructions = Self.makeWrappingLabel("How to enable in macOS:\n1. Click 'Enable Accessibility...' or 'Open System Preferences...' above.\n2. In Security & Privacy → Accessibility, unlock the padlock 🔒 at the bottom left.\n3. Make sure the checkbox next to QuickDictate is checked ☑️.\n(Note: If QuickDictate is in the list but unchecked, check the box. If it is not listed, click the '+' button to add QuickDictate from Applications).\n4. Return to this window — permission will be detected automatically.", fontSize: 11, color: .secondaryLabelColor)
        instructions.frame = NSRect(x: 22, y: 16, width: 560, height: 126)
        contentContainerView.addSubview(instructions)

        refreshAxStatus()
    }

    @objc private func refreshAxStatus() {
        guard axStatusLabel != nil else { return }
        let isTrusted = AXIsProcessTrusted()
        if isTrusted {
            axStatusLabel.stringValue = "Accessibility Permission: Granted ✓"
            axStatusLabel.textColor = .systemGreen
            axActionBtn.isEnabled = false
            axActionBtn.title = "Permission Granted ✓"
            nextButton.isEnabled = true
        } else {
            axStatusLabel.stringValue = "Accessibility Permission: Required ✗"
            axStatusLabel.textColor = .systemOrange
            axActionBtn.isEnabled = true
            axActionBtn.title = "Enable Accessibility..."
            nextButton.isEnabled = false
        }
    }

    @objc private func requestAxAction() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAxStatus()
    }

    @objc private func openAxSettingsAction() {
        // Persist pending Step 3 before opening System Preferences
        PreferencesManager.shared.onboardingCurrentStep = 3
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        axCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshAxStatus()
        }
    }

    private func stopAccessibilityPolling() {
        axCheckTimer?.invalidate()
        axCheckTimer = nil
    }

    // MARK: - Step 4: Transcription Provider & Key Testing

    private func setupStep4Provider() {
        let title = Self.makeWrappingLabel("Connect Your Transcription Provider", fontSize: 18, weight: .bold)
        title.frame = NSRect(x: 22, y: 366, width: 560, height: 26)
        contentContainerView.addSubview(title)

        let desc = Self.makeWrappingLabel("Choose your speech-to-text provider and verify your API key. Keys are encrypted and saved securely in your macOS login Keychain.", fontSize: 13, color: .secondaryLabelColor)
        desc.frame = NSRect(x: 22, y: 316, width: 560, height: 44)
        contentContainerView.addSubview(desc)

        // Provider Selector
        let provLabel = Self.makeWrappingLabel("Provider:", fontSize: 13, weight: .semibold)
        provLabel.frame = NSRect(x: 22, y: 274, width: 140, height: 22)
        contentContainerView.addSubview(provLabel)

        providerPopUp = NSPopUpButton(frame: NSRect(x: 170, y: 270, width: 330, height: 28), pullsDown: false)
        for p in Provider.allCases {
            providerPopUp.addItem(withTitle: p.displayName)
        }
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChangedInWizard)
        if let idx = Provider.allCases.firstIndex(of: PreferencesManager.shared.preferredProvider) {
            providerPopUp.selectItem(at: idx)
        }
        contentContainerView.addSubview(providerPopUp)

        // API Key Input
        let keyLabel = Self.makeWrappingLabel("API Key Secret:", fontSize: 13, weight: .semibold)
        keyLabel.frame = NSRect(x: 22, y: 228, width: 140, height: 22)
        contentContainerView.addSubview(keyLabel)

        apiKeyField = NSSecureTextField(frame: NSRect(x: 170, y: 224, width: 390, height: 28))
        apiKeyField.placeholderString = "Paste gsk_... or sk-... key here"
        apiKeyField.delegate = self
        contentContainerView.addSubview(apiKeyField)

        // Action Buttons Row: Test Connection + Spinner
        testConnectionBtn = NSButton(title: "Test Connection", target: self, action: #selector(testConnectionAction))
        testConnectionBtn.frame = NSRect(x: 170, y: 182, width: 160, height: 32)
        testConnectionBtn.bezelStyle = .rounded
        contentContainerView.addSubview(testConnectionBtn)

        testProgressSpinner = NSProgressIndicator(frame: NSRect(x: 340, y: 188, width: 20, height: 20))
        testProgressSpinner.style = .spinning
        testProgressSpinner.isDisplayedWhenStopped = false
        contentContainerView.addSubview(testProgressSpinner)

        saveWithoutVerificationBtn = NSButton(title: "Save Without Verification", target: self, action: #selector(saveWithoutVerificationAction))
        saveWithoutVerificationBtn.frame = NSRect(x: 370, y: 184, width: 190, height: 28)
        saveWithoutVerificationBtn.bezelStyle = .inline
        saveWithoutVerificationBtn.isHidden = true
        contentContainerView.addSubview(saveWithoutVerificationBtn)

        // Status Label
        apiKeyStatusLabel = Self.makeWrappingLabel("Enter your key and click 'Test Connection' to verify with the provider.", fontSize: 12, color: .secondaryLabelColor)
        apiKeyStatusLabel.frame = NSRect(x: 170, y: 124, width: 410, height: 52)
        contentContainerView.addSubview(apiKeyStatusLabel)

        // Provider Links
        let groqLink = NSButton(title: "Get a free Groq API key →", target: self, action: #selector(openGroqConsole))
        groqLink.frame = NSRect(x: 170, y: 92, width: 220, height: 26)
        groqLink.bezelStyle = .inline
        contentContainerView.addSubview(groqLink)

        let openAiLink = NSButton(title: "Get an OpenAI API key →", target: self, action: #selector(openOpenAIConsole))
        openAiLink.frame = NSRect(x: 170, y: 64, width: 220, height: 26)
        openAiLink.bezelStyle = .inline
        contentContainerView.addSubview(openAiLink)

        let recNote = Self.makeWrappingLabel("Recommendation: Groq provides near-instant Whisper Large V3 Turbo transcription with a generous free tier. Keys are encrypted in Keychain and never shared.", fontSize: 11, color: .secondaryLabelColor)
        recNote.frame = NSRect(x: 22, y: 12, width: 560, height: 46)
        contentContainerView.addSubview(recNote)

        // Check if existing key is already stored in Keychain
        let existingCreds = KeychainCredentialManager.shared.resolveCredentials(
            preferredProvider: PreferencesManager.shared.preferredProvider,
            allowCrossProviderFailover: true
        )
        if let first = existingCreds.first {
            isKeyVerified = true
            apiKeyStatusLabel.stringValue = "Key already configured in Keychain (\(first.metadata.maskedPreview)) ✓"
            apiKeyStatusLabel.textColor = .systemGreen
            nextButton.isEnabled = true
        } else {
            isKeyVerified = false
            nextButton.isEnabled = false
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSecureTextField, field == apiKeyField {
            isKeyVerified = false
            nextButton.isEnabled = false
            saveWithoutVerificationBtn.isHidden = true
            let currentText = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentText.isEmpty {
                apiKeyStatusLabel.stringValue = "Enter your key and click 'Test Connection' to verify."
                apiKeyStatusLabel.textColor = .secondaryLabelColor
            } else {
                apiKeyStatusLabel.stringValue = "Key entered. Click 'Test Connection' to verify with the provider."
                apiKeyStatusLabel.textColor = .labelColor
            }
        }
    }

    @objc private func providerChangedInWizard() {
        APIKeyValidator.shared.cancel()
        let idx = providerPopUp.indexOfSelectedItem
        if idx >= 0 && idx < Provider.allCases.count {
            PreferencesManager.shared.preferredProvider = Provider.allCases[idx]
        }
        isKeyVerified = false
        nextButton.isEnabled = false
        saveWithoutVerificationBtn.isHidden = true

        let existing = KeychainCredentialManager.shared.resolveCredentials(
            preferredProvider: PreferencesManager.shared.preferredProvider,
            allowCrossProviderFailover: false
        )
        if let first = existing.first {
            isKeyVerified = true
            apiKeyStatusLabel.stringValue = "Key already configured in Keychain (\(first.metadata.maskedPreview)) ✓"
            apiKeyStatusLabel.textColor = .systemGreen
            nextButton.isEnabled = true
        } else {
            apiKeyStatusLabel.stringValue = "Provider changed to \(PreferencesManager.shared.preferredProvider.displayName). Please verify your key."
            apiKeyStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func testConnectionAction() {
        let rawKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            apiKeyStatusLabel.stringValue = "Please paste or enter your API key first."
            apiKeyStatusLabel.textColor = .systemRed
            return
        }

        let provider = PreferencesManager.shared.preferredProvider

        testConnectionBtn.isEnabled = false
        testProgressSpinner.startAnimation(nil)
        apiKeyStatusLabel.stringValue = "Connecting to \(provider.shortName) and checking model availability..."
        apiKeyStatusLabel.textColor = .systemBlue
        saveWithoutVerificationBtn.isHidden = true

        APIKeyValidator.shared.validateKey(rawKey: rawKey, provider: provider) { [weak self] status in
            guard let self = self else { return }
            self.testConnectionBtn.isEnabled = true
            self.testProgressSpinner.stopAnimation(nil)

            switch status {
            case .verified(let prov, let modelName):
                self.isKeyVerified = true
                self.apiKeyStatusLabel.stringValue = "Connection Successful! \(prov.shortName) accepted your key. Model: \(modelName) verified ✓"
                self.apiKeyStatusLabel.textColor = .systemGreen
                self.nextButton.isEnabled = true
                self.saveWithoutVerificationBtn.isHidden = true

                // Save to Keychain immediately upon successful test
                do {
                    _ = try KeychainCredentialManager.shared.addCredential(
                        rawKey: rawKey,
                        provider: prov,
                        label: "\(prov.shortName) Key"
                    )
                } catch CredentialStoreError.duplicateKey {
                    // Already in Keychain — fine
                } catch {
                    self.apiKeyStatusLabel.stringValue += " (Note: \(error.localizedDescription))"
                }

            case .invalidKey(let prov, let reason):
                self.isKeyVerified = false
                self.nextButton.isEnabled = false
                self.apiKeyStatusLabel.stringValue = "Invalid API Key: \(prov.shortName) rejected the key (\(reason)). Verify your key in the provider console."
                self.apiKeyStatusLabel.textColor = .systemRed

            case .rateLimited(let prov, let retryAfter):
                self.isKeyVerified = false
                self.nextButton.isEnabled = false
                if let wait = retryAfter, wait > 0 {
                    self.apiKeyStatusLabel.stringValue = "\(prov.shortName) rate limit reached (HTTP 429). Try again in \(Int(ceil(wait)))s."
                } else {
                    self.apiKeyStatusLabel.stringValue = "\(prov.shortName) rate limit reached (HTTP 429). Please wait a moment."
                }
                self.apiKeyStatusLabel.textColor = .systemOrange

            case .modelUnavailable(let prov, let modelName):
                self.isKeyVerified = false
                self.nextButton.isEnabled = false
                self.apiKeyStatusLabel.stringValue = "Connected to \(prov.shortName), but required model '\(modelName)' was not found in your account's available models."
                self.apiKeyStatusLabel.textColor = .systemOrange

            case .networkUnavailable(let prov, let reason):
                self.isKeyVerified = false
                self.apiKeyStatusLabel.stringValue = "Could not reach \(prov.shortName) (\(reason)). Check your internet connection."
                self.apiKeyStatusLabel.textColor = .systemRed
                self.saveWithoutVerificationBtn.isHidden = false

            case .serverError(let prov, let code):
                self.isKeyVerified = false
                self.apiKeyStatusLabel.stringValue = "\(prov.shortName) server error (HTTP \(code)). Provider may be experiencing temporary issues."
                self.apiKeyStatusLabel.textColor = .systemRed
                self.saveWithoutVerificationBtn.isHidden = false

            case .notTested, .checking:
                break
            }
        }
    }

    @objc private func saveWithoutVerificationAction() {
        let rawKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Save API Key Without Verification?"
        alert.informativeText = "QuickDictate could not reach the provider to verify this key. If the key is invalid or your internet is offline, dictation will fail until connection or credentials are fixed. Save anyway?"
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            let provider = PreferencesManager.shared.preferredProvider
            _ = try? KeychainCredentialManager.shared.addCredential(
                rawKey: rawKey,
                provider: provider,
                label: "\(provider.shortName) Key"
            )
            isKeyVerified = true
            nextButton.isEnabled = true
            apiKeyStatusLabel.stringValue = "Key saved without verification. Will test on first dictation."
            apiKeyStatusLabel.textColor = .systemOrange
        }
    }

    @objc private func openGroqConsole() {
        if let url = URL(string: "https://console.groq.com/keys") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openOpenAIConsole() {
        if let url = URL(string: "https://platform.openai.com/api-keys") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 5: Choose Recording Shortcut

    private func setupStep5Shortcut() {
        let title = Self.makeWrappingLabel("Choose Your Recording Shortcut", fontSize: 18, weight: .bold)
        title.frame = NSRect(x: 22, y: 366, width: 560, height: 26)
        contentContainerView.addSubview(title)

        let desc = Self.makeWrappingLabel("Choose how you want to start and stop speech dictation. You can change this later in Settings at any time.", fontSize: 13, color: .secondaryLabelColor)
        desc.frame = NSRect(x: 22, y: 316, width: 560, height: 44)
        contentContainerView.addSubview(desc)

        // Choice 1: Keep Right Option (Recommended)
        shortcutRadioDefault = NSButton(radioButtonWithTitle: "Keep Right Option — Recommended", target: self, action: #selector(shortcutRadioChanged))
        shortcutRadioDefault.frame = NSRect(x: 22, y: 270, width: 400, height: 24)
        shortcutRadioDefault.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentContainerView.addSubview(shortcutRadioDefault)

        let defaultDesc = Self.makeWrappingLabel("Tap the Right Option key once to start recording, speak, and tap it again to finish. Normal Option-key shortcuts (like word jumping) will never be affected.", fontSize: 12, color: .secondaryLabelColor)
        defaultDesc.frame = NSRect(x: 42, y: 226, width: 540, height: 42)
        contentContainerView.addSubview(defaultDesc)

        // Choice 2: Choose a Different Shortcut
        shortcutRadioCustom = NSButton(radioButtonWithTitle: "Choose a Different Shortcut", target: self, action: #selector(shortcutRadioChanged))
        shortcutRadioCustom.frame = NSRect(x: 22, y: 194, width: 400, height: 24)
        shortcutRadioCustom.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentContainerView.addSubview(shortcutRadioCustom)

        // Custom Container Box
        customShortcutContainer = NSView(frame: NSRect(x: 42, y: 20, width: 540, height: 168))

        let presetLabel = Self.makeWrappingLabel("Shortcut Option:", fontSize: 13, weight: .medium)
        presetLabel.frame = NSRect(x: 0, y: 140, width: 140, height: 20)
        customShortcutContainer.addSubview(presetLabel)

        shortcutPopUp = NSPopUpButton(frame: NSRect(x: 145, y: 136, width: 280, height: 26), pullsDown: false)
        for opt in ShortcutOption.allCases {
            shortcutPopUp.addItem(withTitle: opt.displayName)
        }
        shortcutPopUp.target = self
        shortcutPopUp.action = #selector(shortcutPopupChanged)
        customShortcutContainer.addSubview(shortcutPopUp)

        // Custom key combo box
        let customBox = NSBox(frame: NSRect(x: 0, y: 0, width: 540, height: 128))
        customBox.title = "Custom Key Combination"
        customBox.boxType = .primary

        let activeLabel = Self.makeWrappingLabel("Active Combination:", fontSize: 12)
        activeLabel.frame = NSRect(x: 16, y: 76, width: 150, height: 20)
        customBox.addSubview(activeLabel)

        selectedKeyCombo = PreferencesManager.shared.customKeyCombo
        customComboBadge = NSTextField(labelWithString: selectedKeyCombo.displayString)
        customComboBadge.frame = NSRect(x: 16, y: 44, width: 140, height: 28)
        customComboBadge.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        customComboBadge.alignment = .center
        customComboBadge.isBezeled = true
        customComboBadge.drawsBackground = true
        customComboBadge.backgroundColor = NSColor.controlBackgroundColor
        customBox.addSubview(customComboBadge)

        recordShortcutBtn = NSButton(title: "Record Shortcut", target: self, action: #selector(startShortcutCaptureAction))
        recordShortcutBtn.frame = NSRect(x: 170, y: 42, width: 150, height: 32)
        recordShortcutBtn.bezelStyle = .rounded
        customBox.addSubview(recordShortcutBtn)

        resetShortcutBtn = NSButton(title: "Reset to Default (⌃⌥D)", target: self, action: #selector(resetCustomShortcutAction))
        resetShortcutBtn.frame = NSRect(x: 330, y: 42, width: 180, height: 32)
        resetShortcutBtn.bezelStyle = .rounded
        customBox.addSubview(resetShortcutBtn)

        shortcutHelpLabel = Self.makeWrappingLabel("Press 'Record Shortcut', then press your desired combination (e.g. ⌃⌥D). Esc to cancel.", fontSize: 11, color: .secondaryLabelColor)
        shortcutHelpLabel.frame = NSRect(x: 16, y: 12, width: 500, height: 24)
        customBox.addSubview(shortcutHelpLabel)

        customShortcutContainer.addSubview(customBox)
        contentContainerView.addSubview(customShortcutContainer)

        // Set initial radio selection
        let currentChoice = PreferencesManager.shared.shortcutOption
        if currentChoice == .rightOption {
            shortcutRadioDefault.state = .on
            shortcutRadioCustom.state = .off
            customShortcutContainer.isHidden = true
        } else {
            shortcutRadioDefault.state = .off
            shortcutRadioCustom.state = .on
            customShortcutContainer.isHidden = false
            if let idx = ShortcutOption.allCases.firstIndex(of: currentChoice) {
                shortcutPopUp.selectItem(at: idx)
            }
        }
    }

    @objc private func shortcutRadioChanged() {
        if shortcutRadioDefault.state == .on {
            shortcutRadioCustom.state = .off
            customShortcutContainer.isHidden = true
            PreferencesManager.shared.shortcutOption = .rightOption
        } else {
            shortcutRadioDefault.state = .off
            shortcutRadioCustom.state = .on
            customShortcutContainer.isHidden = false
            shortcutPopupChanged()
        }
    }

    @objc private func shortcutPopupChanged() {
        let idx = shortcutPopUp.indexOfSelectedItem
        if idx >= 0 && idx < ShortcutOption.allCases.count {
            PreferencesManager.shared.shortcutOption = ShortcutOption.allCases[idx]
        }
    }

    @objc private func startShortcutCaptureAction() {
        recordShortcutBtn.title = "Press keys now..."
        recordShortcutBtn.isEnabled = false
        shortcutHelpLabel.stringValue = "Listening for key combination (must include ⌃, ⌥, or ⌘)... Press Esc to cancel."
        shortcutHelpLabel.textColor = .systemBlue

        activeRecorderSession = ShortcutRecorderSession()
        activeRecorderSession?.onCaptured = { [weak self] combo in
            DispatchQueue.main.async {
                self?.selectedKeyCombo = combo
                self?.customComboBadge.stringValue = combo.displayString
                PreferencesManager.shared.customKeyCombo = combo
                self?.recordShortcutBtn.title = "Record Shortcut"
                self?.recordShortcutBtn.isEnabled = true
                self?.shortcutHelpLabel.stringValue = "Saved shortcut: \(combo.displayString) ✓"
                self?.shortcutHelpLabel.textColor = .systemGreen
                self?.shortcutPopUp.selectItem(withTitle: ShortcutOption.custom.displayName)
                PreferencesManager.shared.shortcutOption = .custom
            }
        }
        activeRecorderSession?.onCancelled = { [weak self] in
            DispatchQueue.main.async {
                self?.recordShortcutBtn.title = "Record Shortcut"
                self?.recordShortcutBtn.isEnabled = true
                self?.shortcutHelpLabel.stringValue = "Cancelled shortcut recording."
                self?.shortcutHelpLabel.textColor = .secondaryLabelColor
            }
        }
        activeRecorderSession?.onError = { [weak self] errorReason in
            DispatchQueue.main.async {
                self?.shortcutHelpLabel.stringValue = errorReason
                self?.shortcutHelpLabel.textColor = .systemRed
            }
        }
        activeRecorderSession?.startRecording()
    }

    @objc private func resetCustomShortcutAction() {
        selectedKeyCombo = KeyCombo.defaultCustom
        customComboBadge.stringValue = selectedKeyCombo.displayString
        PreferencesManager.shared.customKeyCombo = selectedKeyCombo
        shortcutHelpLabel.stringValue = "Reset to ⌃⌥D."
        shortcutHelpLabel.textColor = .secondaryLabelColor
    }

    // MARK: - Step 6: Setup Complete

    private func setupStep6Complete() {
        let checkIcon = NSImageView(frame: NSRect(x: 266, y: 316, width: 72, height: 72))
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Success")?.withSymbolConfiguration(config)
        checkIcon.contentTintColor = .systemGreen
        contentContainerView.addSubview(checkIcon)

        let title = Self.makeWrappingLabel("You're Ready to Dictate!", fontSize: 22, weight: .bold, alignment: .center)
        title.frame = NSRect(x: 20, y: 270, width: 564, height: 32)
        contentContainerView.addSubview(title)

        let card = NSBox(frame: NSRect(x: 22, y: 70, width: 560, height: 180))
        card.title = ""
        card.boxType = .custom
        card.cornerRadius = 10
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        card.borderColor = NSColor.separatorColor

        let shortcutName: String
        let chosen = PreferencesManager.shared.shortcutOption
        if chosen == .custom {
            shortcutName = PreferencesManager.shared.customKeyCombo.displayString
        } else {
            shortcutName = chosen.displayName
        }

        summaryShortcutLabel = Self.makeWrappingLabel("Your Recording Shortcut: \(shortcutName)", fontSize: 16, weight: .bold, alignment: .center)
        summaryShortcutLabel.frame = NSRect(x: 20, y: 136, width: 520, height: 28)
        card.addSubview(summaryShortcutLabel)

        let instruct = Self.makeWrappingLabel(
            "1. Press \(shortcutName) once in any app (Mail, Notes, Slack, Chrome, Code editors) to start recording.\n2. Speak naturally — a recording indicator will appear in your menu bar.\n3. Press \(shortcutName) again to stop and transcribe your speech into text directly at your cursor.\n4. Say trigger phrases (e.g. 'enter email') to expand custom Voice Snippets.",
            fontSize: 13,
            color: .labelColor
        )
        instruct.frame = NSRect(x: 24, y: 18, width: 512, height: 104)
        card.addSubview(instruct)

        contentContainerView.addSubview(card)

        let menuNote = Self.makeWrappingLabel("QuickDictate is running in your menu bar. Click the waveform icon anytime to adjust Settings, manage Voice Snippets, or run this wizard again.", fontSize: 12, color: .secondaryLabelColor, alignment: .center)
        menuNote.frame = NSRect(x: 22, y: 20, width: 560, height: 36)
        contentContainerView.addSubview(menuNote)
    }

    // MARK: - Navigation Actions

    @objc private func backAction() {
        if currentStep > 1 {
            loadStep(currentStep - 1)
        }
    }

    @objc private func nextAction() {
        // Enforce validation per step before advancing
        if currentStep == 2 {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            guard status == .authorized else {
                refreshMicStatus()
                return
            }
        }

        if currentStep == 3 {
            guard AXIsProcessTrusted() else {
                refreshAxStatus()
                return
            }
        }

        if currentStep == 4 {
            let creds = KeychainCredentialManager.shared.resolveCredentials(
                preferredProvider: PreferencesManager.shared.preferredProvider,
                allowCrossProviderFailover: false
            )
            guard isKeyVerified || !creds.isEmpty else {
                testConnectionAction()
                return
            }
        }

        if currentStep < totalSteps {
            loadStep(currentStep + 1)
        } else {
            // Complete Onboarding
            finishOnboarding()
        }
    }

    private func finishOnboarding() {
        stopAccessibilityPolling()
        PreferencesManager.shared.isOnboardingCompleted = true
        PreferencesManager.shared.onboardingCurrentStep = 1

        // Apply chosen shortcut immediately
        let shortcut = PreferencesManager.shared.shortcutOption
        KeyboardShortcutMonitor.shared.updateShortcut(shortcut, customCombo: PreferencesManager.shared.customKeyCombo)
        KeyboardShortcutMonitor.shared.startMonitoring()

        // Respect Dock vs Menu-bar only preference
        if PreferencesManager.shared.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        window?.close()

        HUDWindowController.shared.show(
            text: "✦ QuickDictate Ready! Shortcut: \(PreferencesManager.shared.shortcutOption.displayName)",
            autoDismiss: 3.5
        )
    }
}

// ============================================================================
// FILE: SettingsWindowController.swift
// ============================================================================
// MARK: - Settings & Credentials Management Window

public final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let shared = SettingsWindowController()

    private var providerPopup: NSPopUpButton!
    private var shortcutPopup: NSPopUpButton!
    private var customShortcutButton: NSButton!
    private var customShortcutBadge: NSTextField!
    private var crossProviderCheckbox: NSButton!
    private var snippetsCheckbox: NSButton!
    private var previewCheckbox: NSButton!
    private var soundCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var dockCheckbox: NSButton!

    private var micStatusLabel: NSTextField!
    private var axStatusLabel: NSTextField!

    private var credentialsTableView: NSTableView!
    private var keyProviderPopup: NSPopUpButton!
    private var keyLabelField: NSTextField!
    private var keySecretField: NSSecureTextField!
    private var statusMessageLabel: NSTextField!

    private var metadataItems: [StoredCredentialMetadata] = []
    private var permissionRefreshTimer: Timer?
    private var activeRecorder: ShortcutRecorderSession?
    public var onSettingsChanged: (() -> Void)?

    public init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 630),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "QuickDictate — Settings & Keychain Credentials"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        // Section 1: General & Permissions
        let genHeader = NSTextField(labelWithString: "General & Dictation Preferences")
        genHeader.frame = NSRect(x: 20, y: 592, width: 620, height: 20)
        genHeader.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        cv.addSubview(genHeader)

        let provLbl = NSTextField(labelWithString: "Primary Provider:")
        provLbl.frame = NSRect(x: 20, y: 560, width: 130, height: 20)
        cv.addSubview(provLbl)

        providerPopup = NSPopUpButton(frame: NSRect(x: 155, y: 558, width: 230, height: 26), pullsDown: false)
        for p in Provider.allCases {
            providerPopup.addItem(withTitle: p.displayName)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        cv.addSubview(providerPopup)

        let shortLbl = NSTextField(labelWithString: "Recording Shortcut:")
        shortLbl.frame = NSRect(x: 20, y: 528, width: 130, height: 20)
        cv.addSubview(shortLbl)

        shortcutPopup = NSPopUpButton(frame: NSRect(x: 155, y: 526, width: 230, height: 26), pullsDown: false)
        for opt in ShortcutOption.allCases {
            shortcutPopup.addItem(withTitle: opt.displayName)
        }
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChanged)
        cv.addSubview(shortcutPopup)

        customShortcutBadge = NSTextField(labelWithString: PreferencesManager.shared.customKeyCombo.displayString)
        customShortcutBadge.frame = NSRect(x: 395, y: 526, width: 70, height: 24)
        customShortcutBadge.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        customShortcutBadge.alignment = .center
        customShortcutBadge.isBezeled = true
        customShortcutBadge.drawsBackground = true
        customShortcutBadge.backgroundColor = NSColor.controlBackgroundColor
        cv.addSubview(customShortcutBadge)

        customShortcutButton = NSButton(title: "Record...", target: self, action: #selector(recordCustomShortcutAction))
        customShortcutButton.frame = NSRect(x: 470, y: 524, width: 80, height: 26)
        customShortcutButton.bezelStyle = .rounded
        cv.addSubview(customShortcutButton)

        // Permissions Box on Right
        micStatusLabel = NSTextField(labelWithString: "Microphone: Checking...")
        micStatusLabel.frame = NSRect(x: 400, y: 562, width: 145, height: 18)
        micStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        cv.addSubview(micStatusLabel)

        let micBtn = NSButton(title: "Settings...", target: self, action: #selector(openMicrophoneSettings))
        micBtn.frame = NSRect(x: 555, y: 558, width: 85, height: 24)
        micBtn.bezelStyle = .rounded
        cv.addSubview(micBtn)

        axStatusLabel = NSTextField(labelWithString: "Accessibility: Checking...")
        axStatusLabel.frame = NSRect(x: 400, y: 494, width: 145, height: 18)
        axStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        cv.addSubview(axStatusLabel)

        let axBtn = NSButton(title: "Settings...", target: self, action: #selector(openAccessibilitySettings))
        axBtn.frame = NSRect(x: 555, y: 490, width: 85, height: 24)
        axBtn.bezelStyle = .rounded
        cv.addSubview(axBtn)

        // Checkboxes
        crossProviderCheckbox = NSButton(checkboxWithTitle: "Allow cross-provider failover (e.g. send audio to OpenAI if all Groq keys fail)", target: self, action: #selector(togglesChanged))
        crossProviderCheckbox.frame = NSRect(x: 20, y: 462, width: 590, height: 20)
        cv.addSubview(crossProviderCheckbox)

        snippetsCheckbox = NSButton(checkboxWithTitle: "Enable local Voice Snippets text expansion", target: self, action: #selector(togglesChanged))
        snippetsCheckbox.frame = NSRect(x: 20, y: 438, width: 300, height: 20)
        cv.addSubview(snippetsCheckbox)

        soundCheckbox = NSButton(checkboxWithTitle: "Play start/stop audio feedback chimes", target: self, action: #selector(togglesChanged))
        soundCheckbox.frame = NSRect(x: 330, y: 438, width: 280, height: 20)
        cv.addSubview(soundCheckbox)

        previewCheckbox = NSButton(checkboxWithTitle: "Enable Periodic Preview HUD (sends up to 6 interim API requests per session)", target: self, action: #selector(togglesChanged))
        previewCheckbox.frame = NSRect(x: 20, y: 414, width: 600, height: 20)
        cv.addSubview(previewCheckbox)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch QuickDictate automatically at login", target: self, action: #selector(launchAtLoginToggled))
        launchAtLoginCheckbox.frame = NSRect(x: 20, y: 390, width: 300, height: 20)
        cv.addSubview(launchAtLoginCheckbox)

        dockCheckbox = NSButton(checkboxWithTitle: "Show QuickDictate icon in Dock", target: self, action: #selector(dockToggled))
        dockCheckbox.frame = NSRect(x: 330, y: 390, width: 280, height: 20)
        cv.addSubview(dockCheckbox)

        let runWizardBtn = NSButton(title: "Run Setup Wizard Again...", target: self, action: #selector(runSetupWizardAction))
        runWizardBtn.frame = NSRect(x: 20, y: 360, width: 190, height: 26)
        runWizardBtn.bezelStyle = .rounded
        cv.addSubview(runWizardBtn)

        // Section 2: Keychain API Credentials
        let credHeader = NSTextField(labelWithString: "Keychain API Credentials (Stored Securely in macOS Keychain — Never Shown in Plaintext)")
        credHeader.frame = NSRect(x: 20, y: 330, width: 600, height: 20)
        credHeader.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        cv.addSubview(credHeader)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 170, width: 620, height: 154))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        credentialsTableView = NSTableView(frame: scrollView.bounds)
        credentialsTableView.usesAlternatingRowBackgroundColors = true
        credentialsTableView.rowHeight = 24

        let colOrder = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("priority"))
        colOrder.title = "#"
        colOrder.width = 32
        credentialsTableView.addTableColumn(colOrder)

        let colProvider = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        colProvider.title = "Provider"
        colProvider.width = 90
        credentialsTableView.addTableColumn(colProvider)

        let colLabel = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        colLabel.title = "Label"
        colLabel.width = 210
        credentialsTableView.addTableColumn(colLabel)

        let colPreview = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("masked"))
        colPreview.title = "Masked Key Preview"
        colPreview.width = 240
        credentialsTableView.addTableColumn(colPreview)

        credentialsTableView.dataSource = self
        credentialsTableView.delegate = self
        scrollView.documentView = credentialsTableView
        cv.addSubview(scrollView)

        // Add / Replace Credential Inputs
        let addProviderLbl = NSTextField(labelWithString: "Provider:")
        addProviderLbl.frame = NSRect(x: 20, y: 138, width: 70, height: 18)
        cv.addSubview(addProviderLbl)

        keyProviderPopup = NSPopUpButton(frame: NSRect(x: 20, y: 110, width: 120, height: 26), pullsDown: false)
        for p in Provider.allCases {
            keyProviderPopup.addItem(withTitle: p.shortName)
        }
        cv.addSubview(keyProviderPopup)

        let addLabelLbl = NSTextField(labelWithString: "Label (Optional):")
        addLabelLbl.frame = NSRect(x: 150, y: 138, width: 140, height: 18)
        cv.addSubview(addLabelLbl)

        keyLabelField = NSTextField(frame: NSRect(x: 150, y: 112, width: 155, height: 24))
        keyLabelField.placeholderString = "e.g. Work Groq Key"
        cv.addSubview(keyLabelField)

        let addSecretLbl = NSTextField(labelWithString: "API Key Secret (Hidden Input):")
        addSecretLbl.frame = NSRect(x: 315, y: 138, width: 280, height: 18)
        cv.addSubview(addSecretLbl)

        keySecretField = NSSecureTextField(frame: NSRect(x: 315, y: 112, width: 305, height: 24))
        keySecretField.placeholderString = "Paste gsk_... or sk-... key here"
        cv.addSubview(keySecretField)

        // Credential Action Buttons
        let addBtn = NSButton(title: "Add Key to Keychain", target: self, action: #selector(addKeyAction))
        addBtn.frame = NSRect(x: 20, y: 70, width: 165, height: 30)
        addBtn.bezelStyle = .rounded
        cv.addSubview(addBtn)

        let replaceBtn = NSButton(title: "Replace Selected Key", target: self, action: #selector(replaceKeyAction))
        replaceBtn.frame = NSRect(x: 190, y: 70, width: 165, height: 30)
        replaceBtn.bezelStyle = .rounded
        cv.addSubview(replaceBtn)

        let removeBtn = NSButton(title: "Remove Selected", target: self, action: #selector(removeKeyAction))
        removeBtn.frame = NSRect(x: 360, y: 70, width: 140, height: 30)
        removeBtn.bezelStyle = .rounded
        cv.addSubview(removeBtn)

        let moveUpBtn = NSButton(title: "↑", target: self, action: #selector(moveUpAction))
        moveUpBtn.frame = NSRect(x: 510, y: 70, width: 50, height: 30)
        moveUpBtn.bezelStyle = .rounded
        cv.addSubview(moveUpBtn)

        let moveDownBtn = NSButton(title: "↓", target: self, action: #selector(moveDownAction))
        moveDownBtn.frame = NSRect(x: 570, y: 70, width: 50, height: 30)
        moveDownBtn.bezelStyle = .rounded
        cv.addSubview(moveDownBtn)

        statusMessageLabel = NSTextField(labelWithString: "")
        statusMessageLabel.frame = NSRect(x: 20, y: 24, width: 500, height: 34)
        statusMessageLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusMessageLabel.cell?.wraps = true
        cv.addSubview(statusMessageLabel)

        let closeBtn = NSButton(title: "Done", target: self, action: #selector(closeWindowAction))
        closeBtn.frame = NSRect(x: 535, y: 22, width: 85, height: 32)
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\r"
        cv.addSubview(closeBtn)
    }

    public func show(initialMessage: String? = nil, isError: Bool = false) {
        refreshStateFromManagers()
        if let msg = initialMessage {
            statusMessageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
            statusMessageLabel.stringValue = msg
        } else {
            statusMessageLabel.stringValue = ""
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        beginPermissionStatusRefresh()
    }

    /// Recheck TCC while Settings is visible. macOS grants are external state:
    /// returning from System Preferences does not trigger a model preference change.
    private func beginPermissionStatusRefresh() {
        permissionRefreshTimer?.invalidate()
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard self.window?.isVisible == true else {
                timer.invalidate()
                self.permissionRefreshTimer = nil
                return
            }
            self.refreshPermissionIndicators()
        }
    }

    public func refreshStateFromManagers() {
        let prefs = PreferencesManager.shared
        if let pIdx = Provider.allCases.firstIndex(of: prefs.preferredProvider) {
            providerPopup.selectItem(at: pIdx)
        }
        if let sIdx = ShortcutOption.allCases.firstIndex(of: prefs.shortcutOption) {
            shortcutPopup.selectItem(at: sIdx)
        }

        crossProviderCheckbox.state = prefs.allowCrossProviderFailover ? .on : .off
        snippetsCheckbox.state = prefs.isSnippetsEnabled ? .on : .off
        previewCheckbox.state = prefs.isPeriodicPreviewEnabled ? .on : .off
        soundCheckbox.state = prefs.isSoundFeedbackEnabled ? .on : .off
        dockCheckbox.state = prefs.showDockIcon ? .on : .off
        customShortcutBadge.stringValue = prefs.customKeyCombo.displayString

        if LaunchAtLoginController.shared.isSupportedNatively {
            launchAtLoginCheckbox.title = "Launch QuickDictate automatically at login"
            launchAtLoginCheckbox.state = LaunchAtLoginController.shared.isEnabled ? .on : .off
        } else {
            launchAtLoginCheckbox.title = "Open Login Items in System Preferences (macOS 12)..."
            launchAtLoginCheckbox.state = .off
        }

        refreshPermissionIndicators()

        metadataItems = KeychainCredentialManager.shared.listMetadata()
        credentialsTableView.reloadData()
    }

    private func refreshPermissionIndicators() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            micStatusLabel.stringValue = "Microphone: Granted ✓"
            micStatusLabel.textColor = .systemGreen
        case .denied, .restricted:
            micStatusLabel.stringValue = "Microphone: Denied ✗"
            micStatusLabel.textColor = .systemRed
        case .notDetermined:
            micStatusLabel.stringValue = "Microphone: Not Requested"
            micStatusLabel.textColor = .secondaryLabelColor
        @unknown default:
            micStatusLabel.stringValue = "Microphone: Unknown"
        }

        // Only the current running process determines whether the grant is valid.
        // A checked entry for another development build does not grant this process access.
        let axTrusted = AXIsProcessTrusted()
        axStatusLabel.stringValue = axTrusted ? "Accessibility: Granted ✓" : "Accessibility: Needed ✗"
        axStatusLabel.textColor = axTrusted ? .systemGreen : .systemOrange
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        let idx = providerPopup.indexOfSelectedItem
        if idx >= 0 && idx < Provider.allCases.count {
            PreferencesManager.shared.preferredProvider = Provider.allCases[idx]
            onSettingsChanged?()
        }
    }

    @objc private func shortcutChanged() {
        let idx = shortcutPopup.indexOfSelectedItem
        if idx >= 0 && idx < ShortcutOption.allCases.count {
            let chosen = ShortcutOption.allCases[idx]
            PreferencesManager.shared.shortcutOption = chosen
            KeyboardShortcutMonitor.shared.updateShortcut(chosen, customCombo: PreferencesManager.shared.customKeyCombo)
            customShortcutButton.isEnabled = (chosen == .custom)
            onSettingsChanged?()
        }
    }

    @objc private func dockToggled() {
        let show = (dockCheckbox.state == .on)
        PreferencesManager.shared.showDockIcon = show
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        onSettingsChanged?()
    }

    @objc private func runSetupWizardAction() {
        window?.orderOut(nil)
        OnboardingWindowController.shared.restartFromBeginning()
    }

    @objc private func recordCustomShortcutAction() {
        customShortcutButton.title = "Press keys..."
        customShortcutButton.isEnabled = false
        statusMessageLabel.stringValue = "Press your desired key combination (e.g. ⌃⌥D). Esc to cancel."
        statusMessageLabel.textColor = .systemBlue

        activeRecorder = ShortcutRecorderSession()
        activeRecorder?.onCaptured = { [weak self] combo in
            DispatchQueue.main.async {
                PreferencesManager.shared.customKeyCombo = combo
                PreferencesManager.shared.shortcutOption = .custom
                KeyboardShortcutMonitor.shared.updateShortcut(.custom, customCombo: combo)
                self?.customShortcutBadge.stringValue = combo.displayString
                self?.customShortcutButton.title = "Record..."
                self?.customShortcutButton.isEnabled = true
                self?.shortcutPopup.selectItem(withTitle: ShortcutOption.custom.displayName)
                self?.statusMessageLabel.stringValue = "Saved custom shortcut: \(combo.displayString) ✓"
                self?.statusMessageLabel.textColor = .systemGreen
                self?.onSettingsChanged?()
            }
        }
        activeRecorder?.onCancelled = { [weak self] in
            DispatchQueue.main.async {
                self?.customShortcutButton.title = "Record..."
                self?.customShortcutButton.isEnabled = true
                self?.statusMessageLabel.stringValue = "Cancelled shortcut recording."
                self?.statusMessageLabel.textColor = .secondaryLabelColor
            }
        }
        activeRecorder?.onError = { [weak self] reason in
            DispatchQueue.main.async {
                self?.statusMessageLabel.stringValue = reason
                self?.statusMessageLabel.textColor = .systemRed
            }
        }
        activeRecorder?.startRecording()
    }

    @objc private func togglesChanged() {
        let prefs = PreferencesManager.shared
        prefs.allowCrossProviderFailover = (crossProviderCheckbox.state == .on)
        prefs.isSnippetsEnabled = (snippetsCheckbox.state == .on)
        prefs.isPeriodicPreviewEnabled = (previewCheckbox.state == .on)
        prefs.isSoundFeedbackEnabled = (soundCheckbox.state == .on)
        onSettingsChanged?()
    }

    @objc private func launchAtLoginToggled() {
        let targetState = (launchAtLoginCheckbox.state == .on)
        do {
            try LaunchAtLoginController.shared.setEnabled(targetState)
            refreshStateFromManagers()
        } catch {
            launchAtLoginCheckbox.state = LaunchAtLoginController.shared.isEnabled ? .on : .off
            statusMessageLabel.textColor = .systemRed
            statusMessageLabel.stringValue = "Could not update Login Item status: \(error.localizedDescription)"
        }
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        // Request the native macOS permission flow for THIS running app rather
        // than merely opening an unrelated Security & Privacy pane.
        _ = SystemAccessibilityController().isTrusted(promptIfNeeded: true)
        if !AXIsProcessTrusted(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissionIndicators()
    }

    @objc private func addKeyAction() {
        let secret = keySecretField.stringValue
        let pIdx = keyProviderPopup.indexOfSelectedItem
        let selectedProvider: Provider = (pIdx >= 0 && pIdx < Provider.allCases.count) ? Provider.allCases[pIdx] : Provider.infer(fromKey: secret)
        let customLabel = keyLabelField.stringValue

        do {
            let added = try KeychainCredentialManager.shared.addCredential(
                rawKey: secret,
                provider: selectedProvider,
                label: customLabel
            )
            keySecretField.stringValue = ""
            keyLabelField.stringValue = ""
            statusMessageLabel.textColor = .systemGreen
            statusMessageLabel.stringValue = "Added \(added.provider.shortName) key (\(added.maskedPreview)) to macOS Keychain."
            refreshStateFromManagers()
            onSettingsChanged?()
        } catch {
            statusMessageLabel.textColor = .systemRed
            statusMessageLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func replaceKeyAction() {
        let row = credentialsTableView.selectedRow
        guard row >= 0 && row < metadataItems.count else {
            statusMessageLabel.textColor = .systemRed
            statusMessageLabel.stringValue = "Select an existing credential row in the table to replace."
            return
        }
        let targetMeta = metadataItems[row]
        let pIdx = keyProviderPopup.indexOfSelectedItem
        let selectedProvider: Provider = (pIdx >= 0 && pIdx < Provider.allCases.count) ? Provider.allCases[pIdx] : targetMeta.provider

        do {
            let updated = try KeychainCredentialManager.shared.replaceCredential(
                id: targetMeta.id,
                newRawKey: keySecretField.stringValue,
                provider: selectedProvider,
                label: keyLabelField.stringValue
            )
            keySecretField.stringValue = ""
            statusMessageLabel.textColor = .systemGreen
            statusMessageLabel.stringValue = "Updated credential '\(updated.label)' (\(updated.maskedPreview)) in Keychain."
            refreshStateFromManagers()
            onSettingsChanged?()
        } catch {
            statusMessageLabel.textColor = .systemRed
            statusMessageLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func removeKeyAction() {
        let row = credentialsTableView.selectedRow
        guard row >= 0 && row < metadataItems.count else {
            statusMessageLabel.textColor = .systemRed
            statusMessageLabel.stringValue = "Select a credential row to remove."
            return
        }
        let targetMeta = metadataItems[row]
        do {
            try KeychainCredentialManager.shared.removeCredential(id: targetMeta.id)
            statusMessageLabel.textColor = .secondaryLabelColor
            statusMessageLabel.stringValue = "Removed '\(targetMeta.label)' from Keychain."
            refreshStateFromManagers()
            onSettingsChanged?()
        } catch {
            statusMessageLabel.textColor = .systemRed
            statusMessageLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func moveUpAction() {
        let row = credentialsTableView.selectedRow
        guard row > 0 && row < metadataItems.count else { return }
        KeychainCredentialManager.shared.moveCredential(fromIndex: row, toIndex: row - 1)
        refreshStateFromManagers()
        credentialsTableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
        onSettingsChanged?()
    }

    @objc private func moveDownAction() {
        let row = credentialsTableView.selectedRow
        guard row >= 0 && row < (metadataItems.count - 1) else { return }
        KeychainCredentialManager.shared.moveCredential(fromIndex: row, toIndex: row + 1)
        refreshStateFromManagers()
        credentialsTableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
        onSettingsChanged?()
    }

    @objc private func closeWindowAction() {
        window?.close()
    }

    // MARK: - Table View Data Source & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return metadataItems.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < metadataItems.count else { return nil }
        let meta = metadataItems[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "priority":
            text = "\(row + 1)"
        case "provider":
            text = meta.provider.shortName
        case "label":
            text = meta.label
        case "masked":
            text = meta.maskedPreview
        default:
            text = ""
        }
        let lbl = NSTextField(labelWithString: text)
        lbl.font = (tableColumn?.identifier.rawValue == "masked")
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        return lbl
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = credentialsTableView.selectedRow
        guard row >= 0 && row < metadataItems.count else { return }
        let meta = metadataItems[row]
        keyLabelField.stringValue = meta.label
        if let idx = Provider.allCases.firstIndex(of: meta.provider) {
            keyProviderPopup.selectItem(at: idx)
        }
        // Never populate keySecretField with the stored secret!
        keySecretField.stringValue = ""
    }
}

// ============================================================================
// FILE: DictationCoordinator.swift
// ============================================================================
// MARK: - Recorder Abstraction for Unit Testing

public protocol AudioRecordingSession: AnyObject {
    var isRecording: Bool { get }
    @discardableResult func record() -> Bool
    func stop()
}

extension AVAudioRecorder: AudioRecordingSession {}

public protocol AudioRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any], delegate: AVAudioRecorderDelegate?) throws -> AudioRecordingSession
}

public struct SystemAudioRecorderFactory: AudioRecorderFactory {
    public init() {}

    public func makeRecorder(url: URL, settings: [String: Any], delegate: AVAudioRecorderDelegate?) throws -> AudioRecordingSession {
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = delegate
        return recorder
    }
}

// MARK: - Alert & HUD Presenter Abstraction (Prevents Modal NSAlert Hang in XCTest/CI)

public protocol UserAlertPresenting: AnyObject {
    func presentMicrophonePermissionDeniedAlert()
    func showHUD(text: String, autoDismiss: Double?)
    func hideHUD()
}

public final class SystemUserAlertPresenter: UserAlertPresenting {
    public init() {}

    public func presentMicrophonePermissionDeniedAlert() {
        // Never open a blocking modal NSAlert when running under XCTest
        guard NSClassFromString("XCTestCase") == nil else { return }

        let work = {
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Required"
            alert.informativeText = "QuickDictate needs microphone access to record speech for transcription.\n\nPlease open System Settings → Privacy & Security → Microphone and enable QuickDictate."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    public func showHUD(text: String, autoDismiss: Double? = nil) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        HUDWindowController.shared.show(text: text, autoDismiss: autoDismiss)
    }

    public func hideHUD() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        HUDWindowController.shared.hide()
    }
}

// MARK: - Dictation Coordinator (Single-State-Machine Lifecycle)

public final class DictationCoordinator: NSObject, AVAudioRecorderDelegate {
    public static let shared = DictationCoordinator()

    public private(set) var state: DictationLifecycleState = .idle {
        didSet {
            onStateChange?(state)
            updateStatusBarIcon(for: state.iconState)
            onMenuNeedsUpdate?()
        }
    }

    public var statusItem: NSStatusItem?
    public var onStateChange: ((DictationLifecycleState) -> Void)?
    public var onMenuNeedsUpdate: (() -> Void)?

    private let credentialManager: KeychainCredentialManager
    private let audioFileManager: AudioSessionFileManager
    private let permissionChecker: MicrophonePermissionChecking
    private let recorderFactory: AudioRecorderFactory
    private let transcriptionClient: TranscriptionClient
    private let previewClient: TranscriptionClient
    private let snippetManager: SnippetManager
    private let textInsertionManager: TextInsertionManager
    private let preferences: PreferencesManager
    private let alertPresenter: UserAlertPresenting

    private var activeRecorder: AudioRecordingSession?
    private var capturedTargetApp: TargetApplicationContext?

    // Session-Scoped Bounded Periodic Preview State
    private var previewTimer: Timer?
    private var activePreviewSessionID: UUID?
    private var activePreviewRequestID: UUID?
    public private(set) var previewRequestsSentInSession: Int = 0
    public let maxPreviewRequestsPerSession: Int = 6
    public let previewIntervalSeconds: TimeInterval = 2.5

    public var isPreviewRequestInFlight: Bool {
        return activePreviewRequestID != nil
    }

    public init(
        credentialManager: KeychainCredentialManager = .shared,
        audioFileManager: AudioSessionFileManager = AudioSessionFileManager(),
        permissionChecker: MicrophonePermissionChecking = SystemMicrophonePermissionChecker(),
        recorderFactory: AudioRecorderFactory = SystemAudioRecorderFactory(),
        transcriptionClient: TranscriptionClient = TranscriptionClient(),
        previewClient: TranscriptionClient = TranscriptionClient(),
        snippetManager: SnippetManager = .shared,
        textInsertionManager: TextInsertionManager = .shared,
        preferences: PreferencesManager = .shared,
        alertPresenter: UserAlertPresenting = SystemUserAlertPresenter()
    ) {
        self.credentialManager = credentialManager
        self.audioFileManager = audioFileManager
        self.permissionChecker = permissionChecker
        self.recorderFactory = recorderFactory
        self.transcriptionClient = transcriptionClient
        self.previewClient = previewClient
        self.snippetManager = snippetManager
        self.textInsertionManager = textInsertionManager
        self.preferences = preferences
        self.alertPresenter = alertPresenter
        super.init()
    }

    // MARK: - Public Actions

    public func toggleDictation() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.toggleDictation()
            }
            return
        }

        switch state {
        case .idle, .completed, .failed:
            startRecordingFlow()
        case .recording(let sessionID, let fileURL):
            stopAndTranscribe(sessionID: sessionID, fileURL: fileURL)
        case .requestingPermission:
            break
        case .stopping, .transcribing:
            break
        }
    }

    public func cancelActiveOperation() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.cancelActiveOperation()
            }
            return
        }

        stopPreviewSubsystem()
        transcriptionClient.cancelCurrentRequest()

        switch state {
        case .recording(_, let url), .stopping(_, let url), .transcribing(_, let url):
            activeRecorder?.stop()
            activeRecorder = nil
            audioFileManager.cleanupRecordingFile(at: url)
            state = .idle
            alertPresenter.showHUD(text: "Dictation cancelled", autoDismiss: 1.5)
        case .requestingPermission:
            state = .idle
        case .idle, .completed, .failed:
            break
        }
    }

    public func handleApplicationTermination() {
        stopPreviewSubsystem()
        transcriptionClient.cancelCurrentRequest()
        activeRecorder?.stop()
        activeRecorder = nil
        audioFileManager.cleanupAllRecordings()
        KeyboardShortcutMonitor.shared.stopMonitoring()
        state = .idle
    }

    // MARK: - Recording Lifecycle

    public func startRecordingFlow() {
        // 1. Verify credentials exist for the selected provider (or failover)
        let activeCreds = credentialManager.resolveCredentials(
            preferredProvider: preferences.preferredProvider,
            allowCrossProviderFailover: preferences.allowCrossProviderFailover
        )
        guard !activeCreds.isEmpty else {
            let allMeta = credentialManager.listMetadata()
            let msg: String
            if allMeta.isEmpty {
                msg = "Add a Groq or OpenAI API key in Keychain to start dictating."
            } else {
                msg = "No API keys found for \(preferences.preferredProvider.shortName). Add a key or switch your primary provider."
            }
            if NSClassFromString("XCTestCase") == nil {
                SettingsWindowController.shared.show(initialMessage: msg, isError: true)
            }
            return
        }

        // 2. Check Microphone Authorization Status
        let authStatus = permissionChecker.authorizationStatus()
        switch authStatus {
        case .authorized:
            beginRecordingSession()
        case .notDetermined:
            state = .requestingPermission
            permissionChecker.requestAccess { [weak self] granted in
                guard let self = self else { return }
                guard self.state == .requestingPermission else { return }
                if granted {
                    self.beginRecordingSession()
                } else {
                    self.state = .failed(sessionID: nil, message: AudioSessionError.permissionDenied.localizedDescription)
                    self.alertPresenter.presentMicrophonePermissionDeniedAlert()
                }
            }
        case .denied, .restricted:
            let err: AudioSessionError = (authStatus == .restricted) ? .permissionRestricted : .permissionDenied
            state = .failed(sessionID: nil, message: err.localizedDescription)
            alertPresenter.presentMicrophonePermissionDeniedAlert()
        @unknown default:
            state = .failed(sessionID: nil, message: AudioSessionError.permissionDenied.localizedDescription)
        }
    }

    private func beginRecordingSession() {
        let sessionID = UUID()
        let recordingURL: URL
        do {
            recordingURL = try audioFileManager.makeRecordingURL(for: sessionID)
        } catch {
            let msg = AudioSessionError.directoryCreationFailed(error.localizedDescription).localizedDescription
            state = .failed(sessionID: sessionID, message: msg)
            alertPresenter.showHUD(text: "⚠️ \(msg)", autoDismiss: 3.5)
            return
        }

        // Capture the target application + window/element tokens before recording begins
        capturedTargetApp = textInsertionManager.captureCurrentTargetApplication()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let recorder = try recorderFactory.makeRecorder(url: recordingURL, settings: settings, delegate: self)
            guard recorder.record(), recorder.isRecording else {
                audioFileManager.cleanupRecordingFile(at: recordingURL)
                let msg = AudioSessionError.recorderFailedToStart("Audio input device failed to start recording.").localizedDescription
                state = .failed(sessionID: sessionID, message: msg)
                SoundFeedbackPlayer.shared.play(.error, enabled: preferences.isSoundFeedbackEnabled)
                alertPresenter.showHUD(text: "⚠️ \(msg)", autoDismiss: 3.5)
                return
            }

            audioFileManager.secureRecordingFilePermissions(at: recordingURL)
            activeRecorder = recorder
            state = .recording(sessionID: sessionID, fileURL: recordingURL)
            SoundFeedbackPlayer.shared.play(.startRecording, enabled: preferences.isSoundFeedbackEnabled)

            if preferences.isPeriodicPreviewEnabled {
                alertPresenter.showHUD(text: "● Listening (Preview On)...", autoDismiss: nil)
                startPreviewSubsystem(sessionID: sessionID, fileURL: recordingURL)
            } else {
                alertPresenter.hideHUD()
            }
        } catch {
            audioFileManager.cleanupRecordingFile(at: recordingURL)
            let msg = AudioSessionError.recorderFailedToStart(error.localizedDescription).localizedDescription
            state = .failed(sessionID: sessionID, message: msg)
            SoundFeedbackPlayer.shared.play(.error, enabled: preferences.isSoundFeedbackEnabled)
            alertPresenter.showHUD(text: "⚠️ \(msg)", autoDismiss: 3.5)
        }
    }

    public func stopAndTranscribe(sessionID: UUID, fileURL: URL) {
        guard case .recording(let currentID, _) = state, currentID == sessionID else {
            return
        }

        // 1. Immediately cancel any preview timer and in-flight preview request
        stopPreviewSubsystem()

        // 2. Transition to stopping and synchronously stop AVAudioRecorder so WAV header is flushed
        state = .stopping(sessionID: sessionID, fileURL: fileURL)
        activeRecorder?.stop()
        activeRecorder = nil

        SoundFeedbackPlayer.shared.play(.stopRecording, enabled: preferences.isSoundFeedbackEnabled)
        if preferences.isPeriodicPreviewEnabled {
            alertPresenter.showHUD(text: "● Transcribing...", autoDismiss: nil)
        }

        // 3. Validate final WAV file and begin transcription
        state = .transcribing(sessionID: sessionID, fileURL: fileURL)

        let audioData: Data
        do {
            audioData = try AudioSessionFileManager.validateAndReadWAV(at: fileURL)
        } catch {
            audioFileManager.cleanupRecordingFile(at: fileURL)
            let msg = error.localizedDescription
            state = .failed(sessionID: sessionID, message: msg)
            alertPresenter.showHUD(text: "⚠️ \(msg)", autoDismiss: 3.0)
            state = .idle
            return
        }

        let credentials = credentialManager.resolveCredentials(
            preferredProvider: preferences.preferredProvider,
            allowCrossProviderFailover: preferences.allowCrossProviderFailover
        )

        transcriptionClient.transcribeAudio(
            audioData: audioData,
            filename: "dictation.wav",
            credentials: credentials,
            allowCrossProviderFailover: preferences.allowCrossProviderFailover
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Always clean up the temporary WAV file once the network call completes
                self.audioFileManager.cleanupRecordingFile(at: fileURL)

                // Verify that this session is still the active transcribing session (prevents late/stale paste)
                guard case .transcribing(let activeID, _) = self.state, activeID == sessionID else {
                    return
                }

                switch result {
                case .success(let response):
                    let rawTrimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawTrimmed.isEmpty else {
                        self.state = .failed(sessionID: sessionID, message: TranscriptionClientError.emptyTranscription.localizedDescription)
                        self.alertPresenter.showHUD(text: "⚠️ No speech detected", autoDismiss: 2.5)
                        self.state = .idle
                        return
                    }

                    let expanded = self.snippetManager.expand(
                        in: rawTrimmed,
                        isEnabled: self.preferences.isSnippetsEnabled
                    )

                    self.state = .completed(sessionID: sessionID)
                    self.deliverTranscriptionResult(expanded, sessionID: sessionID)
                    self.state = .idle

                case .failure(let error):
                    if error == .cancelled {
                        self.state = .idle
                        return
                    }
                    let msg = error.localizedDescription
                    self.state = .failed(sessionID: sessionID, message: msg)
                    SoundFeedbackPlayer.shared.play(.error, enabled: self.preferences.isSoundFeedbackEnabled)
                    self.alertPresenter.showHUD(text: "⚠️ \(msg)", autoDismiss: 4.0)
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Delivering Transcription Safely

    private func deliverTranscriptionResult(_ text: String, sessionID: UUID) {
        let currentApp = textInsertionManager.captureCurrentTargetApplication()
        let outcome = textInsertionManager.insertTranscribedText(
            text,
            sessionID: sessionID,
            expectedTarget: capturedTargetApp,
            currentTarget: currentApp
        )

        switch outcome {
        case .pasteEventDispatched:
            if preferences.isPeriodicPreviewEnabled {
                alertPresenter.showHUD(text: "✦ \"\(text)\"", autoDismiss: 2.2)
            }
        case .focusChanged(let expected, let actual, _):
            alertPresenter.showHUD(
                text: "📋 Focus changed (\(expected) → \(actual)). Copied to clipboard — press ⌘V to paste.",
                autoDismiss: 4.5
            )
        case .windowOrElementChanged(let appName, _):
            alertPresenter.showHUD(
                text: "📋 Active window/field in \(appName) changed. Copied to clipboard — press ⌘V to paste.",
                autoDismiss: 4.5
            )
        case .accessibilityPermissionMissing:
            alertPresenter.showHUD(
                text: "📋 Copied to clipboard. Allow this QuickDictate app in Accessibility, then reopen it for auto-paste.",
                autoDismiss: 4.5
            )
        case .targetUnavailable:
            alertPresenter.showHUD(
                text: "📋 Destination unverified. Copied to clipboard — press ⌘V to paste.",
                autoDismiss: 3.5
            )
        case .duplicateBlocked:
            break
        }
    }

    // MARK: - Session-Scoped Bounded Periodic Preview Subsystem

    private func startPreviewSubsystem(sessionID: UUID, fileURL: URL) {
        stopPreviewSubsystem()
        activePreviewSessionID = sessionID
        activePreviewRequestID = nil
        previewRequestsSentInSession = 0

        previewTimer = Timer.scheduledTimer(withTimeInterval: previewIntervalSeconds, repeats: true) { [weak self] _ in
            self?.triggerPreviewPoll(sessionID: sessionID, fileURL: fileURL)
        }
    }

    private func stopPreviewSubsystem() {
        previewTimer?.invalidate()
        previewTimer = nil
        activePreviewSessionID = nil
        activePreviewRequestID = nil
        previewClient.cancelCurrentRequest()
    }

    /// Triggers a single preview poll for `sessionID`. Exposed `public` so unit tests can deterministically test session-scoped preview race conditions.
    public func triggerPreviewPoll(sessionID: UUID, fileURL: URL) {
        guard case .recording(let activeID, _) = state,
              activeID == sessionID,
              activePreviewSessionID == sessionID,
              preferences.isPeriodicPreviewEnabled,
              activePreviewRequestID == nil,
              previewRequestsSentInSession < maxPreviewRequestsPerSession else {
            return
        }

        let creds = credentialManager.resolveCredentials(
            preferredProvider: preferences.preferredProvider,
            allowCrossProviderFailover: false
        )
        guard let primaryCred = creds.first,
              let wavSnapshot = AudioSessionFileManager.makePatchedPreviewWAVSnapshot(at: fileURL) else {
            return
        }

        let requestID = UUID()
        activePreviewRequestID = requestID
        previewRequestsSentInSession += 1

        previewClient.transcribeAudio(
            audioData: wavSnapshot,
            filename: "preview.wav",
            credentials: [primaryCred],
            allowCrossProviderFailover: false,
            timeoutInterval: 4.0,
            maxSameKeyRetries: 0
        ) { [weak self] result in
            let handlePreviewCallback = { [weak self] in
                guard let self = self else { return }

                // CRITICAL SESSION & REQUEST IDENTITY GUARD:
                // Only mutate `activePreviewRequestID` or update the HUD if this callback belongs to the
                // currently active preview session (`activePreviewSessionID == sessionID`) AND the currently
                // in-flight request (`activePreviewRequestID == requestID`).
                // A late callback from an older recording session can NEVER clear `activePreviewRequestID` of a newer session!
                guard self.activePreviewSessionID == sessionID,
                      self.activePreviewRequestID == requestID else {
                    return
                }

                self.activePreviewRequestID = nil

                guard case .recording(let currentID, _) = self.state,
                      currentID == sessionID,
                      self.preferences.isPeriodicPreviewEnabled else {
                    return
                }

                if case .success(let previewSuccess) = result, !previewSuccess.text.isEmpty {
                    let expanded = self.snippetManager.expand(
                        in: previewSuccess.text,
                        isEnabled: self.preferences.isSnippetsEnabled
                    )
                    self.alertPresenter.showHUD(text: "● \(expanded)", autoDismiss: nil)
                }
            }

            if Thread.isMainThread {
                handlePreviewCallback()
            } else {
                DispatchQueue.main.async(execute: handlePreviewCallback)
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate (Interruptions & Encoding Errors)

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if case .recording(let id, let url) = self.state {
                self.stopPreviewSubsystem()
                self.activeRecorder?.stop()
                self.activeRecorder = nil
                self.audioFileManager.cleanupRecordingFile(at: url)
                let msg = "Audio recording interrupted: \(error?.localizedDescription ?? "Unknown encoding error")"
                self.state = .failed(sessionID: id, message: msg)
                self.alertPresenter.showHUD(text: "⚠️ \(msg)", autoDismiss: 3.5)
                self.state = .idle
            }
        }
    }

    // MARK: - UI Helpers

    /// App startup does not change `state`, so its didSet observer does not run.
    /// Initialize the status-bar icon explicitly when AppDelegate installs the NSStatusItem.
    public func initializeStatusBarIcon() {
        updateStatusBarIcon(for: state.iconState)
    }

    private func updateStatusBarIcon(for iconState: IconState) {
        let work = { [weak self] in
            guard let button = self?.statusItem?.button else { return }
            button.title = ""

            let symbolName: String
            let weight: NSFont.Weight
            switch iconState {
            case .idle:
                symbolName = "waveform"
                weight = .medium
            case .recording:
                symbolName = "waveform.circle.fill"
                weight = .semibold
            case .processing:
                symbolName = "ellipsis.circle"
                weight = .medium
            }

            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: weight)
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "QuickDictate")?.withSymbolConfiguration(config) {
                img.isTemplate = true
                button.image = img
            } else {
                // Keep the menu item usable even on systems where the SF Symbol cannot render.
                button.image = nil
                button.title = "QD"
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

// ============================================================================
// FILE: AppDelegate.swift
// ============================================================================
// MARK: - Application Delegate & Menu Bar Controller

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private var cancelMenuItem: NSMenuItem!
    private var copyLastMenuItem: NSMenuItem!
    private var providerMenuItem: NSMenuItem!
    private var snippetsToggleItem: NSMenuItem!
    private var previewToggleItem: NSMenuItem!
    private var soundToggleItem: NSMenuItem!
    private var crossProviderToggleItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Clean up any stale temporary recordings left behind from a prior crash
        AudioSessionFileManager().cleanupAllRecordings()

        // 2. Perform safe, one-time migration of legacy plaintext credential files (~/.quickdictate_keys, ~/.quickdictate_key)
        let migrationOutcome = KeychainCredentialManager.shared.migrateLegacyPlaintextKeysIfNeeded()

        // 3. Configure Menu Bar Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        DictationCoordinator.shared.statusItem = statusItem
        // The initial lifecycle state is `.idle`, so `didSet` never fires on startup.
        // Without this call a variable-length status item has no title or image and is invisible.
        DictationCoordinator.shared.initializeStatusBarIcon()
        DictationCoordinator.shared.onMenuNeedsUpdate = { [weak self] in
            self?.refreshMenuState()
        }
        SettingsWindowController.shared.onSettingsChanged = { [weak self] in
            self?.refreshMenuState()
        }

        buildMenuBarMenu()
        DictationCoordinator.shared.onMenuNeedsUpdate?()

        // 4. Configure Keyboard Shortcut Monitor
        let activeShortcut = PreferencesManager.shared.shortcutOption
        KeyboardShortcutMonitor.shared.updateShortcut(activeShortcut, customCombo: PreferencesManager.shared.customKeyCombo)
        KeyboardShortcutMonitor.shared.onToggleRequested = {
            DictationCoordinator.shared.toggleDictation()
        }
        if PreferencesManager.shared.isOnboardingCompleted {
            KeyboardShortcutMonitor.shared.startMonitoring()
        }

        // 5. Surface any legacy credential migration error or malformed snippet JSON warning without losing user data
        if let migrationErr = migrationOutcome.errorMessage {
            SettingsWindowController.shared.show(initialMessage: migrationErr, isError: true)
        } else if migrationOutcome.migratedCount > 0 {
            HUDWindowController.shared.show(
                text: "🔒 Migrated \(migrationOutcome.migratedCount) API key(s) to macOS Keychain",
                autoDismiss: 3.5
            )
        }

        if let snippetErr = SnippetManager.shared.lastLoadError {
            HUDWindowController.shared.show(
                text: "⚠️ Snippets JSON syntax error — original file preserved",
                autoDismiss: 4.0
            )
            SafeLogger.logError(snippetErr.localizedDescription)
        }

        // 6. First-Launch Setup Wizard or returning user activation policy
        if !PreferencesManager.shared.isSetupFullyConfigured {
            OnboardingWindowController.shared.show()
        } else {
            if PreferencesManager.shared.showDockIcon {
                NSApp.setActivationPolicy(.regular)
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !PreferencesManager.shared.isSetupFullyConfigured {
            OnboardingWindowController.shared.show()
        } else {
            SettingsWindowController.shared.show()
        }
        return true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        if !PreferencesManager.shared.isSetupFullyConfigured {
            OnboardingWindowController.shared.handleAppDidBecomeActive()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        DictationCoordinator.shared.handleApplicationTermination()
    }

    // MARK: - Menu Construction & Refresh

    private func buildMenuBarMenu() {
        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictationAction), keyEquivalent: "d")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        cancelMenuItem = NSMenuItem(title: "Cancel Active Dictation", action: #selector(cancelDictationAction), keyEquivalent: ".")
        cancelMenuItem.target = self
        cancelMenuItem.isHidden = true
        menu.addItem(cancelMenuItem)

        copyLastMenuItem = NSMenuItem(title: "Copy Last Transcription", action: #selector(copyLastTranscriptionAction), keyEquivalent: "c")
        copyLastMenuItem.target = self
        menu.addItem(copyLastMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Provider Submenu
        providerMenuItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerSubmenu = NSMenu()
        for p in Provider.allCases {
            let item = NSMenuItem(title: p.displayName, action: #selector(selectProviderAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            providerSubmenu.addItem(item)
        }
        providerMenuItem.submenu = providerSubmenu
        menu.addItem(providerMenuItem)

        crossProviderToggleItem = NSMenuItem(
            title: "Allow Cross-Provider Failover",
            action: #selector(toggleCrossProviderAction),
            keyEquivalent: ""
        )
        crossProviderToggleItem.target = self
        menu.addItem(crossProviderToggleItem)

        menu.addItem(NSMenuItem.separator())

        let manageSnippetsItem = NSMenuItem(title: "Manage Voice Snippets...", action: #selector(manageSnippetsAction), keyEquivalent: "m")
        manageSnippetsItem.target = self
        menu.addItem(manageSnippetsItem)

        snippetsToggleItem = NSMenuItem(title: "Voice Snippets Expansion", action: #selector(toggleSnippetsAction), keyEquivalent: "e")
        snippetsToggleItem.target = self
        menu.addItem(snippetsToggleItem)

        previewToggleItem = NSMenuItem(
            title: "Periodic Preview HUD (Uses Extra API Quota)",
            action: #selector(togglePreviewAction),
            keyEquivalent: "l"
        )
        previewToggleItem.target = self
        menu.addItem(previewToggleItem)

        soundToggleItem = NSMenuItem(title: "Audio Feedback Chimes", action: #selector(toggleSoundAction), keyEquivalent: "")
        soundToggleItem.target = self
        menu.addItem(soundToggleItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLoginAction), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let setupWizardItem = NSMenuItem(title: "Run Setup Wizard...", action: #selector(openSetupWizardAction), keyEquivalent: "")
        setupWizardItem.target = self
        menu.addItem(setupWizardItem)

        settingsMenuItem = NSMenuItem(title: "Settings & API Keys...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit QuickDictate", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    public func refreshMenuState() {
        let work = { [weak self] in
            guard let self = self else { return }
            let prefs = PreferencesManager.shared
            let state = DictationCoordinator.shared.state

            let shortcutLabel = prefs.shortcutOption.displayName
            switch state {
            case .recording:
                self.toggleMenuItem.title = "Stop & Transcribe (\(shortcutLabel))"
                self.cancelMenuItem.isHidden = false
            case .stopping, .transcribing:
                self.toggleMenuItem.title = "Transcribing..."
                self.cancelMenuItem.isHidden = false
            case .requestingPermission:
                self.toggleMenuItem.title = "Requesting Microphone Permission..."
                self.cancelMenuItem.isHidden = true
            case .idle, .completed, .failed:
                self.toggleMenuItem.title = "Start Dictation (\(shortcutLabel))"
                self.cancelMenuItem.isHidden = true
            }

            let hasLast = (TextInsertionManager.shared.lastTranscriptionText?.isEmpty == false)
            self.copyLastMenuItem.isEnabled = hasLast

            self.providerMenuItem.title = "Primary Provider: \(prefs.preferredProvider.shortName)"
            if let subItems = self.providerMenuItem.submenu?.items {
                for item in subItems {
                    let isSelected = (item.representedObject as? String) == prefs.preferredProvider.rawValue
                    item.state = isSelected ? .on : .off
                }
            }

            self.crossProviderToggleItem.state = prefs.allowCrossProviderFailover ? .on : .off
            self.snippetsToggleItem.state = prefs.isSnippetsEnabled ? .on : .off
            self.previewToggleItem.state = prefs.isPeriodicPreviewEnabled ? .on : .off
            self.soundToggleItem.state = prefs.isSoundFeedbackEnabled ? .on : .off

            if LaunchAtLoginController.shared.isSupportedNatively {
                self.launchAtLoginItem.title = "Launch at Login"
                self.launchAtLoginItem.state = LaunchAtLoginController.shared.isEnabled ? .on : .off
            } else {
                self.launchAtLoginItem.title = "Configure Login Items (macOS 12)..."
                self.launchAtLoginItem.state = .off
            }

            let keyCount = KeychainCredentialManager.shared.listMetadata().count
            self.settingsMenuItem.title = "Settings & Keychain Keys (\(keyCount) Stored)..."
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleDictationAction() {
        DictationCoordinator.shared.toggleDictation()
    }

    @objc private func cancelDictationAction() {
        DictationCoordinator.shared.cancelActiveOperation()
    }

    @objc private func copyLastTranscriptionAction() {
        if TextInsertionManager.shared.copyLastTranscriptionToClipboard() {
            HUDWindowController.shared.show(text: "📋 Copied last transcription to clipboard", autoDismiss: 2.0)
        }
    }

    @objc private func selectProviderAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let provider = Provider(rawValue: raw) {
            PreferencesManager.shared.preferredProvider = provider
            refreshMenuState()
            SettingsWindowController.shared.refreshStateFromManagers()
        }
    }

    @objc private func toggleCrossProviderAction() {
        PreferencesManager.shared.allowCrossProviderFailover.toggle()
        refreshMenuState()
        SettingsWindowController.shared.refreshStateFromManagers()
    }

    @objc private func manageSnippetsAction() {
        SnippetWindowController.shared.show()
    }

    @objc private func toggleSnippetsAction() {
        PreferencesManager.shared.isSnippetsEnabled.toggle()
        refreshMenuState()
        SettingsWindowController.shared.refreshStateFromManagers()
    }

    @objc private func togglePreviewAction() {
        PreferencesManager.shared.isPeriodicPreviewEnabled.toggle()
        refreshMenuState()
        SettingsWindowController.shared.refreshStateFromManagers()
    }

    @objc private func toggleSoundAction() {
        PreferencesManager.shared.isSoundFeedbackEnabled.toggle()
        refreshMenuState()
        SettingsWindowController.shared.refreshStateFromManagers()
    }

    @objc private func toggleLaunchAtLoginAction() {
        let nextState = !LaunchAtLoginController.shared.isEnabled
        try? LaunchAtLoginController.shared.setEnabled(nextState)
        refreshMenuState()
        SettingsWindowController.shared.refreshStateFromManagers()
    }

    @objc private func openSetupWizardAction() {
        OnboardingWindowController.shared.restartFromBeginning()
    }

    @objc private func openSettingsAction() {
        SettingsWindowController.shared.show()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}

// ============================================================================
// FILE: main.swift
// ============================================================================
// Avoid starting the NSApplication run loop when unit test bundles are loaded under XCTest.
let isRunningTests = NSClassFromString("XCTestCase") != nil

// NSApplication's delegate is weak. Retain the delegate for the app's entire lifetime.
private var retainedQuickDictateDelegate: AppDelegate?

if !isRunningTests {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedQuickDictateDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
