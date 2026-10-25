-- =============================================================================
-- 12_metrics_business.sql
-- Бизнес-метрики и North Star (разделы 4 и 5 в docs/metrics.md):
--   1. GMV, покупки, заказы, AOV по месяцам и за весь период
--   2. То же по неделям (с флагом is_full_week)
--   3. ARPPU и среднее число заказов (на активного пользователя и на покупателя)
--   4. NSM: недельный GMV и его разложение на дерево метрик
--   5. Сверка с независимым источником (stg.events)
--   6. Диагностика: распределение суммы заказа (почему важна медиана)
--
-- Где запускать: подключение к `cosmetics_shop`, каждый запрос отдельно
-- (Ctrl+Enter) или весь файл через Execute Script (Alt+X). Запускать после
-- 05, 07 и 08.
--
-- Источники:
--   * mart.orders: заказы и деньги (одна строка = заказ);
--   * mart.user_activity_daily: активные пользователи (знаменатели);
--   * mart.users: итоги за весь период.
--
-- Правила (см. раздел 0 в docs/metrics.md):
--   * Заказ = строка mart.orders: (user_session, user_id, order_time). Деньги
--     считаем только по покупкам без дублей и с ценой не NULL (это уже учтено
--     при построении витрины).
--   * Заказ, его покупки и GMV относим к периоду order_time (UTC). У заказа одно
--     время, поэтому GMV и покупки по периодам совпадают с расчётом из
--     stg.events по event_time точно (блоки 5.2 и 5.3).
--   * Валюта в данных неизвестна: суммы в условных денежных единицах.
--   * Неделя с понедельника, UTC. Первая и последняя недели неполные.
--   * Первая неделя данных (особенно 2, 6 и 7 октября) содержит аномальный
--     приток пользователей без покупок; GMV этих дней нормальный, а доли и
--     конверсии на пользователя в октябре читать с оговоркой (docs/metrics.md,
--     раздел 6).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. GMV, покупки, заказы, AOV по месяцам и за весь период
--    AOV = GMV / заказы (а не / покупки): в заказе может быть несколько товаров.
--    ROLLUP корректен: каждый заказ относится ровно к одному месяцу, поэтому
--    строка 'all' равна сумме месячных строк.
-- -----------------------------------------------------------------------------
WITH o AS (
    SELECT
        date_trunc('month', order_time AT TIME ZONE 'UTC')::date  AS month,
        gmv,
        items_cnt
    FROM mart.orders
)
SELECT
    COALESCE(month::text, 'all')                    AS period,
    ROUND(SUM(gmv), 2)                              AS gmv,
    SUM(items_cnt)                                  AS purchases,
    COUNT(*)                                        AS orders,
    ROUND(SUM(gmv) / NULLIF(COUNT(*), 0), 2)        AS aov
FROM o
GROUP BY ROLLUP (month)
ORDER BY month NULLS LAST;


-- -----------------------------------------------------------------------------
-- 2. То же по неделям
--    Список недель берём из user_activity_daily, а не из заказов: неделя без
--    заказов осталась бы незамеченной, а не стала нулевой строкой.
-- -----------------------------------------------------------------------------
WITH weeks AS (
    SELECT
        date_trunc('week', activity_date::timestamp)::date  AS week_start,
        COUNT(DISTINCT activity_date) = 7                   AS is_full_week
    FROM mart.user_activity_daily
    GROUP BY 1
),
o AS (
    SELECT
        date_trunc('week', order_time AT TIME ZONE 'UTC')::date   AS week_start,
        SUM(gmv)                                                  AS gmv,
        SUM(items_cnt)                                            AS purchases,
        COUNT(*)                                                  AS orders
    FROM mart.orders
    GROUP BY 1
)
SELECT
    w.week_start,
    w.is_full_week,
    ROUND(COALESCE(o.gmv, 0), 2)                    AS gmv,
    COALESCE(o.purchases, 0)                        AS purchases,
    COALESCE(o.orders, 0)                           AS orders,
    ROUND(o.gmv / NULLIF(o.orders, 0), 2)           AS aov
FROM weeks w
LEFT JOIN o USING (week_start)
ORDER BY w.week_start;


