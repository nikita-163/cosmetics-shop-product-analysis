-- =============================================================================
-- 13_export_for_datalens.sql
-- Выгрузки для дашборда DataLens (схема metrics, таблицы dl_*):
--   1. dl_funnel_monthly      воронка и сессионные метрики: месяц x сценарий
--   2. dl_activity_daily      DAU, новые пользователи, заказы и GMV по дням
--   3. dl_activity_monthly    MAU и avg_dau: месяц x сценарий
--   4. dl_weekly              WAU, покупатели, заказы, GMV по неделям (дерево NSM)
--   5. dl_business_monthly    GMV, заказы, AOV, ARPPU по месяцам
--   6. dl_retention           retention и purchase retention: когорта x неделя N
--   7. dl_cohort_sensitivity  retention первых двух когорт: сценарий x неделя N
--   8. dl_repeat_30d          Repeat purchase rate за 30 дней по когортам
--   9. dl_kpi_total           итоги за весь период (одна строка)
--  10. Сверки: каждая выгрузка против stg.events напрямую
--  11. Контрольные числа реальных данных (регрессия к записанным результатам)
--  12. Что экспортировать в CSV и как
--
-- Где запускать: подключение к `cosmetics_shop`, весь файл через Execute Script
-- (Alt+X) в ОДНОМ окне SQL-редактора (блок 10 создаёт временные таблицы tmp_chk_*,
-- они живут только в текущей сессии). Запускать после 05, 07 и 08. Файлы 09-12
-- для запуска не нужны: выгрузки считаются из витрин, а не из результатов метрик
-- (логика та же, и блок 10 сверяет её со stg.events, а не с 09-12).
-- Порядок блоков важен: блок 9 читает dl_repeat_30d (блок 8). Блок 11 запускать
-- только на реальных данных.
--
-- Зачем отдельные таблицы, а не прямое подключение к mart:
--   * DataLens подключается к файлам (облачная версия не достанет до локальной БД);
--   * в дашборд идут только агрегаты (десятки-сотни строк на таблицу), а не
--     миллионы строк витрин: быстрее, и нет риска посчитать метрику в DataLens
--     иначе, чем в SQL;
--   * вся логика остаётся в репозитории и сверена с 09-12.
--   Компромисс: данные «замороженные» (как и витрины mart): после пересчёта
--   витрин запустить файл заново и заменить CSV в DataLens.
--
-- Правила выгрузок (см. docs/metrics.md, разделы 0, 6 и 7):
--   1. Одна таблица = одно зерно. Зерно указано в COMMENT ON TABLE и в блоке ниже.
--   2. Деньги (GMV, заказы, AOV, ARPPU) приводятся только «как есть» и лежат в
--      таблицах БЕЗ колонки scenario: иначе при суммировании в DataLens деньги
--      повторились бы в каждом сценарии.
--   3. Сценарии (as is и excl. Oct 2, 6, 7) есть только у метрик поведения:
--      воронка (1), активность (3) и retention первых когорт (7). Вспомогательные
--      сценарии «excl. Oct 1, 2, 6, 7, 8» и placebo остаются в блоках 5 и 7 файлов
--      09-11 и в docs/metrics.md, раздел 7: в дашборд их не выносим, чтобы не
--      перегружать его.
--   4. Нет итоговых строк (ROLLUP, 'all'): итоги за период даёт dl_kpi_total.
--      Итоговая строка в таблице при суммировании в DataLens удвоила бы значения.
--   5. Уникальных пользователей (воронка, MAU, WAU, покупатели, retention) нельзя
--      суммировать между периодами: пользователь попадёт в каждый период. Зерно
--      таблицы и есть период, по которому показывать эти метрики.
--   6. Проценты выгружены готовыми (зерно строки = период расчёта) и дополнены
--      числителем и знаменателем. Не усреднять проценты по строкам: при
--      агрегации выше зерна считать SUM(числитель) / SUM(знаменатель).
--   7. Неполные недели, ранние когорты и аномальные дни помечены текстовыми
--      колонками (week_status, cohort_status, day_flag), а не отфильтрованы:
--      решение о показе принимает дашборд. Текстовые метки, а не boolean:
--      не зависят от определения типов при импорте CSV в DataLens.
--   8. Даты в UTC. Неделя с понедельника. Названия сценариев, дней и порог
--      стабильных когорт (2019-11-18) совпадают с 09-12; при изменении
--      поправить везде (список дней задан в блоках scenarios каждого запроса).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. dl_funnel_monthly: воронка, доля удалений, session conversion, abandonment
--    Зерно: (month, scenario). Октябрь в двух сценариях (as is и excl. Oct 2, 6, 7),
--    ноябрь-февраль только as is. Логика совпадает с блоками 5.1 и 5.2 файла
--    09_metrics_funnel.sql (там же объяснение, зачем нужны сценарии).
--    Числа пользователей (view_users и др.) не суммировать по месяцам.
--    Сессия относится ко дню начала (session_start); сессия, начатая в исключённый
--    день, исключается целиком.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_funnel_monthly;

CREATE TABLE metrics.dl_funnel_monthly AS
WITH scenarios (scenario, excluded_days) AS (
    VALUES
        ('as is',             ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7', ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07'])
),
user_day AS (
    SELECT
        sc.scenario,
        date_trunc('month', d.activity_date::timestamp)::date   AS month,
        d.user_id,
        d.has_view,
        d.has_cart,
        d.has_remove_from_cart,
        d.has_purchase
    FROM mart.user_activity_daily d
    JOIN scenarios sc
      ON NOT (d.activity_date = ANY (sc.excluded_days))
    WHERE d.activity_date < DATE '2019-11-01'
    UNION ALL
    SELECT
        'as is',
        date_trunc('month', activity_date::timestamp)::date,
        user_id, has_view, has_cart, has_remove_from_cart, has_purchase
    FROM mart.user_activity_daily
    WHERE activity_date >= DATE '2019-11-01'
),
user_month AS (
    SELECT
        scenario, month, user_id,
        BOOL_OR(has_view)               AS has_view,
        BOOL_OR(has_cart)               AS has_cart,
        BOOL_OR(has_remove_from_cart)   AS has_remove_from_cart,
        BOOL_OR(has_purchase)           AS has_purchase
    FROM user_day
    GROUP BY scenario, month, user_id
),
user_counts AS (
    SELECT
        scenario, month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users,
        COUNT(*) FILTER (WHERE has_cart)                                AS users_with_cart,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart)       AS users_with_cart_and_remove
    FROM user_month
    GROUP BY scenario, month
),
sess AS (
    SELECT
        sc.scenario,
        date_trunc('month', s.session_start AT TIME ZONE 'UTC')::date   AS month,
        s.has_view, s.has_cart, s.has_purchase
    FROM mart.sessions s
    JOIN scenarios sc
      ON NOT ((s.session_start AT TIME ZONE 'UTC')::date = ANY (sc.excluded_days))
    WHERE (s.session_start AT TIME ZONE 'UTC')::date < DATE '2019-11-01'
    UNION ALL
    SELECT
        'as is',
        date_trunc('month', session_start AT TIME ZONE 'UTC')::date,
        has_view, has_cart, has_purchase
    FROM mart.sessions
    WHERE (session_start AT TIME ZONE 'UTC')::date >= DATE '2019-11-01'
),
sess_counts AS (
    SELECT
        scenario, month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_sessions,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS converted_sessions,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_sessions,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_sessions
    FROM sess
    GROUP BY scenario, month
)
SELECT
    u.month,
    TO_CHAR(u.month, 'YYYY-MM')                                                 AS month_label,
    u.scenario,
    u.view_users,
    u.cart_users,
    u.purchase_users,
    ROUND(100.0 * u.cart_users     / NULLIF(u.view_users, 0), 2)                AS view_to_cart_pct,
    ROUND(100.0 * u.purchase_users / NULLIF(u.cart_users, 0), 2)                AS cart_to_purchase_pct,
    ROUND(100.0 * u.purchase_users / NULLIF(u.view_users, 0), 2)                AS conversion_pct,
    u.users_with_cart,
    u.users_with_cart_and_remove,
    ROUND(100.0 * u.users_with_cart_and_remove / NULLIF(u.users_with_cart, 0), 2) AS cart_remove_pct,
    s.view_sessions,
    s.converted_sessions,
    ROUND(100.0 * s.converted_sessions / NULLIF(s.view_sessions, 0), 2)         AS session_conversion_pct,
    s.cart_sessions,
    s.cart_purchase_sessions,
    ROUND(100.0 - 100.0 * s.cart_purchase_sessions / NULLIF(s.cart_sessions, 0), 2) AS abandonment_pct
FROM user_counts u
JOIN sess_counts s
  ON s.month = u.month AND s.scenario = u.scenario;

ALTER TABLE metrics.dl_funnel_monthly ADD PRIMARY KEY (month, scenario);

COMMENT ON TABLE metrics.dl_funnel_monthly IS
    'Выгрузка для DataLens. Зерно: месяц x сценарий (октябрь: as is и excl. Oct 2, 6, 7; остальные месяцы: as is). Пользователей и сессии по месяцам не суммировать.';


-- -----------------------------------------------------------------------------
-- 2. dl_activity_daily: DAU, новые пользователи, заказы и GMV по дням
--    Зерно: activity_date (один день = одна строка). Деньги как есть.
--    new_users            : первый день пользователя в данных = этот день
--                           (в первые недели включает вернувшихся старых клиентов);
--    new_users_baseline   : медиана new_users за дни с 2019-11-18 (константа в
--                           каждой строке: использовать как линию сравнения,
--                           не суммировать), как в блоке 6.1 файла 10;
--    day_flag             : 'anomalous day' для 2, 6, 7 октября (критерий в
--                           10_metrics_activity.sql, блок 6: всплеск новых
--                           пользователей без роста покупателей);
--    buyers               : пользователи с >= 1 заказом в этот день (по дням не
--                           суммировать: один человек может купить в разные дни).
--    orders, gmv          : заказы и GMV дня (относятся ко времени заказа, UTC),
--                           по дням суммируются.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_activity_daily;

