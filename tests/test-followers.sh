#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEST_ROOT QBIT_AUTODELETE_LIBRARY=true
# shellcheck source=../qbit-autodelete.sh
source "${TEST_ROOT}/qbit-autodelete.sh"

fail() { printf 'FALHOU: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "esperado '$2', recebido '$1' ($3)"; }

parse_args --config "${TEST_ROOT}/tests/fixtures/test.env"
load_config
validate_config

# --- seguidores: carga, espacos no nome e precedencia sobre a regra do arquivo ---
rules_file="$(mktemp)"
printf 'Categoria Filmes|48|1.0|24\ncross-seed-link|87600|1.0|24\nCat Com Espaco|10|0|5\n' >"${rules_file}"
CATEGORY_RULES_FILE="${rules_file}"
FOLLOWER_CATEGORIES=" cross-seed-link , Cat Com Espaco ,,"
RETENTION_HOURS=() EMERGENCY_RETENTION_HOURS=() MIN_RATIOS=()
load_category_rules
assert_eq "${#RETENTION_HOURS[@]}" "1" "seguidores saem das regras proprias"
assert_eq "${RETENTION_HOURS[Categoria Filmes]}" "48" "regra do pai preservada"
assert_eq "$(jq -r 'sort | join("|")' <<<"${FOLLOWERS_JSON}")" "Cat Com Espaco|cross-seed-link" "lista de seguidores"
rm -f "${rules_file}"
FOLLOWER_CATEGORIES="cross-seed-link"
RETENTION_HOURS=() EMERGENCY_RETENTION_HOURS=() MIN_RATIOS=()
CATEGORY_RULES_FILE="${TEST_ROOT}/example/qbit-autodelete.categories"
load_category_rules

# --- grupo pai + links em hardlink de verdade ---
dir="$(mktemp -d -t qbit-follow-test.XXXXXX)"
trap 'rm -rf -- "${dir}"' EXIT
printf 'conteudo-do-pai' >"${dir}/pai.mkv"
ln "${dir}/pai.mkv" "${dir}/link1.mkv"
ln "${dir}/pai.mkv" "${dir}/link2.mkv"

now=2000000000
GIB=1073741824
rules='{"Categoria Filmes":{"retention_hours":48,"emergency_retention_hours":24,"min_ratio":0}}'
history='{"version":1,"torrents":{}}'
history="$(jq -cn --argjson now "${now}" '{version:1, updated_at:($now-3600), torrents:{
  pai:{uploaded:0, sampled_at:($now-3600), ewma_upload_bph:0, samples:9, observed_seconds:90000}}}')"

mk() { # hash category content_path age_h upspeed downloaded tags
  jq -cn --argjson now "${now}" --arg hash "$1" --arg category "$2" --arg path "$3" \
    --argjson age "$4" --argjson up "$5" --argjson dl "$6" --arg tags "$7" '{
    hash:$hash, name:("torrent " + $hash), category:$category, content_path:$path,
    progress:1, amount_left:0, completion_on:($now - $age*3600), added_on:($now - $age*3600),
    last_activity:($now - $age*3600), size:(10*1073741824), total_size:(10*1073741824),
    uploaded:0, downloaded:$dl, ratio:0.1, num_complete:20, num_incomplete:0,
    upspeed:$up, dlspeed:0, state:"stalledUP", force_start:false, tags:$tags}'
}

DISK_PRESSURE_ENABLED=true
DELETE_FILES=true
FOLLOWER_ORPHAN_HOURS=0
FOLLOWER_DOWNLOAD_PROTECT_HOURS=168
PROTECT_EFFICIENCY_MIB_PER_GIB_DAY=50
YIELD_OVERRIDE=false
FOLLOWERS_JSON='["cross-seed-link"]'
BYTES_NEEDED=$((1 * GIB))

run_case() { # modo; le o array de torrents em stdin
  RUN_MODE="$1"
  local raw scored
  raw="$(cat)"
  scored="$(score_torrents "${now}" "${rules}" "${history}" <<<"${raw}")"
  enrich_reclaimability "${scored}"
}
input() {
  jq -cn --argjson a "$1" --argjson b "$2" --argjson c "$3" '[$a, $b, $c]'
}

