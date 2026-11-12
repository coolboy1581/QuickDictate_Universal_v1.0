# Troubleshooting QuickDictate

| Symptom | What to check |
|---|---|
| **App is missing from Launchpad** | Verify `/Applications/QuickDictate.app` exists; don't launch it from the mounted DMG. Quit other old copies. Launch Services may take time to refresh. Open from Finder → Applications first. |
| **Menu-bar icon is missing** | Verify QuickDictate is running via Activity Monitor. Click it from Applications. Restart the app once after completing onboarding. Review the Dock/menu-bar preference. |
| **Wizard returned to Welcome** | A persisted incomplete step should resume; check whether you're launching a second old `.app` copy. Report the macOS version, app path, and step transition, without sharing credentials. |
| **Accessibility says Not Enabled but QuickDictate appears in the list** | An old or unchecked entry isn't necessarily trusted. On Monterey go to System Preferences → Security & Privacy → Privacy → Accessibility. Unlock, add `/Applications/QuickDictate.app` if missing, check its box, and return to the wizard. Quit/reopen if macOS asks. |
| **Repeated Microphone request or denied audio** | System Preferences → Security & Privacy → Privacy → Microphone. Allow the actual installed QuickDictate app. Quit/reopen if necessary. |
| **API key verification fails** | Ensure your key is copied from your selected provider and that the exact model is listed: Groq `whisper-large-v3-turbo`, OpenAI `whisper-1`. 401/403 means unauthorized; 429 rate limited; network errors can be temporary. This test doesn't upload audio or guarantee quota. |
| **Nothing happens on Right Option** | Finish onboarding, ensure shortcut monitoring is enabled, make sure you are *tapping* rather than holding the modifier, and check whether macOS or another utility intercepts the shortcut. Try a custom chord. |
| **Transcript is copied but not inserted** | This is intentional when QuickDictate cannot positively verify the same process, window, and focused field after cloud processing. Paste the clipboard into the intended field manually; don't disable target safety checks. |
| **Transcript never arrives** | Verify internet access, microphone authorization, provider/key, model availability, quotas/rate limits, and status messages. Providers can charge for API requests. |
| **Snippet doesn't expand** | Open the Snippets manager and verify the exact spoken trigger. Dictation must first complete using the selected cloud provider. Beware duplicate triggers or corrupted snippet JSON; the app should preserve corrupt files for recovery. |
| **macOS blocks the app** | This beta is ad-hoc signed and **not notarized**. Verify the DMG checksum; consult [installation safety notes](INSTALLATION.md). Do not bypass warnings for tampered/damaged downloads. |

## How to report a bug

Open a GitHub issue with the macOS version, CPU architecture, QuickDictate beta version, exact steps, what you expected, and what happened. **Do not upload real API keys, transcripts, recordings, Keychain exports, or private snippets.** For sensitive security problems see [SECURITY.md](SECURITY.md).