CREATE TABLE metrics.dl_activity_daily AS
WITH daily AS (
    SELECT
        d.activity_date,
        COUNT(*)                                                        AS dau,
        COUNT(*) FILTER (WHERE d.activity_date = u.first_activity_date) AS new_users
    FROM mart.user_activity_daily d
    JOIN mart.users u USING (user_id)
    GROUP BY d.activity_date
),
orders_daily AS (
    SELECT
        (order_time AT TIME ZONE 'UTC')::date                           AS activity_date,
        COUNT(DISTINCT user_id)                                         AS buyers,
        COUNT(*)                                                        AS orders,
        SUM(gmv)                                                        AS gmv
    FROM mart.orders
    GROUP BY 1
),
baseline AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY new_users)       AS new_users_baseline
    FROM daily
    WHERE activity_date >= DATE '2019-11-18'
)
SELECT
    d.activity_date,
    date_trunc('week', d.activity_date::timestamp)::date                AS week_start,
    EXTRACT(ISODOW FROM d.activity_date)::int                           AS iso_dow,
    CASE EXTRACT(ISODOW FROM d.activity_date)::int
        WHEN 1 THEN 'Mon' WHEN 2 THEN 'Tue' WHEN 3 THEN 'Wed' WHEN 4 THEN 'Thu'
        WHEN 5 THEN 'Fri' WHEN 6 THEN 'Sat' WHEN 7 THEN 'Sun'
    END                                                                 AS day_of_week,
    CASE WHEN d.activity_date IN (DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07')
         THEN 'anomalous day' ELSE 'regular day'
    END                                                                 AS day_flag,
    d.dau,
    d.new_users,
    ROUND(b.new_users_baseline::numeric, 1)                             AS new_users_baseline,
    COALESCE(o.buyers, 0)                                               AS buyers,
    COALESCE(o.orders, 0)                                               AS orders,
    ROUND(COALESCE(o.gmv, 0), 2)                                        AS gmv
FROM daily d
CROSS JOIN baseline b
LEFT JOIN orders_daily o USING (activity_date);

ALTER TABLE metrics.dl_activity_daily ADD PRIMARY KEY (activity_date);

COMMENT ON TABLE metrics.dl_activity_daily IS
    'Выгрузка для DataLens. Зерно: день (UTC). dau, new_users, buyers по дням не суммировать; orders и gmv суммируются.';


-- -----------------------------------------------------------------------------
-- 3. dl_activity_monthly: MAU и avg_dau по месяцам и сценариям
--    Зерно: (month, scenario). Логика блока 7.1 файла 10_metrics_activity.sql.
--    days_used  : сколько дней осталось в окне (меньше дней в месяце у сценария
--                 с исключением);
--    dau_sum    : сумма DAU по оставшимся дням; avg_dau = dau_sum / days_used.
--    stickiness_pct заполнен ТОЛЬКО для as is: между сценариями его сравнивать
--    нельзя (MAU при сокращении окна падает быстрее avg_dau, поэтому stickiness
--    растёт механически, это видно по placebo, блок 7 файла 10). Сценарии
--    сравнивать по avg_dau.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_activity_monthly;

CREATE TABLE metrics.dl_activity_monthly AS
WITH scenarios (scenario, excluded_days) AS (
    VALUES
        ('as is',             ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7', ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07'])
),
user_day AS (
    SELECT
        sc.scenario,
        date_trunc('month', d.activity_date::timestamp)::date   AS month,
        d.user_id,
        d.activity_date
    FROM mart.user_activity_daily d
    JOIN scenarios sc
      ON NOT (d.activity_date = ANY (sc.excluded_days))
    WHERE d.activity_date < DATE '2019-11-01'
    UNION ALL
    SELECT
        'as is',
        date_trunc('month', activity_date::timestamp)::date,
        user_id, activity_date
    FROM mart.user_activity_daily
    WHERE activity_date >= DATE '2019-11-01'
)
SELECT
    month,
    TO_CHAR(month, 'YYYY-MM')                                           AS month_label,
    scenario,
    COUNT(DISTINCT user_id)                                             AS mau,
    COUNT(DISTINCT activity_date)                                       AS days_used,
    COUNT(*)                                                            AS dau_sum,
    ROUND(COUNT(*)::numeric / COUNT(DISTINCT activity_date), 1)         AS avg_dau,
    CASE WHEN scenario = 'as is'
         THEN ROUND(100.0 * COUNT(*) / COUNT(DISTINCT activity_date)
                    / COUNT(DISTINCT user_id), 2)
    END                                                                 AS stickiness_pct
FROM user_day
GROUP BY month, scenario;

ALTER TABLE metrics.dl_activity_monthly ADD PRIMARY KEY (month, scenario);

COMMENT ON TABLE metrics.dl_activity_monthly IS
    'Выгрузка для DataLens. Зерно: месяц x сценарий. MAU по месяцам не суммировать; stickiness только для as is; сценарии сравнивать по avg_dau.';


-- -----------------------------------------------------------------------------
-- 4. dl_weekly: недельная аудитория и деньги (дерево North Star Metric)
--    Зерно: week_start (понедельник). Логика блоков 2 файла 10 и 4 файла 12.
--    GMV = WAU x buyer_share x orders_per_buyer x AOV.
--    week_status : 'partial week' для первой (1-6 окт) и последней (24-29 фев)
--                  недели: тренд по ним не интерпретировать;
--    gmv_wow_pct : прирост к предыдущей неделе, заполнен только если обе недели
--                  полные (в 12, блок 4, показан для всех недель, но docs/metrics.md
--                  разрешает интерпретировать только такие строки).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_weekly;

CREATE TABLE metrics.dl_weekly AS
WITH weeks AS (
    SELECT
        date_trunc('week', activity_date::timestamp)::date  AS week_start,
        COUNT(DISTINCT activity_date)                       AS days_with_data,
        COUNT(DISTINCT user_id)                             AS wau
    FROM mart.user_activity_daily
    GROUP BY 1
),
o AS (
    SELECT
        date_trunc('week', order_time AT TIME ZONE 'UTC')::date     AS week_start,
        COUNT(DISTINCT user_id)                                     AS buyers,
        COUNT(*)                                                    AS orders,
        SUM(items_cnt)                                              AS purchases,
        SUM(gmv)                                                    AS gmv
    FROM mart.orders
    GROUP BY 1
),
joined AS (
    SELECT
        w.week_start,
        w.days_with_data,
        CASE WHEN w.days_with_data = 7 THEN 'full week' ELSE 'partial week' END AS week_status,
        w.wau,
        COALESCE(o.buyers, 0)       AS buyers,
        COALESCE(o.orders, 0)       AS orders,
        COALESCE(o.purchases, 0)    AS purchases,
        COALESCE(o.gmv, 0)          AS gmv
    FROM weeks w
    LEFT JOIN o USING (week_start)
)
SELECT
    week_start,
    week_status,
    days_with_data,
    wau,
    buyers,
    orders,
    purchases,
    ROUND(gmv, 2)                                                       AS gmv,
    ROUND(gmv / NULLIF(orders, 0), 2)                                   AS aov,
    ROUND(100.0 * buyers / NULLIF(wau, 0), 2)                           AS buyer_share_pct,
    ROUND(orders::numeric / NULLIF(buyers, 0), 3)                       AS orders_per_buyer,
    CASE WHEN week_status = 'full week'
          AND LAG(week_status) OVER w = 'full week'
         THEN ROUND(100.0 * (gmv - LAG(gmv) OVER w) / NULLIF(LAG(gmv) OVER w, 0), 2)
    END                                                                 AS gmv_wow_pct
FROM joined
WINDOW w AS (ORDER BY week_start);

ALTER TABLE metrics.dl_weekly ADD PRIMARY KEY (week_start);

COMMENT ON TABLE metrics.dl_weekly IS
    'Выгрузка для DataLens. Зерно: неделя (с понедельника, UTC). wau и buyers по неделям не суммировать; orders, purchases и gmv суммируются. Тренд только по полным неделям.';


-- -----------------------------------------------------------------------------
-- 5. dl_business_monthly: GMV, заказы, AOV, ARPPU по месяцам
--    Зерно: month. Логика блоков 1 и 3 файла 12_metrics_business.sql.
--    active_users : пользователи с любым событием в месяце (знаменатель
--                   orders_per_active); buyers: пользователи с >= 1 заказом
--                   (знаменатель ARPPU и orders_per_buyer). Месяцы между собой не
--                   суммировать по active_users и buyers.
--    Строки «за весь период» нет: итог в dl_kpi_total (отношение за период нельзя
--    сравнивать с месячными напрямую, см. комментарий к блоку 3 файла 12).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_business_monthly;

CREATE TABLE metrics.dl_business_monthly AS
WITH m_orders AS (
    SELECT
        date_trunc('month', order_time AT TIME ZONE 'UTC')::date    AS month,
        COUNT(DISTINCT user_id)                                     AS buyers,
        COUNT(*)                                                    AS orders,
        SUM(items_cnt)                                              AS purchases,
        SUM(gmv)                                                    AS gmv
    FROM mart.orders
    GROUP BY 1
),
m_users AS (
    SELECT
        date_trunc('month', activity_date::timestamp)::date         AS month,
        COUNT(DISTINCT user_id)                                     AS active_users
    FROM mart.user_activity_daily
    GROUP BY 1
)
SELECT
    u.month,
    TO_CHAR(u.month, 'YYYY-MM')                                     AS month_label,
    u.active_users,
    COALESCE(o.buyers, 0)                                           AS buyers,
    COALESCE(o.orders, 0)                                           AS orders,
    COALESCE(o.purchases, 0)                                        AS purchases,
    ROUND(COALESCE(o.gmv, 0), 2)                                    AS gmv,
    ROUND(o.gmv / NULLIF(o.orders, 0), 2)                           AS aov,
    ROUND(o.gmv / NULLIF(o.buyers, 0), 2)                           AS arppu,
    ROUND(o.orders::numeric / NULLIF(u.active_users, 0), 4)         AS orders_per_active,
    ROUND(o.orders::numeric / NULLIF(o.buyers, 0), 3)               AS orders_per_buyer
