import Foundation

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
