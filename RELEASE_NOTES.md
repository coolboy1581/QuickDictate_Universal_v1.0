# QuickDictate v2.0.0-beta.1 — first public beta

A native macOS 12+ speech-to-text app for Intel and Apple Silicon, using your own Groq or OpenAI Whisper API key.

## Included

- DMG drag-to-Applications installation and Launchpad app icon.
- Six-step first-run wizard with live Microphone and Accessibility permission checks.
- Groq (`whisper-large-v3-turbo`) and OpenAI (`whisper-1`) Keychain credentials and non-audio API-key verification.
- Right Option default and configurable global shortcut combinations.
- Local Voice Snippets with text expansion and recovery backups.
- Permission-aware text insertion with clipboard-only fallback when focus identity is uncertain.
- Multi-key failover within the selected provider; optional cross-provider failover requiring opt-in.
- 49 automated source scenarios, including regression coverage for exact model verification, cancellation reentrancy, and unverifiable paste destinations.

## Important security and distribution notice

**This beta DMG is ad-hoc signed, not Apple Developer ID signed or notarized.** macOS Gatekeeper may block opening it. Verify `SHA256SUMS.txt`, use the official GitHub release asset only, and read [INSTALLATION.md](INSTALLATION.md). An unsigned beta is not guaranteed to install on managed Macs.

Audio is temporarily stored on the Mac and sent directly to the chosen third-party cloud transcription provider over HTTPS after recording; enabling periodic preview sends additional requests. API costs and server-side retention depend on the provider. No QuickDictate-operated service or telemetry is included. Do not share API keys or microphone recordings in bug reports.

## Testing status

The owner successfully performed real installation, onboarding, and dictation acceptance on macOS Monterey with the preceding local build. The release-hardening changes need independent CI verification; automated mock tests do not replace hands-on testing across supported Macs. Consult the GitHub Actions check before relying on this build.

## Known limitations

- Not notarized or Developer ID signed.
- Requires internet and a separately obtained provider API key; cloud transcription may be billed.
- Auto-insert may fall back to the clipboard in applications where Accessibility does not expose a stable focused element.
- Optional previews may increase API requests.
- First beta; please report reproducible issues without personal data.
