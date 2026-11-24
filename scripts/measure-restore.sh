#!/usr/bin/env bash
# measure-restore.sh — mide cuánto se tarda en copiar y restaurar una base de ejemplo del tamaño pedido.
#
# Uso: measure-restore.sh [-n PEDIDOS] [-c FICHERO_OPCIONES] [-o DIR] [-k] [-h]
# Genera la base, hace la copia, la restaura en otra base (con verificación de SHA-256) y compara.
# Imprime una tabla en Markdown con tamaños y segundos MEDIDOS; no estima nada.
# Códigos de salida: 0 = OK, 2 = fallo o la restauración no coincide, 3 = no ejecutable, 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/mysql.sh
source "${SCRIPT_DIR}/../lib/mysql.sh"

readonly DEFAULT_ORDERS=1000000
readonly SOURCE_DB="tienda_medicion"
readonly RESTORED_DB="tienda_medicion_restaurada"

usage() {
  cat <<EOF
Uso: measure-restore.sh [-n PEDIDOS] [-c FICHERO_OPCIONES] [-o DIR] [-k] [-h]

Opciones:
  -n N      Pedidos de la base de ejemplo (por defecto ${DEFAULT_ORDERS}; 10% de clientes y 3 líneas por pedido)
  -c FICH   Fichero de opciones del cliente (o MYSQL_DEFAULTS_FILE)
  -o DIR    Directorio para la copia (por defecto un directorio temporal que se borra)
  -k        Conservar las bases ${SOURCE_DB} y ${RESTORED_DB} al terminar
  -h        Muestra esta ayuda
EOF
}

# now — segundos con decimales (EPOCHREALTIME, bash 5).
now() { printf '%s' "${EPOCHREALTIME/,/.}"; }

# elapsed <inicio> — segundos transcurridos con dos decimales.
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }

# db_size_mb <base> — datos + índices según information_schema, en MB.
db_size_mb() {
  sql_query "SELECT ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 1)
             FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$1'"
}

KEEP=0
WORK_DIR=""
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  if ((KEEP == 0)); then
    sql_query "DROP DATABASE IF EXISTS \`${SOURCE_DB}\`" >/dev/null 2>&1 || true
    sql_query "DROP DATABASE IF EXISTS \`${RESTORED_DB}\`" >/dev/null 2>&1 || true
  fi
}

main() {
  local orders="$DEFAULT_ORDERS" defaults_file="${MYSQL_DEFAULTS_FILE:-}" out_dir="" opt
  while getopts ':n:c:o:kh' opt; do
    case "$opt" in
      n) orders="$OPTARG" ;;
      c) defaults_file="$OPTARG" ;;
      o) out_dir="$OPTARG" ;;
      k) KEEP=1 ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))
  is_uint "$orders" || { log_error "-n debe ser un entero (recibido: '${orders}')"; exit "$EXIT_USAGE"; }

  require_cmd mysql mysqldump gzip sha256sum awk
  mysql_setup "$defaults_file"
  trap cleanup EXIT
  sql_query "DROP DATABASE IF EXISTS \`${SOURCE_DB}\`"
  sql_query "DROP DATABASE IF EXISTS \`${RESTORED_DB}\`"

  if [[ -z "$out_dir" ]]; then
    WORK_DIR="$(mktemp -d)"
    out_dir="$WORK_DIR"
  fi
  local cnf_args=()
  [[ -z "$defaults_file" ]] || cnf_args=(-c "$defaults_file")

  local t server_version
  server_version="$(sql_query 'SELECT VERSION()')"

  # Coste fijo de arrancar el cliente (en las pruebas es un contenedor): se mide para poder descontarlo.
  t="$(now)"
  sql_query 'SELECT 1' >/dev/null
  local client_overhead
  client_overhead="$(elapsed "$t")"

  t="$(now)"
  "${SCRIPT_DIR}/mysql-sample-data.sh" -d "$SOURCE_DB" -n "$orders" "${cnf_args[@]}" >/dev/null 2>&1
  local t_generate
  t_generate="$(elapsed "$t")"

  local rows_total size_mb
  rows_total="$(sql_query "SELECT SUM(TABLE_ROWS) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${SOURCE_DB}'")"
  size_mb="$(db_size_mb "$SOURCE_DB")"

  t="$(now)"
  local backup_file
  backup_file="$("${SCRIPT_DIR}/mysql-backup.sh" -d "$SOURCE_DB" -o "$out_dir" "${cnf_args[@]}" 2>/dev/null)"
  local t_backup
  t_backup="$(elapsed "$t")"
  local gz_bytes sql_bytes
  gz_bytes="$(stat -c %s "$backup_file")"
  sql_bytes="$(gzip -dc "$backup_file" | wc -c)"

  t="$(now)"
  "${SCRIPT_DIR}/mysql-restore.sh" -f "$backup_file" -d "$RESTORED_DB" "${cnf_args[@]}" >/dev/null 2>&1
  local t_restore
  t_restore="$(elapsed "$t")"

  local matches="sí"
  [[ "$(db_snapshot "$SOURCE_DB" | sort)" == "$(db_snapshot "$RESTORED_DB" | sort)" ]] || matches="NO"

  cat <<EOF
| Dato | Valor |
|---|---|
| Servidor | MySQL ${server_version} |
| Pedidos / filas totales (estimación de information_schema) | ${orders} / ~${rows_total} |
| Tamaño en el servidor (datos + índices) | ${size_mb} MB |
| Volcado SQL sin comprimir | $(awk -v b="$sql_bytes" 'BEGIN { printf "%.1f", b / 1048576 }') MB |
| Copia .sql.gz | $(awk -v b="$gz_bytes" 'BEGIN { printf "%.1f", b / 1048576 }') MB |
| Generar los datos de ejemplo | ${t_generate} s |
| **Copia (mysqldump + gzip + SHA-256)** | **${t_backup} s** |
| **Restauración (verificar SHA-256 + gzip + mysql)** | **${t_restore} s** |
| Coste fijo de arrancar el cliente (una consulta vacía) | ${client_overhead} s |
| Tablas y filas idénticas tras restaurar | ${matches} |
EOF
  [[ "$matches" == "sí" ]] || die "La base restaurada no coincide con el origen" "$EXIT_CRITICAL"
}

main "$@"
