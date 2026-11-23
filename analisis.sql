/* ============================================================================
   PROYECTO CAPSTONE: Análisis Exploratorio de Datos (EDA) en PostgreSQL
   Archivo : analisis.sql
   Autor   : Luca Viliani
   Requiere: haber ejecutado estructura.sql en la base capstone_project.

   Convención usada en todo el análisis:
     "Venta" = pedido con estado 'Entregado'. Los pedidos cancelados no
     generaron ingreso, así que se excluyen de las métricas de facturación y
     se analizan aparte en la pregunta 6 (ventas perdidas).

   Índice del archivo
     0. Diagnóstico de calidad de datos (evidencia de la limpieza)
     1. Top 5 clientes por gasto total ............ GROUP BY + SUM + ventana
     2. Ventas totales por mes ..................... DATE_TRUNC + LAG
     3. Los 3 productos menos vendidos ............. LEFT JOIN + COALESCE
     4. Ranking de pedidos por categoría ........... RANK()
     5. Perfil del cliente leal .................... CASE + CTE
     6. Ventas perdidas por cancelaciones .......... CASE + FILTER
     7. Concentración de la facturación (Pareto) ... SUM() OVER acumulado
   ============================================================================ */


/* ============================================================================
   0. DIAGNÓSTICO DE CALIDAD DE DATOS
   Antes de analizar, se mide cuánta "suciedad" traía el origen y se verifica
   que la limpieza de estructura.sql la haya resuelto. Si este bloque no cierra,
   ningún número posterior es confiable (garbage in, garbage out).
   ============================================================================ */

-- 0.1 Nulos y valores inválidos en las columnas críticas del origen.
-- Se cuentan sobre staging porque ahí están los datos tal como llegaron.
SELECT COUNT(*)                                                           AS filas_crudas,
       COUNT(*) - COUNT(DISTINCT pedido_id)                               AS pedidos_duplicados,
       COUNT(*) FILTER (WHERE NULLIF(TRIM(precio_unitario), '') IS NULL)  AS precio_faltante,
       COUNT(*) FILTER (WHERE NULLIF(TRIM(fecha_pedido), '')    IS NULL)  AS fecha_faltante,
       COUNT(*) FILTER (WHERE fecha_pedido ~ '^\d{2}/\d{2}/\d{4}$')       AS fecha_formato_dd_mm_yyyy,
       COUNT(*) FILTER (WHERE NULLIF(TRIM(cantidad), '') IS NULL
                           OR TRIM(cantidad) = '0')                       AS cantidad_invalida,
       COUNT(DISTINCT estado)                                             AS variantes_de_estado
FROM   staging.pedidos;

-- 0.2 Inconsistencias de texto que habrían partido los GROUP BY en grupos falsos.
SELECT 'categoria de producto' AS campo,
       (SELECT COUNT(DISTINCT categoria)    FROM staging.productos) AS variantes_origen,
       (SELECT COUNT(DISTINCT categoria)    FROM public.productos)  AS valores_limpios
UNION ALL
SELECT 'provincia',
       (SELECT COUNT(DISTINCT provincia)    FROM staging.clientes),
       (SELECT COUNT(DISTINCT provincia)    FROM public.clientes)
UNION ALL
SELECT 'tipo de cliente',
       (SELECT COUNT(DISTINCT tipo_cliente) FROM staging.clientes),
       (SELECT COUNT(DISTINCT tipo_cliente) FROM public.clientes);

-- 0.3 Trazabilidad: cuántos valores del modelo limpio fueron imputados con
-- COALESCE. Se reporta para que quien lea el análisis sepa cuánto pesa la
-- imputación sobre la facturación (si fuera alto, habría que advertirlo).
SELECT COUNT(*)                                       AS pedidos_limpios,
       COUNT(*) FILTER (WHERE precio_imputado)        AS precios_imputados,
       COUNT(*) FILTER (WHERE fecha_imputada)         AS fechas_imputadas,
       ROUND(100.0 * SUM(monto_total) FILTER (WHERE precio_imputado)
             / SUM(monto_total), 1)                   AS pct_facturacion_con_precio_imputado
