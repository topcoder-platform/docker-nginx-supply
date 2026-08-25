#!/usr/bin/env bash

# Load explicitly allowlisted SSM parameters into the current shell without
# evaluating their values. This file must be sourced so exports reach its caller.
#
# Usage:
#   load_ssm_environment /path \
#     --required REQUIRED_NAME ... \
#     --optional OPTIONAL_NAME ...

load_ssm_environment() {
  if [[ "$#" -lt 3 || ! "$1" =~ ^/[A-Za-z0-9._/-]+$ || "$1" == */ ]]; then
    echo "Usage: load_ssm_environment /path --required NAME [--optional NAME ...]" >&2
    return 2
  fi

  local parameter_path="$1"
  shift
  local mode=''
  local name
  local -a required_names=()
  local -a requested_names=()
  declare -A required_lookup=()
  declare -A requested_lookup=()

  for name in "$@"; do
    case "${name}" in
      --required)
        mode=required
        continue
        ;;
      --optional)
        mode=optional
        continue
        ;;
    esac
    if [[ -z "${mode}" || ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
          -n "${requested_lookup[$name]:-}" ]]; then
      echo "SSM allowlist contains an invalid or duplicate variable name." >&2
      return 2
    fi
    if [[ -n "${!name+x}" ]]; then
      echo "Allowlisted SSM variable is already set: ${name}" >&2
      return 1
    fi
    requested_names+=("${name}")
    requested_lookup["${name}"]=1
    if [[ "${mode}" == required ]]; then
      required_names+=("${name}")
      required_lookup["${name}"]=1
    fi
  done
  if [[ "${#required_names[@]}" -eq 0 || "${#requested_names[@]}" -eq 0 ]]; then
    echo "At least one required SSM variable must be allowlisted." >&2
    return 2
  fi

  local parameter_file
  parameter_file="$(mktemp /tmp/nginx-supply-ssm.XXXXXX.json)" || return 1
  local -a loaded_names=()
  local -a encoded_values=()
  declare -A loaded_lookup=()
  declare -A invalid_lookup=()
  local offset
  local batch_name
  local full_name
  local loaded_name
  local invalid_name
  local -a full_names=()
  local -a batch_loaded_names=()
  local -a batch_encoded_values=()

  for ((offset = 0; offset < ${#requested_names[@]}; offset += 10)); do
    full_names=()
    for batch_name in "${requested_names[@]:offset:10}"; do
      full_names+=("${parameter_path}/${batch_name}")
    done
    if ! aws ssm get-parameters \
      --with-decryption \
      --names "${full_names[@]}" \
      --output json > "${parameter_file}"; then
      rm -f "${parameter_file}"
      return 1
    fi
    if ! jq -e '
      (.Parameters | type == "array") and
      (.InvalidParameters | type == "array") and
      (all(.Parameters[];
        (.Name | type == "string") and
        (.Type == "SecureString") and
        (.Value | type == "string"))) and
      (all(.InvalidParameters[]; type == "string"))
    ' "${parameter_file}" >/dev/null; then
      echo "SSM returned an invalid or non-SecureString response." >&2
      rm -f "${parameter_file}"
      return 1
    fi

    mapfile -t batch_loaded_names < <(jq -r '.Parameters[].Name' "${parameter_file}")
    mapfile -t batch_encoded_values < <(
      jq -r '.Parameters[].Value | @base64' "${parameter_file}"
    )
    if [[ "${#batch_loaded_names[@]}" -ne "${#batch_encoded_values[@]}" ]]; then
      echo "SSM response could not be decoded completely." >&2
      rm -f "${parameter_file}"
      return 1
    fi
    for full_name in "${batch_loaded_names[@]}"; do
      if [[ "${full_name}" != "${parameter_path}/"* ]]; then
        echo "SSM returned a parameter outside the requested path." >&2
        rm -f "${parameter_file}"
        return 1
      fi
      loaded_name="${full_name#"${parameter_path}/"}"
      if [[ ! "${loaded_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
            -z "${requested_lookup[$loaded_name]:-}" ||
            -n "${loaded_lookup[$loaded_name]:-}" ]]; then
        echo "SSM returned an unallowlisted or duplicate parameter." >&2
        rm -f "${parameter_file}"
        return 1
      fi
      loaded_lookup["${loaded_name}"]=1
      loaded_names+=("${loaded_name}")
    done
    while IFS= read -r invalid_name; do
      if [[ "${invalid_name}" != "${parameter_path}/"* ]]; then
        echo "SSM returned an invalid parameter outside the requested path." >&2
        rm -f "${parameter_file}"
        return 1
      fi
      loaded_name="${invalid_name#"${parameter_path}/"}"
      if [[ ! "${loaded_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
            -z "${requested_lookup[$loaded_name]:-}" ||
            -n "${loaded_lookup[$loaded_name]:-}" ||
            -n "${invalid_lookup[$loaded_name]:-}" ]]; then
        echo "SSM returned an unallowlisted, duplicate, or contradictory invalid parameter." >&2
        rm -f "${parameter_file}"
        return 1
      fi
      invalid_lookup["${loaded_name}"]=1
    done < <(jq -r '.InvalidParameters[]' "${parameter_file}")
    encoded_values+=("${batch_encoded_values[@]}")
  done
  rm -f "${parameter_file}"

  for name in "${required_names[@]}"; do
    if [[ -z "${loaded_lookup[$name]:-}" ]]; then
      echo "Required SSM parameter is missing: ${parameter_path}/${name}" >&2
      return 1
    fi
  done
  for name in "${requested_names[@]}"; do
    if [[ -z "${loaded_lookup[$name]:-}" && -z "${invalid_lookup[$name]:-}" ]]; then
      echo "SSM response omitted an allowlisted parameter: ${parameter_path}/${name}" >&2
      return 1
    fi
    if [[ -n "${invalid_lookup[$name]:-}" ]]; then
      printf -v "${name}" '%s' ''
      export "${name}"
    fi
  done
  if [[ "${#loaded_names[@]}" -ne "${#encoded_values[@]}" ]]; then
    echo "SSM values do not match their validated names." >&2
    return 1
  fi

  local -a decoded_values=()
  local value_with_sentinel
  local index
  for index in "${!encoded_values[@]}"; do
    if ! value_with_sentinel="$({
      printf '%s' "${encoded_values[$index]}" | base64 --decode
      printf '\001'
    })" || [[ "${value_with_sentinel}" != *$'\001' ]]; then
      echo "SSM value could not be decoded." >&2
      return 1
    fi
    decoded_values+=("${value_with_sentinel%$'\001'}")
  done

  for index in "${!loaded_names[@]}"; do
    printf -v "${loaded_names[$index]}" '%s' "${decoded_values[$index]}"
    export "${loaded_names[$index]}"
  done
}

