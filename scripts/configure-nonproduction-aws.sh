#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

if [[ "$#" -ne 1 ]]; then
  echo "Usage: configure-nonproduction-aws.sh DEV|QA" >&2
  exit 2
fi
readonly deploy_environment="$1"
case "${deploy_environment}" in
  DEV | QA) ;;
  *)
    echo "Non-production AWS authentication is restricted to DEV or QA." >&2
    exit 2
    ;;
esac

readonly expected_account_id="${EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID:?EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID is required}"
readonly expected_region='us-east-1'
readonly expected_role_name="${EXPECTED_NONPRODUCTION_AWS_ROLE_NAME:?EXPECTED_NONPRODUCTION_AWS_ROLE_NAME is required}"
readonly auth0_url="${CI_AUTH0_URL:?CI_AUTH0_URL is required}"
readonly auth0_url_pattern='^https://[A-Za-z0-9.-]+(:443)?/[A-Za-z0-9._~/?=&%-]*$'
[[ "${auth0_url}" =~ ${auth0_url_pattern} ]]
if [[ ! "${expected_account_id}" =~ ^[0-9]{12}$ ]]; then
  echo "The repository-owned non-production AWS account inventory is unresolved." >&2
  exit 1
fi
[[ "${expected_role_name}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]]
: "${CI_AUTH0_CLIENTID:?CI_AUTH0_CLIENTID is required}"
: "${CI_AUTH0_CLIENTSECRET:?CI_AUTH0_CLIENTSECRET is required}"
: "${CI_AUTH0_AUDIENCE:?CI_AUTH0_AUDIENCE is required}"
: "${CIRCLE_PROJECT_USERNAME:?CIRCLE_PROJECT_USERNAME is required}"
: "${CIRCLE_PROJECT_REPONAME:?CIRCLE_PROJECT_REPONAME is required}"
: "${CIRCLE_BUILD_NUM:?CIRCLE_BUILD_NUM is required}"
: "${CIRCLE_BRANCH:?CIRCLE_BRANCH is required}"
: "${BASH_ENV:?BASH_ENV is required}"

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
  AWS_REGION \
  AWS_DEFAULT_REGION \
  AWS_ENDPOINT_URL
do
  if [[ -n "${!inherited_credential_name+x}" ]]; then
    printf 'Non-production context injected a forbidden AWS provider: %s\n' \
      "${inherited_credential_name}" >&2
    exit 1
  fi
done
while IFS= read -r endpoint_variable_name; do
  printf 'Non-production context injected a forbidden AWS endpoint override: %s\n' \
    "${endpoint_variable_name}" >&2
  exit 1
done < <(compgen -A variable AWS_ENDPOINT_URL_)
if [[ -s "${HOME}/.aws/credentials" || -s "${HOME}/.aws/config" ]]; then
  echo "The non-production executor contains an unexpected AWS credential/config file." >&2
  exit 1
fi

temporary_directory="$(mktemp -d /tmp/nginx-supply-nonprod-auth.XXXXXX)"
credential_directory="$(mktemp -d /tmp/nginx-supply-nonprod-aws.XXXXXX)"
readonly temporary_directory credential_directory
chmod 0700 "${credential_directory}"
preserve_credentials=false
cleanup() {
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
  if [[ "${preserve_credentials}" != true && -d "${credential_directory}" ]]; then
    find "${credential_directory}" -mindepth 1 -delete
    rmdir "${credential_directory}"
  fi
}
trap cleanup EXIT

export AWS_CONFIG_FILE="${credential_directory}/config"
export AWS_SHARED_CREDENTIALS_FILE="${credential_directory}/credentials"
export AWS_EC2_METADATA_DISABLED=true
export AWS_DEFAULT_REGION="${expected_region}"

jq -cn \
  --arg client_id "${CI_AUTH0_CLIENTID}" \
  --arg client_secret "${CI_AUTH0_CLIENTSECRET}" \
  --arg audience "${CI_AUTH0_AUDIENCE}" \
  --arg environment "${deploy_environment}" \
  --arg username "${CIRCLE_PROJECT_USERNAME}" \
  --arg reponame "${CIRCLE_PROJECT_REPONAME}" \
  --arg build_num "${CIRCLE_BUILD_NUM}" \
  --arg branch "${CIRCLE_BRANCH}" \
  '{
    client_id: $client_id,
    client_secret: $client_secret,
    audience: $audience,
    grant_type: "client_credentials",
    environment: $environment,
    username: $username,
    reponame: $reponame,
    build_num: $build_num,
    branch: $branch
  }' > "${temporary_directory}/request.json"

curl \
  --disable \
  --fail \
  --silent \
  --show-error \
  --proto '=https' \
  --tlsv1.2 \
  --request POST \
  --header 'Content-Type: application/json' \
  --data-binary "@${temporary_directory}/request.json" \
  "${auth0_url}" > "${temporary_directory}/response.json"
token="$(
  jq -er '.access_token | select(type == "string" and length > 0)' \
    "${temporary_directory}/response.json"
)"
readonly token
IFS='.' read -r token_header token_payload token_signature token_extra <<< "${token}"
if [[ -z "${token_header}" || -z "${token_payload}" || -z "${token_signature}" ||
      -n "${token_extra}" || ! "${token_payload}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "The credential broker returned an invalid JWT." >&2
  exit 1
fi
case $((${#token_payload} % 4)) in
  0) padded_payload="${token_payload}" ;;
  2) padded_payload="${token_payload}==" ;;
  3) padded_payload="${token_payload}=" ;;
  *)
    echo "The credential broker returned invalid base64url data." >&2
    exit 1
    ;;
esac
printf '%s' "${padded_payload}" | tr '_-' '/+' | base64 --decode \
  > "${temporary_directory}/claims.json"

access_key_id="$(
  jq -er '(.AWS_ACCESS_KEY_ID // .AWS_ACCESS_KEY) |
    select(type == "string" and test("^(ASIA|AKIA)[A-Z0-9]{16}$"))' \
    "${temporary_directory}/claims.json"
)"
secret_access_key="$(
  jq -er '(.AWS_SECRET_ACCESS_KEY // .AWS_SECRET_KEY) |
    select(type == "string" and length >= 32)' \
    "${temporary_directory}/claims.json"
)"
session_token="$(
  jq -er '.AWS_SESSION_TOKEN | select(type == "string" and length > 0)' \
    "${temporary_directory}/claims.json"
)"
broker_account_id="$(
  jq -er '.AWS_ACCOUNT_ID | select(type == "string" and test("^[0-9]{12}$"))' \
    "${temporary_directory}/claims.json"
)"
broker_environment="$(
  jq -er '.AWS_ENVIRONMENT | select(type == "string" and length > 0) | ascii_upcase' \
    "${temporary_directory}/claims.json"
)"
readonly access_key_id secret_access_key session_token broker_account_id broker_environment
test "${broker_account_id}" = "${expected_account_id}"
test "${broker_environment}" = "${deploy_environment}"

