-- =============================================================================
-- 11_metrics_cohorts_retention.sql
-- Когорты и retention (раздел 3 в docs/metrics.md):
--   1. Размеры недельных когорт
--   2. Матрица retention и purchase retention (когорта x неделя N)
--   3. Repeat purchase rate (весь период и по когортам)
--   4. Repeat purchase rate за 30 дней (сопоставимо по когортам)
--   5. Время до повторной покупки
--   6. Сверка с независимым источником (stg.events)
--
-- Где запускать: подключение к `cosmetics_shop`, запросы по порядку в ОДНОМ
-- окне SQL-редактора (блок 2 создаёт временную таблицу, она живёт только в
-- текущей сессии и нужна блоку 6.1). Запускать после 05, 07 и 08.
--
-- Источники: mart.users (когорта, заказы; заказы построены из mart.orders),
-- mart.user_activity_daily (активность).
--
-- Правила:
--   * Когорта = неделя первой активности пользователя (mart.users.cohort_week,
--     понедельник, UTC). Первая когорта неполная и включает старых клиентов.
--   * Retention и purchase retention считают поведение: любое событие и любое
--     событие purchase (в том числе без цены и дубли), как в user_activity_daily.
--   * Знаменатель = размер когорты (все пользователи когорты, в том числе
--     никогда не покупавшие).
--   * Repeat purchase и время до повторной покупки считают заказы:
--     orders_cnt, first_order_time, second_order_time (см. 08_mart_users.sql).
--     Заказ = (user_session, user_id, момент покупки), поэтому второй заказ может
--     быть в той же сессии, что и первый (в том числе в тот же день).
--   * Неделя считается полной, если в данных есть все 7 её дней. Недели
--     "когорта + N" вне периода данных в матрице не создаются вовсе (нет
--     «нулей» там, где данных просто ещё нет). Неполные недели остаются с
--     флагом is_full_week = false и в выводах не интерпретируются.
--   * «За 30 дней» в блоке 4 считается по точному времени (второй заказ не позже
--     первого + 30 суток), а интервалы блока 5 по разнице календарных дат UTC,
--     поэтому граница 30 дней в этих блоках может немного расходиться.
--
-- Ограничения расчётов (подробнее в разделе 6 docs/metrics.md):
--   * Левое цензурирование: в первых когортах «новыми» выглядят клиенты, которые
--     были до начала данных. Эффект заметен до середины ноября (блок 4).
--   * Правое цензурирование: чем позже первый заказ, тем меньше времени на
--     повтор. Доли «за весь период» (блок 3) и помесячное время до повторной
--     покупки (блок 5) зависят от окна наблюдения; для сравнений использовать
--     блок 4.
--   * Когорты по календарной неделе: у пришедших в воскресенье неделя 0
--     длится один день, поэтому retention недели 1 у таких пользователей выше.
--     Это стандартный компромисс календарных когорт.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Размеры когорт
-- -----------------------------------------------------------------------------
SELECT
    cohort_week,
    COUNT(*)                                                    AS cohort_size,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS share_of_all_users
FROM mart.users
GROUP BY cohort_week
ORDER BY cohort_week;


-- -----------------------------------------------------------------------------
-- 2. Матрица retention (длинный формат: одна строка = когорта x неделя N)
--    Длинный формат удобнее короткого для DataLens (heatmap) и для проверки.
--    Результат сохраняем во временную таблицу: блок 6.1 сверит её с stg.events.
--
--    week_n                = номер недели с момента когорты (0 = неделя когорты)
--    retention_pct         = активные в неделе N / размер когорты
--    purchase_retention_pct = пользователи с purchase в неделе N / размер когорты
--    Неделя 0: retention = 100% по определению (когорта задана первой активностью).
--    Когорта это календарная неделя: у пришедших в воскресенье неделя 0
--    длится один день, поэтому retention недели 1 для них завышен.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_cohort_retention;

