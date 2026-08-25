#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: test-circleci-config.sh CIRCLECI_BINARY PYTHON_BINARY" >&2
  exit 2
fi

readonly circleci_binary="$1"
readonly python_binary="$2"
readonly expected_binary_sha256='b1db12daab590229e591fd9899d08783685c9e0ac1bf451b3f0671e5b4032294'
readonly expected_version='circleci 1.0.48692 (8492ee467fd2)'
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d /tmp/nginx-supply-circleci-test.XXXXXX)"
readonly repository_root temporary_directory
cleanup() {
  if [[ -d "${temporary_directory}" ]]; then
    find "${temporary_directory}" -mindepth 1 -delete
    rmdir "${temporary_directory}"
  fi
}
trap cleanup EXIT

test -x "${circleci_binary}"
test -x "${python_binary}"
test "$(sha256sum "${circleci_binary}" | awk '{print $1}')" = \
  "${expected_binary_sha256}"
test "$("${circleci_binary}" version)" = "${expected_version}"

"${circleci_binary}" config validate --next \
  "${repository_root}/.circleci/config.yml"
"${circleci_binary}" config process \
  "${repository_root}/.circleci/config.yml" \
  > "${temporary_directory}/processed.yml"

"${python_binary}" - \
  "${repository_root}/.circleci/config.yml" \
  "${temporary_directory}/processed.yml" <<'PY'
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

source_path = Path(sys.argv[1])
processed_path = Path(sys.argv[2])
source_text = source_path.read_text(encoding="utf-8")
processed_text = processed_path.read_text(encoding="utf-8")

if source_text.count(r"\<<<") != 35:
    raise SystemExit("CircleCI source must escape exactly 35 Bash here-strings.")
if processed_text.count(r"\<<<") != 0 or processed_text.count("<<<") != 35:
    raise SystemExit("CircleCI processing did not restore the 35 Bash here-strings.")

config = yaml.safe_load(processed_text)
commands: list[tuple[str, str]] = []
for job_name, job in config.get("jobs", {}).items():
    for step in job.get("steps", []):
        if not isinstance(step, dict):
            continue
        for step_value in step.values():
            if isinstance(step_value, dict) and isinstance(step_value.get("command"), str):
                commands.append((job_name, step_value["command"]))

if not commands:
    raise SystemExit("Processed CircleCI config did not contain shell commands.")
for job_name, command in commands:
    result = subprocess.run(
        ["bash", "-n"],
        input=command,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"Processed CircleCI shell command for {job_name} is invalid:\n{result.stderr}"
        )
PY

cleanup
trap - EXIT
echo "Pinned CircleCI compiler and processed Bash contract passed."
