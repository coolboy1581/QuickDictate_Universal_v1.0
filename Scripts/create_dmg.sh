#!/usr/bin/env bash
set -euo pipefail

# QuickDictate — Consumer DMG Packaging Script
# Creates a compressed, read-only disk image (UDZO) with drag-and-drop Applications link

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/QuickDictate.app"
DMG_PATH="${1:-${BUILD_DIR}/QuickDictate_FinalFreshInstall_Test.dmg}"
STAGE_DIR="$(mktemp -d -t qd_dmg_stage)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "==> Error: App bundle not found at ${APP_BUNDLE}. Run build_universal_app.sh first."
    exit 1
fi

echo "==> Preparing DMG staging directory at ${STAGE_DIR}..."
cp -R "${APP_BUNDLE}" "${STAGE_DIR}/QuickDictate.app"

echo "==> Creating /Applications symlink for drag-and-drop install..."
ln -s /Applications "${STAGE_DIR}/Applications"

cat << 'TXT' > "${STAGE_DIR}/QuickDictate Installation.txt"
QuickDictate v2.0.0
===================

To Install:
1. Drag the "QuickDictate" icon into the "Applications" folder.
2. Open QuickDictate from Launchpad or Finder > Applications.
3. The First-Launch Setup Wizard will guide you through granting
   Microphone and Accessibility permissions, saving your API key,
   and choosing your dictation shortcut.

Requirements:
- macOS Monterey (12.0) or later (Universal: Apple Silicon & Intel)
- Free Groq or OpenAI API key

Enjoy dictating!
TXT

echo "==> Building compressed DMG image with hdiutil..."
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "QuickDictate" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

echo "==> Verifying created DMG..."
hdiutil imageinfo "${DMG_PATH}" | grep -E "Format|Total Bytes|Partition" || true

echo "==> DMG created successfully at: ${DMG_PATH}"
