#!/usr/bin/env python3
"""Reuse this build's verified objects while running normal RPM build stages.

No RPM stage or test is disabled. This helper only restores a cache produced
by the same completed compilation, with the same toolchain, spec build flags
and absolute source path. Make still recompiles any changed input normally.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

DIRECTORIES = ('build-cgi', 'build-apache', 'build-fpm', 'build-embedded', 'build-ztscli', 'build-zts')
PATCH_LINES = ('Patch202: tests-al2-environment.patch\n', '%patch202 -p1\n')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def toolchain():
    result = subprocess.run(['rpm', '-qa', '--qf', '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}\n'],
                            stdout=subprocess.PIPE, universal_newlines=True, check=True)
    return '\n'.join(sorted(result.stdout.splitlines())) + '\n'


def create(work):
    source = work / 'rpmbuild/BUILD/php-8.1.34'
    cache = work / 'compile-cache'
    require(source.is_dir(), 'Completed compilation source tree is missing')
    for name in DIRECTORIES:
        require((source / name / 'Makefile').is_file(), 'Missing compiled build directory: ' + name)
    cache.mkdir(exist_ok=False)
    print('Saving completed compilation cache: ' + str(cache), flush=True)
    tree = cache / 'tree'
    shutil.copytree(str(source), str(tree), symlinks=True)
    files = {}
    for path in sorted(tree.rglob('*')):
        relative = path.relative_to(tree).as_posix()
        if path.is_symlink():
            files[relative] = {'type': 'symlink', 'target': os.readlink(str(path))}
        elif path.is_file():
            stat = path.stat()
            files[relative] = {'type': 'file', 'sha256': sha256(path),
                               'mtime_ns': stat.st_mtime_ns, 'atime_ns': stat.st_atime_ns}
    manifest = {'source': str(source), 'toolchain': toolchain(),
                'original_spec_sha256': sha256(work / 'rpmbuild/SPECS/php.spec'),
                'directories': list(DIRECTORIES), 'files': files}
    (cache / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Compilation cache saved and hashed: {} entries'.format(len(files)), flush=True)


def restore(work):
    cache = work / 'compile-cache'
    tree = cache / 'tree'
    source = work / 'rpmbuild/BUILD/php-8.1.34'
    manifest = json.loads((cache / 'manifest.json').read_text())
    require(str(source) == manifest['source'], 'Cache requires the same absolute build path')
    require(list(DIRECTORIES) == manifest['directories'], 'Unexpected cached directory set')
    require(toolchain() == manifest['toolchain'], 'Installed toolchain packages changed; use a fresh compilation')
    spec = (work / 'rpmbuild/SPECS/php.spec').read_text()
    for line in PATCH_LINES:
        require(spec.count(line) == 1, 'Expected exactly one test-only compatibility patch marker')
        spec = spec.replace(line, '', 1)
    require(hashlib.sha256(spec.encode()).hexdigest() == manifest['original_spec_sha256'],
            'Spec differs beyond the reviewed test-only compatibility patch; use a fresh compilation')
    print('Verifying original compiled files and toolchain before cache reuse', flush=True)
    for relative, metadata in manifest['files'].items():
        require(not Path(relative).is_absolute() and '..' not in Path(relative).parts, 'Unsafe cache path')
        path = tree / relative
        if metadata['type'] == 'symlink':
            require(path.is_symlink() and os.readlink(str(path)) == metadata['target'], 'Cached symlink changed: ' + relative)
        else:
            require(path.is_file() and not path.is_symlink() and sha256(path) == metadata['sha256'],
                    'Cached compilation file changed: ' + relative)
    unchanged = 0
    changed = []
    now = time.time_ns()
    for path in source.rglob('*'):
        relative = path.relative_to(source)
        if relative.parts[0] in DIRECTORIES or path.is_symlink() or not path.is_file():
            continue
        key = relative.as_posix()
        metadata = manifest['files'].get(key)
        if metadata and metadata['type'] == 'file' and sha256(path) == metadata['sha256']:
            os.utime(str(path), ns=(metadata['atime_ns'], metadata['mtime_ns']))
            unchanged += 1
        else:
            # Fresh timestamps force Make to rebuild dependants of changed
            # or new inputs, even when a source archive has an old timestamp.
            os.utime(str(path), ns=(now, now))
            changed.append(key)
    for name in DIRECTORIES:
        destination = source / name
        require(not destination.is_symlink(), 'Unexpected symlink at build directory: ' + name)
        if destination.exists():
            shutil.rmtree(str(destination))
        shutil.copytree(str(tree / name), str(destination), symlinks=True)
    configure_cache = tree / 'config.cache'
    if configure_cache.is_file() and not configure_cache.is_symlink():
        shutil.copy2(str(configure_cache), str(source / 'config.cache'))
    record = {'unchanged_source_inputs': unchanged, 'fresh_or_changed_inputs': changed,
              'verified_cache_entries': len(manifest['files']), 'restored_directories': list(DIRECTORIES),
              'toolchain_identical': True, 'spec_identical_except_patch202': True}
    (work / 'cache-reuse-validation.json').write_text(json.dumps(record, indent=2) + '\n')
    print('Verified cache restored: {} unchanged inputs; {} changed/new inputs remain fresh'.format(unchanged, len(changed)), flush=True)
    print('Normal configure, make, install and full PHPT stages remain enabled', flush=True)


def stamps(work):
    # configure recreates Zend/zend_config.h even when its bytes are unchanged.
    # Normalize only generated C/header inputs before the real Make observes
    # their timestamps; never touch different contents or compiled outputs.
    source = work / 'rpmbuild/BUILD/php-8.1.34'
    cwd = Path.cwd().resolve()
    if cwd not in [source / name for name in DIRECTORIES]:
        return
    manifest = json.loads((work / 'compile-cache/manifest.json').read_text())
    prefix = cwd.relative_to(source).as_posix() + '/'
    restored = []
    for name, metadata in manifest['files'].items():
        if not name.startswith(prefix) or not name.endswith(('.h', '.c')) or metadata['type'] != 'file':
            continue
        path = source / name
        if (path.is_file() and not path.is_symlink() and path.stat().st_mtime_ns != metadata['mtime_ns']
                and sha256(path) == metadata['sha256']):
            os.utime(str(path), ns=(metadata['atime_ns'], metadata['mtime_ns']))
            restored.append(name)
    if restored:
        with (work / 'generated-input-cache.jsonl').open('a') as output:
            output.write(json.dumps({'cwd': str(cwd), 'content_identical_inputs': restored}) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('create', 'restore', 'stamps'))
    parser.add_argument('work', type=Path)
    args = parser.parse_args()
    require(Path('/.dockerenv').exists() and os.geteuid() != 0, 'Run as the non-root builder inside the local AL2 container')
    work = args.work.resolve()
    require(work.parent == Path('/work') and work.name.startswith('php81-build.') and not work.is_symlink(), 'Unexpected build work directory')
    if args.mode == 'create':
        create(work)
    elif args.mode == 'restore':
        restore(work)
    else:
        stamps(work)


if __name__ == '__main__':
    main()
