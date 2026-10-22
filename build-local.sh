#!/usr/bin/env bash
# Run the AL2 RPM build on this PC's local Docker daemon.
# Usage: BUILD_JOBS=2 bash build-local.sh
set -Eeuo pipefail
umask 022
export LC_ALL=C

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || die 'Run from Ubuntu/Linux or a WSL2 Ubuntu terminal.'
[[ $(uname -m) == x86_64 ]] || die 'This kit supports an x86_64 local PC, matching the EC2 server.'
[[ $(id -u) -ne 0 ]] || die 'Run as your normal local user, without sudo. See README-ja.md for Docker access setup.'
for required_command in docker sha256sum mktemp tee stat hostname; do
  command -v "$required_command" >/dev/null 2>&1 || die "Missing command: $required_command"
done
[[ $(hostname -s) != ip-172-31-40-13 ]] \
  || die 'This is the production EC2 host. Run build-local.sh on your local PC.'

BUILD_JOBS=${BUILD_JOBS:-2}
BUILD_CPUS=${BUILD_CPUS:-2}
BUILD_MEMORY=${BUILD_MEMORY:-4g}
for number_setting in BUILD_JOBS BUILD_CPUS; do
  number_value=${!number_setting}
  [[ $number_value =~ ^[1-9][0-9]*$ && ${#number_value} -le 3 && $number_value -le 128 ]] \
    || die "$number_setting must be an integer from 1 to 128."
done
[[ $BUILD_MEMORY =~ ^[1-9][0-9]{0,5}[gm]$ ]] \
  || die 'BUILD_MEMORY must use lowercase g or m, for example 4g or 4096m.'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case "$script_dir" in
  *','*|*$'\n'*|*$'\r'*) die 'Extract the kit into a path without commas or line breaks.' ;;
esac
for required_file in build-rpms.sh install-rpms.sh container-build.sh; do
  [[ -f "$script_dir/$required_file" && ! -L "$script_dir/$required_file" ]] \
    || die "Missing or symlinked kit file: $required_file"
done
if [[ -f "$script_dir/KIT-SHA256SUMS" ]]; then
  (cd -- "$script_dir" && sha256sum --check --strict KIT-SHA256SUMS)
fi

# Resolve the effective Docker endpoint, then pass it explicitly to every
# daemon command. SSH/TCP contexts are rejected to keep builds on this PC.
docker_context=${DOCKER_CONTEXT:-}
if [[ -n $docker_context ]]; then
  docker_endpoint=$(env -u DOCKER_HOST -u DOCKER_CONTEXT docker context inspect \
    "$docker_context" --format '{{.Endpoints.docker.Host}}')
elif [[ -n ${DOCKER_HOST:-} ]]; then
  docker_endpoint=$DOCKER_HOST
else
  docker_context=$(env -u DOCKER_HOST -u DOCKER_CONTEXT docker context show)
  docker_endpoint=$(env -u DOCKER_HOST -u DOCKER_CONTEXT docker context inspect \
    "$docker_context" --format '{{.Endpoints.docker.Host}}')
fi
case "$docker_endpoint" in
  unix:///*) docker_socket=${docker_endpoint#unix://} ;;
  *) die "A local unix-socket Docker daemon is required; refused endpoint: $docker_endpoint" ;;
esac
[[ -S "$docker_socket" ]] || die "Local Docker socket not found: $docker_socket. Start Docker first."
docker_local() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host "$docker_endpoint" "$@"
}
if ! docker_local info >/dev/null; then
  die 'Cannot access local Docker. Run docker info successfully as this normal user before continuing; see README-ja.md.'
fi
[[ $(docker_local info --format '{{.OSType}}') == linux ]] \
  || die 'Docker must be running Linux containers.'
daemon_arch=$(docker_local info --format '{{.Architecture}}')
[[ $daemon_arch == x86_64 || $daemon_arch == amd64 ]] \
  || die 'The local Docker daemon must use x86_64/amd64.'

output_dir="$script_dir/output"
[[ ! -L "$output_dir" ]] || die 'The output directory must not be a symbolic link.'
mkdir -p -- "$output_dir"
[[ -w "$output_dir" && $(stat -c %u "$output_dir") == "$(id -u)" ]] \
  || die 'The output directory must be writable and owned by your current local user.'