CREATE TEMP TABLE tmp_cohort_retention AS
WITH cohorts AS (
    SELECT cohort_week, COUNT(*) AS cohort_size
    FROM mart.users
    GROUP BY cohort_week
),
weeks AS (
    -- все недели, которые есть в данных, и признак полноты
    SELECT
        date_trunc('week', activity_date::timestamp)::date  AS week_start,
        COUNT(DISTINCT activity_date) = 7                   AS is_full_week
    FROM mart.user_activity_daily
    GROUP BY 1
),
grid AS (
    -- все пары (когорта, неделя данных не раньше когорты): date - date = дни
    SELECT
        c.cohort_week,
        c.cohort_size,
        w.week_start                                        AS target_week,
        (w.week_start - c.cohort_week) / 7                  AS week_n,
        w.is_full_week
    FROM cohorts c
    JOIN weeks w ON w.week_start >= c.cohort_week
),
user_week AS (
    -- пара (пользователь, неделя): был ли он активен и была ли покупка
    SELECT
        user_id,
        date_trunc('week', activity_date::timestamp)::date  AS activity_week,
        BOOL_OR(has_purchase)                               AS has_purchase
    FROM mart.user_activity_daily
    GROUP BY user_id, activity_week
),
act AS (
    SELECT
        u.cohort_week,
        uw.activity_week,
        COUNT(*)                                            AS active_users,
        COUNT(*) FILTER (WHERE uw.has_purchase)             AS purchasers
    FROM user_week uw
    JOIN mart.users u ON u.user_id = uw.user_id
    GROUP BY u.cohort_week, uw.activity_week
)
SELECT
    g.cohort_week,
    g.week_n,
    g.target_week,
    g.is_full_week,
    g.cohort_size,
    COALESCE(a.active_users, 0)                                         AS active_users,
    ROUND(100.0 * COALESCE(a.active_users, 0) / g.cohort_size, 2)       AS retention_pct,
    COALESCE(a.purchasers, 0)                                           AS purchasers,
    ROUND(100.0 * COALESCE(a.purchasers, 0) / g.cohort_size, 2)         AS purchase_retention_pct
FROM grid g
LEFT JOIN act a
       ON a.cohort_week = g.cohort_week
      AND a.activity_week = g.target_week;

SELECT *
FROM tmp_cohort_retention
ORDER BY cohort_week, week_n;


-- -----------------------------------------------------------------------------
-- 3. Repeat purchase rate: пользователи с >= 2 заказами / с >= 1 заказом
--    ROLLUP корректен: каждый пользователь принадлежит одной когорте.
--    Строка 'all' = за весь период.
--    Осторожно со сравнением когорт: у поздних когорт было меньше времени на
--    повтор, их доля занижена. Строка 'all' тоже зависит от окна наблюдения
--    (5 месяцев): для сравнений и выводов использовать блок 4.
-- -----------------------------------------------------------------------------
WITH c AS (
    SELECT
        cohort_week,
        COUNT(*) FILTER (WHERE orders_cnt >= 1)   AS buyers,
        COUNT(*) FILTER (WHERE orders_cnt >= 2)   AS repeat_buyers
    FROM mart.users
    GROUP BY ROLLUP (cohort_week)
)
SELECT
    COALESCE(cohort_week::text, 'all')                          AS cohort,
    buyers,
    repeat_buyers,
    ROUND(100.0 * repeat_buyers / NULLIF(buyers, 0), 2)         AS repeat_purchase_rate_pct
FROM c
ORDER BY cohort_week NULLS LAST;


