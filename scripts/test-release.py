#!/usr/bin/env python3
"""Exercise release scripts with fake Apple services; no credentials, builds, or UI required."""
import json
import hashlib
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
IDENTITY = "Developer ID Application: Release Test (TESTTEAM)"
STUB = r'''#!/usr/bin/env python3
import base64, hashlib, json, os, pathlib, plistlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["RELEASE_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
failure = os.environ.get("RELEASE_TEST_FAILURE", "")
if name == "security":
    if args[0] == "find-certificate":
        certificate = b"release-test" if "Developer ID" in args[args.index("-c") + 1] else b"development-test"
        print("-----BEGIN CERTIFICATE-----\n" + base64.b64encode(certificate).decode() + "\n-----END CERTIFICATE-----")
    else:
        print('  1) ' + hashlib.sha1(b"release-test").hexdigest().upper() + ' "Developer ID Application: Release Test (TESTTEAM)"')
        print('  2) ' + hashlib.sha1(b"development-test").hexdigest().upper() + ' "Apple Development: Release Test (PERSONID)"')
elif name == "openssl":
    print("subject=\n    OU=TESTTEAM\n")
elif name == "xcodebuild":
    if "-showBuildSettings" in args:
        print(json.dumps([{"target": "Playden", "buildSettings": {"DEVELOPMENT_TEAM": os.environ.get("RELEASE_TEST_TEAM", "")}}]))
        sys.exit(0)
    output = pathlib.Path(args[args.index("-derivedDataPath") + 1])
    config = args[args.index("-configuration") + 1]
    app = output / "Build/Products" / config / "Playden.app"
    (app / "Contents/Frameworks").mkdir(parents=True, exist_ok=True)
    (app / "Contents/Frameworks/libtest.dylib").write_text("library")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.release-test.playden"}))
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        label = "dmg" if args[2].endswith(".dmg") else "app"
        rejected = failure == label + "-rejected"
        print(json.dumps({"id": label, "status": "Invalid" if rejected else "Accepted"}))
        if rejected:
            sys.exit(1)  # Apple can return a nonzero exit alongside a useful result.
    elif args[:2] == ["notarytool", "log"]:
        pathlib.Path(args[-1]).write_text(json.dumps({"id": args[2]}))
    elif args[:2] == ["stapler", "staple"] and args[-1].endswith(".app"):
        (pathlib.Path(args[-1]) / "test-ticket").touch()
elif name == "hdiutil" and args[0] == "create":
    payload = pathlib.Path(args[args.index("-srcfolder") + 1])
    assert (payload / "Applications").is_symlink()
    assert os.readlink(payload / "Applications") == "/Applications"
    assert (payload / "Playden.app/test-ticket").exists()
    pathlib.Path(args[-1]).write_text("verified test image")
elif name == "spctl" and failure == "gatekeeper":
    sys.exit(1)
elif name == "codesign" and "--force" in args and failure == "signing":
    sys.exit(1)
'''


class ReleaseScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="Playden release test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("build.sh", "build-release.sh", "distribute.sh", "signing-identity.py"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        (self.root / "Config").mkdir()
        shutil.copy2(ROOT / "Config/Playden.entitlements", self.root / "Config/Playden.entitlements")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("security", "openssl", "xcodegen", "xcodebuild", "codesign", "xcrun", "hdiutil", "spctl", "open"):
            path = bin_dir / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("PLAYDEN_")}
        self.env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", RELEASE_TEST_ROOT=str(self.root),
                        PLAYDEN_DEVELOPER_ID=IDENTITY, PLAYDEN_NOTARY_PROFILE="test-profile",
                        PLAYDEN_CODE_SIGN_IDENTITY="-")
        self.output = self.root / "dist/Playden-0.1-1-arm64.dmg"

    def run_script(self, script="distribute.sh", args=("0.1", "1")):
        return subprocess.run(["/bin/zsh", str(self.root / "scripts" / script), *args],
                              cwd="/", env=self.env, capture_output=True, text=True)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_local_build_reveals_release_and_can_suppress_finder(self):
        result = self.run_script("build-release.sh", ())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[0] == "open" and "/Release/Playden.app" in call[-1]
                            for call in self.calls()))
        (self.root / "calls.jsonl").unlink()
        result = self.run_script("build-release.sh", ("--no-open",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == "open" for call in self.calls()))

    def test_distribution_with_profile_and_api_key(self):
        for auth in ("profile", "api"):
            with self.subTest(auth=auth):
                if auth == "api":
                    del self.env["PLAYDEN_NOTARY_PROFILE"]
                    key = self.root / "test-key.p8"
                    key.touch()
                    self.env.update(PLAYDEN_NOTARY_KEY_PATH=str(key),
                                    PLAYDEN_NOTARY_KEY_ID="test-key", PLAYDEN_NOTARY_ISSUER_ID="test-issuer")
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.output.read_text(), "verified test image")
                submits = [call for call in self.calls() if call[:3] == ["xcrun", "notarytool", "submit"]]
                self.assertEqual(len(submits), 2)
                self.assertTrue(all(("--keychain-profile" if auth == "profile" else "--key") in call for call in submits))
                self.assertTrue(any("org.release-test.playden.dmg" in call for call in self.calls()))
                app_signing = next(call for call in self.calls()
                                   if call[0] == "codesign" and "--force" in call and call[-1].endswith(".app"))
                self.assertIn("--entitlements", app_signing)
                entitlements = self.root / app_signing[app_signing.index("--entitlements") + 1]
                with entitlements.open("rb") as source:
                    self.assertTrue(plistlib.load(source)["com.apple.security.device.audio-input"])
                self.assertFalse(list((self.root / "dist").glob(".distribution.*")))
                (self.root / "calls.jsonl").unlink()

    def test_distribution_also_accepts_three_component_versions(self):
        result = self.run_script(args=("0.1.1", "2"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "dist/Playden-0.1.1-2-arm64.dmg").exists())

    def test_failures_preserve_existing_artifact_and_clean_staging(self):
        self.output.parent.mkdir()
        self.output.write_text("previous release")
        for failure in ("app-rejected", "dmg-rejected", "signing", "gatekeeper"):
            with self.subTest(failure=failure):
                self.env["RELEASE_TEST_FAILURE"] = failure
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_text(), "previous release")
                self.assertFalse(list((self.root / "dist").glob(".distribution.*")))
                if failure.endswith("-rejected"):
                    label = failure.split("-")[0]
                    self.assertTrue(list((self.root / ".build/distribution").glob(f"notarization.*/{label}-log.json")))

    def test_missing_credentials_invalid_version_and_development_identity_fail_before_build(self):
        for setting, value in (("PLAYDEN_NOTARY_PROFILE", ""),
                               ("PLAYDEN_DEVELOPER_ID", "Apple Development: Test")):
            original = self.env[setting]
            self.env[setting] = value
            self.assertNotEqual(self.run_script().returncode, 0)
            self.env[setting] = original
        self.assertNotEqual(self.run_script(args=("../bad", "1")).returncode, 0)
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls()))

    def test_signing_respects_resolved_xcconfig_team(self):
        del self.env["PLAYDEN_CODE_SIGN_IDENTITY"]
        self.env["RELEASE_TEST_TEAM"] = "TESTTEAM"
        result = subprocess.run(
            ["python3", str(self.root / "scripts/signing-identity.py")], env=self.env,
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), hashlib.sha1(b"development-test").hexdigest().upper())
        self.env["RELEASE_TEST_TEAM"] = "WRONGTEAM"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
