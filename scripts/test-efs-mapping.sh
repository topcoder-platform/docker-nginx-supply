#!/usr/bin/env bash

set -euo pipefail

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly valid_mapping='legacy-content:/published:/data/nginx:fs-0123456789abcdef0'
valid_sha256="$(printf '%s' "${valid_mapping}" | sha256sum | awk '{print $1}')"
readonly valid_sha256

source "${script_directory}/validate-efs-mapping.sh"
validate_efs_mapping "${valid_mapping}" "${valid_sha256}"
test "${VALIDATED_EFS_VOLUME_NAME}" = legacy-content
test "${VALIDATED_EFS_ROOT_DIRECTORY}" = /published
test "${VALIDATED_EFS_CONTAINER_PATH}" = /data/nginx
test "${VALIDATED_EFS_FILESYSTEM_ID}" = fs-0123456789abcdef0
test "${VALIDATED_EFS_MAPPING_SHA256}" = "${valid_sha256}"

assert_rejected() {
  local value="$1"
  local expected_sha256="$2"
  if (
    source "${script_directory}/validate-efs-mapping.sh"
    validate_efs_mapping "${value}" "${expected_sha256}"
  ) >/dev/null 2>&1; then
    echo 'Unsafe EFS mapping unexpectedly passed.' >&2
    exit 1
  fi
}

assert_rejected "${valid_mapping}" INVENTORY_REQUIRED
assert_rejected "${valid_mapping}" "$(printf '%064d' 0)"
assert_rejected '' "$(printf '' | sha256sum | awk '{print $1}')"
assert_rejected 'legacy content:/published:/data/nginx:fs-0123456789abcdef0' \
  "$(printf '%s' 'legacy content:/published:/data/nginx:fs-0123456789abcdef0' | sha256sum | awk '{print $1}')"
assert_rejected 'legacy-content:/published:/data/nginx:fs-0123456789abcdef0:' \
  "$(printf '%s' 'legacy-content:/published:/data/nginx:fs-0123456789abcdef0:' | sha256sum | awk '{print $1}')"
assert_rejected 'legacy-content:/published:/etc/nginx:fs-0123456789abcdef0' \
  "$(printf '%s' 'legacy-content:/published:/etc/nginx:fs-0123456789abcdef0' | sha256sum | awk '{print $1}')"
assert_rejected 'legacy-content:/../private:/data/nginx:fs-0123456789abcdef0' \
  "$(printf '%s' 'legacy-content:/../private:/data/nginx:fs-0123456789abcdef0' | sha256sum | awk '{print $1}')"
assert_rejected 'legacy-content:/:/data/nginx:fs-invalid' \
  "$(printf '%s' 'legacy-content:/:/data/nginx:fs-invalid' | sha256sum | awk '{print $1}')"
assert_rejected 'one:/:/data/nginx:fs-01234567,two:/:/data/nginx:fs-89abcdef' \
  "$(printf '%s' 'one:/:/data/nginx:fs-01234567,two:/:/data/nginx:fs-89abcdef' | sha256sum | awk '{print $1}')"

echo 'Exact legacy-content EFS mapping contract passed.'