_parse_ssm_allowlist() {
  if [[ "$#" -lt 5 ]]; then
    echo "Internal SSM allowlist parser usage error." >&2
    return 2
  fi
  local required_output_name="$1"
  local requested_output_name="$2"
  local required_lookup_output_name="$3"
  local requested_lookup_output_name="$4"
  shift 4
  local -n required_output="${required_output_name}"
  local -n requested_output="${requested_output_name}"
  local -n required_lookup_output="${required_lookup_output_name}"
  local -n requested_lookup_output="${requested_lookup_output_name}"
  local mode=''
  local name

  for name in "$@"; do
    case "${name}" in
      --required)
        mode=required
        continue
        ;;
      --optional)
        mode=optional
        continue
        ;;
    esac
    if [[ -z "${mode}" || ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
          -n "${requested_lookup_output[$name]:-}" ]]; then
      echo "SSM allowlist contains an invalid or duplicate variable name." >&2
      return 2
    fi
    requested_output+=("${name}")
    requested_lookup_output["${name}"]=1
    if [[ "${mode}" == required ]]; then
      required_output+=("${name}")
      required_lookup_output["${name}"]=1
    fi
  done
  if [[ "${#required_output[@]}" -eq 0 || "${#requested_output[@]}" -eq 0 ]]; then
    echo "At least one required SSM variable must be allowlisted." >&2
    return 2
  fi
}

_validate_ssm_parameter_arn() {
  if [[ "$#" -ne 3 ]]; then
    return 2
  fi
  local arn="$1"
  local parameter_path="$2"
  local name="$3"
  local suffix=":parameter${parameter_path}/${name}"
  local prefix
  if [[ "${arn}" != *"${suffix}" ]]; then
    return 1
  fi
  prefix="${arn%"${suffix}"}"
  [[ "${prefix}" =~ ^arn:aws[a-z-]*:ssm:[a-z0-9-]+:[0-9]{12}$ ]]
}

