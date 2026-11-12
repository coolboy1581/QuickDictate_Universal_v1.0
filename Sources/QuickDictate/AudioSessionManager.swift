import Foundation
import AVFoundation

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
