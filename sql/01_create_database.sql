-- =============================================================================
-- 01_create_database.sql
-- Создание базы данных проекта.
-- =============================================================================

CREATE DATABASE cosmetics_shop;

COMMENT ON DATABASE cosmetics_shop IS
    'Продуктовый анализ магазина косметики (REES46, Kaggle): события, витрины, метрики';

-- Проверка: 
SELECT datname, pg_encoding_to_char(encoding) AS encoding
FROM pg_database
WHERE datname = 'cosmetics_shop';