FROM m_users u
LEFT JOIN m_orders o USING (month);

ALTER TABLE metrics.dl_business_monthly ADD PRIMARY KEY (month);

COMMENT ON TABLE metrics.dl_business_monthly IS
    'Выгрузка для DataLens. Зерно: месяц (UTC). gmv, orders, purchases суммируются; active_users и buyers по месяцам не суммировать. Деньги только как есть.';


-- -----------------------------------------------------------------------------
-- 6. dl_retention: retention и purchase retention (длинный формат)
--    Зерно: (cohort_week, week_n). Логика блока 2 файла 11 (там же объяснение
--    длинного формата и ограничений календарных когорт). Строки только для недель,
--    которые есть в данных.
--    retention_pct          : активные в неделе N / размер когорты;
--    purchase_retention_pct : пользователи с purchase в неделе N / размер когорты;
--    week_status            : полнота недели N (target_week); cohort_week_status:
--                             полнота недели самой когорты (неделя 0);
--    cohort_status          : 'early' для когорт до 2019-11-18 (включают старых
--                             клиентов), 'stable' с 2019-11-18 (stable_from в 11).
--    Для тепловой карты показывать week_n >= 1 и week_status = 'full week': неделя 0
--    равна 100% по определению.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_retention;

CREATE TABLE metrics.dl_retention AS
WITH cohorts AS (
    SELECT cohort_week, COUNT(*) AS cohort_size
    FROM mart.users
    GROUP BY cohort_week
),
weeks AS (
    SELECT
        date_trunc('week', activity_date::timestamp)::date  AS week_start,
        COUNT(DISTINCT activity_date) = 7                   AS is_full_week
    FROM mart.user_activity_daily
    GROUP BY 1
),
grid AS (
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
    CASE WHEN g.is_full_week  THEN 'full week' ELSE 'partial week' END  AS week_status,
    CASE WHEN cw.is_full_week THEN 'full week' ELSE 'partial week' END  AS cohort_week_status,
    CASE WHEN g.cohort_week < DATE '2019-11-18' THEN 'early' ELSE 'stable' END AS cohort_status,
    g.cohort_size,
    COALESCE(a.active_users, 0)                                         AS active_users,
    ROUND(100.0 * COALESCE(a.active_users, 0) / g.cohort_size, 2)       AS retention_pct,
    COALESCE(a.purchasers, 0)                                           AS purchasers,
    ROUND(100.0 * COALESCE(a.purchasers, 0) / g.cohort_size, 2)         AS purchase_retention_pct
FROM grid g
JOIN weeks cw ON cw.week_start = g.cohort_week
LEFT JOIN act a
       ON a.cohort_week = g.cohort_week
      AND a.activity_week = g.target_week;

ALTER TABLE metrics.dl_retention ADD PRIMARY KEY (cohort_week, week_n);

COMMENT ON TABLE metrics.dl_retention IS
    'Выгрузка для DataLens. Зерно: когорта (неделя первой активности) x неделя N. Проценты не усреднять: для сводной строки считать SUM(active_users) / SUM(cohort_size) по строкам одной недели N.';


-- -----------------------------------------------------------------------------
-- 7. dl_cohort_sensitivity: retention первых двух когорт без аномальных дней
--    Зерно: (cohort_week, scenario, week_n), week_n = 1..4. Логика блока 7 файла
--    11 (источник только mart): когорта пересчитывается по оставшейся активности,
--    как будто исключённых дней нет; пользователь, у которого все дни исключены,
--    из когорт пропадает, а вернувшийся позже попадает в когорту первой
--    оставшейся недели. Только когорты 30 сентября и 7 октября (к ним относятся
--    аномальные дни). У когорт 14 и 21 октября рост retention при исключении дней
--    это артефакт пересчёта, а не эффект аномалии (docs/metrics.md, раздел 7,
--    п. 5): в дашборд они не выносятся.
--    days_excluded_in_week : сколько исключённых дней попало в неделю когорта + N;
--    week_quality          : 'clean', если таких дней нет; иначе 'understated':
--                            retention недели занижен механически (у пользователя
--                            меньше дней, чтобы быть активным), для сравнения
--                            сценариев использовать только 'clean'.
--    Для скорости берутся дни до 24 ноября (хватает на неделю 4 когорты 7 октября).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_cohort_sensitivity;

CREATE TABLE metrics.dl_cohort_sensitivity AS
WITH scenarios (scenario, excluded_days) AS (
    VALUES
        ('as is',             ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7', ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07'])
),
ud_sc AS (
    SELECT sc.scenario, sc.excluded_days, d.user_id, d.activity_date AS day
    FROM mart.user_activity_daily d
    JOIN scenarios sc
      ON NOT (d.activity_date = ANY (sc.excluded_days))
    WHERE d.activity_date < DATE '2019-11-25'
),
cohort_user AS (
    SELECT
        scenario, user_id,
        date_trunc('week', MIN(day)::timestamp)::date           AS cohort_week
    FROM ud_sc
    GROUP BY scenario, user_id
),
cohort_size AS (
    SELECT scenario, cohort_week, COUNT(*) AS cohort_size
    FROM cohort_user
    WHERE cohort_week IN (DATE '2019-09-30', DATE '2019-10-07')
    GROUP BY scenario, cohort_week
),
user_week AS (
    SELECT DISTINCT scenario, user_id, date_trunc('week', day::timestamp)::date AS activity_week
    FROM ud_sc
),
active AS (
    SELECT
        c.scenario,
        c.cohort_week,
        (w.activity_week - c.cohort_week) / 7                   AS week_n,
        COUNT(*)                                                AS active_users
    FROM cohort_user c
    JOIN user_week w
      ON w.scenario = c.scenario AND w.user_id = c.user_id
     AND w.activity_week > c.cohort_week
    WHERE c.cohort_week IN (DATE '2019-09-30', DATE '2019-10-07')
      AND (w.activity_week - c.cohort_week) / 7 BETWEEN 1 AND 4
    GROUP BY c.scenario, c.cohort_week, (w.activity_week - c.cohort_week) / 7
),
excl AS (
    SELECT
        s.scenario,
        k.cohort_week,
        n.week_n,
        (SELECT COUNT(*) FROM unnest(s.excluded_days) x
          WHERE date_trunc('week', x::timestamp)::date = k.cohort_week + 7 * n.week_n)  AS days_excluded_in_week
    FROM scenarios s
    CROSS JOIN (VALUES (DATE '2019-09-30'), (DATE '2019-10-07')) AS k(cohort_week)
    CROSS JOIN generate_series(1, 4) AS n(week_n)
)
SELECT
    c.cohort_week,
    c.scenario,
    e.week_n,
    c.cohort_size,
    COALESCE(a.active_users, 0)                                         AS active_users,
    ROUND(100.0 * COALESCE(a.active_users, 0) / c.cohort_size, 2)       AS retention_pct,
    e.days_excluded_in_week,
    CASE WHEN e.days_excluded_in_week = 0 THEN 'clean' ELSE 'understated' END AS week_quality
FROM cohort_size c
JOIN excl e
  ON e.scenario = c.scenario AND e.cohort_week = c.cohort_week
LEFT JOIN active a
  ON a.scenario = c.scenario AND a.cohort_week = c.cohort_week AND a.week_n = e.week_n;

ALTER TABLE metrics.dl_cohort_sensitivity ADD PRIMARY KEY (cohort_week, scenario, week_n);

COMMENT ON TABLE metrics.dl_cohort_sensitivity IS
    'Выгрузка для DataLens. Зерно: когорта (30 сентября, 7 октября) x сценарий x неделя N (1-4). Сценарии сравнивать только по week_quality = clean. Размер когорты зависит от сценария.';


-- -----------------------------------------------------------------------------
-- 8. dl_repeat_30d: Repeat purchase rate за 30 дней по когортам
--    Зерно: cohort_week. Логика блока 4 файла 11 (определения eligible и stable_from
--    там же): в расчёт берутся покупатели, у которых после первого заказа в данных
--    осталось не меньше 30 дней; повтор = второй заказ не позже чем через 30 суток
--    после первого (по точному времени).
--    cohort_status    : 'early' (до 2019-11-18, включает старых клиентов),
--                       'partial' (неделя когорты заканчивается позже граничной
--                       даты: окно 30 дней закрыто не у всех, у поздних когорт
--                       eligible_buyers = 0), 'stable' (остальные);
--    repeat_within_1d, repeat_1_7d, repeat_7_30d : из repeat_30d, повтор в течение
--                       1 суток, позже 1 и до 7, позже 7 и до 30 суток после первого
--                       заказа; в сумме дают repeat_30d (интервалы по точному
--                       времени, поэтому сумма совпадает точно).
--    Вывод по Repeat purchase rate за 30 дней строим по cohort_status = 'stable':
--    SUM(repeat_30d) / SUM(eligible_buyers).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_repeat_30d;

