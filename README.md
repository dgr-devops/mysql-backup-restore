# mysql-backup-restore

Copias de seguridad de MySQL **que se comprueban**: copia lógica con rotación, restauración que verifica la suma SHA-256 y una verificación que restaura de verdad en una base temporal y compara con el origen. Con tiempos de restauración medidos, no supuestos.

> Una copia que nunca se ha restaurado es una esperanza, no una copia.

## Qué hay

| Script | Qué hace |
|---|---|
| [`scripts/mysql-backup.sh`](scripts/mysql-backup.sh) | `mysqldump --single-transaction --routines --triggers --events` → gzip → SHA-256 → rotación. Nombre con fecha y hora, `flock` para no solapar ejecuciones. |
| [`scripts/mysql-restore.sh`](scripts/mysql-restore.sh) | Verifica la suma SHA-256 **antes** de tocar nada y restaura en la base indicada. Se niega a pisar una base con tablas sin `-y`. |
| [`scripts/mysql-verify-restore.sh`](scripts/mysql-verify-restore.sh) | Restaura en una base temporal, compara tablas, filas por tabla, vistas, rutinas, triggers y eventos con el origen, borra la temporal y sale con error si algo no coincide. |
| [`scripts/mysql-sample-data.sh`](scripts/mysql-sample-data.sh) | Genera una base de ejemplo de tamaño ajustable (datos sintéticos). |
| [`scripts/measure-restore.sh`](scripts/measure-restore.sh) | Genera, copia, restaura y cronometra. Origen de [la medición](docs/restauracion-cronometrada.md). |

Códigos de salida (convenio de los plugins de Nagios, el mismo que usa `bash-sysadmin-toolkit`): `0` OK · `1` otra copia en curso (se omite) · `2` fallo o no coincide · `3` no ejecutable (falta un comando, credenciales o conexión) · `64` uso incorrecto.

## Estrategia de copias

Este repositorio implementa **copias completas lógicas**. Lo que eso da y lo que no:

| | Copia completa lógica (`mysqldump`) | Copia + binlog (recuperación a un instante) |
|---|---|---|
| **RPO** (datos que puedes perder) | Hasta el intervalo entre copias: con una copia diaria, hasta 24 h | Segundos o minutos, hasta el último binlog que se haya conservado |
| **RTO** (lo que tardas en volver) | Lo que cueste restaurar el volcado (en la medición, ~65 s para 436 MB) | Restaurar la copia **más** reaplicar los binlogs hasta el instante elegido |
| **Qué permite** | Volver a la hora de la copia; mover datos entre versiones; inspeccionar el SQL | Volver a «el martes a las 11:03, justo antes del `DROP`» |
| **Coste operativo** | Bajo: un cron y espacio en disco | Medio: conservar binlogs, copiarlos fuera del servidor, practicar la recuperación |
| **Está en este repo** | Sí | **No** |

Límites que conviene tener claros:

- **El RPO de este repositorio es el intervalo entre copias.** Con el cron de ejemplo (diario a las 02:30), un fallo a las 23:00 pierde hasta 20 h de datos. Si eso no es aceptable, hay que añadir binlog; copiar con más frecuencia solo lo reduce a costa de carga.
- **Con binlog (`log_bin`, activado por defecto en MySQL 8) se puede recuperar a un instante** restaurando la última copia completa y reaplicando con `mysqlbinlog --stop-datetime=... | mysql`. Pero los binlogs hay que conservarlos y copiarlos fuera del servidor (`binlog_expire_logs_seconds` los borra), y esa recuperación es un procedimiento distinto que aquí **no está automatizado ni probado**. Se menciona para saber cuándo hace falta, no como funcionalidad.
- **El RTO lo domina la restauración, no la copia.** Restaurar tardó unas 5,5 veces lo que tardó copiar. Una copia lógica es razonable para bases de unos pocos GB; a partir de decenas de GB conviene una copia física (XtraBackup, instantáneas del volumen).
- **`--single-transaction` solo es consistente con InnoDB.** Con tablas MyISAM la copia no es coherente entre tablas.
- **Una copia en el mismo disco que la base no es una copia.** Falta enviarla a otro sitio (otro servidor, almacenamiento de objetos) y, si contiene datos personales, cifrarla. Queda fuera de este repositorio a propósito; las decisiones están en [docs/decisiones.md](docs/decisiones.md).
- **La suma SHA-256 detecta corrupción accidental, no manipulación**: está junto al fichero. Para eso haría falta firmar o guardar la suma en otro sistema.

## Uso

### Requisitos

`bash` 4+, `mysql` y `mysqldump` (cliente 8.x), `gzip`, `sha256sum`, `flock` (util-linux). Para las pruebas, además Docker, `bats` y `shellcheck`.

