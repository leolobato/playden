#!/usr/bin/env python3
"""Pick a stable, existing local development identity; never create or import certificates."""
import os
import json
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import ssl

override = os.environ.get("PLAYDEN_CODE_SIGN_IDENTITY")
if override == "-":
    print(override)
    sys.exit(0)

root = Path(__file__).resolve().parent.parent
configuration = sys.argv[1] if len(sys.argv) > 1 else "Debug"
derived_data = sys.argv[2] if len(sys.argv) > 2 else "DerivedData"
settings = subprocess.run(["xcodebuild", "-project", "Playden.xcodeproj", "-scheme", "Playden",
                           "-configuration", configuration, "-derivedDataPath", derived_data,
                           "-showBuildSettings", "-json"], cwd=root, check=True, capture_output=True, text=True)
app_settings = next(item["buildSettings"] for item in json.loads(settings.stdout) if item["target"] == "Playden")
team = app_settings.get("DEVELOPMENT_TEAM", "").strip()
cache = root / ".build" / "signing-identity"
result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                        check=True, capture_output=True, text=True)
identities = re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', result.stdout)


def matches_team(digest, name):
    if not team:
        return True
    # An Apple Development common name ends in a person ID, which need not be the
    # signing team. Match the identity's certificate by fingerprint and read its OU.
    certificates = subprocess.run(["security", "find-certificate", "-a", "-c", name, "-p"],
                                  check=True, capture_output=True, text=True)
    for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates.stdout, re.S):
        der = ssl.PEM_cert_to_DER_cert(pem)
        if hashlib.sha1(der).hexdigest().upper() != digest:
            continue
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject", "-nameopt", "sep_multiline"],
                                 input=pem, check=True, capture_output=True, text=True)
        match = re.search(r"^\s*OU\s*=\s*(\S+)\s*$", subject.stdout, re.M)
        return match is not None and match[1] == team
    return False


if override:
    matches = [(digest, name) for digest, name in identities if override in (digest, name)]
    if len(matches) != 1 or not matches_team(*matches[0]):
        sys.exit("The selected signing certificate is missing, ambiguous, or does not match DEVELOPMENT_TEAM in your xcconfig.")
    print(matches[0][0])
    sys.exit(0)
development = sorted((name, digest) for digest, name in identities
                     if name.startswith("Apple Development:") and matches_team(digest, name))
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
    if team:
        sys.exit(f"No Apple Development certificate found for DEVELOPMENT_TEAM {team}. Install one, or explicitly use PLAYDEN_CODE_SIGN_IDENTITY=- for a local ad-hoc build.")
    print("No Apple Development certificate found; using ad-hoc signing. Keychain may ask for approval after rebuilds.", file=sys.stderr)
    print("-")