CREATE TABLE metrics.dl_repeat_30d AS
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
        )                                                           AS repeat_30d,
        COUNT(*) FILTER (
            WHERE u.orders_cnt >= 1
              AND (u.first_order_time AT TIME ZONE 'UTC')::date <= p.last_eligible_date
              AND u.second_order_time <= u.first_order_time + INTERVAL '1 day'
        )                                                           AS repeat_within_1d,
        COUNT(*) FILTER (
            WHERE u.orders_cnt >= 1
              AND (u.first_order_time AT TIME ZONE 'UTC')::date <= p.last_eligible_date
              AND u.second_order_time >  u.first_order_time + INTERVAL '1 day'
              AND u.second_order_time <= u.first_order_time + INTERVAL '7 days'
        )                                                           AS repeat_1_7d,
        COUNT(*) FILTER (
            WHERE u.orders_cnt >= 1
              AND (u.first_order_time AT TIME ZONE 'UTC')::date <= p.last_eligible_date
              AND u.second_order_time >  u.first_order_time + INTERVAL '7 days'
              AND u.second_order_time <= u.first_order_time + INTERVAL '30 days'
        )                                                           AS repeat_7_30d
    FROM mart.users u
    CROSS JOIN params p
    GROUP BY u.cohort_week
)
SELECT
    c.cohort_week,
    CASE
        WHEN c.cohort_week < p.stable_from                  THEN 'early'
        WHEN c.cohort_week + 6 > p.last_eligible_date       THEN 'partial'
        ELSE 'stable'
    END                                                             AS cohort_status,
    c.buyers,
    c.eligible_buyers,
    ROUND(100.0 * c.eligible_buyers / NULLIF(c.buyers, 0), 1)       AS eligible_share_pct,
    c.repeat_30d,
    c.repeat_within_1d,
    c.repeat_1_7d,
    c.repeat_7_30d,
    ROUND(100.0 * c.repeat_30d / NULLIF(c.eligible_buyers, 0), 2)   AS repeat_30d_rate_pct
FROM c
CROSS JOIN params p;

ALTER TABLE metrics.dl_repeat_30d ADD PRIMARY KEY (cohort_week);

COMMENT ON TABLE metrics.dl_repeat_30d IS
    'Выгрузка для DataLens. Зерно: когорта (неделя первой активности). Для выводов брать cohort_status = stable: SUM(repeat_30d) / SUM(eligible_buyers). Проценты не усреднять.';


-- -----------------------------------------------------------------------------
-- 9. dl_kpi_total: итоги за весь период (одна строка)
--    Источники: mart.users (воронка, покупатели), mart.orders (деньги),
--    dl_repeat_30d (повторы за 30 дней по стабильным когортам, блок 8).
--    Воронка строгая (view -> cart -> purchase), как в блоке 1.1 файла 09.
--    repeat_purchase_rate_pct зависит от окна наблюдения (5 месяцев): для выводов
--    использовать stable_repeat_30d_rate_pct (блок 3 файла 11).
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS metrics.dl_kpi_total;

CREATE TABLE metrics.dl_kpi_total AS
WITH u AS (
    SELECT
        COUNT(*)                                                        AS total_users,
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users,
        COUNT(*) FILTER (WHERE orders_cnt >= 1)                         AS buyers,
        COUNT(*) FILTER (WHERE orders_cnt >= 2)                         AS repeat_buyers
    FROM mart.users
),
o AS (
    SELECT COUNT(*) AS orders, SUM(items_cnt) AS purchases, SUM(gmv) AS gmv
    FROM mart.orders
),
p AS (
    SELECT MIN(activity_date) AS first_date, MAX(activity_date) AS last_date
    FROM mart.user_activity_daily
),
r AS (
    SELECT SUM(eligible_buyers) AS eligible_buyers, SUM(repeat_30d) AS repeat_30d
    FROM metrics.dl_repeat_30d
    WHERE cohort_status = 'stable'
)
SELECT
    p.first_date,
    p.last_date,
    u.total_users,
    u.view_users,
    u.cart_users,
    u.purchase_users,
    ROUND(100.0 * u.cart_users     / NULLIF(u.view_users, 0), 2)        AS view_to_cart_pct,
    ROUND(100.0 * u.purchase_users / NULLIF(u.cart_users, 0), 2)        AS cart_to_purchase_pct,
    ROUND(100.0 * u.purchase_users / NULLIF(u.view_users, 0), 2)        AS conversion_pct,
    u.buyers,
    u.repeat_buyers,
    ROUND(100.0 * u.repeat_buyers / NULLIF(u.buyers, 0), 2)             AS repeat_purchase_rate_pct,
    o.orders,
    o.purchases,
    ROUND(o.gmv, 2)                                                     AS gmv,
    ROUND(o.gmv / NULLIF(o.orders, 0), 2)                               AS aov,
    r.eligible_buyers                                                   AS stable_eligible_buyers,
    r.repeat_30d                                                        AS stable_repeat_30d,
    ROUND(100.0 * r.repeat_30d / NULLIF(r.eligible_buyers, 0), 2)       AS stable_repeat_30d_rate_pct
FROM u CROSS JOIN o CROSS JOIN p CROSS JOIN r;

COMMENT ON TABLE metrics.dl_kpi_total IS
    'Выгрузка для DataLens. Одна строка: итоги за весь период (воронка по пользователям, покупатели, заказы, GMV, AOV, повторы за 30 дней по стабильным когортам).';


-- =============================================================================
-- 10. Сверки: каждая выгрузка против stg.events напрямую
--     Во всех блоках expected считается из stg.events (через временные таблицы
--     tmp_chk_*, построенные здесь же), actual берётся из dl_* таблиц. Временные
--     таблицы строятся независимо от витрин mart: расхождение значит, что
--     выгрузка или витрина устарела или посчитана неверно. Запускать в одном
--     окне с блоками 1-9 (временные таблицы живут в текущей сессии).
--     Колонки результата одинаковые во всех блоках: check_name, expected,
--     actual, status; во всех строках должно быть OK.
-- =============================================================================

-- Подготовка: события, сведённые из stg.events до пользователь-день, заказов и
-- сессий. Это та же логика, что в витринах, но выполненная заново.
DROP TABLE IF EXISTS tmp_chk_user_day;
CREATE TEMP TABLE tmp_chk_user_day AS
SELECT
    user_id,
    (event_time AT TIME ZONE 'UTC')::date           AS d,
    BOOL_OR(event_type = 'view')                    AS v,
    BOOL_OR(event_type = 'cart')                    AS c,
    BOOL_OR(event_type = 'remove_from_cart')        AS r,
    BOOL_OR(event_type = 'purchase')                AS p
FROM stg.events
GROUP BY user_id, (event_time AT TIME ZONE 'UTC')::date;

DROP TABLE IF EXISTS tmp_chk_orders;
CREATE TEMP TABLE tmp_chk_orders AS
SELECT
    user_id,
    user_session,
    event_time                                      AS order_time,
    COUNT(*)                                        AS items_cnt,
    SUM(price)                                      AS gmv
FROM stg.events
WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
GROUP BY user_id, user_session, event_time;

DROP TABLE IF EXISTS tmp_chk_sessions;
CREATE TEMP TABLE tmp_chk_sessions AS
SELECT
    user_session,
    user_id,
    MIN((event_time AT TIME ZONE 'UTC')::date)      AS start_date,
    BOOL_OR(event_type = 'view')                    AS v,
    BOOL_OR(event_type = 'cart')                    AS c,
    BOOL_OR(event_type = 'purchase')                AS p
FROM stg.events
WHERE user_session IS NOT NULL
GROUP BY user_session, user_id;


-- 10.1. Итоги: деньги и заказы во всех таблицах против stg.events;
--       воронка, покупатели и период в dl_kpi_total против stg.events.
--       Заказы в stg считаются по всем покупкам без дубля и с ценой, в том числе
--       без user_session; mart.orders покупки без сессии не включает. Покупок без
--       сессии в данных нет (docs/metrics.md, раздел 6, п. 3; проверка 5.1 в файле 12),
--       поэтому расхождение здесь означало бы, что это перестало быть правдой.
WITH s_money AS (
    SELECT SUM(gmv) AS gmv, SUM(items_cnt) AS purchases, COUNT(*) AS orders
    FROM tmp_chk_orders
),
s_users AS (
    SELECT
        COUNT(*)                                                AS total_users,
        COUNT(*) FILTER (WHERE v)                               AS view_users,
        COUNT(*) FILTER (WHERE v AND c)                         AS cart_users,
        COUNT(*) FILTER (WHERE v AND c AND p)                   AS purchase_users
    FROM (
        SELECT user_id, BOOL_OR(v) AS v, BOOL_OR(c) AS c, BOOL_OR(p) AS p
        FROM tmp_chk_user_day GROUP BY user_id
    ) x
),
s_buyers AS (
    SELECT
        COUNT(*)                                                AS buyers,
        COUNT(*) FILTER (WHERE orders >= 2)                     AS repeat_buyers
    FROM (SELECT user_id, COUNT(*) AS orders FROM tmp_chk_orders GROUP BY user_id) x
),
s_period AS (
    SELECT MIN(d) AS first_date, MAX(d) AS last_date FROM tmp_chk_user_day
),
k AS (SELECT * FROM metrics.dl_kpi_total),
bm AS (SELECT SUM(gmv) AS gmv, SUM(orders) AS orders, SUM(purchases) AS purchases FROM metrics.dl_business_monthly),
wk AS (SELECT SUM(gmv) AS gmv, SUM(orders) AS orders, SUM(purchases) AS purchases FROM metrics.dl_weekly),
dd AS (SELECT SUM(gmv) AS gmv, SUM(orders) AS orders FROM metrics.dl_activity_daily)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END   AS status
FROM s_money m
CROSS JOIN s_users su
CROSS JOIN s_buyers sb
CROSS JOIN s_period sp
CROSS JOIN k
CROSS JOIN bm
CROSS JOIN wk
CROSS JOIN dd
CROSS JOIN LATERAL (VALUES
    ('GMV: dl_kpi_total',                       m.gmv::numeric,          k.gmv::numeric),
    ('GMV: dl_business_monthly (sum)',          m.gmv::numeric,          bm.gmv::numeric),
    ('GMV: dl_weekly (sum)',                    m.gmv::numeric,          wk.gmv::numeric),
    ('GMV: dl_activity_daily (sum)',            m.gmv::numeric,          dd.gmv::numeric),
    ('orders: dl_kpi_total',                    m.orders::numeric,       k.orders::numeric),
    ('orders: dl_business_monthly (sum)',       m.orders::numeric,       bm.orders::numeric),
    ('orders: dl_weekly (sum)',                 m.orders::numeric,       wk.orders::numeric),
    ('orders: dl_activity_daily (sum)',         m.orders::numeric,       dd.orders::numeric),
    ('purchases: dl_kpi_total',                 m.purchases::numeric,    k.purchases::numeric),
    ('purchases: dl_business_monthly (sum)',    m.purchases::numeric,    bm.purchases::numeric),
    ('purchases: dl_weekly (sum)',              m.purchases::numeric,    wk.purchases::numeric),
    ('total users: dl_kpi_total',               su.total_users::numeric,     k.total_users::numeric),
    ('view users: dl_kpi_total',                su.view_users::numeric,      k.view_users::numeric),
    ('cart users (strict): dl_kpi_total',       su.cart_users::numeric,      k.cart_users::numeric),
    ('purchase users (strict): dl_kpi_total',   su.purchase_users::numeric,  k.purchase_users::numeric),
    ('buyers: dl_kpi_total',                    sb.buyers::numeric,          k.buyers::numeric),
    ('repeat buyers: dl_kpi_total',             sb.repeat_buyers::numeric,   k.repeat_buyers::numeric),
    ('first date: dl_kpi_total',                (sp.first_date - DATE '2000-01-01')::numeric,
                                                (k.first_date  - DATE '2000-01-01')::numeric),
    ('last date: dl_kpi_total',                 (sp.last_date  - DATE '2000-01-01')::numeric,
                                                (k.last_date   - DATE '2000-01-01')::numeric)
) AS x(check_name, expected, actual);


