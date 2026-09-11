# Wallet & P2P Transfer Service

Backend-only Spring Boot service for wallets and peer-to-peer transfers in **integer paise**. Built for concurrency correctness: race-free get-or-create, conservation of money, no overdraft, and DB-backed exactly-once idempotency.

## Live demo

| | |
|---|---|
| **Base URL** | https://wallet-transfer-service-production.up.railway.app |
| **Health** | https://wallet-transfer-service-production.up.railway.app/actuator/health |
| **Landing** | https://wallet-transfer-service-production.up.railway.app/ *(JSON index — no UI)* |
| **Repo** | https://github.com/jananik21/wallet-transfer-service |

```bash
BASE=https://wallet-transfer-service-production.up.railway.app

curl -s "$BASE/actuator/health"
curl -s "$BASE/"
curl -s -X POST "$BASE/wallets" -H 'Authorization: Bearer demo-user-1-token'
curl -s -X POST "$BASE/wallets" -H 'Authorization: Bearer demo-user-2-token'
```

New wallets start at balance `0`. For a successful transfer, fund the source wallet in Postgres, then `POST /transfers` with a unique `idempotency_key`. Demo tokens: `demo-user-1-token`, `demo-user-2-token`, `demo-user-3-token`.

Design notes: **[DESIGN.md](DESIGN.md)**. Concurrency / edge-case scripts: **[scripts/](scripts/)**.

## Architecture

```
HTTP (Bearer token)
  → CorrelationIdFilter
    → BearerTokenFilter (/wallets, /transfers)
    → Controllers
    → Services (WalletService / TransferService)
    → MoneyMovementService (ledger primitive)
    → JdbcTemplate + PostgreSQL
```

Observability: JSON logs (Logstash encoder), Micrometer → Prometheus, Actuator health.

## Quick start (Docker — one command)

```bash
docker compose up --build
```

Then:

```bash
curl -s http://127.0.0.1:8080/actuator/health
curl -s -X POST http://127.0.0.1:8080/wallets \
  -H 'Authorization: Bearer demo-user-1-token'
```

Stop: `docker compose down`

## Local run (without Docker app)

Requires JDK 21 + PostgreSQL.

```bash
export JAVA_HOME=...   # JDK 21
export DATABASE_URL=jdbc:postgresql://127.0.0.1:5432/wallet
export DATABASE_USERNAME=wallet
export DATABASE_PASSWORD=wallet
./mvnw spring-boot:run
```

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `DATABASE_URL` | JDBC URL (works with managed Postgres) | `jdbc:postgresql://localhost:5432/wallet` |
| `DATABASE_USERNAME` | DB user | `wallet` |
| `DATABASE_PASSWORD` | DB password | `wallet` |
| `PORT` | HTTP port | `8080` |
| `DB_POOL_SIZE` | Hikari pool size | `30` |
| `POSTGRES_*` | Used by docker-compose for the DB container | see `.env.example` |

Use a full JDBC URL for managed Postgres, e.g.  
`jdbc:postgresql://HOST:5432/DBNAME?sslmode=require`  
(If a host gives `postgres://…`, convert to `jdbc:postgresql://…`.)

**Never hardcode production credentials.** Copy `.env.example` → `.env` for local overrides (`.env` is gitignored).

## Authentication

Simple Bearer tokens (not JWT/OAuth). Tokens are stored as **SHA-256 hashes** in `api_tokens`.

| Token (local/demo) | `user_id` |
|---|---|
| `demo-user-1-token` | `user-1` |
| `demo-user-2-token` | `user-2` |
| `demo-user-3-token` | `user-3` |

Header: `Authorization: Bearer demo-user-1-token`  
A user may only debit **their own** wallet (`403` otherwise). Missing/invalid token → `401`. Tokens are never logged.

## API

### `POST /wallets`
Get-or-create wallet for the authenticated user.  
`201` created / `200` existing.

### `GET /wallets/{id}`
Current balance (`balance_paise`).

### `POST /transfers`
Body:

```json
{
  "from": "<wallet-uuid>",
  "to": "<wallet-uuid>",
  "amount_paise": 10000,
  "idempotency_key": "client-unique-key"
}
```

| Outcome | HTTP |
|---|---|
| New success | `201` + `COMPLETED` |
| Insufficient funds | `422` + `DECLINED_INSUFFICIENT_FUNDS` |
| Idempotent replay | `200` (same transfer id) |
| Same key, different body | `409` |
| Forbidden source wallet | `403` |
| Validation / self-transfer | `400` |
| Missing wallet | `404` |

### `GET /transfers/{id}`
Transfer status.

New wallets start at **0**. Fund via SQL for demos/tests:

```bash
PGPASSWORD=wallet psql -h 127.0.0.1 -U wallet -d wallet \
  -c "UPDATE wallets SET balance_paise = 100000 WHERE user_id = 'user-1';"
```

## Database schema

