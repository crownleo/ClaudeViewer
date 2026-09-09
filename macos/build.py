#!/usr/bin/env python3
"""Optionally bundle the repository's viewer as a local macOS application.

Requires Python 3 and Apple's Command Line Tools; no package installs are needed.
The unchanged upstream viewer is adapted only inside the generated App bundle.
"""

import argparse
import hashlib
import importlib.util
from html.parser import HTMLParser
from pathlib import Path
import platform
import plistlib
import re
import secrets
import shutil
import subprocess

# Compatibility is verified against the released upstream file, not any file
# that happens to contain similarly named functions. Updating this pin requires
# rerunning the native and WebKit integration checks.
VIEWER_SHA256 = "cf82967a1e2d4840b373390bddd2886e414b19101a4e3c57c41b3d04ef34bf7b"


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
    # Replace the upstream CSP instead of stacking two policies: the upstream
    # connect-src 'none' would otherwise block our read-only archive URL scheme.
    source, policy_count = re.subn(r'<meta\s+http-equiv="Content-Security-Policy"\s+content="[^"]*"\s*/?>', '', source, flags=re.IGNORECASE)
    if policy_count != 1:
        raise ValueError("Expected exactly one upstream CSP; review the viewer before rebuilding.")
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


def bundled_html(source):
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != VIEWER_SHA256:
        raise ValueError("The Mac adapter targets upstream v6.0. Review and test adapter compatibility before updating VIEWER_SHA256.")
    path = Path(__file__).with_name("adapter.py")
    spec = importlib.util.spec_from_file_location("claudeviewer_mac_adapter", path)
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
    return secure_html(adapter.inject_native_adapter(source))


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
    if any(directory == output or directory in output.parents for directory in (root / "macos", root / "docs")):
        parser.error("--output must be outside macos/ and docs/ to avoid copying a build into its own source.")
    if output.exists():
        parser.error("Choose a new output path; existing app bundles are not overwritten.")
    # Fail before creating output when the Apple compiler is unavailable.
    subprocess.run(["xcrun", "--find", "swiftc"], check=True, stdout=subprocess.DEVNULL)
    upstream = (root / "claude_viewer.html").read_text(encoding="utf-8")
    version_match = re.search(r"const APP_VERSION='v([0-9]+(?:\.[0-9]+)*)';", upstream)
    if not version_match:
        raise ValueError("Cannot find upstream APP_VERSION.")
    page = bundled_html(upstream)
    contents = output / "Contents"
    resources = contents / "Resources"
    resources.mkdir(parents=True)
    (contents / "MacOS").mkdir()
    (resources / "claude_viewer.html").write_text(page, encoding="utf-8")
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
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version_match.group(1), "CFBundleVersion": "3",
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
