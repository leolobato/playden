#!/usr/bin/env python3
"""Reproduce the pinned, unmodified Steamless release resources; no latest-release lookup."""
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

VERSION = "3.1.0.5"
COMMIT = "cd770bf9749d3e4f438d23ac643917ad1a804257"
ARCHIVE_SHA256 = "e3e2d22e098ff3fb359b2876aa2bed9596f0501e6ff588cbffae90a76d2dc4f5"
MANIFEST_SHA256 = "817b6edd5c8adaba777eb4d1a4f88ccbe01a5460bd3919260ba6327ebd6fbdef"
root = Path(__file__).resolve().parents[1] / "Packages/BigScreenKit/Sources/Sources/Resources/Steamless"
url = f"https://github.com/atom0s/Steamless/releases/download/v{VERSION}/Steamless.v{VERSION}.-.by.atom0s.zip"
archive = urllib.request.urlopen(url, timeout=30).read()
assert hashlib.sha256(archive).hexdigest() == ARCHIVE_SHA256, "Release archive changed"
with zipfile.ZipFile(io.BytesIO(archive)) as release:
    content = {}
    for entry in release.infolist():
        path = Path(entry.filename)
        assert not path.is_absolute() and ".." not in path.parts and "\\" not in entry.filename
        if not entry.is_dir():
            content[path.as_posix()] = release.read(entry)
content["LICENSE"] = urllib.request.urlopen(
    f"https://raw.githubusercontent.com/atom0s/Steamless/{COMMIT}/LICENSE", timeout=30).read()
checksums = {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}
manifest = json.dumps(checksums, sort_keys=True, indent=2).encode()
assert hashlib.sha256(manifest).hexdigest() == MANIFEST_SHA256, "Pinned resource inventory changed"
content["checksums.json"] = manifest
for name, data in content.items():
    target = root / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
print(f"Verified Steamless {VERSION}: {len(checksums)} files")
