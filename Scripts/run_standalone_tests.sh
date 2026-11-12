#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t qd_tests)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Preparing standalone test runner..."

# Create clean version of QuickDictateTests without XCTest imports for standalone execution
sed -e 's/^import XCTest/\/\/ import XCTest/' \
    -e 's/^@testable import QuickDictate/\/\/ @testable import QuickDictate/' \
    "${ROOT_DIR}/Tests/QuickDictateTests/QuickDictateTests.swift" > "${TMP_DIR}/QuickDictateTests_Prepared.swift"

cp "${ROOT_DIR}/Scripts/run_all_tests.swift" "${TMP_DIR}/main.swift"

SOURCES=(
    "${ROOT_DIR}/Sources/QuickDictate/Models.swift"
    "${ROOT_DIR}/Sources/QuickDictate/KeychainCredentialManager.swift"
    "${ROOT_DIR}/Sources/QuickDictate/AudioSessionManager.swift"
    "${ROOT_DIR}/Sources/QuickDictate/TranscriptionClient.swift"
    "${ROOT_DIR}/Sources/QuickDictate/KeyboardShortcutMonitor.swift"
    "${ROOT_DIR}/Sources/QuickDictate/TextInsertionManager.swift"
    "${ROOT_DIR}/Sources/QuickDictate/SnippetManager.swift"
    "${ROOT_DIR}/Sources/QuickDictate/PreferencesAndHUD.swift"
    "${ROOT_DIR}/Sources/QuickDictate/OnboardingWindowController.swift"
    "${ROOT_DIR}/Sources/QuickDictate/SettingsWindowController.swift"
    "${ROOT_DIR}/Sources/QuickDictate/DictationCoordinator.swift"
    "${ROOT_DIR}/Sources/QuickDictate/AppDelegate.swift"
    "${ROOT_DIR}/Scripts/standalone_test_shim.swift"
    "${TMP_DIR}/QuickDictateTests_Prepared.swift"
    "${TMP_DIR}/main.swift"
)

echo "==> Compiling standalone test harness with swiftc..."
swiftc -O \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Security \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework Carbon \
    "${SOURCES[@]}" \
    -o "${TMP_DIR}/QuickDictateTestRunner"

echo "==> Executing test runner..."
"${TMP_DIR}/QuickDictateTestRunner"
