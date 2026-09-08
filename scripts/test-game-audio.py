#!/usr/bin/env python3
"""Opt-in per-bottle audio integration test; requires an idle owned bottle with default audio."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bottle', required=True, type=Path)
parser.add_argument('--device-uid', required=True, help='Connected Core Audio output UID to test')
args = parser.parse_args()
bottle = args.bottle.resolve(strict=True)
receipt = json.loads((bottle / '.bigscreen-game-owner.json').read_text())
assert receipt['bottle']['name'] == bottle.name
# This test must not overwrite a pre-existing output choice. No registry-file edits are used.
registry = (bottle / 'user.reg').read_text()
assert not re.search(r'^"(?:DefaultOutput|BigScreenOutput)"=', registry, re.M), 'Use a bottle with default audio'
root = Path(__file__).resolve().parent.parent
compiler = Path(os.environ.get('PLAYDEN_LLVM_ROOT', '/opt/homebrew/opt/llvm')) / 'bin/clang'
linker = Path(os.environ.get('PLAYDEN_LLD_ROOT', '/opt/homebrew/opt/lld')) / 'bin/lld-link'
def windows(path):
    return 'Z:' + str(path.resolve()).replace('/', '\\')
with tempfile.TemporaryDirectory(prefix='Playden-audio-test-') as temporary:
    work = Path(temporary)
    environment = os.environ | {'SRCROOT': str(root), 'DERIVED_FILE_DIR': str(work / 'build'),
        'TARGET_BUILD_DIR': str(work), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'resources'}
    environment.pop('PLAYDEN_AUDIO_DEVICE_UID', None)
    subprocess.run(['sh', str(root / 'scripts/embed-display-helper.sh')], env=environment, check=True)
    subprocess.run([str(compiler), '--target=x86_64-pc-windows-msvc', '-std=c11', '-Os',
        '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-c',
        str(root / 'Native/DisplayHelper/audio-fixture.c'), '-o', str(work / 'fixture.obj')], check=True)
    fixture = work / 'audio.exe'
    imports = work / 'build/DisplayHelper'
    subprocess.run([str(linker), '/nodefaultlib', '/entry:mainCRTStartup', '/subsystem:console',
        '/machine:x64', f'/out:{fixture}', str(work / 'fixture.obj'),
        *[str(imports / (lib + '.lib')) for lib in ['kernel32', 'ole32', 'advapi32']]], check=True)
    encoded = windows(fixture).encode('utf-16le')
    request = struct.pack('<6iII', 0, 0, 0, 0, 0, 0, 1, len(encoded) // 2) + encoded
    def run(uid=None):
        env = environment.copy()
        if uid is not None:
            env['PLAYDEN_AUDIO_DEVICE_UID'] = uid
        with tempfile.TemporaryFile() as input_file:
            input_file.write(request); input_file.seek(0)
            result = subprocess.run(['/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart',
                '--bottle', str(bottle), '--no-gui', '--no-convert', '--wait-children',
                windows(work / 'resources/PlaydenDisplay.exe')], env=env, stdin=input_file,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True, timeout=30)
        output = result.stdout.decode(errors='replace')
        print(output, end='', flush=True)
        return re.search(r'BSAUDIO=(.+)', output)[1].strip(), output
    baseline, _ = run()
    try:
        selected, output = run(args.device_uid)
        assert 'Preferred output selected' in output and 'BSMANAGED=1' in output
        fallback, output = run('Playden-nonexistent-test-output')
        assert 'Preferred output unavailable' in output and 'BSMANAGED=1' not in output
        assert fallback == baseline, (fallback, baseline)
        run(args.device_uid)
    finally:
        restored, output = run()
        assert restored == baseline and 'BSMANAGED=1' not in output
    print('Passed: child MMDevAPI output selection, missing-device fallback, and system-default restoration.')
