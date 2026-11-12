import Cocoa
import ServiceManagement

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