parent_ok="$(mk pai "Categoria Filmes" "${dir}/pai.mkv" 100 0 0 "")"
link_a="$(mk la cross-seed-link "${dir}/link1.mkv" 1 0 0 "")"
link_b="$(mk lb cross-seed-link "${dir}/link2.mkv" 1 0 0 "")"

for mode in normal aggressive emergency; do
  scored="$(input "${parent_ok}" "${link_a}" "${link_b}" | run_case "${mode}")"
  assert_eq "$(jq -r '[.[] | select(.is_follower)] | length' <<<"${scored}")" "2" "seguidores marcados (${mode})"
  RUN_MODE="${mode}"
  selected="$(select_candidates "${scored}")"
  assert_eq "$(jq -r 'length' <<<"${selected}")" "3" "pai vencido leva os links junto (${mode})"
  assert_eq "$(jq -r '[.[] | select(.is_follower)] | length' <<<"${selected}")" "2" "links incluidos (${mode})"
  (($(jq '[.[].selection_bytes] | add // 0' <<<"${selected}") > 0)) ||
    fail "grupo completo deveria liberar blocos (${mode})"
done

# pai ainda dentro da retencao: nada sai, mesmo com os links "velhos"
young_parent="$(mk pai "Categoria Filmes" "${dir}/pai.mkv" 10 0 0 "")"
scored="$(input "${young_parent}" "${link_a}" "${link_b}" | run_case normal)"
RUN_MODE=normal
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "pai na retencao protege os links"
assert_eq "$(explain_selection "${scored}" | jq -r '.blocked.pai_retencao')" "1" "motivo do bloqueio"

# veto por tag nos links
tagged="$(mk la cross-seed-link "${dir}/link1.mkv" 1 0 0 "keep")"
scored="$(input "${parent_ok}" "${tagged}" "${link_b}" | run_case normal)"
RUN_MODE=normal
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "tag keep no link protege o grupo"
assert_eq "$(explain_selection "${scored}" | jq -r '.blocked.link_protegido')" "1" "motivo link protegido"

# link que baixou dados e ainda esta no prazo do tracker
downloaded="$(mk la cross-seed-link "${dir}/link1.mkv" 24 0 5242880 "")"
scored="$(input "${parent_ok}" "${downloaded}" "${link_b}" | run_case normal)"
RUN_MODE=normal
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "link com download protege o grupo no prazo"
old_downloaded="$(mk la cross-seed-link "${dir}/link1.mkv" 200 0 5242880 "")"
scored="$(input "${parent_ok}" "${old_downloaded}" "${link_b}" | run_case normal)"
assert_eq "$(select_candidates "${scored}" | jq 'length')" "3" "download antigo deixa de proteger"

# protecao por rendimento (isola o criterio desligando o bloqueio por transferencia)
SKIP_ACTIVE_TRANSFERS=false
busy_parent="$(mk pai "Categoria Filmes" "${dir}/pai.mkv" 100 5242880 0 "")" # ~43 GiB/dia em 10 GiB
scored="$(input "${busy_parent}" "${link_a}" "${link_b}" | run_case normal)"
RUN_MODE=normal
assert_eq "$(jq -r '.[] | select(.hash=="pai") | .blockers.yield' <<<"${scored}")" "true" "rendimento alto bloqueia"
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "grupo quente nao e apagado"
YIELD_OVERRIDE=true
scored="$(input "${busy_parent}" "${link_a}" "${link_b}" | run_case emergency)"
RUN_MODE=emergency
assert_eq "$(select_candidates "${scored}" | jq 'length')" "3" "ultimo recurso libera o grupo quente"
YIELD_OVERRIDE=false
SKIP_ACTIVE_TRANSFERS=true

