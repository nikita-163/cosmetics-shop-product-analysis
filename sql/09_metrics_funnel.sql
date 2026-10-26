-- =============================================================================
-- 09_metrics_funnel.sql
-- Воронка и конверсия (раздел 1 в docs/metrics.md):
--   1. Пользователи на шагах воронки, step conversion, conversion rate
--      (весь период и по месяцам)
--   2. Session conversion rate и abandonment rate (весь период и по месяцам)
--   3. Доля удалений из корзины (весь период и по месяцам)
--   4. Сверка с независимым источником (stg.events)
--   5. Чувствительность октября: воронка и сессионные метрики без аномальных дней
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
--     has_purchase, а не заказы из mart.orders (там только покупки без дублей и
--     с ценой, это деньги, а не поведение).
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
--    Считаются сессии, а не заказы: в одной сессии может быть несколько
--    заказов (см. 05_mart_sessions_orders.sql), а сессия с покупкой без цены
--    или с дублем тоже считается сессией с покупкой.
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
--    users_with_cart_and_remove / users_with_cart, где знаменатель только
--    пользователи с cart. Это не шаг воронки: users_with_cart здесь все
--    пользователи с cart, а в блоках 1.1 и 1.2 cart_users это пользователи с
--    view и cart (строгая воронка), поэтому числа различаются.
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
        COUNT(*) FILTER (WHERE has_cart)                        AS users_with_cart,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS users_with_cart_and_remove
    FROM user_month
    GROUP BY month
),
whole AS (
    SELECT
        'all'                                                   AS period,
        COUNT(*) FILTER (WHERE has_cart)                        AS users_with_cart,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS users_with_cart_and_remove
    FROM mart.users
)
SELECT
    period,
    users_with_cart,
    users_with_cart_and_remove,
    ROUND(100.0 * users_with_cart_and_remove / NULLIF(users_with_cart, 0), 2) AS cart_remove_pct
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
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('view users',     s.v, m.v),
    ('cart users',     s.c, m.c),
    ('purchase users', s.p, m.p)
) AS x(check_name, expected, actual);


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
    x.expected,
    x.actual,
    CASE WHEN x.expected = x.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM from_mart m
CROSS JOIN from_stg s
CROSS JOIN LATERAL (VALUES
    ('view sessions',          s.view_s,        m.view_s),
    ('converted sessions',     s.conv_s,        m.conv_s),
    ('cart sessions',          s.cart_s,        m.cart_s),
    ('cart+purchase sessions', s.cart_purchase_s, m.cart_purchase_s)
) AS x(check_name, expected, actual);


-- 4.3. Воронка по месяцам: mart.user_activity_daily против stg.events
--      expected = stg.events, actual = витрина. День и месяц в UTC в обоих
--      источниках. FULL JOIN покажет и месяц,
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
    s.view_users      AS expected_view,      d.view_users      AS actual_view,
    s.cart_users      AS expected_cart,      d.cart_users      AS actual_cart,
    s.purchase_users  AS expected_purchase,  d.purchase_users  AS actual_purchase,
    CASE WHEN (d.view_users, d.cart_users, d.purchase_users)
              IS NOT DISTINCT FROM (s.view_users, s.cart_users, s.purchase_users)
         THEN 'OK' ELSE 'FAIL' END              AS status
FROM from_daily d
FULL JOIN from_stg s ON s.month = d.month
ORDER BY month;


-- 4.4. Сессионные метрики по месяцам: mart.sessions против stg.events
--      Месяц сессии = месяц её первого события (session_start), в stg считается
--      заново как MIN(event_time) по паре (user_session, user_id).
WITH from_mart AS (
    SELECT
        date_trunc('month', session_start AT TIME ZONE 'UTC')::date     AS month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_s,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS conv_s,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_s,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_s
    FROM mart.sessions
    GROUP BY 1
),
from_stg AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_s,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS conv_s,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_s,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_s
    FROM (
        SELECT
            date_trunc('month', MIN(event_time) AT TIME ZONE 'UTC')::date AS month,
            BOOL_OR(event_type = 'view')        AS has_view,
            BOOL_OR(event_type = 'cart')        AS has_cart,
            BOOL_OR(event_type = 'purchase')    AS has_purchase
        FROM stg.events
        WHERE user_session IS NOT NULL
        GROUP BY user_session, user_id
    ) s
    GROUP BY month
)
SELECT
    COALESCE(s.month, m.month)                  AS month,
    s.view_s          AS expected_view_s,       m.view_s          AS actual_view_s,
    s.conv_s          AS expected_conv_s,       m.conv_s          AS actual_conv_s,
    s.cart_s          AS expected_cart_s,       m.cart_s          AS actual_cart_s,
    s.cart_purchase_s AS expected_cart_purch_s, m.cart_purchase_s AS actual_cart_purch_s,
    CASE WHEN (s.view_s, s.conv_s, s.cart_s, s.cart_purchase_s)
              IS NOT DISTINCT FROM (m.view_s, m.conv_s, m.cart_s, m.cart_purchase_s)
         THEN 'OK' ELSE 'FAIL' END              AS status
