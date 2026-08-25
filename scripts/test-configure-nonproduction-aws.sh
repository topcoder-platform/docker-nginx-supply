#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-nonprod-auth-test.XXXXXX)"
readonly repository_root temporary_directory
created_credential_directory=''
unowned_credential_directory=''
cleanup() {
  if [[ -n "${created_credential_directory}" &&
        -d "${created_credential_directory}" ]]; then
    [[ "${created_credential_directory}" =~ ^/tmp/nginx-supply-nonprod-aws\.[A-Za-z0-9]+$ ]]
    find "${created_credential_directory}" -mindepth 1 -delete
    rmdir "${created_credential_directory}"
  fi
  if [[ -n "${unowned_credential_directory}" &&
        -d "${unowned_credential_directory}" ]]; then
    [[ "${unowned_credential_directory}" =~ ^/tmp/nginx-supply-nonprod-aws\.[A-Za-z0-9]+$ ]]
    find "${unowned_credential_directory}" -mindepth 1 -delete
    rmdir "${unowned_credential_directory}"
  fi
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT
mkdir "${temporary_directory}/home"
: > "${temporary_directory}/bash-env"
: > "${temporary_directory}/failure-bash-env"
while IFS= read -r aws_variable_name; do
  unset "${aws_variable_name}"
done < <(compgen -A variable AWS_)

export MOCK_ACCESS_KEY_ID="ASIA$(printf '%s' '01234567' '89ABCDEF')"
export MOCK_SECRET_ACCESS_KEY="$(printf '%040d' 0)"
export MOCK_SESSION_TOKEN='synthetic-session-token'

claims="$({
  jq -cn \
    --arg access_key "${MOCK_ACCESS_KEY_ID}" \
    --arg secret_key "${MOCK_SECRET_ACCESS_KEY}" \
    --arg session_token "${MOCK_SESSION_TOKEN}" \
    '{
      AWS_ACCESS_KEY: $access_key,
      AWS_SECRET_KEY: $secret_key,
      AWS_SESSION_TOKEN: $session_token,
      AWS_ACCOUNT_ID: "811668436784",
      AWS_ENVIRONMENT: "DEV"
    }'
} | base64 --wrap=0 | tr '/+' '_-' | tr -d '=')"
readonly claims
export MOCK_NONPRODUCTION_TOKEN="e30.${claims}.signature"
export MOCK_EXPECTED_BRANCH='feature/$(touch should-not-run)'

curl() {
  local data_file=''
  test "${1:-}" = --disable
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -k | --insecure)
        echo "The non-production auth client disabled TLS verification." >&2
        return 1
        ;;
      --data-binary)
        data_file="${2#@}"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  test -f "${data_file}"
  jq -e \
    --arg branch "${MOCK_EXPECTED_BRANCH}" '
      .grant_type == "client_credentials" and
      .environment == "DEV" and
      .branch == $branch and
      (.client_secret | type == "string" and length > 0)
    ' "${data_file}" >/dev/null
  jq -n --arg token "${MOCK_NONPRODUCTION_TOKEN}" '{access_token: $token}'
}

aws() {
  case "$1 $2 $3" in
    'configure set default.region')
      test "$4" = us-east-1
      MOCK_CONFIGURED_REGION="$4"
      printf '[default]\nregion = %s\n' "$4" > "${AWS_CONFIG_FILE}"
      ;;
    'configure set default.output')
      test "$4" = json
      ;;
    'configure set aws_access_key_id')
      test "$4" = "${MOCK_ACCESS_KEY_ID}"
      printf '[default]\naws_access_key_id = synthetic\n' \
        > "${AWS_SHARED_CREDENTIALS_FILE}"
      ;;
    'configure set aws_secret_access_key')
      test "$4" = "${MOCK_SECRET_ACCESS_KEY}"
      ;;
    'configure set aws_session_token')
      test "$4" = "${MOCK_SESSION_TOKEN}"
      ;;
    'sts get-caller-identity --output')
      test "$4" = json
      jq -n '{
        Account: "811668436784",
        Arn: "arn:aws:sts::811668436784:assumed-role/nginx-supply-dev/session"
      }'
      ;;
    'configure get region')
      printf '%s\n' "${MOCK_CONFIGURED_REGION:-us-east-1}"
      ;;
    *)
      echo "Unexpected mocked AWS invocation." >&2
      return 1
      ;;
  esac
}
export -f curl aws