# orfaos: so saem se a opcao estiver ligada e o tempo vencido
printf 'conteudo-orfao' >"${dir}/orfao1.mkv"
ln "${dir}/orfao1.mkv" "${dir}/orfao2.mkv"
orphan_a="$(mk la cross-seed-link "${dir}/orfao1.mkv" 30 0 0 "")"
orphan_b="$(mk lb cross-seed-link "${dir}/orfao2.mkv" 30 0 0 "")"
only_links="$(jq -cn --argjson a "${orphan_a}" --argjson b "${orphan_b}" '[$a,$b]')"
scored="$(run_case normal <<<"${only_links}")"
RUN_MODE=normal
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "orfaos desligados por padrao"
FOLLOWER_ORPHAN_HOURS=24
assert_eq "$(select_candidates "${scored}" | jq 'length')" "2" "orfaos vencidos saem quando habilitado"
FOLLOWER_ORPHAN_HOURS=48
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "orfaos antes do prazo ficam"
FOLLOWER_ORPHAN_HOURS=0

# orfao cujo arquivo tem outro hardlink fora do grupo (pai protegido) nunca sai
ln "${dir}/orfao1.mkv" "${dir}/fora-do-grupo.mkv"
FOLLOWER_ORPHAN_HOURS=24
scored="$(run_case normal <<<"${only_links}")"
RUN_MODE=normal
assert_eq "$(select_candidates "${scored}" | jq 'length')" "0" "hardlink externo protege os orfaos"
rm -f "${dir}/fora-do-grupo.mkv"
FOLLOWER_ORPHAN_HOURS=0

# choose_mode: rendimento so cede quase sem espaco
DISK_PRESSURE_ENABLED=true
STORAGE_PATH="/tmp"
LOW_WATERMARK_GB=0 HIGH_WATERMARK_GB=0 CRITICAL_WATERMARK_GB=0
LOW_WATERMARK_PERCENT=100 HIGH_WATERMARK_PERCENT=100 CRITICAL_WATERMARK_PERCENT=100
YIELD_OVERRIDE_PERCENT_OF_CRITICAL=100
choose_mode
assert_eq "${RUN_MODE}" "emergency" "emergencia"
assert_eq "${YIELD_OVERRIDE}" "true" "sem espaco libera os torrents quentes"
YIELD_OVERRIDE_PERCENT_OF_CRITICAL=0
choose_mode
assert_eq "${YIELD_OVERRIDE}" "false" "com fracao zero o rendimento nunca cede"

# reconferencia antes de excluir (curl simulado)
COOKIE_JAR="/dev/null"
CURL_COMMON=()
QBT_URL="http://qbt.invalid"
REVERIFY_BEFORE_DELETE=true
YIELD_OVERRIDE=false
RUN_MODE=normal
scored="$(input "${parent_ok}" "${link_a}" "${link_b}" | run_case normal)"
selected="$(select_candidates "${scored}")"
assert_eq "$(jq 'length' <<<"${selected}")" "3" "base da reconferencia"
curl() { printf '%s' "${MOCK_CURL_RESPONSE}"; }
same_state="$(jq -cn --argjson a "${parent_ok}" --argjson b "${link_a}" --argjson c "${link_b}" '[$a,$b,$c]')"
MOCK_CURL_RESPONSE="${same_state}"
assert_eq "$(reverify_selection "${selected}" 2>/dev/null | jq 'length')" "3" "estado igual mantem o grupo"
MOCK_CURL_RESPONSE="$(jq -cn --argjson a "${parent_ok}" --argjson b "${tagged}" --argjson c "${link_b}" '[$a,$b,$c]')"
assert_eq "$(reverify_selection "${selected}" 2>/dev/null | jq 'length')" "0" "tag nova derruba o grupo inteiro"
MOCK_CURL_RESPONSE="$(jq -cn --argjson a "${busy_parent}" --argjson b "${link_a}" --argjson c "${link_b}" '[$a,$b,$c]')"
assert_eq "$(reverify_selection "${selected}" 2>/dev/null | jq 'length')" "0" "pai voltou a render: grupo inteiro fica"
MOCK_CURL_RESPONSE="$(jq -cn --argjson a "${parent_ok}" --argjson b "${link_b}" '[$a,$b]')"
assert_eq "$(reverify_selection "${selected}" 2>/dev/null | jq 'length')" "0" "membro ausente derruba o grupo"
MOCK_CURL_RESPONSE='nao-e-json'
assert_eq "$(reverify_selection "${selected}" 2>/dev/null | jq 'length')" "0" "falha da API adia a exclusao"
unset -f curl

printf 'OK: seguidores, grupos, orfaos, rendimento e reconferencia validados\n'