FROM from_stg s
FULL JOIN from_mart m ON m.month = s.month
ORDER BY 1;


-- 4.5. Доля удалений из корзины (блок 3): по месяцам и за весь период,
--      витрины против stg.events. Пользователи с cart и с cart + remove_from_cart.
WITH m_month AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_cart)                          AS cart_u,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS remove_u
    FROM (
        SELECT
            user_id,
            date_trunc('month', activity_date::timestamp)::date   AS month,
            BOOL_OR(has_cart)                                     AS has_cart,
            BOOL_OR(has_remove_from_cart)                         AS has_remove_from_cart
        FROM mart.user_activity_daily
        GROUP BY user_id, month
    ) t
    GROUP BY month
),
s_month AS (
    SELECT
        month,
        COUNT(*) FILTER (WHERE has_cart)                          AS cart_u,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS remove_u
    FROM (
        SELECT
            user_id,
            date_trunc('month', event_time AT TIME ZONE 'UTC')::date AS month,
            BOOL_OR(event_type = 'cart')                             AS has_cart,
            BOOL_OR(event_type = 'remove_from_cart')                 AS has_remove_from_cart
        FROM stg.events
        GROUP BY user_id, month
    ) t
    GROUP BY month
),
m_all AS (
    SELECT
        COUNT(*) FILTER (WHERE has_cart)                          AS cart_u,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS remove_u
    FROM mart.users
),
s_all AS (
    SELECT
        COUNT(*) FILTER (WHERE has_cart)                          AS cart_u,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart) AS remove_u
    FROM (
        SELECT
            user_id,
            BOOL_OR(event_type = 'cart')                          AS has_cart,
            BOOL_OR(event_type = 'remove_from_cart')              AS has_remove_from_cart
        FROM stg.events
        GROUP BY user_id
    ) t
)
SELECT *
FROM (
    SELECT
        COALESCE(s.month::text, m.month::text)  AS period,
        s.cart_u   AS expected_users_with_cart,   m.cart_u   AS actual_users_with_cart,
        s.remove_u AS expected_with_remove,       m.remove_u AS actual_with_remove,
        CASE WHEN (s.cart_u, s.remove_u) IS NOT DISTINCT FROM (m.cart_u, m.remove_u)
             THEN 'OK' ELSE 'FAIL' END          AS status
    FROM s_month s
    FULL JOIN m_month m ON m.month = s.month
    UNION ALL
    SELECT
        'all',
        s.cart_u, m.cart_u,
        s.remove_u, m.remove_u,
        CASE WHEN (s.cart_u, s.remove_u) IS NOT DISTINCT FROM (m.cart_u, m.remove_u)
             THEN 'OK' ELSE 'FAIL' END
    FROM s_all s
    CROSS JOIN m_all m
) t
ORDER BY period = 'all', period;



-- =============================================================================
-- 5. Чувствительность октября: воронка без аномальных дней
--    Данные октября нетипичны: 2, 6 и 7 октября приходит аномально много новых
--    пользователей с view и cart, но без покупок (диагностика в блоке 6 файла
--    10_metrics_activity.sql, описание в docs/metrics.md, раздел 6, п. 11).
--    Дни не удаляются, а считаются варианты и сравниваются с «как есть» и с
--    ноябрём-февралём:
--      * excl. Oct 2, 6, 7         : три дня с явным всплеском новых пользователей;
--      * excl. Oct 1, 2, 6, 7, 8   : плюс 1 и 8 октября, где конверсия view -> cart
--                                    тоже повышена, но причина может быть другой
--                                    (1 октября это первый день данных, а 8 октября
--                                    хвост эффекта вернувшихся старых клиентов);
--      * placebo: excl. Oct 9-13   : пять обычных дней, ближайших к аномальным.
--                                    Контроль: дни 1 и 8 октября выбраны по повышенной
--                                    конверсии, поэтому часть сдвига после их исключения
--                                    получается по построению. Если placebo сдвигает
--                                    метрики заметно меньше, сдвиг даёт именно
--                                    исключение аномальных дней, а не сокращение выборки.
--    Исключаются дни по дате события (для сессий по дате session_start), а не
--    пользователи по их исходу: иначе конверсия смещалась бы искусственно.
--    Список дней задан в блоке scenarios каждого запроса: при изменении поправить
--    во всех запросах блока 5 (5.1-5.4).
--    Ноябрь-февраль показан «как есть»: эти месяцы уже сверены в блоках 2, 3, 4.
--    Чтение: если октябрь без аномальных дней заметно ближе к ноябрю-февралю, то
--    разница октября объясняется этими днями; если нет, в данных октября есть
--    другая причина, и месяц остаётся с оговоркой.
-- =============================================================================

