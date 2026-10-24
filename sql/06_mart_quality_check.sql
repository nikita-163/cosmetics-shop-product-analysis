-- =============================================================================
-- 06_mart_quality_check.sql
-- Сверка витрин из 05_mart_sessions_orders.sql, 07_mart_user_activity_daily.sql и 08_mart_users.sql с stg.events.
--
-- Принцип: ожидаемые значения считаются из stg.events независимым запросом
-- (не копируются из ноутбуков и не вводятся руками), а фактические берутся из
-- витрины. Поэтому проверка остаётся верной при любом пересчёте данных.
--
-- Порядок запуска: 05, 07, 08, затем 06 (блоки 4 и 5 читают
-- mart.user_activity_daily и mart.users, которых до 07 и 08 ещё нет).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. mart.sessions: сверка с stg.events
-- -----------------------------------------------------------------------------
WITH actual AS (
    SELECT
        COUNT(*)::numeric                                   AS rows_total,
        COUNT(*) FILTER (WHERE has_purchase)::numeric       AS purchase_sessions,
        COUNT(*) FILTER (
            WHERE NOT (has_view OR has_cart OR has_remove_from_cart OR has_purchase)
        )::numeric                                          AS sessions_without_flags,
        COUNT(*) FILTER (WHERE duration_sec < 0)::numeric   AS negative_duration
    FROM mart.sessions
),
stg_pairs AS (
    -- пары (сессия, пользователь) без user_session IS NULL
    SELECT COUNT(*)::numeric AS pairs_total
    FROM (
        SELECT DISTINCT user_session, user_id
        FROM stg.events
        WHERE user_session IS NOT NULL
    ) AS d
),
stg_buyer_pairs AS (
    SELECT COUNT(*)::numeric AS pairs_with_purchase
    FROM (
        SELECT DISTINCT user_session, user_id
        FROM stg.events
        WHERE user_session IS NOT NULL
            AND event_type = 'purchase'
    ) AS d
)
SELECT
    c.check_name,
    c.expected::text AS expected,
    c.actual::text   AS actual,
    CASE WHEN c.expected = c.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM actual a
CROSS JOIN stg_pairs sp
CROSS JOIN stg_buyer_pairs sb
CROSS JOIN LATERAL (VALUES
    ('rows = distinct (user_session, user_id) in stg', sp.pairs_total,                a.rows_total),              -- зерно витрины совпадает с числом пар в stg
    ('sessions with has_purchase',                     sb.pairs_with_purchase,        a.purchase_sessions),       -- флаг покупки не потерян и не добавлен лишний
    ('sessions without any flag',                      0::numeric,                    a.sessions_without_flags),  -- 4 типа событий исчерпывающие: хоть один флаг у сессии есть
    ('sessions with negative duration',                0::numeric,                    a.negative_duration)        -- конец сессии не раньше начала
) AS c(check_name, expected, actual);


-- -----------------------------------------------------------------------------
-- 2. mart.orders: сверка с stg.events
--    Ожидаемые значения считаются независимо: заказы через DISTINCT, деньги
--    напрямую из stg. Фильтр по user_session здесь не ставится: по EDA у purchase
--    нет пропусков в user_session, и если они появятся, проверка это покажет.
-- -----------------------------------------------------------------------------
WITH actual AS (
    SELECT
        COUNT(*)::numeric                                   AS orders_total,
        SUM(gmv)::numeric                                   AS gmv_total,
        SUM(items_cnt)::numeric                             AS items_total,
        COUNT(*) FILTER (WHERE items_cnt < 1 OR gmv <= 0)::numeric
                                                            AS empty_orders
    FROM mart.orders
),
stg_orders AS (
    SELECT COUNT(*)::numeric AS orders_total
    FROM (
        SELECT DISTINCT user_session, user_id, event_time
        FROM stg.events
        WHERE event_type = 'purchase'
            AND NOT is_duplicate
            AND price IS NOT NULL
    ) AS d
),
stg_purchases AS (
    SELECT
        COALESCE(SUM(price), 0)::numeric AS gmv_total,
        COUNT(price)::numeric            AS items_total
    FROM stg.events
    WHERE event_type = 'purchase'
        AND NOT is_duplicate
),
orphan_orders AS (
    -- заказ без сессии с покупкой в mart.sessions или вне границ этой сессии
    SELECT COUNT(*)::numeric AS orphan_rows
    FROM mart.orders o
    LEFT JOIN mart.sessions s USING (user_session, user_id)
    WHERE s.user_session IS NULL
        OR NOT s.has_purchase
        OR o.order_time NOT BETWEEN s.session_start AND s.session_end
)
SELECT
    c.check_name,
    c.expected::text AS expected,
    c.actual::text   AS actual,
    CASE WHEN c.expected = c.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM actual a
