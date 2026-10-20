-- =============================================================================
-- 05_mart_sessions.sql
-- Витрина mart.sessions, построенная из stg.events (очищенные события).
--
-- Правила витрины (решения по итогам EDA и обсуждения):
--   * Дубли (is_duplicate = true) не влияют на флаги и границы времени: у дубля
--     всегда есть оригинал (keep='first'). Влияют только на деньги и счётчики,
--     поэтому GMV и priced_purchases_cnt считаются без дублей.
--   * Цены NULL (бывшие цены <= 0) пропускаются в GMV; на флаги не влияют.
--   * Строки с user_session IS NULL (4 598 шт., 0,02%) в mart.sessions не
--     попадают. Их активность учитывается в mart.user_activity_daily.
--   * GMV = сумма price по событиям purchase без дублей и с ценой не NULL.
--     Возвратов и отмен в данных нет, поэтому это именно GMV, а не выручка.
--   * В данных нет order_id: purchase это покупка позиции, а не заказа.
--     Заказ = сессия хотя бы с одной покупкой без дубля и с ценой не NULL,
--     то есть строка витрины с priced_purchases_cnt > 0.
--   * Воронка и конверсия считаются по has_purchase (любая покупка), а заказы,
--     GMV и AOV по priced_purchases_cnt > 0. Сессии, где все покупки без цены,
--     попадают в конверсию, но не в заказы.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS mart;

-- -----------------------------------------------------------------------------
-- mart.sessions: одна строка на сессию пользователя
--
--    Зерно: (user_session, user_id). Проверка показала 272 сессии, у которых
--    встречается больше одного user_id, поэтому одного user_session для ключа
--    недостаточно. Такая сессия делится на строки по пользователям, события
--    не теряются и никому не приписываются произвольно.
--    Поэтому число строк витрины чуть больше числа уникальных user_session.
--
--    Применение:
--      1. Ступени воронки:
--          has_view -> has_cart -> has_purchase
--          has_remove_from_cart: боковая ветка (брошенные корзины); не следует
--          из has_cart: товар мог быть добавлен в другой сессии.
--
--      2. Бизнес-метрики по docs/metrics.md:
--           GMV                = SUM(gmv)
--           покупки с ценой    = SUM(priced_purchases_cnt)
--           заказы с ценой     = COUNT(*) FILTER (WHERE priced_purchases_cnt > 0)
--           AOV                = GMV / заказы с ценой
--
--      3. first_order_time: момент первой покупки с ценой в сессии. По нему
--         заказ и его GMV относятся к неделе или месяцу, и по нему считается
--         время до повторной покупки. session_start для этого не подходит:
--         сессия может начаться в одну неделю, а покупка случиться в следующую.
--         NULL у сессий без заказа (в том числе у сессий, где все покупки без цены).
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
    BOOL_OR(event_type = 'purchase')                    AS has_purchase,
    -- Фильтр тот же, что в определении заказа: без дублей и с ценой не NULL.
    MIN(event_time) FILTER (
        WHERE event_type = 'purchase' AND NOT is_duplicate AND price IS NOT NULL
    )                                                   AS first_order_time,  -- UTC
    -- SUM пропускает NULL; COALESCE нужен, чтобы у сессий без покупок было 0, а не NULL
    COALESCE(SUM(price) FILTER (
        WHERE event_type = 'purchase' AND NOT is_duplicate
    ), 0)                                               AS gmv,
    -- COUNT(price) считает только строки с ценой не NULL
    COUNT(price) FILTER (
        WHERE event_type = 'purchase' AND NOT is_duplicate
    )                                                   AS priced_purchases_cnt
FROM stg.events
WHERE user_session IS NOT NULL
GROUP BY user_session, user_id;

-- Первичный ключ фиксирует: если в витрине окажутся две строки с одной
-- парой (user_session, user_id), создание ключа упадёт с ошибкой.
ALTER TABLE mart.sessions 
    ADD PRIMARY KEY (user_session, user_id);

COMMENT ON TABLE  mart.sessions IS
    'Одна строка на (user_session, user_id). Источник: stg.events, без user_session IS NULL.';
COMMENT ON COLUMN mart.sessions.gmv IS
    'Сумма price по purchase без дублей и с ценой не NULL; 0 если покупок нет.';
COMMENT ON COLUMN mart.sessions.priced_purchases_cnt IS
    'Число purchase без дублей и с ценой не NULL (метрика "покупки с известной ценой"). Заказ с известной ценой = строка, где значение > 0. Не знаменатель AOV.';
COMMENT ON COLUMN mart.sessions.first_order_time IS
    'Время первого purchase без дубля и с ценой не NULL, UTC; NULL, если заказа нет. Для отнесения заказа к неделе/месяцу и времени до повторной покупки.';

-- Без ANALYZE планировщик не знает распределения данных в новой таблице.
ANALYZE mart.sessions;
