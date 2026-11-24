#!/usr/bin/env bats
# Pruebas de scripts/mysql-verify-restore.sh contra un MySQL 8 real.

load test_helper

setup_file() {
  export CNF="${BATS_FILE_TMPDIR}/root.cnf"
  make_cnf "$CNF"
  require_mysql
  export SRC_DB BACKUP_FILE
  SRC_DB="$(new_db_name)"
  "$SAMPLE" -d "$SRC_DB" -n 1000 -c "$CNF" >/dev/null 2>&1
  "$BACKUP" -d "$SRC_DB" -o "${BATS_FILE_TMPDIR}/backups" -c "$CNF" >/dev/null 2>&1
  BACKUP_FILE="$(ls "${BATS_FILE_TMPDIR}"/backups/*.sql.gz)"
}

teardown_file() {
  drop_dbs_like "verify_bats_$(run_tag)_"
  drop_dbs_like "bats_$(run_tag)_"
}

# temp_dbs — bases temporales que haya dejado el verificador para este origen.
temp_dbs() {
  sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'verify\\_${1}%'"
}

@test "-h muestra la ayuda y sale con 0" {
  run "$VERIFY" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: mysql-verify-restore.sh"* ]]
}

@test "sin -f o sin -s sale con 64" {
  run "$VERIFY" -f "$BACKUP_FILE" -c "$CNF"
  [ "$status" -eq 64 ]
}

@test "una copia correcta coincide con el origen: sale con 0 y borra la base temporal" {
  run "$VERIFY" -f "$BACKUP_FILE" -s "$SRC_DB" -c "$CNF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"coinciden"* ]]
  [ "$(temp_dbs "$SRC_DB")" -eq 0 ]
}

@test "informa del número de tablas y filas comparadas" {
  run "$VERIFY" -f "$BACKUP_FILE" -s "$SRC_DB" -c "$CNF"
  [ "$status" -eq 0 ]
  # 4 tablas; 100 clientes + 1000 pedidos + 3000 líneas + 0 de auditoría.
  [[ "$output" == *"4 tablas y 4100 filas"* ]]
}

@test "si el origen ha cambiado sale con 2, muestra la diferencia y borra la temporal" {
  drift_db="$(new_db_name)"
  "$SAMPLE" -d "$drift_db" -n 1000 -c "$CNF" >/dev/null 2>&1
  "$BACKUP" -d "$drift_db" -o "${BATS_TEST_TMPDIR}/b" -c "$CNF" >/dev/null 2>&1
  sql "INSERT INTO \`${drift_db}\`.audit_log (order_id, old_status, new_status, changed_at) VALUES (1,'a','b',NOW())"
  run "$VERIFY" -f "$(ls "${BATS_TEST_TMPDIR}"/b/*.sql.gz)" -s "$drift_db" -c "$CNF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"audit_log"* ]]
  [[ "$output" == *"NO coincide"* ]]
  [ "$(temp_dbs "$drift_db")" -eq 0 ]
}

@test "si falta una tabla en el origen sale con 2" {
  drift_db="$(new_db_name)"
  "$SAMPLE" -d "$drift_db" -n 1000 -c "$CNF" >/dev/null 2>&1
  "$BACKUP" -d "$drift_db" -o "${BATS_TEST_TMPDIR}/b" -c "$CNF" >/dev/null 2>&1
  sql "DROP TABLE \`${drift_db}\`.audit_log"
  run "$VERIFY" -f "$(ls "${BATS_TEST_TMPDIR}"/b/*.sql.gz)" -s "$drift_db" -c "$CNF"
  [ "$status" -eq 2 ]
  [ "$(temp_dbs "$drift_db")" -eq 0 ]
}

@test "una copia con la suma alterada sale con 2 y no deja base temporal" {
  cp "$BACKUP_FILE" "$BACKUP_FILE.sha256" "$BATS_TEST_TMPDIR/"
  bad="${BATS_TEST_TMPDIR}/$(basename "$BACKUP_FILE")"
  printf 'x' >>"$bad"
  run "$VERIFY" -f "$bad" -s "$SRC_DB" -c "$CNF"
  [ "$status" -eq 2 ]
  [ "$(temp_dbs "$SRC_DB")" -eq 0 ]
}

@test "una base de origen inexistente sale con 3" {
  run "$VERIFY" -f "$BACKUP_FILE" -s no_existe_esta_base -c "$CNF"
  [ "$status" -eq 3 ]
}
