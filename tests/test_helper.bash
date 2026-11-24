#!/usr/bin/env bash
# Utilidades comunes de los tests bats. Se carga con: load test_helper
#
# Los tests necesitan un MySQL 8 real (docker compose up -d --wait, o el servicio del CI).
# Variables: MYSQL_TEST_HOST (127.0.0.1), MYSQL_TEST_PORT (MYSQL_PORT de .env o 33306),
# MYSQL_TEST_PASSWORD (MYSQL_ROOT_PASSWORD de .env). Por defecto el cliente mysql/mysqldump
# se ejecuta en un contenedor (tests/shims); con MYSQL_TEST_NATIVE_CLIENT=1 se usa el del sistema.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export BACKUP="${REPO_ROOT}/scripts/mysql-backup.sh"
export RESTORE="${REPO_ROOT}/scripts/mysql-restore.sh"
export VERIFY="${REPO_ROOT}/scripts/mysql-verify-restore.sh"
export SAMPLE="${REPO_ROOT}/scripts/mysql-sample-data.sh"
export NO_COLOR=1

if [[ -z "${MYSQL_TEST_NATIVE_CLIENT:-}" ]]; then
  export PATH="${REPO_ROOT}/tests/shims:${PATH}"
fi

# load_env — lee .env si existe, sin pisar lo que ya venga del entorno.
load_env() {
  local line key value
  [[ -f "${REPO_ROOT}/.env" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    [[ -n "${!key:-}" ]] || export "${key}=${value}"
  done <"${REPO_ROOT}/.env"
}
load_env

export MYSQL_TEST_HOST="${MYSQL_TEST_HOST:-127.0.0.1}"
export MYSQL_TEST_PORT="${MYSQL_TEST_PORT:-${MYSQL_PORT:-33306}}"
export MYSQL_TEST_PASSWORD="${MYSQL_TEST_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"

# make_cnf <ruta> [clave] — fichero de opciones con permisos 600 (la clave nunca va en la línea de comandos).
make_cnf() {
  local path="$1" password="${2:-$MYSQL_TEST_PASSWORD}"
  (
    umask 077
    printf '[client]\nuser=root\npassword=%s\nhost=%s\nport=%s\n' \
      "$password" "$MYSQL_TEST_HOST" "$MYSQL_TEST_PORT" >"$path"
  )
}

# sql <sentencia> — ejecuta SQL como root y devuelve filas sin cabecera.
sql() {
  mysql --defaults-extra-file="$CNF" --batch --skip-column-names --execute="$1"
}

# require_mysql — falla con un mensaje claro si no hay servidor.
require_mysql() {
  if ! sql 'SELECT 1' >/dev/null 2>&1; then
    echo "No hay MySQL accesible en ${MYSQL_TEST_HOST}:${MYSQL_TEST_PORT}. Ejecuta: docker compose up -d --wait" >&2
    return 1
  fi
}

# new_db_name — nombre único para una base de pruebas.
new_db_name() {
  printf 'bats_%s_%s' "$$" "$RANDOM"
}

# drop_dbs_like <prefijo> — borra las bases de prueba de este proceso.
drop_dbs_like() {
  local db
  for db in $(sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE '${1}%'"); do
    sql "DROP DATABASE \`${db}\`" || true
  done
}

# count_rows <base> <tabla>
count_rows() {
  sql "SELECT COUNT(*) FROM \`$1\`.\`$2\`"
}

# fake_backup <dir> <base> <AAAAMMDD_HHMMSS> — copia vacía con su suma, para probar la rotación.
fake_backup() {
  local file="${1}/${2}_${3}.sql.gz"
  : >"$file"
  : >"${file}.sha256"
}
