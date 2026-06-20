-- ============================================================
-- HFT Simulator - Order Book de Criptomoedas
-- PostgreSQL 15+
-- Etapa: Modelo físico inicial, tabelas, constraints e índices
-- Não inclui triggers nem funções.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS hft;
SET search_path TO hft;

-- ============================================================
-- Tipos enumerados
-- ============================================================

CREATE TYPE user_status AS ENUM (
    'active',
    'blocked',
    'inactive'
);

CREATE TYPE order_side AS ENUM (
    'buy',
    'sell'
);

CREATE TYPE order_status AS ENUM (
    'open',
    'partial',
    'filled',
    'cancelled'
);

CREATE TYPE wallet_movement_type AS ENUM (
    'deposit',
    'lock',
    'unlock',
    'trade_debit',
    'trade_credit',
    'fee',
    'cancel_release'
);

-- ============================================================
-- Usuários
-- ============================================================

CREATE TABLE users (
    user_id      BIGSERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE,
    status       user_status NOT NULL DEFAULT 'active',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_users_email_not_empty
        CHECK (length(trim(email)) > 0),

    CONSTRAINT chk_users_name_not_empty
        CHECK (length(trim(name)) > 0)
);

COMMENT ON TABLE users IS
'Usuários/traders cadastrados no simulador. Cada usuário pode possuir carteiras e enviar múltiplas ordens.';

COMMENT ON COLUMN users.status IS
'Estado operacional do usuário: active, blocked ou inactive.';

-- ============================================================
-- Ativos
-- ============================================================

CREATE TABLE assets (
    asset_id     BIGSERIAL PRIMARY KEY,
    symbol       TEXT NOT NULL UNIQUE,
    name         TEXT NOT NULL,
    precision    INTEGER NOT NULL DEFAULT 8,
    is_active    BOOLEAN NOT NULL DEFAULT true,

    CONSTRAINT chk_assets_symbol_not_empty
        CHECK (length(trim(symbol)) > 0),

    CONSTRAINT chk_assets_name_not_empty
        CHECK (length(trim(name)) > 0),

    CONSTRAINT chk_assets_precision_valid
        CHECK (precision BETWEEN 0 AND 18)
);

COMMENT ON TABLE assets IS
'Ativos negociáveis ou usados como moeda de cotação, como BTC, ETH, USDT e BRL.';

COMMENT ON COLUMN assets.precision IS
'Quantidade de casas decimais permitidas para o ativo.';

-- ============================================================
-- Mercados / pares de negociação
-- ============================================================

CREATE TABLE markets (
    market_id           BIGSERIAL PRIMARY KEY,
    base_asset_id       BIGINT NOT NULL,
    quote_asset_id      BIGINT NOT NULL,
    symbol              TEXT NOT NULL UNIQUE,
    price_precision     INTEGER NOT NULL DEFAULT 2,
    quantity_precision  INTEGER NOT NULL DEFAULT 8,
    is_active           BOOLEAN NOT NULL DEFAULT true,

    CONSTRAINT fk_markets_base_asset
        FOREIGN KEY (base_asset_id)
        REFERENCES assets (asset_id),

    CONSTRAINT fk_markets_quote_asset
        FOREIGN KEY (quote_asset_id)
        REFERENCES assets (asset_id),

    CONSTRAINT chk_markets_distinct_assets
        CHECK (base_asset_id <> quote_asset_id),

    CONSTRAINT chk_markets_symbol_not_empty
        CHECK (length(trim(symbol)) > 0),

    CONSTRAINT chk_markets_price_precision_valid
        CHECK (price_precision BETWEEN 0 AND 18),

    CONSTRAINT chk_markets_quantity_precision_valid
        CHECK (quantity_precision BETWEEN 0 AND 18)
);

COMMENT ON TABLE markets IS
'Pares de negociação do order book. Exemplo: BTC/USDT, onde BTC é o ativo base e USDT é o ativo de cotação.';

COMMENT ON COLUMN markets.base_asset_id IS
'Ativo negociado. Em BTC/USDT, o ativo base é BTC.';

COMMENT ON COLUMN markets.quote_asset_id IS
'Ativo usado para precificar. Em BTC/USDT, o ativo de cotação é USDT.';

-- ============================================================
-- Carteiras
-- ============================================================