-- -----------------------------------------------------------------------------
-- 3. ARPPU и среднее число заказов
--    buyers            : пользователи с >= 1 заказом с известной ценой в периоде
--                        (числитель и знаменатель ARPPU берутся по одним заказам)
--    active_users      : пользователи с любым событием в периоде
--    arppu             = GMV / buyers
--    orders_per_active = заказы / active_users (близко к доле покупающих)
--    orders_per_buyer  = заказы / buyers (частота покупок среди платящих)
--
--    Строка 'whole period' это отношение за все 5 месяцев, а не среднее
--    месячных значений: пользователь, активный в нескольких месяцах, попадает в
--    знаменатель один раз. Поэтому строку 'whole period' нельзя сравнивать с
--    месячными строками напрямую (ARPPU и заказы на пользователя за период
--    длиннее, значит выше).
--
--    Период 'whole period': из mart.users (активные = все пользователи в витрине).
-- -----------------------------------------------------------------------------
WITH m_orders AS (
    SELECT
        date_trunc('month', order_time AT TIME ZONE 'UTC')::date  AS month,
        COUNT(DISTINCT user_id)                                   AS buyers,
        COUNT(*)                                                  AS orders,
        SUM(gmv)                                                  AS gmv
    FROM mart.orders
    GROUP BY 1
),
m_users AS (
    SELECT
        date_trunc('month', activity_date::timestamp)::date AS month,
        COUNT(DISTINCT user_id)                             AS active_users
    FROM mart.user_activity_daily
    GROUP BY 1
),
by_month AS (
    SELECT
        'month'                             AS period_kind,
        u.month::text                       AS period,
        u.active_users,
        COALESCE(o.buyers, 0)               AS buyers,
        COALESCE(o.orders, 0)               AS orders,
        COALESCE(o.gmv, 0)                  AS gmv
    FROM m_users u
    LEFT JOIN m_orders o ON o.month = u.month
),
whole AS (
    SELECT
        'whole period'                                          AS period_kind,
        'all'                                                   AS period,
        COUNT(*)                                                AS active_users,
        COUNT(*) FILTER (WHERE orders_cnt >= 1)                 AS buyers,
        SUM(orders_cnt)                                         AS orders,
        SUM(gmv)                                                AS gmv
    FROM mart.users
)
SELECT
    period_kind,
    period,
    active_users,
    buyers,
    orders,
    ROUND(gmv, 2)                                               AS gmv,
    ROUND(gmv / NULLIF(buyers, 0), 2)                           AS arppu,
    ROUND(orders::numeric / NULLIF(active_users, 0), 4)         AS orders_per_active,
    ROUND(orders::numeric / NULLIF(buyers, 0), 3)               AS orders_per_buyer
FROM (SELECT * FROM by_month UNION ALL SELECT * FROM whole) t
ORDER BY period_kind = 'whole period', period;


-- -----------------------------------------------------------------------------
-- 4. North Star Metric: GMV в неделю и его дерево
--    GMV = WAU x (покупатели / WAU) x (заказы / покупатель) x AOV
--    Каждый множитель можно менять продуктовыми решениями отдельно:
--      wau               : приток аудитории (маркетинг, SEO)
--      buyer_share_pct   : конверсия активного пользователя в покупателя
--      orders_per_buyer  : частота покупок (возвраты, подписки, рассылки)
--      aov               : средний чек (кросс-продажи, акции, цены)
--    gmv_wow_pct показан для всех недель, но интерпретировать можно только
--    строки, где обе недели полные (is_full_week и prev_full_week).
-- -----------------------------------------------------------------------------
WITH weeks AS (
    SELECT
        date_trunc('week', activity_date::timestamp)::date  AS week_start,
        COUNT(DISTINCT activity_date) = 7                   AS is_full_week,
        COUNT(DISTINCT user_id)                             AS wau
    FROM mart.user_activity_daily
    GROUP BY 1
),
o AS (
    SELECT
        date_trunc('week', order_time AT TIME ZONE 'UTC')::date   AS week_start,
        COUNT(DISTINCT user_id)                                   AS buyers,
        COUNT(*)                                                  AS orders,
        SUM(gmv)                                                  AS gmv
    FROM mart.orders
    GROUP BY 1
),
joined AS (
    SELECT
        w.week_start,
        w.is_full_week,
        w.wau,
        COALESCE(o.buyers, 0)   AS buyers,
        COALESCE(o.orders, 0)   AS orders,
        COALESCE(o.gmv, 0)      AS gmv
    FROM weeks w
    LEFT JOIN o USING (week_start)
)
SELECT
    week_start,
    is_full_week,
    ROUND(gmv, 2)                                                       AS gmv,
    ROUND(100.0 * (gmv - LAG(gmv) OVER (ORDER BY week_start))
          / NULLIF(LAG(gmv) OVER (ORDER BY week_start), 0), 2)          AS gmv_wow_pct,
    LAG(is_full_week) OVER (ORDER BY week_start)                        AS prev_full_week,
    wau,
    buyers,
    ROUND(100.0 * buyers / NULLIF(wau, 0), 2)                           AS buyer_share_pct,
    ROUND(orders::numeric / NULLIF(buyers, 0), 3)                       AS orders_per_buyer,
    ROUND(gmv / NULLIF(orders, 0), 2)                                   AS aov
