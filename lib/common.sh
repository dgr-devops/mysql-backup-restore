#!/usr/bin/env bash
# lib/common.sh — funciones compartidas por todos los scripts del toolkit.
# Se carga con: source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# No se ejecuta directamente.

# Librería: las constantes se usan desde los scripts que la cargan.
# shellcheck disable=SC2034

# Códigos de salida estándar (compatibles con los plugins de Nagios).
readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3
readonly EXIT_USAGE=64

# Colores solo si la salida es una terminal y NO_COLOR no está definido.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RED=$'\033[31m' C_YELLOW=$'\033[33m' C_GREEN=$'\033[32m' C_RESET=$'\033[0m'
else
  readonly C_RED="" C_YELLOW="" C_GREEN="" C_RESET=""
fi

# log <nivel> <mensaje...> — escribe en stderr con marca de hora.
log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

log_info() { log INFO "$*"; }
log_warn() { log "${C_YELLOW}WARN${C_RESET}" "$*"; }
log_error() { log "${C_RED}ERROR${C_RESET}" "$*"; }

# die <mensaje> [código] — error fatal: muestra el mensaje y sale.
die() {
  log_error "$1"
  exit "${2:-1}"
}

# require_cmd <comando...> — aborta si falta alguna dependencia.
require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Falta el comando requerido: $cmd"
  done
}

# is_uint <valor> — verdadero si es un entero no negativo.
is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# load_config — carga valores por defecto desde un fichero de configuración.
# Busca, por este orden: $TOOLKIT_CONF, ~/.config/toolkit.conf y /etc/toolkit.conf.
# El fichero NO se ejecuta: solo se leen líneas `TOOLKIT_NOMBRE=valor`.
# Una variable ya definida en el entorno tiene prioridad sobre el fichero.
load_config() {
  local file="" candidate line key value
  if [[ -n "${TOOLKIT_CONF:-}" ]]; then
    [[ -r "$TOOLKIT_CONF" ]] || die "No se puede leer la configuración: ${TOOLKIT_CONF}" "$EXIT_USAGE"
    file="$TOOLKIT_CONF"
  else
    for candidate in "${XDG_CONFIG_HOME:-${HOME:-}/.config}/toolkit.conf" /etc/toolkit.conf; do
      if [[ -r "$candidate" ]]; then
        file="$candidate"
        break
      fi
    done
  fi
  [[ -n "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(TOOLKIT_[A-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}" # quita espacios finales
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      if [[ -z "${!key+x}" ]]; then
        export "${key}=${value}"
      fi
    fi
  done <"$file"
}

# is_identifier <valor> — nombre de base de datos o tabla seguro (letras, números, _).
# Se valida antes de interpolarlo en SQL: aquí no hay consultas parametrizadas.
is_identifier() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_]{1,64}$ ]]
}