FROM   public.pedidos;

-- 0.4 Control de "explosión de filas": la relación pedidos -> clientes y
-- pedidos -> productos es muchos-a-uno, así que el JOIN no debe crear filas.
-- Si filas_despues_join fuera mayor que filas_pedidos, habría llaves
-- duplicadas en una dimensión y todas las sumas estarían infladas.
SELECT (SELECT COUNT(*) FROM public.pedidos) AS filas_pedidos,
       COUNT(*)                              AS filas_despues_join
FROM   public.pedidos   pe
JOIN   public.clientes  c ON c.cliente_id  = pe.cliente_id
JOIN   public.productos p ON p.producto_id = pe.producto_id;

-- Lectura del bloque 0: de 1.662 filas crudas, 12 eran pedidos duplicados y
-- 29 tenían cantidad nula o 0; quedan 1.621 pedidos válidos. El texto libre
-- generaba 17 variantes de categoría para 7 categorías reales y 18 variantes
-- de provincia para 8. El 7,4% de la facturación usa un precio imputado:
-- es bajo, pero se informa en las conclusiones. El JOIN no duplica filas.


/* ============================================================================
   1. TOP 5 CLIENTES POR GASTO TOTAL
   Pregunta de negocio: ¿quiénes son los clientes que más facturan y cuánto
   depende la empresa de ellos? Si pocos clientes explican gran parte de la
   facturación, perder uno es un riesgo y merecen atención comercial dedicada.
   La función de ventana SUM() OVER () calcula el total general sin colapsar
   las filas, para expresar el gasto de cada cliente como % del total.
   ============================================================================ */
WITH gasto_cliente AS (
    SELECT c.cliente_id,
           c.razon_social,
           c.tipo_cliente,
           c.provincia,
           COUNT(*)            AS pedidos,
           SUM(pe.monto_total) AS gasto_total
    FROM   public.pedidos  pe
    JOIN   public.clientes c ON c.cliente_id = pe.cliente_id
    WHERE  pe.estado = 'Entregado'
    GROUP  BY c.cliente_id, c.razon_social, c.tipo_cliente, c.provincia
)
SELECT razon_social,
       tipo_cliente,
       provincia,
       pedidos,
       gasto_total                                                   AS gasto_total_usd,
       ROUND(gasto_total / pedidos, 2)                               AS ticket_promedio_usd,
       ROUND(100.0 * gasto_total / SUM(gasto_total) OVER (), 1)      AS pct_de_la_facturacion
FROM   gasto_cliente
ORDER  BY gasto_total DESC
LIMIT  5;

-- Lectura: los 5 clientes son industrias y suman el 35,3% de la facturación.
-- Solo los dos primeros (Aceros Norte SRL y Autopartes Güemes SA) explican el
-- 19,1%: cada uno factura más que un mes promedio (USD 34.200).


/* ============================================================================
   2. VENTAS TOTALES POR MES
   Pregunta de negocio: ¿hay estacionalidad? Saber qué meses son fuertes y
   cuáles débiles permite planificar compras de stock e importaciones (que
   tienen meses de anticipación) y concentrar promociones en los meses flojos.
   DATE_TRUNC agrupa por mes calendario; LAG() trae el mes anterior a la
   misma fila para calcular la variación sin un self-join.
   ============================================================================ */
WITH ventas_mes AS (
    SELECT DATE_TRUNC('month', fecha_pedido)::DATE AS mes,
           COUNT(*)                                AS pedidos,
           SUM(monto_total)                        AS facturacion
    FROM   public.pedidos
    WHERE  estado = 'Entregado'
      AND  fecha_pedido >= DATE '2025-01-01'
      AND  fecha_pedido <  DATE '2026-01-01'        -- rango explícito: aprovecha idx_pedidos_fecha
    GROUP  BY 1
)
SELECT TO_CHAR(mes, 'YYYY-MM')                                       AS mes,
       pedidos,
       facturacion                                                   AS facturacion_usd,
       ROUND(100.0 * (facturacion - LAG(facturacion) OVER (ORDER BY mes))
             / LAG(facturacion) OVER (ORDER BY mes), 1)              AS variacion_vs_mes_anterior_pct,
       ROUND(100.0 * facturacion / AVG(facturacion) OVER () - 100, 1) AS desvio_vs_promedio_anual_pct
