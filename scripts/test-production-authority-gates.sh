#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-authority-gate-test.XXXXXX)"
readonly repository_root temporary_directory
cleanup() {
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT
mkdir --mode=0700 "${temporary_directory}/bin"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf invoked > "${NGINX_SUPPLY_AWS_INVOCATION_MARKER:?}"' \
  'exit 99' \
  > "${temporary_directory}/bin/aws"
chmod 0700 "${temporary_directory}/bin/aws"

for helper in \
  configure-production-build-aws.sh \
  configure-production-deployvar-snapshot-aws.sh \
  configure-production-deploy-aws.sh
do
  marker="${temporary_directory}/${helper}.aws-invoked"
  if env -i \
    PATH="${temporary_directory}/bin:/usr/bin:/bin" \
    NGINX_SUPPLY_AWS_INVOCATION_MARKER="${marker}" \
    PRODUCTION_AUTHORITY_BOUNDARY_STATUS=BLOCKED_SAME_PROJECT_OIDC \
    bash "${repository_root}/scripts/${helper}" \
    >/dev/null 2>&1; then
    echo "Production authority helper bypassed its blocked boundary: ${helper}" >&2
    exit 1
  fi
  if [[ -e "${marker}" ]]; then
    echo "Production authority helper called AWS before rejecting its boundary: ${helper}" >&2
    exit 1
  fi
done

cleanup
trap - EXIT
echo "All production AWS helpers fail before cloud access at the committed boundary."
