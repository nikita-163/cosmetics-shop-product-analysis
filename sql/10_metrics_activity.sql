-- =============================================================================
-- 10_metrics_activity.sql
-- Метрики активности (раздел 2 в docs/metrics.md):
--   1. DAU (по дням)
--   2. WAU (по неделям, с флагом is_full_week)
--   3. MAU (по месяцам)
--   4. Stickiness (среднее DAU за месяц / MAU)
--   5. Сверка с независимым источником (stg.events)
--   6. Диагностика октября: аномальные дни 2, 6 и 7 октября (метрики не меняются)
--   7. Чувствительность октября: MAU, stickiness и WAU без аномальных дней
--
-- Где запускать: подключение к `cosmetics_shop`, каждый запрос отдельно
-- (Ctrl+Enter) или весь файл через Execute Script (Alt+X). Запускать после 07 и 08 (блок 5.4 читает mart.users).
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
--      Ожидаемое число дней = от первого до последнего дня в stg (UTC); для этих
--      данных это 152 = 31 (окт) + 30 (ноя) + 31 (дек) + 31 (янв) + 29 (фев).
WITH u AS (
    SELECT
        (SELECT COUNT(*) FROM mart.users)                           AS users_mart,
        (SELECT COUNT(DISTINCT user_id) FROM mart.user_activity_daily) AS users_daily,
        (SELECT COUNT(DISTINCT user_id) FROM stg.events)            AS users_stg,
        (SELECT COUNT(DISTINCT activity_date) FROM mart.user_activity_daily) AS days_daily,
        (SELECT MAX(event_time AT TIME ZONE 'UTC')::date - MIN(event_time AT TIME ZONE 'UTC')::date + 1
           FROM stg.events)                                           AS days_stg
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
    ('days with data (окт 2019 - фев 2020)',                  u.days_stg,  u.days_daily)
) AS x(check_name, expected, actual);



-- =============================================================================
-- 6. Диагностика октября: аномальные дни 2, 6 и 7 октября 2019
--    В начале октября приходит аномально много новых пользователей, которые
--    делают view и cart, но не покупают (docs/metrics.md, раздел 6, п. 11).
--    Здесь только диагностика: метрики не меняются.
--
--    Дни не удаляются, а помечаются: исключать их из расчётов нужно по дате
--    события, а не по исходу пользователя (иначе конверсия смещается).
--
--    Базовая линия: медиана за дни с 2019-11-18 (первая стабильная когорта,
--    stable_from в 11_metrics_cohorts_retention.sql) до конца данных. Медиана,
--    а не среднее: на среднее влияют пики Black Friday и праздничные провалы.
--    Данные начинаются 1 октября, поэтому «новыми» в первые недели выглядят и
--    вернувшиеся старые клиенты: множитель new_users_x_baseline в обычные дни
--    начала октября тоже выше 1. Аномальные дни надо оценивать по разрыву с
--    соседними днями, а не по самому факту превышения.
-- =============================================================================

