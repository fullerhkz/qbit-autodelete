#!/usr/bin/env bash
set -Eeuo pipefail

[[ -z "${QBIT_DEL_TEST_CALLS:-}" ]] || printf '%s\n' "$*" >> "${QBIT_DEL_TEST_CALLS}"

if [[ "${1:-}" == "show" ]]; then
  unit="${2:-}"
  property=""
  for argument in "$@"; do
    [[ "${argument}" == --property=* ]] && property="${argument#--property=}"
  done
  case "${property}" in
    LoadState) printf 'loaded\n' ;;
    ActiveState)
      [[ "${unit}" == *.timer ]] && printf 'active\n' || printf 'inactive\n'
      ;;
    UnitFileState) printf 'enabled\n' ;;
    Result) printf 'success\n' ;;
    ExecMainStatus) printf '0\n' ;;
    ExecMainStartTimestamp) printf 'Sun 2026-07-13 21:15:00 -03\n' ;;
    ExecMainExitTimestamp) printf 'Sun 2026-07-13 21:15:04 -03\n' ;;
    LastTriggerUSec) printf 'Sun 2026-07-13 21:15:00 -03\n' ;;
    NextElapseUSecRealtime) printf 'Sun 2026-07-13 22:15:00 -03\n' ;;
  esac
fi
