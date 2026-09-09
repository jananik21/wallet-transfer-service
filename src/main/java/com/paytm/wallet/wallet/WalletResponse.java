package com.paytm.wallet.wallet;

import java.time.Instant;
import java.util.UUID;

public record WalletResponse(
        UUID id,
        String userId,
        long balancePaise,
        Instant createdAt,
        Instant updatedAt
) {

    static WalletResponse from(WalletEntity entity) {
        return new WalletResponse(
                entity.getId(),
                entity.getUserId(),
                entity.getBalancePaise(),
                entity.getCreatedAt(),
                entity.getUpdatedAt()
        );
    }
}
