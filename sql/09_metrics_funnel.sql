-- =============================================================================
-- 09_metrics_funnel.sql
-- Воронка и конверсия (раздел 1 в docs/metrics.md):
--   1. Пользователи на шагах воронки, step conversion, conversion rate
--      (весь период и по месяцам)
--   2. Session conversion rate и abandonment rate (весь период и по месяцам)
--   3. Доля удалений из корзины (весь период и по месяцам)
--   4. Сверка с независимым источником (stg.events)
--
-- Где запускать: подключение к `cosmetics_shop`, каждый запрос отдельно
-- (Ctrl+Enter) или весь файл через Execute Script (Alt+X, результат в
-- отдельных вкладках). Запускать после 05, 07 и 08.
--
-- Правила (см. раздел 0 в docs/metrics.md):
--   * Воронка строгая: на шаге N остаются только прошедшие шаг N-1.
--     "Прошёл" = за период было хотя бы одно событие типа (порядок событий во
--     времени не проверяем, это ограничение метрики).
--   * Поведение считаем по всем событиям, включая дубли и покупки с ценой NULL:
--     has_purchase, а не priced_purchases_cnt.
--   * Месяц и день в UTC. Сессию относим к месяцу её начала (session_start).
--   * 100.0 * ... гарантирует деление в numeric: 100 * a / b на целых числах
--     обрезало бы дробную часть. NULLIF(..., 0) защищает от деления на ноль.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Разведка: как часто воронка «строгая» отбрасывает покупателей
--    Покупатели без view или без cart в воронку не попадут, поэтому сначала
--    смотрим, сколько их. Если доля заметная, это нужно будет написать в выводах.
-- -----------------------------------------------------------------------------
SELECT
    'users'                                                     AS grain,
    COUNT(*) FILTER (WHERE has_purchase)                        AS with_purchase,
    COUNT(*) FILTER (WHERE has_purchase AND NOT has_view)       AS purchase_no_view,
    COUNT(*) FILTER (WHERE has_purchase AND NOT has_cart)       AS purchase_no_cart,
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_purchase AND NOT has_view)
          / NULLIF(COUNT(*) FILTER (WHERE has_purchase), 0), 2) AS purchase_no_view_pct
FROM mart.users
UNION ALL
SELECT
    'sessions',
    COUNT(*) FILTER (WHERE has_purchase),
    COUNT(*) FILTER (WHERE has_purchase AND NOT has_view),
    COUNT(*) FILTER (WHERE has_purchase AND NOT has_cart),
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_purchase AND NOT has_view)
          / NULLIF(COUNT(*) FILTER (WHERE has_purchase), 0), 2)
FROM mart.sessions;


-- -----------------------------------------------------------------------------
-- 1.1. Воронка по пользователям за весь период (источник: mart.users)
--      step_conversion_pct  : доля от предыдущего шага (Step conversion rate)
--      pct_of_view          : доля от шага view; для purchase это
--                             Conversion rate (view -> purchase)
-- -----------------------------------------------------------------------------
WITH counts AS (
    SELECT
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users
    FROM mart.users
)
SELECT
    f.step_no,
    f.step_name,
    f.users,
    ROUND(100.0 * f.users / FIRST_VALUE(f.users) OVER (ORDER BY f.step_no), 2) AS pct_of_view,
    ROUND(100.0 * f.users / LAG(f.users)         OVER (ORDER BY f.step_no), 2) AS step_conversion_pct
FROM counts c
CROSS JOIN LATERAL (VALUES
    (1, 'view',     c.view_users),
    (2, 'cart',     c.cart_users),
    (3, 'purchase', c.purchase_users)
) AS f(step_no, step_name, users)
ORDER BY f.step_no;


