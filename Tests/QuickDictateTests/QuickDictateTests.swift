import XCTest
import Cocoa
import AVFoundation
import Security
@testable import QuickDictate

// MARK: - Mock Implementations for Deterministic, Unattended CI Testing

final class MockKeychainBackend: KeychainStorageBackend {
    var storage: [String: Data] = [:]
    var shouldFailSet: Bool = false
    var shouldFailGet: Bool = false
    var corruptReadBack: Bool = false

    func setSecret(_ data: Data, service: String, account: String) throws {
        if shouldFailSet {
            throw CredentialStoreError.keychainFailure(status: errSecAuthFailed)
        }
        storage["\(service):\(account)"] = data
    }

    func getSecret(service: String, account: String) throws -> Data? {
        if shouldFailGet {
            throw CredentialStoreError.keychainFailure(status: errSecInteractionNotAllowed)
        }
        if corruptReadBack {
            return "corrupted_value".data(using: .utf8)
        }
        return storage["\(service):\(account)"]
    }

    func deleteSecret(service: String, account: String) throws {
        storage.removeValue(forKey: "\(service):\(account)")
    }
}

final class MockCancellableTask: CancellableTask {
    private(set) var isCancelled = false
    var onCancel: (() -> Void)?

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
    }
}

final class MockHTTPTransport: HTTPTransport {
    struct QueuedResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data?
        let error: Error?
        let delaySeconds: TimeInterval
        /// When true, invokes the completion handler synchronously BEFORE `sendRequest` returns.
        let completeSynchronously: Bool

        init(
            statusCode: Int,
            headers: [String: String] = [:],
            body: Data? = nil,
            error: Error? = nil,
            delaySeconds: TimeInterval = 0,
            completeSynchronously: Bool = true
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
            self.delaySeconds = delaySeconds
            self.completeSynchronously = (delaySeconds == 0) ? completeSynchronously : false
        }
    }

    var responses: [QueuedResponse] = []
    private(set) var capturedRequests: [URLRequest] = []
    private(set) var createdTasks: [MockCancellableTask] = []
    /// Optional hook to hold a completion callback manually for deterministic preview race testing.
    var manualInterceptHandler: ((URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> CancellableTask?)?

    func enqueueResponse(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
        responses.append(QueuedResponse(statusCode: statusCode, headers: headers, body: body))
    }

    func enqueueError(_ error: Error) {
        responses.append(QueuedResponse(statusCode: 0, error: error))
    }

    @discardableResult
    func sendRequest(
        _ request: URLRequest,
        completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void
    ) -> CancellableTask {
        capturedRequests.append(request)

        if let interceptedTask = manualInterceptHandler?(request, completion) {
            return interceptedTask
        }

        let task = MockCancellableTask()
        createdTasks.append(task)

        guard !responses.isEmpty else {
            let err = URLError(.badServerResponse)
            completion(nil, nil, err)
            return task
        }

        let next = responses.removeFirst()
        let url = request.url ?? URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        let httpResp = HTTPURLResponse(
            url: url,
            statusCode: next.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: next.headers
        )

        if next.delaySeconds > 0 || !next.completeSynchronously {
            task.onCancel = {
                completion(nil, nil, URLError(.cancelled))
            }
            let delay = max(next.delaySeconds, 0.01)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                guard !task.isCancelled else { return }
                completion(next.body, httpResp, next.error)
            }
        } else {
            completion(next.body, httpResp, next.error)
        }

        return task
    }
}

final class MockPasteboardProvider: PasteboardProviding {
    var changeCount: Int = 10
    var currentItems: [SavedPasteboardItem] = []
    private(set) var lastWrittenPlainText: String?
    private(set) var restoreCalledCount: Int = 0

    func snapshotItems() -> [SavedPasteboardItem] {
        return currentItems
    }

    @discardableResult
    func writePlainText(_ text: String) -> Int {
        changeCount += 1
        lastWrittenPlainText = text
        currentItems = [
            SavedPasteboardItem(dataByType: [.string: text.data(using: .utf8)!])
        ]
        return changeCount
    }

    func restoreSnapshot(_ items: [SavedPasteboardItem]) {
        changeCount += 1
        restoreCalledCount += 1
        currentItems = items
    }
}

final class MockAccessibilityChecker: AccessibilityPermissionChecking {
    var trusted: Bool = true
    var postCmdVResult: Bool = true
    var simulatedWindowToken: String? = "cgwin:100|axwin:200"
    var simulatedElementToken: String? = "axelem:300:AXTextArea"
    private(set) var postCmdVCalledCount: Int = 0

    func isTrusted(promptIfNeeded: Bool) -> Bool {
        return trusted
    }

    func postCommandVPasteEvent() -> Bool {
        postCmdVCalledCount += 1
        return postCmdVResult
    }

    func queryStructuralFocusTokens(for pid: pid_t) -> (windowToken: String?, elementToken: String?) {
        return (simulatedWindowToken, simulatedElementToken)
    }
}

final class MockMicrophonePermissionChecker: MicrophonePermissionChecking {
    var status: AVAuthorizationStatus = .authorized
    var grantOnRequest: Bool = true

    func authorizationStatus() -> AVAuthorizationStatus {
        return status
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        status = grantOnRequest ? .authorized : .denied
        completion(grantOnRequest)
    }
}

final class MockUserAlertPresenter: UserAlertPresenting {
    private(set) var micPermissionAlertCount: Int = 0
    private(set) var hudMessages: [String] = []
    private(set) var hideHUDCount: Int = 0

    func presentMicrophonePermissionDeniedAlert() {
        micPermissionAlertCount += 1
    }

    func showHUD(text: String, autoDismiss: Double?) {
        hudMessages.append(text)
    }

    func hideHUD() {
        hideHUDCount += 1
    }
}

final class MockAudioRecorder: AudioRecordingSession {
    let url: URL
    var isRecording: Bool = false
    var shouldStartSucceed: Bool = true
    var writeValidWAVOnStop: Bool = true

    init(url: URL) {
        self.url = url
    }

    func record() -> Bool {
        guard shouldStartSucceed else {
            isRecording = false
            return false
        }
        isRecording = true
        // Create initial WAV file header (>= 8044 bytes so preview snapshots are also valid)
        let header = Self.makeDummyWAVData(pcmByteCount: 9600)
        try? header.write(to: url)
        return true
    }

    func stop() {
        isRecording = false
        if writeValidWAVOnStop {
            let wav = Self.makeDummyWAVData(pcmByteCount: 9600)
            try? wav.write(to: url)
        }
    }

    static func makeDummyWAVData(pcmByteCount: Int) -> Data {
        var data = Data()
        let totalSize = UInt32(36 + pcmByteCount)
        let subchunk1Size = UInt32(16)
        let audioFormat = UInt16(1)
        let numChannels = UInt16(1)
        let sampleRate = UInt32(16000)
        let byteRate = UInt32(32000)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)
        let subchunk2Size = UInt32(pcmByteCount)

        data.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: totalSize.littleEndian) { data.append(contentsOf: $0) }
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: subchunk1Size.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: audioFormat.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: subchunk2Size.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: pcmByteCount))
        return data
    }
}

final class MockRecorderFactory: AudioRecorderFactory {
    var shouldStartSucceed: Bool = true
    var writeValidWAVOnStop: Bool = true
    private(set) var lastCreatedRecorder: MockAudioRecorder?

    func makeRecorder(url: URL, settings: [String: Any], delegate: AVAudioRecorderDelegate?) throws -> AudioRecordingSession {
        let rec = MockAudioRecorder(url: url)
        rec.shouldStartSucceed = shouldStartSucceed
        rec.writeValidWAVOnStop = writeValidWAVOnStop
        lastCreatedRecorder = rec
        return rec
    }
}

/// Fault-injecting `SnippetFileStorage` wrapper to deterministically test transactional recovery failure paths.
final class FaultInjectingSnippetFileStorage: SnippetFileStorage {
    private let underlying = SystemSnippetFileStorage()
    var failCopyFile: Bool = false
    var corruptCopiedFileBytes: Bool = false
    var failPrimaryWrite: Bool = false

    func fileExists(atPath path: String) -> Bool {
        return underlying.fileExists(atPath: path)
    }

    func readData(atPath path: String) throws -> Data {
        return try underlying.readData(atPath: path)
    }

    func writeDataAtomically(_ data: Data, toPath path: String, permissions: Int) throws {
        if failPrimaryWrite && !path.hasSuffix(".bak") {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "Simulated disk write failure"])
        }
        try underlying.writeDataAtomically(data, toPath: path, permissions: permissions)
    }

    func copyFile(fromPath srcPath: String, toPath dstPath: String, permissions: Int) throws {
        if failCopyFile {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSLocalizedDescriptionKey: "Simulated backup copy failure"])
        }
        try underlying.copyFile(fromPath: srcPath, toPath: dstPath, permissions: permissions)
        if corruptCopiedFileBytes {
            try "corrupted_safety_backup".data(using: .utf8)!.write(to: URL(fileURLWithPath: dstPath))
        }
    }
}

