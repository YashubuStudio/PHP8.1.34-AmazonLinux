#!/usr/bin/env python3
"""Publish an already built/tested local bundle; never compile PHP on Actions.

Transport chunks live only on a release-upload/* delivery branch. The release
tag points at the source commit on main. No PAT is required: Actions uses its
short-lived, repository-scoped GITHUB_TOKEN with Contents:write.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
from urllib.error import HTTPError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

REPOSITORY = 'YashubuStudio/PHP8.1.34-AmazonLinux'
ARCHIVE = 'php81-rpms-8.1.34-cve20261021.1.tar.gz'
BUNDLE = ARCHIVE.removesuffix('.tar.gz')
TAG = 'php81-8.1.34-cve20261021.1'
PACKAGES = ('php-cli', 'php-common', 'php-fpm', 'php-gd', 'php-mbstring', 'php-mysqlnd', 'php-pdo', 'php-xml')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def payload_file(root, name):
    require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name), 'Invalid payload filename')
    path = root / name
    require(path.is_file() and not path.is_symlink(), 'Missing or symlinked payload file: ' + name)
    return path


def verify_archive(archive_path, report):
    expected_rpms = {
        '{}/{}-8.1.34-{}.x86_64.rpm'.format(kind, name, release)
        for kind, release in (('new', '1.amzn2.cve20261021.1'), ('old', '1.amzn2'))
        for name in PACKAGES
    }
    require(report.get('status') == 'passed', 'Runtime validation did not pass')
    candidate = report['phases']['candidate']
    require(candidate['parallel_requests'] == 100 and candidate['session_requests'] == 10,
            'Missing runtime request coverage')
    require(candidate['multipart_upload_and_disabled_progress'] and candidate['bounded_oom_and_fpm_recovery'],
            'Missing upload or bounded OOM verification')
    require(set(report['rpm_sha256']) == expected_rpms, 'Runtime report does not cover exactly 16 RPMs')
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = {}
        for member in archive:
            name = PurePosixPath(member.name)
            require(not name.is_absolute() and '..' not in name.parts and name.parts[0] == BUNDLE,
                    'Unsafe archive member')
            require(member.isdir() or member.isfile(), 'Archive must not contain links or special files')
            require(member.name not in members, 'Duplicate archive member')
            members[member.name] = member
        checksum_name = BUNDLE + '/SHA256SUMS'
        require(checksum_name in members and members[checksum_name].size < 1024 * 1024, 'Missing checksum manifest')
        entries = {}
        for line in archive.extractfile(checksum_name).read().decode('ascii').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
            require(match is not None, 'Invalid checksum entry')
            digest, name = match.groups()
            require(name not in entries, 'Duplicate checksum entry')
            full_name = BUNDLE + '/' + name
            require(full_name in members and members[full_name].isfile(), 'Manifest file missing from archive')
            hasher = hashlib.sha256()
            with archive.extractfile(full_name) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    hasher.update(block)
            require(hasher.hexdigest() == digest, 'Bundle checksum mismatch: ' + name)
            entries[name] = digest
        actual_files = {name for name, member in members.items() if member.isfile()}
        require(actual_files == {BUNDLE + '/' + name for name in entries} | {checksum_name}, 'Unhashed archive files')
        require({name for name in entries if name.startswith(('new/', 'old/'))} == expected_rpms,
                'Archive RPM set differs from the reviewed eight-package configuration')
        for name, digest in report['rpm_sha256'].items():
            require(entries.get(name) == digest, 'Runtime test used different RPM bytes: ' + name)
        bundled_report = archive.extractfile(BUNDLE + '/logs/runtime/runtime-validation.json').read()
        require(json.loads(bundled_report) == report, 'Bundled runtime report differs from release report')


class GitHub:
    def __init__(self, token):
        self.token = token
        self.prefix = 'https://api.github.com/repos/' + REPOSITORY

    def request(self, method, path, data=None, raw_path=None):
        url = path if path.startswith('https://') else self.prefix + path
        parsed = urlparse(url)
        require(parsed.scheme == 'https' and parsed.hostname in ('api.github.com', 'uploads.github.com'), 'Unexpected GitHub host')
        headers = {'Accept': 'application/vnd.github+json', 'Authorization': 'Bearer ' + self.token,
                   'User-Agent': 'php81-local-release-publisher', 'X-GitHub-Api-Version': '2026-03-10'}
        body = None
        if raw_path is not None:
            headers['Content-Type'] = 'application/gzip' if raw_path.name.endswith('.tar.gz') else 'application/octet-stream'
            body = raw_path.read_bytes()
        elif data is not None:
            headers['Content-Type'] = 'application/json'
            body = json.dumps(data).encode('utf-8')
        try:
            with urlopen(Request(url, data=body, headers=headers, method=method), timeout=300) as response:
                return json.load(response)
        except HTTPError as error:
            if method == 'GET' and error.code == 404:
                return None
            raise RuntimeError('GitHub {} {} failed with HTTP {}'.format(method, parsed.path, error.code)) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    require(args.manifest.is_file() and not args.manifest.is_symlink(), 'Missing payload manifest')
    manifest = json.loads(args.manifest.read_text())
    root = args.manifest.resolve().parent
    require(manifest['repository'] == REPOSITORY and manifest['tag'] == TAG and manifest['archive'] == ARCHIVE,
            'Unexpected repository, tag or archive')
    source_commit = manifest['source_commit']
    require(re.fullmatch(r'[0-9a-f]{40}', source_commit), 'An exact source commit is required')
    require(isinstance(manifest['parts'], list) and 1 <= len(manifest['parts']) <= 100, 'Invalid archive part list')
    with tempfile.TemporaryDirectory(prefix='php81-publish-') as temporary:
        archive_path = Path(temporary) / ARCHIVE
        names = set()
        with archive_path.open('xb') as output:
            for part in manifest['parts']:
                require(part['name'] not in names, 'Duplicate archive part')
                names.add(part['name'])
                path = payload_file(root, part['name'])
                require(path.stat().st_size == part['size'] and sha256(path) == part['sha256'], 'Archive part checksum mismatch')
                with path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        output.write(block)
        require(sha256(archive_path) == manifest['archive_sha256'], 'Reassembled archive SHA-256 mismatch')
        files = [archive_path]
        for entry in manifest['files']:
            path = payload_file(root, entry['name'])
            require(path.name not in names and path.name != ARCHIVE, 'Duplicate delivery filename')
            names.add(path.name)
            require(path.stat().st_size == entry['size'] and sha256(path) == entry['sha256'], 'Release file checksum mismatch')
            files.append(path)
        require({path.name for path in files} == {ARCHIVE, ARCHIVE + '.sha256', 'VALIDATION-ja.md', 'runtime-validation.json'},
                'Unexpected release asset set')
        sidecar = payload_file(root, ARCHIVE + '.sha256').read_text(encoding='ascii')
        require(sidecar == manifest['archive_sha256'] + '  ' + ARCHIVE + '\n', 'Invalid archive checksum sidecar')
        report = json.loads(payload_file(root, 'runtime-validation.json').read_text())
        verify_archive(archive_path, report)
        notes = payload_file(root, 'RELEASE-NOTES-ja.txt').read_text()
        require(sha256(root / 'RELEASE-NOTES-ja.txt') == manifest['notes_sha256'], 'Release notes checksum mismatch')
        print('Archive, complete bundle, exact RPM hashes and local runtime verification: PASSED', flush=True)
        if args.verify_only:
            return
        require(os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_REF', '').startswith('refs/heads/release-upload/'),
                'Publishing must run in this repository delivery workflow')
        token = os.environ.get('GH_TOKEN', '')
        require(bool(token), 'Missing workflow token')
        api = GitHub(token)
        tagged = api.request('GET', '/commits/' + quote(TAG, safe=''))
        require(tagged and tagged['sha'] == source_commit, 'Release tag does not identify the tested source commit')
        release = api.request('GET', '/releases/tags/' + quote(TAG, safe=''))
        if release is None:
            release = api.request('POST', '/releases', {'tag_name': TAG, 'target_commitish': source_commit,
                'name': 'PHP 8.1.34 / Amazon Linux 2 x86_64 / verified security rebuild',
                'body': notes, 'draft': True, 'prerelease': False})
        require(release['draft'] is True and release['prerelease'] is False and release['body'] == notes,
                'Refusing to overwrite an existing or unrelated release')
        upload_url = release['upload_url'].split('{', 1)[0]
        existing = {asset['name']: asset for asset in release['assets']}
        require(set(existing).issubset({path.name for path in files}), 'Unexpected existing draft assets')
        for path in files:
            digest = 'sha256:' + sha256(path)
            asset = existing.get(path.name)
            if asset is None:
                asset = api.request('POST', upload_url + '?name=' + quote(path.name, safe=''), raw_path=path)
            require(asset['state'] == 'uploaded' and asset['size'] == path.stat().st_size and asset.get('digest') == digest,
                    'Uploaded asset identity/digest mismatch: ' + path.name)
            print('Verified uploaded asset: ' + path.name, flush=True)
        assets = api.request('GET', '/releases/{}/assets'.format(release['id']))
        require(len(assets) == len(files), 'Unexpected final asset count')
        local = {path.name: path for path in files}
        for asset in assets:
            path = local[asset['name']]
            require(asset['state'] == 'uploaded' and asset['size'] == path.stat().st_size
                    and asset.get('digest') == 'sha256:' + sha256(path), 'Final asset verification failed')
        release = api.request('PATCH', '/releases/{}'.format(release['id']), {'draft': False, 'make_latest': 'true'})
        require(release['draft'] is False and release['tag_name'] == TAG, 'Release publication did not complete')
        print('Published: ' + release['html_url'], flush=True)
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with Path(summary).open('a') as output:
                output.write('Published verified local AL2 build: ' + release['html_url'] + '\n\nArchive SHA-256: `' + manifest['archive_sha256'] + '`\n')


if __name__ == '__main__':
    main()