FROM joined
ORDER BY week_start;


-- =============================================================================
-- 5. Сверка: те же цифры из stg.events напрямую, без витрин
--    Во всех блоках expected считается из stg.events, actual берётся из витрин.
-- =============================================================================

-- 5.1. Итоги за весь период. Должно совпасть точно (OK во всех строках).
--      Заказы в stg: число уникальных моментов покупки (user_session, user_id,
--      event_time) среди покупок без дубля и с ценой.
WITH from_mart AS (
    SELECT
        SUM(gmv)                                            AS gmv,
        SUM(items_cnt)                                      AS purchases,
        COUNT(*)                                            AS orders
    FROM mart.orders
),
from_users AS (
    SELECT SUM(gmv) AS gmv, SUM(orders_cnt) AS orders
    FROM mart.users
),
from_stg AS (
    SELECT
        (SELECT SUM(price) FROM stg.events
          WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL) AS gmv,
        (SELECT COUNT(*) FROM stg.events
          WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL) AS purchases,
        (SELECT COUNT(*) FROM (
             SELECT DISTINCT user_session, user_id, event_time FROM stg.events
              WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
         ) g)                                                                       AS orders,
        -- контроль гипотезы «покупок без user_session нет»: должно быть 0
        (SELECT COUNT(*) FROM stg.events
          WHERE event_type = 'purchase' AND NOT is_duplicate
            AND price IS NOT NULL AND user_session IS NULL)                         AS purchases_without_session
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END   AS status
FROM from_mart m
CROSS JOIN from_users u
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('GMV: mart.orders vs stg.events',           s.gmv::numeric,       m.gmv::numeric),
    ('GMV: mart.users vs stg.events',            s.gmv::numeric,       u.gmv::numeric),
    ('purchases with price: mart.orders vs stg', s.purchases::numeric, m.purchases::numeric),
    ('orders: mart.orders vs stg.events',        s.orders::numeric,    m.orders::numeric),
    ('orders: mart.users vs mart.orders',        m.orders::numeric,    u.orders::numeric),
    ('purchases without user_session',           0::numeric,           s.purchases_without_session::numeric)
) AS x(check_name, expected, actual);


-- 5.2. GMV, покупки и заказы по месяцам: витрина (по order_time) против stg
--      (по event_time). Совпадение должно быть точным в каждой строке: у заказа
--      одно время, поэтому сдвига между периодами нет.
WITH m AS (
    SELECT
        date_trunc('month', order_time AT TIME ZONE 'UTC')::date AS month,
        SUM(gmv)                                                 AS gmv,
        SUM(items_cnt)                                           AS purchases,
        COUNT(*)                                                 AS orders
    FROM mart.orders
    GROUP BY 1
),
s AS (
    SELECT
        date_trunc('month', event_time AT TIME ZONE 'UTC')::date AS month,
        SUM(price)                                               AS gmv,
        COUNT(*)                                                 AS purchases,
        COUNT(DISTINCT (user_session, user_id, event_time))      AS orders
    FROM stg.events
    WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    GROUP BY 1
)
SELECT
    COALESCE(s.month, m.month)                                  AS month,
    ROUND(s.gmv, 2)                                             AS expected_gmv,
    ROUND(m.gmv, 2)                                             AS actual_gmv,
    s.purchases                                                 AS expected_purchases,
    m.purchases                                                 AS actual_purchases,
    s.orders                                                    AS expected_orders,
    m.orders                                                    AS actual_orders,
    CASE WHEN s.gmv       IS NOT DISTINCT FROM m.gmv
          AND s.purchases IS NOT DISTINCT FROM m.purchases
          AND s.orders    IS NOT DISTINCT FROM m.orders
         THEN 'OK' ELSE 'FAIL' END                              AS status
FROM s
FULL JOIN m ON m.month = s.month
ORDER BY 1;


-- 5.3. То же по неделям.
WITH m AS (
    SELECT
        date_trunc('week', order_time AT TIME ZONE 'UTC')::date  AS week_start,
        SUM(gmv)                                                 AS gmv,
        SUM(items_cnt)                                           AS purchases,
        COUNT(*)                                                 AS orders
    FROM mart.orders
    GROUP BY 1
),
s AS (
    SELECT
        date_trunc('week', event_time AT TIME ZONE 'UTC')::date  AS week_start,
        SUM(price)                                               AS gmv,
        COUNT(*)                                                 AS purchases,
        COUNT(DISTINCT (user_session, user_id, event_time))      AS orders
    FROM stg.events
    WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    GROUP BY 1
)
SELECT
    COALESCE(s.week_start, m.week_start)                        AS week_start,
    ROUND(s.gmv, 2)                                             AS expected_gmv,
    ROUND(m.gmv, 2)                                             AS actual_gmv,
    s.purchases                                                 AS expected_purchases,
    m.purchases                                                 AS actual_purchases,
    s.orders                                                    AS expected_orders,
    m.orders                                                    AS actual_orders,
    CASE WHEN s.gmv       IS NOT DISTINCT FROM m.gmv
          AND s.purchases IS NOT DISTINCT FROM m.purchases
          AND s.orders    IS NOT DISTINCT FROM m.orders
         THEN 'OK' ELSE 'FAIL' END                              AS status