### Credenciales: nunca en la línea de comandos

Ningún script acepta una clave como argumento. Hay dos formas, en este orden de preferencia:

1. **Fichero de opciones** con permisos 600, fuera del repositorio (plantilla en [`deploy/backup.example.cnf`](deploy/backup.example.cnf), que también explica los privilegios mínimos del usuario de copias):

   ```bash
   sudo install -m 600 -o backup deploy/backup.example.cnf /etc/mysql-backup/backup.cnf
   # edita la clave; después:
   scripts/mysql-backup.sh -d tienda -c /etc/mysql-backup/backup.cnf
   ```

2. **Variables de entorno**: `MYSQL_USER`, `MYSQL_PWD`, `MYSQL_HOST`, `MYSQL_PORT`.

### Copia

```bash
scripts/mysql-backup.sh -d tienda -o /var/backups/mysql -c /etc/mysql-backup/backup.cnf -k 14 -a 30
```

`-k 14` conserva las 14 copias más recientes y `-a 30` borra además las de más de 30 días; la copia más reciente nunca se borra. Cada ejecución crea `tienda_AAAAMMDD_HHMMSS.sql.gz` y su `.sha256`, ambos con permisos 600.

### Restauración

```bash
scripts/mysql-restore.sh -f /var/backups/mysql/tienda_20261124_093116.sql.gz -d tienda_restaurada -c /etc/mysql-backup/backup.cnf
```

La copia no lleva el nombre de la base original, así que se puede restaurar con otro nombre. Si la base destino ya tiene tablas, hay que confirmarlo con `-y`.

### Verificación

```bash
scripts/mysql-verify-restore.sh -f /var/backups/mysql/tienda_20261124_093116.sql.gz -s tienda -c /etc/mysql-backup/backup.cnf
```