-- -----------------------------------------------------------------------------
-- 1.2. Воронка по пользователям по месяцам (источник: mart.user_activity_daily)
--      Сначала сворачиваем дни до пары (пользователь, месяц), потом считаем
--      пользователей. Пользователь, активный в двух месяцах, попадёт в оба:
--      поэтому строку «всего» из месячных строк суммированием получить нельзя,
--      её даёт запрос 1.1.
-- -----------------------------------------------------------------------------
WITH user_month AS (
    SELECT
        user_id,
        date_trunc('month', activity_date::timestamp)::date     AS month,
        BOOL_OR(has_view)                                       AS has_view,
        BOOL_OR(has_cart)                                       AS has_cart,
        BOOL_OR(has_purchase)                                   AS has_purchase
    FROM mart.user_activity_daily
    GROUP BY user_id, month
),
counts AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users
    FROM user_month
    GROUP BY month
)
SELECT
    month,
    view_users,
    cart_users,
    purchase_users,
    ROUND(100.0 * cart_users     / NULLIF(view_users, 0), 2)    AS view_to_cart_pct,
    ROUND(100.0 * purchase_users / NULLIF(cart_users, 0), 2)    AS cart_to_purchase_pct,
    ROUND(100.0 * purchase_users / NULLIF(view_users, 0), 2)    AS conversion_pct
FROM counts
ORDER BY month;


-- -----------------------------------------------------------------------------
-- 2. Session conversion rate и abandonment rate (источник: mart.sessions)
--    Каждая сессия принадлежит ровно одному месяцу (по session_start), поэтому
--    здесь ROLLUP корректен: строка с month IS NULL это итог за весь период.
--
--    session_conversion_pct = сессии с view+cart+purchase / сессии с view
--    abandonment_pct        = 1 - (сессии с cart+purchase / сессии с cart)
--    Abandonment это оценка сверху: корзина, оформленная в другой сессии,
--    считается брошенной (см. раздел 6 в docs/metrics.md).
-- -----------------------------------------------------------------------------
WITH s AS (
    SELECT
        date_trunc('month', session_start AT TIME ZONE 'UTC')::date AS month,
        has_view, has_cart, has_purchase
    FROM mart.sessions
),
counts AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_sessions,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS converted_sessions,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_sessions,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_sessions
    FROM s
    GROUP BY ROLLUP (month)
)
SELECT
    COALESCE(month::text, 'all')                                AS period,
    view_sessions,
    converted_sessions,
    ROUND(100.0 * converted_sessions / NULLIF(view_sessions, 0), 2)         AS session_conversion_pct,
    cart_sessions,
    cart_purchase_sessions,
    ROUND(100.0 - 100.0 * cart_purchase_sessions / NULLIF(cart_sessions, 0), 2) AS abandonment_pct
FROM counts
ORDER BY month NULLS LAST;


-- -----------------------------------------------------------------------------
-- 3. Доля удалений из корзины (пользователи)
--    cart_remove_users / cart_users, где знаменатель только пользователи с cart.
--    Весь период берём из mart.users, месяцы из mart.user_activity_daily.
-- -----------------------------------------------------------------------------
WITH user_month AS (
    SELECT
        user_id,
        date_trunc('month', activity_date::timestamp)::date     AS month,
        BOOL_OR(has_cart)                                       AS has_cart,
        BOOL_OR(has_remove_from_cart)                           AS has_remove_from_cart
    FROM mart.user_activity_daily
    GROUP BY user_id, month
),
by_month AS (
    SELECT
        month::text                                             AS period,
        COUNT(*) FILTER (WHERE has_cart)                        AS cart_users,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS cart_remove_users
    FROM user_month
    GROUP BY month
),
whole AS (
    SELECT
        'all'                                                   AS period,
        COUNT(*) FILTER (WHERE has_cart)                        AS cart_users,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS cart_remove_users
    FROM mart.users
)
SELECT
    period,
    cart_users,
    cart_remove_users,
    ROUND(100.0 * cart_remove_users / NULLIF(cart_users, 0), 2) AS cart_remove_pct
FROM (SELECT * FROM by_month UNION ALL SELECT * FROM whole) t
ORDER BY period = 'all', period;


-- =============================================================================
-- 4. Сверка: те же цифры из stg.events напрямую, без витрин
--    Идея: витрина могла получиться с ошибкой агрегации, и повторный расчёт из
--    её же данных эту ошибку не найдёт. Поэтому считаем вторым способом из
--    исходной таблицы. Ожидаем OK во всех строках.
-- =============================================================================

