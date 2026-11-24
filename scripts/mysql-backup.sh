#!/usr/bin/env bash
# mysql-backup.sh — copia lógica de una base MySQL: mysqldump + gzip + SHA-256 + rotación.
#
# Uso: mysql-backup.sh -d BASE [-o DIR] [-c FICHERO_OPCIONES] [-k COPIAS] [-a DIAS] [-h]
# Códigos de salida: 0 = OK, 1 = ya hay otra copia en curso, 2 = la copia falló,
#                    3 = no se puede ejecutar (falta comando, credenciales o conexión), 64 = uso incorrecto.
# Es el mismo convenio que los plugins de Nagios, así que se integra con monitorización.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/mysql.sh
source "${SCRIPT_DIR}/../lib/mysql.sh"

readonly DEFAULT_KEEP_COPIES=7
readonly DEFAULT_KEEP_DAYS=0 # 0 = no borrar por antigüedad
# Patrón del nombre: <base>_AAAAMMDD_HHMMSS.sql.gz (el orden alfabético es el cronológico).
readonly STAMP_REGEX='[0-9]{8}_[0-9]{6}'

PARTIAL_FILE=""

usage() {
  cat <<EOF
Uso: mysql-backup.sh -d BASE [-o DIR] [-c FICHERO_OPCIONES] [-k COPIAS] [-a DIAS] [-h]

Genera DIR/BASE_AAAAMMDD_HHMMSS.sql.gz y su suma DIR/BASE_AAAAMMDD_HHMMSS.sql.gz.sha256.
Usa mysqldump --single-transaction --routines --triggers --events (consistente en InnoDB).

Opciones:
  -d BASE   Base de datos a copiar            (o MYSQL_DATABASE)
  -o DIR    Directorio de copias              (o BACKUP_DIR; por defecto ./backups)
  -c FICH   Fichero de opciones del cliente   (o MYSQL_DEFAULTS_FILE) — evita poner la clave en la línea de comandos
  -k N      Conservar las N copias más recientes (o KEEP_COPIES; por defecto ${DEFAULT_KEEP_COPIES})
  -a DIAS   Borrar además las copias con más de DIAS días (o KEEP_DAYS; por defecto desactivado).
            La copia más reciente nunca se borra.
  -h        Muestra esta ayuda

Sin -c se usan MYSQL_HOST, MYSQL_PORT, MYSQL_USER y MYSQL_PWD del entorno.
Códigos de salida: 0 = OK, 1 = otra copia en curso, 2 = fallo, 3 = no ejecutable, 64 = uso incorrecto.
EOF
}

cleanup() {
  [[ -n "$PARTIAL_FILE" && -e "$PARTIAL_FILE" ]] && rm -f -- "$PARTIAL_FILE"
  return 0
}

# list_backups <dir> <base> — copias de la base, de la más antigua a la más reciente.
list_backups() {
  local dir="$1" db="$2" file name
  for file in "${dir}/${db}"_*.sql.gz; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file")"
    if [[ "$name" =~ ^${db}_${STAMP_REGEX}\.sql\.gz$ ]]; then
      printf '%s\n' "$file"
    fi
  done | sort
}

# remove_backup <fichero> — borra la copia y su suma.
remove_backup() {
  rm -f -- "$1" "${1}.sha256"
  log_info "Rotación: borrada $(basename "$1")"
}

# rotate <dir> <base> <copias> <dias> — aplica la política de retención.
# Se borra lo que sobre del límite de copias O supere los días indicados; la más reciente se conserva siempre.
rotate() {
  local dir="$1" db="$2" keep_copies="$3" keep_days="$4"
  local files=() file name stamp cutoff="" total i
  mapfile -t files < <(list_backups "$dir" "$db")
  total="${#files[@]}"
  ((total > 1)) || return 0

  if ((keep_days > 0)); then
    cutoff="$(date -d "-${keep_days} days" +%Y%m%d_%H%M%S)"
  fi

  for ((i = 0; i < total - 1; i++)); do
    file="${files[$i]}"
    name="$(basename "$file")"
    stamp="${name%.sql.gz}"
    stamp="${stamp#"${db}_"}"
    if ((total - i > keep_copies)) || { [[ -n "$cutoff" ]] && [[ "$stamp" < "$cutoff" ]]; }; then
      remove_backup "$file"
    fi
  done
}

