#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-snapshot-auth-test.XXXXXX)"
readonly repository_root temporary_directory
cleanup() {
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT
mkdir "${temporary_directory}/home"

while IFS= read -r aws_variable_name; do
  unset "${aws_variable_name}"
done < <(compgen -A variable AWS_)

aws() {
  case "$1 $2" in
    'sts assume-role-with-web-identity')
      shift 2
      local mock_role_arn='' mock_session_name='' mock_duration=''
      local mock_policy='' mock_region='' mock_token=''
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --role-arn) mock_role_arn="$2"; shift 2 ;;
          --role-session-name) mock_session_name="$2"; shift 2 ;;
          --web-identity-token) mock_token="$2"; shift 2 ;;
          --duration-seconds) mock_duration="$2"; shift 2 ;;
          --policy) mock_policy="$2"; shift 2 ;;
          --region) mock_region="$2"; shift 2 ;;
          --output) test "$2" = json; shift 2 ;;
          *) echo "Unexpected snapshot STS argument: $1" >&2; return 1 ;;
        esac
      done
      test "${mock_role_arn}" = \
        arn:aws:iam::409275337247:role/circleci-docker-nginx-supply-prod-deployvar-snapshot
      test "${mock_session_name}" = nginx-supply-snapshot-test-workflow
      test "${mock_token}" = synthetic-oidc-token
      test "${mock_duration}" = 900
      test "${mock_region}" = us-east-1
      (( ${#mock_policy} <= 2048 ))
      jq -e '
        (.Statement | length) == 1 and
        .Statement[0].Action == "ssm:GetParameters" and
        (.Statement[0].Resource | endswith("/deployvar/*")) and
        ([.. | strings | select(startswith("kms:"))] | length) == 0
      ' <<< "${mock_policy}" >/dev/null
      jq -n '{Credentials: {
        AccessKeyId: "synthetic-access",
        SecretAccessKey: "synthetic-secret",
        SessionToken: "synthetic-session"
      }}'
      ;;
    'configure set')
      test "$#" = 4
      case "$3" in
        default.region) test "$4" = us-east-1 ;;
        default.output) test "$4" = json ;;
        aws_access_key_id) test "$4" = synthetic-access ;;
        aws_secret_access_key) test "$4" = synthetic-secret ;;
        aws_session_token) test "$4" = synthetic-session ;;
        *) echo "Unexpected snapshot AWS configuration key: $3" >&2; return 1 ;;
      esac
      ;;
    'sts get-caller-identity')
      test "$3" = --output
      test "$4" = json
      jq -n '{
        Account: "409275337247",
        Arn: "arn:aws:sts::409275337247:assumed-role/circleci-docker-nginx-supply-prod-deployvar-snapshot/nginx-supply-snapshot-test-workflow"
      }'
      ;;
    *)
      echo "Unexpected mocked snapshot AWS invocation: $*" >&2
      return 1
      ;;
  esac
}
export -f aws

HOME="${temporary_directory}/home" \
PRODUCTION_AUTHORITY_BOUNDARY_STATUS=VERIFIED_EXTERNAL_AUTHORITY_GATE \
EXPECTED_AWS_ACCOUNT_ID=409275337247 \
AWS_PRODUCTION_DEPLOYVAR_SNAPSHOT_ROLE_ARN=arn:aws:iam::409275337247:role/circleci-docker-nginx-supply-prod-deployvar-snapshot \
CIRCLE_OIDC_TOKEN_V2=synthetic-oidc-token \
CIRCLE_WORKFLOW_ID=test-workflow \
AWS_REGION=us-east-1 \
  "${repository_root}/scripts/configure-production-deployvar-snapshot-aws.sh"

if HOME="${temporary_directory}/home" \
  PRODUCTION_AUTHORITY_BOUNDARY_STATUS=BLOCKED_SAME_PROJECT_OIDC \
  "${repository_root}/scripts/configure-production-deployvar-snapshot-aws.sh" \
  >/dev/null 2>&1; then
  echo "The same-project production snapshot authority block was bypassed." >&2
  exit 1
fi

if HOME="${temporary_directory}/home" \
  PRODUCTION_AUTHORITY_BOUNDARY_STATUS=VERIFIED_EXTERNAL_AUTHORITY_GATE \
  EXPECTED_AWS_ACCOUNT_ID=409275337247 \
  AWS_PRODUCTION_DEPLOYVAR_SNAPSHOT_ROLE_ARN=arn:aws:iam::409275337247:role/circleci-docker-nginx-supply-prod-deployvar-snapshot \
  CIRCLE_OIDC_TOKEN_V2=synthetic-oidc-token \
  CIRCLE_WORKFLOW_ID=test-workflow \
  AWS_REGION=us-east-1 \
  AWS_ENDPOINT_URL_SSM=https://example.test \
  "${repository_root}/scripts/configure-production-deployvar-snapshot-aws.sh" \
  >/dev/null 2>&1; then
  echo "The production snapshot accepted an inherited AWS endpoint override." >&2
  exit 1
fi

echo "Production snapshot AWS authentication contract passed without KMS authority."
