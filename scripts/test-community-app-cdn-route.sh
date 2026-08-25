#!/usr/bin/env bash

# Verifies the Community App API fallbacks in source or rendered config.

set -euo pipefail

if (( $# > 2 )); then
  echo 'Usage: test-community-app-cdn-route.sh [config-root [expected-resolver]]' >&2
  exit 2
fi

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly CONFIG_ROOT="$(cd "${1:-${REPOSITORY_ROOT}/src}" && pwd)"
if (( $# == 2 )); then
  EXPECTED_RESOLVER="$2"
else
  EXPECTED_RESOLVER='{{ENV_PLATFORM_UI_RESOLVER}}'
fi
readonly EXPECTED_RESOLVER
readonly WWW_CONFIG="${CONFIG_ROOT}/sites-enabled/www.topcoder.com.nginx.conf"
readonly PROXY_CONFIG="${CONFIG_ROOT}/includes/community-app.cdn.proxy.nginx.conf"
readonly -a COMMUNITY_APP_API_PREFIXES=(
  '/api/cdn'
  '/api/recruit'
  '/api/mml'
  '/api/feeds'
)
readonly -a UNIMPLEMENTED_API_PREFIXES=(
  '/api/blog'
  '/api/gsheets'
)
readonly EXPECTED_INCLUDE_COUNT=$((${#COMMUNITY_APP_API_PREFIXES[@]} * 2))
readonly FAIL_CLOSED_EXACT_LINE="$(grep -Fn 'location = /api {' "${WWW_CONFIG}" | cut -d: -f1)"
readonly FAIL_CLOSED_LINE="$(grep -Fn 'location ^~ /api/ {' "${WWW_CONFIG}" | cut -d: -f1)"

[[ "$(grep -Fc 'include includes/community-app.cdn.proxy.nginx.conf;' "${WWW_CONFIG}")" == "${EXPECTED_INCLUDE_COUNT}" ]] \
  || { echo 'Community App proxy must cover every exact and descendant API route.' >&2; exit 1; }

for prefix in "${COMMUNITY_APP_API_PREFIXES[@]}"; do
  grep -Fq "location = ${prefix} {" "${WWW_CONFIG}" \
    || { echo "Exact Community App route is missing: ${prefix}" >&2; exit 1; }
  grep -Fq "location ^~ ${prefix}/ {" "${WWW_CONFIG}" \
    || { echo "Community App descendant route is missing: ${prefix}/" >&2; exit 1; }
  exact_line="$(grep -Fn "location = ${prefix} {" "${WWW_CONFIG}" | cut -d: -f1)"
  descendant_line="$(grep -Fn "location ^~ ${prefix}/ {" "${WWW_CONFIG}" | cut -d: -f1)"
  (( exact_line < FAIL_CLOSED_LINE && descendant_line < FAIL_CLOSED_LINE )) \
    || { echo "Community App routes must precede the fail-closed API remainder: ${prefix}" >&2; exit 1; }
  printf 'Community App API prefix preserved: %s\n' "${prefix}"
done

grep -Fq 'location ^~ /api/ {' "${WWW_CONFIG}" \
  || { echo 'Fail-closed remainder for unverified API routes is missing.' >&2; exit 1; }
grep -Fq 'location = /api {' "${WWW_CONFIG}" \
  || { echo 'Fail-closed exact API route is missing.' >&2; exit 1; }
(( FAIL_CLOSED_EXACT_LINE < FAIL_CLOSED_LINE )) \
  || { echo 'Exact API fail-closed route must precede its descendant remainder.' >&2; exit 1; }
for prefix in "${UNIMPLEMENTED_API_PREFIXES[@]}"; do
  if awk -v prefix="${prefix}" '$1 == "location" && index($0, prefix) { found = 1 } END { exit !found }' "${WWW_CONFIG}"; then
    echo "Unimplemented API unexpectedly has a Supply override: ${prefix}" >&2
    exit 1
  fi
  printf 'Unimplemented API remains fail-closed: %s\n' "${prefix}"
done

grep -Fq "resolver ${EXPECTED_RESOLVER} valid=60s ipv6=off;" "${PROXY_CONFIG}" \
  || { echo 'Community App proxy must use the configured Fargate resolver.' >&2; exit 1; }
grep -Fq 'proxy_ssl_verify on;' "${PROXY_CONFIG}" \
  || { echo 'Community App proxy must verify the upstream certificate.' >&2; exit 1; }
grep -Fq 'proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' "${PROXY_CONFIG}" \
  || { echo 'Community App proxy must use the image CA trust store.' >&2; exit 1; }
grep -Fq 'proxy_ssl_verify_depth 3;' "${PROXY_CONFIG}" \
  || { echo 'Community App proxy must set a certificate-chain depth.' >&2; exit 1; }
grep -Fq 'proxy_pass https://$community_app_host$request_uri;' "${PROXY_CONFIG}" \
  || { echo 'Community App proxy must preserve the path and query.' >&2; exit 1; }
if grep -Fq 'resolver dns01.' "${PROXY_CONFIG}"; then
  echo 'Community App proxy still uses a legacy named resolver.' >&2
  exit 1
fi

if (( $# == 2 )) && grep -FRq '{{ENV_' "${CONFIG_ROOT}"; then
  echo 'Rendered nginx configuration still contains an environment placeholder.' >&2
  exit 1
fi

printf 'Community App API route contract passed for %s.\n' "${CONFIG_ROOT}"
