#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_ROOT

port_file="$(mktemp)"
python3 "${TEST_ROOT}/tests/mock_qbt.py" "${port_file}" &
server_pid=$!
state_file="${TEST_ROOT}/tests/fixtures/e2e-state.json"
rm -f "${state_file}"
cleanup_test() { kill "${server_pid}" 2>/dev/null || true; rm -f "${state_file}" "${port_file}"; }
trap cleanup_test EXIT

for _ in {1..20}; do
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
printf 'OK: API, aprendizado persistente, score de upload e dry-run validados\n'
