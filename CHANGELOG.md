# Changelog

## [2.0.0-beta.1] — 2026-11-12

First public beta candidate. Native first-launch wizard, Launchpad icon, Groq/OpenAI model-list key verification, configurable hotkeys, local snippets, Keychain credentials, Universal 2 build and DMG packaging. Three targeted release-hardening changes: exact expected transcription model matching, lock-free API-key request cancellation, and clipboard fallback for unverifiable focus/process changes. Adds macOS CI and accurate documentation.

The previous owner-tested application reported 46/46 standalone-harness scenarios. This candidate contains 49, with release CI results recorded on GitHub; no undocumented claims of official XCTest passing.

## [2.0.0 local test builds]

Internal builds implemented modular Swift sources, hardened session cleanup, source-controlled snippet recovery, menu-bar startup, improved Accessibility onboarding, onboarding persistence and the API connection test. Not public releases.
