#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Apply this add-on to an existing, unmodified GestaltX v1.1.1 source checkout.
No network, build, signing, phone access, or device operations occur here.
"""
from pathlib import Path
import argparse
import shutil
import sys

UPSTREAM_COMMIT = "f34d5a7271c14e540edb58e328dc9c06f8f3368f"
FILES = ("GXCanvasAtomic.h", "GXCanvasAtomic.c", "GXCanvasLab.h", "GXCanvasLab.m", "GXCanvasLabView.swift")
EXPECTED_MAIN = '''//
//  GestaltXApp.swift
//  GestaltX
//

import SwiftUI

@main
struct GestaltXApp: App {
    init() {
        // Register the continued-processing launch handler early. It is only
        // ever *submitted* later, from an explicit pairing/capture action.
        DeviceConsoleBackgroundTask.shared.registerIfNeeded()
        // A reinstall can move the app's data container while the pairing
        // index keeps its old absolute path. Resolve it once at launch so
        // capture never opens a stale path.
        Task {
            let store = DevicePairingStore(directory: DeviceConsolePaths.pairing,
                                           device: DeviceConsolePaths.deviceIdentifier)
            _ = await store.currentPairingPath()
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\\.layoutDirection, Bundle.main.preferredLocalizations.first?.hasPrefix("fa") == true ? .rightToLeft : .leftToRight)
        }
    }
}
'''
IMPORT = '#import "CanvasLab/GXCanvasLab.h"'
MARKER = "// Canvas Lab 0.1: explicit user-driven experiment; no automatic display write."


def apply(root: Path, dry_run=False):
    root = root.resolve()
    overlay = Path(__file__).resolve().parent / "overlay"
    app = root / "GestaltX/GestaltXApp.swift"
    bridge = root / "GestaltX/GestaltX-Bridging-Header.h"
    project = root / "GestaltX.xcodeproj/project.pbxproj"
    destination = root / "GestaltX/CanvasLab"
    for file in [app, bridge, project, *(overlay / f for f in FILES)]:
        if not file.is_file() or file.is_symlink():
            raise ValueError(f"Required regular source file missing: {file}")
    original = app.read_text(encoding="utf-8")
    header = bridge.read_text(encoding="utf-8")
    pbx = project.read_text(encoding="utf-8")
    if MARKER in original:
        if IMPORT in header and all((destination/f).is_file() and
                                   (destination/f).read_bytes() == (overlay/f).read_bytes() for f in FILES):
            print("Canvas Lab patch is already applied and matches this kit.")
            return
        raise ValueError("Partially applied or different patch. Start from a fresh pinned checkout.")
    if original.rstrip("\n") != EXPECTED_MAIN.rstrip("\n"):
        raise ValueError("GestaltXApp.swift differs from the reviewed v1.1.1 source; refusing to guess.")
    if '#include "worse_query.h"' not in header or '#import "GXCustomizationAccess.h"' not in header:
        raise ValueError("Unexpected bridging header.")
    if "PBXFileSystemSynchronizedRootGroup" not in pbx or "path = GestaltX;" not in pbx:
        raise ValueError("Expected Xcode synchronized source group not found.")
    if destination.exists() or (root / ".canvaslab-original").exists():
        raise ValueError("Patch destination/backup already exists; refusing to overwrite.")
    replacement = original.replace("            ContentView()", "            GXCanvasLabView()")
    if replacement == original or replacement.count("GXCanvasLabView()") != 1:
        raise ValueError("App entry-point replacement is ambiguous.")
    replacement = MARKER + "\n" + replacement
    header = header.rstrip() + "\n\n" + IMPORT + "\n"
    if dry_run:
        print("Reviewed source anchors match; dry run made no changes.")
        return
    backup = root / ".canvaslab-original"
    backup.mkdir()
    shutil.copy2(app, backup / app.name)
    shutil.copy2(bridge, backup / bridge.name)
    shutil.copytree(overlay, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    app.write_text(replacement, encoding="utf-8")
    bridge.write_text(header, encoding="utf-8")
    print("Applied Canvas Lab source add-on. No IPA was built or signed by this script.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_checkout", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    try:
        apply(args.source_checkout, args.verify_only)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
