# Manual verification scripts

Bash helpers I used while validating wallet get-or-create, transfers, idempotency, and concurrency.

**Requirements:** running app, Postgres reachable with the same credentials as the app, `curl`, `psql`, `python3`.

**Environment (optional):**

| Variable | Default | Purpose |
|---|---|---|
| `BASE_URL` | `http://127.0.0.1:8080` | API base |
| `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` | local `wallet` defaults | Direct DB checks (balances, row counts) |
| `IDEMPOTENCY_STATE_FILE` | `/tmp/wallet-idempotency-restart.env` | State between restart parts |

## Scripts

```bash
./scripts/run_concurrency_tests.sh
./scripts/run_edge_case_tests.sh

# Idempotency across process restart (two steps)
./scripts/idempotency_persistence_part1.sh
# restart the application
./scripts/idempotency_persistence_part2.sh
```

| Script | What it covers |
|---|---|
| `run_concurrency_tests.sh` | Concurrent get-or-create; same-key transfer storm; A↔B contention + overdrafts; conservation / no negatives / no 5xx |
| `run_edge_case_tests.sh` | Happy-path transfer, insufficient funds, idempotent replay + key conflict, self-transfer, bad amounts, missing wallet, auth failures |
| `idempotency_persistence_part1.sh` / `part2.sh` | Transfer → restart app → replay same key (no second debit) → different body → 409 |
| `common.sh` | Shared helpers (not run directly) |

Against a remote API (DB still needs network access for balance checks):

```bash
BASE_URL=https://YOUR_HOST ./scripts/run_concurrency_tests.sh
```
