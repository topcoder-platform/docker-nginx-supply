#!/usr/bin/env bash
set -euo pipefail
# Verified from CloudFront alias metadata and the ECS VPC CIDR on 2026-11-03.
case "${1:-}" in
  prod)
    export ENV_PLATFORM_UI_ORIGIN=d1dpgrdo047sw7.cloudfront.net
    export ENV_PLATFORM_UI_RESOLVER=10.25.0.2
    exec bash ./buildimage.sh PROD '' --render-only
    ;;
  *) echo 'Commit verified public dev CloudFront/DNS settings before building dev.' >&2; exit 1 ;;
esac