-- 4.1. Воронка по пользователям за весь период: mart.users против stg.events
WITH from_mart AS (
    SELECT
        COUNT(*) FILTER (WHERE has_view)                                AS v,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS c,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS p
    FROM mart.users
),
from_stg AS (
    SELECT
        COUNT(*) FILTER (WHERE has_view)                                AS v,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS c,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS p
    FROM (
        SELECT
            user_id,
            BOOL_OR(event_type = 'view')        AS has_view,
            BOOL_OR(event_type = 'cart')        AS has_cart,
            BOOL_OR(event_type = 'purchase')    AS has_purchase
        FROM stg.events
        GROUP BY user_id
    ) u
)
SELECT
    x.check_name,
    x.mart_value,
    x.stg_value,
    CASE WHEN x.mart_value = x.stg_value THEN 'OK' ELSE 'FAIL' END AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('view users',     m.v, s.v),
    ('cart users',     m.c, s.c),
    ('purchase users', m.p, s.p)
) AS x(check_name, mart_value, stg_value);


-- 4.2. Сессионные метрики за весь период: mart.sessions против stg.events
--      Группировка по (user_session, user_id) та же, что зерно витрины;
--      user_session IS NULL исключён так же, как в витрине.
WITH from_mart AS (
    SELECT
        COUNT(*) FILTER (WHERE has_view)                                AS view_s,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS conv_s,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_s,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_s
    FROM mart.sessions
),
from_stg AS (
    SELECT
        COUNT(*) FILTER (WHERE has_view)                                AS view_s,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS conv_s,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_s,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_s
    FROM (
        SELECT
            BOOL_OR(event_type = 'view')        AS has_view,
            BOOL_OR(event_type = 'cart')        AS has_cart,
            BOOL_OR(event_type = 'purchase')    AS has_purchase
        FROM stg.events
        WHERE user_session IS NOT NULL
        GROUP BY user_session, user_id
    ) s
)
SELECT
    x.check_name,
    x.mart_value,
    x.stg_value,
    CASE WHEN x.mart_value = x.stg_value THEN 'OK' ELSE 'FAIL' END AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('view sessions',          m.view_s,        s.view_s),
    ('converted sessions',     m.conv_s,        s.conv_s),
    ('cart sessions',          m.cart_s,        s.cart_s),
    ('cart+purchase sessions', m.cart_purchase_s, s.cart_purchase_s)
) AS x(check_name, mart_value, stg_value);


-- 4.3. Воронка по месяцам: mart.user_activity_daily против stg.events
--      День и месяц в UTC в обоих источниках. FULL JOIN покажет и месяц,
--      который есть только в одном из источников.
WITH from_daily AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users
    FROM (
        SELECT
            user_id,
            date_trunc('month', activity_date::timestamp)::date AS month,
            BOOL_OR(has_view)                                   AS has_view,
            BOOL_OR(has_cart)                                   AS has_cart,
            BOOL_OR(has_purchase)                               AS has_purchase
        FROM mart.user_activity_daily
        GROUP BY user_id, month
    ) um
    GROUP BY month
),
from_stg AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users
    FROM (
        SELECT
            user_id,
            date_trunc('month', event_time AT TIME ZONE 'UTC')::date AS month,
            BOOL_OR(event_type = 'view')                             AS has_view,
            BOOL_OR(event_type = 'cart')                             AS has_cart,
            BOOL_OR(event_type = 'purchase')                         AS has_purchase
        FROM stg.events
        GROUP BY user_id, month
    ) um
    GROUP BY month
)
SELECT
    COALESCE(d.month, s.month)                  AS month,
    d.view_users      AS daily_view,      s.view_users      AS stg_view,
    d.cart_users      AS daily_cart,      s.cart_users      AS stg_cart,
    d.purchase_users  AS daily_purchase,  s.purchase_users  AS stg_purchase,
    CASE WHEN (d.view_users, d.cart_users, d.purchase_users)
              IS NOT DISTINCT FROM (s.view_users, s.cart_users, s.purchase_users)
         THEN 'OK' ELSE 'FAIL' END              AS status
FROM from_daily d
FULL JOIN from_stg s ON s.month = d.month
ORDER BY month;