FROM   ventas_mes
ORDER  BY mes;

-- Lectura: enero (-55% vs. el promedio) y febrero (-34%) son los meses más
-- flojos (vacaciones y paradas de planta); julio cae un 19% (receso de
-- invierno). Los picos son septiembre (+36%), noviembre (+28%) y agosto
-- (+25%). La caída de octubre (-31% vs. septiembre) no tiene una causa
-- estacional evidente y conviene validarla con más de un año de historia.

-- 2.b Lectura por trimestre: suaviza el ruido mensual y facilita comparar
-- con el presupuesto, que suele armarse por trimestre.
SELECT 'T' || EXTRACT(QUARTER FROM fecha_pedido)                     AS trimestre,
       SUM(monto_total)                                              AS facturacion_usd,
       ROUND(100.0 * SUM(monto_total) / SUM(SUM(monto_total)) OVER (), 1) AS pct_del_anio
FROM   public.pedidos
WHERE  estado = 'Entregado'
GROUP  BY 1
ORDER  BY 1;

-- Lectura: el primer trimestre aporta solo el 18,8% del año, contra el
-- 27-28% del segundo semestre.


/* ============================================================================
   3. LOS 3 PRODUCTOS MENOS VENDIDOS
   Pregunta de negocio: ¿qué artículos inmovilizan capital en stock sin
   rotar? Son candidatos a liquidar, a pasar a venta bajo pedido o a dejar de
   reponer.
   Se usa LEFT JOIN desde productos (y no desde pedidos) porque un producto
   que NUNCA se vendió no tiene filas en pedidos: con un INNER JOIN
   desaparecería justo el caso más grave. COALESCE convierte su suma NULL en 0.
   La condición de estado va en el ON y no en el WHERE: en el WHERE eliminaría
   las filas NULL del LEFT JOIN y volvería a ocultar los productos sin ventas.
   ============================================================================ */
SELECT p.producto_id,
       p.nombre,
       p.categoria,
       p.precio_lista                          AS precio_lista_usd,
       COUNT(pe.pedido_id)                     AS pedidos,
       COALESCE(SUM(pe.cantidad), 0)           AS unidades_vendidas,
       COALESCE(SUM(pe.monto_total), 0)        AS facturacion_usd
FROM   public.productos p
LEFT   JOIN public.pedidos pe
       ON  pe.producto_id = p.producto_id
       AND pe.estado      = 'Entregado'
GROUP  BY p.producto_id, p.nombre, p.categoria, p.precio_lista
ORDER  BY unidades_vendidas ASC, facturacion_usd ASC
LIMIT  3;

-- Lectura: el disco diamantado para porcelanato no registró ninguna venta en
-- 12 meses, y la sierra copa diamantada y la hoja sin fin para madera rotan
-- muy poco (7 y 3 pedidos). Los tres sirven para materiales que no son metal
-- (cerámica, madera), mientras que la cartera es metalmecánica: no es un
-- problema de precio sino de producto que no coincide con el cliente.


/* ============================================================================
   4. RANKING DE PEDIDOS POR CATEGORÍA (RANK)
   Pregunta de negocio: ¿cómo son los pedidos más grandes de cada categoría y
   quién los hace? Identifica las operaciones "ancla" de cada línea de
   producto, útiles para negociar volumen con proveedores y para armar
   listas de precios por cantidad.
   PARTITION BY reinicia el ranking en cada categoría. Se usa RANK() (y no
   ROW_NUMBER) para que dos pedidos con el mismo monto compartan el puesto.
   ============================================================================ */
