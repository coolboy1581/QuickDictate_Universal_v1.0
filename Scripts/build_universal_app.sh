#!/usr/bin/env bash
set -euo pipefail

# QuickDictate — Reproducible Universal 2 Build & Packaging Script
# Supports macOS 12.0+ across Apple Silicon (arm64) and Intel (x86_64)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/QuickDictate.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

SIGN_IDENTITY="${SIGN_IDENTITY:--}" # Default to ad-hoc signing ("-") unless Developer ID is provided
RUN_TESTS="${RUN_TESTS:-1}"

echo "==> Preparing clean build directory at ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Assemble single-file QuickDictate.swift for standalone compilation compatibility
echo "==> Generating consolidated QuickDictate.swift from modular sources"
python3 "${ROOT_DIR}/Scripts/assemble_single_file.py"

if [[ "${RUN_TESTS}" == "1" ]]; then
    if xcrun --find xctest >/dev/null 2>&1; then
        echo "==> Running automated XCTest suite via Swift Package Manager..."
        swift test
    else
        echo "==> [NOTICE] XCTest framework is not available in the active Command Line Tools SDK."
        echo "==> Running comprehensive standalone test suite (49 automated scenarios)..."
        "${ROOT_DIR}/Scripts/run_standalone_tests.sh"
    fi
fi

if [[ ! -f "${ROOT_DIR}/AppBundle/AppIcon.icns" ]]; then
    echo "==> Generating AppIcon.icns from vector generator..."
    swift "${ROOT_DIR}/Scripts/generate_icon.swift" "${ROOT_DIR}"
fi

echo "==> Copying AppIcon.icns into app bundle Resources..."
cp "${ROOT_DIR}/AppBundle/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

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
    "${ROOT_DIR}/Sources/QuickDictate/main.swift"
)

echo "==> Compiling for Intel (x86_64-apple-macos12.0)..."
swiftc -target x86_64-apple-macos12.0 -O \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Security \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework Carbon \
    "${SOURCES[@]}" \
    -o "${BUILD_DIR}/QuickDictate_x86_64"

echo "==> Compiling for Apple Silicon (arm64-apple-macos12.0)..."
swiftc -target arm64-apple-macos12.0 -O \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Security \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework Carbon \
    "${SOURCES[@]}" \
    -o "${BUILD_DIR}/QuickDictate_arm64"

echo "==> Creating Universal 2 binary with lipo..."
lipo -create \
    "${BUILD_DIR}/QuickDictate_x86_64" \
    "${BUILD_DIR}/QuickDictate_arm64" \
    -output "${MACOS_DIR}/QuickDictate"

rm -f "${BUILD_DIR}/QuickDictate_x86_64" "${BUILD_DIR}/QuickDictate_arm64"
chmod 755 "${MACOS_DIR}/QuickDictate"

echo "==> Copying Info.plist..."
cp "${ROOT_DIR}/AppBundle/Info.plist" "${CONTENTS_DIR}/Info.plist"

echo "==> Verifying Universal 2 architectures and minimum macOS version..."
lipo -info "${MACOS_DIR}/QuickDictate"
otool -l "${MACOS_DIR}/QuickDictate" | grep -A 4 -E "LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX" || true

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "==> Applying local ad-hoc signature (Note: ad-hoc signing is for local use and is NOT notarized for Gatekeeper distribution)..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
else
    echo "==> Signing with Developer ID identity: ${SIGN_IDENTITY} (Hardened Runtime enabled)..."
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
fi

codesign --verify --verbose=2 "${APP_BUNDLE}"
echo "==> Build complete: ${APP_BUNDLE}"
