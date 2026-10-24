-- =============================================================================
-- 04_stg_quality_check.sql
-- Сверка stg.events после загрузки (scripts/load_to_postgres.py) с результатами
-- 01_EDA.ipynb и 02_cleaning.ipynb.
--
-- В stg загружен очищенный датасет (events_clean.parquet из 02_cleaning).
-- Очистка не удаляет строки, поэтому большинство ожидаемых значений совпадает
-- с цифрами из 01_EDA и не меняется после очистки. Значения, которые появились
-- или изменились именно из-за очистки (price IS NULL, price <= 0, is_duplicate),
-- привязаны к 02_cleaning.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Общие счётчики, пропуски, цены, период (один проход по таблице)
--    Источники ожидаемых значений и почему они актуальны для очищенных данных.
-- -----------------------------------------------------------------------------
WITH s AS (
    SELECT
        COUNT(*)                                        AS total_rows,  
        COUNT(*) FILTER (WHERE is_duplicate)            AS dup_rows,    
        COUNT(*) FILTER (WHERE price IS NULL)           AS price_null,     
        COUNT(*) FILTER (WHERE brand IS NULL)           AS brand_null,  
        COUNT(*) FILTER (WHERE category_code IS NULL)   AS category_code_null,  
        COUNT(*) FILTER (WHERE user_session IS NULL)    AS user_session_null,   
        COUNT(*) FILTER (WHERE price <= 0)              AS price_nonpositive,   
        MAX(price)                                      AS max_price,   
        MIN(event_time AT TIME ZONE 'UTC')              AS min_time_utc,    
        MAX(event_time AT TIME ZONE 'UTC')              AS max_time_utc
    FROM stg.events
)
SELECT
    c.check_name,
    c.expected,
    c.actual,
    CASE WHEN c.expected = c.actual THEN 'OK' ELSE 'FAIL' END AS status
FROM s
CROSS JOIN LATERAL (VALUES
    ('rows total',                '20692840',            s.total_rows::text),   -- 02_cleaning, раздел 6 («строк: 20,692,840»).
    ('is_duplicate = true',       '1109098',             s.dup_rows::text),     -- 1 109 098 дублей в 01_EDA, раздел 4. 
    ('price IS NULL',             '104288',              s.price_null::text),   -- 104288 пропусков price в 02_cleaning, раздел 5.
    ('brand IS NULL',             '8757117',             s.brand_null::text),   -- 8757117 пропусков brand в 02_cleaning, раздел 5.
    ('category_code IS NULL',     '20339246',            s.category_code_null::text),   -- 20339246 пропусков category code в 02_cleaning, раздел 5.
    ('user_session IS NULL',      '4598',                s.user_session_null::text),    -- 4598 пропусков user session в 02_cleaning, раздел 5. 
    ('price <= 0',                '0',                   s.price_nonpositive::text),    -- 0 нелогичных цен после замены на NULL: assert df['price'].min() > 0 в 02_cleaning, раздел 5.
    ('max price',                 '327.78',              s.max_price::text),    -- Максимальная цена 327.78 в 01_EDA, раздел 5, df['price'].describe(), строка max (3.277800e+02).
    -- AT TIME ZONE 'UTC' нужен, чтобы DBeaver не показал время в часовом поясе клиента.
    ('min event_time (UTC)',      '2019-10-01 00:00:00', s.min_time_utc::text),     -- Начало периода в 02_cleaning, раздел 2.
    ('max event_time (UTC)',      '2020-02-29 23:59:59', s.max_time_utc::text)      -- Конец периода в 02_cleaning, раздел 2.
) AS c(check_name, expected, actual);


-- -----------------------------------------------------------------------------
-- 2. Разбивка по типам событий: строки и дубли
--    Строки по типам событий очисткой не меняются. Дубли по типам берём из 01:
--    флаг в 02_cleaning считается той же формулой, но разбивка там не печатается.
-- -----------------------------------------------------------------------------
WITH expected (event_type, expected_rows, expected_dups) AS (
    VALUES
        ('view',             9657821, 1031),        -- 9657821 строк (value_counts) и 1031 дубль в 01_EDA, раздел 4.
        ('cart',             5768333, 115342),      -- 5768333 строк (value_counts) и 115342 дубля в 01_EDA, раздел 4.
        ('remove_from_cart', 3979679, 991820),      -- 3979679 строк (value_counts) и 991820 дублей в 01_EDA, раздел 4.
        ('purchase',         1287007, 905)          -- 1287007 строк (value_counts) и 905 дублей в 01_EDA, раздел 4.
),
actual AS (
    SELECT
        event_type,
        COUNT(*)                             AS actual_rows,
        COUNT(*) FILTER (WHERE is_duplicate) AS actual_dups
    FROM stg.events
    GROUP BY event_type
)
SELECT
    COALESCE(e.event_type, a.event_type) AS event_type,
    e.expected_rows,
    a.actual_rows,
    e.expected_dups,
    a.actual_dups,
    CASE
        WHEN e.expected_rows = a.actual_rows
            AND e.expected_dups = a.actual_dups THEN 'OK'
        ELSE 'FAIL'
    END AS status
FROM expected e
FULL JOIN actual a ON a.event_type = e.event_type
ORDER BY e.expected_rows DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 3. Разбивка по файлам-источникам: число строк
--    Очистка строки не удаляет, поэтому по файлам ничего не меняется.
-- -----------------------------------------------------------------------------
WITH expected (source_file, expected_rows) AS (
    VALUES
        ('2019-Oct.csv', 4102283),    -- 4102283 строк в 01_EDA, разделы 1 и 6; в 02_cleaning, раздел 1.
        ('2019-Nov.csv', 4635837),    -- 4635837 строк в 01_EDA, разделы 1 и 6; в 02_cleaning, раздел 1.
        ('2019-Dec.csv', 3533286),    -- 3533286 строк в 01_EDA, разделы 1 и 6; в 02_cleaning, раздел 1.
        ('2020-Jan.csv', 4264752),    -- 4264752 строк в 01_EDA, разделы 1 и 6; в 02_cleaning, раздел 1.
        ('2020-Feb.csv', 4156682)     -- 4156682 строк в 01_EDA, разделы 1 и 6; в 02_cleaning, раздел 1.
),
actual AS (
    SELECT source_file, COUNT(*) AS actual_rows
    FROM stg.events
    GROUP BY source_file
)
SELECT
    COALESCE(e.source_file, a.source_file) AS source_file,
    e.expected_rows,
    a.actual_rows,
    CASE WHEN e.expected_rows = a.actual_rows THEN 'OK' ELSE 'FAIL' END AS status
FROM expected e
FULL JOIN actual a ON a.source_file = e.source_file
ORDER BY 1;


-- -----------------------------------------------------------------------------
-- 4. Статистика для планировщика (после успешной сверки)
--    Без ANALYZE планировщик не знает распределения данных в свежезагруженной
--    таблице, и запросы могут выполняться долго.
-- -----------------------------------------------------------------------------
ANALYZE stg.events;