-- 5.1. Воронка по пользователям и доля удалений из корзины: октябрь по вариантам,
--      ноябрь-февраль как есть. Определения те же, что в блоках 1.2 и 3:
--        cart_users, purchase_users : строгая воронка (view -> cart -> purchase);
--        users_with_cart            : все пользователи с cart (знаменатель доли
--                                     удалений, не шаг воронки).
--      Пользователь считается за месяц по оставшимся дням. Строка октября
--      «as is» должна совпасть с октябрём в блоках 1.2 и 3 (самопроверка).
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
        'as is', 1,
        date_trunc('month', activity_date::timestamp)::date,
        user_id, has_view, has_cart, has_remove_from_cart, has_purchase
    FROM mart.user_activity_daily
    WHERE activity_date >= DATE '2019-11-01'
),
user_month AS (
    SELECT
        scenario, sort_order, month, user_id,
        BOOL_OR(has_view)               AS has_view,
        BOOL_OR(has_cart)               AS has_cart,
        BOOL_OR(has_remove_from_cart)   AS has_remove_from_cart,
        BOOL_OR(has_purchase)           AS has_purchase
    FROM user_day
    GROUP BY scenario, sort_order, month, user_id
),
counts AS (
    SELECT
        scenario, sort_order, month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_users,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_users,
        COUNT(*) FILTER (WHERE has_cart)                                AS users_with_cart,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart)       AS users_with_cart_and_remove
    FROM user_month
    GROUP BY scenario, sort_order, month
)
SELECT
    month,
    scenario,
    view_users,
    cart_users,
    purchase_users,
    ROUND(100.0 * cart_users     / NULLIF(view_users, 0), 2)            AS view_to_cart_pct,
    ROUND(100.0 * purchase_users / NULLIF(cart_users, 0), 2)            AS cart_to_purchase_pct,
    ROUND(100.0 * purchase_users / NULLIF(view_users, 0), 2)            AS conversion_pct,
    ROUND(100.0 * users_with_cart_and_remove / NULLIF(users_with_cart, 0), 2) AS cart_remove_pct
FROM counts
ORDER BY month, sort_order;


-- 5.2. Session conversion и abandonment: октябрь по вариантам, ноябрь-февраль как
--      есть. Определения как в блоке 2. Сессия относится ко дню начала
--      (session_start, UTC): сессия, начатая в исключённый день, исключается целиком.
--      Строка октября «as is» должна совпасть с октябрём в блоке 2 (самопроверка).
WITH scenarios (scenario, sort_order, excluded_days) AS (
    VALUES
        ('as is',                  1, ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7',      2, ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07']),
        ('excl. Oct 1, 2, 6, 7, 8', 3, ARRAY[DATE '2019-10-01', DATE '2019-10-02', DATE '2019-10-06',
                                              DATE '2019-10-07', DATE '2019-10-08']),
        ('placebo: excl. Oct 9-13', 4, ARRAY[DATE '2019-10-09', DATE '2019-10-10', DATE '2019-10-11',
                                              DATE '2019-10-12', DATE '2019-10-13'])
),
sess AS (
    SELECT
        sc.scenario,
        sc.sort_order,
        date_trunc('month', s.session_start AT TIME ZONE 'UTC')::date   AS month,
        s.has_view, s.has_cart, s.has_purchase
    FROM mart.sessions s
    JOIN scenarios sc
      ON NOT ((s.session_start AT TIME ZONE 'UTC')::date = ANY (sc.excluded_days))
    WHERE (s.session_start AT TIME ZONE 'UTC')::date < DATE '2019-11-01'
    UNION ALL
    SELECT
        'as is', 1,
        date_trunc('month', session_start AT TIME ZONE 'UTC')::date,
        has_view, has_cart, has_purchase
    FROM mart.sessions
    WHERE (session_start AT TIME ZONE 'UTC')::date >= DATE '2019-11-01'
),
counts AS (
    SELECT
        scenario, sort_order, month,
        COUNT(*) FILTER (WHERE has_view)                                AS view_sessions,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS converted_sessions,
        COUNT(*) FILTER (WHERE has_cart)                                AS cart_sessions,
        COUNT(*) FILTER (WHERE has_cart AND has_purchase)               AS cart_purchase_sessions
    FROM sess
    GROUP BY scenario, sort_order, month
)
SELECT
    month,
    scenario,
    view_sessions,
    converted_sessions,
    ROUND(100.0 * converted_sessions / NULLIF(view_sessions, 0), 2)     AS session_conversion_pct,
    cart_sessions,
    cart_purchase_sessions,
    ROUND(100.0 - 100.0 * cart_purchase_sessions / NULLIF(cart_sessions, 0), 2) AS abandonment_pct
