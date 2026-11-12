import Cocoa

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
