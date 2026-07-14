#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="1.0.0"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_SCRIPT="${PROJECT_DIR}/qbit-autodelete.sh"
SOURCE_ENV="${PROJECT_DIR}/example/qbit_autodelete.env"
SOURCE_CATEGORIES="${PROJECT_DIR}/example/qbit-autodelete.categories"
SOURCE_SERVICE="${PROJECT_DIR}/example/qbit-autodelete.service"
SOURCE_TIMER="${PROJECT_DIR}/example/qbit-autodelete.timer"

INSTALL_SCRIPT="${QBIT_INSTALL_SCRIPT:-/usr/local/bin/qbit-autodelete}"
CONFIG_FILE="${QBIT_CONFIG_FILE:-/etc/qbit-autodelete.env}"
CATEGORIES_FILE="${QBIT_CATEGORIES_FILE:-/etc/qbit-autodelete.categories}"
SERVICE_FILE="${QBIT_SERVICE_FILE:-/etc/systemd/system/qbit-autodelete.service}"
TIMER_FILE="${QBIT_TIMER_FILE:-/etc/systemd/system/qbit-autodelete.timer}"
STATE_DIR="${QBIT_STATE_DIR:-/var/lib/qbit-autodelete}"
BACKUP_ROOT="${QBIT_BACKUP_ROOT:-/var/backups/qbit-autodelete}"

SERVICE_NAME="qbit-autodelete.service"
TIMER_NAME="qbit-autodelete.timer"
WORK_DIR=""
BACKUP_DIR=""

RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m' BOLD=$'\033[1m' DIM=$'\033[2m'
  RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m'
  BLUE=$'\033[34m' CYAN=$'\033[36m'
fi

cleanup() {
  [[ -z "${WORK_DIR}" || ! -d "${WORK_DIR}" ]] || rm -rf -- "${WORK_DIR}"
}
if [[ "${QBIT_AUTODELETE_INSTALLER_LIBRARY:-false}" != "true" ]]; then
  trap cleanup EXIT
fi

line() { printf '%s\n' "${DIM}------------------------------------------------------------${RESET}"; }
info() { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn() { printf '%s[AVISO]%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }
die() { printf '%s[ERRO]%s %s\n' "${RED}" "${RESET}" "$*" >&2; exit 1; }

header() {
  clear 2>/dev/null || true
  printf '%s%s\n' "${CYAN}${BOLD}" "+----------------------------------------------------------+"
  printf '| %-56s |\n' "qbit-autodelete - instalador Linux"
  printf '%s%s\n' "+----------------------------------------------------------+" "${RESET}"
  printf '%sVersao do instalador: %s%s\n\n' "${DIM}" "${INSTALLER_VERSION}" "${RESET}"
}

usage() {
  cat <<'EOF'
Uso: ./install.sh [acao]

Sem uma acao, abre o menu interativo.

  install       instala e configura do zero
  reconfigure   altera conexao, volume, seguranca e categorias
  update        atualiza script e units, preservando configuracao
  status        mostra o estado da instalacao e do timer
  uninstall     remove a instalacao (dados so saem com confirmacao)
  help          mostra esta ajuda

Execute a partir da raiz do repositorio. Acoes que alteram o sistema
pedem sudo automaticamente.
EOF
}

require_tty() {
  [[ -t 0 ]] || die "esta acao requer um terminal interativo"
}

require_root() {
  local action="$1"
  ((EUID == 0)) && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo nao encontrado; execute como root"
  info "Permissao administrativa necessaria; chamando sudo..."
  exec sudo --preserve-env=NO_COLOR -- "${BASH_SOURCE[0]}" "${action}"
}

require_assets() {
  local file
  for file in "${SOURCE_SCRIPT}" "${SOURCE_ENV}" "${SOURCE_CATEGORIES}" \
    "${SOURCE_SERVICE}" "${SOURCE_TIMER}"; do
    [[ -r "${file}" ]] || die "arquivo do pacote ausente: ${file}"
  done
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 ||
    die "este instalador requer uma distribuicao Linux com systemd"
  [[ -d /run/systemd/system ]] ||
    die "systemd nao esta ativo como gerenciador do sistema"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt() {
  local __var="$1" label="$2" default="${3-}" required="${4:-false}" input
  while true; do
    if [[ -n "${default}" ]]; then
      printf '%s%s%s [%s]: ' "${BOLD}" "${label}" "${RESET}" "${default}"
    else
      printf '%s%s%s: ' "${BOLD}" "${label}" "${RESET}"
    fi
    IFS= read -r input || die "entrada encerrada"
    input="$(trim "${input}")"
    [[ -n "${input}" ]] || input="${default}"
    if [[ "${required}" == "true" && -z "${input}" ]]; then
      warn "Este campo e obrigatorio."
      continue
    fi
    printf -v "${__var}" '%s' "${input}"
    return 0
  done
}

prompt_secret() {
  local __var="$1" label="$2" current="${3-}" input
  while true; do
    if [[ -n "${current}" ]]; then
      printf '%s%s%s [Enter mantem a atual]: ' "${BOLD}" "${label}" "${RESET}"
    else
      printf '%s%s%s: ' "${BOLD}" "${label}" "${RESET}"
    fi
    IFS= read -r -s input || die "entrada encerrada"
    printf '\n'
    [[ -n "${input}" ]] || input="${current}"
    if [[ -z "${input}" ]]; then
      warn "A senha e obrigatoria e nao sera exibida."
      continue
    fi
    printf -v "${__var}" '%s' "${input}"
    return 0
  done
}

ask_yes_no() {
  local label="$1" default="${2:-yes}" input suffix
  [[ "${default}" == "yes" ]] && suffix="S/n" || suffix="s/N"
  while true; do
    printf '%s%s%s [%s]: ' "${BOLD}" "${label}" "${RESET}" "${suffix}"
    IFS= read -r input || die "entrada encerrada"
    input="${input,,}"
    [[ -n "${input}" ]] || input="${default}"
    case "${input}" in
      s|sim|y|yes) REPLY_BOOL="true"; return 0 ;;
      n|nao|não|no) REPLY_BOOL="false"; return 0 ;;
      *) warn "Responda com s ou n." ;;
    esac
  done
}

pause_screen() {
  printf '\n%sPressione Enter para continuar...%s' "${DIM}" "${RESET}"
  IFS= read -r _ || true
}

validate_url() {
  [[ "$1" =~ ^https?://[^/]+$ ]]
}

validate_host_url() {
  [[ "$1" =~ ^https?://(\[[A-Za-z0-9:._%-]+\]|[A-Za-z0-9._-]+)$ ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

split_qbt_url() {
  local url="$1"
  PARSED_QBT_HOST="${url}"
  PARSED_QBT_PORT="8080"

  if [[ "${url}" =~ ^(https?://\[[^]]+\]):([0-9]+)$ ]]; then
    PARSED_QBT_HOST="${BASH_REMATCH[1]}"
    PARSED_QBT_PORT="${BASH_REMATCH[2]}"
  elif [[ "${url}" =~ ^(https?://[^/:]+):([0-9]+)$ ]]; then
    PARSED_QBT_HOST="${BASH_REMATCH[1]}"
    PARSED_QBT_PORT="${BASH_REMATCH[2]}"
  elif [[ "${url}" == https://* ]]; then
    PARSED_QBT_PORT="443"
  elif [[ "${url}" == http://* ]]; then
    PARSED_QBT_PORT="80"
  fi
}

validate_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_decimal() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

validate_percent_pair() {
  validate_uint "${LOW_PERCENT}" && validate_uint "${HIGH_PERCENT}" &&
    ((LOW_PERCENT > 0 && LOW_PERCENT <= 100 && HIGH_PERCENT >= LOW_PERCENT && HIGH_PERCENT <= 100))
}

missing_runtime_commands() {
  local cmd missing=()
  for cmd in curl jq date df awk flock mktemp dirname mkdir mv chmod rm; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  printf '%s\n' "${missing[*]}"
}

install_dependencies() {
  local missing
  missing="$(missing_runtime_commands)"
  [[ -n "${missing}" ]] || { ok "Dependencias encontradas."; return 0; }

  warn "Dependencias ausentes: ${missing}"
  ask_yes_no "Instalar as dependencias automaticamente?" yes
  [[ "${REPLY_BOOL}" == "true" ]] || die "instalacao cancelada por dependencias ausentes"

  if command -v pacman >/dev/null 2>&1; then
    pacman -S --needed --noconfirm curl jq coreutils gawk util-linux
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl jq coreutils gawk util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq coreutils gawk util-linux
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl jq coreutils gawk util-linux
  else
    die "gerenciador suportado nao encontrado; instale manualmente: curl jq coreutils awk util-linux"
  fi

  missing="$(missing_runtime_commands)"
  [[ -z "${missing}" ]] || die "ainda faltam dependencias: ${missing}"
  ok "Dependencias instaladas."
}

service_user_from_unit() {
  [[ -r "${SERVICE_FILE}" ]] || return 0
  awk -F= '/^User=/{print $2; exit}' "${SERVICE_FILE}"
}

safe_config_value() {
  local key="$1" owner mode
  [[ -r "${CONFIG_FILE}" ]] || return 0
  owner="$(stat -c '%u' "${CONFIG_FILE}")"
  mode="$(stat -c '%a' "${CONFIG_FILE}")"
  [[ "${owner}" == "0" && $((8#${mode} & 022)) -eq 0 ]] ||
    die "${CONFIG_FILE} precisa pertencer ao root e nao pode ser gravavel por grupo/outros"
  (
    set +u
    # Arquivo administrativo, validado quanto a dono e permissoes acima.
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
    printf '%s' "${!key-}"
  )
}

default_service_user() {
  local found
  found="$(service_user_from_unit)"
  if [[ -n "${found}" ]] && id "${found}" >/dev/null 2>&1; then
    printf '%s' "${found}"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "${SUDO_USER}" >/dev/null 2>&1; then
    printf '%s' "${SUDO_USER}"
  else
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}'
  fi
}

declare -a CATEGORIES=()

load_categories() {
  local source_file="${1:-${CATEGORIES_FILE}}" raw
  CATEGORIES=()
  [[ -r "${source_file}" ]] || return 0
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    raw="${raw%$'\r'}"
    [[ "${raw}" =~ ^[[:space:]]*(#|$) ]] && continue
    CATEGORIES+=("${raw}")
  done < "${source_file}"
}

show_categories() {
  local entry name rest hours ratio i=1
  printf '\n%s%sCategorias configuradas%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  line
  printf '%-4s %-30s %10s %10s\n' "#" "Categoria" "Horas" "Ratio"
  line
  if ((${#CATEGORIES[@]} == 0)); then
    printf '%sNenhuma categoria adicionada.%s\n' "${DIM}" "${RESET}"
  else
    for entry in "${CATEGORIES[@]}"; do
      name="${entry%%|*}"
      rest="${entry#*|}"
      hours="${rest%%|*}"
      ratio="${rest#*|}"
      printf '%-4s %-30.30s %10s %10s\n' "${i}" "${name}" "${hours}" "${ratio}"
      ((i += 1))
    done
  fi
  line
}

category_form() {
  local index="${1:--1}" entry="" name_default="" hours_default="72" ratio_default="1.0"
  local name hours ratio existing existing_name i
  if ((index >= 0)); then
    entry="${CATEGORIES[index]}"
    name_default="${entry%%|*}"
    entry="${entry#*|}"
    hours_default="${entry%%|*}"
    ratio_default="${entry#*|}"
  fi

  while true; do
    prompt name "Nome exato da categoria no qBittorrent" "${name_default}" true
    [[ "${name}" != *'|'* ]] || { warn "O nome nao pode conter |."; continue; }
    for i in "${!CATEGORIES[@]}"; do
      ((i == index)) && continue
      existing="${CATEGORIES[i]}"
      existing_name="${existing%%|*}"
      [[ "${existing_name}" != "${name}" ]] || { warn "Essa categoria ja existe."; name=""; break; }
    done
    [[ -n "${name}" ]] && break
  done

  while true; do
    prompt hours "Retencao minima em horas" "${hours_default}" true
    validate_uint "${hours}" && break
    warn "Informe um numero inteiro maior ou igual a zero."
  done
  while true; do
    prompt ratio "Ratio minimo" "${ratio_default}" true
    validate_decimal "${ratio}" && break
    warn "Informe um numero como 1, 1.0 ou 2.5."
  done

  if ((index >= 0)); then
    CATEGORIES[index]="${name}|${hours}|${ratio}"
  else
    CATEGORIES+=("${name}|${hours}|${ratio}")
  fi
}

categories_menu() {
  local choice index
  while true; do
    show_categories
    printf '%s[A]%s Adicionar   %s[E]%s Editar   %s[R]%s Remover   %s[C]%s Concluir\n' \
      "${GREEN}" "${RESET}" "${BLUE}" "${RESET}" "${RED}" "${RESET}" "${CYAN}" "${RESET}"
    prompt choice "Opcao" "A" true
    case "${choice,,}" in
      a) category_form ;;
      e)
        ((${#CATEGORIES[@]} > 0)) || { warn "Adicione uma categoria primeiro."; continue; }
        prompt index "Numero da categoria" "" true
        validate_uint "${index}" && ((index >= 1 && index <= ${#CATEGORIES[@]})) ||
          { warn "Numero invalido."; continue; }
        category_form "$((index - 1))"
        ;;
      r)
        ((${#CATEGORIES[@]} > 0)) || { warn "Nao ha categorias para remover."; continue; }
        prompt index "Numero da categoria" "" true
        validate_uint "${index}" && ((index >= 1 && index <= ${#CATEGORIES[@]})) ||
          { warn "Numero invalido."; continue; }
        unset 'CATEGORIES[index-1]'
        CATEGORIES=("${CATEGORIES[@]}")
        ;;
      c)
        ((${#CATEGORIES[@]} > 0)) || { warn "Configure pelo menos uma categoria."; continue; }
        return 0
        ;;
      *) warn "Opcao invalida." ;;
    esac
  done
}

collect_configuration() {
  local existing="$1" default_user default_host default_port default_url default_qbt_user default_password
  local default_storage default_low default_high default_pressure default_dry category_source

  default_user="$(default_service_user)"
  default_host="http://127.0.0.1"
  default_port="8080"
  default_qbt_user=""
  default_password=""
  default_storage=""
  default_low="10"
  default_high="15"
  default_pressure="true"
  default_dry="true"
  category_source="${CATEGORIES_FILE}"

  if [[ "${existing}" == "true" && -r "${CONFIG_FILE}" ]]; then
    default_url="$(safe_config_value QBT_URL)"
    split_qbt_url "${default_url}"
    default_host="${PARSED_QBT_HOST}"
    default_port="${PARSED_QBT_PORT}"
    default_qbt_user="$(safe_config_value QBT_USER)"
    default_password="$(safe_config_value QBT_PASS)"
    default_storage="$(safe_config_value STORAGE_PATH)"
    default_low="$(safe_config_value LOW_WATERMARK_PERCENT)"
    default_high="$(safe_config_value HIGH_WATERMARK_PERCENT)"
    default_pressure="$(safe_config_value DISK_PRESSURE_ENABLED)"
    default_dry="$(safe_config_value DRY_RUN)"
    category_source="$(safe_config_value CATEGORY_RULES_FILE)"
    [[ -r "${category_source}" ]] || category_source="${CATEGORIES_FILE}"
  fi

  printf '%s%s1. Servico e conexao%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  line
  while true; do
    prompt SERVICE_USER "Usuario Linux que executa o servico" "${default_user}" true
    id "${SERVICE_USER}" >/dev/null 2>&1 && break
    warn "Usuario Linux inexistente: ${SERVICE_USER}"
  done
  SERVICE_GROUP="$(id -gn "${SERVICE_USER}")"

  while true; do
    prompt QBT_HOST_VALUE "Endereco da Web UI (Enter usa localhost)" "${default_host}" true
    QBT_HOST_VALUE="${QBT_HOST_VALUE%/}"
    validate_host_url "${QBT_HOST_VALUE}" && break
    warn "Use esquema e host, sem porta ou caminho; exemplo: http://127.0.0.1"
  done
  while true; do
    prompt QBT_PORT_VALUE "Porta da Web UI" "${default_port}" true
    validate_port "${QBT_PORT_VALUE}" && break
    warn "Informe uma porta entre 1 e 65535."
  done
  QBT_URL_VALUE="${QBT_HOST_VALUE}:${QBT_PORT_VALUE}"
  prompt QBT_USER_VALUE "Usuario da Web UI" "${default_qbt_user}" true
  prompt_secret QBT_PASS_VALUE "Senha da Web UI" "${default_password}"

  printf '\n%s%s2. Armazenamento e seguranca%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  line
  ask_yes_no "Ativar limpeza agressiva sob pressao de disco?" \
    "$([[ "${default_pressure}" == "true" ]] && printf yes || printf no)"
  DISK_PRESSURE_VALUE="${REPLY_BOOL}"

  STORAGE_PATH_VALUE="${default_storage}"
  LOW_PERCENT="${default_low:-10}"
  HIGH_PERCENT="${default_high:-15}"
  if [[ "${DISK_PRESSURE_VALUE}" == "true" ]]; then
    while true; do
      prompt STORAGE_PATH_VALUE "Ponto de montagem que armazena os torrents" "${default_storage}" true
      [[ "${STORAGE_PATH_VALUE}" == /* && -d "${STORAGE_PATH_VALUE}" ]] && break
      warn "Informe um diretorio absoluto que ja exista."
    done
    while true; do
      prompt LOW_PERCENT "Percentual livre que ativa o modo agressivo" "${default_low:-10}" true
      prompt HIGH_PERCENT "Percentual livre que encerra o modo agressivo" "${default_high:-15}" true
      validate_percent_pair && break
      warn "Use 1-100 e mantenha o alvo final maior ou igual ao gatilho."
    done
  fi

  if [[ "${existing}" == "true" ]]; then
    ask_yes_no "Manter em simulacao (DRY_RUN)?" \
      "$([[ "${default_dry}" == "true" ]] && printf yes || printf no)"
    DRY_RUN_VALUE="${REPLY_BOOL}"
  else
    DRY_RUN_VALUE="true"
    info "Instalacoes novas sempre iniciam em DRY_RUN para impedir exclusoes acidentais."
  fi

  printf '\n%s%s3. Categorias%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  line
  load_categories "${category_source}"
  categories_menu
}

show_summary() {
  printf '\n%s%sResumo da configuracao%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  line
  printf '%-25s %s\n' "Usuario do servico:" "${SERVICE_USER} (${SERVICE_GROUP})"
  printf '%-25s %s\n' "Endereco do qBittorrent:" "${QBT_HOST_VALUE}"
  printf '%-25s %s\n' "Porta da Web UI:" "${QBT_PORT_VALUE}"
  printf '%-25s %s\n' "Usuario da Web UI:" "${QBT_USER_VALUE}"
  printf '%-25s %s\n' "Senha da Web UI:" "********"
  printf '%-25s %s\n' "Pressao de disco:" "${DISK_PRESSURE_VALUE}"
  if [[ "${DISK_PRESSURE_VALUE}" == "true" ]]; then
    printf '%-25s %s\n' "Armazenamento:" "${STORAGE_PATH_VALUE}"
    printf '%-25s %s%% -> %s%%\n' "Limites livres:" "${LOW_PERCENT}" "${HIGH_PERCENT}"
  fi
  printf '%-25s %s\n' "DRY_RUN:" "${DRY_RUN_VALUE}"
  printf '%-25s %s\n' "Categorias:" "${#CATEGORIES[@]}"
  printf '%-25s %s\n' "Executavel:" "${INSTALL_SCRIPT}"
  printf '%-25s %s\n' "Configuracao:" "${CONFIG_FILE}"
  line
}

print_assignment() {
  local key="$1" value="$2"
  printf '%s=' "${key}"
  printf '%q' "${value}"
  printf '\n'
}

replace_assignment() {
  local file="$1" key="$2" value="$3" temp found=false line_value
  temp="${file}.new"
  : > "${temp}"
  while IFS= read -r line_value || [[ -n "${line_value}" ]]; do
    if [[ "${line_value}" == "${key}="* ]]; then
      print_assignment "${key}" "${value}" >> "${temp}"
      found=true
    else
      printf '%s\n' "${line_value}" >> "${temp}"
    fi
  done < "${file}"
  [[ "${found}" == "true" ]] || print_assignment "${key}" "${value}" >> "${temp}"
  mv -- "${temp}" "${file}"
}

prepare_config() {
  local destination="$1" existing="$2"
  if [[ "${existing}" == "true" && -r "${CONFIG_FILE}" ]]; then
    cp -- "${CONFIG_FILE}" "${destination}"
  else
    cp -- "${SOURCE_ENV}" "${destination}"
  fi
  replace_assignment "${destination}" QBT_URL "${QBT_URL_VALUE}"
  replace_assignment "${destination}" QBT_USER "${QBT_USER_VALUE}"
  replace_assignment "${destination}" QBT_PASS "${QBT_PASS_VALUE}"
  replace_assignment "${destination}" CATEGORY_RULES_FILE "${CATEGORIES_FILE}"
  replace_assignment "${destination}" DRY_RUN "${DRY_RUN_VALUE}"
  replace_assignment "${destination}" STATE_FILE "${STATE_DIR}/state.json"
  replace_assignment "${destination}" LOCK_FILE "${STATE_DIR}/run.lock"
  replace_assignment "${destination}" DISK_PRESSURE_ENABLED "${DISK_PRESSURE_VALUE}"
  replace_assignment "${destination}" STORAGE_PATH "${STORAGE_PATH_VALUE}"
  replace_assignment "${destination}" LOW_WATERMARK_PERCENT "${LOW_PERCENT}"
  replace_assignment "${destination}" HIGH_WATERMARK_PERCENT "${HIGH_PERCENT}"
}

prepare_categories() {
  local destination="$1" entry
  {
    printf '# Gerenciado por qbit-autodelete-installer.\n'
    printf '# Formato: Categoria|retencao_minima_horas|ratio_minimo\n\n'
    for entry in "${CATEGORIES[@]}"; do
      printf '%s\n' "${entry}"
    done
  } > "${destination}"
}

prepare_service() {
  local destination="$1" content
  content="$(<"${SOURCE_SERVICE}")"
  content="${content//QBIT_SERVICE_USER/${SERVICE_USER}}"
  content="${content//QBIT_SERVICE_GROUP/${SERVICE_GROUP}}"
  content="${content//\/PATH\/TO\/qbit-autodelete.env/${CONFIG_FILE}}"
  content="${content//\/PATH\/TO\/qbit-autodelete/${INSTALL_SCRIPT}}"
  printf '%s\n' "${content}" > "${destination}"
}

create_backup() {
  local path copied=false stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="${BACKUP_ROOT}/${stamp}"
  for path in "$@"; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    if [[ "${copied}" == "false" ]]; then
      install -d -m 0700 "${BACKUP_DIR}"
      copied=true
    fi
    cp -a -- "${path}" "${BACKUP_DIR}/"
  done
  [[ "${copied}" == "false" ]] || info "Backup criado em ${BACKUP_DIR}"
}

validate_installed_config() {
  validate_config_as_user "${INSTALL_SCRIPT}" "${CONFIG_FILE}"
}

validate_config_as_user() {
  local script="$1" config="$2"
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "${SERVICE_USER}" -- "${script}" --config "${config}" --check-config
  else
    su -s /bin/bash "${SERVICE_USER}" -c \
      "$(printf '%q ' "${script}" --config "${config}" --check-config)"
  fi
}

validate_staged_config() {
  local config="$1" categories="$2" validation_config="${WORK_DIR}/validation.env"
  cp -- "${config}" "${validation_config}"
  replace_assignment "${validation_config}" CATEGORY_RULES_FILE "${categories}"
  install -m 0750 -o root -g "${SERVICE_GROUP}" "${SOURCE_SCRIPT}" "${WORK_DIR}/qbit-autodelete"
  chown root:"${SERVICE_GROUP}" "${WORK_DIR}" "${validation_config}" "${categories}"
  chmod 0750 "${WORK_DIR}"
  chmod 0640 "${validation_config}" "${categories}"
  validate_config_as_user "${WORK_DIR}/qbit-autodelete" "${validation_config}"
}

install_files() {
  local existing="$1"
  WORK_DIR="$(mktemp -d -t qbit-autodelete-install.XXXXXX)"
  prepare_config "${WORK_DIR}/qbit-autodelete.env" "${existing}"
  prepare_categories "${WORK_DIR}/qbit-autodelete.categories"
  prepare_service "${WORK_DIR}/qbit-autodelete.service"
  cp -- "${SOURCE_TIMER}" "${WORK_DIR}/qbit-autodelete.timer"

  # Valida tudo antes de parar o timer ou substituir a instalacao atual.
  validate_staged_config "${WORK_DIR}/qbit-autodelete.env" \
    "${WORK_DIR}/qbit-autodelete.categories"

  systemctl disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  create_backup "${INSTALL_SCRIPT}" "${CONFIG_FILE}" "${CATEGORIES_FILE}" "${SERVICE_FILE}" "${TIMER_FILE}"

  install -D -m 0755 -o root -g root "${SOURCE_SCRIPT}" "${INSTALL_SCRIPT}"
  install -D -m 0640 -o root -g "${SERVICE_GROUP}" "${WORK_DIR}/qbit-autodelete.env" "${CONFIG_FILE}"
  install -D -m 0644 -o root -g root "${WORK_DIR}/qbit-autodelete.categories" "${CATEGORIES_FILE}"
  install -D -m 0644 -o root -g root "${WORK_DIR}/qbit-autodelete.service" "${SERVICE_FILE}"
  install -D -m 0644 -o root -g root "${WORK_DIR}/qbit-autodelete.timer" "${TIMER_FILE}"

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${SERVICE_FILE}" "${TIMER_FILE}"
  fi
  systemctl daemon-reload
  validate_installed_config
  systemctl enable --now "${TIMER_NAME}"

  if [[ "${DRY_RUN_VALUE}" == "true" ]]; then
    if systemctl start "${SERVICE_NAME}"; then
      ok "Primeira simulacao concluida."
    else
      warn "A instalacao foi concluida, mas o primeiro acesso ao qBittorrent falhou."
      warn "Confira URL e credenciais com: journalctl -u ${SERVICE_NAME} -n 50"
    fi
  else
    info "Execucao manual nao iniciada porque DRY_RUN esta desativado."
  fi

  rm -rf -- "${WORK_DIR}"
  WORK_DIR=""
  ok "Instalacao concluida; o timer esta ativo."
  printf '\nComandos uteis:\n'
  printf '  systemctl status %s\n' "${TIMER_NAME}"
  printf '  journalctl -u %s -n 100 --no-pager\n' "${SERVICE_NAME}"
  printf '  sudo %s reconfigure\n' "${BASH_SOURCE[0]}"
}

install_flow() {
  require_tty
  require_root install
  require_assets
  require_systemd
  header
  install_dependencies
  local existing=false
  [[ -r "${CONFIG_FILE}" ]] && existing=true
  if [[ "${existing}" == "true" ]]; then
    warn "Uma configuracao existente foi encontrada e sera preservada como base."
  fi
  collect_configuration "${existing}"
  show_summary
  ask_yes_no "Confirmar instalacao?" yes
  [[ "${REPLY_BOOL}" == "true" ]] || die "instalacao cancelada"
  install_files "${existing}"
}

reconfigure_flow() {
  require_tty
  require_root reconfigure
  require_assets
  require_systemd
  [[ -r "${CONFIG_FILE}" ]] || die "instalacao nao encontrada; use install"
  header
  install_dependencies
  collect_configuration true
  show_summary
  ask_yes_no "Aplicar a nova configuracao?" yes
  [[ "${REPLY_BOOL}" == "true" ]] || die "reconfiguracao cancelada"
  install_files true
}

update_flow() {
  require_tty
  require_root update
  require_assets
  require_systemd
  [[ -r "${CONFIG_FILE}" && -r "${CATEGORIES_FILE}" ]] ||
    die "configuracao instalada nao encontrada; use install"
  header
  install_dependencies
  SERVICE_USER="$(default_service_user)"
  [[ -n "${SERVICE_USER}" ]] && id "${SERVICE_USER}" >/dev/null 2>&1 ||
    die "nao foi possivel determinar o usuario do servico"
  SERVICE_GROUP="$(id -gn "${SERVICE_USER}")"
  printf 'O script, o service e o timer serao atualizados.\n'
  printf 'O .env e as categorias serao preservados sem alteracao.\n\n'
  printf '%-22s %s\n' "Usuario:" "${SERVICE_USER}"
  printf '%-22s %s\n' "Executavel:" "${INSTALL_SCRIPT}"
  ask_yes_no "Continuar com a atualizacao?" yes
  [[ "${REPLY_BOOL}" == "true" ]] || die "atualizacao cancelada"

  WORK_DIR="$(mktemp -d -t qbit-autodelete-update.XXXXXX)"
  prepare_service "${WORK_DIR}/qbit-autodelete.service"
  install -m 0750 -o root -g "${SERVICE_GROUP}" "${SOURCE_SCRIPT}" "${WORK_DIR}/qbit-autodelete"
  chown root:"${SERVICE_GROUP}" "${WORK_DIR}"
  chmod 0750 "${WORK_DIR}"
  validate_config_as_user "${WORK_DIR}/qbit-autodelete" "${CONFIG_FILE}"
  systemctl disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  create_backup "${INSTALL_SCRIPT}" "${SERVICE_FILE}" "${TIMER_FILE}"
  install -D -m 0755 -o root -g root "${SOURCE_SCRIPT}" "${INSTALL_SCRIPT}"
  install -D -m 0644 -o root -g root "${WORK_DIR}/qbit-autodelete.service" "${SERVICE_FILE}"
  install -D -m 0644 -o root -g root "${SOURCE_TIMER}" "${TIMER_FILE}"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${SERVICE_FILE}" "${TIMER_FILE}"
  fi
  systemctl daemon-reload
  validate_installed_config
  systemctl enable --now "${TIMER_NAME}"
  rm -rf -- "${WORK_DIR}"
  WORK_DIR=""
  ok "Atualizacao concluida; configuracao e categorias foram preservadas."
}

status_flow() {
  header
  printf '%s%sArquivos%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  local path
  for path in "${INSTALL_SCRIPT}" "${CONFIG_FILE}" "${CATEGORIES_FILE}" "${SERVICE_FILE}" "${TIMER_FILE}"; do
    if [[ -e "${path}" ]]; then
      printf '  %s[OK]%s %s\n' "${GREEN}" "${RESET}" "${path}"
    else
      printf '  %s[--]%s %s\n' "${YELLOW}" "${RESET}" "${path}"
    fi
  done
  if [[ -x "${INSTALL_SCRIPT}" ]]; then
    printf '\nVersao: '
    "${INSTALL_SCRIPT}" --version || true
  fi
  if [[ -r "${CONFIG_FILE}" ]]; then
    printf 'DRY_RUN: %s\n' "$(awk -F= '/^DRY_RUN=/{print $2; exit}' "${CONFIG_FILE}")"
  fi
  printf '\n%s%sSystemd%s\n' "${CYAN}" "${BOLD}" "${RESET}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status "${TIMER_NAME}" "${SERVICE_NAME}" || true
  else
    warn "systemd nao encontrado."
  fi
}

uninstall_flow() {
  require_tty
  require_root uninstall
  require_systemd
  header
  warn "Isso remove o executavel e as units, mas nunca toca nos torrents."
  ask_yes_no "Desinstalar qbit-autodelete?" no
  [[ "${REPLY_BOOL}" == "true" ]] || die "desinstalacao cancelada"

  create_backup "${INSTALL_SCRIPT}" "${CONFIG_FILE}" "${CATEGORIES_FILE}" "${SERVICE_FILE}" "${TIMER_FILE}"
  systemctl disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  rm -f -- "${INSTALL_SCRIPT}" "${SERVICE_FILE}" "${TIMER_FILE}"

  ask_yes_no "Remover tambem .env e categorias?" no
  if [[ "${REPLY_BOOL}" == "true" ]]; then
    rm -f -- "${CONFIG_FILE}" "${CATEGORIES_FILE}"
  fi
  ask_yes_no "Apagar o historico de pontuacao em ${STATE_DIR}?" no
  if [[ "${REPLY_BOOL}" == "true" ]]; then
    rm -rf -- "${STATE_DIR}"
  fi
  systemctl daemon-reload
  systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
  ok "Desinstalacao concluida. Backup: ${BACKUP_DIR:-nenhum arquivo anterior}"
}

main_menu() {
  require_tty
  local choice
  while true; do
    header
    if [[ -x "${INSTALL_SCRIPT}" ]]; then
      printf '%sInstalacao detectada em %s%s\n\n' "${GREEN}" "${INSTALL_SCRIPT}" "${RESET}"
    else
      printf '%sNenhuma instalacao detectada.%s\n\n' "${YELLOW}" "${RESET}"
    fi
    printf '  %s1)%s Instalar / migrar configuracao existente\n' "${GREEN}" "${RESET}"
    printf '  %s2)%s Reconfigurar conexao, disco e categorias\n' "${BLUE}" "${RESET}"
    printf '  %s3)%s Atualizar script e units (preserva configuracao)\n' "${CYAN}" "${RESET}"
    printf '  %s4)%s Ver status\n' "${BOLD}" "${RESET}"
    printf '  %s5)%s Desinstalar\n' "${RED}" "${RESET}"
    printf '  %s0)%s Sair\n\n' "${DIM}" "${RESET}"
    prompt choice "Escolha" "1" true
    case "${choice}" in
      1) exec "${BASH_SOURCE[0]}" install ;;
      2) exec "${BASH_SOURCE[0]}" reconfigure ;;
      3) exec "${BASH_SOURCE[0]}" update ;;
      4) status_flow; pause_screen ;;
      5) exec "${BASH_SOURCE[0]}" uninstall ;;
      0) printf 'Ate logo.\n'; return 0 ;;
      *) warn "Opcao invalida."; pause_screen ;;
    esac
  done
}

main() {
  case "${1:-menu}" in
    menu) main_menu ;;
    install) install_flow ;;
    reconfigure) reconfigure_flow ;;
    update) update_flow ;;
    status) status_flow ;;
    uninstall) uninstall_flow ;;
    help|-h|--help) usage ;;
    version|-v|--version) printf 'qbit-autodelete-installer %s\n' "${INSTALLER_VERSION}" ;;
    *) usage >&2; die "acao desconhecida: $1" ;;
  esac
}

if [[ "${QBIT_AUTODELETE_INSTALLER_LIBRARY:-false}" != "true" ]]; then
  main "$@"
fi
