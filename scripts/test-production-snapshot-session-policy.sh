#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repository_root
readonly account_id='409275337247'
readonly aws_region='us-east-1'
readonly expected_parameter_pattern='arn:aws:ssm:us-east-1:409275337247:parameter/config/docker-nginx-supply/deployvar/*'

policy="$(
  "${repository_root}/scripts/generate-production-snapshot-session-policy.sh" \
    "${account_id}" "${aws_region}"
)"
readonly policy

if (( ${#policy} > 2048 )); then
  echo "Production snapshot session policy exceeds the STS 2,048-character limit." >&2
  exit 1
fi
jq -e \
  --arg pattern "${expected_parameter_pattern}" '
    .Version == "2012-10-17" and
    (.Statement | length) == 1 and
    ([.Statement[] |
      select(.Action == "ssm:GetParameters" and .Resource == $pattern)] |
      length) == 1
  ' <<< "${policy}" >/dev/null

if grep -Eq 'ecr:|ecs:|iam:|kms:|ssm:(Put|Delete)|GetParametersByPath' <<< "${policy}"; then
  echo "Production snapshot session policy contains excessive authority." >&2
  exit 1
fi

printf 'Production snapshot session policy contract passed (%s characters).\n' \
  "${#policy}"
