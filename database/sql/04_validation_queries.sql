SET search_path TO hft;

-- ============================================================
-- Consultas de validacao para demonstracao
-- ============================================================

-- 1. Tabelas criadas no schema hft.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'hft'
ORDER BY table_name;

-- 2. PKs, FKs, UNIQUEs e CHECKs.
SELECT
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type
FROM information_schema.table_constraints tc
WHERE tc.table_schema = 'hft'
ORDER BY tc.table_name, tc.constraint_type, tc.constraint_name;

-- 3. Indices principais do order book.
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'hft'
  AND tablename IN ('orders', 'trades', 'candles_1m')
ORDER BY tablename, indexname;

-- 4. Melhor book por mercado.
SELECT *
FROM get_best_orders(
    (SELECT market_id FROM markets WHERE symbol = 'BTC/USDT'),
    10
);

-- 5. Historico de trades.
SELECT *
FROM view_trades_history
ORDER BY executed_at DESC, trade_id DESC
LIMIT 20;

-- 5.1. Reconstrucao dos candles a partir dos trades.
SELECT rebuild_candles_1m() AS candles_rebuilt;

-- 6. Resumo de mercado.
SELECT *
FROM view_market_summary
ORDER BY market_symbol;

-- 7. Ranking de traders.
SELECT *
FROM view_traders_ranking
LIMIT 20;

-- 8. Portfolio de um usuario de exemplo.
SELECT *
FROM user_portfolio(
    (SELECT user_id FROM users ORDER BY user_id LIMIT 1)
);

-- 9. Tamanho do banco para comprovar volume.
SELECT
    current_database() AS database_name,
    pg_size_pretty(pg_database_size(current_database())) AS database_size;

-- 10. Quantidades principais.
SELECT 'users' AS object_name, COUNT(*) AS total FROM users
UNION ALL
SELECT 'orders', COUNT(*) FROM orders
UNION ALL
SELECT 'trades', COUNT(*) FROM trades
UNION ALL
SELECT 'wallet_movements', COUNT(*) FROM wallet_movements
UNION ALL
SELECT 'order_audit_logs', COUNT(*) FROM order_audit_logs
UNION ALL
SELECT 'candles_1m', COUNT(*) FROM candles_1m;

-- 11. Checks de integridade financeira e do order book.
SELECT 'negative_wallets' AS check_name, COUNT(*) AS problems
FROM wallets
WHERE available_balance < 0 OR locked_balance < 0
UNION ALL
SELECT 'bad_order_quantities', COUNT(*)
FROM orders
WHERE remaining_quantity < 0
   OR executed_quantity < 0
   OR remaining_quantity + executed_quantity > original_quantity;

WITH required AS (
    SELECT
        o.user_id,
        CASE
            WHEN o.side = 'buy' THEN m.quote_asset_id
            ELSE m.base_asset_id
        END AS asset_id,
        SUM(
            CASE
                WHEN o.side = 'buy' THEN o.price * o.remaining_quantity
                ELSE o.remaining_quantity
            END
        ) AS required_locked
    FROM orders o
    JOIN markets m ON m.market_id = o.market_id
    WHERE o.status IN ('open', 'partial')
      AND o.remaining_quantity > 0
    GROUP BY
        o.user_id,
        CASE
            WHEN o.side = 'buy' THEN m.quote_asset_id
            ELSE m.base_asset_id
        END
)
SELECT 'lock_mismatch' AS check_name, COUNT(*) AS problems
FROM wallets w
FULL JOIN required r
       ON r.user_id = w.user_id
      AND r.asset_id = w.asset_id
WHERE ABS(COALESCE(w.locked_balance, 0) - COALESCE(r.required_locked, 0)) > 0.000001;

WITH bid AS (
    SELECT market_id, MAX(price) AS best_bid
    FROM orders
    WHERE side = 'buy'
      AND status IN ('open', 'partial')
      AND remaining_quantity > 0
    GROUP BY market_id
),
ask AS (
    SELECT market_id, MIN(price) AS best_ask
    FROM orders
    WHERE side = 'sell'
      AND status IN ('open', 'partial')
      AND remaining_quantity > 0
    GROUP BY market_id
)
SELECT 'crossed_books' AS check_name, COUNT(*) AS problems
FROM bid
JOIN ask USING (market_id)
WHERE bid.best_bid >= ask.best_ask;
