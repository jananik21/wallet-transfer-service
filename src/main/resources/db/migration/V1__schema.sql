CREATE TABLE wallets (
    id              UUID            PRIMARY KEY,
    user_id         TEXT            NOT NULL,
    balance_paise   BIGINT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CONSTRAINT uq_wallets_user_id UNIQUE (user_id),
    CONSTRAINT chk_wallets_balance_non_negative CHECK (balance_paise >= 0)
);

CREATE TABLE transfers (
    id                UUID            PRIMARY KEY,
    from_wallet_id    UUID            NOT NULL REFERENCES wallets (id),
    to_wallet_id      UUID            NOT NULL REFERENCES wallets (id),
    amount_paise      BIGINT          NOT NULL,
    status            TEXT            NOT NULL,
    idempotency_key   TEXT            NOT NULL,
    request_hash      TEXT            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CONSTRAINT uq_transfers_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT chk_transfers_amount_positive CHECK (amount_paise > 0),
    CONSTRAINT chk_transfers_different_wallets CHECK (from_wallet_id <> to_wallet_id),
    CONSTRAINT chk_transfers_status CHECK (
        status IN ('PENDING', 'COMPLETED', 'DECLINED_INSUFFICIENT_FUNDS')
    )
);

CREATE INDEX idx_transfers_from_wallet_id ON transfers (from_wallet_id);
CREATE INDEX idx_transfers_to_wallet_id ON transfers (to_wallet_id);
CREATE INDEX idx_transfers_created_at ON transfers (created_at);

CREATE TABLE api_tokens (
    token_hash  TEXT            PRIMARY KEY,
    user_id     TEXT            NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now()
);

CREATE INDEX idx_api_tokens_user_id ON api_tokens (user_id);
