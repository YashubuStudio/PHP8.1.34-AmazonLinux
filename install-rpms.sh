#!/usr/bin/env bash
# Amazon Linux 2 / x86_64 / the eight PHP 8.1.34 packages specified in README-ja.md.
# Usage: sudo bash install-rpms.sh check|apply|rollback /absolute/path/to/bundle
# This script never runs yum and never changes repositories or PHP configuration.
set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || die 'Usage: sudo bash install-rpms.sh check|apply|rollback BUNDLE_DIR'
PHP81_MODE=$1
case "$PHP81_MODE" in check|apply|rollback) ;; *) die 'Unknown mode.' ;; esac
[[ $EUID == 0 ]] || die 'Run with sudo bash.'
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == amzn && ${VERSION_ID:-} == 2 ]] || die 'Amazon Linux 2 is required.'
[[ $(uname -m) == x86_64 ]] || die 'x86_64 is required.'

for PHP81_TOOL in rpm rpm2cpio cpio sha256sum tar diff sort awk grep readlink systemctl mktemp timeout flock stat; do
    command -v "$PHP81_TOOL" >/dev/null || die "Required tool is missing: $PHP81_TOOL"
done
PHP81_BUNDLE=$(readlink -f -- "$2")
[[ -d "$PHP81_BUNDLE" && -f "$PHP81_BUNDLE/SHA256SUMS" ]] || die 'Bundle or SHA256SUMS not found.'
PHP81_NAMES=(php-cli php-common php-fpm php-gd php-mbstring php-mysqlnd php-pdo php-xml)
PHP81_OLD_RELEASE=1.amzn2
PHP81_NEW_RELEASE=1.amzn2.cve20261021.1
PHP81_STAGE=''
PHP81_BACKUP=''
PHP81_CHANGE_STARTED=0

cleanup() {
    local update_result=$?
    trap - EXIT
    if [[ -n "$PHP81_STAGE" && -d "$PHP81_STAGE" ]]; then
        rm -rf -- "$PHP81_STAGE"
    fi
    if (( update_result != 0 && PHP81_CHANGE_STARTED == 1 )); then
        printf '\nThe update stopped after the maintenance step began. Inspect the preceding error.\n' >&2
        if [[ -n "$PHP81_BACKUP" ]]; then
            printf 'Rollback command (restores the old, vulnerable PHP packages):\n' >&2
            printf 'sudo bash %q rollback %q\n' "$PHP81_BACKUP/bundle/install-rpms.sh" "$PHP81_BACKUP/bundle" >&2
        fi
    fi
    exit "$update_result"
}
trap cleanup EXIT
trap 'printf "ERROR: stopped at script line %s.\n" "$LINENO" >&2' ERR
exec 9>/var/lock/php81-security-update.lock
flock -n 9 || die 'Another PHP 8.1 update/check is already running.'

# SHA-256 protects bundle contents during transfer. New RPMs are local builds,
# not AWS-signed RPMs. The original AWS rollback RPMs are verified separately.
(cd "$PHP81_BUNDLE" && sha256sum --check --strict SHA256SUMS)

PHP81_EXPECTED_NAMES=$(printf '%s\n' "${PHP81_NAMES[@]}" | LC_ALL=C sort)
PHP81_CURRENT_NAMES=$(rpm -qa 'php*' --qf '%{NAME}\n' | LC_ALL=C sort)
[[ "$PHP81_CURRENT_NAMES" == "$PHP81_EXPECTED_NAMES" ]] || {
    printf 'Expected PHP packages:\n%s\nActual PHP packages:\n%s\n' "$PHP81_EXPECTED_NAMES" "$PHP81_CURRENT_NAMES" >&2
    die 'Installed PHP package set differs from the reviewed eight-package configuration.'
}

