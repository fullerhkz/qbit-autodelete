#!/usr/bin/env bash
set -euo pipefail

# Validação da configuração e valores seguros por padrão
: "${QBT_URL:=http://127.0.0.1:PORTA_QBITTORRENT}"
: "${QBT_USER:?set QBT_USER}"
: "${QBT_PASS:?set QBT_PASS}"

# Normalizar URL e definir valores seguros por padrão
QBT_URL="${QBT_URL%/}"
DRY_RUN="${DRY_RUN:-true}"
LOG_LEVEL="${LOG_LEVEL:-summary}"
ALLOW_INCOMPLETE_DELETE="${ALLOW_INCOMPLETE_DELETE:-false}"
MAX_DELETE_PER_RUN="${MAX_DELETE_PER_RUN:-100}"

# ====== Aguarda qBittorrent responder ======
RETRIES=5
for i in $(seq 1 $RETRIES); do
    if curl -s --max-time 3 "${QBT_URL}/api/v2/app/version" >/dev/null; then
        break
    fi
    sleep 2
    [ "$i" -eq "$RETRIES" ] && {
        echo "[AVISO] qBittorrent ainda não respondeu após ${RETRIES} tentativas. Abortando sem marcar failed."
        exit 0
    }
done

# Opções seguras do curl
CURL_OPTS_BASE=(
  --silent --show-error --fail-with-body
  --connect-timeout 10 --max-time 60
  --retry 3 --retry-delay 1 --retry-all-errors
  -u "${QBT_USER}:${QBT_PASS}"
)

if [[ "${CURL_INSECURE:-}" == "--insecure" ]]; then
  CURL_OPTS_BASE+=(--insecure)
  echo "[AVISO] TLS inseguro habilitado"
fi

# Política de retenção (em horas)
declare -A RETENTION_HOURS=(
  ["Categoria-1"]=168
  ["Categoria-2"]=168
  ["Categoria-3"]=168
  ["Categoria-4"]=168
  ["Categoria-5"]=168
  ["Categoria-6"]=168
  ["Categoria-7"]=168
  ["Categoria-8"]=168
  ["Categoria-9"]=168
)

INCLUDE_NO_CATEGORY="${INCLUDE_NO_CATEGORY:-false}"
NO_CATEGORY_RETENTION_HOURS="${NO_CATEGORY_RETENTION_HOURS:-168}"

# Dependências
for cmd in curl jq date awk sed; do
  command -v "${cmd}" >/dev/null 2>/dev/null || {
    echo "ERRO: comando '${cmd}' não encontrado." >&2
    exit 1
  }
done

# urlencode
urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))"
  else
    local input_content
    input_content=$(cat)
    jq -rn --arg s "${input_content}" '$s|@uri'
  fi
}

