# Decisiones de diseño

Cada decisión, con la alternativa descartada y el motivo. Sirve para defender el diseño en una entrevista y para que quien herede el repositorio sepa qué se puede cambiar sin romper nada.

## 1. Copia lógica (`mysqldump`) y no física

**Decisión:** `mysqldump --single-transaction --routines --triggers --events`.

**Alternativas:** Percona XtraBackup / MySQL Enterprise Backup (copia física), instantáneas del volumen (LVM/ZFS/btrfs).

**Motivo:** para bases de unos pocos GB, que es lo que cubre este repositorio, la copia lógica es portable entre versiones, se puede inspeccionar con `zcat`, se restaura con el cliente estándar y no exige instalar nada más. El precio es el tiempo de restauración: reconstruir los índices es lo que más pesa (ver [la medición](restauracion-cronometrada.md)). A partir de varias decenas de GB la restauración lógica deja de caber en un RTO razonable y conviene una copia física.

**Límite honesto:** `--single-transaction` solo da una vista consistente con tablas InnoDB. Las tablas MyISAM se copian sin consistencia entre sí. Para mezclas de motores habría que usar `--lock-all-tables`, que bloquea escrituras durante toda la copia.

## 2. Credenciales solo por fichero de opciones o por entorno

**Decisión:** `--defaults-extra-file` (recomendado) o `MYSQL_USER` + `MYSQL_PWD`. Ninguna opción de los scripts acepta una clave.

**Alternativa descartada:** `-p<clave>` o `--password=<clave>`.

**Motivo:** una clave en la línea de comandos es visible para cualquier usuario con `ps`, se queda en el historial del shell y suele acabar en logs de cron. El fichero de opciones va con permisos 600 fuera del repositorio; los scripts avisan si lo ven más abierto. `MYSQL_PWD` está desaconsejado por MySQL (el entorno de un proceso lo puede leer su propietario y root), pero no aparece en `ps` y es práctico para contenedores y CI; por eso es la segunda opción y no la primera. Un test comprueba que ningún script usa `--password` ni `-pCLAVE`.

## 3. Escribir en `.partial` y renombrar al final

**Decisión:** el volcado se escribe en `<nombre>.sql.gz.partial`, se prueba con `gzip --test` y solo entonces se renombra y se calcula la suma.

**Motivo:** si la copia se corta (disco lleno, `kill`, error de `mysqldump`), no queda un `.sql.gz` truncado que parezca una copia válida y que la rotación podría contar como tal. Un `trap` borra el `.partial` al salir. Con `pipefail`, un fallo de `mysqldump` dentro de la tubería hacia `gzip` se detecta; sin él, `gzip` terminaría con éxito y el fallo pasaría inadvertido.

## 4. Suma SHA-256 con ruta relativa

**Decisión:** `<copia>.sql.gz.sha256` contiene `hash  nombre.sql.gz`, sin ruta.

**Motivo:** se verifica con `sha256sum -c` desde el directorio donde esté la copia, también después de moverla a otro servidor o a un almacenamiento externo. La restauración la comprueba **antes** de tocar la base y se niega a continuar si falta la suma. No hay opción para saltársela: una copia sin suma no se puede distinguir de una corrupta.

**Límite honesto:** la suma detecta corrupción accidental. Si un atacante puede modificar la copia, también puede modificar la suma que está a su lado; para eso haría falta firmar (GPG) o guardar las sumas en otro sistema.

## 5. `flock` por base de datos

**Decisión:** bloqueo no bloqueante sobre `<directorio>/.<base>.lock`. Si ya hay una copia en curso, sale con código 1 (aviso) y no hace nada.

**Alternativa descartada:** esperar a que acabe la anterior.

**Motivo:** si una copia tarda más que el intervalo de cron, esperar apila procesos y satura el disco. Saltar la ejecución y avisar es lo que haría un operador. El bloqueo lo libera el sistema operativo si el proceso muere, así que no hay ficheros PID huérfanos que limpiar. En systemd, el código 1 figura en `SuccessExitStatus` para que no marque el servicio como fallido.

## 6. Rotación por número de copias y, opcionalmente, por días

