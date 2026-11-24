#!/usr/bin/env bash
# lib/mysql.sh — conexión a MySQL compartida por los tres scripts.
# Se carga después de lib/common.sh. No se ejecuta directamente.
#
# Credenciales: NUNCA en la línea de comandos (se verían en `ps` y en el historial).
#   1) Fichero de opciones:  MYSQL_DEFAULTS_FILE=/etc/mysql-backup/backup.cnf  (recomendado)
#   2) Variables de entorno: MYSQL_HOST, MYSQL_PORT, MYSQL_USER y MYSQL_PWD

# Argumentos de conexión que se pasan a mysql y mysqldump (rellenado por mysql_setup).
MYSQL_ARGS=()

# mysql_setup <fichero-opciones|""> — prepara MYSQL_ARGS y comprueba que se puede conectar.
mysql_setup() {
  local defaults_file="${1:-}"
  MYSQL_ARGS=()

  if [[ -n "$defaults_file" ]]; then
    [[ -r "$defaults_file" ]] || die "No se puede leer el fichero de opciones: ${defaults_file}" "$EXIT_UNKNOWN"
    warn_if_permissive "$defaults_file"
    # --defaults-extra-file debe ser siempre la primera opción.
    MYSQL_ARGS+=("--defaults-extra-file=${defaults_file}")
  else
    [[ -n "${MYSQL_USER:-}" ]] ||
      die "Faltan credenciales: usa -c FICHERO o define MYSQL_USER y MYSQL_PWD" "$EXIT_UNKNOWN"
    MYSQL_ARGS+=("--host=${MYSQL_HOST:-127.0.0.1}" "--port=${MYSQL_PORT:-3306}" "--user=${MYSQL_USER}")
    # La contraseña, si existe, la lee el cliente de MYSQL_PWD; no se copia a ningún argumento.
  fi

  sql_query 'SELECT 1' >/dev/null 2>&1 ||
    die "No se puede conectar a MySQL (revisa host, puerto y credenciales)" "$EXIT_UNKNOWN"
}

# warn_if_permissive <fichero> — avisa si el fichero de credenciales lo puede leer otro usuario.
warn_if_permissive() {
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || echo 000)"
  if [[ "${mode: -2}" != "00" ]]; then
    log_warn "El fichero de opciones $1 tiene permisos ${mode}; debería ser 600"
  fi
}

# sql_query <sentencia> — ejecuta SQL y devuelve filas sin cabecera, separadas por tabulador.
# Lee de /dev/null para no consumir la entrada estándar de un bucle `while read` que la llame.
sql_query() {
  mysql "${MYSQL_ARGS[@]}" --batch --skip-column-names --execute="$1" </dev/null
}

# db_exists <base> — verdadero si la base existe.
db_exists() {
  local found
  found="$(sql_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$1'")" || return 1
  [[ "$found" == "1" ]]
}

# db_table_count <base> — número de tablas y vistas de la base.
db_table_count() {
  sql_query "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$1'"
}

# db_snapshot <base> — huella de la base: una línea por objeto, ordenada.
#   TABLE<TAB>nombre<TAB>filas | VIEW<TAB>nombre | ROUTINE<TAB>nombre | TRIGGER<TAB>nombre | EVENT<TAB>nombre
# Las filas se cuentan con COUNT(*) exacto (TABLE_ROWS de information_schema es solo una estimación).
db_snapshot() {
  local db="$1" table
  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    printf 'TABLE\t%s\t%s\n' "$table" "$(sql_query "SELECT COUNT(*) FROM \`${db}\`.\`${table}\`")"
  done < <(sql_query "SELECT TABLE_NAME FROM information_schema.TABLES
                      WHERE TABLE_SCHEMA = '${db}' AND TABLE_TYPE = 'BASE TABLE' ORDER BY 1")
  sql_query "SELECT 'VIEW', TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA = '${db}'
             UNION ALL SELECT 'ROUTINE', ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '${db}'
             UNION ALL SELECT 'TRIGGER', TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '${db}'
             UNION ALL SELECT 'EVENT', EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = '${db}'"
}

# verify_checksum <fichero> — comprueba <fichero>.sha256 (formato de sha256sum, ruta relativa).
verify_checksum() {
  local file="$1" sum_file="${1}.sha256"
  [[ -f "$sum_file" ]] || die "Falta el fichero de suma de comprobación: ${sum_file}" "$EXIT_CRITICAL"
  (cd "$(dirname "$file")" && sha256sum --check --status "$(basename "$sum_file")") ||
    die "La suma SHA-256 no coincide: la copia está corrupta o modificada (${file})" "$EXIT_CRITICAL"
}
