#!/usr/bin/env python3
"""Publish short-lived unreferenced Git blobs as a download bridge.

Some sandboxes cannot reach the Actions artifact CDN. The APK is public; the
optional signing backup is encrypted to the owner's public key first. No blob
is added to the branch or a release. Actions artifacts remain the primary copy.
"""
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = os.environ['GITHUB_REPOSITORY']
endpoint = f'repos/{repo}/git/blobs'


def blob(data):
    payload = json.dumps({'content': base64.b64encode(data).decode('ascii'), 'encoding': 'base64'})
    response = subprocess.run(['gh', 'api', '--method', 'POST', endpoint, '--input', '-'],
                              input=payload, text=True, capture_output=True, check=True)
    return json.loads(response.stdout)['sha']


apk = Path('artifacts/WorldFriends-1.0.0-universal.apk')
with tempfile.TemporaryDirectory() as temp:
    packed = Path(temp) / 'universal.apk.gz'
    with apk.open('rb') as source, gzip.open(packed, 'wb', compresslevel=6) as target:
        while chunk := source.read(1024 * 1024):
            target.write(chunk)
    chunks = []
    with packed.open('rb') as source:
        while chunk := source.read(5 * 1024 * 1024):
            chunks.append({'sha': blob(chunk), 'size': len(chunk)})
    backup = Path('/tmp/worldfriends-signing-backup.enc')
    verification = Path('artifacts/signature-verification.txt')
    manifest = {
        'format': 1,
        'apk_name': apk.name,
        'apk_size': apk.stat().st_size,
        'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'gzip_sha256': hashlib.sha256(packed.read_bytes()).hexdigest(),
        'chunks': chunks,
        'encrypted_signing_backup_blob': blob(backup.read_bytes()) if backup.exists() else None,
        'verification_blob': blob(verification.read_bytes()),
    }
    manifest_sha = blob(json.dumps(manifest).encode())
    print(f'::notice title=APK_TRANSFER_MANIFEST::{manifest_sha}', flush=True)
    print(f'Uploaded {len(chunks)} temporary transport chunks; Actions artifacts remain authoritative.', flush=True)