-- 10.2. Воронка по месяцам и сценариям (dl_funnel_monthly) против stg.events.
--       Сценарий excl. строится здесь независимым способом: явный список дат в
--       NOT IN, а не массив с JOIN, как в блоке 1. Октябрь excl. сравнивается
--       только за октябрь (в других месяцах этого сценария нет).
--       Результат: число строк с расхождением по любой колонке (ожидаем 0).
WITH ud AS (
    SELECT 'as is' AS scenario, date_trunc('month', d::timestamp)::date AS month, user_id, v, c, r, p
    FROM tmp_chk_user_day
    UNION ALL
    SELECT 'excl. Oct 2, 6, 7', DATE '2019-10-01', user_id, v, c, r, p
    FROM tmp_chk_user_day
    WHERE d BETWEEN DATE '2019-10-01' AND DATE '2019-10-31'
      AND d NOT IN (DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07')
),
um AS (
    SELECT scenario, month, user_id,
           BOOL_OR(v) AS v, BOOL_OR(c) AS c, BOOL_OR(r) AS r, BOOL_OR(p) AS p
    FROM ud GROUP BY scenario, month, user_id
),
e_users AS (
    SELECT
        scenario, month,
        COUNT(*) FILTER (WHERE v)               AS view_users,
        COUNT(*) FILTER (WHERE v AND c)         AS cart_users,
        COUNT(*) FILTER (WHERE v AND c AND p)   AS purchase_users,
        COUNT(*) FILTER (WHERE c)               AS users_with_cart,
        COUNT(*) FILTER (WHERE c AND r)         AS users_with_cart_and_remove
    FROM um GROUP BY scenario, month
),
ss AS (
    SELECT 'as is' AS scenario, date_trunc('month', start_date::timestamp)::date AS month, v, c, p
    FROM tmp_chk_sessions
    UNION ALL
    SELECT 'excl. Oct 2, 6, 7', DATE '2019-10-01', v, c, p
    FROM tmp_chk_sessions
    WHERE start_date BETWEEN DATE '2019-10-01' AND DATE '2019-10-31'
      AND start_date NOT IN (DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07')
),
e_sess AS (
    SELECT
        scenario, month,
        COUNT(*) FILTER (WHERE v)               AS view_sessions,
        COUNT(*) FILTER (WHERE v AND c AND p)   AS converted_sessions,
        COUNT(*) FILTER (WHERE c)               AS cart_sessions,
        COUNT(*) FILTER (WHERE c AND p)         AS cart_purchase_sessions
    FROM ss GROUP BY scenario, month
),
expected AS (
    SELECT * FROM e_users JOIN e_sess USING (scenario, month)
)
SELECT
    'dl_funnel_monthly: rows differing from stg.events'     AS check_name,
    0::numeric                                              AS expected,
    COUNT(*)::numeric                                       AS actual,
    CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'FAIL' END        AS status
FROM expected e
FULL JOIN metrics.dl_funnel_monthly f
  ON f.month = e.month AND f.scenario = e.scenario
WHERE f.month IS NULL OR e.month IS NULL
   OR f.view_users                 IS DISTINCT FROM e.view_users
   OR f.cart_users                 IS DISTINCT FROM e.cart_users
   OR f.purchase_users             IS DISTINCT FROM e.purchase_users
   OR f.users_with_cart            IS DISTINCT FROM e.users_with_cart
   OR f.users_with_cart_and_remove IS DISTINCT FROM e.users_with_cart_and_remove
   OR f.view_sessions              IS DISTINCT FROM e.view_sessions
   OR f.converted_sessions         IS DISTINCT FROM e.converted_sessions
   OR f.cart_sessions              IS DISTINCT FROM e.cart_sessions
   OR f.cart_purchase_sessions     IS DISTINCT FROM e.cart_purchase_sessions;


-- 10.3. Активность: дни, месяцы по сценариям и недели против stg.events.
--       Результат: число строк с расхождением по любой колонке (ожидаем 0).
WITH first_day AS (
    SELECT user_id, MIN(d) AS first_date FROM tmp_chk_user_day GROUP BY user_id
),
e_day AS (
    SELECT
        t.d                                                         AS activity_date,
        COUNT(*)                                                    AS dau,
        COUNT(*) FILTER (WHERE t.d = f.first_date)                  AS new_users
    FROM tmp_chk_user_day t
    JOIN first_day f USING (user_id)
    GROUP BY t.d
),
e_day_orders AS (
    SELECT
        (order_time AT TIME ZONE 'UTC')::date                       AS activity_date,
        COUNT(DISTINCT user_id)                                     AS buyers,
        COUNT(*)                                                    AS orders,
        SUM(gmv)                                                    AS gmv
    FROM tmp_chk_orders GROUP BY 1
),
e_baseline AS (
    SELECT ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY new_users))::numeric, 1) AS b
    FROM e_day WHERE activity_date >= DATE '2019-11-18'
),
daily_diff AS (
    SELECT COUNT(*) AS n
    FROM e_day e
    LEFT JOIN e_day_orders o USING (activity_date)
    CROSS JOIN e_baseline b
    FULL JOIN metrics.dl_activity_daily a ON a.activity_date = e.activity_date
    WHERE a.activity_date IS NULL OR e.activity_date IS NULL
       OR a.dau                IS DISTINCT FROM e.dau
       OR a.new_users          IS DISTINCT FROM e.new_users
       OR a.new_users_baseline IS DISTINCT FROM b.b
       OR a.buyers             IS DISTINCT FROM COALESCE(o.buyers, 0)
       OR a.orders             IS DISTINCT FROM COALESCE(o.orders, 0)
       OR a.gmv                IS DISTINCT FROM ROUND(COALESCE(o.gmv, 0), 2)
       OR a.day_flag           IS DISTINCT FROM CASE WHEN e.activity_date IN
              (DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07')
              THEN 'anomalous day' ELSE 'regular day' END
),
ma AS (
    SELECT 'as is' AS scenario, date_trunc('month', d::timestamp)::date AS month, user_id, d
    FROM tmp_chk_user_day
    UNION ALL
    SELECT 'excl. Oct 2, 6, 7', DATE '2019-10-01', user_id, d
    FROM tmp_chk_user_day
    WHERE d BETWEEN DATE '2019-10-01' AND DATE '2019-10-31'
      AND d NOT IN (DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07')
),
e_month AS (
    SELECT
        scenario, month,
        COUNT(DISTINCT user_id)                                     AS mau,
        COUNT(DISTINCT d)                                           AS days_used,
        COUNT(*)                                                    AS dau_sum
    FROM ma GROUP BY scenario, month
),
monthly_diff AS (
    SELECT COUNT(*) AS n
    FROM e_month e
    FULL JOIN metrics.dl_activity_monthly a
      ON a.month = e.month AND a.scenario = e.scenario
    WHERE a.month IS NULL OR e.month IS NULL
       OR a.mau       IS DISTINCT FROM e.mau
       OR a.days_used IS DISTINCT FROM e.days_used
       OR a.dau_sum   IS DISTINCT FROM e.dau_sum
       OR a.avg_dau   IS DISTINCT FROM ROUND(e.dau_sum::numeric / e.days_used, 1)
       OR (a.scenario = 'as is' AND a.stickiness_pct IS DISTINCT FROM
              ROUND(100.0 * e.dau_sum / e.days_used / e.mau, 2))
       OR (a.scenario <> 'as is' AND a.stickiness_pct IS NOT NULL)
),
e_week AS (
    SELECT
        date_trunc('week', d::timestamp)::date                      AS week_start,
        COUNT(DISTINCT d)                                           AS days_with_data,
        COUNT(DISTINCT user_id)                                     AS wau
    FROM tmp_chk_user_day GROUP BY 1
),
e_week_orders AS (
    SELECT
        date_trunc('week', order_time AT TIME ZONE 'UTC')::date     AS week_start,
        COUNT(DISTINCT user_id)                                     AS buyers,
        COUNT(*)                                                    AS orders,
        SUM(items_cnt)                                              AS purchases,
        SUM(gmv)                                                    AS gmv
    FROM tmp_chk_orders GROUP BY 1
),
weekly_diff AS (
    SELECT COUNT(*) AS n
    FROM e_week e
    LEFT JOIN e_week_orders o USING (week_start)
    FULL JOIN metrics.dl_weekly a ON a.week_start = e.week_start
    WHERE a.week_start IS NULL OR e.week_start IS NULL
       OR a.days_with_data IS DISTINCT FROM e.days_with_data
       OR a.wau            IS DISTINCT FROM e.wau
       OR a.buyers         IS DISTINCT FROM COALESCE(o.buyers, 0)
       OR a.orders         IS DISTINCT FROM COALESCE(o.orders, 0)
       OR a.purchases      IS DISTINCT FROM COALESCE(o.purchases, 0)
       OR a.gmv            IS DISTINCT FROM ROUND(COALESCE(o.gmv, 0), 2)
       OR a.week_status    IS DISTINCT FROM CASE WHEN e.days_with_data = 7
                                                 THEN 'full week' ELSE 'partial week' END
),
e_bm AS (
    SELECT
        date_trunc('month', d::timestamp)::date                     AS month,
        COUNT(DISTINCT user_id)                                     AS active_users
    FROM tmp_chk_user_day GROUP BY 1
),
e_bm_orders AS (
    SELECT
        date_trunc('month', order_time AT TIME ZONE 'UTC')::date    AS month,
        COUNT(DISTINCT user_id)                                     AS buyers,
        COUNT(*)                                                    AS orders,
        SUM(items_cnt)                                              AS purchases,
        SUM(gmv)                                                    AS gmv
    FROM tmp_chk_orders GROUP BY 1
),
business_diff AS (
    SELECT COUNT(*) AS n
    FROM e_bm e
    LEFT JOIN e_bm_orders o USING (month)
    FULL JOIN metrics.dl_business_monthly a ON a.month = e.month
    WHERE a.month IS NULL OR e.month IS NULL
       OR a.active_users IS DISTINCT FROM e.active_users
       OR a.buyers       IS DISTINCT FROM COALESCE(o.buyers, 0)
       OR a.orders       IS DISTINCT FROM COALESCE(o.orders, 0)
       OR a.purchases    IS DISTINCT FROM COALESCE(o.purchases, 0)
       OR a.gmv          IS DISTINCT FROM ROUND(COALESCE(o.gmv, 0), 2)
       OR a.aov          IS DISTINCT FROM ROUND(o.gmv / NULLIF(o.orders, 0), 2)
       OR a.arppu        IS DISTINCT FROM ROUND(o.gmv / NULLIF(o.buyers, 0), 2)
)
SELECT
    x.check_name,
    0::numeric                                              AS expected,
    x.n::numeric                                            AS actual,
    CASE WHEN x.n = 0 THEN 'OK' ELSE 'FAIL' END             AS status
FROM (
    SELECT 'dl_activity_daily: rows differing from stg.events'   AS check_name, n FROM daily_diff
    UNION ALL
    SELECT 'dl_activity_monthly: rows differing from stg.events',               n FROM monthly_diff
    UNION ALL
    SELECT 'dl_weekly: rows differing from stg.events',                         n FROM weekly_diff
    UNION ALL
    SELECT 'dl_business_monthly: rows differing from stg.events',               n FROM business_diff
) x;


-- 10.4. Когорты: dl_retention, dl_cohort_sensitivity, dl_repeat_30d против stg.events.
--       Результат: число строк с расхождением (ожидаем 0).
WITH first_day AS (
    SELECT user_id, MIN(d) AS first_date FROM tmp_chk_user_day GROUP BY user_id
),
cohort AS (
    SELECT user_id, date_trunc('week', first_date::timestamp)::date AS cohort_week
    FROM first_day
),
e_size AS (
    SELECT cohort_week, COUNT(*) AS cohort_size FROM cohort GROUP BY 1
),
uw AS (
    SELECT user_id, date_trunc('week', d::timestamp)::date AS aw, BOOL_OR(p) AS p
    FROM tmp_chk_user_day GROUP BY 1, 2
),
e_ret AS (
    SELECT
        c.cohort_week,
        (uw.aw - c.cohort_week) / 7                                 AS week_n,
        COUNT(*)                                                    AS active_users,
        COUNT(*) FILTER (WHERE uw.p)                                AS purchasers
    FROM cohort c JOIN uw USING (user_id)
    GROUP BY 1, 2
),
retention_diff AS (
    SELECT COUNT(*) AS n
    FROM metrics.dl_retention r
    JOIN e_size s ON s.cohort_week = r.cohort_week
    LEFT JOIN e_ret e ON e.cohort_week = r.cohort_week AND e.week_n = r.week_n
    WHERE r.cohort_size   IS DISTINCT FROM s.cohort_size
       OR r.active_users  IS DISTINCT FROM COALESCE(e.active_users, 0)
       OR r.purchasers    IS DISTINCT FROM COALESCE(e.purchasers, 0)
       OR r.cohort_status IS DISTINCT FROM CASE WHEN r.cohort_week < DATE '2019-11-18'
                                                THEN 'early' ELSE 'stable' END
),
retention_extra AS (
    -- строки в stg, которых нет в выгрузке (неделя N вне сетки)
    SELECT COUNT(*) AS n
    FROM e_ret e
    LEFT JOIN metrics.dl_retention r ON r.cohort_week = e.cohort_week AND r.week_n = e.week_n
    WHERE r.cohort_week IS NULL
),
-- Чувствительность: независимо от блока 7: список дат в NOT IN, источник tmp_chk_user_day.
sens_scn AS (
    SELECT 'as is' AS scenario, user_id, d FROM tmp_chk_user_day WHERE d < DATE '2019-11-25'
    UNION ALL
    SELECT 'excl. Oct 2, 6, 7', user_id, d FROM tmp_chk_user_day
    WHERE d < DATE '2019-11-25'
      AND d NOT IN (DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07')
),
sens_cohort AS (
    SELECT scenario, user_id, date_trunc('week', MIN(d)::timestamp)::date AS cw
    FROM sens_scn GROUP BY 1, 2
),
sens_uw AS (
    SELECT DISTINCT scenario, user_id, date_trunc('week', d::timestamp)::date AS aw
    FROM sens_scn
),
e_sens AS (
    -- размер когорты для каждой недели N (размер от N не зависит)
    SELECT c.scenario, c.cw AS cohort_week, n.week_n, COUNT(*) AS cohort_size
    FROM sens_cohort c
    CROSS JOIN generate_series(1, 4) AS n(week_n)
    WHERE c.cw IN (DATE '2019-09-30', DATE '2019-10-07')
    GROUP BY c.scenario, c.cw, n.week_n
),
e_sens_active AS (
    SELECT c.scenario, c.cw AS cohort_week, (w.aw - c.cw) / 7 AS week_n, COUNT(*) AS active_users
    FROM sens_cohort c
    JOIN sens_uw w ON w.scenario = c.scenario AND w.user_id = c.user_id AND w.aw > c.cw
    WHERE c.cw IN (DATE '2019-09-30', DATE '2019-10-07')
      AND (w.aw - c.cw) / 7 BETWEEN 1 AND 4
    GROUP BY 1, 2, 3
),
sens_diff AS (
    SELECT COUNT(*) AS n
    FROM metrics.dl_cohort_sensitivity s
    LEFT JOIN e_sens e
           ON e.scenario = s.scenario AND e.cohort_week = s.cohort_week AND e.week_n = s.week_n
    LEFT JOIN e_sens_active a
           ON a.scenario = s.scenario AND a.cohort_week = s.cohort_week AND a.week_n = s.week_n
    WHERE s.cohort_size   IS DISTINCT FROM e.cohort_size
       OR s.active_users  IS DISTINCT FROM COALESCE(a.active_users, 0)
),
-- as is из чувствительности должен совпасть с dl_retention (самопроверка)
sens_vs_retention AS (
    SELECT COUNT(*) AS n
    FROM metrics.dl_cohort_sensitivity s
    LEFT JOIN metrics.dl_retention r
           ON r.cohort_week = s.cohort_week AND r.week_n = s.week_n
    WHERE s.scenario = 'as is'
      AND (r.cohort_week IS NULL
           OR r.cohort_size  IS DISTINCT FROM s.cohort_size
           OR r.active_users IS DISTINCT FROM s.active_users
           OR r.retention_pct IS DISTINCT FROM s.retention_pct)
),
-- Repeat за 30 дней из tmp_chk_orders
ord_rank AS (
    SELECT user_id, order_time,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY order_time, user_session) AS rn
    FROM tmp_chk_orders
),
ord_two AS (
    SELECT
        user_id,
        MAX(order_time) FILTER (WHERE rn = 1) AS first_order_time,
        MAX(order_time) FILTER (WHERE rn = 2) AS second_order_time
    FROM ord_rank WHERE rn <= 2 GROUP BY user_id
),
lim AS (SELECT MAX(d) - 30 AS last_eligible_date FROM tmp_chk_user_day),
e_rep AS (
    SELECT
        c.cohort_week,
        COUNT(*)                                                    AS buyers,
        COUNT(*) FILTER (WHERE (t.first_order_time AT TIME ZONE 'UTC')::date <= l.last_eligible_date)
                                                                    AS eligible_buyers,
        COUNT(*) FILTER (WHERE (t.first_order_time AT TIME ZONE 'UTC')::date <= l.last_eligible_date
                           AND t.second_order_time <= t.first_order_time + INTERVAL '30 days')
                                                                    AS repeat_30d,
        COUNT(*) FILTER (WHERE (t.first_order_time AT TIME ZONE 'UTC')::date <= l.last_eligible_date
                           AND t.second_order_time <= t.first_order_time + INTERVAL '1 day')
                                                                    AS repeat_within_1d,
        COUNT(*) FILTER (WHERE (t.first_order_time AT TIME ZONE 'UTC')::date <= l.last_eligible_date
                           AND t.second_order_time >  t.first_order_time + INTERVAL '1 day'
                           AND t.second_order_time <= t.first_order_time + INTERVAL '7 days')
                                                                    AS repeat_1_7d,
        COUNT(*) FILTER (WHERE (t.first_order_time AT TIME ZONE 'UTC')::date <= l.last_eligible_date
                           AND t.second_order_time >  t.first_order_time + INTERVAL '7 days'
                           AND t.second_order_time <= t.first_order_time + INTERVAL '30 days')
                                                                    AS repeat_7_30d
    FROM ord_two t
    JOIN cohort c USING (user_id)
    CROSS JOIN lim l
    GROUP BY c.cohort_week
),
repeat_diff AS (
    SELECT COUNT(*) AS n
    FROM metrics.dl_repeat_30d r
    LEFT JOIN e_rep e USING (cohort_week)
    WHERE r.buyers           IS DISTINCT FROM COALESCE(e.buyers, 0)
       OR r.eligible_buyers  IS DISTINCT FROM COALESCE(e.eligible_buyers, 0)
       OR r.repeat_30d       IS DISTINCT FROM COALESCE(e.repeat_30d, 0)
       OR r.repeat_within_1d IS DISTINCT FROM COALESCE(e.repeat_within_1d, 0)
       OR r.repeat_1_7d      IS DISTINCT FROM COALESCE(e.repeat_1_7d, 0)
       OR r.repeat_7_30d     IS DISTINCT FROM COALESCE(e.repeat_7_30d, 0)
       OR r.repeat_30d       IS DISTINCT FROM
              (r.repeat_within_1d + r.repeat_1_7d + r.repeat_7_30d)
)
SELECT
    x.check_name,
    0::numeric                                              AS expected,
    x.n::numeric                                            AS actual,
    CASE WHEN x.n = 0 THEN 'OK' ELSE 'FAIL' END             AS status
FROM (
    SELECT 'dl_retention: rows differing from stg.events'              AS check_name, n FROM retention_diff
    UNION ALL
    SELECT 'dl_retention: stg rows missing in the export grid',                      n FROM retention_extra
    UNION ALL
    SELECT 'dl_cohort_sensitivity: rows differing from stg.events',                  n FROM sens_diff
    UNION ALL
    SELECT 'dl_cohort_sensitivity (as is) vs dl_retention: rows differing',          n FROM sens_vs_retention
    UNION ALL
    SELECT 'dl_repeat_30d: rows differing from stg.events (and buckets sum)',        n FROM repeat_diff
) x;


-- 10.5. Структура: зерно, ключи и число строк. Во всех таблицах ожидаем:
--       строк = уникальных ключей; ключи без NULL; число строк = ожидаемому.
--       Ожидаемое число строк считается из stg.events:
--         dl_funnel_monthly, dl_activity_monthly : месяцы + 1 (октябрь в 2 сценариях);
--         dl_activity_daily : дни; dl_weekly : недели; dl_business_monthly : месяцы;
--         dl_retention      : пары (когорта, неделя данных не раньше когорты);
--         dl_cohort_sensitivity : 2 когорты x 2 сценария x 4 недели = 16;
--         dl_repeat_30d     : когорты; dl_kpi_total : 1.
WITH e AS (
    SELECT
        COUNT(DISTINCT d)                                           AS days,
        COUNT(DISTINCT date_trunc('week',  d::timestamp)::date)     AS weeks,
        COUNT(DISTINCT date_trunc('month', d::timestamp)::date)     AS months
    FROM tmp_chk_user_day
),
e_ret_rows AS (
    SELECT COUNT(*) AS n
    FROM (SELECT DISTINCT date_trunc('week', first_date::timestamp)::date AS cw
          FROM (SELECT user_id, MIN(d) AS first_date FROM tmp_chk_user_day GROUP BY user_id) f) c
    JOIN (SELECT DISTINCT date_trunc('week', d::timestamp)::date AS ws FROM tmp_chk_user_day) w
      ON w.ws >= c.cw
),
e_cohorts AS (
    SELECT COUNT(DISTINCT date_trunc('week', first_date::timestamp)::date) AS n
    FROM (SELECT user_id, MIN(d) AS first_date FROM tmp_chk_user_day GROUP BY user_id) f
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END   AS status
FROM e
CROSS JOIN e_ret_rows rr
CROSS JOIN e_cohorts ec
CROSS JOIN LATERAL (VALUES
    ('dl_funnel_monthly: rows',           (e.months + 1)::numeric,  (SELECT COUNT(*) FROM metrics.dl_funnel_monthly)::numeric),
    ('dl_funnel_monthly: duplicate keys', 0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT (month, scenario)) FROM metrics.dl_funnel_monthly)::numeric),
    ('dl_activity_daily: rows',           e.days::numeric,          (SELECT COUNT(*) FROM metrics.dl_activity_daily)::numeric),
    ('dl_activity_daily: duplicate keys', 0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT activity_date) FROM metrics.dl_activity_daily)::numeric),
    ('dl_activity_monthly: rows',         (e.months + 1)::numeric,  (SELECT COUNT(*) FROM metrics.dl_activity_monthly)::numeric),
    ('dl_activity_monthly: duplicate keys', 0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT (month, scenario)) FROM metrics.dl_activity_monthly)::numeric),
    ('dl_weekly: rows',                   e.weeks::numeric,         (SELECT COUNT(*) FROM metrics.dl_weekly)::numeric),
    ('dl_weekly: duplicate keys',         0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT week_start) FROM metrics.dl_weekly)::numeric),
    ('dl_business_monthly: rows',         e.months::numeric,        (SELECT COUNT(*) FROM metrics.dl_business_monthly)::numeric),
    ('dl_business_monthly: duplicate keys', 0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT month) FROM metrics.dl_business_monthly)::numeric),
    ('dl_retention: rows',                rr.n::numeric,            (SELECT COUNT(*) FROM metrics.dl_retention)::numeric),
    ('dl_retention: duplicate keys',      0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT (cohort_week, week_n)) FROM metrics.dl_retention)::numeric),
    ('dl_cohort_sensitivity: rows',       16::numeric,              (SELECT COUNT(*) FROM metrics.dl_cohort_sensitivity)::numeric),
    ('dl_cohort_sensitivity: duplicate keys', 0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT (cohort_week, scenario, week_n)) FROM metrics.dl_cohort_sensitivity)::numeric),
    ('dl_repeat_30d: rows',               ec.n::numeric,            (SELECT COUNT(*) FROM metrics.dl_repeat_30d)::numeric),
    ('dl_repeat_30d: duplicate keys',     0::numeric,
        (SELECT COUNT(*) - COUNT(DISTINCT cohort_week) FROM metrics.dl_repeat_30d)::numeric),
    ('dl_kpi_total: rows',                1::numeric,               (SELECT COUNT(*) FROM metrics.dl_kpi_total)::numeric),
    -- в таблицах со сценариями нет денег (правило 2): колонок gmv/orders/aov нет
    ('scenario tables: money columns',    0::numeric,
        (SELECT COUNT(*) FROM information_schema.columns
          WHERE table_schema = 'metrics'
            AND table_name IN ('dl_funnel_monthly', 'dl_activity_monthly', 'dl_cohort_sensitivity')
            AND column_name IN ('gmv', 'orders', 'purchases', 'aov', 'arppu', 'buyers'))::numeric)
) AS x(check_name, expected, actual);


