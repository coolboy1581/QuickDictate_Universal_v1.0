# Security Policy (`SECURITY.md`)

## Supported Versions

| Version | Supported | macOS Target | Architectures |
| :--- | :--- | :--- | :--- |
| `2.0.0-beta.1` | Beta support | macOS 12.0+ (Monterey or newer) | Universal 2 (`arm64` & `x86_64`) |
| `< 2.0` | No | Legacy plaintext key storage | Upgrade to `2.0.0+` immediately |

## Security Architecture Highlights (`v2.0.0`)

1. **Keychain-Backed Credential Storage:** API keys are stored in the user's macOS Keychain (`kSecAttrAccessibleWhenUnlocked`) rather than plaintext dotfiles.
2. **Legacy Credential Migration & Rotation Recommendation:** QuickDictate automatically migrates legacy `~/.quickdictate_keys` and `~/.quickdictate_key` files into macOS Keychain, verifies Keychain read-back, and removes the plaintext files. Because APFS/SSD block wear-leveling and Time Machine backups can retain historical copies of deleted plaintext files, users upgrading from `v1.x` who have shared backups should rotate their API keys in the [Groq Console](https://console.groq.com/keys) or OpenAI Dashboard.
3. **Per-Session Isolated Temporary Audio:** Recordings are written to `$TMPDIR/com.github.quickdictate.recordings/dictation-<UUID>.wav` with directory permissions `0700` and file permissions `0600`, and deleted immediately upon transcription completion, error, cancellation, or app exit.
4. **Focus-Aware Text Insertion:** QuickDictate records the frontmost target application (`pid_t` and bundle ID) when recording begins and refuses to blindly inject synthetic `Cmd + V` keystrokes if focus changes to a different application while cloud transcription is in flight.
5. **Log Redaction:** `SafeLogger` scrubs `Bearer` tokens, `gsk_...`, and `sk-...` patterns before writing any error diagnostics, and never logs spoken audio or transcribed text.

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

1. Use GitHub's **Report a vulnerability** (Private Vulnerability Reporting) tab on the repository's **Security** page, if GitHub private reporting is enabled. If it is not available, contact the maintainer privately through a verified contact method rather than posting exploitable details publicly.
2. Include the QuickDictate version, macOS version, reproduction steps, and impact assessment.
3. Never include real API keys (`gsk_...`, `sk-...`) or personal audio files in bug reports.