# dump_database <base> <destino.partial> — mysqldump | gzip, con tubería que falla si falla cualquier extremo.
dump_database() {
  local db="$1" out="$2"
  mysqldump "${MYSQL_ARGS[@]}" \
    --single-transaction --routines --triggers --events \
    --no-tablespaces --hex-blob --default-character-set=utf8mb4 \
    "$db" | gzip -c >"$out"
}

main() {
  local db="${MYSQL_DATABASE:-}" dir="${BACKUP_DIR:-./backups}" defaults_file="${MYSQL_DEFAULTS_FILE:-}"
  local keep_copies="${KEEP_COPIES:-$DEFAULT_KEEP_COPIES}" keep_days="${KEEP_DAYS:-$DEFAULT_KEEP_DAYS}" opt
  while getopts ':d:o:c:k:a:h' opt; do
    case "$opt" in
      d) db="$OPTARG" ;;
      o) dir="$OPTARG" ;;
      c) defaults_file="$OPTARG" ;;
      k) keep_copies="$OPTARG" ;;
      a) keep_days="$OPTARG" ;;
      h) usage; exit "$EXIT_OK" ;;
      *) usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  shift $((OPTIND - 1))

  [[ -n "$db" ]] || { log_error "Falta la base de datos (-d)"; usage >&2; exit "$EXIT_USAGE"; }
  is_identifier "$db" || { log_error "Nombre de base no válido: '${db}' (solo letras, números y _)"; exit "$EXIT_USAGE"; }
  if ! is_uint "$keep_copies" || ((keep_copies < 1)); then
    log_error "-k debe ser un entero mayor o igual que 1 (recibido: '${keep_copies}')"
    exit "$EXIT_USAGE"
  fi
  is_uint "$keep_days" || { log_error "-a debe ser un entero mayor o igual que 0 (recibido: '${keep_days}')"; exit "$EXIT_USAGE"; }

  require_cmd mysql mysqldump gzip sha256sum flock date
  mysql_setup "$defaults_file"

  # Las copias contienen datos: solo legibles por el propietario.
  umask 077
  mkdir -p -- "$dir" || die "No se puede crear el directorio de copias: ${dir}" "$EXIT_UNKNOWN"

  # Un solo proceso a la vez por base: si cron solapa dos ejecuciones, la segunda se salta.
  exec 9>"${dir}/.${db}.lock"
  if ! flock -n 9; then
    log_warn "Ya hay una copia de '${db}' en curso (bloqueo ${dir}/.${db}.lock); se omite esta ejecución"
    exit "$EXIT_WARNING"
  fi

  local stamp name final started elapsed size
  stamp="$(date +%Y%m%d_%H%M%S)"
  name="${db}_${stamp}.sql.gz"
  final="${dir}/${name}"
  PARTIAL_FILE="${final}.partial"
  trap cleanup EXIT

  [[ ! -e "$final" ]] || die "Ya existe ${final}; espera un segundo entre copias" "$EXIT_CRITICAL"

  log_info "Copiando '${db}' en ${final}"
  started="$SECONDS"
  # Si algo falla, no se deja nunca un .sql.gz a medias: se escribe en .partial y se renombra al final.
  dump_database "$db" "$PARTIAL_FILE" || die "mysqldump falló para '${db}'" "$EXIT_CRITICAL"
  gzip --test -- "$PARTIAL_FILE" || die "El fichero comprimido no supera gzip --test" "$EXIT_CRITICAL"
  mv -- "$PARTIAL_FILE" "$final"
  # La suma lleva el nombre sin ruta: se puede verificar desde el directorio de copias o tras moverla.
  (cd "$dir" && sha256sum -- "$name" >"${name}.sha256")

  rotate "$dir" "$db" "$keep_copies" "$keep_days"

  elapsed=$((SECONDS - started))
  size="$(du -h -- "$final" | cut -f1)"
  log_info "OK: ${name} (${size}, ${elapsed} s)"
  printf '%s\n' "$final"
}

main "$@"
