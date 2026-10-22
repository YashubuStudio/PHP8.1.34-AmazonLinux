#!/usr/bin/env python3
"""Package a verified local build for the repository's release upload workflow.

Only prepares files below the specified output directory. Git push and release
publication are separate, explicit operations. Original build files are kept.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ARCHIVE = 'php81-rpms-8.1.34-cve20261021.1.tar.gz'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def identity(path):
    return {'name': path.name, 'size': path.stat().st_size, 'sha256': sha256(path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--validation', required=True, type=Path)
    parser.add_argument('--runtime-report', required=True, type=Path)
    parser.add_argument('--notes', required=True, type=Path)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.archive.name != ARCHIVE or not re.fullmatch(r'[0-9a-f]{40}', args.source_commit):
        raise SystemExit('Expected the exact archive name and a full source commit SHA')
    for path in (args.archive, args.validation, args.runtime_report, args.notes):
        if not path.is_file() or path.is_symlink():
            raise SystemExit('Missing or symlinked source file: ' + str(path))
    if json.loads(args.runtime_report.read_text()).get('status') != 'passed':
        raise SystemExit('Runtime validation did not pass')
    args.output.mkdir(parents=True, exist_ok=False)
    parts = []
    with args.archive.open('rb') as stream:
        index = 0
        while True:
            block = stream.read(25 * 1024 * 1024)
            if not block:
                break
            part = args.output / ('archive-part-{:04d}'.format(index))
            with part.open('xb') as destination:
                destination.write(block)
            parts.append(identity(part))
            index += 1
    digest = sha256(args.archive)
    (args.output / (ARCHIVE + '.sha256')).write_text(digest + '  ' + ARCHIVE + '\n', encoding='ascii')
    for source, name in ((args.validation, 'VALIDATION-ja.md'),
                         (args.runtime_report, 'runtime-validation.json'), (args.notes, 'RELEASE-NOTES-ja.txt')):
        shutil.copyfile(source, args.output / name)
    manifest = {'repository': 'YashubuStudio/PHP8.1.34-AmazonLinux',
                'tag': 'php81-8.1.34-cve20261021.1', 'source_commit': args.source_commit,
                'archive': ARCHIVE, 'archive_sha256': digest, 'parts': parts,
                'notes_sha256': sha256(args.output / 'RELEASE-NOTES-ja.txt'),
                'files': [identity(args.output / name) for name in
                          (ARCHIVE + '.sha256', 'VALIDATION-ja.md', 'runtime-validation.json')]}
    manifest_path = args.output / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    subprocess.run([sys.executable, str(Path(__file__).with_name('publish-release.py')),
                    str(manifest_path), '--verify-only'], check=True)
    print('Verified release payload prepared: ' + str(args.output))


if __name__ == '__main__':
    main()
