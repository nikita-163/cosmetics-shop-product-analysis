-- =============================================================================
-- 10_metrics_activity.sql
-- Метрики активности (раздел 2 в docs/metrics.md):
--   1. DAU (по дням)
--   2. WAU (по неделям, с флагом is_full_week)
--   3. MAU (по месяцам)
--   4. Stickiness (среднее DAU за месяц / MAU)
--   5. Сверка с независимым источником (stg.events)
--
-- Где запускать: подключение к `cosmetics_shop`, каждый запрос отдельно
-- (Ctrl+Enter) или весь файл через Execute Script (Alt+X). Запускать после 07.
--
-- Источник: mart.user_activity_daily (одна строка на пользователя и день UTC).
-- Активный пользователь = любое событие любого типа за период, включая дубли
-- и строки с user_session IS NULL: человек всё равно был активен.
--
-- Правила:
--   * День, неделя (с понедельника) и месяц в UTC.
--   * Первая (1-6 окт) и последняя (24-29 фев) недели неполные, поэтому у
--     недельных строк есть is_full_week. Он выводится из данных: неделя полная,
--     если в ней есть строки за все 7 дней.
--   * WAU и MAU считаем напрямую как число уникальных пользователей за период.
--     Суммировать DAU нельзя: один человек заходит несколько дней.
--   * activity_date::timestamp перед date_trunc: у date_trunc нет варианта для
--     типа date, PostgreSQL неявно приводит дату к timestamptz по поясу сессии
--     клиента. Явное приведение к timestamp от настроек клиента не зависит.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. DAU
--    Первичный ключ витрины (user_id, activity_date) гарантирует одну строку
--    на пользователя и день, поэтому число строк за день и есть число
--    уникальных пользователей, DISTINCT не нужен (и работает быстрее).
-- -----------------------------------------------------------------------------
SELECT
    activity_date,
    COUNT(*) AS dau
FROM mart.user_activity_daily
GROUP BY activity_date
ORDER BY activity_date;


-- -----------------------------------------------------------------------------
-- 2. WAU
--    Здесь DISTINCT обязателен: на неделю приходится до 7 строк одного
--    пользователя.
-- -----------------------------------------------------------------------------
SELECT
    date_trunc('week', activity_date::timestamp)::date  AS week_start,   -- понедельник
    COUNT(DISTINCT user_id)                             AS wau,
    COUNT(DISTINCT activity_date)                       AS days_with_data,
    COUNT(DISTINCT activity_date) = 7                   AS is_full_week
FROM mart.user_activity_daily
GROUP BY week_start
ORDER BY week_start;


-- -----------------------------------------------------------------------------
-- 3. MAU
-- -----------------------------------------------------------------------------
SELECT
    date_trunc('month', activity_date::timestamp)::date AS month,
    COUNT(DISTINCT user_id)                             AS mau
FROM mart.user_activity_daily
GROUP BY month
ORDER BY month;


-- -----------------------------------------------------------------------------
-- 4. Stickiness = среднее DAU за месяц / MAU того же месяца
--    avg_dau усредняется по дням, которые есть в данных. days_with_data и
--    days_in_month выведены рядом: если они разойдутся, среднее было бы
--    посчитано не по всем календарным дням, и это сразу видно.
-- -----------------------------------------------------------------------------
WITH dau AS (
    SELECT activity_date, COUNT(*) AS dau
    FROM mart.user_activity_daily
    GROUP BY activity_date
),
dau_month AS (
    SELECT
        date_trunc('month', activity_date::timestamp)::date AS month,
        AVG(dau)                                            AS avg_dau,
        COUNT(*)                                            AS days_with_data
    FROM dau
    GROUP BY month
),
mau AS (
    SELECT
        date_trunc('month', activity_date::timestamp)::date AS month,
        COUNT(DISTINCT user_id)                             AS mau
    FROM mart.user_activity_daily
    GROUP BY month
)
SELECT
    m.month,
    ROUND(d.avg_dau, 1)                                         AS avg_dau,
    m.mau,
    d.days_with_data,
    EXTRACT(DAY FROM (m.month + INTERVAL '1 month' - INTERVAL '1 day'))::int AS days_in_month,
    ROUND(100.0 * d.avg_dau / NULLIF(m.mau, 0), 2)              AS stickiness_pct
