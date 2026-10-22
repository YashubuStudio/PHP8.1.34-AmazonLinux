#!/usr/bin/env bash
# Internal bootstrap. build-local.sh runs this only inside a disposable AL2 container.
set -Eeuo pipefail
umask 022
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 && -f /.dockerenv ]] \
  || die 'This bootstrap is for the Docker container only; run build-local.sh on your PC.'
[[ -r /etc/os-release ]] || die 'Missing OS identity.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == amzn && ${VERSION_ID:-} == 2 && $(uname -m) == x86_64 ]] \
  || die 'The container must be Amazon Linux 2 / x86_64.'
[[ -r /kit/build-rpms.sh && -r /kit/install-rpms.sh && -d /work ]] \
  || die 'The required /kit and /work mounts are missing.'

for build_identity in BUILD_UID BUILD_GID; do
  identity_value=${!build_identity:-}
  [[ $identity_value =~ ^[1-9][0-9]{0,8}$ ]] \
    || die "$build_identity must be the invoking non-root user's numeric identity."
done
[[ ${BUILD_JOBS:-} =~ ^[1-9][0-9]{0,2}$ && $BUILD_JOBS -le 128 ]] \
  || die 'BUILD_JOBS must be an integer from 1 to 128.'

printf 'Preparing tools and an unprivileged build user inside the AL2 container.\n'
yum --disablerepo='*' --enablerepo=amzn2-core install -y \
  sudo shadow-utils util-linux findutils tar gzip procps-ng hostname

getent passwd "$BUILD_UID" >/dev/null && die "Container UID $BUILD_UID is already used; review the UID mapping."
getent passwd php81builder >/dev/null && die 'The container build username already exists.'
if ! getent group "$BUILD_GID" >/dev/null; then
  groupadd --gid "$BUILD_GID" php81build
fi
useradd --uid "$BUILD_UID" --gid "$BUILD_GID" --create-home \
  --shell /bin/bash php81builder
install -d -m 0750 /etc/sudoers.d
cat > /etc/sudoers.d/php81builder <<'SUDOERS'
Defaults:php81builder !requiretty
php81builder ALL=(root) NOPASSWD: ALL
SUDOERS
chmod 0440 /etc/sudoers.d/php81builder
visudo -cf /etc/sudoers.d/php81builder

if ! runuser -u php81builder -- test -w /work; then
  die 'The build user cannot write /work. Use a user-owned output directory on the local Linux filesystem; rootless/user-namespace remapping may need a different UID strategy.'
fi
printf 'Starting RPM build as UID %s, GID %s. Host PHP is outside this container.\n' "$BUILD_UID" "$BUILD_GID"
exec runuser -u php81builder -- env "BUILD_JOBS=$BUILD_JOBS" \
  /bin/bash -c 'cd /work && exec /bin/bash /kit/build-rpms.sh'
