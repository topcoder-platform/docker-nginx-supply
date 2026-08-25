#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: generate-production-snapshot-session-policy.sh ACCOUNT REGION" >&2
  exit 2
fi

readonly account_id="$1"
readonly aws_region="$2"
readonly parameter_arn_pattern="arn:aws:ssm:${aws_region}:${account_id}:parameter/config/docker-nginx-supply/deployvar/*"

test "${account_id}" = 409275337247
test "${aws_region}" = us-east-1

# This session policy is a compact ceiling. The role's independently reviewed
# identity policy must allow only the exact 12 parameter ARNs.
# The effective session permissions are their intersection. Snapshot reads never decrypt values.
jq -cn \
  --arg parameter_pattern "${parameter_arn_pattern}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: "ssm:GetParameters",
        Resource: $parameter_pattern
      }
    ]
  }'
