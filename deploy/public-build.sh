#!/usr/bin/env bash
set -euo pipefail
# Public settings verified from CloudFront aliases and the ECS VPC CIDR.
case "${1:-}" in
  dev)
    export ENV_PLATFORM_UI_ORIGIN=d10303ypawq4ub.cloudfront.net
    export ENV_PLATFORM_UI_RESOLVER=10.15.0.2
    exec bash ./buildimage.sh DEV '' --render-only
    ;;
  prod)
    export ENV_PLATFORM_UI_ORIGIN=d1dpgrdo047sw7.cloudfront.net
    export ENV_PLATFORM_UI_RESOLVER=10.25.0.2
    exec bash ./buildimage.sh PROD '' --render-only
    ;;
  *) echo 'Select dev or prod public build settings.' >&2; exit 1 ;;
esac
