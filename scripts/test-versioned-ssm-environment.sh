#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-versioned-ssm-test.XXXXXX)"
readonly repository_root temporary_directory
trap 'rm -rf "${temporary_directory}"' EXIT

# shellcheck source=load-ssm-environment.sh
source "${repository_root}/scripts/load-ssm-environment.sh"

readonly parameter_path='/config/docker-nginx-supply/deployvar'
test_required_names=(
  AWS_REPOSITORY
  AWS_ECS_CLUSTER
  AWS_ECS_SERVICE
  AWS_ECS_TASK_FAMILY
  AWS_ECS_CONTAINER_NAME
  AWS_ECS_PORTS
  AWS_ECS_READONLY_ROOTFILESYSTEM
  AWS_ECS_VOLUMES_EFS
)
test_optional_names=(
  AWS_ECS_CONTAINER_MEMORY_RESERVATION
  AWS_ECS_CONTAINER_CPU
  AWS_ECS_FARGATE_CPU
  AWS_ECS_FARGATE_MEMORY
)
test_all_names=("${test_required_names[@]}" "${test_optional_names[@]}")
readonly -a test_required_names test_optional_names test_all_names
readonly absent_optional='AWS_ECS_FARGATE_MEMORY'
readonly hostile_value='$(touch should-not-run); literal value'

mock_mode=snapshot
aws_call_count=0
aws() {
  test "$1" = ssm
  test "$2" = get-parameters
  if [[ "${mock_mode}" == snapshot ]]; then
    test "$3" = --names
    shift 3
  else
    test "$3" = --with-decryption
    test "$4" = --names
    shift 4
  fi
  local -a selectors=()
  while [[ "$#" -gt 0 && "$1" != --output ]]; do
    selectors+=("$1")
    shift
  done
  test "$1" = --output
  test "$2" = json
  test "${#selectors[@]}" -le 10
  aws_call_count=$((aws_call_count + 1))

  local parameters='[]'
  local invalid_parameters='[]'
  local selector full_name name value version modified
  for selector in "${selectors[@]}"; do
    full_name="${selector%:[0-9]*}"
    name="${full_name#"${parameter_path}/"}"
    version=7
    modified='2026-08-26T01:02:03.000Z'
    if [[ "${name}" == "${absent_optional}" ]]; then
      if [[ "${mock_mode}" == optional_appeared ]]; then
        value='unexpected'
      else
        invalid_parameters="$(
          jq -c --arg selector "${selector}" '. + [$selector]' \
            <<< "${invalid_parameters}"
        )"
        continue
      fi
    elif [[ "${mock_mode}" == missing_version &&
            "${name}" == AWS_REPOSITORY ]]; then
      invalid_parameters="$(
        jq -c --arg selector "${selector}" '. + [$selector]' \
          <<< "${invalid_parameters}"
      )"
      continue
    elif [[ "${mock_mode}" == snapshot ]]; then
      value="encrypted-${name}"
    elif [[ "${name}" == AWS_ECS_CONTAINER_MEMORY_RESERVATION ]]; then
      value="${hostile_value}"
    else
      value="value-${name}"
    fi
    if [[ "${mock_mode}" == version_mismatch &&
          "${name}" == AWS_REPOSITORY ]]; then
      version=8
    fi
    if [[ "${mock_mode}" == recreated &&
          "${name}" == AWS_REPOSITORY ]]; then
      modified='2026-08-26T09:09:09.000Z'
    fi
    parameters="$(
      jq -c \
        --arg name "${full_name}" \
        --arg value "${value}" \
        --argjson version "${version}" \
        --arg arn "arn:aws:ssm:us-east-1:409275337247:parameter${full_name}" \
        --arg modified "${modified}" \
        '. + [{
          Name: $name,
          Type: "SecureString",
          Value: $value,
          Version: $version,
          ARN: $arn,
          LastModifiedDate: $modified
        }]' <<< "${parameters}"
    )"
  done
  jq -n \
    --argjson parameters "${parameters}" \
    --argjson invalid "${invalid_parameters}" \
    '{Parameters: ($parameters | reverse), InvalidParameters: $invalid}'
}

manifest_path="${temporary_directory}/deployvar-versions.tsv"
readonly manifest_path
if ! snapshot_ssm_environment \
  "${parameter_path}" \
  "${manifest_path}" \
  --required "${test_required_names[@]}" \
  --optional "${test_optional_names[@]}" \
  > "${temporary_directory}/snapshot.log" 2>&1; then
  sed -n '1,120p' "${temporary_directory}/snapshot.log" >&2
  exit 1
fi
test "${aws_call_count}" = 2
test "$(wc -l < "${manifest_path}" | tr -d ' ')" = 13
test "$(head -n 1 "${manifest_path}")" = nginx-supply-ssm-version-manifest-v1
grep -Fqx $'absent\tAWS_ECS_FARGATE_MEMORY\t-\t-\t-' "${manifest_path}"
test -z "$(tail -n +2 "${manifest_path}" | cut -f2 | LC_ALL=C sort -c 2>&1 || true)"
if grep -Fq "${hostile_value}" "${manifest_path}" "${temporary_directory}/snapshot.log"; then
  echo "A decrypted SSM value leaked into snapshot evidence." >&2
  exit 1
fi

mock_mode=versioned
aws_call_count=0
if ! load_ssm_environment_from_manifest \
  "${parameter_path}" \
  "${manifest_path}" \
  --required "${test_required_names[@]}" \
  --optional "${test_optional_names[@]}" \
  > "${temporary_directory}/load.log" 2>&1; then
  sed -n '1,120p' "${temporary_directory}/load.log" >&2
  exit 1
fi
test "${aws_call_count}" = 2
test "${AWS_REPOSITORY}" = value-AWS_REPOSITORY
test "${AWS_ECS_CONTAINER_MEMORY_RESERVATION}" = "${hostile_value}"
test "${AWS_ECS_VOLUMES_EFS}" = value-AWS_ECS_VOLUMES_EFS
test -z "${AWS_ECS_FARGATE_MEMORY}"
test ! -e should-not-run
if grep -Fq "${hostile_value}" "${temporary_directory}/load.log"; then
  echo "A decrypted SSM value leaked into load output." >&2
  exit 1
fi
for name in "${test_all_names[@]}"; do
  unset "${name}"
done

for failure_mode in version_mismatch recreated optional_appeared missing_version; do
  mock_mode="${failure_mode}"
  if load_ssm_environment_from_manifest \
    "${parameter_path}" \
    "${manifest_path}" \
    --required "${test_required_names[@]}" \
    --optional "${test_optional_names[@]}" \
    > "${temporary_directory}/${failure_mode}.log" 2>&1; then
    echo "Versioned SSM loading accepted ${failure_mode}." >&2
    exit 1
  fi
  for name in "${test_all_names[@]}"; do
    test -z "${!name+x}"
  done
done

echo "Versioned SSM snapshot and exact-load contract passed."
