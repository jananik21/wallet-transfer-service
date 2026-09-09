package com.paytm.wallet.wallet;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

@Repository
public class WalletJdbcRepository {

    private static final RowMapper<WalletEntity> WALLET_MAPPER = (rs, rowNum) -> new WalletEntity(
            rs.getObject("id", UUID.class),
            rs.getString("user_id"),
            rs.getLong("balance_paise"),
            toInstant(rs.getTimestamp("created_at")),
            toInstant(rs.getTimestamp("updated_at"))
    );

    private final JdbcTemplate jdbcTemplate;

    public WalletJdbcRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }


    public boolean insertIgnoreConflict(UUID id, String userId) {
        int rows = jdbcTemplate.update(
                """
                INSERT INTO wallets (id, user_id, balance_paise, created_at, updated_at)
                VALUES (?, ?, 0, now(), now())
                ON CONFLICT (user_id) DO NOTHING
                """,
                id,
                userId
        );
        return rows == 1;
    }

    public Optional<WalletEntity> findByUserId(String userId) {
        var results = jdbcTemplate.query(
                """
                SELECT id, user_id, balance_paise, created_at, updated_at
                FROM wallets
                WHERE user_id = ?
                """,
                WALLET_MAPPER,
                userId
        );
        return results.stream().findFirst();
    }

    public Optional<WalletEntity> findById(UUID id) {
        var results = jdbcTemplate.query(
                """
                SELECT id, user_id, balance_paise, created_at, updated_at
                FROM wallets
                WHERE id = ?
                """,
                WALLET_MAPPER,
                id
        );
        return results.stream().findFirst();
    }

    private static Instant toInstant(Timestamp timestamp) {
        return timestamp.toInstant();
    }
}
