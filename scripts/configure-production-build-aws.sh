#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly authority_boundary_status="${PRODUCTION_AUTHORITY_BOUNDARY_STATUS:-}"
if [[ "${authority_boundary_status}" != VERIFIED_EXTERNAL_AUTHORITY_GATE ]]; then
  echo "Production build authority is blocked until an external job/approval gate is implemented." >&2
  exit 1
fi

readonly expected_account_id="${EXPECTED_AWS_ACCOUNT_ID:?EXPECTED_AWS_ACCOUNT_ID is required}"
readonly expected_build_role_arn="arn:aws:iam::409275337247:role/circleci-docker-nginx-supply-prod-build"
readonly build_role_arn="${AWS_PRODUCTION_BUILD_ROLE_ARN:?AWS_PRODUCTION_BUILD_ROLE_ARN is required}"
readonly kms_key_arn="${AWS_PRODUCTION_BUILD_KMS_KEY_ARN:?AWS_PRODUCTION_BUILD_KMS_KEY_ARN is required}"
readonly oidc_token="${CIRCLE_OIDC_TOKEN_V2:?CIRCLE_OIDC_TOKEN_V2 is required}"
readonly aws_region="${AWS_REGION:-us-east-1}"

[[ "${expected_account_id}" =~ ^[0-9]{12}$ ]]
test "${expected_account_id}" = 409275337247
test "${build_role_arn}" = "${expected_build_role_arn}"
test "${aws_region}" = us-east-1
[[ "${kms_key_arn}" =~ ^arn:aws:kms:us-east-1:${expected_account_id}:key/[0-9a-f-]{36}$ ]]

if [[ "$#" -eq 0 ]]; then
  echo "At least one exact production build parameter name is required." >&2
  exit 2
fi
declare -A parameter_lookup=()
declare -a parameter_arns=()
for parameter_name in "$@"; do
  case "${parameter_name}" in
    ENV_PLATFORM_UI_RESOLVER) ;;
    *)
      echo "Production build requested a non-allowlisted parameter." >&2
      exit 2
      ;;
  esac
  if [[ -n "${parameter_lookup[$parameter_name]:-}" ]]; then
    echo "Production build requested a duplicate parameter." >&2
    exit 2
  fi
  parameter_lookup["${parameter_name}"]=1
  parameter_arns+=(
    "arn:aws:ssm:${aws_region}:${expected_account_id}:parameter/config/docker-nginx-supply/buildvar/${parameter_name}"
  )
done

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
    printf 'Production build context injected a forbidden AWS provider: %s\n' \
      "${inherited_credential_name}" >&2
    exit 1
  fi
done
while IFS= read -r endpoint_variable_name; do
  printf 'Production build context injected a forbidden AWS endpoint override: %s\n' \
    "${endpoint_variable_name}" >&2
  exit 1
done < <(compgen -A variable AWS_ENDPOINT_URL_)
if [[ -s "${HOME}/.aws/credentials" || -s "${HOME}/.aws/config" ]]; then
  echo "The production build image contains an unexpected AWS credential/config file." >&2
  exit 1
fi

credentials_file="$(mktemp /tmp/nginx-supply-build-role.XXXXXX.json)"
readonly credentials_file
session_policy_file="$(mktemp /tmp/nginx-supply-build-policy.XXXXXX.json)"
readonly session_policy_file
trap 'rm -f "${credentials_file}" "${session_policy_file}"' EXIT

parameter_arns_json="$(printf '%s\n' "${parameter_arns[@]}" | jq -R . | jq -s .)"
readonly parameter_arns_json
jq -n \
  --arg account "${expected_account_id}" \
  --arg via_service "ssm.${aws_region}.amazonaws.com" \
  --arg kms_key "${kms_key_arn}" \
  --argjson parameters "${parameter_arns_json}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: "ssm:GetParameters",
        Resource: $parameters
      },
      {
        Effect: "Allow",
        Action: "kms:Decrypt",
        Resource: $kms_key,
        Condition: {
          StringEquals: {
            "kms:CallerAccount": $account,
            "kms:ViaService": $via_service,
            "kms:EncryptionContext:PARAMETER_ARN": $parameters
          }
        }
      }
    ]
  }' > "${session_policy_file}"
session_policy="$(jq -c . "${session_policy_file}")"
readonly session_policy
if (( ${#session_policy} > 2048 )); then
  echo "Production build session policy exceeds the STS 2,048-character limit." >&2
  exit 1
fi

session_suffix="${CIRCLE_WORKFLOW_ID:-local}"
session_suffix="${session_suffix//[^A-Za-z0-9+=,.@-]/-}"
session_suffix="${session_suffix:0:38}"
readonly session_suffix
readonly session_name="nginx-supply-build-${session_suffix}"

aws sts assume-role-with-web-identity \
  --role-arn "${build_role_arn}" \
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
caller_account_id="$(jq -er '.Account' <<< "${caller_identity}")"
readonly caller_account_id
test "${caller_account_id}" = "${expected_account_id}"
caller_arn="$(jq -er '.Arn' <<< "${caller_identity}")"
readonly caller_arn
test "${caller_arn}" = \
  "arn:aws:sts::409275337247:assumed-role/circleci-docker-nginx-supply-prod-build/${session_name}"

echo "Least-privilege production build role assumed for account ${caller_account_id}."
