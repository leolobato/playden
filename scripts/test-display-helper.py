#!/usr/bin/env python3
"""Opt-in Windows placement/argument/exit tests. Requires an idle, Playden-owned bottle."""
import argparse
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bottle', type=Path, required=True)
options = parser.parse_args()
bottle = options.bottle.resolve(strict=True)
receipt = json.loads((bottle / '.bigscreen-game-owner.json').read_text())
assert receipt['bottle']['name'] == bottle.name, 'Expected a Playden-owned bottle'
root = Path(__file__).resolve().parent.parent
compiler = Path(os.environ.get('PLAYDEN_LLVM_ROOT', '/opt/homebrew/opt/llvm')) / 'bin/clang'
linker = Path(os.environ.get('PLAYDEN_LLD_ROOT', '/opt/homebrew/opt/lld')) / 'bin/lld-link'

def windows(path):
    return 'Z:' + str(path.resolve()).replace('/', '\\')

with tempfile.TemporaryDirectory(prefix='Playden-display-test-') as temporary:
    work = Path(temporary)
    environment = os.environ | {'SRCROOT': str(root), 'DERIVED_FILE_DIR': str(work / 'build'),
                                'TARGET_BUILD_DIR': str(work), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'resources'}
    subprocess.run(['sh', str(root / 'scripts/embed-display-helper.sh')], env=environment, check=True)
    subprocess.run([str(compiler), '--target=x86_64-pc-windows-msvc', '-Os', '-ffreestanding', '-fno-builtin',
                    '-fno-stack-protector', '-I', str(root / 'Native/DisplayHelper'), '-c',
                    str(root / 'Native/DisplayHelper/argument-fixture.c'), '-o', str(work / 'fixture.obj')], check=True)
    fixture = work / 'Unicode 🎮 game.exe'
    imports = work / 'build/DisplayHelper'
    subprocess.run([str(linker), '/nodefaultlib', '/entry:mainCRTStartup', '/subsystem:console', '/machine:x64',
                    '/timestamp:0', f'/out:{fixture}', str(work / 'fixture.obj'), str(imports / 'kernel32.lib'),
                    str(imports / 'shell32.lib')], check=True)
    expected = ['Unicode 🎮', '', 'quoted "value"', 'trailing\\', 'space and trailing\\', '$(touch bad)', '--bottle', 'other']
    arguments = [windows(fixture), *expected]
    # Impossible display geometry also exercises the helper's missing-monitor fallback.
    request = struct.pack('<6iI', -12345, -12345, 800, 600, 1920, 1080, len(arguments))
    for value in arguments:
        encoded = value.encode('utf-16le')
        request += struct.pack('<I', len(encoded) // 2) + encoded
    # Match the app: an unlinked file descriptor, not a command-line argument or a saved file.
    with tempfile.TemporaryFile() as input_file, tempfile.TemporaryFile() as output_file:
        input_file.write(request); input_file.seek(0)
        process = subprocess.Popen(['/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart',
            '--bottle', str(bottle), '--no-gui', '--no-convert', '--wait-children',
            windows(work / 'resources/PlaydenDisplay.exe')], stdin=input_file,
            stdout=output_file, stderr=output_file, start_new_session=True)
        try:
            code = process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
            raise
        output_file.seek(0); output = output_file.read()
    cursor = output.index(b'BSCARGS') + 7
    count = struct.unpack_from('<I', output, cursor)[0]; cursor += 4
    received = []
    for _ in range(count):
        size = struct.unpack_from('<I', output, cursor)[0]; cursor += 4
        received.append(output[cursor:cursor + size * 2].decode('utf-16le')); cursor += size * 2
    assert received[1:] == expected, (received[1:], expected)
    assert code == 37, f'Child exit code was lost: {code}'
    assert b'Preferred display unavailable' in output, 'Missing display did not use the fallback'
    print('Passed: exact Windows arguments, child exit status, and disconnected-display fallback.')
    # Mock only the placement boundary inside the real helper, using virtual 100 ms polls.
    # This exercises cold starts without opening windows or waiting in real time.
    subprocess.run([str(compiler), '--target=x86_64-pc-windows-msvc', '-std=c11', '-Os',
                    '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-builtin',
                    '-fno-stack-protector', '-c', str(root / 'Native/DisplayHelper/placement-fixture.c'),
                    '-o', str(work / 'placement.obj')], check=True)
    placement = work / 'placement.exe'
    subprocess.run([str(linker), '/nodefaultlib', '/entry:mainCRTStartup', '/subsystem:console',
                    '/machine:x64', '/timestamp:0', f'/out:{placement}', str(work / 'placement.obj'),
                    str(imports / 'kernel32.lib'), str(imports / 'user32.lib'),
                    str(imports / 'shell32.lib'), str(imports / 'ole32.lib'),
                    str(imports / 'advapi32.lib')], check=True)
    subprocess.run(['/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart',
                    '--bottle', str(bottle), '--no-gui', '--no-convert', '--wait-children',
                    windows(placement)], check=True, timeout=20)
