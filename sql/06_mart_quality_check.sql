-- =============================================================================
-- 06_mart_quality_check.sql
-- Сверка витрин из 05_mart_sessions.sql, 07_mart_user_activity_daily.sql и 08_mart_users.sql с stg.events.
--
-- Принцип: ожидаемые значения считаются из stg.events независимым запросом
-- (не копируются из ноутбуков и не вводятся руками), а фактические берутся из
-- витрины. Поэтому проверка остаётся верной при любом пересчёте данных.
--
-- Порядок запуска: 05, 07, 08, затем 06 (блоки 3 и 4 читают
-- mart.user_activity_daily и mart.users, которых до 07 и 08 ещё нет).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. mart.sessions: сверка с stg.events
-- -----------------------------------------------------------------------------
WITH actual AS (
    SELECT
        COUNT(*)::numeric                                   AS rows_total,
        COUNT(*) FILTER (WHERE has_purchase)::numeric       AS purchase_sessions,
        SUM(gmv)::numeric                                   AS gmv_total,
        SUM(priced_purchases_cnt)::numeric                  AS priced_purchases_total,
        COUNT(*) FILTER (
            WHERE NOT (has_view OR has_cart OR has_remove_from_cart OR has_purchase)
        )::numeric                                          AS sessions_without_flags,
        COUNT(*) FILTER (WHERE duration_sec < 0)::numeric   AS negative_duration,
        -- first_order_time должен быть заполнен ровно у сессий-заказов
        COUNT(*) FILTER (
            WHERE (priced_purchases_cnt > 0) IS DISTINCT FROM (first_order_time IS NOT NULL)
        )::numeric                                          AS order_time_inconsistent
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
),
stg_purchases AS (
    -- Без фильтра по user_session: по EDA у purchase нет пропусков в user_session
    SELECT
        COALESCE(SUM(price), 0)::numeric AS gmv_total,
        COUNT(price)::numeric            AS priced_purchases_total
    FROM stg.events
    WHERE event_type = 'purchase'
        AND NOT is_duplicate
),
stg_first_order AS (
    -- момент первого заказа по каждой паре, посчитанный заново из stg
    SELECT user_session, user_id, MIN(event_time) AS first_order_time
    FROM stg.events
    WHERE event_type = 'purchase'
        AND NOT is_duplicate
        AND price IS NOT NULL
        AND user_session IS NOT NULL
    GROUP BY user_session, user_id
),
order_time_check AS (
    -- Витрина и stg сравниваются в обе стороны: LEFT JOIN от витрины ловит
    -- «в витрине время есть, в stg нет» и разные значения, а у сессий без заказа
    -- в stg_first_order строки нет, и NULL против NULL совпадает.
    -- IS DISTINCT FROM, а не <>: сравнение с NULL через <> даёт NULL, и случай
    -- «в витрине NULL, а в stg время есть» не попал бы в счёт.
    SELECT COUNT(*)::numeric AS mismatched_rows
    FROM mart.sessions m
    LEFT JOIN stg_first_order s USING (user_session, user_id)
    WHERE m.first_order_time IS DISTINCT FROM s.first_order_time
)
SELECT
    c.check_name,
    c.expected::text AS expected,
    c.actual::text   AS actual,
    CASE WHEN c.expected = c.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM actual a
CROSS JOIN stg_pairs sp
CROSS JOIN stg_buyer_pairs sb
CROSS JOIN stg_purchases spu
CROSS JOIN order_time_check otc
CROSS JOIN LATERAL (VALUES
    ('rows = distinct (user_session, user_id) in stg', sp.pairs_total,                a.rows_total),              -- зерно витрины совпадает с числом пар в stg
    ('sessions with has_purchase',                     sb.pairs_with_purchase,        a.purchase_sessions),       -- флаг покупки не потерян и не добавлен лишний
    ('sum(gmv) = GMV in stg',                          spu.gmv_total,                 a.gmv_total),               -- ни одной копейки GMV не потеряно при группировке и исключении NULL-сессий
    ('sum(priced_purchases_cnt)',                      spu.priced_purchases_total,    a.priced_purchases_total),  -- то же для числа покупок с ценой
    ('sessions without any flag',                      0::numeric,                    a.sessions_without_flags),  -- 4 типа событий исчерпывающие: хоть один флаг у сессии есть
    ('sessions with negative duration',                0::numeric,                    a.negative_duration),       -- конец сессии не раньше начала
    ('first_order_time filled iff priced_purchases_cnt > 0', 0::numeric,              a.order_time_inconsistent), -- время заказа есть у каждой сессии-заказа и нет у остальных
    ('first_order_time = value recomputed from stg',   0::numeric,                    otc.mismatched_rows)        -- время первого заказа совпало с независимым пересчётом из stg
) AS c(check_name, expected, actual);


-- -----------------------------------------------------------------------------
-- 2. (справочно) Во сколько строк обошлось зерно (user_session, user_id)
--    Ожидается extra_rows >= 272: именно столько сессий имеют больше одного
--    user_id, и каждая даёт минимум одну лишнюю строку.
-- -----------------------------------------------------------------------------
SELECT
    COUNT(*)                                   AS rows_total,
    COUNT(DISTINCT user_session)               AS distinct_sessions,
    COUNT(*) - COUNT(DISTINCT user_session)    AS extra_rows
FROM mart.sessions;

-- -----------------------------------------------------------------------------
-- 3. mart.user_activity_daily: сверка с stg.events (07_mart_user_activity_daily.sql)
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
-- 4. mart.users: сверка с stg.events и с витринами (08_mart_users.sql)
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
    -- заказ = пара (сессия, пользователь) с покупкой без дубля и с ценой; 
    -- затем считаем заказы, пользователей с заказом и деньги
    SELECT
        COUNT(*)::numeric                                           AS orders_total,
        COUNT(DISTINCT user_id)::numeric                            AS buyers_with_order,
        SUM(gmv)::numeric                                           AS gmv_total,
        SUM(priced_purchases)::numeric                              AS priced_purchases_total
    FROM (
        SELECT user_session, user_id,
            SUM(price)  AS gmv,
            COUNT(price) AS priced_purchases
        FROM stg.events
        WHERE event_type = 'purchase'
            AND NOT is_duplicate
            AND price IS NOT NULL
            AND user_session IS NOT NULL
        GROUP BY user_session, user_id
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
