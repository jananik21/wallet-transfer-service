package com.paytm.wallet.transfer;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

@Repository
public class TransferJdbcRepository {

    private static final RowMapper<TransferRecord> MAPPER = (rs, rowNum) -> new TransferRecord(
            rs.getObject("id", UUID.class),
            rs.getObject("from_wallet_id", UUID.class),
            rs.getObject("to_wallet_id", UUID.class),
            rs.getLong("amount_paise"),
            TransferStatus.valueOf(rs.getString("status")),
            rs.getString("idempotency_key"),
            rs.getString("request_hash"),
            rs.getTimestamp("created_at").toInstant(),
            rs.getTimestamp("updated_at").toInstant()
    );

    private final JdbcTemplate jdbcTemplate;

    public TransferJdbcRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public boolean tryInsertPending(UUID id,
                                    UUID fromWalletId,
                                    UUID toWalletId,
                                    long amountPaise,
                                    String idempotencyKey,
                                    String requestHash) {
        int rows = jdbcTemplate.update(
                """
                INSERT INTO transfers (
                    id, from_wallet_id, to_wallet_id, amount_paise,
                    status, idempotency_key, request_hash, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, now(), now())
                ON CONFLICT (idempotency_key) DO NOTHING
                """,
                id,
                fromWalletId,
                toWalletId,
                amountPaise,
                TransferStatus.PENDING.name(),
                idempotencyKey,
                requestHash
        );
        return rows == 1;
    }

    public Optional<TransferRecord> findByIdempotencyKey(String idempotencyKey) {
        var results = jdbcTemplate.query(
                """
                SELECT id, from_wallet_id, to_wallet_id, amount_paise, status,
                       idempotency_key, request_hash, created_at, updated_at
                FROM transfers
                WHERE idempotency_key = ?
                """,
                MAPPER,
                idempotencyKey
        );
        return results.stream().findFirst();
    }

    public Optional<TransferRecord> findById(UUID id) {
        var results = jdbcTemplate.query(
                """
                SELECT id, from_wallet_id, to_wallet_id, amount_paise, status,
                       idempotency_key, request_hash, created_at, updated_at
                FROM transfers
                WHERE id = ?
                """,
                MAPPER,
                id
        );
        return results.stream().findFirst();
    }

    public TransferRecord updateStatus(UUID id, TransferStatus status) {
        jdbcTemplate.update(
                """
                UPDATE transfers
                SET status = ?, updated_at = now()
                WHERE id = ?
                """,
                status.name(),
                id
        );
        return findById(id).orElseThrow(() -> new IllegalStateException("Transfer missing after status update: " + id));
    }
}
