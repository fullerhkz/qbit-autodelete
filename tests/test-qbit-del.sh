#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLS_FILE="$(mktemp -t qbit-del-calls.XXXXXX)"
DISK_JOURNAL="$(mktemp -t qbit-del-disk-journal.XXXXXX)"
trap 'rm -f -- "${CALLS_FILE}" "${DISK_JOURNAL}"' EXIT

fail() { printf 'FALHOU: %s\n' "$*" >&2; exit 1; }
assert_output() { grep -Fq -- "$2" <<<"$1" || fail "'$2' ausente na saida"; }
assert_call() { grep -Fxq -- "$1" "${CALLS_FILE}" || fail "chamada systemd ausente: $1"; }

COMMON_ENV=(
  NO_COLOR=1
  QBIT_DEL_SKIP_ROOT=true
  QBIT_DEL_SKIP_INSTALL_CHECK=true
  QBIT_DEL_SYSTEMCTL="${TEST_ROOT}/tests/mock-systemctl.sh"
  QBIT_DEL_TEST_CALLS="${CALLS_FILE}"
)

log_output="$(env "${COMMON_ENV[@]}" \
  QBIT_DEL_JOURNAL_FILE="${TEST_ROOT}/tests/fixtures/qbit-del-journal.log" \
  "${TEST_ROOT}/qbit-del" log)"
assert_output "${log_output}" "Conexao qBittorrent:     SUCESSO"
assert_output "${log_output}" "Resultado:               CONCLUIDA"
assert_output "${log_output}" "PONTUACAO NA ULTIMA AVALIACAO"
assert_output "${log_output}" "Torrents gerenciados:     3/4 (1 fora da politica)"
assert_output "${log_output}" "Volume gerenciado:        8.00 GiB"
assert_output "${log_output}" "Scores:                   media 68.33 | min 45 | max 90"
assert_output "${log_output}" "Categoria-Filmes  2 torrent(s) | 7.00 GiB | 1.00 MiB/s"
assert_output "${log_output}" "MAIORES SCORES ATUAIS"
assert_output "${log_output}" "score 90     [SELECIONADO] Filme A"
assert_output "${log_output}" "eficiencia 0 MiB/GiB/dia"
assert_output "${log_output}" "Categoria-Filmes  2 torrent(s) | 7.00 GiB"
assert_output "${log_output}" "Categoria-Series  1 torrent(s) | 1.00 GiB"
assert_output "${log_output}" "Filme A"
assert_output "${log_output}" "Torrents removidos:      3"
assert_output "${log_output}" "Espaco estimado:         8.00 GiB"
! grep -Fq 'old-run' <<<"${log_output}" || fail "execucao antiga apareceu no resumo"

sed 's/"mode":"normal"/"mode":"emergency","disk_pressure_enabled":true,"disk_free_bytes":107374182400,"critical_watermark_bytes":214748364800,"low_watermark_bytes":429496729600,"high_watermark_bytes":644245094400,"bytes_needed":536870912000/' \
  "${TEST_ROOT}/tests/fixtures/qbit-del-journal.log" >"${DISK_JOURNAL}"
disk_output="$(env "${COMMON_ENV[@]}" QBIT_DEL_JOURNAL_FILE="${DISK_JOURNAL}" \
  "${TEST_ROOT}/qbit-del" log)"
assert_output "${disk_output}" "Modo da politica:         emergency"
assert_output "${disk_output}" "Espaco livre:             100.00 GiB"
assert_output "${disk_output}" "Emerg./agress./alvo:      200.00 GiB / 400.00 GiB / 600.00 GiB"
assert_output "${disk_output}" "A recuperar nesta faixa:  500.00 GiB"

failure_output="$(env "${COMMON_ENV[@]}" \
  QBIT_DEL_JOURNAL_FILE="${TEST_ROOT}/tests/fixtures/qbit-del-failure.log" \
  "${TEST_ROOT}/qbit-del" log)"
assert_output "${failure_output}" "Modo:                    NAO INICIADO"
assert_output "${failure_output}" "Conexao qBittorrent:     NAO CONFIRMADA"
assert_output "${failure_output}" "Resultado:               FALHOU"
assert_output "${failure_output}" "nao foi possivel autenticar no qBittorrent"

status_output="$(env "${COMMON_ENV[@]}" "${TEST_ROOT}/qbit-del" status)"
assert_output "${status_output}" "Timer:                   active"
assert_output "${status_output}" "concluida com sucesso"
assert_output "${status_output}" "Proximo disparo:"

: > "${CALLS_FILE}"
env "${COMMON_ENV[@]}" "${TEST_ROOT}/qbit-del" run >/dev/null
assert_call "start qbit-autodelete.service"

: > "${CALLS_FILE}"
env "${COMMON_ENV[@]}" "${TEST_ROOT}/qbit-del" stop >/dev/null
assert_call "stop qbit-autodelete.timer"
assert_call "stop qbit-autodelete.service"

: > "${CALLS_FILE}"
env "${COMMON_ENV[@]}" "${TEST_ROOT}/qbit-del" start >/dev/null
assert_call "start qbit-autodelete.timer"
assert_call "start qbit-autodelete.service"

: > "${CALLS_FILE}"
env "${COMMON_ENV[@]}" "${TEST_ROOT}/qbit-del" restart >/dev/null
assert_call "stop qbit-autodelete.timer"
assert_call "stop qbit-autodelete.service"
assert_call "start qbit-autodelete.timer"
assert_call "start qbit-autodelete.service"

printf 'OK: comandos globais, status e relatorio estruturado validados\n'
