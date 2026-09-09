package com.paytm.wallet.auth;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.Optional;

@Repository
public class TokenRepository {

    private final JdbcTemplate jdbcTemplate;

    public TokenRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public Optional<String> findUserIdByTokenHash(String tokenHash) {
        var results = jdbcTemplate.query(
                """
                SELECT user_id
                FROM api_tokens
                WHERE token_hash = ?
                """,
                (rs, rowNum) -> rs.getString("user_id"),
                tokenHash
        );
        return results.stream().findFirst();
    }
}
