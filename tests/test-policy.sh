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

assert_eq "${NORMAL_MIN_SCORE}" "65" "perfil racing: score normal"
assert_eq "${AGGRESSIVE_MIN_SCORE}" "30" "perfil racing: score agressivo"
assert_eq "${AGGRESSIVE_WITHOUT_HISTORY}" "false" "perfil racing: exige historico"
assert_eq "${MAX_DELETE_PER_RUN}" "20" "perfil racing: limite de itens"
assert_eq "${MAX_RECLAIM_GB_PER_RUN}" "500" "perfil racing: limite estimado por rodada"
assert_eq "${EMERGENCY_WITHOUT_HISTORY}" "true" "emergencia aceita sem historico"
assert_eq "${EMERGENCY_MAX_DELETE_PER_RUN}" "30" "limite de itens na emergencia"
assert_eq "${EMERGENCY_MAX_RECLAIM_GB_PER_RUN}" "800" "limite estimado na emergencia"

now=2000000000
rules='{"Categoria Filmes":{"retention_hours":48,"min_ratio":1.0}}'
input="$(jq -cn --argjson now "${now}" '[
  {
    hash:"large", name:"grande sem upload", category:"Categoria Filmes",
    progress:1, amount_left:0, completion_on:($now - 10*86400),
    last_activity:($now - 8*86400), size:(100*1073741824), total_size:(100*1073741824),
    uploaded:0, ratio:2, num_complete:20, num_seeds:2, num_incomplete:0,
    upspeed:0, dlspeed:0, state:"stalledUP", force_start:false, tags:""
  },
  {
    hash:"productive", name:"alto upload por GiB", category:"Categoria Filmes",
    progress:1, amount_left:0, completion_on:($now - 10*86400),
    last_activity:($now - 8*86400), size:(100*1073741824), total_size:(100*1073741824),
    uploaded:(10*1073741824), ratio:2, num_complete:0, num_seeds:0, num_incomplete:20,
    upspeed:0, dlspeed:0, state:"stalledUP", force_start:false, tags:""
  },
  {
    hash:"active", name:"ativo", category:"Categoria Filmes",
    progress:1, amount_left:0, completion_on:($now - 10*86400),
    last_activity:($now - 8*86400), size:(100*1073741824), uploaded:0, ratio:2,
    num_complete:20, upspeed:1024, dlspeed:0, state:"uploading", force_start:false, tags:""
  },
  {
    hash:"protected", name:"protegido", category:"Categoria Filmes",
    progress:1, amount_left:0, completion_on:($now - 10*86400),
    last_activity:($now - 8*86400), size:(100*1073741824), uploaded:0, ratio:2,
    num_complete:20, upspeed:0, dlspeed:0, state:"stalledUP", force_start:false, tags:"keep"
  },
  {
    hash:"under_ratio", name:"ratio ainda protegido", category:"Categoria Filmes",
    progress:1, amount_left:0, completion_on:($now - 100*3600),
    last_activity:($now - 100*3600), size:(100*1073741824), uploaded:0, ratio:0.2,
    num_complete:20, upspeed:0, dlspeed:0, state:"stalledUP", force_start:false, tags:""
  },
  {
    hash:"young", name:"novo", category:"Categoria Filmes",
    progress:1, amount_left:0, completion_on:($now - 24*3600),
    last_activity:($now - 24*3600), size:(100*1073741824), uploaded:0, ratio:2,
    num_complete:20, upspeed:0, dlspeed:0, state:"stalledUP", force_start:false, tags:""
  },
  {
    hash:"partial", name:"incompleto visto no swarm", category:"Categoria Filmes",
    progress:0.5, amount_left:100, completion_on:0, seen_complete:($now - 30*86400),
    added_on:($now - 30*86400), last_activity:($now - 8*86400), size:(100*1073741824),
    uploaded:0, ratio:2, num_complete:20, upspeed:0, dlspeed:0,
    state:"stalledDL", force_start:false, tags:""
  }
]')"

history="$(jq -cn --argjson now "${now}" '{
  version:1, updated_at:($now - 3600), torrents:{
    large:{uploaded:0, sampled_at:($now - 3600), ewma_upload_bph:0, samples:5, observed_seconds:18000},
    productive:{uploaded:0, sampled_at:($now - 3600), ewma_upload_bph:0, samples:5, observed_seconds:18000}
  }
}')"

