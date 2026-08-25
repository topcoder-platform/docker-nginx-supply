#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-ssm-test.XXXXXX)"
readonly repository_root temporary_directory
trap 'rm -rf "${temporary_directory}"' EXIT

# shellcheck source=load-ssm-environment.sh
source "${repository_root}/scripts/load-ssm-environment.sh"

mock_mode=valid
aws() {
  test "$1" = ssm
  test "$2" = get-parameters
  test "$3" = --with-decryption
  case "${mock_mode}" in
    valid)
      jq -n \
        --arg injection '$(touch should-not-run)' \
        --arg multiline $'line one\nline two\n' \
        '{Parameters: [
          {Name: "/config/docker-nginx-supply/deployvar/SAFE_VALUE", Type: "SecureString", Value: "plain"},
          {Name: "/config/docker-nginx-supply/deployvar/INJECTION_VALUE", Type: "SecureString", Value: $injection},
          {Name: "/config/docker-nginx-supply/deployvar/MULTILINE_VALUE", Type: "SecureString", Value: $multiline}
        ], InvalidParameters: ["/config/docker-nginx-supply/deployvar/OPTIONAL_VALUE"]}'
      ;;
    unallowlisted)
      jq -n '{Parameters: [
        {Name: "/config/docker-nginx-supply/deployvar/UNALLOWLISTED_VALUE", Type: "SecureString", Value: "overridden"}
      ], InvalidParameters: ["/config/docker-nginx-supply/deployvar/SAFE_VALUE"]}'
      ;;
    missing)
      jq -n '{Parameters: [], InvalidParameters: [
        "/config/docker-nginx-supply/deployvar/SAFE_VALUE"
      ]}'
      ;;
    wrong_type)
      jq -n '{Parameters: [
        {Name: "/config/docker-nginx-supply/deployvar/SAFE_VALUE", Type: "String", Value: "plain"}
      ], InvalidParameters: []}'
      ;;
    unexpected_invalid)
      jq -n '{Parameters: [
        {Name: "/config/docker-nginx-supply/deployvar/SAFE_VALUE", Type: "SecureString", Value: "plain"}
      ], InvalidParameters: [
        "/config/docker-nginx-supply/deployvar/UNALLOWLISTED_VALUE"
      ]}'
      ;;
    contradictory_invalid)
      jq -n '{Parameters: [
        {Name: "/config/docker-nginx-supply/deployvar/SAFE_VALUE", Type: "SecureString", Value: "plain"}
      ], InvalidParameters: [
        "/config/docker-nginx-supply/deployvar/SAFE_VALUE"
      ]}'
      ;;
    incomplete_optional)
      jq -n '{Parameters: [
        {Name: "/config/docker-nginx-supply/deployvar/SAFE_VALUE", Type: "SecureString", Value: "plain"}
      ], InvalidParameters: []}'
      ;;
    *)
      return 1
      ;;
  esac
}

cd "${temporary_directory}"
load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE INJECTION_VALUE MULTILINE_VALUE \
  --optional OPTIONAL_VALUE
test "${SAFE_VALUE}" = plain
test "${INJECTION_VALUE}" = '$(touch should-not-run)'
test "${MULTILINE_VALUE}" = $'line one\nline two\n'
test -z "${OPTIONAL_VALUE}"
test -n "${OPTIONAL_VALUE+x}"
test ! -e should-not-run
unset SAFE_VALUE INJECTION_VALUE MULTILINE_VALUE OPTIONAL_VALUE

OPTIONAL_VALUE='inherited-value'
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE \
  --optional OPTIONAL_VALUE; then
  echo "Pre-set optional SSM variable was accepted." >&2
  exit 1
fi
test "${OPTIONAL_VALUE}" = inherited-value
unset OPTIONAL_VALUE

mock_mode=unallowlisted
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE; then
  echo "Unallowlisted SSM variable name was accepted." >&2
  exit 1
fi
test -z "${UNALLOWLISTED_VALUE:-}"

mock_mode=missing
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE; then
  echo "Missing required SSM value was accepted." >&2
  exit 1
fi

mock_mode=wrong_type
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE; then
  echo "Non-SecureString SSM value was accepted." >&2
  exit 1
fi

mock_mode=unexpected_invalid
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE; then
  echo "Unallowlisted invalid SSM name was accepted." >&2
  exit 1
fi

mock_mode=contradictory_invalid
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE; then
  echo "Contradictory present/invalid SSM name was accepted." >&2
  exit 1
fi

mock_mode=incomplete_optional
if load_ssm_environment /config/docker-nginx-supply/deployvar \
  --required SAFE_VALUE \
  --optional OPTIONAL_VALUE; then
  echo "Incomplete optional SSM response was accepted." >&2
  exit 1
fi

echo "Safe SSM environment loader contract passed."