FROM counts
ORDER BY month, sort_order;


-- 5.3. Сверка 5.1 за октябрь (все три варианта): mart.user_activity_daily против
--      stg.events. В stg флаги «пользователь-день» считаются заново.
--      Ноябрь-февраль здесь не сверяются: «как есть» они уже сверены в 4.3 и 4.5.
WITH scenarios (scenario, sort_order, excluded_days) AS (
    VALUES
        ('as is',                  1, ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7',      2, ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07']),
        ('excl. Oct 1, 2, 6, 7, 8', 3, ARRAY[DATE '2019-10-01', DATE '2019-10-02', DATE '2019-10-06',
                                              DATE '2019-10-07', DATE '2019-10-08']),
        ('placebo: excl. Oct 9-13', 4, ARRAY[DATE '2019-10-09', DATE '2019-10-10', DATE '2019-10-11',
                                              DATE '2019-10-12', DATE '2019-10-13'])
),
m AS (
    SELECT
        scenario,
        COUNT(*) FILTER (WHERE has_view)                                AS view_u,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_u,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_u,
        COUNT(*) FILTER (WHERE has_cart)                                AS with_cart_u,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart)       AS with_remove_u
    FROM (
        SELECT
            sc.scenario, d.user_id,
            BOOL_OR(d.has_view)             AS has_view,
            BOOL_OR(d.has_cart)             AS has_cart,
            BOOL_OR(d.has_remove_from_cart) AS has_remove_from_cart,
            BOOL_OR(d.has_purchase)         AS has_purchase
        FROM mart.user_activity_daily d
        JOIN scenarios sc ON NOT (d.activity_date = ANY (sc.excluded_days))
        WHERE d.activity_date < DATE '2019-11-01'
        GROUP BY sc.scenario, d.user_id
    ) t
    GROUP BY scenario
),
s AS (
    SELECT
        scenario,
        COUNT(*) FILTER (WHERE has_view)                                AS view_u,
        COUNT(*) FILTER (WHERE has_view AND has_cart)                   AS cart_u,
        COUNT(*) FILTER (WHERE has_view AND has_cart AND has_purchase)  AS purchase_u,
        COUNT(*) FILTER (WHERE has_cart)                                AS with_cart_u,
        COUNT(*) FILTER (WHERE has_cart AND has_remove_from_cart)       AS with_remove_u
    FROM (
        SELECT
            sc.scenario, e.user_id,
            BOOL_OR(e.event_type = 'view')              AS has_view,
            BOOL_OR(e.event_type = 'cart')              AS has_cart,
            BOOL_OR(e.event_type = 'remove_from_cart')  AS has_remove_from_cart,
            BOOL_OR(e.event_type = 'purchase')          AS has_purchase
        FROM stg.events e
        JOIN scenarios sc
          ON NOT ((e.event_time AT TIME ZONE 'UTC')::date = ANY (sc.excluded_days))
        WHERE (e.event_time AT TIME ZONE 'UTC')::date < DATE '2019-11-01'
        GROUP BY sc.scenario, e.user_id
    ) t
    GROUP BY scenario
)
SELECT
    COALESCE(s.scenario, m.scenario)            AS scenario,
    s.view_u      AS expected_view_u,       m.view_u      AS actual_view_u,
    s.cart_u      AS expected_cart_u,       m.cart_u      AS actual_cart_u,
    s.purchase_u  AS expected_purchase_u,   m.purchase_u  AS actual_purchase_u,
    s.with_cart_u AS expected_with_cart_u,  m.with_cart_u AS actual_with_cart_u,
    s.with_remove_u AS expected_with_remove_u, m.with_remove_u AS actual_with_remove_u,
    CASE WHEN (s.view_u, s.cart_u, s.purchase_u, s.with_cart_u, s.with_remove_u)
              IS NOT DISTINCT FROM (m.view_u, m.cart_u, m.purchase_u, m.with_cart_u, m.with_remove_u)
         THEN 'OK' ELSE 'FAIL' END              AS status