snapshot_ssm_environment() {
  if [[ "$#" -lt 5 || ! "$1" =~ ^/[A-Za-z0-9._/-]+$ || "$1" == */ ||
        -z "$2" ]]; then
    echo "Usage: snapshot_ssm_environment /path OUTPUT --required NAME [--optional NAME ...]" >&2
    return 2
  fi
  local parameter_path="$1"
  local output_path="$2"
  shift 2
  local -a required_names=()
  local -a requested_names=()
  declare -A required_lookup=()
  declare -A requested_lookup=()
  _parse_ssm_allowlist \
    required_names requested_names required_lookup requested_lookup "$@" || return 1

  local response_file
  response_file="$(mktemp /tmp/nginx-supply-ssm-snapshot.XXXXXX.json)" || return 1
  local manifest_file
  manifest_file="$(mktemp /tmp/nginx-supply-ssm-manifest.XXXXXX.tsv)" || {
    rm -f "${response_file}"
    return 1
  }
  local rows_file
  rows_file="$(mktemp /tmp/nginx-supply-ssm-rows.XXXXXX.tsv)" || {
    rm -f "${response_file}" "${manifest_file}"
    return 1
  }
  local cleanup_snapshot_files=true
  _cleanup_ssm_snapshot_files() {
    rm -f "${response_file}" "${rows_file}"
    if [[ "${cleanup_snapshot_files}" == true ]]; then
      rm -f "${manifest_file}"
    fi
  }
  trap 'trap - RETURN; _cleanup_ssm_snapshot_files' RETURN

  declare -A present_lookup=()
  declare -A invalid_lookup=()
  declare -A version_lookup=()
  declare -A arn_lookup=()
  declare -A modified_lookup=()
  local offset batch_name full_name loaded_name version arn modified invalid_name
  local -a full_names=()

  for ((offset = 0; offset < ${#requested_names[@]}; offset += 10)); do
    full_names=()
    for batch_name in "${requested_names[@]:offset:10}"; do
      full_names+=("${parameter_path}/${batch_name}")
    done
    if ! aws ssm get-parameters \
      --names "${full_names[@]}" \
      --output json > "${response_file}"; then
      return 1
    fi
    if ! jq -e '
      (.Parameters | type == "array") and
      (.InvalidParameters | type == "array") and
      (all(.Parameters[];
        (.Name | type == "string") and
        (.Type == "SecureString") and
        (.Value | type == "string") and
        (.Version | type == "number" and floor == . and . > 0) and
        (.ARN | type == "string") and
        ((.LastModifiedDate | type) == "string" or
          (.LastModifiedDate | type) == "number"))) and
      (all(.InvalidParameters[]; type == "string"))
    ' "${response_file}" >/dev/null; then
      echo "SSM returned invalid snapshot metadata." >&2
      return 1
    fi
    jq -r '.Parameters[] |
      [.Name, (.Version | tostring), .ARN, (.LastModifiedDate | tostring)] | @tsv' \
      "${response_file}" > "${rows_file}"
    while IFS=$'\t' read -r full_name version arn modified; do
      [[ "${full_name}" == "${parameter_path}/"* ]] || return 1
      loaded_name="${full_name#"${parameter_path}/"}"
      if [[ -z "${requested_lookup[$loaded_name]:-}" ||
            -n "${present_lookup[$loaded_name]:-}" ||
            ! "${version}" =~ ^[1-9][0-9]*$ ||
            ! "${modified}" =~ ^[0-9A-Za-z:+.-]+$ ]] ||
          ! _validate_ssm_parameter_arn "${arn}" "${parameter_path}" "${loaded_name}"; then
        echo "SSM returned unexpected or duplicate snapshot metadata." >&2
        return 1
      fi
      present_lookup["${loaded_name}"]=1
      version_lookup["${loaded_name}"]="${version}"
      arn_lookup["${loaded_name}"]="${arn}"
      modified_lookup["${loaded_name}"]="${modified}"
    done < "${rows_file}"
    while IFS= read -r invalid_name; do
      [[ "${invalid_name}" == "${parameter_path}/"* ]] || return 1
      loaded_name="${invalid_name#"${parameter_path}/"}"
      if [[ -z "${requested_lookup[$loaded_name]:-}" ||
            -n "${invalid_lookup[$loaded_name]:-}" ||
            -n "${present_lookup[$loaded_name]:-}" ]]; then
        echo "SSM returned an unexpected invalid snapshot parameter." >&2
        return 1
      fi
      invalid_lookup["${loaded_name}"]=1
    done < <(jq -r '.InvalidParameters[]' "${response_file}")
  done

  printf '%s\n' 'nginx-supply-ssm-version-manifest-v1' > "${manifest_file}"
  for loaded_name in "${requested_names[@]}"; do
    if [[ -n "${present_lookup[$loaded_name]:-}" ]]; then
      printf 'present\t%s\t%s\t%s\t%s\n' \
        "${loaded_name}" \
        "${version_lookup[$loaded_name]}" \
        "${arn_lookup[$loaded_name]}" \
        "${modified_lookup[$loaded_name]}" >> "${manifest_file}"
    elif [[ -n "${invalid_lookup[$loaded_name]:-}" &&
            -z "${required_lookup[$loaded_name]:-}" ]]; then
      printf 'absent\t%s\t-\t-\t-\n' "${loaded_name}" >> "${manifest_file}"
    else
      echo "A required snapshot parameter is missing or the response was incomplete." >&2
      return 1
    fi
  done
  {
    head -n 1 "${manifest_file}"
    tail -n +2 "${manifest_file}" | LC_ALL=C sort -t $'\t' -k2,2
  } > "${rows_file}"
  chmod 0600 "${rows_file}"
  mv "${rows_file}" "${output_path}"
  cleanup_snapshot_files=false
  rm -f "${response_file}" "${manifest_file}"
  trap - RETURN
}

load_ssm_environment_from_manifest() {
  if [[ "$#" -lt 5 || ! "$1" =~ ^/[A-Za-z0-9._/-]+$ || "$1" == */ ||
        ! -f "$2" ]]; then
    echo "Usage: load_ssm_environment_from_manifest /path MANIFEST --required NAME [--optional NAME ...]" >&2
    return 2
  fi
  local parameter_path="$1"
  local manifest_path="$2"
  shift 2
  local -a required_names=()
  local -a requested_names=()
  declare -A required_lookup=()
  declare -A requested_lookup=()
  _parse_ssm_allowlist \
    required_names requested_names required_lookup requested_lookup "$@" || return 1

  if [[ "$(head -n 1 "${manifest_path}")" != nginx-supply-ssm-version-manifest-v1 ]]; then
    echo "The SSM version manifest header is invalid." >&2
    return 1
  fi
  declare -A status_lookup=()
  declare -A version_lookup=()
  declare -A arn_lookup=()
  declare -A modified_lookup=()
  local status name version arn modified extra
  while IFS=$'\t' read -r status name version arn modified extra; do
    if [[ -n "${extra}" || -z "${requested_lookup[$name]:-}" ||
          -n "${status_lookup[$name]:-}" ]]; then
      echo "The SSM version manifest contains an unexpected row." >&2
      return 1
    fi
    case "${status}" in
      present)
        if [[ ! "${version}" =~ ^[1-9][0-9]*$ ||
              ! "${modified}" =~ ^[0-9A-Za-z:+.-]+$ ]] ||
            ! _validate_ssm_parameter_arn "${arn}" "${parameter_path}" "${name}"; then
          echo "The SSM version manifest contains invalid metadata." >&2
          return 1
        fi
        ;;
      absent)
        if [[ "${version}" != - || "${arn}" != - || "${modified}" != - ||
              -n "${required_lookup[$name]:-}" ]]; then
          echo "The SSM version manifest has an invalid absent parameter." >&2
          return 1
        fi
        ;;
      *)
        echo "The SSM version manifest status is invalid." >&2
        return 1
        ;;
    esac
    status_lookup["${name}"]="${status}"
    version_lookup["${name}"]="${version}"
    arn_lookup["${name}"]="${arn}"
    modified_lookup["${name}"]="${modified}"
  done < <(tail -n +2 "${manifest_path}")
  for name in "${requested_names[@]}"; do
    if [[ -z "${status_lookup[$name]:-}" || -n "${!name+x}" ]]; then
      echo "The SSM version manifest is incomplete or a variable is already set." >&2
      return 1
    fi
  done

  local response_file
  response_file="$(mktemp /tmp/nginx-supply-ssm-versioned.XXXXXX.json)" || return 1
  local rows_file
  rows_file="$(mktemp /tmp/nginx-supply-ssm-versioned-rows.XXXXXX.tsv)" || {
    rm -f "${response_file}"
    return 1
  }
  trap 'trap - RETURN; rm -f "${response_file}" "${rows_file}"' RETURN
  declare -A loaded_lookup=()
  declare -A invalid_lookup=()
  declare -A encoded_lookup=()
  local offset selector full_name loaded_name loaded_version loaded_arn loaded_modified encoded invalid_selector
  local -a selectors=()

  for ((offset = 0; offset < ${#requested_names[@]}; offset += 10)); do
    selectors=()
    for name in "${requested_names[@]:offset:10}"; do
      full_name="${parameter_path}/${name}"
      if [[ "${status_lookup[$name]}" == present ]]; then
        selectors+=("${full_name}:${version_lookup[$name]}")
      else
        selectors+=("${full_name}")
      fi
    done
    if ! aws ssm get-parameters \
      --with-decryption \
      --names "${selectors[@]}" \
      --output json > "${response_file}"; then
      return 1
    fi
    if ! jq -e '
      (.Parameters | type == "array") and
      (.InvalidParameters | type == "array") and
      (all(.Parameters[];
        (.Name | type == "string") and
        (.Type == "SecureString") and
        (.Value | type == "string") and
        (.Version | type == "number" and floor == . and . > 0) and
        (.ARN | type == "string") and
        ((.LastModifiedDate | type) == "string" or
          (.LastModifiedDate | type) == "number"))) and
      (all(.InvalidParameters[]; type == "string"))
    ' "${response_file}" >/dev/null; then
      echo "SSM returned invalid versioned parameter metadata." >&2
      return 1
    fi
    jq -r '.Parameters[] |
      [.Name, (.Version | tostring), .ARN, (.LastModifiedDate | tostring),
        (.Value | @base64)] | @tsv' "${response_file}" > "${rows_file}"
    while IFS=$'\t' read -r full_name loaded_version loaded_arn loaded_modified encoded; do
      [[ "${full_name}" == "${parameter_path}/"* ]] || return 1
      loaded_name="${full_name#"${parameter_path}/"}"
      if [[ -z "${requested_lookup[$loaded_name]:-}" ||
            "${status_lookup[$loaded_name]}" != present ||
            -n "${loaded_lookup[$loaded_name]:-}" ||
            "${loaded_version}" != "${version_lookup[$loaded_name]}" ||
            "${loaded_arn}" != "${arn_lookup[$loaded_name]}" ||
            "${loaded_modified}" != "${modified_lookup[$loaded_name]}" ]]; then
        echo "A versioned SSM parameter differs from its approved snapshot." >&2
        return 1
      fi
      loaded_lookup["${loaded_name}"]=1
      encoded_lookup["${loaded_name}"]="${encoded}"
    done < "${rows_file}"
    while IFS= read -r invalid_selector; do
      loaded_name=''
      for name in "${requested_names[@]:offset:10}"; do
        full_name="${parameter_path}/${name}"
        selector="${full_name}"
        if [[ "${status_lookup[$name]}" == present ]]; then
          selector="${full_name}:${version_lookup[$name]}"
        fi
        if [[ "${invalid_selector}" == "${selector}" ]]; then
          loaded_name="${name}"
          break
        fi
      done
      if [[ -z "${loaded_name}" || "${status_lookup[$loaded_name]}" != absent ||
            -n "${invalid_lookup[$loaded_name]:-}" ]]; then
        echo "SSM returned an unexpected invalid version selector." >&2
        return 1
      fi
      invalid_lookup["${loaded_name}"]=1
    done < <(jq -r '.InvalidParameters[]' "${response_file}")
  done

  local value_with_sentinel
  for name in "${requested_names[@]}"; do
    if [[ "${status_lookup[$name]}" == present ]]; then
      if [[ -z "${loaded_lookup[$name]:-}" ]]; then
        echo "An approved SSM parameter version is missing." >&2
        return 1
      fi
      if ! value_with_sentinel="$({
        printf '%s' "${encoded_lookup[$name]}" | base64 --decode
        printf '\001'
      })" || [[ "${value_with_sentinel}" != *$'\001' ]]; then
        echo "A versioned SSM value could not be decoded." >&2
        return 1
      fi
      printf -v "${name}" '%s' "${value_with_sentinel%$'\001'}"
    else
      if [[ -z "${invalid_lookup[$name]:-}" ]]; then
        echo "An absent optional SSM parameter appeared after approval." >&2
        return 1
      fi
      printf -v "${name}" '%s' ''
    fi
    export "${name}"
  done
  rm -f "${response_file}" "${rows_file}"
  trap - RETURN
}
