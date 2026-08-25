#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "Usage: test-runtime.sh IMAGE [EXPECTED_WWW_HOST]" >&2
  exit 2
fi

readonly image="$1"
readonly expected_www_host="${2:-www.topcoder.com}"
case "${expected_www_host}" in
  www.topcoder.com | www.topcoder-dev.com | www.topcoder-qa.com | www.topcoder-local.com) ;;
  *)
    echo "The runtime test host is not an approved website hostname." >&2
    exit 2
    ;;
esac
temporary_directory="$(mktemp -d /tmp/nginx-supply-runtime-test.XXXXXX)"
readonly temporary_directory
readonly container_name="nginx-supply-runtime-$(basename "${temporary_directory}")"
docker_host_arguments=(--add-host dns01.topcoder.com:127.0.0.1)
for test_only_static_upstream in \
  asteroids.tcmini.wpengine.com \
  bluehost.topcoder.com \
  dtn.tcmini.wpengine.com \
  epa.tcmini.wpengine.com \
  mf01 \
  s3.amazonaws.com \
  sendgrid.net \
  solarsystems.tcmini.wpengine.com \
  tccommunityres.wpengine.com \
  tchelp.wpengine.com \
  tco15.wpengine.com \
  tco16.wpengine.com \
  wwwtc
do
  # Keep the local runtime contract independent of public and corporate DNS.
  # Deployment canaries, not this syntax/PID-1 test, validate live upstreams.
  docker_host_arguments+=(--add-host "${test_only_static_upstream}:127.0.0.1")
done
readonly -a docker_host_arguments
container_started=false
cleanup() {
  if [[ "${container_started}" == true ]]; then
    docker stop --time 5 "${container_name}" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if ! docker container inspect "${container_name}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    docker rm --force "${container_name}" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
      if ! docker container inspect "${container_name}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
  fi
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT

if docker container inspect "${container_name}" >/dev/null 2>&1; then
  echo "Refusing to reuse an existing runtime test container." >&2
  exit 1
fi
docker run --detach --rm \
  --name "${container_name}" \
  "${docker_host_arguments[@]}" \
  "${image}" > "${temporary_directory}/container-id"
container_started=true

nginx_ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  container_status="$(
    docker container inspect "${container_name}" --format '{{.State.Status}}' 2>/dev/null || true
  )"
  if [[ "${container_status}" != running ]]; then
    break
  fi
  if [[ "$(docker exec "${container_name}" cat /proc/1/comm 2>/dev/null || true)" == nginx ]]; then
    nginx_ready=true
    break
  fi
  sleep 0.2
done
if [[ "${nginx_ready}" != true ]]; then
  docker logs "${container_name}" >&2 || true
  echo "The nginx image did not reach its required PID 1 runtime state." >&2
  exit 1
fi

case "$(docker exec "${container_name}" bash -c 'tr "\0" " " < /proc/1/cmdline')" in
  'nginx: master process nginx ') ;;
  *)
    echo "Nginx is not PID 1 in the runtime container." >&2
    exit 1
    ;;
esac
docker exec "${container_name}" test -f /tmp/nginx/nginx.pid
docker exec "${container_name}" test -d /tmp/nginx/cache
docker exec "${container_name}" test -d /tmp/nginx/client-body
health_status_code="$(
  docker exec "${container_name}" bash -c '
    readonly expected_www_host="$1"
    exec 3<>/dev/tcp/127.0.0.1/8000
    printf "GET /www_topcoder_status HTTP/1.0\r\n" >&3
    printf "Host: %s\r\n" "${expected_www_host}" >&3
    printf "Connection: close\r\n\r\n" >&3
    IFS=" " read -r _ status_code _ <&3
    printf "%s\n" "${status_code}"
  ' bash "${expected_www_host}"
)"
readonly health_status_code
if [[ "${health_status_code}" != 200 ]]; then
  printf 'The expected www virtual host did not serve its local status route: %s -> %s\n' \
    "${expected_www_host}" "${health_status_code}" >&2
  exit 1
fi

readonly -a fail_closed_routes=(
  '/'
  '/api'
  '/api/unknown'
  '/api/blog'
  '/api/gsheets'
  '/ai-hub'
  '/ai-hub/ai-exponential-league'
  '/ai-hub/ai-exponential-league/innocentive'
  '/ai-hub/competitions'
  '/ai-hub/engage'
  '/ai-hub/leaderboard'
  '/marathon-match-tournament/schedule'
  '/customer-roundtable'
  '/doe'
  '/fonts/example.woff'
  '/iss'
)
for route in "${fail_closed_routes[@]}"; do
  route_status_code="$(
    docker exec "${container_name}" bash -c '
      readonly route="$1"
      exec 3<>/dev/tcp/127.0.0.1/8000
      printf "GET %s HTTP/1.0\r\n" "${route}" >&3
      printf "Host: %s\r\n" "$2" >&3
      printf "X-Forwarded-Proto: https\r\n" >&3
      printf "Connection: close\r\n\r\n" >&3
      IFS=" " read -r _ status_code _ <&3
      printf "%s\n" "${status_code}"
    ' bash "${route}" "${expected_www_host}"
  )"
  if [[ "${route_status_code}" != 404 ]]; then
    printf 'Direct-origin route did not fail closed: %s -> %s\n' \
      "${route}" "${route_status_code}" >&2
    exit 1
  fi
done

cleanup
container_started=false
trap - EXIT
if docker container inspect "${container_name}" >/dev/null 2>&1; then
  echo "The runtime test container was not removed." >&2
  exit 1
fi

echo "Writable-root runtime, nginx PID 1, and fail-closed HTTP route contract passed."