-- 6.1. Дни с 1 по 13 октября: пользователи, воронка дня, заказы и GMV
--      new_users           : первый день пользователя в данных = этот день
--      new_view_cart_users : новые пользователи с view и cart в этот день
--      view_to_cart_pct    : пользователи дня с view и cart / с view (как в 09)
--      view_to_cart_baseline_pct : медиана view_to_cart_pct за дни базовой линии
--                            (дневная конверсия, не сопоставима с месячной из 09)
--      *_x_baseline        : значение дня / медиана базовой линии
--      Ожидаем: у 2, 6 и 7 октября new_users в 2-3 раза выше базовой линии, а
--      purchase_users, orders и gmv около 1.
WITH daily AS (
    SELECT
        d.activity_date,
        COUNT(*)                                                    AS active_users,
        COUNT(*) FILTER (WHERE d.activity_date = u.first_activity_date)
                                                                    AS new_users,
        COUNT(*) FILTER (WHERE d.activity_date = u.first_activity_date
                           AND d.has_view AND d.has_cart)           AS new_view_cart_users,
        COUNT(*) FILTER (WHERE d.has_view)                          AS view_users,
        COUNT(*) FILTER (WHERE d.has_view AND d.has_cart)           AS cart_users,
        COUNT(*) FILTER (WHERE d.has_purchase)                      AS purchase_users
    FROM mart.user_activity_daily d
    JOIN mart.users u USING (user_id)
    GROUP BY d.activity_date
),
orders_daily AS (
    SELECT
        (order_time AT TIME ZONE 'UTC')::date                       AS activity_date,
        COUNT(*)                                                    AS orders,
        SUM(gmv)                                                    AS gmv
    FROM mart.orders
    GROUP BY 1
),
joined AS (
    SELECT
        d.*,
        COALESCE(o.orders, 0)                                       AS orders,
        COALESCE(o.gmv, 0)                                          AS gmv
    FROM daily d
    LEFT JOIN orders_daily o USING (activity_date)
),
baseline AS (
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY new_users)      AS new_users,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY purchase_users) AS purchase_users,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY orders)         AS orders,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gmv)            AS gmv,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY 100.0 * cart_users / NULLIF(view_users, 0))    AS view_to_cart_pct
    FROM joined
    WHERE activity_date >= DATE '2019-11-18'
)
SELECT
    j.activity_date,
    j.active_users,
    j.new_users,
    j.new_view_cart_users,
    ROUND(100.0 * j.cart_users / NULLIF(j.view_users, 0), 2)        AS view_to_cart_pct,
    ROUND(b.view_to_cart_pct::numeric, 2)                           AS view_to_cart_baseline_pct,
    j.purchase_users,
    j.orders,
    ROUND(j.gmv, 2)                                                 AS gmv,
    ROUND(j.new_users::numeric       / NULLIF(b.new_users, 0)::numeric, 2)       AS new_users_x_baseline,
    ROUND(j.purchase_users::numeric  / NULLIF(b.purchase_users, 0)::numeric, 2)  AS purchase_users_x_baseline,
    ROUND(j.orders::numeric          / NULLIF(b.orders, 0)::numeric, 2)          AS orders_x_baseline,
    ROUND(j.gmv::numeric             / NULLIF(b.gmv, 0)::numeric, 2)             AS gmv_x_baseline
FROM joined j
CROSS JOIN baseline b
WHERE j.activity_date BETWEEN DATE '2019-10-01' AND DATE '2019-10-13'
ORDER BY j.activity_date;


-- 6.2. Базовая линия и «хвост»: максимум new_users_x_baseline после 7 октября.
--      Показывает, насколько высокие значения бывают вне аномальных дней, и
--      сравнивается с множителями 2, 6 и 7 октября из 6.1.
--      cohort_check: сумма new_users за 1-6 октября равна размеру первой когорты
--      (по определению когорты, понедельник 2019-09-30).
WITH new_daily AS (
    -- те же дни и тот же способ, что в 6.1: день без новых пользователей даёт 0
    SELECT
        d.activity_date,
        COUNT(*) FILTER (WHERE d.activity_date = u.first_activity_date) AS new_users
    FROM mart.user_activity_daily d
    JOIN mart.users u USING (user_id)
    GROUP BY d.activity_date
),
baseline AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY new_users) AS median_new_users
    FROM new_daily
    WHERE activity_date >= DATE '2019-11-18'
)
SELECT
    ROUND(b.median_new_users::numeric, 1)                            AS median_new_users_from_2019_11_18,
    MAX(n.new_users)                                                 AS max_new_users_after_oct_7,
    ROUND(MAX(n.new_users)::numeric / NULLIF(b.median_new_users, 0)::numeric, 2)
                                                                     AS max_x_baseline_after_oct_7,
    (SELECT SUM(new_users) FROM new_daily
     WHERE activity_date BETWEEN DATE '2019-10-01' AND DATE '2019-10-06')
                                                                     AS new_users_oct_1_6,
    (SELECT COUNT(*) FROM mart.users WHERE cohort_week = DATE '2019-09-30')
                                                                     AS first_cohort_size,
    CASE WHEN (SELECT SUM(new_users) FROM new_daily
               WHERE activity_date BETWEEN DATE '2019-10-01' AND DATE '2019-10-06')
              = (SELECT COUNT(*) FROM mart.users WHERE cohort_week = DATE '2019-09-30')
         THEN 'OK' ELSE 'FAIL' END                                   AS cohort_check
FROM new_daily n
CROSS JOIN baseline b
WHERE n.activity_date > DATE '2019-10-07'
GROUP BY b.median_new_users;