bundle_name=php81-rpms-8.1.34-cve20261021.1
[[ ! -e "$output_dir/$bundle_name.tar.gz" && ! -e "$output_dir/$bundle_name.tar.gz.sha256" ]] \
  || die 'A completed or partial delivery archive already exists in output/. Preserve it elsewhere before rebuilding.'

run_log_dir=$(mktemp -d "$output_dir/local-build-$(date -u '+%Y%m%dT%H%M%SZ')-XXXXXXXX")
exec > >(tee -a "$run_log_dir/console.log") 2>&1
trap 'build_rc=$?; printf "Local build stopped (exit %s). Logs: %s\n" "$build_rc" "$run_log_dir" >&2; exit "$build_rc"' ERR

image_tag=public.ecr.aws/amazonlinux/amazonlinux:2
printf 'All compilation runs on this PC through local Docker.\n'
printf 'Local Docker endpoint: %s\nCPU quota: %s\nRAM limit: %s (no extra container swap)\nParallel jobs: %s\n' \
  "$docker_endpoint" "$BUILD_CPUS" "$BUILD_MEMORY" "$BUILD_JOBS"
printf 'Output directory: %s\nConsole log: %s\n' "$output_dir" "$run_log_dir/console.log"

docker_local pull --platform linux/amd64 "$image_tag"
image_digest=
while IFS= read -r candidate_digest; do
  if [[ $candidate_digest =~ ^public\.ecr\.aws/amazonlinux/amazonlinux@sha256:[0-9a-f]{64}$ ]]; then
    image_digest=$candidate_digest
    break
  fi
done < <(docker_local image inspect "$image_tag" --format '{{range .RepoDigests}}{{println .}}{{end}}')
[[ -n $image_digest ]] || die 'Could not resolve the official AL2 image to an immutable repository digest.'
[[ $(docker_local image inspect "$image_tag" --format '{{.Os}}/{{.Architecture}}') == linux/amd64 ]] \
  || die 'The pulled AL2 image is not linux/amd64.'

container_name="php81-local-$(id -u)-$(date -u '+%Y%m%d%H%M%S')-$RANDOM"
cat > "$run_log_dir/environment.txt" <<METADATA
Started UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Docker endpoint: $docker_endpoint
Image tag requested: $image_tag
Image digest executed: $image_digest
Platform: linux/amd64
CPU quota: $BUILD_CPUS
RAM limit: $BUILD_MEMORY
Memory plus swap limit: $BUILD_MEMORY
Parallel compiler jobs: $BUILD_JOBS
Container name: $container_name
Docker daemon version: $(docker_local version --format '{{.Server.Version}}')
This file records the local container environment; it is not a build-success report.
METADATA
printf 'Pinned image for this run: %s\nContainer name: %s\n' "$image_digest" "$container_name"

# Only the kit and its output directory are mounted. Host PHP, credentials,
# home directories, and the Docker socket are not mounted into the container.
docker_local run --rm --init --name "$container_name" \
  --hostname php81-local-build \
  --platform linux/amd64 \
  --cpus "$BUILD_CPUS" \
  --memory "$BUILD_MEMORY" --memory-swap "$BUILD_MEMORY" \
  --mount "type=bind,source=$script_dir,target=/kit,readonly" \
  --mount "type=bind,source=$output_dir,target=/work" \
  --env "BUILD_UID=$(id -u)" --env "BUILD_GID=$(id -g)" \
  --env "BUILD_JOBS=$BUILD_JOBS" \
  "$image_digest" /bin/bash /kit/container-build.sh

[[ -s "$output_dir/$bundle_name.tar.gz" && -s "$output_dir/$bundle_name.tar.gz.sha256" ]] \
  || die 'The container exited without both expected delivery files.'
(cd -- "$output_dir" && sha256sum --check --strict "$bundle_name.tar.gz.sha256")
printf '\nLOCAL BUILD COMPLETED\n'
printf 'Upload these two files to GitHub Releases or transfer them to EC2:\n%s\n%s\n' \
  "$output_dir/$bundle_name.tar.gz" "$output_dir/$bundle_name.tar.gz.sha256"
printf 'No production server was contacted or updated. Keep output/ until deployment checks are complete.\n'
