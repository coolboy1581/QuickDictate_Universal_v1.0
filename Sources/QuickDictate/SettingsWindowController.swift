import Cocoa
import AVFoundation

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