Pensado para ejecutarse justo después de la copia o una vez por semana. Si el origen recibe escrituras entre la copia y la verificación, las filas pueden diferir de forma legítima (ver [límites](docs/decisiones.md#8-verificar-es-restaurar-de-verdad-y-comparar)).

### Programación

- **cron:** [`deploy/mysql-backup.cron`](deploy/mysql-backup.cron): copia diaria y verificación semanal.
- **systemd:** [`deploy/mysql-backup@.service`](deploy/mysql-backup@.service) y [`deploy/mysql-backup@.timer`](deploy/mysql-backup@.timer): una instancia por base (`systemctl enable --now mysql-backup@tienda.timer`). El código de salida 1 («otra copia en curso») no marca el servicio como fallido.

Variables que entienden los scripts (también en [`.env.example`](.env.example)): `MYSQL_DEFAULTS_FILE`, `MYSQL_DATABASE`, `BACKUP_DIR`, `KEEP_COPIES`, `KEEP_DAYS`.

## Salida real

Capturada contra un MySQL 8.4 en Docker, con la base de ejemplo (20 000 pedidos; 82 000 filas en total). Las rutas se han acortado a `/var/backups/mysql`.

```text
$ scripts/mysql-backup.sh -d tienda -o /var/backups/mysql -c backup.cnf -k 7
2026-11-24 09:31:16 [INFO] Copiando 'tienda' en /var/backups/mysql/tienda_20261124_093116.sql.gz
2026-11-24 09:31:16 [INFO] OK: tienda_20261124_093116.sql.gz (1,3M, 0 s)
/var/backups/mysql/tienda_20261124_093116.sql.gz

$ ls -l /var/backups/mysql; cat /var/backups/mysql/*.sha256
-rw------- 1 backup backup 1298293 nov 24 09:31 tienda_20261124_093116.sql.gz
-rw------- 1 backup backup      96 nov 24 09:31 tienda_20261124_093116.sql.gz.sha256
4239983cb5375cdba20f9597a0255c440809ee9d205ab1ea089e5a0f470dd30e  tienda_20261124_093116.sql.gz

$ scripts/mysql-verify-restore.sh -f /var/backups/mysql/tienda_*.sql.gz -s tienda -c backup.cnf
2026-11-24 09:31:17 [INFO] Restaurando tienda_20261124_093116.sql.gz en la base temporal 'verify_tienda_20261124093117_399166'
2026-11-24 09:31:18 [INFO] Verificando SHA-256 de tienda_20261124_093116.sql.gz
2026-11-24 09:31:18 [INFO] Creando la base 'verify_tienda_20261124093117_399166'
2026-11-24 09:31:18 [INFO] Restaurando en 'verify_tienda_20261124093117_399166'
2026-11-24 09:31:20 [INFO] OK: restaurada en 'verify_tienda_20261124093117_399166' en 2 s
2026-11-24 09:31:25 [INFO] OK: 4 tablas y 82000 filas coinciden; verificado en 8 s

$ # se altera un byte de la copia y se intenta restaurar
$ scripts/mysql-restore.sh -f /var/backups/mysql/mala.sql.gz -d tienda_otra -c backup.cnf
2026-11-24 09:31:30 [INFO] Verificando SHA-256 de mala.sql.gz
2026-11-24 09:31:30 [ERROR] La suma SHA-256 no coincide: la copia está corrupta o modificada (/var/backups/mysql/mala.sql.gz)
$ echo $?
2
```

(Las 8 s de la verificación son sobre todo el arranque del cliente en contenedor de las pruebas, unos 0,4 s por consulta; ver [decisiones](docs/decisiones.md#10-los-tests-usan-un-mysql-real-y-el-cliente-oficial-en-contenedor).)

### Cuánto tarda restaurar

Medido en tres ejecuciones con 1 000 000 de pedidos (4,1 millones de filas, 436 MB en el servidor, volcado de 203 MB, copia de 58 MB):

| | Copia | Restauración |
|---|---|---|
| Media de 3 ejecuciones | 11,8 s | 64,8 s |

Detalle, entorno y límites de la medición en [docs/restauracion-cronometrada.md](docs/restauracion-cronometrada.md). Son números de un portátil con NVMe, no una promesa para otro servidor.

## Pruebas

Los tests (`bats`) usan un MySQL 8.4 **real**, no simulado:

```bash
cp .env.example .env              # marcador de posición; no es una clave real
docker compose up -d --wait       # MySQL 8.4 en 127.0.0.1:33306
shellcheck scripts/*.sh lib/*.sh tests/shims/mysql
bats tests                        # 35 pruebas
docker compose down -v
```

Cubren: copia y suma verificable, rutinas/trigger/vista en el volcado, permisos 600, que la clave no aparece en la salida ni en la copia, credenciales por entorno, clave incorrecta, rotación por copias y por días (sin tocar otras bases), `flock`, restauración con datos y trigger funcionando, copia alterada, ausencia de `.sha256`, base destino con tablas, nombres de base peligrosos, y verificación correcta y con diferencias (siempre borra la base temporal).

Por defecto el `mysql`/`mysqldump` de los tests se ejecuta en un contenedor oficial 8.4 (`tests/shims/`): el cliente del sistema puede ser MariaDB u otra versión. Con `MYSQL_TEST_NATIVE_CLIENT=1` se usa el instalado. El CI (`.github/workflows/ci.yml`) levanta un servicio MySQL 8.4, pasa shellcheck y ejecuta los mismos tests.

## Estructura

```text
scripts/    mysql-backup.sh, mysql-restore.sh, mysql-verify-restore.sh, mysql-sample-data.sh, measure-restore.sh
lib/        common.sh (logs, códigos de salida), mysql.sh (conexión, huella de la base, suma)
sample/     schema.sql de la base de ejemplo
tests/      *.bats, test_helper.bash, shims/ (cliente MySQL en contenedor)
deploy/     cron, unidad y temporizador de systemd, plantilla del fichero de opciones
docs/       decisiones.md, restauracion-cronometrada.md
```

## Qué se ha verificado y qué no

**Ejecutado de verdad:**

- `shellcheck scripts/*.sh lib/*.sh tests/shims/mysql`: sin avisos, en local y en el CI de GitHub.
- `bats tests`: 35 de 35 pruebas contra un MySQL 8.4 real, en local (Docker Compose) y en GitHub Actions (servicio `mysql:8.4`). Último resultado del CI: [verde](https://github.com/dgr-devops/mysql-backup-restore/actions).
- [Medición de restauración](docs/restauracion-cronometrada.md): 3 ejecuciones con 1 000 000 de pedidos; las tres restauraciones coincidieron con el origen.

**No verificado:**

- Los ejemplos de cron y systemd (`deploy/`) no se han instalado ni ejecutado; solo se comprobó su sintaxis.
- Los scripts no se han probado con el cliente `mysql` nativo del sistema ni con MySQL 8.0 o 9.x: las pruebas usan el cliente oficial 8.4 en contenedor.
- La recuperación a un instante con binlog no está implementada ni probada.
- Los tiempos de restauración son de un portátil con NVMe; no se han medido otros tamaños ni otro hardware.

## Qué no cubre

- Copia incremental, binlog y recuperación a un instante (ver [estrategia](#estrategia-de-copias)).
- Cifrado y envío fuera del servidor.
- Alertas propias: el código de salida y el syslog están pensados para engancharlos a Nagios, `OnFailure=` de systemd o el correo de cron.
- Réplicas, clústeres Galera/InnoDB Cluster, MySQL gestionado en la nube.

## Licencia

MIT. Ver [LICENSE](LICENSE).
