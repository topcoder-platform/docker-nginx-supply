#!/usr/bin/env bash
set -euo pipefail
set +x

readonly credential_directory="${NONPRODUCTION_AWS_CREDENTIAL_DIRECTORY:?NONPRODUCTION_AWS_CREDENTIAL_DIRECTORY is required}"
if [[ ! "${credential_directory}" =~ ^/tmp/nginx-supply-nonprod-aws\.[A-Za-z0-9]+$ ]]; then
  echo "Refusing to clean an invalid non-production credential path." >&2
  exit 1
fi
if [[ "${AWS_CONFIG_FILE:-}" != "${credential_directory}/config" ||
      "${AWS_SHARED_CREDENTIALS_FILE:-}" != "${credential_directory}/credentials" ]]; then
  echo "Non-production AWS credential paths do not match their owned directory." >&2
  exit 1
fi
if [[ -d "${credential_directory}" ]]; then
  find "${credential_directory}" -mindepth 1 -delete
  rmdir "${credential_directory}"
fi
