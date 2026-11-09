#!/usr/bin/env bash
# Avalia uma instancia "sombra" do qbit-autodelete (DRY_RUN=true) comparando o
# upload que os candidatos a exclusao realmente geraram depois de indicados.
# Como a instancia sombra nao exclui nada, o qBittorrent continua com os torrents
# e o contador `uploaded` mostra quanto upload a politica teria descartado.
#
# Uso: shadow-report.sh --config ARQUIVO_ENV [--unit UNIDADE] [--since "-72 hours"]
#                       [--min-age-hours 24] [--threshold-percent 1]
# Saida 0 quando o upload descartavel fica abaixo do limite; 1 caso contrario.
set -Eeuo pipefail

CONFIG=""
UNIT="qbit-autodelete-shadow.service"
SINCE="-72 hours"
MIN_AGE_HOURS=24
THRESHOLD_PERCENT=1

while (($#)); do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --unit) UNIT="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --min-age-hours) MIN_AGE_HOURS="$2"; shift 2 ;;
    --threshold-percent) THRESHOLD_PERCENT="$2"; shift 2 ;;
    *) printf 'opcao desconhecida: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -r "${CONFIG}" ]] || { printf 'informe --config com o env da instancia\n' >&2; exit 2; }

events="$(journalctl -u "${UNIT}" --since "${SINCE}" --no-pager -o cat 2>/dev/null |
  grep -o 'QBIT_EVENT .*' | sed 's/^QBIT_EVENT //')"
[[ -n "${events}" ]] || { printf 'sem eventos de %s desde %s\n' "${UNIT}" "${SINCE}" >&2; exit 2; }

# shellcheck source=/dev/null
source "${CONFIG}"
cookie="$(mktemp)"
trap 'rm -f "${cookie}"' EXIT
user_enc="$(QBIT_AD_VALUE="${QBT_USER}" jq -rn 'env.QBIT_AD_VALUE|@uri')"
pass_enc="$(QBIT_AD_VALUE="${QBT_PASS}" jq -rn 'env.QBIT_AD_VALUE|@uri')"
printf 'username=%s&password=%s' "${user_enc}" "${pass_enc}" |
  curl -fsS -c "${cookie}" -H "Referer: ${QBT_URL}/" --data-binary @- "${QBT_URL}/api/v2/auth/login" >/dev/null
current="$(curl -fsS -b "${cookie}" -H "Referer: ${QBT_URL}/" "${QBT_URL}/api/v2/torrents/info")"

now_epoch="$(date +%s)"
jq -rn \
  --slurpfile ev <(printf '%s\n' "${events}") \
  --slurpfile current_file <(printf '%s' "${current}") \
  --argjson now "${now_epoch}" \
  --argjson min_age "${MIN_AGE_HOURS}" \
  --argjson threshold "${THRESHOLD_PERCENT}" '
  def epoch:
    . as $t
    | ($t[0:19] + "Z" | fromdateiso8601) as $base
    | ($t[19:] | if . == "Z" or . == "" then 0
         else ((.[0:1] | if . == "-" then -1 else 1 end)
               * ((.[1:3] | tonumber) * 3600 + (.[4:6] | tonumber) * 60)) end) as $offset
    | $base - $offset;
  ($current_file[0] | map({key: .hash, value: .}) | from_entries) as $now_by_hash
  | [$ev[] | select(.event == "dry_run_candidate")]
  | group_by(.hash) | map(sort_by(.timestamp) | .[0]) as $first
  | [$first[]
      | . as $c
      | ($now_by_hash[$c.hash]) as $cur
      | select($cur != null)
      | (($now - ($c.timestamp | epoch)) / 3600) as $age_h
      | select($age_h >= $min_age)
      | {name: $c.name, category: $c.category, size_gib: ($c.size_bytes / 1073741824),
         age_h: $age_h, follower: $c.is_follower, mode: $c.mode,
         gained_gib: ((([$cur.uploaded - $c.uploaded_bytes, 0] | max)) / 1073741824),
         rate_gib_day: ((([$cur.uploaded - $c.uploaded_bytes, 0] | max) / 1073741824) / ($age_h / 24))}] as $obs
  | ([$ev[] | select(.event == "policy_snapshot")] | sort_by(.timestamp)) as $snaps
  | (if ($snaps | length) > 1 then
       ([range(1; $snaps | length) as $i
         | ((($snaps[$i].timestamp | epoch) - ($snaps[$i-1].timestamp | epoch)) as $dt
            | select($dt > 0 and $dt < 5400) | ($snaps[$i-1].upload_speed_bps * $dt))] | add // 0) as $bytes
       | (($snaps[-1].timestamp | epoch) - ($snaps[0].timestamp | epoch)) as $span
       | (if $span > 0 then $bytes / $span * 86400 / 1073741824 else 0 end)
     else 0 end) as $total_day
  | ($obs | map(.rate_gib_day) | add // 0) as $cand_day
  | (if $total_day > 0 then 100 * $cand_day / $total_day else 0 end) as $pct
  | "candidatos observados (>= \($min_age)h): \($obs | length), \($obs | map(.size_gib) | add // 0 | floor) GiB"
  , "upload dos candidatos: \($cand_day * 10 | round / 10) GiB/dia somados; upload total medido: \($total_day * 10 | round / 10) GiB/dia"
  , "upload descartavel: \($pct * 100 | round / 100)% (limite \($threshold)%)"
  , "maiores geradores de upload entre os candidatos:"
  , ($obs | sort_by(-.rate_gib_day) | .[:8][]
      | "  \(.rate_gib_day * 10 | round / 10) GiB/dia  \(.size_gib | floor) GiB  \(.category)  idade=\(.age_h | floor)h  \(.name[0:70])")
  , (if $pct < $threshold then "RESULTADO: dentro do limite" else "RESULTADO: acima do limite" end)
'