-- =============================================================================
-- 11. Контрольные числа реальных данных (регрессия к записанным результатам)
--     Ожидаемые значения взяты из результатов, уже полученных на реальных данных
--     (sql/09-12, docs/metrics.md, раздел 7, проектная память). Запускать ТОЛЬКО
--     на реальной БД cosmetics_shop: на других данных строки будут FAIL.
--     Если после пересчёта витрин числа законно изменились, сначала обновить
--     docs/metrics.md, потом ожидаемые значения здесь.
-- =============================================================================
WITH k AS (SELECT * FROM metrics.dl_kpi_total),
fm AS (
    SELECT
        MAX(CASE WHEN scenario = 'as is'             THEN view_to_cart_pct      END) AS a_v2c,
        MAX(CASE WHEN scenario = 'as is'             THEN cart_to_purchase_pct  END) AS a_c2p,
        MAX(CASE WHEN scenario = 'as is'             THEN conversion_pct        END) AS a_conv,
        MAX(CASE WHEN scenario = 'as is'             THEN cart_remove_pct       END) AS a_rem,
        MAX(CASE WHEN scenario = 'as is'             THEN abandonment_pct       END) AS a_aband,
        MAX(CASE WHEN scenario = 'as is'             THEN session_conversion_pct END) AS a_sconv,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN view_to_cart_pct      END) AS x_v2c,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN cart_to_purchase_pct  END) AS x_c2p,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN conversion_pct        END) AS x_conv,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN cart_remove_pct       END) AS x_rem,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN abandonment_pct       END) AS x_aband,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN session_conversion_pct END) AS x_sconv
    FROM metrics.dl_funnel_monthly
    WHERE month = DATE '2019-10-01'
),
am AS (
    SELECT
        MAX(CASE WHEN scenario = 'as is'             THEN mau     END) AS a_mau,
        MAX(CASE WHEN scenario = 'as is'             THEN avg_dau END) AS a_dau,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN mau     END) AS x_mau,
        MAX(CASE WHEN scenario = 'excl. Oct 2, 6, 7' THEN avg_dau END) AS x_dau
    FROM metrics.dl_activity_monthly
    WHERE month = DATE '2019-10-01'
),
cs AS (
    SELECT
        MAX(CASE WHEN cohort_week = DATE '2019-09-30' AND scenario = 'as is'             THEN cohort_size END)    AS c1_a_size,
        MAX(CASE WHEN cohort_week = DATE '2019-09-30' AND scenario = 'as is'             AND week_n = 1 THEN retention_pct END) AS c1_a_w1,
        MAX(CASE WHEN cohort_week = DATE '2019-09-30' AND scenario = 'as is'             AND week_n = 4 THEN retention_pct END) AS c1_a_w4,
        MAX(CASE WHEN cohort_week = DATE '2019-09-30' AND scenario = 'excl. Oct 2, 6, 7' THEN cohort_size END)    AS c1_x_size,
        MAX(CASE WHEN cohort_week = DATE '2019-09-30' AND scenario = 'excl. Oct 2, 6, 7' AND week_n = 1 THEN retention_pct END) AS c1_x_w1,
        MAX(CASE WHEN cohort_week = DATE '2019-09-30' AND scenario = 'excl. Oct 2, 6, 7' AND week_n = 4 THEN retention_pct END) AS c1_x_w4,
        MAX(CASE WHEN cohort_week = DATE '2019-10-07' AND scenario = 'as is'             THEN cohort_size END)    AS c2_a_size,
        MAX(CASE WHEN cohort_week = DATE '2019-10-07' AND scenario = 'as is'             AND week_n = 1 THEN retention_pct END) AS c2_a_w1,
        MAX(CASE WHEN cohort_week = DATE '2019-10-07' AND scenario = 'as is'             AND week_n = 4 THEN retention_pct END) AS c2_a_w4,
        MAX(CASE WHEN cohort_week = DATE '2019-10-07' AND scenario = 'excl. Oct 2, 6, 7' THEN cohort_size END)    AS c2_x_size,
        MAX(CASE WHEN cohort_week = DATE '2019-10-07' AND scenario = 'excl. Oct 2, 6, 7' AND week_n = 1 THEN retention_pct END) AS c2_x_w1,
        MAX(CASE WHEN cohort_week = DATE '2019-10-07' AND scenario = 'excl. Oct 2, 6, 7' AND week_n = 4 THEN retention_pct END) AS c2_x_w4
    FROM metrics.dl_cohort_sensitivity
),
dd AS (
    SELECT
        MAX(new_users) FILTER (WHERE activity_date = DATE '2019-10-01') AS nu_1,
        MAX(new_users) FILTER (WHERE activity_date = DATE '2019-10-02') AS nu_2,
        MAX(new_users) FILTER (WHERE activity_date = DATE '2019-10-06') AS nu_6,
        MAX(new_users) FILTER (WHERE activity_date = DATE '2019-10-07') AS nu_7,
        MAX(new_users_baseline)                                         AS baseline
    FROM metrics.dl_activity_daily
)
SELECT
    x.check_name,
    x.expected,
    x.actual,
    -- допуск 0.5 только у медианы новых пользователей: в записанных результатах она
    -- приведена как целое (10 339), а медиана чётного числа дней может быть .5
    CASE WHEN ABS(x.expected - x.actual)
              <= CASE WHEN x.check_name LIKE 'new users baseline%' THEN 0.5 ELSE 0 END
         THEN 'OK' ELSE 'FAIL' END                              AS status
