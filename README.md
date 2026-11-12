# QuickDictate

**Native speech-to-text for macOS, powered by your own Groq or OpenAI API key.**

[![macOS CI](https://github.com/coolboy1581/QuickDictate_Universal_v1.0/actions/workflows/macos-ci.yml/badge.svg)](https://github.com/coolboy1581/QuickDictate_Universal_v1.0/actions/workflows/macos-ci.yml)  [License: MIT](LICENSE) · **macOS 12 Monterey or later** · **Intel & Apple Silicon**

QuickDictate is a lightweight menu-bar dictation app written in Swift/AppKit. Speak into your Mac, then insert the transcription into the application you were using. It includes a first-launch setup wizard, global keyboard shortcuts, local text snippets, and Keychain-based credential storage. It has **no project-operated backend or telemetry**. Speech is processed by the cloud provider you select.

> **Beta distribution notice:** `v2.0.0-beta.1` is an **unsigned-by-Developer-ID / ad-hoc-signed** testing release, **not Apple-notarized**. macOS Gatekeeper may warn or prevent launching it. Only download binaries from this repository's official Releases page, verify the SHA-256 value, and review Apple's security prompt. You can also build directly from the published source. See [Installation & Gatekeeper](INSTALLATION.md).

## Download and install

1. Open [**GitHub Releases**](https://github.com/coolboy1581/QuickDictate_Universal_v1.0/releases) and choose the latest **beta**.
2. Download the `QuickDictate_v2.0.0-beta.1_Unsigned.dmg` asset. Verify the SHA-256 against the release `SHA256SUMS.txt`.
3. Double-click the DMG, drag **QuickDictate.app** to **Applications**, and eject the DMG.
4. Launch QuickDictate from **Launchpad**, **Spotlight**, or **Finder → Applications**. Do **not** run it from inside the mounted DMG.
5. Complete the six-step setup below and start dictating. macOS may show a security prompt for this unnotarized beta; see [Installation & Gatekeeper](INSTALLATION.md).

Detailed prerequisites, installation, updates, uninstallation, and troubleshooting are in [INSTALLATION.md](INSTALLATION.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## First launch: the six-step setup wizard

| Step | What you do | Why |
|---|---|---|
| **1. Welcome** | Read the privacy explanation and click Get Started. | Cloud processing is disclosed before recording. |
| **2. Microphone** | Click Grant Microphone Access and approve the macOS dialog. | Allows user-initiated recording. |
| **3. Accessibility** | Click Enable Accessibility; use macOS **System Preferences → Security & Privacy → Privacy → Accessibility** (Monterey), then return to QuickDictate. | Allows QuickDictate to insert text into other apps. Continue becomes available when the system reports access. |
| **4. Provider & key** | Choose **Groq** or **OpenAI**, enter your own API key, and select **Test Connection**. | Verifies access to the exact supported model without uploading audio; securely stores a valid key in Keychain. Network failures can be saved without verification with an explicit warning. |
| **5. Shortcut** | Keep **Right Option** (default) or choose a different supported shortcut. | Controls starting/stopping dictation. |
| **6. Ready** | Click **Finish Setup & Start Dictating**. | The menu-bar utility stays available in the background. |

QuickDictate resumes an interrupted setup instead of returning to the Welcome step. You can reopen the wizard from the application's menu-bar Settings.

### Getting an API key

- **Groq:** Create a key in the [Groq Console](https://console.groq.com/keys); QuickDictate requests `whisper-large-v3-turbo`.
- **OpenAI:** Create a key in the [OpenAI Platform](https://platform.openai.com/api-keys); QuickDictate requests `whisper-1`.

Keys are **not provided by QuickDictate**. Usage, quotas, prices, and provider retention policies depend on your own account. The **Test Connection** action sends an authenticated models-list request; it **does not upload microphone audio** and does not prove transcription quota or billing availability. Model identifiers are checked exactly. See [Privacy](PRIVACY.md).

## Use QuickDictate

1. Click into a text field in TextEdit, Notes, a supported browser, or another application.
2. **Tap Right Option once** to start recording (unless you configured a different hotkey).
3. Speak naturally, then **tap the shortcut again** to stop and transcribe. A network connection is required.
4. QuickDictate inserts the resulting text if it can verify that the original application, window, **and focused element** remain the same. If it cannot safely confirm the destination, it copies the text to the clipboard for you to paste manually.

The shortcut is a **toggle**, not a hold-to-talk mechanism. QuickDictate should not activate during ordinary Option-key chords. You can choose custom modifier combinations (for example, Control–Option–D) in Settings. Some global shortcuts are reserved by macOS and cannot be used.

### Voice Snippets

Voice Snippets expand predefined spoken triggers **locally** *after* transcription. For example, a trigger `enter work email` can be replaced by `name@example.com` when spoken alone or in a longer sentence. Configure triggers and replacements in QuickDictate's **Snippets** management window; multiline snippets are supported. Snippets are saved to `~/.quickdictate_snippets.json` with backups. Their *spoken trigger audio* still goes to the chosen transcription provider, but snippet replacement text is processed locally.

### Other settings

- Select your preferred provider and manage multiple keys; keys are stored in macOS Keychain. Automatic same-provider failover may occur; **cross-provider failover requires explicit opt-in**.
- Optional **Periodic Preview** sends additional snippets of audio to the provider before you finish speaking and may increase API usage.
- Configure sound feedback, Launch at Login, a custom shortcut, and menu-bar/Dock presentation.
- Use **Run Setup Wizard Again** to revisit onboarding. Do not delete your data just to update permissions.

## Build from source

Requires macOS 12+, Swift 5.7+ / Apple Command Line Tools or Xcode, Python 3, `lipo`, `codesign`, and `hdiutil`. **The Universal 2 DMG must be built on macOS**, not Linux.

```bash
xcode-select --install  # only if Command Line Tools are not already installed
git clone https://github.com/coolboy1581/QuickDictate_Universal_v1.0.git
cd QuickDictate_Universal_v1.0
chmod +x Scripts/*.sh
./Scripts/build_universal_app.sh
./Scripts/create_dmg.sh build/QuickDictate-local.dmg
open build/QuickDictate.app
```

`build_universal_app.sh` generates `QuickDictate.swift`, compiles Intel and Apple Silicon slices, verifies architectures, bundles the icon, and **ad-hoc signs** unless `SIGN_IDENTITY` is set. With full Xcode it attempts official `swift test`; with Command Line Tools only it uses the standalone compatibility harness. A development build isn't notarized and should not be represented as a trusted signed release. Do not distribute builds with personal credentials or audio files.

## Tests and CI

There are **49 automated scenarios in source** (46 from the owner-tested build and three release-hardening regression tests). Run:

```bash
swift test                               # Apple XCTest when full Xcode is installed
./Scripts/run_standalone_tests.sh      # standalone compatibility harness
RUN_TESTS=0 ./Scripts/build_universal_app.sh
```

Tests use synthetic/mock credentials, networks, and permissions rather than live microphone uploads. GitHub Actions runs official macOS tests and verifies the Universal 2 package; its status is visible through the badge above. **A local standalone-harness pass is not a substitute for a passing macOS CI run.** UI permission dialogs, macOS Gatekeeper, real dictation, and clipboard insertion still require hands-on acceptance testing.

## Privacy, permissions, and security

- **Microphone** is required for recording. **Accessibility** is required for automatic insertion into another application's text field.
- Audio is written temporarily to a user-restricted WAV file and uploaded **over HTTPS** to the user-selected provider when recording ends; optional preview uploads additional audio during recording.
- The app does **not** run local Whisper inference, and it does **not** promise provider-side zero retention.
- API keys are kept in the macOS Keychain. Snippets are locally stored; no project telemetry/analytics/backend is included.
- Unverifiable text targets fall back to clipboard-only mode. If the clipboard is restored, another application's changes are respected.

Read [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Project layout

| Path | Description |
|---|---|
| `Sources/QuickDictate/` | Modular Swift/AppKit implementation |
| `Tests/QuickDictateTests/` | Mocked XCTest cases |
| `Scripts/` | Universal build, standalone harness, packaging, and icon-generation tools |
| `AppBundle/` | App icon and Info.plist |
| `QuickDictate.swift` | Automatically generated standalone source for auditing/compatibility |
| `.github/workflows/macos-ci.yml` | macOS CI verification |

## Contribute and report problems

Issues, reproducible bug reports, accessibility fixes, and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md). **Never attach real API keys, audio, or personal transcripts to issues**. Use GitHub private vulnerability reporting for security findings, described in [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE). This project is independent of Groq, OpenAI, and Apple and is not affiliated with or endorsed by them.
