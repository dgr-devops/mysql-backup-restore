#!/usr/bin/env bash
# mysql-restore.sh — restaura una copia .sql.gz en una base destino, verificando antes su SHA-256.
#
# Uso: mysql-restore.sh -f COPIA.sql.gz -d BASE_DESTINO [-c FICHERO_OPCIONES] [-y] [-h]
# Códigos de salida: 0 = OK, 2 = suma incorrecta o restauración fallida,
#                    3 = no se puede ejecutar (falta comando, credenciales o conexión), 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/mysql.sh
source "${SCRIPT_DIR}/../lib/mysql.sh"

usage() {
  cat <<EOF
Uso: mysql-restore.sh -f COPIA.sql.gz -d BASE_DESTINO [-c FICHERO_OPCIONES] [-y] [-h]

1. Verifica COPIA.sql.gz contra COPIA.sql.gz.sha256 (si no coincide, no toca la base).
2. Comprueba la integridad del gzip.
3. Crea la base destino si no existe y vuelca la copia en ella.

La copia no incluye el nombre de la base original, así que se puede restaurar con otro nombre.

Opciones:
  -f FICH   Copia a restaurar (.sql.gz)
  -d BASE   Base de datos destino
  -c FICH   Fichero de opciones del cliente (o MYSQL_DEFAULTS_FILE); sin él se usan MYSQL_USER y MYSQL_PWD
  -y        Permitir restaurar sobre una base que ya tiene tablas (las tablas de la copia se reemplazan)
  -h        Muestra esta ayuda

Códigos de salida: 0 = OK, 2 = suma incorrecta o fallo, 3 = no ejecutable, 64 = uso incorrecto.
EOF
}

main() {
  local file="" db="" defaults_file="${MYSQL_DEFAULTS_FILE:-}" assume_yes=0 opt
  while getopts ':f:d:c:yh' opt; do
    case "$opt" in
      f) file="$OPTARG" ;;
      d) db="$OPTARG" ;;
      c) defaults_file="$OPTARG" ;;
      y) assume_yes=1 ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ -n "$file" && -n "$db" ]] || { log_error "Faltan -f y -d"; usage >&2; exit "$EXIT_USAGE"; }
  is_identifier "$db" || { log_error "Nombre de base no válido: '${db}' (solo letras, números y _)"; exit "$EXIT_USAGE"; }
  [[ -f "$file" ]] || die "No existe la copia: ${file}" "$EXIT_UNKNOWN"

  require_cmd mysql gzip sha256sum
  mysql_setup "$defaults_file"

  # La suma va primero: una copia corrupta no debe llegar a tocar la base.
  log_info "Verificando SHA-256 de $(basename "$file")"
  verify_checksum "$file"
  gzip --test -- "$file" || die "El fichero no supera gzip --test: ${file}" "$EXIT_CRITICAL"

  if db_exists "$db"; then
    local tables
    tables="$(db_table_count "$db")"
    if ((tables > 0 && assume_yes == 0)); then
      die "La base '${db}' ya tiene ${tables} tablas; usa -y para restaurar encima" "$EXIT_USAGE"
    fi
  else
    log_info "Creando la base '${db}'"
    sql_query "CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4" || die "No se pudo crear la base '${db}'" "$EXIT_CRITICAL"
  fi

  local started="$SECONDS"
  log_info "Restaurando en '${db}'"
  gzip -dc -- "$file" | mysql "${MYSQL_ARGS[@]}" --default-character-set=utf8mb4 "$db" ||
    die "La restauración falló (la base '${db}' puede estar incompleta)" "$EXIT_CRITICAL"
  log_info "OK: restaurada en '${db}' en $((SECONDS - started)) s"
}

main "$@"