-- -----------------------------------------------------------------------------
-- 4. Repeat purchase rate за 30 дней
--    В расчёт берём только пользователей, у которых после первого заказа в
--    данных осталось не меньше 30 дней: первый заказ не позже
--    (последний день данных - 30). Иначе поздние когорты были бы в проигрыше.
--    Повтор засчитывается, если второй заказ не позже чем через 30 суток после
--    первого. Когорта здесь по-прежнему неделя первой активности.
--
--    buyers          : все покупатели когорты (с >= 1 заказом)
--    eligible_buyers : из них те, у кого окно 30 дней полностью в данных
--    eligible_share_pct: доля покупателей когорты с полным окном. 83-97% у
--                      большинства когорт: часть покупателей сделала первый заказ
--                      в последние 30 дней данных, у них окно ещё не закрыто.
--                      Когорта помечается 'partial' только если сама неделя
--                      когорты заканчивается позже граничной даты (когорта
--                      27 января учтена на 47%, когорты с 3 февраля вовсе не
--                      попадают в расчёт).
--    stable_from     : первая когорта, где влияние старых клиентов (левое
--                      цензурирование) мало. Дата выбрана по результатам этого же
--                      блока: доля повторов за 30 дней перестаёт падать и держится
--                      около 11-12% с середины ноября. Строка 'stable cohorts' это
--                      число для выводов; 'all cohorts' смешивает ранние и
--                      частичные когорты.
-- -----------------------------------------------------------------------------
WITH params AS (
    SELECT
        MAX(activity_date) - 30     AS last_eligible_date,
        DATE '2019-11-18'           AS stable_from
    FROM mart.user_activity_daily
),
c AS (
    SELECT
        u.cohort_week,
        COUNT(*) FILTER (WHERE u.orders_cnt >= 1)                   AS buyers,
        COUNT(*) FILTER (
            WHERE u.orders_cnt >= 1
              AND (u.first_order_time AT TIME ZONE 'UTC')::date <= p.last_eligible_date
        )                                                           AS eligible_buyers,
        COUNT(*) FILTER (
            WHERE u.orders_cnt >= 1
              AND (u.first_order_time AT TIME ZONE 'UTC')::date <= p.last_eligible_date
              AND u.second_order_time <= u.first_order_time + INTERVAL '30 days'
        )                                                           AS repeat_30d
    FROM mart.users u
    CROSS JOIN params p
    GROUP BY u.cohort_week
),
out_rows AS (
    SELECT
        c.cohort_week::text                                         AS cohort,
        1                                                           AS ord,
        c.cohort_week                                               AS sort_key,
        c.buyers, c.eligible_buyers, c.repeat_30d,
        CASE
            WHEN c.cohort_week < p.stable_from
                THEN 'early cohort: includes old customers'
            WHEN c.cohort_week + 6 > p.last_eligible_date
                THEN 'partial: cohort week ends after the last eligible date'
        END                                                         AS note
    FROM c
    CROSS JOIN params p
    UNION ALL
    SELECT 'all cohorts', 2, NULL::date,
           SUM(buyers), SUM(eligible_buyers), SUM(repeat_30d),
           'includes early and partial cohorts'
    FROM c
    UNION ALL
    SELECT 'stable cohorts', 3, NULL::date,
           SUM(c.buyers), SUM(c.eligible_buyers), SUM(c.repeat_30d),
           'cohorts from stable_from with a full 30-day window'
    FROM c
    CROSS JOIN params p
    WHERE c.cohort_week >= p.stable_from
      AND c.cohort_week + 6 <= p.last_eligible_date
)
SELECT
    cohort,
    buyers,
    eligible_buyers,
    ROUND(100.0 * eligible_buyers / NULLIF(buyers, 0), 1)           AS eligible_share_pct,
    repeat_30d,
    ROUND(100.0 * repeat_30d / NULLIF(eligible_buyers, 0), 2)       AS repeat_30d_rate_pct,
    note
FROM out_rows
ORDER BY ord, sort_key;


-- -----------------------------------------------------------------------------
-- 5. Время до повторной покупки (пользователи с >= 2 заказами)
--    gap_days = разница календарных дней UTC между первым и вторым заказом;
--    0 = второй заказ в тот же день, что и первый.
--    Месяц определяется по второму заказу (см. раздел 3 в docs/metrics.md).
--    Распределение скошено вправо, поэтому смотрим медиану и квартили, а
--    среднее держим как вспомогательное. Доли по корзинам в сумме дают 100%.
--
--    Помесячные строки сравнивать между собой нельзя: данные начинаются
--    1 октября, поэтому максимально возможный интервал равен
--    max_possible_gap_days (30 для октября, 60 для ноября и так далее), и медиана
--    растёт вместе с окном. Строка 'all' считается только по тем, кто повторил
--    покупку до конца данных (правое цензурирование), поэтому занижена. Для
--    сравнений использовать блок 4 (доля повторов за фиксированные 30 дней).
--    Второй заказ в тот же день (same_day) включает повторные оформления в одной
--    сессии: это следствие определения заказа по моменту покупки.
-- -----------------------------------------------------------------------------
WITH params AS (
    SELECT MIN(activity_date) AS min_date, MAX(activity_date) AS max_date
    FROM mart.user_activity_daily
),
repeaters AS (
    SELECT
        user_id,
        (second_order_time AT TIME ZONE 'UTC')::date
          - (first_order_time AT TIME ZONE 'UTC')::date                 AS gap_days,
        date_trunc('month', second_order_time AT TIME ZONE 'UTC')::date AS second_month
    FROM mart.users
    WHERE second_order_time IS NOT NULL
),
agg AS (
    SELECT
        second_month,
        COUNT(*)                                                        AS repeat_buyers,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY gap_days::float8)  AS p25_days,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gap_days::float8)  AS median_days,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_days::float8)  AS p75_days,
        AVG(gap_days)                                                   AS avg_days,
        COUNT(*) FILTER (WHERE gap_days = 0)                            AS same_day,
        COUNT(*) FILTER (WHERE gap_days BETWEEN 1 AND 7)                AS d1_7,
        COUNT(*) FILTER (WHERE gap_days BETWEEN 8 AND 30)               AS d8_30,
        COUNT(*) FILTER (WHERE gap_days BETWEEN 31 AND 60)              AS d31_60,
        COUNT(*) FILTER (WHERE gap_days > 60)                           AS d61_plus
    FROM repeaters
    GROUP BY ROLLUP (second_month)
)
SELECT
    COALESCE(second_month::text, 'all')                         AS period,
    repeat_buyers,
    ROUND(p25_days::numeric, 1)                                 AS p25_days,
    ROUND(median_days::numeric, 1)                              AS median_days,
    ROUND(p75_days::numeric, 1)                                 AS p75_days,
    ROUND(avg_days, 1)                                          AS avg_days,
    ROUND(100.0 * same_day / repeat_buyers, 1)                  AS same_day_pct,
    ROUND(100.0 * d1_7     / repeat_buyers, 1)                  AS d1_7_pct,
    ROUND(100.0 * d8_30    / repeat_buyers, 1)                  AS d8_30_pct,
    ROUND(100.0 * d31_60   / repeat_buyers, 1)                  AS d31_60_pct,
    ROUND(100.0 * d61_plus / repeat_buyers, 1)                  AS d61_plus_pct,
    CASE WHEN second_month IS NULL THEN NULL
         ELSE LEAST((second_month + INTERVAL '1 month')::date - 1, p.max_date)
              - p.min_date
    END                                                         AS max_possible_gap_days