CREATE TABLE wallets (
    wallet_id           BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL,
    asset_id            BIGINT NOT NULL,
    available_balance   NUMERIC(36, 18) NOT NULL DEFAULT 0,
    locked_balance      NUMERIC(36, 18) NOT NULL DEFAULT 0,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_wallets_user
        FOREIGN KEY (user_id)
        REFERENCES users (user_id),

    CONSTRAINT fk_wallets_asset
        FOREIGN KEY (asset_id)
        REFERENCES assets (asset_id),

    CONSTRAINT uq_wallets_user_asset
        UNIQUE (user_id, asset_id),

    CONSTRAINT chk_wallets_available_non_negative
        CHECK (available_balance >= 0),

    CONSTRAINT chk_wallets_locked_non_negative
        CHECK (locked_balance >= 0)
);

COMMENT ON TABLE wallets IS
'Carteiras dos usuários por ativo. Controla saldo disponível e saldo bloqueado por ordens abertas ou parciais.';

COMMENT ON COLUMN wallets.available_balance IS
'Saldo livre para ser usado em novas ordens ou retiradas.';

COMMENT ON COLUMN wallets.locked_balance IS
'Saldo reservado por ordens abertas ou parcialmente executadas.';

-- ============================================================
-- Ordens
-- ============================================================

CREATE TABLE orders (
    order_id            BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL,
    market_id           BIGINT NOT NULL,
    side                order_side NOT NULL,
    price               NUMERIC(36, 18) NOT NULL,
    original_quantity   NUMERIC(36, 18) NOT NULL,
    remaining_quantity  NUMERIC(36, 18) NOT NULL,
    executed_quantity   NUMERIC(36, 18) NOT NULL DEFAULT 0,
    status              order_status NOT NULL DEFAULT 'open',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelled_at        TIMESTAMPTZ,

    CONSTRAINT fk_orders_user
        FOREIGN KEY (user_id)
        REFERENCES users (user_id),

    CONSTRAINT fk_orders_market
        FOREIGN KEY (market_id)
        REFERENCES markets (market_id),

    CONSTRAINT chk_orders_price_positive
        CHECK (price > 0),

    CONSTRAINT chk_orders_original_quantity_positive
        CHECK (original_quantity > 0),

    CONSTRAINT chk_orders_remaining_quantity_non_negative
        CHECK (remaining_quantity >= 0),

    CONSTRAINT chk_orders_executed_quantity_non_negative
        CHECK (executed_quantity >= 0),

    CONSTRAINT chk_orders_quantities_consistent
        CHECK (remaining_quantity + executed_quantity <= original_quantity),

    CONSTRAINT chk_orders_cancelled_at_consistent
        CHECK (
            (status = 'cancelled' AND cancelled_at IS NOT NULL)
            OR
            (status <> 'cancelled')
        ),

    CONSTRAINT chk_orders_filled_has_no_remaining
        CHECK (
            (status = 'filled' AND remaining_quantity = 0)
            OR
            (status <> 'filled')
        ),

    CONSTRAINT chk_orders_partial_has_execution_and_remaining
        CHECK (
            (status = 'partial'
                AND executed_quantity > 0
                AND remaining_quantity > 0)
            OR
            (status <> 'partial')
        )
);

COMMENT ON TABLE orders IS
'Ordens de compra e venda inseridas no order book. Cada ordem pertence a um usuário e a um mercado.';

COMMENT ON COLUMN orders.side IS
'Lado da ordem: buy para compra ou sell para venda.';

COMMENT ON COLUMN orders.status IS
'Estado da ordem: open, partial, filled ou cancelled.';

COMMENT ON COLUMN orders.remaining_quantity IS
'Quantidade ainda não executada da ordem.';

COMMENT ON COLUMN orders.executed_quantity IS
'Quantidade já executada por trades.';

-- ============================================================
-- Trades
-- ============================================================

CREATE TABLE trades (
    trade_id        BIGSERIAL PRIMARY KEY,
    market_id       BIGINT NOT NULL,
    buy_order_id    BIGINT NOT NULL,
    sell_order_id   BIGINT NOT NULL,
    buyer_user_id   BIGINT NOT NULL,
    seller_user_id  BIGINT NOT NULL,
    price           NUMERIC(36, 18) NOT NULL,
    quantity        NUMERIC(36, 18) NOT NULL,
    quote_amount    NUMERIC(36, 18) NOT NULL,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_trades_market
        FOREIGN KEY (market_id)
        REFERENCES markets (market_id),

    CONSTRAINT fk_trades_buy_order
        FOREIGN KEY (buy_order_id)
        REFERENCES orders (order_id),

    CONSTRAINT fk_trades_sell_order
        FOREIGN KEY (sell_order_id)
        REFERENCES orders (order_id),

    CONSTRAINT fk_trades_buyer_user
        FOREIGN KEY (buyer_user_id)
        REFERENCES users (user_id),

    CONSTRAINT fk_trades_seller_user
        FOREIGN KEY (seller_user_id)
        REFERENCES users (user_id),

    CONSTRAINT chk_trades_distinct_orders
        CHECK (buy_order_id <> sell_order_id),

    CONSTRAINT chk_trades_distinct_users
        CHECK (buyer_user_id <> seller_user_id),

    CONSTRAINT chk_trades_price_positive
        CHECK (price > 0),

    CONSTRAINT chk_trades_quantity_positive
        CHECK (quantity > 0),

    CONSTRAINT chk_trades_quote_amount_positive
        CHECK (quote_amount > 0)
);

