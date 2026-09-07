#!/usr/bin/env python3
"""Optionally bundle the repository's viewer as a local macOS application.

Requires Python 3 and Apple's Command Line Tools; no package installs are needed.
The only transformation of the web viewer is a per-build script nonce and CSP.
"""

import argparse
from html.parser import HTMLParser
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shutil
import subprocess


class ScriptTags(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=False)
        self.lines = source.splitlines(keepends=True)
        self.offsets = []

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            line, column = self.getpos()
            self.offsets.append(sum(map(len, self.lines[:line - 1])) + column + len("<script"))


def secure_html(source):
    nonce = secrets.token_urlsafe(32)
    parser = ScriptTags(source)
    parser.feed(source)
    if not parser.offsets:
        raise ValueError("Viewer has no bundled scripts.")
    for offset in reversed(parser.offsets):
        source = source[:offset] + ' nonce="' + nonce + '"' + source[offset:]
    policy = (
        "default-src 'none'; "
        f"script-src 'nonce-{nonce}'; script-src-attr 'none'; "
        "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; "
        "connect-src claude-archive:; media-src data: blob:; "
        "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"
    )
    source, count = re.subn(r"<head\s*>", lambda match: match.group(0) +
                           '\n<meta http-equiv="Content-Security-Policy" content="' + policy + '">',
                           source, count=1, flags=re.IGNORECASE)
    if count != 1:
        raise ValueError("Viewer has no head element.")
    return source


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / "_release/ClaudeViewer.app",
                        help="New output .app path (existing bundles are never overwritten)")
    parser.add_argument("--bundle-id", default="cn.crownleo.ClaudeViewer",
                        help="Bundle identity; keep the same ID when upgrading to retain WebKit preferences")
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default="arm64" if platform.machine() == "arm64" else "x86_64")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Building the optional Mac app requires macOS.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.bundle_id):
        parser.error("--bundle-id must be a reverse-DNS identifier.")
    output = args.output.expanduser().resolve()
    if output.suffix != ".app":
        parser.error("--output must end in .app")
    if output.exists():
        parser.error("Choose a new output path; existing app bundles are not overwritten.")
    # Fail before creating output when the Apple compiler is unavailable.
    subprocess.run(["xcrun", "--find", "swiftc"], check=True, stdout=subprocess.DEVNULL)
    contents = output / "Contents"
    resources = contents / "Resources"
    resources.mkdir(parents=True)
    (contents / "MacOS").mkdir()
    (resources / "claude_viewer.html").write_text(secure_html((root / "claude_viewer.html").read_text(encoding="utf-8")), encoding="utf-8")
    shutil.copy2(root / "macos/AppIcon.icns", resources / "AppIcon.icns")
    # Include the preferred form for modification and its license in the bundle.
    source_dir = resources / "Source"
    source_dir.mkdir()
    for name in ["claude_viewer.html", "LICENSE", "README.md", "README.en.md"]:
        if (root / name).exists():
            shutil.copy2(root / name, source_dir / name)
    shutil.copytree(root / "docs", source_dir / "docs")
    shutil.copytree(root / "macos", source_dir / "macos", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    metadata = {
        "CFBundleName": "ClaudeViewer", "CFBundleDisplayName": "ClaudeViewer",
        "CFBundleIdentifier": args.bundle_id, "CFBundleExecutable": "ClaudeViewer",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "5.7.2", "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "12.0", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        "CFBundleIconFile": "AppIcon",
        "NSHumanReadableCopyright": "ClaudeViewer © crownleo and contributors. GPL-3.0.",
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "ZIP archive", "CFBundleTypeRole": "Viewer",
                                   "LSHandlerRank": "Alternate", "LSItemContentTypes": ["public.zip-archive"]}],
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
    subprocess.run(["xcrun", "swiftc", str(root / "macos/ArchiveStore.swift"), str(root / "macos/ClaudeViewer.swift"),
                    "-o", str(contents / "MacOS/ClaudeViewer"), "-target", f"{args.arch}-apple-macos12.0",
                    "-framework", "AppKit", "-framework", "WebKit", "-framework", "CryptoKit", "-O"], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", args.bundle_id, str(output)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
    print(output)


if __name__ == "__main__":
    main()
