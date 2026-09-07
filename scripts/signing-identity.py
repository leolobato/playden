#!/usr/bin/env python3
"""Pick a stable, existing local development identity; never create or import certificates."""
import os
from pathlib import Path
import re
import subprocess
import sys

override = os.environ.get("BIGSCREEN_CODE_SIGN_IDENTITY")
if override:
    print(override)
    sys.exit(0)

root = Path(__file__).resolve().parent.parent
cache = root / ".build" / "signing-identity"
result = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                        check=True, capture_output=True, text=True)
identities = re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', result.stdout)
development = sorted((name, digest) for digest, name in identities if name.startswith("Apple Development:"))
available = {digest for _, digest in development}
saved = cache.read_text().strip() if cache.exists() else None
if saved in available:
    print(saved)
elif development:
    chosen = development[0][1]
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(chosen + "\n")
    print(chosen)
else:
    print("No Apple Development certificate found; using ad-hoc signing. Keychain may ask for approval after rebuilds.", file=sys.stderr)
    print("-")
