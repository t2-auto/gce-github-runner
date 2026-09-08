#!/usr/bin/env bash

ACTION_DIR="$( cd $( dirname "${BASH_SOURCE[0]}" ) >/dev/null 2>&1 && pwd )"

machine_zone=
fallback_zones=
forward_args=()
zone_candidates=()

function usage {
  echo "Usage: ${0} --machine_zone=<zone> [--fallback_zones=<zone1,zone2>] <action arguments>"
}

function trim_whitespace {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

function append_zone_candidate {
  local candidate_zone
  candidate_zone=$(trim_whitespace "$1")
  if [[ -z "${candidate_zone}" ]]; then
    return 0
  fi

  local existing_zone
  for existing_zone in "${zone_candidates[@]}"; do
    if [[ "${existing_zone}" == "${candidate_zone}" ]]; then
      return 0
    fi
  done

  zone_candidates+=("${candidate_zone}")
}

function build_zone_candidates {
  zone_candidates=()
  append_zone_candidate "${machine_zone}"

  if [[ -z "${fallback_zones}" ]]; then
    return 0
  fi

  local fallback_zone
  local -a parsed_fallback_zones=()
  IFS=',' read -r -a parsed_fallback_zones <<< "${fallback_zones}"
  for fallback_zone in "${parsed_fallback_zones[@]}"; do
    append_zone_candidate "${fallback_zone}"
  done
}

function is_zone_resource_exhausted {
  local output=$1
  [[ "${output}" == *"ZONE_RESOURCE_POOL_EXHAUSTED"* ]] \
    || [[ "${output}" == *"ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS"* ]] \
    || [[ "${output}" == *"does not have enough resources available to fulfill the request"* ]]
}

function parse_args {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --machine_zone=*)
        machine_zone=${arg#--machine_zone=}
        forward_args+=("$arg")
        ;;
      --fallback_zones=*)
        fallback_zones=${arg#--fallback_zones=}
        ;;
      *)
        forward_args+=("$arg")
        ;;
    esac
  done

  if [[ -z "${machine_zone}" ]]; then
    usage >&2
    echo "machine_zone is required." >&2
    exit 1
  fi
}

function run_action_for_zone {
  local zone=$1
  local arg
  local -a attempt_args=()
  for arg in "${forward_args[@]}"; do
    case "$arg" in
      --machine_zone=*)
        attempt_args+=("--machine_zone=${zone}")
        ;;
      *)
        attempt_args+=("$arg")
        ;;
    esac
  done

  bash "${ACTION_DIR}/action.sh" "${attempt_args[@]}"
}

function write_resolved_zone_output {
  local zone=$1
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "resolved_machine_zone=${zone}" >> "${GITHUB_OUTPUT}"
  fi
}

function main {
  parse_args "$@"
  build_zone_candidates
  echo "Zone candidates: ${zone_candidates[*]}"

  local attempt_output=
  local attempt_status=0
  local candidate_zone=
  local next_zone=
  local zone_idx=0
  local -a exhausted_zones=()

  for (( zone_idx=0; zone_idx<${#zone_candidates[@]}; zone_idx++ )); do
    candidate_zone=${zone_candidates[$zone_idx]}
    next_zone=
    if (( zone_idx + 1 < ${#zone_candidates[@]} )); then
      next_zone=${zone_candidates[$((zone_idx + 1))]}
    fi

    echo "Trying to create runner in ${candidate_zone} ..."
    attempt_output=$(run_action_for_zone "${candidate_zone}" 2>&1)
    attempt_status=$?

    if (( attempt_status == 0 )); then
      if [[ -n "${attempt_output}" ]]; then
        printf '%s\n' "${attempt_output}"
      fi
      write_resolved_zone_output "${candidate_zone}"
      echo "✅ Created runner in ${candidate_zone}"
      return 0
    fi

    if [[ -n "${attempt_output}" ]]; then
      printf '%s\n' "${attempt_output}" >&2
    fi

    if is_zone_resource_exhausted "${attempt_output}"; then
      exhausted_zones+=("${candidate_zone}")
      if [[ -n "${next_zone}" ]]; then
        echo "Zone ${candidate_zone} is exhausted. Falling back to ${next_zone} ..." >&2
        continue
      fi
      echo "Zone ${candidate_zone} is exhausted and no fallback zones remain." >&2
      break
    fi

    echo "Instance creation failed in ${candidate_zone} with a non-retriable error." >&2
    return "${attempt_status}"
  done

  echo "Failed to create runner. Exhausted zones tried: ${exhausted_zones[*]}" >&2
  return 1
}

main "$@"
