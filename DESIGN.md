# Design write-up — Wallet & P2P Transfer

One-page reasoning for the Paytm R2 exercise.

## 1. Data model

- **`wallets`**: one row per user (`UNIQUE(user_id)`), `balance_paise BIGINT` with `CHECK (balance_paise >= 0)`.
- **`transfers`**: money movement + idempotency record. `UNIQUE(idempotency_key)`, `request_hash`, status `PENDING | COMPLETED | DECLINED_INSUFFICIENT_FUNDS`, FKs to wallets, `amount_paise > 0`, `from ≠ to`.
- **`api_tokens`**: SHA-256(`token`) → `user_id` (no raw tokens stored).

Money is always integer paise (`long` / `BIGINT`). No floats.

`PENDING` exists only inside an open transaction as the idempotency claim; the same transaction updates it to a terminal status before commit.

## 2. Simplest correct concurrency mechanism

Default isolation **READ COMMITTED**, plus:

1. Lock both wallets with `SELECT … FOR UPDATE` in **ascending wallet id order**.
2. Conditional debit: `UPDATE … SET balance = balance - amount WHERE id = :from AND balance >= :amount`.
3. Credit destination.
4. Persist transfer status.

All of the above share **one database transaction** with the idempotency key insert.

## 3. Alternatives considered

| Approach | Verdict |
|---|---|
| Conditional `UPDATE` only (no explicit sorted locks) | Correct for overdraft, but A→B and B→A can still deadlock when taking row locks in opposite orders unless you add ordering or retry. |
| `SELECT FOR UPDATE` sorted + then updates | **Chosen** — clear deadlock story + clear no-overdraft story. |
| `SERIALIZABLE` | Correct but heavier: serialization failures under burst → retry storms; harder to operate/explain than needed here. |
| Read balance in Java → subtract → save | **Rejected** — classic lost update; can create/destroy money. |

## 4. Why alternatives were rejected

We wanted the **simplest mechanism that is still correct under the live probes**, and that is easy to defend in an interview. Sorted row locks + conditional debit meets that bar without SERIALIZABLE complexity.

We also lock wallets **before** inserting the transfer row. Inserting first takes FK `FOR KEY SHARE` on wallet rows; upgrading to `FOR UPDATE` under concurrency can deadlock. Lock-first avoids that.

## 5. How conservation is guaranteed

A successful path always performs **−amount** on source and **+amount** on destination in the same transaction. A declined path performs **neither**. There is no unpaired credit. Therefore the sum of balances across involved wallets (and the system) does not change due to a transfer.

## 6. How overdrafts are prevented

The debit is a single conditional `UPDATE` requiring `balance_paise >= amount`. Zero rows updated ⇒ `DECLINED_INSUFFICIENT_FUNDS`, no credit. Table `CHECK (balance_paise >= 0)` is a backstop.

## 7. How deadlocks are prevented

Both wallets are locked in deterministic **sorted id order**. Concurrent A→B and B→A take locks in the same sequence → no lock cycle.

## 8. Where idempotency is stored

PostgreSQL `transfers.idempotency_key` with a **UNIQUE** constraint. Also store `request_hash` of `(from, to, amount_paise)`.

## 9. Why idempotency is committed atomically with money movement

If you check the key in one transaction and move money in another (TOCTOU), concurrent retries can double-apply. Inserting/claiming the unique key in the **same transaction** as debit/credit means concurrent duplicates either wait and see the committed result, or lose the insert race and replay/conflict — they cannot both move money.

## 10. Same key + different request

Compare `request_hash`. Mismatch ⇒ **HTTP 409 Conflict**, no additional movement.

## 11. Consistency vs availability

This is a **money** workload: we choose **strong consistency** (row locks, transactional debit/credit, DB unique idempotency) over availability under conflict. Contended transfers wait or decline; we do not accept “eventually correct balances.” Under partition from the database, the API cannot safely take money movement traffic — fail closed.

## 12. AI usage disclosure

### AI DIRECTED
I owned the architectural decisions: single Spring Boot + PostgreSQL service; integer paise; race-free `INSERT … ON CONFLICT` for wallets; sorted `FOR UPDATE` + conditional debit; DB-unique idempotency in the same transaction as money movement; `PENDING` as in-TX claim only; Bearer token hash auth; Docker multi-stage/non-root; burst scripts for the three live gates; consistency-over-availability trade-off.

I used AI assistance for implementation boilerplate, wiring Spring/Flyway/Actuator, drafting scripts/docs, debugging (Flyway checksums, logback blank line, contention script key reuse, FK lock ordering), and review.

### AI DECIDED (reviewed and accepted)
- Spring Boot 3.3 / Java 21 baseline stack choices for a small interview service.
- Logstash JSON encoder + Micrometer Prometheus as the default observability wiring.
- Testcontainers-oriented integration test dependency setup for later Postgres-backed tests.
- Concrete packaging details of the multi-stage Dockerfile (Temurin JRE Alpine, non-root user name).

I can explain every important path in the final code (wallet get-or-create, transfer/idempotency transaction, burst scripts, Docker/health/metrics).

## Free-tier cost note

Target cost **₹0**: free-tier container host + free managed Postgres (e.g. Render/Railway/Fly.io/Neon style free plans). No paid add-ons required for the exercise scope.
