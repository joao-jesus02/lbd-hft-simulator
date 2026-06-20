SET search_path TO hft;

-- ============================================================
-- HFT Simulator - Matching, auditoria e views
-- PostgreSQL 15+
--
-- Execute depois do script estrutural com tabelas, tipos e indices.
-- ============================================================

-- ------------------------------------------------------------
-- Protecao de imutabilidade dos trades
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION prevent_trade_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Trades are immutable and cannot be updated or deleted';
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_trade_update ON trades;
CREATE TRIGGER trg_prevent_trade_update
BEFORE UPDATE ON trades
FOR EACH ROW
EXECUTE FUNCTION prevent_trade_changes();

DROP TRIGGER IF EXISTS trg_prevent_trade_delete ON trades;
CREATE TRIGGER trg_prevent_trade_delete
BEFORE DELETE ON trades
FOR EACH ROW
EXECUTE FUNCTION prevent_trade_changes();

-- ------------------------------------------------------------
-- Funcao auxiliar para registrar auditoria de ordens
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION log_order_audit(
    p_order_id BIGINT,
    p_old_status order_status,
    p_new_status order_status,
    p_old_remaining NUMERIC,
    p_new_remaining NUMERIC,
    p_reason TEXT
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO order_audit_logs (
        order_id,
        old_status,
        new_status,
        old_remaining_quantity,
        new_remaining_quantity,
        reason
    )
    VALUES (
        p_order_id,
        p_old_status,
        p_new_status,
        p_old_remaining,
        p_new_remaining,
        p_reason
    );
END;
$$;

-- ------------------------------------------------------------
-- Funcao auxiliar para registrar movimentacao de carteira
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION log_wallet_movement(
    p_wallet_id BIGINT,
    p_user_id BIGINT,
    p_asset_id BIGINT,
    p_order_id BIGINT,
    p_trade_id BIGINT,
    p_movement_type wallet_movement_type,
    p_amount NUMERIC,
    p_available_after NUMERIC,
    p_locked_after NUMERIC
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO wallet_movements (
        wallet_id,
        user_id,
        asset_id,
        order_id,
        trade_id,
        movement_type,
        amount,
        balance_available_after,
        balance_locked_after
    )
    VALUES (
        p_wallet_id,
        p_user_id,
        p_asset_id,
        p_order_id,
        p_trade_id,
        p_movement_type,
        p_amount,
        p_available_after,
        p_locked_after
    );
END;
$$;

-- ------------------------------------------------------------
-- Atualiza candle OHLCV de 1 minuto a partir de um trade
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION upsert_candle_1m(
    p_market_id BIGINT,
    p_executed_at TIMESTAMPTZ,
    p_price NUMERIC,
    p_quantity NUMERIC,
    p_quote_amount NUMERIC
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_bucket TIMESTAMPTZ;
BEGIN
    v_bucket := date_trunc('minute', p_executed_at);

    INSERT INTO candles_1m (
        market_id,
        bucket_minute,
        open_price,
        high_price,
        low_price,
        close_price,
        volume_base,
        volume_quote,
        trades_count
    )
    VALUES (
        p_market_id,
        v_bucket,
        p_price,
        p_price,
        p_price,
        p_price,
        p_quantity,
        p_quote_amount,
        1
    )
    ON CONFLICT (market_id, bucket_minute)
    DO UPDATE SET
        high_price = GREATEST(candles_1m.high_price, EXCLUDED.high_price),
        low_price = LEAST(candles_1m.low_price, EXCLUDED.low_price),
        close_price = EXCLUDED.close_price,
        volume_base = candles_1m.volume_base + EXCLUDED.volume_base,
        volume_quote = candles_1m.volume_quote + EXCLUDED.volume_quote,
        trades_count = candles_1m.trades_count + 1;
END;
$$;

CREATE OR REPLACE FUNCTION rebuild_candles_1m()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT;
BEGIN
    TRUNCATE TABLE candles_1m;

    INSERT INTO candles_1m (
        market_id,
        bucket_minute,
        open_price,
        high_price,
        low_price,
        close_price,
        volume_base,
        volume_quote,
        trades_count
    )
    SELECT
        t.market_id,
        date_trunc('minute', t.executed_at) AS bucket_minute,
        (array_agg(t.price ORDER BY t.executed_at ASC, t.trade_id ASC))[1] AS open_price,
        MAX(t.price) AS high_price,
        MIN(t.price) AS low_price,
        (array_agg(t.price ORDER BY t.executed_at DESC, t.trade_id DESC))[1] AS close_price,
        SUM(t.quantity) AS volume_base,
        SUM(t.quote_amount) AS volume_quote,
        COUNT(*) AS trades_count
    FROM trades t
    GROUP BY t.market_id, date_trunc('minute', t.executed_at);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- ------------------------------------------------------------
-- Trigger principal de matching
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION match_order_after_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_order orders%ROWTYPE;
    v_counter_order orders%ROWTYPE;
    v_market markets%ROWTYPE;
    v_lock_asset_id BIGINT;
    v_initial_lock NUMERIC(36, 18);
    v_trade_qty NUMERIC(36, 18);
    v_trade_price NUMERIC(36, 18);
    v_trade_quote NUMERIC(36, 18);
    v_new_old_remaining NUMERIC(36, 18);
    v_counter_old_remaining NUMERIC(36, 18);
    v_new_old_status order_status;
    v_counter_old_status order_status;
    v_new_status order_status;
    v_counter_status order_status;
    v_trade_id BIGINT;
    v_buyer_user_id BIGINT;
    v_seller_user_id BIGINT;
    v_buy_order_id BIGINT;
    v_sell_order_id BIGINT;
    v_buyer_base_wallet wallets%ROWTYPE;
    v_buyer_quote_wallet wallets%ROWTYPE;
    v_seller_base_wallet wallets%ROWTYPE;
    v_seller_quote_wallet wallets%ROWTYPE;
    v_order_wallet wallets%ROWTYPE;
    v_locked_needed NUMERIC(36, 18);
    v_refund NUMERIC(36, 18);
    v_new_locked_remaining NUMERIC(36, 18);
    v_locked_wallets_count INTEGER;
BEGIN
    -- Serializa o nucleo financeiro do matching para evitar deadlocks entre
    -- carteiras quando multiplos processos inserem ordens concorrentemente.
    PERFORM pg_advisory_xact_lock(hashtext('hft_matching_core'));

    IF NEW.status <> 'open' OR NEW.remaining_quantity <= 0 THEN
        RETURN NEW;
    END IF;

    SELECT *
    INTO v_market
    FROM markets
    WHERE market_id = NEW.market_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Market % not found', NEW.market_id;
    END IF;

    -- Trava a ordem entrante. Embora seja NEW, isso serializa futuras alteracoes.
    SELECT *
    INTO v_new_order
    FROM orders
    WHERE order_id = NEW.order_id
    FOR UPDATE;

    -- Bloqueia saldo da ordem entrante.
    IF v_new_order.side = 'buy' THEN
        v_lock_asset_id := v_market.quote_asset_id;
        v_initial_lock := v_new_order.price * v_new_order.remaining_quantity;
    ELSE
        v_lock_asset_id := v_market.base_asset_id;
        v_initial_lock := v_new_order.remaining_quantity;
    END IF;

    v_new_locked_remaining := v_initial_lock;

    SELECT *
    INTO v_order_wallet
    FROM wallets
    WHERE user_id = v_new_order.user_id
      AND asset_id = v_lock_asset_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet not found for user %, asset %',
            v_new_order.user_id, v_lock_asset_id;
    END IF;

    IF v_order_wallet.available_balance < v_initial_lock THEN
        RAISE EXCEPTION
            'Insufficient available balance for order %. Available %, required %',
            v_new_order.order_id, v_order_wallet.available_balance, v_initial_lock;
    END IF;

    UPDATE wallets
    SET available_balance = available_balance - v_initial_lock,
        locked_balance = locked_balance + v_initial_lock,
        updated_at = now()
    WHERE wallet_id = v_order_wallet.wallet_id
    RETURNING *
    INTO v_order_wallet;

    PERFORM log_wallet_movement(
        v_order_wallet.wallet_id,
        v_order_wallet.user_id,
        v_order_wallet.asset_id,
        v_new_order.order_id,
        NULL,
        'lock',
        v_initial_lock,
        v_order_wallet.available_balance,
        v_order_wallet.locked_balance
    );

    PERFORM log_order_audit(
        v_new_order.order_id,
        NULL,
        v_new_order.status,
        NULL,
        v_new_order.remaining_quantity,
        'created'
    );

    LOOP
        EXIT WHEN v_new_order.remaining_quantity <= 0;

        IF v_new_order.side = 'buy' THEN
            SELECT *
            INTO v_counter_order
            FROM orders
            WHERE market_id = v_new_order.market_id
              AND side = 'sell'
              AND status IN ('open', 'partial')
              AND remaining_quantity > 0
              AND price <= v_new_order.price
              AND user_id <> v_new_order.user_id
              AND EXISTS (
                  SELECT 1
                  FROM order_audit_logs audit
                  WHERE audit.order_id = orders.order_id
                    AND audit.reason = 'created'
              )
            ORDER BY price ASC, created_at ASC, order_id ASC
            LIMIT 1
            FOR UPDATE SKIP LOCKED;
        ELSE
            SELECT *
            INTO v_counter_order
            FROM orders
            WHERE market_id = v_new_order.market_id
              AND side = 'buy'
              AND status IN ('open', 'partial')
              AND remaining_quantity > 0
              AND price >= v_new_order.price
              AND user_id <> v_new_order.user_id
              AND EXISTS (
                  SELECT 1
                  FROM order_audit_logs audit
                  WHERE audit.order_id = orders.order_id
                    AND audit.reason = 'created'
              )
            ORDER BY price DESC, created_at ASC, order_id ASC
            LIMIT 1
            FOR UPDATE SKIP LOCKED;
        END IF;

        EXIT WHEN NOT FOUND;

        v_trade_qty := LEAST(v_new_order.remaining_quantity, v_counter_order.remaining_quantity);
        v_trade_price := v_counter_order.price;
        v_trade_quote := v_trade_price * v_trade_qty;

        IF v_new_order.side = 'buy' THEN
            v_buyer_user_id := v_new_order.user_id;
            v_seller_user_id := v_counter_order.user_id;
            v_buy_order_id := v_new_order.order_id;
            v_sell_order_id := v_counter_order.order_id;
        ELSE
            v_buyer_user_id := v_counter_order.user_id;
            v_seller_user_id := v_new_order.user_id;
            v_buy_order_id := v_counter_order.order_id;
            v_sell_order_id := v_new_order.order_id;
        END IF;

        -- Trava carteiras em ordem deterministica para reduzir deadlocks.
        SELECT COUNT(*)
        INTO v_locked_wallets_count
        FROM (
            SELECT wallet_id
            FROM wallets
            WHERE (user_id = v_buyer_user_id AND asset_id IN (v_market.base_asset_id, v_market.quote_asset_id))
               OR (user_id = v_seller_user_id AND asset_id IN (v_market.base_asset_id, v_market.quote_asset_id))
            ORDER BY wallet_id
            FOR UPDATE
        ) locked_wallets;

        IF v_locked_wallets_count <> 4 THEN
            RAISE EXCEPTION 'Expected 4 wallets for trade settlement, found %', v_locked_wallets_count;
        END IF;

        -- Depois da trava ordenada, carrega cada carteira para aplicar os debitos e creditos.
        SELECT *
        INTO v_buyer_base_wallet
        FROM wallets
        WHERE user_id = v_buyer_user_id
          AND asset_id = v_market.base_asset_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Buyer base wallet not found';
        END IF;

        SELECT *
        INTO v_buyer_quote_wallet
        FROM wallets
        WHERE user_id = v_buyer_user_id
          AND asset_id = v_market.quote_asset_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Buyer quote wallet not found';
        END IF;

        SELECT *
        INTO v_seller_base_wallet
        FROM wallets
        WHERE user_id = v_seller_user_id
          AND asset_id = v_market.base_asset_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Seller base wallet not found';
        END IF;

        SELECT *
        INTO v_seller_quote_wallet
        FROM wallets
        WHERE user_id = v_seller_user_id
          AND asset_id = v_market.quote_asset_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Seller quote wallet not found';
        END IF;

        IF v_buyer_quote_wallet.locked_balance < v_trade_quote THEN
            RAISE EXCEPTION 'Buyer locked quote balance is insufficient';
        END IF;

        IF v_seller_base_wallet.locked_balance < v_trade_qty THEN
            RAISE EXCEPTION 'Seller locked base balance is insufficient';
        END IF;

        INSERT INTO trades (
            market_id,
            buy_order_id,
            sell_order_id,
            buyer_user_id,
            seller_user_id,
            price,
            quantity,
            quote_amount
        )
        VALUES (
            v_new_order.market_id,
            v_buy_order_id,
            v_sell_order_id,
            v_buyer_user_id,
            v_seller_user_id,
            v_trade_price,
            v_trade_qty,
            v_trade_quote
        )
        RETURNING trade_id
        INTO v_trade_id;

        UPDATE wallets
        SET available_balance = available_balance + v_trade_qty,
            updated_at = now()
        WHERE wallet_id = v_buyer_base_wallet.wallet_id
        RETURNING *
        INTO v_buyer_base_wallet;

        UPDATE wallets
        SET locked_balance = locked_balance - v_trade_quote,
            updated_at = now()
        WHERE wallet_id = v_buyer_quote_wallet.wallet_id
        RETURNING *
        INTO v_buyer_quote_wallet;

        UPDATE wallets
        SET locked_balance = locked_balance - v_trade_qty,
            updated_at = now()
        WHERE wallet_id = v_seller_base_wallet.wallet_id
        RETURNING *
        INTO v_seller_base_wallet;

        UPDATE wallets
        SET available_balance = available_balance + v_trade_quote,
            updated_at = now()
        WHERE wallet_id = v_seller_quote_wallet.wallet_id
        RETURNING *
        INTO v_seller_quote_wallet;

        IF v_new_order.side = 'buy' THEN
            v_new_locked_remaining := v_new_locked_remaining - v_trade_quote;
        ELSE
            v_new_locked_remaining := v_new_locked_remaining - v_trade_qty;
        END IF;

        PERFORM log_wallet_movement(v_buyer_base_wallet.wallet_id, v_buyer_user_id, v_market.base_asset_id, v_buy_order_id, v_trade_id, 'trade_credit', v_trade_qty, v_buyer_base_wallet.available_balance, v_buyer_base_wallet.locked_balance);
        PERFORM log_wallet_movement(v_buyer_quote_wallet.wallet_id, v_buyer_user_id, v_market.quote_asset_id, v_buy_order_id, v_trade_id, 'trade_debit', -v_trade_quote, v_buyer_quote_wallet.available_balance, v_buyer_quote_wallet.locked_balance);
        PERFORM log_wallet_movement(v_seller_base_wallet.wallet_id, v_seller_user_id, v_market.base_asset_id, v_sell_order_id, v_trade_id, 'trade_debit', -v_trade_qty, v_seller_base_wallet.available_balance, v_seller_base_wallet.locked_balance);
        PERFORM log_wallet_movement(v_seller_quote_wallet.wallet_id, v_seller_user_id, v_market.quote_asset_id, v_sell_order_id, v_trade_id, 'trade_credit', v_trade_quote, v_seller_quote_wallet.available_balance, v_seller_quote_wallet.locked_balance);

        v_new_old_remaining := v_new_order.remaining_quantity;
        v_new_old_status := v_new_order.status;
        v_counter_old_remaining := v_counter_order.remaining_quantity;
        v_counter_old_status := v_counter_order.status;

        v_new_order.remaining_quantity := v_new_order.remaining_quantity - v_trade_qty;
        v_new_order.executed_quantity := v_new_order.executed_quantity + v_trade_qty;
        v_counter_order.remaining_quantity := v_counter_order.remaining_quantity - v_trade_qty;
        v_counter_order.executed_quantity := v_counter_order.executed_quantity + v_trade_qty;

        v_new_status := CASE
            WHEN v_new_order.remaining_quantity = 0 THEN 'filled'::order_status
            ELSE 'partial'::order_status
        END;

        v_counter_status := CASE
            WHEN v_counter_order.remaining_quantity = 0 THEN 'filled'::order_status
            ELSE 'partial'::order_status
        END;

        UPDATE orders
        SET remaining_quantity = v_new_order.remaining_quantity,
            executed_quantity = v_new_order.executed_quantity,
            status = v_new_status,
            updated_at = now()
        WHERE order_id = v_new_order.order_id;

        UPDATE orders
        SET remaining_quantity = v_counter_order.remaining_quantity,
            executed_quantity = v_counter_order.executed_quantity,
            status = v_counter_status,
            updated_at = now()
        WHERE order_id = v_counter_order.order_id;

        v_new_order.status := v_new_status;
        v_counter_order.status := v_counter_status;

        PERFORM log_order_audit(v_new_order.order_id, v_new_old_status, v_new_status, v_new_old_remaining, v_new_order.remaining_quantity, 'trade_match');
        PERFORM log_order_audit(v_counter_order.order_id, v_counter_old_status, v_counter_status, v_counter_old_remaining, v_counter_order.remaining_quantity, 'trade_match');

        -- Candles sao reconstruidos em lote por rebuild_candles_1m().
        -- Evita deadlocks em carga concorrente intensa.
    END LOOP;

    -- Reembolsa excesso de bloqueio em compra quando a execucao ocorreu abaixo do limite.
    -- O calculo usa apenas o bloqueio da ordem atual, sem misturar outros locked_balance do usuario.
    IF v_new_order.side = 'buy' THEN
        v_locked_needed := v_new_order.remaining_quantity * v_new_order.price;

        SELECT *
        INTO v_order_wallet
        FROM wallets
        WHERE user_id = v_new_order.user_id
          AND asset_id = v_market.quote_asset_id
        FOR UPDATE;

        v_refund := v_new_locked_remaining - v_locked_needed;

        IF v_refund > 0 THEN
            UPDATE wallets
            SET available_balance = available_balance + v_refund,
                locked_balance = locked_balance - v_refund,
                updated_at = now()
            WHERE wallet_id = v_order_wallet.wallet_id
            RETURNING *
            INTO v_order_wallet;

            PERFORM log_wallet_movement(
                v_order_wallet.wallet_id,
                v_order_wallet.user_id,
                v_order_wallet.asset_id,
                v_new_order.order_id,
                NULL,
                'unlock',
                v_refund,
                v_order_wallet.available_balance,
                v_order_wallet.locked_balance
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_match_order_after_insert ON orders;
CREATE TRIGGER trg_match_order_after_insert
AFTER INSERT ON orders
FOR EACH ROW
EXECUTE FUNCTION match_order_after_insert();

-- ------------------------------------------------------------
-- Views exigidas
-- ------------------------------------------------------------

CREATE OR REPLACE VIEW view_trades_history AS
SELECT
    t.trade_id,
    m.symbol AS market_symbol,
    t.price,
    t.quantity,
    t.quote_amount,
    buyer.email AS buyer_email,
    seller.email AS seller_email,
    t.buy_order_id,
    t.sell_order_id,
    t.executed_at
FROM trades t
JOIN markets m ON m.market_id = t.market_id
JOIN users buyer ON buyer.user_id = t.buyer_user_id
JOIN users seller ON seller.user_id = t.seller_user_id
ORDER BY t.executed_at DESC, t.trade_id DESC;

CREATE OR REPLACE VIEW view_market_summary AS
WITH last_trade AS (
    SELECT DISTINCT ON (t.market_id)
        t.market_id,
        t.price AS last_price,
        t.executed_at AS last_trade_at
    FROM trades t
    ORDER BY t.market_id, t.executed_at DESC, t.trade_id DESC
),
price_24h_ago AS (
    SELECT DISTINCT ON (t.market_id)
        t.market_id,
        t.price AS price_24h_ago
    FROM trades t
    WHERE t.executed_at <= now() - interval '24 hours'
    ORDER BY t.market_id, t.executed_at DESC, t.trade_id DESC
),
volume_24h AS (
    SELECT
        t.market_id,
        SUM(t.quantity) AS volume_base_24h,
        SUM(t.quote_amount) AS volume_quote_24h
    FROM trades t
    WHERE t.executed_at >= now() - interval '24 hours'
    GROUP BY t.market_id
),
best_bid AS (
    SELECT DISTINCT ON (o.market_id)
        o.market_id,
        o.price AS best_bid
    FROM orders o
    WHERE o.side = 'buy'
      AND o.status IN ('open', 'partial')
      AND o.remaining_quantity > 0
    ORDER BY o.market_id, o.price DESC, o.created_at ASC, o.order_id ASC
),
best_ask AS (
    SELECT DISTINCT ON (o.market_id)
        o.market_id,
        o.price AS best_ask
    FROM orders o
    WHERE o.side = 'sell'
      AND o.status IN ('open', 'partial')
      AND o.remaining_quantity > 0
    ORDER BY o.market_id, o.price ASC, o.created_at ASC, o.order_id ASC
)
SELECT
    m.market_id,
    m.symbol AS market_symbol,
    lt.last_price,
    lt.last_trade_at,
    CASE
        WHEN p24.price_24h_ago IS NULL OR p24.price_24h_ago = 0 THEN NULL
        ELSE ((lt.last_price - p24.price_24h_ago) / p24.price_24h_ago) * 100
    END AS variation_24h_percent,
    COALESCE(v24.volume_base_24h, 0) AS volume_base_24h,
    COALESCE(v24.volume_quote_24h, 0) AS volume_quote_24h,
    bb.best_bid,
    ba.best_ask,
    CASE
        WHEN bb.best_bid IS NULL OR ba.best_ask IS NULL THEN NULL
        ELSE ba.best_ask - bb.best_bid
    END AS spread
FROM markets m
LEFT JOIN last_trade lt ON lt.market_id = m.market_id
LEFT JOIN price_24h_ago p24 ON p24.market_id = m.market_id
LEFT JOIN volume_24h v24 ON v24.market_id = m.market_id
LEFT JOIN best_bid bb ON bb.market_id = m.market_id
LEFT JOIN best_ask ba ON ba.market_id = m.market_id;

CREATE OR REPLACE VIEW view_traders_ranking AS
WITH trader_volume AS (
    SELECT
        t.buyer_user_id AS user_id,
        SUM(t.quote_amount) AS volume_quote_24h,
        COUNT(*) AS trades_count_24h
    FROM trades t
    WHERE t.executed_at >= now() - interval '24 hours'
    GROUP BY t.buyer_user_id
    UNION ALL
    SELECT
        t.seller_user_id AS user_id,
        SUM(t.quote_amount) AS volume_quote_24h,
        COUNT(*) AS trades_count_24h
    FROM trades t
    WHERE t.executed_at >= now() - interval '24 hours'
    GROUP BY t.seller_user_id
),
grouped AS (
    SELECT
        user_id,
        SUM(volume_quote_24h) AS volume_quote_24h,
        SUM(trades_count_24h) AS trades_count_24h
    FROM trader_volume
    GROUP BY user_id
)
SELECT
    RANK() OVER (ORDER BY g.volume_quote_24h DESC) AS ranking_position,
    u.user_id,
    u.name,
    u.email,
    g.volume_quote_24h,
    g.trades_count_24h
FROM grouped g
JOIN users u ON u.user_id = g.user_id
ORDER BY ranking_position, u.user_id;

-- ============================================================
-- Funcoes de consulta do Order Book
-- ============================================================

-- Retorna os N melhores bids (compras) e asks (vendas) de um mercado
CREATE OR REPLACE FUNCTION get_best_orders(
    p_market_id BIGINT,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    side TEXT,
    price NUMERIC,
    quantity NUMERIC,
    order_id BIGINT,
    user_email TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH bids AS (
        SELECT
            'buy'::TEXT AS side,
            o.price,
            o.remaining_quantity AS quantity,
            o.order_id,
            u.email AS user_email
        FROM orders o
        JOIN users u ON u.user_id = o.user_id
        WHERE o.market_id = p_market_id
          AND o.side = 'buy'
          AND o.status IN ('open', 'partial')
          AND o.remaining_quantity > 0
        ORDER BY o.price DESC, o.created_at ASC, o.order_id ASC
        LIMIT p_limit
    ),
    asks AS (
        SELECT
            'sell'::TEXT AS side,
            o.price,
            o.remaining_quantity AS quantity,
            o.order_id,
            u.email AS user_email
        FROM orders o
        JOIN users u ON u.user_id = o.user_id
        WHERE o.market_id = p_market_id
          AND o.side = 'sell'
          AND o.status IN ('open', 'partial')
          AND o.remaining_quantity > 0
        ORDER BY o.price ASC, o.created_at ASC, o.order_id ASC
        LIMIT p_limit
    )
    SELECT book.side, book.price, book.quantity, book.order_id, book.user_email
    FROM (
        SELECT bids.side, bids.price, bids.quantity, bids.order_id, bids.user_email
        FROM bids
        UNION ALL
        SELECT asks.side, asks.price, asks.quantity, asks.order_id, asks.user_email
        FROM asks
    ) book
    ORDER BY
        CASE WHEN book.side = 'buy' THEN 0 ELSE 1 END,
        CASE WHEN book.side = 'buy' THEN book.price END DESC,
        CASE WHEN book.side = 'sell' THEN book.price END ASC,
        book.order_id ASC;
END;
$$;

-- ============================================================
-- Funcao para cancelamento de ordem
-- ============================================================

-- Cancela uma ordem aberta ou parcial e restaura o saldo bloqueado
CREATE OR REPLACE FUNCTION cancel_order(p_order_id BIGINT)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_order orders%ROWTYPE;
    v_market markets%ROWTYPE;
    v_wallet wallets%ROWTYPE;
    v_unlock_amount NUMERIC(36, 18);
    v_asset_id BIGINT;
    v_old_remaining NUMERIC(36, 18);
    v_old_status order_status;
BEGIN
    -- Travar e carregar a ordem
    SELECT *
    INTO v_order
    FROM orders
    WHERE order_id = p_order_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ordem % não encontrada', p_order_id;
    END IF;

    -- Verificar se a ordem pode ser cancelada
    IF v_order.status NOT IN ('open', 'partial') THEN
        RAISE EXCEPTION 'Ordem % não pode ser cancelada. Status atual: %', p_order_id, v_order.status;
    END IF;

    IF v_order.remaining_quantity = 0 THEN
        RAISE EXCEPTION 'Ordem % já foi totalmente executada', p_order_id;
    END IF;

    -- Carregar mercado para determinar qual ativo desbloquear
    SELECT *
    INTO v_market
    FROM markets
    WHERE market_id = v_order.market_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mercado % não encontrado', v_order.market_id;
    END IF;

    -- Determinar qual ativo desbloquear baseado no lado da ordem
    IF v_order.side = 'buy' THEN
        v_asset_id := v_market.quote_asset_id;
        v_unlock_amount := v_order.remaining_quantity * v_order.price;
    ELSE
        v_asset_id := v_market.base_asset_id;
        v_unlock_amount := v_order.remaining_quantity;
    END IF;

    -- Travar e atualizar a carteira
    SELECT *
    INTO v_wallet
    FROM wallets
    WHERE user_id = v_order.user_id
      AND asset_id = v_asset_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Carteira não encontrada para usuário % e ativo %',
            v_order.user_id, v_asset_id;
    END IF;

    -- Validar que o saldo bloqueado é suficiente
    IF v_wallet.locked_balance < v_unlock_amount THEN
        RAISE EXCEPTION 'Saldo bloqueado insuficiente. Bloqueado: %, a liberar: %',
            v_wallet.locked_balance, v_unlock_amount;
    END IF;

    -- Registrar auditoria antes da mudança
    v_old_status := v_order.status;
    v_old_remaining := v_order.remaining_quantity;

    -- Atualizar ordem para cancelada
    UPDATE orders
    SET status = 'cancelled',
        remaining_quantity = 0,
        cancelled_at = now(),
        updated_at = now()
    WHERE order_id = p_order_id;

    -- Atualizar carteira: mover do bloqueado para disponível
    UPDATE wallets
    SET available_balance = available_balance + v_unlock_amount,
        locked_balance = locked_balance - v_unlock_amount,
        updated_at = now()
    WHERE wallet_id = v_wallet.wallet_id;

    -- Registrar movimentação de carteira
    PERFORM log_wallet_movement(
        v_wallet.wallet_id,
        v_order.user_id,
        v_asset_id,
        p_order_id,
        NULL,
        'cancel_release',
        v_unlock_amount,
        (v_wallet.available_balance + v_unlock_amount),
        (v_wallet.locked_balance - v_unlock_amount)
    );

    -- Registrar auditoria da ordem
    PERFORM log_order_audit(
        p_order_id,
        v_old_status,
        'cancelled',
        v_old_remaining,
        0,
        'cancelled_by_user'
    );
END;
$$;

-- ============================================================
-- Funcao para consultar portfolio do usuario
-- ============================================================

-- Retorna o portfolio (saldos) de um usuário com valores totais
CREATE OR REPLACE FUNCTION user_portfolio(p_user_id BIGINT)
RETURNS TABLE (
    asset_symbol TEXT,
    available_balance NUMERIC,
    locked_balance NUMERIC,
    total_balance NUMERIC,
    value_in_quote NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_user_exists BOOLEAN;
    v_last_price NUMERIC(36, 18);
BEGIN
    -- Verificar se usuário existe
    SELECT EXISTS(SELECT 1 FROM users WHERE user_id = p_user_id)
    INTO v_user_exists;

    IF NOT v_user_exists THEN
        RAISE EXCEPTION 'Usuário % não encontrado', p_user_id;
    END IF;

    -- Retornar portfolio com valores em USDT (ou último preço negociado)
    RETURN QUERY
    WITH portfolio AS (
        SELECT
            a.symbol AS asset_symbol,
            w.available_balance,
            w.locked_balance,
            w.available_balance + w.locked_balance AS total_balance,
            a.asset_id
        FROM wallets w
        JOIN assets a ON a.asset_id = w.asset_id
        WHERE w.user_id = p_user_id
    ),
    prices AS (
        SELECT DISTINCT ON (m.quote_asset_id)
            m.quote_asset_id,
            t.price AS last_price
        FROM trades t
        JOIN markets m ON m.market_id = t.market_id
        WHERE m.quote_asset_id = (SELECT asset_id FROM assets WHERE symbol = 'USDT' LIMIT 1)
        ORDER BY m.quote_asset_id, t.executed_at DESC, t.trade_id DESC
    )
    SELECT
        p.asset_symbol,
        p.available_balance,
        p.locked_balance,
        p.total_balance,
        CASE
            WHEN p.asset_symbol = 'USDT' THEN p.total_balance
            ELSE COALESCE(
                (
                    SELECT p2.last_price * p.total_balance
                    FROM (
                        SELECT DISTINCT ON (m.base_asset_id)
                            t.price AS last_price
                        FROM trades t
                        JOIN markets m ON m.market_id = t.market_id
                        WHERE m.base_asset_id = p.asset_id
                          AND m.quote_asset_id = (SELECT asset_id FROM assets WHERE symbol = 'USDT' LIMIT 1)
                        ORDER BY m.base_asset_id, t.executed_at DESC, t.trade_id DESC
                    ) p2
                ),
                0
            )
        END AS value_in_quote
    FROM portfolio p
    ORDER BY p.asset_symbol;
END;
$$;