PHP81_NEW_RPMS=()
PHP81_OLD_RPMS=()
for PHP81_NAME in "${PHP81_NAMES[@]}"; do
    PHP81_NEW_FILE="$PHP81_BUNDLE/new/${PHP81_NAME}-8.1.34-${PHP81_NEW_RELEASE}.x86_64.rpm"
    PHP81_OLD_FILE="$PHP81_BUNDLE/old/${PHP81_NAME}-8.1.34-${PHP81_OLD_RELEASE}.x86_64.rpm"
    for PHP81_KIND in new old; do
        if [[ "$PHP81_KIND" == new ]]; then
            PHP81_FILE=$PHP81_NEW_FILE
            PHP81_RELEASE=$PHP81_NEW_RELEASE
        else
            PHP81_FILE=$PHP81_OLD_FILE
            PHP81_RELEASE=$PHP81_OLD_RELEASE
        fi
        [[ -f "$PHP81_FILE" ]] || die "Missing RPM: $PHP81_FILE"
        PHP81_HEADER=$(rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SOURCERPM}' "$PHP81_FILE")
        [[ "$PHP81_HEADER" == "$PHP81_NAME|8.1.34|$PHP81_RELEASE|x86_64|php-8.1.34-$PHP81_RELEASE.src.rpm" ]] \
            || die "Unexpected RPM header: $PHP81_FILE"
    done
    PHP81_SIGNATURE=$(LC_ALL=C rpm -Kv "$PHP81_OLD_FILE") || die "AWS RPM signature/digest check failed: $PHP81_OLD_FILE"
    printf '%s\n' "$PHP81_SIGNATURE" | grep -Eq 'Signature.*: OK' \
        || die "A trusted AWS signature could not be verified: $PHP81_OLD_FILE"
    if printf '%s\n' "$PHP81_SIGNATURE" | grep -Eq 'NOKEY|NOT OK|BAD'; then
        die "AWS RPM signature is not trusted: $PHP81_OLD_FILE"
    fi
    PHP81_INSTALLED=$(rpm -q --qf '%{VERSION}|%{RELEASE}|%{ARCH}' "$PHP81_NAME")
    if [[ "$PHP81_MODE" == rollback ]]; then
        case "$PHP81_INSTALLED" in
            "8.1.34|$PHP81_OLD_RELEASE|x86_64"|"8.1.34|$PHP81_NEW_RELEASE|x86_64") ;;
            *) die "Unexpected installed version for rollback: $PHP81_NAME $PHP81_INSTALLED" ;;
        esac
    else
        [[ "$PHP81_INSTALLED" == "8.1.34|$PHP81_OLD_RELEASE|x86_64" ]] \
            || die "Expected the original AWS package: $PHP81_NAME $PHP81_INSTALLED"
    fi
    PHP81_NEW_RPMS+=("$PHP81_NEW_FILE")
    PHP81_OLD_RPMS+=("$PHP81_OLD_FILE")
