#!/usr/bin/env bats
# Pruebas de scripts/mysql-restore.sh contra un MySQL 8 real.

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
  drop_dbs_like "bats_$$_"
}

setup() {
  TARGET_DB="$(new_db_name)"
}

# Copia la copia buena a un directorio propio del test para poder estropearla.
local_copy() {
  cp "$BACKUP_FILE" "$BACKUP_FILE.sha256" "$BATS_TEST_TMPDIR/"
  LOCAL_FILE="${BATS_TEST_TMPDIR}/$(basename "$BACKUP_FILE")"
}

@test "-h muestra la ayuda y sale con 0" {
  run "$RESTORE" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: mysql-restore.sh"* ]]
}

@test "sin -f o sin -d sale con 64" {
  run "$RESTORE" -f "$BACKUP_FILE" -c "$CNF"
  [ "$status" -eq 64 ]
}

@test "restaura en una base nueva con las mismas filas que el origen" {
  run "$RESTORE" -f "$BACKUP_FILE" -d "$TARGET_DB" -c "$CNF"
  [ "$status" -eq 0 ]
  for table in customers orders order_items audit_log; do
    [ "$(count_rows "$TARGET_DB" "$table")" = "$(count_rows "$SRC_DB" "$table")" ]
  done
  [ "$(count_rows "$TARGET_DB" orders)" -eq 1000 ]
}

@test "restaura rutinas, trigger y vista, y funcionan" {
  "$RESTORE" -f "$BACKUP_FILE" -d "$TARGET_DB" -c "$CNF" 2>/dev/null
  [ "$(sql "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${TARGET_DB}'")" -eq 2 ]
  [ "$(sql "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='${TARGET_DB}'")" -eq 1 ]
  [ "$(sql "SELECT \`${TARGET_DB}\`.fn_order_items(1)")" -eq 3 ]
  # El trigger restaurado dispara: cambiar el estado de un pedido escribe en audit_log.
  sql "UPDATE \`${TARGET_DB}\`.orders SET status='zzz' WHERE id=2"
  [ "$(sql "SELECT COUNT(*) FROM \`${TARGET_DB}\`.audit_log WHERE new_status='zzz'")" -eq 1 ]
}

@test "con la suma alterada no toca la base: sale con 2 y no crea el destino" {
  local_copy
  printf 'corrupcion' >>"$LOCAL_FILE"
  run "$RESTORE" -f "$LOCAL_FILE" -d "$TARGET_DB" -c "$CNF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SHA-256"* ]]
  [ "$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${TARGET_DB}'")" -eq 0 ]
}

@test "sin fichero .sha256 se niega a restaurar" {
  local_copy
  rm -f "${LOCAL_FILE}.sha256"
  run "$RESTORE" -f "$LOCAL_FILE" -d "$TARGET_DB" -c "$CNF"
  [ "$status" -eq 2 ]
  [[ "$output" == *"suma"* ]]
  [ "$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${TARGET_DB}'")" -eq 0 ]
}

@test "una base destino con tablas exige -y" {
  "$RESTORE" -f "$BACKUP_FILE" -d "$TARGET_DB" -c "$CNF" 2>/dev/null
  run "$RESTORE" -f "$BACKUP_FILE" -d "$TARGET_DB" -c "$CNF"
  [ "$status" -eq 64 ]
  [[ "$output" == *"-y"* ]]
}

@test "con -y restaura encima y recupera los datos borrados" {
  "$RESTORE" -f "$BACKUP_FILE" -d "$TARGET_DB" -c "$CNF" 2>/dev/null
  sql "DROP TABLE \`${TARGET_DB}\`.audit_log"
  run "$RESTORE" -f "$BACKUP_FILE" -d "$TARGET_DB" -c "$CNF" -y
  [ "$status" -eq 0 ]
  [ "$(count_rows "$TARGET_DB" audit_log)" -eq 0 ]
  [ "$(count_rows "$TARGET_DB" orders)" -eq 1000 ]
}

@test "un nombre de base destino peligroso se rechaza con 64" {
  run "$RESTORE" -f "$BACKUP_FILE" -d 'x`; DROP DATABASE mysql; --' -c "$CNF"
  [ "$status" -eq 64 ]
}

@test "una copia inexistente sale con 3" {
  run "$RESTORE" -f "${BATS_TEST_TMPDIR}/nada.sql.gz" -d "$TARGET_DB" -c "$CNF"
  [ "$status" -eq 3 ]
}