FROM s
FULL JOIN m ON m.scenario = s.scenario
ORDER BY 1;


-- 5.4. Сверка 5.2 за октябрь (все три варианта): mart.sessions против stg.events.
--      День сессии в stg считается заново как день MIN(event_time) пары
--      (user_session, user_id).
WITH scenarios (scenario, sort_order, excluded_days) AS (
    VALUES
        ('as is',                  1, ARRAY[]::date[]),
        ('excl. Oct 2, 6, 7',      2, ARRAY[DATE '2019-10-02', DATE '2019-10-06', DATE '2019-10-07']),
        ('excl. Oct 1, 2, 6, 7, 8', 3, ARRAY[DATE '2019-10-01', DATE '2019-10-02', DATE '2019-10-06',
                                              DATE '2019-10-07', DATE '2019-10-08']),
        ('placebo: excl. Oct 9-13', 4, ARRAY[DATE '2019-10-09', DATE '2019-10-10', DATE '2019-10-11',
                                              DATE '2019-10-12', DATE '2019-10-13'])
),
m AS (
    SELECT
        sc.scenario,
        COUNT(*) FILTER (WHERE x.has_view)                                  AS view_s,
        COUNT(*) FILTER (WHERE x.has_view AND x.has_cart AND x.has_purchase) AS conv_s,
        COUNT(*) FILTER (WHERE x.has_cart)                                  AS cart_s,
        COUNT(*) FILTER (WHERE x.has_cart AND x.has_purchase)               AS cart_purchase_s
    FROM (
        SELECT (session_start AT TIME ZONE 'UTC')::date AS day,
               has_view, has_cart, has_purchase
        FROM mart.sessions
    ) x
    JOIN scenarios sc ON NOT (x.day = ANY (sc.excluded_days))
    WHERE x.day < DATE '2019-11-01'
    GROUP BY sc.scenario
),
s AS (
    SELECT
        sc.scenario,
        COUNT(*) FILTER (WHERE x.has_view)                                  AS view_s,
        COUNT(*) FILTER (WHERE x.has_view AND x.has_cart AND x.has_purchase) AS conv_s,
        COUNT(*) FILTER (WHERE x.has_cart)                                  AS cart_s,
        COUNT(*) FILTER (WHERE x.has_cart AND x.has_purchase)               AS cart_purchase_s
    FROM (
        SELECT
            (MIN(event_time) AT TIME ZONE 'UTC')::date  AS day,
            BOOL_OR(event_type = 'view')                AS has_view,
            BOOL_OR(event_type = 'cart')                AS has_cart,
            BOOL_OR(event_type = 'purchase')            AS has_purchase
        FROM stg.events
        WHERE user_session IS NOT NULL
        GROUP BY user_session, user_id
    ) x
    JOIN scenarios sc ON NOT (x.day = ANY (sc.excluded_days))
    WHERE x.day < DATE '2019-11-01'
    GROUP BY sc.scenario
)
SELECT
    COALESCE(s.scenario, m.scenario)            AS scenario,
    s.view_s          AS expected_view_s,       m.view_s          AS actual_view_s,
    s.conv_s          AS expected_conv_s,       m.conv_s          AS actual_conv_s,
    s.cart_s          AS expected_cart_s,       m.cart_s          AS actual_cart_s,
    s.cart_purchase_s AS expected_cart_purch_s, m.cart_purchase_s AS actual_cart_purch_s,
    CASE WHEN (s.view_s, s.conv_s, s.cart_s, s.cart_purchase_s)
              IS NOT DISTINCT FROM (m.view_s, m.conv_s, m.cart_s, m.cart_purchase_s)
         THEN 'OK' ELSE 'FAIL' END              AS status
FROM s
FULL JOIN m ON m.scenario = s.scenario
ORDER BY 1;
