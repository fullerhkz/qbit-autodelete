#!/usr/bin/env bash
set -Eeuo pipefail

# Toda a configuracao fica fora do codigo. Use --config para outro servidor.
CONFIG_FILE="${QBIT_AUTODELETE_CONFIG:-/etc/qbit-autodelete.env}"
VERSION="3.0.0"

declare -A RETENTION_HOURS=()
declare -A MIN_RATIOS=()
COOKIE_JAR=""
CLI_DRY_RUN=""
ACTION="run"

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "${level}" "$*"
}

die() {
  log "ERRO" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso: qbit-autodelete.sh [opcoes]

  -c, --config ARQUIVO  usa outro arquivo de configuracao
      --dry-run         simula esta execucao, sem excluir
      --check-config    valida a configuracao e encerra
  -h, --help            mostra esta ajuda
  -v, --version         mostra a versao
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -c|--config)
        (($# >= 2)) || die "$1 requer um arquivo"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        CLI_DRY_RUN="true"
        shift
        ;;
      --check-config)
        ACTION="check-config"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -v|--version)
        printf 'qbit-autodelete %s\n' "${VERSION}"
        exit 0
        ;;
      *) die "opcao desconhecida: $1" ;;
    esac
  done
}

load_config() {
  [[ -r "${CONFIG_FILE}" ]] || die "arquivo de configuracao nao legivel: ${CONFIG_FILE}"
  # O arquivo e administrado localmente e usa sintaxe simples de variaveis Bash.
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"

  : "${QBT_URL:?defina QBT_URL em ${CONFIG_FILE}}"
  : "${QBT_USER:?defina QBT_USER em ${CONFIG_FILE}}"
  : "${QBT_PASS:?defina QBT_PASS em ${CONFIG_FILE}}"
  : "${CATEGORY_RULES_FILE:?defina CATEGORY_RULES_FILE em ${CONFIG_FILE}}"

  QBT_URL="${QBT_URL%/}"
  DRY_RUN="${DRY_RUN:-true}"
  [[ -n "${CLI_DRY_RUN}" ]] && DRY_RUN="${CLI_DRY_RUN}"
  LOG_LEVEL="${LOG_LEVEL:-summary}"
  DELETE_FILES="${DELETE_FILES:-true}"
  ALLOW_INCOMPLETE_DELETE="${ALLOW_INCOMPLETE_DELETE:-false}"
  INCLUDE_NO_CATEGORY="${INCLUDE_NO_CATEGORY:-false}"
  NO_CATEGORY_RETENTION_HOURS="${NO_CATEGORY_RETENTION_HOURS:-168}"
  DEFAULT_MIN_RATIO="${DEFAULT_MIN_RATIO:-1.0}"
  RATIO_PROTECTION_MAX_HOURS="${RATIO_PROTECTION_MAX_HOURS:-336}"
  PROTECTED_TAGS="${PROTECTED_TAGS:-keep,never-delete}"
  SKIP_FORCE_STARTED="${SKIP_FORCE_STARTED:-true}"
  SKIP_ACTIVE_TRANSFERS="${SKIP_ACTIVE_TRANSFERS:-true}"
  MIN_INACTIVE_HOURS="${MIN_INACTIVE_HOURS:-6}"

  NORMAL_CLEANUP_ENABLED="${NORMAL_CLEANUP_ENABLED:-true}"
  NORMAL_MIN_SCORE="${NORMAL_MIN_SCORE:-70}"
  AGGRESSIVE_MIN_SCORE="${AGGRESSIVE_MIN_SCORE:-35}"
  AGGRESSIVE_WITHOUT_HISTORY="${AGGRESSIVE_WITHOUT_HISTORY:-false}"
  MAX_DELETE_PER_RUN="${MAX_DELETE_PER_RUN:-15}"
  MAX_RECLAIM_GB_PER_RUN="${MAX_RECLAIM_GB_PER_RUN:-400}"

  SCORE_LOW_UPLOAD_WEIGHT="${SCORE_LOW_UPLOAD_WEIGHT:-45}"
  SCORE_SIZE_WEIGHT="${SCORE_SIZE_WEIGHT:-20}"
  SCORE_INACTIVITY_WEIGHT="${SCORE_INACTIVITY_WEIGHT:-20}"
  SCORE_COMPETITION_WEIGHT="${SCORE_COMPETITION_WEIGHT:-15}"
  UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY="${UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY:-100}"
  SIZE_FULL_SCORE_GB="${SIZE_FULL_SCORE_GB:-100}"
  INACTIVITY_FULL_SCORE_HOURS="${INACTIVITY_FULL_SCORE_HOURS:-168}"

  STATE_FILE="${STATE_FILE:-/var/lib/qbit-autodelete/state.json}"
  HISTORY_MIN_SAMPLES="${HISTORY_MIN_SAMPLES:-6}"
  HISTORY_MIN_HOURS="${HISTORY_MIN_HOURS:-6}"
  HISTORY_MIN_SAMPLE_SECONDS="${HISTORY_MIN_SAMPLE_SECONDS:-1800}"
  UPLOAD_EWMA_ALPHA_PERCENT="${UPLOAD_EWMA_ALPHA_PERCENT:-35}"

  DISK_PRESSURE_ENABLED="${DISK_PRESSURE_ENABLED:-false}"
  STORAGE_PATH="${STORAGE_PATH:-}"
  LOW_WATERMARK_GB="${LOW_WATERMARK_GB:-0}"
  HIGH_WATERMARK_GB="${HIGH_WATERMARK_GB:-0}"
  LOW_WATERMARK_PERCENT="${LOW_WATERMARK_PERCENT:-0}"
  HIGH_WATERMARK_PERCENT="${HIGH_WATERMARK_PERCENT:-0}"

  CURL_INSECURE="${CURL_INSECURE:-false}"
  CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
  REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"
  LOGIN_RETRIES="${LOGIN_RETRIES:-5}"
  LOCK_FILE="${LOCK_FILE:-/tmp/qbit-autodelete-${UID}.lock}"
}