FROM agg
CROSS JOIN params p
ORDER BY second_month NULLS LAST;


-- =============================================================================
-- 6. Сверка: те же цифры из stg.events напрямую, без витрин
--    Ожидаем OK во всех строках.
-- =============================================================================

-- 6.1. Матрица retention: сверка с stg.events и проверка недели 0
--      expected = значение из stg.events, actual = значение из матрицы.
WITH m AS (
    SELECT
        SUM(cohort_size) FILTER (WHERE week_n = 0)                  AS users_in_cohorts,
        SUM(active_users)                                           AS user_weeks,
        SUM(purchasers)                                             AS purchase_user_weeks,
        COUNT(*) FILTER (WHERE week_n = 0 AND active_users <> cohort_size) AS bad_week0
    FROM tmp_cohort_retention
),
s AS (
    SELECT
        (SELECT COUNT(DISTINCT user_id) FROM stg.events)            AS users,
        (SELECT COUNT(*) FROM (
             SELECT DISTINCT user_id,
                    date_trunc('week', event_time AT TIME ZONE 'UTC')
             FROM stg.events
         ) t)                                                       AS user_weeks,
        (SELECT COUNT(*) FROM (
             SELECT DISTINCT user_id,
                    date_trunc('week', event_time AT TIME ZONE 'UTC')
             FROM stg.events
             WHERE event_type = 'purchase'
         ) t)                                                       AS purchase_user_weeks
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END       AS status
FROM m
CROSS JOIN s
CROSS JOIN LATERAL (VALUES
    ('sum of cohort sizes = unique users in stg',        s.users::numeric,       m.users_in_cohorts::numeric),
    ('sum of active user-weeks = distinct (user, week)', s.user_weeks::numeric,  m.user_weeks::numeric),
    ('sum of purchasers = distinct (user, week) with purchase', s.purchase_user_weeks::numeric, m.purchase_user_weeks::numeric),
    ('cohorts where week 0 retention <> 100%',           0::numeric,             m.bad_week0::numeric)
) AS x(check_name, expected, actual);


-- 6.2. Repeat purchase: покупатели и повторные покупатели, mart.users и stg.events
--      Заказы пользователя из stg: число его уникальных моментов покупки
--      (user_session, event_time) среди purchase без дубля и с ценой не NULL
--      (user_session IS NULL исключён, как в mart.orders).
WITH from_mart AS (
    SELECT
        COUNT(*) FILTER (WHERE orders_cnt >= 1)  AS buyers,
        COUNT(*) FILTER (WHERE orders_cnt >= 2)  AS repeat_buyers
    FROM mart.users
),
from_stg AS (
    SELECT
        COUNT(*) FILTER (WHERE orders >= 1)      AS buyers,
        COUNT(*) FILTER (WHERE orders >= 2)      AS repeat_buyers
    FROM (
        SELECT
            user_id,
            COUNT(DISTINCT (user_session, event_time)) FILTER (
                WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
            ) AS orders
        FROM stg.events
        WHERE user_session IS NOT NULL
        GROUP BY user_id
    ) o
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END  AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('buyers (orders >= 1)',        s.buyers,        m.buyers),
    ('repeat buyers (orders >= 2)', s.repeat_buyers, m.repeat_buyers)
) AS x(check_name, expected, actual);


-- 6.3. Время до повторной покупки: число повторных покупателей и сумма
--      gap_days, mart.users и stg.events. Из stg заново находим первую покупку
--      с ценой в каждом моменте покупки, нумеруем заказы по времени и берём второй.
--      Сумма интервалов служит контрольной суммой: если она совпала, значит и
--      сами интервалы, скорее всего, совпали.
WITH s AS (
    SELECT DISTINCT user_id, user_session, event_time AS t
    FROM stg.events
    WHERE event_type = 'purchase'
      AND NOT is_duplicate
      AND price IS NOT NULL
      AND user_session IS NOT NULL
),
r AS (
    SELECT
        user_id,
        t,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY t, user_session) AS rn
    FROM s
),
u AS (
    SELECT
        user_id,
        MIN(t) FILTER (WHERE rn = 1) AS t1,
        MIN(t) FILTER (WHERE rn = 2) AS t2
    FROM r
    WHERE rn <= 2
    GROUP BY user_id
),
from_stg AS (
    SELECT
        COUNT(t2)                                                   AS repeaters,
        SUM((t2 AT TIME ZONE 'UTC')::date - (t1 AT TIME ZONE 'UTC')::date) AS gap_sum
    FROM u
),
from_mart AS (
    SELECT
        COUNT(second_order_time)                                    AS repeaters,
        SUM((second_order_time AT TIME ZONE 'UTC')::date
            - (first_order_time AT TIME ZONE 'UTC')::date)          AS gap_sum
    FROM mart.users
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END  AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('repeat buyers',        s.repeaters, m.repeaters),
    ('sum of gap_days',      s.gap_sum,   m.gap_sum)
) AS x(check_name, expected, actual);