FROM k CROSS JOIN fm CROSS JOIN am CROSS JOIN cs CROSS JOIN dd
CROSS JOIN LATERAL (VALUES
    ('total users',                          1639358::numeric,     k.total_users::numeric),
    ('view users',                           1597754::numeric,     k.view_users::numeric),
    ('cart users (strict)',                  358026::numeric,      k.cart_users::numeric),
    ('purchase users (strict)',              104757::numeric,      k.purchase_users::numeric),
    ('view -> cart, %',                      22.41::numeric,       k.view_to_cart_pct),
    ('cart -> purchase, %',                  29.26::numeric,       k.cart_to_purchase_pct),
    ('conversion, %',                        6.56::numeric,        k.conversion_pct),
    ('buyers',                               110518::numeric,      k.buyers::numeric),
    ('orders',                               159382::numeric,      k.orders::numeric),
    ('GMV',                                  6348267.70::numeric,  k.gmv),
    ('AOV',                                  39.83::numeric,       k.aov),
    ('repeat 30d, stable cohorts, %',        11.53::numeric,       k.stable_repeat_30d_rate_pct),
    ('Oct as is: view -> cart, %',           31.74::numeric,       fm.a_v2c),
    ('Oct as is: cart -> purchase, %',       19.42::numeric,       fm.a_c2p),
    ('Oct as is: conversion, %',             6.16::numeric,        fm.a_conv),
    ('Oct as is: cart removals, %',          33.77::numeric,       fm.a_rem),
    ('Oct as is: abandonment, %',            89.23::numeric,       fm.a_aband),
    ('Oct as is: session conversion, %',     2.53::numeric,        fm.a_sconv),
    ('Oct excl: view -> cart, %',            23.76::numeric,       fm.x_v2c),
    ('Oct excl: cart -> purchase, %',        28.49::numeric,       fm.x_c2p),
    ('Oct excl: conversion, %',              6.77::numeric,        fm.x_conv),
    ('Oct excl: cart removals, %',           48.56::numeric,       fm.x_rem),
    ('Oct excl: abandonment, %',             86.99::numeric,       fm.x_aband),
    ('Oct excl: session conversion, %',      2.62::numeric,        fm.x_sconv),
    ('Oct as is: MAU',                       399664::numeric,      am.a_mau::numeric),
    ('Oct as is: avg DAU',                   17952.9::numeric,     am.a_dau),
    ('Oct excl: MAU',                        329449::numeric,      am.x_mau::numeric),
    ('Oct excl: avg DAU',                    16600.5::numeric,     am.x_dau),
    ('new users 1 Oct',                      19230::numeric,       dd.nu_1::numeric),
    ('new users 2 Oct',                      31739::numeric,       dd.nu_2::numeric),
    ('new users 6 Oct',                      27849::numeric,       dd.nu_6::numeric),
    ('new users 7 Oct',                      21818::numeric,       dd.nu_7::numeric),
    ('new users baseline (median from 18 Nov)', 10339.0::numeric,  dd.baseline),
    ('cohort 30 Sep as is: size',            115609::numeric,      cs.c1_a_size::numeric),
    ('cohort 30 Sep as is: week 1, %',       11.21::numeric,       cs.c1_a_w1),
    ('cohort 30 Sep as is: week 4, %',       6.16::numeric,        cs.c1_a_w4),
    ('cohort 30 Sep excl: size',             58373::numeric,       cs.c1_x_size::numeric),
    ('cohort 30 Sep excl: week 1, %',        13.95::numeric,       cs.c1_x_w1),
    ('cohort 30 Sep excl: week 4, %',        9.35::numeric,        cs.c1_x_w4),
    ('cohort 7 Oct as is: size',             94486::numeric,       cs.c2_a_size::numeric),
    ('cohort 7 Oct as is: week 1, %',        9.89::numeric,        cs.c2_a_w1),
    ('cohort 7 Oct as is: week 4, %',        5.36::numeric,        cs.c2_a_w4),
    ('cohort 7 Oct excl: size',              77901::numeric,       cs.c2_x_size::numeric),
    ('cohort 7 Oct excl: week 1, %',         12.37::numeric,       cs.c2_x_w1),
    ('cohort 7 Oct excl: week 4, %',         6.73::numeric,        cs.c2_x_w4)
) AS x(check_name, expected, actual);


