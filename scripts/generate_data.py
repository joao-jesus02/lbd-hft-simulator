import argparse
import math
import os
import random
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone

import psycopg


ASSETS = [
    ("BTC", "Bitcoin", 8),
    ("ETH", "Ethereum", 8),
    ("SOL", "Solana", 8),
    ("USDT", "Tether USD", 6),
]

MARKETS = [
    ("BTC/USDT", "BTC", "USDT", 2, 8, 50000.0),
    ("ETH/USDT", "ETH", "USDT", 2, 8, 3000.0),
    ("SOL/USDT", "SOL", "USDT", 2, 8, 150.0),
]


def connect(dsn: str):
    return psycopg.connect(dsn, autocommit=False)


def execute_many(cur, sql, rows):
    with cur.copy(sql) as copy:
        for row in rows:
            copy.write_row(row)


def setup_seed_data(dsn: str, traders: int):
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO hft")

            cur.executemany(
                """
                INSERT INTO assets (symbol, name, precision)
                VALUES (%s, %s, %s)
                ON CONFLICT (symbol) DO NOTHING
                """,
                ASSETS,
            )

            for symbol, base, quote, price_precision, qty_precision, _ in MARKETS:
                cur.execute(
                    """
                    INSERT INTO markets (
                        base_asset_id,
                        quote_asset_id,
                        symbol,
                        price_precision,
                        quantity_precision
                    )
                    SELECT b.asset_id, q.asset_id, %s, %s, %s
                    FROM assets b
                    JOIN assets q ON q.symbol = %s
                    WHERE b.symbol = %s
                    ON CONFLICT (symbol) DO NOTHING
                    """,
                    (symbol, price_precision, qty_precision, quote, base),
                )

            cur.executemany(
                """
                INSERT INTO users (name, email)
                VALUES (%s, %s)
                ON CONFLICT (email) DO NOTHING
                """,
                [
                    (f"Trader {i:05d}", f"trader{i:05d}@sim.local")
                    for i in range(1, traders + 1)
                ],
            )

            cur.execute(
                """
                INSERT INTO wallets (user_id, asset_id, available_balance, locked_balance)
                SELECT u.user_id, a.asset_id,
                       CASE
                           WHEN a.symbol = 'USDT' THEN 100000000
                           WHEN a.symbol = 'BTC' THEN 100
                           WHEN a.symbol = 'ETH' THEN 2000
                           WHEN a.symbol = 'SOL' THEN 50000
                           ELSE 0
                       END,
                       0
                FROM users u
                CROSS JOIN assets a
                WHERE u.email LIKE 'trader%@sim.local'
                ON CONFLICT (user_id, asset_id) DO NOTHING
                """
            )

        conn.commit()


def load_ids(dsn: str):
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO hft")
            cur.execute("SELECT user_id FROM users WHERE email LIKE 'trader%@sim.local' ORDER BY user_id")
            users = [row[0] for row in cur.fetchall()]
            cur.execute("SELECT market_id, symbol FROM markets ORDER BY market_id")
            markets = cur.fetchall()
    return users, markets


def realistic_price(base_price: float, step: int, rng: random.Random) -> float:
    wave = math.sin(step / 200.0) * 0.006
    drift = math.sin(step / 2000.0) * 0.02
    noise = rng.gauss(0, 0.002)
    return max(0.01, base_price * (1 + wave + drift + noise))


def worker(dsn: str, worker_id: int, orders_count: int, batch_size: int):
    rng = random.Random(1000 + worker_id)
    users, markets = load_ids(dsn)
    market_base_price = {symbol: base for symbol, _, _, _, _, base in MARKETS}

    inserted = 0
    start = time.perf_counter()

    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO hft")

            rows = []
            for i in range(orders_count):
                market_id, symbol = rng.choice(markets)
                base_price = market_base_price[symbol]
                mid = realistic_price(base_price, i + worker_id * orders_count, rng)
                side = "buy" if rng.random() < 0.5 else "sell"

                if side == "buy":
                    price = mid * (1 - rng.random() * 0.006)
                else:
                    price = mid * (1 + rng.random() * 0.006)

                qty = max(0.0001, rng.lognormvariate(-1.5, 0.8))

                rows.append(
                    (
                        rng.choice(users),
                        market_id,
                        side,
                        round(price, 8),
                        round(qty, 8),
                        round(qty, 8),
                    )
                )

                if len(rows) >= batch_size:
                    execute_many(
                        cur,
                        """
                        COPY orders (
                            user_id,
                            market_id,
                            side,
                            price,
                            original_quantity,
                            remaining_quantity
                        )
                        FROM STDIN
                        """,
                        rows,
                    )
                    conn.commit()
                    inserted += len(rows)
                    rows.clear()

            if rows:
                execute_many(
                    cur,
                    """
                    COPY orders (
                        user_id,
                        market_id,
                        side,
                        price,
                        original_quantity,
                        remaining_quantity
                    )
                    FROM STDIN
                    """,
                    rows,
                )
                conn.commit()
                inserted += len(rows)

    elapsed = time.perf_counter() - start
    return worker_id, inserted, elapsed


def count_results(dsn: str):
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO hft")
            cur.execute("SELECT COUNT(*) FROM orders")
            orders = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM trades")
            trades = cur.fetchone()[0]
            cur.execute(
                """
                SELECT pg_size_pretty(pg_database_size(current_database())),
                       pg_database_size(current_database())
                """
            )
            size_pretty, size_bytes = cur.fetchone()
    return orders, trades, size_pretty, size_bytes


def rebuild_candles(dsn: str):
    with connect(dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SET search_path TO hft")
            cur.execute("SELECT rebuild_candles_1m()")
            rows = cur.fetchone()[0]
        conn.commit()
    return rows


def main():
    parser = argparse.ArgumentParser(description="Gerador concorrente de dados para HFT Simulator.")
    parser.add_argument("--dsn", default=os.getenv("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/hft"))
    parser.add_argument("--traders", type=int, default=500)
    parser.add_argument("--orders", type=int, default=200000)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--batch-size", type=int, default=1000)
    args = parser.parse_args()

    setup_seed_data(args.dsn, args.traders)

    per_worker = args.orders // args.workers
    remainder = args.orders % args.workers
    started_at = datetime.now(timezone.utc)
    start = time.perf_counter()

    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = []
        for worker_id in range(args.workers):
            total = per_worker + (1 if worker_id < remainder else 0)
            futures.append(executor.submit(worker, args.dsn, worker_id + 1, total, args.batch_size))

        for future in as_completed(futures):
            worker_id, inserted, elapsed = future.result()
            print(f"worker={worker_id} inserted={inserted} elapsed={elapsed:.2f}s")

    candles_rebuilt = rebuild_candles(args.dsn)
    elapsed = time.perf_counter() - start
    orders, trades, size_pretty, size_bytes = count_results(args.dsn)

    print("started_at_utc=", started_at.isoformat())
    print("volume_total_orders=", orders)
    print("trades_generated=", trades)
    print("candles_rebuilt=", candles_rebuilt)
    print("database_size=", size_pretty)
    print("database_size_bytes=", size_bytes)
    print("execution_time_seconds=", round(elapsed, 2))


if __name__ == "__main__":
    main()