-- 6.4. Repeat purchase rate за 30 дней (блок 4): число покупателей с полным
--      окном и число повторивших, mart.users против stg.events. Первый и второй
--      заказ находим из stg заново, последний день данных тоже берём из stg.
WITH s AS (
    SELECT DISTINCT user_id, user_session, event_time AS t
    FROM stg.events
    WHERE event_type = 'purchase'
      AND NOT is_duplicate
      AND price IS NOT NULL
      AND user_session IS NOT NULL
),
r AS (
    SELECT
        user_id,
        t,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY t, user_session) AS rn
    FROM s
),
u AS (
    SELECT
        user_id,
        MIN(t) FILTER (WHERE rn = 1) AS t1,
        MIN(t) FILTER (WHERE rn = 2) AS t2
    FROM r
    WHERE rn <= 2
    GROUP BY user_id
),
from_stg AS (
    SELECT
        COUNT(*) FILTER (
            WHERE (u.t1 AT TIME ZONE 'UTC')::date <= p.last_eligible_date
        )                                                           AS eligible_buyers,
        COUNT(*) FILTER (
            WHERE (u.t1 AT TIME ZONE 'UTC')::date <= p.last_eligible_date
              AND u.t2 <= u.t1 + INTERVAL '30 days'
        )                                                           AS repeat_30d
    FROM u
    CROSS JOIN (
        SELECT MAX((event_time AT TIME ZONE 'UTC')::date) - 30 AS last_eligible_date
        FROM stg.events
    ) p
),
from_mart AS (
    SELECT
        COUNT(*) FILTER (
            WHERE orders_cnt >= 1
              AND (first_order_time AT TIME ZONE 'UTC')::date
                  <= (SELECT MAX(activity_date) - 30 FROM mart.user_activity_daily)
        )                                                           AS eligible_buyers,
        COUNT(*) FILTER (
            WHERE orders_cnt >= 1
              AND (first_order_time AT TIME ZONE 'UTC')::date
                  <= (SELECT MAX(activity_date) - 30 FROM mart.user_activity_daily)
              AND second_order_time <= first_order_time + INTERVAL '30 days'
        )                                                           AS repeat_30d
    FROM mart.users
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END  AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('eligible buyers (full 30-day window)', s.eligible_buyers, m.eligible_buyers),
    ('repeat within 30 days',                s.repeat_30d,      m.repeat_30d)
) AS x(check_name, expected, actual);
