#!/usr/bin/env python3
"""Exercise native storage with synthetic ZIPs; never opens user archives or the app."""
from pathlib import Path
import importlib.util
import json
import re
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="ClaudeViewer-tests-") as temporary:
    workspace = Path(temporary)
    for account in ("a", "b"):
        with zipfile.ZipFile(workspace / f"account-{account}.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("conversations.json", json.dumps([{"uuid": "shared-conversation-id", "name": f"Account {account}", "chat_messages": []}]))
            archive.writestr("users.json", json.dumps([{"email": f"{account}@example.invalid"}]))
    executable = workspace / "store-tests"
    subprocess.run(["xcrun", "swiftc", str(root / "macos/ArchiveStore.swift"),
                    str(root / "macos/tests/ArchiveStoreTests.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(workspace)], check=True)

spec = importlib.util.spec_from_file_location("macos_build", root / "macos/build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
original = (root / "claude_viewer.html").read_text(encoding="utf-8")
bundled = build.secure_html(original)
nonce = re.search(r"script-src 'nonce-([^']+)'", bundled).group(1)
assert "script-src-attr 'none'" in bundled
assert "connect-src claude-archive:" in bundled
assert "script-src 'unsafe-inline'" not in bundled
restored = bundled.replace(f' nonce="{nonce}"', "")
restored = re.sub(r'\n<meta http-equiv="Content-Security-Policy" content="[^"]*">', "", restored, count=1)
assert restored == original, "Build must not patch the viewer's application logic"
print("Native bundle: nonce CSP and otherwise byte-equivalent viewer passed.")
