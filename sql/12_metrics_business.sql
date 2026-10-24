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
--   * mart.sessions: деньги и заказы (одна строка = сессия пользователя);
--   * mart.user_activity_daily: активные пользователи (знаменатели);
--   * mart.users: итоги за весь период.
--
-- Правила (см. раздел 0 в docs/metrics.md):
--   * Заказ = строка mart.sessions с priced_purchases_cnt > 0. Деньги считаем
--     только по покупкам без дублей и с ценой не NULL (это уже учтено в gmv и
--     priced_purchases_cnt витрины).
--   * Заказ и его GMV относим к периоду first_order_time (UTC), а не session_start:
--     сессия может начаться в одну неделю, а покупка случиться в следующую.
--   * Известное ограничение: если в одной сессии покупки лежат по обе стороны
--     границы недели или месяца, весь GMV сессии уходит в период первой
--     покупки. Размер эффекта измеряет блок 5.2 и 5.3.
--   * Валюта в данных неизвестна: суммы в условных денежных единицах.
--   * Неделя с понедельника, UTC. Первая и последняя недели неполные.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. GMV, покупки, заказы, AOV по месяцам и за весь период
--    AOV = GMV / заказы (а не / покупки): в заказе может быть несколько товаров.
--    ROLLUP корректен: каждый заказ относится ровно к одному месяцу, поэтому
--    строка 'all' равна сумме месячных строк.
-- -----------------------------------------------------------------------------
WITH o AS (
    SELECT
        date_trunc('month', first_order_time AT TIME ZONE 'UTC')::date  AS month,
        gmv,
        priced_purchases_cnt
    FROM mart.sessions
    WHERE priced_purchases_cnt > 0
)
SELECT
    COALESCE(month::text, 'all')                    AS period,
    ROUND(SUM(gmv), 2)                              AS gmv,
    SUM(priced_purchases_cnt)                       AS purchases,
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
        date_trunc('week', first_order_time AT TIME ZONE 'UTC')::date   AS week_start,
        SUM(gmv)                                                        AS gmv,
        SUM(priced_purchases_cnt)                                       AS purchases,
        COUNT(*)                                                        AS orders
    FROM mart.sessions
    WHERE priced_purchases_cnt > 0
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
--    Диагностика к решению про знаменатель ARPPU: any_purchase_users считает всех
--    с любой покупкой, в том числе без цены. Разница между buyers и
--    any_purchase_users показывает, сколько платящих мы теряем, если брать
--    только покупки с ценой.
--
--    Период 'all': из mart.users (активные = все пользователи в витрине).
-- -----------------------------------------------------------------------------
WITH m_orders AS (
    SELECT
        date_trunc('month', first_order_time AT TIME ZONE 'UTC')::date  AS month,
        COUNT(DISTINCT user_id)                                         AS buyers,
        COUNT(*)                                                        AS orders,
        SUM(gmv)                                                        AS gmv
    FROM mart.sessions
    WHERE priced_purchases_cnt > 0
    GROUP BY 1
),
m_users AS (
    SELECT
        month,
        COUNT(*)                                        AS active_users,
        COUNT(*) FILTER (WHERE has_purchase)            AS any_purchase_users
    FROM (
        SELECT
            user_id,
            date_trunc('month', activity_date::timestamp)::date AS month,
            BOOL_OR(has_purchase)                               AS has_purchase
        FROM mart.user_activity_daily
        GROUP BY 1, 2
    ) um
    GROUP BY month
),
by_month AS (
    SELECT
        u.month::text                       AS period,
        u.active_users,
        u.any_purchase_users,
        COALESCE(o.buyers, 0)               AS buyers,
        COALESCE(o.orders, 0)               AS orders,
        COALESCE(o.gmv, 0)                  AS gmv
    FROM m_users u
    LEFT JOIN m_orders o ON o.month = u.month
),
whole AS (
    SELECT
        'all'                                                   AS period,
        COUNT(*)                                                AS active_users,
        COUNT(*) FILTER (WHERE has_purchase)                    AS any_purchase_users,
        COUNT(*) FILTER (WHERE orders_cnt >= 1)                 AS buyers,
        SUM(orders_cnt)                                         AS orders,
        SUM(gmv)                                                AS gmv
    FROM mart.users
)
SELECT
    period,
    active_users,
    buyers,
    any_purchase_users,
    orders,
    ROUND(gmv, 2)                                               AS gmv,
    ROUND(gmv / NULLIF(buyers, 0), 2)                           AS arppu,
    ROUND(gmv / NULLIF(any_purchase_users, 0), 2)               AS arppu_any_purchase_denominator,
    ROUND(orders::numeric / NULLIF(active_users, 0), 4)         AS orders_per_active,
    ROUND(orders::numeric / NULLIF(buyers, 0), 3)               AS orders_per_buyer
