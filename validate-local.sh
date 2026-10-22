#!/usr/bin/env bash
# Test a built bundle using real installed RPMs in a fresh local AL2 container.
set -Eeuo pipefail
umask 022
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && $(id -u) != 0 && $(uname -s) == Linux && $(uname -m) == x86_64 ]] \
    || die 'Usage, as your ordinary local Linux user: bash validate-local.sh BUNDLE_DIR'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bundle=$(realpath -- "$1")
[[ -d $bundle/new && -d $bundle/old && -f $bundle/SHA256SUMS ]] || die 'Expected an extracted build bundle.'
case "$script_dir,$bundle" in *$'\n'*|*$'\r'*) die 'Paths must not contain line breaks.' ;; esac
[[ $script_dir != *,* && $bundle != *,* ]] || die 'Paths must not contain commas.'
(cd -- "$bundle" && sha256sum --check --strict SHA256SUMS)

if [[ -n ${DOCKER_CONTEXT:-} ]]; then
    endpoint=$(env -u DOCKER_HOST -u DOCKER_CONTEXT docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
elif [[ -n ${DOCKER_HOST:-} ]]; then
    endpoint=$DOCKER_HOST
else
    context=$(env -u DOCKER_HOST -u DOCKER_CONTEXT docker context show)
    endpoint=$(env -u DOCKER_HOST -u DOCKER_CONTEXT docker context inspect "$context" --format '{{.Endpoints.docker.Host}}')
fi
[[ $endpoint == unix:///* && -S ${endpoint#unix://} ]] || die 'A local Unix-socket Docker daemon is required.'
docker_local() {
    env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        docker --host "$endpoint" "$@"
}
image=public.ecr.aws/amazonlinux/amazonlinux@sha256:ee98817857ba78c33457304c9b6d81579322e9a464847c6e54207f44ce46f70c
mkdir -p "$script_dir/output"
results=$(mktemp -d "$script_dir/output/runtime-validation-$(date -u '+%Y%m%dT%H%M%SZ')-XXXXXXXX")
cp -- "$bundle/SHA256SUMS" "$results/input-bundle-SHA256SUMS"
exec > >(tee -a "$results/console.log") 2>&1
printf 'Runtime validation results: %s\nPinned AL2 image: %s\n' "$results" "$image"
started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
docker_local run --rm --init --platform linux/amd64 \
    --name "php81-runtime-$(id -u)-$(date -u '+%Y%m%d%H%M%S')-$RANDOM" \
    --hostname php81-runtime-validation --cpus 2 --memory 4g --memory-swap 4g \
    --mount "type=bind,source=$script_dir,target=/kit,readonly" \
    --mount "type=bind,source=$bundle,target=/bundle,readonly" \
    --mount "type=bind,source=$results,target=/results" \
    --env "RESULT_UID=$(id -u)" --env "RESULT_GID=$(id -g)" \
    "$image" /bin/bash /kit/tests/container-runtime.sh
python3 - "$results" "$image" "$started" "$script_dir" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
phases = {phase: json.loads((root / ('http-' + phase + '.json')).read_text())
          for phase in ('original', 'candidate', 'rollback', 'reapplied')}
candidate = phases['candidate']
assert candidate['parallel_requests'] == 100
assert candidate['session_requests'] == 10
assert candidate['multipart_upload_and_disabled_progress']
assert candidate['bounded_oom_and_fpm_recovery']
rpm_hashes = {}
for line in (root / 'input-bundle-SHA256SUMS').read_text().splitlines():
    digest, path = line.split('  ', 1)
    if path.startswith(('new/', 'old/')):
        rpm_hashes[path] = digest
assert len(rpm_hashes) == 16
report = {
    'status': 'passed', 'started_utc': sys.argv[3],
    'completed_utc': datetime.now(timezone.utc).isoformat(),
    'image': sys.argv[2], 'architecture': 'x86_64',
    'cpu_limit': 2, 'memory_limit': '4g',
    'rpm_sha256': rpm_hashes, 'phases': phases,
    'harness_sha256': {name: hashlib.sha256((Path(sys.argv[4]) / name).read_bytes()).hexdigest()
                       for name in ('validate-local.sh', 'tests/container-runtime.sh',
                                    'tests/http-runtime.py', 'tests/runtime.php')},
    'configuration_preserved': True,
    'module_list_preserved': True,
    'bounded_cli_oom_original_rollback_exit': 255,
    'bounded_cli_oom_candidate_reapplied_exit': 1,
    'limitations': [
        'Isolated Apache/PHP-FPM/MariaDB fixtures; production applications and traffic were not tested.',
        'Actual RPM update/rollback/reapply tested; systemd-dependent install-rpms.sh orchestration was not executed in this non-systemd container.',
    ],
}
(root / 'runtime-validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print('RUNTIME VALIDATION PASSED. Report: ' + str(root / 'runtime-validation.json'))
PY
