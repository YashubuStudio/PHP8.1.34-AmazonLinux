#!/usr/bin/env python3
"""Download this kit's finished RPM archive from a GitHub Release.

No packages are installed and no archive is extracted. Private repositories use
an interactive, hidden token prompt; the token is never written to a file.
Requires Python 3.7+ with the standard library and working CA certificates.
"""

import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener


ARCHIVE = "php81-rpms-8.1.34-cve20261021.1.tar.gz"
CHECKSUM = ARCHIVE + ".sha256"
MAX_ASSET_BYTES = 2 * 1024 * 1024 * 1024 - 1


class DownloadError(Exception):
    pass


class GitHubRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        destination = urlparse(newurl)
        hostname = destination.hostname or ""
        if (destination.scheme != "https" or destination.username is not None
                or destination.password is not None
                or destination.port not in (None, 443)
                or not (hostname in ("api.github.com", "github.com")
                        or hostname.endswith(".githubusercontent.com"))):
            raise DownloadError("Download redirected outside the allowed GitHub HTTPS hosts.")
        next_request = super().redirect_request(req, fp, code, msg, headers, newurl)
        if next_request is not None:
            # A signed asset URL needs no PAT. Never forward the PAT on redirects.
            next_request.remove_header("Authorization")
        return next_request


def api_request(opener, url, token, accept):
    headers = {
        "Accept": accept,
        "User-Agent": "php81-local-build-kit",
        "X-GitHub-Api-Version": "2026-03-10",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    return opener.open(Request(url, headers=headers), timeout=60)


def download_asset(opener, repo, asset, destination, token, limit):
    asset_id = asset.get("id")
    expected_size = asset.get("size")
    if (type(asset_id) is not int or asset_id <= 0
            or type(expected_size) is not int or not 0 < expected_size <= limit
            or asset.get("state") != "uploaded"):
        raise DownloadError("Unexpected asset identity, size, or upload state: " + destination.name)
    url = "https://api.github.com/repos/{}/releases/assets/{}".format(repo, asset_id)
    digest = hashlib.sha256()
    total = 0
    with api_request(opener, url, token, "application/octet-stream") as response:
        with destination.open("xb") as output:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                total += len(block)
                if total > expected_size or total > limit:
                    raise DownloadError("Asset exceeds the expected size: " + destination.name)
                digest.update(block)
                output.write(block)
    if total != expected_size:
        raise DownloadError("Incomplete download: " + destination.name)
    actual = digest.hexdigest()
    api_digest = asset.get("digest")
    if api_digest is not None:
        if not isinstance(api_digest, str) or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", api_digest):
            raise DownloadError("Unsupported GitHub asset digest: " + destination.name)
        if actual != api_digest.split(":", 1)[1].lower():
            raise DownloadError("GitHub asset digest mismatch: " + destination.name)
    print("Downloaded: {} ({} bytes)".format(destination.name, total), flush=True)
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, metavar="OWNER/REPO")
    parser.add_argument("--tag", required=True, help="Explicit release tag; do not use latest")
    parser.add_argument("--output", default=".", help="Destination directory; existing files are never overwritten")
    parser.add_argument("--private", action="store_true", help="Prompt for a repository-scoped Contents:read token")
    args = parser.parse_args()

    if hasattr(os, "geteuid") and os.geteuid() == 0:
        raise DownloadError("Run as ec2-user or another normal user, without sudo.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", args.repo):
        raise DownloadError("--repo must be an OWNER/REPO name, without a URL or .git suffix.")
    if args.repo.split("/", 1)[1] in (".", "..") or args.repo.endswith(".git"):
        raise DownloadError("Use the repository name without the .git suffix.")
    if not args.tag or args.tag.lower() == "latest" or any(ord(c) < 32 for c in args.tag):
        raise DownloadError("Use the explicit release tag shown in GitHub Releases.")

    output_dir = Path(args.output).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    for name in (ARCHIVE, CHECKSUM):
        if os.path.lexists(str(output_dir / name)):
            raise DownloadError("Destination already exists; preserve it or choose another directory: " + str(output_dir / name))

    token = ""
    if args.private:
        if not sys.stdin.isatty():
            raise DownloadError("--private requires an interactive terminal for the hidden token prompt.")
        token = getpass.getpass("GitHub token (Contents:read; input is hidden): ").strip()
        if not re.fullmatch(r"[A-Za-z0-9_]+", token):
            raise DownloadError("The token is empty or contains unexpected characters.")

    opener = build_opener(GitHubRedirects(), HTTPSHandler(context=ssl.create_default_context()))
    metadata_url = "https://api.github.com/repos/{}/releases/tags/{}".format(args.repo, quote(args.tag, safe=""))
    with api_request(opener, metadata_url, token, "application/vnd.github+json") as response:
        metadata_bytes = response.read(8 * 1024 * 1024 + 1)
    if len(metadata_bytes) > 8 * 1024 * 1024:
        raise DownloadError("Unexpectedly large release metadata.")
    release = json.loads(metadata_bytes)
    if not isinstance(release, dict) or release.get("tag_name") != args.tag or release.get("draft") is not False:
        raise DownloadError("Expected a published release with the exact requested tag.")
    assets = release.get("assets", [])
    if not isinstance(assets, list):
        raise DownloadError("Invalid release asset list.")
    selected = {}
    for name in (ARCHIVE, CHECKSUM):
        matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
        if len(matches) != 1:
            raise DownloadError("The release must contain exactly one asset named " + name)
        selected[name] = matches[0]

    with tempfile.TemporaryDirectory(prefix=".php81-download-", dir=str(output_dir)) as temp_name:
        temporary = Path(temp_name)
        download_asset(opener, args.repo, selected[CHECKSUM], temporary / CHECKSUM, token, 4096)
        checksum_text = (temporary / CHECKSUM).read_text(encoding="ascii")
        checksum_match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]" + re.escape(ARCHIVE) + r"\r?\n?", checksum_text)
        if checksum_match is None:
            raise DownloadError("Unexpected checksum file contents; no files were installed.")
        actual_hash = download_asset(opener, args.repo, selected[ARCHIVE], temporary / ARCHIVE, token, MAX_ASSET_BYTES)
        if actual_hash != checksum_match.group(1).lower():
            raise DownloadError("Archive SHA-256 mismatch; do not use this release.")
        published_here = []
        try:
            for name in (ARCHIVE, CHECKSUM):
                # Same filesystem hard links atomically refuse to replace existing files.
                os.link(str(temporary / name), str(output_dir / name))
                published_here.append(output_dir / name)
        except OSError:
            for path in published_here:
                path.unlink()
            raise

    print("SHA-256 OK: " + actual_hash)
    print("Saved to: " + str(output_dir))
    print("Download only completed. No archive was extracted and no PHP package was changed.")
    print("Continue with the verification and installation steps in README.html.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nDownload cancelled. No PHP package was changed.", file=sys.stderr)
        sys.exit(130)
    except HTTPError as error:
        print("ERROR: GitHub returned HTTP {}. Check the repository, tag, published release and read permissions.".format(error.code), file=sys.stderr)
        if error.code == 404:
            print("A private repository needs --private and a token authorized for that repository.", file=sys.stderr)
        sys.exit(1)
    except URLError:
        print("ERROR: HTTPS download failed. Check network access and CA certificates.", file=sys.stderr)
        sys.exit(1)
    except (DownloadError, OSError, ValueError, UnicodeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