FROM (SELECT * FROM by_month UNION ALL SELECT * FROM whole) t
ORDER BY period = 'all', period;


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
        date_trunc('week', first_order_time AT TIME ZONE 'UTC')::date   AS week_start,
        COUNT(DISTINCT user_id)                                         AS buyers,
        COUNT(*)                                                        AS orders,
        SUM(gmv)                                                        AS gmv
    FROM mart.sessions
    WHERE priced_purchases_cnt > 0
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
-- =============================================================================

-- 5.1. Итоги за весь период. Должно совпасть точно (OK во всех строках).
--      Заказы в stg: число уникальных пар (user_session, user_id) с покупкой
--      без дубля и с ценой; user_session IS NULL исключён, как в mart.sessions.
WITH from_mart AS (
    SELECT
        SUM(gmv)                                            AS gmv,
        SUM(priced_purchases_cnt)                           AS purchases,
        COUNT(*) FILTER (WHERE priced_purchases_cnt > 0)    AS orders
    FROM mart.sessions
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
             SELECT 1 FROM stg.events
              WHERE event_type = 'purchase' AND NOT is_duplicate
                AND price IS NOT NULL AND user_session IS NOT NULL
              GROUP BY user_session, user_id
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
    ('GMV: mart.sessions vs stg.events',      s.gmv::numeric,       m.gmv::numeric),
    ('GMV: mart.users vs stg.events',         s.gmv::numeric,       u.gmv::numeric),
    ('purchases with price',                  s.purchases::numeric, m.purchases::numeric),
    ('orders: mart.sessions vs stg.events',   s.orders::numeric,    m.orders::numeric),
    ('orders: mart.users vs mart.sessions',   m.orders::numeric,    u.orders::numeric),
    ('purchases without user_session',        0::numeric,           s.purchases_without_session::numeric)
) AS x(check_name, expected, actual);


-- 5.2. GMV по месяцам: заказы по first_order_time (витрина) против покупок по
--      event_time (stg). Итоги за период равны (см. 5.1), а по месяцам
--      возможен небольшой сдвиг из-за сессий, пересекающих границу месяца.
--      CHECK означает «посмотреть глазами», а не ошибку; порог 0.1%
--      выбран как ориентир, не как стандарт.
WITH m AS (
    SELECT
        date_trunc('month', first_order_time AT TIME ZONE 'UTC')::date AS month,
        SUM(gmv)                                                       AS gmv
    FROM mart.sessions
    WHERE priced_purchases_cnt > 0
    GROUP BY 1
),
s AS (
    SELECT
        date_trunc('month', event_time AT TIME ZONE 'UTC')::date       AS month,
        SUM(price)                                                     AS gmv
    FROM stg.events
    WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    GROUP BY 1
)
SELECT
    COALESCE(m.month, s.month)                                  AS month,
    ROUND(m.gmv, 2)                                             AS gmv_mart,
    ROUND(s.gmv, 2)                                             AS gmv_stg,
    ROUND(m.gmv - s.gmv, 2)                                     AS diff,
    ROUND(100.0 * (m.gmv - s.gmv) / NULLIF(s.gmv, 0), 4)        AS diff_pct,
    CASE WHEN ABS(100.0 * (m.gmv - s.gmv) / NULLIF(s.gmv, 0)) <= 0.1
         THEN 'OK' ELSE 'CHECK' END                             AS status
FROM m
FULL JOIN s ON s.month = m.month
ORDER BY 1;


-- 5.3. GMV по неделям: то же сравнение. На границе недели (воскресенье,
--      полночь UTC) сдвиг заметнее, чем на границе месяца.
WITH m AS (
    SELECT
        date_trunc('week', first_order_time AT TIME ZONE 'UTC')::date  AS week_start,
        SUM(gmv)                                                       AS gmv
    FROM mart.sessions
    WHERE priced_purchases_cnt > 0
    GROUP BY 1
),
s AS (
    SELECT
        date_trunc('week', event_time AT TIME ZONE 'UTC')::date        AS week_start,
        SUM(price)                                                     AS gmv
    FROM stg.events
    WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    GROUP BY 1
)
SELECT
    COALESCE(m.week_start, s.week_start)                        AS week_start,
    ROUND(m.gmv, 2)                                             AS gmv_mart,
    ROUND(s.gmv, 2)                                             AS gmv_stg,
    ROUND(m.gmv - s.gmv, 2)                                     AS diff,
    ROUND(100.0 * (m.gmv - s.gmv) / NULLIF(s.gmv, 0), 4)        AS diff_pct,
    CASE WHEN ABS(100.0 * (m.gmv - s.gmv) / NULLIF(s.gmv, 0)) <= 0.1
         THEN 'OK' ELSE 'CHECK' END                             AS status
FROM m
FULL JOIN s ON s.week_start = m.week_start
ORDER BY 1;


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
    ROUND(AVG(priced_purchases_cnt), 2)                                 AS items_per_order,
    MAX(priced_purchases_cnt)                                           AS max_items_in_order
FROM mart.sessions
WHERE priced_purchases_cnt > 0;
