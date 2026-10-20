-- =============================================================================
-- 08_mart_users.sql
-- Витрина mart.users, построенная из mart.user_activity_daily (активность) и mart.sessions (заказы).
-- Запускать только после 05_mart_sessions.sql и 07_mart_user_activity_daily.sql.
-- =============================================================================
--
-- Правила:
--   * В витрине все пользователи из stg.events, в том числе те, у кого все
--     события с user_session IS NULL: они есть в mart.user_activity_daily.
--   * Заказ = строка mart.sessions с priced_purchases_cnt > 0 (см. 05_mart_sessions.sql).
--     orders_cnt, gmv, first_order_time, second_order_time считаются по заказам;
--     has_purchase это любая покупка (как в воронке), поэтому у пользователя может
--     быть has_purchase = true при orders_cnt = 0 (все его покупки без цены).
--   * Сессия, поделённая между пользователями (272 случая), даёт заказ каждому из
--     них, у кого в ней есть покупка с ценой. Деньги при этом не дублируются:
--     gmv строки считается только по событиям этого user_id.
--   * cohort_week: понедельник недели первой активности (date_trunc('week')).
--     Данные начинаются во вторник 1 окт 2019, поэтому первая когорта неполная
--     и включает старых клиентов (см. ограничения в README).
--   * День считается в UTC (activity_date уже в UTC).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- mart.users: одна строка на пользователя (user_id) за весь период.
--
--    Зерно: (user_id, activity_date)
--
--    Применение:
--      1. воронка по пользователям за весь период: has_view -> has_cart -> has_purchase;
--      2. когорты: cohort_week (неделя первой активности);
--      3. Repeat purchase rate: orders_cnt >= 2 / orders_cnt >= 1;
--      4. время до повторной покупки: second_order_time - first_order_time;
--      5. ARPPU и среднее число заказов на пользователя: gmv, orders_cnt.
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS mart;

DROP TABLE IF EXISTS mart.users;

CREATE TABLE mart.users AS
WITH activity AS (
    -- поведение пользователя за весь период, из дневной витрины
    SELECT
        user_id,
        MIN(activity_date)                      AS first_activity_date,
        MAX(activity_date)                      AS last_activity_date,
        BOOL_OR(has_view)                       AS has_view,
        BOOL_OR(has_cart)                       AS has_cart,
        BOOL_OR(has_remove_from_cart)           AS has_remove_from_cart,
        BOOL_OR(has_purchase)                   AS has_purchase
    FROM mart.user_activity_daily
    GROUP BY user_id
),
order_agg AS (
    -- деньги и заказы пользователя из сессий
    SELECT
        user_id,
        COUNT(*) FILTER (WHERE priced_purchases_cnt > 0)    AS orders_cnt,
        SUM(priced_purchases_cnt)                           AS priced_purchases_cnt,
        SUM(gmv)                                            AS gmv,
        MIN(first_order_time)                               AS first_order_time
    FROM mart.sessions
    GROUP BY user_id
),
second_order AS (
    -- Второй заказ: заказы пользователя нумеруются по времени. При равном
    -- времени порядок задаёт user_session, иначе номер был бы случайным.
    SELECT user_id, first_order_time AS second_order_time
    FROM (
        SELECT
            user_id,
            first_order_time,
            ROW_NUMBER() OVER (
                PARTITION BY user_id
                ORDER BY first_order_time, user_session
            ) AS order_num
        FROM mart.sessions
        WHERE priced_purchases_cnt > 0
    ) AS ranked
    WHERE order_num = 2
)
SELECT
    a.user_id,
    a.first_activity_date,
    a.last_activity_date,
    date_trunc('week', a.first_activity_date)::date     AS cohort_week,     -- понедельник
    a.has_view,
    a.has_cart,
    a.has_remove_from_cart,
    a.has_purchase,
    -- у пользователей без сессий (только события с user_session IS NULL) строки в
    -- order_agg нет: заказов и денег у них нет по определению, поэтому 0, а не NULL
    COALESCE(o.orders_cnt, 0)                           AS orders_cnt,
    COALESCE(o.priced_purchases_cnt, 0)                 AS priced_purchases_cnt,
    COALESCE(o.gmv, 0)                                  AS gmv,
    o.first_order_time,                                 -- UTC; NULL, если заказов нет
    s.second_order_time                                 -- UTC; NULL, если заказов меньше двух
FROM activity a
LEFT JOIN order_agg    o ON o.user_id = a.user_id
LEFT JOIN second_order s ON s.user_id = a.user_id;

-- Первичный ключ фиксирует зерно: одна строка на пользователя.
ALTER TABLE mart.users ADD PRIMARY KEY (user_id);

COMMENT ON TABLE  mart.users IS
    'Одна строка на user_id за весь период. Источники: mart.user_activity_daily (активность) и mart.sessions (заказы).';
COMMENT ON COLUMN mart.users.cohort_week IS
    'Понедельник недели первой активности (UTC). Первая когорта неполная: данные начинаются во вторник 2019-10-01.';
COMMENT ON COLUMN mart.users.has_purchase IS
    'Была хотя бы одна покупка, в том числе без цены. Для воронки. Для заказов и денег используй orders_cnt и gmv.';
COMMENT ON COLUMN mart.users.orders_cnt IS
    'Число сессий пользователя с priced_purchases_cnt > 0 (заказ с известной ценой).';
COMMENT ON COLUMN mart.users.gmv IS
    'Сумма gmv по сессиям пользователя (без дублей и покупок с ценой NULL); 0, если заказов нет.';
COMMENT ON COLUMN mart.users.first_order_time IS
    'Время первого заказа с известной ценой, UTC; NULL, если заказов нет.';
COMMENT ON COLUMN mart.users.second_order_time IS
    'Время второго заказа с известной ценой, UTC; NULL, если заказов меньше двух.';

-- Без ANALYZE планировщик не знает распределения данных в новой таблице.
ANALYZE mart.users;
