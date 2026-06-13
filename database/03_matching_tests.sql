SET search_path TO hft;

-- ============================================================
-- Testes do matching, partial fill, auditoria e views
-- Execute em um banco limpo ou adapte os emails/simbolos.
-- ============================================================

INSERT INTO users (name, email)
VALUES
    ('Buyer One', 'buyer1@example.com'),
    ('Seller One', 'seller1@example.com'),
    ('Seller Two', 'seller2@example.com')
ON CONFLICT (email) DO NOTHING;

INSERT INTO assets (symbol, name, precision)
VALUES
    ('BTC', 'Bitcoin', 8),
    ('USDT', 'Tether USD', 6)
ON CONFLICT (symbol) DO NOTHING;

INSERT INTO markets (base_asset_id, quote_asset_id, symbol, price_precision, quantity_precision)
SELECT btc.asset_id, usdt.asset_id, 'BTC/USDT', 2, 8
FROM assets btc
JOIN assets usdt ON usdt.symbol = 'USDT'
WHERE btc.symbol = 'BTC'
ON CONFLICT (symbol) DO NOTHING;

INSERT INTO wallets (user_id, asset_id, available_balance, locked_balance)
SELECT u.user_id, a.asset_id,
       CASE
           WHEN u.email = 'buyer1@example.com' AND a.symbol = 'USDT' THEN 200000
           WHEN u.email IN ('seller1@example.com', 'seller2@example.com') AND a.symbol = 'BTC' THEN 10
           ELSE 0
       END,
       0
FROM users u
CROSS JOIN assets a
WHERE u.email IN ('buyer1@example.com', 'seller1@example.com', 'seller2@example.com')
ON CONFLICT (user_id, asset_id) DO UPDATE
SET available_balance = EXCLUDED.available_balance,
    locked_balance = 0,
    updated_at = now();

-- Seller One vende 2 BTC a 50000.
INSERT INTO orders (user_id, market_id, side, price, original_quantity, remaining_quantity)
SELECT u.user_id, m.market_id, 'sell', 50000, 2, 2
FROM users u
JOIN markets m ON m.symbol = 'BTC/USDT'
WHERE u.email = 'seller1@example.com';

-- Seller Two vende 2 BTC a 51000.
INSERT INTO orders (user_id, market_id, side, price, original_quantity, remaining_quantity)
SELECT u.user_id, m.market_id, 'sell', 51000, 2, 2
FROM users u
JOIN markets m ON m.symbol = 'BTC/USDT'
WHERE u.email = 'seller2@example.com';

-- Buyer One compra 3 BTC ate 52000.
-- Esperado: executa 2 BTC contra 50000 e 1 BTC contra 51000.
-- A segunda ordem de venda fica parcial com 1 BTC restante.
INSERT INTO orders (user_id, market_id, side, price, original_quantity, remaining_quantity)
SELECT u.user_id, m.market_id, 'buy', 52000, 3, 3
FROM users u
JOIN markets m ON m.symbol = 'BTC/USDT'
WHERE u.email = 'buyer1@example.com';

-- Ordens apos matching.
SELECT
    o.order_id,
    u.email,
    o.side,
    o.price,
    o.original_quantity,
    o.executed_quantity,
    o.remaining_quantity,
    o.status,
    o.created_at
FROM orders o
JOIN users u ON u.user_id = o.user_id
JOIN markets m ON m.market_id = o.market_id
WHERE m.symbol = 'BTC/USDT'
ORDER BY o.order_id;

-- Trades gerados.
SELECT *
FROM view_trades_history
WHERE market_symbol = 'BTC/USDT'
ORDER BY trade_id;

-- Auditoria.
SELECT
    audit_id,
    order_id,
    old_status,
    new_status,
    old_remaining_quantity,
    new_remaining_quantity,
    reason,
    created_at
FROM order_audit_logs
ORDER BY audit_id;

-- Saldos finais.
SELECT
    u.email,
    a.symbol,
    w.available_balance,
    w.locked_balance
FROM wallets w
JOIN users u ON u.user_id = w.user_id
JOIN assets a ON a.asset_id = w.asset_id
WHERE u.email IN ('buyer1@example.com', 'seller1@example.com', 'seller2@example.com')
ORDER BY u.email, a.symbol;

-- Views.
SELECT * FROM view_market_summary WHERE market_symbol = 'BTC/USDT';
SELECT * FROM view_traders_ranking;

