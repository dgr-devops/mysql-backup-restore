#!/usr/bin/env bats
# Pruebas de scripts/mysql-backup.sh contra un MySQL 8 real.

load test_helper

setup_file() {
  export CNF="${BATS_FILE_TMPDIR}/root.cnf"
  make_cnf "$CNF"
  require_mysql
  export SRC_DB
  SRC_DB="$(new_db_name)"
  "$SAMPLE" -d "$SRC_DB" -n 1000 -c "$CNF" >/dev/null 2>&1
}

teardown_file() {
  drop_dbs_like "bats_$$_"
}

setup() {
  OUT_DIR="${BATS_TEST_TMPDIR}/backups"
}

@test "-h muestra la ayuda y sale con 0" {
  run "$BACKUP" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: mysql-backup.sh"* ]]
}

@test "sin base de datos sale con 64" {
  run "$BACKUP" -o "$OUT_DIR" -c "$CNF"
  [ "$status" -eq 64 ]
}

@test "un nombre de base con caracteres peligrosos se rechaza con 64" {
  run "$BACKUP" -d 'x; DROP DATABASE mysql' -o "$OUT_DIR" -c "$CNF"
  [ "$status" -eq 64 ]
}

@test "crea la copia .sql.gz y su suma SHA-256 verificable" {
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF"
  [ "$status" -eq 0 ]
  file="$(ls "$OUT_DIR"/"${SRC_DB}"_*.sql.gz)"
  [ -s "$file" ]
  [ -s "${file}.sha256" ]
  gzip --test "$file"
  (cd "$OUT_DIR" && sha256sum --check --status "$(basename "$file").sha256")
}

@test "el nombre lleva marca de tiempo AAAAMMDD_HHMMSS" {
  "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" 2>/dev/null
  [[ "$(basename "$(ls "$OUT_DIR"/*.sql.gz)")" =~ ^${SRC_DB}_[0-9]{8}_[0-9]{6}\.sql\.gz$ ]]
}

@test "la copia incluye rutinas, trigger y vista (--routines --triggers)" {
  "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" 2>/dev/null
  dump="$(gzip -dc "$OUT_DIR"/*.sql.gz)"
  [[ "$dump" == *"CREATE"*"PROCEDURE"*"sp_customer_orders"* ]]
  [[ "$dump" == *"CREATE"*"FUNCTION"*"fn_order_items"* ]]
  [[ "$dump" == *"TRIGGER"*"trg_orders_status_audit"* ]]
  [[ "$dump" == *"v_customer_totals"* ]]
}

@test "la copia no es legible por otros usuarios (permisos 600)" {
  "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" 2>/dev/null
  [ "$(stat -c %a "$(ls "$OUT_DIR"/*.sql.gz)")" = "600" ]
}

@test "la clave no aparece en la salida ni en la copia" {
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$MYSQL_TEST_PASSWORD"* ]]
  ! gzip -dc "$OUT_DIR"/*.sql.gz | grep -qF -- "$MYSQL_TEST_PASSWORD"
}

@test "los scripts no pasan la clave por línea de comandos (ni --password ni -pCLAVE)" {
  ! grep -nE -- '(--password|[[:space:]]-p[^[:space:]])' "$BACKUP" "$RESTORE" "$VERIFY" "${REPO_ROOT}"/lib/mysql.sh
}

@test "funciona con credenciales por entorno (MYSQL_USER y MYSQL_PWD) sin fichero de opciones" {
  MYSQL_HOST="$MYSQL_TEST_HOST" MYSQL_PORT="$MYSQL_TEST_PORT" MYSQL_USER=root MYSQL_PWD="$MYSQL_TEST_PASSWORD" \
    run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ -s "$(ls "$OUT_DIR"/*.sql.gz)" ]
}

@test "una clave incorrecta sale con 3 y no deja ficheros" {
  make_cnf "${BATS_TEST_TMPDIR}/mala.cnf" "clave-equivocada"
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "${BATS_TEST_TMPDIR}/mala.cnf"
  [ "$status" -eq 3 ]
  [ -z "$(ls "$OUT_DIR"/*.sql.gz 2>/dev/null)" ]
}

@test "una base inexistente falla con 2 sin dejar .partial ni .sql.gz" {
  run "$BACKUP" -d no_existe_esta_base -o "$OUT_DIR" -c "$CNF"
  [ "$status" -eq 2 ]
  [ -z "$(ls "$OUT_DIR"/*.sql.gz "$OUT_DIR"/*.partial 2>/dev/null)" ]
}

@test "rotación por copias: conserva las N más recientes y borra también la suma" {
  mkdir -p "$OUT_DIR"
  for stamp in 20200101_000000 20200102_000000 20200103_000000 20200104_000000 20200105_000000; do
    fake_backup "$OUT_DIR" "$SRC_DB" "$stamp"
  done
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" -k 3
  [ "$status" -eq 0 ]
  [ "$(ls "$OUT_DIR"/*.sql.gz | wc -l)" -eq 3 ]
  [ ! -e "$OUT_DIR/${SRC_DB}_20200101_000000.sql.gz" ]
  [ ! -e "$OUT_DIR/${SRC_DB}_20200101_000000.sql.gz.sha256" ]
  [ -e "$OUT_DIR/${SRC_DB}_20200105_000000.sql.gz" ]
  [ -e "$OUT_DIR/${SRC_DB}_20200104_000000.sql.gz" ]
}

@test "rotación por días: borra las antiguas y conserva las recientes" {
  mkdir -p "$OUT_DIR"
  fake_backup "$OUT_DIR" "$SRC_DB" 20200101_000000
  recent="$(date -d '-2 days' +%Y%m%d_%H%M%S)"
  fake_backup "$OUT_DIR" "$SRC_DB" "$recent"
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" -k 50 -a 30
  [ "$status" -eq 0 ]
  [ ! -e "$OUT_DIR/${SRC_DB}_20200101_000000.sql.gz" ]
  [ -e "$OUT_DIR/${SRC_DB}_${recent}.sql.gz" ]
  [ "$(ls "$OUT_DIR"/*.sql.gz | wc -l)" -eq 2 ]
}

@test "la rotación no toca copias de otra base con prefijo parecido" {
  mkdir -p "$OUT_DIR"
  fake_backup "$OUT_DIR" "${SRC_DB}_otra" 20200101_000000
  fake_backup "$OUT_DIR" "ajena" 20200101_000000
  fake_backup "$OUT_DIR" "$SRC_DB" 20200101_000000
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" -k 1
  [ "$status" -eq 0 ]
  [ -e "$OUT_DIR/${SRC_DB}_otra_20200101_000000.sql.gz" ]
  [ -e "$OUT_DIR/ajena_20200101_000000.sql.gz" ]
  [ ! -e "$OUT_DIR/${SRC_DB}_20200101_000000.sql.gz" ]
}

@test "-k 0 se rechaza con 64" {
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF" -k 0
  [ "$status" -eq 64 ]
}

@test "con otra copia en curso (flock) sale con 1 sin copiar" {
  mkdir -p "$OUT_DIR"
  ready="${BATS_TEST_TMPDIR}/ready"
  ( flock -n 9 && : >"$ready" && sleep 20 ) 9>"$OUT_DIR/.${SRC_DB}.lock" &
  holder=$!
  for _ in $(seq 1 50); do [ -e "$ready" ] && break; sleep 0.1; done
  [ -e "$ready" ]
  run "$BACKUP" -d "$SRC_DB" -o "$OUT_DIR" -c "$CNF"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"en curso"* ]]
  [ -z "$(ls "$OUT_DIR"/*.sql.gz 2>/dev/null)" ]
}
