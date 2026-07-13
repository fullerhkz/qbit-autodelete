#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d -t qbit-installer-test.XXXXXX)"
trap 'rm -rf -- "${TEMP_ROOT}"' EXIT

export QBIT_AUTODELETE_INSTALLER_LIBRARY=true
export QBIT_INSTALL_SCRIPT="${TEMP_ROOT}/bin/qbit-autodelete"
export QBIT_CONFIG_FILE="${TEMP_ROOT}/etc/qbit-autodelete.env"
export QBIT_CATEGORIES_FILE="${TEMP_ROOT}/etc/qbit-autodelete.categories"
export QBIT_SERVICE_FILE="${TEMP_ROOT}/systemd/qbit-autodelete.service"
export QBIT_TIMER_FILE="${TEMP_ROOT}/systemd/qbit-autodelete.timer"
export QBIT_STATE_DIR="${TEMP_ROOT}/state"
export QBIT_BACKUP_ROOT="${TEMP_ROOT}/backup"

# shellcheck source=../install.sh
source "${TEST_ROOT}/install.sh"

fail() { printf 'FALHOU: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "esperado '$2', recebido '$1' ($3)"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "'$2' ausente em $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "'$2' ainda presente em $1"; }

mkdir -p "${TEMP_ROOT}/etc" "${TEMP_ROOT}/systemd" "${TEMP_ROOT}/storage"

SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
QBT_URL_VALUE="http://127.0.0.1:8080"
QBT_USER_VALUE="usuario de teste"
QBT_PASS_VALUE='senha com espaco $aspas" e ; ponto'
DRY_RUN_VALUE="true"
DISK_PRESSURE_VALUE="true"
STORAGE_PATH_VALUE="${TEMP_ROOT}/storage"
LOW_PERCENT="10"
HIGH_PERCENT="15"
CATEGORIES=("Filmes 4K|48|1.0" "Series|72|2.5")

prepare_config "${TEMP_ROOT}/new.env" false
prepare_categories "${TEMP_ROOT}/new.categories"
prepare_service "${TEMP_ROOT}/systemd/qbit-autodelete.service"
cp "${SOURCE_TIMER}" "${TEMP_ROOT}/systemd/qbit-autodelete.timer"

(
  set +u
  # shellcheck source=/dev/null
  source "${TEMP_ROOT}/new.env"
  assert_eq "${QBT_URL}" "${QBT_URL_VALUE}" "URL gerada"
  assert_eq "${QBT_USER}" "${QBT_USER_VALUE}" "usuario com espaco"
  assert_eq "${QBT_PASS}" "${QBT_PASS_VALUE}" "senha com caracteres especiais"
  assert_eq "${CATEGORY_RULES_FILE}" "${CATEGORIES_FILE}" "arquivo de categorias"
  assert_eq "${STATE_FILE}" "${STATE_DIR}/state.json" "arquivo de estado"
  assert_eq "${LOCK_FILE}" "${STATE_DIR}/run.lock" "arquivo de lock"
  assert_eq "${STORAGE_PATH}" "${STORAGE_PATH_VALUE}" "volume"
)

assert_contains "${TEMP_ROOT}/new.categories" "Filmes 4K|48|1.0"
assert_contains "${TEMP_ROOT}/new.categories" "Series|72|2.5"
assert_contains "${TEMP_ROOT}/systemd/qbit-autodelete.service" "User=${SERVICE_USER}"
assert_contains "${TEMP_ROOT}/systemd/qbit-autodelete.service" "Group=${SERVICE_GROUP}"
assert_contains "${TEMP_ROOT}/systemd/qbit-autodelete.service" \
  "ExecStart=${INSTALL_SCRIPT} --config ${CONFIG_FILE}"
assert_not_contains "${TEMP_ROOT}/systemd/qbit-autodelete.service" "QBIT_SERVICE_USER"
assert_not_contains "${TEMP_ROOT}/systemd/qbit-autodelete.service" "/PATH/TO/"

# Reconfigurar deve trocar apenas os campos gerenciados e preservar opcoes avancadas.
cp "${TEMP_ROOT}/new.env" "${CONFIG_FILE}"
printf '\nCUSTOM_POLICY=preservar\n' >> "${CONFIG_FILE}"
QBT_PASS_VALUE='nova senha !@# $HOME'
prepare_config "${TEMP_ROOT}/reconfigured.env" true
assert_contains "${TEMP_ROOT}/reconfigured.env" "CUSTOM_POLICY=preservar"
(
  set +u
  # shellcheck source=/dev/null
  source "${TEMP_ROOT}/reconfigured.env"
  assert_eq "${QBT_PASS}" "${QBT_PASS_VALUE}" "senha reconfigurada"
  assert_eq "${CUSTOM_POLICY}" "preservar" "opcao avancada preservada"
)

validate_url "http://localhost:8080" || fail "URL localhost valida foi rejeitada"
! validate_url "localhost:8080/path" || fail "URL sem esquema/caminho foi aceita"
LOW_PERCENT=10 HIGH_PERCENT=15 validate_percent_pair || fail "percentuais validos rejeitados"
! (LOW_PERCENT=20 HIGH_PERCENT=10 validate_percent_pair) || fail "alvo menor que gatilho foi aceito"

printf 'OK: geracao segura, categorias, unit e reconfiguracao validadas\n'
