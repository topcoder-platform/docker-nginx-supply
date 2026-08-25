#!/usr/bin/env bash

# Verifies the immutable provider-off image rather than trusting pre-build inputs alone.

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo 'Usage: verify-provider-off-image.sh IMAGE EXPECTED_SOURCE_SHA' >&2
  exit 2
fi

readonly image="$1"
readonly expected_source_sha="$2"
[[ "${expected_source_sha}" =~ ^[0-9a-f]{40}$ ]]

readonly script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-provider-off-image.XXXXXX)"
readonly temporary_directory
readonly runtime_container_name="nginx-supply-provider-scan-$(basename "${temporary_directory}")"
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
  # Keep the local image scan independent of public and corporate DNS.
  # Deployment canaries, not this expanded-config test, validate live upstreams.
  docker_host_arguments+=(--add-host "${test_only_static_upstream}:127.0.0.1")
done
readonly -a docker_host_arguments
created_container_id=''
runtime_container_started=false
cleanup() {
  if [[ "${runtime_container_started}" == true ]]; then
    docker stop --time 5 "${runtime_container_name}" >/dev/null 2>&1 || true
    docker rm --force "${runtime_container_name}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${created_container_id}" ]]; then
    docker rm --force "${created_container_id}" >/dev/null 2>&1 || true
  fi
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT

docker image inspect "${image}" --format '{{json .Config}}' \
  > "${temporary_directory}/image-config.json"
jq -e --arg expected_source_sha "${expected_source_sha}" '
  .Cmd == ["./rund"] and
  (((.Entrypoint // []) | length) == 0) and
  .WorkingDir == "/data/nginxconf" and
  ((.User // "") == "") and
  (((.Volumes // {}) | length) == 0) and
  (((.Healthcheck // {}) | length) == 0) and
  (.Env | (type == "array" and length == 1 and (.[0] | startswith("PATH=")))) and
  .Labels.app == "nginx-supply" and
  .Labels.version == "1.0" and
  .Labels["org.opencontainers.image.ref.name"] == "ubuntu" and
  .Labels["org.opencontainers.image.version"] == "20.04" and
  .Labels["org.opencontainers.image.revision"] == $expected_source_sha and
  (.Labels | keys | sort) == [
    "app",
    "org.opencontainers.image.ref.name",
    "org.opencontainers.image.revision",
    "org.opencontainers.image.version",
    "version"
  ]
' "${temporary_directory}/image-config.json" >/dev/null
"${script_directory}/verify-no-retired-provider-routes.py" \
  "${temporary_directory}/image-config.json"

created_container_id="$(docker create "${image}")"
[[ "${created_container_id}" =~ ^[0-9a-f]{64}$ ]]
docker cp "${created_container_id}:/data/nginxconf" \
  "${temporary_directory}/nginxconf"
docker cp "${created_container_id}:/home/apps/nginx/app/healthcheck.html" \
  "${temporary_directory}/healthcheck.html"
docker rm "${created_container_id}" >/dev/null
created_container_id=''

top_level_inputs="$(
  find "${temporary_directory}/nginxconf" -mindepth 1 -maxdepth 1 \
    -printf '%f\n' | sort | tr '\n' ' '
)"
readonly top_level_inputs
test "${top_level_inputs}" = 'dist rund '
"${script_directory}/verify-no-retired-provider-routes.py" \
  "${temporary_directory}/nginxconf" \
  "${temporary_directory}/healthcheck.html"

docker run --detach --rm \
  --name "${runtime_container_name}" \
  "${docker_host_arguments[@]}" \
  "${image}" > "${temporary_directory}/runtime-container-id"
runtime_container_started=true
nginx_ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  container_status="$(
    docker container inspect "${runtime_container_name}" \
      --format '{{.State.Status}}' 2>/dev/null || true
  )"
  if [[ "${container_status}" != running ]]; then
    break
  fi
  if [[ "$(docker exec "${runtime_container_name}" cat /proc/1/comm 2>/dev/null || true)" == nginx ]]; then
    nginx_ready=true
    break
  fi
  sleep 0.2
done
if [[ "${nginx_ready}" != true ]]; then
  docker logs "${runtime_container_name}" >&2 || true
  echo 'Provider scan container did not reach nginx PID 1.' >&2
  exit 1
fi
docker exec "${runtime_container_name}" nginx -T \
  > "${temporary_directory}/nginx-expanded.txt" 2>&1
"${script_directory}/verify-no-retired-provider-routes.py" \
  "${temporary_directory}/nginx-expanded.txt"

cleanup
runtime_container_started=false
trap - EXIT
echo 'Provider-off image metadata, payload, and expanded nginx contract passed.'