# Cookie seguro
COOKIE_JAR="$(mktemp -t qbt_cookie_XXXXXX)"
cleanup() { rm -f "${COOKIE_JAR}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Login
login_qbittorrent() {
  echo "[INFO] Iniciando sessão..."
  local origin_host
  origin_host="$(echo "${QBT_URL}" | sed -E 's#(https?://[^/]+).*#\1#')"

  local login_response
  login_response=$(curl -s -D - -c "${COOKIE_JAR}" \
    "${CURL_OPTS_BASE[@]}" \
    -X POST "${QBT_URL}/api/v2/auth/login" \
    -H "Referer: ${QBT_URL}/" -H "Origin: ${origin_host}" \
    --data "username=${QBT_USER}&password=${QBT_PASS}" |
    awk 'BEGIN{RS="\r\n\r\n"} NR>1{print}')

  if ! printf "%s" "${login_response}" | grep -qi '^Ok\.$'; then
    echo "[ERRO] Falha no login: ${login_response}" >&2
    exit 1
  fi
  echo "[INFO] Login OK."
}

# API helpers
fetch_all_torrents() {
  curl -s -b "${COOKIE_JAR}" "${CURL_OPTS_BASE[@]}" "${QBT_URL}/api/v2/torrents/info"
}

fetch_category_torrents() {
  local category="$1"
  local category_encoded
  category_encoded=$(printf "%s" "${category}" | urlencode)
  curl -s -b "${COOKIE_JAR}" "${CURL_OPTS_BASE[@]}" \
    "${QBT_URL}/api/v2/torrents/info?category=${category_encoded}"
}

# Processamento
enrich_torrents() {
  local now_epoch="$1"
  jq -c --argjson now "${now_epoch}" '
    map(
      . + {
        is_complete: (
          [ ((.progress // 0) >= 0.9999),
            ((.completion_on // 0) > 0),
            ((.seen_complete // 0) > 0)
          ] | map(select(.)) | length > 0
        ),
        effective_age: (
          [
            (if (.completion_on // 0) > 0 then ($now - .completion_on) else 0 end),
            (.seeding_time // 0),
            (if (.seen_complete // 0) > 0 then ($now - .seen_complete) else 0 end),
            (if (.added_on // 0) > 0 then ($now - .added_on) else 0 end),
            (.time_active // 0)
          ] | max
        )
      }
    )
  '
}

filter_candidates() {
  local seconds="$1"
  local allow_incomplete="$2"
  local max_delete="$3"
  jq -c --argjson secs "${seconds}" --argjson allow "${allow_incomplete}" --argjson max "${max_delete}" '
    (map(
      select( (if $allow then true else (.is_complete==true) end) )
      | select(.effective_age > $secs)
    ) // []) | .[0:$max]
  '
}

make_summary() {
  local seconds="$1"
  local allow_incomplete="$2"
  jq -c --argjson secs "${seconds}" --argjson allow "${allow_incomplete}" '
    {
      total: (length),
      completos: (map(select(.is_complete==true)) | length),
      elegiveis_por_idade: (map(select(.effective_age>$secs)) | length)
    }
  '
}

show_top3() {
  local allow_incomplete="$1"
  jq -r --argjson allow "${allow_incomplete}" '
    map(select( (if $allow then true else (.is_complete==true) end) ))
    | sort_by(.effective_age) | reverse | .[0:3]
    | map([.name, ((.effective_age/3600)|floor|tostring) + "h"] | @tsv)
    | .[]
  '
}

delete_torrents() {
  local hashes="$1"
  local count="$2"
  local label="$3"
  echo "[INFO] Excluindo ${count} torrents em ${label}..."
  local response
  response=$(curl -s -b "${COOKIE_JAR}" "${CURL_OPTS_BASE[@]}" \
    -d "hashes=${hashes}&deleteFiles=true" \
    "${QBT_URL}/api/v2/torrents/delete")
  [[ -z "${response}" ]] && echo "[OK] Exclusão concluída (${label})." || echo "[AVISO] Resposta: ${response}" >&2
}

process_category() {
  local category_name="$1"
  local hours="$2"

  echo
  if [[ "${category_name}" == "__NO_CATEGORY__" ]]; then
    echo "========== (Sem Categoria) (retenção: ${hours}h) =========="
    local all_torrents
    all_torrents=$(fetch_all_torrents)
    local subset
    subset=$(echo "${all_torrents}" | jq -c '[ .[]? | select((.category == null or .category == "")) ]')
    process_subset "${subset}" "(sem categoria)" "${hours}"
    return 0
  fi

  echo "========== Categoria: '${category_name}' (retenção: ${hours}h) =========="
  local json_data
  json_data=$(fetch_category_torrents "${category_name}")

  if [[ -z "${json_data//[$'\n' ]/}" || "${json_data}" == "[]" ]]; then
    echo "[INFO] Nenhum torrent elegível para exclusão na categoria '${category_name}'."
    return 0
  fi

  process_subset "${json_data}" "categoria '${category_name}'" "${hours}"
}

process_subset() {
  local raw_json="$1"
  local label="$2"
  local hours="$3"

  local seconds=$((hours * 60 * 60))
  local allow_flag="false"
  [[ "${ALLOW_INCOMPLETE_DELETE}" == "true" ]] && allow_flag="true"

  local enriched_array
  enriched_array=$(echo "${raw_json}" | enrich_torrents "${NOW_EPOCH}")

  local summary
  summary=$(echo "${enriched_array}" | make_summary "${seconds}" "${allow_flag}")
  echo "[INFO] Resumo ${label}: ${summary}"

  local candidates
  candidates=$(echo "${enriched_array}" | filter_candidates "${seconds}" "${allow_flag}" "${MAX_DELETE_PER_RUN}")
  local count
  count=$(printf "%s\n" "${candidates}" | jq 'length')

  if [[ "${count}" -eq 0 ]]; then
    echo "[INFO] Nenhum torrent atingiu o prazo em ${label}."
    echo "[INFO] TOP 3 mais antigos em ${label}:"
    echo "${enriched_array}" | show_top3 "${allow_flag}"
    return 0
  fi

  echo "[INFO] Encontrados ${count} candidatos em ${label}:"
  [[ "${LOG_LEVEL}" == "detailed" ]] && printf "%s\n" "${candidates}" | jq -r '.[] | "- " + .name'

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Exclusão NÃO executada."
    return 0
  else
    local hashes_pipe
    hashes_pipe=$(printf "%s\n" "${candidates}" | jq -r '.[].hash' | paste -sd'|' -)
    delete_torrents "${hashes_pipe}" "${count}" "${label}"
    return 0
  fi
}

main() {
  echo "[CRON] Executado em $(date)"
  login_qbittorrent
  NOW_EPOCH=$(date +%s)

  for category in "${!RETENTION_HOURS[@]}"; do
    process_category "${category}" "${RETENTION_HOURS[${category}]}"
  done

  [[ "${INCLUDE_NO_CATEGORY}" == "true" ]] && process_category "__NO_CATEGORY__" "${NO_CATEGORY_RETENTION_HOURS}"

  echo "[INFO] Concluído."
}

main "$@"