validate_bool() {
  local name="$1" value="${!1}"
  [[ "${value}" == "true" || "${value}" == "false" ]] ||
    die "${name} deve ser true ou false (recebido: ${value})"
}

validate_uint() {
  local name="$1" value="${!1}"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} deve ser um inteiro >= 0 (recebido: ${value})"
}

validate_decimal() {
  local name="$1" value="${!1}"
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "${name} deve ser um numero >= 0 (recebido: ${value})"
}

validate_range_0_100() {
  local name="$1" value="${!1}"
  validate_uint "${name}"
  ((value <= 100)) || die "${name} deve estar entre 0 e 100"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

load_category_rules() {
  [[ -r "${CATEGORY_RULES_FILE}" ]] || die "arquivo de categorias nao legivel: ${CATEGORY_RULES_FILE}"

  local raw category hours min_ratio extra line_number=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    ((line_number += 1))
    raw="${raw%$'\r'}"
    [[ "${raw}" =~ ^[[:space:]]*(#|$) ]] && continue

    IFS='|' read -r category hours min_ratio extra <<<"${raw}"
    category="$(trim "${category:-}")"
    hours="$(trim "${hours:-}")"
    min_ratio="$(trim "${min_ratio:-${DEFAULT_MIN_RATIO}}")"
    [[ -n "${min_ratio}" ]] || min_ratio="${DEFAULT_MIN_RATIO}"
    [[ -n "${category}" && -z "${extra:-}" && "${hours}" =~ ^[0-9]+$ &&
      "${min_ratio}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
      die "regra invalida em ${CATEGORY_RULES_FILE}:${line_number}; use Categoria|horas|min_ratio"
    [[ -z "${RETENTION_HOURS[${category}]+x}" ]] ||
      die "categoria duplicada em ${CATEGORY_RULES_FILE}:${line_number}: ${category}"
    RETENTION_HOURS["${category}"]="${hours}"
    MIN_RATIOS["${category}"]="${min_ratio}"
  done < "${CATEGORY_RULES_FILE}"

  ((${#RETENTION_HOURS[@]} > 0)) || die "nenhuma categoria configurada em ${CATEGORY_RULES_FILE}"
  if [[ "${INCLUDE_NO_CATEGORY}" == "true" ]]; then
    RETENTION_HOURS[""]="${NO_CATEGORY_RETENTION_HOURS}"
    MIN_RATIOS[""]="${DEFAULT_MIN_RATIO}"
  fi
}

validate_config() {
  local cmd
  for cmd in curl jq date df awk flock mktemp dirname mkdir mv chmod rm; do
    command -v "${cmd}" >/dev/null 2>&1 || die "dependencia ausente: ${cmd}"
  done

  [[ "${QBT_URL}" =~ ^https?://[^/]+$ ]] ||
    die "QBT_URL deve conter somente esquema, host e porta (ex.: http://QBT_HOST:QBT_PORT)"
  [[ "${LOG_LEVEL}" == "summary" || "${LOG_LEVEL}" == "detailed" ]] ||
    die "LOG_LEVEL deve ser summary ou detailed"

  local bool_name
  for bool_name in DRY_RUN DELETE_FILES ALLOW_INCOMPLETE_DELETE INCLUDE_NO_CATEGORY \
    SKIP_FORCE_STARTED SKIP_ACTIVE_TRANSFERS NORMAL_CLEANUP_ENABLED AGGRESSIVE_WITHOUT_HISTORY \
    DISK_PRESSURE_ENABLED CURL_INSECURE; do
    validate_bool "${bool_name}"
  done

  local uint_name
  for uint_name in NO_CATEGORY_RETENTION_HOURS RATIO_PROTECTION_MAX_HOURS MIN_INACTIVE_HOURS MAX_DELETE_PER_RUN \
    MAX_RECLAIM_GB_PER_RUN SCORE_LOW_UPLOAD_WEIGHT SCORE_SIZE_WEIGHT SCORE_INACTIVITY_WEIGHT \
    SCORE_COMPETITION_WEIGHT SIZE_FULL_SCORE_GB INACTIVITY_FULL_SCORE_HOURS HISTORY_MIN_SAMPLES \
    HISTORY_MIN_HOURS HISTORY_MIN_SAMPLE_SECONDS LOW_WATERMARK_GB \
    HIGH_WATERMARK_GB CONNECT_TIMEOUT REQUEST_TIMEOUT LOGIN_RETRIES; do
    validate_uint "${uint_name}"
  done
  validate_range_0_100 NORMAL_MIN_SCORE
  validate_range_0_100 AGGRESSIVE_MIN_SCORE
  validate_range_0_100 LOW_WATERMARK_PERCENT
  validate_range_0_100 HIGH_WATERMARK_PERCENT
  validate_range_0_100 UPLOAD_EWMA_ALPHA_PERCENT
  validate_decimal DEFAULT_MIN_RATIO
  validate_decimal UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY

  ((MAX_DELETE_PER_RUN > 0)) || die "MAX_DELETE_PER_RUN deve ser maior que zero"
  ((SIZE_FULL_SCORE_GB > 0 && INACTIVITY_FULL_SCORE_HOURS > 0)) ||
    die "os valores *_FULL_SCORE devem ser maiores que zero"
  awk -v value="${UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY}" 'BEGIN {exit !(value > 0)}' ||
    die "UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY deve ser maior que zero"
  ((UPLOAD_EWMA_ALPHA_PERCENT > 0)) || die "UPLOAD_EWMA_ALPHA_PERCENT deve ser maior que zero"
  ((SCORE_LOW_UPLOAD_WEIGHT + SCORE_SIZE_WEIGHT + SCORE_INACTIVITY_WEIGHT + SCORE_COMPETITION_WEIGHT == 100)) ||
    die "os quatro pesos SCORE_*_WEIGHT devem somar 100"
  [[ -n "${STATE_FILE}" ]] || die "STATE_FILE nao pode ser vazio"

  if [[ "${DISK_PRESSURE_ENABLED}" == "true" ]]; then
    [[ -d "${STORAGE_PATH}" ]] || die "STORAGE_PATH nao existe ou nao e um diretorio: ${STORAGE_PATH:-<vazio>}"
    ((LOW_WATERMARK_GB > 0 || LOW_WATERMARK_PERCENT > 0)) ||
      die "configure pelo menos um LOW_WATERMARK para o modo de pressao"
    ((HIGH_WATERMARK_GB >= LOW_WATERMARK_GB)) ||
      die "HIGH_WATERMARK_GB nao pode ser menor que LOW_WATERMARK_GB"
    ((HIGH_WATERMARK_PERCENT >= LOW_WATERMARK_PERCENT)) ||
      die "HIGH_WATERMARK_PERCENT nao pode ser menor que LOW_WATERMARK_PERCENT"
  fi

  load_category_rules
}

rules_as_json() {
  local json='{}' category
  for category in "${!RETENTION_HOURS[@]}"; do
    json="$(jq -cn --argjson current "${json}" --arg category "${category}" \
      --argjson hours "${RETENTION_HOURS[${category}]}" --argjson min_ratio "${MIN_RATIOS[${category}]}" \
      '$current + {($category): {retention_hours: $hours, min_ratio: $min_ratio}}')"
  done
  printf '%s' "${json}"
}

setup_runtime() {
  umask 077
  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "outra execucao ainda esta ativa (${LOCK_FILE})"

  COOKIE_JAR="$(mktemp -t qbit-autodelete-cookie.XXXXXX)"
  trap cleanup EXIT INT TERM

  CURL_COMMON=(
    --silent --show-error --fail-with-body
    --connect-timeout "${CONNECT_TIMEOUT}"
    --max-time "${REQUEST_TIMEOUT}"
    --retry 2 --retry-delay 1 --retry-all-errors
    -H "Referer: ${QBT_URL}/"
    -H "Origin: ${QBT_URL}"
  )
  if [[ "${CURL_INSECURE}" == "true" ]]; then
    CURL_COMMON+=(--insecure)
  fi
}

cleanup() {
  if [[ -n "${COOKIE_JAR}" ]]; then
    curl --silent --max-time 3 -b "${COOKIE_JAR}" "${CURL_COMMON[@]:-}" \
      -X POST "${QBT_URL}/api/v2/auth/logout" >/dev/null 2>&1 || true
    rm -f "${COOKIE_JAR}" 2>/dev/null || true
  fi
}

login_qbittorrent() {
  local attempt response user_encoded pass_encoded
  user_encoded="$(jq -rn --arg value "${QBT_USER}" '$value|@uri')"
  pass_encoded="$(jq -rn --arg value "${QBT_PASS}" '$value|@uri')"

  for ((attempt = 1; attempt <= LOGIN_RETRIES; attempt++)); do
    response="$({
      printf 'username=%s&password=%s' "${user_encoded}" "${pass_encoded}"
    } | curl "${CURL_COMMON[@]}" -c "${COOKIE_JAR}" -X POST \
      -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
      "${QBT_URL}/api/v2/auth/login" 2>/dev/null || true)"
    if [[ "${response}" == "Ok." ]]; then
      log "INFO" "sessao autenticada no qBittorrent"
      return 0
    fi
    ((attempt < LOGIN_RETRIES)) && sleep 2
  done
  die "nao foi possivel autenticar no qBittorrent apos ${LOGIN_RETRIES} tentativas"
}

fetch_all_torrents() {
  local response
  response="$(curl "${CURL_COMMON[@]}" -b "${COOKIE_JAR}" \
    "${QBT_URL}/api/v2/torrents/info")" || die "falha ao consultar torrents"
  jq -e 'type == "array"' >/dev/null <<<"${response}" || die "a API retornou uma lista de torrents invalida"
  printf '%s' "${response}"
}

empty_state() {
  printf '{"version":1,"updated_at":0,"torrents":{}}'
}

load_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    empty_state
    return 0
  fi

  local state
  if ! state="$(jq -ce 'select(.version == 1 and (.torrents | type == "object"))' "${STATE_FILE}" 2>/dev/null)"; then
    log "AVISO" "historico invalido em ${STATE_FILE}; iniciando novo periodo de aprendizado" >&2
    empty_state
    return 0
  fi
  printf '%s' "${state}"
}

score_torrents() {
  local now_epoch="$1" rules_json="$2" state_json="$3"
  jq -c \
    --argjson now "${now_epoch}" \
    --argjson rules "${rules_json}" \
    --argjson history "${state_json}" \
    --arg protected_tags "${PROTECTED_TAGS}" \
    --argjson allow_incomplete "${ALLOW_INCOMPLETE_DELETE}" \
    --argjson skip_forced "${SKIP_FORCE_STARTED}" \
    --argjson skip_active "${SKIP_ACTIVE_TRANSFERS}" \
    --argjson min_inactive "${MIN_INACTIVE_HOURS}" \
    --argjson ratio_protection_max_hours "${RATIO_PROTECTION_MAX_HOURS}" \
    --argjson history_min_samples "${HISTORY_MIN_SAMPLES}" \
    --argjson history_min_hours "${HISTORY_MIN_HOURS}" \
    --argjson min_sample_seconds "${HISTORY_MIN_SAMPLE_SECONDS}" \
    --argjson ewma_alpha_percent "${UPLOAD_EWMA_ALPHA_PERCENT}" \
    --argjson low_upload_weight "${SCORE_LOW_UPLOAD_WEIGHT}" \
    --argjson size_weight "${SCORE_SIZE_WEIGHT}" \
    --argjson inactivity_weight "${SCORE_INACTIVITY_WEIGHT}" \
    --argjson competition_weight "${SCORE_COMPETITION_WEIGHT}" \
    --argjson efficiency_full "${UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY}" \
    --argjson size_full "${SIZE_FULL_SCORE_GB}" \
    --argjson inactivity_full "${INACTIVITY_FULL_SCORE_HOURS}" '
      def cap01: [[., 0] | max, 1] | min;
      def capped_ratio($value; $full): (($value / $full) | cap01);
      def clean_tags:
        ((.tags // "") | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)));
      ($ewma_alpha_percent / 100) as $alpha
      |
      ($protected_tags | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))) as $protected
      | map(
          (.category // "") as $category
          | select($rules[$category] != null)
          | $rules[$category] as $rule
          | ($history.torrents[.hash] // null) as $previous
          | ([($now - ($previous.sampled_at // $now)), 0] | max) as $sample_elapsed
          | ([.uploaded // 0, 0] | max) as $uploaded_now
          | ($previous != null and $uploaded_now < ($previous.uploaded // 0)) as $counter_reset
          | ($previous != null and ($counter_reset | not) and $sample_elapsed > 0
             and $sample_elapsed >= $min_sample_seconds) as $new_sample
          | (if $new_sample then
               (($uploaded_now - ($previous.uploaded // 0)) * 3600 / $sample_elapsed)
             else 0 end) as $instant_upload_bph
          | (if $new_sample then
               if (($previous.samples // 0) > 0) then
                 ($alpha * $instant_upload_bph) + ((1 - $alpha) * ($previous.ewma_upload_bph // 0))
               else $instant_upload_bph end
             elif $counter_reset or $previous == null then 0
             else ($previous.ewma_upload_bph // 0) end) as $ewma_upload_bph
          | (if $new_sample then (($previous.samples // 0) + 1)
             elif $counter_reset or $previous == null then 0
             else ($previous.samples // 0) end) as $samples
          | (if $new_sample then (($previous.observed_seconds // 0) + $sample_elapsed)
             elif $counter_reset or $previous == null then 0
             else ($previous.observed_seconds // 0) end) as $observed_seconds
          | (if $new_sample or $counter_reset or $previous == null then $uploaded_now
             else ($previous.uploaded // $uploaded_now) end) as $next_uploaded
          | (if $new_sample or $counter_reset or $previous == null then $now
             else ($previous.sampled_at // $now) end) as $next_sampled_at
          | ((.progress // 0) >= 0.9999 and (.amount_left // 0) == 0) as $complete
          | (if (.completion_on // 0) > 0 then .completion_on
             elif (.added_on // 0) > 0 then .added_on
             else $now end) as $completed_at
          | ([.last_activity // 0, $completed_at, .added_on // 0] | max) as $activity_at
          | ([($now - $completed_at), 0] | max / 3600) as $age_hours
          | ([($now - $activity_at), 0] | max / 3600) as $inactive_hours
          | ([.size // 0, .total_size // 0, 0] | max) as $size_bytes
          | ($size_bytes / 1073741824) as $size_gb
          | ([.num_complete // -1, .num_seeds // -1, 0] | max) as $seeds
          | ([.num_incomplete // -1, .num_leechs // -1, 0] | max) as $leechers
          | (if $size_gb > 0 then ($ewma_upload_bph * 24 / ($size_gb * 1048576)) else 0 end) as $efficiency
          | (if $leechers <= 0 then 1
             elif $seeds <= 0 then 0
             else ($seeds / ($seeds + $leechers)) end) as $competition
          | (($samples >= $history_min_samples) and
             ($observed_seconds >= ($history_min_hours * 3600))) as $history_ready
          | ([.ratio // 0, 0] | max) as $current_ratio
          | (($rule.min_ratio > 0) and ($current_ratio < $rule.min_ratio) and
             (($ratio_protection_max_hours == 0) or ($age_hours < $ratio_protection_max_hours))) as $ratio_protected
          | (clean_tags) as $tags
          | (any($tags[]; . as $tag | $protected | index($tag))) as $protected_by_tag
          | (((.upspeed // 0) > 0) or ((.dlspeed // 0) > 0) or
             ((.state // "") | test("^(checking|moving|allocating)"))) as $active
          | (((1 - capped_ratio($efficiency; $efficiency_full)) * $low_upload_weight)
             + (capped_ratio($size_gb; $size_full) * $size_weight)
             + (capped_ratio($inactive_hours; $inactivity_full) * $inactivity_weight)
             + ($competition * $competition_weight)) as $score
          | . + {
              is_complete: $complete,
              retention_hours: $rule.retention_hours,
              min_ratio: $rule.min_ratio,
              ratio_protected: $ratio_protected,
              age_hours: ($age_hours | floor),
              inactive_hours: ($inactive_hours | floor),
              size_bytes: $size_bytes,
              size_gb: (($size_gb * 100) | round / 100),
              swarm_seeds: $seeds,
              swarm_leechers: $leechers,
              recent_upload_bph: ($ewma_upload_bph | floor),
              upload_efficiency_mib_per_gib_day: (($efficiency * 100) | round / 100),
              history_samples: $samples,
              history_observed_hours: (($observed_seconds / 3600 * 100) | round / 100),
              history_ready: $history_ready,
              cleanup_score: (($score * 100) | round / 100),
              protected_by_tag: $protected_by_tag,
              is_active_transfer: $active,
              history_next: {
                uploaded: $next_uploaded,
                sampled_at: $next_sampled_at,
                ewma_upload_bph: $ewma_upload_bph,
                samples: $samples,
                observed_seconds: $observed_seconds
              },
              eligible: (
                ($allow_incomplete or $complete)
                and ($age_hours >= $rule.retention_hours)
                and ($inactive_hours >= $min_inactive)
                and ($ratio_protected | not)
                and ($protected_by_tag | not)
                and (($skip_forced and (.force_start // false)) | not)
                and (($skip_active and $active) | not)
              )
            }
        )
    '
}

save_state() {
  local scored_json="$1" now_epoch="$2" state_dir state_tmp
  state_dir="$(dirname "${STATE_FILE}")"
  mkdir -p "${state_dir}" || die "nao foi possivel criar o diretorio de historico: ${state_dir}"
  state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || die "nao foi possivel criar historico temporario"

  if ! jq -c --argjson now "${now_epoch}" '
    reduce .[] as $torrent
      ({version: 1, updated_at: $now, torrents: {}};
       .torrents[$torrent.hash] = $torrent.history_next)
  ' <<<"${scored_json}" >"${state_tmp}"; then
    rm -f "${state_tmp}"
    die "falha ao montar o historico de upload"
  fi
  chmod 600 "${state_tmp}"
  mv -f "${state_tmp}" "${STATE_FILE}" || die "nao foi possivel salvar o historico em ${STATE_FILE}"
}

filesystem_status() {
  local values total_kb available_kb
  values="$(df -PkP "${STORAGE_PATH}" | awk 'NR == 2 {print $2, $4}')"
  read -r total_kb available_kb <<<"${values}"
  [[ "${total_kb:-}" =~ ^[0-9]+$ && "${available_kb:-}" =~ ^[0-9]+$ ]] ||
    die "nao foi possivel medir o filesystem de ${STORAGE_PATH}"
  printf '%s %s\n' "$((total_kb * 1024))" "$((available_kb * 1024))"
}

max_number() {
  if (($1 > $2)); then printf '%s' "$1"; else printf '%s' "$2"; fi
}

choose_mode() {
  RUN_MODE="normal"
  BYTES_NEEDED=0
  DISK_TOTAL_BYTES=0
  DISK_FREE_BYTES=0
  LOW_WATERMARK_BYTES=0
  HIGH_WATERMARK_BYTES=0

  [[ "${DISK_PRESSURE_ENABLED}" == "true" ]] || return 0

  read -r DISK_TOTAL_BYTES DISK_FREE_BYTES < <(filesystem_status)
  local low_gb_bytes=$((LOW_WATERMARK_GB * 1024 * 1024 * 1024))
  local high_gb_bytes=$((HIGH_WATERMARK_GB * 1024 * 1024 * 1024))
  local low_percent_bytes=$((DISK_TOTAL_BYTES * LOW_WATERMARK_PERCENT / 100))
  local high_percent_bytes=$((DISK_TOTAL_BYTES * HIGH_WATERMARK_PERCENT / 100))
  LOW_WATERMARK_BYTES="$(max_number "${low_gb_bytes}" "${low_percent_bytes}")"
  HIGH_WATERMARK_BYTES="$(max_number "${high_gb_bytes}" "${high_percent_bytes}")"

  if ((DISK_FREE_BYTES < LOW_WATERMARK_BYTES)); then
    RUN_MODE="aggressive"
    BYTES_NEEDED=$((HIGH_WATERMARK_BYTES - DISK_FREE_BYTES))
    if ((BYTES_NEEDED < 0)); then
      BYTES_NEEDED=0
    fi
  fi
}

select_candidates() {
  local scored_json="$1"
  local threshold bytes_limit
  if [[ "${RUN_MODE}" == "aggressive" ]]; then
    threshold="${AGGRESSIVE_MIN_SCORE}"
    bytes_limit="${BYTES_NEEDED}"
  else
    threshold="${NORMAL_MIN_SCORE}"
    bytes_limit=0
    [[ "${NORMAL_CLEANUP_ENABLED}" == "true" ]] || { printf '[]'; return 0; }
  fi

  local max_reclaim_bytes=$((MAX_RECLAIM_GB_PER_RUN * 1024 * 1024 * 1024))
  jq -c \
    --argjson threshold "${threshold}" \
    --arg mode "${RUN_MODE}" \
    --argjson aggressive_without_history "${AGGRESSIVE_WITHOUT_HISTORY}" \
    --argjson max_count "${MAX_DELETE_PER_RUN}" \
    --argjson wanted_bytes "${bytes_limit}" \
    --argjson max_reclaim_bytes "${max_reclaim_bytes}" '
      [ .[]
        | select(.eligible)
        | select(.history_ready or ($mode == "aggressive" and $aggressive_without_history))
        | select(.cleanup_score >= $threshold)
      ]
      | sort_by(.cleanup_score, .size_bytes) | reverse
      | reduce .[] as $torrent
          ({items: [], bytes: 0};
            if ((.items | length) >= $max_count)
               or ($wanted_bytes > 0 and .bytes >= $wanted_bytes)
               or ($max_reclaim_bytes > 0 and .bytes >= $max_reclaim_bytes)
            then .
            else .items += [$torrent] | .bytes += $torrent.size_bytes
            end)
      | .items
    ' <<<"${scored_json}"
}

human_gib() {
  awk -v bytes="$1" 'BEGIN {printf "%.1f GiB", bytes / 1073741824}'
}

show_policy_summary() {
  local scored_json="$1" selected_json="$2" total="$3"
  local managed eligible history_ready selected planned
  managed="$(jq 'length' <<<"${scored_json}")"
  eligible="$(jq '[.[] | select(.eligible)] | length' <<<"${scored_json}")"
  history_ready="$(jq '[.[] | select(.history_ready)] | length' <<<"${scored_json}")"
  selected="$(jq 'length' <<<"${selected_json}")"
  planned="$(jq '[.[].size_bytes] | add // 0' <<<"${selected_json}")"

  log "INFO" "modo=${RUN_MODE}; gerenciados=${managed}/${total}; historico_pronto=${history_ready}; elegiveis=${eligible}; selecionados=${selected}; recuperacao_estimada=$(human_gib "${planned}")"
  if [[ "${DISK_PRESSURE_ENABLED}" == "true" ]]; then
    log "INFO" "disco livre=$(human_gib "${DISK_FREE_BYTES}"); gatilho=$(human_gib "${LOW_WATERMARK_BYTES}"); alvo=$(human_gib "${HIGH_WATERMARK_BYTES}")"
  fi

  if ((selected > 0)); then
    local list_limit=5
    [[ "${LOG_LEVEL}" == "detailed" ]] && list_limit="${selected}"
    jq -r --argjson limit "${list_limit}" '.[:$limit][] |
      "  score=\(.cleanup_score) eficiencia=\(.upload_efficiency_mib_per_gib_day)MiB/GiB/dia size=\(.size_gb)GiB inativo=\(.inactive_hours)h swarm=\(.swarm_seeds)S/\(.swarm_leechers)L ratio=\(.ratio) categoria=\(.category) :: \(.name)"' \
      <<<"${selected_json}"
    if ((selected > list_limit)); then
      log "INFO" "$((selected - list_limit)) item(ns) adicional(is) omitido(s); use LOG_LEVEL=detailed"
    fi
  elif ((eligible > 0 && history_ready == 0)) && [[ "${RUN_MODE}" == "normal" ]]; then
    log "INFO" "periodo de aprendizado ativo; a limpeza normal comeca apos ${HISTORY_MIN_SAMPLES} amostras e ${HISTORY_MIN_HOURS}h observadas"
  elif ((eligible > 0)); then
    log "INFO" "nenhum elegivel atingiu a pontuacao minima do modo ${RUN_MODE}"
    jq -r '[.[] | select(.eligible)] | sort_by(.cleanup_score) | reverse | .[:3][] |
      "  proximo: score=\(.cleanup_score) eficiencia=\(.upload_efficiency_mib_per_gib_day)MiB/GiB/dia size=\(.size_gb)GiB :: \(.name)"' <<<"${scored_json}"
  fi
}

delete_torrents() {
  local selected_json="$1" count hashes response
  count="$(jq 'length' <<<"${selected_json}")"
  ((count > 0)) || return 0

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN" "nenhuma exclusao executada"
    return 0
  fi

  hashes="$(jq -r '.[].hash' <<<"${selected_json}" | paste -sd'|' -)"
  response="$(curl "${CURL_COMMON[@]}" -b "${COOKIE_JAR}" -X POST \
    --data-urlencode "hashes=${hashes}" --data "deleteFiles=${DELETE_FILES}" \
    "${QBT_URL}/api/v2/torrents/delete")" || die "a API recusou a exclusao"
  [[ -z "${response}" ]] || log "AVISO" "resposta inesperada da API ao excluir: ${response}"
  log "OK" "${count} torrent(s) removido(s); deleteFiles=${DELETE_FILES}"
}

main() {
  parse_args "$@"
  load_config
  validate_config

  if [[ "${ACTION}" == "check-config" ]]; then
    log "OK" "configuracao valida; ${#RETENTION_HOURS[@]} regra(s) de categoria carregada(s)"
    return 0
  fi

  setup_runtime
  log "INFO" "qbit-autodelete ${VERSION} iniciado; dry_run=${DRY_RUN}"
  [[ "${ALLOW_INCOMPLETE_DELETE}" == "true" ]] && log "AVISO" "exclusao de torrents incompletos esta habilitada"
  login_qbittorrent

  local raw_json rules_json state_json scored_json selected_json now_epoch
  raw_json="$(fetch_all_torrents)"
  rules_json="$(rules_as_json)"
  state_json="$(load_state)"
  now_epoch="$(date +%s)"
  scored_json="$(score_torrents "${now_epoch}" "${rules_json}" "${state_json}" <<<"${raw_json}")"

  choose_mode
  selected_json="$(select_candidates "${scored_json}")"
  show_policy_summary "${scored_json}" "${selected_json}" "$(jq 'length' <<<"${raw_json}")"
  save_state "${scored_json}" "${now_epoch}"
  delete_torrents "${selected_json}"
  log "INFO" "execucao concluida"
}

if [[ "${QBIT_AUTODELETE_LIBRARY:-false}" != "true" ]]; then
  main "$@"
fi
