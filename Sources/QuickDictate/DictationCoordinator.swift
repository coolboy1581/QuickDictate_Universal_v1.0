import Cocoa
import AVFoundation

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
