#!/usr/bin/env bash
set -Eeuo pipefail

# Toda a configuracao fica fora do codigo. Use --config para outro servidor.
CONFIG_FILE="${QBIT_AUTODELETE_CONFIG:-/etc/qbit-autodelete.env}"
VERSION="3.7.1"

declare -A RETENTION_HOURS=()
declare -A EMERGENCY_RETENTION_HOURS=()
declare -A MIN_RATIOS=()
declare -A FOLLOWERS=()
FOLLOWERS_JSON="[]"
YIELD_OVERRIDE="false"
COOKIE_JAR=""
CLI_DRY_RUN=""
ACTION="run"
RUN_ID=""

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "${level}" "$*"
}

die() {
  if [[ -n "${RUN_ID}" ]] && command -v jq >/dev/null 2>&1; then
    emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
      --arg message "$*" '{event:"run_failed", run_id:$run_id, timestamp:$timestamp, message:$message}')" || true
  fi
  log "ERRO" "$*" >&2
  exit 1
}

emit_event() {
  log "EVENT" "QBIT_EVENT $1"
}

usage() {
  cat <<'EOF'
Uso: qbit-autodelete.sh [opcoes]

  -c, --config ARQUIVO  usa outro arquivo de configuracao
      --dry-run         simula esta execucao, sem excluir
      --check-config    valida a configuracao e encerra
      --pressure-gate   executa so se o disco estiver abaixo do nivel baixo
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
      --pressure-gate)
        ACTION="pressure-gate"
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
  EMERGENCY_RATIO_PROTECTION_MAX_HOURS="${EMERGENCY_RATIO_PROTECTION_MAX_HOURS:-${RATIO_PROTECTION_MAX_HOURS}}"
  PROTECTED_TAGS="${PROTECTED_TAGS:-keep,never-delete}"
  FOLLOWER_CATEGORIES="${FOLLOWER_CATEGORIES:-}"
  FOLLOWER_DOWNLOAD_PROTECT_HOURS="${FOLLOWER_DOWNLOAD_PROTECT_HOURS:-168}"
  FOLLOWER_ORPHAN_HOURS="${FOLLOWER_ORPHAN_HOURS:-0}"
  PROTECT_EFFICIENCY_MIB_PER_GIB_DAY="${PROTECT_EFFICIENCY_MIB_PER_GIB_DAY:-0}"
  YIELD_OVERRIDE_PERCENT_OF_CRITICAL="${YIELD_OVERRIDE_PERCENT_OF_CRITICAL:-50}"
  REVERIFY_BEFORE_DELETE="${REVERIFY_BEFORE_DELETE:-true}"
  PRESSURE_GATE_MIN_INTERVAL_SECONDS="${PRESSURE_GATE_MIN_INTERVAL_SECONDS:-300}"
  SKIP_FORCE_STARTED="${SKIP_FORCE_STARTED:-true}"
  SKIP_ACTIVE_TRANSFERS="${SKIP_ACTIVE_TRANSFERS:-true}"
  MIN_INACTIVE_HOURS="${MIN_INACTIVE_HOURS:-6}"
  AGGRESSIVE_MIN_INACTIVE_HOURS="${AGGRESSIVE_MIN_INACTIVE_HOURS:-2}"
  EMERGENCY_MIN_INACTIVE_HOURS="${EMERGENCY_MIN_INACTIVE_HOURS:-0}"

  NORMAL_CLEANUP_ENABLED="${NORMAL_CLEANUP_ENABLED:-true}"
  NORMAL_MIN_SCORE="${NORMAL_MIN_SCORE:-65}"
  AGGRESSIVE_MIN_SCORE="${AGGRESSIVE_MIN_SCORE:-30}"
  AGGRESSIVE_WITHOUT_HISTORY="${AGGRESSIVE_WITHOUT_HISTORY:-false}"
  MAX_DELETE_PER_RUN="${MAX_DELETE_PER_RUN:-20}"
  MAX_RECLAIM_GB_PER_RUN="${MAX_RECLAIM_GB_PER_RUN:-500}"
  EMERGENCY_MIN_SCORE="${EMERGENCY_MIN_SCORE:-0}"
  EMERGENCY_WITHOUT_HISTORY="${EMERGENCY_WITHOUT_HISTORY:-true}"
  EMERGENCY_MAX_DELETE_PER_RUN="${EMERGENCY_MAX_DELETE_PER_RUN:-30}"
  EMERGENCY_MAX_RECLAIM_GB_PER_RUN="${EMERGENCY_MAX_RECLAIM_GB_PER_RUN:-800}"

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
  CRITICAL_WATERMARK_GB="${CRITICAL_WATERMARK_GB:-0}"
  LOW_WATERMARK_PERCENT="${LOW_WATERMARK_PERCENT:-0}"
  HIGH_WATERMARK_PERCENT="${HIGH_WATERMARK_PERCENT:-0}"
  # Zero preserva compatibilidade com configuracoes anteriores. Instalacoes novas
  # recebem um limite critico explicito pelo arquivo de exemplo/instalador.
  CRITICAL_WATERMARK_PERCENT="${CRITICAL_WATERMARK_PERCENT:-0}"

  CURL_INSECURE="${CURL_INSECURE:-false}"
  CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
  REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"
  LOGIN_RETRIES="${LOGIN_RETRIES:-5}"
  PHYSICAL_MEASURE_TIMEOUT_SECONDS="${PHYSICAL_MEASURE_TIMEOUT_SECONDS:-300}"
  PHYSICAL_MEASURE_INTERVAL_SECONDS="${PHYSICAL_MEASURE_INTERVAL_SECONDS:-5}"
  LOCK_FILE="${LOCK_FILE:-/tmp/qbit-autodelete-${UID}.lock}"
  RUN_STAMP_FILE="${RUN_STAMP_FILE:-${STATE_FILE}.lastrun}"
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

  local raw category hours min_ratio emergency_hours extra line_number=0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    ((line_number += 1))
    raw="${raw%$'\r'}"
    [[ "${raw}" =~ ^[[:space:]]*(#|$) ]] && continue

    IFS='|' read -r category hours min_ratio emergency_hours extra <<<"${raw}"
    category="$(trim "${category:-}")"
    hours="$(trim "${hours:-}")"
    min_ratio="$(trim "${min_ratio:-${DEFAULT_MIN_RATIO}}")"
    emergency_hours="$(trim "${emergency_hours:-${hours}}")"
    [[ -n "${min_ratio}" ]] || min_ratio="${DEFAULT_MIN_RATIO}"
    [[ -n "${emergency_hours}" ]] || emergency_hours="${hours}"
    [[ -n "${category}" && -z "${extra:-}" && "${hours}" =~ ^[0-9]+$ &&
      "${emergency_hours}" =~ ^[0-9]+$ && 10#${emergency_hours} -le 10#${hours} &&
      "${min_ratio}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
      die "regra invalida em ${CATEGORY_RULES_FILE}:${line_number}; use Categoria|horas|min_ratio|horas_emergencia (horas_emergencia <= horas)"
    [[ -z "${RETENTION_HOURS[${category}]+x}" ]] ||
      die "categoria duplicada em ${CATEGORY_RULES_FILE}:${line_number}: ${category}"
    RETENTION_HOURS["${category}"]="${hours}"
    EMERGENCY_RETENTION_HOURS["${category}"]="${emergency_hours}"
    MIN_RATIOS["${category}"]="${min_ratio}"
  done < "${CATEGORY_RULES_FILE}"

  load_followers
  ((${#RETENTION_HOURS[@]} > 0)) || die "nenhuma categoria configurada em ${CATEGORY_RULES_FILE}"
  if [[ "${INCLUDE_NO_CATEGORY}" == "true" ]]; then
    RETENTION_HOURS[""]="${NO_CATEGORY_RETENTION_HOURS}"
    EMERGENCY_RETENTION_HOURS[""]="${NO_CATEGORY_RETENTION_HOURS}"
    MIN_RATIOS[""]="${DEFAULT_MIN_RATIO}"
  fi
}

load_followers() {
  FOLLOWERS=()
  local item category
  local -a items=()
  IFS=',' read -r -a items <<<"${FOLLOWER_CATEGORIES}"
  for item in "${items[@]}"; do
    category="$(trim "${item}")"
    [[ -n "${category}" ]] || continue
    FOLLOWERS["${category}"]=1
    # A categoria seguidora nao tem retencao propria: ela acompanha o torrent pai.
    unset 'RETENTION_HOURS[${category}]' 'EMERGENCY_RETENTION_HOURS[${category}]' 'MIN_RATIOS[${category}]'
  done
  if ((${#FOLLOWERS[@]} > 0)); then
    FOLLOWERS_JSON="$(printf '%s\n' "${!FOLLOWERS[@]}" | jq -Rn '[inputs]')"
  else
    FOLLOWERS_JSON="[]"
  fi
}

validate_config() {
  local cmd
  for cmd in curl jq date df awk flock mktemp dirname mkdir mv chmod rm find stat base64 sha256sum; do
    command -v "${cmd}" >/dev/null 2>&1 || die "dependencia ausente: ${cmd}"
  done

  [[ "${QBT_URL}" =~ ^https?://[^/]+$ ]] ||
    die "QBT_URL deve conter somente esquema, host e porta (ex.: http://QBT_HOST:QBT_PORT)"
  [[ "${LOG_LEVEL}" == "summary" || "${LOG_LEVEL}" == "detailed" ]] ||
    die "LOG_LEVEL deve ser summary ou detailed"

  local bool_name
  for bool_name in DRY_RUN DELETE_FILES ALLOW_INCOMPLETE_DELETE INCLUDE_NO_CATEGORY \
    SKIP_FORCE_STARTED SKIP_ACTIVE_TRANSFERS NORMAL_CLEANUP_ENABLED AGGRESSIVE_WITHOUT_HISTORY \
    EMERGENCY_WITHOUT_HISTORY REVERIFY_BEFORE_DELETE \
    DISK_PRESSURE_ENABLED CURL_INSECURE; do
    validate_bool "${bool_name}"
  done

  local uint_name
  for uint_name in NO_CATEGORY_RETENTION_HOURS RATIO_PROTECTION_MAX_HOURS \
    EMERGENCY_RATIO_PROTECTION_MAX_HOURS MIN_INACTIVE_HOURS \
    AGGRESSIVE_MIN_INACTIVE_HOURS EMERGENCY_MIN_INACTIVE_HOURS MAX_DELETE_PER_RUN \
    MAX_RECLAIM_GB_PER_RUN EMERGENCY_MAX_DELETE_PER_RUN EMERGENCY_MAX_RECLAIM_GB_PER_RUN \
    SCORE_LOW_UPLOAD_WEIGHT SCORE_SIZE_WEIGHT SCORE_INACTIVITY_WEIGHT \
    SCORE_COMPETITION_WEIGHT SIZE_FULL_SCORE_GB INACTIVITY_FULL_SCORE_HOURS HISTORY_MIN_SAMPLES \
    HISTORY_MIN_HOURS HISTORY_MIN_SAMPLE_SECONDS LOW_WATERMARK_GB HIGH_WATERMARK_GB \
    CRITICAL_WATERMARK_GB CONNECT_TIMEOUT REQUEST_TIMEOUT LOGIN_RETRIES \
    FOLLOWER_DOWNLOAD_PROTECT_HOURS FOLLOWER_ORPHAN_HOURS YIELD_OVERRIDE_PERCENT_OF_CRITICAL \
    PRESSURE_GATE_MIN_INTERVAL_SECONDS; do
    validate_uint "${uint_name}"
  done
  validate_uint PHYSICAL_MEASURE_TIMEOUT_SECONDS
  validate_uint PHYSICAL_MEASURE_INTERVAL_SECONDS
  validate_range_0_100 NORMAL_MIN_SCORE
  validate_range_0_100 AGGRESSIVE_MIN_SCORE
  validate_range_0_100 EMERGENCY_MIN_SCORE
  validate_range_0_100 LOW_WATERMARK_PERCENT
  validate_range_0_100 HIGH_WATERMARK_PERCENT
  validate_range_0_100 CRITICAL_WATERMARK_PERCENT
  validate_range_0_100 UPLOAD_EWMA_ALPHA_PERCENT
  validate_decimal DEFAULT_MIN_RATIO
  validate_decimal UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY
  validate_decimal PROTECT_EFFICIENCY_MIB_PER_GIB_DAY
  validate_range_0_100 YIELD_OVERRIDE_PERCENT_OF_CRITICAL

  ((MAX_DELETE_PER_RUN > 0)) || die "MAX_DELETE_PER_RUN deve ser maior que zero"
  ((EMERGENCY_MAX_DELETE_PER_RUN > 0)) ||
    die "EMERGENCY_MAX_DELETE_PER_RUN deve ser maior que zero"
  ((PHYSICAL_MEASURE_INTERVAL_SECONDS > 0)) ||
    die "PHYSICAL_MEASURE_INTERVAL_SECONDS deve ser maior que zero"
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
    ((CRITICAL_WATERMARK_GB <= LOW_WATERMARK_GB)) ||
      die "CRITICAL_WATERMARK_GB nao pode ser maior que LOW_WATERMARK_GB"
    ((CRITICAL_WATERMARK_PERCENT <= LOW_WATERMARK_PERCENT)) ||
      die "CRITICAL_WATERMARK_PERCENT nao pode ser maior que LOW_WATERMARK_PERCENT"
  fi

  load_category_rules
}

rules_as_json() {
  local json='{}' category
  for category in "${!RETENTION_HOURS[@]}"; do
    json="$(jq -cn --argjson current "${json}" --arg category "${category}" \
      --argjson hours "${RETENTION_HOURS[${category}]}" \
      --argjson emergency_hours "${EMERGENCY_RETENTION_HOURS[${category}]}" \
      --argjson min_ratio "${MIN_RATIOS[${category}]}" \
      '$current + {($category): {
        retention_hours: $hours,
        emergency_retention_hours: $emergency_hours,
        min_ratio: $min_ratio
      }}')"
  done
  printf '%s' "${json}"
}

setup_runtime() {
  umask 077
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "INFO" "execucao ignorada: outra limpeza ja esta em andamento"
    emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" '{event:"run_skipped", run_id:$run_id, timestamp:$timestamp, reason:"already_running"}')"
    exit 0
  fi

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
  # Credenciais seguem por ambiente do processo (nao aparecem em /proc/PID/cmdline).
  user_encoded="$(QBIT_AD_VALUE="${QBT_USER}" jq -rn 'env.QBIT_AD_VALUE|@uri')"
  pass_encoded="$(QBIT_AD_VALUE="${QBT_PASS}" jq -rn 'env.QBIT_AD_VALUE|@uri')"

  for ((attempt = 1; attempt <= LOGIN_RETRIES; attempt++)); do
    response="$({
      printf 'username=%s&password=%s' "${user_encoded}" "${pass_encoded}"
    } | curl "${CURL_COMMON[@]}" --retry 0 -c "${COOKIE_JAR}" -X POST \
      -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
      "${QBT_URL}/api/v2/auth/login" 2>/dev/null || true)"
    if [[ "${response}" == "Ok." ]]; then
      log "INFO" "sessao autenticada no qBittorrent"
      emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
        '{event:"connection", run_id:$run_id, timestamp:$timestamp, success:true}')"
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
    --arg mode "${RUN_MODE:-normal}" \
    --arg protected_tags "${PROTECTED_TAGS}" \
    --argjson followers "${FOLLOWERS_JSON}" \
    --argjson follower_download_protect_hours "${FOLLOWER_DOWNLOAD_PROTECT_HOURS}" \
    --argjson protect_efficiency "${PROTECT_EFFICIENCY_MIB_PER_GIB_DAY}" \
    --argjson yield_override "${YIELD_OVERRIDE}" \
    --argjson allow_incomplete "${ALLOW_INCOMPLETE_DELETE}" \
    --argjson skip_forced "${SKIP_FORCE_STARTED}" \
    --argjson skip_active "${SKIP_ACTIVE_TRANSFERS}" \
    --argjson normal_min_inactive "${MIN_INACTIVE_HOURS}" \
    --argjson aggressive_min_inactive "${AGGRESSIVE_MIN_INACTIVE_HOURS}" \
    --argjson emergency_min_inactive "${EMERGENCY_MIN_INACTIVE_HOURS}" \
    --argjson ratio_protection_max_hours "${RATIO_PROTECTION_MAX_HOURS}" \
    --argjson emergency_ratio_protection_max_hours "${EMERGENCY_RATIO_PROTECTION_MAX_HOURS}" \
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
      | (if $mode == "emergency" then $emergency_min_inactive
         elif $mode == "aggressive" then $aggressive_min_inactive
         else $normal_min_inactive end) as $effective_min_inactive
      | (if $mode == "emergency"
         then $emergency_ratio_protection_max_hours
         else $ratio_protection_max_hours end) as $effective_ratio_protection_max_hours
      |
      ($protected_tags | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))) as $protected
      | map(
          (.category // "") as $category
          | (($followers | index($category)) != null) as $is_follower
          | select($rules[$category] != null or $is_follower)
          | ($rules[$category] // {retention_hours: 0, emergency_retention_hours: 0, min_ratio: 0}) as $rule
          | (if $mode == "emergency"
             then ($rule.emergency_retention_hours // $rule.retention_hours)
             else $rule.retention_hours end) as $effective_retention
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
             (($effective_ratio_protection_max_hours == 0) or
              ($age_hours < $effective_ratio_protection_max_hours))) as $ratio_protected
          | (clean_tags) as $tags
          | (any($tags[]; . as $tag | $protected | index($tag))) as $protected_by_tag
          | (if $size_gb > 0 then ((.upspeed // 0) * 86400 / 1048576 / $size_gb) else 0 end) as $instant_efficiency
          | ([$efficiency, $instant_efficiency] | max) as $yield_efficiency
          | (($protect_efficiency > 0) and ($yield_efficiency >= $protect_efficiency)
             and ($yield_override | not)) as $yield_protected
          | (($follower_download_protect_hours > 0) and ((.downloaded // 0) > 0)
             and ($age_hours < $follower_download_protect_hours)) as $downloaded_protected
          | (((.upspeed // 0) > 0) or ((.dlspeed // 0) > 0) or
             ((.state // "") | test("^(checking|moving|allocating)"))) as $active
          | (($allow_incomplete | not) and ($complete | not)) as $blocked_incomplete
          | ($age_hours < $effective_retention) as $blocked_retention
          | ($inactive_hours < $effective_min_inactive) as $blocked_inactivity
          | ($ratio_protected) as $blocked_ratio
          | ($protected_by_tag) as $blocked_tag
          | ($yield_protected and ($is_follower | not)) as $blocked_yield
          | ($skip_forced and (.force_start // false)) as $blocked_forced
          | ($skip_active and $active) as $blocked_active
          | (((1 - capped_ratio($efficiency; $efficiency_full)) * $low_upload_weight)
             + (capped_ratio($size_gb; $size_full) * $size_weight)
             + (capped_ratio($inactive_hours; $inactivity_full) * $inactivity_weight)
             + ($competition * $competition_weight)) as $score
          | . + {
              is_complete: $complete,
              configured_retention_hours: $rule.retention_hours,
              emergency_retention_hours: ($rule.emergency_retention_hours // $rule.retention_hours),
              retention_hours: $effective_retention,
              min_inactive_hours: $effective_min_inactive,
              min_ratio: $rule.min_ratio,
              ratio_protection_max_hours: $effective_ratio_protection_max_hours,
              ratio_protected: $ratio_protected,
              age_hours: ($age_hours | floor),
              inactive_hours: ($inactive_hours | floor),
              size_bytes: $size_bytes,
              size_gb: (($size_gb * 100) | round / 100),
              swarm_seeds: $seeds,
              swarm_leechers: $leechers,
              recent_upload_bph: ($ewma_upload_bph | floor),
              upload_efficiency_mib_per_gib_day: (($efficiency * 100) | round / 100),
              yield_mib_per_gib_day: (($yield_efficiency * 100) | round / 100),
              is_follower: $is_follower,
              follower_veto: ($protected_by_tag or $downloaded_protected),
              downloaded_protected: $downloaded_protected,
              history_samples: $samples,
              history_observed_hours: (($observed_seconds / 3600 * 100) | round / 100),
              history_ready: $history_ready,
              cleanup_score: (($score * 100) | round / 100),
              protected_by_tag: $protected_by_tag,
              is_active_transfer: $active,
              blockers: {
                incomplete: $blocked_incomplete,
                retention: $blocked_retention,
                inactivity: $blocked_inactivity,
                ratio: $blocked_ratio,
                protected_tag: $blocked_tag,
                yield: $blocked_yield,
                forced: $blocked_forced,
                active_transfer: $blocked_active
              },
              history_next: {
                uploaded: $next_uploaded,
                sampled_at: $next_sampled_at,
                ewma_upload_bph: $ewma_upload_bph,
                samples: $samples,
                observed_seconds: $observed_seconds
              },
              eligible: (
                ($is_follower | not)
                and ($blocked_incomplete | not)
                and ($blocked_retention | not)
                and ($blocked_inactivity | not)
                and ($blocked_ratio | not)
                and ($blocked_tag | not)
                and ($blocked_yield | not)
                and ($blocked_forced | not)
                and ($blocked_active | not)
              )
            }
        )
    '
}

save_state() {
  local scored_json="$1" now_epoch="$2" state_dir state_tmp
  state_dir="$(dirname "${STATE_FILE}")"
  if ! mkdir -p "${state_dir}"; then
    log "AVISO" "nao foi possivel criar o diretorio de historico: ${state_dir}"
    return 1
  fi
  if ! state_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"; then
    log "AVISO" "nao foi possivel criar o historico temporario; a limpeza continuara"
    return 1
  fi

  if ! jq -c --argjson now "${now_epoch}" '
    reduce .[] as $torrent
      ({version: 1, updated_at: $now, torrents: {}};
       .torrents[$torrent.hash] = $torrent.history_next)
  ' <<<"${scored_json}" >"${state_tmp}"; then
    rm -f "${state_tmp}"
    log "AVISO" "falha ao montar o historico de upload; a limpeza continuara"
    return 1
  fi
  if ! chmod 600 "${state_tmp}" || ! mv -f "${state_tmp}" "${STATE_FILE}"; then
    rm -f "${state_tmp}"
    log "AVISO" "nao foi possivel salvar o historico em ${STATE_FILE}; a limpeza continuara"
    return 1
  fi
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
  CRITICAL_WATERMARK_BYTES=0
  YIELD_OVERRIDE="false"

  [[ "${DISK_PRESSURE_ENABLED}" == "true" ]] || return 0

  read -r DISK_TOTAL_BYTES DISK_FREE_BYTES < <(filesystem_status)
  local low_gb_bytes=$((LOW_WATERMARK_GB * 1024 * 1024 * 1024))
  local high_gb_bytes=$((HIGH_WATERMARK_GB * 1024 * 1024 * 1024))
  local critical_gb_bytes=$((CRITICAL_WATERMARK_GB * 1024 * 1024 * 1024))
  local low_percent_bytes=$((DISK_TOTAL_BYTES * LOW_WATERMARK_PERCENT / 100))
  local high_percent_bytes=$((DISK_TOTAL_BYTES * HIGH_WATERMARK_PERCENT / 100))
  local critical_percent_bytes=$((DISK_TOTAL_BYTES * CRITICAL_WATERMARK_PERCENT / 100))
  LOW_WATERMARK_BYTES="$(max_number "${low_gb_bytes}" "${low_percent_bytes}")"
  HIGH_WATERMARK_BYTES="$(max_number "${high_gb_bytes}" "${high_percent_bytes}")"
  CRITICAL_WATERMARK_BYTES="$(max_number "${critical_gb_bytes}" "${critical_percent_bytes}")"

  if ((CRITICAL_WATERMARK_BYTES > 0 && DISK_FREE_BYTES < CRITICAL_WATERMARK_BYTES)); then
    RUN_MODE="emergency"
  elif ((DISK_FREE_BYTES < LOW_WATERMARK_BYTES)); then
    RUN_MODE="aggressive"
  fi

  # Torrents que ainda rendem upload so entram na selecao quando o disco esta
  # abaixo de uma fracao do nivel critico, isto e, quando nao ha mais nada morto.
  if [[ "${RUN_MODE}" == "emergency" ]] &&
    ((DISK_FREE_BYTES * 100 < CRITICAL_WATERMARK_BYTES * YIELD_OVERRIDE_PERCENT_OF_CRITICAL)); then
    YIELD_OVERRIDE="true"
  fi

  if [[ "${RUN_MODE}" != "normal" ]]; then
    BYTES_NEEDED=$((HIGH_WATERMARK_BYTES - DISK_FREE_BYTES))
    if ((BYTES_NEEDED < 0)); then
      BYTES_NEEDED=0
    fi
  fi
}

estimate_path_reclaimable_bytes() {
  local path="$1" links blocks
  if [[ -f "${path}" ]]; then
    read -r links blocks < <(stat -c '%h %b' -- "${path}" 2>/dev/null) || {
      printf '0'
      return 0
    }
    if ((links == 1)); then
      printf '%s' "$((blocks * 512))"
    else
      printf '0'
    fi
    return 0
  fi
  if [[ -d "${path}" ]]; then
    find "${path}" -xdev -type f -links 1 -printf '%b\n' 2>/dev/null |
      awk '{blocks += $1} END {printf "%.0f", blocks * 512}'
    return 0
  fi
  printf '0'
}

# Agrupa os torrents por componente conectado: dois torrents pertencem ao mesmo grupo
# quando compartilham ao menos um inode (hardlink de cross-seed), mesmo que um deles
# use so um subconjunto dos arquivos do outro. O espaco liberavel de um grupo e a soma
# dos arquivos cujos nomes (links) estao todos dentro dele.
# The API owns the file list. content_path may be a folder shared by unrelated torrents.
fetch_torrent_file_manifest() {
  curl "${CURL_COMMON[@]}" -b "${COOKIE_JAR}" -G \
    --data-urlencode "hash=$1" "${QBT_URL}/api/v2/torrents/files"
}

torrent_file_stats() {
  local hash="$1" base="$2" complete="$3" manifest encoded priority name path file_stat
  [[ "${base}" == /* && "${base}" != "/" ]] || return 1
  manifest="$(fetch_torrent_file_manifest "${hash}")" || return 1
  jq -e 'type == "array" and length > 0 and all(.[];
    (.name | type == "string") and (.name | length > 0) and
    (.name | startswith("/") | not) and (.name | split("/") | all(. != "..")))' \
    >/dev/null <<<"${manifest}" || return 1
  while IFS=$'\t' read -r encoded priority; do
    name="$(printf '%s' "${encoded}" | base64 --decode)"
    path="${base%/}/${name}"
    if [[ ! -e "${path}" && -f "${path}.!qB" ]]; then path+=".!qB"; fi
    if [[ -L "${path}" ]]; then return 1; fi
    if [[ -f "${path}" ]]; then
      # Include the actual path: several owners of one path are not extra hardlinks.
      file_stat="$(stat -c '%d:%i %h %b' -- "${path}")" || return 1
      printf '%s %s\n' "${file_stat}" \
        "$(printf '%s' "${path}" | base64 -w0)"
    elif [[ "${complete}" == "true" && "${priority}" != "0" ]]; then
      return 1
    fi
  done < <(jq -r '.[] | [(.name | @base64), (.priority // 1)] | @tsv' <<<"${manifest}")
}

enrich_reclaimability() {
  local scored_json="$1" mapping hash encoded_path path
  if [[ "${DELETE_FILES}" != "true" ||
    ( "${DISK_PRESSURE_ENABLED}" != "true" && "${FOLLOWERS_JSON}" == "[]" ) ]]; then
    jq -c 'map(. + {
      physical_reclaimable_bytes:null,
      physical_reclaim_estimated:false,
      physical_group_key:null,
      physical_group_member_count:1,
      physical_group_complete:null,
      physical_group_reclaimable_bytes:null
    })' \
      <<<"${scored_json}"
    return 0
  fi

  mapping="$(
    while IFS=$'\t' read -r hash encoded_path complete; do
      path="$(printf '%s' "${encoded_path}" | base64 --decode 2>/dev/null || true)"
      local stats=""
      stats="$(torrent_file_stats "${hash}" "${path}" "${complete}")" || \
        die "nao foi possivel validar os arquivos do torrent; exclusao bloqueada"
      if [[ -n "${stats}" ]]; then
        awk -v hash="${hash}" '{printf "%s\t%s\t%s\t%s\t%s\n", hash, $1, $2, $3, $4}' <<<"${stats}"
      else
        printf '%s\t\t0\t0\n' "${hash}"
      fi
    done < <(jq -r '.[] | [(.hash // ""), ((.save_path // "") | @base64), (.is_complete // false)] | @tsv' <<<"${scored_json}") |
      jq -Rn '
        [inputs | split("\t") | {
          hash:.[0], ino:.[1], nlink:(.[2] | tonumber), blocks:(.[3] | tonumber), path:.[4]
        }] as $lines
        | ($lines | group_by(.hash)
           | map({hash: .[0].hash, files: (map(select(.ino != "")) | unique_by(.path))})) as $rows
        | ($rows | map(select(.files | length > 0))) as $with
        # inodes referenciados por 2 ou mais torrents ligam os torrents entre si
        | ($with | map(.hash as $h | .files[] | {ino, h: $h}) | group_by(.ino)
           | map(select(length > 1) | map(.h) | unique)) as $links
        | ($with | map({key: .hash, value: .hash}) | from_entries) as $start
        | ($start | until(
            . as $lab | ($links | map(map($lab[.]) | unique | length) | all(. == 1));
            reduce $links[] as $set (.;
              . as $cur | ($set | map($cur[.]) | min) as $low
              | reduce $set[] as $h (.; .[$h] = $low)))) as $lab
        | reduce ($with | group_by($lab[.hash])[]) as $comp ({};
            ($comp | map(.hash)) as $members
            | ($comp | map(.files[]) | group_by(.ino)
               | map({ino: .[0].ino, nlink: .[0].nlink, blocks: .[0].blocks, names: (map(.path) | unique | length)})) as $inodes
            | ((($inodes | map(select(.names >= .nlink) | .blocks) | add) // 0) * 512) as $freed
            | ($inodes | all(.names >= .nlink)) as $complete
            | ("grp:" + ($members | min)) as $key
            | reduce $comp[] as $row (.;
                .[$row.hash] = {
                  key: $key, member_count: ($members | length),
                  complete: $complete, reclaimable_bytes: $freed,
                  individual_reclaimable_bytes:
                    ((($row.files | map(select(.nlink <= 1) | .blocks) | add) // 0) * 512)
                }))
        | reduce ($rows[] | select(.files | length == 0)) as $item (.;
            .[$item.hash] = {
              key: null, member_count: 1, complete: false,
              reclaimable_bytes: 0, individual_reclaimable_bytes: 0
            })
      '
  )" || return 1

  jq -c --argjson mapping "${mapping}" '
    map(. + {
      physical_reclaimable_bytes: ($mapping[.hash].individual_reclaimable_bytes // 0),
      physical_reclaim_estimated: true,
      physical_group_key: ($mapping[.hash].key // null),
      physical_group_member_count: ($mapping[.hash].member_count // 1),
      physical_group_complete: ($mapping[.hash].complete // false),
      physical_group_reclaimable_bytes: ($mapping[.hash].reclaimable_bytes // 0)
    })
  ' <<<"${scored_json}"
}

# Programa jq unico para selecao e diagnostico. Cada grupo fisico (hardlinks
# compartilhados) e avaliado como um conjunto: o torrent pai decide e os
# seguidores (cross-seed) acompanham, mantendo apenas vetos explicitos.
SELECT_JQ='
  def parent_ok:
    .eligible and (.history_ready or ($mode != "normal" and $without_history))
    and (.cleanup_score >= $threshold);
  def failing_reason:
    if (.blockers.protected_tag // false) then "tag"
    elif (.blockers.yield // false) then "rendimento"
    elif (.blockers.forced // false) then "forcado"
    elif (.blockers.active_transfer // false) then "transferencia"
    elif (.blockers.incomplete // false) then "incompleto"
    elif (.blockers.retention // false) then "retencao"
    elif (.blockers.ratio // false) then "ratio"
    elif (.blockers.inactivity // false) then "inatividade"
    elif ((.history_ready or ($mode != "normal" and $without_history)) | not) then "historico"
    elif (.cleanup_score < $threshold) then "score"
    else "outro" end;
  def gkey: (.physical_group_key // ("torrent:" + (.hash // "")));
  def follower: (.is_follower // false);
  [group_by(gkey)[]
    | . as $all
    | ($all | map(select(follower | not))) as $parents
    | ($all | map(select(follower))) as $followers
    | (if ($parents | length) == 0 then
         # Orfao so quando todos os nomes do arquivo estao no grupo: um hardlink fora
         # dele (rTorrent, categoria nao gerenciada) indica um pai protegido.
         if $orphan_hours > 0 and ($all[0].physical_group_key != null)
            and (($all[0].physical_reclaim_estimated // false) and ($all[0].physical_group_complete // false))
            and all($followers[]; (.age_hours >= $orphan_hours) and ((.follower_veto // false) | not))
         then {kind: "cand", reason: "orfao", members: $all, rank: 100}
         else {kind: "blocked", reason: (if $orphan_hours > 0 then "orfao_aguardando" else "orfao_ignorado" end)} end
       elif ($parents | map(parent_ok) | all | not) then
         {kind: "blocked",
          reason: ("pai_" + ([$parents[] | select(parent_ok | not)] | sort_by(.cleanup_score) | reverse | .[0] | failing_reason))}
       elif ($followers | map(.follower_veto // false) | any) then
         {kind: "blocked", reason: "link_protegido"}
       else {kind: "cand", reason: "pai", members: $all,
             rank: ($parents | map(.cleanup_score) | min // 0)} end) as $decision
    | if $decision.kind == "blocked" then $decision
      else
        ($decision.members) as $members
        | (if $mode == "normal" then
             (if ($members[0].physical_reclaim_estimated // false)
              then ($members[0].physical_group_reclaimable_bytes // 0)
              else ([$members[] | (.size_bytes // 0)] | max // 0) end)
           elif ($members[0].physical_reclaim_estimated // false)
           then ($members[0].physical_group_reclaimable_bytes //
                 $members[0].physical_reclaimable_bytes // 0)
           else ($members[0].physical_group_reclaimable_bytes //
                 $members[0].physical_reclaimable_bytes // $members[0].size_bytes // 0)
           end) as $group_bytes
        | if ($mode != "normal") and ($group_bytes <= 0)
          then {kind: "blocked", reason: "sem_recuperacao"}
          else {kind: "cand", reason: $decision.reason,
                items: ($members | sort_by(.cleanup_score, .size_bytes) | reverse),
                count: ($members | length), bytes: $group_bytes, rank: $decision.rank} end
      end
  ] as $groups
  | ([$groups[] | select(.kind == "cand")] | sort_by(.rank, .bytes) | reverse
     | reduce .[] as $group
         ({items: [], rest: [], bytes: 0};
           if (((.items | map(.count) | add // 0) + $group.count) > $max_count)
              or ($wanted_bytes > 0 and .bytes >= $wanted_bytes)
              or ($max_reclaim_bytes > 0 and (.bytes + $group.bytes) > $max_reclaim_bytes)
           then .rest += [$group]
           else .items += [$group] | .bytes += $group.bytes
           end)) as $chosen
  | if $want == "diag" then
      {selected_groups: ($chosen.items | length),
       cut_by_limit: ($chosen.rest | length),
       blocked: ([$groups[] | select(.kind == "blocked") | .reason]
                 | group_by(.) | map({key: .[0], value: length}) | from_entries)}
    else
      [$chosen.items[]
        | . as $group
        | $group.items | to_entries[]
        | .value + {
            selection_bytes: (if .key == 0 then $group.bytes else 0 end),
            physical_bundle_size: $group.count
          }]
    end
'

_select_run() {
  local scored_json="$1" want="$2"
  local threshold bytes_limit without_history max_count max_reclaim_gb
  case "${RUN_MODE}" in
    emergency)
      threshold="${EMERGENCY_MIN_SCORE}"
      bytes_limit="${BYTES_NEEDED}"
      without_history="${EMERGENCY_WITHOUT_HISTORY}"
      max_count="${EMERGENCY_MAX_DELETE_PER_RUN}"
      max_reclaim_gb="${EMERGENCY_MAX_RECLAIM_GB_PER_RUN}"
      ;;
    aggressive)
      threshold="${AGGRESSIVE_MIN_SCORE}"
      bytes_limit="${BYTES_NEEDED}"
      without_history="${AGGRESSIVE_WITHOUT_HISTORY}"
      max_count="${MAX_DELETE_PER_RUN}"
      max_reclaim_gb="${MAX_RECLAIM_GB_PER_RUN}"
      ;;
    *)
      threshold="${NORMAL_MIN_SCORE}"
      bytes_limit=0
      without_history="false"
      max_count="${MAX_DELETE_PER_RUN}"
      max_reclaim_gb="${MAX_RECLAIM_GB_PER_RUN}"
      if [[ "${NORMAL_CLEANUP_ENABLED}" != "true" ]]; then
        [[ "${want}" == "diag" ]] && printf '{"selected_groups":0,"cut_by_limit":0,"blocked":{}}' || printf '[]'
        return 0
      fi
      ;;
  esac

  local max_reclaim_bytes=$((max_reclaim_gb * 1024 * 1024 * 1024))
  jq -c \
    --argjson threshold "${threshold}" \
    --arg mode "${RUN_MODE}" \
    --arg want "${want}" \
    --argjson without_history "${without_history}" \
    --argjson max_count "${max_count}" \
    --argjson wanted_bytes "${bytes_limit}" \
    --argjson max_reclaim_bytes "${max_reclaim_bytes}" \
    --argjson orphan_hours "${FOLLOWER_ORPHAN_HOURS}" \
    "${SELECT_JQ}" <<<"${scored_json}"
}

select_candidates() {
  _select_run "$1" select
}

explain_selection() {
  _select_run "$1" diag
}

human_gib() {
  awk -v bytes="$1" 'BEGIN {printf "%.1f GiB", bytes / 1073741824}'
}

show_policy_summary() {
  local scored_json="$1" selected_json="$2" total="$3"
  local managed eligible history_ready selected planned planned_physical blockers diagnostics followers
  managed="$(jq 'length' <<<"${scored_json}")"
  eligible="$(jq '[.[] | select(.eligible)] | length' <<<"${scored_json}")"
  history_ready="$(jq '[.[] | select(.history_ready)] | length' <<<"${scored_json}")"
  selected="$(jq 'length' <<<"${selected_json}")"
  planned="$(jq '[.[].size_bytes] | add // 0' <<<"${selected_json}")"
  planned_physical="$(jq '[.[].selection_bytes // 0] | add // 0' <<<"${selected_json}")"

  log "INFO" "modo=${RUN_MODE}; gerenciados=${managed}/${total}; historico_pronto=${history_ready}; elegiveis=${eligible}; selecionados=${selected}; tamanho_logico=$(human_gib "${planned}"); recuperacao_fisica_estimada=$(human_gib "${planned_physical}")"
  if [[ "${DISK_PRESSURE_ENABLED}" == "true" ]]; then
    log "INFO" "disco livre=$(human_gib "${DISK_FREE_BYTES}"); emergencia=$(human_gib "${CRITICAL_WATERMARK_BYTES}"); gatilho=$(human_gib "${LOW_WATERMARK_BYTES}"); alvo=$(human_gib "${HIGH_WATERMARK_BYTES}")"
  fi
  blockers="$(jq -r '
    def blocked($name): [.[] | select(.blockers[$name] // false)];
    [
      ["retencao", blocked("retention")],
      ["inatividade", blocked("inactivity")],
      ["ratio", blocked("ratio")],
      ["transferencia", blocked("active_transfer")],
      ["tag", blocked("protected_tag")],
      ["rendimento", blocked("yield")],
      ["forcado", blocked("forced")],
      ["incompleto", blocked("incomplete")]
    ]
    | map("\(.[0])=\(.[1]|length)/\(([.[1][] | .size_bytes] | add // 0) / 1073741824 * 10 | round / 10)GiB")
    | join("; ")
  ' <<<"${scored_json}")"
  followers="$(jq '[.[] | select(.is_follower // false)] | length' <<<"${scored_json}")"
  log "INFO" "bloqueios (podem se sobrepor): ${blockers}; categorias_nao_listadas=$((total - managed)); seguidores=${followers}"
  diagnostics="$(explain_selection "${scored_json}" 2>/dev/null | jq -r '
    "grupos: selecionados=\(.selected_groups); cortados_pelo_limite=\(.cut_by_limit); bloqueados: " +
    (if (.blocked | length) == 0 then "nenhum"
     else (.blocked | to_entries | sort_by(-.value) | map("\(.key)=\(.value)") | join("; ")) end)
  ' 2>/dev/null || true)"
  [[ -z "${diagnostics}" ]] || log "INFO" "${diagnostics}"

  if ((selected > 0)); then
    local list_limit=5
    [[ "${LOG_LEVEL}" == "detailed" ]] && list_limit="${selected}"
    jq -r --argjson limit "${list_limit}" '.[:$limit][] |
      "  score=\(.cleanup_score) eficiencia=\(.upload_efficiency_mib_per_gib_day)MiB/GiB/dia size=\(.size_gb)GiB fisico=\((.selection_bytes // 0)/1073741824*100|round/100)GiB inativo=\(.inactive_hours)h swarm=\(.swarm_seeds)S/\(.swarm_leechers)L ratio=\(.ratio) categoria=\(.category) :: \(.name)"' \
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

emit_policy_snapshot() {
  local scored_json="$1" selected_json="$2" total="$3" selected_map snapshot
  if ! selected_map="$(jq -c '
    reduce .[] as $item ({}; .[$item.hash] = ($item.selection_bytes // 0))
  ' <<<"${selected_json}" 2>/dev/null)"; then
    log "AVISO" "nao foi possivel preparar o resumo estruturado; a limpeza continuara"
    return 0
  fi
  if ! snapshot="$(jq -c \
    --arg run_id "${RUN_ID}" \
    --arg timestamp "$(date --iso-8601=seconds)" \
    --arg mode "${RUN_MODE}" \
    --argjson total_torrents "${total}" \
    --argjson selected_map "${selected_map}" \
    --argjson disk_pressure_enabled "${DISK_PRESSURE_ENABLED}" \
    --argjson disk_total_bytes "${DISK_TOTAL_BYTES}" \
    --argjson disk_free_bytes "${DISK_FREE_BYTES}" \
    --argjson critical_watermark_bytes "${CRITICAL_WATERMARK_BYTES}" \
    --argjson low_watermark_bytes "${LOW_WATERMARK_BYTES}" \
    --argjson high_watermark_bytes "${HIGH_WATERMARK_BYTES}" \
    --argjson bytes_needed "${BYTES_NEEDED}" '
      def selected($hash): $selected_map[$hash] != null;
      def rounded_average($values):
        if ($values | length) > 0
        then (($values | add / length * 100) | round / 100)
        else 0 end;
      . as $torrents
      | ($torrents | length) as $managed
      | ($torrents | map(.cleanup_score // 0)) as $scores
      | {
          event: "policy_snapshot",
          run_id: $run_id,
          timestamp: $timestamp,
          mode: $mode,
          disk_pressure_enabled: $disk_pressure_enabled,
          disk_total_bytes: $disk_total_bytes,
          disk_free_bytes: $disk_free_bytes,
          critical_watermark_bytes: $critical_watermark_bytes,
          low_watermark_bytes: $low_watermark_bytes,
          high_watermark_bytes: $high_watermark_bytes,
          bytes_needed: $bytes_needed,
          total_torrents: $total_torrents,
          managed_torrents: $managed,
          unmanaged_torrents: ([$total_torrents - $managed, 0] | max),
          managed_size_bytes: ([$torrents[] | (.size_bytes // 0)] | add // 0),
          active_torrents: ([$torrents[] | select(.is_active_transfer)] | length),
          upload_speed_bps: ([$torrents[] | (.upspeed // 0)] | add // 0),
          uploaded_bytes_total: ([$torrents[] | (.uploaded // 0)] | add // 0),
          follower_torrents: ([$torrents[] | select(.is_follower // false)] | length),
          history_ready: ([$torrents[] | select(.history_ready)] | length),
          eligible_torrents: ([$torrents[] | select(.eligible)] | length),
          selected_torrents: ($selected_map | length),
          selected_logical_bytes: (
            [$torrents[] | select(selected(.hash)) | (.size_bytes // 0)] | add // 0
          ),
          estimated_physical_reclaim_bytes: (
            [$torrents[] | select(selected(.hash)) |
              ($selected_map[.hash] // .physical_reclaimable_bytes // .size_bytes // 0)] | add // 0
          ),
          blockers: {
            retention: ([$torrents[] | select(.blockers.retention // false)] | length),
            inactivity: ([$torrents[] | select(.blockers.inactivity // false)] | length),
            ratio: ([$torrents[] | select(.blockers.ratio // false)] | length),
            active_transfer: ([$torrents[] | select(.blockers.active_transfer // false)] | length),
            protected_tag: ([$torrents[] | select(.blockers.protected_tag // false)] | length),
            yield: ([$torrents[] | select(.blockers.yield // false)] | length),
            forced: ([$torrents[] | select(.blockers.forced // false)] | length),
            incomplete: ([$torrents[] | select(.blockers.incomplete // false)] | length)
          },
          scores: {
            average: rounded_average($scores),
            minimum: ($scores | min // 0),
            maximum: ($scores | max // 0)
          },
          categories: (
            $torrents
            | sort_by(.category // "")
            | group_by(.category // "")
            | map(
                . as $items
                | ($items | map(.cleanup_score // 0)) as $category_scores
                | {
                    category: ($items[0].category // ""),
                    count: ($items | length),
                    size_bytes: ([$items[] | (.size_bytes // 0)] | add // 0),
                    upload_speed_bps: ([$items[] | (.upspeed // 0)] | add // 0),
                    active: ([$items[] | select(.is_active_transfer)] | length),
                    history_ready: ([$items[] | select(.history_ready)] | length),
                    eligible: ([$items[] | select(.eligible)] | length),
                    selected: ([$items[] | select(selected(.hash))] | length),
                    estimated_physical_reclaim_bytes: (
                      [$items[] | select(selected(.hash)) |
                        ($selected_map[.hash] // .physical_reclaimable_bytes // .size_bytes // 0)] | add // 0
                    ),
                    blockers: {
                      retention: ([$items[] | select(.blockers.retention // false)] | length),
                      inactivity: ([$items[] | select(.blockers.inactivity // false)] | length),
                      ratio: ([$items[] | select(.blockers.ratio // false)] | length),
                      active_transfer: ([$items[] | select(.blockers.active_transfer // false)] | length)
                    },
                    average_score: rounded_average($category_scores),
                    maximum_score: ($category_scores | max // 0)
                  }
              )
            | sort_by(.size_bytes)
            | reverse
          ),
          top_scores: (
            $torrents
            | sort_by(.cleanup_score, .size_bytes)
            | reverse
            | .[:5]
            | map({
                name: (.name // ""),
                category: (.category // ""),
                size_bytes: (.size_bytes // 0),
                physical_reclaimable_bytes: (.physical_reclaimable_bytes // null),
                score: (.cleanup_score // 0),
                upload_efficiency: (.upload_efficiency_mib_per_gib_day // 0),
                upload_speed_bps: (.upspeed // 0),
                inactive_hours: (.inactive_hours // 0),
                ratio: (.ratio // 0),
                seeds: (.swarm_seeds // 0),
                leechers: (.swarm_leechers // 0),
                history_ready: (.history_ready // false),
                eligible: (.eligible // false),
                blockers: (.blockers // {}),
                selected: selected(.hash)
              })
          )
        }
    ' <<<"${scored_json}" 2>/dev/null)"; then
    log "AVISO" "nao foi possivel montar o resumo estruturado; a limpeza continuara"
    return 0
  fi
  emit_event "${snapshot}"
}

# Reconfere os candidatos imediatamente antes de excluir: tags, rendimento atual
# e conclusao podem ter mudado durante a varredura. Um grupo so e excluido inteiro.
reverify_selection() {
  local selected_json="$1" count hashes response filtered
  count="$(jq 'length' <<<"${selected_json}")"
  if ((count == 0)) || [[ "${REVERIFY_BEFORE_DELETE}" != "true" ]]; then
    printf '%s' "${selected_json}"
    return 0
  fi
  hashes="$(jq -r '.[].hash' <<<"${selected_json}" | paste -sd'|' -)"
  if ! response="$(curl "${CURL_COMMON[@]}" -b "${COOKIE_JAR}" -G \
    --data-urlencode "hashes=${hashes}" "${QBT_URL}/api/v2/torrents/info" 2>/dev/null)" ||
    ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${response}"; then
    log "AVISO" "nao foi possivel reconferir os candidatos; exclusao adiada para a proxima rodada" >&2
    printf '[]'
    return 0
  fi
  filtered="$(jq -c \
    --argjson current "${response}" \
    --arg protected_tags "${PROTECTED_TAGS}" \
    --argjson skip_forced "${SKIP_FORCE_STARTED}" \
    --argjson allow_incomplete "${ALLOW_INCOMPLETE_DELETE}" \
    --argjson protect_efficiency "${PROTECT_EFFICIENCY_MIB_PER_GIB_DAY}" \
    --argjson yield_override "${YIELD_OVERRIDE}" '
      def tags_of: ((.tags // "") | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)));
      def gkey: (.physical_group_key // ("torrent:" + (.hash // "")));
      ($protected_tags | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))) as $protected
      | ($current | map({key: .hash, value: .}) | from_entries) as $now
      | (map(select(
          ($now[.hash]) as $cur
          | ($cur == null)
          or ($cur.save_path != .save_path)
          or ($cur.content_path != .content_path)
          or (($cur | tags_of) as $tags | any($tags[]; . as $t | $protected | index($t)))
          or ((.is_follower // false | not) and (
                ($skip_forced and ($cur.force_start // false))
                or (($allow_incomplete | not) and (($cur.progress // 0) < 0.9999))
                or (($protect_efficiency > 0) and ($yield_override | not)
                    and ((.size_bytes // 0) > 0)
                    and ((($cur.upspeed // 0) * 86400 / 1048576 / ((.size_bytes // 1) / 1073741824))
                         >= $protect_efficiency))))
        ) | gkey)) as $drop_keys
      | map(select(gkey as $k | ($drop_keys | index($k)) == null))
    ' <<<"${selected_json}")" || {
    log "AVISO" "falha ao reconferir os candidatos; exclusao adiada para a proxima rodada" >&2
    printf '[]'
    return 0
  }
  local kept
  kept="$(jq 'length' <<<"${filtered}")"
  if ((kept < count)); then
    log "INFO" "reconferencia retirou $((count - kept)) de ${count} candidato(s) (grupos inteiros) por mudanca de estado" >&2
  fi
  printf '%s' "${filtered}"
}

delete_torrents() {
  local selected_json="$1" count hashes response planned_bytes estimated_physical_bytes
  local released_bytes event_time item free_before=0 free_after=0 measurement_available=false
  local best_free=0 current_free=0 deadline=0 stable_samples=0 target_released=0
  count="$(jq 'length' <<<"${selected_json}")"
  planned_bytes="$(jq '[.[].size_bytes] | add // 0' <<<"${selected_json}")"
  estimated_physical_bytes="$(jq '[.[].selection_bytes // 0] | add // 0' <<<"${selected_json}")"

  if ((count == 0)); then
    emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
      --argjson dry_run "${DRY_RUN}" \
      '{event:"deletion_summary", run_id:$run_id, timestamp:$timestamp, dry_run:$dry_run,
        planned_count:0, planned_bytes:0, estimated_physical_reclaim_bytes:0,
        deleted_count:0, released_bytes:0, physical_measurement_available:false}')"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN" "nenhuma exclusao executada"
    while IFS= read -r item; do
      emit_event "${item}"
    done < <(jq -c --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
      --arg mode "${RUN_MODE}" '
        .[] | {
          event:"dry_run_candidate", run_id:$run_id, timestamp:$timestamp, mode:$mode,
          hash:.hash, name:(.name // ""), category:(.category // ""),
          size_bytes:(.size_bytes // 0), uploaded_bytes:(.uploaded // 0),
          score:(.cleanup_score // 0), yield_mib_per_gib_day:(.yield_mib_per_gib_day // 0),
          is_follower:(.is_follower // false)
        }' <<<"${selected_json}")
    emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
      --argjson planned_count "${count}" --argjson planned_bytes "${planned_bytes}" \
      --argjson estimated_physical_bytes "${estimated_physical_bytes}" \
      '{event:"deletion_summary", run_id:$run_id, timestamp:$timestamp, dry_run:true,
        planned_count:$planned_count, planned_bytes:$planned_bytes,
        estimated_physical_reclaim_bytes:$estimated_physical_bytes,
        deleted_count:0, released_bytes:0, physical_measurement_available:false}')"
    return 0
  fi

  if [[ "${DISK_PRESSURE_ENABLED}" == "true" ]]; then
    read -r _ free_before < <(filesystem_status)
    measurement_available=true
  fi
  hashes="$(jq -r '.[].hash' <<<"${selected_json}" | paste -sd'|' -)"
  response="$(curl "${CURL_COMMON[@]}" -b "${COOKIE_JAR}" -X POST \
    --data-urlencode "hashes=${hashes}" --data "deleteFiles=${DELETE_FILES}" \
    "${QBT_URL}/api/v2/torrents/delete")" || die "a API recusou a exclusao"
  [[ -z "${response}" ]] || log "AVISO" "resposta inesperada da API ao excluir: ${response}"
  log "OK" "${count} torrent(s) removido(s); deleteFiles=${DELETE_FILES}"

  event_time="$(date --iso-8601=seconds)"
  released_bytes=0
  if [[ "${measurement_available}" == "true" ]]; then
    best_free="${free_before}"
    target_released=$((estimated_physical_bytes * 9 / 10))
    deadline=$((SECONDS + PHYSICAL_MEASURE_TIMEOUT_SECONDS))
    log "INFO" "aguardando a exclusao assincrona do qBittorrent por ate ${PHYSICAL_MEASURE_TIMEOUT_SECONDS}s"
    while ((SECONDS < deadline)); do
      sleep "${PHYSICAL_MEASURE_INTERVAL_SECONDS}"
      read -r _ current_free < <(filesystem_status)
      if ((current_free > best_free)); then
        best_free="${current_free}"
        stable_samples=0
      else
        ((stable_samples += 1))
      fi
      released_bytes=$((best_free - free_before))
      if ((target_released > 0 && released_bytes >= target_released)); then
        break
      fi
      if ((released_bytes > 0 && stable_samples >= 6)); then
        break
      fi
    done
    free_after="${best_free}"
    released_bytes=$((free_after - free_before))
  fi
  log "INFO" "exclusao concluida: logico=$(human_gib "${planned_bytes}"); fisico_estimado=$(human_gib "${estimated_physical_bytes}"); fisico_observado=$(human_gib "${released_bytes}")"
  while IFS= read -r item; do
    emit_event "${item}"
  done < <(jq -c --arg run_id "${RUN_ID}" --arg timestamp "${event_time}" \
    --argjson delete_files "${DELETE_FILES}" '
      .[] | {
        event:"torrent_deleted", run_id:$run_id, timestamp:$timestamp,
        name:(.name // ""), category:(.category // ""), size_bytes:(.size_bytes // 0),
        estimated_physical_reclaim_bytes:(
          if $delete_files then (.selection_bytes // .physical_reclaimable_bytes // .size_bytes // 0) else 0 end
        )
      }' <<<"${selected_json}")
  emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "${event_time}" \
    --argjson planned_count "${count}" --argjson planned_bytes "${planned_bytes}" \
    --argjson estimated_physical_bytes "${estimated_physical_bytes}" \
    --argjson deleted_count "${count}" --argjson released_bytes "${released_bytes}" \
    --argjson measurement_available "${measurement_available}" \
    --argjson delete_files "${DELETE_FILES}" \
    '{event:"deletion_summary", run_id:$run_id, timestamp:$timestamp, dry_run:false,
      delete_files:$delete_files, planned_count:$planned_count, planned_bytes:$planned_bytes,
      estimated_physical_reclaim_bytes:$estimated_physical_bytes,
      deleted_count:$deleted_count, released_bytes:$released_bytes,
      physical_measurement_available:$measurement_available}')"
}

# O modo --pressure-gate roda em intervalos curtos: sai em silencio quando o
# disco esta confortavel, quando outra execucao ocupa o lock ou quando a ultima
# execucao completa foi recente.
pressure_gate_precheck() {
  load_config
  validate_config
  CONFIG_LOADED="true"
  [[ "${DISK_PRESSURE_ENABLED}" == "true" ]] || exit 0
  choose_mode
  [[ "${RUN_MODE}" != "normal" ]] || exit 0
  if [[ -f "${RUN_STAMP_FILE}" ]]; then
    local age=$(($(date +%s) - $(stat -c %Y -- "${RUN_STAMP_FILE}" 2>/dev/null || echo 0)))
    ((age >= PRESSURE_GATE_MIN_INTERVAL_SECONDS)) || exit 0
  fi
  exec 8>"${LOCK_FILE}"
  flock -n 8 || exit 0
  flock -u 8
  exec 8>&-
}

main() {
  parse_args "$@"

  if [[ "${ACTION}" == "check-config" ]]; then
    load_config
    validate_config
    log "OK" "configuracao valida; ${#RETENTION_HOURS[@]} regra(s) de categoria carregada(s)"
    return 0
  fi

  CONFIG_LOADED="false"
  if [[ "${ACTION}" == "pressure-gate" ]]; then
    pressure_gate_precheck
  fi

  RUN_ID="$(date +%s)-$$-${RANDOM}"
  if command -v jq >/dev/null 2>&1; then
    emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
      --arg version "${VERSION}" \
      '{event:"run_started", run_id:$run_id, timestamp:$timestamp, version:$version}')"
  fi
  if [[ "${CONFIG_LOADED}" != "true" ]]; then
    load_config
    validate_config
  fi
  setup_runtime
  log "INFO" "qbit-autodelete ${VERSION} iniciado; dry_run=${DRY_RUN}"
  emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
    --arg version "${VERSION}" --argjson dry_run "${DRY_RUN}" \
    '{event:"run_configured", run_id:$run_id, timestamp:$timestamp, version:$version, dry_run:$dry_run}')"
  [[ "${ALLOW_INCOMPLETE_DELETE}" == "true" ]] && log "AVISO" "exclusao de torrents incompletos esta habilitada"
  login_qbittorrent

  local raw_json rules_json state_json scored_json selected_json now_epoch
  raw_json="$(fetch_all_torrents)"
  rules_json="$(rules_as_json)"
  state_json="$(load_state)"
  now_epoch="$(date +%s)"
  choose_mode
  scored_json="$(score_torrents "${now_epoch}" "${rules_json}" "${state_json}" <<<"${raw_json}")"
  scored_json="$(enrich_reclaimability "${scored_json}")"
  selected_json="$(select_candidates "${scored_json}")"
  show_policy_summary "${scored_json}" "${selected_json}" "$(jq 'length' <<<"${raw_json}")"
  save_state "${scored_json}" "${now_epoch}" ||
    log "AVISO" "historico nao atualizado nesta execucao"
  emit_policy_snapshot "${scored_json}" "${selected_json}" "$(jq 'length' <<<"${raw_json}")"
  selected_json="$(reverify_selection "${selected_json}")"
  delete_torrents "${selected_json}"
  touch -- "${RUN_STAMP_FILE}" 2>/dev/null || true
  emit_event "$(jq -cn --arg run_id "${RUN_ID}" --arg timestamp "$(date --iso-8601=seconds)" \
    '{event:"run_completed", run_id:$run_id, timestamp:$timestamp, success:true}')"
  log "INFO" "execucao concluida"
}

if [[ "${QBIT_AUTODELETE_LIBRARY:-false}" != "true" ]]; then
  main "$@"
fi
