# Contributing to QuickDictate

Thank you for helping improve this native, lightweight macOS tool. We welcome bug reports, documentation corrections, accessibility fixes, tests, and focused pull requests.

## Requirements

- macOS 12+; Xcode for official XCTest or Apple Command Line Tools for the standalone harness.
- Keep the project native Swift/AppKit without introducing tracking, remote infrastructure, or third-party dependencies without maintainer review.
- Do not commit API keys, Keychain exports, local snippets, personal recordings, signing certificates, or derived build products.

## Before opening a PR

1. `./Scripts/run_standalone_tests.sh` — deterministic logic/integration harness using synthetic mocked credentials, network and accessibility; **not official XCTest**.
2. `swift test` — official XCTest where full Xcode is installed; new tests must pass there.
3. `RUN_TESTS=0 ./Scripts/build_universal_app.sh` — verify Intel and Apple Silicon slices; may require Xcode depending on local SDK/toolchain.
4. `python3 Scripts/assemble_single_file.py` — keep generated `QuickDictate.swift` synchronized with modular source.
5. Verify `git diff --check`, grep for secrets and personal data, and check `.gitignore`.

Don't introduce real network calls to providers into automated tests. Use `MockHTTPTransport`, `MockKeychainBackend`, `MockAccessibilityChecker`, and `MockPasteboardProvider`. Security-sensitive text insertion requires matching process, window, and focused-element identity or a clipboard-only fallback.

Provide a minimal reproduction and macOS version in PRs. Use [private vulnerability reporting](SECURITY.md) for exploitable weaknesses rather than public issues.

## Layout

`Sources/QuickDictate/` (modular app), `Tests/QuickDictateTests/`, `AppBundle/`, `Scripts/`, and `.github/workflows/`.

## License

Contributions are submitted under the repository's [MIT License](LICENSE).