-- 6.3. Сверка 6.1 с stg.events напрямую (все дни данных, не только октябрь).
--      Ожидаем days_mismatch = 0 и OK во всех строках.
--      user-day флаги из stg считаются независимо от mart.user_activity_daily.
WITH stg_user_day AS (
    SELECT
        user_id,
        (event_time AT TIME ZONE 'UTC')::date                       AS day,
        BOOL_OR(event_type = 'view')                                AS has_view,
        BOOL_OR(event_type = 'cart')                                AS has_cart,
        BOOL_OR(event_type = 'purchase')                            AS has_purchase
    FROM stg.events
    GROUP BY 1, 2
),
stg_first AS (
    SELECT user_id, MIN(day) AS first_day
    FROM stg_user_day
    GROUP BY 1
),
s_users AS (
    SELECT
        d.day,
        COUNT(*) FILTER (WHERE d.day = f.first_day)                 AS new_users,
        COUNT(*) FILTER (WHERE d.day = f.first_day
                           AND d.has_view AND d.has_cart)           AS new_view_cart_users,
        COUNT(*) FILTER (WHERE d.has_view)                          AS view_users,
        COUNT(*) FILTER (WHERE d.has_view AND d.has_cart)           AS cart_users,
        COUNT(*) FILTER (WHERE d.has_purchase)                      AS purchase_users
    FROM stg_user_day d
    JOIN stg_first f USING (user_id)
    GROUP BY d.day
),
s_orders AS (
    -- заказ = (сессия, пользователь, момент покупки): покупка без дубля и с ценой
    SELECT
        (event_time AT TIME ZONE 'UTC')::date                       AS day,
        COUNT(DISTINCT (user_session, user_id, event_time))         AS orders,
        SUM(price)                                                  AS gmv
    FROM stg.events
    WHERE event_type = 'purchase'
      AND NOT is_duplicate
      AND price IS NOT NULL
      AND user_session IS NOT NULL
    GROUP BY 1
),
s AS (
    SELECT
        u.day,
        u.new_users, u.new_view_cart_users, u.view_users, u.cart_users, u.purchase_users,
        COALESCE(o.orders, 0)                                       AS orders,
        COALESCE(o.gmv, 0)                                          AS gmv
    FROM s_users u
    LEFT JOIN s_orders o USING (day)
),
m_users AS (
    SELECT
        d.activity_date                                             AS day,
        COUNT(*) FILTER (WHERE d.activity_date = u.first_activity_date)
                                                                    AS new_users,
        COUNT(*) FILTER (WHERE d.activity_date = u.first_activity_date
                           AND d.has_view AND d.has_cart)           AS new_view_cart_users,
        COUNT(*) FILTER (WHERE d.has_view)                          AS view_users,
        COUNT(*) FILTER (WHERE d.has_view AND d.has_cart)           AS cart_users,
        COUNT(*) FILTER (WHERE d.has_purchase)                      AS purchase_users
    FROM mart.user_activity_daily d
    JOIN mart.users u USING (user_id)
    GROUP BY d.activity_date
),
m_orders AS (
    SELECT
        (order_time AT TIME ZONE 'UTC')::date                       AS day,
        COUNT(*)                                                    AS orders,
        SUM(gmv)                                                    AS gmv
    FROM mart.orders
    GROUP BY 1
),
m AS (
    SELECT
        u.day,
        u.new_users, u.new_view_cart_users, u.view_users, u.cart_users, u.purchase_users,
        COALESCE(o.orders, 0)                                       AS orders,
        COALESCE(o.gmv, 0)                                          AS gmv
    FROM m_users u
    LEFT JOIN m_orders o USING (day)
)
SELECT
    x.check_name,
    COUNT(*)                                                        AS days_compared,
    COUNT(*) FILTER (WHERE x.expected IS DISTINCT FROM x.actual)    AS days_mismatch,
    CASE WHEN COUNT(*) FILTER (WHERE x.expected IS DISTINCT FROM x.actual) = 0
         THEN 'OK' ELSE 'FAIL' END                                  AS status
FROM s
FULL JOIN m USING (day)
CROSS JOIN LATERAL (VALUES
    ('daily new_users',           s.new_users::numeric,           m.new_users::numeric),
    ('daily new_view_cart_users', s.new_view_cart_users::numeric, m.new_view_cart_users::numeric),
    ('daily view_users',          s.view_users::numeric,          m.view_users::numeric),
    ('daily cart_users',          s.cart_users::numeric,          m.cart_users::numeric),
    ('daily purchase_users',      s.purchase_users::numeric,      m.purchase_users::numeric),
    ('daily orders',              s.orders::numeric,              m.orders::numeric),
    ('daily gmv',                 s.gmv::numeric,                 m.gmv::numeric)
) AS x(check_name, expected, actual)
GROUP BY x.check_name
ORDER BY x.check_name;



