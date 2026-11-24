#!/usr/bin/env bash
# mysql-verify-restore.sh — demuestra que una copia se puede restaurar: la vuelca en una base
# temporal, la compara con la base de origen y borra la temporal.
#
# Uso: mysql-verify-restore.sh -f COPIA.sql.gz -s BASE_ORIGEN [-c FICHERO_OPCIONES] [-h]
# Códigos de salida: 0 = coincide, 2 = no coincide o la restauración falló,
#                    3 = no se puede ejecutar (falta comando, credenciales o conexión), 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/mysql.sh
source "${SCRIPT_DIR}/../lib/mysql.sh"

TEMP_DB=""
WORK_DIR=""

usage() {
  cat <<EOF
Uso: mysql-verify-restore.sh -f COPIA.sql.gz -s BASE_ORIGEN [-c FICHERO_OPCIONES] [-h]

1. Restaura COPIA.sql.gz (con verificación de SHA-256) en una base temporal verify_<origen>_<fecha>_<pid>.
2. Compara con BASE_ORIGEN: lista de tablas, filas por tabla (COUNT(*) exacto), vistas,
   rutinas, triggers y eventos.
3. Borra la base temporal siempre, también si algo falla.

Si la base de origen sigue recibiendo escrituras, las filas pueden diferir legítimamente de la copia:
úsalo contra una réplica, una ventana sin tráfico o justo tras la copia.

Opciones:
  -f FICH   Copia a verificar (.sql.gz)
  -s BASE   Base de datos de origen con la que comparar
  -c FICH   Fichero de opciones del cliente (o MYSQL_DEFAULTS_FILE); sin él se usan MYSQL_USER y MYSQL_PWD
  -h        Muestra esta ayuda

Códigos de salida: 0 = coincide, 2 = no coincide o fallo, 3 = no ejecutable, 64 = uso incorrecto.
EOF
}

# cleanup — se ejecuta siempre al salir: borra los ficheros temporales y la base temporal
# (solo si la creó este script).
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  if [[ -n "$TEMP_DB" && "$TEMP_DB" == verify_* ]]; then
    sql_query "DROP DATABASE IF EXISTS \`${TEMP_DB}\`" >/dev/null 2>&1 ||
      log_warn "No se pudo borrar la base temporal '${TEMP_DB}'; bórrala a mano"
  fi
}

main() {
  local file="" source_db="" defaults_file="${MYSQL_DEFAULTS_FILE:-}" opt
  while getopts ':f:s:c:h' opt; do
    case "$opt" in
      f) file="$OPTARG" ;;
      s) source_db="$OPTARG" ;;
      c) defaults_file="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ -n "$file" && -n "$source_db" ]] || { log_error "Faltan -f y -s"; usage >&2; exit "$EXIT_USAGE"; }
  is_identifier "$source_db" || { log_error "Nombre de base no válido: '${source_db}'"; exit "$EXIT_USAGE"; }
  [[ -f "$file" ]] || die "No existe la copia: ${file}" "$EXIT_UNKNOWN"

  require_cmd mysql gzip sha256sum diff mktemp
  mysql_setup "$defaults_file"
  db_exists "$source_db" || die "La base de origen '${source_db}' no existe" "$EXIT_UNKNOWN"

  # El nombre temporal cabe en los 64 caracteres de MySQL aunque la base de origen sea larga.
  TEMP_DB="verify_${source_db:0:24}_$(date +%Y%m%d%H%M%S)_$$"
  trap cleanup EXIT

  local started="$SECONDS"
  log_info "Restaurando $(basename "$file") en la base temporal '${TEMP_DB}'"
  # El script de restauración verifica la suma antes de tocar nada; su código de salida se propaga.
  "${SCRIPT_DIR}/mysql-restore.sh" -f "$file" -d "$TEMP_DB" ${defaults_file:+-c "$defaults_file"} ||
    die "La restauración en '${TEMP_DB}' falló (ver mensajes anteriores)" "$EXIT_CRITICAL"
  (($(db_table_count "$TEMP_DB") > 0)) || die "La copia restaurada no contiene ninguna tabla" "$EXIT_CRITICAL"

  local expected actual
  WORK_DIR="$(mktemp -d)"
  expected="${WORK_DIR}/origen.txt" actual="${WORK_DIR}/restaurada.txt"
  db_snapshot "$source_db" | sort >"$expected"
  db_snapshot "$TEMP_DB" | sort >"$actual"

  if diff --unified=0 --label "origen:${source_db}" --label "restaurada" "$expected" "$actual" >&2; then
    log_info "OK: $(grep -c '^TABLE' "$expected") tablas y $(awk -F'\t' '$1=="TABLE"{s+=$3} END{print s+0}' "$expected") filas coinciden; verificado en $((SECONDS - started)) s"
  else
    die "La copia restaurada NO coincide con '${source_db}' (ver diferencias arriba)" "$EXIT_CRITICAL"
  fi
}

main "$@"
