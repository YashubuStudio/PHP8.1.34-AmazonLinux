#!/usr/bin/env bash
# Build the official PHP 8.1 EOL mitigation as local AL2 RPMs.
# build-local.sh starts this as a non-root user inside the local AL2 container.
set -Eeuo pipefail
umask 022
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $(id -u) -ne 0 ]] || die 'Run as a non-root build user with sudo access.'
[[ -r /etc/os-release ]] || die '/etc/os-release is unavailable.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == amzn && ${VERSION_ID:-} == 2 ]] || die 'Amazon Linux 2 is required.'
[[ $(uname -m) == x86_64 ]] || die 'An x86_64 build machine is required.'

build_host_name=$(hostname -s)
[[ $build_host_name != ip-172-31-40-13 ]] || die 'This is the production host. Use a dedicated build machine.'
for build_service in php-fpm.service httpd.service; do
  if command -v systemctl >/dev/null 2>&1; then
    build_service_state=$(systemctl is-active "$build_service" 2>/dev/null || true)
    case "$build_service_state" in
      active|activating|reloading)
        die "$build_service is running. Use a dedicated build machine with application services stopped."
        ;;
    esac
  fi
done
if command -v pgrep >/dev/null 2>&1; then
  for build_process in php-fpm httpd; do
    if pgrep -x "$build_process" >/dev/null; then
      die "$build_process processes exist. Use a dedicated build machine."
    fi
  done
fi