done
[[ ${#PHP81_NEW_RPMS[@]} == 8 && ${#PHP81_OLD_RPMS[@]} == 8 ]] || die 'RPM count must be exactly eight.'

if [[ "$PHP81_MODE" == rollback ]]; then
    printf '\nROLLBACK: the two CVE fixes will be removed. PHP-FPM will be stopped briefly.\n'
    # --replacepkgs also handles a failed transaction that left a mixture of old/new RPMs.
    rpm -Uvh --oldpackage --replacepkgs --test "${PHP81_OLD_RPMS[@]}"
    PHP81_CHANGE_STARTED=1
    systemctl stop php-fpm
    rpm -Uvh --oldpackage --replacepkgs "${PHP81_OLD_RPMS[@]}"
    /usr/sbin/php-fpm -t
    systemctl start php-fpm
    systemctl is-active --quiet php-fpm
    rpm -q "${PHP81_NAMES[@]}"
    printf '\nROLLBACK COMPLETE. The original, unpatched PHP 8.1.34 packages are running.\n'
    exit 0
fi

systemctl is-active --quiet php-fpm || die 'PHP-FPM is not active; inspect its state before updating.'
systemctl is-active --quiet httpd || die 'Apache is not active; inspect its state before updating.'
[[ $(rpm -qf --qf '%{NAME}' /usr/bin/php) == php-cli ]] || die 'Unexpected CLI ownership.'
[[ $(rpm -qf --qf '%{NAME}' /usr/sbin/php-fpm) == php-fpm ]] || die 'Unexpected FPM ownership.'
[[ -f /etc/php.ini && -f /etc/php-fpm.conf && -d /etc/php.d ]] || die 'Expected PHP configuration is missing.'

# Dependency/conflict checks do not download, upgrade or ignore dependencies.
rpm -Uvh --test "${PHP81_NEW_RPMS[@]}"
PHP81_STAGE=$(mktemp -d /var/tmp/php81-precheck.XXXXXXXX)
for PHP81_FILE in "${PHP81_NEW_RPMS[@]}"; do
    (cd "$PHP81_STAGE" && rpm2cpio "$PHP81_FILE" | cpio -idm --quiet --no-absolute-filenames)
done

PHP81_CLI="$PHP81_STAGE/usr/bin/php"
PHP81_FPM="$PHP81_STAGE/usr/sbin/php-fpm"
PHP81_EXTENSIONS="$PHP81_STAGE/usr/lib64/php/modules"
[[ -x "$PHP81_CLI" && -x "$PHP81_FPM" && -d "$PHP81_EXTENSIONS" ]] || die 'Incomplete staged PHP payload.'
for PHP81_BINARY in "$PHP81_CLI" "$PHP81_FPM"; do
    LC_ALL=C grep -aFq 'zend_mm_safe_error_ex' "$PHP81_BINARY" || die "Patch marker is missing: $PHP81_BINARY"
done

env PHP_INI_SCAN_DIR=/etc/php.d /usr/bin/php -c /etc/php.ini -m \
    >"$PHP81_STAGE/modules-before.txt" 2>"$PHP81_STAGE/cli-before.stderr"
env PHP_INI_SCAN_DIR=/etc/php.d "$PHP81_CLI" -c /etc/php.ini \
    -d "extension_dir=$PHP81_EXTENSIONS" -m \
    >"$PHP81_STAGE/modules-candidate.txt" 2>"$PHP81_STAGE/cli-candidate.stderr"
for PHP81_STDERR in "$PHP81_STAGE/cli-before.stderr" "$PHP81_STAGE/cli-candidate.stderr"; do
    if [[ -s "$PHP81_STDERR" ]]; then
        cat "$PHP81_STDERR" >&2
        die 'PHP startup emitted diagnostics; resolve them before replacing packages.'
    fi
done
diff -u <(LC_ALL=C sort "$PHP81_STAGE/modules-before.txt") \
    <(LC_ALL=C sort "$PHP81_STAGE/modules-candidate.txt") \
    || die 'PHP extension list differs between current and candidate builds.'

# A bounded, independent CLI check uses an 8 MiB PHP limit. It does not send
# network requests or try to exhaust host memory.
PHP81_OOM_STATUS=0
timeout 15 "$PHP81_CLI" -n -d memory_limit=8M -r \
    'register_shutdown_function(function () { echo "PHP81_SHUTDOWN_CALLBACK\n"; }); str_repeat("x", 16 * 1024 * 1024);' \
    >"$PHP81_STAGE/oom-check.txt" 2>&1 || PHP81_OOM_STATUS=$?
[[ $PHP81_OOM_STATUS == 1 ]] || die "Unexpected patched OOM behavior (exit $PHP81_OOM_STATUS)."
grep -q 'Allowed memory size' "$PHP81_STAGE/oom-check.txt" || die 'Expected PHP memory-limit error was not observed.'
if grep -q 'PHP81_SHUTDOWN_CALLBACK' "$PHP81_STAGE/oom-check.txt"; then
    die 'The old memory-limit shutdown behavior is still present.'
fi

if ! env PHP_INI_SCAN_DIR=/etc/php.d "$PHP81_FPM" -c /etc/php.ini \
    -d "extension_dir=$PHP81_EXTENSIONS" -y /etc/php-fpm.conf -t \
    >"$PHP81_STAGE/fpm-config-check.txt" 2>&1; then
    cat "$PHP81_STAGE/fpm-config-check.txt" >&2
    die 'Candidate PHP-FPM configuration check failed.'
fi
cat "$PHP81_STAGE/fpm-config-check.txt"
if grep -Eiq 'PHP (Warning|Fatal)|Unable to load dynamic library|undefined symbol|error while loading shared' \
    "$PHP81_STAGE/fpm-config-check.txt"; then
    die 'Candidate PHP-FPM emitted startup errors.'
fi
printf '\nPRECHECK OK: eight RPMs, dependencies, CLI extensions, patched OOM behavior and FPM configuration.\n'
printf 'This does not test application requests or per-pool runtime overrides.\n'
[[ "$PHP81_MODE" == apply ]] || exit 0

# Keep the exact source bundle and original configuration under a root-only directory.
mkdir -p /var/backups
PHP81_BACKUP=$(mktemp -d "/var/backups/php81-cve-$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
chmod 700 "$PHP81_BACKUP"
cp -a "$PHP81_BUNDLE" "$PHP81_BACKUP/bundle"
cp "$PHP81_STAGE/modules-before.txt" "$PHP81_BACKUP/modules-before.txt"
cp "$PHP81_STAGE/fpm-config-check.txt" "$PHP81_BACKUP/fpm-config-check.txt"
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort >"$PHP81_BACKUP/packages-before.txt"
systemctl show php-fpm httpd -p Id -p ActiveState -p MainPID -p ExecStart >"$PHP81_BACKUP/services-before.txt"
PHP81_CONFIG_PATHS=()
for PHP81_CONFIG in etc/php.ini etc/php.d etc/php-fpm.conf etc/php-fpm.d etc/sysconfig/php-fpm etc/systemd/system/php-fpm.service.d; do
    [[ ! -e "/$PHP81_CONFIG" ]] || PHP81_CONFIG_PATHS+=("$PHP81_CONFIG")
done
tar -C / --acls --xattrs -czpf "$PHP81_BACKUP/configuration.tar.gz" "${PHP81_CONFIG_PATHS[@]}"
printf '\nBackup: %s\n' "$PHP81_BACKUP"
printf 'Maintenance begins now: stop PHP-FPM, replace eight PHP RPMs, validate and start PHP-FPM.\n'
PHP81_CHANGE_STARTED=1
# Stopping first prevents the RPM postun restart hook from restarting FPM midway.
systemctl stop php-fpm
rpm -Uvh "${PHP81_NEW_RPMS[@]}"
for PHP81_NAME in "${PHP81_NAMES[@]}"; do
    [[ $(rpm -q --qf '%{VERSION}|%{RELEASE}|%{ARCH}' "$PHP81_NAME") == "8.1.34|$PHP81_NEW_RELEASE|x86_64" ]] \
        || die "Post-install version mismatch: $PHP81_NAME"
done
env PHP_INI_SCAN_DIR=/etc/php.d /usr/bin/php -c /etc/php.ini -m \
    >"$PHP81_BACKUP/modules-after.txt" 2>"$PHP81_BACKUP/cli-after.stderr"
[[ ! -s "$PHP81_BACKUP/cli-after.stderr" ]] || { cat "$PHP81_BACKUP/cli-after.stderr" >&2; die 'Installed PHP emitted startup diagnostics.'; }
diff -u <(LC_ALL=C sort "$PHP81_BACKUP/modules-before.txt") \
    <(LC_ALL=C sort "$PHP81_BACKUP/modules-after.txt") || die 'Installed PHP module list changed.'
/usr/sbin/php-fpm -t
systemctl start php-fpm
systemctl is-active --quiet php-fpm
PHP81_PID=$(systemctl show php-fpm -p MainPID | awk -F= '$1 == "MainPID" {print $2}')
[[ "$PHP81_PID" =~ ^[1-9][0-9]*$ && -e "/proc/$PHP81_PID/exe" ]] || die 'No running PHP-FPM master was found.'
[[ $(stat -Lc '%d:%i' "/proc/$PHP81_PID/exe") == $(stat -Lc '%d:%i' /usr/sbin/php-fpm) ]] \
    || die 'Running PHP-FPM does not use the installed binary.'
systemctl is-active --quiet httpd || die 'Apache is not active.'
rpm -q "${PHP81_NAMES[@]}"
/usr/bin/php -v
printf '\nUPDATE COMPLETE: PHP remains 8.1.34; RPM release is %s.\n' "$PHP81_NEW_RELEASE"
printf 'PHP-FPM master PID: %s. Configuration and the existing CVE ini file were retained.\n' "$PHP81_PID"
printf 'Now check your existing website, login/session flow, and a small upload.\n'
printf 'Backup and rollback command:\n'
printf 'sudo bash %q rollback %q\n' "$PHP81_BACKUP/bundle/install-rpms.sh" "$PHP81_BACKUP/bundle"