COMMENT ON TABLE trades IS
'Registro imutável dos negócios executados. Cada trade liga uma ordem de compra a uma ordem de venda.';

COMMENT ON COLUMN trades.quote_amount IS
'Valor financeiro do trade no ativo de cotação: price * quantity.';

-- ============================================================
-- Auditoria de ordens
-- ============================================================

CREATE TABLE order_audit_logs (
    audit_id                    BIGSERIAL PRIMARY KEY,
    order_id                    BIGINT NOT NULL,
    old_status                  order_status,
    new_status                  order_status NOT NULL,
    old_remaining_quantity      NUMERIC(36, 18),
    new_remaining_quantity      NUMERIC(36, 18),
    reason                      TEXT NOT NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_order_audit_logs_order
        FOREIGN KEY (order_id)
        REFERENCES orders (order_id),

    CONSTRAINT chk_order_audit_logs_reason_not_empty
        CHECK (length(trim(reason)) > 0),

    CONSTRAINT chk_order_audit_logs_old_remaining_non_negative
        CHECK (old_remaining_quantity IS NULL OR old_remaining_quantity >= 0),

    CONSTRAINT chk_order_audit_logs_new_remaining_non_negative
        CHECK (new_remaining_quantity IS NULL OR new_remaining_quantity >= 0)
);

COMMENT ON TABLE order_audit_logs IS
'Log de auditoria das mudanças de estado e quantidade restante das ordens.';

-- ============================================================
-- Movimentações de carteira
-- ============================================================

CREATE TABLE wallet_movements (
    movement_id                BIGSERIAL PRIMARY KEY,
    wallet_id                  BIGINT NOT NULL,
    user_id                    BIGINT NOT NULL,
    asset_id                   BIGINT NOT NULL,
    order_id                   BIGINT,
    trade_id                   BIGINT,
    movement_type              wallet_movement_type NOT NULL,
    amount                     NUMERIC(36, 18) NOT NULL,
    balance_available_after    NUMERIC(36, 18) NOT NULL,
    balance_locked_after       NUMERIC(36, 18) NOT NULL,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_wallet_movements_wallet
        FOREIGN KEY (wallet_id)
        REFERENCES wallets (wallet_id),

    CONSTRAINT fk_wallet_movements_user
        FOREIGN KEY (user_id)
        REFERENCES users (user_id),

    CONSTRAINT fk_wallet_movements_asset
        FOREIGN KEY (asset_id)
        REFERENCES assets (asset_id),

    CONSTRAINT fk_wallet_movements_order
        FOREIGN KEY (order_id)
        REFERENCES orders (order_id),

    CONSTRAINT fk_wallet_movements_trade
        FOREIGN KEY (trade_id)
        REFERENCES trades (trade_id),

    CONSTRAINT chk_wallet_movements_amount_not_zero
        CHECK (amount <> 0),

    CONSTRAINT chk_wallet_movements_available_after_non_negative
        CHECK (balance_available_after >= 0),

    CONSTRAINT chk_wallet_movements_locked_after_non_negative
        CHECK (balance_locked_after >= 0)
);

COMMENT ON TABLE wallet_movements IS
'Histórico das alterações de saldo das carteiras. Permite auditar bloqueios, liberações, débitos e créditos.';

-- ============================================================
-- Candles OHLCV por minuto
-- Tabela particionada por tempo
-- ============================================================

