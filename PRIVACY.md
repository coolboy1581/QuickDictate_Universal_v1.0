# Privacy Policy (`PRIVACY.md`)

**Effective Date:** November 11, 2026  
**Project:** QuickDictate (`v2.0.0`)

QuickDictate is an open-source, menu-bar dictation utility for macOS. Because QuickDictate relies on third-party cloud speech-to-text APIs that you configure with your own API credentials, this document explains what data stays on your Mac, what data leaves your Mac, and how credentials and temporary recordings are handled.

## 1. Summary of Data Flow

1. **Local Audio Capture:** When you initiate dictation (by tapping your configured shortcut or clicking **Start Dictation** in the menu bar), QuickDictate records microphone audio locally on your Mac at 16,000 Hz, 16-bit mono Linear PCM (`.wav`).
2. **Direct Cloud Transmission:** When you stop recording (or periodically while speaking if you explicitly enable the optional **Periodic Preview HUD**), QuickDictate sends the recorded `.wav` audio over encrypted HTTPS directly from your Mac to your selected cloud transcription provider:
   - **Groq:** `https://api.groq.com/openai/v1/audio/transcriptions` (using model `whisper-large-v3-turbo`, per the [Groq Speech-to-Text Documentation](https://console.groq.com/docs/speech-to-text))
   - **OpenAI:** `https://api.openai.com/v1/audio/transcriptions` (using model `whisper-1`, per the [OpenAI Speech-to-Text Guide](https://developers.openai.com/api/docs/guides/speech-to-text))
3. **No Intermediary Servers, Analytics, or Telemetry:** QuickDictate has no backend servers operated by the project authors and includes **no analytics SDKs, crash reporters, or telemetry**. Network requests go strictly between your Mac and the API endpoint of the provider you selected.
4. **Internet & Billing Requirements:** Cloud transcription requires an active internet connection. API requests are billed or counted against the rate limits and quotas of your personal or organization account with Groq or OpenAI (for example, see [Groq Rate Limits](https://console.groq.com/docs/rate-limits)).

## 2. Cross-Provider Failover & Explicit Consent

If you store multiple API keys in QuickDictate, automatic failover between keys belonging to the **same** provider happens automatically on rate-limit (`HTTP 429`), authentication, or server errors.

- **Cross-Provider Failover Disabled by Default:** QuickDictate **never** sends your audio recording to a different cloud provider (for example, failing over from Groq to OpenAI) unless you explicitly check **"Allow cross-provider failover"** in **Settings & Keychain Keys...** or the menu bar.

## 3. Optional Periodic Preview HUD & API Consumption

- By default, QuickDictate uploads audio **once** when you finish speaking.
- If you enable the optional **Periodic Preview HUD**, QuickDictate sends up to **6** interim snapshots of the in-progress recording (at 2.5-second intervals, capped at 2 MB per preview snapshot) to your primary provider while you are speaking.
- Because neither Groq's nor OpenAI's standard `/audio/transcriptions` HTTP endpoint is a bidirectional WebSocket stream, enabling periodic previews generates additional API requests and will consume additional provider quota or incurred charges (for instance, Groq bills a 10-second minimum per transcription request as noted in the [Groq Speech-to-Text Documentation](https://console.groq.com/docs/speech-to-text)).

## 4. Local Temporary Audio Lifecycle

- Each recording session writes to a unique session file (`dictation-<UUID>.wav`) inside an application-specific temporary directory (`$TMPDIR/com.github.quickdictate.recordings/`) configured with POSIX `0700` directory permissions and `0600` file permissions (accessible only to your macOS user account).
- Temporary `.wav` files are automatically deleted immediately after:
  - Successful transcription
  - Failed transcription
  - User cancellation
  - Normal application termination (`applicationWillTerminate`)
  - Subsequent application startup (cleaning up any orphaned files if the app previously force-quit or crashed)

## 5. API Credential Storage & Legacy File Migration

- **macOS Keychain Storage:** API keys are stored in the macOS login Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`) under service identifier `com.github.quickdictate.credentials`.
- **Masked UI Display:** Full API keys are never displayed in plaintext in the QuickDictate UI once saved; only a masked preview (e.g., `gsk_••••3456`) and provider label are shown.
- **One-Time Legacy Migration & Backup Caveat:** Earlier versions of QuickDictate stored API keys in plaintext files (`~/.quickdictate_keys` and `~/.quickdictate_key`). On launch, QuickDictate v2.0.0 imports valid keys into macOS Keychain, verifies read-back from Keychain, and then removes the legacy plaintext files.
  - **Important Caveat:** Standard filesystem deletion (`unlink`) on modern SSDs (APFS) does not cryptographically erase underlying flash blocks, and previously created Time Machine snapshots, cloud backups, or disk images may still contain copies of `~/.quickdictate_keys` or `~/.quickdictate_key`. If your machine or backups are shared or untrusted, rotate any previously used API keys in your provider console ([Groq Console Keys](https://console.groq.com/keys) or OpenAI Dashboard).

## 6. Local Voice Snippets & Diagnostic Logging

- **Voice Snippets:** Your voice snippets are stored locally in `~/.quickdictate_snippets.json` (with `0600` permissions) and expanded entirely on your Mac before text insertion. Your snippet table is never uploaded to any server; however, if you speak a trigger phrase aloud, the spoken words themselves are part of the audio sent to your transcription provider.
- **Zero Sensitive Content in Logs:** QuickDictate never logs spoken transcripts, snippet replacement values, or audio data. Any diagnostic error messages pass through `SafeLogger.redact(_:)`, which strips strings matching `Bearer ...`, `gsk_...`, or `sk-...` patterns.

## 7. Third-Party Provider Privacy & Data Retention Policies

Once audio leaves your Mac, its processing and retention are governed by the terms and privacy policies of the provider you selected and your account configuration with them. QuickDictate cannot guarantee zero data retention on provider servers. Review the official policies for your account tier:

- **OpenAI:** [OpenAI API Data Usage Policies](https://openai.com/policies/api-data-usage-policies)
- **Groq:** [Groq Console Policies & Notices](https://console.groq.com/docs/speech-to-text)
