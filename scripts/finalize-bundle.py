#!/usr/bin/env python3
"""Add actual runtime evidence to a copy of a completed build bundle.

Original expanded bundles and original delivery archives are never changed.
The final archive is created in a new output directory, then re-verified using
the same full verification required by the release publisher.
"""
import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile

BUNDLE = 'php81-rpms-8.1.34-cve20261021.1'
KIT = Path(__file__).resolve().parents[1]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def verify_tree(root):
    for path in root.rglob('*'):
        require(not path.is_symlink() and (path.is_dir() or path.is_file()), 'Unexpected link/special file: ' + str(path))
    entries = {}
    for line in (root / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
        require(match is not None, 'Invalid bundle checksum manifest')
        digest, name = match.groups()
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and '..' not in relative.parts and name not in entries, 'Unsafe or duplicate checksum path')
        path = root / name
        require(path.is_file() and sha256(path) == digest, 'Bundle file checksum mismatch: ' + name)
        entries[name] = digest
    actual = {path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_file()}
    require(actual == set(entries) | {'SHA256SUMS'}, 'Original bundle contains unhashed files')
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--runtime-results', required=True, type=Path)
    parser.add_argument('--build-run-logs', required=True, type=Path)
    parser.add_argument('--validation', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(args.bundle.name == BUNDLE, 'Unexpected bundle directory name')
    original = verify_tree(args.bundle)
    report = json.loads((args.runtime_results / 'runtime-validation.json').read_text())
    require(report['status'] == 'passed', 'Runtime validation did not pass')
    require(set(report['harness_sha256']) == {'validate-local.sh', 'tests/container-runtime.sh',
            'tests/http-runtime.py', 'tests/runtime.php'}, 'Unexpected runtime harness file set')
    for name, digest in report['rpm_sha256'].items():
        require(original.get(name) == digest, 'Runtime report identifies a different RPM: ' + name)
    require(len(report['rpm_sha256']) == 16, 'Runtime report must cover the new and rollback RPMs')
    for name, digest in report['harness_sha256'].items():
        require(sha256(KIT / name) == digest, 'Runtime harness changed after validation: ' + name)
    build_validation = (args.bundle / 'logs/VALIDATION.txt').read_text()
    require('rpmbuild -ba: completed successfully' in build_validation, 'Missing successful RPM build validation')
    build_log = (args.bundle / 'logs/rpmbuild.log').read_text(errors='replace')
    failures = re.findall(r'^Tests failed\s*:\s*(\d+)', build_log, re.M)
    require(failures and all(int(count) == 0 for count in failures), 'PHP test suite failure or missing summary')
    require('LOCAL BUILD COMPLETED' in (args.build_run_logs / 'console.log').read_text(errors='replace'),
            'Local Docker build did not report completion')
    args.output.mkdir(parents=True, exist_ok=False)
    destination = args.output / BUNDLE
    shutil.copytree(args.bundle, destination)
    shutil.copytree(args.runtime_results, destination / 'logs/runtime')
    for name in ('environment.txt', 'console.log'):
        shutil.copy2(args.build_run_logs / name, destination / 'logs' / ('local-' + name))
    for name in ('early-phpt.log', 'early-compiled-cli-validation.log', 'early-shared-extension-validation.log'):
        path = args.build_run_logs / name
        if path.is_file():
            shutil.copy2(path, destination / 'logs' / name)
    for name in ('README-ja.md', 'README.html', 'TEST-CHANGES-ja.md'):
        shutil.copy2(KIT / name, destination / name)
    shutil.copy2(args.validation, destination / 'VALIDATION-ja.md')
    validation_sources = destination / 'sources/validation'
    (validation_sources / 'tests').mkdir(parents=True)
    for name in report['harness_sha256']:
        shutil.copy2(KIT / name, validation_sources / name)
    entries = []
    for path in sorted(destination.rglob('*')):
        require(not path.is_symlink(), 'Unexpected symlink in final bundle')
        if path.is_file() and path != destination / 'SHA256SUMS':
            entries.append(sha256(path) + '  ' + path.relative_to(destination).as_posix() + '\n')
    (destination / 'SHA256SUMS').write_text(''.join(entries))
    verify_tree(destination)
    archive_path = args.output / (BUNDLE + '.tar.gz')

    def metadata(member):
        member.uid = member.gid = 0
        member.uname = member.gname = 'root'
        return member

    with archive_path.open('xb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
                archive.add(destination, arcname=BUNDLE, filter=metadata)
    checksum = archive_path.with_name(archive_path.name + '.sha256')
    checksum.write_text(sha256(archive_path) + '  ' + archive_path.name + '\n')
    specification = importlib.util.spec_from_file_location('release_publisher', KIT / 'scripts/publish-release.py')
    publisher = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(publisher)
    publisher.verify_archive(archive_path, report)
    print('Final, fully verified archive: ' + str(archive_path))
    print('SHA-256: ' + sha256(archive_path))


if __name__ == '__main__':
    main()