CREATE TABLE candles_1m (
    market_id       BIGINT NOT NULL,
    bucket_minute   TIMESTAMPTZ NOT NULL,
    open_price      NUMERIC(36, 18) NOT NULL,
    high_price      NUMERIC(36, 18) NOT NULL,
    low_price       NUMERIC(36, 18) NOT NULL,
    close_price     NUMERIC(36, 18) NOT NULL,
    volume_base     NUMERIC(36, 18) NOT NULL DEFAULT 0,
    volume_quote    NUMERIC(36, 18) NOT NULL DEFAULT 0,
    trades_count    BIGINT NOT NULL DEFAULT 0,

    CONSTRAINT pk_candles_1m
        PRIMARY KEY (market_id, bucket_minute),

    CONSTRAINT fk_candles_1m_market
        FOREIGN KEY (market_id)
        REFERENCES markets (market_id),

    CONSTRAINT chk_candles_prices_positive
        CHECK (
            open_price > 0
            AND high_price > 0
            AND low_price > 0
            AND close_price > 0
        ),

    CONSTRAINT chk_candles_price_range
        CHECK (
            high_price >= low_price
            AND high_price >= open_price
            AND high_price >= close_price
            AND low_price <= open_price
            AND low_price <= close_price
        ),

    CONSTRAINT chk_candles_volume_non_negative
        CHECK (volume_base >= 0 AND volume_quote >= 0),

    CONSTRAINT chk_candles_trades_count_non_negative
        CHECK (trades_count >= 0)
) PARTITION BY RANGE (bucket_minute);

COMMENT ON TABLE candles_1m IS
'Série temporal de preços OHLCV por minuto. Tabela particionada por bucket_minute para suportar grande volume de dados.';

-- Exemplo de partições. Ajuste conforme o período usado no gerador de dados.

CREATE TABLE candles_1m_2026_06
PARTITION OF candles_1m
FOR VALUES FROM ('2026-06-01 00:00:00+00') TO ('2026-07-01 00:00:00+00');

CREATE TABLE candles_1m_2026_07
PARTITION OF candles_1m
FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00');

-- ============================================================
-- Índices para performance
-- ============================================================

-- Busca das melhores ordens de compra:
-- maior preço primeiro, depois ordem mais antiga.
CREATE INDEX idx_orders_book_bids
ON orders (market_id, price DESC, created_at ASC, order_id ASC)
WHERE side = 'buy'
  AND status IN ('open', 'partial')
  AND remaining_quantity > 0;

-- Busca das melhores ordens de venda:
-- menor preço primeiro, depois ordem mais antiga.
CREATE INDEX idx_orders_book_asks
ON orders (market_id, price ASC, created_at ASC, order_id ASC)
WHERE side = 'sell'
  AND status IN ('open', 'partial')
  AND remaining_quantity > 0;

-- Consulta de ordens por usuário.
CREATE INDEX idx_orders_user_created_at
ON orders (user_id, created_at DESC);

-- Consulta de ordens por mercado e status.
CREATE INDEX idx_orders_market_status
ON orders (market_id, status, created_at DESC);

-- Histórico recente de trades por mercado.
CREATE INDEX idx_trades_market_executed_at
ON trades (market_id, executed_at DESC);

-- Trades por ordem de compra.
CREATE INDEX idx_trades_buy_order
ON trades (buy_order_id);

-- Trades por ordem de venda.
CREATE INDEX idx_trades_sell_order
ON trades (sell_order_id);

-- Trades por comprador.
CREATE INDEX idx_trades_buyer_user_executed_at
ON trades (buyer_user_id, executed_at DESC);

-- Trades por vendedor.
CREATE INDEX idx_trades_seller_user_executed_at
ON trades (seller_user_id, executed_at DESC);

-- Carteiras por usuário.
CREATE INDEX idx_wallets_user
ON wallets (user_id);

-- Carteiras por ativo.
CREATE INDEX idx_wallets_asset
ON wallets (asset_id);

-- Movimentações de carteira em ordem temporal.
CREATE INDEX idx_wallet_movements_wallet_created_at
ON wallet_movements (wallet_id, created_at DESC);

-- Movimentações associadas a ordens.
CREATE INDEX idx_wallet_movements_order
ON wallet_movements (order_id);

-- Movimentações associadas a trades.
CREATE INDEX idx_wallet_movements_trade
ON wallet_movements (trade_id);

-- Auditoria por ordem.
CREATE INDEX idx_order_audit_logs_order_created_at
ON order_audit_logs (order_id, created_at DESC);

-- Candles por mercado e tempo decrescente.
CREATE INDEX idx_candles_1m_market_bucket_desc
ON candles_1m (market_id, bucket_minute DESC);

-- ============================================================
-- Observação importante
-- ============================================================
-- A imutabilidade de trades será reforçada posteriormente por trigger,
-- rule ou política de permissões. Como solicitado, esta etapa não inclui
-- triggers nem funções.