#!/usr/bin/env bash
# mysql-sample-data.sh — crea la base de ejemplo "tienda" con datos sintéticos de tamaño ajustable.
#
# Uso: mysql-sample-data.sh -d BASE [-n PEDIDOS] [-c FICHERO_OPCIONES] [-h]
# Códigos de salida: 0 = OK, 2 = fallo al cargar, 3 = no ejecutable, 64 = uso incorrecto.
# Proporción: PEDIDOS/10 clientes y 3 líneas por pedido. Los datos son aleatorios y no personales.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/mysql.sh
source "${SCRIPT_DIR}/../lib/mysql.sh"

readonly DEFAULT_ORDERS=1000
readonly MAX_ORDERS=50000000
readonly ITEMS_PER_ORDER=3
readonly SCHEMA_FILE="${SCRIPT_DIR}/../sample/schema.sql"

usage() {
  cat <<EOF
Uso: mysql-sample-data.sh -d BASE [-n PEDIDOS] [-c FICHERO_OPCIONES] [-h]

Crea la base BASE (debe estar vacía o no existir) con el esquema de sample/schema.sql
y PEDIDOS pedidos (por defecto ${DEFAULT_ORDERS}), PEDIDOS/10 clientes y ${ITEMS_PER_ORDER} líneas por pedido.

Opciones:
  -d BASE   Base de datos a crear
  -n N      Número de pedidos (entero entre 1000 y ${MAX_ORDERS})
  -c FICH   Fichero de opciones del cliente (o MYSQL_DEFAULTS_FILE)
  -h        Muestra esta ayuda
EOF
}

# load_rows <base> <pedidos> — inserta los datos con una tabla auxiliar de 0..999 y producto cartesiano.
load_rows() {
  local db="$1" orders="$2" customers=$(($2 / 10))
  mysql "${MYSQL_ARGS[@]}" "$db" <<SQL
SET SESSION foreign_key_checks = 0, unique_checks = 0;
-- MySQL no permite usar una tabla TEMPORARY dos veces en la misma consulta: tabla real, que se borra al final.
DROP TABLE IF EXISTS seq;
CREATE TABLE seq (i INT NOT NULL PRIMARY KEY);
INSERT INTO seq WITH RECURSIVE r (i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM r WHERE i < 999) SELECT i FROM r;

INSERT INTO customers (name, email, created_at)
SELECT CONCAT('Cliente ', n), CONCAT('cliente', n, '@example.invalid'), NOW() - INTERVAL MOD(n, 900) DAY
FROM (SELECT a.i + 1000 * b.i + 1000000 * c.i AS n FROM seq a, seq b, seq c
      WHERE c.i <= (${customers} - 1) DIV 1000000) t
WHERE n < ${customers};

INSERT INTO orders (customer_id, total, status, created_at, notes)
SELECT 1 + MOD(n, ${customers}), ROUND(RAND() * 500, 2), ELT(1 + MOD(n, 4), 'new', 'paid', 'shipped', 'cancelled'),
       NOW() - INTERVAL MOD(n, 365) DAY - INTERVAL MOD(n, 86400) SECOND, SUBSTRING(MD5(n), 1, 32)
FROM (SELECT a.i + 1000 * b.i + 1000000 * c.i AS n FROM seq a, seq b, seq c
      WHERE c.i <= (${orders} - 1) DIV 1000000) t
WHERE n < ${orders};

INSERT INTO order_items (order_id, sku, qty, price)
SELECT o.id, CONCAT('SKU-', LPAD(MOD(o.id * 7 + s.i, 100000), 8, '0')), 1 + MOD(o.id + s.i, 5), ROUND(RAND() * 100, 2)
FROM orders o JOIN seq s ON s.i < ${ITEMS_PER_ORDER};

DROP TABLE seq;
SQL
}

main() {
  local db="" orders="$DEFAULT_ORDERS" defaults_file="${MYSQL_DEFAULTS_FILE:-}" opt
  while getopts ':d:n:c:h' opt; do
    case "$opt" in
      d) db="$OPTARG" ;;
      n) orders="$OPTARG" ;;
      c) defaults_file="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ -n "$db" ]] || { log_error "Falta la base de datos (-d)"; usage >&2; exit "$EXIT_USAGE"; }
  is_identifier "$db" || { log_error "Nombre de base no válido: '${db}'"; exit "$EXIT_USAGE"; }
  if ! is_uint "$orders" || ((orders < 1000 || orders > MAX_ORDERS)); then
    log_error "-n debe ser un entero entre 1000 y ${MAX_ORDERS} (recibido: '${orders}')"
    exit "$EXIT_USAGE"
  fi

  require_cmd mysql
  mysql_setup "$defaults_file"

  if db_exists "$db" && (($(db_table_count "$db") > 0)); then
    die "La base '${db}' ya tiene tablas; usa otra o bórrala antes" "$EXIT_USAGE"
  fi

  local started="$SECONDS"
  sql_query "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4"
  log_info "Creando el esquema en '${db}'"
  mysql "${MYSQL_ARGS[@]}" "$db" <"$SCHEMA_FILE" || die "No se pudo cargar sample/schema.sql" "$EXIT_CRITICAL"
  log_info "Cargando ${orders} pedidos (puede tardar)"
  load_rows "$db" "$orders" || die "Falló la carga de datos" "$EXIT_CRITICAL"
  log_info "OK: base '${db}' lista en $((SECONDS - started)) s"
}

main "$@"
