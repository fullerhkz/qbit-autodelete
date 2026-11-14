#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_ROOT

port_file="$(mktemp)"
delete_file="$(mktemp)"
rm -f "${delete_file}"
python3 "${TEST_ROOT}/tests/mock_qbt.py" "${port_file}" "${delete_file}" &
server_pid=$!
state_file="${TEST_ROOT}/tests/fixtures/e2e-state.json"
rm -f "${state_file}"
cleanup_test() {
  kill "${server_pid}" 2>/dev/null || true
  rm -f "${port_file}.payload/payload.bin"
  rmdir "${port_file}.payload" 2>/dev/null || true
  rm -f "${state_file}" "${state_file}.lastrun" "${port_file}" "${delete_file}" \
    "${TEST_ROOT}/tests/fixtures/e2e-gate-state.json" "${TEST_ROOT}/tests/fixtures/e2e-gate-state.json.lastrun" \
    "${TEST_ROOT}/tests/fixtures/e2e-gate.lock"
}
trap cleanup_test EXIT

for _ in {1..100}; do
  if [[ -s "${port_file}" ]]; then break; fi
  if kill -0 "${server_pid}" 2>/dev/null; then sleep 0.05; else exit 1; fi
done
[[ -s "${port_file}" ]]
export TEST_QBT_URL="http://127.0.0.1:$(<"${port_file}")"

first_output="$("${TEST_ROOT}/qbit-autodelete.sh" --config "${TEST_ROOT}/tests/fixtures/e2e.env")"
grep -q 'historico_pronto=0.*selecionados=0' <<<"${first_output}"
[[ -s "${state_file}" ]]

sleep 1.1
second_output="$("${TEST_ROOT}/qbit-autodelete.sh" --config "${TEST_ROOT}/tests/fixtures/e2e.env")"
grep -q 'historico_pronto=1.*selecionados=1' <<<"${second_output}"
grep -q 'eficiencia=0MiB/GiB/dia' <<<"${second_output}"
grep -q '\[DRY-RUN\] nenhuma exclusao executada' <<<"${second_output}"
grep -q 'QBIT_EVENT.*"event":"connection".*"success":true' <<<"${second_output}"
grep -q 'QBIT_EVENT.*"event":"run_configured".*"dry_run":true' <<<"${second_output}"
grep -q 'QBIT_EVENT.*"event":"policy_snapshot".*"managed_torrents":1.*"top_scores"' <<<"${second_output}"
grep -q '"scores":{"average":90,"minimum":90,"maximum":90}' <<<"${second_output}"
grep -q 'QBIT_EVENT.*"event":"deletion_summary".*"dry_run":true' <<<"${second_output}"
grep -q 'QBIT_EVENT.*"event":"dry_run_candidate".*"hash":"mockhash".*"uploaded_bytes":0' <<<"${second_output}"
grep -q 'grupos: selecionados=1' <<<"${second_output}"
[[ ! -e "${delete_file}" ]]

live_output="$("${TEST_ROOT}/qbit-autodelete.sh" --config "${TEST_ROOT}/tests/fixtures/e2e-live.env")"
grep -q 'QBIT_EVENT.*"event":"torrent_deleted".*"category":"Categoria-Filmes"' <<<"${live_output}"
grep -q 'QBIT_EVENT.*"event":"deletion_summary".*"planned_bytes":53687091200.*"deleted_count":1.*"released_bytes":0.*"physical_measurement_available":false' <<<"${live_output}"
grep -q 'QBIT_EVENT.*"event":"run_completed".*"success":true' <<<"${live_output}"
[[ -s "${delete_file}" ]]

# Modo de pressao: silencioso sem pressao; executa sob pressao; respeita o intervalo minimo.
quiet_output="$("${TEST_ROOT}/qbit-autodelete.sh" --pressure-gate --config "${TEST_ROOT}/tests/fixtures/e2e-gate-quiet.env" 2>&1)"
[[ -z "${quiet_output}" ]]
gate_output="$("${TEST_ROOT}/qbit-autodelete.sh" --pressure-gate --config "${TEST_ROOT}/tests/fixtures/e2e-gate-run.env" 2>&1)"
grep -q 'QBIT_EVENT.*"event":"run_started"' <<<"${gate_output}"
grep -q 'modo=aggressive' <<<"${gate_output}"
grep -q 'QBIT_EVENT.*"event":"run_completed".*"success":true' <<<"${gate_output}"
[[ -e "${TEST_ROOT}/tests/fixtures/e2e-gate-state.json.lastrun" ]]
repeat_output="$("${TEST_ROOT}/qbit-autodelete.sh" --pressure-gate --config "${TEST_ROOT}/tests/fixtures/e2e-gate-run.env" 2>&1)"
[[ -z "${repeat_output}" ]]

set +e
failed_output="$("${TEST_ROOT}/qbit-autodelete.sh" --config "${TEST_ROOT}/tests/fixtures/ausente.env" 2>&1)"
failed_status=$?
set -e
((failed_status != 0))
grep -q 'QBIT_EVENT.*"event":"run_started"' <<<"${failed_output}"
grep -q 'QBIT_EVENT.*"event":"run_failed".*arquivo de configuracao nao legivel' <<<"${failed_output}"
printf 'OK: API, aprendizado, dry-run, exclusao e eventos estruturados validados\n'
