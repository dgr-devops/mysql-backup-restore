# Restauración cronometrada

Una copia de seguridad no vale nada hasta que se sabe cuánto se tarda en recuperarla. Este documento recoge una medición **real**: se genera una base de ejemplo, se copia, se restaura en otra base y se cronometra cada paso. Los números salen de `scripts/measure-restore.sh`; no hay estimaciones ni valores redondeados a mano.

## Cómo se midió

**Orden ejecutada** (tres veces seguidas, con la misma base recién generada cada vez):

```bash
docker compose up -d --wait
PATH="$PWD/tests/shims:$PATH" scripts/measure-restore.sh -n 1000000 -c /ruta/fuera/del/repo/root.cnf
```

El script, en este orden y midiendo con `EPOCHREALTIME`:

1. Crea la base `tienda_medicion` con `mysql-sample-data.sh -n 1000000` (1 000 000 de pedidos, 100 000 clientes, 3 000 000 de líneas de pedido y una tabla de auditoría vacía; vista, función, procedimiento y trigger incluidos).
2. Hace la copia con `mysql-backup.sh` (mysqldump + gzip + SHA-256).
3. Restaura con `mysql-restore.sh` en `tienda_medicion_restaurada`: comprueba la suma SHA-256, prueba el gzip y vuelca el SQL.
4. Compara las dos bases (tablas, `COUNT(*)` exacto por tabla, vistas, rutinas y triggers) y termina con error si no coinciden.

**Entorno** (una sola máquina, sin otra carga relevante durante la medición):

| Elemento | Valor |
|---|---|
| CPU | Intel Core Ultra 7 155H, 22 hilos |
| Memoria | 30 GiB |
| Disco | NVMe, sistema de ficheros btrfs |
| Docker | 29.10.0, almacenamiento `overlayfs` (el volumen de datos de MySQL está en el disco anterior) |
| Servidor | MySQL 8.4.13 (`mysql:8.4`) con la configuración por defecto de la imagen |
| Cliente | `mysql`/`mysqldump` 8.4 en contenedor (`tests/shims`), por red del host |

La configuración de MySQL es la de fábrica a propósito: es lo que se encuentra uno en un servidor sin ajustar. No se desactivó el binlog ni se tocó `innodb_buffer_pool_size`.

## Resultado

Salida literal de la primera ejecución:

| Dato | Valor |
|---|---|
| Servidor | MySQL 8.4.13 |
| Pedidos / filas totales (estimación de information_schema) | 1000000 / ~4086785 |
| Tamaño en el servidor (datos + índices) | 435.7 MB |
| Volcado SQL sin comprimir | 203.4 MB |
| Copia .sql.gz | 58.0 MB |
| Generar los datos de ejemplo | 54.34 s |
| **Copia (mysqldump + gzip + SHA-256)** | **11.85 s** |
| **Restauración (verificar SHA-256 + gzip + mysql)** | **63.66 s** |
| Coste fijo de arrancar el cliente (una consulta vacía) | 0.39 s |
| Tablas y filas idénticas tras restaurar | sí |

Las tres ejecuciones:

| Ejecución | Copia | Restauración | Tamaño en servidor |
|---|---|---|---|
| 1 | 11.85 s | 63.66 s | 435.7 MB |
| 2 | 11.83 s | 65.59 s | 432.7 MB |
| 3 | 11.65 s | 65.08 s | 437.7 MB |
| **Media** | **11.78 s** | **64.78 s** | |

El volcado (203.4 MB sin comprimir, 58.0 MB comprimido) es idéntico en las tres. El tamaño en servidor varía unos MB porque `information_schema` da estimaciones de páginas InnoDB, no porque los datos cambien. Las filas totales (~4,09 millones) son la suma de `TABLE_ROWS`, que también es una estimación; la comparación de tablas tras restaurar sí usa `COUNT(*)` exacto y coincidió las tres veces.

## Cómo leerlo

- **Restaurar cuesta unas 5,5 veces lo que cuesta copiar** (64,8 s frente a 11,8 s). Copiar es leer secuencialmente; restaurar es insertar 4 millones de filas y mantener 5 índices secundarios y 2 claves foráneas. Por eso el RTO real de una copia lógica lo marca la restauración, no la copia.
- **Rendimiento observado en la restauración:** unos 3,1 MB de SQL por segundo (203,4 MB en 64,8 s), o unos 63 000 filas por segundo.
- **El cliente en contenedor no distorsiona la restauración:** el arranque del contenedor suma unos 0,4 s por llamada y la restauración es una única llamada de `mysql`. Sí penaliza a `mysql-verify-restore.sh`, que lanza muchas consultas pequeñas; en las pruebas tarda más de lo que tardaría con un cliente nativo.
- **La restauración incluye verificar el SHA-256** del fichero comprimido de 58 MB y `gzip --test`; es una fracción pequeña del total (no se midió por separado).

## Lo que esta medición NO dice

- **No es una garantía para otro servidor.** Mide una base de ~436 MB en un portátil con NVMe. En un servidor con disco más lento, varias bases o carga simultánea, los tiempos serán distintos. Para fijar un RTO propio, hay que repetir la medición en el hardware de destino con `scripts/measure-restore.sh -n <pedidos>`.
- **No se ha medido con más tamaño.** Extrapolar linealmente (por ejemplo, «10 GB = 25 minutos») sería una suposición: el tiempo de restauración no es lineal cuando los índices dejan de caber en el *buffer pool*. Se deja sin cifra a propósito.
- **No se ha medido ningún ajuste de rendimiento.** Es habitual acelerar una restauración lógica con `innodb_flush_log_at_trx_commit=2`, `sql_log_bin=0` o un `innodb_buffer_pool_size` mayor, pero aquí no se probó ninguno y no se puede afirmar cuánto ganarían.
- **No incluye el tiempo humano:** detectar el fallo, decidir restaurar, localizar la copia correcta y copiarla al servidor. En un incidente real esos minutos pueden pesar más que los 65 s de la restauración.
