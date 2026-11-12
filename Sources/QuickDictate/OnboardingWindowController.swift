import Cocoa
import AVFoundation

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
