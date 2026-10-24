-- =============================================================================
-- 05_mart_sessions_orders.sql
-- Витрины mart.sessions и mart.orders, построенные из stg.events (очищенные события).
--
-- Разделение ролей:
--   * mart.sessions: поведение внутри сессии (воронка, конверсия сессий,
--     брошенные корзины). Деньги и заказы здесь не хранятся.
--   * mart.orders: заказы и деньги (GMV, AOV, повторные покупки, время до
--     повторной покупки). Один источник для денег, чтобы заказы и GMV нельзя было
--     отнести к периоду по разным временам.
--
-- Правила витрин (решения по итогам EDA и обсуждения):
--   * Дубли (is_duplicate = true) не влияют на флаги и границы времени: у дубля
--     всегда есть оригинал (keep='first'). Влияют только на деньги, поэтому
--     mart.orders считается без дублей.
--   * Цены NULL (бывшие цены <= 0) пропускаются в mart.orders; на флаги
--     mart.sessions не влияют.
--   * Строки с user_session IS NULL (4 598 шт., 0,02%) в витрины не попадают. Их
--     активность учитывается в mart.user_activity_daily. Покупок без user_session
--     в данных нет, поэтому деньги не теряются (проверяет 06).
--   * GMV = сумма price по событиям purchase без дублей и с ценой не NULL.
--     Возвратов и отмен в данных нет, поэтому это именно GMV, а не выручка.
--   * В данных нет order_id: purchase это покупка позиции, а не заказа.
--     Заказ = (user_session, user_id, момент покупки), то есть все позиции пары
--     с одинаковым event_time (с точностью до секунды). Основание (диагностика
--     2026-10-24): в 98,3% пар (user_session, user_id) с покупкой все позиции
--     записаны в одну секунду, а между разными моментами одной пары интервал не
--     больше минуты только в 6% случаев (медиана около часа). Значит, разные
--     моменты это отдельные оформления, а не разброс записи одной корзины.
--     Идентификатор user_session у части пользователей живёт неделями, поэтому
--     «заказ = сессия» занижал число заказов (155 617 против 159 382).
--   * Воронка и конверсия считаются по has_purchase (любая покупка), а заказы,
--     GMV и AOV по mart.orders. Сессии, где все покупки без цены, попадают в
--     конверсию, но не в заказы.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS mart;

-- -----------------------------------------------------------------------------
-- 1. mart.sessions: одна строка на сессию пользователя
--
--    Зерно: (user_session, user_id). Проверка показала 272 сессии, у которых
--    встречается больше одного user_id, поэтому одного user_session для ключа
--    недостаточно. Такая сессия делится на строки по пользователям, события
--    не теряются и никому не приписываются произвольно.
--    Поэтому число строк витрины чуть больше числа уникальных user_session.
--
--    Применение:
--      Ступени воронки: has_view -> has_cart -> has_purchase.
--      has_remove_from_cart: боковая ветка (брошенные корзины); не следует
--      из has_cart: товар мог быть добавлен в другой сессии.
--      Период сессии определяется по session_start.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS mart.sessions;

CREATE TABLE mart.sessions AS
SELECT
    user_session,
    user_id,
    MIN(event_time)                                     AS session_start,   -- UTC
    MAX(event_time)                                     AS session_end,     -- UTC
    EXTRACT(EPOCH FROM MAX(event_time) - MIN(event_time))::integer
                                                        AS duration_sec,
    BOOL_OR(event_type = 'view')                        AS has_view,
    BOOL_OR(event_type = 'cart')                        AS has_cart,
    BOOL_OR(event_type = 'remove_from_cart')            AS has_remove_from_cart,
    BOOL_OR(event_type = 'purchase')                    AS has_purchase
FROM stg.events
WHERE user_session IS NOT NULL
GROUP BY user_session, user_id;

-- Первичный ключ фиксирует: если в витрине окажутся две строки с одной
-- парой (user_session, user_id), создание ключа упадёт с ошибкой.
ALTER TABLE mart.sessions
    ADD PRIMARY KEY (user_session, user_id);

COMMENT ON TABLE  mart.sessions IS
    'Одна строка на (user_session, user_id). Источник: stg.events, без user_session IS NULL. Деньги и заказы в mart.orders.';
COMMENT ON COLUMN mart.sessions.has_purchase IS
    'Была хотя бы одна покупка, в том числе дубль или покупка без цены. Для воронки. Для заказов и денег использовать mart.orders.';

-- Без ANALYZE планировщик не знает распределения данных в новой таблице.
ANALYZE mart.sessions;


-- -----------------------------------------------------------------------------
-- 2. mart.orders: одна строка на заказ
--
--    Зерно: (user_session, user_id, order_time).
--
--    Применение по docs/metrics.md:
--      GMV                  = SUM(gmv)
--      покупки с ценой      = SUM(items_cnt)
--      заказы с ценой       = COUNT(*)
--      AOV                  = GMV / заказы с ценой
--      период заказа и GMV  = order_time (UTC): у заказа одно время, поэтому GMV
--                             по периодам совпадает с расчётом из stg.events.
--      повторная покупка    = второй заказ пользователя (08_mart_users.sql).
--
--    Заказ из нескольких позиций с одним временем попадает в одну строку.
--    Два разных оформления в одну и ту же секунду в одной сессии слились бы в
--    один заказ; по данным это единичные случаи, в расчётах не учитываются.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS mart.orders;

CREATE TABLE mart.orders AS
SELECT
    user_session,
    user_id,
    event_time                  AS order_time,      -- UTC
    COUNT(*)                    AS items_cnt,       -- позиций в заказе (покупок с ценой)
    SUM(price)                  AS gmv
FROM stg.events
WHERE event_type = 'purchase'
    AND NOT is_duplicate
    AND price IS NOT NULL
    AND user_session IS NOT NULL
GROUP BY user_session, user_id, event_time;

ALTER TABLE mart.orders
    ADD PRIMARY KEY (user_session, user_id, order_time);

COMMENT ON TABLE  mart.orders IS
    'Одна строка на заказ: (user_session, user_id, order_time). Источник: stg.events, purchase без дублей и с ценой не NULL.';
COMMENT ON COLUMN mart.orders.order_time IS
    'Момент покупки (event_time позиций заказа), UTC. К этому времени относятся заказ и его GMV.';
COMMENT ON COLUMN mart.orders.items_cnt IS
    'Число покупок (позиций) в заказе; количество товара в данных не указано.';
COMMENT ON COLUMN mart.orders.gmv IS
    'Сумма price позиций заказа (без дублей и покупок с ценой NULL).';

-- Без ANALYZE планировщик не знает распределения данных в новой таблице.
ANALYZE mart.orders;
