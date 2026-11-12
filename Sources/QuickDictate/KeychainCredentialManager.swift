import Foundation
import Security

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
