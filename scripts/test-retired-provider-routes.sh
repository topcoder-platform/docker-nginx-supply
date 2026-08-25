#!/usr/bin/env bash

# Verifies the final fail-closed website origin and retired-provider scan.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly WWW_CONFIG="${REPOSITORY_ROOT}/src/sites-enabled/www.topcoder.com.nginx.conf"
temporary_directory="$(mktemp -d /tmp/nginx-supply-retired-provider-test.XXXXXX)"
readonly temporary_directory
cleanup() {
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT

"${SCRIPT_DIRECTORY}/test-community-app-cdn-route.sh"
"${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py"

printf '%s\n' 'proxy_pass https://legacy.net%6cify.invalid;' > "${temporary_directory}/encoded.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/encoded.conf" >/dev/null 2>&1; then
  echo 'Encoded retired-host fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s\n' 'set $ENV_NET""LIFY legacy.invalid;' > "${temporary_directory}/indirect.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/indirect.conf" >/dev/null 2>&1; then
  echo 'Indirect retired-host variable fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s\n' 'set $provider net' 'lify.invalid;' > "${temporary_directory}/multiline.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/multiline.conf" >/dev/null 2>&1; then
  echo 'Multiline retired-host fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s\n' \
  'set $left net;' \
  'set $right lify.app;' \
  'set $origin "$left$right";' \
  'proxy_pass https://$origin;' \
  > "${temporary_directory}/resolved-variables.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/resolved-variables.conf" >/dev/null 2>&1; then
  echo 'Resolved-variable retired-host fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s' 'https://production--topcoder-site.netlify.app' | base64 \
  > "${temporary_directory}/encoded-value.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/encoded-value.conf" >/dev/null 2>&1; then
  echo 'Base64-encoded retired-host fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s\n' 'proxy_pass https://cdn.content%66ul.invalid;' > "${temporary_directory}/cms.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/cms.conf" >/dev/null 2>&1; then
  echo 'Encoded retired-CMS fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s\n' 'proxy_pass https://images.ctfassets.net.invalid;' > "${temporary_directory}/assets.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/assets.conf" >/dev/null 2>&1; then
  echo 'Retired CMS asset fixture unexpectedly passed.' >&2
  exit 1
fi

printf '%s\n' 'set $proxy "oct\u0061na.invalid";' > "${temporary_directory}/proxy.conf"
if "${SCRIPT_DIRECTORY}/verify-no-retired-provider-routes.py" "${temporary_directory}/proxy.conf" >/dev/null 2>&1; then
  echo 'Unicode-escaped retired-proxy fixture unexpectedly passed.' >&2
  exit 1
fi

python3 - "${WWW_CONFIG}" <<'PY'
import re
import sys
from pathlib import Path

config = Path(sys.argv[1]).read_text(encoding="utf-8")
required_fail_closed_blocks = (
    r"location\s*=\s*/\s*\{\s*return\s+404\s*;",
    r"location\s+/\s*\{\s*return\s+404\s*;",
    r"location\s*=\s*/api\s*\{\s*return\s+404\s*;",
    r"location\s+\^~\s+/api/\s*\{\s*return\s+404\s*;",
)
for pattern in required_fail_closed_blocks:
    if not re.search(pattern, config):
        raise SystemExit(f"Missing fail-closed nginx block: {pattern}")

website_owned_routes = (
    "/ai-hub",
    "/ai-hub/ai-exponential-league",
    "/ai-hub/ai-exponential-league/innocentive",
    "/ai-hub/competitions",
    "/ai-hub/engage",
    "/ai-hub/leaderboard",
    "/marathon-match-tournament/schedule",
)
for route in website_owned_routes:
    location_pattern = rf"(?m)^\s*location\b[^\n{{]*{re.escape(route)}"
    if re.search(location_pattern, config):
        raise SystemExit(f"Website-owned route has a Supply override: {route}")
    print(f"Website-owned route has no Supply override: {route}")

former_special_routes = ("/customer-roundtable", "/doe", "/fonts/", "/iss")
for route in former_special_routes:
    location_pattern = rf"(?m)^\s*location\b[^\n{{]*{re.escape(route)}"
    if re.search(location_pattern, config):
        raise SystemExit(f"Former website proxy still has a Supply override: {route}")
    print(f"Former website proxy now reaches the fail-closed fallback: {route}")

unimplemented_api_routes = ("/api/blog", "/api/gsheets")
for route in unimplemented_api_routes:
    location_pattern = rf"(?m)^\s*location\b[^\n{{]*{re.escape(route)}"
    if re.search(location_pattern, config):
        raise SystemExit(f"Unimplemented API has a Supply override: {route}")
    print(f"Unimplemented API remains fail-closed: {route}")
PY

cleanup
trap - EXIT
printf 'Retired-provider route contract passed.\n'
