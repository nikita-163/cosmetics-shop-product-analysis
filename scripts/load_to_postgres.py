"""
Загрузка очищенных событий из parquet в PostgreSQL (stg.events).

Что делает:
    1. читает data/processed/events_clean.parquet батчами (в памяти один батч);
    2. каждый батч переводит в CSV и отправляет через COPY ... FROM STDIN;
    3. всё выполняется в ОДНОЙ транзакции: TRUNCATE + COPY + сверка счётчиков.
    Если что-то пошло не так, в таблице остаётся то, что было до запуска.

Подключение: переменные PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
(из файла .env в корне проекта или из окружения). Пароль в коде не хранится.

Запуск из корня проекта:
    python scripts/load_to_postgres.py
    python scripts/load_to_postgres.py --batch-size 250000
"""

import argparse
import io
import time
from pathlib import Path

import psycopg
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.csv as pacsv
import pyarrow.parquet as pq
from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
PARQUET_PATH = PROJECT_ROOT / "data" / "processed" / "events_clean.parquet"

TARGET_TABLE = "stg.events"

# Порядок и состав колонок: совпадает с sql/03_create_stg_events.sql.
# Список передаётся в COPY явно, чтобы загрузка не зависела от порядка в файле.
COLUMNS = [
    "event_time",
    "event_type",
    "product_id",
    "category_id",
    "category_code",
    "brand",
    "price",
    "user_id",
    "user_session",
    "source_file",
    "is_duplicate",
]

# Формат времени для COPY. Источник в UTC (проверяется в check_schema), поэтому
# смещение задаём явно: так Postgres не зависит от часового пояса сессии.
TIME_FORMAT = "%Y-%m-%d %H:%M:%S+00"


def check_schema(schema: pa.Schema) -> None:
    """Падаем сразу, если parquet не тот, который ожидает таблица."""
    missing = [c for c in COLUMNS if c not in schema.names]
    if missing:
        raise ValueError(f"В parquet нет колонок: {missing}")

    time_type = schema.field("event_time").type
    if not pa.types.is_timestamp(time_type) or time_type.tz != "UTC":
        raise ValueError(
            f"event_time должен быть timestamp с tz=UTC, а получен: {time_type}"
        )


def batch_to_csv_bytes(batch: pa.RecordBatch) -> bytes:
    """Один батч parquet -> CSV-байты в формате, понятном COPY (без заголовка)."""
    table = pa.Table.from_batches([batch])

    # Время выводим строкой сами, чтобы формат не зависел от версии pyarrow.
    idx = table.schema.get_field_index("event_time")
    time_str = pc.strftime(table["event_time"], format=TIME_FORMAT)
    table = table.set_column(idx, "event_time", time_str)

    buf = io.BytesIO()
    options = pacsv.WriteOptions(include_header=False, quoting_style="needed")
    pacsv.write_csv(table, buf, write_options=options)
    return buf.getvalue()


def load(batch_size: int) -> None:
    pf = pq.ParquetFile(PARQUET_PATH)
    check_schema(pf.schema_arrow)

    expected_rows = pf.metadata.num_rows
    print(f"Источник: {PARQUET_PATH.name}, строк в файле: {expected_rows:,}")

    # Контрольные суммы считаем по ходу чтения, потом сверяем с тем, что в БД.
    seen_rows = 0
    seen_null_price = 0
    seen_duplicates = 0

    copy_sql = f"COPY {TARGET_TABLE} ({', '.join(COLUMNS)}) FROM STDIN WITH (FORMAT csv)"
    started = time.perf_counter()

    # Контекстный менеджер: при исключении транзакция откатывается,
    # при нормальном выходе без commit тоже (мы коммитим явно ниже).
    with psycopg.connect() as conn:
        with conn.cursor() as cur:
            cur.execute(f"TRUNCATE {TARGET_TABLE}")

            with cur.copy(copy_sql) as copy:
                for batch in pf.iter_batches(batch_size=batch_size, columns=COLUMNS):
                    copy.write(batch_to_csv_bytes(batch))

                    seen_rows += batch.num_rows
                    seen_null_price += batch.column("price").null_count
                    seen_duplicates += pc.sum(batch.column("is_duplicate")).as_py() or 0

                    elapsed = time.perf_counter() - started
                    print(f"  отправлено {seen_rows:>11,} строк, {elapsed:6.1f} c")

            # Сверка ДО commit: если не сходится, откатываемся.
            cur.execute(
                f"""
                SELECT count(*),
                    count(*) FILTER (WHERE price IS NULL),
                    count(*) FILTER (WHERE is_duplicate)
                FROM {TARGET_TABLE}
                """
            )
            db_rows, db_null_price, db_duplicates = cur.fetchone()

        problems = []
        if db_rows != expected_rows:
            problems.append(f"строк: в БД {db_rows:,}, в parquet {expected_rows:,}")
        if db_rows != seen_rows:
            problems.append(f"строк: в БД {db_rows:,}, прочитано {seen_rows:,}")
        if db_null_price != seen_null_price:
            problems.append(f"price IS NULL: в БД {db_null_price:,}, в parquet {seen_null_price:,}")
        if db_duplicates != seen_duplicates:
            problems.append(f"is_duplicate: в БД {db_duplicates:,}, в parquet {seen_duplicates:,}")

        if problems:
            raise RuntimeError("Сверка не прошла, транзакция откатана:\n  " + "\n  ".join(problems))

        conn.commit()

    total = time.perf_counter() - started
    print(f"Готово: {db_rows:,} строк за {total:.1f} c")
    print(f"  price IS NULL: {db_null_price:,}; is_duplicate = true: {db_duplicates:,}")


def main() -> None:
    parser = argparse.ArgumentParser(description="parquet -> PostgreSQL (stg.events)")
    parser.add_argument("--batch-size", type=int, default=500_000,
                        help="строк в одном батче (по умолчанию 500000)")
    args = parser.parse_args()

    load_dotenv(PROJECT_ROOT / ".env")
    load(args.batch_size)


if __name__ == "__main__":
    main()