scored="$(score_torrents "${now}" "${rules}" "${history}" <<<"${input}")"
assert_eq "$(jq -r '.[] | select(.hash=="large") | .cleanup_score' <<<"${scored}")" "100" "torrent improdutivo recebe score maximo"
assert_eq "$(jq -r '.[] | select(.hash=="large") | .history_ready' <<<"${scored}")" "true" "historico suficiente"
assert_eq "$(jq -r '.[] | select(.hash=="large") | .eligible' <<<"${scored}")" "true" "candidato valido"
assert_eq "$(jq -r '.[] | select(.hash=="productive") | .cleanup_score' <<<"${scored}")" "40" "upload eficiente reduz score"
assert_eq "$(jq -r '.[] | select(.hash=="active") | .eligible' <<<"${scored}")" "false" "transferencia ativa"
assert_eq "$(jq -r '.[] | select(.hash=="protected") | .eligible' <<<"${scored}")" "false" "tag protegida"
assert_eq "$(jq -r '.[] | select(.hash=="under_ratio") | .ratio_protected' <<<"${scored}")" "true" "ratio minimo"
assert_eq "$(jq -r '.[] | select(.hash=="young") | .eligible' <<<"${scored}")" "false" "retencao minima"
assert_eq "$(jq -r '.[] | select(.hash=="partial") | .is_complete' <<<"${scored}")" "false" "seen_complete nao e conclusao local"
assert_eq "$(jq -r '.[] | select(.hash=="partial") | .eligible' <<<"${scored}")" "false" "incompleto protegido"

RUN_MODE="normal"
selected="$(select_candidates "${scored}")"
assert_eq "$(jq -r 'length' <<<"${selected}")" "1" "selecao normal"
assert_eq "$(jq -r '.[0].hash' <<<"${selected}")" "large" "preserva maior retorno por GiB"

without_history="$(jq -c '[.[] | select(.hash=="large") | .history_ready=false | .cleanup_score=0]' <<<"${scored}")"
RUN_MODE="aggressive"
BYTES_NEEDED=0
selected="$(select_candidates "${without_history}")"
assert_eq "$(jq -r 'length' <<<"${selected}")" "0" "agressivo ainda protege sem historico"
RUN_MODE="emergency"
BYTES_NEEDED=1073741824
selected="$(select_candidates "${without_history}")"
assert_eq "$(jq -r 'length' <<<"${selected}")" "1" "emergencia evita disco cheio sem historico"

# Com 100% como piso, qualquer filesystem real entra em pressao.
DISK_PRESSURE_ENABLED="true"
STORAGE_PATH="/tmp"
LOW_WATERMARK_GB=0
HIGH_WATERMARK_GB=0
CRITICAL_WATERMARK_GB=0
LOW_WATERMARK_PERCENT=100
HIGH_WATERMARK_PERCENT=100
CRITICAL_WATERMARK_PERCENT=0
choose_mode
assert_eq "${RUN_MODE}" "aggressive" "gatilho de pressao por percentual"
((BYTES_NEEDED > 0)) || fail "modo agressivo deve calcular bytes a recuperar"

CRITICAL_WATERMARK_PERCENT=100
choose_mode
assert_eq "${RUN_MODE}" "emergency" "gatilho critico por percentual"

# Regressao: centenas de torrents excediam o limite por argumento do Linux quando
# o JSON completo era passado a jq com --argjson. O resumo deve usar stdin.
padding="$(printf '%0800d' 0)"
large_snapshot="$(jq -cn --arg padding "${padding}" '[
  range(0; 400) as $i | {
    hash: ("hash-" + ($i|tostring)),
    name: ($padding + ($i|tostring)),
    category: "Carga",
    size_bytes: 1073741824,
    upspeed: 0,
    cleanup_score: 50,
    upload_efficiency_mib_per_gib_day: 0,
    inactive_hours: 24,
    ratio: 1,
    swarm_seeds: 1,
    swarm_leechers: 0,
    history_ready: true,
    eligible: true,
    is_active_transfer: false
  }
]')"
RUN_ID="policy-regression"
RUN_MODE="normal"
snapshot_output="$(emit_policy_snapshot "${large_snapshot}" '[]' 500)"
grep -Fq '"managed_torrents":400' <<<"${snapshot_output}" ||
  fail "resumo grande nao foi produzido via stdin"
grep -Fq '"disk_pressure_enabled":true' <<<"${snapshot_output}" ||
  fail "estado do disco ausente no resumo"

snapshot_output="$(emit_policy_snapshot '{json-invalido' '[]' 1)"
grep -Fq 'a limpeza continuara' <<<"${snapshot_output}" ||
  fail "falha de observabilidade bloqueou a politica"

printf 'OK: retorno de upload, historico, ratio e protecoes validados\n'