aws configure set default.region "${expected_region}"
aws configure set default.output json
aws configure set aws_access_key_id "${access_key_id}"
aws configure set aws_secret_access_key "${secret_access_key}"
aws configure set aws_session_token "${session_token}"

caller_identity="$(aws sts get-caller-identity --output json)"
readonly caller_identity
test "$(jq -er '.Account' <<< "${caller_identity}")" = "${expected_account_id}"
caller_arn="$(jq -er '.Arn' <<< "${caller_identity}")"
readonly caller_arn
readonly expected_caller_prefix="arn:aws:sts::${expected_account_id}:assumed-role/${expected_role_name}/"
[[ "${caller_arn}" == "${expected_caller_prefix}"* ]]
caller_session_name="${caller_arn#"${expected_caller_prefix}"}"
readonly caller_session_name
[[ "${caller_session_name}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]]
test "$(aws configure get region)" = "${expected_region}"

{
  printf 'export AWS_ACCOUNT_ID=%q\n' "${expected_account_id}"
  printf 'export AWS_REGION=%q\n' "${expected_region}"
  printf 'export AWS_DEFAULT_REGION=%q\n' "${expected_region}"
  printf 'export AWS_CONFIG_FILE=%q\n' "${AWS_CONFIG_FILE}"
  printf 'export AWS_SHARED_CREDENTIALS_FILE=%q\n' "${AWS_SHARED_CREDENTIALS_FILE}"
  printf 'export AWS_EC2_METADATA_DISABLED=%q\n' true
  printf 'export NONPRODUCTION_AWS_CREDENTIAL_DIRECTORY=%q\n' "${credential_directory}"
} >> "${BASH_ENV}"

preserve_credentials=true

echo "Validated non-production AWS session for account ${expected_account_id}."