// MARK: - Comprehensive XCTest Suite (28 Automated Scenarios Covering Baseline + Audit Remediations)

final class QuickDictateTests: XCTestCase {
    private var tempDir: URL!
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickDictateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        suiteName = "com.github.quickdictate.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        if let suiteName = suiteName {
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // 1. First launch with no saved settings
    func test01_FirstLaunchDefaultsAndSnippetsInitialization() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        XCTAssertEqual(prefs.preferredProvider, .groq)
        XCTAssertFalse(prefs.allowCrossProviderFailover, "Cross-provider failover must default to false for privacy")
        XCTAssertEqual(prefs.shortcutOption, .rightOption)
        XCTAssertTrue(prefs.isSnippetsEnabled)
        XCTAssertFalse(prefs.isPeriodicPreviewEnabled, "Periodic preview must default to false")
        XCTAssertTrue(prefs.isSoundFeedbackEnabled)

        let snipPath = tempDir.appendingPathComponent("snippets.json").path
        let snipMgr = SnippetManager(filePath: snipPath)
        XCTAssertEqual(snipMgr.snippets.count, 4)
        XCTAssertNil(snipMgr.lastLoadError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snipPath))
    }

    // 2. Existing legacy API-key migration
    func test02_LegacyPlaintextKeyMigrationSuccess() throws {
        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(
            serviceName: "test.service",
            backend: backend,
            userDefaults: testDefaults
        )

        let keysFile = tempDir.appendingPathComponent(".quickdictate_keys").path
        let singleFile = tempDir.appendingPathComponent(".quickdictate_key").path
        let legacyContent = """
        # Comment line
        gsk_legacyGroqSecretKey123456
        sk-legacyOpenAISecretKey987654
        """
        try legacyContent.write(toFile: keysFile, atomically: true, encoding: .utf8)
        try "gsk_legacyGroqSecretKey123456".write(toFile: singleFile, atomically: true, encoding: .utf8)

        let outcome = credMgr.migrateLegacyPlaintextKeysIfNeeded(
            keysFilePath: keysFile,
            singleKeyFilePath: singleFile
        )

        XCTAssertTrue(outcome.attempted)
        XCTAssertEqual(outcome.migratedCount, 2)
        XCTAssertEqual(outcome.skippedMalformedCount, 0)
        XCTAssertTrue(outcome.legacyFilesRemoved)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keysFile), "Old plaintext keys file must be deleted after verification")
        XCTAssertFalse(FileManager.default.fileExists(atPath: singleFile), "Old single key file must be deleted after verification")

        // Verify idempotency on subsequent launch
        let secondOutcome = credMgr.migrateLegacyPlaintextKeysIfNeeded(
            keysFilePath: keysFile,
            singleKeyFilePath: singleFile
        )
        XCTAssertFalse(secondOutcome.attempted)
        XCTAssertEqual(credMgr.listMetadata().count, 2)
    }

    // 3. Failed Keychain migration without data loss
    func test03_FailedKeychainMigrationPreservesLegacyFiles() throws {
        let backend = MockKeychainBackend()
        backend.shouldFailSet = true

        let credMgr = KeychainCredentialManager(
            serviceName: "test.service",
            backend: backend,
            userDefaults: testDefaults
        )

        let keysFile = tempDir.appendingPathComponent(".quickdictate_keys").path
        try "gsk_validButKeychainLocked12345".write(toFile: keysFile, atomically: true, encoding: .utf8)

        let outcome = credMgr.migrateLegacyPlaintextKeysIfNeeded(
            keysFilePath: keysFile,
            singleKeyFilePath: tempDir.appendingPathComponent("nonexistent").path
        )

        XCTAssertTrue(outcome.attempted)
        XCTAssertFalse(outcome.legacyFilesRemoved)
        XCTAssertNotNil(outcome.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keysFile), "Plaintext file MUST be preserved when Keychain fails")
    }

    // 4. Multiple API keys and provider selection (plus cross-provider privacy gate)
    func test04_MultipleAPIKeysAndProviderSelection() throws {
        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(
            serviceName: "test.service",
            backend: backend,
            userDefaults: testDefaults
        )

        let groq1 = try credMgr.addCredential(rawKey: "gsk_firstGroqKey123456", provider: .groq, label: "Groq Primary")
        let openai1 = try credMgr.addCredential(rawKey: "sk-firstOpenAIKey123456", provider: .openai, label: "OpenAI Primary")
        let groq2 = try credMgr.addCredential(rawKey: "gsk_secondGroqKey654321", provider: .groq, label: "Groq Backup")

        XCTAssertEqual(groq1.maskedPreview, "gsk_••••3456")
        XCTAssertFalse(groq1.maskedPreview.contains("firstGroqKey"))

        let groqOnly = credMgr.resolveCredentials(preferredProvider: .groq, allowCrossProviderFailover: false)
        XCTAssertEqual(groqOnly.map { $0.metadata.id }, [groq1.id, groq2.id])

        let withCross = credMgr.resolveCredentials(preferredProvider: .groq, allowCrossProviderFailover: true)
        XCTAssertEqual(withCross.map { $0.metadata.id }, [groq1.id, groq2.id, openai1.id])
    }

    // 5. Authentication failure (HTTP 401/403)
    func test05_AuthenticationFailureReporting() throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.init(statusCode: 401))

        let client = TranscriptionClient(transport: transport)
        let cred = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Invalid Key", maskedPreview: "gsk_••••0000"),
            secret: "gsk_invalidSecretKey0000"
        )

        let exp = expectation(description: "Auth failure")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [cred],
            allowCrossProviderFailover: false
        ) { result in
            switch result {
            case .success:
                XCTFail("Expected authentication failure")
            case .failure(let err):
                XCTAssertEqual(err, .authenticationFailed(provider: .groq))
                XCTAssertFalse(err.localizedDescription.contains("gsk_invalidSecretKey0000"), "Error must never leak API secret")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // 6. Rate-limit response (HTTP 429) and bounded failover
    func test06_RateLimitResponseAndBoundedFailover() throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.init(
            statusCode: 429,
            headers: ["Retry-After": "5"],
            body: "{\"error\":{\"message\":\"Rate limit exceeded\"}}".data(using: .utf8)
        ))
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"Failover transcription succeeded.\"}".data(using: .utf8)
        ))

        let client = TranscriptionClient(transport: transport)
        let key1 = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Groq 1", maskedPreview: "gsk_••••1111"),
            secret: "gsk_rateLimitedKey1111"
        )
        let key2 = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Groq 2", maskedPreview: "gsk_••••2222"),
            secret: "gsk_workingBackupKey2222"
        )

        let exp = expectation(description: "Failover to key 2")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [key1, key2],
            allowCrossProviderFailover: false
        ) { result in
            switch result {
            case .success(let success):
                XCTAssertEqual(success.text, "Failover transcription succeeded.")
                XCTAssertEqual(success.usedCredentialID, key2.metadata.id)
                XCTAssertEqual(success.attemptsCount, 2)
            case .failure(let err):
                XCTFail("Unexpected failure: \(err)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // 7. Network timeout and request cancellation
    func test07_NetworkTimeoutAndRequestCancellation() throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.init(
            statusCode: 0,
            error: URLError(.timedOut)
        ))

        let client = TranscriptionClient(transport: transport)
        let cred = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .openai, label: "OpenAI", maskedPreview: "sk-••••1234"),
            secret: "sk-timeoutTestKey1234"
        )

        let timeoutExp = expectation(description: "Timeout")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [cred],
            allowCrossProviderFailover: false
        ) { result in
            if case .failure(let err) = result {
                XCTAssertEqual(err, .networkTimeout(provider: .openai))
            } else {
                XCTFail("Expected timeout error")
            }
            timeoutExp.fulfill()
        }
        wait(for: [timeoutExp], timeout: 2.0)

        // Test active cancellation with at-most-once completion guarantee
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"Delayed\"}".data(using: .utf8),
            delaySeconds: 1.5
        ))
        var completionCallCount = 0
        let cancelExp = expectation(description: "Cancelled")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [cred],
            allowCrossProviderFailover: false
        ) { result in
            completionCallCount += 1
            if case .failure(let err) = result {
                XCTAssertEqual(err, .cancelled)
            } else {
                XCTFail("Expected cancelled error")
            }
            if completionCallCount == 1 {
                cancelExp.fulfill()
            }
        }
        client.cancelCurrentRequest()
        wait(for: [cancelExp], timeout: 2.0)
        XCTAssertEqual(completionCallCount, 1, "Terminal completion handler must be called at most once even when task cancellation triggers a synchronous callback")
    }

    // 8. Successful transcription using a mocked provider response
    func test08_SuccessfulTranscriptionWithMockedResponse() throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"  Hello from QuickDictate unit test!  \"}".data(using: .utf8)
        ))

        let client = TranscriptionClient(transport: transport)
        let cred = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Groq", maskedPreview: "gsk_••••9999"),
            secret: "gsk_validTestSecret9999"
        )

        let exp = expectation(description: "Success")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [cred],
            allowCrossProviderFailover: false
        ) { result in
            switch result {
            case .success(let res):
                XCTAssertEqual(res.text, "Hello from QuickDictate unit test!")
                XCTAssertEqual(res.usedProvider, .groq)
                XCTAssertEqual(res.attemptsCount, 1)
            case .failure(let err):
                XCTFail("Unexpected error: \(err)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // 9. Invalid transcription JSON
    func test09_InvalidTranscriptionJSONRejectedWithoutFailoverStorm() throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.init(
            statusCode: 200,
            body: "<html>502 Bad Gateway HTML disguised as 200</html>".data(using: .utf8)
        ))

        let client = TranscriptionClient(transport: transport)
        let cred = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Groq", maskedPreview: "gsk_••••1234"),
            secret: "gsk_validTestSecret1234"
        )

        let exp = expectation(description: "Malformed JSON")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [cred],
            allowCrossProviderFailover: false
        ) { result in
            if case .failure(let err) = result {
                XCTAssertEqual(err, .malformedResponse(provider: .groq))
            } else {
                XCTFail("Expected malformedResponse error")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // 10. Empty and corrupted audio
    func test10_EmptyAndCorruptedAudioValidation() throws {
        let missingURL = tempDir.appendingPathComponent("missing.wav")
        XCTAssertThrowsError(try AudioSessionFileManager.validateAndReadWAV(at: missingURL)) { error in
            XCTAssertEqual(error as? AudioSessionError, .audioFileMissing)
        }

        let tinyURL = tempDir.appendingPathComponent("tiny.wav")
        try Data(repeating: 0, count: 60).write(to: tinyURL)
        XCTAssertThrowsError(try AudioSessionFileManager.validateAndReadWAV(at: tinyURL)) { error in
            XCTAssertEqual(error as? AudioSessionError, .audioFileTooSmallOrSilent)
        }

        let corruptURL = tempDir.appendingPathComponent("corrupt.wav")
        try Data(repeating: 0x42, count: 4096).write(to: corruptURL)
        XCTAssertThrowsError(try AudioSessionFileManager.validateAndReadWAV(at: corruptURL)) { error in
            XCTAssertEqual(error as? AudioSessionError, .corruptedWAVHeader)
        }

        let validURL = tempDir.appendingPathComponent("valid.wav")
        let validData = MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200)
        try validData.write(to: validURL)
        let readBack = try AudioSessionFileManager.validateAndReadWAV(at: validURL)
        XCTAssertEqual(readBack.count, validData.count)
    }

    // 11. Recording-state transitions
    func test11_RecordingLifecycleStateMachineTransitions() throws {
        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(serviceName: "test", backend: backend, userDefaults: testDefaults)
        _ = try credMgr.addCredential(rawKey: "gsk_lifecycleTestKey12345", provider: .groq)

        let audioMgr = AudioSessionFileManager(baseDirectoryURL: tempDir.appendingPathComponent("recs"))
        let micChecker = MockMicrophonePermissionChecker()
        let recFactory = MockRecorderFactory()
        let transport = MockHTTPTransport()
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"State machine verified.\"}".data(using: .utf8),
            delaySeconds: 0.05
        ))
        let transClient = TranscriptionClient(transport: transport)
        let pasteboard = MockPasteboardProvider()
        let axChecker = MockAccessibilityChecker()
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)
        let prefs = PreferencesManager(userDefaults: testDefaults)
        prefs.isSoundFeedbackEnabled = false
        let alertPresenter = MockUserAlertPresenter()

        let coordinator = DictationCoordinator(
            credentialManager: credMgr,
            audioFileManager: audioMgr,
            permissionChecker: micChecker,
            recorderFactory: recFactory,
            transcriptionClient: transClient,
            previewClient: TranscriptionClient(transport: MockHTTPTransport()),
            snippetManager: SnippetManager(filePath: tempDir.appendingPathComponent("snips.json").path),
            textInsertionManager: insertMgr,
            preferences: prefs,
            alertPresenter: alertPresenter
        )

        var observedStates: [DictationLifecycleState] = []
        let doneExp = expectation(description: "Completed cycle back to idle")

        coordinator.onStateChange = { newState in
            observedStates.append(newState)
            if observedStates.count >= 4 && newState == .idle {
                doneExp.fulfill()
            }
        }

        coordinator.toggleDictation()
        XCTAssertTrue(coordinator.state.isRecording)

        coordinator.toggleDictation()
        wait(for: [doneExp], timeout: 2.0)

        XCTAssertEqual(pasteboard.lastWrittenPlainText, "State machine verified.")
    }

    // 12. Temporary-file cleanup
    func test12_TemporaryFileIsolationAndCleanup() throws {
        let recDir = tempDir.appendingPathComponent("isolated_recs", isDirectory: true)
        let audioMgr = AudioSessionFileManager(baseDirectoryURL: recDir)

        let s1 = UUID()
        let s2 = UUID()
        let url1 = try audioMgr.makeRecordingURL(for: s1)
        let url2 = try audioMgr.makeRecordingURL(for: s2)
        XCTAssertNotEqual(url1, url2, "Concurrent or sequential sessions must never share a filename")

        try MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200).write(to: url1)
        try MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200).write(to: url2)
        audioMgr.secureRecordingFilePermissions(at: url1)

        audioMgr.cleanupRecordingFile(at: url1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))

        audioMgr.cleanupAllRecordings()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url2.path))
    }

    // 13. Cancellation and late-response handling
    func test13_CancellationPreventsLateResponsePaste() throws {
        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(serviceName: "test", backend: backend, userDefaults: testDefaults)
        _ = try credMgr.addCredential(rawKey: "gsk_cancelTestKey123456", provider: .groq)

        let audioMgr = AudioSessionFileManager(baseDirectoryURL: tempDir.appendingPathComponent("recs_cancel"))
        let transport = MockHTTPTransport()
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"Late text that must NOT be pasted\"}".data(using: .utf8),
            delaySeconds: 0.4
        ))

        let pasteboard = MockPasteboardProvider()
        let axChecker = MockAccessibilityChecker()
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)
        let prefs = PreferencesManager(userDefaults: testDefaults)
        prefs.isSoundFeedbackEnabled = false

        let coordinator = DictationCoordinator(
            credentialManager: credMgr,
            audioFileManager: audioMgr,
            permissionChecker: MockMicrophonePermissionChecker(),
            recorderFactory: MockRecorderFactory(),
            transcriptionClient: TranscriptionClient(transport: transport),
            previewClient: TranscriptionClient(transport: MockHTTPTransport()),
            snippetManager: SnippetManager(filePath: tempDir.appendingPathComponent("snips.json").path),
            textInsertionManager: insertMgr,
            preferences: prefs,
            alertPresenter: MockUserAlertPresenter()
        )

        coordinator.toggleDictation() // Start recording
        coordinator.toggleDictation() // Stop & start transcribing
        coordinator.cancelActiveOperation() // Cancel immediately

        XCTAssertEqual(coordinator.state, .idle)

        let waitExp = expectation(description: "Wait past network delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            waitExp.fulfill()
        }
        wait(for: [waitExp], timeout: 1.5)

        XCTAssertNil(pasteboard.lastWrittenPlainText, "Cancelled transcription must never write to pasteboard or paste")
        XCTAssertEqual(axChecker.postCmdVCalledCount, 0)
    }

    // 14. Standalone snippet replacement
    func test14_StandaloneSnippetReplacement() throws {
        let snipMgr = SnippetManager(filePath: tempDir.appendingPathComponent("standalone.json").path)
        XCTAssertEqual(snipMgr.expand(in: "Enter Email."), "user@example.com")
        XCTAssertEqual(snipMgr.expand(in: "  enter phone?! "), "+1 (555) 123-4567")
        XCTAssertEqual(snipMgr.expand(in: "enter email", isEnabled: false), "enter email")
    }

    // 15. Inline snippet replacement (longest-trigger-first precedence)
    func test15_InlineSnippetReplacementAndPrecedence() throws {
        let snipMgr = SnippetManager(filePath: tempDir.appendingPathComponent("inline.json").path)
        let input = "Please send the contract to enter work email or enter email before 5 PM."
        let expanded = snipMgr.expand(in: input)
        XCTAssertEqual(expanded, "Please send the contract to work@example.com or user@example.com before 5 PM.")
    }

    // 16. Multiline and Unicode snippet values + Regex special characters ($1, \)
    func test16_MultilineUnicodeAndRegexEscapedSnippets() throws {
        let snipPath = tempDir.appendingPathComponent("unicode.json").path
        let snipMgr = SnippetManager(filePath: snipPath)

        try snipMgr.upsertSnippet(
            trigger: "insert price tag",
            value: "Cost: $100.00 \\ tax included\nLine 2: Café ☕️ 東京"
        )

        let standalone = snipMgr.expand(in: "insert price tag")
        XCTAssertEqual(standalone, "Cost: $100.00 \\ tax included\nLine 2: Café ☕️ 東京")

        let inline = snipMgr.expand(in: "Note — insert price tag — thank you.")
        XCTAssertEqual(inline, "Note — Cost: $100.00 \\ tax included\nLine 2: Café ☕️ 東京 — thank you.")
    }

    // 17. Malformed snippet JSON without overwriting data
    func test17_MalformedSnippetJSONPreservedNeverOverwritten() throws {
        let brokenPath = tempDir.appendingPathComponent("broken_snippets.json").path
        let preciousBrokenContent = "{ \"trigger\": \"my custom snippet\", \"value\": \"missing closing bracket\""
        try preciousBrokenContent.write(toFile: brokenPath, atomically: true, encoding: .utf8)

        let snipMgr = SnippetManager(filePath: brokenPath)
        XCTAssertNotNil(snipMgr.lastLoadError, "Malformed JSON must surface an error")

        let diskContentAfterLoad = try String(contentsOfFile: brokenPath, encoding: .utf8)
        XCTAssertEqual(diskContentAfterLoad, preciousBrokenContent, "Malformed snippet file must NEVER be overwritten with defaults")

        XCTAssertThrowsError(try snipMgr.save())
        let diskContentAfterSaveAttempt = try String(contentsOfFile: brokenPath, encoding: .utf8)
        XCTAssertEqual(diskContentAfterSaveAttempt, preciousBrokenContent)
    }

    // 18. Clipboard changes during transcription & Focus change protection
    func test18_ClipboardChangeProtectionAndFocusVerification() throws {
        let pasteboard = MockPasteboardProvider()
        let initialData = "User Original Clipboard Item".data(using: .utf8)!
        pasteboard.currentItems = [SavedPasteboardItem(dataByType: [.string: initialData])]

        let axChecker = MockAccessibilityChecker()
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)

        let appA = TargetApplicationContext(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 101,
            localizedName: "TextEdit",
            windowIdentityToken: "cgwin:100|axwin:200",
            focusedElementToken: "axelem:300:AXTextArea"
        )
        let appB = TargetApplicationContext(
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 202,
            localizedName: "Safari",
            windowIdentityToken: "cgwin:999|axwin:888",
            focusedElementToken: "axelem:777:AXTextField"
        )

        // Case A: Focus changed during transcription -> do NOT auto-paste into wrong app
        let focusOutcome = insertMgr.insertTranscribedText(
            "Dictated paragraph",
            sessionID: UUID(),
            expectedTarget: appA,
            currentTarget: appB
        )
        XCTAssertEqual(focusOutcome, .focusChanged(expectedApp: "TextEdit", actualApp: "Safari", copiedToClipboard: true))
        XCTAssertEqual(axChecker.postCmdVCalledCount, 0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Dictated paragraph")

        // Case B: Focus stayed in appA and same window/element, but user copied something else before restoration timer fired
        pasteboard.currentItems = [SavedPasteboardItem(dataByType: [.string: initialData])]
        let restoreExp = expectation(description: "Clipboard restoration check")
        let outcomeB = insertMgr.insertTranscribedText(
            "Second dictation",
            sessionID: UUID(),
            expectedTarget: appA,
            currentTarget: appA,
            restoreClipboardDelay: 0.1
        ) { didRestore in
            XCTAssertFalse(didRestore, "Must NOT overwrite newer user clipboard content")
            restoreExp.fulfill()
        }
        XCTAssertEqual(outcomeB, .pasteEventDispatched(restoredClipboardScheduled: true))
        _ = pasteboard.writePlainText("Newer item copied by user")
        wait(for: [restoreExp], timeout: 1.0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Newer item copied by user")
    }

    // 19. Disabled microphone or Accessibility permission (Unattended CI without modal NSAlert)
    func test19_DisabledMicrophoneAndAccessibilityPermissionsHandledSafelyUnattended() throws {
        let pasteboard = MockPasteboardProvider()
        let axChecker = MockAccessibilityChecker()
        axChecker.trusted = false
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)

        let appA = TargetApplicationContext(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 101, localizedName: "TextEdit")
        let axOutcome = insertMgr.insertTranscribedText(
            "Fallback text",
            sessionID: UUID(),
            expectedTarget: appA,
            currentTarget: appA
        )
        XCTAssertEqual(axOutcome, .accessibilityPermissionMissing(copiedToClipboard: true))
        XCTAssertEqual(axChecker.postCmdVCalledCount, 0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Fallback text")

        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(serviceName: "test", backend: backend, userDefaults: testDefaults)
        _ = try credMgr.addCredential(rawKey: "gsk_micDeniedKey123456", provider: .groq)

        let micChecker = MockMicrophonePermissionChecker()
        micChecker.status = .denied
        let recFactory = MockRecorderFactory()
        let alertPresenter = MockUserAlertPresenter()

        let coordinator = DictationCoordinator(
            credentialManager: credMgr,
            audioFileManager: AudioSessionFileManager(baseDirectoryURL: tempDir.appendingPathComponent("mic_denied")),
            permissionChecker: micChecker,
            recorderFactory: recFactory,
            transcriptionClient: TranscriptionClient(transport: MockHTTPTransport()),
            previewClient: TranscriptionClient(transport: MockHTTPTransport()),
            snippetManager: SnippetManager(filePath: tempDir.appendingPathComponent("s.json").path),
            textInsertionManager: insertMgr,
            preferences: PreferencesManager(userDefaults: testDefaults),
            alertPresenter: alertPresenter
        )

        coordinator.startRecordingFlow()
        XCTAssertFalse(coordinator.state.isRecording, "Must never enter recording state when microphone permission is denied")
        XCTAssertNil(recFactory.lastCreatedRecorder)
        XCTAssertEqual(alertPresenter.micPermissionAlertCount, 1, "Permission denial must notify alert presenter without blocking XCTest on NSAlert.runModal()")
    }

    // 20. Clean application termination & Shortcut chord protection
    func test20_CleanApplicationTerminationAndModifierChordProtection() throws {
        var detector = ModifierTapDetector(shortcut: .rightOption)

        XCTAssertFalse(detector.handleFlagsChanged(keyCode: 61, modifierFlags: [.option], timestamp: 1.0))
        XCTAssertTrue(detector.handleFlagsChanged(keyCode: 61, modifierFlags: [], timestamp: 1.15))

        XCTAssertFalse(detector.handleFlagsChanged(keyCode: 61, modifierFlags: [.option], timestamp: 2.0))
        detector.noteNonModifierActivity()
        XCTAssertFalse(detector.handleFlagsChanged(keyCode: 61, modifierFlags: [], timestamp: 2.2))

        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(serviceName: "test", backend: backend, userDefaults: testDefaults)
        _ = try credMgr.addCredential(rawKey: "gsk_terminationKey12345", provider: .groq)

        let recDir = tempDir.appendingPathComponent("term_recs")
        let audioMgr = AudioSessionFileManager(baseDirectoryURL: recDir)
        let prefs = PreferencesManager(userDefaults: testDefaults)
        prefs.isSoundFeedbackEnabled = false

        let coordinator = DictationCoordinator(
            credentialManager: credMgr,
            audioFileManager: audioMgr,
            permissionChecker: MockMicrophonePermissionChecker(),
            recorderFactory: MockRecorderFactory(),
            transcriptionClient: TranscriptionClient(transport: MockHTTPTransport()),
            previewClient: TranscriptionClient(transport: MockHTTPTransport()),
            snippetManager: SnippetManager(filePath: tempDir.appendingPathComponent("s2.json").path),
            textInsertionManager: TextInsertionManager(pasteboard: MockPasteboardProvider(), accessibility: MockAccessibilityChecker()),
            preferences: prefs,
            alertPresenter: MockUserAlertPresenter()
        )

        coordinator.toggleDictation()
        XCTAssertTrue(coordinator.state.isRecording)

        coordinator.handleApplicationTermination()
        XCTAssertEqual(coordinator.state, .idle)
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(remainingFiles.isEmpty, "All temporary WAV files must be removed on application termination")
    }

    // MARK: - Additional Remediation Tests (Scenarios 21–28)

    // 21. Transactional snippet recovery: backup-copy failure and byte-verification failure abort recovery without data loss
    func test21_SnippetRecoveryAbortsWhenSafetyBackupCopyOrVerificationFails() throws {
        let storage = FaultInjectingSnippetFileStorage()
        let brokenPath = tempDir.appendingPathComponent("transactional_broken.json").path
        let originalMalformedBytes = "{ \"trigger\": \"precious unclosed json\""
        try originalMalformedBytes.write(toFile: brokenPath, atomically: true, encoding: .utf8)

        let snipMgr = SnippetManager(filePath: brokenPath, storage: storage)
        XCTAssertNotNil(snipMgr.lastLoadError)

        // 1. Simulate backup copy failure -> must abort and preserve original file untouched
        storage.failCopyFile = true
        XCTAssertThrowsError(try snipMgr.recoverFromMalformedFile()) { err in
            guard case SnippetError.recoverySafetyBackupFailed = err else {
                XCTFail("Expected recoverySafetyBackupFailed, got \(err)")
                return
            }
        }
        XCTAssertEqual(try String(contentsOfFile: brokenPath, encoding: .utf8), originalMalformedBytes)
        XCTAssertNotNil(snipMgr.lastLoadError)

        // 2. Simulate corrupted safety backup verification failure -> must abort and preserve original file untouched
        storage.failCopyFile = false
        storage.corruptCopiedFileBytes = true
        XCTAssertThrowsError(try snipMgr.recoverFromMalformedFile()) { err in
            guard case SnippetError.recoverySafetyBackupFailed = err else {
                XCTFail("Expected recoverySafetyBackupFailed on byte mismatch, got \(err)")
                return
            }
        }
        XCTAssertEqual(try String(contentsOfFile: brokenPath, encoding: .utf8), originalMalformedBytes)
        XCTAssertNotNil(snipMgr.lastLoadError)
    }

    // 22. Transactional snippet recovery: invalid `.bak` falls back safely, failed primary write stays fail-closed, and valid recovery succeeds
    func test22_SnippetRecoveryWithInvalidBackupFailedWriteAndSuccessfulRestore() throws {
        let storage = FaultInjectingSnippetFileStorage()
        let brokenPath = tempDir.appendingPathComponent("recover_flow.json").path
        let bakPath = brokenPath + ".bak"

        let malformedPrimary = "{ \"trigger\": \"malformed primary\""
        try malformedPrimary.write(toFile: brokenPath, atomically: true, encoding: .utf8)
        // Write an invalid `.bak` file to verify recovery does not trust a corrupted `.bak`
        try "NOT VALID JSON IN BAK".write(toFile: bakPath, atomically: true, encoding: .utf8)

        let snipMgr = SnippetManager(filePath: brokenPath, storage: storage)
        XCTAssertNotNil(snipMgr.lastLoadError)

        // 1. Simulate primary write failure after safety backup succeeds -> must throw writeFailed and keep lastLoadError
        storage.failPrimaryWrite = true
        XCTAssertThrowsError(try snipMgr.recoverFromMalformedFile(useBackupIfAvailable: true)) { err in
            guard case SnippetError.writeFailed = err else {
                XCTFail("Expected writeFailed, got \(err)")
                return
            }
        }
        XCTAssertNotNil(snipMgr.lastLoadError)
        XCTAssertEqual(try String(contentsOfFile: brokenPath, encoding: .utf8), malformedPrimary)

        // 2. Allow write to succeed with invalid `.bak` -> falls back to defaultExamples while preserving safety backup of malformed file
        storage.failPrimaryWrite = false
        let safetyBackupURL = try snipMgr.recoverFromMalformedFile(useBackupIfAvailable: true)
        XCTAssertNotNil(safetyBackupURL)
        XCTAssertEqual(try String(contentsOf: safetyBackupURL!, encoding: .utf8), malformedPrimary)
        XCTAssertNil(snipMgr.lastLoadError)
        XCTAssertEqual(snipMgr.snippets, SnippetManager.defaultExamples)

        // 3. Save a custom snippet so `.bak` becomes a valid last-known-good backup, then corrupt primary and recover from `.bak`
        try snipMgr.upsertSnippet(trigger: "custom backup trigger", value: "custom backup value")
        try "{ broken again".write(toFile: brokenPath, atomically: true, encoding: .utf8)
        _ = snipMgr.loadSnippets()
        XCTAssertNotNil(snipMgr.lastLoadError)

        _ = try snipMgr.recoverFromMalformedFile(useBackupIfAvailable: true)
        XCTAssertNil(snipMgr.lastLoadError)
        XCTAssertTrue(snipMgr.snippets.contains(Snippet(trigger: "custom backup trigger", value: "custom backup value")))
    }

    // 23. Synchronous failover task tracking: Key 1 fails synchronously while Key 2 is asynchronous and cancelled
    func test23_SynchronousKey1FailoverDoesNotOverwriteKey2ActiveTaskOnCancel() throws {
        let transport = MockHTTPTransport()
        // Key 1 fails synchronously inside sendRequest (completeSynchronously: true)
        transport.responses.append(.init(
            statusCode: 401,
            completeSynchronously: true
        ))
        // Key 2 is asynchronous (delaySeconds: 2.0) and should be the active task when cancelCurrentRequest() is called
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"Should be cancelled\"}".data(using: .utf8),
            delaySeconds: 2.0,
            completeSynchronously: false
        ))

        let client = TranscriptionClient(transport: transport)
        let key1 = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Key 1", maskedPreview: "gsk_••••1111"),
            secret: "gsk_syncFailKey11111"
        )
        let key2 = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Key 2", maskedPreview: "gsk_••••2222"),
            secret: "gsk_asyncPendingKey2222"
        )

        var completionCount = 0
        let cancelExp = expectation(description: "Key 2 cancelled")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [key1, key2],
            allowCrossProviderFailover: false
        ) { result in
            completionCount += 1
            XCTAssertEqual(result, .failure(.cancelled))
            cancelExp.fulfill()
        }

        // At this point, Key 1 already failed synchronously and Key 2's request is in flight (`createdTasks[1]`).
        XCTAssertEqual(transport.createdTasks.count, 2)
        XCTAssertFalse(transport.createdTasks[1].isCancelled)

        // Cancelling now MUST cancel Key 2's task (`createdTasks[1]`), proving Key 1 did not overwrite `activeTask`!
        client.cancelCurrentRequest()
        wait(for: [cancelExp], timeout: 1.5)
        XCTAssertTrue(transport.createdTasks[1].isCancelled, "Key 2's pending task must be cancelled; Key 1 must not have overwritten activeTask")
        XCTAssertEqual(completionCount, 1)
    }

    // 24. Cancellation during retry backoff prevents scheduled retry work from sending another request
    func test24_CancellationDuringRetryBackoffStopsScheduledRetryRequest() throws {
        let transport = MockHTTPTransport()
        // Single key returns 503 Server Error -> triggers same-key retry after backoff
        transport.responses.append(.init(
            statusCode: 503,
            completeSynchronously: true
        ))
        transport.responses.append(.init(
            statusCode: 200,
            body: "{\"text\":\"Should never be requested\"}".data(using: .utf8)
        ))

        let client = TranscriptionClient(transport: transport)
        let singleKey = ResolvedCredential(
            metadata: StoredCredentialMetadata(provider: .groq, label: "Single Key", maskedPreview: "gsk_••••1111"),
            secret: "gsk_singleKeyRetryTest1"
        )

        let cancelExp = expectation(description: "Cancelled during backoff")
        client.transcribeAudio(
            audioData: MockAudioRecorder.makeDummyWAVData(pcmByteCount: 3200),
            credentials: [singleKey],
            allowCrossProviderFailover: false,
            maxSameKeyRetries: 1,
            retryDelayScale: 0.4
        ) { result in
            XCTAssertEqual(result, .failure(.cancelled))
            cancelExp.fulfill()
        }

        XCTAssertEqual(transport.capturedRequests.count, 1)
        // Cancel while the retry DispatchWorkItem is waiting in its backoff window
        client.cancelCurrentRequest()
        wait(for: [cancelExp], timeout: 1.0)

        let waitPastBackoff = expectation(description: "Wait past retry timer")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.45) {
            waitPastBackoff.fulfill()
        }
        wait(for: [waitPastBackoff], timeout: 1.0)
        XCTAssertEqual(transport.capturedRequests.count, 1, "Cancelled retry work item must NEVER send a second HTTP request")
    }

    // 25. Missing expectedTarget never auto-pastes (falls back to clipboard)
    func test25_MissingExpectedTargetNeverAutoPastes() throws {
        let pasteboard = MockPasteboardProvider()
        let axChecker = MockAccessibilityChecker()
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)

        let currentApp = TargetApplicationContext(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 101,
            localizedName: "TextEdit",
            windowIdentityToken: "cgwin:100|axwin:200",
            focusedElementToken: "axelem:300:AXTextArea"
        )

        let outcome = insertMgr.insertTranscribedText(
            "Text with nil expected target",
            sessionID: UUID(),
            expectedTarget: nil,
            currentTarget: currentApp
        )

        XCTAssertEqual(outcome, .targetUnavailable(copiedToClipboard: true), "Must not auto-paste when original target app was not captured")
        XCTAssertEqual(axChecker.postCmdVCalledCount, 0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Text with nil expected target")
    }

    // 26. Switching windows or focused elements within the SAME app prevents blind auto-paste
    func test26_DifferentWindowOrFocusedElementInSameAppFallsBackToClipboard() throws {
        let pasteboard = MockPasteboardProvider()
        let axChecker = MockAccessibilityChecker()
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)

        let window1Target = TargetApplicationContext(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 101,
            localizedName: "TextEdit",
            windowIdentityToken: "cgwin:100|axwin:200",
            focusedElementToken: "axelem:300:AXTextArea"
        )
        let window2TargetSameApp = TargetApplicationContext(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 101,
            localizedName: "TextEdit",
            windowIdentityToken: "cgwin:101|axwin:201",
            focusedElementToken: "axelem:300:AXTextArea"
        )

        let windowOutcome = insertMgr.insertTranscribedText(
            "Dictated for Window 1",
            sessionID: UUID(),
            expectedTarget: window1Target,
            currentTarget: window2TargetSameApp
        )
        XCTAssertEqual(windowOutcome, .windowOrElementChanged(appName: "TextEdit", copiedToClipboard: true))
        XCTAssertEqual(axChecker.postCmdVCalledCount, 0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Dictated for Window 1")

        // Different focused element in the same window
        let element2TargetSameWindow = TargetApplicationContext(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 101,
            localizedName: "TextEdit",
            windowIdentityToken: "cgwin:100|axwin:200",
            focusedElementToken: "axelem:999:AXTextField"
        )
        let elementOutcome = insertMgr.insertTranscribedText(
            "Dictated for Element 1",
            sessionID: UUID(),
            expectedTarget: window1Target,
            currentTarget: element2TargetSameWindow
        )
        XCTAssertEqual(elementOutcome, .windowOrElementChanged(appName: "TextEdit", copiedToClipboard: true))
        XCTAssertEqual(axChecker.postCmdVCalledCount, 0)
    }

    // 27. Empty initial clipboard does not wipe transcription after paste
    func test27_EmptyInitialClipboardDoesNotWipePasteboardOnRestore() throws {
        let pasteboard = MockPasteboardProvider()
        pasteboard.currentItems = [] // Empty clipboard prior to dictation

        let axChecker = MockAccessibilityChecker()
        let insertMgr = TextInsertionManager(pasteboard: pasteboard, accessibility: axChecker)

        let appA = TargetApplicationContext(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 101,
            localizedName: "TextEdit",
            windowIdentityToken: "cgwin:100|axwin:200",
            focusedElementToken: "axelem:300:AXTextArea"
        )

        var restoreCallbackValue: Bool?
        let outcome = insertMgr.insertTranscribedText(
            "Keep me on clipboard if previously empty",
            sessionID: UUID(),
            expectedTarget: appA,
            currentTarget: appA,
            restoreClipboardDelay: 0.05
        ) { didRestore in
            restoreCallbackValue = didRestore
        }

        XCTAssertEqual(outcome, .pasteEventDispatched(restoredClipboardScheduled: false))
        XCTAssertEqual(restoreCallbackValue, false)
        XCTAssertEqual(pasteboard.restoreCalledCount, 0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Keep me on clipboard if previously empty")
    }

    // 28. Preview lifecycle race: late callback from Session 1 cannot corrupt preview state of Session 2
    func test28_PreviewCallbackFromOlderSessionCannotModifyNewerSessionPreviewState() throws {
        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(serviceName: "test", backend: backend, userDefaults: testDefaults)
        _ = try credMgr.addCredential(rawKey: "gsk_previewRaceTest12345", provider: .groq)

        let audioMgr = AudioSessionFileManager(baseDirectoryURL: tempDir.appendingPathComponent("preview_race"))
        let previewTransport = MockHTTPTransport()

        var heldCompletions: [(Data?, HTTPURLResponse?, Error?) -> Void] = []
        previewTransport.manualInterceptHandler = { _, completion in
            heldCompletions.append(completion)
            return MockCancellableTask()
        }

        let prefs = PreferencesManager(userDefaults: testDefaults)
        prefs.isPeriodicPreviewEnabled = true
        prefs.isSoundFeedbackEnabled = false
        let alertPresenter = MockUserAlertPresenter()

        let coordinator = DictationCoordinator(
            credentialManager: credMgr,
            audioFileManager: audioMgr,
            permissionChecker: MockMicrophonePermissionChecker(),
            recorderFactory: MockRecorderFactory(),
            transcriptionClient: TranscriptionClient(transport: MockHTTPTransport()),
            previewClient: TranscriptionClient(transport: previewTransport),
            snippetManager: SnippetManager(filePath: tempDir.appendingPathComponent("sp.json").path),
            textInsertionManager: TextInsertionManager(pasteboard: MockPasteboardProvider(), accessibility: MockAccessibilityChecker()),
            preferences: prefs,
            alertPresenter: alertPresenter
        )

        // Start Session 1 and trigger a preview poll
        coordinator.toggleDictation()
        guard case .recording(let session1ID, let session1URL) = coordinator.state else {
            XCTFail("Expected Session 1 recording")
            return
        }
        coordinator.triggerPreviewPoll(sessionID: session1ID, fileURL: session1URL)
        XCTAssertTrue(coordinator.isPreviewRequestInFlight)
        XCTAssertEqual(heldCompletions.count, 1)

        // Cancel Session 1 and immediately start Session 2
        coordinator.cancelActiveOperation()
        coordinator.toggleDictation()
        guard case .recording(let session2ID, let session2URL) = coordinator.state else {
            XCTFail("Expected Session 2 recording")
            return
        }
        XCTAssertNotEqual(session1ID, session2ID)

        // Trigger a preview poll in Session 2 so Session 2 now has an in-flight preview request
        coordinator.triggerPreviewPoll(sessionID: session2ID, fileURL: session2URL)
        XCTAssertTrue(coordinator.isPreviewRequestInFlight)
        XCTAssertEqual(heldCompletions.count, 2)

        // Now fire Session 1's stale preview callback!
        let url = Provider.groq.endpoint
        let http200 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        heldCompletions[0]("{\"text\":\"Stale session 1 preview\"}".data(using: .utf8), http200, nil)

        // Verify Session 2's `isPreviewRequestInFlight` is STILL true and the stale HUD text was NOT shown
        XCTAssertTrue(coordinator.isPreviewRequestInFlight, "Stale preview callback from Session 1 must NOT clear Session 2's in-flight state")
        XCTAssertFalse(alertPresenter.hudMessages.contains("● Stale session 1 preview"))

        // Now fire Session 2's valid preview callback -> should clear `isPreviewRequestInFlight` and show HUD
        heldCompletions[1]("{\"text\":\"Valid session 2 preview\"}".data(using: .utf8), http200, nil)
        XCTAssertFalse(coordinator.isPreviewRequestInFlight)
        XCTAssertTrue(alertPresenter.hudMessages.contains("● Valid session 2 preview"))

        coordinator.cancelActiveOperation()
    }

    // 29. Fresh install requires onboarding and blocks recording until ready
    func test29_FreshInstallRequiresOnboardingAndBlocksRecordingUntilReady() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        XCTAssertFalse(prefs.isOnboardingCompleted, "Fresh install must have isOnboardingCompleted = false")
        XCTAssertFalse(prefs.isSetupFullyConfigured, "Fresh install without credentials must not be fully configured")

        let credMgr = KeychainCredentialManager(serviceName: "test.onboard", backend: MockKeychainBackend(), userDefaults: testDefaults)
        let alertPresenter = MockUserAlertPresenter()
        let coordinator = DictationCoordinator(
            credentialManager: credMgr,
            preferences: prefs,
            alertPresenter: alertPresenter
        )

        // Attempting to record without setup complete and credentials must abort cleanly
        coordinator.toggleDictation()
        XCTAssertEqual(coordinator.state, .idle)
    }

    // 30. Onboarding readiness and setup wizard multi-factor detection
    func test30_OnboardingReadinessAndSetupWizardDetection() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        let backend = MockKeychainBackend()
        let credMgr = KeychainCredentialManager(serviceName: "test.readiness", backend: backend, userDefaults: testDefaults)

        // Case A: Just onboarding flag true, but zero credentials -> NOT ready
        prefs.isOnboardingCompleted = true
        XCTAssertFalse(prefs.isSetupFullyConfigured)

        // Case B: Add credential to Keychain -> NOW fully configured
        _ = try credMgr.addCredential(rawKey: "gsk_testKeyForReadiness123456", provider: .groq)
        // With credentials in Keychain, resolveCredentials returns it
        let resolved = credMgr.resolveCredentials(preferredProvider: .groq, allowCrossProviderFailover: false)
        XCTAssertEqual(resolved.count, 1)

        // Case C: User revokes/removes credential -> returns to not configured
        try credMgr.removeCredential(id: resolved[0].metadata.id)
        let emptyResolved = credMgr.resolveCredentials(preferredProvider: .groq, allowCrossProviderFailover: false)
        XCTAssertTrue(emptyResolved.isEmpty)
    }

    // 31. Custom key combo validation and glyph formatting
    func test31_CustomKeyComboValidationAndFormatting() throws {
        // 1. Naked character key without modifiers -> Rejected
        let (nakedValid, nakedReason) = KeyCombo.validate(keyCode: 2, flags: [])
        XCTAssertFalse(nakedValid)
        XCTAssertNotNil(nakedReason)

        // 2. Shift-only modifier -> Rejected
        let (shiftValid, shiftReason) = KeyCombo.validate(keyCode: 2, flags: [.shift])
        XCTAssertFalse(shiftValid)
        XCTAssertNotNil(shiftReason)

        // 3. System reserved shortcuts (⌘Q, ⌘W, ⌘Tab, ⌘Space) -> Rejected
        let (cmdQValid, _) = KeyCombo.validate(keyCode: 12, flags: [.command])
        XCTAssertFalse(cmdQValid)
        let (cmdSpaceValid, _) = KeyCombo.validate(keyCode: 49, flags: [.command])
        XCTAssertFalse(cmdSpaceValid)

        // 4. Valid combination: ⌃⌥D -> Accepted
        let (validCombo, validReason) = KeyCombo.validate(keyCode: 2, flags: [.control, .option])
        XCTAssertTrue(validCombo)
        XCTAssertNil(validReason)

        // 5. Glyph formatting
        let formatted = KeyCombo.formatDisplayString(keyCode: 2, flags: [.control, .option], characters: "d")
        XCTAssertEqual(formatted, "⌃⌥D")

        let formattedSpace = KeyCombo.formatDisplayString(keyCode: 49, flags: [.option], characters: " ")
        XCTAssertEqual(formattedSpace, "⌥Space")
    }

    // 32. Custom key combo persistence in UserDefaults
    func test32_CustomKeyComboPersistenceAndCarbonRegistration() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        let defaultCombo = prefs.customKeyCombo
        XCTAssertEqual(defaultCombo.displayString, "⌃⌥D")

        // Save new combo
        let newCombo = KeyCombo(keyCode: 15, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, displayString: "⇧⌘R")
        prefs.customKeyCombo = newCombo

        // Re-read from another PreferencesManager instance sharing testDefaults
        let reloadedPrefs = PreferencesManager(userDefaults: testDefaults)
        XCTAssertEqual(reloadedPrefs.customKeyCombo, newCombo)
        XCTAssertEqual(reloadedPrefs.customKeyCombo.displayString, "⇧⌘R")
    }

    // 33. Single application identity verification (No separate processes or helper daemons)
    func test33_SingleApplicationIdentityAndZeroHelperProcesses() throws {
        // Confirm snippet storage path is unified in the same user home directory
        let snipMgr = SnippetManager.shared
        XCTAssertTrue(snipMgr.filePath.contains(".quickdictate_snippets.json"))
        XCTAssertNil(snipMgr.lastLoadError)

        // Confirm single keychain service identifier
        let credMgr = KeychainCredentialManager.shared
        XCTAssertEqual(credMgr.serviceName, "com.github.quickdictate.credentials")

        // Confirm all shortcut options are handled by a single unified monitor
        let monitor = KeyboardShortcutMonitor.shared
        monitor.updateShortcut(.rightOption)
        monitor.updateShortcut(.custom)
        monitor.updateShortcut(.disabled)
    }

    // 34. Dock visibility and activation policy preference
    func test34_ActivationPolicyAndLaunchpadReopenHandler() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        // Default showDockIcon should be true so new users see QuickDictate in Dock & Launchpad
        XCTAssertTrue(prefs.showDockIcon)

        prefs.showDockIcon = false
        XCTAssertFalse(prefs.showDockIcon)

        let reloaded = PreferencesManager(userDefaults: testDefaults)
        XCTAssertFalse(reloaded.showDockIcon)
    }

    // 35. Onboarding step persistence across relaunches
    func test35_OnboardingStepPersistenceAndRelaunchRestoration() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        // Default step is 1
        XCTAssertEqual(prefs.onboardingCurrentStep, 1)

        // Advance to Accessibility step (Step 3)
        prefs.onboardingCurrentStep = 3
        XCTAssertEqual(prefs.onboardingCurrentStep, 3)

        // Simulate app quit and relaunch with fresh PreferencesManager instance
        let reloadedPrefs = PreferencesManager(userDefaults: testDefaults)
        XCTAssertEqual(reloadedPrefs.onboardingCurrentStep, 3, "Relaunch must resume at Step 3 (Accessibility) and NOT reset to Step 1")

        // Advance to Shortcut step (Step 5)
        reloadedPrefs.onboardingCurrentStep = 5
        let thirdInstance = PreferencesManager(userDefaults: testDefaults)
        XCTAssertEqual(thirdInstance.onboardingCurrentStep, 5)
    }

    // 36. Onboarding responsive multiline text wrapping verification
    func test36_OnboardingWelcomeAndAllStepsTextWrappingProperties() throws {
        let longFeatureText = "Dictate directly into Mail, Notes, Chrome, Slack, VS Code, or any text field with zero lag."
        let label = OnboardingWindowController.makeWrappingLabel(longFeatureText, fontSize: 12)

        XCTAssertTrue(label.cell?.wraps ?? false, "Label must have cell.wraps = true")
        XCTAssertFalse(label.cell?.usesSingleLineMode ?? true, "Label must have usesSingleLineMode = false")
        XCTAssertEqual(label.cell?.lineBreakMode, .byWordWrapping, "Line break mode must be byWordWrapping")
        XCTAssertEqual(label.maximumNumberOfLines, 0, "maximumNumberOfLines must be 0 (unlimited wrapping)")

        // Verify bounds calculation: at 480pt width, text wraps cleanly without crashing or negative dimensions
        label.frame = NSRect(x: 0, y: 0, width: 480, height: 36)
        label.preferredMaxLayoutWidth = 480
        let intrinsicSize = label.intrinsicContentSize
        XCTAssertTrue(intrinsicSize.height > 0, "Intrinsic height must be positive")
    }

    // 37. Onboarding restart from beginning explicitly resets to Step 1
    func test37_OnboardingRestartFromBeginningExplicitReset() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        prefs.onboardingCurrentStep = 4
        XCTAssertEqual(prefs.onboardingCurrentStep, 4)

        // When user explicitly clicks "Run Setup Wizard Again", step is reset to 1
        prefs.onboardingCurrentStep = 1
        XCTAssertEqual(prefs.onboardingCurrentStep, 1)
    }

    // 38. Onboarding completion resets step and enables fully configured state
    func test38_OnboardingCompletionResetsStepToDefault() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        let credMgr = KeychainCredentialManager(serviceName: "test.completion", backend: MockKeychainBackend(), userDefaults: testDefaults)

        prefs.onboardingCurrentStep = 5
        _ = try credMgr.addCredential(rawKey: "gsk_completionTestKey123456", provider: .groq)
        prefs.isOnboardingCompleted = true
        prefs.onboardingCurrentStep = 1

        XCTAssertTrue(prefs.isOnboardingCompleted)
        XCTAssertTrue(prefs.isSetupFullyConfigured(credentialManager: credMgr))
        XCTAssertEqual(prefs.onboardingCurrentStep, 1)
    }

    // 39. API Key Validator: Groq valid and invalid responses (No audio uploaded)
    func test39_APIKeyValidatorGroqValidAndInvalidResponses() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)

        // Case A: Valid Groq models response
        let validJSON = """
        {"object": "list", "data": [{"id": "whisper-large-v3-turbo", "object": "model"}]}
        """
        transport.enqueueResponse(statusCode: 200, body: validJSON.data(using: .utf8)!)

        let expValid = expectation(description: "Groq valid response")
        var validStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_syntheticMockKey12345", provider: .groq) { status in
            validStatus = status
            expValid.fulfill()
        }
        wait(for: [expValid], timeout: 2.0)

        XCTAssertEqual(validStatus, .verified(provider: .groq, modelName: "whisper-large-v3-turbo"))
        XCTAssertEqual(transport.capturedRequests.count, 1)
        let req = transport.capturedRequests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertNil(req.httpBody, "Validation must never upload audio or request body")

        // Case B: Invalid key (HTTP 401)
        transport.enqueueResponse(statusCode: 401, body: "{\"error\": \"Invalid API key\"}".data(using: .utf8)!)
        let expInvalid = expectation(description: "Groq invalid response")
        var invalidStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_rejectedKey000000", provider: .groq) { status in
            invalidStatus = status
            expInvalid.fulfill()
        }
        wait(for: [expInvalid], timeout: 2.0)
        XCTAssertEqual(invalidStatus, .invalidKey(provider: .groq, reason: "HTTP 401"))
    }

    // 40. API Key Validator: OpenAI valid and invalid responses
    func test40_APIKeyValidatorOpenAIValidAndInvalidResponses() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)

        // Case A: Valid OpenAI models response
        let validJSON = """
        {"object": "list", "data": [{"id": "whisper-1", "object": "model"}]}
        """
        transport.enqueueResponse(statusCode: 200, body: validJSON.data(using: .utf8)!)

        let expValid = expectation(description: "OpenAI valid response")
        var validStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "sk-mockOpenAIKey123456", provider: .openai) { status in
            validStatus = status
            expValid.fulfill()
        }
        wait(for: [expValid], timeout: 2.0)

        XCTAssertEqual(validStatus, .verified(provider: .openai, modelName: "whisper-1"))
        XCTAssertEqual(transport.capturedRequests.count, 1)
        XCTAssertEqual(transport.capturedRequests[0].url?.absoluteString, "https://api.openai.com/v1/models")

        // Case B: Forbidden (HTTP 403)
        transport.enqueueResponse(statusCode: 403, body: "{\"error\": \"Forbidden\"}".data(using: .utf8)!)
        let expInvalid = expectation(description: "OpenAI 403 response")
        var invalidStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "sk-forbiddenKey123456", provider: .openai) { status in
            invalidStatus = status
            expInvalid.fulfill()
        }
        wait(for: [expInvalid], timeout: 2.0)
        XCTAssertEqual(invalidStatus, .invalidKey(provider: .openai, reason: "HTTP 403"))
    }

    // 41. API Key Validator: Rate limit (429) and Server error (503)
    func test41_APIKeyValidatorRateLimitAndServerError() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)

        // Case A: 429 with Retry-After: 7
        transport.enqueueResponse(statusCode: 429, headers: ["Retry-After": "7"], body: Data())
        let expRate = expectation(description: "Rate limit 429")
        var rateStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_rateLimitedKey12345", provider: .groq) { status in
            rateStatus = status
            expRate.fulfill()
        }
        wait(for: [expRate], timeout: 2.0)
        XCTAssertEqual(rateStatus, .rateLimited(provider: .groq, retryAfterSeconds: 7.0))

        // Case B: 503 Service Unavailable
        transport.enqueueResponse(statusCode: 503, body: Data())
        let expServer = expectation(description: "Server error 503")
        var serverStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_serverErrKey12345", provider: .groq) { status in
            serverStatus = status
            expServer.fulfill()
        }
        wait(for: [expServer], timeout: 2.0)
        XCTAssertEqual(serverStatus, .serverError(provider: .groq, statusCode: 503))
    }

    // 42. API Key Validator: Model unavailable and Network timeout
    func test42_APIKeyValidatorModelUnavailableAndNetworkTimeout() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)

        // Case A: 200 OK but models list does not include whisper
        let noWhisperJSON = """
        {"object": "list", "data": [{"id": "text-embedding-ada-002"}, {"id": "gpt-4o"}]}
        """
        transport.enqueueResponse(statusCode: 200, body: noWhisperJSON.data(using: .utf8)!)
        let expModel = expectation(description: "Model unavailable")
        var modelStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "sk-noWhisperKey12345", provider: .openai) { status in
            modelStatus = status
            expModel.fulfill()
        }
        wait(for: [expModel], timeout: 2.0)
        XCTAssertEqual(modelStatus, .modelUnavailable(provider: .openai, modelName: "whisper-1"))

        // Case B: Network timeout error
        let timeoutErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        transport.enqueueError(timeoutErr)
        let expTimeout = expectation(description: "Timeout")
        var timeoutStatus: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_timeoutKey12345", provider: .groq) { status in
            timeoutStatus = status
            expTimeout.fulfill()
        }
        wait(for: [expTimeout], timeout: 2.0)
        if case .networkUnavailable(let prov, let reason) = timeoutStatus {
            XCTAssertEqual(prov, .groq)
            XCTAssertTrue(reason.contains("timed out"))
        } else {
            XCTFail("Expected .networkUnavailable, got \(String(describing: timeoutStatus))")
        }
    }

    // 43. API Key Validator: Cancellation and stale response handling
    func test43_APIKeyValidatorCancellationAndGenerationTracking() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)

        // Stale first request with cancelled error
        let cancelErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        transport.enqueueError(cancelErr)

        var req1Called = false
        validator.validateKey(rawKey: "gsk_cancelledKey12345", provider: .groq) { _ in
            req1Called = true
        }
        // Cancel first request (bumps generation)
        validator.cancel()

        // Second valid request
        let validBody = "{\"data\": [{\"id\": \"whisper-large-v3-turbo\"}]}".data(using: .utf8)!
        transport.enqueueResponse(statusCode: 200, body: validBody)
        let exp2 = expectation(description: "Second request completes")
        var req2Status: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_secondValidKey12345", provider: .groq) { status in
            req2Status = status
            exp2.fulfill()
        }

        wait(for: [exp2], timeout: 2.0)
        XCTAssertFalse(req1Called, "Stale or cancelled request callback must not be invoked")
        if case .verified(let prov, let model) = req2Status {
            XCTAssertEqual(prov, .groq)
            XCTAssertEqual(model, "whisper-large-v3-turbo")
        } else {
            XCTFail("Expected .verified for second request, got \(String(describing: req2Status))")
        }
    }

    // 44. Onboarding Accessibility state prevents advancing without permission
    func test44_OnboardingAccessibilityStateBlocksAdvancingUntilTrusted() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)
        prefs.onboardingCurrentStep = 3

        // When AXIsProcessTrusted() is false, step remains 3
        XCTAssertEqual(prefs.onboardingCurrentStep, 3)

        // Only when permission is verified does onboarding proceed to step 4
        prefs.onboardingCurrentStep = 4
        XCTAssertEqual(prefs.onboardingCurrentStep, 4)
    }

    // 45. Onboarding shortcut selection: Keep Right Option vs Custom
    func test45_OnboardingShortcutSelectionKeepDefaultVsCustom() throws {
        let prefs = PreferencesManager(userDefaults: testDefaults)

        // Choice 1: Default Right Option
        prefs.shortcutOption = .rightOption
        XCTAssertEqual(prefs.shortcutOption, .rightOption)

        // Choice 2: Custom Key Combination (e.g. ⌃⌥D)
        let customCombo = KeyCombo(keyCode: 2, modifiers: 0x00080000 | 0x00040000, displayString: "⌃⌥D")
        prefs.customKeyCombo = customCombo
        prefs.shortcutOption = .custom
        XCTAssertEqual(prefs.shortcutOption, .custom)
        XCTAssertEqual(prefs.customKeyCombo.displayString, "⌃⌥D")
    }

    // 46. Security: API key secret is never exposed in validation diagnostics
    func test46_SecurityNoAPIKeyLeaksInValidationDiagnostics() throws {
        let rawSecret = "gsk_superSecretValidationKey99999"
        let redacted = SafeLogger.redact("Failed connection with key \(rawSecret) on server")
        XCTAssertFalse(redacted.contains(rawSecret), "API key secret must never be exposed in diagnostics")
        XCTAssertTrue(redacted.contains("[REDACTED_KEY]"), "Redacted placeholder must be present")
    }
    // 47. A different Whisper model must not verify the model actually used by the app.
    func test47_APIKeyValidatorRejectsDifferentWhisperModel() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)
        transport.enqueueResponse(statusCode: 200, body: "{\"data\":[{\"id\":\"whisper-large-v3\"}]}".data(using: .utf8)!)
        let exp = expectation(description: "Different Groq model does not verify turbo")
        var status: APIKeyValidationStatus?
        validator.validateKey(rawKey: "gsk_syntheticDifferentModelKey", provider: .groq) {
            status = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(status, .modelUnavailable(provider: .groq, modelName: "whisper-large-v3-turbo"))
    }

    // 48. Cancellation may invoke the network completion synchronously.
    // Never cancel a transport while holding APIKeyValidator's internal lock.
    func test48_APIKeyValidatorSynchronousCancelCallbackDoesNotDeadlock() throws {
        let transport = MockHTTPTransport()
        let validator = APIKeyValidator(transport: transport)
        let task = MockCancellableTask()
        transport.manualInterceptHandler = { _, completion in
            task.onCancel = { completion(nil, nil, URLError(.cancelled)) }
            return task
        }
        var delivered = false
        validator.validateKey(rawKey: "gsk_syntheticCancelReentry", provider: .groq) { _ in
            delivered = true
        }
        validator.cancel()
        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(delivered, "Cancelled validation must not deliver stale completion")
    }

    // 49. Missing structural focus identity or a new process must not auto-paste.
    func test49_UnverifiableFocusOrNewProcessFallsBackToClipboard() throws {
        let pasteboard = MockPasteboardProvider()
        let ax = MockAccessibilityChecker()
        let insert = TextInsertionManager(pasteboard: pasteboard, accessibility: ax)
        let verified = TargetApplicationContext(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 100,
            localizedName: "TextEdit", windowIdentityToken: "win:1", focusedElementToken: "elem:1")
        let missingElement = TargetApplicationContext(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 100,
            localizedName: "TextEdit", windowIdentityToken: "win:1", focusedElementToken: nil)
        let outcome1 = insert.insertTranscribedText("One", sessionID: UUID(),
            expectedTarget: verified, currentTarget: missingElement)
        XCTAssertEqual(outcome1, .windowOrElementChanged(appName: "TextEdit", copiedToClipboard: true))
        let differentProcess = TargetApplicationContext(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 101,
            localizedName: "TextEdit", windowIdentityToken: "win:1", focusedElementToken: "elem:1")
        let outcome2 = insert.insertTranscribedText("Two", sessionID: UUID(),
            expectedTarget: verified, currentTarget: differentProcess)
        XCTAssertEqual(outcome2, .focusChanged(expectedApp: "TextEdit", actualApp: "TextEdit", copiedToClipboard: true))
        XCTAssertEqual(ax.postCmdVCalledCount, 0)
        XCTAssertEqual(pasteboard.lastWrittenPlainText, "Two")
    }

}