CROSS JOIN stg_orders so
CROSS JOIN stg_purchases spu
CROSS JOIN orphan_orders oo
CROSS JOIN LATERAL (VALUES
    ('orders: rows = distinct (session, user, time) in stg', so.orders_total,    a.orders_total),   -- зерно витрины совпадает с независимым пересчётом заказов
    ('orders: sum(gmv) = GMV in stg',                        spu.gmv_total,      a.gmv_total),      -- ни одной копейки GMV не потеряно при группировке и исключении NULL-сессий
    ('orders: sum(items_cnt) = priced purchases in stg',     spu.items_total,    a.items_total),    -- то же для числа покупок с ценой
    ('orders: empty orders (items < 1 or gmv <= 0)',         0::numeric,         a.empty_orders),   -- у заказа есть хотя бы одна позиция и положительная сумма
    ('orders: without matching purchase session',            0::numeric,         oo.orphan_rows)    -- каждый заказ лежит внутри сессии с has_purchase
) AS c(check_name, expected, actual);


-- -----------------------------------------------------------------------------
-- 3. (справочно) Во сколько строк обошлось зерно (user_session, user_id)
--    Ожидается extra_rows >= 272: именно столько сессий имеют больше одного
--    user_id, и каждая даёт минимум одну лишнюю строку.
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                   AS rows_total,
    COUNT(DISTINCT user_session)               AS distinct_sessions,
    COUNT(*) - COUNT(DISTINCT user_session)    AS extra_rows
FROM mart.sessions;

-- -----------------------------------------------------------------------------
-- 4. mart.user_activity_daily: сверка с stg.events (07_mart_user_activity_daily.sql)
--    Ожидаемые значения считаются независимо: день берём тем же правилом
--    (UTC), но подсчёт идёт по DISTINCT, а не через группировку, как в витрине.
-- -----------------------------------------------------------------------------
WITH actual AS (
    SELECT
        COUNT(*)::numeric                                       AS rows_total,
        COUNT(DISTINCT user_id)::numeric                        AS users_total,
        COUNT(*) FILTER (WHERE has_purchase)::numeric           AS purchase_days,
        COUNT(*) FILTER (
            WHERE NOT (has_view OR has_cart OR has_remove_from_cart OR has_purchase)
        )::numeric                                              AS days_without_flags,
        MIN(activity_date)::text                                AS min_date,
        MAX(activity_date)::text                                AS max_date
    FROM mart.user_activity_daily
),
stg_days AS (
    SELECT
        COUNT(*)::numeric                                       AS days_total,
        COUNT(DISTINCT user_id)::numeric                        AS users_total,
        COUNT(*) FILTER (WHERE has_purchase)::numeric           AS purchase_days
    FROM (
        SELECT
            user_id,
            (event_time AT TIME ZONE 'UTC')::date               AS d,
            BOOL_OR(event_type = 'purchase')                    AS has_purchase
        FROM stg.events
        GROUP BY user_id, (event_time AT TIME ZONE 'UTC')::date
    ) AS t
)
SELECT
    c.check_name,
    c.expected,
    c.actual,
    CASE WHEN c.expected = c.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM actual a
CROSS JOIN stg_days s
CROSS JOIN LATERAL (VALUES
    ('daily: rows = distinct (user_id, day) in stg',  s.days_total::text,    a.rows_total::text),       -- зерно витрины совпадает с числом пар в stg
    ('daily: distinct users = users in stg',          s.users_total::text,   a.users_total::text),      -- ни один пользователь не потерян
    ('daily: days with has_purchase',                 s.purchase_days::text, a.purchase_days::text),    -- флаг покупки не потерян и не добавлен лишний
    ('daily: days without any flag',                  '0',                   a.days_without_flags::text), -- у каждого дня есть хотя бы один флаг
    ('daily: min activity_date (UTC)',                '2019-10-01',          a.min_date),               -- начало периода по 04_stg_quality_check
    ('daily: max activity_date (UTC)',                '2020-02-29',          a.max_date)                -- конец периода по 04_stg_quality_check
) AS c(check_name, expected, actual);


