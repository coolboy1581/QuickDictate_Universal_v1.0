import Cocoa

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