-- =============================================================================
-- 7. Чувствительность октября: активность без аномальных дней
--    Сценарии те же, что в блоке 5 файла 09_metrics_funnel.sql (описание, зачем
--    нужен каждый и почему дни не удаляются, там же): как есть; без 2, 6, 7 окт;
--    без 1, 2, 6, 7, 8 окт; placebo (без 9-13 окт). Список дней задан в блоке
--    scenarios каждого запроса: при изменении поправить во всех запросах блока 7
--    и в блоке 5 файла 09.
--
--    Метрики с учётом исключения дней:
--      * MAU и WAU считаются по оставшимся дням: исключение дня уменьшает их
--        механически, поэтому абсолютные значения разных сценариев сравнивать
--        нельзя без days_used;
--      * avg_dau = сумма DAU по оставшимся дням / days_used (по дням с данными,
--        а не по всем дням месяца, как в блоке 4);
--      * stickiness = avg_dau / MAU. Для сравнения сценариев НЕ подходит: MAU
--        с сокращением окна падает быстрее, чем avg_dau, поэтому stickiness растёт
--        механически при исключении любых дней (это видно по placebo). Сравнивать
--        сценарии по avg_dau: среднее по дню от числа дней не зависит. Строка
--        октября «as is» должна совпасть с блоком 4 (самопроверка).
--    Ноябрь-февраль и недели с 14 октября показаны «как есть» для сравнения.
-- =============================================================================

-- 7.1. MAU, avg_dau и stickiness: октябрь по сценариям, ноябрь-февраль как есть
WITH scenarios (scenario, sort_order, excluded_days) AS (
    VALUES
        ('as is',                  1, ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7',      2, ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07']),
        ('excl. Oct 1, 2, 6, 7, 8', 3, ARRAY[DATE '2019-10-01', DATE '2019-10-02', DATE '2019-10-06',
                                              DATE '2019-10-07', DATE '2019-10-08']),
        ('placebo: excl. Oct 9-13', 4, ARRAY[DATE '2019-10-09', DATE '2019-10-10', DATE '2019-10-11',
                                              DATE '2019-10-12', DATE '2019-10-13'])
),
user_day AS (
    SELECT
        sc.scenario,
        sc.sort_order,
        date_trunc('month', d.activity_date::timestamp)::date   AS month,
        d.user_id,
        d.activity_date
    FROM mart.user_activity_daily d
    JOIN scenarios sc
      ON NOT (d.activity_date = ANY (sc.excluded_days))
    WHERE d.activity_date < DATE '2019-11-01'
    UNION ALL
    SELECT
        'as is', 1,
        date_trunc('month', activity_date::timestamp)::date,
        user_id, activity_date
    FROM mart.user_activity_daily
    WHERE activity_date >= DATE '2019-11-01'
)
SELECT
    month,
    scenario,
    COUNT(DISTINCT user_id)                                                 AS mau,
    COUNT(DISTINCT activity_date)                                           AS days_used,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT activity_date), 1)             AS avg_dau,
    ROUND(100.0 * COUNT(*) / COUNT(DISTINCT activity_date)
          / COUNT(DISTINCT user_id), 2)                                     AS stickiness_pct
FROM user_day
GROUP BY month, scenario, sort_order
ORDER BY month, sort_order;