WITH ranking AS (
    SELECT p.categoria,
           pe.pedido_id,
           pe.fecha_pedido,
           c.razon_social,
           c.tipo_cliente,
           p.nombre                                    AS producto,
           pe.cantidad,
           pe.monto_total,
           RANK() OVER (PARTITION BY p.categoria
                        ORDER BY pe.monto_total DESC)  AS puesto_en_categoria
    FROM   public.pedidos   pe
    JOIN   public.productos p ON p.producto_id = pe.producto_id
    JOIN   public.clientes  c ON c.cliente_id  = pe.cliente_id
    WHERE  pe.estado = 'Entregado'
)
SELECT categoria, puesto_en_categoria, pedido_id, fecha_pedido, razon_social,
       tipo_cliente, producto, cantidad, monto_total AS monto_usd
FROM   ranking
WHERE  puesto_en_categoria <= 3          -- top 3 por categoría
ORDER  BY categoria, puesto_en_categoria;

-- Lectura: 17 de los 21 puestos del ranking corresponden a industrias y
-- Aceros Norte SRL aparece en 8: los pedidos más grandes de casi todas las
-- líneas dependen de pocos compradores industriales. En las categorías de
-- mayor precio (Insertos, Sierras sin fin) el pedido tope ronda las 20-28
-- unidades; en consumibles (lijas, mechas) supera las 100.

-- 4.b Resumen por categoría: cuánto aporta cada línea y qué tan grande es su
-- pedido típico. Contextualiza el ranking anterior.
SELECT p.categoria,
       COUNT(*)                                                       AS pedidos,
       SUM(pe.monto_total)                                            AS facturacion_usd,
       ROUND(100.0 * SUM(pe.monto_total) / SUM(SUM(pe.monto_total)) OVER (), 1) AS pct_facturacion,
       ROUND(AVG(pe.monto_total), 2)                                  AS ticket_promedio_usd,
       RANK() OVER (ORDER BY SUM(pe.monto_total) DESC)                AS ranking_facturacion
FROM   public.pedidos   pe
JOIN   public.productos p ON p.producto_id = pe.producto_id
WHERE  pe.estado = 'Entregado'
GROUP  BY p.categoria
ORDER  BY facturacion_usd DESC;

-- Lectura: Mechas, Lijas y abrasivos e Insertos generan el 64,8% de la
-- facturación. Discos de corte es la categoría con más pedidos (473, el 30%)
-- pero solo aporta el 9,2% del dinero, con un ticket de USD 80: es el
-- producto de "tráfico" que hace volver al cliente, ideal para venta cruzada.


/* ============================================================================
   5. PERFIL DEL CLIENTE LEAL
   Pregunta de negocio: ¿cómo es nuestro cliente más leal? Se segmenta por
   frecuencia de compra con CASE. Los cortes se eligieron sobre el negocio:
     - Leal       : 24+ pedidos en el año (compra en promedio cada 2 semanas)
     - Recurrente : 6 a 23 pedidos (compra al menos cada 2 meses)
     - Ocasional  : 1 a 5 pedidos
   Luego se cruza el segmento con el tipo de cliente para ver quién lo compone.
   ============================================================================ */
WITH frecuencia AS (
    SELECT c.cliente_id,
           c.tipo_cliente,
           COUNT(*)            AS pedidos,
           SUM(pe.monto_total) AS gasto
    FROM   public.pedidos  pe
    JOIN   public.clientes c ON c.cliente_id = pe.cliente_id
    WHERE  pe.estado = 'Entregado'
    GROUP  BY c.cliente_id, c.tipo_cliente
),
segmentado AS (
    SELECT *,
           CASE
               WHEN pedidos >= 24 THEN '1. Leal'
               WHEN pedidos >= 6  THEN '2. Recurrente'
               ELSE                    '3. Ocasional'
           END AS segmento
    FROM   frecuencia
)
SELECT segmento,
       COUNT(*)                                                       AS clientes,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)             AS pct_clientes,
       ROUND(100.0 * SUM(gasto) / SUM(SUM(gasto)) OVER (), 1)         AS pct_facturacion,
       ROUND(AVG(pedidos), 1)                                         AS pedidos_promedio,
       ROUND(SUM(gasto) / SUM(pedidos), 2)                            AS ticket_promedio_usd,
       -- composición del segmento por tipo de cliente
       COUNT(*) FILTER (WHERE tipo_cliente = 'Industria')             AS industria,
       COUNT(*) FILTER (WHERE tipo_cliente = 'Taller metalúrgico')    AS taller,
       COUNT(*) FILTER (WHERE tipo_cliente = 'Ferretería')            AS ferreteria,
       COUNT(*) FILTER (WHERE tipo_cliente = 'Consumidor final')      AS consumidor_final
