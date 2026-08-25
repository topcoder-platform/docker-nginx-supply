#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly authority_boundary_status="${PRODUCTION_AUTHORITY_BOUNDARY_STATUS:-}"
if [[ "${authority_boundary_status}" != VERIFIED_EXTERNAL_AUTHORITY_GATE ]]; then
  echo "Production snapshot authority is blocked until an external job/approval gate is implemented." >&2
  exit 1
fi

readonly expected_account_id="${EXPECTED_AWS_ACCOUNT_ID:?EXPECTED_AWS_ACCOUNT_ID is required}"
readonly expected_role_name='circleci-docker-nginx-supply-prod-deployvar-snapshot'
readonly expected_role_arn="arn:aws:iam::409275337247:role/${expected_role_name}"
readonly role_arn="${AWS_PRODUCTION_DEPLOYVAR_SNAPSHOT_ROLE_ARN:?AWS_PRODUCTION_DEPLOYVAR_SNAPSHOT_ROLE_ARN is required}"
readonly oidc_token="${CIRCLE_OIDC_TOKEN_V2:?CIRCLE_OIDC_TOKEN_V2 is required}"
readonly aws_region="${AWS_REGION:-us-east-1}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_directory

test "${expected_account_id}" = 409275337247
test "${role_arn}" = "${expected_role_arn}"
test "${aws_region}" = us-east-1

for inherited_credential_name in \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  AWS_SESSION_TOKEN \
  AWS_SECURITY_TOKEN \
  AWS_PROFILE \
  AWS_DEFAULT_PROFILE \
  AWS_SHARED_CREDENTIALS_FILE \
  AWS_CONFIG_FILE \
  AWS_WEB_IDENTITY_TOKEN_FILE \
  AWS_ROLE_ARN \
  AWS_CONTAINER_CREDENTIALS_FULL_URI \
  AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_CA_BUNDLE \
  AWS_ENDPOINT_URL
do
  if [[ -n "${!inherited_credential_name+x}" ]]; then
    printf 'Production snapshot context injected a forbidden AWS provider: %s\n' \
      "${inherited_credential_name}" >&2
    exit 1
  fi
done
while IFS= read -r endpoint_variable_name; do
  printf 'Production snapshot context injected a forbidden AWS endpoint override: %s\n' \
    "${endpoint_variable_name}" >&2
  exit 1
done < <(compgen -A variable AWS_ENDPOINT_URL_)
if [[ -s "${HOME}/.aws/credentials" || -s "${HOME}/.aws/config" ]]; then
  echo "The production snapshot image contains an unexpected AWS credential/config file." >&2
  exit 1
fi

credentials_file="$(mktemp /tmp/nginx-supply-snapshot-role.XXXXXX.json)"
readonly credentials_file
trap 'rm -f "${credentials_file}"' EXIT

session_policy="$(
  "${script_directory}/generate-production-snapshot-session-policy.sh" \
    "${expected_account_id}" \
    "${aws_region}"
)"
readonly session_policy
if (( ${#session_policy} > 2048 )); then
  echo "Production snapshot session policy exceeds the STS 2,048-character limit." >&2
  exit 1
fi

session_suffix="${CIRCLE_WORKFLOW_ID:-local}"
session_suffix="${session_suffix//[^A-Za-z0-9+=,.@-]/-}"
session_suffix="${session_suffix:0:35}"
readonly session_suffix
readonly session_name="nginx-supply-snapshot-${session_suffix}"

aws sts assume-role-with-web-identity \
  --role-arn "${role_arn}" \
  --role-session-name "${session_name}" \
  --web-identity-token "${oidc_token}" \
  --duration-seconds 900 \
  --policy "${session_policy}" \
  --region "${aws_region}" \
  --output json > "${credentials_file}"

jq -e '
  (.Credentials.AccessKeyId | type == "string" and length > 0) and
  (.Credentials.SecretAccessKey | type == "string" and length > 0) and
  (.Credentials.SessionToken | type == "string" and length > 0)
' "${credentials_file}" >/dev/null

aws configure set default.region "${aws_region}"
aws configure set default.output json
aws configure set aws_access_key_id \
  "$(jq -r '.Credentials.AccessKeyId' "${credentials_file}")"
aws configure set aws_secret_access_key \
  "$(jq -r '.Credentials.SecretAccessKey' "${credentials_file}")"
aws configure set aws_session_token \
  "$(jq -r '.Credentials.SessionToken' "${credentials_file}")"

caller_identity="$(aws sts get-caller-identity --output json)"
readonly caller_identity
test "$(jq -er '.Account' <<< "${caller_identity}")" = "${expected_account_id}"
caller_arn="$(jq -er '.Arn' <<< "${caller_identity}")"
readonly caller_arn
test "${caller_arn}" = \
  "arn:aws:sts::409275337247:assumed-role/${expected_role_name}/${session_name}"

echo "Least-privilege production deploy-variable snapshot role assumed."