- **`wallets`**: `UNIQUE(user_id)`, `balance_paise BIGINT CHECK (>= 0)`
- **`transfers`**: `UNIQUE(idempotency_key)`, `request_hash`, status ∈ `PENDING|COMPLETED|DECLINED_INSUFFICIENT_FUNDS`, FKs to wallets
- **`api_tokens`**: `token_hash` → `user_id`

Flyway migrations: `src/main/resources/db/migration/`.

`PENDING` is an **in-transaction** claim only; it is updated to a terminal status before commit. Crashes roll back the whole transaction (no durable incomplete PENDING).

## Concurrency strategy

**Chosen:** `SELECT … FOR UPDATE` on both wallets in **ascending id order**, then atomic conditional debit:

```sql
UPDATE wallets
SET balance_paise = balance_paise - :amount
WHERE id = :from AND balance_paise >= :amount;
```

then credit, all in **one transaction** with the idempotency insert.

**Why:** prevents lost updates and negative balances; sorted locks prevent A→B / B→A deadlocks; conditional debit is easy to explain and enforce.

**Rejected:** SERIALIZABLE-everywhere (retry noise); read-balance-in-Java-then-save (lost updates); insert-transfer-before-locking wallets (FK `FOR KEY SHARE` + later `FOR UPDATE` can deadlock under contention).

## Idempotency strategy

- Uniqueness enforced by **`UNIQUE(idempotency_key)` in PostgreSQL**
- Claim + money movement in the **same DB transaction**
- `request_hash = sha256(from|to|amount)` → same key + different body → `409`
- Survives process restart (not app memory)

## Deadlock handling

Always lock `min(wallet_id)` then `max(wallet_id)`. Never lock in transfer direction order.

## Observability

### Logs
JSON to stdout (`logback-spring.xml`).  
Correlation: read/generate `X-Correlation-ID`, put in MDC, echo on response.

Domain events include: `wallet_created`, `wallet_existing_returned`, `transfer_created`, `transfer_debited`, `transfer_credited`, `transfer_declined_insufficient_funds`, `idempotent_replay`, `idempotency_conflict`.

### Metrics
- HTTP: Actuator/Micrometer (rate, latency, errors, percentiles)
- Domain counters: `transfers_created_total`, `transfers_declined_insufficient_funds_total`, `idempotent_replays_total`

Endpoints:

- Health: `GET /actuator/health`
- Prometheus: `GET /actuator/prometheus`
- Metrics: `GET /actuator/metrics`

### Docker image
Multi-stage build, runs as non-root user `wallet`, `HEALTHCHECK` on `/actuator/health`.

## Manual verification scripts

Bash scripts under [`scripts/`](scripts/) used while developing to check concurrency, money safety, idempotency, and API edge cases. They need a running app, Postgres access (`psql`), `curl`, and `python3`. Details: [`scripts/README.md`](scripts/README.md).

| Script | What it checks |
|---|---|
| `run_concurrency_tests.sh` | Concurrent wallet get-or-create; same-key transfer storm; A↔B contention + overdrafts; conservation; no negatives; no HTTP 5xx |
| `run_edge_case_tests.sh` | Happy-path transfer, insufficient funds, idempotent replay + key conflict, self-transfer, invalid amounts, missing wallet, auth failures |
| `idempotency_persistence_part1.sh` / `part2.sh` | Transfer → restart app → replay same key (no second debit) → different body → `409` |

Local (defaults: `http://127.0.0.1:8080`, local `wallet` DB):

```bash
./scripts/run_edge_case_tests.sh
./scripts/run_concurrency_tests.sh
```

Against a deployed API (set DB vars to the same Postgres the app uses; Neon needs `PGSSLMODE=require`):

```bash
export BASE_URL=https://wallet-transfer-service-production.up.railway.app
export DB_HOST=...          # Postgres host
export DB_PORT=5432
export DB_NAME=...
export DB_USER=...
export DB_PASSWORD=...
export PGSSLMODE=require    # if using Neon / managed SSL

./scripts/run_edge_case_tests.sh
./scripts/run_concurrency_tests.sh
```

Restart idempotency (two steps):

```bash
./scripts/idempotency_persistence_part1.sh
# restart the application
./scripts/idempotency_persistence_part2.sh
```

## Deployment (free tier / ₹0)

The app is deployment-ready: env-based config, health, metrics, container image.

Suggested path (no card required on common free tiers):

1. Create a **managed Postgres** (e.g. Railway/Render/Neon free tier).
2. Build/push this Docker image or connect the GitHub repo to the host.
3. Set `DATABASE_URL`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `PORT`.
4. Confirm `GET /actuator/health` publicly.
5. Re-run the verification scripts with `BASE_URL=https://…`.


## Design write-up

See **[DESIGN.md](DESIGN.md)** for data model, alternatives rejected, idempotency placement, consistency vs availability, and AI usage disclosure.

## Scope

Backend only — single Spring Boot service, no frontend, no microservices.
