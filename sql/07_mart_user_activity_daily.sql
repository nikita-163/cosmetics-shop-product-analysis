-- =============================================================================
-- 07_mart_user_activity_daily.sql
-- Витрина mart.user_activity_daily, построенная из stg.events (очищенные события).
--
-- Правила:
--   * День считается в UTC: (event_time AT TIME ZONE 'UTC')::date. Без явного
--     AT TIME ZONE день зависел бы от часового пояса сессии клиента (DBeaver
--     показал бы +03:00), и граница суток сдвинулась бы на 3 часа.
--   * Дубли не исключаются: повторная копия строки не меняет факт активности
--     пользователя в этот день (у дубля всегда есть оригинал).
--   * Строки с user_session IS NULL учитываются: пользователь всё равно был
--     активен, а user_id у них заполнен (NOT NULL в stg.events).
--   * Флаги означают «в этот день у пользователя было хотя бы одно событие типа».
--     has_purchase включает покупки с ценой NULL: поведение, а не деньги.
--     Деньги (GMV, AOV) здесь не считаются, они берутся из mart.sessions.
--   * Неделя, месяц, когорта выводятся из activity_date при расчёте метрик:
--     date_trunc('week', activity_date::timestamp) (неделя с понедельника), date_trunc('month', ...).
--     Первая неделя данных (с 1 окт 2019, вторник) и последняя (по 29 фев 2020,
--     суббота) неполные: при расчёте недельных метрик это нужно учитывать.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- mart.user_activity_daily: одна строка на пользователя и дату.
--
--    Зерно: (user_id, activity_date)
--
--    Применение:
--        Витрина показывает активность пользователей во времени:
--          1. DAU / WAU / MAU / stickiness: уникальные активные пользователи за период;
--          2. воронка и доля удалений из корзины по месяцам;
--          3. недельные когорты, retention и purchase retention.
--        mart.sessions на это не отвечает: сессия может пересекать границу суток, а
--        события с user_session IS NULL в неё не попадают. Здесь они учитываются.
-- -----------------------------------------------------------------------------

DROP TABLE IF EXISTS mart.user_activity_daily;

CREATE TABLE mart.user_activity_daily AS
SELECT
    user_id,
    (event_time AT TIME ZONE 'UTC')::date               AS activity_date,   -- дата UTC
    BOOL_OR(event_type = 'view')                        AS has_view,
    BOOL_OR(event_type = 'cart')                        AS has_cart,
    BOOL_OR(event_type = 'remove_from_cart')            AS has_remove_from_cart,
    BOOL_OR(event_type = 'purchase')                    AS has_purchase
FROM stg.events
GROUP BY user_id, (event_time AT TIME ZONE 'UTC')::date;

-- Первичный ключ фиксирует зерно и сразу создаёт индекс (user_id, activity_date):
-- он ускоряет запросы по пользователю (когорты, retention, повторные покупки).
ALTER TABLE mart.user_activity_daily
    ADD PRIMARY KEY (user_id, activity_date);

-- Запросы DAU, WAU и MAU фильтруют и группируют по дате
-- без user_id в начале, и индекс с user_id первым им не помогает. Отдельный индекс
-- по дате занимает место и замедляет пересоздание таблицы, но для таблицы, которая
-- пересоздаётся редко и читается часто, это оправданно.
CREATE INDEX idx_user_activity_daily_date
    ON mart.user_activity_daily (activity_date);

COMMENT ON TABLE  mart.user_activity_daily IS
    'Одна строка на (user_id, день UTC). Источник: stg.events целиком, включая дубли и user_session IS NULL. Для DAU/WAU/MAU, воронки по месяцам, когорт и retention.';
COMMENT ON COLUMN mart.user_activity_daily.activity_date IS
    'Календарный день события в UTC.';
COMMENT ON COLUMN mart.user_activity_daily.has_purchase IS
    'В этот день было хотя бы одно событие purchase (включая покупки с ценой NULL и дубли). Не для денежных метрик.';

-- Без ANALYZE планировщик не знает распределения данных в новой таблице.
ANALYZE mart.user_activity_daily;