FROM mau m
JOIN dau_month d ON d.month = m.month
ORDER BY m.month;


-- =============================================================================
-- 5. Сверка: те же цифры из stg.events напрямую, без витрины
--    Витрину мог испортить неверный GROUP BY или часовой пояс, поэтому считаем
--    из исходной таблицы. День, неделя и месяц там тоже в UTC
--    (AT TIME ZONE 'UTC'). Ожидаем OK во всех строках.
-- =============================================================================

-- 5.1. DAU по дням: сколько дней сравнили и сколько из них не совпало
WITH d AS (
    SELECT activity_date AS day, COUNT(*) AS dau
    FROM mart.user_activity_daily
    GROUP BY activity_date
),
s AS (
    SELECT (event_time AT TIME ZONE 'UTC')::date AS day, COUNT(DISTINCT user_id) AS dau
    FROM stg.events
    GROUP BY 1
)
SELECT
    COUNT(*)                                                AS days_compared,
    COUNT(*) FILTER (WHERE d.dau IS DISTINCT FROM s.dau)    AS days_mismatch,
    CASE WHEN COUNT(*) FILTER (WHERE d.dau IS DISTINCT FROM s.dau) = 0
         THEN 'OK' ELSE 'FAIL' END                          AS status
FROM d
FULL JOIN s USING (day);


-- 5.2. WAU по неделям
WITH d AS (
    SELECT
        date_trunc('week', activity_date::timestamp)::date AS week_start,
        COUNT(DISTINCT user_id)                            AS wau
    FROM mart.user_activity_daily
    GROUP BY 1
),
s AS (
    SELECT
        date_trunc('week', event_time AT TIME ZONE 'UTC')::date AS week_start,
        COUNT(DISTINCT user_id)                                 AS wau
    FROM stg.events
    GROUP BY 1
)
SELECT
    COUNT(*)                                                AS weeks_compared,
    COUNT(*) FILTER (WHERE d.wau IS DISTINCT FROM s.wau)    AS weeks_mismatch,
    CASE WHEN COUNT(*) FILTER (WHERE d.wau IS DISTINCT FROM s.wau) = 0
         THEN 'OK' ELSE 'FAIL' END                          AS status
FROM d
FULL JOIN s USING (week_start);


-- 5.3. MAU по месяцам
WITH d AS (
    SELECT
        date_trunc('month', activity_date::timestamp)::date AS month,
        COUNT(DISTINCT user_id)                             AS mau
    FROM mart.user_activity_daily
    GROUP BY 1
),
s AS (
    SELECT
        date_trunc('month', event_time AT TIME ZONE 'UTC')::date AS month,
        COUNT(DISTINCT user_id)                                  AS mau
    FROM stg.events
    GROUP BY 1
)
SELECT
    COUNT(*)                                                AS months_compared,
    COUNT(*) FILTER (WHERE d.mau IS DISTINCT FROM s.mau)    AS months_mismatch,
    CASE WHEN COUNT(*) FILTER (WHERE d.mau IS DISTINCT FROM s.mau) = 0
         THEN 'OK' ELSE 'FAIL' END                          AS status
FROM d
FULL JOIN s USING (month);


-- 5.4. Общие проверки: уникальные пользователи за весь период и число дней.
--      152 дня = 31 (окт) + 30 (ноя) + 31 (дек) + 31 (янв) + 29 (фев).
WITH u AS (
    SELECT
        (SELECT COUNT(*) FROM mart.users)                           AS users_mart,
        (SELECT COUNT(DISTINCT user_id) FROM mart.user_activity_daily) AS users_daily,
        (SELECT COUNT(DISTINCT user_id) FROM stg.events)            AS users_stg,
        (SELECT COUNT(DISTINCT activity_date) FROM mart.user_activity_daily) AS days_daily
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM u
CROSS JOIN LATERAL (VALUES
    ('unique users: mart.users vs stg.events',                u.users_stg, u.users_mart),
    ('unique users: user_activity_daily vs stg.events',       u.users_stg, u.users_daily),
    ('days with data (окт 2019 - фев 2020)',                  152::bigint, u.days_daily)
) AS x(check_name, expected, actual);