(
  cd "${temporary_directory}"
  HOME="${temporary_directory}/home" \
  BASH_ENV="${temporary_directory}/bash-env" \
  CI_AUTH0_URL='https://broker.example.test/token?audience=x&mode=y' \
  CI_AUTH0_CLIENTID='synthetic-client' \
  CI_AUTH0_CLIENTSECRET='synthetic-client-secret' \
  CI_AUTH0_AUDIENCE='synthetic-audience' \
  CIRCLE_PROJECT_USERNAME='topcoder-platform' \
  CIRCLE_PROJECT_REPONAME='docker-nginx-supply' \
  CIRCLE_BUILD_NUM='123' \
  CIRCLE_BRANCH="${MOCK_EXPECTED_BRANCH}" \
  EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID='811668436784' \
  EXPECTED_NONPRODUCTION_AWS_ROLE_NAME='nginx-supply-dev' \
    "${repository_root}/scripts/configure-nonproduction-aws.sh" DEV
)
test -s "${temporary_directory}/bash-env"
grep -Fqx 'export AWS_ACCOUNT_ID=811668436784' "${temporary_directory}/bash-env"
grep -Fqx 'export AWS_REGION=us-east-1' "${temporary_directory}/bash-env"
created_credential_directory="$(
  sed -n 's|^export NONPRODUCTION_AWS_CREDENTIAL_DIRECTORY=||p' \
    "${temporary_directory}/bash-env"
)"
[[ "${created_credential_directory}" =~ ^/tmp/nginx-supply-nonprod-aws\.[A-Za-z0-9]+$ ]]
grep -Fqx \
  "export AWS_CONFIG_FILE=${created_credential_directory}/config" \
  "${temporary_directory}/bash-env"
test -s "${created_credential_directory}/config"
test -s "${created_credential_directory}/credentials"
test ! -e "${temporary_directory}/should-not-run"
if grep -Fq \
  -e 'synthetic-client-secret' \
  -e "${MOCK_SESSION_TOKEN}" \
  -e "${MOCK_SECRET_ACCESS_KEY}" \
  "${temporary_directory}/bash-env"; then
  echo "Non-production credentials leaked into BASH_ENV." >&2
  exit 1
fi
(
  source "${temporary_directory}/bash-env"
  "${repository_root}/scripts/cleanup-nonproduction-aws.sh"
)
test ! -e "${created_credential_directory}"
created_credential_directory=''

common_environment=(
  HOME="${temporary_directory}/home"
  BASH_ENV="${temporary_directory}/failure-bash-env"
  CI_AUTH0_CLIENTID='synthetic-client'
  CI_AUTH0_CLIENTSECRET='synthetic-client-secret'
  CI_AUTH0_AUDIENCE='synthetic-audience'
  CIRCLE_PROJECT_USERNAME='topcoder-platform'
  CIRCLE_PROJECT_REPONAME='docker-nginx-supply'
  CIRCLE_BUILD_NUM='123'
  CIRCLE_BRANCH='dev'
  EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID='811668436784'
  EXPECTED_NONPRODUCTION_AWS_ROLE_NAME='nginx-supply-dev'
)
if env \
  "${common_environment[@]}" \
  CI_AUTH0_URL='http://broker.example.test/token' \
  "${repository_root}/scripts/configure-nonproduction-aws.sh" DEV \
  >/dev/null 2>&1; then
  echo "An insecure non-production broker URL was accepted." >&2
  exit 1
fi
if env \
  "${common_environment[@]}" \
  CI_AUTH0_URL='https://broker.example.test/token' \
  AWS_ACCESS_KEY_ID='inherited' \
  "${repository_root}/scripts/configure-nonproduction-aws.sh" DEV \
  >/dev/null 2>&1; then
  echo "An inherited non-production AWS provider was accepted." >&2
  exit 1
fi
if env \
  "${common_environment[@]}" \
  CI_AUTH0_URL='https://broker.example.test/token' \
  AWS_ENDPOINT_URL_SSM='https://example.test' \
  "${repository_root}/scripts/configure-nonproduction-aws.sh" DEV \
  >/dev/null 2>&1; then
  echo "A non-production AWS endpoint override was accepted." >&2
  exit 1
fi
if env \
  "${common_environment[@]}" \
  CI_AUTH0_URL='https://broker.example.test/token' \
  EXPECTED_NONPRODUCTION_AWS_ROLE_NAME='wrong-role' \
  "${repository_root}/scripts/configure-nonproduction-aws.sh" DEV \
  >/dev/null 2>&1; then
  echo "A non-production session from an unexpected role was accepted." >&2
  exit 1
fi

unowned_credential_directory="$(mktemp -d /tmp/nginx-supply-nonprod-aws.XXXXXX)"
: > "${unowned_credential_directory}/sentinel"
if NONPRODUCTION_AWS_CREDENTIAL_DIRECTORY="${unowned_credential_directory}" \
  AWS_CONFIG_FILE="${temporary_directory}/wrong-config" \
  AWS_SHARED_CREDENTIALS_FILE="${unowned_credential_directory}/credentials" \
  "${repository_root}/scripts/cleanup-nonproduction-aws.sh" >/dev/null 2>&1; then
  echo "Credential cleanup accepted mismatched ownership paths." >&2
  exit 1
fi
test -f "${unowned_credential_directory}/sentinel"
find "${unowned_credential_directory}" -mindepth 1 -delete
rmdir "${unowned_credential_directory}"
unowned_credential_directory=''

echo "Non-production AWS authentication contract passed."