-- 7.2. WAU и avg_dau недели: две первые недели (30 сентября и 7 октября) по
--      сценариям, недели с 14 октября по 28 октября как есть.
--      Неделя, из которой исключены дни, неполная: смотреть days_used и avg_dau.
WITH scenarios (scenario, sort_order, excluded_days) AS (
    VALUES
        ('as is',                  1, ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7',      2, ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07']),
        ('excl. Oct 1, 2, 6, 7, 8', 3, ARRAY[DATE '2019-10-01', DATE '2019-10-02', DATE '2019-10-06',
                                              DATE '2019-10-07', DATE '2019-10-08']),
        ('placebo: excl. Oct 9-13', 4, ARRAY[DATE '2019-10-09', DATE '2019-10-10', DATE '2019-10-11',
                                              DATE '2019-10-12', DATE '2019-10-13'])
),
user_day AS (
    SELECT
        sc.scenario,
        sc.sort_order,
        date_trunc('week', d.activity_date::timestamp)::date    AS week_start,
        d.user_id,
        d.activity_date
    FROM mart.user_activity_daily d
    JOIN scenarios sc
      ON NOT (d.activity_date = ANY (sc.excluded_days))
    WHERE d.activity_date < DATE '2019-10-14'
    UNION ALL
    SELECT
        'as is', 1,
        date_trunc('week', activity_date::timestamp)::date,
        user_id, activity_date
    FROM mart.user_activity_daily
    WHERE activity_date >= DATE '2019-10-14'
      AND activity_date <  DATE '2019-11-04'
)
SELECT
    week_start,
    scenario,
    COUNT(DISTINCT user_id)                                                 AS wau,
    COUNT(DISTINCT activity_date)                                           AS days_used,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT activity_date), 1)             AS avg_dau
FROM user_day
GROUP BY week_start, scenario, sort_order
ORDER BY week_start, sort_order;


-- 7.3. Сверка 7.1 и 7.2 (октябрь и две первые недели): mart.user_activity_daily
--      против stg.events. В stg «пользователь-день» считается заново.
--      Сравниваются число пользователей, число дней и число пар «пользователь-день»
--      (из них следует avg_dau). Ожидаем OK во всех строках.
WITH scenarios (scenario, sort_order, excluded_days) AS (
    VALUES
        ('as is',                  1, ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7',      2, ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07']),
        ('excl. Oct 1, 2, 6, 7, 8', 3, ARRAY[DATE '2019-10-01', DATE '2019-10-02', DATE '2019-10-06',
                                              DATE '2019-10-07', DATE '2019-10-08']),
        ('placebo: excl. Oct 9-13', 4, ARRAY[DATE '2019-10-09', DATE '2019-10-10', DATE '2019-10-11',
                                              DATE '2019-10-12', DATE '2019-10-13'])
),
ud AS (
    SELECT 'mart' AS src, user_id, activity_date AS day
    FROM mart.user_activity_daily
    UNION ALL
    SELECT 'stg', user_id, day
    FROM (
        SELECT DISTINCT user_id, (event_time AT TIME ZONE 'UTC')::date AS day
        FROM stg.events
    ) s
),
agg AS (
    SELECT
        ud.src, sc.scenario, 'month'                                AS period_kind,
        DATE '2019-10-01'                                           AS period_start,
        COUNT(DISTINCT ud.user_id)                                  AS users,
        COUNT(DISTINCT ud.day)                                      AS days_used,
        COUNT(*)                                                    AS user_days
    FROM ud
    JOIN scenarios sc ON NOT (ud.day = ANY (sc.excluded_days))
    WHERE ud.day < DATE '2019-11-01'
    GROUP BY ud.src, sc.scenario
    UNION ALL
    SELECT
        ud.src, sc.scenario, 'week',
        date_trunc('week', ud.day::timestamp)::date,
        COUNT(DISTINCT ud.user_id),
        COUNT(DISTINCT ud.day),
        COUNT(*)
    FROM ud
    JOIN scenarios sc ON NOT (ud.day = ANY (sc.excluded_days))
    WHERE ud.day < DATE '2019-10-14'
    GROUP BY ud.src, sc.scenario, date_trunc('week', ud.day::timestamp)::date
)
SELECT
    COALESCE(s.scenario, m.scenario)                AS scenario,
    COALESCE(s.period_kind, m.period_kind)          AS period_kind,
    COALESCE(s.period_start, m.period_start)        AS period_start,
    s.users     AS expected_users,      m.users     AS actual_users,
    s.days_used AS expected_days,       m.days_used AS actual_days,
    s.user_days AS expected_user_days,  m.user_days AS actual_user_days,
    CASE WHEN (s.users, s.days_used, s.user_days)
              IS NOT DISTINCT FROM (m.users, m.days_used, m.user_days)
         THEN 'OK' ELSE 'FAIL' END                  AS status
FROM (SELECT * FROM agg WHERE src = 'stg')  s
FULL JOIN (SELECT * FROM agg WHERE src = 'mart') m
       ON m.scenario = s.scenario
      AND m.period_kind = s.period_kind
      AND m.period_start = s.period_start
ORDER BY 3, 2, 1;
