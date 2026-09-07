#!/usr/bin/env python3
"""Exercise only uniquely named, probe-owned CrossOver bottles; never reuse a game bottle."""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

CROSSOVER = Path(os.environ.get("BIGSCREEN_CROSSOVER_PATH", "/Applications/CrossOver.app"))
BIN = CROSSOVER / "Contents/SharedSupport/CrossOver/bin"
ROOT = Path.home() / "Library/Application Support/CrossOver/Bottles"
TOKEN = uuid.uuid4().hex
NAMES = [f"gn-probe-{TOKEN}-template", f"gn-probe-{TOKEN}-game"]
MARKER = ".bigscreen-probe-owner.json"
OUTPUT = Path(__file__).resolve().parent.parent / ".build/crossover-probe" / TOKEN
OUTPUT.mkdir(parents=True)
results = []
created = []


def run(stage, tool, args, timeout=120, expect_success=True):
    start = time.monotonic()
    command = [str(BIN / tool), *args]
    log = OUTPUT / f"{stage}.log"
    timed_out = False
    with log.open("w") as output:
        try:
            process = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout, text=True)
        except subprocess.TimeoutExpired:
            timed_out = True
            process = subprocess.CompletedProcess(command, -1)
    process.stdout = log.read_text(errors="replace")
    result = {"stage": stage, "tool": tool, "arguments": args, "exitCode": None if timed_out else process.returncode,
              "timedOut": timed_out, "elapsedSeconds": round(time.monotonic() - start, 3)}
    results.append(result)
    print(json.dumps(result), flush=True)
    if timed_out:
        raise RuntimeError(f"{stage} did not exit within {timeout}s; see {log}")
    if expect_success and process.returncode:
        raise RuntimeError(f"{stage} failed; see {OUTPUT / (stage + '.log')}")
    return process


def make(name, args, stage):
    path = ROOT / name
    if path.exists() or path.is_symlink():
        raise RuntimeError("Refusing to use an existing bottle")
    # Remember ownership before the command so even a partial creation can be cleaned up.
    created.append(name)
    try:
        return run(stage, "cxbottle", ["--bottle", name, *args])
    finally:
        if path.is_dir() and not path.is_symlink() and path.resolve().parent == ROOT.resolve():
            (path / MARKER).write_text(json.dumps({"token": TOKEN, "bottle": name}))


def verify_owned(name):
    path = ROOT / name
    if name not in created or not name.startswith(f"gn-probe-{TOKEN}-") or path.is_symlink():
        raise RuntimeError("Bottle ownership check failed")
    if path.resolve().parent != ROOT.resolve():
        raise RuntimeError("Bottle escaped the private root")
    owner = json.loads((path / MARKER).read_text())
    if owner != {"token": TOKEN, "bottle": name}:
        raise RuntimeError("Bottle marker does not match this probe")


try:
    make(NAMES[0], ["--create", "--template", "win10_64", "--param", "EnvironmentVariables:WINEMSYNC=1",
                   "--param", "EnvironmentVariables:CX_GRAPHICS_BACKEND=d3dmetal"], "create")
    config = (ROOT / NAMES[0] / "cxbottle.conf").read_text()
    # Save only the requested engine settings, not host/user-dependent configuration.
    settings = [line.strip() for line in config.splitlines() if "WINEMSYNC" in line or "CX_GRAPHICS_BACKEND" in line]
    if not any('"WINEMSYNC" = "1"' in line for line in settings) or not any('"CX_GRAPHICS_BACKEND" = "d3dmetal"' in line for line in settings):
        raise RuntimeError(f"Requested engine settings were not applied: {settings}")
    (OUTPUT / "engine-settings.json").write_text(json.dumps(settings, indent=2))
    make(NAMES[1], ["--copy", NAMES[0]], "clone")
    result = run("command", "cxstart", ["--bottle", NAMES[1], "--no-gui", "--wait-children", "cmd.exe", "/c", "echo BIGSCREEN_PROBE_OK"])
    if "BIGSCREEN_PROBE_OK" not in result.stdout:
        raise RuntimeError("Windows command did not produce its expected output")
    missing = run("missing-exe", "cxstart", ["--bottle", NAMES[1], "--no-gui", "--wait-children", "Z:\\bigscreen-no-such-file.exe"], timeout=15, expect_success=False)
    if missing.returncode == 0:
        raise RuntimeError("Missing executable incorrectly reported success")
finally:
    cleanup_failures = []
    for name in reversed(created):
        if not (ROOT / name).exists():
            continue
        try:
            verify_owned(name)
            run("delete-" + name.rsplit("-", 1)[-1], "cxbottle", ["--bottle", name, "--delete", "--force"])
            if (ROOT / name).exists():
                raise RuntimeError("Bottle directory remains after deletion")
        except Exception as error:
            cleanup_failures.append(str(error))
    (OUTPUT / "results.json").write_text(json.dumps({"probeID": TOKEN, "results": results, "cleanupFailures": cleanup_failures}, indent=2))
    print(f"Evidence: {OUTPUT}", flush=True)
    if cleanup_failures:
        raise RuntimeError("Probe cleanup failed: " + "; ".join(cleanup_failures))