-- -----------------------------------------------------------------------------
-- 5. mart.users: сверка с stg.events и с витринами (08_mart_users.sql)
--    Число пользователей, заказов и GMV считаются заново из stg.events, а не из
--    других витрин: сверка должна ловить ошибки всей цепочки, а не только 08.
--    Логические проверки внутри таблицы (порядок дат, понедельник) считаются по
--    самой mart.users.
-- -----------------------------------------------------------------------------
WITH actual AS (
    SELECT
        COUNT(*)::numeric                                           AS users_total,
        COUNT(*) FILTER (WHERE has_purchase)::numeric               AS purchasers,
        COUNT(*) FILTER (WHERE orders_cnt >= 1)::numeric            AS buyers_with_order,
        SUM(orders_cnt)::numeric                                    AS orders_total,
        SUM(gmv)::numeric                                           AS gmv_total,
        SUM(priced_purchases_cnt)::numeric                          AS priced_purchases_total,
        -- second_order_time заполнено ровно у пользователей с >= 2 заказами
        COUNT(*) FILTER (
            WHERE (orders_cnt >= 2) IS DISTINCT FROM (second_order_time IS NOT NULL)
        )::numeric                                                  AS second_order_inconsistent,
        -- first_order_time заполнено ровно у пользователей с >= 1 заказом
        COUNT(*) FILTER (
            WHERE (orders_cnt >= 1) IS DISTINCT FROM (first_order_time IS NOT NULL)
        )::numeric                                                  AS first_order_inconsistent,
        -- второй заказ не раньше первого
        COUNT(*) FILTER (WHERE second_order_time < first_order_time)::numeric
                                                                    AS second_before_first,
        -- первый заказ не раньше первого дня активности (в UTC)
        COUNT(*) FILTER (
            WHERE (first_order_time AT TIME ZONE 'UTC')::date < first_activity_date
        )::numeric                                                  AS order_before_activity,
        -- cohort_week это понедельник (ISODOW = 1) и не позже первой активности
        COUNT(*) FILTER (
            WHERE EXTRACT(ISODOW FROM cohort_week) <> 1
                OR cohort_week > first_activity_date
        )::numeric                                                  AS bad_cohort_week
    FROM mart.users
),
stg_users AS (
    SELECT
        COUNT(DISTINCT user_id)::numeric                            AS users_total,
        COUNT(DISTINCT user_id) FILTER (
            WHERE event_type = 'purchase'
        )::numeric                                                  AS purchasers
    FROM stg.events
),
stg_orders AS (
    -- заказ = (сессия, пользователь, момент покупки) с покупкой без дубля и с ценой;
    -- затем считаем заказы, пользователей с заказом и деньги
    SELECT
        COUNT(*)::numeric                                           AS orders_total,
        COUNT(DISTINCT user_id)::numeric                            AS buyers_with_order,
        SUM(gmv)::numeric                                           AS gmv_total,
        SUM(priced_purchases)::numeric                              AS priced_purchases_total
    FROM (
        SELECT user_session, user_id, event_time,
            SUM(price)  AS gmv,
            COUNT(price) AS priced_purchases
        FROM stg.events
        WHERE event_type = 'purchase'
            AND NOT is_duplicate
            AND price IS NOT NULL
            AND user_session IS NOT NULL
        GROUP BY user_session, user_id, event_time
    ) AS o
)
SELECT
    c.check_name,
    c.expected,
    c.actual,
    CASE WHEN c.expected = c.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM actual a
CROSS JOIN stg_users su
CROSS JOIN stg_orders so
CROSS JOIN LATERAL (VALUES
    ('users: rows = distinct user_id in stg',          su.users_total::text,             a.users_total::text),             -- ни один пользователь не потерян и не задвоен
    ('users: has_purchase = users with purchase in stg', su.purchasers::text,             a.purchasers::text),              -- флаг покупки не потерян и не добавлен лишний
    ('users: orders_cnt >= 1 = buyers with order in stg', so.buyers_with_order::text,    a.buyers_with_order::text),       -- число пользователей с заказом
    ('users: sum(orders_cnt) = orders in stg',          so.orders_total::text,            a.orders_total::text),            -- число заказов сошлось с независимым пересчётом
    ('users: sum(gmv) = GMV of orders in stg',          so.gmv_total::text,               a.gmv_total::text),               -- ни одной копейки GMV не потеряно
    ('users: sum(priced_purchases_cnt)',                so.priced_purchases_total::text,  a.priced_purchases_total::text),  -- то же для числа покупок с ценой
    ('users: first_order_time filled iff orders_cnt >= 1',  '0',                          a.first_order_inconsistent::text),
    ('users: second_order_time filled iff orders_cnt >= 2', '0',                          a.second_order_inconsistent::text),
    ('users: second order before first',                '0',                              a.second_before_first::text),     -- порядок заказов не перепутан
    ('users: first order before first activity day',    '0',                              a.order_before_activity::text),   -- заказ не раньше первого дня активности
    ('users: cohort_week is Monday and <= first activity', '0',                           a.bad_cohort_week::text)          -- когорта посчитана по понедельникам
) AS c(check_name, expected, actual);
