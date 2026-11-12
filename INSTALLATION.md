# Installing QuickDictate on macOS

## Requirements

- macOS **Monterey 12.0 or later**, on Intel x86_64 or Apple Silicon arm64.
- Working microphone, internet connection, and **your own** Groq or OpenAI API key.
- macOS permissions: **Microphone** for audio recording; **Accessibility** for automatic insertion into other apps.

## Install the beta DMG

1. On this repository's [Releases page](https://github.com/coolboy1581/QuickDictate_Universal_v1.0/releases), select **v2.0.0-beta.1** and download `QuickDictate_v2.0.0-beta.1_Unsigned.dmg`. Check its size and `SHA256SUMS.txt` checksum. If assets are not available, the CI release build has not completed: do not use an unrelated mirror.
2. In Finder → Downloads, **double-click the DMG** to mount it.
3. **Drag QuickDictate.app into Applications** using the shortcut shown in the DMG window.
4. Eject the QuickDictate disk image. Launch the app from **Applications** or **Launchpad**. Do not run the app directly inside the DMG: approval and Login Item registrations may refer to a temporary path.
5. In the wizard: Welcome → Microphone → Accessibility → Provider/API key and Test Connection → Shortcut → Ready. The app stays in the menu bar when setup completes.

## Gatekeeper and unsigned beta limitations

This beta is built with **ad-hoc code signing**. It is **not Developer ID signed or Apple-notarized**, and Apple may block it when downloaded from the Internet. This is not equivalent to the official Apple security review.

If you consciously trust the download source and have verified the release checksum, Apple may offer **Control-click the app → Open** in Finder, or an **Open Anyway** control after an attempted launch: on Monterey look under **System Preferences → Security & Privacy → General**; on newer macOS look under **System Settings → Privacy & Security**. The exact steps and availability vary by version and policy. **Do not disable Gatekeeper, SIP, or remove quarantine flags system-wide.** If macOS reports the file is damaged or tampered with, do not bypass the warning; re-download and verify the checksum or build from source. Managed corporate Macs may prohibit this installation.

We recommend building from source if the unsigned beta is blocked, and plan Developer ID signing/notarization for a future stable release.

## Permission details

**Microphone:** The app requests Microphone access during onboarding. If previously denied, go to **System Preferences → Security & Privacy → Privacy → Microphone** on Monterey, select QuickDictate, and return to the app. If you change permissions, macOS may require restarting the app.

**Accessibility:** QuickDictate requests permission to dispatch text insertion. On Monterey open **System Preferences → Security & Privacy → Privacy → Accessibility**, unlock with the padlock, then check QuickDictate. If the entry is missing, use **+** to add the **actual installed** `/Applications/QuickDictate.app`. Return to the wizard; it rechecks `AXIsProcessTrusted()` and enables Continue only when authorized. A stale entry from an old build is not proof that the currently launched executable has permission. Avoid duplicate copies in Desktop or mounted DMGs.

A **separate Snippets permission** is not required by the intended design; snippets run inside QuickDictate.

## API provider connection

Choose Groq (`whisper-large-v3-turbo`) or OpenAI (`whisper-1`). Create your own key at the provider's official site, enter it in onboarding, and press **Test Connection**. The test sends only an authenticated HTTPS models-list request; it uploads **no microphone audio**. A positive result confirms key/model listing, not billing balance or future transcription success. Connection failures can be retried. An explicit offline **Save Without Verification** route may be available, but dictation can fail until the key is verified. Keys are stored in Keychain.

## Shortcuts and first dictation

Keep **Right Option** (default) or choose another supported key combination. After setup, click a text field, **tap** Right Option once to start recording, speak, and **tap** it again to stop and transcribe. QuickDictate may copy to the clipboard instead of automatic insertion if it cannot safely verify the original target window and focused field. Check menu-bar status/Settings for errors.

## Update an existing installation

Quit QuickDictate from the menu-bar menu, drag the newer verified app from the DMG into `/Applications`, and replace the existing copy. **Do not delete Keychain entries, UserDefaults, or snippets** to update. macOS may require permission re-approval if app identity/signature changes between unsigned builds. Always preserve personal snippets before experimenting with beta versions.

## Uninstall and data cleanup

1. Quit QuickDictate and turn off Launch at Login in Settings.
2. Delete `/Applications/QuickDictate.app` (and any other confirmed installed copies).
3. **Optional, irreversible:** Remove only QuickDictate's `com.github.quickdictate` UserDefaults domain, `~/.quickdictate_snippets.json*`, and **Keychain** credentials in service `com.github.quickdictate.credentials` if you explicitly want a full factory reset. Simply dragging the app to Trash does **not** delete these personal settings or provider keys.
4. macOS permission entries can remain after uninstall. Review only QuickDictate entries in the Privacy pane; do not reset privacy permissions for other applications.

For other problems see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
