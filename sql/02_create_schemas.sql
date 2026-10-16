-- =============================================================================
-- 02_create_schemas.sql
-- Создание схем базы cosmetics_shop по слоям данных.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS mart;
CREATE SCHEMA IF NOT EXISTS metrics;

COMMENT ON SCHEMA stg     IS 'Очищенные события из parquet (флаг is_duplicate, price > 0 или NULL)';
COMMENT ON SCHEMA mart    IS 'Витрины: сессии, пользователи, когорты';
COMMENT ON SCHEMA metrics IS 'Итоговые метрики и выгрузки для DataLens';

-- Проверка: 
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN ('stg', 'mart', 'metrics')
ORDER BY schema_name;