**Decisión:** `-k N` conserva las N más recientes; `-a DIAS` borra además las más antiguas que ese plazo. Se borra lo que incumpla cualquiera de las dos, **salvo la copia más reciente, que nunca se borra**.

**Motivo:** solo por días, una parada larga del servidor (o un reloj roto) borraría todas las copias y no dejaría ninguna. La edad se deduce del nombre (`AAAAMMDD_HHMMSS`) y no de `mtime`, porque `mtime` cambia al copiar o restaurar ficheros y haría la rotación impredecible. El patrón del nombre es estricto (`^<base>_<fecha>_<hora>.sql.gz$`), así que la rotación de `tienda` no toca las copias de `tienda_test`.

## 7. La restauración se niega a pisar una base con tablas

**Decisión:** `mysql-restore.sh` exige `-y` si la base destino ya tiene tablas.

**Motivo:** el error caro de un operador es restaurar en la base equivocada. El volcado trae `DROP TABLE IF EXISTS` y reemplazaría los datos actuales sin avisar. La copia no contiene el nombre de la base, así que se puede restaurar con otro nombre sin tocar la original.

## 8. Verificar es restaurar de verdad y comparar

**Decisión:** `mysql-verify-restore.sh` restaura en una base temporal y compara lista de tablas, `COUNT(*)` exacto por tabla, vistas, rutinas, triggers y eventos.

**Motivo:** una copia que nunca se ha restaurado es una esperanza, no una copia. `gzip --test` y la suma solo demuestran que el fichero está íntegro, no que el SQL se pueda ejecutar. Se usa `COUNT(*)` y no `information_schema.TABLES.TABLE_ROWS` porque esta última es una estimación en InnoDB. La base temporal se borra siempre (`trap` al salir), también si la comparación falla.

**Límite honesto:** si el origen sigue recibiendo escrituras tras la copia, las filas pueden diferir de forma legítima y el script saldrá con 2. Debe ejecutarse justo después de la copia, contra una réplica o en una ventana sin tráfico. Compara cantidades, no contenido: no detecta una fila alterada que mantenga el recuento.

## 9. Códigos de salida estilo Nagios

**Decisión:** 0 = OK, 1 = aviso (otra copia en curso), 2 = fallo, 3 = no ejecutable (falta un comando, credenciales o conexión), 64 = uso incorrecto.

**Motivo:** es el mismo convenio que el repositorio hermano `bash-sysadmin-toolkit`; cualquier sistema de monitorización o `OnFailure=` de systemd lo entiende sin adaptadores. Separar 2 de 3 distingue «la copia salió mal» de «ni siquiera pude intentarla».

## 10. Los tests usan un MySQL real y el cliente oficial en contenedor

**Decisión:** bats contra un servidor `mysql:8.4` en Docker. El cliente `mysql`/`mysqldump` de los tests es un *shim* (`tests/shims/`) que ejecuta el cliente oficial 8.4 en un contenedor con la red del host.

**Alternativa descartada:** simular `mysqldump` con funciones falsas.

**Motivo:** un mock no detecta lo que más falla en la práctica: opciones que cambian entre versiones, privilegios, `DEFINER`, el orden de las claves foráneas. Además, el cliente instalado en la máquina de desarrollo (MariaDB en Arch) no es el de MySQL 8 y daría resultados distintos. El shim fija el cliente y el servidor a la misma versión, igual en local que en el CI. En producción se usa el cliente nativo del sistema.

**Consecuencia para la medición:** cada llamada al cliente paga el arranque de un contenedor (unos 0,4 s). La restauración es una sola llamada, así que apenas le afecta; la verificación hace muchas consultas y por eso tarda más en las pruebas que en producción.

## 11. Lo que queda fuera (a propósito)

- **Copia incremental / binlog / PITR:** ver la sección de estrategia del [README](../README.md). No se implementa; se documenta cuándo hace falta.
- **Cifrado de las copias y envío fuera del servidor:** una copia en el mismo disco que la base no protege de un fallo de disco. Se documenta como siguiente paso (`rclone`/`restic`/`age`), no se implementa para no aparentar más de lo que se ha probado.
- **Alertas:** el código de salida y el syslog bastan para engancharlo a Nagios, a systemd `OnFailure=` o a un correo desde cron; no se reinventa.
