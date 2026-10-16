-- =============================================================================
-- 03_create_stg_events.sql
-- Таблица stg.events: 
-- очищенные события из data/processed/events_clean.parquet.
-- =============================================================================
DROP TABLE IF EXISTS stg.events;

CREATE TABLE stg.events (
    event_time    timestamptz   NOT NULL,   -- "event_time" приведён к времени (UTC), поэтому timestamptz
    event_type    text          NOT NULL,
    product_id    bigint        NOT NULL,
    category_id   bigint        NOT NULL,
    category_code text,                     -- ~98% пропусков в данных, поэтому оставлены NULL
    brand         text,                     -- ~42% пропусков в данных, поэтому оставлены NULL
    price         numeric(10,2),            -- NULL там, где исходная цена была <= 0
    user_id       bigint        NOT NULL,
    user_session  text,                     
    source_file   text          NOT NULL,   -- файл-источник, для прослеживаемости
    is_duplicate  boolean       NOT NULL,   -- полные дубли не удалены, а помечены "is_duplicate", поэтому boolean NOT NULL

    CONSTRAINT chk_events_event_type
        CHECK (event_type IN ('view', 'cart', 'remove_from_cart', 'purchase')),
    CONSTRAINT chk_events_price_positive
        CHECK (price IS NULL OR price > 0)
);

COMMENT ON TABLE stg.events IS
    'Очищенные события интернет-магазина косметики (REES46), окт 2019 - фев 2020. Дубли помечены, не удалены.';

COMMENT ON COLUMN stg.events.event_time    IS 'Время события, UTC';
COMMENT ON COLUMN stg.events.event_type    IS 'view | cart | remove_from_cart | purchase';
COMMENT ON COLUMN stg.events.price         IS 'Цена в событии; NULL, если исходное значение <= 0. Валюта неизвестна';
COMMENT ON COLUMN stg.events.user_session  IS 'Идентификатор сессии из источника; у части строк отсутствует';
COMMENT ON COLUMN stg.events.is_duplicate  IS 'TRUE для повторных копий полностью совпадающих строк (первая копия = FALSE). Для выручки и AOV фильтровать is_duplicate = FALSE';

-- Проверка структуры:
SELECT ordinal_position, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'stg' AND table_name = 'events'
ORDER BY ordinal_position;
