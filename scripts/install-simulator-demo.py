#!/usr/bin/env python3
"""Install the verified release Demo on a user-specified iOS simulator."""
import argparse
import hashlib
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True, help='UDID of your dedicated, already booted simulator')
args = parser.parse_args()
root = Path(__file__).resolve().parent
manifest = json.loads((root / 'build-manifest.json').read_text())
archive = root / 'Runner.tar.gz'
if hashlib.sha256(archive.read_bytes()).hexdigest() != manifest['sha256']:
    raise SystemExit('Demo archive checksum mismatch')
with tempfile.TemporaryDirectory(prefix='ocean-demo-install-') as name:
    destination = Path(name)
    with tarfile.open(archive, 'r:gz') as bundle:
        bundle.extractall(destination, filter='data')
    application = destination / 'Runner.app'
    actual = {str(p.relative_to(application)) for p in application.rglob('*') if p.is_file()}
    expected = {f['path'] for f in manifest['files']}
    if actual != expected:
        raise SystemExit('Demo bundle member mismatch')
    for f in manifest['files']:
        payload = (application / f['path']).read_bytes()
        if len(payload) != f['bytes'] or hashlib.sha256(payload).hexdigest() != f['sha256']:
            raise SystemExit('Demo bundle checksum mismatch: ' + f['path'])
    subprocess.run(['xcrun', 'simctl', 'install', args.device, str(application)], check=True)
    subprocess.run(['xcrun', 'simctl', 'launch', args.device, 'dev.oceandelivery.oceanDelivery'], check=True)
print('Installed and launched formal Demo; simulated confirmations, arm64 simulator debug, not production signed.')