BUILD_JOBS=${BUILD_JOBS:-2}
[[ $BUILD_JOBS =~ ^[1-9][0-9]*$ ]] || die 'BUILD_JOBS must be a positive integer.'
[[ ${#BUILD_JOBS} -le 3 && $BUILD_JOBS -le 128 ]] || die 'BUILD_JOBS must be between 1 and 128.'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ -f "$script_dir/install-rpms.sh" ]] || die 'Keep install-rpms.sh beside build-rpms.sh.'
test_patch_name=tests-php81-cve.patch
test_patch_sha256=0f68687ff063de5961dd22b37cf8886df146d8a716be1a3d0fdf6f0a65580071
[[ -f "$script_dir/$test_patch_name" && -f "$script_dir/TEST-CHANGES-ja.md" ]] \
  || die 'Keep the test-only patch and TEST-CHANGES-ja.md beside build-rpms.sh.'
test_patch_actual=$(sha256sum "$script_dir/$test_patch_name")
[[ ${test_patch_actual%% *} == "$test_patch_sha256" ]] || die 'Test-only patch SHA-256 mismatch.'
command -v sudo >/dev/null 2>&1 || die 'sudo is required on this build machine.'

bundle_name=php81-rpms-8.1.34-cve20261021.1
delivery_archive="$PWD/${bundle_name}.tar.gz"
[[ ! -e "$delivery_archive" && ! -e "$delivery_archive.sha256" ]] \
  || die 'An output archive already exists in this directory. Move it aside before rebuilding.'
build_work=$(mktemp -d "$PWD/php81-build.XXXXXXXX")
bundle_dir="$build_work/$bundle_name"
rpm_topdir="$build_work/rpmbuild"
package_release=1.amzn2.cve20261021.1
source_name=php-8.1.34-1.amzn2.src.rpm
patch_name=php-8.1-1d7dec178a094e6e75b229ce22754045f8c6070a.patch
php_packages=(php-cli php-common php-fpm php-gd php-mbstring php-mysqlnd php-pdo php-xml)

mkdir -p "$bundle_dir"/{new,old,sources,logs} "$rpm_topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
exec > >(tee -a "$build_work/build-run.log") 2>&1
trap 'build_rc=$?; printf "Build stopped (exit %s). Work and logs retained: %s\n" "$build_rc" "$build_work" >&2; exit "$build_rc"' ERR
printf 'Build host: %s\nWork directory: %s\nParallel jobs: %s\n' "$build_host_name" "$build_work" "$BUILD_JOBS"
printf 'This script builds packages; it does not install the rebuilt PHP packages.\n'

sudo -v
sudo yum --disablerepo='*' --enablerepo=amzn2-core install -y \
  yum-utils rpm-build gcc gcc-c++ make autoconf automake patch python3 curl ca-certificates

# Import only Amazon Linux 2 keys already supplied by the build machine's OS.
shopt -s nullglob
aws_key_files=(/etc/pki/rpm-gpg/RPM-GPG-KEY-amazon-linux-2*)
shopt -u nullglob
[[ ${#aws_key_files[@]} -gt 0 ]] || die 'No existing Amazon Linux 2 RPM GPG key files were found.'
for aws_key_file in "${aws_key_files[@]}"; do
  [[ -f $aws_key_file ]] || die "Not a regular key file: $aws_key_file"
done
sudo rpm --import "${aws_key_files[@]}"

download_checked() {
  local download_url=$1 download_path=$2 expected_sha=$3 actual_sha
  printf 'Downloading %s\n' "$(basename -- "$download_path")"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 600 --retry 3 \
    --output "$download_path.part" "$download_url"
  actual_sha=$(sha256sum "$download_path.part")
  actual_sha=${actual_sha%% *}
  [[ $actual_sha == "$expected_sha" ]] || die "SHA-256 mismatch: $download_path"
  mv -- "$download_path.part" "$download_path"
}

check_aws_signature() {
  local signed_rpm=$1 signature_output signature_status=0
  signature_output=$(rpm --checksig --verbose "$signed_rpm" 2>&1) || signature_status=$?
  printf '%s\n' "$signature_output" | tee -a "$bundle_dir/logs/aws-rpm-signatures.log"
  [[ $signature_status -eq 0 ]] || die "RPM signature verification failed: $signed_rpm"
  if printf '%s\n' "$signature_output" | grep -Eiq 'NOKEY|NOT OK|NOTTRUSTED|BAD'; then
    die "An untrusted or invalid RPM signature was reported: $signed_rpm"
  fi
  printf '%s\n' "$signature_output" | grep -Eq '[Ss]ignature.*: OK' \
    || die "No verified RPM signature was found: $signed_rpm"
}

# Columns: relative bundle path, SHA-256, official HTTPS URL.
cat > "$bundle_dir/sources/upstream-downloads.tsv" <<'DOWNLOADS'
sources/php-8.1.34-1.amzn2.src.rpm	268a00aa08e9e14679a834c3d5f841193968816e5d17e5d59bccbfd8a03a7394	https://cdn.amazonlinux.com/blobstore/268a00aa08e9e14679a834c3d5f841193968816e5d17e5d59bccbfd8a03a7394/php-8.1.34-1.amzn2.src.rpm
sources/php-8.1-1d7dec178a094e6e75b229ce22754045f8c6070a.patch	c85ad0fddcbff7f2318617eeaa54d271135463b5bf70a01228447e3ed78de96e	https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a.patch
old/php-cli-8.1.34-1.amzn2.x86_64.rpm	80ade73e3b8fda07e96163cc47f23aa0230c6eb8000cc462f7c9141c0bd2e513	https://cdn.amazonlinux.com/blobstore/80ade73e3b8fda07e96163cc47f23aa0230c6eb8000cc462f7c9141c0bd2e513/php-cli-8.1.34-1.amzn2.x86_64.rpm
old/php-common-8.1.34-1.amzn2.x86_64.rpm	d584483c3b1a39c2d5706c5eafa12199cca6cb0abcab32cd5be683e80e49c249	https://cdn.amazonlinux.com/blobstore/d584483c3b1a39c2d5706c5eafa12199cca6cb0abcab32cd5be683e80e49c249/php-common-8.1.34-1.amzn2.x86_64.rpm
old/php-fpm-8.1.34-1.amzn2.x86_64.rpm	9cec8ab31bb543967a52fbb3091fb1d0d924b3eca8e1719ff9c8a5f6f89180d2	https://cdn.amazonlinux.com/blobstore/9cec8ab31bb543967a52fbb3091fb1d0d924b3eca8e1719ff9c8a5f6f89180d2/php-fpm-8.1.34-1.amzn2.x86_64.rpm
old/php-gd-8.1.34-1.amzn2.x86_64.rpm	5357243199aa6dccb54568eccdc62dae15ad0d1923b2d3a5f44f26d7165a36f1	https://cdn.amazonlinux.com/blobstore/5357243199aa6dccb54568eccdc62dae15ad0d1923b2d3a5f44f26d7165a36f1/php-gd-8.1.34-1.amzn2.x86_64.rpm
old/php-mbstring-8.1.34-1.amzn2.x86_64.rpm	862348bc84165c4202fcab203aafcf79e4e380100a7ec74e677bd05e9de47b82	https://cdn.amazonlinux.com/blobstore/862348bc84165c4202fcab203aafcf79e4e380100a7ec74e677bd05e9de47b82/php-mbstring-8.1.34-1.amzn2.x86_64.rpm
old/php-mysqlnd-8.1.34-1.amzn2.x86_64.rpm	5e74f5b814639f9e73a2c3c7bd3a11f351d5544bc9a079eae97ac9cc53584e40	https://cdn.amazonlinux.com/blobstore/5e74f5b814639f9e73a2c3c7bd3a11f351d5544bc9a079eae97ac9cc53584e40/php-mysqlnd-8.1.34-1.amzn2.x86_64.rpm
old/php-pdo-8.1.34-1.amzn2.x86_64.rpm	9c5ccbb29b7675afa0b2e44c0cbb2d4dc0e4db03100da84ab058bf575c7a01fc	https://cdn.amazonlinux.com/blobstore/9c5ccbb29b7675afa0b2e44c0cbb2d4dc0e4db03100da84ab058bf575c7a01fc/php-pdo-8.1.34-1.amzn2.x86_64.rpm
old/php-xml-8.1.34-1.amzn2.x86_64.rpm	fc840f643349d818b5cc7bb70c5ffe1d45212a3f8864035c7c9fcd323c46836d	https://cdn.amazonlinux.com/blobstore/fc840f643349d818b5cc7bb70c5ffe1d45212a3f8864035c7c9fcd323c46836d/php-xml-8.1.34-1.amzn2.x86_64.rpm
DOWNLOADS

while IFS=$'\t' read -r relative_path expected_sha download_url; do
  download_checked "$download_url" "$bundle_dir/$relative_path" "$expected_sha"
  case "$relative_path" in
    *.rpm) check_aws_signature "$bundle_dir/$relative_path" ;;
  esac
done < "$bundle_dir/sources/upstream-downloads.tsv"

source_rpm="$bundle_dir/sources/$source_name"
security_patch="$bundle_dir/sources/$patch_name"
test_patch="$bundle_dir/sources/$test_patch_name"
cp -- "$script_dir/$test_patch_name" "$test_patch"
cp -- "$script_dir/TEST-CHANGES-ja.md" "$bundle_dir/sources/TEST-CHANGES-ja.md"
[[ $(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}' "$source_rpm") == 'php 8.1.34 1.amzn2 x86_64' ]] \
  || die 'Unexpected source RPM identity.'
for php_package in "${php_packages[@]}"; do
  old_rpm="$bundle_dir/old/${php_package}-8.1.34-1.amzn2.x86_64.rpm"
  [[ $(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH} %{SOURCERPM}' "$old_rpm") == "$php_package 8.1.34 1.amzn2 x86_64 $source_name" ]] \
    || die "Unexpected rollback RPM identity: $old_rpm"
done

# Only the dedicated build machine receives build dependencies.
sudo yum-builddep --disablerepo='*' --enablerepo=amzn2-core -y "$source_rpm"
rpm --define "_topdir $rpm_topdir" -ivh "$source_rpm"
cp -- "$security_patch" "$rpm_topdir/SOURCES/$patch_name"
cp -- "$test_patch" "$rpm_topdir/SOURCES/$test_patch_name"
spec_path="$rpm_topdir/SPECS/php.spec"
cp -- "$spec_path" "$bundle_dir/sources/php.spec.aws"

python3 - "$spec_path" "$patch_name" "$package_release" "$test_patch_name" <<'PY'
from pathlib import Path
import sys

spec_path = Path(sys.argv[1])
patch_name, release, test_patch_name = sys.argv[2:]
text = spec_path.read_text()
changes = (
    ('Release: 1%{?dist}%{?_trivial}%{?_buildid}\n',
     'Release: ' + release + '\nVendor: Local PHP 8.1 security rebuild\n'),
    ('# Security fixes (200+)\n',
     '# Security fixes (200+)\nPatch200: ' + patch_name + '\n'
     '# Local PHPT expectations for the official mitigation; no production code.\n'
     'Patch201: ' + test_patch_name + '\n'),
    ('# security patches\n',
     '# security patches\n%patch200 -p1\n%patch201 -p1\n'),
    ('  #exit 1\n', '  exit 1\n'),
)
if any(marker in text for marker in ('Patch200:', '%patch200', 'Patch201:', '%patch201', '\nVendor:')):
    raise SystemExit('Unexpected existing Patch200/Patch201 or Vendor; stop for review.')
if text.count('%if %runselftest\n') != 1:
    raise SystemExit('Unexpected test section; stop for review.')
for old, new in changes:
    if text.count(old) != 1:
        raise SystemExit('Expected exactly one spec marker: ' + repr(old))
    text = text.replace(old, new, 1)
spec_path.write_text(text)
print('Updated release/vendor, added the official patch and documented PHPT expectations, and made test failures fatal.')
PY

cp -- "$spec_path" "$bundle_dir/sources/php.spec"
cp -- "$script_dir/build-rpms.sh" "$bundle_dir/sources/build-rpms.sh"
diff -u "$bundle_dir/sources/php.spec.aws" "$bundle_dir/sources/php.spec" \
  > "$bundle_dir/logs/spec-changes.diff" || [[ $? -eq 1 ]]

rpm_build_options=(--define "_topdir $rpm_topdir" --define "_smp_mflags -j$BUILD_JOBS" --define 'runselftest 1')
rpmbuild "${rpm_build_options[@]}" -bp "$spec_path" 2>&1 | tee "$bundle_dir/logs/rpmbuild-prep.log"
prepared_source="$rpm_topdir/BUILD/php-8.1.34"
[[ -d $prepared_source ]] || die 'The expected prepared source directory does not exist.'
(
  cd -- "$prepared_source"
  patch --batch --fuzz=0 --dry-run --reverse -p1 --input "$security_patch"
) 2>&1 | tee "$bundle_dir/logs/security-patch-reverse-check-before-build.log"
(
  cd -- "$prepared_source"
  patch --batch --fuzz=0 --dry-run --reverse -p1 --input "$test_patch"
) 2>&1 | tee "$bundle_dir/logs/test-patch-reverse-check-before-build.log"

# The original AWS test suite is enabled. A failure stops here for review;
# no application compatibility or test success is inferred from compilation alone.
rpmbuild "${rpm_build_options[@]}" -ba "$spec_path" 2>&1 | tee "$bundle_dir/logs/rpmbuild.log"
(
  cd -- "$prepared_source"
  patch --batch --fuzz=0 --dry-run --reverse -p1 --input "$security_patch"
) 2>&1 | tee "$bundle_dir/logs/security-patch-reverse-check-after-build.log"
(
  cd -- "$prepared_source"
  patch --batch --fuzz=0 --dry-run --reverse -p1 --input "$test_patch"
) 2>&1 | tee "$bundle_dir/logs/test-patch-reverse-check-after-build.log"

for php_package in "${php_packages[@]}"; do
  new_rpm="$rpm_topdir/RPMS/x86_64/${php_package}-8.1.34-${package_release}.x86_64.rpm"
  [[ -f $new_rpm ]] || die "Missing rebuilt RPM: $new_rpm"
  [[ $(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH} %{VENDOR}' "$new_rpm") == "$php_package 8.1.34 $package_release x86_64 Local PHP 8.1 security rebuild" ]] \
    || die "Unexpected rebuilt RPM identity: $new_rpm"
  rpm --checksig "$new_rpm"
  cp -- "$new_rpm" "$bundle_dir/new/"
  rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH} %{SOURCERPM}\n' "$new_rpm" \
    >> "$bundle_dir/logs/rebuilt-rpm-identities.txt"
done
rebuilt_srpm="$rpm_topdir/SRPMS/php-8.1.34-${package_release}.src.rpm"
[[ -f $rebuilt_srpm ]] || die 'Missing rebuilt source RPM.'
cp -- "$rebuilt_srpm" "$bundle_dir/sources/"

cat > "$bundle_dir/logs/VALIDATION.txt" <<VALIDATION
Built on: $build_host_name
Build time (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
OS: Amazon Linux 2 x86_64
Original package: php-8.1.34-1.amzn2.src.rpm
Rebuilt release: $package_release
Official PHP commit: 1d7dec178a094e6e75b229ce22754045f8c6070a
Original source and rollback RPMs: pinned SHA-256 and RPM GPG signatures verified.
Official patch: pinned SHA-256 verified; reverse dry-run passed before and after build.
Local test-only patch: $test_patch_name, SHA-256 $test_patch_sha256.
The test-only patch updates 11 PHPT expectations to the official changed behavior; no additional production code, skips or XFAILs.
AWS spec test suite: enabled; the original ignored-failure exit was made fatal.
rpmbuild -ba: completed successfully, including that enabled test suite.
Application compatibility, production traffic, and production PHP-FPM execution: NOT tested.
New RPMs are locally rebuilt and unsigned; they are not AWS-issued security updates.
The official PHP change is an EOL minimal mitigation for CVE-2026-109618 and CVE-2026-109619.
Only these packages are included for installation: ${php_packages[*]}
VALIDATION

cp -- "$script_dir/install-rpms.sh" "$bundle_dir/install-rpms.sh"
chmod 0755 "$bundle_dir/install-rpms.sh"
if [[ -f "$script_dir/README-ja.md" ]]; then
  cp -- "$script_dir/README-ja.md" "$bundle_dir/README-ja.md"
fi
if [[ -f "$script_dir/README.html" ]]; then
  cp -- "$script_dir/README.html" "$bundle_dir/README.html"
fi
cp -- "$script_dir/TEST-CHANGES-ja.md" "$bundle_dir/TEST-CHANGES-ja.md"
cp -- "$build_work/build-run.log" "$bundle_dir/logs/build-run.log"
python3 - "$bundle_dir" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1])
entries = []
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        raise SystemExit('Unexpected symbolic link in bundle: ' + str(path))
    if path.is_file() and path != root / 'SHA256SUMS':
        digest = hashlib.sha256()
        with path.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(block)
        entries.append(digest.hexdigest() + '  ' + path.relative_to(root).as_posix() + '\n')
(root / 'SHA256SUMS').write_text(''.join(entries))
PY
(
  cd -- "$bundle_dir"
  sha256sum --check --strict SHA256SUMS
)
tar -C "$build_work" -czf "$build_work/${bundle_name}.tar.gz" "$bundle_name"
(
  cd -- "$build_work"
  sha256sum "${bundle_name}.tar.gz" > "${bundle_name}.tar.gz.sha256"
)
cp -- "$build_work/${bundle_name}.tar.gz" "$delivery_archive"
cp -- "$build_work/${bundle_name}.tar.gz.sha256" "$delivery_archive.sha256"
printf '\nBuild completed. No rebuilt PHP package has been installed.\n'
printf 'Bundle: %s\nArchive: %s\nArchive checksum: %s\n' \
  "$bundle_dir" "$delivery_archive" "$delivery_archive.sha256"
printf 'Preserve the work directory until the production update and application checks are complete.\n'
