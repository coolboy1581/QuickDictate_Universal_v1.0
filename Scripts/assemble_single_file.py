#!/usr/bin/env python3
"""
Assembles the modular Swift files under Sources/QuickDictate/ into a single
consolidated QuickDictate.swift at the repository root so developers who prefer
single-file compilation (`swiftc QuickDictate.swift`) can still build it directly.
"""
from pathlib import Path

MODULE_ORDER = [
    "Models.swift",
    "KeychainCredentialManager.swift",
    "AudioSessionManager.swift",
    "TranscriptionClient.swift",
    "KeyboardShortcutMonitor.swift",
    "TextInsertionManager.swift",
    "SnippetManager.swift",
    "PreferencesAndHUD.swift",
    "OnboardingWindowController.swift",
    "SettingsWindowController.swift",
    "DictationCoordinator.swift",
    "AppDelegate.swift",
    "main.swift",
]

def main() -> None:
    root = Path(__file__).resolve().parent.parent
    src_dir = root / "Sources" / "QuickDictate"
    out_path = root / "QuickDictate.swift"

    imports = [
        "import Cocoa",
        "import Foundation",
        "import AVFoundation",
        "import Security",
        "import ApplicationServices",
        "import ServiceManagement",
        "import Carbon",
    ]

    body_chunks = []
    for filename in MODULE_ORDER:
        file_path = src_dir / filename
        lines = file_path.read_text(encoding="utf-8").splitlines()
        filtered = [
            line for line in lines
            if not line.strip().startswith("import ")
        ]
        body_chunks.append(f"// ============================================================================\n// FILE: {filename}\n// ============================================================================\n" + "\n".join(filtered).strip())

    header = (
        "// QuickDictate.swift — Consolidated Single-File Source (v2.0.0)\n"
        "// Generated from modular sources in Sources/QuickDictate/\n"
        "// Target: macOS 12.0+ (Universal 2: arm64 + x86_64)\n\n"
        + "\n".join(imports)
        + "\n\n"
    )

    out_path.write_text(header + "\n\n".join(body_chunks) + "\n", encoding="utf-8")
    print(f"Wrote consolidated {out_path} ({out_path.stat().st_size} bytes)")

if __name__ == "__main__":
    main()