FROM   segmentado
GROUP  BY segmento
ORDER  BY segmento;

-- Lectura: 21 clientes leales (24% de la cartera) generan el 66,9% de la
-- facturación. Son todos B2B (9 talleres, 7 ferreterías, 5 industrias), hacen
-- unos 42 pedidos al año (casi uno por semana) y ningún consumidor final
-- llega a este segmento. Los 48 recurrentes, sobre todo talleres y
-- ferreterías, son la cantera natural para crecer.


/* ============================================================================
   6. VENTAS PERDIDAS POR CANCELACIONES
   Pregunta de negocio: ¿en qué segmento perdemos más ventas? Una tasa de
   cancelación alta en un segmento suele indicar un problema de proceso
   (medios de pago, plazos de entrega, stock publicado sin respaldo) que se
   puede corregir, a diferencia de la estacionalidad.
   ============================================================================ */
SELECT c.tipo_cliente,
       COUNT(*)                                                         AS pedidos_totales,
       COUNT(*) FILTER (WHERE pe.estado = 'Cancelado')                  AS cancelados,
       ROUND(100.0 * COUNT(*) FILTER (WHERE pe.estado = 'Cancelado')
             / COUNT(*), 1)                                             AS tasa_cancelacion_pct,
       SUM(CASE WHEN pe.estado = 'Cancelado' THEN pe.monto_total ELSE 0 END) AS monto_perdido_usd,
       SUM(CASE WHEN pe.estado = 'Entregado' THEN pe.monto_total ELSE 0 END) AS monto_facturado_usd
FROM   public.pedidos  pe
JOIN   public.clientes c ON c.cliente_id = pe.cliente_id
GROUP  BY c.tipo_cliente
ORDER  BY tasa_cancelacion_pct DESC;

-- Lectura: el consumidor final cancela el 12,5% de sus pedidos, unas 4 veces
-- más que el B2B (3-4,5%), lo que apunta a un problema del checkout web. Pero
-- en dinero la mayor pérdida está en ferreterías (USD 7.000 de USD 15.500
-- perdidos en total): la prioridad depende de si se mide proceso o ingreso.


/* ============================================================================
   7. CONCENTRACIÓN DE LA FACTURACIÓN (PARETO)
   Pregunta de negocio: ¿qué porcentaje de clientes explica el 80% de la
   facturación? Complementa la pregunta 1: el top 5 muestra nombres; esta
   consulta mide el riesgo de concentración de toda la cartera.
   SUM() OVER (ORDER BY ...) arma el acumulado ordenado de mayor a menor gasto.
   ============================================================================ */
WITH gasto AS (
    SELECT cliente_id, SUM(monto_total) AS gasto
    FROM   public.pedidos
    WHERE  estado = 'Entregado'
    GROUP  BY cliente_id
),
acumulado AS (
    SELECT cliente_id,
           gasto,
           ROW_NUMBER() OVER (ORDER BY gasto DESC)                          AS posicion,
           COUNT(*)     OVER ()                                             AS total_clientes,
           SUM(gasto)   OVER (ORDER BY gasto DESC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(gasto) OVER ()                                           AS pct_acumulado
    FROM   gasto
)
SELECT MIN(posicion)                                        AS clientes_para_llegar_al_80pct,
       MAX(total_clientes)                                  AS clientes_con_compras,
       ROUND(100.0 * MIN(posicion) / MAX(total_clientes), 1) AS pct_de_la_cartera
FROM   acumulado
WHERE  pct_acumulado >= 0.80;

-- Lectura: 31 de 88 clientes con compras (35%) explican el 80% de la
-- facturación. Hay concentración, pero menos extrema que un 80/20 clásico.