-- =============================================================================
-- 12. Что экспортировать в CSV и как
--     Итоговый список файлов (9 таблиц, лимит DataLens: 10 файлов в одном
--     подключении, каждый лист Excel считается файлом; CSV и TXT поддерживаются):
--       dashboards/data/dl_funnel_monthly.csv       <- metrics.dl_funnel_monthly
--       dashboards/data/dl_activity_daily.csv       <- metrics.dl_activity_daily
--       dashboards/data/dl_activity_monthly.csv     <- metrics.dl_activity_monthly
--       dashboards/data/dl_weekly.csv               <- metrics.dl_weekly
--       dashboards/data/dl_business_monthly.csv     <- metrics.dl_business_monthly
--       dashboards/data/dl_retention.csv            <- metrics.dl_retention
--       dashboards/data/dl_cohort_sensitivity.csv   <- metrics.dl_cohort_sensitivity
--       dashboards/data/dl_repeat_30d.csv           <- metrics.dl_repeat_30d
--       dashboards/data/dl_kpi_total.csv            <- metrics.dl_kpi_total
--     Как в DBeaver: ПКМ на таблице -> Export Data -> CSV. Настройки:
--       * Delimiter: , (запятая); Header: top; Quote character: "; Quote always:
--         disabled; NULL string: пустая строка; Encoding: UTF-8, Insert BOM: off;
--       * Formatting: не форматировать числа и даты (иначе десятичный разделитель
--         и формат дат зависят от локали: нужна точка и ISO-даты YYYY-MM-DD);
--       * имя файла = имя таблицы (шаблон ${table}).
--     После экспорта сравнить число строк в каждом CSV с запросом ниже.
-- =============================================================================
SELECT t.table_name, t.rows_expected
FROM (
    SELECT 'dl_funnel_monthly'      AS table_name, COUNT(*) AS rows_expected FROM metrics.dl_funnel_monthly
    UNION ALL SELECT 'dl_activity_daily',     COUNT(*) FROM metrics.dl_activity_daily
    UNION ALL SELECT 'dl_activity_monthly',   COUNT(*) FROM metrics.dl_activity_monthly
    UNION ALL SELECT 'dl_weekly',             COUNT(*) FROM metrics.dl_weekly
    UNION ALL SELECT 'dl_business_monthly',   COUNT(*) FROM metrics.dl_business_monthly
    UNION ALL SELECT 'dl_retention',          COUNT(*) FROM metrics.dl_retention
    UNION ALL SELECT 'dl_cohort_sensitivity', COUNT(*) FROM metrics.dl_cohort_sensitivity
    UNION ALL SELECT 'dl_repeat_30d',         COUNT(*) FROM metrics.dl_repeat_30d
    UNION ALL SELECT 'dl_kpi_total',          COUNT(*) FROM metrics.dl_kpi_total
) t
ORDER BY t.table_name;
