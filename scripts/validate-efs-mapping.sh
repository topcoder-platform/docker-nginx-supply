#!/usr/bin/env bash

# Validates the one legacy-content EFS mount accepted by Supply releases.

validate_efs_mapping() {
  if [[ "$#" -ne 2 ]]; then
    echo 'Usage: validate_efs_mapping VALUE EXPECTED_SHA256' >&2
    return 2
  fi

  local mapping="$1"
  local expected_sha256="$2"
  local actual_sha256
  local volume_name
  local root_directory
  local container_path
  local filesystem_id
  local unexpected_field
  local path_segment
  local field_separators

  if [[ ! "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'The reviewed EFS mapping SHA-256 is not committed.' >&2
    return 1
  fi
  if [[ -z "${mapping}" || "${mapping}" == *[$'\t\r\n ']* || "${mapping}" == *,* ]]; then
    echo 'Supply requires exactly one whitespace-free EFS mapping.' >&2
    return 1
  fi
  field_separators="${mapping//[^:]/}"
  if [[ "${#field_separators}" -ne 3 ]]; then
    echo 'The EFS mapping must contain exactly four non-empty fields.' >&2
    return 1
  fi
  actual_sha256="$(printf '%s' "${mapping}" | sha256sum | awk '{print $1}')"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo 'The EFS mapping does not match the reviewed SHA-256.' >&2
    return 1
  fi

  IFS=':' read -r volume_name root_directory container_path filesystem_id unexpected_field \
    <<< "${mapping}"
  if [[ -n "${unexpected_field}" || -z "${volume_name}" || -z "${root_directory}" ||
        -z "${container_path}" || -z "${filesystem_id}" ]]; then
    echo 'The EFS mapping must contain exactly four non-empty fields.' >&2
    return 1
  fi
  if [[ ! "${volume_name}" =~ ^[A-Za-z0-9_-]{1,255}$ ]]; then
    echo 'The EFS volume name is invalid.' >&2
    return 1
  fi
  if [[ ! "${root_directory}" =~ ^/[A-Za-z0-9._/-]*$ || "${root_directory}" == *'//'* ]]; then
    echo 'The EFS root directory is invalid.' >&2
    return 1
  fi
  IFS='/' read -r -a root_segments <<< "${root_directory}"
  for path_segment in "${root_segments[@]}"; do
    if [[ "${path_segment}" == '.' || "${path_segment}" == '..' ]]; then
      echo 'The EFS root directory must not contain traversal segments.' >&2
      return 1
    fi
  done
  if [[ "${container_path}" != /data/nginx ]]; then
    echo 'The EFS mapping must mount at /data/nginx.' >&2
    return 1
  fi
  if [[ ! "${filesystem_id}" =~ ^fs-[0-9a-f]{8}([0-9a-f]{9})?$ ]]; then
    echo 'The EFS filesystem ID is invalid.' >&2
    return 1
  fi

  declare -gr VALIDATED_EFS_VOLUME_NAME="${volume_name}"
  declare -gr VALIDATED_EFS_ROOT_DIRECTORY="${root_directory}"
  declare -gr VALIDATED_EFS_CONTAINER_PATH="${container_path}"
  declare -gr VALIDATED_EFS_FILESYSTEM_ID="${filesystem_id}"
  declare -gr VALIDATED_EFS_MAPPING_SHA256="${actual_sha256}"
}