FROM s
FULL JOIN m ON m.week_start = s.week_start
ORDER BY 1;


-- 5.4. Аудитория в блоках 3 и 4: активные пользователи и покупатели по месяцам
--      и неделям (витрины) против stg.events. В каждой строке считается число
--      периодов, где значения различаются; ожидается 0.
WITH m_act AS (
    SELECT date_trunc('month', activity_date::timestamp)::date AS p,
           COUNT(DISTINCT user_id)                            AS n
    FROM mart.user_activity_daily GROUP BY 1
),
s_act AS (
    SELECT date_trunc('month', event_time AT TIME ZONE 'UTC')::date AS p,
           COUNT(DISTINCT user_id)                                  AS n
    FROM stg.events GROUP BY 1
),
m_buy AS (
    SELECT date_trunc('month', order_time AT TIME ZONE 'UTC')::date AS p,
           COUNT(DISTINCT user_id)                                  AS n
    FROM mart.orders GROUP BY 1
),
s_buy AS (
    SELECT date_trunc('month', event_time AT TIME ZONE 'UTC')::date AS p,
           COUNT(DISTINCT user_id)                                  AS n
    FROM stg.events
    WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    GROUP BY 1
),
mw_act AS (
    SELECT date_trunc('week', activity_date::timestamp)::date AS p,
           COUNT(DISTINCT user_id)                           AS n
    FROM mart.user_activity_daily GROUP BY 1
),
sw_act AS (
    SELECT date_trunc('week', event_time AT TIME ZONE 'UTC')::date AS p,
           COUNT(DISTINCT user_id)                                 AS n
    FROM stg.events GROUP BY 1
),
mw_buy AS (
    SELECT date_trunc('week', order_time AT TIME ZONE 'UTC')::date AS p,
           COUNT(DISTINCT user_id)                                 AS n
    FROM mart.orders GROUP BY 1
),
sw_buy AS (
    SELECT date_trunc('week', event_time AT TIME ZONE 'UTC')::date AS p,
           COUNT(DISTINCT user_id)                                 AS n
    FROM stg.events
    WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    GROUP BY 1
),
checks AS (
    SELECT 'monthly active_users (блок 3)' AS check_name,
           COUNT(*) FILTER (WHERE a.n IS DISTINCT FROM b.n) AS mismatched
    FROM m_act a FULL JOIN s_act b USING (p)
    UNION ALL
    SELECT 'monthly buyers (блок 3)',
           COUNT(*) FILTER (WHERE a.n IS DISTINCT FROM b.n)
    FROM m_buy a FULL JOIN s_buy b USING (p)
    UNION ALL
    SELECT 'weekly wau (блок 4)',
           COUNT(*) FILTER (WHERE a.n IS DISTINCT FROM b.n)
    FROM mw_act a FULL JOIN sw_act b USING (p)
    UNION ALL
    SELECT 'weekly buyers (блок 4)',
           COUNT(*) FILTER (WHERE a.n IS DISTINCT FROM b.n)
    FROM mw_buy a FULL JOIN sw_buy b USING (p)
)
SELECT
    check_name,
    '0'                                                   AS expected,
    mismatched::text                                      AS actual,
    CASE WHEN mismatched = 0 THEN 'OK' ELSE 'FAIL' END    AS status
FROM checks;


-- =============================================================================
-- 6. Диагностика: распределение суммы заказа
--    Средний чек (AOV) чувствителен к крупным заказам. Если среднее заметно
--    выше медианы, в выводах нужно показывать оба значения и не обещать
--    «типичный чек» по среднему.
--    items_per_order показывает, сколько позиций в среднем в заказе (в данных
--    нет количества, одно событие = одна единица).
-- =============================================================================
SELECT
    COUNT(*)                                                            AS orders,
    ROUND(AVG(gmv), 2)                                                  AS mean_order,
    ROUND((PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gmv::float8))::numeric, 2) AS median_order,
    ROUND((PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gmv::float8))::numeric, 2) AS p90_order,
    ROUND((PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY gmv::float8))::numeric, 2) AS p99_order,
    MAX(gmv)                                                            AS max_order,
    ROUND(AVG(items_cnt), 2)                                            AS items_per_order,
    MAX(items_cnt)                                                      AS max_items_in_order
FROM mart.orders;
